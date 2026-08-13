#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/shell-helpers.sh
source "$SCRIPT_DIR/shell-helpers.sh"

[[ $# -eq 2 && "$1" == "--app" ]] || {
    echo "Usage: scripts/leak-guard.sh --app PATH/TO/ICloudGuard.app" >&2
    exit 64
}

APP="$(cd "$(dirname "$2")" && pwd -P)/$(basename "$2")"
BINARY="$APP/Contents/MacOS/ICloudGuard"
[[ -x "$BINARY" && ! -L "$BINARY" ]] || { echo "ERROR: App executable not found: $BINARY" >&2; exit 1; }
[[ "$(uname)" == "Darwin" ]] || { echo "ERROR: Runtime leak checks require macOS." >&2; exit 1; }
BINARY="$(cd "$(dirname "$BINARY")" && pwd -P)/$(basename "$BINARY")"

TEST_PARENT="${TMPDIR:-/private/tmp}"
TEST_PARENT="${TEST_PARENT%/}"
[[ -d "$TEST_PARENT" && ! -L "$TEST_PARENT" ]] || { echo "ERROR: Temporary parent is unsafe." >&2; exit 1; }
TEST_ROOT="$(mktemp -d "$TEST_PARENT/icloud-guard-leak.XXXXXX")"
APP_PID=""

pid_binary() {
    local pid="$1"
    local value
    value="$(/bin/ps -ww -o comm= -p "$pid" 2>/dev/null | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    [[ "$value" == /* ]] || return 1
    printf '%s/%s\n' "$(cd "$(dirname "$value")" && pwd -P)" "$(basename "$value")"
}

pid_is_app() {
    [[ -n "$APP_PID" ]] || return 1
    kill -0 "$APP_PID" 2>/dev/null || return 1
    [[ "$(pid_binary "$APP_PID")" == "$BINARY" ]]
}

require_app_pid() {
    pid_is_app || { echo "ERROR: PID $APP_PID no longer belongs to $BINARY." >&2; return 1; }
}

stop_app() {
    [[ -n "$APP_PID" ]] || return 0
    kill -0 "$APP_PID" 2>/dev/null || { wait "$APP_PID" 2>/dev/null || true; return 0; }
    require_app_pid || return 1
    kill -TERM "$APP_PID"
    for _ in {1..50}; do
        kill -0 "$APP_PID" 2>/dev/null || { wait "$APP_PID" 2>/dev/null || true; return 0; }
        require_app_pid || return 1
        sleep 0.1
    done
    require_app_pid || return 1
    kill -KILL "$APP_PID"
    for _ in {1..50}; do
        kill -0 "$APP_PID" 2>/dev/null || { wait "$APP_PID" 2>/dev/null || true; return 0; }
        sleep 0.1
    done
    echo "ERROR: App PID $APP_PID survived bounded TERM and KILL waits." >&2
    return 1
}

cleanup() {
    stop_app || true
    safe_remove_tree "$TEST_ROOT" "$TEST_PARENT"
}
trap cleanup EXIT INT TERM
mkdir -p "$TEST_ROOT/state" "$TEST_ROOT/scope"
cat > "$TEST_ROOT/state/config.toml" <<EOF
[suppression]
spotlight = false
quicklook = false
materialize_dataless = true

[scope]
path = "$TEST_ROOT/scope"
EOF

ICLOUD_GUARD_HOME="$TEST_ROOT/state" \
ICLOUD_GUARD_DISABLE_SYSTEM_INTEGRATIONS=1 \
"$BINARY" &
APP_PID=$!
sleep 8
require_app_pid
RSS_START="$(/bin/ps -o rss= -p "$APP_PID" | tr -d ' ')"
sleep 15
require_app_pid
RSS_END="$(/bin/ps -o rss= -p "$APP_PID" | tr -d ' ')"
[[ "$RSS_START" =~ ^[0-9]+$ && "$RSS_END" =~ ^[0-9]+$ ]] || { echo "ERROR: RSS sampling failed." >&2; exit 1; }
GROWTH=$((RSS_END - RSS_START))
[[ "$GROWTH" -le 51200 ]] || { echo "ERROR: RSS grew ${GROWTH} KiB in 15 seconds." >&2; exit 1; }

if [[ -x /usr/bin/leaks ]]; then
    require_app_pid
    /usr/bin/leaks "$APP_PID"
fi
stop_app
APP_PID=""
echo "Leak guard passed: RSS growth ${GROWTH} KiB."
