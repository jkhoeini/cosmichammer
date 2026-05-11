@import Cocoa;
#import "MJDockIcon.h"
#import "variables.h"

static void reflect_defaults(void);

void MJDockIconSetup(void) {
    reflect_defaults();
}

BOOL MJDockIconVisible(void) {
    return [[NSUserDefaults standardUserDefaults] boolForKey:MJShowDockIconKey];
}

void MJDockIconSetVisible(BOOL visible) {
    [[NSUserDefaults standardUserDefaults] setBool:visible
                                            forKey:MJShowDockIconKey];
    reflect_defaults();
}

static void reflect_defaults(void) {
    NSApplication* app = [NSApplication sharedApplication];
    NSApplicationActivationPolicy currentPolicy = app.activationPolicy;
    NSApplicationActivationPolicy targetPolicy = MJDockIconVisible() ? NSApplicationActivationPolicyRegular : NSApplicationActivationPolicyAccessory;

    if (currentPolicy == targetPolicy) {
        // No need to do anything, we already have the policy we want
        return;
    }

    [app setActivationPolicy:targetPolicy];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [app unhide: nil];
        [app activate];
    });
}

//
// Open Console on Dock Icon Click:
//
BOOL HSOpenConsoleOnDockClickEnabled(void) {
    return [[NSUserDefaults standardUserDefaults] boolForKey:HSOpenConsoleOnDockClickKey];
}

void HSOpenConsoleOnDockClickSetEnabled(BOOL enabled) {
    [[NSUserDefaults standardUserDefaults] setBool:enabled
                                            forKey:HSOpenConsoleOnDockClickKey];
}
