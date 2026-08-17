// (c) 2014-2024 Ricci Adams
// MIT License (or) 1-clause BSD License

#import <Foundation/Foundation.h>

@class HugAudioDevice;

typedef NS_ENUM(NSInteger, KeySignatureDisplayMode) {
    KeySignatureDisplayModeRaw,
    KeySignatureDisplayModeTraditional,
    KeySignatureDisplayModeOpenKeyNotation
};


typedef NS_OPTIONS(NSUInteger, DuplicateStatusMode) {
    DuplicateStatusModeSameFile     = 1,
    DuplicateStatusModeSameTitle    = 2,
    DuplicateStatusModeSimilarTitle = 4
};


typedef NS_OPTIONS(NSUInteger, ThemeType) {
    ThemeTypeSystem = 0,
    ThemeTypeLight  = 1,
    ThemeTypeDark   = 2
};

typedef NS_ENUM(NSInteger, TrackViewAttribute) {
    TrackViewAttributeArtist          = 0,
    TrackViewAttributeBeatsPerMinute  = 1,
    TrackViewAttributeComments        = 2,
    TrackViewAttributeGrouping        = 3,
    TrackViewAttributeKeySignature    = 4,
    TrackViewAttributeRawKeySignature = 5,
    TrackViewAttributeEnergyLevel     = 6,
    TrackViewAttributeGenre           = 7,
    TrackViewAttributeDuplicateStatus = 8,
    TrackViewAttributePlayingStatus   = 9,
    TrackViewAttributeLabelStripes    = 10,
    TrackViewAttributeLabelDots       = 11,
    TrackViewAttributeYear            = 12,
    TrackViewAttributeAlbumArtist     = 13,
    TrackViewAttributeStatusShape     = 14,
};

extern NSString * const PreferencesDidChangeNotification;


@interface Preferences : NSObject

+ (id) sharedInstance;

@property (nonatomic, readonly) NSString *latestBuildString;

@property (nonatomic) BOOL usesLargerText;
@property (nonatomic) NSInteger numberOfLayoutLines;
@property (nonatomic) BOOL shortensPlayedTracks;

@property (nonatomic) ThemeType themeType;

- (void) setTrackViewAttribute:(TrackViewAttribute)attribute selected:(BOOL)selected;
- (BOOL) isTrackViewAttributeSelected:(TrackViewAttribute)attribute;

@property (nonatomic) BOOL showsAlbumArtist;
@property (nonatomic) BOOL showsArtist;
@property (nonatomic) BOOL showsBPM;
@property (nonatomic) BOOL showsComments;
@property (nonatomic) BOOL showsDuplicateStatus;
@property (nonatomic) BOOL showsGenre;
@property (nonatomic) BOOL showsGrouping;
@property (nonatomic) BOOL showsKeySignature;
@property (nonatomic) BOOL showsEnergyLevel;
@property (nonatomic) BOOL showsPlayingStatus;
@property (nonatomic) BOOL showsStatusShape;
@property (nonatomic) BOOL showsLabelDots;
@property (nonatomic) BOOL showsLabelStripes;
@property (nonatomic) BOOL showsYear;

@property (nonatomic) BOOL floatsOnTop;

@property (nonatomic) NSString *scriptHandlerName;
@property (nonatomic) BOOL allowsAllEffects;
@property (nonatomic) BOOL allowsPlaybackShortcuts;

@property (nonatomic) KeySignatureDisplayMode keySignatureDisplayMode;
@property (nonatomic) DuplicateStatusMode duplicateStatusMode;

@property (nonatomic) HugAudioDevice *mainOutputAudioDevice;
@property (nonatomic) double          mainOutputSampleRate;
@property (nonatomic) UInt32          mainOutputFrames;
@property (nonatomic) BOOL            mainOutputUsesHogMode;
@property (nonatomic) BOOL            mainOutputResetsVolume;

@end
