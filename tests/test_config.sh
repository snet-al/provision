#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/lib/core.sh"
source "$ROOT_DIR/lib/logging.sh"
source "$ROOT_DIR/lib/config.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
LOG_FILE="$TMP/test.log"

if ! command -v yq >/dev/null 2>&1; then
  echo "test_config.sh skipped (yq not installed)"
  exit 0
fi

mkdir -p "$TMP/hosts"
cat > "$TMP/hosts/basic.yml" <<'YAML'
env:
  DEFAULT_USER: forge
  LOG_FILE: /tmp/provision.log
YAML
HOSTS_DIR="$TMP/hosts"
load_profile_config basic
[[ "$DEFAULT_USER" == "forge" ]]

cfg="$TMP/host.yml"
cat > "$cfg" <<'YAML'
server:
  hostname: x-host
profile: basic
users:
  - name: forge
    ssh_keys:
      - ssh-ed25519 AAAA
YAML

load_host_config "$cfg"
[[ "$PROVISION_HOSTNAME" == "x-host" ]]
[[ "$DEFAULT_USER" == "forge" ]]

echo "test_config.sh passed"
