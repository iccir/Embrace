// (c) 2014-2024 Ricci Adams
// MIT License (or) 1-clause BSD License

#import "TrackLabelView.h"


static NSColor *sGetBorderColorForTrackLabel(TrackLabel trackLabel)
{
    NSColorName name = nil;

    if      (trackLabel == TrackLabelRed)    name = @"TrackLabelRedBorder";
    else if (trackLabel == TrackLabelOrange) name = @"TrackLabelOrangeBorder";
    else if (trackLabel == TrackLabelYellow) name = @"TrackLabelYellowBorder";
    else if (trackLabel == TrackLabelGreen)  name = @"TrackLabelGreenBorder";
    else if (trackLabel == TrackLabelBlue)   name = @"TrackLabelBlueBorder";
    else if (trackLabel == TrackLabelPurple) name = @"TrackLabelPurpleBorder";
    
    return name ? [NSColor colorNamed:name] : nil;
}


static NSColor *sGetFillColorForTrackLabel(TrackLabel trackLabel)
{
    NSColorName name = nil;

    if      (trackLabel == TrackLabelRed)    name = @"TrackLabelRedFill";
    else if (trackLabel == TrackLabelOrange) name = @"TrackLabelOrangeFill";
    else if (trackLabel == TrackLabelYellow) name = @"TrackLabelYellowFill";
    else if (trackLabel == TrackLabelGreen)  name = @"TrackLabelGreenFill";
    else if (trackLabel == TrackLabelBlue)   name = @"TrackLabelBlueFill";
    else if (trackLabel == TrackLabelPurple) name = @"TrackLabelPurpleFill";
    
    return name ? [NSColor colorNamed:name] : nil;
}


@implementation TrackLabelView

- (void) drawRect:(NSRect)dirtyRect
{
    if (_style == TrackLabelViewDot) {
        [self _drawDot];
    } else if (_style == TrackLabelViewEdge) {
        [self _drawEdge];
    } else if (_style == TrackLabelViewStatusShape) {
        [self _drawStatusShape];
    }
}


#pragma mark - Private Methods

- (void) _drawDot
{
    if (_label == TrackLabelNone) return;

    NSColor *borderColor = sGetBorderColorForTrackLabel(_label);
    NSColor *fillColor   = sGetFillColorForTrackLabel(_label);
   
    CGFloat scale = [[self window] backingScaleFactor];

    CGContextRef context = [[NSGraphicsContext currentContext] CGContext];
    CGRect bounds = [self bounds];

    CGRect rect = bounds;

    if (scale > 1) {
        rect.size.width  -= 0.5;
        rect.size.height -= 0.5;
    }
    
    [(_needsWhiteBorder ? [NSColor whiteColor] : borderColor) set];
    CGContextFillEllipseInRect(context, rect);

    [fillColor set];
    CGContextFillEllipseInRect(context, CGRectInset(rect, 1, 1));
}

- (void) _drawEdge
{
    if (_label == TrackLabelNone) return;

    NSColor *borderColor = sGetBorderColorForTrackLabel(_label);
    NSColor *fillColor   = sGetFillColorForTrackLabel(_label);

    CGFloat scale = [[self window] backingScaleFactor];

    CGRect bounds = [self bounds];

    CGRect leftRect   = bounds;
    CGRect bottomRect = bounds;

    CGFloat onePixel = scale > 1 ? 0.5 : 1;

    if (fillColor) {
        [fillColor set];
        NSRectFill(bounds);
    }
    
    if (borderColor) {
        [borderColor set];
        bottomRect.size.height = onePixel;
        NSRectFill(bottomRect);
        
        leftRect.size.width = onePixel;
        NSRectFill(leftRect);
    }
}


- (void) _drawStatusShape
{
    CGContextRef context = [[NSGraphicsContext currentContext] CGContext];
    CGRect bounds = [self bounds];
    
    bounds = CGRectInset(bounds, 2, 2);
       
    if (_trackStatus == TrackStatusQueued || _trackStatus == TrackStatusPreparing) {
        NSColor *borderColor = sGetBorderColorForTrackLabel(_label);
        NSColor *fillColor   = sGetFillColorForTrackLabel(_label);

        if (_needsWhiteBorder) borderColor = [NSColor whiteColor];

        if (!borderColor) {
            borderColor = [NSColor colorNamed:@"SetlistPrimary"];
        }

        if (!fillColor) {
            fillColor = [NSColor colorNamed:@"SetlistSecondary"];
            fillColor = [fillColor blendedColorWithFraction:0.5 ofColor:borderColor];
        }

        NSBezierPath *path = [NSBezierPath bezierPathWithOvalInRect:bounds];

        [fillColor set];
        [path fill];

        [borderColor set];
        [path setLineWidth:2];
        [path stroke];
        
    } else if (_trackStatus == TrackStatusPlaying) {
        CGFloat x1 = CGRectGetMinX(bounds), y1 = CGRectGetMinY(bounds);
        CGFloat x2 = CGRectGetMaxX(bounds), y2 = CGRectGetMidY(bounds);
        CGFloat x3 = CGRectGetMinX(bounds), y3 = CGRectGetMaxY(bounds);

        x2 += 2;

        CGContextMoveToPoint(context, CGRectGetMinX(bounds), CGRectGetMidY(bounds));
        CGContextAddArcToPoint(context, x1, y1, x2, y2, 2);
        CGContextAddArcToPoint(context, x2, y2, x3, y3, 2);
        CGContextAddArcToPoint(context, x3, y3, x1, y1, 2);
        CGContextClosePath(context);

        [[NSColor colorNamed:@"SetlistPlayingText"] set];

        CGContextFillPath(context);
    
    } else if (_trackStatus == TrackStatusPlayed) {
        CGRect insetRect = CGRectInset(bounds, 2, 2);
        CGFloat x1 = CGRectGetMinX(insetRect);
        CGFloat x2 = CGRectGetMaxX(insetRect);
        CGFloat y1 = CGRectGetMinY(insetRect);
        CGFloat y2 = CGRectGetMaxY(insetRect);
        
        CGContextMoveToPoint(context, x1, y1);
        CGContextAddLineToPoint(context, x2, y2);
        CGContextMoveToPoint(context, x1, y2);
        CGContextAddLineToPoint(context, x2, y1);
        
        if (_needsWhiteBorder) {
            [[NSColor whiteColor] set];
        } else {
            [[NSColor colorNamed:@"SetlistPrimaryPlayed"] set];
        }

        CGContextSetLineWidth(context, 4);
        CGContextSetLineCap(context, kCGLineCapRound);
        CGContextStrokePath(context);
    }
}


#pragma mark - Accessors

- (void) setStyle:(TrackLabelViewStyle)style
{
    if (_style != style) {
        _style = style;
        [self setNeedsDisplay:YES];
    }
}


- (void) setTrackStatus:(TrackStatus)trackStatus
{
    if (_trackStatus != trackStatus) {
        _trackStatus = trackStatus;
        [self setNeedsDisplay:YES];
    }
}


- (void) setLabel:(TrackLabel)label
{
    if (_label != label) {
        _label = label;
        [self setNeedsDisplay:YES];
    }
}


- (void) setNeedsWhiteBorder:(BOOL)needsWhiteBorder
{
    if (_needsWhiteBorder != needsWhiteBorder) {
        _needsWhiteBorder = needsWhiteBorder;
        [self setNeedsDisplay:YES];
    }
}


@end
