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
    xcodebuild -workspace {{ workspace }} -scheme {{ scheme }} -configuration Debug -destination "platform=macOS" -derivedDataPath {{ build_dir }}/DerivedData clean

# Build Hammerspoon.app (config: Debug or Release)
build config="Debug":
    #!/usr/bin/env bash
    set -euo pipefail
    mkdir -p {{ build_dir }}

    # --- Pre-build: version numbers from git ---
    git_bin=$(sh /etc/profile; which git)
    # In a jj workspace the .git dir may live outside the working copy.
    # Resolve it via the jj store pointer when .git is absent locally.
    if [ ! -d .git ] && [ -f .jj/repo ] || [ -d .jj/repo/store ]; then
        if [ -f .jj/repo ]; then
            _repo_dir="$(cd "$(dirname .jj/repo)/$(cat .jj/repo)" && pwd)"
        else
            _repo_dir="$(pwd)/.jj/repo"
        fi
        _git_target="$(cat "${_repo_dir}/store/git_target")"
        case "$_git_target" in
            /*) export GIT_DIR="$_git_target" ;;
            *)  export GIT_DIR="${_repo_dir}/store/${_git_target}" ;;
        esac
    fi
    version=$("$git_bin" describe --tags --always --abbrev=0 | sed -e 's/^v//' -e 's/g//')
    build_num=$("$git_bin" rev-list $("$git_bin" describe --tags --always) --count)
    unset GIT_DIR  # avoid leaking into xcodebuild/SPM
    echo "Version: ${version} (${build_num})"

    # --- Pre-build: compile docs.json ---
    if [ -f ./scripts/docs/.build/release/BuildDocs ]; then
        ./scripts/docs/.build/release/BuildDocs -o ./build/ --json Hammerspoon extensions
    else
        echo "warning: BuildDocs not built, skipping docs.json. Run: swift build -c release --package-path scripts/docs"
        touch ./build/docs.json
    fi

    # --- Pre-build: build hs CLI ---
    swift build -c release --package-path Packages/hs

    # --- Main build ---
    xcodebuild -workspace {{ workspace }} \
        -scheme {{ scheme }} \
        -configuration {{ config }} \
        -destination "platform=macOS" \
        -derivedDataPath {{ build_dir }}/DerivedData \
        CURRENT_PROJECT_VERSION="${build_num}" \
        MARKETING_VERSION="${version}" \
        build 2>&1 | tee {{ build_dir }}/{{ config }}-build.log

    # --- Post-build: copy hs CLI into .app ---
    APP_DIR="{{ build_dir }}/DerivedData/Build/Products/{{ config }}/Hammerspoon.app"
    HS_DEST="${APP_DIR}/Contents/Frameworks/hs"
    mkdir -p "${HS_DEST}"
    cp Packages/hs/.build/release/hs "${HS_DEST}/hs"
    /usr/bin/codesign --force --sign - "${HS_DEST}/hs"

    # --- Post-build: copy extension Lua files ---
    SRCROOT="$(pwd)" \
    BUILT_PRODUCTS_DIR="{{ build_dir }}/DerivedData/Build/Products/{{ config }}" \
    UNLOCALIZED_RESOURCES_FOLDER_PATH="Hammerspoon.app/Contents/Resources" \
    ./scripts/copy-extension-lua-files.sh

    # --- Post-build: re-sign .app with entitlements ---
    # The hs CLI and Lua file copies happen after xcodebuild's CodeSign
    # step, which invalidates the sealed signature. Re-sign and apply
    # entitlements (moved out of Xcode's CODE_SIGN_ENTITLEMENTS).
    if [ "{{ config }}" = "Release" ]; then
        ENTITLEMENTS="Hammerspoon/Hammerspoon.entitlements"
    else
        ENTITLEMENTS="Hammerspoon/Hammerspoon-dev.entitlements"
    fi
    /usr/bin/codesign --force --sign - --deep --entitlements "${ENTITLEMENTS}" "${APP_DIR}"

# Run tests (requires build first)
test config="Debug":
    #!/usr/bin/env bash
    set +e
    set -uo pipefail
    mkdir -p {{ build_dir }}/reports
    xcodebuild -workspace {{ workspace }} \
        -scheme {{ scheme }} \
        -configuration {{ config }} \
        -derivedDataPath {{ build_dir }}/DerivedData \
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

# Generate Xcode project from project.yml
generate:
    xcodegen generate

# Full rebuild: clean + build
rebuild: clean build
