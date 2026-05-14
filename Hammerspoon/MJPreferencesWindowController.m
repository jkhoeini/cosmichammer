#import "MJPreferencesWindowController.h"
#import "MJAutoLaunch.h"
#import "MJLua.h"
#import "MJDockIcon.h"
#import "MJMenuIcon.h"
#import "MJAccessibilityUtils.h"
#import "MJConsoleWindowController.h"
#import "variables.h"

//
// Enable & Disable Preferences Dark Mode:
//
BOOL PreferencesDarkModeEnabled(void) {
    return [[NSUserDefaults standardUserDefaults] boolForKey:HSPreferencesDarkModeKey];
}

void PreferencesDarkModeSetEnabled(BOOL enabled) {
    [[NSUserDefaults standardUserDefaults] setBool:enabled
                                            forKey:HSPreferencesDarkModeKey];
}


#define MJSkipDockMenuIconProblemAlertKey @"MJSkipDockMenuIconProblemAlertKey"

@interface MJPreferencesWindowController ()

@property (strong) NSButton* openAtLoginCheckbox;
@property (strong) NSButton* showDockIconCheckbox;
@property (strong) NSButton* showMenuIconCheckbox;
@property (strong) NSButton* keepConsoleOnTopCheckbox;

@property BOOL isAccessibilityEnabled;

@end

@implementation MJPreferencesWindowController

+ (instancetype) singleton {
    static MJPreferencesWindowController* s;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        s = [[MJPreferencesWindowController alloc] init];
    });
    return s;
}

- (void) setup {
    [self reflectDefaults];
}

- (void) reflectDefaults {
    
    //
    // Dark Mode:
    //
    if (PreferencesDarkModeEnabled()) {
        self.window.appearance = [NSAppearance appearanceNamed: NSAppearanceNameVibrantDark] ;
        self.window.titlebarAppearsTransparent = YES ;
    } else {
        self.window.appearance = [NSAppearance appearanceNamed: NSAppearanceNameVibrantLight] ;
        self.window.titlebarAppearsTransparent = NO ;
    }
    
}

- (void)updateFeedbackDisplay:(NSNotification __unused *)notification {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.openAtLoginCheckbox setState:MJAutoLaunchGet() ? NSControlStateValueOn : NSControlStateValueOff];
        [self.showDockIconCheckbox setState: MJDockIconVisible() ? NSControlStateValueOn : NSControlStateValueOff];
        [self.showMenuIconCheckbox setState: MJMenuIconVisible() ? NSControlStateValueOn : NSControlStateValueOff];
        [self.keepConsoleOnTopCheckbox setState: MJConsoleWindowAlwaysOnTop() ? NSControlStateValueOn : NSControlStateValueOff];
    });
}

- (void) showWindow:(id)sender {
    if (![[self window] isVisible])
        [[self window] center];
    [super showWindow: sender];
    [self reflectDefaults];
}

