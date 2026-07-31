#!/bin/zsh
set -euo pipefail

root="${0:A:h}"
expected_order="hs.libprototype_callback,hs.libprototype_nested,hs.libprototype_simple,hs.libprototype_userdata"
expected_evidence="modules=4/4 legacy=typed=require stack=balanced callback=42:callback;nested=9:nested;simple=42:simple;userdata=userdata:7"
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

"$root/generate.zsh"
cp "$root/Sources/GeneratedRegistry.swift" "$tmpdir/GeneratedRegistry.swift"
"$root/generate.zsh"
cmp "$tmpdir/GeneratedRegistry.swift" "$root/Sources/GeneratedRegistry.swift"

if grep -R -E '@_(cdecl|silgen_name)' "$root/Sources"; then
    print -u2 "prototype source contains an underscored ABI attribute"
    exit 1
fi
grep -q 'enum BundledLuaModule: String, CaseIterable' "$root/Sources/GeneratedRegistry.swift"
grep -q 'private extension BundledLuaModule' "$root/Sources/GeneratedRegistry.swift"
grep -q 'func loadBundledLuaModule' "$root/Sources/GeneratedRegistry.swift"

swift package --package-path "$root" resolve

debug_output="$(swift run --package-path "$root" -c debug TypedTestLoaderPrototype)"
print -r -- "$debug_output"
[[ "$debug_output" == *"configuration=debug order=$expected_order $expected_evidence"* ]]

swift package --package-path "$root" clean
release_log="$tmpdir/release-build.log"
swift build --package-path "$root" -c release -v >"$release_log" 2>&1
grep -q -- '-dead_strip' "$release_log"
release_bin="$(swift build --package-path "$root" -c release --show-bin-path)/TypedTestLoaderPrototype"
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

print "generator=idempotent typed-identity=manifest-derived factory=private"
print "equivalence=legacy-direct:typed-direct:typed-require release=dead-strip underscored-abi=absent"
