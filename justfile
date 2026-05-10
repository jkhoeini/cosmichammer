# Hammerspoon build tasks

set shell := ["bash", "-euo", "pipefail", "-c"]

workspace := "Hammerspoon.xcworkspace"
scheme    := "Hammerspoon"
build_dir := "build"

default:
    @just --list

# Clean build artifacts
clean:
    rm -rf {{ build_dir }}
    xcodebuild -workspace {{ workspace }} -scheme {{ scheme }} -configuration Debug -destination "platform=macOS" clean

# Build Hammerspoon.app (config: Debug or Release)
build config="Debug":
    #!/usr/bin/env bash
    set -euo pipefail
    mkdir -p {{ build_dir }}
    xcodebuild -workspace {{ workspace }} \
        -scheme {{ scheme }} \
        -configuration {{ config }} \
        -destination "platform=macOS" \
        build | tee {{ build_dir }}/{{ config }}-build.log

# Run tests (requires build first)
test config="Debug":
    #!/usr/bin/env bash
    set +e
    set -uo pipefail
    mkdir -p {{ build_dir }}/reports
    xcodebuild -workspace {{ workspace }} \
        -scheme {{ scheme }} \
        -configuration {{ config }} \
        -resultBundlePath {{ build_dir }}/TestResults \
        test-without-building 2>&1 | tee {{ build_dir }}/test.log

# Build all documentation
docs:
    #!/usr/bin/env bash
    set -euo pipefail
    DOCSTOOL="scripts/docs/.build/release/BuildDocs"
    if [ ! -f "$DOCSTOOL" ]; then
        echo "Building docs tool..."
        swift build -c release --package-path scripts/docs
    fi
    mkdir -p {{ build_dir }}
    for fmt in json markdown html sql; do
        echo "Building docs $fmt..."
        "$DOCSTOOL" -o {{ build_dir }} --$fmt Hammerspoon extensions/
    done

# Lint documentation without building
docs-lint:
    #!/usr/bin/env bash
    set -euo pipefail
    DOCSTOOL="scripts/docs/.build/release/BuildDocs"
    if [ ! -f "$DOCSTOOL" ]; then
        echo "Building docs tool..."
        swift build -c release --package-path scripts/docs
    fi
    "$DOCSTOOL" --lint Hammerspoon extensions/

# Full rebuild: clean + build
rebuild: clean build
