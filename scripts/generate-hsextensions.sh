#!/usr/bin/env bash
# Regenerates HSExtensions glue and Lua loader metadata from extensions.manifest.
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"
repo_physical_root="$(pwd -P)"

MANIFEST="extensions.manifest"
OUT_PRELOAD_H="Sources/HSExtensions/include/HSExtensions/HSExtensions+Preload.h"
OUT_SWIFT="Sources/HSSwiftExtensions/HSExtensionsGenerated.swift"
OUT_LOADER_METADATA="extensions/_coresetup/_loader_metadata.lua"
OUT_COPY_MAP="extensions/_coresetup/_loader_copy_map.tsv"

if [[ ! -f "$MANIFEST" ]]; then
    echo "error: manifest not found: $MANIFEST" >&2
    exit 1
fi

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

native_tsv="$tmpdir/native.tsv"
lua_tsv="$tmpdir/lua.tsv"
aliases_tsv="$tmpdir/aliases.tsv"
native_by_symbol="$tmpdir/native-by-symbol.tsv"
native_by_key="$tmpdir/native-by-key.tsv"
lua_by_module="$tmpdir/lua-by-module.tsv"
lua_by_bundle="$tmpdir/lua-by-bundle.tsv"
aliases_by_public="$tmpdir/aliases-by-public.tsv"
native_keys="$tmpdir/native-keys.txt"
lua_module_names="$tmpdir/lua-modules.txt"
alias_publics="$tmpdir/alias-publics.txt"
lazy_extensions="$tmpdir/lazy-extensions.txt"

: > "$native_tsv"
: > "$lua_tsv"
: > "$aliases_tsv"

trim() {
    local value="$1"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    printf '%s' "$value"
}

die_manifest() {
    local line="$1"
    local message="$2"
    echo "error: $MANIFEST:$line: $message" >&2
    exit 1
}

