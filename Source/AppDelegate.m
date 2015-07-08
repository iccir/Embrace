//
//  AppDelegate.m
//  Embrace
//
//  Created by Ricci Adams on 2014-01-03.
//  Copyright (c) 2014 Ricci Adams. All rights reserved.
//

#import "AppDelegate.h"

#import "SetlistController.h"
#import "EffectsController.h"
#import "PreferencesController.h"
#import "EditEffectController.h"
#import "CurrentTrackController.h"
#import "ViewTrackController.h"
#import "TracksController.h"
#import "Preferences.h"
#import "DebugController.h"

#import "Player.h"
#import "Effect.h"
#import "Track.h"
#import "CrashPadClient.h"

#import "iTunesManager.h"
#import "WrappedAudioDevice.h"

#import <CrashReporter.h>
#import "CrashReportSender.h"

@interface AppDelegate ()

- (IBAction) openFile:(id)sender;

- (IBAction) clearSetlist:(id)sender;
- (IBAction) resetPlayedTracks:(id)sender;

- (IBAction) copySetlist:(id)sender;
- (IBAction) saveSetlist:(id)sender;
- (IBAction) exportSetlist:(id)sender;

- (IBAction) changeNumberOfLayoutLines:(id)sender;
- (IBAction) changeShortensPlayedTracks:(id)sender;

- (IBAction) changeViewAttributes:(id)sender;
- (IBAction) changeKeySignatureDisplayMode:(id)sender;
- (IBAction) revealEndTime:(id)sender;

- (IBAction) performPreferredPlaybackAction:(id)sender;
- (IBAction) hardSkip:(id)sender;
- (IBAction) hardPause:(id)sender;

- (IBAction) increaseVolume:(id)sender;
- (IBAction) decreaseVolume:(id)sender;
- (IBAction) increaseAutoGap:(id)sender;
- (IBAction) decreaseAutoGap:(id)sender;

- (IBAction) showSetlistWindow:(id)sender;
- (IBAction) showEffectsWindow:(id)sender;
- (IBAction) showPreferences:(id)sender;
- (IBAction) showCurrentTrack:(id)sender;

- (IBAction) sendFeedback:(id)sender;
- (IBAction) viewOnAppStore:(id)sender;

- (IBAction) openAcknowledgements:(id)sender;

- (IBAction) showDebugWindow:(id)sender;
- (IBAction) sendCrashReports:(id)sender;
- (IBAction) openSupportFolder:(id)sender;

@property (nonatomic, weak) IBOutlet NSMenuItem *debugMenuItem;

@property (nonatomic, weak) IBOutlet NSMenuItem *crashReportSeparator;
@property (nonatomic, weak) IBOutlet NSMenuItem *crashReportMenuItem;

@property (nonatomic, weak) IBOutlet NSMenuItem *openSupportSeparator;
@property (nonatomic, weak) IBOutlet NSMenuItem *openSupportMenuItem;

@end

@implementation AppDelegate {
    SetlistController      *_setlistController;
    EffectsController      *_effectsController;
    NSWindowController     *_currentTrackController;
    PreferencesController  *_preferencesController;

#if DEBUG
    DebugController        *_debugController;
#endif

    PLCrashReporter   *_crashReporter;
    CrashReportSender *_crashSender;

    NSMutableArray         *_editEffectControllers;
    NSMutableArray         *_viewTrackControllers;
}


- (void) dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}


