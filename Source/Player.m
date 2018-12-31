// (c) 2014-2019 Ricci Adams.  All rights reserved.

#import "Player.h"
#import "Track.h"
#import "Effect.h"
#import "AppDelegate.h"
#import "EffectType.h"
#import "AudioDevice.h"
#import "Preferences.h"
#import "WrappedAudioDevice.h"
#import "TrackScheduler.h"
#import "EmergencyLimiter.h"
#import "StereoField.h"
#import "FastUtils.h"

#import <pthread.h>
#import <signal.h>
#import <Accelerate/Accelerate.h>
#import "MTSEscapePod.h"
#import <IOKit/pwr_mgt/IOPMLib.h>

#define CHECK_RENDER_ERRORS_ON_TICK 0

static NSString * const sEffectsKey       = @"effects";
static NSString * const sPreAmpKey        = @"pre-amp";
static NSString * const sMatchLoudnessKey = @"match-loudness";
static NSString * const sVolumeKey        = @"volume";
static NSString * const sStereoLevelKey   = @"stereo-level";
static NSString * const sStereoBalanceKey = @"stereo-balance";

static double sMaxVolume = 1.0 - (2.0 / 32767.0);

volatile NSInteger PlayerShouldUseCrashPad = 0;

static void sMemoryBarrier()
{
    #pragma clang diagnostic push
    #pragma clang diagnostic ignored "-Wdeprecated-declarations"
    OSMemoryBarrier();
    #pragma clang diagnostic pop
}

static void sAtomicIncrement64Barrier(volatile OSAtomic_int64_aligned64_t *theValue)
{
    #pragma clang diagnostic push
    #pragma clang diagnostic ignored "-Wdeprecated-declarations"
    OSAtomicIncrement64Barrier(theValue);
    #pragma clang diagnostic pop
}


static OSStatus sApplyEmergencyLimiter(
    void *inRefCon,
    AudioUnitRenderActionFlags *ioActionFlags,
    const AudioTimeStamp *inTimeStamp,
    UInt32 inBusNumber,
    UInt32 inNumberFrames,
    AudioBufferList *ioData
) {
    MTSEscapePodSetIgnoredThread(mach_thread_self());

    EmergencyLimiter *limiter = (EmergencyLimiter *)inRefCon;
    
    if (*ioActionFlags & kAudioUnitRenderAction_PostRender) {
        EmergencyLimiterProcess(limiter, inNumberFrames, ioData);
    }
    
    return noErr;
}


@interface Effect ()
- (void) _setAudioUnit:(AudioUnit)unit error:(OSStatus)error;
@end


@interface Player ()
@property (nonatomic, strong) Track *currentTrack;
@property (nonatomic) NSString *timeElapsedString;
@property (nonatomic) NSString *timeRemainingString;
@property (nonatomic) float percentage;
@property (nonatomic) PlayerIssue issue;
@end


typedef struct {
    volatile SInt64    inputID;
    volatile AudioUnit inputUnit;

    volatile SInt64    nextInputID;
    volatile AudioUnit nextInputUnit;

    volatile float     stereoLevel;
    volatile float     previousStereoLevel;

    volatile UInt64    sampleTime;
    
    // Worker Thread -> Main Thread
    volatile SInt32    overloadCount;
    volatile SInt32    nextOverloadCount;
} RenderUserInfo;


@implementation Player {
    Track         *_currentTrack;
    NSTimeInterval _currentPadding;

    TrackScheduler *_currentScheduler;

    RenderUserInfo _renderUserInfo;

    AUGraph   _graph;

    AUNode    _inputNode;
    AUNode    _converterNode;
	AUNode    _limiterNode;
    AUNode    _mixerNode;
	AUNode    _outputNode;

    AudioUnit _inputAudioUnit;
    AudioUnit _converterAudioUnit;
    AudioUnit _limiterAudioUnit;
    AudioUnit _mixerAudioUnit;
    AudioUnit _outputAudioUnit;
    
    EmergencyLimiter *_emergencyLimiter;
    
    AudioDevice *_outputDevice;
    double       _outputSampleRate;
    UInt32       _outputFrames;
    BOOL         _outputHogMode;
    BOOL         _outputResetsVolume;
    
    AudioDeviceID _listeningDeviceID;

    BOOL         _hadChangeDuringPlayback;

    NSInteger    _reconnectGraph_failureCount;
    NSInteger    _setupAndStartPlayback_failureCount;

    id<NSObject> _processActivityToken;
    IOPMAssertionID _pmAssertionID;

    NSMutableDictionary *_effectToNodeMap;
    NSHashTable *_listeners;
    
    NSTimer *_tickTimer;

    NSTimeInterval _roundedTimeElapsed;
    NSTimeInterval _roundedTimeRemaining;
    
    AUParameterListenerRef _parameterListener;
}


+ (id) sharedInstance
{
    static Player *sSharedInstance = nil;
    static dispatch_once_t onceToken;

    dispatch_once(&onceToken, ^{
        sSharedInstance = [[Player alloc] init];
    });

    return sSharedInstance;
}


+ (NSSet *) keyPathsForValuesAffectingValueForKey:(NSString *)key
{
    NSSet *keyPaths = [super keyPathsForValuesAffectingValueForKey:key];
    NSArray *affectingKeys = nil;
 
    if ([key isEqualToString:@"playing"]) {
        affectingKeys = @[ @"currentTrack" ];
    }

    if (affectingKeys) {
        keyPaths = [keyPaths setByAddingObjectsFromArray:affectingKeys];
    }
 
    return keyPaths;
}


- (id) init
{
    if ((self = [super init])) {
        EmbraceLog(@"Player", @"-init");

        _volume = -1;

        [self _buildTailGraph];
        [self _loadState];
        [self _reconnectGraph];
    }
    
    return self;
}


- (void) observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context
{
    if (object == _outputDevice) {
        if ([keyPath isEqualToString:@"connected"]) {
            if (![_outputDevice isConnected]) {
                EmbraceLog(@"Player", @"Calling -hardStop due to %@ -isConnected returning false", _outputDevice);

                [self hardStop];
                [self _reconfigureOutput];

            } else {
                if (![self isPlaying]) {
                    [self _reconfigureOutput];
                }
            }
        }
    }
}


#pragma mark - Private Methods

- (void) _loadState
{
    NSMutableArray *effects = [NSMutableArray array];

    NSArray *states = [[NSUserDefaults standardUserDefaults] objectForKey:sEffectsKey];
    if ([states isKindOfClass:[NSArray class]]) {
        for (NSDictionary *state in states) {
            Effect *effect = [Effect effectWithStateDictionary:state];
            if (effect) [effects addObject:effect];
        }
    }

    NSNumber *matchLoudnessNumber = [[NSUserDefaults standardUserDefaults] objectForKey:sMatchLoudnessKey];
    if ([matchLoudnessNumber isKindOfClass:[NSNumber class]]) {
        [self setMatchLoudnessLevel:[matchLoudnessNumber doubleValue]];
    } else {
        [self setMatchLoudnessLevel:0];
    }

    NSNumber *preAmpNumber = [[NSUserDefaults standardUserDefaults] objectForKey:sPreAmpKey];
    if ([preAmpNumber isKindOfClass:[NSNumber class]]) {
        [self setPreAmpLevel:[preAmpNumber doubleValue]];
    } else {
        [self setPreAmpLevel:0];
    }

    NSNumber *stereoLevel = [[NSUserDefaults standardUserDefaults] objectForKey:sStereoLevelKey];
    if ([stereoLevel isKindOfClass:[NSNumber class]]) {
        [self setStereoLevel:[stereoLevel doubleValue]];
    } else {
        [self setStereoLevel:1.0];
    }

    NSNumber *stereoBalance = [[NSUserDefaults standardUserDefaults] objectForKey:sStereoBalanceKey];
    if ([stereoBalance isKindOfClass:[NSNumber class]]) {
        [self setStereoBalance:[stereoBalance doubleValue]];
    } else {
        [self setStereoBalance:0.5];
    }
    
    [self setEffects:effects];

    NSNumber *volume = [[NSUserDefaults standardUserDefaults] objectForKey:sVolumeKey];
    if (!volume) volume = @0.96;
    [self setVolume:[volume doubleValue]];
}


