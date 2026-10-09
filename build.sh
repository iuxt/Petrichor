#!/bin/bash

# Build a local Release app, quit Petrichor, replace it, and launch the new app.
# GitHub releases continue to use Scripts/build-installer.sh.
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_NAME="Petrichor"
CONFIGURATION="Release"
ARCH="$(uname -m)"
VERSION=""
VERBOSE=false
INSTALL=true
INSTALL_DIR="/Applications"

usage() {
    cat <<EOF
Usage: $0 [options]
Build a local Release app without a signing certificate or notarization,
then quit Petrichor, replace it in /Applications, and launch the new version.
No DMG is created.

  --universal          Build for both Intel and Apple Silicon
  --intel-only         Build for Intel
  --arm-only           Build for Apple Silicon
  --version <version>  Override the app version
  --verbose            Show full build output
  --no-install         Build the app without installing it
  --install-dir <path> Install to another directory (default: /Applications)
  --help               Show this help

GitHub release packaging: Scripts/build-installer.sh
EOF
}

fail() { printf 'Error: %s\n' "$*" >&2; exit 1; }

while [ "$#" -gt 0 ]; do
    case "$1" in
        --universal) ARCH="x86_64 arm64"; shift ;;
        --intel-only) ARCH="x86_64"; shift ;;
        --arm-only) ARCH="arm64"; shift ;;
        --version|--install-dir)
            [ "$#" -ge 2 ] && [ -n "$2" ] && [[ "$2" != --* ]] || fail "$1 requires a value"
            if [ "$1" = --version ]; then VERSION="$2"; else INSTALL_DIR="$2"; fi
            shift 2
            ;;
        --verbose) VERBOSE=true; shift ;;
        --no-install) INSTALL=false; shift ;;
        --help|-h) usage; exit 0 ;;
        *) fail "Unknown option: $1 (see --help)" ;;
    esac
done

required_tools=(xcodebuild git ditto)
if [ "$INSTALL" = true ]; then required_tools+=(pgrep osascript open); fi
for tool in "${required_tools[@]}"; do
    command -v "$tool" >/dev/null 2>&1 || fail "Missing required tool: $tool"
done
cd "$PROJECT_ROOT"

if [ -z "$VERSION" ]; then
    VERSION="$(git describe --tags --exact-match 2>/dev/null || true)"
    VERSION="${VERSION#v}"
    if [ -z "$VERSION" ]; then
        VERSION="dev-$(git rev-parse --short=8 HEAD)"
    fi
fi

case "$ARCH" in
    arm64) SUFFIX="AppleSilicon" ;;
    x86_64) SUFFIX="Intel" ;;
    "x86_64 arm64") SUFFIX="Universal" ;;
    *) fail "Unsupported architecture: $ARCH" ;;
esac

BUILD_DIR="$PROJECT_ROOT/build/local-$SUFFIX"
DERIVED_DATA="$BUILD_DIR/DerivedData"
BUILT_APP="$DERIVED_DATA/Build/Products/$CONFIGURATION/$APP_NAME.app"
PACKAGED_APP="$BUILD_DIR/$APP_NAME.app"
mkdir -p "$BUILD_DIR"

build_args=(
    build
    -project "$PROJECT_ROOT/Petrichor.xcodeproj"
    -scheme "$APP_NAME"
    -configuration "$CONFIGURATION"
    -destination "generic/platform=macOS"
    -derivedDataPath "$DERIVED_DATA"
    "MARKETING_VERSION=$VERSION"
    "CLANG_CXX_LANGUAGE_STANDARD=gnu++20"
    'OTHER_CPLUSPLUSFLAGS=$(inherited) -D_LIBCPP_ENABLE_EXPERIMENTAL'
    "ARCHS=$ARCH"
    ONLY_ACTIVE_ARCH=NO
    CODE_SIGNING_ALLOWED=NO
    CODE_SIGNING_REQUIRED=NO
    CODE_SIGN_IDENTITY=
    CODE_SIGN_ENTITLEMENTS=
)
if [ "$VERBOSE" = false ]; then build_args+=(-quiet); fi