- (void) applicationDidFinishLaunching:(NSNotification *)aNotification
{
    EmbraceLogMethod();

    EmbraceCheckCompatibility();

    // Load preferences
    [Preferences sharedInstance];

    // Start parsing iTunes XML
    [iTunesManager sharedInstance];
    
    PLCrashReporterConfig *config = [[PLCrashReporterConfig alloc] initWithSignalHandlerType:PLCrashReporterSignalHandlerTypeBSD symbolicationStrategy:PLCrashReporterSymbolicationStrategyAll];
    _crashReporter = [[PLCrashReporter alloc] initWithConfiguration:config];
    
    _crashSender = [[CrashReportSender alloc] initWithAppIdentifier:@"<redacted>"];

    [_crashSender extractPendingReportFromReporter:_crashReporter];
    SetupCrashPad(_crashReporter);
    
    if (![CrashReportSender isDebuggerAttached]) {
        [_crashReporter enableCrashReporter];
    }

    _setlistController      = [[SetlistController alloc] init];
    _effectsController      = [[EffectsController alloc] init];
    _currentTrackController = [[CurrentTrackController alloc] init];

    [self _showPreviouslyVisibleWindows];

    BOOL hasCrashReports = [_crashSender hasCrashReports];

    [[self crashReportMenuItem] setHidden:!hasCrashReports];
    [[self crashReportSeparator] setHidden:!hasCrashReports];

#ifdef DEBUG
    [[self debugMenuItem] setHidden:NO];
#endif

    EmbraceLog(@"Hello", @"Embrace finished launching at %@", [NSDate date]);
}


- (void) _showPreviouslyVisibleWindows
{
    NSArray *visibleWindows = [[NSUserDefaults standardUserDefaults] objectForKey:@"visible-windows"];
    
    if ([visibleWindows containsObject:@"current-track"]) {
        [self showCurrentTrack:self];
    }

    // Always show Set List
    [self showSetlistWindow:self];
    
#ifdef DEBUG
    [[self debugMenuItem] setHidden:NO];
#endif
}


- (void) _saveVisibleWindows
{
    NSMutableArray *visibleWindows = [NSMutableArray array];
    
    if ([[_setlistController window] isVisible]) {
        [visibleWindows addObject:@"setlist"];
    }

    if ([[_currentTrackController window] isVisible]) {
        [visibleWindows addObject:@"current-track"];
    }

    [[NSUserDefaults standardUserDefaults] setObject:visibleWindows forKey:@"visible-windows"];
}


- (BOOL)applicationShouldHandleReopen:(NSApplication *)theApplication hasVisibleWindows:(BOOL)hasVisibleWindows
{
    EmbraceLogMethod();

    if (!hasVisibleWindows) {
        [self showSetlistWindow:self];
    }

    return YES;
}


- (BOOL) application:(NSApplication *)sender openFile:(NSString *)filename
{
    EmbraceLogMethod();

    NSURL *fileURL = [NSURL fileURLWithPath:filename];

    if (IsAudioFileAtURL(fileURL)) {
        [_setlistController openFileAtURL:fileURL];
        return YES;
    }

    return NO;
}


- (void) application:(NSApplication *)sender openFiles:(NSArray *)filenames
{
    EmbraceLogMethod();

    for (NSString *filename in [filenames reverseObjectEnumerator]) {
        NSURL *fileURL = [NSURL fileURLWithPath:filename];

        if (IsAudioFileAtURL(fileURL)) {
            [_setlistController openFileAtURL:fileURL];
        }
    }
}


- (void) applicationWillTerminate:(NSNotification *)notification
{
    EmbraceLogMethod();

    [self _saveVisibleWindows];

    [[Player sharedInstance] saveEffectState];
    [[Player sharedInstance] hardStop];
    
    [WrappedAudioDevice releaseHoggedDevices];
}


- (NSApplicationTerminateReply) applicationShouldTerminate:(NSApplication *)sender
{
    EmbraceLogMethod();

    if ([[Player sharedInstance] isPlaying]) {
        NSAlert *alert = [[NSAlert alloc] init];

        [alert setMessageText:NSLocalizedString(@"Quit Embrace", nil)];
        [alert setInformativeText:NSLocalizedString(@"Music is currently playing. Are you sure you want to quit?", nil)];
        [alert addButtonWithTitle:NSLocalizedString(@"Quit",   nil)];
        [alert addButtonWithTitle:NSLocalizedString(@"Cancel", nil)];
        [alert setAlertStyle:NSCriticalAlertStyle];

        return [alert runModal] == NSAlertFirstButtonReturn ? NSTerminateNow : NSTerminateCancel;
    }
    
    return NSTerminateNow;
}


#pragma mark - Public Methods

- (void) performPreferredPlaybackAction
{
    [self performPreferredPlaybackAction:self];
}


