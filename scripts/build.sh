#!/bin/bash
# Hammerspoon build system

# Make it easy to fork us
export APP_NAME="${APP_NAME:-"Hammerspoon"}"

# Set some defaults that we'll override based on command line arguments
XCODE_SCHEME="Hammerspoon"
XCODE_CONFIGURATION="Debug"
XCCONFIG_FILE=""
UPLOAD_DSYM=0
BUILD_FOR_TESTING=0
DEBUG=0
DOCS_JSON=1
DOCS_MD=1
DOCS_HTML=1
DOCS_SQL=1
DOCS_DASH=1
DOCS_LUASKIN=1
DOCS_LINT_ONLY=0
INSTALLDEPS_FULL=0

# Print out friendly command line usage information
function usage() {
    echo "Usage $0 COMMAND [OPTIONS]"
    echo "COMMANDS:"
    echo "  installdeps   - Install all ${APP_NAME} build dependencies"
    echo "  clean         - Erase build directory"
    echo "  build         - Build ${APP_NAME}.app"
    echo "  test          - Test ${APP_NAME}.app"
    echo "  docs          - Build documentation"
    echo ""
    echo "GENERAL OPTIONS:"
    echo "  -h             - Show this help"
    echo "  -d             - Enable debugging"
    echo ""
    echo "BUILD OPTIONS:"
    echo "  -s             - Hammerspoon build scheme (Default: Hammerspoon)"
    echo "  -c             - Hammerspoon build configuration (Default: Debug)"
    echo "  -x             - Use extra build settings from a .xcconfig file (Default: None)"
    echo "  -u             - Upload debug symbols to crash reporting service (Default: No)"
    echo "  -e             - Build for testing"
    echo ""
    echo "DOCS OPTIONS:"
    echo "By default all docs are built. Only one of the following options can be supplied."
    echo "If more than one is present, only the last one will have an effect"
    echo "  -j             - Build only JSON documentation"
    echo "  -m             - Build only Markdown documentation"
    echo "  -t             - Build only HTML documentation"
    echo "  -q             - Build only SQLite documentation"
    echo "  -a             - Build only Dash documentation"
    echo "  -k             - Build only LuaSkin documentation"
    echo "  -l             - Only lint docs, don't build anything"
    echo ""
    echo "INSTALLDEPS OPTIONS:"
    echo "  -r             - Install full dependencies required to complete a public release"

    exit 2
}

# Fetch the COMMAND we should perform
OPERATION=${1:-unknown};shift
if [ "${OPERATION}" == "-h" ] || [ "${OPERATION}" == "--help" ]; then
    usage
fi

# Parse the rest of any arguments
PARSED_ARGUMENTS=$(getopt ds:c:x:ujmtqaklw:e $*)
if [ $? != 0 ]; then
    usage
fi
set -- $PARSED_ARGUMENTS

# Translate the parsed arguments into our defaults
for i
do
    case "$i" in
        -d)
            DEBUG=1
            shift;;
        -s)
            XCODE_SCHEME=${2}; shift
            shift;;
        -c)
            XCODE_CONFIGURATION=${2}; shift
            shift;;
        -x)
            XCCONFIG_FILE=${2}; shift
            shift;;
        -u)
            UPLOAD_DSYM=1
            shift;;
        -e)
            BUILD_FOR_TESTING=1
            shift;;
        -j)
            # JSON can be built without any of the others
            DOCS_MD=0
            DOCS_HTML=0
            DOCS_SQL=0
            DOCS_DASH=0
            DOCS_LUASKIN=0
            DOCS_LINT_ONLY=0
            shift;;
        -m)
            # Markdown requires JSON, so leave that enabled
            DOCS_HTML=0
            DOCS_SQL=0
            DOCS_DASH=0
            DOCS_LUASKIN=0
            DOCS_LINT_ONLY=0
            shift;;
        -t)
            # HTML requires JSON, so leave that enabled
            DOCS_MD=0
            DOCS_SQL=0
            DOCS_DASH=0
            DOCS_LUASKIN=0
            DOCS_LINT_ONLY=0
            shift;;
        -q)
            # SQLite requires JSON, so leave that enabled
            DOCS_MD=0
            DOCS_HTML=0
            DOCS_DASH=0
            DOCS_LUASKIN=0
            DOCS_LINT_ONLY=0
            shift;;
        -a)
            # Dash requires JSON, SQLite, LuaSkin and HTML
            DOCS_MD=0
            DOCS_LINT_ONLY=0
            shift;;
        -k)
            # LuaSkin requires nothing else
            DOCS_JSON=0
            DOCS_MD=0
            DOCS_HTML=0
            DOCS_SQL=0
            DOCS_DASH=0
            DOCS_LINT_ONLY=0
            shift;;
        -l)
            # Linting requires no other docs to be built
            DOCS_JSON=0
            DOCS_MD=0
            DOCS_HTML=0
            DOCS_SQL=0
            DOCS_DASH=0
            DOCS_LINT_ONLY=1
            shift;;
        -r)
            INSTALLDEPS_FULL=1
            shift;;
        --)
            shift; break;;
    esac
