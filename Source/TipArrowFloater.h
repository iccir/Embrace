// (c) 2016-2018 Ricci Adams.  All rights reserved.

#import <Foundation/Foundation.h>

@interface TipArrowFloater : NSObject <CAAnimationDelegate>

- (void) showWithView:(NSView *)view rect:(NSRect)rect;
- (void) hide;


@end
