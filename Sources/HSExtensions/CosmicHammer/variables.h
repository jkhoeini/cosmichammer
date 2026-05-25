#define MJShowDockIconKey            @"MJShowDockIconKey"
#define MJShowMenuIconKey            @"MJShowMenuIconKey"
#define MJKeepConsoleOnTopKey        @"MJKeepConsoleOnTopKey"
#define MJHasRunAlreadyKey           @"MJHasRunAlreadyKey"
#define HSAutoLoadExtensions         @"HSAutoLoadExtensions"
#define HSAppleScriptEnabledKey      @"HSAppleScriptEnabledKey"
#define HSOpenConsoleOnDockClickKey  @"HSOpenConsoleOnDockClickKey"
#define HSConsoleDarkModeKey         @"HSConsoleDarkModeKey"
#define HSPreferencesDarkModeKey     @"HSPreferencesDarkModeKey"

extern NSString* MJConfigFileGet(void);
extern void MJConfigFileSet(NSString* path);
#define MJConfigFile MJConfigFileGet()
