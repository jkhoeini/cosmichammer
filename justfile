# Hammerspoon build tasks

# Default: list available tasks
default:
    @just --list

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
