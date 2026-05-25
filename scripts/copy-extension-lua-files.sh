#!/usr/bin/env bash
# Copies every Lua file listed in Packages/HSExtensions/extensions.manifest
# into the built Cosmic Hammer.app bundle under
# Contents/Resources/extensions/hs/<basename>.lua.
#
# This is the build-time replacement for the legacy "Copy Extension Lua files"
# PBXCopyFilesBuildPhase. Driven by the unified manifest so adding a new
# extension's Lua file only requires editing
# Packages/HSExtensions/extensions.manifest — no pbxproj edit needed.
#
# Invoked as an Xcode Run Script build phase. The phase declares the manifest
# and every source path as inputs and every destination as outputs (via
# xcfilelists generated from the same manifest) so Xcode's incremental build
# graph stays correct.
set -euo pipefail

# When invoked by Xcode, SRCROOT / BUILT_PRODUCTS_DIR /
# UNLOCALIZED_RESOURCES_FOLDER_PATH are set. When run standalone (e.g. for
# ad-hoc smoke-testing), fall back to the repo root and a sentinel destination.
SRCROOT="${SRCROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
MANIFEST="${SRCROOT}/Packages/HSExtensions/extensions.manifest"

if [[ -z "${BUILT_PRODUCTS_DIR:-}" || -z "${UNLOCALIZED_RESOURCES_FOLDER_PATH:-}" ]]; then
    echo "error: BUILT_PRODUCTS_DIR / UNLOCALIZED_RESOURCES_FOLDER_PATH not set." >&2
    echo "       This script is meant to be run from an Xcode build phase." >&2
    exit 1
fi

# UNLOCALIZED_RESOURCES_FOLDER_PATH for an .app expands to
# "Cosmic Hammer.app/Contents/Resources" — the destination the legacy
# PBXCopyFilesBuildPhase used (dstSubfolderSpec 7 = Resources).
DEST_DIR="${BUILT_PRODUCTS_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}/extensions/hs"

if [[ ! -f "$MANIFEST" ]]; then
    echo "error: manifest not found: $MANIFEST" >&2
    exit 1
fi

mkdir -p "$DEST_DIR"

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
            lua_paths+=("$f")
        else
            lua_paths+=("extensions/${dir}/${f}")
        fi
    done
done < "$MANIFEST"

copied=0
for line in "${lua_paths[@]}"; do
    src="${SRCROOT}/${line}"
    if [[ ! -f "$src" ]]; then
        echo "error: missing source: $src" >&2
        exit 1
    fi

    dst="${DEST_DIR}/$(basename "$line")"
    # ditto preserves attrs and is happier than cp for build-output writes
    /usr/bin/ditto "$src" "$dst"
    copied=$((copied + 1))
done

echo "Copied ${copied} Lua files to ${DEST_DIR}"
