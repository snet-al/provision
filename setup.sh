#!/bin/bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HANDOFF_COMPLETE=false

CLI_PROFILE=""
CLI_CONFIG=""
CLI_NON_INTERACTIVE=false
CLI_APPLY=false
INTERACTIVE_DEFAULT=false

show_help() {
  cat <<USAGE
Usage:
  sudo ./setup.sh                            # interactive mode
  sudo ./setup.sh --profile docker_host --non-interactive --apply #the docker_host profile is the default profile becase we have everything on docker
  sudo ./setup.sh --config ./hosts/basic.yml --apply

Options:
  --profile <name>         Profile to run: basic|docker_host|agents|multi_deployment
  --config <path>          Host config file (.yml/.yaml)
  --non-interactive        Do not prompt; fail on missing required values
  --apply                  Apply changes
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
    --apply)
      CLI_APPLY=true
      shift
      ;;
    --handoff)
      HANDOFF_COMPLETE=true
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
if [[ -z "$CLI_PROFILE" && -z "$CLI_CONFIG" && "$CLI_NON_INTERACTIVE" == "false" && "$CLI_APPLY" == "false" ]]; then
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

target_user_repo() {
  echo "/home/$DEFAULT_USER/provision"
}

sync_repo_for_handoff() {
  local target_repo
  target_repo="$(target_user_repo)"

  if [[ "$ROOT_DIR" == "$target_repo" ]]; then
    log_info "Already running from handoff workspace $target_repo"
    return 0
  fi

  log_info "Syncing repository to $target_repo for handoff"
  mkdir -p "$target_repo"
  chown "$DEFAULT_USER:$DEFAULT_USER" "$target_repo"
  chmod 750 "$target_repo"

  if rsync -a --delete --exclude "provision-servers/" "$ROOT_DIR/" "$target_repo/"; then
    chown -R "$DEFAULT_USER:$DEFAULT_USER" "$target_repo"
    log_info "Repository synced to $target_repo"
    return 0
  fi

  log_error "Failed to sync repository to $target_repo"
  return 1
}

handoff_to_user_repo() {
  local target_repo
  local handoff_args=("--handoff" "--profile" "$PROVISION_PROFILE")
  target_repo="$(target_user_repo)"

  if [[ "$HANDOFF_COMPLETE" == "true" ]]; then
    log_info "Handoff already complete; continuing from $ROOT_DIR"
    return 0
  fi

  if [[ "$ROOT_DIR" == "$target_repo" ]]; then
    log_info "Already executing from target workspace $target_repo"
    return 0
  fi

  ensure_forge_workspace_ready
  sync_repo_for_handoff

  handoff_args+=("--apply")
  [[ "$PROVISION_NON_INTERACTIVE" == "true" ]] && handoff_args+=("--non-interactive")
  [[ -n "$CLI_CONFIG" ]] && handoff_args+=("--config" "$CLI_CONFIG")

  log_info "Re-launching setup from $target_repo"
  exec "$target_repo/setup.sh" "${handoff_args[@]}"
}

bootstrap_yq() {
  if command -v yq >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
    log_info "Required dependencies already available: yq jq"
    return 0
  fi

  ensure_root
  log_info "Bootstrapping required dependencies: yq jq"
  if ! apt-get update -y; then
    log_error "Failed to update apt metadata while installing yq/jq."
    exit 1
  fi
  if ! apt-get install -y yq jq; then
    log_error "Failed to install required dependencies: yq jq."
    exit 1
  fi
  if ! command -v yq >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
    log_error "Dependency bootstrap incomplete: expected both yq and jq to be available."
    exit 1
  fi
  log_info "Dependency bootstrap complete: yq jq"
}

PROVISION_MODE="apply"

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
fi

ensure_root
init_logging
trap 'log_error "Setup aborted unexpectedly near line $LINENO"' ERR

if [[ -n "$CLI_CONFIG" && -z "$CLI_PROFILE" ]]; then
  bootstrap_yq
  detected_profile="$(detect_profile_from_host_config "$CLI_CONFIG")"
  if [[ -n "$detected_profile" ]]; then
    PROVISION_PROFILE="$detected_profile"
  fi
fi

bootstrap_yq
log_info "Loading profile config for $PROVISION_PROFILE"
load_profile_config "$PROVISION_PROFILE"

if [[ -n "$CLI_CONFIG" ]]; then
  log_info "Loading host config from $CLI_CONFIG"
  load_host_config "$CLI_CONFIG"
fi

apply_cli_overrides

if [[ -n "${SERVER_HOSTNAME:-}" ]]; then
  PROVISION_HOSTNAME="$SERVER_HOSTNAME"
fi

validate_required_non_interactive
handoff_to_user_repo

echo "Starting profile: $PROVISION_PROFILE (mode=$PROVISION_MODE)"

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

run_post_setup

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
