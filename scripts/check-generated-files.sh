#!/usr/bin/env bash
# Verifies that HSExtensions generated files are in sync with their manifest.
#
#   extensions.manifest + scripts/generate-hsextensions.sh
#     Outputs:
#       Sources/HSExtensions/include/HSExtensions/HSExtensions+Preload.h
#       Sources/HSSwiftExtensions/HSExtensionsGenerated.swift
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

write_manifest_symbols() {
    local raw_out="$1" sorted_out="$2" duplicates_out="$3"

    awk -F '\t' '
        {
            dir = $1
            sub(/#.*/, "", dir)
            gsub(/[[:space:]]/, "", dir)
            if (dir == "") next

            entry_points = $2
            gsub(/[[:space:]]/, "", entry_points)
            if (entry_points == "" || entry_points == "-") next

            count = split(entry_points, symbols, ",")
            for (i = 1; i <= count; i++) {
                if (symbols[i] != "") print symbols[i]
            }
        }
    ' "$MANIFEST" > "$raw_out"

    sort "$raw_out" > "$sorted_out"
    sort "$raw_out" | uniq -d > "$duplicates_out"
}

MANIFEST="extensions.manifest"
GEN_EXT="scripts/generate-hsextensions.sh"
OUT_PRELOAD_H="Sources/HSExtensions/include/HSExtensions/HSExtensions+Preload.h"
OUT_SWIFT="Sources/HSSwiftExtensions/HSExtensionsGenerated.swift"

[[ -f "$MANIFEST" ]] || die "manifest not found: $MANIFEST"
[[ -f "$GEN_EXT" ]] || die "generator not found: $GEN_EXT"
[[ -f "$OUT_PRELOAD_H" ]] || die "output not found: $OUT_PRELOAD_H"
[[ -f "$OUT_SWIFT" ]] || die "output not found: $OUT_SWIFT"

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

mkdir -p "$tmpdir/scripts"
mkdir -p "$tmpdir/Sources/HSExtensions/include/HSExtensions"
mkdir -p "$tmpdir/Sources/HSSwiftExtensions"

cp "$MANIFEST" "$tmpdir/$MANIFEST"
cp "$GEN_EXT" "$tmpdir/$GEN_EXT"
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

manifest_raw="$tmpdir/manifest-symbols.raw"
manifest_symbols="$tmpdir/manifest-symbols.sorted"
manifest_duplicates="$tmpdir/manifest-symbols.duplicates"
header_symbols="$tmpdir/header-symbols.sorted"
swift_import_symbols="$tmpdir/swift-import-symbols.sorted"
expected_preload_keys="$tmpdir/expected-preload-keys.sorted"
swift_preload_keys="$tmpdir/swift-preload-keys.sorted"

write_manifest_symbols "$manifest_raw" "$manifest_symbols" "$manifest_duplicates"

if [[ ! -s "$manifest_symbols" ]]; then
    die "no native entry-point symbols found in $MANIFEST"
fi

if [[ -s "$manifest_duplicates" ]]; then
    echo "MISMATCH: duplicate native symbols in $MANIFEST"
    sed 's/^/  duplicate: /' "$manifest_duplicates"
    echo ""
    failed=1
elif [[ "$quiet" == false ]]; then
    echo "  OK: no duplicate manifest native symbols"
fi

sed -nE 's/^[[:space:]]*int[[:space:]]+(luaopen_[A-Za-z0-9_]+)[[:space:]]*\(lua_State[[:space:]]+\*L\);[[:space:]]*(\/\/.*)?$/\1/p' \
    "$OUT_PRELOAD_H" | sort > "$header_symbols"

sed -nE 's/^[[:space:]]*@_silgen_name[[:space:]]*\("[[:space:]]*(luaopen_[A-Za-z0-9_]+)[[:space:]]*"\)[[:space:]]*(\/\/.*)?$/\1/p' \
    "$OUT_SWIFT" | sort > "$swift_import_symbols"

awk '
    {
        symbol = $0
        sub(/^luaopen_hs_/, "", symbol)
        print "hs." symbol
    }
' "$manifest_symbols" | sort > "$expected_preload_keys"

sed -nE 's/^[[:space:]]*\("([^"]+)",[[:space:]]*_import_luaopen_[A-Za-z0-9_]+\),[[:space:]]*(\/\/.*)?$/\1/p' \
    "$OUT_SWIFT" | sort > "$swift_preload_keys"

check_extraction_nonempty "header declarations" "$header_symbols"
check_extraction_nonempty "Swift @_silgen_name imports" "$swift_import_symbols"
check_extraction_nonempty "Swift preload keys" "$swift_preload_keys"

check_list_match "manifest symbols vs header declarations" \
    "$manifest_symbols" "$header_symbols"
check_list_match "manifest symbols vs Swift @_silgen_name imports" \
    "$manifest_symbols" "$swift_import_symbols"
check_list_match "manifest symbols vs Swift preload keys" \
    "$expected_preload_keys" "$swift_preload_keys"

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
