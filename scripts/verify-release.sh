#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/shell-helpers.sh
source "$SCRIPT_DIR/shell-helpers.sh"

report_unexpected_failure() {
    local status=$?
    echo "ERROR: Release verifier command failed at line ${BASH_LINENO[0]}." >&2
    exit "$status"
}
trap report_unexpected_failure ERR

EXPECTED_COMMIT=""
EXPECTED_TAG=""
EXPECTED_TEAM_ID=""
EXPECTED_SHA256=""
ALLOW_UNAUTHENTICATED_TIP=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --expected-commit|--expected-tag|--expected-team-id|--expected-sha256)
            [[ $# -ge 2 ]] || { echo "ERROR: $1 requires a value." >&2; exit 64; }
            case "$1" in
                --expected-commit) EXPECTED_COMMIT="$2" ;;
                --expected-tag) EXPECTED_TAG="$2" ;;
                --expected-team-id) EXPECTED_TEAM_ID="$2" ;;
                --expected-sha256) EXPECTED_SHA256="$2" ;;
            esac
            shift 2
            ;;
        --allow-unauthenticated-tip) ALLOW_UNAUTHENTICATED_TIP=true; shift ;;
        --) shift; break ;;
        -*) echo "ERROR: Unknown argument: $1" >&2; exit 64 ;;
        *) break ;;
    esac
done
[[ $# -eq 2 ]] || {
    echo "Usage: scripts/verify-release.sh --expected-commit SHA --expected-tag TAG [--expected-team-id TEAM] [--expected-sha256 DIGEST | --allow-unauthenticated-tip] MANIFEST ARCHIVE" >&2
    exit 64
}
[[ "$EXPECTED_COMMIT" =~ ^[0-9a-f]{40}$ ]] || { echo "ERROR: --expected-commit must be an independently obtained full commit SHA." >&2; exit 64; }
[[ -n "$EXPECTED_TAG" ]] || { echo "ERROR: --expected-tag is required." >&2; exit 64; }
if [[ -n "$EXPECTED_SHA256" && ! "$EXPECTED_SHA256" =~ ^[0-9a-f]{64}$ ]]; then
    echo "ERROR: --expected-sha256 must be a lowercase SHA-256 digest." >&2
    exit 64
fi

MANIFEST="$1"
ARCHIVE="$2"
[[ -f "$MANIFEST" && ! -L "$MANIFEST" ]] || { echo "ERROR: Release manifest is not a real file: $MANIFEST" >&2; exit 1; }
[[ -f "$ARCHIVE" && ! -L "$ARCHIVE" ]] || { echo "ERROR: Release archive is not a real file: $ARCHIVE" >&2; exit 1; }

extract() {
    local key="$1"
    local expected_type="$2"
    plutil -extract "$key" raw -expect "$expected_type" -o - "$MANIFEST"
}

EXPECTED_KEYS=$'artifact_filename\nartifact_sha256\nartifact_size\nbuild_toolchain\nchannel\ncommit\nexecutable_sha256\nexecutable_uuid\nminimum_macos\nnotarized\nschema_version\nsigning_identity\nsigning_type\nsource_epoch\nsource_tree_clean\nstapled\ntag\nversion'
ACTUAL_KEYS="$(
    plutil -convert xml1 -o - "$MANIFEST" |
        sed -n 's/^[[:space:]]*<key>\([^<]*\)<\/key>[[:space:]]*$/\1/p' |
        LC_ALL=C sort
)"
if [[ "$ACTUAL_KEYS" != "$EXPECTED_KEYS" ]]; then
    echo "ERROR: Release manifest keys do not match schema 2." >&2
    exit 1
fi

