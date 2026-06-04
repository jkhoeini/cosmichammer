#!/usr/bin/env bash
# Verifies that HSExtensions generated files are in sync with their manifest.
#
#   extensions.manifest + scripts/generate-hsextensions.sh
#     Outputs:
#       Sources/HSExtensions/include/HSExtensions/HSExtensions+Preload.h
#       Sources/HSSwiftExtensions/HSExtensionsGenerated.swift
#       extensions/_coresetup/_loader_metadata.lua
#       extensions/_coresetup/_loader_copy_map.tsv
#
# This script does NOT modify tracked files. It regenerates outputs into a temp
# directory, compares them against the committed versions, and checks manifest,
# header, and Swift registration consistency.
#
# Usage:
#   scripts/check-generated-files.sh          # check generated HSExtensions glue
#   scripts/check-generated-files.sh --quiet  # suppress success messages
#
# Exit codes:
#   0  all generated files are up to date
#   1  one or more generated files are stale or inconsistent
#   2  script error (missing files, generator failed, etc.)
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"

quiet=false
[[ "${1:-}" == "--quiet" ]] && quiet=true

failed=0

die() {
    echo "error: $*" >&2
    exit 2
}

check_file_match() {
    local label="$1" expected="$2" actual="$3"

    if ! diff -q "$expected" "$actual" >/dev/null 2>&1; then
        echo "STALE: $label"
        echo "  committed: $actual"
        echo "  expected:  regenerated from extensions.manifest"
        diff -u "$actual" "$expected" | head -80
        echo ""
        failed=1
    elif [[ "$quiet" == false ]]; then
        echo "  OK: $label"
    fi
}

check_list_match() {
    local label="$1" expected="$2" actual="$3"

    if ! diff -q "$expected" "$actual" >/dev/null 2>&1; then
        echo "MISMATCH: $label"
        diff -u "$expected" "$actual" | head -80
        echo ""
        failed=1
    elif [[ "$quiet" == false ]]; then
        echo "  OK: $label"
    fi
}

check_extraction_nonempty() {
    local label="$1" path="$2"

    if [[ ! -s "$path" ]]; then
        echo "MISMATCH: $label extraction produced no symbols"
        echo "  This usually means the generated-file parser no longer matches the file format."
        echo ""
        failed=1
    fi
}