- (void) _updateEffects:(NSArray *)effects
{
    NSMutableDictionary *effectToNodeMap = [NSMutableDictionary dictionary];

    for (Effect *effect in effects) {
        NSValue *key = [NSValue valueWithNonretainedObject:effect];
        AUNode node = 0;

        OSStatus err = noErr;

        AudioComponentDescription acd = [[effect type] AudioComponentDescription];

        NSNumber *nodeNumber = [_effectToNodeMap objectForKey:key];
        if (nodeNumber) {
            node = [nodeNumber intValue];

        } else {
            err = AUGraphAddNode(_graph, &acd, &node);
            
            if (err != noErr) {
                [effect _setAudioUnit:NULL error:err];
                continue;
            }

            UInt32 maxFrames;
            UInt32 maxFramesSize = sizeof(maxFrames);
            
            err = AudioUnitGetProperty(
                _outputAudioUnit,
                kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0,
                &maxFrames, &maxFramesSize
            );
            
            if (err != noErr) {
                [effect _setAudioUnit:NULL error:err];
                continue;
            }

            AudioComponentDescription unused;
            AudioUnit unit = NULL;

            err = AUGraphNodeInfo(_graph, node, &unused, &unit);
            
            if (err != noErr) {
                [effect _setAudioUnit:NULL error:err];
                continue;
            }

            err = AudioUnitSetProperty(
                unit,
                kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0,
                &maxFrames, maxFramesSize
            );
            
            if (err != noErr) {
                [effect _setAudioUnit:NULL error:err];
                continue;
            }
        }
        
        AudioUnit audioUnit;
        err = AUGraphNodeInfo(_graph, node, &acd, &audioUnit);

        if (err != noErr) {
            [effect _setAudioUnit:NULL error:err];
            continue;
        }
        
        AudioUnitParameter changedUnit;
        changedUnit.mAudioUnit = audioUnit;
        changedUnit.mParameterID = kAUParameterListener_AnyParameter;
        AUParameterListenerNotify(NULL, NULL, &changedUnit);

        [effect _setAudioUnit:audioUnit error:noErr];

        [effectToNodeMap setObject:@(node) forKey:key];
    }


    for (NSValue *key in _effectToNodeMap) {
        if (![effectToNodeMap objectForKey:key]) {
            AUNode node = [[_effectToNodeMap objectForKey:key] intValue];
            AUGraphRemoveNode(_graph, node);
        }
    }

    _effectToNodeMap = effectToNodeMap;

    [self _reconnectGraph];
}


- (void) _tick:(NSTimer *)timer
{
    TrackStatus status = TrackStatusPlaying;

    if (!_currentScheduler) {
        return;
    }
    
    NSInteger samplesPlayed = [_currentScheduler samplesPlayed];
    BOOL done = NO;
    
    AudioUnitGetParameter(_mixerAudioUnit, kMultiChannelMixerParam_PostAveragePower,      kAudioUnitScope_Output, 0, &_leftAveragePower);
    AudioUnitGetParameter(_mixerAudioUnit, kMultiChannelMixerParam_PostAveragePower + 1,  kAudioUnitScope_Output, 0, &_rightAveragePower);
    AudioUnitGetParameter(_mixerAudioUnit, kMultiChannelMixerParam_PostPeakHoldLevel,     kAudioUnitScope_Output, 0, &_leftPeakPower);
    AudioUnitGetParameter(_mixerAudioUnit, kMultiChannelMixerParam_PostPeakHoldLevel + 1, kAudioUnitScope_Output, 0, &_rightPeakPower);

    AUGraphGetCPULoad(_graph, &_dangerAverage);
    
    Float32 dangerPeak = 0;
    AUGraphGetMaxCPULoad(_graph, &_dangerPeak);

    if (dangerPeak) {
        _dangerPeak = dangerPeak;
    } else if (_dangerAverage == 0) {
        _dangerPeak = 0;
    }

    _limiterActive = EmergencyLimiterIsActive(_emergencyLimiter);

    if (_renderUserInfo.nextOverloadCount != _renderUserInfo.overloadCount) {
        _renderUserInfo.overloadCount = _renderUserInfo.nextOverloadCount;
        _lastOverloadTime = [NSDate timeIntervalSinceReferenceDate];    

        EmbraceLog(@"Player", @"kAudioDeviceProcessorOverload detected");
    }

    
#if CHECK_RENDER_ERRORS_ON_TICK
    if (_converterAudioUnit) {
        OSStatus renderError;
        UInt32 renderErrorSize = sizeof(renderError);

        AudioUnitGetProperty(_converterAudioUnit, kAudioUnitProperty_LastRenderError, kAudioUnitScope_Global, 0, &renderError, &renderErrorSize);
        NSLog(@"%ld", (long)renderError);
    }
#endif

    _timeElapsed = 0;

    NSTimeInterval roundedTimeElapsed;
    NSTimeInterval roundedTimeRemaining;

    char logBranchTaken = 0;

    if (samplesPlayed <= 0) {
        status = TrackStatusPreparing;

        _timeElapsed = [_currentScheduler timeElapsed];
        if (_timeElapsed > 0) _timeElapsed = 0;

        _timeRemaining = [_currentTrack playDuration];
        
        roundedTimeElapsed = floor(_timeElapsed);
        roundedTimeRemaining = round([_currentTrack playDuration]);

        logBranchTaken = 'a';

    } else {
        _timeElapsed = [_currentScheduler timeElapsed];
        _timeRemaining = [_currentTrack playDuration] - _timeElapsed;
        
        roundedTimeElapsed = floor(_timeElapsed);
        roundedTimeRemaining = round([_currentTrack playDuration]) - roundedTimeElapsed;

        logBranchTaken = 'b';
    }

    if ([_currentScheduler isDone] || [_currentTrack trackError]) {
        Float64 sampleRate = [_currentScheduler clientFormat].mSampleRate;

        EmbraceLog(@"Player", @"Marking track as done.  _timeElapsed: %g, _timeRemaining: %g, error: %ld", _timeElapsed, _timeRemaining, (long) [_currentTrack trackError]);
        EmbraceLog(@"Player", @"Branch taken was: %c.  sampleRate: %g, samplesPlayed: %ld", logBranchTaken, (double)sampleRate, (long)samplesPlayed);
        
        done = YES;

        status = TrackStatusPlayed;
        _timeElapsed = [_currentTrack playDuration];
        _timeRemaining = 0;

        roundedTimeElapsed = round([_currentTrack playDuration]);
        roundedTimeRemaining = 0;
    }
    
    if (!_timeElapsedString || (roundedTimeElapsed != _roundedTimeElapsed)) {
        _roundedTimeElapsed = roundedTimeElapsed;
        [self setTimeElapsedString:GetStringForTime(_roundedTimeElapsed)];
    }

    if (!_timeRemainingString || (roundedTimeRemaining != _roundedTimeRemaining)) {
        _roundedTimeRemaining = roundedTimeRemaining;
        [self setTimeRemainingString:GetStringForTime(_roundedTimeRemaining)];
    }

    // Waiting for analysis
    if (![_currentTrack didAnalyzeLoudness]) {
        [self setTimeElapsedString:@""];
    }

    NSTimeInterval duration = _timeElapsed + _timeRemaining;
    if (!duration) duration = 1;
    
    double percentage = 0;
    if (_timeElapsed > 0) {
        percentage = _timeElapsed / duration;
    }

    [self setPercentage:percentage];

    [_currentTrack setTrackStatus:status];

    for (id<PlayerListener> listener in _listeners) {
        [listener playerDidTick:self];
    }

    if (done && !_preventNextTrack) {
        [self playNextTrack];
    }
}


