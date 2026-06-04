#!/usr/bin/env bash
set -euo pipefail

fail() {
    echo "error: $*" >&2
    exit 1
}

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "${script_dir}/../.." && pwd)"
build_dir_arg="${1:-build}"

case "$build_dir_arg" in
    /*) build_dir="$build_dir_arg" ;;
    *) build_dir="${repo_root}/${build_dir_arg}" ;;
esac

mkdir -p "$build_dir"
cd "$repo_root"

package_target="$(
    sed -nE 's/.*platforms:.*\.macOS\(\.v([0-9]+)\).*/\1.0/p' Package.swift | head -n 1
)"
[[ -n "$package_target" ]] || fail "could not derive macOS deployment target from Package.swift"

info_template="CosmicHammer/CosmicHammer-Info.plist"
[[ -f "$info_template" ]] || fail "missing Info.plist template: $info_template"

marketing_placeholder="$(/usr/bin/plutil -extract CFBundleShortVersionString raw -o - "$info_template")"
build_placeholder="$(/usr/bin/plutil -extract CFBundleVersion raw -o - "$info_template")"
minimum_placeholder="$(/usr/bin/plutil -extract LSMinimumSystemVersion raw -o - "$info_template")"
[[ "$marketing_placeholder" == '$(MARKETING_VERSION)' ]] \
    || fail "Info.plist CFBundleShortVersionString must be \$(MARKETING_VERSION)"
[[ "$build_placeholder" == '$(CURRENT_PROJECT_VERSION)' ]] \
    || fail "Info.plist CFBundleVersion must be \$(CURRENT_PROJECT_VERSION)"
[[ "$minimum_placeholder" == '${MACOSX_DEPLOYMENT_TARGET}' ]] \
    || fail "Info.plist LSMinimumSystemVersion must be \${MACOSX_DEPLOYMENT_TARGET}"

git_bin="$(sh -c '. /etc/profile >/dev/null 2>&1 || true; command -v git' 2>/dev/null || true)"
git_bin="${git_bin:-$(command -v git || true)}"
[[ -n "$git_bin" ]] || fail "git is required for tag describe/count version metadata"

configure_git_dir_from_jj() {
    [[ -d "${repo_root}/.git" ]] && return 0

    local jj_repo_dir=""
    if [[ -f "${repo_root}/.jj/repo" ]]; then
        local repo_pointer
        repo_pointer="$(cat "${repo_root}/.jj/repo")"
        jj_repo_dir="$(cd "${repo_root}/.jj/$(dirname "$repo_pointer")" && cd "$(basename "$repo_pointer")" && pwd)"
    elif [[ -d "${repo_root}/.jj/repo/store" ]]; then
        jj_repo_dir="${repo_root}/.jj/repo"
    else
        return 0
    fi

    local git_target_file="${jj_repo_dir}/store/git_target"
    [[ -f "$git_target_file" ]] || return 0

    local git_target
    git_target="$(cat "$git_target_file")"
    case "$git_target" in
        /*) export GIT_DIR="$git_target" ;;
        *)
            export GIT_DIR="$(cd "${jj_repo_dir}/store/$(dirname "$git_target")" && pwd)/$(basename "$git_target")"
            ;;
    esac
}

revision_selector="${JJ_VERSION_REV:-@}"
source_revision_method=""
source_revision=""
if command -v jj >/dev/null 2>&1 && jj root >/dev/null 2>&1; then
    jj git export >/dev/null 2>&1 || true
    source_revision="$(jj log -r "$revision_selector" --no-graph -T commit_id)"
    source_revision_method="jj log -r ${revision_selector}"
else
    source_revision="$("$git_bin" rev-parse HEAD)"
    source_revision_method="git rev-parse HEAD"
fi

[[ -n "$source_revision" ]] || fail "could not resolve source revision"

configure_git_dir_from_jj

# Git interop is intentionally isolated here: the existing build derives the
# marketing version and monotonic build number from Git tag describe/rev-list.
describe_nearest="$("$git_bin" describe --tags --always --abbrev=0 "$source_revision")" \
    || fail "could not describe nearest tag for $source_revision"
describe_current="$("$git_bin" describe --tags --always "$source_revision")" \
    || fail "could not describe current revision $source_revision"
marketing_version="$(printf '%s' "$describe_nearest" | sed -e 's/^v//' -e 's/g//')"
current_project_version="$("$git_bin" rev-list "$describe_current" --count)" \
    || fail "could not derive build number from $describe_current"
unset GIT_DIR

version_env="${build_dir}/version.env"
version_json="${build_dir}/version.json"

{
    printf 'MARKETING_VERSION=%q\n' "$marketing_version"
    printf 'CURRENT_PROJECT_VERSION=%q\n' "$current_project_version"
    printf 'MACOS_DEPLOYMENT_TARGET=%q\n' "$package_target"
    printf 'SOURCE_REVISION=%q\n' "$source_revision"
    printf 'SOURCE_REVISION_METHOD=%q\n' "$source_revision_method"
    printf 'VERSION_METHOD=%q\n' "jj-selected revision with git describe/rev-list"
    printf 'GIT_DESCRIBE=%q\n' "$describe_current"
} > "${version_env}.tmp"
mv "${version_env}.tmp" "$version_env"

rm -f "${version_json}.tmp"
/usr/bin/plutil -create xml1 "${version_json}.tmp"
/usr/bin/plutil -replace MARKETING_VERSION -string "$marketing_version" "${version_json}.tmp"
/usr/bin/plutil -replace CURRENT_PROJECT_VERSION -string "$current_project_version" "${version_json}.tmp"
/usr/bin/plutil -replace MACOS_DEPLOYMENT_TARGET -string "$package_target" "${version_json}.tmp"
/usr/bin/plutil -replace SOURCE_REVISION -string "$source_revision" "${version_json}.tmp"
/usr/bin/plutil -replace SOURCE_REVISION_METHOD -string "$source_revision_method" "${version_json}.tmp"
/usr/bin/plutil -replace VERSION_METHOD -string "jj-selected revision with git describe/rev-list" "${version_json}.tmp"
/usr/bin/plutil -replace GIT_DESCRIBE -string "$describe_current" "${version_json}.tmp"
/usr/bin/plutil -convert json -r "${version_json}.tmp"
mv "${version_json}.tmp" "$version_json"

echo "Version: ${marketing_version} (${current_project_version})"
echo "Wrote ${version_env#${repo_root}/} and ${version_json#${repo_root}/}"