- (void) displayErrorForTrack:(Track *)track
{
    TrackError trackError = [track trackError];
    if (!trackError) return;

    NSString *messageText     = @"";
    NSString *informativeText = @"";
    
    if (trackError == TrackErrorConversionFailed) {
        messageText = NSLocalizedString(@"The file cannot be read because it is in an unknown format.", nil);
    
    } else if (trackError == TrackErrorProtectedContent) {
        messageText     = NSLocalizedString(@"The file cannot be read because it is protected.", nil);
        informativeText = NSLocalizedString(@"Protected content can only be played with iTunes.\n\nIf this file was downloaded from Apple Music, you will need to first remove the download and then purchase it from the iTunes Store.", nil);

    } else if (trackError == TrackErrorOpenFailed) {
        messageText = NSLocalizedString(@"The file cannot be opened.", nil);
    
    } else {
        messageText = NSLocalizedString(@"The file cannot be read.", nil);
    }
    
    if (![messageText length]) {
        return;
    }
    
    NSAlert *alert = [[NSAlert alloc] init];
    
    [alert setMessageText:messageText];
    [alert setInformativeText:informativeText];

    [alert runModal];
}


- (void) showEffectsWindow
{
    [self showEffectsWindow:self];
}


- (void) showCurrentTrack
{
    [self showCurrentTrack:self];
}


- (void) showPreferences
{
    [self showPreferences:self];
}


- (EditEffectController *) editControllerForEffect:(Effect *)effect
{
    if (!_editEffectControllers) {
        _editEffectControllers = [NSMutableArray array];
    }

    for (EditEffectController *controller in _editEffectControllers) {
        if ([[controller effect] isEqual:effect]) {
            return controller;
        }
    }
    
    EditEffectController *controller = [[EditEffectController alloc] initWithEffect:effect index:[_editEffectControllers count]];

    if (controller) {
        [_editEffectControllers addObject:controller];
    }

    return controller;
}


- (void) closeEditControllerForEffect:(Effect *)effect
{
    NSMutableArray *toRemove = [NSMutableArray array];

    for (EditEffectController *controller in _editEffectControllers) {
        if ([controller effect] == effect) {
            [controller close];
            if (controller) [toRemove addObject:controller];
        }
    }
    
    [_editEffectControllers removeObjectsInArray:toRemove];
}


- (ViewTrackController *) viewTrackControllerForTrack:(Track *)track
{
    if (!_viewTrackControllers) {
        _viewTrackControllers = [NSMutableArray array];
    }

    for (ViewTrackController *controller in _viewTrackControllers) {
        if ([[controller track] isEqual:track]) {
            return controller;
        }
    }
    
    ViewTrackController *controller = [[ViewTrackController alloc] initWithTrack:track];
    if (controller) [_viewTrackControllers addObject:controller];
    return controller;
}


- (void) closeViewTrackControllerForEffect:(Track *)track
{
    NSMutableArray *toRemove = [NSMutableArray array];

    for (ViewTrackController *controller in _viewTrackControllers) {
        if ([controller track] == track) {
            [controller close];
            if (controller) [toRemove addObject:controller];
        }
    }
    
    [_viewTrackControllers removeObjectsInArray:toRemove];
}


#pragma mark - IBActions

