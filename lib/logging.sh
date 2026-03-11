#!/bin/bash

LOG_FILE="${LOG_FILE:-/var/log/provision.log}"

log_line() {
  local level="$1"
  local msg="$2"
  local ts
  local line
  ts="$(date '+%Y-%m-%d %H:%M:%S')"
  line="$(printf '[%s] [%s] %s\n' "$ts" "$level" "$msg")"
  printf '%s\n' "$line"
  printf '%s\n' "$line" >> "$LOG_FILE" 2>/dev/null || true
}

log_info() { log_line "INFO" "$1"; }
log_warn() { log_line "WARN" "$1"; }
log_error() { log_line "ERROR" "$1" >&2; }

log_status() {
  local status="$1"
  local name="$2"
  local msg="${3:-}"
  mark_status "$status"
  log_line "$status" "$name${msg:+: $msg}"
}

init_logging() {
  if ! touch "$LOG_FILE" 2>/dev/null; then
    LOG_FILE="/tmp/provision.log"
    touch "$LOG_FILE"
  fi
  chmod 0644 "$LOG_FILE" || true
  log_info "Provision run started (mode=$PROVISION_MODE profile=$PROVISION_PROFILE host=$PROVISION_HOSTNAME)"
}

write_json_report() {
  local report_path="$1"
  mkdir -p "$(dirname "$report_path")"
  cat > "$report_path" <<JSON
{
  "host": "${PROVISION_HOSTNAME}",
  "profile": "${PROVISION_PROFILE}",
  "ok": ${SUMMARY_OK},
  "changed": ${SUMMARY_CHANGED},
  "failed": ${SUMMARY_FAILED},
  "skipped": ${SUMMARY_SKIPPED},
  "duration_sec": $(current_duration_sec)
}
JSON
}
