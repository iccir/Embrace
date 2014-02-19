//
//  Preferences.h
//  Embrace
//
//  Created by Ricci Adams on 2014-01-13.
//  Copyright (c) 2014 Ricci Adams. All rights reserved.
//

#import <Foundation/Foundation.h>

@class AudioDevice;

typedef NS_ENUM(NSInteger, TonalityDisplayMode) {
    TonalityDisplayModeNone,
    TonalityDisplayModeTraditional,
    TonalityDisplayModeCamelot
};

extern NSString * const PreferencesDidChangeNotification;


@interface Preferences : NSObject

+ (id) sharedInstance;

@property (nonatomic) TonalityDisplayMode tonalityDisplayMode;
@property (nonatomic) BOOL showsBPM;

@property (nonatomic) AudioDevice *mainOutputAudioDevice;
@property (nonatomic) double       mainOutputSampleRate;
@property (nonatomic) UInt32       mainOutputFrames;
@property (nonatomic) BOOL         mainOutputUsesHogMode;

@end
