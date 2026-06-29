#!/usr/bin/env bash
# Copies Lua files listed in the generated loader copy map into the built
# Cosmic Hammer.app bundle under Contents/Resources/extensions/.
set -euo pipefail

# When invoked by Xcode, SRCROOT / BUILT_PRODUCTS_DIR /
# UNLOCALIZED_RESOURCES_FOLDER_PATH are set. When run standalone, fail with
# a clear message because the destination is build-environment dependent.
SRCROOT="${SRCROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
COPY_MAP="${SRCROOT}/extensions/_coresetup/_loader_copy_map.tsv"

if [[ -z "${BUILT_PRODUCTS_DIR:-}" || -z "${UNLOCALIZED_RESOURCES_FOLDER_PATH:-}" ]]; then
    echo "error: BUILT_PRODUCTS_DIR / UNLOCALIZED_RESOURCES_FOLDER_PATH not set." >&2
    echo "       This script is meant to be run from an Xcode build phase." >&2
    exit 1
fi

DEST_ROOT="${BUILT_PRODUCTS_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}/extensions"

if [[ ! -f "$COPY_MAP" ]]; then
    echo "error: generated copy map not found: $COPY_MAP" >&2
    echo "       Run scripts/generate-hsextensions.sh first." >&2
    exit 1
fi

trim() {
    local value="$1"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    printf '%s' "$value"
}

is_safe_relative_path() {
    local path="$1"
    local component
    [[ -n "$path" && "$path" != /* ]] || return 1

    local IFS='/'
    for component in $path; do
        [[ -n "$component" && "$component" != "." && "$component" != ".." ]] || return 1
    done
}

sources=()
destinations=()
modules=()
seen_destinations=()

line_no=0
while IFS=$'\t' read -r source bundle_path module extra || [[ -n "${source:-}" ]]; do
    line_no=$((line_no + 1))
    source="$(trim "${source:-}")"
    [[ -z "$source" ]] && continue
    [[ "$source" == \#* ]] && continue
    [[ -z "${extra:-}" ]] || {
        echo "error: $COPY_MAP:$line_no: expected source, bundle path, and module columns" >&2
        exit 1
    }
    bundle_path="$(trim "${bundle_path:-}")"
    module="$(trim "${module:-}")"
    [[ -n "$bundle_path" && -n "$module" ]] || {
        echo "error: $COPY_MAP:$line_no: missing bundle path or module" >&2
        exit 1
    }
    is_safe_relative_path "$source" || {
        echo "error: $COPY_MAP:$line_no: unsafe source path: $source" >&2
        exit 1
    }
    is_safe_relative_path "$bundle_path" || {
        echo "error: $COPY_MAP:$line_no: unsafe bundle path: $bundle_path" >&2
        exit 1
    }

    if ((${#seen_destinations[@]})); then
        for seen in "${seen_destinations[@]}"; do
            if [[ "$seen" == "$bundle_path" ]]; then
                echo "error: duplicate Lua bundle destination before copy: extensions/${bundle_path}" >&2
                echo "       Regenerate metadata after fixing extensions.manifest." >&2
                exit 1
            fi
        done
    fi
    seen_destinations+=("$bundle_path")
    sources+=("$source")
    destinations+=("$bundle_path")
    modules+=("$module")
done < "$COPY_MAP"

mkdir -p "$DEST_ROOT"

copied=0
for i in "${!sources[@]}"; do
    src="${SRCROOT}/${sources[$i]}"
    dst="${DEST_ROOT}/${destinations[$i]}"
    if [[ ! -f "$src" ]]; then
        echo "error: missing source for ${modules[$i]}: $src" >&2
        exit 1
    fi

    mkdir -p "$(dirname "$dst")"
    /usr/bin/ditto "$src" "$dst"
    copied=$((copied + 1))
done

echo "Copied ${copied} Lua files to ${DEST_ROOT}"
