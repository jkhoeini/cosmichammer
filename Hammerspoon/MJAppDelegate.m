#import <Cocoa/Cocoa.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import "MJAppDelegate.h"
#import "MJConsoleWindowController.h"
#import "MJPreferencesWindowController.h"
#import "MJDockIcon.h"
#import "MJMenuIcon.h"
#import "MJLua.h"
#import "MJVersionUtils.h"
#import "MJConfigUtils.h"
#import "MJFileUtils.h"
#import "MJAccessibilityUtils.h"
#import "HSLogger.h"
#import "variables.h"

@implementation MJAppDelegate

#pragma mark - Programmatic Menu Construction

- (void)setupMainMenu {
    NSMenu *mainMenu = [[NSMenu alloc] initWithTitle:@"Main Menu"];

    // ── Hammerspoon (application) menu ──
    NSMenuItem *appMenuItem = [[NSMenuItem alloc] initWithTitle:@"Hammerspoon" action:nil keyEquivalent:@""];
    NSMenu *appMenu = [[NSMenu alloc] initWithTitle:@"Hammerspoon"];

    [appMenu addItemWithTitle:@"About Hammerspoon" action:@selector(showAboutPanel:) keyEquivalent:@""].target = self;

    [appMenu addItem:[NSMenuItem separatorItem]];

    [appMenu addItemWithTitle:@"Preferences…" action:@selector(showPreferencesWindow:) keyEquivalent:@","].target = self;

    [appMenu addItem:[NSMenuItem separatorItem]];

    NSMenuItem *servicesItem = [[NSMenuItem alloc] initWithTitle:@"Services" action:nil keyEquivalent:@""];
    NSMenu *servicesMenu = [[NSMenu alloc] initWithTitle:@"Services"];
    servicesItem.submenu = servicesMenu;
    [appMenu addItem:servicesItem];
    [NSApp setServicesMenu:servicesMenu];

    [appMenu addItem:[NSMenuItem separatorItem]];

    [appMenu addItemWithTitle:@"Hide Hammerspoon" action:@selector(hide:) keyEquivalent:@"h"];

    NSMenuItem *hideOthersItem = [appMenu addItemWithTitle:@"Hide Others" action:@selector(hideOtherApplications:) keyEquivalent:@"h"];
    hideOthersItem.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagOption;

    [appMenu addItemWithTitle:@"Show All" action:@selector(unhideAllApplications:) keyEquivalent:@""];

    [appMenu addItem:[NSMenuItem separatorItem]];

    [appMenu addItemWithTitle:@"Quit Hammerspoon" action:@selector(quitHammerspoon:) keyEquivalent:@"q"].target = self;

    appMenuItem.submenu = appMenu;
    [mainMenu addItem:appMenuItem];

    // ── File menu ──
    NSMenuItem *fileMenuItem = [[NSMenuItem alloc] initWithTitle:@"File" action:nil keyEquivalent:@""];
    NSMenu *fileMenu = [[NSMenu alloc] initWithTitle:@"File"];

    NSMenuItem *reloadItem = [fileMenu addItemWithTitle:@"Reload Config" action:@selector(reloadConfig:) keyEquivalent:@"R"];
    reloadItem.target = self;
    reloadItem.keyEquivalentModifierMask = NSEventModifierFlagCommand;

    [fileMenu addItemWithTitle:@"Open Config" action:@selector(openConfig:) keyEquivalent:@"o"].target = self;

    [fileMenu addItem:[NSMenuItem separatorItem]];

    [fileMenu addItemWithTitle:@"Console…" action:@selector(showConsoleWindow:) keyEquivalent:@"r"].target = self;

    [fileMenu addItem:[NSMenuItem separatorItem]];

    NSMenuItem *pageSetupItem = [fileMenu addItemWithTitle:@"Page Setup…" action:@selector(runPageLayout:) keyEquivalent:@"P"];
    pageSetupItem.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagShift;

    [fileMenu addItemWithTitle:@"Print…" action:@selector(print:) keyEquivalent:@"p"];

    fileMenuItem.submenu = fileMenu;
    [mainMenu addItem:fileMenuItem];

    // ── Edit menu ──
    NSMenuItem *editMenuItem = [[NSMenuItem alloc] initWithTitle:@"Edit" action:nil keyEquivalent:@""];
    NSMenu *editMenu = [[NSMenu alloc] initWithTitle:@"Edit"];

    [editMenu addItemWithTitle:@"Undo" action:@selector(undo:) keyEquivalent:@"z"];
    NSMenuItem *redoItem = [editMenu addItemWithTitle:@"Redo" action:@selector(redo:) keyEquivalent:@"Z"];
    redoItem.keyEquivalentModifierMask = NSEventModifierFlagCommand;

    [editMenu addItem:[NSMenuItem separatorItem]];

    [editMenu addItemWithTitle:@"Cut" action:@selector(cut:) keyEquivalent:@"x"];
    [editMenu addItemWithTitle:@"Copy" action:@selector(copy:) keyEquivalent:@"c"];
    [editMenu addItemWithTitle:@"Paste" action:@selector(paste:) keyEquivalent:@"v"];

    NSMenuItem *pasteMatchItem = [editMenu addItemWithTitle:@"Paste and Match Style" action:@selector(pasteAsPlainText:) keyEquivalent:@"V"];
    pasteMatchItem.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagOption;

    [editMenu addItemWithTitle:@"Delete" action:@selector(delete:) keyEquivalent:@""];
    [editMenu addItemWithTitle:@"Select All" action:@selector(selectAll:) keyEquivalent:@"a"];

    [editMenu addItem:[NSMenuItem separatorItem]];

    // Find submenu
    NSMenuItem *findMenuItem = [[NSMenuItem alloc] initWithTitle:@"Find" action:nil keyEquivalent:@""];
    NSMenu *findMenu = [[NSMenu alloc] initWithTitle:@"Find"];

    NSMenuItem *findItem = [findMenu addItemWithTitle:@"Find…" action:@selector(performFindPanelAction:) keyEquivalent:@"f"];
    findItem.tag = 1;

    NSMenuItem *findReplaceItem = [findMenu addItemWithTitle:@"Find and Replace…" action:@selector(performFindPanelAction:) keyEquivalent:@"f"];
    findReplaceItem.tag = 12;
    findReplaceItem.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagOption;

    NSMenuItem *findNextItem = [findMenu addItemWithTitle:@"Find Next" action:@selector(performFindPanelAction:) keyEquivalent:@"g"];
    findNextItem.tag = 2;

    NSMenuItem *findPrevItem = [findMenu addItemWithTitle:@"Find Previous" action:@selector(performFindPanelAction:) keyEquivalent:@"G"];
    findPrevItem.tag = 3;
    findPrevItem.keyEquivalentModifierMask = NSEventModifierFlagCommand;

    NSMenuItem *useSelItem = [findMenu addItemWithTitle:@"Use Selection for Find" action:@selector(performFindPanelAction:) keyEquivalent:@"e"];
    useSelItem.tag = 7;

    [findMenu addItemWithTitle:@"Jump to Selection" action:@selector(centerSelectionInVisibleArea:) keyEquivalent:@"j"];

    findMenuItem.submenu = findMenu;
    [editMenu addItem:findMenuItem];

    // Spelling and Grammar submenu
    NSMenuItem *spellingMenuItem = [[NSMenuItem alloc] initWithTitle:@"Spelling and Grammar" action:nil keyEquivalent:@""];
    NSMenu *spellingMenu = [[NSMenu alloc] initWithTitle:@"Spelling"];

    [spellingMenu addItemWithTitle:@"Show Spelling and Grammar" action:@selector(showGuessPanel:) keyEquivalent:@":"];
    [spellingMenu addItemWithTitle:@"Check Document Now" action:@selector(checkSpelling:) keyEquivalent:@";"];
    [spellingMenu addItem:[NSMenuItem separatorItem]];
    [spellingMenu addItemWithTitle:@"Check Spelling While Typing" action:@selector(toggleContinuousSpellChecking:) keyEquivalent:@""];
    [spellingMenu addItemWithTitle:@"Check Grammar With Spelling" action:@selector(toggleGrammarChecking:) keyEquivalent:@""];
    [spellingMenu addItemWithTitle:@"Correct Spelling Automatically" action:@selector(toggleAutomaticSpellingCorrection:) keyEquivalent:@""];

    spellingMenuItem.submenu = spellingMenu;
    [editMenu addItem:spellingMenuItem];

    // Substitutions submenu
    NSMenuItem *subsMenuItem = [[NSMenuItem alloc] initWithTitle:@"Substitutions" action:nil keyEquivalent:@""];
    NSMenu *subsMenu = [[NSMenu alloc] initWithTitle:@"Substitutions"];

    [subsMenu addItemWithTitle:@"Show Substitutions" action:@selector(orderFrontSubstitutionsPanel:) keyEquivalent:@""];
    [subsMenu addItem:[NSMenuItem separatorItem]];
    [subsMenu addItemWithTitle:@"Smart Copy/Paste" action:@selector(toggleSmartInsertDelete:) keyEquivalent:@""];
    [subsMenu addItemWithTitle:@"Smart Quotes" action:@selector(toggleAutomaticQuoteSubstitution:) keyEquivalent:@""];
    [subsMenu addItemWithTitle:@"Smart Dashes" action:@selector(toggleAutomaticDashSubstitution:) keyEquivalent:@""];
    [subsMenu addItemWithTitle:@"Smart Links" action:@selector(toggleAutomaticLinkDetection:) keyEquivalent:@""];
    [subsMenu addItemWithTitle:@"Data Detectors" action:@selector(toggleAutomaticDataDetection:) keyEquivalent:@""];
    [subsMenu addItemWithTitle:@"Text Replacement" action:@selector(toggleAutomaticTextReplacement:) keyEquivalent:@""];

    subsMenuItem.submenu = subsMenu;
    [editMenu addItem:subsMenuItem];

    // Transformations submenu
    NSMenuItem *transMenuItem = [[NSMenuItem alloc] initWithTitle:@"Transformations" action:nil keyEquivalent:@""];
    NSMenu *transMenu = [[NSMenu alloc] initWithTitle:@"Transformations"];

    [transMenu addItemWithTitle:@"Make Upper Case" action:@selector(uppercaseWord:) keyEquivalent:@""];
    [transMenu addItemWithTitle:@"Make Lower Case" action:@selector(lowercaseWord:) keyEquivalent:@""];
    [transMenu addItemWithTitle:@"Capitalize" action:@selector(capitalizeWord:) keyEquivalent:@""];

    transMenuItem.submenu = transMenu;
    [editMenu addItem:transMenuItem];

    // Speech submenu
    NSMenuItem *speechMenuItem = [[NSMenuItem alloc] initWithTitle:@"Speech" action:nil keyEquivalent:@""];
    NSMenu *speechMenu = [[NSMenu alloc] initWithTitle:@"Speech"];

    [speechMenu addItemWithTitle:@"Start Speaking" action:@selector(startSpeaking:) keyEquivalent:@""];
    [speechMenu addItemWithTitle:@"Stop Speaking" action:@selector(stopSpeaking:) keyEquivalent:@""];

    speechMenuItem.submenu = speechMenu;
    [editMenu addItem:speechMenuItem];

    editMenuItem.submenu = editMenu;
    [mainMenu addItem:editMenuItem];

    // ── Window menu ──
    NSMenuItem *windowMenuItem = [[NSMenuItem alloc] initWithTitle:@"Window" action:nil keyEquivalent:@""];
    NSMenu *windowMenu = [[NSMenu alloc] initWithTitle:@"Window"];

    [windowMenu addItemWithTitle:@"Minimize" action:@selector(performMiniaturize:) keyEquivalent:@"m"];
    [windowMenu addItemWithTitle:@"Zoom" action:@selector(performZoom:) keyEquivalent:@""];
    [windowMenu addItem:[NSMenuItem separatorItem]];
    [windowMenu addItemWithTitle:@"Close" action:@selector(performClose:) keyEquivalent:@"w"];
    [windowMenu addItem:[NSMenuItem separatorItem]];
    [windowMenu addItemWithTitle:@"Bring All to Front" action:@selector(arrangeInFront:) keyEquivalent:@""];

    windowMenuItem.submenu = windowMenu;
    [mainMenu addItem:windowMenuItem];
    [NSApp setWindowsMenu:windowMenu];

    // ── Help menu ──
    NSMenuItem *helpMenuItem = [[NSMenuItem alloc] initWithTitle:@"Help" action:nil keyEquivalent:@""];
    NSMenu *helpMenu = [[NSMenu alloc] initWithTitle:@"Help"];

    [helpMenu addItemWithTitle:@"Hammerspoon Help" action:@selector(showHelp:) keyEquivalent:@"?"];

    helpMenuItem.submenu = helpMenu;
    [mainMenu addItem:helpMenuItem];
    [NSApp setHelpMenu:helpMenu];

    [NSApp setMainMenu:mainMenu];
}

