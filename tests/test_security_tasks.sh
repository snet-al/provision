#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/lib/core.sh"
source "$ROOT_DIR/lib/logging.sh"
source "$ROOT_DIR/lib/files.sh"
source "$ROOT_DIR/lib/ensure.sh"
source "$ROOT_DIR/tasks/10-system/unattended_upgrades.sh"
source "$ROOT_DIR/tasks/30-security/ssh_hardening.sh"
source "$ROOT_DIR/tasks/30-security/fail2ban.sh"
source "$ROOT_DIR/tasks/40-container/docker.sh"
source "$ROOT_DIR/tasks/40-container/portainer.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
LOG_FILE="$TMP/test.log"
BACKUP_DIR="$TMP/backups"
PROVISION_MODE="apply"
SSH_DROPIN_DIR="$TMP/sshd_config.d"
mkdir -p "$SSH_DROPIN_DIR"

expect_fail() {
  if "$@"; then
    echo "expected failure: $*"
    exit 1
  fi
}

# invalid sshd value is rolled back
printf 'PermitRootLogin no\n' > "$SSH_DROPIN_DIR/00-provision.conf"
sshd() { [[ "$1" == "-t" ]] && return 1; return 0; }
expect_fail ensure_sshd_option "KbdInteractiveAuthentication" "false"
[[ "$ENSURE_LAST_STATUS" == "failed" ]]
[[ "$(cat "$SSH_DROPIN_DIR/00-provision.conf")" == "PermitRootLogin no" ]]
rm -f "$SSH_DROPIN_DIR/00-provision.conf"

# legacy drop-ins: provision-only file removed, file with other rules kept
printf '%s\n' 'PermitRootLogin prohibit-password' 'PasswordAuthentication no' 'KbdInteractiveAuthentication no' > "$SSH_DROPIN_DIR/00-hardening.conf"
printf '%s\n' '# client rules' 'PasswordAuthentication no' 'AllowUsers forge deploy' 'AuthenticationMethods publickey,password' > "$SSH_DROPIN_DIR/99-provision.conf"
remove_legacy_ssh_dropins
[[ ! -e "$SSH_DROPIN_DIR/00-hardening.conf" ]]
[[ -e "$SSH_DROPIN_DIR/99-provision.conf" ]]
rm -f "$SSH_DROPIN_DIR/99-provision.conf"

SSHD_OPTIONS=()
ensure_sshd_option() { SSHD_OPTIONS+=("$1 $2"); ENSURE_LAST_STATUS="changed"; }
ensure_service_restarted_if_changed() { ENSURE_LAST_STATUS="changed"; }
SSHD_EFFECTIVE=$'permitrootlogin no\npasswordauthentication yes\nx11forwarding no\nmaxauthtries 3\nkbdinteractiveauthentication no'
SSHD_EFFECTIVE_FORGE=""
SSHD_EFFECTIVE_ROOT=""
sshd() {
  case "$*" in
    -t) return 0 ;;
    "-T -C user=forge,"*) printf '%s\n' "${SSHD_EFFECTIVE_FORGE:-$SSHD_EFFECTIVE}" ;;
    "-T -C user=root,"*) printf '%s\n' "${SSHD_EFFECTIVE_ROOT:-$SSHD_EFFECTIVE}" ;;
    -T) printf '%s\n' "$SSHD_EFFECTIVE" ;;
  esac
}
DEFAULT_USER="forge"
SSH_PASSWORD_AUTH="yes"
SSH_ROOT_AUTHORIZED_KEYS="$TMP/root_keys"
: > "$SSH_ROOT_AUTHORIZED_KEYS"

# missing forge keys: nothing is touched
DEFAULT_USER="no-such-user-$$"
SSH_PASSWORD_AUTH="no"
expect_fail run_ssh_hardening
[[ "${#SSHD_OPTIONS[@]}" == "0" ]]
DEFAULT_USER="forge"
SSH_PASSWORD_AUTH="yes"

# invalid value: nothing is touched
SSH_X11_FORWARDING="maybe"
expect_fail run_ssh_hardening
[[ "${#SSHD_OPTIONS[@]}" == "0" ]]
unset SSH_X11_FORWARDING

# YAML false/true are normalized to no/yes
SSH_KBD_INTERACTIVE_AUTH="false"
SSH_X11_FORWARDING="False"
run_ssh_hardening
printf '%s\n' "${SSHD_OPTIONS[@]}" | grep -Fx "KbdInteractiveAuthentication no" >/dev/null
printf '%s\n' "${SSHD_OPTIONS[@]}" | grep -Fx "X11Forwarding no" >/dev/null
unset SSH_KBD_INTERACTIVE_AUTH SSH_X11_FORWARDING

