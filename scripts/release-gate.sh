#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
# shellcheck source=scripts/shell-helpers.sh
source "$SCRIPT_DIR/shell-helpers.sh"

VERSION="$("$SCRIPT_DIR/version.sh")"
CHANNEL="stable"
TAG=""
OUTPUT_DIR=""
BUILD_NUMBER="${GITHUB_RUN_NUMBER:-1}"
SIGN_IDENTITY="${CODESIGN_IDENTITY:-}"
KEYCHAIN_PATH="${CODESIGN_KEYCHAIN:-}"
NOTARY_PROFILE="${NOTARY_KEYCHAIN_PROFILE:-}"
NOTARY_KEYCHAIN_PATH="${NOTARY_KEYCHAIN:-}"
ALLOW_DIRTY=false
CHECK_ONLY=false
REQUIRE_SIGNING=false
NOTARIZE=false

usage() {
    cat <<'EOF'
Usage: scripts/release-gate.sh [options]
  --check                 Validate release inputs without building.
  --channel NAME          stable, beta, or tip (default: stable).
  --tag TAG               Require the channel's canonical tag.
  --output-dir PATH       Publish all verified artifacts into new PATH.
  --build-number N        Set the app build number.
  --sign-identity ID      Use this Developer ID signing identity.
  --keychain PATH         Restrict signing identity lookup to PATH.
  --require-signing       Reject ad hoc or missing signing identities.
  --notarize              Require notarization and stapling.
  --notary-profile NAME   Use a notarytool keychain profile.
  --notary-keychain PATH  Read the notary profile from this keychain.
  --allow-dirty           Permit dirty source only with --check.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --check) CHECK_ONLY=true; shift ;;
        --allow-dirty) ALLOW_DIRTY=true; shift ;;
        --require-signing) REQUIRE_SIGNING=true; shift ;;
        --notarize) NOTARIZE=true; REQUIRE_SIGNING=true; shift ;;
        --channel|--tag|--output-dir|--build-number|--sign-identity|--keychain|--notary-profile|--notary-keychain)
            [[ $# -ge 2 ]] || { echo "ERROR: $1 requires a value." >&2; exit 64; }
            case "$1" in
                --channel) CHANNEL="$2" ;;
                --tag) TAG="$2" ;;
                --output-dir) OUTPUT_DIR="$2" ;;
                --build-number) BUILD_NUMBER="$2" ;;
                --sign-identity) SIGN_IDENTITY="$2" ;;
                --keychain) KEYCHAIN_PATH="$2" ;;
                --notary-profile) NOTARY_PROFILE="$2" ;;
                --notary-keychain) NOTARY_KEYCHAIN_PATH="$2" ;;
            esac
            shift 2
            ;;
        --help|-h) usage; exit 0 ;;
        *) echo "ERROR: Unknown argument: $1" >&2; usage >&2; exit 64 ;;
    esac
done

git -C "$ROOT_DIR" rev-parse --is-inside-work-tree >/dev/null
COMMIT="$(git -C "$ROOT_DIR" rev-parse HEAD)"
SHORT_COMMIT="${COMMIT:0:12}"
case "$CHANNEL" in
    stable)
        EXPECTED_TAG="v$VERSION"
        ARTIFACT="ICloudGuard-$VERSION.zip"
        REQUIRE_SIGNING=true
        NOTARIZE=true
        ;;
    beta)
        EXPECTED_TAG="beta-$VERSION"
        ARTIFACT="ICloudGuard-beta-$VERSION.zip"
        REQUIRE_SIGNING=true
        NOTARIZE=true
        ;;
    tip)
        EXPECTED_TAG="tip-$SHORT_COMMIT"
        ARTIFACT="ICloudGuard-tip-$VERSION-$SHORT_COMMIT.zip"
        ;;
    *) echo "ERROR: Channel must be stable, beta, or tip." >&2; exit 64 ;;
esac

[[ -n "$TAG" ]] || { echo "ERROR: --tag is required." >&2; exit 64; }
[[ "$TAG" == "$EXPECTED_TAG" ]] || {
    echo "ERROR: Tag $TAG does not match $EXPECTED_TAG for source commit $COMMIT." >&2
    exit 1
}
[[ "$BUILD_NUMBER" =~ ^[1-9][0-9]*$ ]] || { echo "ERROR: Build number must be a positive integer." >&2; exit 64; }
if [[ "$ALLOW_DIRTY" == true && "$CHECK_ONLY" != true ]]; then
    echo "ERROR: --allow-dirty is valid only with --check; release artifacts require clean tracked source." >&2
    exit 1
