#!/usr/bin/env bash
# Regenerates HSExtensions glue files.
#
# Reads the list of `luaopen_hs_lib*` symbols (one per line) from
# Packages/HSExtensions/extensions.list and emits three generated files:
#
#   1. Packages/HSExtensions/Sources/HSExtensions/HSExtensions+Preload.h
#      Forward declarations for each luaopen_hs_lib* symbol.
#
#   2. Packages/HSExtensions/Sources/HSExtensions/HSExtensions.m
#      Implementation of HSExtensionsRegisterAll, which inserts each
#      luaopen_hs_lib<name> into Lua's package.preload keyed by
#      "hs.lib<name>".
#
#   3. Hammerspoon/HSExtensionsRegistry.m
#      Keep-alive array in the main app target. The static linker pulls each
#      referenced object out of libHSExtensions.a so the `luaopen_*`
#      functions don't get dead-stripped.
#
# Re-run this script whenever you add or remove an extension entry-point.
# The script is idempotent: running it twice produces the same output.
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"

LIST_FILE="Packages/HSExtensions/extensions.list"
OUT_PRELOAD_H="Packages/HSExtensions/Sources/HSExtensions/include/HSExtensions/HSExtensions+Preload.h"
OUT_REGISTER_M="Packages/HSExtensions/Sources/HSExtensions/HSExtensions.m"
OUT_KEEPALIVE_M="Hammerspoon/HSExtensionsRegistry.m"

if [[ ! -f "$LIST_FILE" ]]; then
    echo "error: extensions list not found: $LIST_FILE" >&2
    echo "expected one luaopen_hs_lib* symbol per line." >&2
    exit 1
fi

symbols=()
while IFS= read -r line; do
    # strip whitespace and skip blank / comment lines
    sym="${line%%#*}"
    sym="${sym//[[:space:]]/}"
    [[ -z "$sym" ]] && continue
    symbols+=("$sym")
done < "$LIST_FILE"

if [[ ${#symbols[@]} -eq 0 ]]; then
    echo "error: no symbols found in $LIST_FILE" >&2
    exit 1
fi

count="${#symbols[@]}"
echo "Generating glue for ${count} symbols..."

# Compute the longest symbol length for column alignment in HSExtensions.m
maxlen=0
for sym in "${symbols[@]}"; do
    if (( ${#sym} > maxlen )); then maxlen=${#sym}; fi
done
pad=$((maxlen + 2))

# -- 1. Preload header ----------------------------------------------------------
{
    cat <<'HDR'
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

HDR
    for sym in "${symbols[@]}"; do
        printf 'int %s(lua_State *L);\n' "$sym"
    done
    cat <<'HDR'

#ifdef __cplusplus
}
#endif
HDR
} > "$OUT_PRELOAD_H"

# -- 2. Register implementation -------------------------------------------------
{
    cat <<'HDR'
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
HDR
    for sym in "${symbols[@]}"; do
        # luaopen_hs_libwindow -> hs.libwindow
        modname="hs.${sym#luaopen_hs_}"
        # left-justify quoted module name to align func column
        quoted="\"${modname}\","
        printf '        { %-*s %s },\n' "$pad" "$quoted" "$sym"
    done
    cat <<'HDR'
        { NULL, NULL }
    };

    luaL_getsubtable(L, LUA_REGISTRYINDEX, LUA_PRELOAD_TABLE);
    for (size_t i = 0; preload[i].name; i++) {
        lua_pushcfunction(L, preload[i].func);
        lua_setfield(L, -2, preload[i].name);
    }
    lua_pop(L, 1);  // pop _PRELOAD table
}
HDR
} > "$OUT_REGISTER_M"

# -- 3. Keep-alive registry (main app target) -----------------------------------
{
    cat <<'HDR'
// AUTO-GENERATED. DO NOT EDIT. Re-run scripts/generate-hsextensions.sh.
//
// Purpose: prevent the static linker from dead-stripping the luaopen_hs_*
// entry points out of libHSExtensions.a. Each symbol is referenced from a
// __used array so the linker keeps the archive object alive.
#import <HSExtensions/HSExtensions+Preload.h>

__attribute__((used))
static void * const _HSExtensionsKeepAlive[] = {
HDR
    for sym in "${symbols[@]}"; do
        printf '    (void *)&%s,\n' "$sym"
    done
    cat <<'HDR'
};
HDR
} > "$OUT_KEEPALIVE_M"

echo "  wrote $OUT_PRELOAD_H"
echo "  wrote $OUT_REGISTER_M"
echo "  wrote $OUT_KEEPALIVE_M"
