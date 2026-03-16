#!/bin/bash

run_fail2ban() {
  log_info "Running task: fail2ban"
  if [[ "${ENABLE_FAIL2BAN:-true}" =~ ^(false|no|0)$ ]]; then
    log_status "skipped" "run_fail2ban" "disabled by config"
    return 0
  fi

  ensure_package fail2ban
  ensure_directory /etc/fail2ban/jail.d

  local jail_file="/etc/fail2ban/jail.d/sshd-hardening.conf"
  local jail_content="[sshd]\nenabled  = true\nmaxretry = ${FAIL2BAN_SSH_MAXRETRY:-3}\nbantime  = ${FAIL2BAN_SSH_BANTIME:-1h}\nfindtime = ${FAIL2BAN_SSH_FINDTIME:-10m}"

  ensure_block_in_file "$jail_file" "provision:fail2ban:sshd" "$jail_content"
  ensure_service_enabled fail2ban
  ensure_service_running fail2ban
}
