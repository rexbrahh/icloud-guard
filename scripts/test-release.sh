#!/bin/bash
set -Eeuo pipefail
report_error() {
    local status="$1"
    printf 'ERROR: test-release failed at line %s: %s\n' "$2" "$3" >&2
    exit "$status"
}
trap 'report_error "$?" "$LINENO" "$BASH_COMMAND"' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/shell-helpers.sh
source "$SCRIPT_DIR/shell-helpers.sh"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
grep -Fq 'https://github.com/rexbrahh/icloud-guard.git' "$ROOT_DIR/README.md" || {
    echo "ERROR: README does not use the canonical repository clone URL." >&2
    exit 1
}
if grep -Fq 'https://github.com/rexliu/icloud-guard.git' "$ROOT_DIR/README.md"; then
    echo "ERROR: README contains the retired repository clone URL." >&2
    exit 1
fi
TEST_PARENT="${TMPDIR:-/private/tmp}"
TEST_PARENT="${TEST_PARENT%/}"
TEST_ROOT="$(mktemp -d "$TEST_PARENT/icloud-guard-release-test.XXXXXX")"
cleanup() { safe_remove_tree "$TEST_ROOT" "$TEST_PARENT"; }
trap cleanup EXIT
mkdir -p "$TEST_ROOT/repo/scripts" "$TEST_ROOT/repo/Sources/ICloudGuardCore" "$TEST_ROOT/repo/Sources/ICloudGuardApp/Resources"
cp "$SCRIPT_DIR/version.sh" "$SCRIPT_DIR/release-gate.sh" "$SCRIPT_DIR/verify-release.sh" "$SCRIPT_DIR/package-app.sh" "$SCRIPT_DIR/shell-helpers.sh" "$SCRIPT_DIR/release-preflight.sh" "$TEST_ROOT/repo/scripts/"
cp "$ROOT_DIR/Sources/ICloudGuardCore/ProductInfo.swift" "$TEST_ROOT/repo/Sources/ICloudGuardCore/"
cp "$ROOT_DIR/Sources/ICloudGuardApp/Resources/Info.plist" "$TEST_ROOT/repo/Sources/ICloudGuardApp/Resources/"
git -C "$TEST_ROOT/repo" init -q
git -C "$TEST_ROOT/repo" add .
git -C "$TEST_ROOT/repo" -c user.name=ReleaseTest -c user.email=release@example.invalid commit -qm baseline
VERSION="$("$TEST_ROOT/repo/scripts/version.sh")"
COMMIT="$(git -C "$TEST_ROOT/repo" rev-parse HEAD)"
SHORT_COMMIT="${COMMIT:0:12}"
TIP_TAG="tip-$SHORT_COMMIT"

DEBUG_FLAGS="$("$ROOT_DIR/scripts/build-app.sh" --print-build-flags)"
RELEASE_FLAGS="$("$ROOT_DIR/scripts/build-app.sh" --release --print-build-flags)"
[[ "$DEBUG_FLAGS" != *$'-Xlinker\n-S'* ]] || { echo "ERROR: Debug build strips DWARF." >&2; exit 1; }
[[ "$RELEASE_FLAGS" == *$'-Xlinker\n-S'* ]] || { echo "ERROR: Release build does not pass linker -S." >&2; exit 1; }

expect_failure() {
    local label="$1"
    shift
    if "$@" >"$TEST_ROOT/output" 2>&1; then
        echo "ERROR: $label unexpectedly succeeded." >&2
        exit 1
    fi
}

capture_success() {
    local output
    if ! output="$("$@")"; then
        printf '%s\n' "$output" >&2
        return 1
    fi
    printf '%s' "$output"
}

"$TEST_ROOT/repo/scripts/release-gate.sh" --check --channel tip --tag "$TIP_TAG" >/dev/null
expect_failure "tag mismatch" "$TEST_ROOT/repo/scripts/release-gate.sh" --check --channel tip --tag tip
touch "$TEST_ROOT/repo/untracked"
expect_failure "dirty source" "$TEST_ROOT/repo/scripts/release-gate.sh" --check --channel tip --tag "$TIP_TAG"
"$TEST_ROOT/repo/scripts/release-gate.sh" --check --allow-dirty --channel tip --tag "$TIP_TAG" >/dev/null
expect_failure "dirty artifact override" "$TEST_ROOT/repo/scripts/release-gate.sh" --allow-dirty --channel tip --tag "$TIP_TAG" --output-dir "$TEST_ROOT/forbidden"
rm "$TEST_ROOT/repo/untracked"
expect_failure "missing signing identity" env -u CODESIGN_IDENTITY "$TEST_ROOT/repo/scripts/release-gate.sh" --check --channel beta --tag "beta-$VERSION"
expect_failure "missing notarization profile" env \
    -u NOTARY_KEYCHAIN_PROFILE \
    APPLE_TEAM_ID=ABCDE12345 \
    CODESIGN_IDENTITY="Developer ID Application: Test" \
    "$TEST_ROOT/repo/scripts/release-gate.sh" --check --channel beta --tag "beta-$VERSION"

