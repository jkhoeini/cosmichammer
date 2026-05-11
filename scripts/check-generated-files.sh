#!/usr/bin/env bash
# Verifies that generated files are in sync with their manifest.
#
# Both generator pipelines read from one unified manifest:
#
#   extensions.manifest → generate-hsextensions.sh
#     Outputs: HSExtensions+Preload.h, HSExtensions.m, HSExtensionsRegistry.m
#
#   extensions.manifest → generate-lua-files-xcfilelists.sh
#     Outputs: lua-files.inputs.xcfilelist, lua-files.outputs.xcfilelist
#
# This script does NOT modify any files. It regenerates outputs into a temp
# directory and compares them against the committed versions. If they differ,
# it prints instructions and exits non-zero.
#
# Usage:
#   scripts/check-generated-files.sh          # check both pipelines
#   scripts/check-generated-files.sh --quiet  # suppress "OK" messages
#
# Exit codes:
#   0  — all generated files are up to date
#   1  — one or more generated files are stale
#   2  — script error (missing files, generator failed, etc.)
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"

quiet=false
[[ "${1:-}" == "--quiet" ]] && quiet=true

failed=0

# ── Helpers ──────────────────────────────────────────────────────────────

die() { echo "error: $*" >&2; exit 2; }

check_file_match() {
    local label="$1" expected="$2" actual="$3"
    if ! diff -q "$expected" "$actual" >/dev/null 2>&1; then
        echo "STALE: $label"
        echo "  committed: $actual"
        echo "  expected:  (regenerated from manifest)"
        diff -u "$actual" "$expected" | head -40
        echo ""
        failed=1
    elif [[ "$quiet" == false ]]; then
        echo "  OK: $label"
    fi
}

# ── Shared manifest ────────────────────────────────────────────────────

MANIFEST="Packages/HSExtensions/extensions.manifest"

[[ -f "$MANIFEST" ]] || die "manifest not found: $MANIFEST"

# ── Pipeline 1: extensions.manifest → HSExtensions glue ────────────────

GEN_EXT="scripts/generate-hsextensions.sh"

OUT_PRELOAD_H="Packages/HSExtensions/Sources/HSExtensions/include/HSExtensions/HSExtensions+Preload.h"
OUT_REGISTER_M="Packages/HSExtensions/Sources/HSExtensions/HSExtensions.m"
OUT_KEEPALIVE_M="Hammerspoon/HSExtensionsRegistry.m"

[[ -f "$GEN_EXT" ]]   || die "generator not found: $GEN_EXT"
[[ -f "$OUT_PRELOAD_H" ]] || die "output not found: $OUT_PRELOAD_H"
[[ -f "$OUT_REGISTER_M" ]] || die "output not found: $OUT_REGISTER_M"
[[ -f "$OUT_KEEPALIVE_M" ]] || die "output not found: $OUT_KEEPALIVE_M"

tmpdir_ext="$(mktemp -d)"
trap 'rm -rf "$tmpdir_ext" "${tmpdir_lua:-}"' EXIT

# Create a mirror directory structure so the generator writes to predictable paths.
mkdir -p "$tmpdir_ext/Packages/HSExtensions/Sources/HSExtensions/include/HSExtensions"
mkdir -p "$tmpdir_ext/Hammerspoon"

# Copy the manifest so the generator finds it.
mkdir -p "$tmpdir_ext/Packages/HSExtensions"
cp "$MANIFEST" "$tmpdir_ext/$MANIFEST"

# Run the generator against the temp tree.
(
    cd "$tmpdir_ext"
    mkdir -p scripts
    cp "$repo_root/$GEN_EXT" scripts/
    chmod +x scripts/generate-hsextensions.sh
    bash scripts/generate-hsextensions.sh >/dev/null 2>&1
) || die "generate-hsextensions.sh failed in temp directory"

echo "Checking pipeline 1: extensions.manifest → HSExtensions glue"
check_file_match "HSExtensions+Preload.h" \
    "$tmpdir_ext/$OUT_PRELOAD_H" "$repo_root/$OUT_PRELOAD_H"
check_file_match "HSExtensions.m" \
    "$tmpdir_ext/$OUT_REGISTER_M" "$repo_root/$OUT_REGISTER_M"
check_file_match "HSExtensionsRegistry.m" \
    "$tmpdir_ext/$OUT_KEEPALIVE_M" "$repo_root/$OUT_KEEPALIVE_M"

# ── Pipeline 2: extensions.manifest → xcfilelists ─────────────────────

GEN_LUA="scripts/generate-lua-files-xcfilelists.sh"

OUT_INPUTS="scripts/lua-files.inputs.xcfilelist"
OUT_OUTPUTS="scripts/lua-files.outputs.xcfilelist"

[[ -f "$GEN_LUA" ]]     || die "generator not found: $GEN_LUA"
[[ -f "$OUT_INPUTS" ]]  || die "output not found: $OUT_INPUTS"
[[ -f "$OUT_OUTPUTS" ]] || die "output not found: $OUT_OUTPUTS"

tmpdir_lua="$(mktemp -d)"

# Mirror the structure for pipeline 2.
mkdir -p "$tmpdir_lua/Packages/HSExtensions"
mkdir -p "$tmpdir_lua/scripts"

cp "$MANIFEST" "$tmpdir_lua/$MANIFEST"

(
    cd "$tmpdir_lua"
    cp "$repo_root/$GEN_LUA" scripts/
    chmod +x scripts/generate-lua-files-xcfilelists.sh
    bash scripts/generate-lua-files-xcfilelists.sh >/dev/null 2>&1
) || die "generate-lua-files-xcfilelists.sh failed in temp directory"

echo "Checking pipeline 2: extensions.manifest → xcfilelists"
check_file_match "lua-files.inputs.xcfilelist" \
    "$tmpdir_lua/$OUT_INPUTS" "$repo_root/$OUT_INPUTS"
check_file_match "lua-files.outputs.xcfilelist" \
    "$tmpdir_lua/$OUT_OUTPUTS" "$repo_root/$OUT_OUTPUTS"

# ── Result ───────────────────────────────────────────────────────────────

if [[ "$failed" -ne 0 ]]; then
    echo ""
    echo "Generated files are out of sync with their manifest."
    echo "Run the following to fix:"
    echo "  scripts/generate-hsextensions.sh"
    echo "  scripts/generate-lua-files-xcfilelists.sh"
    exit 1
fi

if [[ "$quiet" == false ]]; then
    echo ""
    echo "All generated files are up to date."
fi
exit 0
