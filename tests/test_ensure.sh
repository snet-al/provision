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

BACKUP_DIR="$TMP/backups"

b="$TMP/block.conf"
printf 'keep me\n' > "$b"
ensure_block_in_file "$b" "provision:test" "line one\nline two"
[[ "$ENSURE_LAST_STATUS" == "changed" ]]
[[ "$(cat "$b")" == $'keep me\n\n# provision:test\nline one\nline two\n# /provision:test' ]]
ensure_block_in_file "$b" "provision:test" "line one\nline two"
[[ "$ENSURE_LAST_STATUS" == "ok" ]]
ensure_block_in_file "$b" "provision:test" "line one\nline three"
[[ "$ENSURE_LAST_STATUS" == "changed" ]]
[[ "$(cat "$b")" == $'keep me\n\n# provision:test\nline one\nline three\n# /provision:test' ]]

legacy50="$TMP/50unattended-upgrades"
printf '%s\n' 'Unattended-Upgrade::Allowed-Origins {' '        "${distro_id}:${distro_codename}-security";' '};' '' '# provision:unattended-upgrades' \
  'Unattended-Upgrade::Origins-Pattern {\n        "origin=Ubuntu,archive=noble-security";\n};\nUnattended-Upgrade::Automatic-Reboot "false";' > "$legacy50"
ensure_block_absent "$legacy50" "provision:unattended-upgrades"
[[ "$ENSURE_LAST_STATUS" == "changed" ]]
[[ "$(grep -cF 'provision:' "$legacy50")" == "0" ]]
[[ "$(grep -cF 'Origins-Pattern' "$legacy50")" == "0" ]]
grep -F -- '-security";' "$legacy50" >/dev/null
ensure_block_absent "$legacy50" "provision:unattended-upgrades"
[[ "$ENSURE_LAST_STATUS" == "ok" ]]

legacy20="$TMP/20auto-upgrades"
printf '%s\n' 'APT::Periodic::Update-Package-Lists "1";' 'APT::Periodic::Unattended-Upgrade "1";' '' '# provision:auto-upgrades' \
  'APT::Periodic::Update-Package-Lists "1";\nAPT::Periodic::Unattended-Upgrade "1";' > "$legacy20"
ensure_block_in_file "$legacy20" "provision:auto-upgrades" 'APT::Periodic::Update-Package-Lists "1";\nAPT::Periodic::Unattended-Upgrade "1";'
[[ "$ENSURE_LAST_STATUS" == "changed" ]]
[[ "$(grep -cF '\n' "$legacy20")" == "0" ]]
[[ "$(grep -c '^# provision:auto-upgrades$' "$legacy20")" == "1" ]]

PROVISION_MODE="plan"
p="$TMP/plan.conf"
ensure_block_in_file "$p" "provision:test" "x"
[[ "$ENSURE_LAST_STATUS" == "changed" ]]
[[ ! -e "$p" ]]
PROVISION_MODE="apply"

echo "test_ensure.sh passed"
