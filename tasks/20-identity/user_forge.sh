#!/bin/bash

is_valid_ssh_public_key() {
  local key="$1"
  [[ "$key" =~ ^(ssh-rsa|ssh-ed25519|ecdsa-sha2-nistp256|ecdsa-sha2-nistp384|ecdsa-sha2-nistp521)[[:space:]]+[A-Za-z0-9+/=]+([[:space:]].*)?$ ]]
}

ensure_authorized_keys_file() {
  local auth_file="/home/$DEFAULT_USER/.ssh/authorized_keys"
  touch "$auth_file"
  chown "$DEFAULT_USER:$DEFAULT_USER" "$auth_file"
  chmod 600 "$auth_file"
}

ensure_forge_workspace_ready() {
  log_info "Preparing forge workspace prerequisites for $DEFAULT_USER"
  ensure_user "$DEFAULT_USER"
  ensure_group_exists sudo
  ensure_user_in_group "$DEFAULT_USER" sudo
  ensure_directory "/home/$DEFAULT_USER/.ssh" "700" "$DEFAULT_USER:$DEFAULT_USER"
}

prompt_forge_ssh_key_if_needed() {
  local auth_file="/home/$DEFAULT_USER/.ssh/authorized_keys"
  local add_key_choice=""
  local ssh_key=""

  if [[ -s "$auth_file" ]]; then
    log_status "ok" "prompt_forge_ssh_key_if_needed" "authorized_keys already present for $DEFAULT_USER"
    return 0
  fi

  if [[ "${PROVISION_NON_INTERACTIVE:-false}" == "true" ]]; then
    log_status "skipped" "prompt_forge_ssh_key_if_needed" "non-interactive mode and no ssh keys provided for $DEFAULT_USER"
    return 0
  fi

  echo
  read -r -p "No SSH keys were provided for $DEFAULT_USER. Add one now to preserve login access? (Y/n): " add_key_choice
  if [[ "${add_key_choice:-y}" =~ ^[Nn]$ ]]; then
    log_status "skipped" "prompt_forge_ssh_key_if_needed" "operator chose not to add an ssh key for $DEFAULT_USER"
    return 0
  fi

  while true; do
    read -r -p "Paste SSH public key for $DEFAULT_USER: " ssh_key
    if [[ -z "$ssh_key" ]]; then
      echo "SSH public key cannot be empty."
      continue
    fi
    if ! is_valid_ssh_public_key "$ssh_key"; then
      echo "Invalid SSH public key format. Expected ssh-ed25519, ssh-rsa, or ecdsa-sha2-* key."
      continue
    fi
    ensure_authorized_keys_file
    ensure_line_in_file "$auth_file" "$ssh_key"
    log_status "changed" "prompt_forge_ssh_key_if_needed" "added ssh key for $DEFAULT_USER"
    return 0
  done
}

run_user_forge() {
  log_info "Running task: user_forge"
  ensure_user "$DEFAULT_USER"
  ensure_group_exists sudo
  ensure_user_in_group "$DEFAULT_USER" sudo
  ensure_directory "/home/$DEFAULT_USER/.ssh" "700" "$DEFAULT_USER:$DEFAULT_USER"

  local auth_file="/home/$DEFAULT_USER/.ssh/authorized_keys"
  if [[ "${#USER_SSH_KEYS[@]}" -eq 0 ]]; then
    log_status "skipped" "run_user_forge" "no ssh keys provided via config"
    prompt_forge_ssh_key_if_needed
  else
    ensure_directory "/home/$DEFAULT_USER/.ssh" "700" "$DEFAULT_USER:$DEFAULT_USER"
    ensure_authorized_keys_file
    local key
    for key in "${USER_SSH_KEYS[@]}"; do
      ensure_line_in_file "$auth_file" "$key"
    done
  fi
}
