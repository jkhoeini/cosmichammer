#!/usr/bin/env bash
# Regenerates the input/output xcfilelists used by the
# "Copy Extension Lua files (manifest)" Run Script build phase.
#
# Reads Packages/HSExtensions/lua-files.list (one source path per line,
# relative to repo root) and emits:
#
#   scripts/lua-files.inputs.xcfilelist   — manifest + every source .lua
#   scripts/lua-files.outputs.xcfilelist  — every destination path
#
# These files give Xcode an accurate incremental-build dependency graph so
# touching a listed .lua re-runs the copy phase and only that phase.
#
# Re-run this script after editing Packages/HSExtensions/lua-files.list.
# The script is idempotent.
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"

LIST_FILE="Packages/HSExtensions/lua-files.list"
INPUTS="scripts/lua-files.inputs.xcfilelist"
OUTPUTS="scripts/lua-files.outputs.xcfilelist"

if [[ ! -f "$LIST_FILE" ]]; then
    echo "error: manifest not found: $LIST_FILE" >&2
    exit 1
fi

{
    # The manifest itself is an input — editing it must invalidate the phase.
    printf '$(SRCROOT)/%s\n' "$LIST_FILE"
    while IFS= read -r raw; do
        line="${raw%%#*}"
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        [[ -z "$line" ]] && continue
        printf '$(SRCROOT)/%s\n' "$line"
    done < "$LIST_FILE"
} > "$INPUTS"

{
    while IFS= read -r raw; do
        line="${raw%%#*}"
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        [[ -z "$line" ]] && continue
        base="$(basename "$line")"
        printf '$(BUILT_PRODUCTS_DIR)/$(UNLOCALIZED_RESOURCES_FOLDER_PATH)/extensions/hs/%s\n' "$base"
    done < "$LIST_FILE"
} > "$OUTPUTS"

echo "  wrote $INPUTS ($(wc -l < "$INPUTS") lines)"
echo "  wrote $OUTPUTS ($(wc -l < "$OUTPUTS") lines)"
