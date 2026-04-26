// (c) 2014-2026 Ricci Adams
// MIT License (or) 1-clause BSD License

#import "SetlistSlider.h"



@implementation SetlistSlider

- (void) mouseDown:(NSEvent *)theEvent
{
    [_dragDelegate sliderDidStartDrag:self];
    [super mouseDown:theEvent];
    [_dragDelegate sliderDidEndDrag:self];
}


- (void) windowDidUpdateMain:(NSWindow *)window
{
    [self setNeedsDisplay:YES];
}


- (void) setNeedsDisplayInRect:(NSRect)invalidRect
{
    // Always draw entire bounds, else we get artifacts
    [super setNeedsDisplayInRect:CGRectUnion(invalidRect, [self bounds])];
}


- (NSRect) knobRect
{
    return [[self cell] knobRectFlipped:NO];
}


- (BOOL) acceptsFirstMouse:(nullable NSEvent *)event
{
    return NO;
}


@end


@implementation SetlistSliderCell {
    NSRect _cellFrame;
}


- (NSRect) knobRectFlipped:(BOOL)flipped
{
    double doubleValue = [self doubleValue];
    double minValue    = [self minValue];
    double maxValue    = [self maxValue];
    
    double percentX = (doubleValue - minValue) / (maxValue - minValue);

    CGRect bounds   = [[self controlView] bounds];
    CGRect knobArea = CGRectInset(bounds, 2, 2);

    CGFloat knobWidth = 12;
    CGFloat valueX = round(knobArea.origin.x + ((knobArea.size.width - knobWidth) * percentX));

    CGFloat y = knobArea.origin.y + (knobArea.size.height - knobWidth) / 2;

    return CGRectMake(valueX, y, knobWidth, knobWidth);
}


- (void) drawKnob:(NSRect)inKnobRect
{
    BOOL isInactive = ![[[self controlView] window] isMainWindow] || ![NSApp isActive];

    NSImage *image;
    
    if (isInactive) {
        image = [NSImage imageNamed:@"SetlistSliderInactive"];
    } else if ([self isHighlighted]) {
        image = [NSImage imageNamed:@"SetlistSliderPressed"];
    } else {
        image = [NSImage imageNamed:@"SetlistSliderNormal"];
    }

    CGRect imageRect = CGRectZero;
    imageRect.size = [image size];
    imageRect.origin.x = inKnobRect.origin.x + ((inKnobRect.size.width - imageRect.size.width) / 2.0);
    imageRect.origin.y = inKnobRect.origin.y + ((inKnobRect.size.width - imageRect.size.width) / 2.0);
    
    [image drawInRect:imageRect];
}


- (void) drawTickMarks { }

- (void) drawBarInside:(NSRect)aRect flipped:(BOOL)flipped
{
    BOOL isMainWindow = [[[self controlView] window] isMainWindow];

    NSRect knobRect = [self knobRectFlipped:flipped];
        
    CGFloat midX = NSMidX(knobRect);
    
    NSRect leftRect, rightRect;
    NSDivideRect(aRect, &leftRect, &rightRect, midX - aRect.origin.x, NSMinXEdge);
    
    CGFloat radius = aRect.size.height > aRect.size.width ? aRect.size.width : aRect.size.height;
    radius /= 2;
    
    NSBezierPath *roundedPath = [NSBezierPath bezierPathWithRoundedRect:aRect xRadius:radius yRadius:radius];
    
    [NSGraphicsContext saveGraphicsState];
    [NSGraphicsContext saveGraphicsState];
  
    NSColor *activeColor = [NSColor colorNamed:isMainWindow ? @"MeterFilledMain" : @"MeterFilled"];
    [activeColor set];

    [[NSBezierPath bezierPathWithRect:leftRect] addClip];
    [roundedPath fill];
    
    [NSGraphicsContext restoreGraphicsState];
    
    [[NSColor colorNamed:@"MeterUnfilled"] set];
    [[NSBezierPath bezierPathWithRect:rightRect] addClip];
    [roundedPath fill];
    
    [NSGraphicsContext restoreGraphicsState];
}


@end
