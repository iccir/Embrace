// (c) 2014-2018 Ricci Adams.  All rights reserved.

#import <Foundation/Foundation.h>
#import "AudioFile.h"

@class Track;

@interface TrackScheduler : NSObject

- (id) initWithTrack:(Track *)track;

- (BOOL) setup;

- (BOOL) startSchedulingWithAudioUnit:(AudioUnit)audioUnit paddingInSeconds:(NSTimeInterval)paddingInSeconds;
- (void) stopScheduling:(AudioUnit)audioUnit;

- (AudioFileError) audioFileError;

- (NSTimeInterval) timeElapsed;
- (NSInteger) samplesPlayed;
- (BOOL) isDone;

@property (nonatomic, readonly) Track *track;
@property (nonatomic, readonly) AudioStreamBasicDescription clientFormat;

@end