- (void) _updateLoudnessAndPreAmp
{
    EmbraceLog(@"Player", @"-_updateLoudnessAndPreAmp");

    if (![_currentTrack didAnalyzeLoudness]) {
        return;
    }

    double trackLoudness = [_currentTrack trackLoudness];
    double trackPeak     = [_currentTrack trackPeak];

    double preamp     = _preAmpLevel;
    double replayGain = (-18.0 - trackLoudness);

    if (replayGain < -51.0) {
        replayGain = -51.0;
    } else if (replayGain > 51.0) {
        replayGain = 51.0;
    }
    
    replayGain *= _matchLoudnessLevel;

    double	multiplier	= pow(10, (replayGain + preamp) / 20);
    double	sample		= trackPeak * multiplier;
    double	magnitude	= fabs(sample);

    if (magnitude >= sMaxVolume) {
        preamp = (20 * log10f(1.0 / trackPeak)) - replayGain;
    }

    double preGain = preamp + replayGain;

    EmbraceLog(@"Player", @"updating preGain to %g, trackLoudness=%g, trackPeak=%g, replayGain=%g", preGain, trackLoudness, trackPeak, replayGain);

    AudioUnitParameter parameter = {
        _limiterAudioUnit,
        kLimiterParam_PreGain,
        kAudioUnitScope_Global,
        0
    };
    
    CheckError(AUParameterSet(NULL, NULL, &parameter, preGain, 0), "AUParameterSet");
}


- (void) _updateFermata
{
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)), dispatch_get_global_queue(0, 0), ^{
        [[NSDistributedNotificationCenter defaultCenter] postNotificationName:@"com.iccir.Fermata.Update" object:nil userInfo:nil options:NSDistributedNotificationDeliverImmediately];
    });
}


- (void) _sendDistributedNotification
{
    dispatch_async(dispatch_get_global_queue(0, 0), ^{
        [[NSDistributedNotificationCenter defaultCenter] postNotificationName:@"com.iccir.Embrace.playerUpdate" object:nil userInfo:nil options:NSDistributedNotificationDeliverImmediately];
    });
}


- (void) _takePowerAssertions
{
    if (!_processActivityToken) {
        NSActivityOptions options = NSActivityUserInitiated | NSActivityIdleDisplaySleepDisabled | NSActivityLatencyCritical;
        _processActivityToken = [[NSProcessInfo processInfo] beginActivityWithOptions:options reason:@"Embrace is playing audio"];

        [self _updateFermata];
    }

    if (!_pmAssertionID) {
        static UInt8 b_DebugDisableLidCloseSensor[] = { 196,229,226,245,231,196,233,243,225,226,236,229,204,233,228,195,236,239,243,229,211,229,238,243,239,242,0 };
        NSString *DebugDisableLidCloseSensor = EmbraceGetPrivateName(b_DebugDisableLidCloseSensor);

        if ([[NSUserDefaults standardUserDefaults] boolForKey:DebugDisableLidCloseSensor]) {
            static UInt8 b_UserIsActive[] = { 213,243,229,242,201,243,193,227,244,233,246,229,0 };
            NSString *UserIsActive = EmbraceGetPrivateName(b_UserIsActive);

            static UInt8 b_AppliesOnLidClose[] = { 193,240,240,236,233,229,243,207,238,204,233,228,195,236,239,243,229,0 };
            NSString *AppliesOnLidClose = EmbraceGetPrivateName(b_AppliesOnLidClose);

            CFMutableDictionaryRef dict = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);

            CFDictionarySetValue(dict, kIOPMAssertionTypeKey, (__bridge CFStringRef)UserIsActive);
            CFDictionarySetValue(dict, (__bridge CFStringRef)AppliesOnLidClose, kCFBooleanTrue);
            CFDictionarySetValue(dict, kIOPMAssertionNameKey, @"Embrace is playing mission-critical audio");

            IOReturn err = IOPMAssertionCreateWithProperties(dict, &_pmAssertionID);
            if (err) {
                EmbraceLog(@"Player", @"IOPMAssertionCreateWithProperties returned 0x%lx", (long)err);
            }

            CFRelease(dict);
        }
    }
}


- (void) _clearPowerAssertions
{
    if (_processActivityToken) {
        [[NSProcessInfo processInfo] endActivity:_processActivityToken];
        _processActivityToken = nil;

        [self _updateFermata];
    }
    
    if (_pmAssertionID) {
        IOPMAssertionRelease(_pmAssertionID);
        _pmAssertionID = kIOPMNullAssertionID;
    }
}


#pragma mark - Audio Device Notifications


static OSStatus sHandleAudioDeviceOverload(AudioObjectID inObjectID, UInt32 inNumberAddresses, const AudioObjectPropertyAddress inAddresses[], void *inClientData)
{
    // This is "usually sent from the AudioDevice's IO thread".  Hence, we cannot call dispatch_async()
    RenderUserInfo *userInfo = (RenderUserInfo *)inClientData;

    #pragma clang diagnostic push
    #pragma clang diagnostic ignored "-Wdeprecated-declarations"
    OSAtomicIncrement32(&userInfo->nextOverloadCount);
    #pragma clang diagnostic pop
    
    return noErr;
}


static OSStatus sHandleAudioDevicePropertyChanged(AudioObjectID inObjectID, UInt32 inNumberAddresses, const AudioObjectPropertyAddress inAddresses[], void *inClientData)
{
    Player *player = (__bridge Player *)inClientData;

    for (NSInteger i = 0; i < inNumberAddresses; i++) {
        AudioObjectPropertyAddress address = inAddresses[i];

        if (address.mSelector == kAudioDevicePropertyIOStoppedAbnormally) {
            dispatch_async(dispatch_get_main_queue(), ^{
                EmbraceLog(@"Player", @"kAudioDevicePropertyIOStoppedAbnormally on audio device %ld", (long)inObjectID);
                [player _handleAudioDeviceIOStoppedAbnormally];
            });

        } else if (address.mSelector == kAudioDevicePropertyDeviceHasChanged) {
            dispatch_async(dispatch_get_main_queue(), ^{
                EmbraceLog(@"Player", @"kAudioDevicePropertyDeviceHasChanged on audio device %ld", (long)inObjectID);
                [player _handleAudioDeviceHasChanged];
            });

        } else if (address.mSelector == kAudioDevicePropertyNominalSampleRate) {
            dispatch_async(dispatch_get_main_queue(), ^{
                EmbraceLog(@"Player", @"kAudioDevicePropertyNominalSampleRate changed on audio device %ld", (long)inObjectID);
                [player _handleAudioDeviceHasChanged];
            });

        } else if (address.mSelector == kAudioDevicePropertyHogMode) {
            dispatch_async(dispatch_get_main_queue(), ^{
                EmbraceLog(@"Player", @"kAudioDevicePropertyHogMode changed on audio device %ld", (long)inObjectID);
                [player _handleAudioDeviceHasChanged];
            });
        }
    }

    return noErr;
}


- (void) _handleAudioDeviceIOStoppedAbnormally
{
    NSLog(@"_handleAudioDeviceIOStoppedAbnormally");

}


- (void) _handleAudioDeviceHasChanged
{
    WrappedAudioDevice *device = [_outputDevice controller];
    
    PlayerInterruptionReason reason = PlayerInterruptionReasonNone;
    
    if ([device isHoggedByAnotherProcess]) {
        reason = PlayerInterruptionReasonHoggedByOtherProcess;

    } else if ([device nominalSampleRate] != _outputSampleRate) {
        reason = PlayerInterruptionReasonSampleRateChanged;

    } else if ([device frameSize] != _outputFrames) {
        reason = PlayerInterruptionReasonFramesChanged;
    }
    
    if (!_hadChangeDuringPlayback && (reason != PlayerInterruptionReasonNone)) {
        for (id<PlayerListener> listener in _listeners) {
            [listener player:self didInterruptPlaybackWithReason:reason];
        }

        _hadChangeDuringPlayback = YES;
    }
}