[[ "$(extract schema_version integer)" == "2" ]] || { echo "ERROR: Unsupported release manifest schema." >&2; exit 1; }
CHANNEL="$(extract channel string)"
VERSION="$(extract version string)"
TAG="$(extract tag string)"
COMMIT="$(extract commit string)"
SOURCE_TREE_CLEAN="$(extract source_tree_clean bool)"
ARTIFACT_FILENAME="$(extract artifact_filename string)"
EXPECTED_SHA="$(extract artifact_sha256 string)"
EXPECTED_SIZE="$(extract artifact_size integer)"
EXPECTED_EXECUTABLE_SHA="$(extract executable_sha256 string)"
EXECUTABLE_UUID="$(extract executable_uuid string)"
SIGNING_IDENTITY="$(extract signing_identity string)"
SIGNING_TYPE="$(extract signing_type string)"
NOTARIZED="$(extract notarized bool)"
STAPLED="$(extract stapled bool)"
BUILD_TOOLCHAIN="$(extract build_toolchain string)"
MINIMUM_MACOS="$(extract minimum_macos string)"
SOURCE_EPOCH="$(extract source_epoch integer)"

[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "ERROR: Release version is invalid." >&2; exit 1; }
[[ "$COMMIT" =~ ^[0-9a-f]{40}$ ]] || { echo "ERROR: Release commit is invalid." >&2; exit 1; }
[[ "$SOURCE_TREE_CLEAN" == "true" ]] || { echo "ERROR: Release manifest does not attest to clean source." >&2; exit 1; }
[[ "$EXPECTED_SHA" =~ ^[0-9a-f]{64}$ && "$EXPECTED_EXECUTABLE_SHA" =~ ^[0-9a-f]{64}$ ]] || { echo "ERROR: Release checksum is invalid." >&2; exit 1; }
[[ "$EXPECTED_SIZE" =~ ^[1-9][0-9]*$ && "$SOURCE_EPOCH" =~ ^[0-9]+$ ]] || { echo "ERROR: Release size or source epoch is invalid." >&2; exit 1; }
[[ "$EXECUTABLE_UUID" =~ ^[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}$ ]] || { echo "ERROR: Executable LC_UUID is invalid." >&2; exit 1; }
[[ -n "$BUILD_TOOLCHAIN" ]] || { echo "ERROR: Build toolchain is empty." >&2; exit 1; }
[[ "$MINIMUM_MACOS" == "15.0" ]] || { echo "ERROR: Minimum macOS claim is invalid." >&2; exit 1; }

SHORT_COMMIT="${COMMIT:0:12}"
case "$CHANNEL" in
    stable)
        EXPECTED_NAME="ICloudGuard-$VERSION.zip"
        EXPECTED_CHANNEL_TAG="v$VERSION"
        [[ "$SIGNING_TYPE" == "developer-id" && "$SIGNING_IDENTITY" == "Developer ID Application:"* ]] || { echo "ERROR: Stable release signing claim is invalid." >&2; exit 1; }
        [[ "$EXPECTED_TEAM_ID" =~ ^[A-Z0-9]{10}$ ]] || { echo "ERROR: Stable verification requires --expected-team-id." >&2; exit 64; }
        [[ "$NOTARIZED" == "true" && "$STAPLED" == "true" ]] || { echo "ERROR: Stable release must be notarized and stapled." >&2; exit 1; }
        ;;
    beta)
        EXPECTED_NAME="ICloudGuard-beta-$VERSION.zip"
        EXPECTED_CHANNEL_TAG="beta-$VERSION"
        [[ "$SIGNING_TYPE" == "developer-id" && "$SIGNING_IDENTITY" == "Developer ID Application:"* ]] || { echo "ERROR: Beta release signing claim is invalid." >&2; exit 1; }
        [[ "$EXPECTED_TEAM_ID" =~ ^[A-Z0-9]{10}$ ]] || { echo "ERROR: Beta verification requires --expected-team-id." >&2; exit 64; }
        [[ "$NOTARIZED" == "true" && "$STAPLED" == "true" ]] || { echo "ERROR: Beta release must be notarized and stapled." >&2; exit 1; }
        ;;
    tip)
        EXPECTED_NAME="ICloudGuard-tip-$VERSION-$SHORT_COMMIT.zip"
        EXPECTED_CHANNEL_TAG="tip-$SHORT_COMMIT"
        [[ "$SIGNING_TYPE" == "adhoc" && "$SIGNING_IDENTITY" == "-" ]] || { echo "ERROR: Tip release must claim ad hoc signing." >&2; exit 1; }
        [[ "$NOTARIZED" == "false" && "$STAPLED" == "false" ]] || { echo "ERROR: Tip release cannot claim notarization or stapling." >&2; exit 1; }
        [[ -z "$EXPECTED_TEAM_ID" ]] || { echo "ERROR: Tip verification must not supply a Developer Team ID." >&2; exit 64; }
        [[ -n "$EXPECTED_SHA256" || "$ALLOW_UNAUTHENTICATED_TIP" == true ]] || {
            echo "ERROR: Tip verification requires an independent --expected-sha256 or explicit --allow-unauthenticated-tip acknowledgment." >&2
            exit 64
        }
        ;;
    *) echo "ERROR: Release channel is invalid." >&2; exit 1 ;;
