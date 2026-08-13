#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
# shellcheck source=scripts/shell-helpers.sh
source "$SCRIPT_DIR/shell-helpers.sh"

[[ $# -eq 0 ]] || { echo "Usage: scripts/test-tip-reproducibility.sh" >&2; exit 64; }
[[ -z "$(git -C "$ROOT_DIR" status --porcelain=v1 --untracked-files=all)" ]] || {
    echo "ERROR: Reproducibility test requires a clean source tree." >&2
    exit 1
}

REPRO_PARENT="${TMPDIR:-/private/tmp}"
REPRO_PARENT="${REPRO_PARENT%/}"
REPRO_ROOT="$(mktemp -d "$REPRO_PARENT/icloud-guard-repro.XXXXXX")"
cleanup() { safe_remove_tree "$REPRO_ROOT" "$REPRO_PARENT"; }
trap cleanup EXIT

SOURCE_COMMIT="$(git -C "$ROOT_DIR" rev-parse HEAD)"
SOURCE_EPOCH="$(git -C "$ROOT_DIR" show -s --format=%ct HEAD)"
SOURCE_FINGERPRINT="$(git -C "$ROOT_DIR" ls-files -s | shasum -a 256 | awk '{print $1}')"
assert_source_unchanged() {
    [[ "$(git -C "$ROOT_DIR" rev-parse HEAD)" == "$SOURCE_COMMIT" ]] || { echo "ERROR: Source commit changed during reproducibility test." >&2; exit 1; }
    [[ "$(git -C "$ROOT_DIR" ls-files -s | shasum -a 256 | awk '{print $1}')" == "$SOURCE_FINGERPRINT" ]] || { echo "ERROR: Tracked source index changed during reproducibility test." >&2; exit 1; }
    [[ -z "$(git -C "$ROOT_DIR" status --porcelain=v1 --untracked-files=all)" ]] || { echo "ERROR: Source tree changed during reproducibility test." >&2; exit 1; }
}

build_once() {
    local run_name="$1"
    local run_root="$REPRO_ROOT/$run_name"
    local scratch="$REPRO_ROOT/build"
    mkdir -p "$run_root" "$scratch" "$run_root/package"
    "$SCRIPT_DIR/build-app.sh" \
        --release \
        --scratch-path "$scratch" \
        --output "$run_root/ICloudGuard.app" \
        --unsigned-sha "$run_root/unsigned.sha"
    shasum -a 256 "$run_root/ICloudGuard.app/Contents/MacOS/ICloudGuard" | awk '{print $1}' > "$run_root/signed.sha"
    xcrun dwarfdump --uuid "$run_root/ICloudGuard.app/Contents/MacOS/ICloudGuard" | awk 'NR == 1 {print $2}' > "$run_root/uuid"
    "$SCRIPT_DIR/package-app.sh" tip "$run_root/ICloudGuard.app" "$run_root/ICloudGuard.zip" "$SOURCE_EPOCH" "$run_root/package"
    shasum -a 256 "$run_root/ICloudGuard.zip" | awk '{print $1}' > "$run_root/archive.sha"
    safe_remove_tree "$scratch" "$REPRO_ROOT"
    assert_source_unchanged
}

build_once one
build_once two
for evidence in unsigned.sha signed.sha uuid archive.sha; do
    cmp -s "$REPRO_ROOT/one/$evidence" "$REPRO_ROOT/two/$evidence" || {
        echo "ERROR: Tip reproducibility mismatch in $evidence." >&2
        printf 'one=%s\ntwo=%s\n' "$(cat "$REPRO_ROOT/one/$evidence")" "$(cat "$REPRO_ROOT/two/$evidence")" >&2
        exit 1
    }
done
printf 'unsigned_sha=%s\nsigned_sha=%s\nlc_uuid=%s\narchive_sha=%s\n' \
    "$(cat "$REPRO_ROOT/one/unsigned.sha")" \
    "$(cat "$REPRO_ROOT/one/signed.sha")" \
    "$(cat "$REPRO_ROOT/one/uuid")" \
    "$(cat "$REPRO_ROOT/one/archive.sha")"
