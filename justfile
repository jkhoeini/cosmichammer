# Cosmic Hammer build tasks

set shell := ["bash", "-euo", "pipefail", "-c"]

build_dir := "build"

default:
    @just --list

# Clean build artifacts
clean:
    rm -rf {{ build_dir }}
    rm -rf .build

# Build Cosmic Hammer.app (config: Debug or Release)
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
        ./scripts/docs/.build/release/BuildDocs -o ./build/ --json extensions
    else
        echo "warning: BuildDocs not built, skipping docs.json. Run: swift build -c release --package-path scripts/docs"
        touch ./build/docs.json
    fi

    # --- Pre-build: build hs CLI ---
    swift build -c release --product hs

    # --- Main build: compile Cosmic Hammer executable via SPM ---
    # Map Xcode-style config names to SPM -c values.
    if [ "{{ config }}" = "Release" ]; then
        spm_config="release"
    else
        spm_config="debug"
    fi

    SDK_PATH="$(xcrun --show-sdk-path)"
    swift build \
        --product CosmicHammer \
        -c "${spm_config}" \
        -Xlinker -F -Xlinker "${SDK_PATH}/System/Library/PrivateFrameworks" \
        2>&1 | tee {{ build_dir }}/{{ config }}-build.log

    # --- Assemble .app bundle ---
    APP_DIR="{{ build_dir }}/Cosmic Hammer.app"
    CONTENTS="${APP_DIR}/Contents"
    MACOS="${CONTENTS}/MacOS"
    RESOURCES="${CONTENTS}/Resources"

    rm -rf "${APP_DIR}"
    mkdir -p "${MACOS}" "${RESOURCES}" "${CONTENTS}/Frameworks/hs"

    # Copy executable
    cp ".build/${spm_config}/CosmicHammer" "${MACOS}/CosmicHammer"

    # Generate Info.plist from template
    sed -e 's/${EXECUTABLE_NAME}/CosmicHammer/g' \
        -e 's/$(PRODUCT_BUNDLE_IDENTIFIER)/org.cosmic-hammer.CosmicHammer/g' \
        -e 's/${PRODUCT_NAME}/Cosmic Hammer/g' \
        -e "s/\$(MARKETING_VERSION)/${version}/g" \
        -e "s/\$(CURRENT_PROJECT_VERSION)/${build_num}/g" \
        -e 's/${MACOSX_DEPLOYMENT_TARGET}/26.0/g' \
        CosmicHammer/CosmicHammer-Info.plist > "${CONTENTS}/Info.plist"

    # PkgInfo
    printf 'APPL????' > "${CONTENTS}/PkgInfo"

    # Copy app resources
    cp CosmicHammer/CosmicHammer.icns "${RESOURCES}/"
    cp CosmicHammer/Spoon.icns        "${RESOURCES}/"
    cp CosmicHammer/Credits.rtf       "${RESOURCES}/"
    cp CosmicHammer/CosmicHammer.sdef "${RESOURCES}/"
    cp CosmicHammer/setup.lua         "${RESOURCES}/"
    cp CosmicHammer/statusicon.pdf    "${RESOURCES}/"

    # Extension resources
    cp extensions/doc/lua.json         "${RESOURCES}/"
    cp extensions/httpserver/timeout3   "${RESOURCES}/"
    cp {{ build_dir }}/docs.json       "${RESOURCES}/" 2>/dev/null || true

    # hs manpage
    mkdir -p "${RESOURCES}/man"
    cp Sources/hs/hs.man "${RESOURCES}/man/"

    # hsdocs
    mkdir -p "${RESOURCES}/extensions/hs/hsdocs"
    cp -R extensions/doc/hsdocs/* "${RESOURCES}/extensions/hs/hsdocs/" 2>/dev/null || true
    cp scripts/docs/templates/docs.css "${RESOURCES}/extensions/hs/hsdocs/"

    # CocoaLumberjack resource bundle (PrivacyInfo)
    CL_BUNDLE=".build/${spm_config}/CocoaLumberjack_CocoaLumberjack.bundle"
    if [ -d "$CL_BUNDLE" ]; then
        cp -R "$CL_BUNDLE" "${RESOURCES}/"
    fi

    # Copy hs CLI
    cp .build/release/hs "${CONTENTS}/Frameworks/hs/hs"
    /usr/bin/codesign --force --sign - "${CONTENTS}/Frameworks/hs/hs"

    # Copy extension Lua files
    SRCROOT="$(pwd)" \
    BUILT_PRODUCTS_DIR="{{ build_dir }}" \
    UNLOCALIZED_RESOURCES_FOLDER_PATH="Cosmic Hammer.app/Contents/Resources" \
    ./scripts/copy-extension-lua-files.sh

    # Codesign with entitlements
    if [ "{{ config }}" = "Release" ]; then
        ENTITLEMENTS="CosmicHammer/CosmicHammer.entitlements"
    else
        ENTITLEMENTS="CosmicHammer/CosmicHammer-dev.entitlements"
    fi
    /usr/bin/codesign --force --sign - --deep --entitlements "${ENTITLEMENTS}" "${APP_DIR}"

# Run tests (SPM test target; requires `just build` first for Lua resources)
test:
    #!/usr/bin/env bash
    set -euo pipefail
    mkdir -p {{ build_dir }}
    SDK_PATH="$(xcrun --show-sdk-path)"
    swift test \
        -Xlinker -F -Xlinker "${SDK_PATH}/System/Library/PrivateFrameworks" \
        2>&1 | tee {{ build_dir }}/test.log

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
        "$DOCSTOOL" -o {{ build_dir }} --$fmt extensions/
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
    "$DOCSTOOL" --lint extensions/

# Generate Xcode project and workspace from project.yml
generate:
    #!/usr/bin/env bash
    set -euo pipefail
    xcodegen generate
    rm -rf CosmicHammer.xcworkspace
    mkdir -p CosmicHammer.xcworkspace/xcshareddata/xcschemes
    cat > CosmicHammer.xcworkspace/contents.xcworkspacedata << 'XCWS'
    <?xml version="1.0" encoding="UTF-8"?>
    <Workspace
       version = "1.0">
       <FileRef
          location = "group:CosmicHammer.xcodeproj">
       </FileRef>
    </Workspace>
    XCWS
    mv CosmicHammer.xcodeproj/xcshareddata/xcschemes/*.xcscheme \
       CosmicHammer.xcworkspace/xcshareddata/xcschemes/

# Full rebuild: clean + build
rebuild: clean build

# Create a GitHub release with DMG
release version:
    #!/usr/bin/env bash
    set -euo pipefail

    TAG="v{{ version }}"
    DMG_NAME="CosmicHammer-{{ version }}-macos-arm64.dmg"
    OUTPUT_DIR="release"

    # ── Preflight ─────────────────────────────────────────────────────────
    command -v gh >/dev/null \
        || { echo "Error: gh CLI not found — install with: brew install gh" >&2; exit 1; }
    command -v create-dmg >/dev/null \
        || { echo "Error: create-dmg not found — install with: brew install create-dmg" >&2; exit 1; }

    if gh release view "$TAG" &>/dev/null; then
        echo "Error: release $TAG already exists on GitHub" >&2
        exit 1
    fi

    # ── Tag ───────────────────────────────────────────────────────────────
    echo "===> Tagging $TAG"
    jj tag create "$TAG" -r dev 2>/dev/null \
        || git tag "$TAG" $(jj log -r dev --no-graph -T commit_id --limit 1)
    git push origin "$TAG"

    # ── Build Release ─────────────────────────────────────────────────────
    echo "===> Building Cosmic Hammer {{ version }} (Release)"
    just build Release

    # ── Package DMG ───────────────────────────────────────────────────────
    echo "===> Creating $DMG_NAME"
    rm -rf "$OUTPUT_DIR"
    mkdir -p "$OUTPUT_DIR"

    create-dmg \
        --volname "Cosmic Hammer" \
        --window-pos 200 120 \
        --window-size 600 380 \
        --icon-size 100 \
        --icon "Cosmic Hammer.app" 150 180 \
        --hide-extension "Cosmic Hammer.app" \
        --app-drop-link 450 180 \
        --no-internet-enable \
        "$OUTPUT_DIR/$DMG_NAME" \
        "{{ build_dir }}/Cosmic Hammer.app"

    echo "===> DMG ready:"
    ls -lh "$OUTPUT_DIR/$DMG_NAME"

    # ── Publish GitHub release ────────────────────────────────────────────
    RELEASE_NOTES="$(cat <<NOTES
    ## Cosmic Hammer {{ version }}

    ### Install

    Download \`$DMG_NAME\`, open the DMG, and drag **Cosmic Hammer** to Applications.

    If macOS blocks the app on first launch:
    \`\`\`
    xattr -dr com.apple.quarantine /Applications/Cosmic\ Hammer.app
    \`\`\`

    ### Requirements

    - macOS 26+
    NOTES
    )"

    echo "===> Publishing $TAG to GitHub"
    gh release create "$TAG" \
        --title "$TAG" \
        --notes "$RELEASE_NOTES" \
        "$OUTPUT_DIR/$DMG_NAME"

    echo "===> Release $TAG published ✓"

    # ── Update flake.nix with new version + hash ─────────────────────────
    DMG_HASH=$(nix hash to-sri --type sha256 $(shasum -a 256 "$OUTPUT_DIR/$DMG_NAME" | cut -d' ' -f1))
    sed -i '' \
        -e "s|version = \".*\";|version = \"{{ version }}\";|" \
        -e "s|hash = \".*\";|hash = \"${DMG_HASH}\";|" \
        flake.nix
    echo "===> Updated flake.nix to {{ version }} (${DMG_HASH})"