fi
SOURCE_STATUS="$(git -C "$ROOT_DIR" status --porcelain=v1 --untracked-files=all)"
if [[ "$ALLOW_DIRTY" != true && -n "$SOURCE_STATUS" ]]; then
    echo "ERROR: Release source tree contains modified or untracked files." >&2
    exit 1
fi
[[ "$(plutil -extract CFBundleShortVersionString raw -o - "$ROOT_DIR/Sources/ICloudGuardApp/Resources/Info.plist")" == "__ICLOUD_GUARD_VERSION__" ]] || {
    echo "ERROR: Info.plist does not derive its version from the canonical source." >&2
    exit 1
}
if [[ "$REQUIRE_SIGNING" == true && ( -z "$SIGN_IDENTITY" || "$SIGN_IDENTITY" == "-" ) ]]; then
    echo "ERROR: Developer ID signing is required, but no identity was supplied." >&2
    exit 1
fi
if [[ -n "$KEYCHAIN_PATH" && ! -f "$KEYCHAIN_PATH" ]]; then
    echo "ERROR: Signing keychain not found: $KEYCHAIN_PATH" >&2
    exit 1
fi
if [[ "$NOTARIZE" == true ]]; then
    [[ -n "$NOTARY_PROFILE" ]] || {
        echo "ERROR: Stable and beta releases require a preconfigured notarytool keychain profile." >&2
        exit 1
    }
    : "${APPLE_TEAM_ID:?ERROR: APPLE_TEAM_ID is required to verify Developer ID provenance.}"
    if [[ -n "$NOTARY_KEYCHAIN_PATH" && ( ! -f "$NOTARY_KEYCHAIN_PATH" || -L "$NOTARY_KEYCHAIN_PATH" ) ]]; then
        echo "ERROR: Notary profile keychain not found: $NOTARY_KEYCHAIN_PATH" >&2
        exit 1
    fi
fi
SOURCE_EPOCH="${SOURCE_DATE_EPOCH:-$(git -C "$ROOT_DIR" show -s --format=%ct HEAD)}"
[[ "$SOURCE_EPOCH" =~ ^[0-9]+$ ]] || { echo "ERROR: SOURCE_DATE_EPOCH must be an integer." >&2; exit 64; }

if [[ "$CHECK_ONLY" == true ]]; then
    echo "Release inputs valid: $CHANNEL $VERSION $TAG $COMMIT"
    exit 0
fi

if [[ "$CHANNEL" != "tip" ]]; then
    TAG_COMMIT="$(git -C "$ROOT_DIR" rev-parse "$TAG^{commit}" 2>/dev/null)" || {
        echo "ERROR: Release tag does not resolve to a commit: $TAG" >&2
        exit 1
    }
    [[ "$TAG_COMMIT" == "$COMMIT" ]] || { echo "ERROR: Release tag does not point to source commit $COMMIT." >&2; exit 1; }
fi

"$SCRIPT_DIR/release-preflight.sh"
"$SCRIPT_DIR/test-release.sh"

