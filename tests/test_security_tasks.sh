#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/lib/core.sh"
source "$ROOT_DIR/lib/logging.sh"
source "$ROOT_DIR/lib/files.sh"
source "$ROOT_DIR/tasks/30-security/ssh_hardening.sh"
source "$ROOT_DIR/tasks/30-security/fail2ban.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
LOG_FILE="$TMP/test.log"
BACKUP_DIR="$TMP/backups"
PROVISION_MODE="apply"

SSHD_OPTION_CALLS=0
ensure_sshd_option() { SSHD_OPTION_CALLS=$((SSHD_OPTION_CALLS + 1)); ENSURE_LAST_STATUS="ok"; }

DEFAULT_USER="no-such-user-$$"
SSH_PASSWORD_AUTH="no"
if run_ssh_hardening; then
  echo "ssh guard: expected failure"; exit 1
fi
[[ "$SSHD_OPTION_CALLS" == "0" ]]

SSH_DROPIN_DIR="$TMP/sshd_config.d"
mkdir -p "$SSH_DROPIN_DIR"
printf '%s\n' 'PermitRootLogin prohibit-password' 'PasswordAuthentication no' 'KbdInteractiveAuthentication no' > "$SSH_DROPIN_DIR/00-hardening.conf"
printf '%s\n' '# client rules' 'PasswordAuthentication no' 'AllowUsers forge deploy' > "$SSH_DROPIN_DIR/99-provision.conf"
remove_legacy_ssh_dropins
[[ ! -e "$SSH_DROPIN_DIR/00-hardening.conf" ]]
[[ -e "$SSH_DROPIN_DIR/99-provision.conf" ]]
[[ "$SSH_LEGACY_REMOVED" == "true" ]]

ensure_package() { ENSURE_LAST_STATUS="ok"; }
ensure_directory() { ENSURE_LAST_STATUS="ok"; }
ensure_service_enabled() { ENSURE_LAST_STATUS="ok"; }
ensure_service_running() { ENSURE_LAST_STATUS="ok"; }
ensure_block_in_file() { ENSURE_LAST_STATUS="changed"; }
fail2ban-client() { return 1; }
failed_before="$SUMMARY_FAILED"
if run_fail2ban; then
  echo "fail2ban: expected failure when reload fails"; exit 1
fi
[[ "$SUMMARY_FAILED" -gt "$failed_before" ]]

echo "test_security_tasks.sh passed"