- (void)loadWindow {
    // --- Panel ---
    NSPanel *panel = [[NSPanel alloc] initWithContentRect:NSMakeRect(957, 580, 357, 246)
                                                styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable)
                                                  backing:NSBackingStoreBuffered
                                                    defer:YES];
    panel.title = @"Hammerspoon Preferences";
    panel.releasedWhenClosed = NO;
    panel.frameAutosaveName = @"prefs";
    panel.titlebarAppearsTransparent = YES;
    panel.titleVisibility = NSWindowTitleHidden;
    panel.animationBehavior = NSWindowAnimationBehaviorDefault;

    // --- Visual effect view as the content view ---
    NSVisualEffectView *effectView = [[NSVisualEffectView alloc] initWithFrame:panel.contentView.bounds];
    effectView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    effectView.blendingMode = NSVisualEffectBlendingModeBehindWindow;
    effectView.material = NSVisualEffectMaterialUnderWindowBackground;
    effectView.state = NSVisualEffectStateFollowsWindowActiveState;
    effectView.translatesAutoresizingMaskIntoConstraints = NO;

    // Replace the content view's subview hierarchy — pin the effect view to fill
    NSView *contentView = panel.contentView;
    [contentView addSubview:effectView];
    [NSLayoutConstraint activateConstraints:@[
        [effectView.topAnchor constraintEqualToAnchor:contentView.topAnchor],
        [effectView.bottomAnchor constraintEqualToAnchor:contentView.bottomAnchor],
        [effectView.leadingAnchor constraintEqualToAnchor:contentView.leadingAnchor],
        [effectView.trailingAnchor constraintEqualToAnchor:contentView.trailingAnchor],
    ]];

    // --- "Behavior:" label ---
    NSTextField *behaviorLabel = [NSTextField labelWithString:@"Behavior:"];
    behaviorLabel.translatesAutoresizingMaskIntoConstraints = NO;
    behaviorLabel.alignment = NSTextAlignmentRight;
    behaviorLabel.font = [NSFont systemFontOfSize:0]; // system default size
    [effectView addSubview:behaviorLabel];

    // --- Checkboxes ---
    NSButton *openAtLogin = [NSButton checkboxWithTitle:@"Launch Hammerspoon at login"
                                                 target:self
                                                 action:@selector(toggleOpensAtLogin:)];
    openAtLogin.translatesAutoresizingMaskIntoConstraints = NO;
    [effectView addSubview:openAtLogin];
    self.openAtLoginCheckbox = openAtLogin;

    NSButton *showDock = [NSButton checkboxWithTitle:@"Show dock icon"
                                              target:self
                                              action:@selector(toggleShowDockIcon:)];
    showDock.translatesAutoresizingMaskIntoConstraints = NO;
    [effectView addSubview:showDock];
    self.showDockIconCheckbox = showDock;

    NSButton *showMenu = [NSButton checkboxWithTitle:@"Show menu icon"
                                              target:self
                                              action:@selector(toggleMenuDockIcon:)];
    showMenu.translatesAutoresizingMaskIntoConstraints = NO;
    [effectView addSubview:showMenu];
    self.showMenuIconCheckbox = showMenu;

    NSButton *keepOnTop = [NSButton checkboxWithTitle:@"Keep Console window on top"
                                               target:self
                                               action:@selector(toggleKeepConsoleOnTop:)];
    keepOnTop.translatesAutoresizingMaskIntoConstraints = NO;
    [effectView addSubview:keepOnTop];
    self.keepConsoleOnTopCheckbox = keepOnTop;

    // --- "Accessibility:" label ---
    NSTextField *accessibilityLabel = [NSTextField labelWithString:@"Accessibility:"];
    accessibilityLabel.translatesAutoresizingMaskIntoConstraints = NO;
    accessibilityLabel.alignment = NSTextAlignmentRight;
    accessibilityLabel.font = [NSFont systemFontOfSize:0];
    [effectView addSubview:accessibilityLabel];

    // --- Accessibility status text (bound) ---
    NSTextField *statusText = [NSTextField labelWithString:@""];
    statusText.translatesAutoresizingMaskIntoConstraints = NO;
    statusText.font = [NSFont systemFontOfSize:0];
    [statusText bind:NSValueBinding toObject:self withKeyPath:@"maybeEnableAccessibilityString" options:nil];
    [effectView addSubview:statusText];

    // --- "Enable Accessibility" button (bound) ---
    NSButton *enableAccessButton = [[NSButton alloc] initWithFrame:NSZeroRect];
    enableAccessButton.translatesAutoresizingMaskIntoConstraints = NO;
    enableAccessButton.title = @"Enable Accessibility";
    enableAccessButton.bezelStyle = NSBezelStyleRounded;
    enableAccessButton.target = self;
    enableAccessButton.action = @selector(openAccessibility:);
    [enableAccessButton bind:NSEnabledBinding toObject:self withKeyPath:@"isAccessibilityEnabled"
                     options:@{ NSValueTransformerNameBindingOption: NSNegateBooleanTransformerName }];
    [effectView addSubview:enableAccessButton];

    // --- Status dot image view (bound) ---
    NSImageView *statusDot = [[NSImageView alloc] initWithFrame:NSZeroRect];
    statusDot.translatesAutoresizingMaskIntoConstraints = NO;
    [statusDot bind:NSValueBinding toObject:self withKeyPath:@"isAccessibilityEnabledImage" options:nil];
    [effectView addSubview:statusDot];

    // --- Auto Layout constraints ---
    [NSLayoutConstraint activateConstraints:@[
        // "Behavior:" label — top-left
        [behaviorLabel.topAnchor constraintEqualToAnchor:effectView.topAnchor constant:20],
        [behaviorLabel.leadingAnchor constraintEqualToAnchor:effectView.leadingAnchor constant:20],

        // First checkbox aligns baseline with "Behavior:" label, 8pt after label trailing
        [openAtLogin.bottomAnchor constraintEqualToAnchor:behaviorLabel.bottomAnchor constant:-1],
        [openAtLogin.leadingAnchor constraintEqualToAnchor:behaviorLabel.trailingAnchor constant:8],

        // Remaining checkboxes stack vertically with 6pt spacing
        [showDock.topAnchor constraintEqualToAnchor:openAtLogin.bottomAnchor constant:6],
        [showDock.leadingAnchor constraintEqualToAnchor:behaviorLabel.trailingAnchor constant:8],

        [showMenu.topAnchor constraintEqualToAnchor:showDock.bottomAnchor constant:6],
        [showMenu.leadingAnchor constraintEqualToAnchor:behaviorLabel.trailingAnchor constant:8],

        [keepOnTop.topAnchor constraintEqualToAnchor:showMenu.bottomAnchor constant:6],
        [keepOnTop.leadingAnchor constraintEqualToAnchor:behaviorLabel.trailingAnchor constant:8],

        // "Accessibility:" label — below last checkbox, right-aligned with "Behavior:" label
        [accessibilityLabel.topAnchor constraintEqualToAnchor:keepOnTop.bottomAnchor constant:8],
        [accessibilityLabel.leadingAnchor constraintEqualToAnchor:effectView.leadingAnchor constant:20],
        [accessibilityLabel.trailingAnchor constraintEqualToAnchor:behaviorLabel.trailingAnchor],

        // Status text vertically centered with "Accessibility:" label
        [statusText.centerYAnchor constraintEqualToAnchor:accessibilityLabel.centerYAnchor],
        [statusText.leadingAnchor constraintEqualToAnchor:accessibilityLabel.trailingAnchor constant:8],
        [statusText.trailingAnchor constraintEqualToAnchor:effectView.trailingAnchor constant:-20],

        // "Enable Accessibility" button below status text, aligned to its leading
        [enableAccessButton.topAnchor constraintEqualToAnchor:statusText.bottomAnchor constant:8],
        [enableAccessButton.leadingAnchor constraintEqualToAnchor:statusText.leadingAnchor],
        [enableAccessButton.widthAnchor constraintEqualToConstant:200],

        // Status dot centered vertically with the button, 8pt to its right
        [statusDot.centerYAnchor constraintEqualToAnchor:enableAccessButton.centerYAnchor],
        [statusDot.leadingAnchor constraintEqualToAnchor:enableAccessButton.trailingAnchor constant:8],
        [statusDot.widthAnchor constraintEqualToConstant:16],
        [statusDot.heightAnchor constraintEqualToConstant:16],
    ]];

    // --- Assign the window ---
    [self setWindow:panel];

    // --- Post-load setup (equivalent of windowDidLoad) ---
    dispatch_async(dispatch_get_main_queue(), ^{
        [self cacheIsAccessibilityEnabled];
    });

    [[NSDistributedNotificationCenter defaultCenter] addObserver:self selector:@selector(accessibilityChanged:) name:@"com.apple.accessibility.api" object:nil];

    [self.openAtLoginCheckbox setState:MJAutoLaunchGet() ? NSControlStateValueOn : NSControlStateValueOff];
    [self.showDockIconCheckbox setState: MJDockIconVisible() ? NSControlStateValueOn : NSControlStateValueOff];
    [self.showMenuIconCheckbox setState: MJMenuIconVisible() ? NSControlStateValueOn : NSControlStateValueOff];
    [self.keepConsoleOnTopCheckbox setState: MJConsoleWindowAlwaysOnTop() ? NSControlStateValueOn : NSControlStateValueOff];

    NSNotificationCenter *changeWatcher = [NSNotificationCenter defaultCenter];
    [changeWatcher addObserver:self
                      selector:@selector(updateFeedbackDisplay:)
                          name:NSUserDefaultsDidChangeNotification
                        object:nil];
}

