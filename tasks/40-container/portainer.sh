#!/bin/bash

run_portainer() {
  log_info "Running task: portainer"
  if [[ "${ENABLE_PORTAINER:-true}" =~ ^(false|no|0)$ ]]; then
    log_status "skipped" "run_portainer" "disabled by config"
    return 0
  fi

  if ! command -v docker >/dev/null 2>&1; then
    log_status "failed" "run_portainer" "docker is required"
    return 1
  fi

  local volume="${PORTAINER_VOLUME_NAME:-portainer_data}"
  local name="${PORTAINER_CONTAINER_NAME:-portainer}"
  local image="${PORTAINER_IMAGE:-portainer/portainer-ce:latest}"
  local http_port="${PORTAINER_HTTP_PORT:-9000}"
  local https_port="${PORTAINER_HTTPS_PORT:-9443}"
  local pull_image="${PORTAINER_PULL_IMAGE:-false}"

  if docker volume ls --format '{{.Name}}' | grep -Fx "$volume" >/dev/null 2>&1; then
    log_status "ok" "run_portainer" "volume $volume exists"
  elif is_plan_mode; then
    log_status "changed" "run_portainer" "plan: would create volume $volume"
  else
    docker volume create "$volume" >/dev/null
    log_status "changed" "run_portainer" "created volume $volume"
  fi

  local container_exists=false
  if docker ps -a --format '{{.Names}}' | grep -Fx "$name" >/dev/null 2>&1; then
    container_exists=true
  fi

  local needs_recreate=false
  local desired_image_id=""
  if [[ "$pull_image" =~ ^(true|yes|1)$ ]]; then
    if is_plan_mode; then
      log_status "changed" "run_portainer" "plan: would pull $image"
    else
      docker pull "$image" >/dev/null
      log_status "changed" "run_portainer" "pulled image $image"
    fi
  fi

  if [[ "$container_exists" == "true" ]]; then
    local current_image current_image_id restart_policy running_state
    current_image="$(docker inspect --format '{{.Config.Image}}' "$name" 2>/dev/null || true)"
    current_image_id="$(docker inspect --format '{{.Image}}' "$name" 2>/dev/null || true)"
    restart_policy="$(docker inspect --format '{{.HostConfig.RestartPolicy.Name}}' "$name" 2>/dev/null || true)"
    running_state="$(docker inspect --format '{{.State.Running}}' "$name" 2>/dev/null || true)"

    if [[ "$current_image" != "$image" ]]; then
      needs_recreate=true
      log_status "changed" "run_portainer" "image drift detected ($current_image != $image)"
    fi

    if [[ "$restart_policy" != "unless-stopped" ]]; then
      needs_recreate=true
      log_status "changed" "run_portainer" "restart policy drift detected"
    fi

    if ! docker inspect --format '{{json .HostConfig.PortBindings}}' "$name" | grep -F "\"9000/tcp\":[{\"HostIp\":\"\",\"HostPort\":\"$http_port\"}]" >/dev/null 2>&1; then
      needs_recreate=true
      log_status "changed" "run_portainer" "HTTP port binding drift detected"
    fi

    if ! docker inspect --format '{{json .HostConfig.PortBindings}}' "$name" | grep -F "\"9443/tcp\":[{\"HostIp\":\"\",\"HostPort\":\"$https_port\"}]" >/dev/null 2>&1; then
      needs_recreate=true
      log_status "changed" "run_portainer" "HTTPS port binding drift detected"
    fi

    if ! docker inspect --format '{{json .Mounts}}' "$name" | grep -F "\"Source\":\"/var/run/docker.sock\"" >/dev/null 2>&1; then
      needs_recreate=true
      log_status "changed" "run_portainer" "docker socket mount drift detected"
    fi

    if ! docker inspect --format '{{json .Mounts}}' "$name" | grep -F "\"Name\":\"$volume\"" >/dev/null 2>&1; then
      needs_recreate=true
      log_status "changed" "run_portainer" "data volume mount drift detected"
    fi

    if [[ "$pull_image" =~ ^(true|yes|1)$ ]]; then
      desired_image_id="$(docker image inspect --format '{{.Id}}' "$image" 2>/dev/null || true)"
      if [[ -n "$desired_image_id" && "$current_image_id" != "$desired_image_id" ]]; then
        needs_recreate=true
        log_status "changed" "run_portainer" "newer image available"
      fi
    fi

    if [[ "$needs_recreate" == "false" ]]; then
      if [[ "$running_state" == "true" ]]; then
        log_status "ok" "run_portainer" "container $name already healthy"
      elif is_plan_mode; then
        log_status "changed" "run_portainer" "plan: would start stopped container $name"
      else
        docker start "$name" >/dev/null
        log_status "changed" "run_portainer" "started existing container $name"
      fi
    fi
  fi

  if [[ "$container_exists" == "false" || "$needs_recreate" == "true" ]]; then
    if is_plan_mode; then
      if [[ "$container_exists" == "true" ]]; then
        log_status "changed" "run_portainer" "plan: would recreate $name"
      else
        log_status "changed" "run_portainer" "plan: would run $name container"
      fi
    else
      if [[ "$container_exists" == "true" ]]; then
        docker rm -f "$name" >/dev/null 2>&1 || true
      fi
      docker run -d --name "$name" --restart unless-stopped \
        -p "$http_port:9000" -p "$https_port:9443" \
        -v /var/run/docker.sock:/var/run/docker.sock \
        -v "$volume:/data" \
        "$image" >/dev/null
      if [[ "$container_exists" == "true" ]]; then
        log_status "changed" "run_portainer" "recreated $name with desired config"
      else
        log_status "changed" "run_portainer" "started $name"
      fi
    fi
  fi
}
