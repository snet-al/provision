#!/bin/bash

provision_servers_repo_dir() {
  echo "${PROVISION_SERVERS_DIR:-/home/$DEFAULT_USER/provision/provision-servers}"
}

provision_servers_repo_url() {
  echo "${PROVISION_SERVERS_REPO_URL:-git@github.com:snet-al/provision-servers.git}"
}

provision_servers_profile_folder() {
  case "${1:-}" in
    agents) echo "agents" ;;
    multi_deployment) echo "deployment" ;;
    *) echo "" ;;
  esac
}

provision_servers_key_file() {
  echo "/home/$DEFAULT_USER/.ssh/id_ed25519"
}

show_provision_servers_pubkey() {
  local pub_file
  pub_file="$(provision_servers_key_file).pub"
  if [[ -f "$pub_file" ]]; then
    echo "--------------------------------------------"
    sudo -u "$DEFAULT_USER" cat "$pub_file"
    echo "--------------------------------------------"
  fi
}

ensure_provision_servers_repo_access() {
  local ssh_dir="/home/$DEFAULT_USER/.ssh"
  local key_file
  local pub_file
  local known_hosts

  key_file="$(provision_servers_key_file)"
  pub_file="${key_file}.pub"
  known_hosts="$ssh_dir/known_hosts"

  log_info "Preparing '$DEFAULT_USER' SSH key for provision-servers access"
  ensure_directory "$ssh_dir" "700" "$DEFAULT_USER:$DEFAULT_USER"

  if [[ ! -f "$pub_file" ]]; then
    if is_plan_mode; then
      log_status "changed" "ensure_provision_servers_repo_access" "plan: would generate SSH key for $DEFAULT_USER"
    else
      if ! sudo -u "$DEFAULT_USER" ssh-keygen -t ed25519 -N "" -f "$key_file" >/dev/null; then
        log_status "failed" "ensure_provision_servers_repo_access" "failed to generate SSH key for $DEFAULT_USER"
        return 1
      fi
      log_status "changed" "ensure_provision_servers_repo_access" "generated SSH key for $DEFAULT_USER"
    fi
  else
    log_status "ok" "ensure_provision_servers_repo_access" "SSH key already present for $DEFAULT_USER"
  fi

  if is_plan_mode; then
    log_status "changed" "ensure_provision_servers_repo_access" "plan: would ensure github.com known_hosts entry"
    return 0
  fi

  sudo -u "$DEFAULT_USER" touch "$known_hosts"
  chown "$DEFAULT_USER:$DEFAULT_USER" "$known_hosts"
  chmod 644 "$known_hosts" || true

  if sudo -u "$DEFAULT_USER" ssh-keygen -F github.com -f "$known_hosts" >/dev/null 2>&1; then
    log_status "ok" "ensure_provision_servers_repo_access" "github.com already present in known_hosts"
    return 0
  fi

  if sudo -u "$DEFAULT_USER" sh -c "ssh-keyscan github.com >> '$known_hosts' 2>/dev/null"; then
    log_status "changed" "ensure_provision_servers_repo_access" "added github.com to known_hosts"
  else
    log_status "failed" "ensure_provision_servers_repo_access" "failed to add github.com to known_hosts"
    return 1
  fi
}

sync_provision_servers_repo_once() {
  local repo_dir
  local repo_url

  repo_dir="$(provision_servers_repo_dir)"
  repo_url="$(provision_servers_repo_url)"

  ensure_directory "$(dirname "$repo_dir")" "750" "$DEFAULT_USER:$DEFAULT_USER"

  if is_plan_mode; then
    if [[ -d "$repo_dir/.git" ]]; then
      log_status "changed" "sync_provision_servers_repo" "plan: would pull latest changes in $repo_dir"
    else
      log_status "changed" "sync_provision_servers_repo" "plan: would clone $repo_url into $repo_dir"
    fi
    return 0
  fi

  if [[ -d "$repo_dir/.git" ]]; then
    if sudo -u "$DEFAULT_USER" git -C "$repo_dir" pull --rebase --autostash; then
      log_status "ok" "sync_provision_servers_repo" "updated repo at $repo_dir"
      return 0
    fi
    log_warn "Failed to update provision-servers repo at $repo_dir"
    return 1
  fi

  if sudo -u "$DEFAULT_USER" git clone "$repo_url" "$repo_dir"; then
    log_status "changed" "sync_provision_servers_repo" "cloned repo to $repo_dir"
    return 0
  fi

  log_warn "Failed to clone provision-servers repo into $repo_dir"
  return 1
}

prompt_for_provision_servers_access() {
  local repo_url
  repo_url="$(provision_servers_repo_url)"

  log_warn "Grant this SSH key access to $repo_url, then retry"
  show_provision_servers_pubkey
  echo
  read -r -p "Press Enter after repo access is ready..." _
}

sync_provision_servers_repo() {
  while true; do
    if sync_provision_servers_repo_once; then
      return 0
    fi

    if [[ "${PROVISION_NON_INTERACTIVE:-false}" == "true" ]]; then
      log_error "Non-interactive mode cannot wait for manual provision-servers repo access"
      show_provision_servers_pubkey
      log_status "failed" "sync_provision_servers_repo" "repo access missing or git sync failed"
      return 1
    fi

    prompt_for_provision_servers_access
  done
}

record_provision_servers_profile() {
  local repo_dir
  local type_file

  repo_dir="$(provision_servers_repo_dir)"
  type_file="$repo_dir/.server_type"

  if is_plan_mode; then
    log_status "changed" "record_provision_servers_profile" "plan: would record profile $PROVISION_PROFILE"
    return 0
  fi

  if sudo -u "$DEFAULT_USER" sh -c "printf '%s\n' '$PROVISION_PROFILE' > '$type_file'"; then
    log_status "changed" "record_provision_servers_profile" "recorded profile in $type_file"
  else
    log_status "failed" "record_provision_servers_profile" "failed to write $type_file"
    return 1
  fi
}

run_provision_servers_setup() {
  local repo_dir
  local folder
  local setup_script

  repo_dir="$(provision_servers_repo_dir)"
  folder="$(provision_servers_profile_folder "$PROVISION_PROFILE")"

  if [[ -z "$folder" ]]; then
    log_status "skipped" "run_provision_servers_setup" "no provision-servers mapping for profile $PROVISION_PROFILE"
    return 0
  fi

  setup_script="$repo_dir/$folder/setup.sh"
  if [[ ! -f "$setup_script" ]]; then
    log_status "skipped" "run_provision_servers_setup" "missing setup script at $setup_script"
    return 0
  fi

  if is_plan_mode; then
    log_status "changed" "run_provision_servers_setup" "plan: would run $setup_script $PROVISION_PROFILE"
    return 0
  fi

  if sudo -u "$DEFAULT_USER" bash "$setup_script" "$PROVISION_PROFILE"; then
    log_status "ok" "run_provision_servers_setup" "executed $setup_script"
  else
    log_status "failed" "run_provision_servers_setup" "private setup script failed"
    return 1
  fi
}

run_provision_servers_extension() {
  log_info "Running task: provision_servers_extension"

  case "${PROVISION_PROFILE:-}" in
    basic|docker_host)
      log_status "skipped" "run_provision_servers_extension" "profile $PROVISION_PROFILE does not use provision-servers"
      return 0
      ;;
  esac

  ensure_provision_servers_repo_access
  sync_provision_servers_repo
  record_provision_servers_profile
  run_provision_servers_setup
}
