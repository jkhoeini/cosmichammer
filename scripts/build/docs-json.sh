#!/usr/bin/env bash
set -euo pipefail

fail() {
    echo "error: $*" >&2
    exit 1
}

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "${script_dir}/../.." && pwd)"
dest_arg="${1:-build/docs}"

case "$dest_arg" in
    /*) dest_dir="$dest_arg" ;;
    *) dest_dir="${repo_root}/${dest_arg}" ;;
esac

cd "$repo_root"

docs_tool="scripts/docs/.build/release/BuildDocs"
if [[ ! -f "$docs_tool" ]]; then
    echo "Building docs tool..."
    swift build -c release --package-path scripts/docs
fi

mkdir -p "$dest_dir"
dest_dir="$(cd "$dest_dir" && pwd)"
"$docs_tool" -o "$dest_dir" --json extensions

[[ -f "${dest_dir}/docs.json" ]] || fail "docs tool did not write ${dest_dir}/docs.json"
[[ -f "${dest_dir}/docs_index.json" ]] || fail "docs tool did not write ${dest_dir}/docs_index.json"

# Keep the historical build/docs.json outputs fresh for callers that have not
# switched to build/docs yet.
if [[ "$dest_dir" == "${repo_root}/build/docs" ]]; then
    /usr/bin/ditto "${dest_dir}/docs.json" "${repo_root}/build/docs.json"
    /usr/bin/ditto "${dest_dir}/docs_index.json" "${repo_root}/build/docs_index.json"
fi

echo "Wrote ${dest_dir#${repo_root}/}/docs.json"