esac
[[ "$TAG" == "$EXPECTED_CHANNEL_TAG" ]] || { echo "ERROR: Release tag is inconsistent with channel provenance." >&2; exit 1; }
[[ "$ARTIFACT_FILENAME" == "$EXPECTED_NAME" && "$(basename "$ARCHIVE")" == "$EXPECTED_NAME" ]] || { echo "ERROR: Release artifact name is inconsistent with channel provenance." >&2; exit 1; }
[[ "$COMMIT" == "$EXPECTED_COMMIT" ]] || { echo "ERROR: Release commit does not match caller expectation." >&2; exit 1; }
[[ "$TAG" == "$EXPECTED_TAG" ]] || { echo "ERROR: Release tag does not match caller expectation." >&2; exit 1; }

ACTUAL_SIZE="$(/usr/bin/stat -f %z "$ARCHIVE")"
ACTUAL_SHA="$(shasum -a 256 "$ARCHIVE" | awk '{print $1}')"
[[ "$ACTUAL_SIZE" == "$EXPECTED_SIZE" ]] || { echo "ERROR: Release archive size mismatch." >&2; exit 1; }
[[ "$ACTUAL_SHA" == "$EXPECTED_SHA" ]] || { echo "ERROR: Release archive checksum mismatch." >&2; exit 1; }
if [[ -n "$EXPECTED_SHA256" ]]; then
    [[ "$ACTUAL_SHA" == "$EXPECTED_SHA256" ]] || { echo "ERROR: Release archive does not match the independently supplied digest." >&2; exit 1; }
fi

