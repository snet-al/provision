#!/bin/bash

fail2ban_seconds() {
  local v="$1"
  case "$v" in
    *[0-9]w) echo $(( ${v%w} * 604800 )) ;;
    *[0-9]d) echo $(( ${v%d} * 86400 )) ;;
    *[0-9]h) echo $(( ${v%h} * 3600 )) ;;
    *[0-9]m) echo $(( ${v%m} * 60 )) ;;
    *[0-9]s) echo "${v%s}" ;;
    *) echo "$v" ;;
  esac
}

fail2ban_sshd_jail_mismatch() {
  local pair key want got
  for pair in \
    "maxretry=${FAIL2BAN_SSH_MAXRETRY:-3}" \
    "bantime=$(fail2ban_seconds "${FAIL2BAN_SSH_BANTIME:-1h}")" \
    "findtime=$(fail2ban_seconds "${FAIL2BAN_SSH_FINDTIME:-10m}")"; do
    key="${pair%%=*}"
    want="${pair#*=}"
    got="$(fail2ban-client get sshd "$key" 2>/dev/null)" || got="(jail not running)"
    if [[ "$got" != "$want" ]]; then
      echo "$key is $got, want $want"
      return 0
    fi
  done
  return 1
}

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

  local mismatch
  if ! mismatch="$(fail2ban_sshd_jail_mismatch)"; then
    log_status "ok" "run_fail2ban" "running sshd jail matches config"
    return 0
  fi

  if is_plan_mode; then
    log_status "changed" "run_fail2ban" "plan: would reload fail2ban (running sshd jail: $mismatch)"
    return 0
  fi

  if ! fail2ban-client reload >/dev/null 2>&1; then
    log_status "failed" "run_fail2ban" "fail2ban-client reload failed (running sshd jail: $mismatch; check: fail2ban-client -d)"
    return 1
  fi
  if mismatch="$(fail2ban_sshd_jail_mismatch)"; then
    log_status "failed" "run_fail2ban" "fail2ban reloaded but the running sshd jail still differs: $mismatch"
    return 1
  fi
  log_status "changed" "run_fail2ban" "fail2ban reloaded; running sshd jail matches config"
}
