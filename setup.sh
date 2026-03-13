#!/bin/bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

CLI_PROFILE=""
CLI_CONFIG=""
CLI_NON_INTERACTIVE=false
CLI_PLAN=false
CLI_APPLY=false
INTERACTIVE_DEFAULT=false

show_help() {
  cat <<USAGE
Usage:
  sudo ./setup.sh                            # interactive mode
  sudo ./setup.sh --profile docker_host --non-interactive --apply #the docker_host profile is the default profile becase we have everything on docker
  sudo ./setup.sh --config ./hosts/basic.yml --plan

Options:
  --profile <name>         Profile to run: basic|docker_host|agents|multi_deployment
  --config <path>          Host config file (.yml/.yaml)
  --non-interactive        Do not prompt; fail on missing required values
  --plan                   Dry-run mode (best effort)
  --apply                  Apply changes (default when using flags)
  -h, --help               Show help
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile)
      CLI_PROFILE="${2:-}"
      shift 2
      ;;
    --config)
      CLI_CONFIG="${2:-}"
      shift 2
      ;;
    --non-interactive)
      CLI_NON_INTERACTIVE=true
      shift
      ;;
    --plan)
      CLI_PLAN=true
      shift
      ;;
    --apply)
      CLI_APPLY=true
      shift
      ;;
    -h|--help)
      show_help
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      show_help
      exit 1
      ;;
  esac
done

# No flags means interactive mode with new framework.
if [[ -z "$CLI_PROFILE" && -z "$CLI_CONFIG" && "$CLI_NON_INTERACTIVE" == "false" && "$CLI_PLAN" == "false" && "$CLI_APPLY" == "false" ]]; then
  INTERACTIVE_DEFAULT=true
fi

source "$ROOT_DIR/lib/core.sh"
source "$ROOT_DIR/lib/logging.sh"
source "$ROOT_DIR/lib/files.sh"
source "$ROOT_DIR/lib/services.sh"
source "$ROOT_DIR/lib/ensure.sh"
source "$ROOT_DIR/lib/config.sh"

source "$ROOT_DIR/tasks/10-system/base.sh"
source "$ROOT_DIR/tasks/20-identity/user_forge.sh"
source "$ROOT_DIR/tasks/30-security/ssh_hardening.sh"
source "$ROOT_DIR/tasks/10-system/unattended_upgrades.sh"
source "$ROOT_DIR/tasks/30-security/firewall.sh"
source "$ROOT_DIR/tasks/30-security/fail2ban.sh"
source "$ROOT_DIR/tasks/30-security/microsoft_defender.sh"
source "$ROOT_DIR/tasks/40-container/docker.sh"
source "$ROOT_DIR/tasks/40-container/portainer.sh"
source "$ROOT_DIR/tasks/50-extensions/provision_servers.sh"
source "$ROOT_DIR/tasks/90-post/post_setup.sh"

source "$ROOT_DIR/profiles/basic.sh"
source "$ROOT_DIR/profiles/docker_host.sh"
source "$ROOT_DIR/profiles/agents.sh"
source "$ROOT_DIR/profiles/multi_deployment.sh"

bootstrap_yq() {
  if command -v yq >/dev/null 2>&1; then
    return 0
  fi

  echo "Bootstrapping required dependency: yq"
  apt-get update -y >/dev/null
  apt-get install -y yq >/dev/null
}

if [[ "$CLI_PLAN" == "true" ]]; then
  PROVISION_MODE="plan"
else
  PROVISION_MODE="apply"
fi

if [[ "$CLI_NON_INTERACTIVE" == "true" ]]; then
  PROVISION_NON_INTERACTIVE="true"
fi

if [[ -n "$CLI_PROFILE" ]]; then
  PROVISION_PROFILE="$CLI_PROFILE"
fi

if [[ "$INTERACTIVE_DEFAULT" == "true" ]]; then
  echo
  echo "Select provisioning profile:"
  echo "1) basic"
  echo "2) docker_host"
  echo "3) agents"
  echo "4) multi_deployment"
  read -rp "Enter choice [1-4, default 2]: " _profile_choice
  case "${_profile_choice:-2}" in
    1) PROVISION_PROFILE="basic" ;;
    2) PROVISION_PROFILE="docker_host" ;;
    3) PROVISION_PROFILE="agents" ;;
    4) PROVISION_PROFILE="multi_deployment" ;;
    *) echo "Invalid choice"; exit 1 ;;
  esac

  read -rp "Run in plan mode? (y/N): " _plan_choice
  if [[ "${_plan_choice:-n}" =~ ^[Yy]$ ]]; then
    PROVISION_MODE="plan"
  else
    PROVISION_MODE="apply"
  fi
fi

if [[ -n "$CLI_CONFIG" && -z "$CLI_PROFILE" ]]; then
  detected_profile="$(detect_profile_from_host_config "$CLI_CONFIG")"
  if [[ -n "$detected_profile" ]]; then
    PROVISION_PROFILE="$detected_profile"
  fi
fi

bootstrap_yq
load_profile_config "$PROVISION_PROFILE"

if [[ -n "$CLI_CONFIG" ]]; then
  load_host_config "$CLI_CONFIG"
fi

apply_cli_overrides

if [[ -n "${SERVER_HOSTNAME:-}" ]]; then
  PROVISION_HOSTNAME="$SERVER_HOSTNAME"
fi

ensure_root
init_logging
validate_required_non_interactive

run_profile() {
  case "$PROVISION_PROFILE" in
    basic) profile_basic ;;
    docker_host) profile_docker_host ;;
    agents) profile_agents ;;
    multi_deployment) profile_multi_deployment ;;
    *)
      log_error "Unknown profile: $PROVISION_PROFILE"
      exit 1
      ;;
  esac
}

if run_profile; then
  :
else
  log_status "failed" "setup" "profile execution failed"
fi

report_dir="$ROOT_DIR/reports/$(date +%Y%m%d_%H%M%S)"
report_file="$report_dir/${PROVISION_HOSTNAME}.json"
write_json_report "$report_file"

cat <<SUMMARY

Execution summary:
  OK:      $SUMMARY_OK
  CHANGED: $SUMMARY_CHANGED
  FAILED:  $SUMMARY_FAILED
  SKIPPED: $SUMMARY_SKIPPED
  REPORT:  $report_file
SUMMARY

if [[ "$SUMMARY_FAILED" -gt 0 ]]; then
  echo
  echo "Provisioning finished with failures."
  exit 1
fi

echo
echo "Provisioning completed successfully."
echo "Done."
