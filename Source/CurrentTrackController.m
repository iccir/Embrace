//
//  LegacyCurrentTrackController.m
//  Embrace
//
//  Created by Ricci Adams on 2014-01-21.
//  Copyright (c) 2014 Ricci Adams. All rights reserved.
//

#import "CurrentTrackController.h"
#import "Player.h"
#import "EmbraceWindow.h"
#import "WaveformView.h"

typedef NS_ENUM(NSInteger, CurrentTrackAppearance) {
    CurrentTrackAppearanceWhite = 0,
    CurrentTrackAppearanceLight = 1,
    CurrentTrackAppearanceDark  = 2,
};


static CurrentTrackAppearance sGetCurrentTrackAppearance()
{
    return [[NSUserDefaults standardUserDefaults] integerForKey:@"CurrentTrackAppearance"];
}


static void sSetCurrentTrackAppearance(CurrentTrackAppearance appearance)
{
    [[NSUserDefaults standardUserDefaults] setInteger:appearance forKey:@"CurrentTrackAppearance"];
}


static BOOL sGetCurrentTrackPinning()
{
    return [[NSUserDefaults standardUserDefaults] boolForKey:@"CurrentTrackPinning"];
}


static void sSetCurrentTrackPinning(BOOL yn)
{
    [[NSUserDefaults standardUserDefaults] setBool:yn forKey:@"CurrentTrackPinning"];
}



@interface CurrentTrackController () <PlayerListener, NSWindowDelegate>
@end

@interface CurrentTrackControllerMainView : NSView
@end

@implementation CurrentTrackControllerMainView

- (void) mouseDown:(NSEvent *)theEvent
{
    if ([theEvent type] == NSLeftMouseDown) {
        NSEventModifierFlags modifierFlags = [NSEvent modifierFlags];
        
        if ((modifierFlags & (NSShiftKeyMask | NSControlKeyMask | NSAlternateKeyMask | NSCommandKeyMask)) == NSControlKeyMask) {
            [NSMenu popUpContextMenu:[self menu] withEvent:theEvent forView:self];
            return;
        }
    }
    
    [super mouseDown:theEvent];
}


- (void) rightMouseDown:(NSEvent *)theEvent
{
    if ([theEvent type] == NSRightMouseDown) {
        [NSMenu popUpContextMenu:[self menu] withEvent:theEvent forView:self];
    } else {
        [super rightMouseDown:theEvent];
    }
}

@end



@implementation CurrentTrackController

- (NSString *) windowNibName
{
    return @"CurrentTrackWindow";
}

- (void) dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [[Player sharedInstance] removeObserver:self forKeyPath:@"currentTrack"];
}


- (void) observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context
{
    if (object == _player) {
        if ([keyPath isEqualToString:@"currentTrack"]) {
            [self _updateTrack];
        }
    }
}


- (void) _updateTrack
{
    Track *track = [[Player sharedInstance] currentTrack];

    if (track) {
        [[self waveformView] setTrack:track];

        [[self waveformView] setHidden:NO];
        [[self leftLabel]    setHidden:NO];
        [[self rightLabel]   setHidden:NO];

        [[self noTrackLabel] setHidden:YES];

    } else {
        [[self waveformView] setHidden:YES];
        [[self leftLabel]    setHidden:YES];
        [[self rightLabel]   setHidden:YES];

        [[self noTrackLabel] setHidden:NO];
    }
}


