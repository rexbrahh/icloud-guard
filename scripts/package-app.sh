#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/shell-helpers.sh
source "$SCRIPT_DIR/shell-helpers.sh"

[[ $# -eq 5 ]] || {
    echo "Usage: scripts/package-app.sh CHANNEL APP ARCHIVE SOURCE_EPOCH WORK_DIR" >&2
    exit 64
}

CHANNEL="$1"
APP="$2"
ARCHIVE="$3"
SOURCE_EPOCH="$4"
WORK_DIR="$5"
[[ "$CHANNEL" == "stable" || "$CHANNEL" == "beta" || "$CHANNEL" == "tip" ]] || {
    echo "ERROR: Packaging channel must be stable, beta, or tip." >&2
    exit 64
}
[[ -d "$APP" && ! -L "$APP" && "$(basename "$APP")" == "ICloudGuard.app" ]] || {
    echo "ERROR: Packaging input must be a real ICloudGuard.app directory." >&2
    exit 1
}
[[ "$SOURCE_EPOCH" =~ ^[0-9]+$ ]] || { echo "ERROR: Source epoch must be an integer." >&2; exit 64; }
[[ "$WORK_DIR" == /* && -d "$WORK_DIR" && ! -L "$WORK_DIR" ]] || {
    echo "ERROR: Packaging work directory must be an absolute real directory." >&2
    exit 1
}
[[ ! -e "$ARCHIVE" ]] || { echo "ERROR: Archive already exists: $ARCHIVE" >&2; exit 1; }

if [[ "$CHANNEL" == "tip" ]]; then
    PACKAGE_ROOT="$WORK_DIR/package"
    [[ ! -e "$PACKAGE_ROOT" ]] || { echo "ERROR: Packaging stage already exists: $PACKAGE_ROOT" >&2; exit 1; }
    mkdir -p "$PACKAGE_ROOT"
    cp -R "$APP" "$PACKAGE_ROOT/ICloudGuard.app"
    STAMP="$(/bin/date -u -r "$SOURCE_EPOCH" +%Y%m%d%H%M.%S)"
    while IFS= read -r path; do /usr/bin/touch -h -t "$STAMP" "$path"; done < <(/usr/bin/find -s "$PACKAGE_ROOT/ICloudGuard.app" -print)
    (
        cd "$PACKAGE_ROOT"
        /usr/bin/find -s ICloudGuard.app -print | /usr/bin/zip -X -q "$ARCHIVE" -@
    )
    safe_remove_tree "$PACKAGE_ROOT" "$WORK_DIR"
else
    # Apple recommends ditto for the distributable archive of a notarized app.
    /usr/bin/ditto -c -k --keepParent "$APP" "$ARCHIVE"
fi

[[ -s "$ARCHIVE" ]] || { echo "ERROR: Release archive was not created." >&2; exit 1; }