- (void)setupStatusItemMenu {
    NSMenu *menu = [[NSMenu alloc] initWithTitle:@"Status Item Menu"];

    [menu addItemWithTitle:@"Reload Config" action:@selector(reloadConfig:) keyEquivalent:@""].target = self;
    [menu addItemWithTitle:@"Open Config" action:@selector(openConfig:) keyEquivalent:@""].target = self;
    [menu addItem:[NSMenuItem separatorItem]];
    [menu addItemWithTitle:@"Console…" action:@selector(showConsoleWindow:) keyEquivalent:@""].target = self;
    [menu addItemWithTitle:@"Preferences…" action:@selector(showPreferencesWindow:) keyEquivalent:@""].target = self;
    [menu addItem:[NSMenuItem separatorItem]];
    [menu addItemWithTitle:@"About Hammerspoon" action:@selector(showAboutPanel:) keyEquivalent:@""].target = self;
    [menu addItemWithTitle:@"Quit Hammerspoon" action:@selector(quitHammerspoon:) keyEquivalent:@""].target = self;

    self.menuBarMenu = menu;
}

#pragma mark - Application Lifecycle

- (BOOL) applicationShouldHandleReopen:(NSApplication*)theApplication hasVisibleWindows:(BOOL)hasVisibleWindows {
    callDockIconCallback();
    if (HSOpenConsoleOnDockClickEnabled()) {
        [[MJConsoleWindowController singleton] showWindow: nil];
    };
    return NO;
}

