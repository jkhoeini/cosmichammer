#!/usr/bin/env bash
# Copies every Lua file listed in Packages/HSExtensions/lua-files.list
# into the built Hammerspoon.app bundle under
# Contents/Resources/extensions/hs/<basename>.lua.
#
# This is the build-time replacement for the legacy "Copy Extension Lua files"
# PBXCopyFilesBuildPhase. Driven by a flat manifest so adding a new extension's
# Lua file only requires editing Packages/HSExtensions/lua-files.list — no
# pbxproj edit needed.
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
LIST_FILE="${SRCROOT}/Packages/HSExtensions/lua-files.list"

if [[ -z "${BUILT_PRODUCTS_DIR:-}" || -z "${UNLOCALIZED_RESOURCES_FOLDER_PATH:-}" ]]; then
    echo "error: BUILT_PRODUCTS_DIR / UNLOCALIZED_RESOURCES_FOLDER_PATH not set." >&2
    echo "       This script is meant to be run from an Xcode build phase." >&2
    exit 1
fi

# UNLOCALIZED_RESOURCES_FOLDER_PATH for an .app expands to
# "Hammerspoon.app/Contents/Resources" — the destination the legacy
# PBXCopyFilesBuildPhase used (dstSubfolderSpec 7 = Resources).
DEST_DIR="${BUILT_PRODUCTS_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}/extensions/hs"

if [[ ! -f "$LIST_FILE" ]]; then
    echo "error: manifest not found: $LIST_FILE" >&2
    exit 1
fi

mkdir -p "$DEST_DIR"

copied=0
while IFS= read -r raw; do
    # strip comments and whitespace
    line="${raw%%#*}"
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [[ -z "$line" ]] && continue

    src="${SRCROOT}/${line}"
    if [[ ! -f "$src" ]]; then
        echo "error: missing source: $src" >&2
        exit 1
    fi

    dst="${DEST_DIR}/$(basename "$line")"
    # ditto preserves attrs and is happier than cp for build-output writes
    /usr/bin/ditto "$src" "$dst"
    copied=$((copied + 1))
done < "$LIST_FILE"

echo "Copied ${copied} Lua files to ${DEST_DIR}"