[[ -n "$OUTPUT_DIR" ]] || OUTPUT_DIR="$ROOT_DIR/.build/release-$CHANNEL-$VERSION"
if [[ "$OUTPUT_DIR" != /* ]]; then OUTPUT_DIR="$ROOT_DIR/$OUTPUT_DIR"; fi
[[ ! -e "$OUTPUT_DIR" ]] || { echo "ERROR: Output directory already exists: $OUTPUT_DIR" >&2; exit 1; }

BUILD_PARENT="$ROOT_DIR/.build"
mkdir -p "$BUILD_PARENT"
[[ -d "$BUILD_PARENT" && ! -L "$BUILD_PARENT" ]] || { echo "ERROR: Build parent must not be a symlink." >&2; exit 1; }
BUILD_ROOT="$BUILD_PARENT/release-gate-$CHANNEL"
[[ ! -e "$BUILD_ROOT" ]] || { echo "ERROR: Deterministic build scratch path already exists: $BUILD_ROOT" >&2; exit 1; }
TEMP_PARENT="${TMPDIR:-/private/tmp}"
TEMP_PARENT="${TEMP_PARENT%/}"
[[ -d "$TEMP_PARENT" && ! -L "$TEMP_PARENT" ]] || { echo "ERROR: Temporary parent must be a real directory." >&2; exit 1; }
WORK_DIR="$(mktemp -d "$TEMP_PARENT/icloud-guard-release.XXXXXX")"
PUBLISH_STAGE=""
cleanup() {
    if [[ -n "$PUBLISH_STAGE" && -e "$PUBLISH_STAGE" ]]; then
        safe_remove_tree "$PUBLISH_STAGE" "$(dirname "$PUBLISH_STAGE")"
    fi
    safe_remove_tree "$WORK_DIR" "$TEMP_PARENT"
    safe_remove_tree "$BUILD_ROOT" "$BUILD_PARENT"
}
trap cleanup EXIT
mkdir -p "$WORK_DIR/home"
export HOME="$WORK_DIR/home"
export XDG_CACHE_HOME="$WORK_DIR/xdg-cache"
export XDG_CONFIG_HOME="$WORK_DIR/xdg-config"

STRICT_FLAGS=(-Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors)
swift test --package-path "$ROOT_DIR" --scratch-path "$WORK_DIR/test-build" "${STRICT_FLAGS[@]}"

BUILD_ARGS=(
    --release
    --scratch-path "$BUILD_ROOT"
    --output "$WORK_DIR/ICloudGuard.app"
    --build-number "$BUILD_NUMBER"
    --sign-identity "${SIGN_IDENTITY:--}"
)
if [[ -n "$KEYCHAIN_PATH" ]]; then BUILD_ARGS+=(--keychain "$KEYCHAIN_PATH"); fi
if [[ "$REQUIRE_SIGNING" == true ]]; then BUILD_ARGS+=(--timestamp); fi
"$SCRIPT_DIR/build-app.sh" "${BUILD_ARGS[@]}"

APP="$WORK_DIR/ICloudGuard.app"
EXECUTABLE="$APP/Contents/MacOS/ICloudGuard"
[[ -x "$EXECUTABLE" ]] || { echo "ERROR: Release app executable is missing." >&2; exit 1; }
[[ "$("$EXECUTABLE" --version)" == "$VERSION" ]] || { echo "ERROR: Release CLI version mismatch." >&2; exit 1; }
[[ "$(plutil -extract CFBundleShortVersionString raw -o - "$APP/Contents/Info.plist")" == "$VERSION" ]] || { echo "ERROR: Release app version mismatch." >&2; exit 1; }
codesign --verify --deep --strict --verbose=2 "$APP"

NOTARIZED=false
STAPLED=false
if [[ "$NOTARIZE" == true ]]; then
    NOTARY_ARCHIVE="$WORK_DIR/ICloudGuard-notary.zip"
    /usr/bin/ditto -c -k --keepParent "$APP" "$NOTARY_ARCHIVE"
    NOTARY_ARGS=(--keychain-profile "$NOTARY_PROFILE")
    if [[ -n "$NOTARY_KEYCHAIN_PATH" ]]; then NOTARY_ARGS+=(--keychain "$NOTARY_KEYCHAIN_PATH"); fi
    xcrun notarytool submit "${NOTARY_ARGS[@]}" --wait "$NOTARY_ARCHIVE"
    xcrun stapler staple "$APP"
    xcrun stapler validate "$APP"
    spctl --assess --type execute --verbose=2 "$APP"
    NOTARIZED=true
    STAPLED=true
fi

ARCHIVE_PATH="$WORK_DIR/$ARTIFACT"
"$SCRIPT_DIR/package-app.sh" "$CHANNEL" "$APP" "$ARCHIVE_PATH" "$SOURCE_EPOCH" "$WORK_DIR"
ARCHIVE_SHA="$(shasum -a 256 "$ARCHIVE_PATH" | awk '{print $1}')"
ARCHIVE_SIZE="$(/usr/bin/stat -f %z "$ARCHIVE_PATH")"
EXECUTABLE_SHA="$(shasum -a 256 "$EXECUTABLE" | awk '{print $1}')"
EXECUTABLE_UUID="$(xcrun dwarfdump --uuid "$EXECUTABLE" | awk 'NR == 1 {print $2}')"
[[ "$EXECUTABLE_UUID" =~ ^[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}$ ]] || {
    echo "ERROR: Release executable does not contain a valid LC_UUID." >&2
    exit 1
}

if [[ "$REQUIRE_SIGNING" == true ]]; then
    SIGNING_TYPE="developer-id"
    SIGNING_IDENTITY="$(codesign -d --verbose=4 "$APP" 2>&1 | awk -F= '/^Authority=Developer ID Application:/ {print substr($0, index($0, "=") + 1); exit}')"
    [[ -n "$SIGNING_IDENTITY" ]] || { echo "ERROR: Developer ID signing authority is missing." >&2; exit 1; }
else
    SIGNING_TYPE="adhoc"
    SIGNING_IDENTITY="-"
fi

[[ -z "$(git -C "$ROOT_DIR" status --porcelain=v1 --untracked-files=all)" ]] || {
    echo "ERROR: Source tree changed during the release build." >&2
    exit 1
}
[[ "$(git -C "$ROOT_DIR" rev-parse HEAD)" == "$COMMIT" ]] || { echo "ERROR: Source commit changed during the release build." >&2; exit 1; }

CHECKSUM_PATH="$WORK_DIR/$ARTIFACT.sha256"
printf '%s  %s\n' "$ARCHIVE_SHA" "$ARTIFACT" > "$CHECKSUM_PATH"
MANIFEST_PATH="$WORK_DIR/$ARTIFACT.json"
plutil -create xml1 "$MANIFEST_PATH"
plutil -insert schema_version -integer 2 "$MANIFEST_PATH"
plutil -insert channel -string "$CHANNEL" "$MANIFEST_PATH"
plutil -insert version -string "$VERSION" "$MANIFEST_PATH"
plutil -insert tag -string "$TAG" "$MANIFEST_PATH"
plutil -insert commit -string "$COMMIT" "$MANIFEST_PATH"
plutil -insert source_tree_clean -bool true "$MANIFEST_PATH"
plutil -insert artifact_filename -string "$ARTIFACT" "$MANIFEST_PATH"
plutil -insert artifact_sha256 -string "$ARCHIVE_SHA" "$MANIFEST_PATH"
plutil -insert artifact_size -integer "$ARCHIVE_SIZE" "$MANIFEST_PATH"
plutil -insert executable_sha256 -string "$EXECUTABLE_SHA" "$MANIFEST_PATH"
plutil -insert executable_uuid -string "$EXECUTABLE_UUID" "$MANIFEST_PATH"
plutil -insert signing_identity -string "$SIGNING_IDENTITY" "$MANIFEST_PATH"
plutil -insert signing_type -string "$SIGNING_TYPE" "$MANIFEST_PATH"
plutil -insert notarized -bool "$NOTARIZED" "$MANIFEST_PATH"
plutil -insert stapled -bool "$STAPLED" "$MANIFEST_PATH"
plutil -insert build_toolchain -string "$(xcrun swift --version | head -n 1)" "$MANIFEST_PATH"
plutil -insert minimum_macos -string "14.0" "$MANIFEST_PATH"
plutil -insert source_epoch -integer "$SOURCE_EPOCH" "$MANIFEST_PATH"
plutil -convert json "$MANIFEST_PATH"

VERIFY_ARGS=(--expected-commit "$COMMIT" --expected-tag "$TAG")
if [[ "$REQUIRE_SIGNING" == true ]]; then
    VERIFY_ARGS+=(--expected-team-id "$APPLE_TEAM_ID")
else
    VERIFY_ARGS+=(--allow-unauthenticated-tip)
fi
"$SCRIPT_DIR/verify-release.sh" "${VERIFY_ARGS[@]}" "$MANIFEST_PATH" "$ARCHIVE_PATH"
(
    cd "$WORK_DIR"
    shasum -a 256 -c "$(basename "$CHECKSUM_PATH")"
)

OUTPUT_PARENT="$(dirname "$OUTPUT_DIR")"
mkdir -p "$OUTPUT_PARENT"
[[ -d "$OUTPUT_PARENT" && ! -L "$OUTPUT_PARENT" ]] || { echo "ERROR: Output parent must be a real directory." >&2; exit 1; }
PUBLISH_STAGE="$(mktemp -d "$OUTPUT_PARENT/.icloud-guard-release.XXXXXX")"
cp "$ARCHIVE_PATH" "$CHECKSUM_PATH" "$MANIFEST_PATH" "$PUBLISH_STAGE/"
mv "$PUBLISH_STAGE" "$OUTPUT_DIR"
PUBLISH_STAGE=""
echo "Release artifacts: $OUTPUT_DIR"
