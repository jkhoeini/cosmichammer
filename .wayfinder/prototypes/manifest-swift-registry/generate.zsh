#!/bin/zsh
set -euo pipefail

root="${0:A:h}"
manifest="$root/prototype.manifest"
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

native="$tmpdir/native.tsv"
lua_modules="$tmpdir/lua.tsv"
aliases_file="$tmpdir/aliases.tsv"
: > "$native"
: > "$lua_modules"
: > "$aliases_file"

while IFS=$'\t' read -r scope native_spec lua_spec alias_spec extra || [[ -n "${scope:-}" ]]; do
    [[ -z "${scope:-}" || "$scope" == \#* ]] && continue
    [[ -z "${extra:-}" ]] || { print -u2 "expected four columns"; exit 1; }

    if [[ "$native_spec" != "-" ]]; then
        for item in ${(s:,:)native_spec}; do
            key="${item%%=*}"
            factory="${item#*=}"
            [[ "$key" == hs.* ]] || { print -u2 "invalid preload key: $key"; exit 1; }
            [[ "$factory" =~ '^[A-Za-z_][A-Za-z0-9_]*$' ]] || { print -u2 "invalid Swift factory: $factory"; exit 1; }
            printf '%s\t%s\n' "$key" "$factory" >> "$native"
        done
    fi

    if [[ "$lua_spec" != "-" ]]; then
        for item in ${(s:,:)lua_spec}; do
            module="${item%%=*}"
            rest="${item#*=}"
            source="${rest%%>*}"
            bundle="${rest#*>}"
            printf '%s\t%s\t%s\n' "$module" "$source" "$bundle" >> "$lua_modules"
        done
    fi

    if [[ "$alias_spec" != "-" ]]; then
        for item in ${(s:,:)alias_spec}; do
            public="${item%%=*}"
            target="${item#*=}"
            printf '%s\t%s\n' "$public" "$target" >> "$aliases_file"
        done
    fi
done < "$manifest"

LC_ALL=C sort -t $'\t' -k1,1 "$native" > "$tmpdir/native.sorted"
LC_ALL=C sort -t $'\t' -k1,1 "$lua_modules" > "$tmpdir/lua.sorted"
LC_ALL=C sort -t $'\t' -k1,1 "$aliases_file" > "$tmpdir/aliases.sorted"

for spec in 'preload key:1:native.sorted' 'Swift factory:2:native.sorted' 'Lua module:1:lua.sorted' 'alias:1:aliases.sorted'; do
    label="${spec%%:*}"
    rest="${spec#*:}"
    column="${rest%%:*}"
    file="${rest#*:}"
    duplicates="$(cut -f "$column" "$tmpdir/$file" | uniq -d)"
    [[ -z "$duplicates" ]] || { print -u2 "duplicate $label: $duplicates"; exit 1; }
done

{
    cat <<'SWIFT'
// PROTOTYPE — generated direct-reference registry. Delete after the decision is absorbed.
import CLua
import Lua

private struct BundledLuaModule {
    let preloadKey: String
    let factory: Lua.lua_CFunction
}

private let bundledLuaModules: [BundledLuaModule] = [
SWIFT
    while IFS=$'\t' read -r key factory; do
        printf '    BundledLuaModule(preloadKey: "%s", factory: %s),\n' "$key" "$factory"
    done < "$tmpdir/native.sorted"
    cat <<'SWIFT'
]

func registerBundledLuaModules(in state: LuaState) {
    luaL_getsubtable(state, LUA_REGISTRYINDEX, "_PRELOAD")
    for module in bundledLuaModules {
        lua_pushcclosure(state, module.factory, 0)
        module.preloadKey.withCString { key in
            lua_setfield(state, -2, key)
        }
    }
    lua_pop(state, 1)
}
SWIFT
} > "$root/Sources/GeneratedRegistry.swift"

{
    cat <<'LUA'
-- PROTOTYPE — generated key-only loader metadata. Delete with the prototype.
local M = {}
M.nativeModules = {
LUA
    while IFS=$'\t' read -r key _factory; do
        printf '  ["%s"] = true,\n' "$key"
    done < "$tmpdir/native.sorted"
    cat <<'LUA'
}
M.nativeModuleList = {
LUA
    while IFS=$'\t' read -r key _factory; do
        printf '  "%s",\n' "$key"
    done < "$tmpdir/native.sorted"
    cat <<'LUA'
}
M.luaModules = {
LUA
    while IFS=$'\t' read -r module source bundle; do
        printf '  ["%s"] = { source = "%s", bundlePath = "%s" },\n' "$module" "$source" "$bundle"
    done < "$tmpdir/lua.sorted"
    cat <<'LUA'
}
M.preloadAliases = {
LUA
    while IFS=$'\t' read -r public target; do
        printf '  { "%s", "%s" },\n' "$public" "$target"
    done < "$tmpdir/aliases.sorted"
    cat <<'LUA'
}
M.lazyExtensions = {
LUA
    while IFS=$'\t' read -r module _source _bundle; do
        extension="${module#hs.}"
        if [[ "$extension" != *.* && "$extension" != *_* ]]; then
            printf '  ["%s"] = true,\n' "$extension"
        fi
    done < "$tmpdir/lua.sorted"
    cat <<'LUA'
}
return M
LUA
} > "$root/GeneratedMetadata.lua"

count="$(wc -l < "$tmpdir/native.sorted" | tr -d '[:space:]')"
print "generated=$count"
