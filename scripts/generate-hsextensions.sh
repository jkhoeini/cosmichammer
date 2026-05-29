#!/usr/bin/env bash
# Regenerates HSExtensions glue files.
#
# Reads entry-point symbols from the unified manifest
# extensions.manifest and emits two generated files:
#
#   1. Sources/HSExtensions/include/HSExtensions/HSExtensions+Preload.h
#      Forward declarations for each luaopen_hs_lib* symbol.
#      Still needed so C/ObjC compilation units can reference these symbols.
#
#   2. Sources/HSSwiftExtensions/HSExtensionsGenerated.swift
#      Implementation of hsExtensionsRegisterAll(_:), which inserts each
#      luaopen_hs_lib<name> into Lua's package.preload keyed by
#      "hs.lib<name>".  All entry points are imported via @_silgen_name
#      so the Swift function name is decoupled from the C symbol name.
#
# Re-run this script whenever you add or remove an extension entry-point.
# The script is idempotent: running it twice produces the same output.
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"

MANIFEST="extensions.manifest"
OUT_PRELOAD_H="Sources/HSExtensions/include/HSExtensions/HSExtensions+Preload.h"
OUT_SWIFT="Sources/HSSwiftExtensions/HSExtensionsGenerated.swift"

if [[ ! -f "$MANIFEST" ]]; then
    echo "error: manifest not found: $MANIFEST" >&2
    exit 1
fi

# Extract entry-point symbols from column 2 of the manifest.
# Skip comment/blank lines and lines where column 2 is "-" (Lua-only).
symbols=()
while IFS=$'\t' read -r _dir entry_points _lua; do
    # strip comments and whitespace
    _dir="${_dir%%#*}"
    _dir="${_dir//[[:space:]]/}"
    [[ -z "$_dir" ]] && continue
    [[ "$entry_points" == "-" ]] && continue
    # split comma-separated symbols
    IFS=',' read -ra syms <<< "$entry_points"
    for sym in "${syms[@]}"; do
        sym="${sym//[[:space:]]/}"
        [[ -n "$sym" ]] && symbols+=("$sym")
    done
done < "$MANIFEST"

if [[ ${#symbols[@]} -eq 0 ]]; then
    echo "error: no symbols found in $MANIFEST" >&2
    exit 1
fi

# Sort symbols alphabetically for deterministic output.
IFS=$'\n' symbols=($(sort <<<"${symbols[*]}")); unset IFS

count="${#symbols[@]}"
echo "Generating glue for ${count} symbols..."

# -- 1. Preload header ----------------------------------------------------------
{
    cat <<'HDR'
// AUTO-GENERATED. DO NOT EDIT. Re-run scripts/generate-hsextensions.sh.
//
// Forward declarations for every luaopen_hs_lib<name> entry point that the
// HSExtensions static library exposes.  Needed so C/ObjC compilation units
// can reference these symbols.
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

# -- 2. Swift registration implementation ---------------------------------------
{
    cat <<'HDR'
// AUTO-GENERATED. DO NOT EDIT. Re-run scripts/generate-hsextensions.sh.
//
// Registers all bundled extension entry points into Lua's package.preload table.
// Call after lua_State creation and before setup.lua runs.
//
// Every entry point is imported via @_silgen_name so the Swift function name
// is decoupled from the C symbol name (handles both @_cdecl Swift funcs and
// C-implemented funcs like lsqlite3).
import CLua

// MARK: - Forward declarations (C symbol imports)

HDR
    for sym in "${symbols[@]}"; do
        printf '@_silgen_name("%s")\n' "$sym"
        printf 'private func _import_%s(_ L: UnsafeMutablePointer<lua_State>!) -> Int32\n\n' "$sym"
    done

    cat <<'HDR'
// MARK: - Registration

/// Registers every bundled hs.lib<name> entry point with package.preload.
/// Call after lua_State creation and before setup.lua runs.
@_cdecl("HSExtensionsRegisterAll")
func hsExtensionsRegisterAll(_ L: UnsafeMutablePointer<lua_State>!) {
    let preload: [(String, @convention(c) (UnsafeMutablePointer<lua_State>?) -> Int32)] = [
HDR
    for sym in "${symbols[@]}"; do
        # luaopen_hs_libwindow -> hs.libwindow
        modname="hs.${sym#luaopen_hs_}"
        printf '        ("%s", _import_%s),\n' "$modname" "$sym"
    done
    # Use the Swift-available constant for LUA_REGISTRYINDEX.
    cat <<'HDR'
    ]

    luaL_getsubtable(L, LUA_REGISTRYINDEX_VALUE, "_PRELOAD")
    for (name, fn) in preload {
        lua_pushcclosure(L, fn, 0)
        lua_setfield(L, -2, name)
    }
    lua_pop(L, 1)
}
HDR
} > "$OUT_SWIFT"

echo "  wrote $OUT_PRELOAD_H"
echo "  wrote $OUT_SWIFT"
