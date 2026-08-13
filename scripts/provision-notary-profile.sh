#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/shell-helpers.sh
source "$SCRIPT_DIR/shell-helpers.sh"

usage() {
    cat <<'EOF'
Usage:
  scripts/provision-notary-profile.sh create --state-dir DIR --profile NAME --env-file FILE
  scripts/provision-notary-profile.sh cleanup --state-dir DIR

The create command reads APP_STORE_CONNECT_KEY_ID,
APP_STORE_CONNECT_ISSUER_ID, and APP_STORE_CONNECT_PRIVATE_KEY_P8 from the
environment. The private key may be raw PEM or base64-encoded PEM.
This helper supports Team API keys, for which the issuer UUID is required. It
does not support Individual API keys.
EOF
}

[[ $# -ge 1 ]] || { usage >&2; exit 64; }
COMMAND="$1"
shift
STATE_DIR=""
PROFILE=""
ENV_FILE=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --state-dir|--profile|--env-file)
            [[ $# -ge 2 ]] || { echo "ERROR: $1 requires a value." >&2; exit 64; }
            case "$1" in
                --state-dir) STATE_DIR="$2" ;;
                --profile) PROFILE="$2" ;;
                --env-file) ENV_FILE="$2" ;;
            esac
            shift 2
            ;;
        *) echo "ERROR: Unknown argument: $1" >&2; usage >&2; exit 64 ;;
    esac
done

