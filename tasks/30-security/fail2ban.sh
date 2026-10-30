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
  local jail_status="$ENSURE_LAST_STATUS"
  ensure_service_enabled fail2ban
  ensure_service_running fail2ban

  if [[ "$jail_status" == "failed" ]]; then
    return 1
  fi

  if [[ "$jail_status" == "changed" ]] && ! is_plan_mode; then
    if fail2ban-client reload >/dev/null 2>&1; then
      log_status "changed" "run_fail2ban" "fail2ban reloaded with new sshd jail"
    else
      log_status "failed" "run_fail2ban" "fail2ban-client reload failed (check: fail2ban-client -d)"
      return 1
    fi
  fi
}