- (BOOL) validateMenuItem:(NSMenuItem *)menuItem
{
    SEL action = [menuItem action];

    if (action == @selector(performPreferredPlaybackAction:)) {
        PlaybackAction playbackAction = [_setlistController preferredPlaybackAction];
        
        NSString *title = NSLocalizedString(@"Play", nil);
        BOOL enabled = [_setlistController isPreferredPlaybackActionEnabled];
        NSInteger state = NSOffState;
        
        if (playbackAction == PlaybackActionShowIssue) {
            title = NSLocalizedString(@"Show Issue", nil);

        } else if (playbackAction == PlaybackActionPause) {
            title = NSLocalizedString(@"Pause", nil);
        }

        [menuItem setState:state];
        [menuItem setTitle:title];
        [menuItem setEnabled:enabled];
        [menuItem setKeyEquivalent:@" "];

    } else if (action == @selector(clearSetlist:)) {
        if ([_setlistController shouldPromptForClear]) {
            [menuItem setTitle:NSLocalizedString(@"Clear Set List\\U2026", nil)];
        } else {
            [menuItem setTitle:NSLocalizedString(@"Clear Set List", nil)];
        }

// Disable this when playing in the trial version.  Else it's too easy to DJ with the trial.
#if TRIAL
        return ![[Player sharedInstance] isPlaying];
#endif

        return YES;
    
    } else if (action == @selector(resetPlayedTracks:)) {
        if ([_setlistController shouldPromptForClear]) {
            [menuItem setTitle:NSLocalizedString(@"Reset Played Tracks\\U2026", nil)];
        } else {
            [menuItem setTitle:NSLocalizedString(@"Reset Played Tracks", nil)];
        }

        return ![[Player sharedInstance] isPlaying];
    
    } else if (action == @selector(hardPause:)) {
        return [[Player sharedInstance] isPlaying];

    } else if (action == @selector(hardSkip:)) {
        return [[Player sharedInstance] isPlaying];

    } else if (action == @selector(showSetlistWindow:)) {
        BOOL yn = [_setlistController isWindowLoaded] && [[_setlistController window] isMainWindow];
        [menuItem setState:(yn ? NSOnState : NSOffState)];
    
    } else if (action == @selector(showEffectsWindow:)) {
        BOOL yn = [_effectsController isWindowLoaded] && [[_effectsController window] isMainWindow];
        [menuItem setState:(yn ? NSOnState : NSOffState)];
    
    } else if (action == @selector(showCurrentTrack:)) {
        BOOL yn = [_currentTrackController isWindowLoaded] && [[_currentTrackController window] isMainWindow];
        [menuItem setState:(yn ? NSOnState : NSOffState)];

    } else if (action == @selector(changeViewAttributes:)) {
        TrackViewAttribute viewAttribute = [menuItem tag];
        BOOL isEnabled = [[Preferences sharedInstance] numberOfLayoutLines] > 1;
        
        if (viewAttribute == TrackViewAttributeDuplicateStatus) {
            isEnabled = YES;
        }

        BOOL yn = [[Preferences sharedInstance] isTrackViewAttributeSelected:viewAttribute];
        if (!isEnabled) yn = NO;

        [menuItem setState:(yn ? NSOnState : NSOffState)];
        
        return isEnabled;

    } else if (action == @selector(changeKeySignatureDisplayMode:)) {
        KeySignatureDisplayMode mode = [[Preferences sharedInstance] keySignatureDisplayMode];
        BOOL yn = mode == [menuItem tag];
        [menuItem setState:(yn ? NSOnState : NSOffState)];
    
    } else if (action == @selector(changeNumberOfLayoutLines:)) {
        NSInteger yn = ([[Preferences sharedInstance] numberOfLayoutLines] == [menuItem tag]);
        [menuItem setState:(yn ? NSOnState : NSOffState)];

    } else if (action == @selector(changeShortensPlayedTracks:)) {
        NSInteger yn = [[Preferences sharedInstance] shortensPlayedTracks];
        [menuItem setState:(yn ? NSOnState : NSOffState)];

    } else if (action == @selector(revealEndTime:)) {
        return [_setlistController validateMenuItem:menuItem];

    } else if (action == @selector(sendCrashReports:)){
        BOOL hasCrashReports = [_crashSender hasCrashReports];

        [[self crashReportMenuItem]  setHidden:!hasCrashReports];
        [[self crashReportSeparator] setHidden:!hasCrashReports];

        return YES;

    } else if (action == @selector(openSupportFolder:)){
        NSUInteger modifierFlags = [NSEvent modifierFlags];
        
        NSUInteger mask = NSControlKeyMask | NSAlternateKeyMask | NSCommandKeyMask;
        BOOL visible = ((modifierFlags & mask) == mask);
    
        [[self openSupportSeparator] setHidden:!visible];
        [[self openSupportMenuItem]  setHidden:!visible];

        return YES;
    }

    return YES;
}


