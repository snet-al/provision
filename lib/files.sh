#!/bin/bash

backup_file_if_exists() {
  local src="$1"
  local backup_dir="${BACKUP_DIR:-/etc/provision-backups}"
  [[ -f "$src" ]] || return 0
  local dst="$backup_dir/$(basename "$src").$(date +%Y%m%d_%H%M%S).bak"
  if is_plan_mode; then
    log_status "skipped" "backup_file_if_exists" "plan: would backup $src to $dst"
    return 0
  fi
  mkdir -p "$backup_dir"
  cp "$src" "$dst"
  log_status "changed" "backup_file_if_exists" "backup created at $dst"
}

file_contains_line() {
  local file="$1"
  local line="$2"
  [[ -f "$file" ]] && grep -F -- "$line" "$file" >/dev/null 2>&1
}
