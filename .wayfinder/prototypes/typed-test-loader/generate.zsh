#!/bin/zsh
set -euo pipefail

root="${0:A:h}"
manifest="$root/prototype.manifest"
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT
rows="$tmpdir/rows.tsv"
: > "$rows"

while IFS=$'\t' read -r typed_id preload_key factory extra || [[ -n "${typed_id:-}" ]]; do
    [[ -z "${typed_id:-}" || "$typed_id" == \#* ]] && continue
    if [[ -n "${extra:-}" || -z "${preload_key:-}" || -z "${factory:-}" ]]; then
        print -u2 "invalid manifest row: $typed_id"
        exit 1
    fi
    [[ "$typed_id" =~ '^[a-z][A-Za-z0-9]*$' ]] || { print -u2 "invalid typed id: $typed_id"; exit 1; }
    [[ "$preload_key" == hs.* ]] || { print -u2 "invalid preload key: $preload_key"; exit 1; }
    [[ "$factory" =~ '^[A-Za-z_][A-Za-z0-9_]*$' ]] || { print -u2 "invalid factory: $factory"; exit 1; }
    printf '%s\t%s\t%s\n' "$typed_id" "$preload_key" "$factory" >> "$rows"
done < "$manifest"

LC_ALL=C sort -t $'\t' -k2,2 "$rows" > "$tmpdir/sorted.tsv"
for column in 1 2; do
    duplicate="$(cut -f "$column" "$tmpdir/sorted.tsv" | LC_ALL=C sort | uniq -d | head -n 1)"
    [[ -z "$duplicate" ]] || { print -u2 "duplicate manifest identity: $duplicate"; exit 1; }
done

{
    cat <<'SWIFT'
// PROTOTYPE — generated typed module identity and private factory registry.
import CLua
import Lua

enum BundledLuaModule: String, CaseIterable {
SWIFT
    while IFS=$'\t' read -r typed_id preload_key factory; do
        printf '    case %s = "%s"\n' "$typed_id" "$preload_key"
    done < "$tmpdir/sorted.tsv"
    cat <<'SWIFT'
}

private extension BundledLuaModule {
    var factory: Lua.lua_CFunction {
        switch self {
SWIFT
    while IFS=$'\t' read -r typed_id preload_key factory; do
        printf '        case .%s: %s\n' "$typed_id" "$factory"
    done < "$tmpdir/sorted.tsv"
    cat <<'SWIFT'
        }
    }
}

func registerBundledLuaModules(in state: LuaState) {
    luaL_getsubtable(state, LUA_REGISTRYINDEX, "_PRELOAD")
    for module in BundledLuaModule.allCases {
        lua_pushcclosure(state, module.factory, 0)
        module.rawValue.withCString { key in
            lua_setfield(state, -2, key)
        }
    }
    lua_pop(state, 1)
}

@discardableResult
func loadBundledLuaModule(_ module: BundledLuaModule, in state: LuaState) -> CInt {
    module.factory(state)
}
SWIFT
} > "$root/Sources/GeneratedRegistry.swift"

count="$(wc -l < "$tmpdir/sorted.tsv" | tr -d '[:space:]')"
print "generated=$count"