ARCHIVE_LIST="$(/usr/bin/unzip -Z1 "$ARCHIVE")"
[[ -n "$ARCHIVE_LIST" ]] || { echo "ERROR: Release archive is empty." >&2; exit 1; }
while IFS= read -r path; do
    [[ "$path" == "ICloudGuard.app" || "$path" == "ICloudGuard.app/" || "$path" == ICloudGuard.app/* ]] || {
        echo "ERROR: Release archive has an unexpected root: $path" >&2
        exit 1
    }
    [[ "$path" != /* && "$path" != *"/../"* && "$path" != "../"* && "$path" != *"/.." && "$path" != *"\\"* ]] || {
        echo "ERROR: Release archive path is unsafe: $path" >&2
        exit 1
    }
done <<< "$ARCHIVE_LIST"

VERIFY_PARENT="${TMPDIR:-/private/tmp}"
VERIFY_PARENT="${VERIFY_PARENT%/}"
[[ -d "$VERIFY_PARENT" && ! -L "$VERIFY_PARENT" ]] || { echo "ERROR: Verification temporary parent is unsafe." >&2; exit 1; }
VERIFY_ROOT="$(mktemp -d "$VERIFY_PARENT/icloud-guard-verify.XXXXXX")"
cleanup() { safe_remove_tree "$VERIFY_ROOT" "$VERIFY_PARENT"; }
trap cleanup EXIT
/usr/bin/ditto -x -k "$ARCHIVE" "$VERIFY_ROOT"
APP="$VERIFY_ROOT/ICloudGuard.app"
[[ -d "$APP" && ! -L "$APP" ]] || { echo "ERROR: Release archive does not contain one real ICloudGuard.app." >&2; exit 1; }
[[ "$(/usr/bin/find -P "$VERIFY_ROOT" -mindepth 1 -maxdepth 1 -print | wc -l | tr -d ' ')" == "1" ]] || { echo "ERROR: Release archive contains unexpected top-level content." >&2; exit 1; }
if /usr/bin/find -P "$APP" -type l -print -quit | grep -q .; then
    echo "ERROR: Release app contains a symlink." >&2
    exit 1
fi
INFO="$APP/Contents/Info.plist"
EXECUTABLE="$APP/Contents/MacOS/ICloudGuard"
[[ -f "$INFO" && ! -L "$INFO" && -x "$EXECUTABLE" && ! -L "$EXECUTABLE" ]] || { echo "ERROR: Release app structure is invalid." >&2; exit 1; }
[[ "$(plutil -extract CFBundleShortVersionString raw -expect string -o - "$INFO")" == "$VERSION" ]] || { echo "ERROR: Release app version mismatch." >&2; exit 1; }
[[ "$(plutil -extract LSMinimumSystemVersion raw -expect string -o - "$INFO")" == "$MINIMUM_MACOS" ]] || { echo "ERROR: Release app minimum macOS mismatch." >&2; exit 1; }
[[ "$(shasum -a 256 "$EXECUTABLE" | awk '{print $1}')" == "$EXPECTED_EXECUTABLE_SHA" ]] || { echo "ERROR: Release executable checksum mismatch." >&2; exit 1; }
[[ "$(xcrun dwarfdump --uuid "$EXECUTABLE" | awk 'NR == 1 {print $2}')" == "$EXECUTABLE_UUID" ]] || { echo "ERROR: Release executable LC_UUID mismatch." >&2; exit 1; }
codesign --verify --deep --strict --verbose=2 "$APP"
CODESIGN_DETAILS="$(codesign -d --verbose=4 "$APP" 2>&1)"
if [[ "$SIGNING_TYPE" == "adhoc" ]]; then
    grep -q '^Signature=adhoc$' <<< "$CODESIGN_DETAILS" || { echo "ERROR: Tip release is not ad hoc signed." >&2; exit 1; }
    if grep -q '^Authority=' <<< "$CODESIGN_DETAILS"; then echo "ERROR: Tip release unexpectedly has a signing authority." >&2; exit 1; fi
else
    grep -Fqx "Authority=$SIGNING_IDENTITY" <<< "$CODESIGN_DETAILS" || { echo "ERROR: Developer ID signing authority mismatch." >&2; exit 1; }
    grep -Fqx "TeamIdentifier=$EXPECTED_TEAM_ID" <<< "$CODESIGN_DETAILS" || { echo "ERROR: Developer Team ID mismatch." >&2; exit 1; }
    grep -q '^Authority=Developer ID Application:' <<< "$CODESIGN_DETAILS" || { echo "ERROR: Developer ID Application authority is missing." >&2; exit 1; }
fi
if [[ "$NOTARIZED" == "true" ]]; then
    xcrun stapler validate "$APP"
    spctl --assess --type execute --verbose=2 "$APP"
fi

if [[ "$CHANNEL" == "tip" ]]; then
    if [[ -n "$EXPECTED_SHA256" ]]; then
        echo "Artifact integrity verified against independent digest; source provenance not authenticated: $(basename "$ARCHIVE")"
    else
        echo "Internal consistency verified; publisher and source provenance not authenticated: $(basename "$ARCHIVE")"
    fi
else
    echo "Publisher and integrity verified; source provenance relies on trusted CI: $(basename "$ARCHIVE")"
fi
