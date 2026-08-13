#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/shell-helpers.sh
source "$SCRIPT_DIR/shell-helpers.sh"

TEST_PARENT="${TMPDIR:-/private/tmp}"
TEST_PARENT="${TEST_PARENT%/}"
TEST_ROOT="$(mktemp -d "$TEST_PARENT/icloud-guard-feed-test.XXXXXX")"
cleanup() { safe_remove_tree "$TEST_ROOT" "$TEST_PARENT"; }
trap cleanup EXIT

TOOL="$TEST_ROOT/update-feed"
/usr/bin/xcrun swiftc -warnings-as-errors "$SCRIPT_DIR/update-feed.swift" -o "$TOOL"

expect_failure() {
    local label="$1"
    shift
    if "$@" >"$TEST_ROOT/output" 2>&1; then
        echo "ERROR: $label unexpectedly succeeded." >&2
        exit 1
    fi
}

REAL_OUTPUT_PARENT="$TEST_ROOT/real-output-parent"
SYMLINK_OUTPUT_PARENT="$TEST_ROOT/symlink-output-parent"
mkdir "$REAL_OUTPUT_PARENT"
ln -s "$REAL_OUTPUT_PARENT" "$SYMLINK_OUTPUT_PARENT"
expect_failure "symlink output parent" \
    "$TOOL" keygen \
        --private-key "$SYMLINK_OUTPUT_PARENT/private.pem" \
        --public-key "$SYMLINK_OUTPUT_PARENT/public.txt"
[[ ! -e "$REAL_OUTPUT_PARENT/private.pem" && ! -e "$REAL_OUTPUT_PARENT/public.txt" ]] || {
    echo "ERROR: Feed key generator wrote through a symlink output parent." >&2
    exit 1
}

OUTPUT_CANARY="$TEST_ROOT/output-canary"
SYMLINK_OUTPUT="$TEST_ROOT/symlink-private.pem"
printf 'preserve-output-canary' > "$OUTPUT_CANARY"
ln -s "$OUTPUT_CANARY" "$SYMLINK_OUTPUT"
expect_failure "symlink output canary" \
    "$TOOL" keygen \
        --private-key "$SYMLINK_OUTPUT" \
        --public-key "$TEST_ROOT/symlink-public.txt"
[[ -L "$SYMLINK_OUTPUT" && "$(< "$OUTPUT_CANARY")" == "preserve-output-canary" && \
    ! -e "$TEST_ROOT/symlink-public.txt" ]] || {
    echo "ERROR: Feed key generator modified a symlink output canary." >&2
    exit 1
}

NORMALIZED_OUTPUT_PARENT="$TEST_ROOT/normalized-output-parent"
mkdir "$NORMALIZED_OUTPUT_PARENT"
expect_failure "non-normalized output path" \
    "$TOOL" keygen \
        --private-key "$NORMALIZED_OUTPUT_PARENT/../non-normalized-private.pem" \
        --public-key "$TEST_ROOT/non-normalized-public.txt"
[[ ! -e "$TEST_ROOT/non-normalized-private.pem" && ! -e "$TEST_ROOT/non-normalized-public.txt" ]] || {
    echo "ERROR: Feed key generator accepted a non-normalized output path." >&2
    exit 1
}

PRIVATE_KEY="$TEST_ROOT/private.pem"
PUBLIC_KEY="$TEST_ROOT/public.txt"
"$TOOL" keygen --private-key "$PRIVATE_KEY" --public-key "$PUBLIC_KEY"
[[ "$(/usr/bin/stat -f %Lp "$PRIVATE_KEY")" == "600" ]] || {
    echo "ERROR: Feed key generator did not protect the private key." >&2
    exit 1
}
PUBLIC_KEY_BASE64="$(tr -d '\n' < "$PUBLIC_KEY")"
[[ "$PUBLIC_KEY_BASE64" =~ ^[A-Za-z0-9+/]{87}=$ ]] || {
    echo "ERROR: Feed key generator did not emit an uncompressed P-256 public key." >&2
    exit 1
}

