#!/bin/bash

mde_bool_true() {
  [[ "${1,,}" =~ ^(true|yes|1)$ ]]
}

mde_os_supported() {
  if [[ ! -f /etc/os-release ]]; then
    return 1
  fi
  # Current provisioning scope is Ubuntu 24.04+ servers.
  # The guard is explicit so unsupported distros fail safely.
  . /etc/os-release
  [[ "${ID:-}" == "ubuntu" ]]
}

mde_install_repo_and_package() {
  ensure_package ca-certificates
  ensure_package curl
  ensure_package gnupg
  ensure_directory /etc/apt/keyrings 755

  local key_path="/etc/apt/keyrings/microsoft.asc"
  local repo_name="microsoft-prod-mde"
  local repo_line
  repo_line="deb [arch=$(dpkg --print-architecture) signed-by=${key_path}] https://packages.microsoft.com/ubuntu/$(. /etc/os-release && echo "$VERSION_ID")/prod $(. /etc/os-release && echo "$VERSION_CODENAME") main"

  if [[ ! -f "$key_path" ]]; then
    if is_plan_mode; then
      log_status "changed" "run_microsoft_defender" "plan: would install Microsoft package signing key"
    else
      if curl -fsSL "https://packages.microsoft.com/keys/microsoft.asc" -o "$key_path"; then
        chmod 0644 "$key_path"
        log_status "changed" "run_microsoft_defender" "installed Microsoft package signing key"
      else
        log_status "failed" "run_microsoft_defender" "failed to install Microsoft package signing key"
        return 1
      fi
    fi
  else
    log_status "ok" "run_microsoft_defender" "Microsoft package signing key already present"
  fi

  ensure_apt_repo "$repo_name" "$repo_line"
  ensure_package mdatp
  ensure_service_enabled mdatp
  ensure_service_running mdatp
}

mde_set_mode() {
  local mode="${MDE_MODE:-active}"
  local allow_passive="${MDE_ALLOW_PASSIVE_MODE:-false}"
  local desired_passive="disabled"

  case "$mode" in
    active) desired_passive="disabled" ;;
    passive)
      if ! mde_bool_true "$allow_passive"; then
        log_warn "run_microsoft_defender: passive mode requested but MDE_ALLOW_PASSIVE_MODE is false; staying active."
        return 0
      fi
      desired_passive="enabled"
      ;;
    *)
      log_warn "run_microsoft_defender: unsupported MDE_MODE=$mode, expected active|passive."
      return 0
      ;;
  esac

  if ! command -v mdatp >/dev/null 2>&1; then
    log_status "skipped" "run_microsoft_defender" "mdatp CLI unavailable; skipping mode update"
    return 0
  fi

  local current="unknown"
  local health_out
  health_out="$(mdatp health 2>/dev/null || true)"
  if printf '%s\n' "$health_out" | grep -E 'passive_mode_enabled[^a-zA-Z]*(true|enabled)' >/dev/null 2>&1; then
    current="enabled"
  elif printf '%s\n' "$health_out" | grep -E 'passive_mode_enabled[^a-zA-Z]*(false|disabled)' >/dev/null 2>&1; then
    current="disabled"
  fi

  if [[ "$current" == "$desired_passive" ]]; then
    log_status "ok" "run_microsoft_defender" "passive mode already $desired_passive"
    return 0
  fi

  if is_plan_mode; then
    log_status "changed" "run_microsoft_defender" "plan: would set passive mode to $desired_passive"
    return 0
  fi

  if mdatp config passive-mode --value "$desired_passive" >/dev/null 2>&1; then
    log_status "changed" "run_microsoft_defender" "set passive mode to $desired_passive"
  else
    log_warn "run_microsoft_defender: unable to set passive mode to $desired_passive"
  fi
}

mde_run_onboarding_if_configured() {
  if ! mde_bool_true "${MDE_ONBOARDING_ENABLED:-false}"; then
    log_status "skipped" "run_microsoft_defender" "onboarding disabled"
    return 0
  fi

  local onboarding_cmd="${MDE_ONBOARDING_COMMAND:-}"
  local onboarding_script="${MDE_ONBOARDING_SCRIPT:-}"

  if [[ -z "$onboarding_cmd" && -z "$onboarding_script" ]]; then
    log_warn "run_microsoft_defender: onboarding enabled but no onboarding command/script provided."
    return 0
  fi

  if is_plan_mode; then
    log_status "changed" "run_microsoft_defender" "plan: would run MDE onboarding"
    return 0
  fi

  if [[ -n "$onboarding_script" ]]; then
    if [[ -x "$onboarding_script" ]]; then
      if "$onboarding_script"; then
        log_status "changed" "run_microsoft_defender" "onboarding script executed"
      else
        log_warn "run_microsoft_defender: onboarding script failed"
      fi
    else
      log_warn "run_microsoft_defender: onboarding script path is not executable: $onboarding_script"
    fi
  fi

  if [[ -n "$onboarding_cmd" ]]; then
    if eval "$onboarding_cmd"; then
      log_status "changed" "run_microsoft_defender" "onboarding command executed"
    else
      log_warn "run_microsoft_defender: onboarding command failed"
    fi
  fi
}

