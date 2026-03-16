#!/bin/bash

profile_basic() {
  run_base
  run_user_forge
  run_ssh_hardening
  run_unattended_upgrades
  run_firewall
  run_fail2ban
  run_microsoft_defender
}