- (IBAction) clearSetlist:(id)sender
{
    EmbraceLogMethod();

    if ([_setlistController shouldPromptForClear]) {
        NSAlert *alert = [[NSAlert alloc] init];
        
        [alert setMessageText:NSLocalizedString(@"Clear Set List", nil)];
        [alert setInformativeText:NSLocalizedString(@"You haven't saved or exported the current set list. Are you sure you want to clear it?", nil)];
        [alert addButtonWithTitle:NSLocalizedString(@"Clear",  nil)];
        [alert addButtonWithTitle:NSLocalizedString(@"Cancel", nil)];
        
        if ([alert runModal] == NSAlertFirstButtonReturn) {
            [_setlistController clear];
        }
    
    } else {
        [_setlistController clear];
    }
}


- (IBAction) resetPlayedTracks:(id)sender
{
    EmbraceLogMethod();

    if ([_setlistController shouldPromptForClear]) {
        NSAlert *alert = [[NSAlert alloc] init];

        [alert setMessageText:NSLocalizedString(@"Reset Played Tracks", nil)];
        [alert setInformativeText:NSLocalizedString(@"Are you sure you want to reset all played tracks to the queued state?", nil)];
        [alert addButtonWithTitle:NSLocalizedString(@"Reset",  nil)];
        [alert addButtonWithTitle:NSLocalizedString(@"Cancel", nil)];
        
        if ([alert runModal] == NSAlertFirstButtonReturn) {
            [_setlistController resetPlayedTracks];
        }
    
    } else {
        [_setlistController resetPlayedTracks];
    }
}


- (IBAction) openFile:(id)sender
{
    EmbraceLogMethod();

    NSOpenPanel *openPanel = [NSOpenPanel openPanel];

    if (!LoadPanelState(openPanel, @"open-file-panel")) {
        NSString *musicPath = [NSSearchPathForDirectoriesInDomains(NSMusicDirectory, NSUserDomainMask, YES) firstObject];
        
        if (musicPath) {
            [openPanel setDirectoryURL:[NSURL fileURLWithPath:musicPath]];
        }
    }
    
    [openPanel setTitle:NSLocalizedString(@"Add to Set List", nil)];
    [openPanel setAllowedFileTypes:GetAvailableAudioFileUTIs()];

    __weak id weakSetlistController = _setlistController;


    [openPanel beginWithCompletionHandler:^(NSInteger result) {
        if (result == NSFileHandlingPanelOKButton) {
            SavePanelState(openPanel, @"open-file-panel");
            [weakSetlistController openFileAtURL:[openPanel URL]];
        }
    }];
}


- (IBAction) copySetlist:(id)sender
{
    EmbraceLogMethod();

    [_setlistController copyToPasteboard:[NSPasteboard generalPasteboard]];
}


- (IBAction) saveSetlist:(id)sender
{
    EmbraceLogMethod();

    NSSavePanel *savePanel = [NSSavePanel savePanel];

    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    [formatter setDateStyle:NSDateFormatterLongStyle];
    [formatter setTimeStyle:NSDateFormatterNoStyle];
    
    NSString *dateString = [formatter stringFromDate:[NSDate date]];

    NSString *suggestedNameFormat = NSLocalizedString(@"Embrace (%@)", nil);
    NSString *suggestedName = [NSString stringWithFormat:suggestedNameFormat, dateString];
    [savePanel setNameFieldStringValue:suggestedName];

    [savePanel setTitle:NSLocalizedString(@"Save Set List", nil)];
    [savePanel setAllowedFileTypes:@[ @"txt" ]];
    
    if (!LoadPanelState(savePanel, @"save-set-list-panel")) {
        NSString *desktopPath = [NSSearchPathForDirectoriesInDomains(NSDesktopDirectory, NSUserDomainMask, YES) firstObject];
        
        if (desktopPath) {
            [savePanel setDirectoryURL:[NSURL fileURLWithPath:desktopPath]];
        }
    }
    
    __weak id weakSetlistController = _setlistController;
    
    [savePanel beginWithCompletionHandler:^(NSInteger result) {
        if (result == NSFileHandlingPanelOKButton) {
            SavePanelState(savePanel, @"save-set-list-panel");
            [weakSetlistController saveToFileAtURL:[savePanel URL]];
        }
    }];
}