printf 'Building %s %s (%s)…\n' "$APP_NAME" "$VERSION" "$SUFFIX"
xcodebuild "${build_args[@]}" 2>&1 | tee "$BUILD_DIR/build.log"
[ -x "$BUILT_APP/Contents/MacOS/$APP_NAME" ] || fail "Build did not produce a runnable app: $BUILT_APP"
rm -rf "$PACKAGED_APP"
ditto "$BUILT_APP" "$PACKAGED_APP"
printf 'App built: %s\n' "$PACKAGED_APP"

if [ "$INSTALL" = false ]; then exit 0; fi

USE_SUDO=false
if [ ! -w "$INSTALL_DIR" ]; then
    # New custom directories can be created without sudo when their parent is writable.
    if [ ! -d "$INSTALL_DIR" ] && [ -w "$(dirname "$INSTALL_DIR")" ]; then
        mkdir -p "$INSTALL_DIR"
    else
        printf 'Administrator permission is needed to install in %s.\n' "$INSTALL_DIR"
        sudo -v
        USE_SUDO=true
        sudo mkdir -p "$INSTALL_DIR"
    fi
fi
INSTALL_DIR="$(cd "$INSTALL_DIR" && pwd)"
TARGET_APP="$INSTALL_DIR/$APP_NAME.app"
[ ! -L "$TARGET_APP" ] || fail "Refusing to replace a symlink: $TARGET_APP"
[ ! -e "$TARGET_APP" ] || [ -d "$TARGET_APP" ] || fail "Install destination is not an app directory: $TARGET_APP"
if [ -d "$TARGET_APP" ] && [ ! -w "$TARGET_APP" ] && [ "$USE_SUDO" = false ]; then
    printf 'Administrator permission is needed to replace %s.\n' "$TARGET_APP"
    sudo -v
    USE_SUDO=true
fi

install_command() {
    if [ "$USE_SUDO" = true ]; then sudo "$@"; else "$@"; fi
}
STAGE_DIR="$(install_command mktemp -d "$INSTALL_DIR/.Petrichor-install.XXXXXX")"
cleanup_install() {
    local status=$?
    if [ -d "$STAGE_DIR/previous.app" ] && [ ! -e "$TARGET_APP" ]; then
        if ! install_command mv "$STAGE_DIR/previous.app" "$TARGET_APP"; then
            printf 'Could not restore the previous app; it is preserved at %s/previous.app\n' "$STAGE_DIR" >&2
            return 1
        fi
    fi
    install_command rm -rf "$STAGE_DIR"
    return "$status"
}
trap cleanup_install EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# Copy completely before moving the old bundle, so failed copies leave it intact.
install_command ditto "$PACKAGED_APP" "$STAGE_DIR/$APP_NAME.app"

# Request a normal quit so playback state and database changes are saved.
# Never replace the bundle if the app refuses to quit or is still shutting down.
if pgrep -x "$APP_NAME" >/dev/null; then
    printf 'Quitting %s…\n' "$APP_NAME"
    osascript \
        -e 'with timeout of 30 seconds' \
        -e 'tell application id "org.Petrichor" to quit' \
        -e 'end timeout' || fail "Could not quit $APP_NAME; the installed app has not been replaced"
    remaining_seconds=30
    while pgrep -x "$APP_NAME" >/dev/null; do
        [ "$remaining_seconds" -gt 0 ] || fail "$APP_NAME is still running; the installed app has not been replaced"
        sleep 1
        remaining_seconds=$((remaining_seconds - 1))
    done
fi

if [ -d "$TARGET_APP" ]; then
    install_command mv "$TARGET_APP" "$STAGE_DIR/previous.app"
fi
install_command mv "$STAGE_DIR/$APP_NAME.app" "$TARGET_APP"
printf 'Installed: %s\n' "$TARGET_APP"
open "$TARGET_APP" || fail "App installed, but could not launch $TARGET_APP"
printf 'Started: %s\n' "$TARGET_APP"
