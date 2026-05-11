// AUTO-GENERATED. DO NOT EDIT. Re-run scripts/generate-hsextensions.sh.
//
// Implements HSExtensionsRegisterAll(L), which inserts every bundled
// luaopen_hs_lib<name> into Lua's package.preload keyed by "hs.lib<name>".
// Call after lua_State creation and before setup.lua runs so require()
// resolves bundled modules without ever touching package.cpath.
#import "HSExtensions/HSExtensions.h"
#import "HSExtensions/HSExtensions+Preload.h"

#include <LuaSkin/lauxlib.h>

void HSExtensionsRegisterAll(lua_State *L) {
    static const struct { const char *name; lua_CFunction func; } preload[] = {
        { "hs.libbase64",        luaopen_hs_libbase64 },
        { "hs.libmath",          luaopen_hs_libmath },
        { "hs.libwindow",        luaopen_hs_libwindow },
        { NULL, NULL }
    };

    luaL_getsubtable(L, LUA_REGISTRYINDEX, LUA_PRELOAD_TABLE);
    for (size_t i = 0; preload[i].name; i++) {
        lua_pushcfunction(L, preload[i].func);
        lua_setfield(L, -2, preload[i].name);
    }
    lua_pop(L, 1);  // pop _PRELOAD table
}