- (IBAction) changeNumberOfLayoutLines:(id)sender
{
    EmbraceLogMethod();
    [[Preferences sharedInstance] setNumberOfLayoutLines:[sender tag]];
}


- (IBAction) changeShortensPlayedTracks:(id)sender
{
    EmbraceLogMethod();
    
    Preferences *preferences = [Preferences sharedInstance];
    [preferences setShortensPlayedTracks:![preferences shortensPlayedTracks]];
}


- (IBAction) changeViewAttributes:(id)sender
{
    EmbraceLogMethod();

    Preferences *preferences = [Preferences sharedInstance];
    TrackViewAttribute attribute = [sender tag];
    
    BOOL yn = [preferences isTrackViewAttributeSelected:attribute];
    [preferences setTrackViewAttribute:attribute selected:!yn];
}


- (IBAction) changeKeySignatureDisplayMode:(id)sender
{
    EmbraceLogMethod();

    Preferences *preferences = [Preferences sharedInstance];
    [preferences setKeySignatureDisplayMode:[sender tag]];
}


- (IBAction) exportSetlist:(id)sender   {  EmbraceLogMethod();  [_setlistController exportToPlaylist]; }
- (IBAction) increaseAutoGap:(id)sender {  EmbraceLogMethod();  [_setlistController increaseAutoGap:self]; }
- (IBAction) decreaseAutoGap:(id)sender {  EmbraceLogMethod();  [_setlistController decreaseAutoGap:self]; }
- (IBAction) revealEndTime:(id)sender   {  EmbraceLogMethod();  [_setlistController revealEndTime:self];     }


- (IBAction) performPreferredPlaybackAction:(id)sender
{
    EmbraceLog(@"AppDelegate", @"performPreferredPlaybackAction:  sender=%@, event=%@", sender, [NSApp currentEvent]);
    [_setlistController performPreferredPlaybackAction:self];
}


- (IBAction) increaseVolume:(id)sender
{
    EmbraceLog(@"AppDelegate", @"increaseVolume:  sender=%@, event=%@", sender, [NSApp currentEvent]);
    [_setlistController increaseVolume:self];
}


- (IBAction) decreaseVolume:(id)sender
{
    EmbraceLog(@"AppDelegate", @"decreaseVolume:  sender=%@, event=%@", sender, [NSApp currentEvent]);
    [_setlistController decreaseVolume:self];
}


- (IBAction) hardSkip:(id)sender
{
    EmbraceLog(@"AppDelegate", @"hardSkip:  sender=%@, event=%@", sender, [NSApp currentEvent]);
    [[Player sharedInstance] hardSkip];
}


- (IBAction) hardPause:(id)sender
{
    EmbraceLog(@"AppDelegate", @"hardPause:  sender=%@, event=%@", sender, [NSApp currentEvent]);
    [[Player sharedInstance] hardStop];
}


- (void) _toggleWindowForController:(NSWindowController *)controller sender:(id)sender
{
    BOOL orderIn = YES;

    if ([sender isKindOfClass:[NSMenuItem class]]) {
        if ([sender state] == NSOnState) {
            orderIn = NO;
        }
    }
    
    if (orderIn) {
        [controller showWindow:self];
    } else {
        [[controller window] orderOut:self];
    }
}


- (IBAction) showSetlistWindow:(id)sender
{
    EmbraceLogMethod();
    [self _toggleWindowForController:_setlistController sender:sender];
}


- (IBAction) showEffectsWindow:(id)sender
{
    EmbraceLogMethod();
    [self _toggleWindowForController:_effectsController sender:sender];
}


- (IBAction) showCurrentTrack:(id)sender
{
    EmbraceLogMethod();
    [self _toggleWindowForController:_currentTrackController sender:sender];
}


- (IBAction) showDebugWindow:(id)sender
{
#if DEBUG
    EmbraceLogMethod();

    if (!_debugController) {
        _debugController = [[DebugController alloc] init];
    }

    [_debugController showWindow:self];
#endif
}


