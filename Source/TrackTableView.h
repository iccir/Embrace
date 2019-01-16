// (c) 2014-2019 Ricci Adams.  All rights reserved.

#import <Foundation/Foundation.h>


extern NSString * const EmbraceLockedTrackPasteboardType;
extern NSString * const EmbraceQueuedTrackPasteboardType;

extern NSColor * const TrackTableViewGetPlayingTextColor(void);
extern NSColor * const TrackTableViewGetRowHighlightColor(BOOL emphasized);


@interface TrackTableView : NSTableView
@property (nonatomic, readonly) NSInteger rowWithMouseInside;
@end


@protocol TrackTableViewDelegate <NSTableViewDelegate>
@optional
- (void) trackTableView:(TrackTableView *)tableView isModifyingViaDrag:(BOOL)isModifyingViaDrag;
@end
