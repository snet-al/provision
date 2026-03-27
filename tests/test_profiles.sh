#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

for f in \
  "$ROOT_DIR/tasks/10-system/base.sh" \
  "$ROOT_DIR/tasks/20-identity/user_forge.sh" \
  "$ROOT_DIR/tasks/30-security/ssh_hardening.sh" \
  "$ROOT_DIR/tasks/10-system/unattended_upgrades.sh" \
  "$ROOT_DIR/tasks/30-security/firewall.sh" \
  "$ROOT_DIR/tasks/30-security/fail2ban.sh" \
  "$ROOT_DIR/tasks/30-security/microsoft_defender.sh" \
  "$ROOT_DIR/tasks/40-container/docker.sh" \
  "$ROOT_DIR/tasks/40-container/portainer.sh" \
  "$ROOT_DIR/tasks/50-extensions/provision_servers.sh" \
  "$ROOT_DIR/tasks/90-post/post_setup.sh" \
  "$ROOT_DIR/profiles/basic.sh" \
  "$ROOT_DIR/profiles/docker_host.sh" \
  "$ROOT_DIR/profiles/multi_deployment.sh" \
  "$ROOT_DIR/profiles/deployment_compose.sh"; do
  bash -n "$f"
done

echo "test_profiles.sh passed"