done

# If the user asked for debugging, print out some settings and enable bash tracing
if [ ${DEBUG} == 1 ]; then
    echo "OPERATION is: ${OPERATION}"
    echo "XCODE_SCHEME is: ${XCODE_SCHEME}"
    echo "XCCODE_CONFIGURATION is: ${XCODE_CONFIGURATION}"
    echo "XCCONFIG_FILE is: ${XCCONFIG_FILE:-None}"
    echo "UPLOAD_DSYM is: ${UPLOAD_DSYM}"
    echo "BUILD_FOR_TESTING is: ${BUILD_FOR_TESTING}"
    echo "DEBUG is: ${DEBUG}"

    echo "DOCS_JSON is: ${DOCS_JSON}"
    echo "DOCS_MD is: ${DOCS_MD}"
    echo "DOCS_HTML is: ${DOCS_HTML}"
    echo "DOCS_SQL is: ${DOCS_SQL}"
    echo "DOCS_DASH is: ${DOCS_DASH}"
    echo "DOCS_LUASKIN is: ${DOCS_LUASKIN}"
    echo "DOCS_LINT_ONLY is: ${DOCS_LINT_ONLY}"

    # Enable script tracing, with timestamps
    #export PS4='+\t '
    set -x
fi

# Enable lots of safety
set -eu
set -o pipefail

# Export all the arguments we need later
export XCODE_SCHEME
export XCODE_CONFIGURATION
export XCCONFIG_FILE
export UPLOAD_DSYM
export BUILD_FOR_TESTING
export DEBUG
export DOCS_JSON
export DOCS_MD
export DOCS_HTML
export DOCS_SQL
export DOCS_DASH
export DOCS_LINT_ONLY
export INSTALLDEPS_FULL

# Early sanity checks that we have everything we need, starting with Xcode as the default Developer path
echo "Current Developer path is: $(xcode-select -p)"
if [[ "$(xcode-select -p)" != *"Xcode"* ]]; then
    echo "ERROR: Your active Developer directory is not pointing at Xcode.app. You will need Xcode to build ${APP_NAME}."
    echo "You can change this with: sudo xcode-select -s /path/to/Xcode.app"
    exit 1
fi
export PATH="$PATH:/opt/homebrew/bin"
export RM="rm"

# Calculate some variables we need later
echo "Gathering info..."

export SCRIPT_NAME ; SCRIPT_NAME="$(basename "$0")"
export SCRIPT_HOME ; SCRIPT_HOME="$(dirname "$(readlink -f "$0")")"
export HAMMERSPOON_HOME ; HAMMERSPOON_HOME="$(readlink -f "${SCRIPT_HOME}/../")"
export BUILD_HOME="${HAMMERSPOON_HOME}/build"
export HAMMERSPOON_BUNDLE_NAME="${APP_NAME}.app"
export HAMMERSPOON_BUNDLE_PATH="${BUILD_HOME}/${HAMMERSPOON_BUNDLE_NAME}"
export HAMMERSPOON_XCARCHIVE_PATH="${HAMMERSPOON_BUNDLE_PATH}.xcarchive"
export XCODE_BUILT_PRODUCTS_DIR ; XCODE_BUILT_PRODUCTS_DIR="$(xcodebuild -workspace Hammerspoon.xcworkspace -scheme "${XCODE_SCHEME}" -configuration "${XCODE_CONFIGURATION}" -destination "platform=macOS" -showBuildSettings | sort | uniq | grep ' BUILT_PRODUCTS_DIR =' | awk '{ print $3 }')"
export DOCS_SEARCH_DIRS=("Hammerspoon" "extensions/")

# Calculate options for xcbeautify
export XCB_OPTS=(-q)
if [ "${DEBUG}" == "1" ]; then
    XCB_OPTS=()
fi

# Import our function library
# shellcheck source=scripts/libbuild.sh disable=SC1091
source "${SCRIPT_HOME}/libbuild.sh"

# Make sure our build directory exists
mkdir -p "${BUILD_HOME}"

# Figure out which COMMAND we have been tasked with performing, and go do it
case "${OPERATION}" in
    "clean")
        op_clean
        ;;
    "build")
        op_build
        ;;
    "test")
        op_test
        ;;
    "docs")
        op_docs
        ;;
    "installdeps")
        op_installdeps
        ;;
    *)
        echo "Unknown command: ${OPERATION}"
        usage
        ;;
esac

exit 0