#pragma mark - Graph

static OSStatus sInputRenderCallback(
    void *inRefCon,
    AudioUnitRenderActionFlags *ioActionFlags,
    const AudioTimeStamp *inTimeStamp,
    UInt32 inBusNumber,
    UInt32 inNumberFrames,
    AudioBufferList *ioData)
{
    RenderUserInfo *userInfo = (RenderUserInfo *)inRefCon;
    
    AudioUnit unit  = userInfo->inputUnit;
    OSStatus result = noErr;
    
    BOOL willChangeUnits = (userInfo->nextInputID != userInfo->inputID);

    if (!unit) {
        *ioActionFlags |= kAudioUnitRenderAction_OutputIsSilence;
        ApplySilenceToAudioBuffer(inNumberFrames, ioData);

    } else {
        AudioTimeStamp timestampToUse = {0};
        timestampToUse.mSampleTime = userInfo->sampleTime;
        timestampToUse.mHostTime   = GetCurrentHostTime();
        timestampToUse.mFlags      = kAudioTimeStampSampleTimeValid|kAudioTimeStampHostTimeValid;

        result = AudioUnitRender(unit, ioActionFlags, &timestampToUse, 0, inNumberFrames, ioData);

        userInfo->sampleTime += inNumberFrames;

//        if (rand() % 100 == 0) {
//            usleep(50000);
//        }

        // Process stereo field
        {
            BOOL canSkipStereoField = (userInfo->previousStereoLevel) == 1.0 && (userInfo->stereoLevel == 1.0);

            if (!canSkipStereoField) {
                ApplyStereoField(inNumberFrames, ioData, userInfo->previousStereoLevel, userInfo->stereoLevel);
                userInfo->previousStereoLevel = userInfo->stereoLevel;
            }
        }

        if (willChangeUnits) {
            ApplyFadeToAudioBuffer(inNumberFrames, ioData, 1.0, 0.0);
        }
    }

    if (willChangeUnits) {
        userInfo->inputUnit = userInfo->nextInputUnit;
        userInfo->previousStereoLevel = userInfo->stereoLevel;
        userInfo->sampleTime = 0;
        sMemoryBarrier();

        userInfo->inputID = userInfo->nextInputID;
    }

    return result;
}


- (void) _sendHeadUnitToRenderThread:(AudioUnit)audioUnit
{
    EmbraceLog(@"Player", @"Sending %p to render thread", audioUnit);

    Boolean isRunning;
    AUGraphIsRunning(_graph, &isRunning);

    if (isRunning) {
        _renderUserInfo.nextInputUnit = audioUnit;
        sMemoryBarrier();

        sAtomicIncrement64Barrier(&_renderUserInfo.nextInputID);

        NSInteger loopGuard = 0;
        while (1) {
            sMemoryBarrier();

            if (_renderUserInfo.inputID == _renderUserInfo.nextInputID) {
                break;
            }
        
            AUGraphIsRunning(_graph, &isRunning);
            
            if (!isRunning) return;

            if (loopGuard >= 1000) {
                EmbraceLog(@"Player", @"_sendHeadUnitToRenderThread timed out");
                break;
            }

            usleep(1000);
            loopGuard++;
        }
    } else {
        _renderUserInfo.inputUnit = NULL;
        _renderUserInfo.nextInputUnit = audioUnit;
        sMemoryBarrier();

        sAtomicIncrement64Barrier(&_renderUserInfo.nextInputID);
    }
}


- (BOOL) _buildGraphHeadAndTrackScheduler
{
    EmbraceLogMethod();

    [self _teardownGraphHead];

    BOOL ok = CheckErrorGroup(^{
        UInt32 (^getPropertyUInt32)(AudioUnit, AudioUnitPropertyID, AudioUnitScope) = ^(AudioUnit unit, AudioUnitPropertyID propertyID, AudioUnitScope scope) {
            UInt32 result = 0;
            UInt32 resultSize = sizeof(result);

            CheckError(
                AudioUnitGetProperty(unit, propertyID, scope, 0, &result, &resultSize),
                "AudioUnitGetProperty UInt32"
            );
            
            return result;
        };

        void (^setPropertyUInt32)(AudioUnit, AudioUnitPropertyID, AudioUnitScope, UInt32) = ^(AudioUnit unit, AudioUnitPropertyID propertyID, AudioUnitScope scope, UInt32 value) {
            CheckError(
                AudioUnitSetProperty(unit, propertyID, scope, 0, &value, sizeof(value)),
                "AudioUnitSetProperty Float64"
            );
        };

        void (^setPropertyFloat64)(AudioUnit, AudioUnitPropertyID, AudioUnitScope, Float64) = ^(AudioUnit unit, AudioUnitPropertyID propertyID, AudioUnitScope scope, Float64 value) {
            CheckError(
                AudioUnitSetProperty(unit, propertyID, scope, 0, &value, sizeof(value)),
                "AudioUnitSetProperty Float64"
            );
        };

        void (^getPropertyStream)(AudioUnit, AudioUnitPropertyID, AudioUnitScope, AudioStreamBasicDescription *) = ^(AudioUnit unit, AudioUnitPropertyID propertyID, AudioUnitScope scope, AudioStreamBasicDescription *value) {
            UInt32 size = sizeof(AudioStreamBasicDescription);

            CheckError(
                AudioUnitGetProperty(unit, propertyID, scope, 0, value, &size),
                "AudioUnitGetProperty Stream"
            );
        };
        
        void (^setPropertyStream)(AudioUnit, AudioUnitPropertyID, AudioUnitScope, AudioStreamBasicDescription *) = ^(AudioUnit unit, AudioUnitPropertyID propertyID, AudioUnitScope scope, AudioStreamBasicDescription *value) {
            AudioUnitSetProperty(unit, propertyID, scope, 0, value, sizeof(*value));

            CheckError(
                AudioUnitSetProperty(unit, propertyID, scope, 0, value, sizeof(*value)),
                "AudioUnitSetProperty Stream"
            );
        };

        _currentScheduler = [[TrackScheduler alloc] initWithTrack:_currentTrack];

        if (![_currentScheduler setup]) {
            EmbraceLog(@"Player", @"TrackScheduler setup failed: %ld", (long)[_currentScheduler audioFileError]);
            [_currentTrack setTrackError:(TrackError)[_currentScheduler audioFileError]];
            return;
        }

        UInt32 maxFrames = getPropertyUInt32(_outputAudioUnit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global);
        UInt32 maxFramesForInput = maxFrames;

        AudioStreamBasicDescription outputFormat;
        getPropertyStream(_outputAudioUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, &outputFormat);
        
        AudioStreamBasicDescription fileFormat = [_currentScheduler clientFormat];

        AudioStreamBasicDescription inputFormat = outputFormat;
        inputFormat.mSampleRate = fileFormat.mSampleRate;

        AudioUnit inputUnit     = 0;
        AudioUnit converterUnit = NULL;

        if (fileFormat.mSampleRate != _outputSampleRate) {
            AudioComponentDescription converterCD = {0};
            converterCD.componentType = kAudioUnitType_FormatConverter;
            converterCD.componentSubType = kAudioUnitSubType_AUConverter;
            converterCD.componentManufacturer = kAudioUnitManufacturer_Apple;
            converterCD.componentFlags = kAudioComponentFlag_SandboxSafe;

            AUNode converterNode = 0;
            CheckError(AUGraphAddNode( _graph, &converterCD,  &converterNode),  "AUGraphAddNode[ Converter ]");

            CheckError(AUGraphNodeInfo(_graph, converterNode,  NULL, &converterUnit),  "AUGraphNodeInfo[ Converter ]");

            UInt32 complexity = [[Preferences sharedInstance] usesMasteringComplexitySRC] ?
                kAudioUnitSampleRateConverterComplexity_Mastering :
                kAudioUnitSampleRateConverterComplexity_Normal;

            setPropertyUInt32(converterUnit, kAudioUnitProperty_SampleRateConverterComplexity, kAudioUnitScope_Global, complexity);
            setPropertyUInt32(converterUnit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, maxFrames);

            setPropertyFloat64(converterUnit, kAudioUnitProperty_SampleRate, kAudioUnitScope_Input,  inputFormat.mSampleRate);
            setPropertyFloat64(converterUnit, kAudioUnitProperty_SampleRate, kAudioUnitScope_Output, _outputSampleRate);

            AudioStreamBasicDescription unitFormat = inputFormat;
            unitFormat.mSampleRate = _outputSampleRate;

            setPropertyStream(converterUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input,  &inputFormat);
            setPropertyStream(converterUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, &unitFormat);

            CheckError(AudioUnitInitialize(converterUnit), "AudioUnitInitialize[ Converter ]");

            // maxFrames will be different when going through a SRC
            maxFramesForInput = getPropertyUInt32(converterUnit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global);

            _converterNode = converterNode;
            _converterAudioUnit = converterUnit;
        }

        // Make input node
        {
            AudioComponentDescription inputCD = {0};
            inputCD.componentType = kAudioUnitType_Mixer;
            inputCD.componentSubType = kAudioUnitSubType_StereoMixer;
            inputCD.componentManufacturer = kAudioUnitManufacturer_Apple;
            inputCD.componentFlags = kAudioComponentFlag_SandboxSafe;

            AUNode inputNode = 0;
            CheckError(AUGraphAddNode(_graph, &inputCD, &inputNode), "AUGraphAddNode[ Input ]");
            CheckError(AUGraphNodeInfo(_graph, inputNode, NULL, &inputUnit),  "AUGraphNodeInfo[ Input ]");

            setPropertyUInt32( inputUnit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, maxFramesForInput);

            setPropertyStream(inputUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input,  &fileFormat);
            setPropertyStream(inputUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, &inputFormat);
            
            CheckError(AudioUnitInitialize(inputUnit), "AudioUnitInitialize[ Input ]");

            _inputNode = inputNode;
            _inputAudioUnit = inputUnit;
        }

        [self _sendHeadUnitToRenderThread:(converterUnit ? converterUnit : inputUnit)];
    });
    
    if (ok) {
        [self _reconnectGraph];
    }

    return ok;
}