- (void) accessibilityChanged:(NSNotification*)note {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self cacheIsAccessibilityEnabled];
    });
}

- (void) cacheIsAccessibilityEnabled {
    self.isAccessibilityEnabled = MJAccessibilityIsEnabled();
}

- (NSString*) maybeEnableAccessibilityString {
    if (self.isAccessibilityEnabled)
        return @"Accessibility is enabled. You're all set!";
    else
        return @"WARNING! Accessibility is not enabled!";
}

- (NSImage*) isAccessibilityEnabledImage {
    if (self.isAccessibilityEnabled)
        return [NSImage imageNamed:NSImageNameStatusAvailable];
    else
        return [NSImage imageNamed:NSImageNameStatusUnavailable];
}

+ (NSSet*) keyPathsForValuesAffectingMaybeEnableAccessibilityString {
    return [NSSet setWithArray:@[@"isAccessibilityEnabled"]];
}

+ (NSSet*) keyPathsForValuesAffectingIsAccessibilityEnabledImage {
    return [NSSet setWithArray:@[@"isAccessibilityEnabled"]];
}

- (IBAction) openAccessibility:(id)sender {
    MJAccessibilityOpenPanel();
}

- (IBAction) toggleOpensAtLogin:(NSButton*)sender {
    BOOL enabled = [sender state] == NSControlStateValueOn;
    MJAutoLaunchSet(enabled);
}

