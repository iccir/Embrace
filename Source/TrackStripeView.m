// (c) 2014-2024 Ricci Adams
// MIT License (or) 1-clause BSD License

#import "TrackStripeView.h"


@implementation TrackStripeView

- (BOOL) isOpaque
{
    return YES;
}


- (void) drawRect:(NSRect)dirtyRect
{
    CGRect  bounds = [self bounds];

    CGRect insetBounds = GetInsetBounds(self);

    if (_solidColor) {
        [_solidColor set];
        NSRectFill(bounds);
    }

    if (_dashColor) {
        [_dashColor set];

        NSRect dashRect = insetBounds;
        dashRect.size.width = bounds.size.height * 3;

        while (dashRect.origin.x < insetBounds.size.width) {
            NSRectFill(dashRect);
            dashRect.origin.x += (dashRect.size.width * 2);
        }
    }
}


#pragma mark - Accessors

- (void) setSolidColor:(NSColor *)solidColor
{
    if (_solidColor != solidColor) {
        _solidColor = solidColor;
        [self setNeedsDisplay:YES];
    }
}


- (void) setDashColor:(NSColor *)dashColor
{
    if (_dashColor != dashColor) {
        _dashColor = dashColor;
        [self setNeedsDisplay:YES];
    }
}


@end