-(void)applicationWillFinishLaunching:(NSNotification *)aNotification
{
    [self setupMainMenu];
    [self setupStatusItemMenu];

    // Set up an early event manager handler so we can catch URLs used to launch us
    NSAppleEventManager *appleEventManager = [NSAppleEventManager sharedAppleEventManager];
    [appleEventManager setEventHandler:self
                           andSelector:@selector(handleGetURLEvent:withReplyEvent:)
                         forEventClass:kInternetEventClass andEventID:kAEGetURL];
    self.startupEvent = nil;
    self.startupFile = nil;
    self.openFileDelegate = nil;
}

- (void)handleGetURLEvent:(NSAppleEventDescriptor *)event withReplyEvent:(NSAppleEventDescriptor *)replyEvent
{
    self.startupEvent = event;
}

- (BOOL)application:(NSApplication *)theApplication openFile:(NSString *)fileAndPath {
    NSString *typeOfFile = nil;
    NSURL *fileURL = [NSURL fileURLWithPath:fileAndPath];
    id contentTypeValue = nil;
    if ([fileURL getResourceValue:&contentTypeValue forKey:NSURLContentTypeKey error:nil] && contentTypeValue) {
        typeOfFile = [(UTType *)contentTypeValue identifier];
    }

    if ([typeOfFile isEqualToString:@"org.hammerspoon.hammerspoon.spoon"]) {
        // This is a Spoon, so we will attempt to copy it to the Spoons directory
        NSError *fileError;
        BOOL success = NO;
        BOOL upgrade = NO;
        NSString *spoonPath = [MJConfigDirAbsolute() stringByAppendingPathComponent:@"Spoons"];
        NSString *spoonName = [fileAndPath lastPathComponent];
        NSString *dstSpoonFullPath = [spoonPath stringByAppendingPathComponent:spoonName];

        if ([dstSpoonFullPath isEqualToString:fileAndPath]) {
            NSLog(@"User double clicked on a Spoon in %@, skipping", MJConfigDirAbsolute());
            return YES;
        }

        NSFileManager *fileManager = [NSFileManager defaultManager];

        // Remove any preexisting copy of the Spoon
        if ([fileManager fileExistsAtPath:dstSpoonFullPath]) {
            NSLog(@"Spoon already exists at %@, removing the old version", dstSpoonFullPath);
            upgrade = YES;
            success = [fileManager removeItemAtPath:dstSpoonFullPath error:&fileError];
            if (!success) {
                NSLog(@"Unable to remove existing Spoon (%@):%@", dstSpoonFullPath, fileError);
                NSAlert *alert = [[NSAlert alloc] init];
                [alert addButtonWithTitle:@"OK"];
                [alert setMessageText:@"Error upgrading Spoon"];
                [alert setInformativeText:[NSString stringWithFormat:@"%@\n\nSource: %@\nDest: %@", fileError.localizedDescription, fileAndPath, spoonPath]];
                [alert setAlertStyle:NSAlertStyleCritical];
                [alert runModal];
                return YES;
            }
        }


        success = [[NSFileManager defaultManager] moveItemAtPath:fileAndPath toPath:dstSpoonFullPath error:&fileError];
        if (!success) {
            NSLog(@"Unable to move %@ to %@: %@", fileAndPath, spoonPath, fileError);
            NSAlert *alert = [[NSAlert alloc] init];
            [alert addButtonWithTitle:@"OK"];
            [alert setMessageText:@"Error installing Spoon"];
            [alert setInformativeText:[NSString stringWithFormat:@"%@\n\nSource: %@\nDest: %@", fileError.localizedDescription, fileAndPath, spoonPath]];
            [alert setAlertStyle:NSAlertStyleCritical];
            [alert runModal];
        } else {
            NSUserNotification *notification = [[NSUserNotification alloc] init];
            notification.title = [NSString stringWithFormat:@"Spoon %@", upgrade ? @"upgraded" : @"installed"];
            notification.informativeText = [NSString stringWithFormat:@"%@ is now available%@", spoonName, upgrade ? @", reload your config" : @""];
            notification.soundName = NSUserNotificationDefaultSoundName;
            [[NSUserNotificationCenter defaultUserNotificationCenter] deliverNotification:notification];
        }
        return YES; // Note that we always return YES here because otherwise macOS tells the user that we can't open Spoons, which is ludicrous
    }

    NSString *fileExtension = [fileAndPath pathExtension];
    NSDictionary *infoDict = [[NSBundle mainBundle] infoDictionary];
    NSArray *supportedExtensions = [infoDict valueForKeyPath:@"CFBundleDocumentTypes.CFBundleTypeExtensions"];
    NSArray *flatSupportedExtensions = [supportedExtensions valueForKeyPath:@"@unionOfArrays.self"];

    // Files to be processed by hs.urlevent
    if ([flatSupportedExtensions containsObject:fileExtension]) {
        if (!self.openFileDelegate) {
            self.startupFile = fileAndPath;
        } else {
            if ([self.openFileDelegate respondsToSelector:@selector(callbackWithURL:senderPID:)]) {
                [self.openFileDelegate callbackWithURL:fileAndPath senderPID:-1];
            }
        }
    } else {
        // Trigger File Dropped to Dock Icon Callback
        fileDroppedToDockIcon(fileAndPath);
    }

    return YES;
}

