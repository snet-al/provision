#!/bin/bash

invalid_unattended_patterns() {
  local dump
  dump="$(cat)"
  awk -F'"' 'index($1, "Unattended-Upgrade") && index($1, "\\n") { print $1 }' <<<"$dump"
  awk -F'"' '/^Unattended-Upgrade::Origins-Pattern:: / { print $2 }' <<<"$dump" | python3 -I -c '
import importlib.machinery, importlib.util, logging, sys, types
logging.disable(logging.CRITICAL)
try:
    loader = importlib.machinery.SourceFileLoader("unattended_upgrade_worker", sys.argv[1])
    worker = importlib.util.module_from_spec(importlib.util.spec_from_loader(loader.name, loader))
    loader.exec_module(worker)
    check = worker.match_whitelist_string
except Exception as exc:
    print("cannot load the unattended-upgrade parser from %s: %s" % (sys.argv[1], exc))
    sys.exit(0)
origin = types.SimpleNamespace(origin="", label="", archive="", codename="", component="", site="")
for line in sys.stdin:
    pattern = line.rstrip("\n")
    if not pattern.strip():
        continue
    try:
        check(pattern, origin)
    except Exception:
        print(pattern)
' "${UNATTENDED_UPGRADE_BIN:-/usr/bin/unattended-upgrade}" 2>/dev/null
}

run_unattended_upgrades() {
  log_info "Running task: unattended_upgrades"
  ensure_package unattended-upgrades

  local codename
  codename="$(. /etc/os-release && echo "$VERSION_CODENAME")"

  local reboot="false"
  [[ "${AUTO_REBOOT:-false}" =~ ^(true|yes|1)$ ]] && reboot="true"
  local reboot_time="${AUTO_REBOOT_TIME:-04:00}"

  ensure_block_absent "/etc/apt/apt.conf.d/50unattended-upgrades" "provision:unattended-upgrades"

  local file52="/etc/apt/apt.conf.d/52provision-unattended-upgrades"
  local content52="Unattended-Upgrade::Origins-Pattern {\n        \"origin=Ubuntu,archive=${codename}-security\";\n        \"origin=Ubuntu,archive=${codename}-updates\";\n};\nUnattended-Upgrade::Automatic-Reboot \"${reboot}\";\nUnattended-Upgrade::Automatic-Reboot-Time \"${reboot_time}\";"
  ensure_block_in_file "$file52" "provision:unattended-upgrades" "$content52"

  local file20="/etc/apt/apt.conf.d/20auto-upgrades"
  local content20="APT::Periodic::Update-Package-Lists \"1\";\nAPT::Periodic::Unattended-Upgrade \"1\";"
  ensure_block_in_file "$file20" "provision:auto-upgrades" "$content20"

  if ! is_plan_mode; then
    local dump bad_patterns
    if ! dump="$(apt-config dump 2>&1)"; then
      log_status "failed" "run_unattended_upgrades" "apt config does not parse: $dump"
      return 1
    fi
    bad_patterns="$(invalid_unattended_patterns <<<"$dump")"
    if [[ -n "$bad_patterns" ]]; then
      log_status "failed" "run_unattended_upgrades" "unattended-upgrade would reject these Origins-Pattern entries in /etc/apt/apt.conf.d: ${bad_patterns//$'\n'/; }"
      return 1
    fi
    log_status "ok" "run_unattended_upgrades" "apt config valid (auto reboot=${reboot} at ${reboot_time})"
  fi

  ensure_cron_job "provision-unattended-upgrades" "0 3 * * *" "unattended-upgrade -v"
  ensure_service_enabled unattended-upgrades
  ensure_service_running unattended-upgrades
}
