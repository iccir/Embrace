// (c) 2014-2024 Ricci Adams
// MIT License (or) 1-clause BSD License

#import "Preferences.h"
#import "HugAudioDevice.h"
#import "EffectAdditions.h"

NSString * const PreferencesDidChangeNotification = @"PreferencesDidChange";

static NSString * const sDeviceDictionaryUIDKey  = @"DeviceUID";
static NSString * const sDeviceDictionaryNameKey = @"Name";

static NSDictionary *sGetDefaultValues()
{
    static NSDictionary *sDefaultValues = nil;
    static dispatch_once_t onceToken;

    dispatch_once(&onceToken, ^{

    sDefaultValues = @{
        @"numberOfLayoutLines":  @2,
        @"usesLargerText":       @NO,
        @"shortensPlayedTracks": @NO,
    
        @"floatsOnTop":          @NO,
        
        @"themeType": @( ThemeTypeSystem ),

        @"showsAlbumArtist":     @NO,
        @"showsArtist":          @YES,
        @"showsBPM":             @YES,
        @"showsComments":        @NO,
        @"showsGrouping":        @NO,
        @"showsKeySignature":    @NO,
        @"showsEnergyLevel":     @NO,
        @"showsGenre":           @NO,
        @"showsDuplicateStatus": @YES,
        @"showsPlayingStatus":   @YES,
        @"showsStatusShape":     @NO,
        @"showsLabelDots":       @NO,
        @"showsLabelStripes":    @YES,
        @"showsYear":            @NO,

        @"scriptHandlerName":       @"",
        @"allowsAllEffects":        @NO,
        @"allowsPlaybackShortcuts": @NO,

        @"keySignatureDisplayMode": @( KeySignatureDisplayModeRaw ),
        @"duplicateStatusMode":     @( DuplicateStatusModeSameFile ),
        
        @"mainOutputAudioDevice":  [HugAudioDevice placeholderDevice],
        @"mainOutputSampleRate":   @(44100),
        @"mainOutputFrames":       @(2048),
        @"mainOutputUsesHogMode":  @(NO),
        @"mainOutputResetsVolume": @(YES)
    };
    
    });
    
    return sDefaultValues;
}


static void sSetDefaultObject(id dictionary, NSString *key, id valueToSave, id defaultValue)
{
    void (^saveObject)(NSObject *, NSString *) = ^(NSObject *o, NSString *k) {
        if (o) {
            [dictionary setObject:o forKey:k];
        } else {
            [dictionary removeObjectForKey:k];
        }
    };

    if ([defaultValue isKindOfClass:[NSNumber class]]) {
        saveObject(valueToSave, key);

    } else if ([defaultValue isKindOfClass:[HugAudioDevice class]]) {
        NSString *deviceUID = [valueToSave deviceUID];
        NSString *name      = [valueToSave name];
        
        if (deviceUID && name) {
            saveObject(@{
                sDeviceDictionaryUIDKey:deviceUID, 
                sDeviceDictionaryNameKey: name
            }, key);
        }

    } else if ([defaultValue isKindOfClass:[NSData class]]) {
        saveObject(valueToSave, key);

    } else if ([defaultValue isKindOfClass:[NSString class]]) {
        saveObject(valueToSave, key);
    }
}


static void sRegisterDefaults()
{
    NSMutableDictionary *defaults = [NSMutableDictionary dictionary];

    NSDictionary *defaultValuesDictionary = sGetDefaultValues();

    for (NSString *key in defaultValuesDictionary) {
        id value = [defaultValuesDictionary objectForKey:key];
        sSetDefaultObject(defaults, key, value, value);
    }

    // Default to a single 10-band EQ
    [defaults setObject:@[ @{ @"name": EmbraceMappedEffect10BandEQ } ] forKey:@"effects"];

    [[NSUserDefaults standardUserDefaults] registerDefaults:defaults];
}


@implementation Preferences


+ (id) sharedInstance
{
    static Preferences *sSharedInstance = nil;
    static dispatch_once_t onceToken;

    dispatch_once(&onceToken, ^{
        sRegisterDefaults();
        sSharedInstance = [[Preferences alloc] init];
    });
    
    return sSharedInstance;
}


- (id) init
{
    if ((self = [super init])) {
        [self _load];
        
        for (NSString *key in sGetDefaultValues()) {
            [self addObserver:self forKeyPath:key options:0 context:NULL];
        }
        
        NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
        NSString *currentBuildString = GetAppBuildString();
        NSString *latestBuildString  = [defaults objectForKey:@"latest-build"];
        
        if (GetCombinedBuildNumber(currentBuildString) > GetCombinedBuildNumber(latestBuildString)) {
            [defaults setObject:currentBuildString forKey:@"latest-build"];
            latestBuildString = currentBuildString;
        }

        [defaults setObject:currentBuildString forKey:@"last-build"];

        _latestBuildString = latestBuildString;
    }

    return self;
}