# a Match block that re-enables passwords for forge is caught
SSHD_EFFECTIVE_FORGE=$'permitrootlogin no\npasswordauthentication no\nx11forwarding no\nmaxauthtries 3\nkbdinteractiveauthentication yes'
SSH_PASSWORD_AUTH="yes"
expect_fail run_ssh_hardening
grep -F "effective KbdInteractiveAuthentication for user=forge is yes, want no" "$LOG_FILE" >/dev/null
SSHD_EFFECTIVE_FORGE=""

# root keys in use (e.g. Forge) and PermitRootLogin no: nothing is touched
printf 'ssh-rsa AAAA worker@forge.laravel.com\n' > "$SSH_ROOT_AUTHORIZED_KEYS"
SSHD_EFFECTIVE_ROOT=$'permitrootlogin yes'
SSHD_OPTIONS=()
expect_fail run_ssh_hardening
[[ "${#SSHD_OPTIONS[@]}" == "0" ]]
SSH_PERMIT_ROOT_LOGIN="prohibit-password"
SSHD_EFFECTIVE=$'permitrootlogin without-password\npasswordauthentication yes\nx11forwarding no\nmaxauthtries 3\nkbdinteractiveauthentication no'
SSHD_EFFECTIVE_ROOT=""
run_ssh_hardening
[[ "${#SSHD_OPTIONS[@]}" -gt "0" ]]
unset SSH_PERMIT_ROOT_LOGIN

# Origins-Pattern check follows unattended-upgrade's parser
good=$'Unattended-Upgrade::Origins-Pattern:: "origin=Ubuntu,archive=noble-security";\nUnattended-Upgrade::Origins-Pattern:: "o=Ubuntu,a=noble-updates";'
[[ -z "$(invalid_unattended_patterns <<<"$good")" ]]
for bad in 'origin=Ubuntu,archive=noble-security,broken' '\n' 'origin=Ubuntu=x' 'foo=bar'; do
  [[ -n "$(invalid_unattended_patterns <<<"Unattended-Upgrade::Origins-Pattern:: \"$bad\";")" ]]
done

# fail2ban: a failed reload is retried on the next run even though the file is unchanged
ensure_package() { ENSURE_LAST_STATUS="ok"; }
ensure_directory() { ENSURE_LAST_STATUS="ok"; }
ensure_service_enabled() { ENSURE_LAST_STATUS="ok"; }
ensure_service_running() { ENSURE_LAST_STATUS="ok"; }
ensure_block_in_file() { ENSURE_LAST_STATUS="ok"; }
F2B_MAXRETRY=5
F2B_RELOAD_OK=0
F2B_RELOADS=0
fail2ban-client() {
  case "$1 ${3:-}" in
    "get maxretry") echo "$F2B_MAXRETRY" ;;
    "get bantime") echo 3600 ;;
    "get findtime") echo 600 ;;
    "reload "*)
      F2B_RELOADS=$((F2B_RELOADS + 1))
      [[ "$F2B_RELOAD_OK" == "1" ]] || return 1
      F2B_MAXRETRY=3
      ;;
  esac
}
expect_fail run_fail2ban
F2B_RELOAD_OK=1
run_fail2ban
[[ "$F2B_RELOADS" == "2" ]]
run_fail2ban
[[ "$F2B_RELOADS" == "2" ]]

# portainer: failed rm or run is reported, the old container is not reported as recreated
DOCKER_RM_OK=0
DOCKER_RUN_OK=1
DOCKER_RUN_CALLS=0
docker() {
  case "$1" in
    version) echo 29.4.1 ;;
    volume) echo portainer_data ;;
    ps) echo portainer ;;
    inspect)
      case "$3" in
        '{{.Config.Image}}') echo portainer/portainer-ce:latest ;;
        '{{.Image}}') echo sha256:abc ;;
        '{{.HostConfig.RestartPolicy.Name}}') echo unless-stopped ;;
        '{{.State.Running}}') echo true ;;
        '{{json .HostConfig.PortBindings}}') echo '{"9000/tcp":[{"HostIp":"","HostPort":"9000"}],"9443/tcp":[{"HostIp":"","HostPort":"9443"}]}' ;;
        '{{json .Mounts}}') echo '[{"Source":"/var/run/docker.sock"},{"Name":"portainer_data"}]' ;;
      esac
      ;;
    rm) [[ "$DOCKER_RM_OK" == "1" ]] ;;
    run) DOCKER_RUN_CALLS=$((DOCKER_RUN_CALLS + 1)); [[ "$DOCKER_RUN_OK" == "1" ]] ;;
  esac
}
expect_fail run_portainer
[[ "$DOCKER_RUN_CALLS" == "0" ]]
DOCKER_RM_OK=1
DOCKER_RUN_OK=0
expect_fail run_portainer
[[ "$DOCKER_RUN_CALLS" == "1" ]]
! grep -F "recreated portainer" "$LOG_FILE" >/dev/null || { echo "portainer reported as recreated"; exit 1; }

echo "test_security_tasks.sh passed"