VERSION="1.2.3"
CHANNEL="stable"
TEAM_ID="ABCDE12345"
KEY_ID="release-2026-a"
ARTIFACT="ICloudGuard-$VERSION.zip"
ORIGIN="https://updates.example.invalid/icloud-guard"
MANIFEST="$TEST_ROOT/$ARTIFACT.json"
ARTIFACT_PATH="$TEST_ROOT/$ARTIFACT"
FEED="$TEST_ROOT/feed.json"
GENERATED="$(date +%s)"
EXPIRES="$((GENERATED + 604800))"
MARKER="$TEST_ROOT/shell-injection-marker"
printf 'verified release archive fixture' > "$ARTIFACT_PATH"
ARTIFACT_SHA="$(shasum -a 256 "$ARTIFACT_PATH" | awk '{print $1}')"
ARTIFACT_SIZE="$(/usr/bin/stat -f %z "$ARTIFACT_PATH")"

write_manifest() {
    local tag
    if [[ "$CHANNEL" == "stable" ]]; then tag="v$VERSION"; else tag="beta-$VERSION"; fi
    plutil -create xml1 "$MANIFEST"
    plutil -insert schema_version -integer 2 "$MANIFEST"
    plutil -insert channel -string "$CHANNEL" "$MANIFEST"
    plutil -insert version -string "$VERSION" "$MANIFEST"
    plutil -insert tag -string "$tag" "$MANIFEST"
    plutil -insert commit -string 0123456789abcdef0123456789abcdef01234567 "$MANIFEST"
    plutil -insert source_tree_clean -bool true "$MANIFEST"
    plutil -insert artifact_filename -string "$ARTIFACT" "$MANIFEST"
    plutil -insert artifact_sha256 -string "$ARTIFACT_SHA" "$MANIFEST"
    plutil -insert artifact_size -integer "$ARTIFACT_SIZE" "$MANIFEST"
    plutil -insert executable_sha256 -string bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb "$MANIFEST"
    plutil -insert executable_uuid -string 12345678-1234-ABCD-9876-123456789ABC "$MANIFEST"
    plutil -insert signing_identity -string "Developer ID Application: Fixture \$(touch $MARKER)" "$MANIFEST"
    plutil -insert signing_type -string developer-id "$MANIFEST"
    plutil -insert notarized -bool true "$MANIFEST"
    plutil -insert stapled -bool true "$MANIFEST"
    plutil -insert build_toolchain -string "Apple Swift fixture" "$MANIFEST"
    plutil -insert minimum_macos -string 14.0 "$MANIFEST"
    plutil -insert source_epoch -integer 1700000000 "$MANIFEST"
    plutil -convert json "$MANIFEST"
}

create_feed() {
    "$TOOL" create \
        --manifest "$MANIFEST" \
        --artifact "$ARTIFACT_PATH" \
        --update-origin "$ORIGIN" \
        --channel "$CHANNEL" \
        --team-id "$TEAM_ID" \
        --key-id "$KEY_ID" \
        --private-key "$PRIVATE_KEY" \
        --generated-at "$GENERATED" \
        --expires-at "$EXPIRES" \
        --output "$FEED"
}

verify_feed() {
    "$TOOL" verify \
        --feed "$FEED" \
        --update-origin "$ORIGIN" \
        --channel "$CHANNEL" \
        --team-id "$TEAM_ID" \
        --key-id "$KEY_ID" \
        --public-key-x963-base64 "$PUBLIC_KEY_BASE64" \
        --checked-at "$GENERATED"
}

write_manifest
create_feed
verify_feed
[[ ! -e "$MARKER" ]] || { echo "ERROR: Feed producer executed manifest text." >&2; exit 1; }
[[ "$(plutil -extract schema raw -expect integer -o - "$FEED")" == "1" ]] || {
    echo "ERROR: Feed envelope schema is invalid." >&2
    exit 1
}
[[ "$(plutil -extract keyID raw -expect string -o - "$FEED")" == "$KEY_ID" ]] || {
    echo "ERROR: Feed key ID is invalid." >&2
    exit 1
}
if grep -Fq 'PRIVATE KEY' "$FEED"; then
    echo "ERROR: Feed output contains private key material." >&2
    exit 1
fi

expect_failure "existing feed overwrite" create_feed
cp "$ARTIFACT_PATH" "$TEST_ROOT/artifact.backup"
printf 'tampered release archive fixture' > "$ARTIFACT_PATH"
expect_failure "tampered artifact" \
    "$TOOL" create \
        --manifest "$MANIFEST" \
        --artifact "$ARTIFACT_PATH" \
        --update-origin "$ORIGIN" \
        --channel "$CHANNEL" \
        --team-id "$TEAM_ID" \
        --key-id "$KEY_ID" \
        --private-key "$PRIVATE_KEY" \
        --generated-at "$GENERATED" \
        --expires-at "$EXPIRES" \
        --output "$TEST_ROOT/tampered-artifact.json"
