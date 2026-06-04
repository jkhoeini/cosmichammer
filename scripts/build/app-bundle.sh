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
    Debug|debug) config_name="Debug"; spm_config="debug" ;;
    Release|release) config_name="Release"; spm_config="release" ;;
    *) fail "unknown config '${config}'; expected Debug or Release" ;;
esac

case "$build_dir_arg" in
    /*) build_dir="$build_dir_arg" ;;
    *) build_dir="${repo_root}/${build_dir_arg}" ;;
esac

version_env="${build_dir}/version.env"
docs_json="${build_dir}/docs/docs.json"
app_dir="${build_dir}/Cosmic Hammer.app"
contents="${app_dir}/Contents"
macos="${contents}/MacOS"
resources="${contents}/Resources"
frameworks="${contents}/Frameworks"

[[ -f "$version_env" ]] || fail "missing ${version_env}; run 'just build-version' first"
[[ -f "$docs_json" ]] || fail "missing ${docs_json}; run 'just docs-json' first"
[[ -x "${repo_root}/.build/${spm_config}/CosmicHammer" ]] \
    || fail "missing .build/${spm_config}/CosmicHammer; run 'just spm-binary ${config_name}' first"
[[ -x "${repo_root}/.build/release/hs" ]] \
    || fail "missing .build/release/hs; run 'just hs-cli' first"

# shellcheck disable=SC1090
source "$version_env"

case "$build_dir" in
    ""|"/") fail "refusing unsafe build directory: $build_dir" ;;
esac
case "$app_dir" in
    "${build_dir}/"*) rm -rf "$app_dir" ;;
    *) fail "refusing to remove app path outside build directory: $app_dir" ;;
esac

mkdir -p "$macos" "$resources" "${frameworks}/hs"

/usr/bin/ditto "${repo_root}/.build/${spm_config}/CosmicHammer" "${macos}/CosmicHammer"

info_plist="${contents}/Info.plist"
/usr/bin/ditto "${repo_root}/CosmicHammer/CosmicHammer-Info.plist" "$info_plist"
/usr/bin/plutil -replace CFBundleExecutable -string "CosmicHammer" "$info_plist"
/usr/bin/plutil -replace CFBundleIdentifier -string "org.cosmic-hammer.CosmicHammer" "$info_plist"
/usr/bin/plutil -replace CFBundleName -string "Cosmic Hammer" "$info_plist"
/usr/bin/plutil -replace CFBundleShortVersionString -string "$MARKETING_VERSION" "$info_plist"
/usr/bin/plutil -replace CFBundleVersion -string "$CURRENT_PROJECT_VERSION" "$info_plist"
/usr/bin/plutil -replace LSMinimumSystemVersion -string "$MACOS_DEPLOYMENT_TARGET" "$info_plist"
/usr/bin/plutil -lint "$info_plist" >/dev/null

printf 'APPL????' > "${contents}/PkgInfo"

"${repo_root}/scripts/build/copy-resources.sh" "$resources" "$docs_json"
/usr/bin/ditto "${repo_root}/.build/release/hs" "${frameworks}/hs/hs"

"${repo_root}/scripts/build/smoke-resources.sh" "$resources" "$app_dir"
echo "Assembled ${app_dir#${repo_root}/} (${config_name})"
