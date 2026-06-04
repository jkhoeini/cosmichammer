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
    just build-version
    just docs-json
    just hs-cli
    just spm-binary {{ config }}
    just app-bundle {{ config }}
    just sign-app {{ config }}
    just bundle-smoke

# Write build/version.env and build/version.json
build-version:
    ./scripts/build/version-metadata.sh {{ build_dir }}

# Build docs JSON artifacts under build/docs
docs-json:
    ./scripts/build/docs-json.sh {{ build_dir }}/docs

# Build the release hs CLI product
hs-cli:
    swift build -c release --product hs

# Build the CosmicHammer SPM executable (config: Debug or Release)
spm-binary config="Debug":
    ./scripts/build/spm-binary.sh {{ config }} {{ build_dir }}

# Copy runtime/test resources into a resource root
resources dest docs_json="{{ build_dir }}/docs/docs.json":
    ./scripts/build/copy-resources.sh "{{ dest }}" "{{ docs_json }}"

# Prepare Lua resources for swift test without assembling or signing the app
test-resources: docs-json hs-cli
    rm -rf "{{ build_dir }}/test"
    ./scripts/build/copy-resources.sh "{{ build_dir }}/test/Cosmic Hammer.app/Contents/Resources" "{{ build_dir }}/docs/docs.json"
    mkdir -p "{{ build_dir }}/test/Cosmic Hammer.app/Contents/Frameworks/hs"
    /usr/bin/ditto .build/release/hs "{{ build_dir }}/test/Cosmic Hammer.app/Contents/Frameworks/hs/hs"

# Assemble build/Cosmic Hammer.app without signing it
app-bundle config="Debug":
    ./scripts/build/app-bundle.sh {{ config }} {{ build_dir }}

# Sign the assembled app bundle (Release enables hardened runtime)
sign-app config="Debug":
    ./scripts/build/sign-app.sh {{ config }} {{ build_dir }}

# Verify the app bundle and resource layout
bundle-smoke:
    ./scripts/build/smoke-resources.sh "{{ build_dir }}/Cosmic Hammer.app/Contents/Resources" "{{ build_dir }}/Cosmic Hammer.app"

# Run tests (prepares Lua resources without requiring a full app bundle)
test: test-resources
    #!/usr/bin/env bash
    set -euo pipefail
    mkdir -p {{ build_dir }}
    SDK_PATH="$(xcrun --show-sdk-path)"
    export COSMIC_HAMMER_TEST_RESOURCES="$(pwd)/{{ build_dir }}/test/Cosmic Hammer.app/Contents/Resources"
    swift test \
        -Xlinker -F -Xlinker "${SDK_PATH}/System/Library/PrivateFrameworks" \
        2>&1 | tee {{ build_dir }}/test.log

# Check generated files against their source manifests
check-generated:
    ./scripts/check-generated-files.sh

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
        "$DOCSTOOL" -o {{ build_dir }} --$fmt extensions/ Sources/HSSwiftExtensions
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
    "$DOCSTOOL" --lint extensions/ Sources/HSSwiftExtensions

# Full rebuild: clean + build
rebuild: clean build

# Full local/CI verification path
verify: check-generated docs-lint build test

# Create a GitHub release with DMG
release version:
    #!/usr/bin/env bash
    set -euo pipefail

    TAG="v{{ version }}"
    DMG_NAME="Cosmic-Hammer-{{ version }}.dmg"
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
    ./scripts/build/publish-release-tag.sh "$TAG" dev

    # ── Build Release ─────────────────────────────────────────────────────
    echo "===> Building Cosmic Hammer {{ version }} (Release)"
    JJ_VERSION_REV=dev just build Release

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