- (BOOL)application:(NSApplication *)application
    continueUserActivity:(NSUserActivity *)userActivity
      restorationHandler:(nonnull void (^)(NSArray<id<NSUserActivityRestoring>> *_Nullable))restorationHandler
{
  //NSLog(@"Open URL in NSUserActivityTypeBrowsingWeb");
  if ([userActivity.activityType isEqualToString:NSUserActivityTypeBrowsingWeb]) {
    [[NSWorkspace sharedWorkspace] openURL:userActivity.webpageURL];
    return YES;
  }
  return NO;
}


- (void)applicationDidFinishLaunching:(NSNotification *)aNotification {
    BOOL isTesting = NO;

    // User is holding down Command (0x37) & Option (0x3A) keys:
    if (CGEventSourceKeyState(kCGEventSourceStateCombinedSessionState,0x3A) && CGEventSourceKeyState(kCGEventSourceStateCombinedSessionState,0x37)) {

        NSAlert *alert = [[NSAlert alloc] init];
        NSButton *deleteButton = [alert addButtonWithTitle:@"Delete Preferences"];
        deleteButton.hasDestructiveAction = YES;

        [alert addButtonWithTitle:@"Cancel"];
        [alert setMessageText:@"Do you want to delete the preferences?"];
        [alert setInformativeText:@"Deleting the preferences will reset all Hammerspoon settings (including everything that uses hs.settings) to their defaults. This does not remove anything in ~/.hammerspoon/"];
        [alert setAlertStyle:NSAlertStyleWarning];

        if ([alert runModal] == NSAlertFirstButtonReturn) {

            // Reset Preferences:
            NSDictionary * allObjects;
            allObjects = [[NSUserDefaults standardUserDefaults] dictionaryRepresentation];
            for(NSString *key in allObjects)
            {
                [[NSUserDefaults standardUserDefaults] removeObjectForKey: key];
            }
            [[NSUserDefaults standardUserDefaults] synchronize];

        }
    }

    [[NSDistributedNotificationCenter defaultCenter] addObserver:self selector:@selector(accessibilityChanged:) name:@"com.apple.accessibility.api" object:nil];

    // Remove our early event manager handler so hs.urlevent can register for it later, if the user has it configured to
    [[NSAppleEventManager sharedAppleEventManager] removeEventHandlerForEventClass:kInternetEventClass andEventID:kAEGetURL];

    if(NSClassFromString(@"XCTest") != nil) {
        // Hammerspoon Tests
        NSLog(@"in testing mode!");
        isTesting = YES;

        NSBundle *mainBundle = [NSBundle mainBundle];
        NSBundle *bundle = [NSBundle bundleWithPath:[NSString stringWithFormat:@"%@/Contents/Plugins/Hammerspoon Tests.xctest", mainBundle.bundlePath]];
        NSString *lsUnitPath = [bundle pathForResource:@"lsunit" ofType:@"lua"];
        const char *fsPath = [lsUnitPath fileSystemRepresentation];

        if (!fsPath) {
            NSLog(@"Unable to find lsunit.lua in Hammerspoon Tests.xctest. We're about to crash, sorry!");
            abort();
        } else {
            NSLog(@"testing lsunit.lua");
        }
        MJConfigFile = [[NSFileManager defaultManager] stringWithFileSystemRepresentation:fsPath length:strlen(fsPath)];
    } else if ([[[NSProcessInfo processInfo] environment] objectForKey:@"XCTESTING"]) {
        // Hammerspoon UI Tests
        NSLog(@"in UI testing mode");
        NSString *initPath = [[[NSFileManager defaultManager] currentDirectoryPath] stringByAppendingString:@"/Hammerspoon UI Tests-Runner.app/Contents/PlugIns/Hammerspoon UI Tests.xctest/Contents/Resources/init.lua"];
        const char *fsPath = [initPath fileSystemRepresentation];

        if (!fsPath) {
            NSLog(@"Unable to find init.lua in Hammerspoon UI Tests. We're about to crash, sorry!");
            abort();
        } else {
            NSLog(@"UI testing init.lua");
        }
        MJConfigFile = [[NSFileManager defaultManager] stringWithFileSystemRepresentation:fsPath length:strlen(fsPath)];
        [self showConsoleWindow:nil];
    } else {
        // No test environment detected, this is a live user run
        NSString* userMJConfigFile = [[NSUserDefaults standardUserDefaults] stringForKey:@"MJConfigFile"];
        if (userMJConfigFile) MJConfigFile = userMJConfigFile ;

        // Ensure we have a Spoons directory
        NSString *spoonsPath = [MJConfigDirAbsolute() stringByAppendingPathComponent:@"Spoons"];
        NSFileManager *fileManager = [NSFileManager defaultManager];
        BOOL spoonsPathIsDir;
        BOOL spoonsPathExists = [fileManager fileExistsAtPath:spoonsPath isDirectory:&spoonsPathIsDir];

        NSLog(@"Determined Spoons path will be: %@ (exists: %@, isDir: %@)", spoonsPath, spoonsPathExists ? @"YES" : @"NO", spoonsPathIsDir ? @"YES" : @"NO");

        if (spoonsPathExists && !spoonsPathIsDir) {
            NSLog(@"ERROR: %@ exists, but is a file", spoonsPath);
            abort();
        }

        if (!spoonsPathExists) {
            NSLog(@"Creating Spoons directory at: %@", spoonsPath);
            [[NSFileManager defaultManager] createDirectoryAtPath:spoonsPath withIntermediateDirectories:YES attributes:nil error:nil];
        }
    }

    // Become the handler for events from macOS Services
    [NSApp setServicesProvider:self];

    MJEnsureDirectoryExists(MJConfigDir());
    [[NSFileManager defaultManager] changeCurrentDirectoryPath:MJConfigDir()];

    [self registerDefaultDefaults];

    MJMenuIconSetup(self.menuBarMenu);
    MJDockIconSetup();
    [[MJConsoleWindowController singleton] setup];
    MJLuaCreate();

    if (!MJAccessibilityIsEnabled())
        [[MJPreferencesWindowController singleton] showWindow: nil];
}

