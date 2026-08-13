#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/shell-helpers.sh
source "$SCRIPT_DIR/shell-helpers.sh"
TEST_PARENT="${TMPDIR:-/private/tmp}"
TEST_PARENT="${TEST_PARENT%/}"
TEST_ROOT="$(mktemp -d "$TEST_PARENT/icloud-guard-notary-test.XXXXXX")"
BLOCKED_PATH=""
cleanup() {
    if [[ -n "$BLOCKED_PATH" && -d "$BLOCKED_PATH" ]]; then chmod 700 "$BLOCKED_PATH"; fi
    safe_remove_tree "$TEST_ROOT" "$TEST_PARENT"
}
trap cleanup EXIT
mkdir "$TEST_ROOT/bin"

cat > "$TEST_ROOT/bin/security" <<'EOF'
#!/bin/bash
set -euo pipefail
case "$1" in
    create-keychain)
        printf 'create-keychain %s\n' "${!#}" >> "$MOCK_LOG"
        : > "${!#}"
        ;;
    set-keychain-settings) printf 'set-keychain-settings %s\n' "${!#}" >> "$MOCK_LOG" ;;
    unlock-keychain) printf 'unlock-keychain %s\n' "${!#}" >> "$MOCK_LOG" ;;
    delete-keychain)
        printf 'delete-keychain %s\n' "$2" >> "$MOCK_LOG"
        if [[ "${MOCK_DELETE_FAIL:-false}" == true ]]; then exit 55; fi
        rm -f "$2"
        ;;
    *) exit 70 ;;