PREFLIGHT_BACKUP="$TEST_ROOT/release-preflight.backup"
cp "$TEST_ROOT/repo/scripts/release-preflight.sh" "$PREFLIGHT_BACKUP"
printf '#!/bin/bash\nexit 42\n' > "$TEST_ROOT/repo/scripts/release-preflight.sh"
chmod 755 "$TEST_ROOT/repo/scripts/release-preflight.sh"
git -C "$TEST_ROOT/repo" add scripts/release-preflight.sh
git -C "$TEST_ROOT/repo" -c user.name=ReleaseTest -c user.email=release@example.invalid commit -qm failing-preflight
COMMIT="$(git -C "$TEST_ROOT/repo" rev-parse HEAD)"
SHORT_COMMIT="${COMMIT:0:12}"
TIP_TAG="tip-$SHORT_COMMIT"
expect_failure "failed preflight" "$TEST_ROOT/repo/scripts/release-gate.sh" --channel tip --tag "$TIP_TAG" --output-dir "$TEST_ROOT/forbidden-output"
[[ ! -e "$TEST_ROOT/forbidden-output" ]] || { echo "ERROR: Failed preflight emitted release output." >&2; exit 1; }
cp "$PREFLIGHT_BACKUP" "$TEST_ROOT/repo/scripts/release-preflight.sh"
git -C "$TEST_ROOT/repo" add scripts/release-preflight.sh
git -C "$TEST_ROOT/repo" -c user.name=ReleaseTest -c user.email=release@example.invalid commit -qm restore-preflight
COMMIT="$(git -C "$TEST_ROOT/repo" rev-parse HEAD)"
SHORT_COMMIT="${COMMIT:0:12}"
TIP_TAG="tip-$SHORT_COMMIT"

FIXTURE="$TEST_ROOT/fixture"
APP="$FIXTURE/ICloudGuard.app"
mkdir -p "$APP/Contents/MacOS"
MARKER="$TEST_ROOT/verifier-executed-untrusted-code"
cat > "$FIXTURE/main.c" <<'EOF'
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
int main(int argc, char **argv) {
    if (argc == 2 && strcmp(argv[1], "--version") == 0) {
        close(creat(MARKER_PATH, 0600));
    }
    return 0;
}
EOF
xcrun clang -target arm64-apple-macos14.0 -Wl,-S -DMARKER_PATH="\"$MARKER\"" "$FIXTURE/main.c" -o "$APP/Contents/MacOS/ICloudGuard"
cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>ICloudGuard</string>
<key>CFBundleIdentifier</key><string>dev.rexliu.ICloudGuard.release-test</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$VERSION</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
</dict></plist>
EOF
codesign --force --sign - "$APP"

ARCHIVE_NAME="ICloudGuard-tip-$VERSION-$SHORT_COMMIT.zip"
ARCHIVE="$TEST_ROOT/$ARCHIVE_NAME"
"$TEST_ROOT/repo/scripts/package-app.sh" tip "$APP" "$ARCHIVE" 1700000000 "$TEST_ROOT"
ARCHIVE_SHA="$(shasum -a 256 "$ARCHIVE" | awk '{print $1}')"
ARCHIVE_SIZE="$(/usr/bin/stat -f %z "$ARCHIVE")"
EXECUTABLE_SHA="$(shasum -a 256 "$APP/Contents/MacOS/ICloudGuard" | awk '{print $1}')"
EXECUTABLE_UUID="$(xcrun dwarfdump --uuid "$APP/Contents/MacOS/ICloudGuard" | awk 'NR == 1 {print $2}')"
MANIFEST="$ARCHIVE.json"

