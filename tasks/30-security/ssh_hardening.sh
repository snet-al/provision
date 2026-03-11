#!/bin/bash

normalize_bool_to_ssh() {
  local v="${1:-}"
  case "${v,,}" in
    true|yes|1) echo "yes" ;;
    false|no|0) echo "no" ;;
    *) echo "$v" ;;
  esac
}

run_ssh_hardening() {
  log_info "Running task: ssh_hardening"
  local changed=false
  backup_file_if_exists "/etc/ssh/sshd_config"
  backup_file_if_exists "/etc/ssh/sshd_config.d/99-provision.conf"

  ensure_sshd_option "Port" "${SSH_PORT:-22}"; [[ "$ENSURE_LAST_STATUS" == "changed" ]] && changed=true
  ensure_sshd_option "PermitRootLogin" "$(normalize_bool_to_ssh "${SSH_PERMIT_ROOT_LOGIN:-no}")"; [[ "$ENSURE_LAST_STATUS" == "changed" ]] && changed=true
  ensure_sshd_option "PasswordAuthentication" "$(normalize_bool_to_ssh "${SSH_PASSWORD_AUTH:-no}")"; [[ "$ENSURE_LAST_STATUS" == "changed" ]] && changed=true
  ensure_sshd_option "X11Forwarding" "${SSH_X11_FORWARDING:-no}"; [[ "$ENSURE_LAST_STATUS" == "changed" ]] && changed=true
  ensure_sshd_option "MaxAuthTries" "${SSH_MAX_AUTH_TRIES:-3}"; [[ "$ENSURE_LAST_STATUS" == "changed" ]] && changed=true

  ensure_service_restarted_if_changed ssh "$changed"
}
