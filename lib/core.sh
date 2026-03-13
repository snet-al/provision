#!/bin/bash

set -o errexit
set -o nounset
set -o pipefail

readonly PROVISION_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PROVISION_MODE="${PROVISION_MODE:-apply}"   # apply|plan
PROVISION_NON_INTERACTIVE="${PROVISION_NON_INTERACTIVE:-false}"
PROVISION_PROFILE="${PROVISION_PROFILE:-basic}"
PROVISION_HOSTNAME="${PROVISION_HOSTNAME:-$(hostname -s 2>/dev/null || hostname)}"
PROVISION_REPORT_DIR="${PROVISION_REPORT_DIR:-$PROVISION_ROOT/reports}"
PROVISION_START_TS="$(date +%s)"

SUMMARY_OK=0
SUMMARY_CHANGED=0
SUMMARY_FAILED=0
SUMMARY_SKIPPED=0

ensure_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "This script must be run as root (sudo)." >&2
    exit 1
  fi
}

is_plan_mode() {
  [[ "$PROVISION_MODE" == "plan" ]]
}

mark_status() {
  local status="$1"
  case "$status" in
    ok) SUMMARY_OK=$((SUMMARY_OK + 1)) ;;
    changed) SUMMARY_CHANGED=$((SUMMARY_CHANGED + 1)) ;;
    failed) SUMMARY_FAILED=$((SUMMARY_FAILED + 1)) ;;
    skipped) SUMMARY_SKIPPED=$((SUMMARY_SKIPPED + 1)) ;;
  esac
}

current_duration_sec() {
  local now
  now="$(date +%s)"
  echo $((now - PROVISION_START_TS))
}