- (void) _updateAppearance
{
    CurrentTrackAppearance appearance = sGetCurrentTrackAppearance();
    BOOL pinToBottom = sGetCurrentTrackPinning();

    NSWindow *window = [self window];

    if (appearance == CurrentTrackAppearanceWhite) {
        [window setAppearance:[NSAppearance appearanceNamed:NSAppearanceNameAqua]];

        [[self effectView] setState:NSVisualEffectStateInactive];
    
        [[self leftLabel]  setTextColor:[NSColor blackColor]];
        [[self rightLabel] setTextColor:[NSColor blackColor]];
        [[self noTrackLabel] setTextColor:GetRGBColor(0x909090, 1.0)];
    
        [[self waveformView] setAppearance:[NSAppearance appearanceNamed:NSAppearanceNameAqua]];
        [[self waveformView] setActiveWaveformColor:  GetRGBColor(0x202020, 1.0)];
        [[self waveformView] setInactiveWaveformColor:GetRGBColor(0xababab, 1.0)];

    } else if (appearance == CurrentTrackAppearanceLight) {
        [window setAppearance:[NSAppearance appearanceNamed:NSAppearanceNameVibrantLight]];

        [[self effectView] setState:NSVisualEffectStateActive];

        [[self leftLabel]  setTextColor:[NSColor secondaryLabelColor]];
        [[self rightLabel] setTextColor:[NSColor secondaryLabelColor]];
        [[self noTrackLabel] setTextColor:[NSColor secondaryLabelColor]];

        [[self waveformView] setAppearance:[NSAppearance appearanceNamed:NSAppearanceNameVibrantLight]];
        [[self waveformView] setActiveWaveformColor:  [NSColor secondaryLabelColor]];
        [[self waveformView] setInactiveWaveformColor:[NSColor tertiaryLabelColor]];
    
    } else if (appearance == CurrentTrackAppearanceDark) {
        [window setAppearance:[NSAppearance appearanceNamed:NSAppearanceNameVibrantDark]];

        [[self effectView] setState:NSVisualEffectStateActive];

        [[self leftLabel]  setTextColor:[NSColor secondaryLabelColor]];
        [[self rightLabel] setTextColor:[NSColor secondaryLabelColor]];
        [[self noTrackLabel] setTextColor:[NSColor secondaryLabelColor]];

        [[self waveformView] setAppearance:[NSAppearance appearanceNamed:NSAppearanceNameVibrantDark]];
        [[self waveformView] setActiveWaveformColor:  [NSColor colorWithCalibratedWhite:0.6  alpha:1.0]];
        [[self waveformView] setInactiveWaveformColor:[NSColor colorWithCalibratedWhite:0.25 alpha:1.0]];
    }
    
    [[window standardWindowButton:NSWindowCloseButton] setHidden:pinToBottom];

    if (pinToBottom) {
        [window setHasShadow:NO];
        [window setStyleMask:([window styleMask] & ~NSResizableWindowMask)];
        [window setMovable:NO];
        [window setMovableByWindowBackground:NO];
        [window setLevel:NSDockWindowLevel];

        [window setCollectionBehavior:(
            NSWindowCollectionBehaviorCanJoinAllSpaces |
            NSWindowCollectionBehaviorTransient |
            NSWindowCollectionBehaviorIgnoresCycle |
            NSWindowCollectionBehaviorFullScreenAuxiliary
        )];

    } else {
        [window setHasShadow:YES];
        [window setStyleMask:([window styleMask] | NSResizableWindowMask)];
        [window setMovable:YES];
        [window setMovableByWindowBackground:YES];
        [window setLevel:NSNormalWindowLevel];

        [window setCollectionBehavior:NSWindowCollectionBehaviorDefault];
    }

    [[self waveformView] redisplay];
}


- (void) _updateWindowFrame
{
    if (!sGetCurrentTrackPinning()) return;

    NSRect oldFrame = [[self window] frame];
    
    NSScreen *screen = [NSScreen mainScreen];
    
    NSRect visibleFrame = [screen visibleFrame];
    NSRect frame        = [screen frame];

    // Dock on left
    if (visibleFrame.origin.x > frame.origin.x) {
        if (visibleFrame.origin.x < 10) {
            visibleFrame.size.width += visibleFrame.origin.x;
            visibleFrame.origin.x = 0;

        } else {
            visibleFrame.origin.x   -= 1.0;
            visibleFrame.size.width += 1.0;
        }

    // Dock on right
    } else if (visibleFrame.size.width < frame.size.width) {
        CGFloat dockWidth = frame.size.width - visibleFrame.size.width;
        
        if (dockWidth < 10) {
            visibleFrame.size.width += dockWidth;
        }
        
    // Dock on bottom
    } else {
        if (visibleFrame.origin.y  < 10) {
            visibleFrame.origin.y = 0;
        }
    }

    NSRect newFrame = visibleFrame;
    
    newFrame.size.height = oldFrame.size.height;
    
    [[self window] setFrame:newFrame display:NO];
}


