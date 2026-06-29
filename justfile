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
build config="Debug": (_build-inputs config)
    just app-bundle {{ config }}
    just sign-app {{ config }}
    just bundle-smoke

[parallel]
_build-inputs config="Debug": build-version docs-json (_swift-binaries config)

_swift-binaries config="Debug":
    just hs-cli
    just spm-binary {{ config }}

# Write build/version.env and build/version.json
build-version:
    ./scripts/build/version-metadata.sh {{ build_dir }}

# Build the documentation tool if needed
_docs-tool:
    @if [ ! -f scripts/docs/.build/release/BuildDocs ]; then \
        echo "Building docs tool..."; \
        swift build -c release --package-path scripts/docs; \
    fi

# Build docs JSON artifacts under build/docs
docs-json: _docs-tool
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
test-resources: docs-json
    rm -rf "{{ build_dir }}/test"
    ./scripts/build/copy-resources.sh "{{ build_dir }}/test/Cosmic Hammer.app/Contents/Resources" "{{ build_dir }}/docs/docs.json"

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
    just _test "{{ build_dir }}/test/Cosmic Hammer.app/Contents/Resources"

# Run tests against the built app bundle resources
test-built: build
    just _test "{{ build_dir }}/Cosmic Hammer.app/Contents/Resources"

_test resource_root:
    #!/usr/bin/env bash
    set -euo pipefail
    mkdir -p {{ build_dir }}
    SDK_PATH="$(xcrun --show-sdk-path)"
    export COSMIC_HAMMER_TEST_RESOURCES="$(pwd)/{{ resource_root }}"
    if [ ! -d "$COSMIC_HAMMER_TEST_RESOURCES" ]; then
        echo "error: missing test resources: $COSMIC_HAMMER_TEST_RESOURCES" >&2
        exit 1
    fi
    swift test \
        -Xlinker -F -Xlinker "${SDK_PATH}/System/Library/PrivateFrameworks" \
        2>&1 | tee {{ build_dir }}/test.log

_test-filter resource_root filter:
    #!/usr/bin/env bash
    set -euo pipefail
    mkdir -p {{ build_dir }}
    SDK_PATH="$(xcrun --show-sdk-path)"
    export COSMIC_HAMMER_TEST_RESOURCES="$(pwd)/{{ resource_root }}"
    if [ ! -d "$COSMIC_HAMMER_TEST_RESOURCES" ]; then
        echo "error: missing test resources: $COSMIC_HAMMER_TEST_RESOURCES" >&2
        exit 1
    fi
    swift test \
        --filter "{{ filter }}" \
        -Xlinker -F -Xlinker "${SDK_PATH}/System/Library/PrivateFrameworks" \
        2>&1 | tee {{ build_dir }}/otel-test-{{ filter }}.log

# Check generated files against their source manifests
check-generated:
    ./scripts/check-generated-files.sh

# Build all documentation
docs: _docs-tool
    #!/usr/bin/env bash
    set -euo pipefail
    DOCSTOOL="scripts/docs/.build/release/BuildDocs"
    mkdir -p {{ build_dir }}
    for fmt in json markdown html sql; do
        echo "Building docs $fmt..."
        "$DOCSTOOL" -o {{ build_dir }} --$fmt extensions/ Sources/HSSwiftExtensions
    done

# Lint documentation without building
docs-lint: _docs-tool
    #!/usr/bin/env bash
    set -euo pipefail
    DOCSTOOL="scripts/docs/.build/release/BuildDocs"
    "$DOCSTOOL" --lint extensions/ Sources/HSSwiftExtensions

# Full rebuild: clean + build
rebuild: clean build

# Full local verification path
[parallel]
verify: check-generated docs-lint test-built

# Quick local OTEL benchmark run. Advisory only; not part of verify.
bench-otel suite="smoke" iterations="10000" samples="5":
    SDK_PATH="$(xcrun --show-sdk-path)"; swift run -c release -Xlinker -F -Xlinker "$SDK_PATH/System/Library/PrivateFrameworks" OTELBenchmarks --suite {{ suite }} --iterations {{ iterations }} --samples {{ samples }} --warmup 1 --telemetry simulated --output pretty

# Local OTEL benchmark smoke. Writes advisory JSON output.
bench-otel-smoke:
    mkdir -p {{ build_dir }}/otel-benchmarks
    SDK_PATH="$(xcrun --show-sdk-path)"; swift run -c release -Xlinker -F -Xlinker "$SDK_PATH/System/Library/PrivateFrameworks" OTELBenchmarks --suite smoke --iterations 5000 --samples 3 --warmup 1 --telemetry simulated --output json > {{ build_dir }}/otel-benchmarks/otel-smoke.json

