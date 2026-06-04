#!/usr/bin/env bash
set -euo pipefail

fail() {
    echo "error: $*" >&2
    exit 1
}

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "${script_dir}/../.." && pwd)"
config="${1:-Debug}"
build_dir_arg="${2:-build}"

case "$config" in
    Debug|debug) config_name="Debug"; entitlements="CosmicHammer/CosmicHammer-dev.entitlements" ;;
    Release|release) config_name="Release"; entitlements="CosmicHammer/CosmicHammer.entitlements" ;;
    *) fail "unknown config '${config}'; expected Debug or Release" ;;
esac

case "$build_dir_arg" in
    /*) build_dir="$build_dir_arg" ;;
    *) build_dir="${repo_root}/${build_dir_arg}" ;;
esac

app_dir="${build_dir}/Cosmic Hammer.app"
cli="${app_dir}/Contents/Frameworks/hs/hs"

[[ -x "$cli" ]] || fail "missing hs CLI at $cli; run 'just app-bundle ${config_name}' first"
[[ -d "$app_dir" ]] || fail "missing app bundle at $app_dir; run 'just app-bundle ${config_name}' first"

cd "$repo_root"
/usr/bin/codesign --force --sign - "$cli"
if [[ "$config_name" == "Release" ]]; then
    /usr/bin/codesign --force --sign - --deep --options runtime --entitlements "$entitlements" "$app_dir"
else
    /usr/bin/codesign --force --sign - --deep --entitlements "$entitlements" "$app_dir"
fi

echo "Signed ${app_dir#${repo_root}/} (${config_name})"