- (void) windowDidResize:(NSNotification *)notification
{
    [self _updateWindowFrame];
}


- (void) windowDidLoad
{
    [super windowDidLoad];

    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(_handleNSApplicationDidChangeScreenParameters:) name:NSApplicationDidChangeScreenParametersNotification object:nil];

    NSWindow *window = [self window];

    [window setDelegate:self];
    [window setFrameAutosaveName:@"CurrentTrackWindow"];

    [window setTitleVisibility:NSWindowTitleHidden];
    [window setTitlebarAppearsTransparent:YES];

    [[window standardWindowButton:NSWindowMiniaturizeButton] setHidden:YES];
    [[window standardWindowButton:NSWindowZoomButton] setHidden:YES];

    [[self mainView] setFrame:[[self effectView] bounds]];
    [[self mainView] setAutoresizingMask:NSViewHeightSizable|NSViewWidthSizable];
    [[self effectView] addSubview:[self mainView]];
    
    if (![window setFrameUsingName:@"CurrentTrackWindow"]) {
        NSScreen *screen = [[NSScreen screens] firstObject];
        
        NSRect screenFrame = [screen visibleFrame];

        NSRect windowFrame = NSMakeRect(0, screenFrame.origin.y, 0, 64);

        windowFrame.size.width = screenFrame.size.width - 32;
        windowFrame.origin.x = round((screenFrame.size.width - windowFrame.size.width) / 2);
        windowFrame.origin.x += screenFrame.origin.x;
    
        [window setFrame:windowFrame display:NO];
    }
    
    Player *player = [Player sharedInstance];
    [self setPlayer:[Player sharedInstance]];

    [player addObserver:self forKeyPath:@"currentTrack" options:0 context:NULL];

    [self _updateTrack];
    
    [[Player sharedInstance] addListener:self];

    [self _updateTrack];

    [[self window] setExcludedFromWindowsMenu:YES];
    
    [self _updateAppearance];
}


- (BOOL) validateMenuItem:(NSMenuItem *)menuItem
{
    NSString *actionString = NSStringFromSelector([menuItem action]);

    if ([actionString isEqualToString:@"changeAppearance:"]) {
        NSInteger tag = [menuItem tag];
        
        if (sGetCurrentTrackAppearance() == tag) {
            [menuItem setState:NSOnState];
        } else {
            [menuItem setState:NSOffState];
        }
    
        return YES;

    } else if ([actionString isEqualToString:@"changePinning:"]) {
        [menuItem setState:sGetCurrentTrackPinning() ? NSOnState : NSOffState];
        return YES;
    }
    
    return NO;
}


- (void) showWindow:(id)sender
{
    [self _updateWindowFrame];
    [super showWindow:sender];
}


- (IBAction) changeAppearance:(id)sender
{
    sSetCurrentTrackAppearance([sender tag]);
    [self _updateAppearance];
}


- (IBAction) changePinning:(id)sender
{
    sSetCurrentTrackPinning([sender state] == NSOffState);
    [self _updateAppearance];
    [self _updateWindowFrame];
}


- (void) _handleNSApplicationDidChangeScreenParameters:(NSNotification *)note
{
    [self _updateWindowFrame];
}


- (void) player:(Player *)player didUpdatePlaying:(BOOL)playing { }
- (void) player:(Player *)player didUpdateIssue:(PlayerIssue)issue { }
- (void) player:(Player *)player didUpdateVolume:(double)volume { }
- (void) player:(Player *)player didInterruptPlaybackWithReason:(PlayerInterruptionReason)reason { }

- (void) playerDidTick:(Player *)player
{
    [[self waveformView] setPercentage:[player percentage]];
}


@end