mv "$TEST_ROOT/artifact.backup" "$ARTIFACT_PATH"
expect_failure "non-HTTPS update origin" \
    "$TOOL" create \
        --manifest "$MANIFEST" \
        --artifact "$ARTIFACT_PATH" \
        --update-origin "http://updates.example.invalid/icloud-guard" \
        --channel "$CHANNEL" \
        --team-id "$TEAM_ID" \
        --key-id "$KEY_ID" \
        --private-key "$PRIVATE_KEY" \
        --generated-at "$GENERATED" \
        --expires-at "$EXPIRES" \
        --output "$TEST_ROOT/cross-origin.json"

chmod 644 "$PRIVATE_KEY"
expect_failure "readable private key" \
    "$TOOL" create \
        --manifest "$MANIFEST" \
        --artifact "$ARTIFACT_PATH" \
        --update-origin "$ORIGIN" \
        --channel "$CHANNEL" \
        --team-id "$TEAM_ID" \
        --key-id "$KEY_ID" \
        --private-key "$PRIVATE_KEY" \
        --generated-at "$GENERATED" \
        --expires-at "$EXPIRES" \
        --output "$TEST_ROOT/readable-key.json"
chmod 600 "$PRIVATE_KEY"

TAMPERED="$TEST_ROOT/tampered.json"
cp "$FEED" "$TAMPERED"
plutil -replace signature -string AAAA "$TAMPERED"
expect_failure "tampered signature" \
    "$TOOL" verify \
        --feed "$TAMPERED" \
        --update-origin "$ORIGIN" \
        --channel "$CHANNEL" \
        --team-id "$TEAM_ID" \
        --key-id "$KEY_ID" \
        --public-key-x963-base64 "$PUBLIC_KEY_BASE64" \
        --checked-at "$GENERATED"

OTHER_PRIVATE="$TEST_ROOT/other.pem"
OTHER_PUBLIC="$TEST_ROOT/other-public.txt"
"$TOOL" keygen --private-key "$OTHER_PRIVATE" --public-key "$OTHER_PUBLIC"
expect_failure "wrong public key" \
    "$TOOL" verify \
        --feed "$FEED" \
        --update-origin "$ORIGIN" \
        --channel "$CHANNEL" \
        --team-id "$TEAM_ID" \
        --key-id "$KEY_ID" \
        --public-key-x963-base64 "$(tr -d '\n' < "$OTHER_PUBLIC")" \
        --checked-at "$GENERATED"

UNKNOWN_MANIFEST="$TEST_ROOT/unknown.json"
cp "$MANIFEST" "$UNKNOWN_MANIFEST"
plutil -insert unexpected -string rejected "$UNKNOWN_MANIFEST"
expect_failure "unknown manifest field" \
    "$TOOL" create \
        --manifest "$UNKNOWN_MANIFEST" \
        --artifact "$ARTIFACT_PATH" \
        --update-origin "$ORIGIN" \
        --channel "$CHANNEL" \
        --team-id "$TEAM_ID" \
        --key-id "$KEY_ID" \
        --private-key "$PRIVATE_KEY" \
        --generated-at "$GENERATED" \
        --expires-at "$EXPIRES" \
        --output "$TEST_ROOT/unknown.json.feed"

CHANNEL="beta"
ARTIFACT="ICloudGuard-beta-$VERSION.zip"
ARTIFACT_PATH="$TEST_ROOT/$ARTIFACT"
MANIFEST="$TEST_ROOT/$ARTIFACT.json"
FEED="$TEST_ROOT/beta-feed.json"
printf 'verified beta archive fixture' > "$ARTIFACT_PATH"
ARTIFACT_SHA="$(shasum -a 256 "$ARTIFACT_PATH" | awk '{print $1}')"
ARTIFACT_SIZE="$(/usr/bin/stat -f %z "$ARTIFACT_PATH")"
write_manifest
create_feed
verify_feed

expect_failure "tip channel" \
    "$TOOL" create \
        --manifest "$MANIFEST" \
        --artifact "$ARTIFACT_PATH" \
        --update-origin "$ORIGIN" \
        --channel tip \
        --team-id "$TEAM_ID" \
        --key-id "$KEY_ID" \
        --private-key "$PRIVATE_KEY" \
        --generated-at "$GENERATED" \
        --expires-at "$EXPIRES" \
        --output "$TEST_ROOT/tip.json"

echo "Update feed tests passed."
