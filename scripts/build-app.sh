#!/bin/bash
set -euo pipefail

# Build ICloudGuard.app from Swift Package Manager output.
#
# Usage:
#   ./scripts/build-app.sh [--release] [--install]
#
# --release   Build in release configuration (default: debug)
# --install   Copy to ~/Applications after building

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
APP_NAME="ICloudGuard"
BUNDLE_NAME="ICloudGuard.app"
CONFIGURATION="debug"
INSTALL=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --release)
            CONFIGURATION="release"
            shift
            ;;
        --install)
            INSTALL=true
            shift
            ;;
        *)
            echo "Unknown argument: $1" >&2
            exit 1
            ;;
    esac
done

BUILD_PATH="$PROJECT_DIR/.build"
BINARY_PATH="$BUILD_PATH/$CONFIGURATION/$APP_NAME"
APP_BUNDLE="$BUILD_PATH/$BUNDLE_NAME"

if [[ ! -f "$BINARY_PATH" ]]; then
    echo "Building $APP_NAME ($CONFIGURATION)..."
    cd "$PROJECT_DIR"
    if [[ "$CONFIGURATION" == "release" ]]; then
        swift build -c release --product "$APP_NAME"
    else
        swift build --product "$APP_NAME"
    fi
fi

if [[ ! -x "$BINARY_PATH" ]]; then
    echo "ERROR: Binary not found at $BINARY_PATH" >&2
    exit 1
fi

echo "Assembling .app bundle..."
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

cp "$BINARY_PATH" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
cp "$PROJECT_DIR/Sources/ICloudGuardApp/Resources/Info.plist" "$APP_BUNDLE/Contents/Info.plist"

# Ad-hoc code signing (required for notifications and hardened runtime)
codesign --sign - --force --deep "$APP_BUNDLE" 2>/dev/null || {
    echo "WARNING: Code signing failed (codesign not available or no identity)" >&2
    echo "The app will run but notifications may not work." >&2
}

echo "Built: $APP_BUNDLE"

if [[ "$INSTALL" == true ]]; then
    INSTALL_DIR="$HOME/Applications"
    mkdir -p "$INSTALL_DIR"
    rm -rf "$INSTALL_DIR/$BUNDLE_NAME"
    cp -R "$APP_BUNDLE" "$INSTALL_DIR/"
    echo "Installed to: $INSTALL_DIR/$BUNDLE_NAME"
    echo "Launch with: open $INSTALL_DIR/$BUNDLE_NAME"
fi
