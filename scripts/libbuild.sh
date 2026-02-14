#!/bin/bash
# Helper functions for Hammerspoon build.sh

############################## ERROR FUNCTIONS ##############################

function fail() {
  echo "ERROR: $*" >/dev/stderr
  exit 1
}

############################# TOP LEVEL COMMANDS #############################

function op_clean() {
    echo "Cleaning build folder..."
    ${RM} -rf "${BUILD_HOME}"

    echo "Cleaning temporary build folders..."
    xcodebuild -workspace Hammerspoon.xcworkspace -scheme "${XCODE_SCHEME}" -configuration "${XCODE_CONFIGURATION}" -destination "platform=macOS" clean | xcbeautify ${XCB_OPTS[@]:-}
}

function op_build() {
    op_build_assert

    echo "Building..."
    ${RM} -rf "${HAMMERSPOON_BUNDLE_PATH}"

    local BUILD_COMMAND="build"
    if [ "${BUILD_FOR_TESTING}" == "1" ]; then
        BUILD_COMMAND="build-for-testing"
    fi

    # Build the app
    xcodebuild -workspace Hammerspoon.xcworkspace \
               -scheme "${XCODE_SCHEME}" \
               -configuration "${XCODE_CONFIGURATION}" \
               -destination "platform=macOS" \
               "${BUILD_COMMAND}" | tee "${BUILD_HOME}/${XCODE_CONFIGURATION}-build.log" | xcbeautify ${XCB_OPTS[@]:-}
}

function op_test() {
    op_test_assert

    mkdir -p "${BUILD_HOME}/reports"

    # We have to allow things to fail, because test runs may fail and we want the output
    set +e
    set +o pipefail
#xcodebuild -workspace Hammerspoon.xcworkspace -scheme Release test-without-building

    xcodebuild -workspace Hammerspoon.xcworkspace \
               -scheme "${XCODE_SCHEME}" \
               -configuration "${XCODE_CONFIGURATION}" \
               -resultBundlePath "${BUILD_HOME}/TestResults" \
               test-without-building 2>&1 | tee "${BUILD_HOME}/test.log" | xcbeautify ${XCB_OPTS[@]:-}

    # Re-enable error capture
    set -e
    set -o pipefail
}

function op_docs() {
    op_docs_assert

    local LSDOCSDIR="${BUILD_HOME}/html/LuaSkin"
    local DOCSTOOL="${HAMMERSPOON_HOME}/scripts/docs/.build/release/BuildDocs"

    # Build the docs tool if needed
    if [ ! -f "${DOCSTOOL}" ]; then
        echo "Building docs tool..."
        swift build -c release --package-path "${HAMMERSPOON_HOME}/scripts/docs" || fail "Unable to build docs tool"
    fi

    pushd "${HAMMERSPOON_HOME}" >/dev/null || fail "Unable to access Hammerspoon repo at ${HAMMERSPOON_HOME}"

    if [ "${DOCS_LINT_ONLY}" == 1 ]; then
        "${DOCSTOOL}" --lint ${DOCS_SEARCH_DIRS[*]} || fail "Docs lint failed"
        echo "Docs lint OK"
        popd >/dev/null || fail "Unknown"
        return # We return here because this option cannot be used with any of the subsequent ones
    fi

    if [ "${DOCS_JSON}" == 1 ]; then
        echo "Building docs JSON..."
        "${DOCSTOOL}" -o "${BUILD_HOME}" --json ${DOCS_SEARCH_DIRS[@]}
    fi

    if [ "${DOCS_MD}" == 1 ]; then
        echo "Building docs Markdown..."
        "${DOCSTOOL}" -o "${BUILD_HOME}" --markdown ${DOCS_SEARCH_DIRS[@]}
    fi

    if [ "${DOCS_HTML}" == 1 ]; then
        echo "Building docs HTML..."
        "${DOCSTOOL}" -o "${BUILD_HOME}" --html ${DOCS_SEARCH_DIRS[@]}
    fi

    if [ "${DOCS_SQL}" == 1 ]; then
        echo "Building docs SQLite..."
        "${DOCSTOOL}" -o "${BUILD_HOME}" --sql ${DOCS_SEARCH_DIRS[@]}
    fi

    if [ "${DOCS_DASH}" == 1 ]; then
        echo "Building docs Dash..."
        local DASHDIR="${BUILD_HOME}/Hammerspoon.docset"
        ${RM} -rf "${DASHDIR}"
        ${RM} -rf "${LSDOCSDIR}"
        cp -R "${HAMMERSPOON_HOME}/scripts/docs/templates/Hammerspoon.docset" "${DASHDIR}"
        cp "${BUILD_HOME}/docs.sqlite" "${DASHDIR}/Contents/Resources/docSet.dsidx"
        cp "${HAMMERSPOON_HOME}"/build/html/* "${DASHDIR}/Contents/Resources/Documents/"
        tar -cvf "${BUILD_HOME}/Hammerspoon.tgz" -C "${BUILD_HOME}" Hammerspoon.docset >"${BUILD_HOME}/docset-tar.log" 2>&1
    fi

    if [ "${DOCS_LUASKIN}" == 1 ]; then
        echo "Building docs LuaSkin..."
        mkdir -p "${LSDOCSDIR}"
        headerdoc2html -u -o "${LSDOCSDIR}" "${HAMMERSPOON_HOME}/LuaSkin/LuaSkin/Skin.h" >"${BUILD_HOME}/luaskin-headerdoc.log" 2>&1
        resolveLinks "${LSDOCSDIR}" >"${BUILD_HOME}/luaskin-resolveLinks.log" 2>&1
        mv "${LSDOCSDIR}"/Skin_h/* "${LSDOCSDIR}"
        rmdir "${LSDOCSDIR}/Skin_h"
    fi

    echo "Docs built"
  popd >/dev/null || fail "Unknown"
}

function op_installdeps() {
    echo "Installing dependencies..."
    echo "  mise-managed tools..."
    mise install || fail "Unable to install mise-managed tools"

    echo "  Building docs tool..."
    swift build -c release --package-path "${HAMMERSPOON_HOME}/scripts/docs" || fail "Unable to build docs tool"
}

############################## COMMAND ASSERTIONS ##############################
function op_build_assert() {
    echo "Checking build environment..."
    assert_xcbeautify
    assert_cocoapods_state
}

function op_test_assert() {
    # Nothing to assert here for now
    return
}

function op_docs_assert() {
    echo "Checking docs environment..."
}

function op_installdeps_assert() {
    echo "Checking environment..."
    if [ ! "$(which brew)" ]; then
        echo "Unable to continue without Homebrew installed, please see: https://brew.sh/"
        exit 1
    fi
}

############################## ASSERTION HELPERS ###############################
function assert_xcbeautify() {
  if [ "$(which xcbeautify)" == "" ]; then
    fail "xcbeautify is not in PATH. Try $0 installdeps"
  fi
}

function assert_cocoapods_state() {
  echo "Checking Cocoapods state..."
  pushd "${HAMMERSPOON_HOME}" >/dev/null || fail "Unable to enter ${HAMMERSPOON_HOME}"
  if ! pod outdated >/dev/null 2>&1 ; then
    fail "cocoapods installation does not seem sane"
  fi
  popd >/dev/null || fail "Unknown"
}

