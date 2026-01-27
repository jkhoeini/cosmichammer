#!/bin/bash
# Prepare GitHub Actions environment for testing

set -eu
set -o pipefail

export IS_CI=1
mkdir -p artifacts

# Remove the pre-installed Cocoapods binary (CI runners ship a stale version)
if [ -f /usr/local/bin/pod ]; then
    rm /usr/local/bin/pod
fi

# Install mise-managed tools (includes cocoapods)
mise install

# Install build dependencies
./scripts/build.sh installdeps