write_manifest() {
    plutil -create xml1 "$MANIFEST"
    plutil -insert schema_version -integer 2 "$MANIFEST"
    plutil -insert channel -string tip "$MANIFEST"
    plutil -insert version -string "$VERSION" "$MANIFEST"
    plutil -insert tag -string "$TIP_TAG" "$MANIFEST"
    plutil -insert commit -string "$COMMIT" "$MANIFEST"
    plutil -insert source_tree_clean -bool true "$MANIFEST"
    plutil -insert artifact_filename -string "$ARCHIVE_NAME" "$MANIFEST"
    plutil -insert artifact_sha256 -string "$ARCHIVE_SHA" "$MANIFEST"
    plutil -insert artifact_size -integer "$ARCHIVE_SIZE" "$MANIFEST"
    plutil -insert executable_sha256 -string "$EXECUTABLE_SHA" "$MANIFEST"
    plutil -insert executable_uuid -string "$EXECUTABLE_UUID" "$MANIFEST"
    plutil -insert signing_identity -string - "$MANIFEST"
    plutil -insert signing_type -string adhoc "$MANIFEST"
    plutil -insert notarized -bool false "$MANIFEST"
    plutil -insert stapled -bool false "$MANIFEST"
    plutil -insert build_toolchain -string "release-test" "$MANIFEST"
    plutil -insert minimum_macos -string 14.0 "$MANIFEST"
    plutil -insert source_epoch -integer 1700000000 "$MANIFEST"
    plutil -convert json "$MANIFEST"
}

write_manifest
expect_failure "tip provenance from commit and tag alone" \
    "$TEST_ROOT/repo/scripts/verify-release.sh" --expected-commit "$COMMIT" --expected-tag "$TIP_TAG" "$MANIFEST" "$ARCHIVE"
INTEGRITY_OUTPUT="$(capture_success "$TEST_ROOT/repo/scripts/verify-release.sh" \
    --expected-commit "$COMMIT" \
    --expected-tag "$TIP_TAG" \
    --allow-unauthenticated-tip \
    "$MANIFEST" "$ARCHIVE")"
[[ "$INTEGRITY_OUTPUT" == "Internal consistency verified; publisher and source provenance not authenticated: $ARCHIVE_NAME" ]] || {
    echo "ERROR: Integrity-only tip label is misleading." >&2
    exit 1
}
expect_failure "independent digest mismatch" \
    "$TEST_ROOT/repo/scripts/verify-release.sh" \
        --expected-commit "$COMMIT" \
        --expected-tag "$TIP_TAG" \
        --expected-sha256 "$(printf '0%.0s' {1..64})" \
        "$MANIFEST" "$ARCHIVE"
VERIFIED_DIGEST_OUTPUT="$(capture_success "$TEST_ROOT/repo/scripts/verify-release.sh" \
    --expected-commit "$COMMIT" \
    --expected-tag "$TIP_TAG" \
    --expected-sha256 "$ARCHIVE_SHA" \
    "$MANIFEST" "$ARCHIVE")"
[[ "$VERIFIED_DIGEST_OUTPUT" == "Artifact integrity verified against independent digest; source provenance not authenticated: $ARCHIVE_NAME" ]] || {
    echo "ERROR: Independent-digest tip label is misleading." >&2
    exit 1
}
[[ ! -e "$MARKER" ]] || { echo "ERROR: Release verifier executed the extracted app." >&2; exit 1; }
expect_failure "missing independent provenance" "$TEST_ROOT/repo/scripts/verify-release.sh" "$MANIFEST" "$ARCHIVE"
[[ ! -e "$MARKER" ]] || { echo "ERROR: Release verifier executed the extracted app on failure." >&2; exit 1; }

expect_manifest_failure() {
    local label="$1"
    shift
    write_manifest
    plutil -convert xml1 "$MANIFEST"
    "$@"
    plutil -convert json "$MANIFEST"
    expect_failure "$label" "$TEST_ROOT/repo/scripts/verify-release.sh" \
        --expected-commit "$COMMIT" \
        --expected-tag "$TIP_TAG" \
        --expected-sha256 "$ARCHIVE_SHA" \
        "$MANIFEST" "$ARCHIVE"
    [[ ! -e "$MARKER" ]] || { echo "ERROR: Release verifier executed the extracted app during $label." >&2; exit 1; }
}

expect_manifest_failure "caller commit mismatch" plutil -replace commit -string "$(printf '0%.0s' {1..40})" "$MANIFEST"
expect_manifest_failure "tag lie" plutil -replace tag -string tip-lie "$MANIFEST"
expect_manifest_failure "signing lie" plutil -replace signing_type -string developer-id "$MANIFEST"
expect_manifest_failure "notarization lie" plutil -replace notarized -bool true "$MANIFEST"
expect_manifest_failure "artifact name lie" plutil -replace artifact_filename -string wrong.zip "$MANIFEST"
expect_manifest_failure "checksum lie" plutil -replace artifact_sha256 -string "$(printf '0%.0s' {1..64})" "$MANIFEST"
expect_manifest_failure "size lie" plutil -replace artifact_size -integer 1 "$MANIFEST"
expect_manifest_failure "missing field" plutil -remove source_epoch "$MANIFEST"
expect_manifest_failure "unknown field" plutil -insert extra -string nope "$MANIFEST"

echo "Release gate tests passed."
"$SCRIPT_DIR/test-update-feed.sh"
