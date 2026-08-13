#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
# shellcheck source=scripts/shell-helpers.sh
source "$SCRIPT_DIR/shell-helpers.sh"
APP_PRODUCT="icloud-guard"
BUNDLE_BINARY="ICloudGuard"
BUNDLE_NAME="ICloudGuard.app"
CONFIGURATION="debug"
SCRATCH_PATH="$ROOT_DIR/.build"
OUTPUT_PATH=""
BUILD_NUMBER="${GITHUB_RUN_NUMBER:-1}"
SIGN_IDENTITY="${CODESIGN_IDENTITY:--}"
KEYCHAIN_PATH="${CODESIGN_KEYCHAIN:-}"
INSTALL=false
TIMESTAMP=false
UNSIGNED_SHA_FILE=""
PRINT_BUILD_FLAGS=false

usage() {
    cat <<'EOF'
Usage: scripts/build-app.sh [options]
  --release             Build the release product.
  --scratch-path PATH   Use this SwiftPM scratch directory.
  --output PATH         Write the app bundle to PATH.
  --build-number N      Set CFBundleVersion (default: 1).
  --sign-identity ID    Sign with ID (default: ad hoc signing).
  --keychain PATH       Restrict signing identity lookup to PATH.
  --timestamp           Request a trusted signing timestamp.
  --unsigned-sha PATH   Write the pre-sign executable SHA-256 to PATH.
  --print-build-flags   Print Swift build flags without building.
  --install             Install the completed bundle in ~/Applications.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --release)
            CONFIGURATION="release"
            shift
            ;;
        --scratch-path|--output|--build-number|--sign-identity|--keychain|--unsigned-sha)
            [[ $# -ge 2 ]] || { echo "ERROR: $1 requires a value." >&2; exit 64; }
            case "$1" in
                --scratch-path) SCRATCH_PATH="$2" ;;
                --output) OUTPUT_PATH="$2" ;;
                --build-number) BUILD_NUMBER="$2" ;;
                --sign-identity) SIGN_IDENTITY="$2" ;;
                --keychain) KEYCHAIN_PATH="$2" ;;
                --unsigned-sha) UNSIGNED_SHA_FILE="$2" ;;
            esac
            shift 2
            ;;
        --timestamp)
            TIMESTAMP=true
            shift
            ;;
        --print-build-flags)
            PRINT_BUILD_FLAGS=true
            shift
            ;;
        --install)
            INSTALL=true
            shift
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            echo "ERROR: Unknown argument: $1" >&2
            usage >&2
            exit 64
            ;;
    esac
done

[[ "$BUILD_NUMBER" =~ ^[1-9][0-9]*$ ]] || {
    echo "ERROR: Build number must be a positive integer." >&2
    exit 64
}
[[ -n "$SIGN_IDENTITY" ]] || {
    echo "ERROR: Signing identity is empty." >&2
    exit 64
}

SWIFT_FLAGS=(-Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors)
if [[ "$CONFIGURATION" == "release" ]]; then
    # Remove release linker STABS/N_OSO records, which contain rebuild
    # timestamps. Debug builds retain DWARF. LC_UUID remains enabled.
    SWIFT_FLAGS+=(-Xlinker -S)
fi
if [[ "$PRINT_BUILD_FLAGS" == true ]]; then
    printf '%s\n' "${SWIFT_FLAGS[@]}"
    exit 0
fi

mkdir -p "$SCRATCH_PATH"
SCRATCH_PATH="$(cd "$SCRATCH_PATH" && pwd)"
if [[ -z "$OUTPUT_PATH" ]]; then
    OUTPUT_PATH="$SCRATCH_PATH/$BUNDLE_NAME"
