//
//  Scheduler.m
//  Embrace
//
//  Created by Ricci Adams on 2014-02-11.
//  Copyright (c) 2014 Ricci Adams. All rights reserved.
//

#import "TrackScheduler.h"
#import "Track.h"

@interface TrackScheduler ()
@property (atomic) NSInteger totalFrames;
@property (atomic) NSInteger availableFrames;
@end

@implementation TrackScheduler {
    UInt8    **_buffers;
    NSUInteger _bufferCount;
    
    ExtAudioFileRef _audioFile;
    AudioStreamBasicDescription _clientFormat;

    ScheduledAudioSlice *_slice;
}


- (id) initWithTrack:(Track *)track
{
    if ((self = [super init])) {
        _track = track;
        
        if (![self _setupAudioFile]) {
            self = nil;
            return nil;
        }
        
        [self _setupBuffers];
    }
    
    return self;
}


- (void) dealloc
{
    [self _cleanupAudioFile];
    [self _cleanupBuffers];
}


- (void) _cleanupAudioFile
{
    if (_audioFile) {
        ExtAudioFileDispose(_audioFile);
    }

    [[_track fileURL] stopAccessingSecurityScopedResource];
}


- (BOOL) _setupAudioFile
{
    NSURL *url = [_track fileURL];

    AudioStreamBasicDescription fileFormat = {0};
    UInt32 fileFormatSize = sizeof(fileFormat);

    SInt64 fileLengthFrames = 0;
    UInt32 fileLengthFramesSize = sizeof(fileLengthFrames);

    [url startAccessingSecurityScopedResource];

    if (!CheckError(
        ExtAudioFileOpenURL((__bridge CFURLRef)url, &_audioFile),
        "ExtAudioFileOpenURL"
    )) {
        return NO;
    }

    if (!CheckError(
        ExtAudioFileGetProperty(_audioFile, kExtAudioFileProperty_FileDataFormat, &fileFormatSize, &fileFormat),
        "ExtAudioFileGetProperty[ FileDataFormat ]"
    )) {
        return NO;
    }

    _clientFormat = GetPCMStreamBasicDescription(fileFormat.mSampleRate, fileFormat.mChannelsPerFrame, NO);
    _sampleRate   = fileFormat.mSampleRate;

    if (!CheckError(
        ExtAudioFileSetProperty(_audioFile, kExtAudioFileProperty_ClientDataFormat, sizeof(_clientFormat), &_clientFormat),
        "ExtAudioFileSetProperty[ ClientDataFormat ]"
    )) {
        return NO;
    }
    
    if (!CheckError(
        ExtAudioFileGetProperty(_audioFile, kExtAudioFileProperty_FileLengthFrames, &fileLengthFramesSize, &fileLengthFrames),
        "ExtAudioFileGetProperty[ FileLengthFrames ]"
    )) {
        return NO;
    }

    // Determine start and stop time in frames
    {
        NSInteger totalFrames = fileLengthFrames;
        
        NSInteger startFrame  = [_track startTime] * _clientFormat.mSampleRate;
        if (startFrame < 0) startFrame = 0;
        if (startFrame > totalFrames) startFrame = totalFrames;

        if ([_track stopTime]) {
            NSInteger stopFrame  = [_track stopTime] * _clientFormat.mSampleRate;
            if (stopFrame < 0) stopFrame = 0;
            if (stopFrame > totalFrames) stopFrame = totalFrames;

            totalFrames = stopFrame;
        }

        if (startFrame) {
            ExtAudioFileSeek(_audioFile, startFrame);
        }
        
        fileLengthFrames = totalFrames;
    }
    
    [self setTotalFrames:fileLengthFrames];
    
    return YES;
}


