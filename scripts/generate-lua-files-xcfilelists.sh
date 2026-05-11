#!/usr/bin/env bash
# Regenerates the input/output xcfilelists used by the
# "Copy Extension Lua files (manifest)" Run Script build phase.
#
# Reads Packages/HSExtensions/extensions.manifest (the unified manifest) and
# emits:
#
#   scripts/lua-files.inputs.xcfilelist   — manifest + every source .lua
#   scripts/lua-files.outputs.xcfilelist  — every destination path
#
# These files give Xcode an accurate incremental-build dependency graph so
# touching a listed .lua re-runs the copy phase and only that phase.
#
# Re-run this script after editing Packages/HSExtensions/extensions.manifest.
# The script is idempotent.
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"

MANIFEST="Packages/HSExtensions/extensions.manifest"
INPUTS="scripts/lua-files.inputs.xcfilelist"
OUTPUTS="scripts/lua-files.outputs.xcfilelist"

if [[ ! -f "$MANIFEST" ]]; then
    echo "error: manifest not found: $MANIFEST" >&2
    exit 1
fi

# Collect all lua file paths (repo-relative) from the manifest.
lua_paths=()
while IFS=$'\t' read -r dir _entry_points lua_files; do
    # strip comments and whitespace from dir
    dir="${dir%%#*}"
    dir="${dir#"${dir%%[![:space:]]*}"}"
    dir="${dir%"${dir##*[![:space:]]}"}"
    [[ -z "$dir" ]] && continue
    [[ "$lua_files" == "-" ]] && continue

    IFS=',' read -ra files <<< "$lua_files"
    for f in "${files[@]}"; do
        f="${f#"${f%%[![:space:]]*}"}"
        f="${f%"${f##*[![:space:]]}"}"
        [[ -z "$f" ]] && continue
        if [[ "$dir" == @* ]]; then
            # Special entry: lua_files column is a full repo-relative path
            lua_paths+=("$f")
        else
            lua_paths+=("extensions/${dir}/${f}")
        fi
    done
done < "$MANIFEST"

{
    # The manifest itself is an input — editing it must invalidate the phase.
    printf '$(SRCROOT)/%s\n' "$MANIFEST"
    for p in "${lua_paths[@]}"; do
        printf '$(SRCROOT)/%s\n' "$p"
    done
} > "$INPUTS"

{
    for p in "${lua_paths[@]}"; do
        base="$(basename "$p")"
        printf '$(BUILT_PRODUCTS_DIR)/$(UNLOCALIZED_RESOURCES_FOLDER_PATH)/extensions/hs/%s\n' "$base"
    done
} > "$OUTPUTS"

echo "  wrote $INPUTS ($(wc -l < "$INPUTS") lines)"
echo "  wrote $OUTPUTS ($(wc -l < "$OUTPUTS") lines)"
