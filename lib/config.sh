#!/bin/bash

HOSTS_DIR="${HOSTS_DIR:-$PROVISION_ROOT/hosts}"
HOST_CONFIG_PATH=""
USER_SSH_KEYS=()

require_command() {
  local cmd="$1"
  command -v "$cmd" >/dev/null 2>&1 || {
    log_error "Missing required command: $cmd"
    return 1
  }
}

_set_if_present() {
  local key="$1"
  local value="$2"
  if [[ -n "$value" && "$value" != "null" ]]; then
    printf -v "$key" '%s' "$value"
  fi
}

_apply_env_map_from_yaml() {
  local cfg="$1"
  mapfile -t _env_pairs < <(yq -r '.env // {} | to_entries[] | "\(.key)\t\(.value|@base64)"' "$cfg")
  local pair key value_b64 value
  for pair in "${_env_pairs[@]}"; do
    key="${pair%%$'\t'*}"
    value_b64="${pair#*$'\t'}"
    if [[ "$key" =~ ^[A-Z_][A-Z0-9_]*$ ]]; then
      value="$(printf '%s' "$value_b64" | base64 -d)"
      printf -v "$key" '%s' "$value"
    fi
  done
}

load_profile_config() {
  require_command yq
  local profile="$1"
  local base_cfg="$HOSTS_DIR/${profile}.yml"
  local local_cfg="$HOSTS_DIR/${profile}.local.yml"

  if [[ ! -f "$base_cfg" ]]; then
    log_error "Missing profile config: $base_cfg"
    return 1
  fi

  _apply_env_map_from_yaml "$base_cfg"
  if [[ -f "$local_cfg" ]]; then
    _apply_env_map_from_yaml "$local_cfg"
  fi
}

detect_profile_from_host_config() {
  local cfg="$1"
  require_command yq
  yq -r '.profile // ""' "$cfg"
}

load_host_config_yaml() {
  local cfg="$1"
  require_command yq
  HOST_CONFIG_PATH="$cfg"

  _apply_env_map_from_yaml "$cfg"

  _set_if_present PROVISION_HOSTNAME "$(yq -r '.server.hostname // ""' "$cfg")"
  _set_if_present SERVER_TIMEZONE "$(yq -r '.server.timezone // ""' "$cfg")"
  _set_if_present PROVISION_PROFILE "$(yq -r '.profile // ""' "$cfg")"
  _set_if_present DEFAULT_USER "$(yq -r '.users[0].name // ""' "$cfg")"
  _set_if_present SSH_PORT "$(yq -r '.security.ssh.port // ""' "$cfg")"
  _set_if_present SSH_PASSWORD_AUTH "$(yq -r '.security.ssh.password_auth // ""' "$cfg")"
  _set_if_present SSH_PERMIT_ROOT_LOGIN "$(yq -r '.security.ssh.root_login // ""' "$cfg")"

  local ufw_allow
  ufw_allow="$(yq -r '.security.ufw.allow // [] | join(" ")' "$cfg")"
  _set_if_present UFW_ALLOWED_PORTS "$ufw_allow"

  _set_if_present ENABLE_FAIL2BAN "$(yq -r '.security.fail2ban // ""' "$cfg")"
  _set_if_present ENABLE_DOCKER "$(yq -r '.docker.enabled // ""' "$cfg")"
  _set_if_present ENABLE_PORTAINER "$(yq -r '.docker.portainer // ""' "$cfg")"

  mapfile -t USER_SSH_KEYS < <(yq -r '.users[0].ssh_keys[]? // empty' "$cfg")
}

load_host_config() {
  local cfg="$1"
  case "$cfg" in
    *.yml|*.yaml) load_host_config_yaml "$cfg" ;;
    *)
      log_error "Unsupported host config format: $cfg (YAML only)"
      return 1
      ;;
  esac
}

apply_cli_overrides() {
  if [[ -n "${CLI_PROFILE:-}" ]]; then
    PROVISION_PROFILE="$CLI_PROFILE"
  fi
  return 0
}

validate_required_non_interactive() {
  if [[ "$PROVISION_NON_INTERACTIVE" != "true" ]]; then
    return 0
  fi

  if [[ -z "${PROVISION_PROFILE:-}" ]]; then
    log_error "--non-interactive requires profile (via --profile or config)."
    return 1
  fi

  if [[ -z "${DEFAULT_USER:-}" ]]; then
    log_error "--non-interactive missing DEFAULT_USER."
    return 1
  fi
}
