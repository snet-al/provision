#!/bin/bash

run_base() {
  log_info "Running task: base"
  ensure_package ca-certificates
  ensure_package curl
  ensure_package git
  ensure_package rsync
  ensure_package software-properties-common

  if [[ -n "${SERVER_TIMEZONE:-}" ]]; then
    local current_tz
    current_tz="$(timedatectl show -p Timezone --value 2>/dev/null || true)"
    if [[ "$current_tz" == "$SERVER_TIMEZONE" ]]; then
      log_status "ok" "run_base" "timezone already $SERVER_TIMEZONE"
    elif is_plan_mode; then
      log_status "changed" "run_base" "plan: would set timezone to $SERVER_TIMEZONE"
    else
      timedatectl set-timezone "$SERVER_TIMEZONE"
      log_status "changed" "run_base" "timezone set to $SERVER_TIMEZONE"
    fi
  else
    log_status "skipped" "run_base" "timezone not configured"
  fi
}