- (void) _teardownGraphHead
{
    EmbraceLogMethod();

    if (_inputAudioUnit) {
        CheckError(AudioUnitUninitialize(_inputAudioUnit), "AudioUnitUninitialize[ Input ]");
        CheckError(AUGraphRemoveNode(_graph, _inputNode), "AUGraphRemoveNode[ Input ]" );
        
        _inputAudioUnit = NULL;
        _inputNode = 0;
    }

    if (_converterAudioUnit) {
        CheckError(AudioUnitUninitialize(_converterAudioUnit), "AudioUnitUninitialize[ Converter ]");
        CheckError(AUGraphRemoveNode(_graph, _converterNode), "AUGraphRemoveNode[ Converter ]" );
        
        _converterAudioUnit = NULL;
        _converterNode = 0;
    }
}


- (void) _buildTailGraph
{
    EmbraceLogMethod();

    CheckError(NewAUGraph(&_graph), "NewAUGraph");
	
    AudioComponentDescription limiterCD = {0};
    limiterCD.componentType = kAudioUnitType_Effect;
    limiterCD.componentSubType = kAudioUnitSubType_PeakLimiter;
    limiterCD.componentManufacturer = kAudioUnitManufacturer_Apple;
    limiterCD.componentFlags = kAudioComponentFlag_SandboxSafe;

    AudioComponentDescription mixerCD = {0};
    mixerCD.componentType = kAudioUnitType_Mixer;
    mixerCD.componentSubType = kAudioUnitSubType_StereoMixer;
    mixerCD.componentManufacturer = kAudioUnitManufacturer_Apple;
    mixerCD.componentFlags = kAudioComponentFlag_SandboxSafe;

    AudioComponentDescription outputCD = {0};
    outputCD.componentType = kAudioUnitType_Output;
    outputCD.componentSubType = kAudioUnitSubType_HALOutput;
    outputCD.componentManufacturer = kAudioUnitManufacturer_Apple;
    outputCD.componentFlags = kAudioComponentFlag_SandboxSafe;

    CheckError(AUGraphAddNode(_graph, &limiterCD,    &_limiterNode),    "AUGraphAddNode[ Limiter ]");
    CheckError(AUGraphAddNode(_graph, &mixerCD,      &_mixerNode),      "AUGraphAddNode[ Mixer ]");
    CheckError(AUGraphAddNode(_graph, &outputCD,     &_outputNode),     "AUGraphAddNode[ Output ]");

	CheckError(AUGraphOpen(_graph), "AUGraphOpen");

    CheckError(AUGraphNodeInfo(_graph, _limiterNode, NULL, &_limiterAudioUnit), "AUGraphNodeInfo[ Limiter ]");
	CheckError(AUGraphNodeInfo(_graph, _mixerNode,   NULL, &_mixerAudioUnit),   "AUGraphNodeInfo[ Mixer ]");
	CheckError(AUGraphNodeInfo(_graph, _outputNode,  NULL, &_outputAudioUnit),  "AUGraphNodeInfo[ Output ]");

	CheckError(AUGraphInitialize(_graph), "AUGraphInitialize");

    UInt32 on = 1;
    CheckError(AudioUnitSetProperty(_mixerAudioUnit,
        kAudioUnitProperty_MeteringMode, kAudioUnitScope_Global, 0,
        &on,
        sizeof(on)
    ), "AudioUnitSetProperty[kAudioUnitProperty_MeteringMode]");

    CheckError(AudioUnitSetParameter(_mixerAudioUnit,
        kStereoMixerParam_Volume, kAudioUnitScope_Output, 0,
        _volume, 0
    ), "AudioUnitSetParameter[Volume]");

    CheckError(AudioUnitSetParameter(_mixerAudioUnit,
        kStereoMixerParam_Pan, kAudioUnitScope_Input, 0,
        _stereoBalance, 0
    ), "AudioUnitSetParameter[Volume]");

    _emergencyLimiter = EmergencyLimiterCreate();

    AUGraphAddRenderNotify(_graph, sApplyEmergencyLimiter, _emergencyLimiter);
}


- (void) _iterateGraphNodes:(void (^)(AUNode, NSString *))callback
{
    if (_inputNode)     callback(_inputNode,     @"Input");
    if (_converterNode) callback(_converterNode, @"Converter");
    callback(_limiterNode, @"Limiter");
    
    for (Effect *effect in _effects) {
        NSValue  *key        = [NSValue valueWithNonretainedObject:effect];
        NSNumber *nodeNumber = [_effectToNodeMap objectForKey:key];

        if (!nodeNumber) continue;
        callback([nodeNumber intValue], [[effect type] name]);
    }

    callback(_mixerNode,  @"Mixer");
    callback(_outputNode, @"Output");
}


- (void) _iterateGraphAudioUnits:(void (^)(AudioUnit, NSString *))callback
{
    [self _iterateGraphNodes:^(AUNode node, NSString *unitString) {
        AudioComponentDescription acd;
        AudioUnit audioUnit;

        AUGraphNodeInfo(_graph, node, &acd, &audioUnit);

        callback(audioUnit, unitString);
    }];
}


