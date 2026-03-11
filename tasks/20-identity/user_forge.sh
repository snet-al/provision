#!/bin/bash

run_user_forge() {
  log_info "Running task: user_forge"
  ensure_user "$DEFAULT_USER"
  ensure_group_exists sudo
  ensure_user_in_group "$DEFAULT_USER" sudo
  ensure_directory "/home/$DEFAULT_USER/.ssh" "700" "$DEFAULT_USER:$DEFAULT_USER"

  local auth_file="/home/$DEFAULT_USER/.ssh/authorized_keys"
  if [[ "${#USER_SSH_KEYS[@]}" -eq 0 ]]; then
    log_status "skipped" "run_user_forge" "no ssh keys provided"
  else
    ensure_directory "/home/$DEFAULT_USER/.ssh" "700" "$DEFAULT_USER:$DEFAULT_USER"
    touch "$auth_file"
    chown "$DEFAULT_USER:$DEFAULT_USER" "$auth_file"
    chmod 600 "$auth_file"
    local key
    for key in "${USER_SSH_KEYS[@]}"; do
      ensure_line_in_file "$auth_file" "$key"
    done
  fi
}
