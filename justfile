# Hammerspoon build tasks

# Default: list available tasks
default:
    @just --list

# Check all dependencies are installed
check:
    #!/usr/bin/env bash
    set -euo pipefail
    echo "Checking dependencies..."
    
    # Check Xcode
    XCODE_PATH=$(xcode-select -p 2>/dev/null || echo "")
    if [[ ! "$XCODE_PATH" == *"Xcode"* ]]; then
        echo "ERROR: Xcode not found. Install from App Store and run: sudo xcode-select -s /Applications/Xcode.app"
        exit 1
    fi
    echo "  Xcode: OK ($XCODE_PATH)"
    
    # Check mise tools
    for cmd in just xcbeautify; do
        if ! command -v $cmd &>/dev/null; then
            echo "ERROR: $cmd not found. Run: mise install"
            exit 1
        fi
    done
    echo "  mise tools: OK"

    echo "All dependencies OK!"

# Install all dependencies
setup:
    mise install
    swift build -c release --package-path scripts/docs

# Clean build artifacts
clean:
    ./scripts/build.sh clean

# Build debug configuration
build:
    ./scripts/build.sh build

# Run tests (requires build first)
test:
    ./scripts/build.sh test

# Build documentation
docs:
    ./scripts/build.sh docs

# Full rebuild: clean + build
rebuild: clean build
