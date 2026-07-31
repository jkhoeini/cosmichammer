#!/bin/zsh
set -euo pipefail

root="${0:A:h}"
expected_order="hs.libprototype_callback,hs.libprototype_nested,hs.libprototype_simple,hs.libprototype_userdata"
expected_evidence="preload=4/4 aliases=4/4 lazy=4/4 simple=42 userdata=7 callback=42 nested=9 stack=balanced"
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

"$root/generate.zsh"
cp "$root/Sources/GeneratedRegistry.swift" "$tmpdir/GeneratedRegistry.swift"
cp "$root/GeneratedMetadata.lua" "$tmpdir/GeneratedMetadata.lua"
"$root/generate.zsh"
cmp "$tmpdir/GeneratedRegistry.swift" "$root/Sources/GeneratedRegistry.swift"
cmp "$tmpdir/GeneratedMetadata.lua" "$root/GeneratedMetadata.lua"

if grep -R -E '@_(cdecl|silgen_name)' "$root/Sources"; then
    print -u2 "prototype source contains an underscored ABI attribute"
    exit 1
fi
grep -q 'factory: prototypeSimpleFactoryV2' "$root/Sources/GeneratedRegistry.swift"

swift package --package-path "$root" resolve

debug_output="$(swift run --package-path "$root" -c debug ManifestSwiftRegistryPrototype)"
print -r -- "$debug_output"
[[ "$debug_output" == *"configuration=debug order=$expected_order $expected_evidence"* ]]

swift package --package-path "$root" clean
release_log="$tmpdir/release-build.log"
swift build --package-path "$root" -c release -v >"$release_log" 2>&1
grep -q -- '-dead_strip' "$release_log"
release_bin="$(swift build --package-path "$root" -c release --show-bin-path)/ManifestSwiftRegistryPrototype"
release_output="$("$release_bin")"
print -r -- "$release_output"
[[ "$release_output" == *"configuration=release order=$expected_order $expected_evidence"* ]]

nm -gU "$release_bin" > "$tmpdir/global-symbols.txt"
for factory in prototypeSimpleFactoryV2 prototypeUserdataFactory prototypeCallbackFactory prototypeNestedFactory prototypeNestedChildFactory; do
    if grep -E "[[:space:]]_${factory}$" "$tmpdir/global-symbols.txt"; then
        print -u2 "unexpected unmangled C export: $factory"
        exit 1
    fi
done

print "generator=idempotent order=deterministic source=underscored-abi-free"
print "release-link=dead_strip release-symbols=no-unmangled-factory-exports"
