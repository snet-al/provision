#!/bin/bash

normalize_bool_to_ssh() {
  local v="${1:-}"
  case "${v,,}" in
    true|yes|1) echo "yes" ;;
    false|no|0) echo "no" ;;
    *) echo "$v" ;;
  esac
}

sshd_effective_value() {
  local key="$1"
  local value="$2"
  case "${key,,}:${value,,}" in
    permitrootlogin:prohibit-password) echo "without-password" ;;
    *) echo "${value,,}" ;;
  esac
}

ssh_option_value_valid() {
  local key="$1"
  local value="$2"
  case "$key" in
    PermitRootLogin) [[ "$value" =~ ^(yes|no|prohibit-password|without-password|forced-commands-only)$ ]] ;;
    Port|MaxAuthTries) [[ "$value" =~ ^[0-9]+$ ]] ;;
    *) [[ "$value" =~ ^(yes|no)$ ]] ;;
  esac
}

ssh_check_context() {
  echo "user=$1,host=provision-check,addr=203.0.113.10"
}

ssh_dropin_unmanaged_keys() {
  awk '
    /^[[:space:]]*(#|$)/ { next }
    {
      k = tolower($1)
      if (k !~ /^(port|permitrootlogin|passwordauthentication|x11forwarding|maxauthtries|kbdinteractiveauthentication)$/) print $1
    }
  ' "$1" | sort -u | tr '\n' ' '
}

ssh_dropin_names() {
  echo "00-provision.conf ${SSH_LEGACY_DROPINS:-99-provision.conf 00-hardening.conf}"
}

ssh_snapshot_dropins() {
  local snapshot="$1" dir="${SSH_DROPIN_DIR:-/etc/ssh/sshd_config.d}" name
  : > "$snapshot/.present" || return 1
  for name in $(ssh_dropin_names); do
    if [[ -f "$dir/$name" ]]; then
      cp -p "$dir/$name" "$snapshot/$name" || return 1
      cmp -s "$dir/$name" "$snapshot/$name" || return 1
      printf '%s\n' "$name" >> "$snapshot/.present" || return 1
    fi
  done
  : > "$snapshot/.complete" || return 1
}

ssh_restore_dropins() {
  local snapshot="$1" dir="${SSH_DROPIN_DIR:-/etc/ssh/sshd_config.d}" name restore_failed=false
  [[ -f "$snapshot/.complete" ]] || return 1
  for name in $(ssh_dropin_names); do
    if grep -Fx -- "$name" "$snapshot/.present" >/dev/null; then
      cp -p "$snapshot/$name" "$dir/$name" || restore_failed=true
    else
      rm -f "$dir/$name" || restore_failed=true
    fi
  done
  [[ "$restore_failed" == "false" ]]
}

remove_legacy_ssh_dropins() {
  local name path unmanaged
  SSH_LEGACY_REMOVED=false
  for name in ${SSH_LEGACY_DROPINS:-99-provision.conf 00-hardening.conf}; do
    path="${SSH_DROPIN_DIR:-/etc/ssh/sshd_config.d}/$name"
    [[ -f "$path" ]] || continue
    unmanaged="$(ssh_dropin_unmanaged_keys "$path")"
    if [[ -n "$unmanaged" ]]; then
      log_warn "Keeping $path: it sets options provision does not manage (${unmanaged% }); review it and remove it by hand if it is obsolete"
      log_status "skipped" "run_ssh_hardening" "kept legacy drop-in $path (unmanaged: ${unmanaged% })"
      continue
    fi
    if is_plan_mode; then
      log_status "changed" "run_ssh_hardening" "plan: would remove legacy drop-in $path"
      continue
    fi
    backup_file_if_exists "$path"
    rm -f "$path"
    SSH_LEGACY_REMOVED=true
    log_status "changed" "run_ssh_hardening" "removed legacy drop-in $path"
  done
}

verify_sshd_effective() {
  if grep -Eqs '^[[:space:]]*Match[[:space:]]' /etc/ssh/sshd_config "${SSH_DROPIN_DIR:-/etc/ssh/sshd_config.d}"/*.conf; then
    log_warn "sshd has Match blocks: verified for $DEFAULT_USER and root from an outside address only; review other Match conditions by hand"
  fi

  local mismatches=0 ctx label effective pair key want got ctx_ok
  for ctx in "" "$(ssh_check_context "$DEFAULT_USER")" "$(ssh_check_context root)"; do
    label="${ctx:+ for ${ctx%%,*}}"
    if [[ -n "$ctx" ]]; then
      effective="$(sshd -T -C "$ctx" 2>/dev/null)" || effective=""
    else
      effective="$(sshd -T 2>/dev/null)" || effective=""
    fi
    if [[ -z "$effective" ]]; then
      log_status "failed" "run_ssh_hardening" "sshd -T failed${label}; cannot verify effective config"
      mismatches=$((mismatches + 1))
      continue
    fi

    ctx_ok=true
    for pair in "$@"; do
      key="${pair%%=*}"
      want="$(sshd_effective_value "$key" "${pair#*=}")"
      got="$(awk -v k="${key,,}" '$1 == k { print $2; exit }' <<<"$effective")"
      [[ "$got" == "$want" ]] && continue
      ctx_ok=false
      if is_plan_mode; then
        log_status "changed" "run_ssh_hardening" "plan: effective $key${label} is $got, want $want"
      else
        log_status "failed" "run_ssh_hardening" "effective $key${label} is $got, want $want (another sshd file or a Match block overrides it)"
        mismatches=$((mismatches + 1))
      fi
    done
    if [[ "$ctx_ok" == "true" ]]; then
      log_status "ok" "run_ssh_hardening" "effective sshd config matches${label:- (global)}"
    fi
  done
  [[ "$mismatches" -eq 0 ]]
}

run_ssh_hardening() {
  log_info "Running task: ssh_hardening"
  local changed=false

  local root_login password_auth
  root_login="$(normalize_bool_to_ssh "${SSH_PERMIT_ROOT_LOGIN:-no}")"
  password_auth="$(normalize_bool_to_ssh "${SSH_PASSWORD_AUTH:-no}")"
  local options=(
    "Port=${SSH_PORT:-22}"
    "PermitRootLogin=$root_login"
    "PasswordAuthentication=$password_auth"
    "X11Forwarding=$(normalize_bool_to_ssh "${SSH_X11_FORWARDING:-no}")"
    "MaxAuthTries=${SSH_MAX_AUTH_TRIES:-3}"
    "KbdInteractiveAuthentication=$(normalize_bool_to_ssh "${SSH_KBD_INTERACTIVE_AUTH:-no}")"
  )

  local pair
  for pair in "${options[@]}"; do
    if ! ssh_option_value_valid "${pair%%=*}" "${pair#*=}"; then
      log_status "failed" "run_ssh_hardening" "no changes made: invalid value '${pair#*=}' for ${pair%%=*}"
      return 1
    fi
  done

  if [[ "$password_auth" == "no" && ! -s "/home/$DEFAULT_USER/.ssh/authorized_keys" ]]; then
    log_status "failed" "run_ssh_hardening" "no changes made: /home/$DEFAULT_USER/.ssh/authorized_keys is empty, disabling password login would lock out $DEFAULT_USER"
    return 1
  fi

  local root_keys="${SSH_ROOT_AUTHORIZED_KEYS:-/root/.ssh/authorized_keys}"
  if [[ "$root_login" == "no" && -s "$root_keys" ]]; then
    local current_root
    current_root="$(sshd -T -C "$(ssh_check_context root)" 2>/dev/null | awk '$1 == "permitrootlogin" { print $2; exit }')"
    if [[ "$current_root" != "no" ]]; then
      log_status "failed" "run_ssh_hardening" "no changes made: root has keys in $root_keys and can log in with them now (permitrootlogin ${current_root:-unknown}); set SSH_PERMIT_ROOT_LOGIN: prohibit-password in hosts/<profile>.local.yml if they are needed (e.g. Forge), or remove them"
      return 1
    fi
  fi

  backup_file_if_exists "/etc/ssh/sshd_config"
  backup_file_if_exists "${SSH_DROPIN_DIR:-/etc/ssh/sshd_config.d}/00-provision.conf"

  local snapshot=""
  if ! snapshot="$(mktemp -d)" || ! ssh_snapshot_dropins "$snapshot"; then
    [[ -n "$snapshot" ]] && rm -rf -- "$snapshot"
    log_status "failed" "run_ssh_hardening" "no changes made: could not snapshot the current sshd drop-ins"
    return 1
  fi

  local expected=() failure=""
  for pair in "${options[@]}"; do
    ensure_sshd_option "${pair%%=*}" "${pair#*=}"
    case "$ENSURE_LAST_STATUS" in
      changed) changed=true ;;
      failed) failure="could not set ${pair%%=*}"; break ;;
    esac
    [[ "${pair%%=*}" == "Port" ]] || expected+=("$pair")
  done

  if [[ -z "$failure" ]]; then
    remove_legacy_ssh_dropins
    [[ "$SSH_LEGACY_REMOVED" == "true" ]] && changed=true
    if [[ "$changed" == "true" ]] && ! is_plan_mode && ! sshd -t; then
      failure="sshd -t rejected the new config"
    fi
  fi

  if [[ -z "$failure" ]] && ! verify_sshd_effective "${expected[@]}"; then
    failure="effective config does not match"
  fi

  if [[ -n "$failure" ]]; then
    if is_plan_mode; then
      rm -rf -- "$snapshot"
      log_status "failed" "run_ssh_hardening" "$failure"
    elif ssh_restore_dropins "$snapshot"; then
      rm -rf -- "$snapshot"
      log_status "failed" "run_ssh_hardening" "$failure; previous sshd drop-ins restored, ssh not restarted"
    else
      log_status "failed" "run_ssh_hardening" "$failure; RESTORE FAILED, ssh not restarted; the previous drop-ins are kept in $snapshot (list: $snapshot/.present), copy them back to ${SSH_DROPIN_DIR:-/etc/ssh/sshd_config.d} before any ssh restart or reboot"
    fi
    return 1
  fi

  rm -rf -- "$snapshot"
  ensure_service_restarted_if_changed ssh "$changed"
}