elif [[ "$OUTPUT_PATH" != /* ]]; then
    OUTPUT_PATH="$ROOT_DIR/$OUTPUT_PATH"
fi
[[ "$OUTPUT_PATH" == *.app ]] || {
    echo "ERROR: Output path must end in .app." >&2
    exit 64
}

VERSION="$("$SCRIPT_DIR/version.sh")"
INFO_SOURCE="$ROOT_DIR/Sources/ICloudGuardApp/Resources/Info.plist"
ICON_SOURCE="$ROOT_DIR/Sources/ICloudGuardApp/Resources/AppIcon.icns"
PLACEHOLDER="$(plutil -extract CFBundleShortVersionString raw -o - "$INFO_SOURCE")"
[[ "$PLACEHOLDER" == "__ICLOUD_GUARD_VERSION__" ]] || {
    echo "ERROR: Info.plist must use the canonical version placeholder." >&2
    exit 1
}

swift build \
    --package-path "$ROOT_DIR" \
    --scratch-path "$SCRATCH_PATH" \
    -c "$CONFIGURATION" \
    --product "$APP_PRODUCT" \
    "${SWIFT_FLAGS[@]}"
BIN_DIR="$(swift build --package-path "$ROOT_DIR" --scratch-path "$SCRATCH_PATH" -c "$CONFIGURATION" --show-bin-path)"
BINARY_PATH="$BIN_DIR/$APP_PRODUCT"
[[ -x "$BINARY_PATH" ]] || {
    echo "ERROR: Current product binary was not built at $BINARY_PATH." >&2
    exit 1
}
if [[ -n "$UNSIGNED_SHA_FILE" ]]; then
    if [[ "$UNSIGNED_SHA_FILE" != /* ]]; then UNSIGNED_SHA_FILE="$ROOT_DIR/$UNSIGNED_SHA_FILE"; fi
    mkdir -p "$(dirname "$UNSIGNED_SHA_FILE")"
    shasum -a 256 "$BINARY_PATH" | awk '{print $1}' > "$UNSIGNED_SHA_FILE"
fi

OUTPUT_PARENT="$(dirname "$OUTPUT_PATH")"
mkdir -p "$OUTPUT_PARENT"
[[ ! -e "$OUTPUT_PATH" ]] || {
    echo "ERROR: Output already exists: $OUTPUT_PATH" >&2
    exit 1
}
STAGE_ROOT="$(mktemp -d "$OUTPUT_PARENT/.icloud-guard-app.XXXXXX")"
cleanup_stage() {
    safe_remove_tree "$STAGE_ROOT" "$OUTPUT_PARENT"
}
trap cleanup_stage EXIT
STAGED_APP="$STAGE_ROOT/$BUNDLE_NAME"
mkdir -p "$STAGED_APP/Contents/MacOS" "$STAGED_APP/Contents/Resources"
install -m 755 "$BINARY_PATH" "$STAGED_APP/Contents/MacOS/$BUNDLE_BINARY"
install -m 644 "$INFO_SOURCE" "$STAGED_APP/Contents/Info.plist"
if [[ -f "$ICON_SOURCE" ]]; then
    install -m 644 "$ICON_SOURCE" "$STAGED_APP/Contents/Resources/AppIcon.icns"
fi
plutil -replace CFBundleShortVersionString -string "$VERSION" "$STAGED_APP/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$BUILD_NUMBER" "$STAGED_APP/Contents/Info.plist"

SIGN_ARGS=(--sign "$SIGN_IDENTITY" --force --options runtime)
if [[ -n "$KEYCHAIN_PATH" ]]; then
    [[ -f "$KEYCHAIN_PATH" ]] || { echo "ERROR: Signing keychain not found: $KEYCHAIN_PATH" >&2; exit 1; }
    SIGN_ARGS+=(--keychain "$KEYCHAIN_PATH")
fi
if [[ "$TIMESTAMP" == true ]]; then
    [[ "$SIGN_IDENTITY" != "-" ]] || { echo "ERROR: Ad hoc signing cannot use a trusted timestamp." >&2; exit 64; }
    SIGN_ARGS+=(--timestamp)
fi
codesign "${SIGN_ARGS[@]}" "$STAGED_APP"
codesign --verify --deep --strict --verbose=2 "$STAGED_APP"

[[ "$(plutil -extract CFBundleShortVersionString raw -o - "$STAGED_APP/Contents/Info.plist")" == "$VERSION" ]] || {
    echo "ERROR: Built app version does not match $VERSION." >&2
    exit 1
}
[[ "$("$STAGED_APP/Contents/MacOS/$BUNDLE_BINARY" --version)" == "$VERSION" ]] || {
    echo "ERROR: Built CLI version does not match $VERSION." >&2
    exit 1
}

mv "$STAGED_APP" "$OUTPUT_PATH"
safe_remove_tree "$STAGE_ROOT" "$OUTPUT_PARENT"
trap - EXIT
echo "Built: $OUTPUT_PATH"

if [[ "$INSTALL" == true ]]; then
    INSTALL_DIR="$HOME/Applications"
    INSTALLED_APP="$INSTALL_DIR/$BUNDLE_NAME"
    mkdir -p "$INSTALL_DIR"
    INSTALL_STAGE="$(mktemp -d "$INSTALL_DIR/.icloud-guard-install.XXXXXX")/$BUNDLE_NAME"
    ditto "$OUTPUT_PATH" "$INSTALL_STAGE"
    if [[ -e "$INSTALLED_APP" ]]; then safe_remove_tree "$INSTALLED_APP" "$INSTALL_DIR"; fi
    mv "$INSTALL_STAGE" "$INSTALLED_APP"
    rmdir "$(dirname "$INSTALL_STAGE")"

    BIN_DIR="$HOME/bin"
    mkdir -p "$BIN_DIR"
    CLI_WRAPPER="$BIN_DIR/icloud-guard"
    WRAPPER_STAGE="$(mktemp "$BIN_DIR/.icloud-guard-wrapper.XXXXXX")"
    cat > "$WRAPPER_STAGE" <<'WRAPPER'
#!/bin/bash
set -euo pipefail
exec "$HOME/Applications/ICloudGuard.app/Contents/MacOS/ICloudGuard" "$@"
WRAPPER
    chmod 755 "$WRAPPER_STAGE"
    mv "$WRAPPER_STAGE" "$CLI_WRAPPER"
    echo "Installed: $INSTALLED_APP"
    echo "CLI wrapper: $CLI_WRAPPER"
fi
