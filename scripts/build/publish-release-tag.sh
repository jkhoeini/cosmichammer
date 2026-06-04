#!/usr/bin/env bash
set -euo pipefail

fail() {
    echo "error: $*" >&2
    exit 1
}

tag="${1:?usage: publish-release-tag.sh TAG [REV]}"
rev="${2:-dev}"

command -v jj >/dev/null 2>&1 || fail "jj is required to publish release tags"
git_bin="$(sh -c '. /etc/profile >/dev/null 2>&1 || true; command -v git' 2>/dev/null || true)"
git_bin="${git_bin:-$(command -v git || true)}"
[[ -n "$git_bin" ]] || fail "git is required for GitHub tag publishing interop"

echo "===> Tagging ${tag}"
if jj tag set "$tag" -r "$rev" 2>/dev/null; then
    jj git export >/dev/null
else
    "$git_bin" tag "$tag" "$(jj log -r "$rev" --no-graph -T commit_id --limit 1)"
fi

# GitHub releases consume Git tags, so the final publish remains Git interop.
"$git_bin" push origin "$tag"
