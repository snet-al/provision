#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/lib/core.sh"
source "$ROOT_DIR/lib/logging.sh"
source "$ROOT_DIR/lib/files.sh"
source "$ROOT_DIR/lib/services.sh"
source "$ROOT_DIR/lib/ensure.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

LOG_FILE="$TMP/test.log"
PROVISION_MODE="apply"

f="$TMP/test.txt"
ensure_line_in_file "$f" "hello"
first="$ENSURE_LAST_STATUS"
ensure_line_in_file "$f" "hello"
second="$ENSURE_LAST_STATUS"

[[ "$first" == "changed" ]]
[[ "$second" == "ok" ]]

echo "test_ensure.sh passed"