is_safe_relative_path() {
    local path="$1"
    local component
    [[ -n "$path" && "$path" != /* ]] || return 1

    local IFS='/'
    for component in $path; do
        [[ -n "$component" && "$component" != "." && "$component" != ".." ]] || return 1
    done
}

parse_native_preloads() {
    local line_no="$1"
    local spec="$2"

    [[ "$spec" == "-" ]] && return
    IFS=',' read -ra items <<< "$spec"
    for item in "${items[@]}"; do
        item="$(trim "$item")"
        [[ -z "$item" ]] && continue
        [[ "$item" == *=* ]] || die_manifest "$line_no" "native preload must be package-key=luaopen_symbol: $item"
        local key="${item%%=*}"
        local symbol="${item#*=}"
        key="$(trim "$key")"
        symbol="$(trim "$symbol")"
        [[ "$key" == hs.* ]] || die_manifest "$line_no" "native preload key must start with hs.: $key"
        [[ "$symbol" == luaopen_* ]] || die_manifest "$line_no" "native symbol must start with luaopen_: $symbol"
        printf '%s\t%s\n' "$symbol" "$key" >> "$native_tsv"
    done
}

parse_lua_modules() {
    local line_no="$1"
    local scope="$2"
    local spec="$3"

    [[ "$spec" == "-" ]] && return
    IFS=',' read -ra items <<< "$spec"
    for item in "${items[@]}"; do
        item="$(trim "$item")"
        [[ -z "$item" ]] && continue
        [[ "$item" == *=* ]] || die_manifest "$line_no" "Lua module must be module=source>bundle-path: $item"
        local module="${item%%=*}"
        local rest="${item#*=}"
        [[ "$rest" == *">"* ]] || die_manifest "$line_no" "Lua module must include source>bundle-path: $item"
        local source="${rest%%>*}"
        local bundle_path="${rest#*>}"
        module="$(trim "$module")"
        source="$(trim "$source")"
        bundle_path="$(trim "$bundle_path")"
        [[ "$module" == hs.* ]] || die_manifest "$line_no" "Lua module name must start with hs.: $module"
        is_safe_relative_path "$source" || die_manifest "$line_no" "source must be a safe repo-relative path: $source"
        is_safe_relative_path "$bundle_path" || die_manifest "$line_no" "bundle path must be relative to extensions/hs: $bundle_path"
        local full_bundle_path="hs/${bundle_path}"
        if [[ "$scope" == @* ]]; then
            printf '%s\t%s\t%s\n' "$module" "$source" "$full_bundle_path" >> "$lua_tsv"
        else
            printf '%s\t%s\t%s\n' "$module" "extensions/${scope}/${source}" "$full_bundle_path" >> "$lua_tsv"
        fi
    done
}

parse_aliases() {
    local line_no="$1"
    local spec="$2"

    [[ "$spec" == "-" ]] && return
    IFS=',' read -ra items <<< "$spec"
    for item in "${items[@]}"; do
        item="$(trim "$item")"
        [[ -z "$item" ]] && continue
        [[ "$item" == *=* ]] || die_manifest "$line_no" "alias must be public-module=target-module: $item"
        local public="${item%%=*}"
        local target="${item#*=}"
        public="$(trim "$public")"
        target="$(trim "$target")"
        [[ "$public" == hs.* ]] || die_manifest "$line_no" "alias public module must start with hs.: $public"
        [[ "$target" == hs.* ]] || die_manifest "$line_no" "alias target module must start with hs.: $target"
        printf '%s\t%s\n' "$public" "$target" >> "$aliases_tsv"
    done
}

line_no=0
while IFS=$'\t' read -r scope native_preloads lua_modules aliases extra || [[ -n "${scope:-}" ]]; do
    line_no=$((line_no + 1))
    scope="$(trim "${scope:-}")"
    [[ -z "$scope" ]] && continue
    [[ "$scope" == \#* ]] && continue
    [[ -z "${extra:-}" ]] || die_manifest "$line_no" "expected exactly 4 tab-separated columns"
    if [[ "$scope" == @* ]]; then
        [[ "${#scope}" -gt 1 && "$scope" != *"/"* ]] || die_manifest "$line_no" "special scope must be @name without path separators: $scope"
    else
        [[ -n "$scope" && "$scope" != "." && "$scope" != ".." && "$scope" != *"/"* ]] || die_manifest "$line_no" "scope must be an extension folder name: $scope"
    fi

    native_preloads="$(trim "${native_preloads:-}")"
    lua_modules="$(trim "${lua_modules:-}")"
    aliases="$(trim "${aliases:-}")"
    [[ -n "$native_preloads" ]] || die_manifest "$line_no" "missing native-preloads column"
    [[ -n "$lua_modules" ]] || die_manifest "$line_no" "missing lua-modules column"
    [[ -n "$aliases" ]] || die_manifest "$line_no" "missing aliases column"

    parse_native_preloads "$line_no" "$native_preloads"
    parse_lua_modules "$line_no" "$scope" "$lua_modules"
    parse_aliases "$line_no" "$aliases"
done < "$MANIFEST"

if [[ ! -s "$native_tsv" ]]; then
    echo "error: no native preload symbols found in $MANIFEST" >&2
    exit 1
fi

LC_ALL=C sort -t $'\t' -k1,1 "$native_tsv" > "$native_by_symbol"
LC_ALL=C sort -t $'\t' -k2,2 "$native_tsv" > "$native_by_key"
LC_ALL=C sort -t $'\t' -k1,1 "$lua_tsv" > "$lua_by_module"
LC_ALL=C sort -t $'\t' -k3,3 "$lua_tsv" > "$lua_by_bundle"
LC_ALL=C sort -t $'\t' -k1,1 "$aliases_tsv" > "$aliases_by_public"

check_duplicates() {
    local label="$1"
    local file="$2"
    local column="$3"
    local duplicates
    duplicates="$(cut -f "$column" "$file" | LC_ALL=C sort | uniq -d)"
    if [[ -n "$duplicates" ]]; then
        echo "error: duplicate $label in $MANIFEST" >&2
        printf '%s\n' "$duplicates" | sed 's/^/  duplicate: /' >&2
        exit 1
    fi
}

check_duplicates "native symbol" "$native_tsv" 1
check_duplicates "native preload key" "$native_tsv" 2
check_duplicates "Lua module" "$lua_tsv" 1
check_duplicates "Lua bundle path" "$lua_tsv" 3
if [[ -s "$aliases_tsv" ]]; then
    check_duplicates "preload alias" "$aliases_tsv" 1
fi

cut -f2 "$native_tsv" | LC_ALL=C sort > "$native_keys"
cut -f1 "$lua_tsv" | LC_ALL=C sort > "$lua_module_names"
cut -f1 "$aliases_tsv" | LC_ALL=C sort > "$alias_publics"

check_collisions() {
    local label="$1"
    local left="$2"
    local right="$3"
    local collisions
    collisions="$(comm -12 "$left" "$right")"
    if [[ -n "$collisions" ]]; then
        echo "error: colliding $label in $MANIFEST" >&2
        printf '%s\n' "$collisions" | sed 's/^/  collision: /' >&2
        exit 1
    fi
}

check_collisions "native preload keys and Lua modules" "$native_keys" "$lua_module_names"
if [[ -s "$alias_publics" ]]; then
    check_collisions "native preload keys and aliases" "$native_keys" "$alias_publics"
    check_collisions "Lua modules and aliases" "$lua_module_names" "$alias_publics"
fi

while IFS=$'\t' read -r module source _bundle_path; do
    [[ "$source" == "$OUT_LOADER_METADATA" ]] && continue
    [[ -f "$source" ]] || {
        echo "error: missing Lua source for $module: $source" >&2
        exit 1
    }
    resolved_source="$(realpath "$source")"
    case "$resolved_source" in
        "$repo_physical_root"/*) ;;
        *)
            echo "error: Lua source for $module resolves outside repo: $source -> $resolved_source" >&2
            exit 1
            ;;
    esac
done < "$lua_by_module"

while IFS=$'\t' read -r public target; do
    if ! grep -F -q $'\t'"$target" "$native_by_key" && ! grep -F -q "$target"$'\t' "$lua_by_module"; then
        echo "error: alias $public targets unknown module: $target" >&2
        exit 1
    fi
done < "$aliases_by_public"

while IFS=$'\t' read -r module _source _bundle_path; do
    case "$module" in
        hs.*)
            extension="${module#hs.}"
            if [[ "$extension" != *.* && "$extension" != *_* ]]; then
                printf '%s\n' "$extension"
            fi
            ;;
    esac
done < "$lua_by_module" | LC_ALL=C sort -u > "$lazy_extensions"

native_count="$(wc -l < "$native_by_symbol" | tr -d '[:space:]')"
echo "Generating glue for ${native_count} symbols..."

mkdir -p "$(dirname "$OUT_PRELOAD_H")"
mkdir -p "$(dirname "$OUT_SWIFT")"
mkdir -p "$(dirname "$OUT_LOADER_METADATA")"

lua_escape() {
    local value="$1"
    value="${value//\\/\\\\}"
    value="${value//\"/\\\"}"
    printf '%s' "$value"
}

# -- 1. Preload header ----------------------------------------------------------
{
    cat <<'HDR'
// AUTO-GENERATED. DO NOT EDIT. Re-run scripts/generate-hsextensions.sh.
//
// Forward declarations for every luaopen_hs_lib<name> entry point that the
// HSExtensions static library exposes.  Needed so C/ObjC compilation units
// can reference these symbols.
#pragma once
#include <CLua.h>

#ifdef __cplusplus
extern "C" {
#endif

HDR
    while IFS=$'\t' read -r symbol _key; do
        printf 'int %s(lua_State *L);\n' "$symbol"
    done < "$native_by_symbol"
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
    while IFS=$'\t' read -r symbol _key; do
        printf '@_silgen_name("%s")\n' "$symbol"
        printf 'private func _import_%s(_ L: UnsafeMutablePointer<lua_State>!) -> Int32\n\n' "$symbol"
    done < "$native_by_symbol"

    cat <<'HDR'
// MARK: - Registration

/// Registers every bundled native entry point with package.preload.
/// Call after lua_State creation and before setup.lua runs.
@_cdecl("HSExtensionsRegisterAll")
func hsExtensionsRegisterAll(_ L: UnsafeMutablePointer<lua_State>!) {
    let preload: [(String, @convention(c) (UnsafeMutablePointer<lua_State>?) -> Int32)] = [
HDR
    while IFS=$'\t' read -r symbol key; do
        printf '        ("%s", _import_%s),\n' "$key" "$symbol"
    done < "$native_by_symbol"
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

# -- 3. Lua loader metadata -----------------------------------------------------
{
    cat <<'HDR'
-- AUTO-GENERATED. DO NOT EDIT. Re-run scripts/generate-hsextensions.sh.
--
-- Loader metadata generated from extensions.manifest. App bootstrap, test
-- bootstrap, preload aliases, lazy loading, and Lua resource copying all
-- consume this manifest-derived shape.

local M = {}

M.nativeModules = {
HDR
    while IFS=$'\t' read -r symbol key; do
        printf '  ["%s"] = { symbol = "%s" },\n' "$(lua_escape "$key")" "$(lua_escape "$symbol")"
    done < "$native_by_key"
    cat <<'HDR'
}

M.nativeModuleList = {
HDR
    while IFS=$'\t' read -r symbol key; do
        printf '  { name = "%s", symbol = "%s" },\n' "$(lua_escape "$key")" "$(lua_escape "$symbol")"
    done < "$native_by_key"
    cat <<'HDR'
}

M.luaModules = {
HDR
    while IFS=$'\t' read -r module source bundle_path; do
        printf '  ["%s"] = { source = "%s", bundlePath = "%s" },\n' \
            "$(lua_escape "$module")" "$(lua_escape "$source")" "$(lua_escape "$bundle_path")"
    done < "$lua_by_module"
    cat <<'HDR'
}

M.luaModuleList = {
HDR
    while IFS=$'\t' read -r module source bundle_path; do
        printf '  { name = "%s", source = "%s", bundlePath = "%s" },\n' \
            "$(lua_escape "$module")" "$(lua_escape "$source")" "$(lua_escape "$bundle_path")"
    done < "$lua_by_module"
    cat <<'HDR'
}

M.copyMap = {
HDR
    while IFS=$'\t' read -r module source bundle_path; do
        printf '  { module = "%s", source = "%s", bundlePath = "%s" },\n' \
            "$(lua_escape "$module")" "$(lua_escape "$source")" "$(lua_escape "$bundle_path")"
    done < "$lua_by_bundle"
    cat <<'HDR'
}

M.preloadAliases = {
HDR
    while IFS=$'\t' read -r public target; do
        printf '  { "%s", "%s" },\n' "$(lua_escape "$public")" "$(lua_escape "$target")"
    done < "$aliases_by_public"
    cat <<'HDR'
}

M.aliasTargets = {
HDR
    while IFS=$'\t' read -r public target; do
        printf '  ["%s"] = "%s",\n' "$(lua_escape "$public")" "$(lua_escape "$target")"
    done < "$aliases_by_public"
    cat <<'HDR'
}

M.lazyExtensions = {
HDR
    while IFS= read -r extension; do
        [[ -z "$extension" ]] && continue
        printf '  ["%s"] = true,\n' "$(lua_escape "$extension")"
    done < "$lazy_extensions"
    cat <<'HDR'
}

return M
HDR
} > "$OUT_LOADER_METADATA"

# -- 4. Lua copy map ------------------------------------------------------------
{
    cat <<'HDR'
# AUTO-GENERATED. DO NOT EDIT. Re-run scripts/generate-hsextensions.sh.
# source<TAB>bundle-path<TAB>module
HDR
    while IFS=$'\t' read -r module source bundle_path; do
        printf '%s\t%s\t%s\n' "$source" "$bundle_path" "$module"
    done < "$lua_by_bundle"
} > "$OUT_COPY_MAP"

echo "  wrote $OUT_PRELOAD_H"
echo "  wrote $OUT_SWIFT"
echo "  wrote $OUT_LOADER_METADATA"
echo "  wrote $OUT_COPY_MAP"
