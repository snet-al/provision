#!/bin/bash

run_firewall() {
  log_info "Running task: firewall"
  ensure_package ufw
  backup_file_if_exists "/etc/ufw/user.rules"
  backup_file_if_exists "/etc/ufw/user6.rules"

  local desired_in="${UFW_DEFAULT_INCOMING:-deny}"
  local desired_out="${UFW_DEFAULT_OUTGOING:-allow}"
  local verbose_status
  verbose_status="$(ufw status verbose 2>/dev/null || true)"
  if printf '%s\n' "$verbose_status" | grep -E "Default:[[:space:]]+${desired_in}[[:space:]]+\(incoming\),[[:space:]]+${desired_out}[[:space:]]+\(outgoing\)" >/dev/null 2>&1; then
    log_status "ok" "run_firewall" "ufw defaults already ${desired_in}/${desired_out}"
  elif is_plan_mode; then
    log_status "changed" "run_firewall" "plan: would set ufw defaults to ${desired_in}/${desired_out}"
  else
    ufw --force default "$desired_in" incoming >/dev/null
    ufw --force default "$desired_out" outgoing >/dev/null
    log_status "changed" "run_firewall" "ufw defaults enforced to ${desired_in}/${desired_out}"
  fi

  if printf '%s\n' "$verbose_status" | grep -F "Status: active" >/dev/null 2>&1; then
    log_status "ok" "run_firewall" "ufw already enabled"
  elif is_plan_mode; then
    log_status "changed" "run_firewall" "plan: would enable ufw"
  else
    ufw --force enable >/dev/null
    log_status "changed" "run_firewall" "ufw enabled"
  fi

  local rules="${UFW_ALLOWED_PORTS:-}"
  if [[ -z "$rules" && -n "${UFW_ALLOWED_SERVICES:-}" ]]; then
    rules="$UFW_ALLOWED_SERVICES"
  fi
  if [[ -z "$rules" ]]; then
    rules="22 80 443"
  fi

  local p
  for p in $rules; do
    ensure_ufw_rule "$p"
  done
}