// Dragging & Dropping of Text to Dock Item
-(void) processDockIconDraggedText:(NSPasteboard *)pboard userData:(NSString *)userData error:(NSString **)error {
    NSString *pboardString = [pboard stringForType:NSPasteboardTypeString];
    textDroppedToDockIcon(pboardString);
}

// Dragging & Dropping of File to Dock Item
-(void) processDockIconDraggedFile:(NSPasteboard *)pboard userData:(NSString *)userData error:(NSString **)error {
    NSArray *filePaths = [pboard propertyListForType:NSFilenamesPboardType];
    for (NSString *filePath in filePaths) {
        fileDroppedToDockIcon(filePath);
    }
}

- (void) accessibilityChanged:(NSNotification*)note {
    HSNSLOG(@"accessibilityChanged: %@", MJAccessibilityIsEnabled() ? @"ENABLED" : @"DISABLED");
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        callAccessibilityStateCallback();
    });
}

- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication *)sender {
    MJLuaDestroy();
    return NSTerminateNow;
}

- (void) registerDefaultDefaults {
    [[NSUserDefaults standardUserDefaults]
     registerDefaults: @{@"NSApplicationCrashOnExceptions": @YES,
                         MJShowDockIconKey: @NO,
                         MJShowMenuIconKey: @YES,
                         HSAutoLoadExtensions: @YES,

                         HSAppleScriptEnabledKey: @NO,
                         HSOpenConsoleOnDockClickKey: @YES,
                         HSPreferencesDarkModeKey: @NO,
                         HSConsoleDarkModeKey: @NO,
                         }];
}

