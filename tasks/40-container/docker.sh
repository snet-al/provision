#!/bin/bash

run_docker() {
  log_info "Running task: docker"
  if [[ "${ENABLE_DOCKER:-true}" =~ ^(false|no|0)$ ]]; then
    log_status "skipped" "run_docker" "disabled by config"
    return 0
  fi

  ensure_package ca-certificates
  ensure_package curl
  ensure_package gnupg

  ensure_directory /etc/apt/keyrings 755

  local docker_key="/etc/apt/keyrings/docker.asc"
  if [[ ! -f "$docker_key" ]]; then
    if is_plan_mode; then
      log_status "changed" "run_docker" "plan: would download docker gpg key"
    else
      curl -fsSL "${DOCKER_GPG_URL:-https://download.docker.com/linux/ubuntu/gpg}" -o "$docker_key"
      chmod a+r "$docker_key"
      log_status "changed" "run_docker" "docker gpg key installed"
    fi
  else
    log_status "ok" "run_docker" "docker gpg key exists"
  fi

  local repo_line
  repo_line="deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo \"$VERSION_CODENAME\") stable"
  ensure_apt_repo docker "$repo_line"

  ensure_package docker-ce
  ensure_package docker-ce-cli
  ensure_package containerd.io
  ensure_package docker-buildx-plugin
  ensure_package docker-compose-plugin

  ensure_group_exists docker
  ensure_user_in_group "$DEFAULT_USER" docker
  ensure_service_enabled docker
  ensure_service_running docker
}