- (void) _setupBuffers
{
    _bufferCount = _clientFormat.mChannelsPerFrame;

    UInt32 totalFrames = (UInt32)[self totalFrames];
    UInt32 totalBytes  = totalFrames * _clientFormat.mBytesPerFrame;

    _buffers = malloc(sizeof(UInt8 *) * _bufferCount);

    _slice = calloc(1, sizeof(ScheduledAudioSlice));
    _slice->mBufferList = malloc(sizeof(AudioBufferList) * _bufferCount);
    _slice->mNumberFrames = (UInt32)totalFrames;
    
    for (NSInteger i = 0; i < _bufferCount; i++) {
        _buffers[i] = malloc(totalBytes);

        AudioBuffer *b = &_slice->mBufferList->mBuffers[i];
        b->mNumberChannels = 1;
        b->mDataByteSize = (UInt32)totalBytes;
        b->mData = _buffers[i];
    }
}


- (void) _cleanupBuffers
{
    for (NSInteger i = 0; i < _bufferCount; i++) {
        free(_buffers[i]);
        _buffers[i] = NULL;
    }
    
    free(_slice);
    _slice = NULL;

    free(_buffers);
    _buffers = NULL;
}


- (void) _readDataInBackground
{
    NSInteger framesRemaining = [self totalFrames];
    NSInteger bytesRemaining = framesRemaining * _clientFormat.mBytesPerFrame;

    NSInteger bytesRead = 0;
    NSInteger framesAvailable = 0;

    AudioBufferList *fillBufferList = alloca(sizeof(AudioBufferList) * _bufferCount);
    fillBufferList->mNumberBuffers = (UInt32)_bufferCount;
    
    OSStatus err = noErr;
    
    while (1 && (err == noErr)) {
        UInt32 maxFrames  = 32768;
        UInt32 frameCount = (UInt32)framesRemaining;
        if (frameCount > maxFrames) frameCount = maxFrames;

        for (NSInteger i = 0; i < _bufferCount; i++) {
            fillBufferList->mBuffers[i].mNumberChannels = 1;
            fillBufferList->mBuffers[i].mDataByteSize = (UInt32)bytesRemaining;
            fillBufferList->mBuffers[i].mData = _buffers[i] + bytesRead;
        }

        err = ExtAudioFileRead(_audioFile, &frameCount, fillBufferList);

        framesAvailable += frameCount;
        [self setAvailableFrames:framesAvailable];
        
        framesRemaining -= frameCount;
    
        bytesRead       += frameCount * _clientFormat.mBytesPerFrame;
        bytesRemaining  -= frameCount * _clientFormat.mBytesPerFrame;
        
        if (framesRemaining == 0) {
            break;
        }
    }
}


#pragma mark - Public Methods

- (void) startSchedulingWithAudioUnit:(AudioUnit)audioUnit timeStamp:(AudioTimeStamp)timeStamp
{
    dispatch_async(dispatch_get_global_queue(0, 0), ^{
        [self _readDataInBackground];
        
        dispatch_async(dispatch_get_main_queue(), ^{
            [self _cleanupAudioFile];
        });
    });

    while (![self totalFrames]) {
        usleep(1);
    }
    
    NSInteger primeAmount = (_clientFormat.mSampleRate * 10);
    NSInteger totalFrames = [self totalFrames];
    
    if (totalFrames < primeAmount) primeAmount = totalFrames;

    while ([self availableFrames] < primeAmount) {
        usleep(1);
    }

    _slice->mTimeStamp = timeStamp;

    AudioUnitReset(audioUnit, kAudioUnitScope_Global, 0);
    CheckError(
        AudioUnitSetProperty(audioUnit, kAudioUnitProperty_ScheduleAudioSlice, kAudioUnitScope_Global, 0, _slice, sizeof(ScheduledAudioSlice)),
        "AudioUnitSetProperty[ ScheduleAudioSlice ]"
    );
};


- (void) stopScheduling:(AudioUnit)audioUnit
{
    AudioUnitReset(audioUnit, kAudioUnitScope_Global, 0);
}


@end
