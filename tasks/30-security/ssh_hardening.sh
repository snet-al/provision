#!/bin/bash

normalize_bool_to_ssh() {
  local v="${1:-}"
  case "${v,,}" in
    true|yes|1) echo "yes" ;;
    false|no|0) echo "no" ;;
    *) echo "$v" ;;
  esac
}

sshd_effective_value() {
  local key="$1"
  local value="$2"
  case "${key,,}:${value,,}" in
    permitrootlogin:prohibit-password) echo "without-password" ;;
    *) echo "${value,,}" ;;
  esac
}

remove_legacy_ssh_dropins() {
  local name path
  SSH_LEGACY_REMOVED=false
  for name in ${SSH_LEGACY_DROPINS:-99-provision.conf 00-hardening.conf}; do
    path="/etc/ssh/sshd_config.d/$name"
    [[ -f "$path" ]] || continue
    if is_plan_mode; then
      log_status "changed" "run_ssh_hardening" "plan: would remove legacy drop-in $path"
      continue
    fi
    backup_file_if_exists "$path"
    rm -f "$path"
    SSH_LEGACY_REMOVED=true
    log_status "changed" "run_ssh_hardening" "removed legacy drop-in $path"
  done
}

verify_sshd_effective() {
  local effective
  if ! effective="$(sshd -T 2>/dev/null)"; then
    log_status "failed" "run_ssh_hardening" "sshd -T failed; cannot verify effective config"
    return 1
  fi

  local mismatches=0 pair key want got
  for pair in "$@"; do
    key="${pair%%=*}"
    want="$(sshd_effective_value "$key" "${pair#*=}")"
    got="$(awk -v k="${key,,}" '$1 == k { print $2; exit }' <<<"$effective")"
    if [[ "$got" == "$want" ]]; then
      log_status "ok" "run_ssh_hardening" "effective $key is $got"
    elif is_plan_mode; then
      log_status "changed" "run_ssh_hardening" "plan: effective $key is $got, want $want"
    else
      log_status "failed" "run_ssh_hardening" "effective $key is $got, want $want (another file in /etc/ssh/sshd_config or sshd_config.d overrides it)"
      mismatches=$((mismatches + 1))
    fi
  done
  [[ "$mismatches" -eq 0 ]]
}

run_ssh_hardening() {
  log_info "Running task: ssh_hardening"
  local changed=false
  backup_file_if_exists "/etc/ssh/sshd_config"
  backup_file_if_exists "/etc/ssh/sshd_config.d/00-provision.conf"

  local root_login password_auth
  root_login="$(normalize_bool_to_ssh "${SSH_PERMIT_ROOT_LOGIN:-prohibit-password}")"
  password_auth="$(normalize_bool_to_ssh "${SSH_PASSWORD_AUTH:-no}")"
  local expected=(
    "PermitRootLogin=$root_login"
    "X11Forwarding=${SSH_X11_FORWARDING:-no}"
    "MaxAuthTries=${SSH_MAX_AUTH_TRIES:-3}"
    "KbdInteractiveAuthentication=${SSH_KBD_INTERACTIVE_AUTH:-no}"
  )

  ensure_sshd_option "Port" "${SSH_PORT:-22}"; [[ "$ENSURE_LAST_STATUS" == "changed" ]] && changed=true
  ensure_sshd_option "PermitRootLogin" "$root_login"; [[ "$ENSURE_LAST_STATUS" == "changed" ]] && changed=true
  if [[ "$password_auth" == "no" && ! -s "/home/$DEFAULT_USER/.ssh/authorized_keys" ]]; then
    log_status "failed" "run_ssh_hardening" "refusing PasswordAuthentication no: /home/$DEFAULT_USER/.ssh/authorized_keys is empty (would lock out $DEFAULT_USER)"
  else
    ensure_sshd_option "PasswordAuthentication" "$password_auth"; [[ "$ENSURE_LAST_STATUS" == "changed" ]] && changed=true
    expected+=("PasswordAuthentication=$password_auth")
  fi
  ensure_sshd_option "X11Forwarding" "${SSH_X11_FORWARDING:-no}"; [[ "$ENSURE_LAST_STATUS" == "changed" ]] && changed=true
  ensure_sshd_option "MaxAuthTries" "${SSH_MAX_AUTH_TRIES:-3}"; [[ "$ENSURE_LAST_STATUS" == "changed" ]] && changed=true
  ensure_sshd_option "KbdInteractiveAuthentication" "${SSH_KBD_INTERACTIVE_AUTH:-no}"; [[ "$ENSURE_LAST_STATUS" == "changed" ]] && changed=true

  remove_legacy_ssh_dropins
  [[ "$SSH_LEGACY_REMOVED" == "true" ]] && changed=true

  if [[ "$changed" == "true" ]] && ! is_plan_mode && ! sshd -t; then
    log_status "failed" "run_ssh_hardening" "sshd -t failed; not restarting ssh"
    return 1
  fi

  ensure_service_restarted_if_changed ssh "$changed"
  verify_sshd_effective "${expected[@]}"
}