- (IBAction) reloadConfig:(id)sender {
    MJLuaReplace();
}

- (IBAction) showConsoleWindow:(id)sender {
    [[NSApplication sharedApplication] activate];
    [[MJConsoleWindowController singleton] showWindow: nil];
}

- (IBAction) showPreferencesWindow:(id)sender {
    [[NSApplication sharedApplication] activate];
    [[MJPreferencesWindowController singleton] showWindow: nil];
}

- (IBAction) showAboutPanel:(id)sender {
    [[NSApplication sharedApplication] activate];
    @try {
        [[NSApplication sharedApplication] orderFrontStandardAboutPanel: nil];
    } @catch (NSException *exception) {
        [LuaSkin logError:@"Unable to open About dialog. This may mean your Hammerspoon installation is corrupt. Please re-install it!"];
    }
}

- (IBAction) quitHammerspoon:(id)sender {
    [[NSApplication sharedApplication] terminate:nil];
}

- (IBAction) openConfig:(id)sender {
    NSString* path = MJConfigFileFullPath();

    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
        [[NSFileManager defaultManager] createFileAtPath:path
                                                contents:[NSData data]
                                              attributes:nil];
    }

    NSWorkspace *workspace = [NSWorkspace sharedWorkspace];
    if ([workspace openFile:path] == NO) {
        // No app is associated with .lua files, so fall back on TextEdit
        [workspace openFile:path withApplication:@"TextEdit" andDeactivate:YES];
    }
}

@end

int main(int argc, const char * argv[]) {
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        MJAppDelegate *delegate = [[MJAppDelegate alloc] init];
        app.delegate = delegate;
        [app run];
    }
    return 0;
}
