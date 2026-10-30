#!/bin/bash

invalid_unattended_patterns() {
  awk -F'"' '
    index($1, "Unattended-Upgrade") && index($1, "\\n") { print $1; next }
    /^Unattended-Upgrade::Origins-Pattern:: / {
      p = $2
      gsub(/\\,/, "%2C", p)
      if (p ~ /^[[:space:]]*$/) next
      n = split(p, toks, ",")
      for (i = 1; i <= n; i++) {
        m = split(toks[i], kv, "=")
        k = kv[1]
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", k)
        if (m != 2 || k !~ /^(o|origin|l|label|a|archive|suite|c|component|n|codename|site)$/) { print $2; break }
      }
    }
  '
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
