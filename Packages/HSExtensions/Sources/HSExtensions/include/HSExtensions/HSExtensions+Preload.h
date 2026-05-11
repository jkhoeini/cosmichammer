// AUTO-GENERATED. DO NOT EDIT. Re-run scripts/generate-hsextensions.sh.
//
// Forward declarations for every luaopen_hs_lib<name> entry point that the
// HSExtensions static library exposes. The keep-alive registry array in the
// main app target references these symbols so the static linker doesn't
// dead-strip them out of libHSExtensions.a.
#pragma once
#include <LuaSkin/lua.h>

#ifdef __cplusplus
extern "C" {
#endif

int luaopen_hs_libbase64(lua_State *L);
int luaopen_hs_libmath(lua_State *L);
int luaopen_hs_libwindow(lua_State *L);

#ifdef __cplusplus
}
#endif