- (void) _reconnectGraph_attempt
{
    BOOL (^doReconnect)() = ^{
        if (!CheckError(
            AUGraphClearConnections(_graph),
            "AUGraphClearConnections"
        )) {
            return NO;
        }
        
        __block AUNode lastNode = 0;
        __block NSInteger index = 0;
        __block BOOL didConnectAll = YES;

        AURenderCallbackStruct inputCallbackStruct;
        inputCallbackStruct.inputProc        = &sInputRenderCallback;
        inputCallbackStruct.inputProcRefCon  = &_renderUserInfo;

        if (!CheckError(
            AUGraphSetNodeInputCallback(_graph, _limiterNode, 0, &inputCallbackStruct),
            "AUGraphSetNodeInputCallback"
        )) {
            return NO;
        }
        
        [self _iterateGraphNodes:^(AUNode node, NSString *unitString) {
            if (lastNode && (node != _limiterNode)) {
                if (!CheckError(AUGraphConnectNodeInput(_graph, lastNode, 0, node, 0), "AUGraphConnectNodeInput")) {
                    didConnectAll = NO;
                }
            }

            lastNode = node;
            index++;
        }];
        
        if (!didConnectAll) {
            return NO;
        }
        
        if (!CheckError(AUGraphUpdate(_graph, NULL), "AUGraphUpdate")) {
            return NO;
        }
        
        return YES;
    };
    
    if (!doReconnect()) {
        _reconnectGraph_failureCount++;
        
        if (_reconnectGraph_failureCount > 200) {
            EmbraceLog(@"Player", @"doReconnect() still failing after 1 second.  Stopping.");
            [self hardStop];
        }

        EmbraceLog(@"Player", @"doReconnect() failed, calling again in 5ms");

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
            [self _reconnectGraph_attempt];
        });
    }
}


- (void) _reconnectGraph
{
    EmbraceLogMethod();

    _reconnectGraph_failureCount = 0;
    [self _reconnectGraph_attempt];
}


- (void) _reconfigureOutput_attempt
{
    // Properties that we will listen for
    //
    AudioObjectPropertyAddress overloadPropertyAddress   = { kAudioDeviceProcessorOverload,           kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMaster };
    AudioObjectPropertyAddress ioStoppedPropertyAddress  = { kAudioDevicePropertyIOStoppedAbnormally, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMaster };
    AudioObjectPropertyAddress changedPropertyAddress    = { kAudioDevicePropertyDeviceHasChanged,    kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMaster };
    AudioObjectPropertyAddress sampleRatePropertyAddress = { kAudioDevicePropertyNominalSampleRate,   kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMaster };
    AudioObjectPropertyAddress hogModePropertyAddress    = { kAudioDevicePropertyHogMode,             kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMaster };

    // Remove old listeners
    //
    if (_listeningDeviceID) {
        AudioObjectRemovePropertyListener(_listeningDeviceID, &overloadPropertyAddress, sHandleAudioDeviceOverload, &_renderUserInfo);

        AudioObjectRemovePropertyListener(_listeningDeviceID, &ioStoppedPropertyAddress,  sHandleAudioDevicePropertyChanged, (__bridge void *)self);
        AudioObjectRemovePropertyListener(_listeningDeviceID, &changedPropertyAddress,    sHandleAudioDevicePropertyChanged, (__bridge void *)self);
        AudioObjectRemovePropertyListener(_listeningDeviceID, &sampleRatePropertyAddress, sHandleAudioDevicePropertyChanged, (__bridge void *)self);
        AudioObjectRemovePropertyListener(_listeningDeviceID, &hogModePropertyAddress,    sHandleAudioDevicePropertyChanged, (__bridge void *)self);
    
        _listeningDeviceID = 0;
    }

    __block BOOL ok = YES;
    __block PlayerIssue issue = PlayerIssueNone;
    
    void (^raiseIssue)(PlayerIssue) = ^(PlayerIssue i) {
        if (issue == PlayerIssueNone) issue = i;
        ok = NO;
    };
    
    void (^checkError)(OSStatus, NSString *, NSString *) = ^(OSStatus error, NSString *formatString, NSString *unitString) {
        if (ok) {
            const char *errorString = NULL;

            if (error != noErr) {
                errorString = [[NSString stringWithFormat:formatString, unitString] UTF8String];
            }

            if (!CheckError(error, errorString)) {
                raiseIssue(PlayerIssueErrorConfiguringOutputDevice);
            }
        }
    };
   
    if (![_outputDevice isConnected]) {
        raiseIssue(PlayerIssueDeviceMissing);

    } else if ([[_outputDevice controller] isHoggedByAnotherProcess]) {
        raiseIssue(PlayerIssueDeviceHoggedByOtherProcess);
    }

    Boolean isRunning = 0;
    AUGraphIsRunning(_graph, &isRunning);
    
    _hadChangeDuringPlayback = NO;
    
    if (isRunning) AUGraphStop(_graph);
    
    CheckError(AUGraphUninitialize(_graph), "AUGraphUninitialize");

    AUGraphClearConnections(_graph);

    for (AudioDevice *device in [AudioDevice outputAudioDevices]) {
        WrappedAudioDevice *controller = [device controller];
        
        if ([controller isHoggedByMe]) {
            EmbraceLog(@"Player", @"Un-oink");
            [controller releaseHogMode];
        }
    }
    

    WrappedAudioDevice *controller = [_outputDevice controller];
    AudioDeviceID deviceID = [controller objectID];
    
    if (ok) {
        [controller setNominalSampleRate:_outputSampleRate];

        if (!_outputSampleRate || ([controller nominalSampleRate] != _outputSampleRate)) {
            raiseIssue(PlayerIssueErrorConfiguringSampleRate);
        }
    }

    if (ok) {
        [controller setFrameSize:_outputFrames];

        if (!_outputFrames || ([controller frameSize] != _outputFrames)) {
            raiseIssue(PlayerIssueErrorConfiguringFrameSize);
        }
    }

    if (ok) {
        if (_outputHogMode) {
            if ([controller takeHogModeAndResetVolume:_outputResetsVolume]) {
                EmbraceLog(@"Player", @"_outputHogMode is YES, took hog mode.");

            } else {
                EmbraceLog(@"Player", @"-_outputHogMode is YES, but FAILED to take hog mode.");
                raiseIssue(PlayerIssueErrorConfiguringHogMode);
            }

        } else {
            EmbraceLog(@"Player", @"_outputHogMode is NO, not taking hog mode");
        }
    }
    
    if (ok) {
        checkError(AudioUnitSetProperty(_outputAudioUnit,
            kAudioDevicePropertyBufferFrameSize, kAudioUnitScope_Global, 0,
            &_outputFrames,
            sizeof(_outputFrames)
        ), @"AudioUnitSetProperty[ Output, kAudioDevicePropertyBufferFrameSize]", nil);

        checkError(AudioUnitSetProperty(_outputAudioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceID, sizeof(deviceID)
        ), @"AudioUnitSetProperty[ Output, CurrentDevice]", nil);

        // Register for new listeners
        //
        if (deviceID) {
            AudioObjectAddPropertyListener(deviceID, &overloadPropertyAddress, sHandleAudioDeviceOverload, &_renderUserInfo);

            AudioObjectAddPropertyListener(deviceID, &ioStoppedPropertyAddress,  sHandleAudioDevicePropertyChanged, (__bridge void *)self);
            AudioObjectAddPropertyListener(deviceID, &changedPropertyAddress,    sHandleAudioDevicePropertyChanged, (__bridge void *)self);
            AudioObjectAddPropertyListener(deviceID, &sampleRatePropertyAddress, sHandleAudioDevicePropertyChanged, (__bridge void *)self);
            AudioObjectAddPropertyListener(deviceID, &hogModePropertyAddress,    sHandleAudioDevicePropertyChanged, (__bridge void *)self);

            _listeningDeviceID = deviceID;
        }
    }

    UInt32 maxFrames;
    UInt32 maxFramesSize = sizeof(maxFrames);
    
    checkError(AudioUnitGetProperty(
        _outputAudioUnit,
        kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0,
        &maxFrames, &maxFramesSize
    ), @"AudioUnitGetProperty[ Output, MaximumFramesPerSlice ]", nil);
    
    EmbraceLog(@"Player", @"Configuring audio units with %lf sample rate, %ld frame size", _outputSampleRate, (long)maxFrames);
    
    [self _iterateGraphAudioUnits:^(AudioUnit unit, NSString *unitString) {
        Float64 inputSampleRate  = _outputSampleRate;
        Float64 outputSampleRate = _outputSampleRate;

        if (unit == _inputAudioUnit) {
            inputSampleRate = 0;

        } else if (unit == _outputAudioUnit) {
            outputSampleRate = 0;
        }
        
        if (inputSampleRate) {
            checkError(AudioUnitSetProperty(
                unit,
                kAudioUnitProperty_SampleRate, kAudioUnitScope_Input, 0,
                &inputSampleRate, sizeof(inputSampleRate)
            ), @"AudioUnitSetProperty[ %@, SampleRate, Input ]", unitString);
        }

        if (outputSampleRate) {
            checkError(AudioUnitSetProperty(
                unit,
                kAudioUnitProperty_SampleRate, kAudioUnitScope_Output, 0,
                &outputSampleRate, sizeof(outputSampleRate)
            ), @"AudioUnitSetProperty[ %@, SampleRate, Output ]", unitString);
        }

        checkError(AudioUnitSetProperty(
            unit,
            kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0,
            &maxFrames, maxFramesSize
        ), @"AudioUnitSetProperty[ %@, MaximumFramesPerSlice ]", unitString);
    }];

    checkError(AUGraphInitialize(_graph), @"AUGraphInitialize", nil);

    if (ok) {
        [self _reconnectGraph];

        if (isRunning) {
            [self _startGraph];
        }
    }
   
    if (issue != _issue) {
        EmbraceLog(@"Player", @"issue is %ld", (long) issue);

        [self setIssue:issue];

        for (id<PlayerListener> listener in _listeners) {
            [listener player:self didUpdateIssue:issue];
        }
    }

    if (issue == PlayerIssueNone) {
        EmbraceLog(@"Player", @"_reconfigureOutput successful");
    } else {
        [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(_reconfigureOutput_attempt) object:nil];
        [self performSelector:@selector(_reconfigureOutput_attempt) withObject:nil afterDelay:1];
    }
}