- (void) _load
{
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];

    if ([defaults integerForKey:@"mainOutputSampleRate"] == 0) {
        [defaults setInteger:44100 forKey:@"mainOutputSampleRate"];
    }
    
    if ([defaults integerForKey:@"mainOutputFrames"] == 0) {
        [defaults setInteger:2048 forKey:@"mainOutputFrames"];
    }

    NSDictionary *defaultValuesDictionary = sGetDefaultValues();
    for (NSString *key in defaultValuesDictionary) {
        id defaultValue = [defaultValuesDictionary objectForKey:key];

        if ([defaultValue isKindOfClass:[NSNumber class]]) {
            [self setValue:@([defaults integerForKey:key]) forKey:key];

        } else if ([defaultValue isKindOfClass:[NSData class]]) {
            [self setValue:[defaults objectForKey:key] forKey:key];

        } else if ([defaultValue isKindOfClass:[NSString class]]) {
            [self setValue:[defaults objectForKey:key] forKey:key];

        } else if ([defaultValue isKindOfClass:[HugAudioDevice class]]) {
            NSDictionary *dictionary = [defaults objectForKey:key];

            if ([dictionary isKindOfClass:[NSDictionary class]]) {
                NSString *name      = [dictionary objectForKey:sDeviceDictionaryNameKey];
                NSString *deviceUID = [dictionary objectForKey:sDeviceDictionaryUIDKey];
                
                if (name && deviceUID) {
                    HugAudioDevice *device = [HugAudioDevice archivedDeviceWithDeviceUID:deviceUID name:name];
                    if (device) [self setValue:device forKey:key];
                }

            } else {
                HugAudioDevice *device = [HugAudioDevice bestDefaultDevice];
                if (device) [self setValue:device forKey:key];
            }
        }
    }
}


- (NSString *) _keyForTrackViewAttribute:(TrackViewAttribute)attribute
{
    if (attribute == TrackViewAttributeAlbumArtist) {
        return @"showsAlbumArtist";

    } else if (attribute == TrackViewAttributeArtist) {
        return @"showsArtist";

    } else if (attribute == TrackViewAttributeBeatsPerMinute) {
        return @"showsBPM";
        
    } else if (attribute == TrackViewAttributeComments) {
        return @"showsComments";

    } else if (attribute == TrackViewAttributeGrouping) {
        return @"showsGrouping";

    } else if (attribute == TrackViewAttributeKeySignature) {
        return @"showsKeySignature";
    
    } else if (attribute == TrackViewAttributeEnergyLevel) {
        return @"showsEnergyLevel";

    } else if (attribute == TrackViewAttributeGenre) {
        return @"showsGenre";

    } else if (attribute == TrackViewAttributeDuplicateStatus) {
        return @"showsDuplicateStatus";

    } else if (attribute == TrackViewAttributePlayingStatus) {
        return @"showsPlayingStatus";

    } else if (attribute == TrackViewAttributeStatusShape) {
        return @"showsStatusShape";

    } else if (attribute == TrackViewAttributeLabelDots) {
        return @"showsLabelDots";

    } else if (attribute == TrackViewAttributeLabelStripes) {
        return @"showsLabelStripes";

    } else if (attribute == TrackViewAttributeYear) {
        return @"showsYear";
    }

    return nil;
}


- (void) _save
{
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    
    NSDictionary *defaultValuesDictionary = sGetDefaultValues();
    for (NSString *key in defaultValuesDictionary) {
        id defaultValue = [defaultValuesDictionary objectForKey:key];
        id selfValue    = [self valueForKey:key];
        
        sSetDefaultObject(defaults, key, selfValue, defaultValue);
    }
}


- (void) restoreDefaultColors
{
    NSDictionary *defaultValuesDictionary = sGetDefaultValues();

    for (NSString *key in defaultValuesDictionary) {
        id defaultValue = [defaultValuesDictionary objectForKey:key];

        if ([defaultValue isKindOfClass:[NSColor class]]) {
            [self setValue:defaultValue forKey:key];
        }
    }
}


- (void) observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context
{
    if (object == self) {
        [[NSNotificationCenter defaultCenter] postNotificationName:PreferencesDidChangeNotification object:self];
        [self _save];
    }
}


- (void) setTrackViewAttribute:(TrackViewAttribute)attribute selected:(BOOL)selected
{
    NSString *key = [self _keyForTrackViewAttribute:attribute];
    if (!key) return;
    
    [self setValue:@(selected) forKey:key];
}


- (BOOL) isTrackViewAttributeSelected:(TrackViewAttribute)attribute
{
    NSString *key = [self _keyForTrackViewAttribute:attribute];
    if (!key) return NO;

    return [[self valueForKey:key] boolValue];
}


@end
