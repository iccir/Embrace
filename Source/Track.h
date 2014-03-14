//
//  Track.h
//  Embrace
//
//  Created by Ricci Adams on 2014-01-03.
//  Copyright (c) 2014 Ricci Adams. All rights reserved.
//

#import <Foundation/Foundation.h>
#import "AudioFile.h"

extern NSString * const TrackDidModifyPlayDurationNotificationName;

@class TrackAnalyzer;

typedef NS_ENUM(NSInteger, TrackStatus) {
    TrackStatusQueued,  // Track is queued
    TrackStatusPlaying, // Track is active
    TrackStatusPlayed   // Track was played
};


typedef NS_ENUM(NSInteger, TrackError) {
    TrackErrorNone             = 0,

    TrackErrorProtectedContent = AudioFileErrorProtectedContent,
    TrackErrorConversionFailed = AudioFileErrorConversionFailed,
    TrackErrorOpenFailed       = AudioFileErrorOpenFailed,
    TrackErrorReadTooSlow      = AudioFileErrorReadTooSlow
};

@interface Track : NSObject

+ (void) clearPersistedState;

+ (instancetype) trackWithUUID:(NSUUID *)uuid;

+ (instancetype) trackWithFileURL:(NSURL *)url;

- (void) cancelLoad;

- (void) clearAndCleanup;
- (void) startPriorityAnalysis;

// estimatedEndTime may either be a relative date (when not playing a track)
// or an absolute date (when playing a track).  estimatedEndTimeDate returns
// the correct value
//
- (NSDate *) estimatedEndTimeDate;


@property (nonatomic, readonly) NSURL *externalURL;
@property (nonatomic, readonly) NSURL *internalURL;
@property (nonatomic, readonly) NSUUID *UUID;


// Read/Write
@property (nonatomic) TrackStatus trackStatus;
@property (nonatomic) BOOL pausesAfterPlaying;

@property (nonatomic) NSTimeInterval estimatedEndTime;
@property (nonatomic) TrackError trackError;


// Metadata
@property (nonatomic, readonly) NSString *title;
@property (nonatomic, readonly) NSString *artist;
@property (nonatomic, readonly) NSString *comments;
@property (nonatomic, readonly) NSString *grouping;
@property (nonatomic, readonly) NSString *genre;

@property (nonatomic, readonly) NSInteger beatsPerMinute;
@property (nonatomic, readonly) NSTimeInterval startTime;
@property (nonatomic, readonly) NSTimeInterval stopTime;
@property (nonatomic, readonly) NSTimeInterval duration;
@property (nonatomic, readonly) NSInteger databaseID;
@property (nonatomic, readonly) Tonality tonality;
@property (nonatomic, readonly) NSInteger energyLevel;

@property (nonatomic, readonly) double  trackLoudness;
@property (nonatomic, readonly) double  trackPeak;
@property (nonatomic, readonly) NSData *overviewData;
@property (nonatomic, readonly) double  overviewRate;

// Dynamic
@property (nonatomic, readonly) NSTimeInterval playDuration;
@property (nonatomic, readonly) NSTimeInterval silenceAtStart;
@property (nonatomic, readonly) NSTimeInterval silenceAtEnd;
@property (nonatomic, readonly) BOOL didAnalyzeLoudness;

@end