[[ "$STATE_DIR" == /* ]] || { echo "ERROR: --state-dir must be absolute." >&2; exit 64; }
STATE_PARENT="$(dirname "$STATE_DIR")"
[[ "$(basename "$STATE_DIR")" == icloud-guard-notary-* ]] || {
    echo "ERROR: Notary state directory must use the icloud-guard-notary- prefix." >&2
    exit 64
}
[[ -d "$STATE_PARENT" && ! -L "$STATE_PARENT" ]] || { echo "ERROR: Notary state parent is unsafe." >&2; exit 1; }
[[ ! -L "$STATE_DIR" ]] || { echo "ERROR: Notary state must not be a symlink." >&2; exit 1; }

KEYCHAIN_PATH="$STATE_DIR/notary.keychain-db"
KEY_PATH="$STATE_DIR/AuthKey.p8"
remove_private_key() {
    [[ -e "$KEY_PATH" || -L "$KEY_PATH" ]] || return 0
    [[ -d "$STATE_DIR" && ! -L "$STATE_DIR" ]] || {
        echo "ERROR: Notary private-key parent is unsafe." >&2
        return 1
    }
    local canonical_state key_parent
    canonical_state="$(cd "$STATE_DIR" && pwd -P)"
    key_parent="$(cd "$(dirname "$KEY_PATH")" && pwd -P)"
    [[ "$key_parent" == "$canonical_state" && "$(basename "$KEY_PATH")" == "AuthKey.p8" ]] || {
        echo "ERROR: Notary private-key path is outside its state directory." >&2
        return 1
    }
    [[ -f "$KEY_PATH" && ! -L "$KEY_PATH" ]] || {
        echo "ERROR: Notary private-key path is not a regular file." >&2
        return 1
    }
    /bin/rm -f -- "$KEY_PATH"
}

cleanup_state() {
    local had_errexit=false
    local key_status=0
    local keychain_status=0
    local tree_status=0
    [[ $- == *e* ]] && had_errexit=true
    set +e
    remove_private_key
    key_status=$?
    if [[ -f "$KEYCHAIN_PATH" && ! -L "$KEYCHAIN_PATH" ]]; then
        security delete-keychain "$KEYCHAIN_PATH"
        keychain_status=$?
    fi
    safe_remove_tree "$STATE_DIR" "$STATE_PARENT"
    tree_status=$?
    if [[ "$had_errexit" == true ]]; then set -e; fi

    if (( key_status != 0 || keychain_status != 0 || tree_status != 0 )); then
        echo "ERROR: Notary credential cleanup did not complete." >&2
        if (( key_status != 0 )); then return "$key_status"; fi
        if (( keychain_status != 0 )); then return "$keychain_status"; fi
        return "$tree_status"
    fi
}

rollback_provisioning() {
    local provisioning_status=$?
    trap - EXIT INT TERM
    if ! cleanup_state; then
        echo "ERROR: Provisioning failed; credential cleanup also reported an error." >&2
    fi
    exit "$provisioning_status"
}

case "$COMMAND" in
    cleanup)
        [[ -z "$PROFILE" && -z "$ENV_FILE" ]] || { echo "ERROR: cleanup accepts only --state-dir." >&2; exit 64; }
        [[ -e "$STATE_DIR" ]] || exit 0
        [[ -d "$STATE_DIR" ]] || { echo "ERROR: Notary state is not a directory." >&2; exit 1; }
        cleanup_state
        ;;
    create)
        [[ "$PROFILE" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "ERROR: --profile contains unsafe characters." >&2; exit 64; }
        [[ "$ENV_FILE" == /* && ! -L "$ENV_FILE" ]] || { echo "ERROR: --env-file must be an absolute non-symlink path." >&2; exit 64; }
        [[ -d "$(dirname "$ENV_FILE")" ]] || { echo "ERROR: Environment file parent does not exist." >&2; exit 1; }
        [[ ! -e "$STATE_DIR" ]] || { echo "ERROR: Notary state already exists." >&2; exit 1; }

        : "${APP_STORE_CONNECT_KEY_ID:?ERROR: APP_STORE_CONNECT_KEY_ID is required.}"
        : "${APP_STORE_CONNECT_ISSUER_ID:?ERROR: APP_STORE_CONNECT_ISSUER_ID is required.}"
        : "${APP_STORE_CONNECT_PRIVATE_KEY_P8:?ERROR: APP_STORE_CONNECT_PRIVATE_KEY_P8 is required.}"
        [[ "$APP_STORE_CONNECT_KEY_ID" =~ ^[A-Za-z0-9]+$ ]] || { echo "ERROR: App Store Connect key ID is invalid." >&2; exit 64; }
        [[ "$APP_STORE_CONNECT_ISSUER_ID" =~ ^[A-Fa-f0-9]{8}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{12}$ ]] || {
            echo "ERROR: App Store Connect issuer ID must be a UUID." >&2
            exit 64
        }

        umask 077
        mkdir "$STATE_DIR"
        trap rollback_provisioning EXIT
        trap 'exit 130' INT
        trap 'exit 143' TERM
        if [[ "$APP_STORE_CONNECT_PRIVATE_KEY_P8" == *"-----BEGIN PRIVATE KEY-----"* ]]; then
            printf '%s\n' "$APP_STORE_CONNECT_PRIVATE_KEY_P8" > "$KEY_PATH"
        else
            printf '%s' "$APP_STORE_CONNECT_PRIVATE_KEY_P8" | /usr/bin/base64 --decode > "$KEY_PATH"
        fi
        chmod 600 "$KEY_PATH"
        grep -q '^-----BEGIN PRIVATE KEY-----$' "$KEY_PATH" || { echo "ERROR: App Store Connect private key is not PEM." >&2; exit 1; }
        grep -q '^-----END PRIVATE KEY-----$' "$KEY_PATH" || { echo "ERROR: App Store Connect private key is incomplete." >&2; exit 1; }

        KEYCHAIN_PASSWORD="$(openssl rand -hex 32)"
        if [[ "${GITHUB_ACTIONS:-}" == "true" ]]; then
            printf '::add-mask::%s\n' "$KEYCHAIN_PASSWORD"
        fi
        security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"
        security set-keychain-settings -lut 21600 "$KEYCHAIN_PATH"
        security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"
        xcrun notarytool store-credentials "$PROFILE" \
            --key "$KEY_PATH" \
            --key-id "$APP_STORE_CONNECT_KEY_ID" \
            --issuer "$APP_STORE_CONNECT_ISSUER_ID" \
            --keychain "$KEYCHAIN_PATH" \
            --validate
        /bin/rm -f "$KEY_PATH"

        printf 'NOTARY_KEYCHAIN_PROFILE=%s\nNOTARY_KEYCHAIN=%s\n' "$PROFILE" "$KEYCHAIN_PATH" >> "$ENV_FILE"
        trap - EXIT INT TERM
        ;;
    *) echo "ERROR: Command must be create or cleanup." >&2; usage >&2; exit 64 ;;
esac
