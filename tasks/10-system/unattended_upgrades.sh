#!/bin/bash

run_unattended_upgrades() {
  log_info "Running task: unattended_upgrades"
  ensure_package unattended-upgrades

  local codename
  codename="$(. /etc/os-release && echo "$VERSION_CODENAME")"
  local file50="/etc/apt/apt.conf.d/50unattended-upgrades"
  local content50="Unattended-Upgrade::Origins-Pattern {\n        \"origin=Ubuntu,archive=${codename}-security\";\n        \"origin=Ubuntu,archive=${codename}-updates\";\n};\nUnattended-Upgrade::Automatic-Reboot \"false\";"
  ensure_block_in_file "$file50" "provision:unattended-upgrades" "$content50"

  local file20="/etc/apt/apt.conf.d/20auto-upgrades"
  local content20="APT::Periodic::Update-Package-Lists \"1\";\nAPT::Periodic::Unattended-Upgrade \"1\";"
  ensure_block_in_file "$file20" "provision:auto-upgrades" "$content20"

  ensure_cron_job "provision-unattended-upgrades" "0 3 * * *" "unattended-upgrade -v"
  ensure_service_enabled unattended-upgrades
  ensure_service_running unattended-upgrades
}
