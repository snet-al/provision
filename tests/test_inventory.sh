#!/bin/bash
set -euo pipefail

if ! command -v jq >/dev/null 2>&1; then
  echo "test_inventory.sh skipped (jq not installed)"
  exit 0
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/lib/core.sh"
source "$ROOT_DIR/lib/logging.sh"
source "$ROOT_DIR/lib/inventory.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
LOG_FILE="$TMP/test.log"

inv="$TMP/inventory.json"
cat > "$inv" <<JSON
{
  "groups": {"docker_hosts": ["docker-01"]},
  "hosts": {"docker-01": {"host": "10.0.0.11", "user": "root", "profile": "docker_host"}}
}
JSON

rows="$(inventory_select_hosts "$inv" "docker_hosts")"
[[ "$rows" == "docker-01 10.0.0.11 root docker_host" ]]

echo "test_inventory.sh passed"