mde_healthcheck() {
  if ! mde_bool_true "${MDE_HEALTHCHECK_ENABLED:-true}"; then
    log_status "skipped" "run_microsoft_defender" "healthcheck disabled"
    return 0
  fi

  local installed="false"
  local running="false"
  local passive_mode="unknown"
  local av_enabled="unknown"
  local rtp_enabled="unknown"
  local healthy="unknown"

  if dpkg -s mdatp >/dev/null 2>&1; then
    installed="true"
  fi
  if systemctl is-active mdatp >/dev/null 2>&1; then
    running="true"
  fi

  if command -v mdatp >/dev/null 2>&1; then
    local health_out
    health_out="$(mdatp health 2>/dev/null || true)"

    if printf '%s\n' "$health_out" | grep -E 'passive_mode_enabled[^a-zA-Z]*(true|enabled)' >/dev/null 2>&1; then
      passive_mode="true"
    elif printf '%s\n' "$health_out" | grep -E 'passive_mode_enabled[^a-zA-Z]*(false|disabled)' >/dev/null 2>&1; then
      passive_mode="false"
    fi

    if printf '%s\n' "$health_out" | grep -E 'antivirus_enabled[^a-zA-Z]*(true|enabled)' >/dev/null 2>&1; then
      av_enabled="true"
    elif printf '%s\n' "$health_out" | grep -E 'antivirus_enabled[^a-zA-Z]*(false|disabled)' >/dev/null 2>&1; then
      av_enabled="false"
    fi

    if printf '%s\n' "$health_out" | grep -E 'real_time_protection_enabled[^a-zA-Z]*(true|enabled)' >/dev/null 2>&1; then
      rtp_enabled="true"
    elif printf '%s\n' "$health_out" | grep -E 'real_time_protection_enabled[^a-zA-Z]*(false|disabled)' >/dev/null 2>&1; then
      rtp_enabled="false"
    fi

    if printf '%s\n' "$health_out" | grep -E 'healthy[^a-zA-Z]*(true|yes)' >/dev/null 2>&1; then
      healthy="true"
    elif printf '%s\n' "$health_out" | grep -E 'healthy[^a-zA-Z]*(false|no)' >/dev/null 2>&1; then
      healthy="false"
    fi
  else
    log_warn "run_microsoft_defender: mdatp command not found; health command unavailable."
  fi

  log_info "mde_health installed=$installed running=$running passive_mode=$passive_mode antivirus_enabled=$av_enabled real_time_protection_enabled=$rtp_enabled healthy=$healthy"

  if [[ "${MDE_MODE:-active}" == "active" && "$passive_mode" == "true" ]]; then
    log_warn "run_microsoft_defender: passive mode is enabled unexpectedly while MDE_MODE=active."
  fi

  if mde_bool_true "${MDE_FAIL_ON_UNHEALTHY:-false}"; then
    if [[ "$installed" != "true" || "$running" != "true" || "$healthy" == "false" ]]; then
      log_status "failed" "run_microsoft_defender" "healthcheck failed with strict mode enabled"
      return 1
    fi
  fi

  log_status "ok" "run_microsoft_defender" "healthcheck completed"
}

run_microsoft_defender() {
  log_info "Running task: microsoft_defender"

  if [[ "${ROLE_K8S_WORKER:-false}" =~ ^(true|yes|1)$ ]] && ! mde_bool_true "${ENABLE_MDE:-false}"; then
    log_status "skipped" "run_microsoft_defender" "k8s worker detected; MDE is opt-in and currently disabled"
    return 0
  fi

  if ! mde_bool_true "${ENABLE_MDE:-false}"; then
    log_status "skipped" "run_microsoft_defender" "disabled by config"
    return 0
  fi

  if ! mde_os_supported; then
    log_status "skipped" "run_microsoft_defender" "unsupported distro; MDE module currently supports Ubuntu targets"
    return 0
  fi

  mde_install_repo_and_package
  mde_set_mode
  mde_run_onboarding_if_configured
  mde_healthcheck
}
