#!/bin/bash

normalize_provision_workspace_permissions() {
  local workspace="/home/$DEFAULT_USER/provision"

  ensure_directory "$workspace" "750" "$DEFAULT_USER:$DEFAULT_USER"

  if is_plan_mode; then
    log_status "changed" "normalize_provision_workspace_permissions" "plan: would normalize ownership and directory modes under $workspace"
    return 0
  fi

  # Preserve Git file modes by only normalizing ownership recursively and
  # tightening directory permissions. Avoid recursive chmod on regular files.
  chown -R "$DEFAULT_USER:$DEFAULT_USER" "$workspace"
  find "$workspace" -type d -exec chmod 750 {} +

  log_status "ok" "normalize_provision_workspace_permissions" "workspace ownership and directory permissions normalized"
}

run_post_setup() {
  log_info "Running task: post_setup"
  normalize_provision_workspace_permissions
  log_status "ok" "run_post_setup" "post-setup workspace permissions ensured without changing tracked file modes"
}