- (IBAction) sendCrashReports:(id)sender
{
    EmbraceLogMethod();

    NSAlert *(^makeAlertOne)() = ^{
        NSAlert *alert = [[NSAlert alloc] init];
        
        [alert setMessageText:NSLocalizedString(@"Send Crash Report?", nil)];
        [alert setInformativeText:NSLocalizedString(@"Information about the crash, your operating system, and device will be sent. No personal information is included.", nil)];
        [alert addButtonWithTitle:NSLocalizedString(@"Send", nil)];
        [alert addButtonWithTitle:NSLocalizedString(@"Cancel", nil)];

        return alert;
    };

    NSAlert *(^makeAlertTwo)() = ^{
        NSAlert *alert = [[NSAlert alloc] init];

        [alert setMessageText:NSLocalizedString(@"Crash Report Sent", nil)];
        [alert setInformativeText:NSLocalizedString(@"Thank you for your crash report.  If you have any additional information regarding the crash, please contact me.", nil)];
        [alert addButtonWithTitle:NSLocalizedString(@"OK", nil)];
        [alert addButtonWithTitle:NSLocalizedString(@"Contact", nil)];

        return alert;
    };
    
    BOOL okToSend = [makeAlertOne() runModal] == NSAlertFirstButtonReturn;

    if (okToSend) {
        [_crashSender sendCrashReportsWithCompletionHandler:^(BOOL didSend) {
            NSModalResponse response = [makeAlertTwo() runModal];
            
            if (response == NSAlertSecondButtonReturn) {
                [self sendFeedback:nil];
            }
        }];
    }
}


- (IBAction) openSupportFolder:(id)sender
{
    EmbraceLogMethod();

    NSString *file = GetApplicationSupportDirectory();
    file = [file stringByDeletingLastPathComponent];

    [[NSWorkspace sharedWorkspace] openFile:file];
}


- (IBAction) showPreferences:(id)sender
{
    EmbraceLogMethod();

    if (!_preferencesController) {
        _preferencesController = [[PreferencesController alloc] init];
    }

    [_preferencesController showWindow:self];
}


- (IBAction) sendFeedback:(id)sender
{
    EmbraceLogMethod();

    NSURL *url = [NSURL URLWithString:@"http://www.ricciadams.com/contact/"];
    [[NSWorkspace sharedWorkspace] openURL:url];
}


- (IBAction) viewWebsite:(id)sender
{
    EmbraceLogMethod();

    NSURL *url = [NSURL URLWithString:@"http://www.ricciadams.com/projects/embrace"];
    [[NSWorkspace sharedWorkspace] openURL:url];
}



- (IBAction) viewFacebookGroup:(id)sender
{
    EmbraceLogMethod();

    NSURL *url = [NSURL URLWithString:@"https://www.facebook.com/groups/embrace.users"];
    [[NSWorkspace sharedWorkspace] openURL:url];
}



- (IBAction) viewOnAppStore:(id)sender
{
    EmbraceLogMethod();

    NSURL *url = [NSURL URLWithString:@"http://www.ricciadams.com/buy/embrace"];
    [[NSWorkspace sharedWorkspace] openURL:url];
}


- (IBAction) openAcknowledgements:(id)sender
{
    EmbraceLogMethod();

    NSString *fromPath = [[NSBundle mainBundle] pathForResource:@"Acknowledgements" ofType:@"rtf"];
    NSString *toPath = [NSTemporaryDirectory() stringByAppendingPathComponent:[fromPath lastPathComponent]];

    NSError *error;

    if ([[NSFileManager defaultManager] fileExistsAtPath:toPath]) {
        [[NSFileManager defaultManager] removeItemAtPath:toPath error:&error];
    }

    [[NSFileManager defaultManager] copyItemAtPath:fromPath toPath:toPath error:&error];

    [[NSFileManager defaultManager] setAttributes:@{
        NSFilePosixPermissions: @0444
    } ofItemAtPath:toPath error:&error];
    
    [[NSWorkspace sharedWorkspace] openFile:toPath];
}


@end
