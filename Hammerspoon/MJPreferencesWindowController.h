#import <Cocoa/Cocoa.h>

@interface MJPreferencesWindowController : NSWindowController

+ (instancetype) singleton;
- (void) setup;

@end

//
// Enable & Disable Preferences Dark Mode:
//
BOOL PreferencesDarkModeEnabled(void);
void PreferencesDarkModeSetEnabled(BOOL enabled);
