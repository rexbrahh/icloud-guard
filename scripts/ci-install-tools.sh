#!/bin/bash
set -euo pipefail

[[ $# -eq 1 ]] || { echo "Usage: scripts/ci-install-tools.sh DESTINATION" >&2; exit 64; }
DESTINATION="$1"
[[ "$DESTINATION" == /* ]] || { echo "ERROR: Tool destination must be absolute." >&2; exit 64; }
mkdir -p "$DESTINATION"

SHELLCHECK_VERSION=0.10.0
ACTIONLINT_VERSION=1.7.7
case "$(uname -m)" in
    arm64)
        SHELLCHECK_ARCH=aarch64
        ACTIONLINT_ARCH=arm64
        SHELLCHECK_SHA=bbd2f14826328eee7679da7221f2bc3afb011f6a928b848c80c321f6046ddf81
        ACTIONLINT_SHA=2693315b9093aeacb4ebd91a993fea54fc215057bf0da2659056b4bc033873db
        ;;
    x86_64)
        SHELLCHECK_ARCH=x86_64
        ACTIONLINT_ARCH=amd64
        SHELLCHECK_SHA=ef27684f23279d112d8ad84e0823642e43f838993bbb8c0963db9b58a90464c2
        ACTIONLINT_SHA=28e5de5a05fc558474f638323d736d822fff183d2d492f0aecb2b73cc44584f5
        ;;
    *) echo "ERROR: Unsupported runner architecture: $(uname -m)" >&2; exit 1 ;;
esac

WORK_PARENT="${RUNNER_TEMP:-${TMPDIR:-/private/tmp}}"
WORK_PARENT="${WORK_PARENT%/}"
WORK_DIR="$(mktemp -d "$WORK_PARENT/icloud-guard-tools.XXXXXX")"
cleanup() {
    /usr/bin/find -P "$WORK_DIR" -depth -mindepth 1 -delete
    rmdir "$WORK_DIR"
}
trap cleanup EXIT

SHELLCHECK_ARCHIVE="shellcheck-v${SHELLCHECK_VERSION}.darwin.${SHELLCHECK_ARCH}.tar.xz"
ACTIONLINT_ARCHIVE="actionlint_${ACTIONLINT_VERSION}_darwin_${ACTIONLINT_ARCH}.tar.gz"
curl --fail --location --silent --show-error \
    "https://github.com/koalaman/shellcheck/releases/download/v${SHELLCHECK_VERSION}/${SHELLCHECK_ARCHIVE}" \
    --output "$WORK_DIR/$SHELLCHECK_ARCHIVE"
printf '%s  %s\n' "$SHELLCHECK_SHA" "$WORK_DIR/$SHELLCHECK_ARCHIVE" | shasum -a 256 -c -
tar -xJf "$WORK_DIR/$SHELLCHECK_ARCHIVE" -C "$WORK_DIR"
install -m 755 "$WORK_DIR/shellcheck-v${SHELLCHECK_VERSION}/shellcheck" "$DESTINATION/shellcheck"

curl --fail --location --silent --show-error \
    "https://github.com/rhysd/actionlint/releases/download/v${ACTIONLINT_VERSION}/${ACTIONLINT_ARCHIVE}" \
    --output "$WORK_DIR/$ACTIONLINT_ARCHIVE"
printf '%s  %s\n' "$ACTIONLINT_SHA" "$WORK_DIR/$ACTIONLINT_ARCHIVE" | shasum -a 256 -c -
tar -xzf "$WORK_DIR/$ACTIONLINT_ARCHIVE" -C "$WORK_DIR" actionlint
install -m 755 "$WORK_DIR/actionlint" "$DESTINATION/actionlint"
