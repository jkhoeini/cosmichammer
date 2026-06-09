#!/usr/bin/env bash
set -euo pipefail

fail() {
    echo "error: $*" >&2
    exit 1
}

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "${script_dir}/../.." && pwd)"

dest_arg="${1:?usage: copy-resources.sh DEST_ROOT [DOCS_JSON]}"
docs_arg="${2:-build/docs/docs.json}"

case "$dest_arg" in
    /*) dest_root="$dest_arg" ;;
    *) dest_root="${repo_root}/${dest_arg}" ;;
esac
case "$docs_arg" in
    /*) docs_json="$docs_arg" ;;
    *) docs_json="${repo_root}/${docs_arg}" ;;
esac

copy_required() {
    local src="$1"
    local dst="$2"
    [[ -f "$src" ]] || fail "missing required resource: $src"
    mkdir -p "$(dirname "$dst")"
    /usr/bin/ditto "$src" "$dst"
}

[[ -f "$docs_json" ]] || fail "missing docs.json: $docs_json; run 'just docs-json' first"

mkdir -p "$dest_root"

copy_required "${repo_root}/CosmicHammer/CosmicHammer.icns" "${dest_root}/CosmicHammer.icns"
copy_required "${repo_root}/CosmicHammer/Credits.rtf" "${dest_root}/Credits.rtf"
copy_required "${repo_root}/CosmicHammer/CosmicHammer.sdef" "${dest_root}/CosmicHammer.sdef"
copy_required "${repo_root}/CosmicHammer/setup.lua" "${dest_root}/setup.lua"
copy_required "${repo_root}/CosmicHammer/statusicon.pdf" "${dest_root}/statusicon.pdf"

copy_required "${repo_root}/extensions/doc/lua.json" "${dest_root}/lua.json"
copy_required "${repo_root}/extensions/httpserver/timeout3" "${dest_root}/timeout3"
copy_required "$docs_json" "${dest_root}/docs.json"

copy_required "${repo_root}/Sources/hs/hs.man" "${dest_root}/man/hs.man"

mkdir -p "${dest_root}/extensions/hs/hsdocs"
/usr/bin/ditto "${repo_root}/extensions/doc/hsdocs" "${dest_root}/extensions/hs/hsdocs"
copy_required "${repo_root}/scripts/docs/templates/docs.css" "${dest_root}/extensions/hs/hsdocs/docs.css"

cd "$repo_root"
SRCROOT="$repo_root" \
BUILT_PRODUCTS_DIR="$(dirname "$dest_root")" \
UNLOCALIZED_RESOURCES_FOLDER_PATH="$(basename "$dest_root")" \
    "${repo_root}/scripts/copy-extension-lua-files.sh"

"${repo_root}/scripts/build/smoke-resources.sh" "$dest_root"