# Longer local advisory OTEL benchmark suite. Writes JSON output.
bench-otel-full:
    mkdir -p {{ build_dir }}/otel-benchmarks
    SDK_PATH="$(xcrun --show-sdk-path)"; swift run -c release -Xlinker -F -Xlinker "$SDK_PATH/System/Library/PrivateFrameworks" OTELBenchmarks --suite all --iterations 50000 --samples 10 --warmup 3 --telemetry simulated --output json > {{ build_dir }}/otel-benchmarks/otel-full.json

# Focused deterministic OTEL smoke tests.
otel-test: test-resources
    just _test-filter "{{ build_dir }}/test/Cosmic Hammer.app/Contents/Resources" OpenTelemetryFunctionalTests
    just _test-filter "{{ build_dir }}/test/Cosmic Hammer.app/Contents/Resources" OTELBenchmarkSupportTests

# Deterministic W3C/golden OTEL conformance tests.
otel-conformance: test-resources
    just _test-filter "{{ build_dir }}/test/Cosmic Hammer.app/Contents/Resources" OpenTelemetryPropagationConformanceTests
    just _test-filter "{{ build_dir }}/test/Cosmic Hammer.app/Contents/Resources" OpenTelemetryOTLPExportTests

# Collector-backed OTEL tests are opt-in local checks.
otel-collector-test:
    #!/usr/bin/env bash
    set -euo pipefail
    if [[ "${OTEL_COLLECTOR_TESTS:-}" != "1" ]]; then
        echo "error: set OTEL_COLLECTOR_TESTS=1 to run collector-backed OTEL tests" >&2
        exit 2
    fi
    just otel-grpc-integration

# Reload/lifecycle stress tests are opt-in until runtime budgets are settled.
otel-stress-test: test-resources
    #!/usr/bin/env bash
    set -euo pipefail
    if [[ "${OTEL_STRESS_TESTS:-}" != "1" ]]; then
        echo "error: set OTEL_STRESS_TESTS=1 to run OTEL stress tests" >&2
        exit 2
    fi
    just _test-filter "{{ build_dir }}/test/Cosmic Hammer.app/Contents/Resources" OpenTelemetryLifecycleStressTests

# Advisory local OTEL benchmark check; separate from default verify.
otel-benchmark:
    #!/usr/bin/env bash
    set -euo pipefail
    if [[ "${OTEL_BENCHMARK_TESTS:-}" != "1" ]]; then
        echo "error: set OTEL_BENCHMARK_TESTS=1 to run advisory OTEL benchmarks" >&2
        exit 2
    fi
    just bench-otel-smoke

# Local OTEL umbrella. Optional checks run only when env-gated.
otel-local-checks:
    #!/usr/bin/env bash
    set -euo pipefail
    just verify
    just otel-test
    just otel-conformance
    if [[ "${OTEL_BENCHMARK_TESTS:-}" == "1" ]]; then
        just otel-benchmark
    else
        echo "Skipping advisory OTEL benchmarks; set OTEL_BENCHMARK_TESTS=1 to include them"
    fi
    if [[ "${OTEL_COLLECTOR_TESTS:-}" == "1" ]]; then
        just otel-collector-test
    else
        echo "Skipping collector-backed OTEL tests; set OTEL_COLLECTOR_TESTS=1 to include them"
    fi
    if [[ "${OTEL_STRESS_TESTS:-}" == "1" ]]; then
        just otel-stress-test
    else
        echo "Skipping OTEL stress tests; set OTEL_STRESS_TESTS=1 to include them"
    fi
    if [[ "${COSMIC_HAMMER_OTEL_GRPC_INTEGRATION:-}" == "1" ]]; then
        just otel-grpc-integration
    else
        echo "Skipping OTLP/gRPC integration; set COSMIC_HAMMER_OTEL_GRPC_INTEGRATION=1 to include it"
    fi

# Local OTLP/gRPC collector integration scaffold.
otel-grpc-integration:
    scripts/test-otel-grpc-integration.sh

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
    command -v jj >/dev/null \
        || { echo "Error: jj CLI not found" >&2; exit 1; }

    if [[ -n "$(jj diff --summary)" ]]; then
        echo "Error: working copy must be clean before release" >&2
        jj status >&2
        exit 1
    fi

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

    FLAKE_DIFF="$(jj diff --summary)"
    if [[ "$FLAKE_DIFF" != "M flake.nix" ]]; then
        echo "Error: expected only flake.nix to change after release, got:" >&2
        echo "$FLAKE_DIFF" >&2
        exit 1
    fi

    echo "===> Committing flake.nix release metadata"
    jj commit -m "chore: update flake.nix to $TAG"
    jj bookmark move dev --to @-

    echo "===> Pushing dev with flake.nix release metadata"
    jj git push --bookmark dev
