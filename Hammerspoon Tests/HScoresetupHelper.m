#import "HScoresetupHelper.h"
#import "MJLua.h"

static BOOL testFlag = NO;

static int verifyShutdown(lua_State *L) {
    testFlag = YES;
    return 0;
}

@implementation HScoresetupHelper

+ (void)registerShutdownLib {
    luaL_Reg shutdownLib[] = {
        {"verifyShutdown", verifyShutdown},
        {NULL, NULL}
    };
    LuaSkin *skin = [LuaSkin sharedWithState:NULL];
    [skin registerLibrary:"shutdownLib" functions:shutdownLib metaFunctions:nil];
    lua_setglobal(skin.L, "shutdownLib");
}

+ (BOOL)shutdownFired {
    return testFlag;
}

+ (void)resetShutdownFlag {
    testFlag = NO;
}

@end
