// AUTO-GENERATED. DO NOT EDIT. Re-run scripts/generate-hsextensions.sh.
#import "HSExtensions/HSExtensions.h"
#import "HSExtensions+Preload.h"

#include <LuaSkin/lauxlib.h>

void HSExtensionsRegisterAll(lua_State *L) {
    static const struct { const char *name; lua_CFunction func; } preload[] = {
        // (no entries yet — Phase 1 scaffold; regenerated per scripts/generate-hsextensions.sh)
        { NULL, NULL }
    };

    luaL_getsubtable(L, LUA_REGISTRYINDEX, LUA_PRELOAD_TABLE);
    for (size_t i = 0; preload[i].name; i++) {
        lua_pushcfunction(L, preload[i].func);
        lua_setfield(L, -2, preload[i].name);
    }
    lua_pop(L, 1);  // pop _PRELOAD table
}