- (IBAction) toggleShowDockIcon:(NSButton*)sender {
    [[self class] cancelPreviousPerformRequestsWithTarget:self selector:@selector(actuallyToggleShowDockIcon) object:nil];
    [self performSelector:@selector(actuallyToggleShowDockIcon) withObject:nil afterDelay:0.3];
}

- (void) actuallyToggleShowDockIcon {
    BOOL enabled = [self.showDockIconCheckbox state] == NSControlStateValueOn;
    MJDockIconSetVisible(enabled);
    [self maybeWarnAboutDockMenuProblem];
}

- (IBAction) toggleMenuDockIcon:(NSButton*)sender {
    BOOL enabled = [sender state] == NSControlStateValueOn;
    MJMenuIconSetVisible(enabled);
    [self maybeWarnAboutDockMenuProblem];
}

- (IBAction) toggleKeepConsoleOnTop:(id)sender {
    MJConsoleWindowSetAlwaysOnTop([sender state] == NSControlStateValueOn);
}

- (void) dockMenuProblemAlertDidEnd:(NSAlert *)alert returnCode:(NSInteger)returnCode contextInfo:(void *)contextInfo {
    BOOL skipNextTime = ([[alert suppressionButton] state] == NSControlStateValueOn);
    [[NSUserDefaults standardUserDefaults] setBool:skipNextTime forKey:MJSkipDockMenuIconProblemAlertKey];
}

- (void) maybeWarnAboutDockMenuProblem {
    if (MJMenuIconVisible() || MJDockIconVisible())
        return;

    if ([[NSUserDefaults standardUserDefaults] boolForKey:MJSkipDockMenuIconProblemAlertKey])
        return;

    NSAlert* alert = [[NSAlert alloc] init];
    [alert setAlertStyle:NSAlertStyleWarning];
    [alert setMessageText:@"How to get back to this window"];
    [alert setInformativeText:@"When both the dock icon and menu icon are disabled, you can get back to this Preferences window by activating Hammerspoon from Spotlight or by running `open -a Hammerspoon` from Terminal, and then pressing Command + Comma."];
    [alert setShowsSuppressionButton:YES];
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    [alert beginSheetModalForWindow:[self window]
                      modalDelegate:self
                     didEndSelector:@selector(dockMenuProblemAlertDidEnd:returnCode:contextInfo:)
                        contextInfo:NULL];
#pragma clang diagnostic pop
}

@end
