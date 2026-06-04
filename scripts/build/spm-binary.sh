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

mkdir -p "$build_dir"
cd "$repo_root"

sdk_path="$(xcrun --show-sdk-path)"
swift build \
    --product CosmicHammer \
    -c "$spm_config" \
    -Xlinker -F -Xlinker "${sdk_path}/System/Library/PrivateFrameworks" \
    2>&1 | tee "${build_dir}/${config_name}-build.log"

[[ -x "${repo_root}/.build/${spm_config}/CosmicHammer" ]] \
    || fail "SPM did not produce .build/${spm_config}/CosmicHammer"
