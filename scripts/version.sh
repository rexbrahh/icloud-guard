#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
SOURCE="$ROOT_DIR/Sources/ICloudGuardCore/ProductInfo.swift"

VERSION="$(sed -nE 's/^[[:space:]]*public static let version = "([0-9]+\.[0-9]+\.[0-9]+)"[[:space:]]*$/\1/p' "$SOURCE")"
if [[ -z "$VERSION" || "$(printf '%s\n' "$VERSION" | wc -l | tr -d ' ')" != 1 ]]; then
    echo "ERROR: $SOURCE must contain one semantic product version." >&2
    exit 1
fi

printf '%s\n' "$VERSION"