- (void) _reconfigureOutput
{
    EmbraceLogMethod();

    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(_reconfigureOutput_attempt) object:nil];
    [self _reconfigureOutput_attempt];
}


- (void) _setupAndStartPlayback
{
    EmbraceLogMethod();
    
    PlayerShouldUseCrashPad = 0;

    Track *track = _currentTrack;
    NSTimeInterval padding = _currentPadding;

    [self _sendHeadUnitToRenderThread:NULL];

    [_currentScheduler stopScheduling:_inputAudioUnit];
    _currentScheduler = nil;

    if ([track isResolvingURLs]) {
        EmbraceLog(@"Player", @"%@ isn't ready due to URL resolution", track);
        [self performSelector:@selector(_setupAndStartPlayback) withObject:nil afterDelay:0.1];
        return;
    }

    if (![track didAnalyzeLoudness] && ![track trackError]) {
        EmbraceLog(@"Player", @"%@ isn't ready, calling startPriorityAnalysis", track);

        [track startPriorityAnalysis];
        [self performSelector:@selector(_setupAndStartPlayback) withObject:nil afterDelay:0.1];
        return;
    }

    NSURL *fileURL = [track internalURL];
    if (!fileURL) {
        EmbraceLog(@"Player", @"No URL for %@!", track);
        [self hardStop];
        return;
    }

    PlayerShouldUseCrashPad = 0;

    if ([self _buildGraphHeadAndTrackScheduler]) {
        _setupAndStartPlayback_failureCount = 0;

    } else {
        _setupAndStartPlayback_failureCount++;

        EmbraceLog(@"Player", @"Failure %ld during _buildGraphHeadAndTrackScheduler", (long)_setupAndStartPlayback_failureCount);
        
        if (![track trackError] && (_setupAndStartPlayback_failureCount < 20)) {
            [self performSelector:@selector(_setupAndStartPlayback) withObject:nil afterDelay:0.1];
        } else {
            [self hardStop];
        }
    }

    [self _updateLoudnessAndPreAmp];

    if (padding > 0 && _outputSampleRate > 0) {
        padding += _outputSampleRate ? (_outputFrames / _outputSampleRate) : 0;
    }

    EmbraceLog(@"Player", @"Calling startSchedulingWithAudioUnit. audioUnit=%p, padding=%lf", _inputAudioUnit, padding);
        
    BOOL didScheldule = [_currentScheduler startSchedulingWithAudioUnit:_inputAudioUnit paddingInSeconds:padding];
    if (!didScheldule) {
        EmbraceLog(@"Player", @"startSchedulingWithAudioUnit failed: %ld", (long)[_currentScheduler audioFileError]);
        [_currentTrack setTrackError:(TrackError)[_currentScheduler audioFileError]];
        return;
    }

    EmergencyLimiterSetSampleRate(_emergencyLimiter, _outputSampleRate);

    [self _sendDistributedNotification];

    EmbraceLog(@"Player", @"setup complete, starting graph");
    [self _startGraph];
}


- (void) _startGraph
{
    EmbraceLogMethod();

    Boolean isRunning = 0;
    AUGraphIsRunning(_graph, &isRunning);

    if (!isRunning) {
        CheckError(AUGraphStart(_graph), "AUGraphStart");
    }

    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(_stopGraph) object:nil];
}


- (void) _stopGraph
{
    EmbraceLogMethod();
    CheckError(AUGraphStop(_graph), "AUGraphStop");
}


#pragma mark - Public Methods

- (AudioUnit) audioUnitForEffect:(Effect *)effect
{
    NSValue *key = [NSValue valueWithNonretainedObject:effect];
    AUNode node = [[_effectToNodeMap objectForKey:key] intValue];

    AudioUnit audioUnit;
    AudioComponentDescription acd;

    CheckError(AUGraphNodeInfo(_graph, node, &acd, &audioUnit), "AUGraphNodeInfo");

    return audioUnit;
}


- (void) saveEffectState
{
    NSMutableArray *effectsStateArray = [NSMutableArray arrayWithCapacity:[_effects count]];
    
    for (Effect *effect in _effects) {
        NSDictionary *dictionary = [effect stateDictionary];
        if (dictionary) [effectsStateArray addObject:dictionary];
    }

    [[NSUserDefaults standardUserDefaults] setObject:effectsStateArray forKey:sEffectsKey];
}


- (void) playNextTrack
{
    EmbraceLog(@"Player", @"-playNextTrack");

    Track *nextTrack = nil;
    NSTimeInterval padding = 0;

    if (![_currentTrack stopsAfterPlaying]) {
        [_trackProvider player:self getNextTrack:&nextTrack getPadding:&padding];
    }
    
    if ([_currentTrack ignoresAutoGap]) {
        padding = 0;
    }
    
    // Padding should never be over 15.  If it is, "Auto Stop" is on.
    if (padding >= 60) {
        nextTrack = nil;
    }
    
    if (nextTrack) {
        if (_currentTrack) {
            for (id<PlayerListener> listener in _listeners) {
                [listener player:self didFinishTrack:_currentTrack];
            }
        }
        [self setCurrentTrack:nextTrack];
        _currentPadding = padding;

        [self _setupAndStartPlayback];

    } else {
        EmbraceLog(@"Player", @"Calling -hardStop due to nil nextTrack");
        [self hardStop];
    }
}


- (void) play
{
    EmbraceLog(@"Player", @"-play");

    if (_currentTrack) return;

    [self _reconfigureOutput];

    [self playNextTrack];
    
    if (_currentTrack) {
        _tickTimer = [NSTimer timerWithTimeInterval:(1.0/30.0) target:self selector:@selector(_tick:) userInfo:nil repeats:YES];
        [_tickTimer setTolerance:(1.0/60.0)];

        [[NSRunLoop mainRunLoop] addTimer:_tickTimer forMode:NSRunLoopCommonModes];
        [[NSRunLoop mainRunLoop] addTimer:_tickTimer forMode:NSEventTrackingRunLoopMode];

        for (id<PlayerListener> listener in _listeners) {
            [listener player:self didUpdatePlaying:YES];
        }
        
        [self _takePowerAssertions];
    }
}


