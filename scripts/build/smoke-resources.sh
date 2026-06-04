#!/usr/bin/env bash
set -euo pipefail

fail() {
    echo "error: $*" >&2
    exit 1
}

resource_root="${1:?usage: smoke-resources.sh RESOURCE_ROOT [APP_DIR]}"
app_dir="${2:-}"

missing=()
required_files=(
    "setup.lua"
    "docs.json"
    "lua.json"
    "timeout3"
    "man/hs.man"
    "extensions/hs/_loader_metadata.lua"
    "extensions/hs/_coresetup.lua"
    "extensions/hs/application.lua"
    "extensions/hs/doc.lua"
    "extensions/hs/network_ping.lua"
    "extensions/hs/hsdocs/init.lua"
    "extensions/hs/hsdocs/docs.css"
)

for rel in "${required_files[@]}"; do
    [[ -f "${resource_root}/${rel}" ]] || missing+=("${resource_root}/${rel}")
done

[[ -x "${resource_root}/timeout3" ]] || missing+=("${resource_root}/timeout3 (not executable)")

if [[ -d "${resource_root}/extensions/hs" ]]; then
    lua_count="$(find "${resource_root}/extensions/hs" -maxdepth 1 -type f -name '*.lua' | wc -l | tr -d '[:space:]')"
else
    lua_count=0
fi
[[ "$lua_count" -ge 50 ]] || missing+=("${resource_root}/extensions/hs/*.lua (expected at least 50, found ${lua_count})")

if [[ -n "$app_dir" ]]; then
    app_required=(
        "Contents/Info.plist"
        "Contents/PkgInfo"
        "Contents/MacOS/CosmicHammer"
        "Contents/Frameworks/hs/hs"
    )
    for rel in "${app_required[@]}"; do
        [[ -f "${app_dir}/${rel}" ]] || missing+=("${app_dir}/${rel}")
    done
    [[ -x "${app_dir}/Contents/MacOS/CosmicHammer" ]] || missing+=("${app_dir}/Contents/MacOS/CosmicHammer (not executable)")
    [[ -x "${app_dir}/Contents/Frameworks/hs/hs" ]] || missing+=("${app_dir}/Contents/Frameworks/hs/hs (not executable)")
fi

if [[ "${#missing[@]}" -gt 0 ]]; then
    printf 'error: resource smoke check failed; missing required build outputs:\n' >&2
    printf '  %s\n' "${missing[@]}" >&2
    exit 1
fi

echo "Resource smoke check passed: ${resource_root}"
