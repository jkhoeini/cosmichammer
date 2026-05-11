// HSExtensions.h
//
// Public entry point for the consolidated HSExtensions static library.
// All bundled hs.lib<name> entry points are registered into Lua's
// package.preload by HSExtensionsRegisterAll, which the main app calls
// after Lua state creation and before setup.lua runs.

#pragma once
#include <LuaSkin/lua.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Registers every bundled hs.lib<name> entry point with package.preload.
/// Call after lua_State creation and before setup.lua runs.
void HSExtensionsRegisterAll(lua_State *L);

#ifdef __cplusplus
}
#endif