esac
EOF
cat > "$TEST_ROOT/bin/xcrun" <<'EOF'
#!/bin/bash
set -euo pipefail
[[ "$1" == notarytool && "$2" == store-credentials ]]
printf '%s\n' "$*" >> "$MOCK_LOG"
key_path=""
while [[ $# -gt 0 ]]; do
    if [[ "$1" == --key ]]; then key_path="$2"; break; fi
    shift
done
[[ -n "$key_path" && "$(/usr/bin/stat -f %Lp "$key_path")" == 600 ]]
if [[ "${MOCK_TREE_FAILURE_BEFORE_TRAVERSAL:-false}" == true ]]; then
    state_path="$(dirname "$key_path")"
    mkdir "$state_path/blocked"
    : > "$state_path/blocked/entry"
    chmod 000 "$state_path/blocked"
    printf 'left-private-key-intact %s\n' "$key_path" >> "$MOCK_LOG"
    exit 42
fi
if [[ "${MOCK_STORE_FAIL:-false}" == true ]]; then exit 42; fi
EOF
chmod 755 "$TEST_ROOT/bin/security" "$TEST_ROOT/bin/xcrun"

PEM=$'-----BEGIN PRIVATE KEY-----\nmock-private-key\n-----END PRIVATE KEY-----'
ISSUER_ID=01234567-89ab-cdef-0123-456789abcdef
run_case() {
    local label="$1"
    local private_key="$2"
    local state="$TEST_ROOT/icloud-guard-notary-$label"
    local env_file="$TEST_ROOT/$label.env"
    local log="$TEST_ROOT/$label.log"
    : > "$env_file"
    : > "$log"
    PATH="$TEST_ROOT/bin:$PATH" \
    MOCK_LOG="$log" \
    APP_STORE_CONNECT_KEY_ID=ABC123DEF4 \
    APP_STORE_CONNECT_ISSUER_ID="$ISSUER_ID" \
    APP_STORE_CONNECT_PRIVATE_KEY_P8="$private_key" \
        "$SCRIPT_DIR/provision-notary-profile.sh" create \
            --state-dir "$state" \
            --profile "icloud-guard-$label" \
            --env-file "$env_file"

    [[ ! -e "$state/AuthKey.p8" ]]
    grep -Fqx "NOTARY_KEYCHAIN_PROFILE=icloud-guard-$label" "$env_file"
    grep -Fqx "NOTARY_KEYCHAIN=$state/notary.keychain-db" "$env_file"
    grep -Fqx "notarytool store-credentials icloud-guard-$label --key $state/AuthKey.p8 --key-id ABC123DEF4 --issuer $ISSUER_ID --keychain $state/notary.keychain-db --validate" "$log"
    if grep -Fq 'mock-private-key' "$log"; then
        echo "ERROR: Private key contents reached a command log." >&2
        exit 1
    fi

    PATH="$TEST_ROOT/bin:$PATH" MOCK_LOG="$log" \
        "$SCRIPT_DIR/provision-notary-profile.sh" cleanup --state-dir "$state"
    [[ ! -e "$state" ]]
    grep -Fqx "delete-keychain $state/notary.keychain-db" "$log"
}

run_case raw "$PEM"
run_case base64 "$(printf '%s\n' "$PEM" | /usr/bin/base64)"

run_store_failure() {
    local label="$1"
    local delete_fails="$2"
    local state="$TEST_ROOT/icloud-guard-notary-$label"
    local log="$TEST_ROOT/$label.log"
    local output="$TEST_ROOT/$label.output"
    : > "$log"
    : > "$TEST_ROOT/$label.env"
    set +e
    PATH="$TEST_ROOT/bin:$PATH" \
    MOCK_LOG="$log" \
    MOCK_STORE_FAIL=true \
    MOCK_DELETE_FAIL="$delete_fails" \
    APP_STORE_CONNECT_KEY_ID=ABC123DEF4 \
    APP_STORE_CONNECT_ISSUER_ID="$ISSUER_ID" \
    APP_STORE_CONNECT_PRIVATE_KEY_P8="$PEM" \
        "$SCRIPT_DIR/provision-notary-profile.sh" create \
            --state-dir "$state" \
            --profile "icloud-guard-$label" \
            --env-file "$TEST_ROOT/$label.env" > "$output" 2>&1
    local status=$?
    set -e
    [[ "$status" == 42 ]] || { echo "ERROR: Provisioning failure status was not preserved." >&2; exit 1; }
    [[ ! -e "$state/AuthKey.p8" && ! -e "$state" ]]
    grep -Fq 'notarytool store-credentials' "$log"
    grep -Fq 'delete-keychain' "$log"
    if grep -Fq 'mock-private-key' "$log" "$output"; then
        echo "ERROR: Failed provisioning logged private key contents." >&2
        exit 1
    fi
    if [[ "$delete_fails" == true ]]; then
        grep -Fq 'credential cleanup also reported an error' "$output"
    fi
}

run_store_failure store-fails-delete-succeeds false
run_store_failure store-fails-delete-fails true

COMBINED_STATE="$TEST_ROOT/icloud-guard-notary-store-and-tree-fail"
COMBINED_LOG="$TEST_ROOT/store-and-tree-fail.log"
COMBINED_OUTPUT="$TEST_ROOT/store-and-tree-fail.output"
BLOCKED_PATH="$COMBINED_STATE/blocked"
: > "$COMBINED_LOG"
: > "$TEST_ROOT/store-and-tree-fail.env"
set +e
PATH="$TEST_ROOT/bin:$PATH" \
MOCK_LOG="$COMBINED_LOG" \
MOCK_TREE_FAILURE_BEFORE_TRAVERSAL=true \
APP_STORE_CONNECT_KEY_ID=ABC123DEF4 \
APP_STORE_CONNECT_ISSUER_ID="$ISSUER_ID" \
APP_STORE_CONNECT_PRIVATE_KEY_P8="$PEM" \
    "$SCRIPT_DIR/provision-notary-profile.sh" create \
        --state-dir "$COMBINED_STATE" \
        --profile icloud-guard-store-and-tree-fail \
        --env-file "$TEST_ROOT/store-and-tree-fail.env" > "$COMBINED_OUTPUT" 2>&1
COMBINED_STATUS=$?
set -e
[[ "$COMBINED_STATUS" == 42 ]]
[[ ! -e "$COMBINED_STATE/AuthKey.p8" ]]
[[ -d "$COMBINED_STATE" && -d "$BLOCKED_PATH" ]]
grep -Fqx "left-private-key-intact $COMBINED_STATE/AuthKey.p8" "$COMBINED_LOG"
grep -Fq 'Provisioning failed; credential cleanup also reported an error' "$COMBINED_OUTPUT"
if grep -Fq 'mock-private-key' "$COMBINED_LOG" "$COMBINED_OUTPUT"; then
    echo "ERROR: Combined cleanup failure logged private key contents." >&2
    exit 1
fi
chmod 700 "$BLOCKED_PATH"
BLOCKED_PATH=""
PATH="$TEST_ROOT/bin:$PATH" MOCK_LOG="$COMBINED_LOG" \
    "$SCRIPT_DIR/provision-notary-profile.sh" cleanup --state-dir "$COMBINED_STATE"
[[ ! -e "$COMBINED_STATE" ]]

KEY_FAILURE_STATE="$TEST_ROOT/icloud-guard-notary-key-removal-fails"
KEY_FAILURE_LOG="$TEST_ROOT/key-removal-fails.log"
: > "$KEY_FAILURE_LOG"
: > "$TEST_ROOT/key-removal-fails.env"
PATH="$TEST_ROOT/bin:$PATH" \
MOCK_LOG="$KEY_FAILURE_LOG" \
APP_STORE_CONNECT_KEY_ID=ABC123DEF4 \
APP_STORE_CONNECT_ISSUER_ID="$ISSUER_ID" \
APP_STORE_CONNECT_PRIVATE_KEY_P8="$PEM" \
    "$SCRIPT_DIR/provision-notary-profile.sh" create \
        --state-dir "$KEY_FAILURE_STATE" \
        --profile icloud-guard-key-removal-fails \
        --env-file "$TEST_ROOT/key-removal-fails.env"
mkdir "$KEY_FAILURE_STATE/AuthKey.p8"
set +e
PATH="$TEST_ROOT/bin:$PATH" MOCK_LOG="$KEY_FAILURE_LOG" \
    "$SCRIPT_DIR/provision-notary-profile.sh" cleanup --state-dir "$KEY_FAILURE_STATE" \
    > "$TEST_ROOT/key-removal-fails.output" 2>&1
KEY_FAILURE_STATUS=$?
set -e
[[ "$KEY_FAILURE_STATUS" != 0 && ! -e "$KEY_FAILURE_STATE" ]]
grep -Fq 'Notary private-key path is not a regular file' "$TEST_ROOT/key-removal-fails.output"
grep -Fq 'Notary credential cleanup did not complete' "$TEST_ROOT/key-removal-fails.output"
grep -Fq "delete-keychain $KEY_FAILURE_STATE/notary.keychain-db" "$KEY_FAILURE_LOG"

EXPLICIT_STATE="$TEST_ROOT/icloud-guard-notary-explicit-delete-fails"
EXPLICIT_LOG="$TEST_ROOT/explicit-delete-fails.log"
: > "$EXPLICIT_LOG"
: > "$TEST_ROOT/explicit-delete-fails.env"
PATH="$TEST_ROOT/bin:$PATH" \
MOCK_LOG="$EXPLICIT_LOG" \
APP_STORE_CONNECT_KEY_ID=ABC123DEF4 \
APP_STORE_CONNECT_ISSUER_ID="$ISSUER_ID" \
APP_STORE_CONNECT_PRIVATE_KEY_P8="$PEM" \
    "$SCRIPT_DIR/provision-notary-profile.sh" create \
        --state-dir "$EXPLICIT_STATE" \
        --profile icloud-guard-explicit-delete-fails \
        --env-file "$TEST_ROOT/explicit-delete-fails.env"
set +e
PATH="$TEST_ROOT/bin:$PATH" MOCK_LOG="$EXPLICIT_LOG" MOCK_DELETE_FAIL=true \
    "$SCRIPT_DIR/provision-notary-profile.sh" cleanup --state-dir "$EXPLICIT_STATE" \
    > "$TEST_ROOT/explicit-delete-fails.output" 2>&1
EXPLICIT_STATUS=$?
set -e
[[ "$EXPLICIT_STATUS" == 55 && ! -e "$EXPLICIT_STATE" ]]
grep -Fq 'Notary credential cleanup did not complete' "$TEST_ROOT/explicit-delete-fails.output"

SAFE_STATE="$TEST_ROOT/icloud-guard-notary-safe-remove-fails"
SAFE_LOG="$TEST_ROOT/safe-remove-fails.log"
: > "$SAFE_LOG"
: > "$TEST_ROOT/safe-remove-fails.env"
PATH="$TEST_ROOT/bin:$PATH" \
MOCK_LOG="$SAFE_LOG" \
APP_STORE_CONNECT_KEY_ID=ABC123DEF4 \
APP_STORE_CONNECT_ISSUER_ID="$ISSUER_ID" \
APP_STORE_CONNECT_PRIVATE_KEY_P8="$PEM" \
    "$SCRIPT_DIR/provision-notary-profile.sh" create \
        --state-dir "$SAFE_STATE" \
        --profile icloud-guard-safe-remove-fails \
        --env-file "$TEST_ROOT/safe-remove-fails.env"
BLOCKED_PATH="$SAFE_STATE/blocked"
mkdir "$BLOCKED_PATH"
: > "$BLOCKED_PATH/entry"
chmod 000 "$BLOCKED_PATH"
set +e
PATH="$TEST_ROOT/bin:$PATH" MOCK_LOG="$SAFE_LOG" \
    "$SCRIPT_DIR/provision-notary-profile.sh" cleanup --state-dir "$SAFE_STATE" \
    > "$TEST_ROOT/safe-remove-fails.output" 2>&1
SAFE_STATUS=$?
set -e
[[ "$SAFE_STATUS" != 0 && ! -e "$SAFE_STATE/AuthKey.p8" && -d "$SAFE_STATE" ]]
grep -Fq 'Notary credential cleanup did not complete' "$TEST_ROOT/safe-remove-fails.output"
chmod 700 "$BLOCKED_PATH"
BLOCKED_PATH=""
PATH="$TEST_ROOT/bin:$PATH" MOCK_LOG="$SAFE_LOG" \
    "$SCRIPT_DIR/provision-notary-profile.sh" cleanup --state-dir "$SAFE_STATE"
[[ ! -e "$SAFE_STATE" ]]

MISSING_STATE="$TEST_ROOT/icloud-guard-notary-missing"
if env -u APP_STORE_CONNECT_ISSUER_ID \
    PATH="$TEST_ROOT/bin:$PATH" \
    MOCK_LOG="$TEST_ROOT/missing.log" \
    APP_STORE_CONNECT_KEY_ID=ABC123DEF4 \
    APP_STORE_CONNECT_PRIVATE_KEY_P8="$PEM" \
        "$SCRIPT_DIR/provision-notary-profile.sh" create \
            --state-dir "$MISSING_STATE" \
            --profile missing \
            --env-file "$TEST_ROOT/missing.env" > /dev/null 2>&1; then
    echo "ERROR: Missing issuer secret unexpectedly succeeded." >&2
    exit 1
fi
[[ ! -e "$MISSING_STATE" ]]

echo "Notary profile helper tests passed."