- (void) hardSkip
{
    EmbraceLog(@"Player", @"-hardSkip");

    if (!_currentTrack) return;

    Track *nextTrack = nil;
    NSTimeInterval padding = 0;

    [_currentTrack setTrackStatus:TrackStatusPlayed];
    [_currentTrack setStopsAfterPlaying:NO];
    [_currentTrack setIgnoresAutoGap:NO];

    [_trackProvider player:self getNextTrack:&nextTrack getPadding:&padding];
    
    if (nextTrack) {
        for (id<PlayerListener> listener in _listeners) {
            [listener player:self didFinishTrack:_currentTrack];
        }
        [self setCurrentTrack:nextTrack];
        _currentPadding = 0;

        [self _setupAndStartPlayback];

    } else {
        EmbraceLog(@"Player", @"Calling -hardStop due to nil nextTrack");
        [self hardStop];
    }
}


- (void) hardStop
{
    EmbraceLog(@"Player", @"-hardStop");

    if (!_currentTrack) return;

    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(_setupAndStartPlayback) object:nil];
    _setupAndStartPlayback_failureCount = 0;

    if ([_currentTrack trackStatus] == TrackStatusPreparing) {
        EmbraceLog(@"Player", @"Remarking %@ as queued due to status of preparing", _currentTrack);
        [_currentTrack setTrackStatus:TrackStatusQueued];

    } else if ([self _shouldRemarkAsQueued]) {
        EmbraceLog(@"Player", @"Remarking %@ as queued due to _timeElapsed of %g", _currentTrack, _timeElapsed);
        [_currentTrack setTrackStatus:TrackStatusQueued];

    } else {
        EmbraceLog(@"Player", @"Marking %@ as played", _currentTrack);

        [_currentTrack setTrackStatus:TrackStatusPlayed];
        [_currentTrack setStopsAfterPlaying:NO];
        [_currentTrack setIgnoresAutoGap:NO];
    }

    for (id<PlayerListener> listener in _listeners) {
        [listener player:self didFinishTrack:_currentTrack];
    }
    [self setCurrentTrack:nil];

    if (_tickTimer) {
        [_tickTimer invalidate];
        _tickTimer = nil;
    }

    Boolean isRunning = 0;
    CheckError(
        AUGraphIsRunning(_graph, &isRunning),
        "AUGraphIsRunning"
    );

    if (isRunning) {
        [self _sendHeadUnitToRenderThread:NULL];
        [self performSelector:@selector(_stopGraph) withObject:nil afterDelay:30];
    }

    [self _iterateGraphAudioUnits:^(AudioUnit unit, NSString *unitString) {
        OSStatus err = AudioUnitReset(unit, kAudioUnitScope_Global, 0);
        
        if (err != noErr) {
            CheckError(err, [[NSString stringWithFormat:@"%@, AudioUnitReset", unitString] UTF8String]);
        }
    }];

    [_currentScheduler stopScheduling:_inputAudioUnit];
    _currentScheduler = nil;
    
    _leftAveragePower = _rightAveragePower = _leftPeakPower = _rightPeakPower = -INFINITY;
    _limiterActive = NO;

    [self _teardownGraphHead];
    
    for (id<PlayerListener> listener in _listeners) {
        [listener player:self didUpdatePlaying:NO];
    }

    [self _sendDistributedNotification];
    [self _clearPowerAssertions];
}


- (BOOL) _shouldRemarkAsQueued
{
    NSTimeInterval playDuration = [_currentTrack playDuration];

    if (playDuration > 10.0) {
        return _timeElapsed < 5.0;
    } else {
        return NO;
    }
}


- (void) updateOutputDevice: (AudioDevice *) outputDevice
                 sampleRate: (double) sampleRate
                     frames: (UInt32) frames
                    hogMode: (BOOL) hogMode
               resetsVolume: (BOOL) resetsVolume
{
    EmbraceLog(@"Player", @"updateOutputDevice:%@ sampleRate:%lf frames:%lu hogMode:%ld", self, sampleRate, (unsigned long)frames, (long)hogMode);

    if (_outputDevice       != outputDevice ||
        _outputSampleRate   != sampleRate   ||
        _outputFrames       != frames       ||
        _outputHogMode      != hogMode      ||
        _outputResetsVolume != resetsVolume)
    {
        if (_outputDevice != outputDevice) {
            [_outputDevice removeObserver:self forKeyPath:@"connected"];
            
            _outputDevice = outputDevice;
            [_outputDevice addObserver:self forKeyPath:@"connected" options:0 context:NULL];
        }

        _outputSampleRate   = sampleRate;
        _outputFrames       = frames;
        _outputHogMode      = hogMode;
        _outputResetsVolume = resetsVolume;

        [self _reconfigureOutput];
    }
}


- (void) addListener:(id<PlayerListener>)listener
{
    if (!_listeners) _listeners = [NSHashTable weakObjectsHashTable];
    if (listener) [_listeners addObject:listener];
}


- (void) removeListener:(id<PlayerListener>)listener
{
    [_listeners removeObject:listener];
}


#pragma mark - Accessors

- (void) setCurrentTrack:(Track *)currentTrack
{
    if (_currentTrack != currentTrack) {
        _currentTrack = currentTrack;
        [_currentTrack setTrackStatus:TrackStatusPreparing];

        _timeElapsed = 0;
    }
}


- (void) setPreAmpLevel:(double)preAmpLevel
{
    if (_preAmpLevel != preAmpLevel) {
        _preAmpLevel = preAmpLevel;
        [[NSUserDefaults standardUserDefaults] setObject:@(preAmpLevel) forKey:sPreAmpKey];
        [self _updateLoudnessAndPreAmp];
    }
}


- (void) setMatchLoudnessLevel:(double)matchLoudnessLevel
{
    if (_matchLoudnessLevel != matchLoudnessLevel) {
        _matchLoudnessLevel = matchLoudnessLevel;
        [[NSUserDefaults standardUserDefaults] setObject:@(matchLoudnessLevel) forKey:sMatchLoudnessKey];
        [self _updateLoudnessAndPreAmp];
    }
}


- (void) setStereoLevel:(float)stereoLevel
{
    if (_stereoLevel != stereoLevel) {
        _stereoLevel = stereoLevel;
        [[NSUserDefaults standardUserDefaults] setObject:@(stereoLevel) forKey:sStereoLevelKey];

        _renderUserInfo.stereoLevel = stereoLevel;
    }
}


- (void) setStereoBalance:(float)stereoBalance
{
    if (stereoBalance < -1.0f) stereoBalance = -1.0f;
    if (stereoBalance >  1.0f) stereoBalance =  1.0f;

    if (_stereoBalance != stereoBalance) {
        _stereoBalance = stereoBalance;
        [[NSUserDefaults standardUserDefaults] setObject:@(stereoBalance) forKey:sStereoBalanceKey];

        Float32 value = _stereoBalance;

        CheckError(AudioUnitSetParameter(_mixerAudioUnit,
            kStereoMixerParam_Pan, kAudioUnitScope_Input, 0,
            value, 0
        ), "AudioUnitSetParameter[Volume]");
    }
}


- (void) setEffects:(NSArray *)effects
{
    if (_effects != effects) {
        _effects = effects;

        [self _updateEffects:effects];
        [self saveEffectState];
    }
}


- (void) setVolume:(double)volume
{
    if (volume < 0) volume = 0;
    if (volume > sMaxVolume) volume = sMaxVolume;

    if (_volume != volume) {
        _volume = volume;

        [[NSUserDefaults standardUserDefaults] setDouble:_volume forKey:sVolumeKey];
        
        CheckError(AudioUnitSetParameter(_mixerAudioUnit,
            kStereoMixerParam_Volume, kAudioUnitScope_Output, 0,
            volume, 0
        ), "AudioUnitSetParameter[Volume]");
        
        for (id<PlayerListener> listener in _listeners) {
            [listener player:self didUpdateVolume:_volume];
        }
    }
}


- (BOOL) isPlaying
{
    return _currentTrack != nil;
}


@end


