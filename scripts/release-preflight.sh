#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

bash -n "$SCRIPT_DIR"/*.sh
shellcheck "$SCRIPT_DIR"/*.sh
(
    cd "$ROOT_DIR"
    actionlint
)
"$SCRIPT_DIR/test-notary-profile.sh"
