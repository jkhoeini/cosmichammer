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
    for cmd in just python3 ruby jq xcbeautify pod; do
        if ! command -v $cmd &>/dev/null; then
            echo "ERROR: $cmd not found. Run: mise install"
            exit 1
        fi
    done
    echo "  mise tools: OK (incl. CocoaPods $(pod --version))"
    
    # Check pods installed (check Pods directory exists)
    if [[ ! -d "Pods" ]]; then
        echo "ERROR: Pods not installed. Run: pod install"
        exit 1
    fi
    echo "  Pods: OK"
    
    # Check Python requirements (build scripts use /usr/bin/python3)
    if ! /usr/bin/python3 -c "import jinja2, mistune, pygments" &>/dev/null; then
        echo "ERROR: Python requirements not satisfied. Run: /usr/bin/pip3 install --user -r requirements.txt"
        exit 1
    fi
    echo "  Python requirements: OK"
    
    echo "All dependencies OK!"

# Install all dependencies
setup:
    mise install
    pod install
    /usr/bin/pip3 install --user -r requirements.txt

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
