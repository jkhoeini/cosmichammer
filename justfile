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
    rm -rf Packages/.build

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
    unset GIT_DIR  # avoid leaking into SPM
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

    # --- Main build: compile Hammerspoon executable via SPM ---
    # Map Xcode-style config names to SPM -c values.
    if [ "{{ config }}" = "Release" ]; then
        spm_config="release"
    else
        spm_config="debug"
    fi

    SDK_PATH="$(xcrun --show-sdk-path)"
    swift build --package-path Packages \
        --product Hammerspoon \
        -c "${spm_config}" \
        -Xlinker -F -Xlinker "${SDK_PATH}/System/Library/PrivateFrameworks" \
        2>&1 | tee {{ build_dir }}/{{ config }}-build.log

    # --- Assemble .app bundle ---
    APP_DIR="{{ build_dir }}/Hammerspoon.app"
    CONTENTS="${APP_DIR}/Contents"
    MACOS="${CONTENTS}/MacOS"
    RESOURCES="${CONTENTS}/Resources"

    rm -rf "${APP_DIR}"
    mkdir -p "${MACOS}" "${RESOURCES}" "${CONTENTS}/Frameworks/hs"

    # Copy executable
    cp "Packages/.build/${spm_config}/Hammerspoon" "${MACOS}/Hammerspoon"

    # Generate Info.plist from template
    sed -e 's/${EXECUTABLE_NAME}/Hammerspoon/g' \
        -e 's/$(PRODUCT_BUNDLE_IDENTIFIER)/org.hammerspoon.Hammerspoon/g' \
        -e 's/${PRODUCT_NAME}/Hammerspoon/g' \
        -e "s/\$(MARKETING_VERSION)/${version}/g" \
        -e "s/\$(CURRENT_PROJECT_VERSION)/${build_num}/g" \
        -e 's/${MACOSX_DEPLOYMENT_TARGET}/26.0/g' \
        Hammerspoon/Hammerspoon-Info.plist > "${CONTENTS}/Info.plist"

    # PkgInfo
    printf 'APPL????' > "${CONTENTS}/PkgInfo"

    # Copy app resources
    cp Hammerspoon/Hammerspoon.icns "${RESOURCES}/"
    cp Hammerspoon/Spoon.icns       "${RESOURCES}/"
    cp Hammerspoon/Credits.rtf      "${RESOURCES}/"
    cp Hammerspoon/Hammerspoon.sdef "${RESOURCES}/"
    cp Hammerspoon/setup.lua        "${RESOURCES}/"
    cp Hammerspoon/statusicon.pdf   "${RESOURCES}/"

    # Extension resources
    cp extensions/doc/lua.json         "${RESOURCES}/"
    cp extensions/httpserver/timeout3   "${RESOURCES}/"
    cp {{ build_dir }}/docs.json       "${RESOURCES}/" 2>/dev/null || true

    # hs manpage
    mkdir -p "${RESOURCES}/man"
    cp extensions/ipc/cli/hs.man "${RESOURCES}/man/"

    # hsdocs
    mkdir -p "${RESOURCES}/extensions/hs/hsdocs"
    cp -R extensions/doc/hsdocs/* "${RESOURCES}/extensions/hs/hsdocs/" 2>/dev/null || true
    cp scripts/docs/templates/docs.css "${RESOURCES}/extensions/hs/hsdocs/"

    # CocoaLumberjack resource bundle (PrivacyInfo)
    CL_BUNDLE="Packages/.build/${spm_config}/CocoaLumberjack_CocoaLumberjack.bundle"
    if [ -d "$CL_BUNDLE" ]; then
        cp -R "$CL_BUNDLE" "${RESOURCES}/"
    fi

    # Copy hs CLI
    cp Packages/hs/.build/release/hs "${CONTENTS}/Frameworks/hs/hs"
    /usr/bin/codesign --force --sign - "${CONTENTS}/Frameworks/hs/hs"

    # Copy extension Lua files
    SRCROOT="$(pwd)" \
    BUILT_PRODUCTS_DIR="{{ build_dir }}" \
    UNLOCALIZED_RESOURCES_FOLDER_PATH="Hammerspoon.app/Contents/Resources" \
    ./scripts/copy-extension-lua-files.sh

    # Codesign with entitlements
    if [ "{{ config }}" = "Release" ]; then
        ENTITLEMENTS="Hammerspoon/Hammerspoon.entitlements"
    else
        ENTITLEMENTS="Hammerspoon/Hammerspoon-dev.entitlements"
    fi
    /usr/bin/codesign --force --sign - --deep --entitlements "${ENTITLEMENTS}" "${APP_DIR}"

# Run tests (uses xcodebuild; requires `just generate` first)
test config="Debug":
    #!/usr/bin/env bash
    set +e
    set -uo pipefail
    mkdir -p {{ build_dir }}/reports
    xcodebuild -workspace {{ workspace }} \
        -scheme {{ scheme }} \
        -configuration {{ config }} \
        -destination "platform=macOS" \
        -derivedDataPath {{ build_dir }}/DerivedData \
        -resultBundlePath {{ build_dir }}/TestResults \
        test 2>&1 | tee {{ build_dir }}/test.log

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