write_manifest_native() {
    local raw_out="$1" symbols_out="$2" keys_out="$3" symbol_duplicates_out="$4" key_duplicates_out="$5"

    awk -F '\t' '
        {
            scope = $1
            sub(/#.*/, "", scope)
            gsub(/[[:space:]]/, "", scope)
            if (scope == "") next

            native_preloads = $2
            gsub(/[[:space:]]/, "", native_preloads)
            if (native_preloads == "" || native_preloads == "-") next

            count = split(native_preloads, entries, ",")
            for (i = 1; i <= count; i++) {
                if (entries[i] == "") continue
                eq = index(entries[i], "=")
                if (eq == 0) {
                    print entries[i] "\t"
                } else {
                    print substr(entries[i], eq + 1) "\t" substr(entries[i], 1, eq - 1)
                }
            }
        }
    ' "$MANIFEST" > "$raw_out"

    cut -f1 "$raw_out" | sort > "$symbols_out"
    cut -f2 "$raw_out" | sort > "$keys_out"
    cut -f1 "$raw_out" | sort | uniq -d > "$symbol_duplicates_out"
    cut -f2 "$raw_out" | sort | uniq -d > "$key_duplicates_out"
}

check_copy_map_sources_and_destinations() {
    local malformed_rows="$tmpdir/copy-map-malformed-rows.txt"
    local source_duplicates="$tmpdir/copy-map-source-duplicates.txt"
    local destination_duplicates="$tmpdir/copy-map-destination-duplicates.txt"
    local missing_sources="$tmpdir/copy-map-missing-sources.txt"

    awk -F '\t' '
        /^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
        NF != 3 { print NR ":" $0 }
    ' "$OUT_COPY_MAP" > "$malformed_rows"

    awk -F '\t' '
        /^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
        NF != 3 { next }
        { print $2 }
    ' "$OUT_COPY_MAP" | sort | uniq -d > "$destination_duplicates"

    awk -F '\t' '
        /^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
        NF == 3 { print $1 }
    ' "$OUT_COPY_MAP" | sort | uniq -d > "$source_duplicates"

    awk -F '\t' '
        /^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
        NF == 3 { print $1 }
    ' "$OUT_COPY_MAP" | while IFS= read -r source; do
        [[ -f "$source" ]] || printf '%s\n' "$source"
    done > "$missing_sources"

    if [[ -s "$malformed_rows" ]]; then
        echo "MISMATCH: malformed Lua copy map rows in $OUT_COPY_MAP"
        sed 's/^/  row: /' "$malformed_rows"
        echo ""
        failed=1
    elif [[ "$quiet" == false ]]; then
        echo "  OK: Lua copy map rows have source, bundle path, and module columns"
    fi

    if [[ -s "$destination_duplicates" ]]; then
        echo "MISMATCH: duplicate Lua bundle destinations in $OUT_COPY_MAP"
        sed 's/^/  duplicate: /' "$destination_duplicates"
        echo ""
        failed=1
    elif [[ "$quiet" == false ]]; then
        echo "  OK: no duplicate Lua bundle destinations"
    fi

    if [[ -s "$source_duplicates" && "$quiet" == false ]]; then
        echo "  OK: duplicate Lua sources are allowed only if they copy to different bundle paths"
    fi

    if [[ -s "$missing_sources" ]]; then
        echo "MISMATCH: Lua copy map references missing source files"
        sed 's/^/  missing: /' "$missing_sources"
        echo ""
        failed=1
    elif [[ "$quiet" == false ]]; then
        echo "  OK: Lua copy map source files exist"
    fi
}

MANIFEST="extensions.manifest"
GEN_EXT="scripts/generate-hsextensions.sh"
OUT_PRELOAD_H="Sources/HSExtensions/include/HSExtensions/HSExtensions+Preload.h"
OUT_SWIFT="Sources/HSSwiftExtensions/HSExtensionsGenerated.swift"
OUT_LOADER_METADATA="extensions/_coresetup/_loader_metadata.lua"
OUT_COPY_MAP="extensions/_coresetup/_loader_copy_map.tsv"

[[ -f "$MANIFEST" ]] || die "manifest not found: $MANIFEST"
[[ -f "$GEN_EXT" ]] || die "generator not found: $GEN_EXT"
[[ -f "$OUT_PRELOAD_H" ]] || die "output not found: $OUT_PRELOAD_H"
[[ -f "$OUT_SWIFT" ]] || die "output not found: $OUT_SWIFT"
[[ -f "$OUT_LOADER_METADATA" ]] || die "output not found: $OUT_LOADER_METADATA"
[[ -f "$OUT_COPY_MAP" ]] || die "output not found: $OUT_COPY_MAP"

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

mkdir -p "$tmpdir/scripts"
mkdir -p "$tmpdir/Sources/HSExtensions/include/HSExtensions"
mkdir -p "$tmpdir/Sources/HSSwiftExtensions"
mkdir -p "$tmpdir/extensions"

cp "$MANIFEST" "$tmpdir/$MANIFEST"
cp "$GEN_EXT" "$tmpdir/$GEN_EXT"
cp -R extensions/. "$tmpdir/extensions/"
chmod +x "$tmpdir/$GEN_EXT"

(
    cd "$tmpdir"
    bash "$GEN_EXT" >/dev/null 2>&1
) || die "generate-hsextensions.sh failed in temp directory"

if [[ "$quiet" == false ]]; then
    echo "Checking generated HSExtensions glue"
fi

check_file_match "HSExtensions+Preload.h" \
    "$tmpdir/$OUT_PRELOAD_H" "$repo_root/$OUT_PRELOAD_H"
check_file_match "HSExtensionsGenerated.swift" \
    "$tmpdir/$OUT_SWIFT" "$repo_root/$OUT_SWIFT"
check_file_match "_loader_metadata.lua" \
    "$tmpdir/$OUT_LOADER_METADATA" "$repo_root/$OUT_LOADER_METADATA"
check_file_match "_loader_copy_map.tsv" \
    "$tmpdir/$OUT_COPY_MAP" "$repo_root/$OUT_COPY_MAP"

manifest_native="$tmpdir/manifest-native.raw"
manifest_symbols="$tmpdir/manifest-symbols.sorted"
manifest_preload_keys="$tmpdir/manifest-preload-keys.sorted"
manifest_symbol_duplicates="$tmpdir/manifest-symbols.duplicates"
manifest_key_duplicates="$tmpdir/manifest-preload-keys.duplicates"
header_symbols="$tmpdir/header-symbols.sorted"
swift_import_symbols="$tmpdir/swift-import-symbols.sorted"
swift_preload_keys="$tmpdir/swift-preload-keys.sorted"

write_manifest_native \
    "$manifest_native" \
    "$manifest_symbols" \
    "$manifest_preload_keys" \
    "$manifest_symbol_duplicates" \
    "$manifest_key_duplicates"

if [[ ! -s "$manifest_symbols" ]]; then
    die "no native entry-point symbols found in $MANIFEST"
fi

if [[ -s "$manifest_symbol_duplicates" ]]; then
    echo "MISMATCH: duplicate native symbols in $MANIFEST"
    sed 's/^/  duplicate: /' "$manifest_symbol_duplicates"
    echo ""
    failed=1
elif [[ "$quiet" == false ]]; then
    echo "  OK: no duplicate manifest native symbols"
fi

if [[ -s "$manifest_key_duplicates" ]]; then
    echo "MISMATCH: duplicate native preload keys in $MANIFEST"
    sed 's/^/  duplicate: /' "$manifest_key_duplicates"
    echo ""
    failed=1
elif [[ "$quiet" == false ]]; then
    echo "  OK: no duplicate manifest native preload keys"
fi

sed -nE 's/^[[:space:]]*int[[:space:]]+(luaopen_[A-Za-z0-9_]+)[[:space:]]*\(lua_State[[:space:]]+\*L\);[[:space:]]*(\/\/.*)?$/\1/p' \
    "$OUT_PRELOAD_H" | sort > "$header_symbols"

sed -nE 's/^[[:space:]]*@_silgen_name[[:space:]]*\("[[:space:]]*(luaopen_[A-Za-z0-9_]+)[[:space:]]*"\)[[:space:]]*(\/\/.*)?$/\1/p' \
    "$OUT_SWIFT" | sort > "$swift_import_symbols"

sed -nE 's/^[[:space:]]*\("([^"]+)",[[:space:]]*_import_luaopen_[A-Za-z0-9_]+\),[[:space:]]*(\/\/.*)?$/\1/p' \
    "$OUT_SWIFT" | sort > "$swift_preload_keys"

check_extraction_nonempty "header declarations" "$header_symbols"
check_extraction_nonempty "Swift @_silgen_name imports" "$swift_import_symbols"
check_extraction_nonempty "Swift preload keys" "$swift_preload_keys"

check_list_match "manifest symbols vs header declarations" \
    "$manifest_symbols" "$header_symbols"
check_list_match "manifest symbols vs Swift @_silgen_name imports" \
    "$manifest_symbols" "$swift_import_symbols"
check_list_match "manifest preload keys vs Swift preload keys" \
    "$manifest_preload_keys" "$swift_preload_keys"

check_copy_map_sources_and_destinations

if [[ "$failed" -ne 0 ]]; then
    echo "Generated files are out of sync with extensions.manifest."
    echo "Run the following to fix:"
    echo "  scripts/generate-hsextensions.sh"
    exit 1
fi

if [[ "$quiet" == false ]]; then
    echo "All generated HSExtensions files are up to date."
fi
exit 0
