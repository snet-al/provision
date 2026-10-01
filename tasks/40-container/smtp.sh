#!/bin/bash

# Send-only SMTP relay (Postfix + OpenDKIM) for the docker host.
# Image is built from docker/smtp; apps reach it as smtp:25 on the
# SMTP_NETWORK docker network (attach compose stacks to it as external).

SMTP_SOURCE_LABEL="provision.smtp.source"
SMTP_ENV_LABEL="provision.smtp.env"
SMTP_DOMAIN_PATTERN='^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$'

smtp_hash_dir() {
  local dir="$1"
  (cd "$dir" && find . -type f | LC_ALL=C sort | xargs sha256sum) | sha256sum | cut -c1-16
}

smtp_hash_string() {
  printf '%s' "$1" | sha256sum | cut -c1-16
}

smtp_is_valid_domain() {
  [[ "$1" =~ $SMTP_DOMAIN_PATTERN ]]
}

smtp_domain_from_hostname() {
  local domain
  domain="$(hostname -d 2>/dev/null || true)"
  # Only trust a real FQDN domain; "localdomain" and friends are not one.
  if [[ "$domain" == *.* ]] && smtp_is_valid_domain "$domain"; then
    echo "$domain"
  fi
}

# Prints the chosen domain, or nothing when the answer is empty (caller skips).
# stdout is captured by the caller, so everything else goes to stderr.
smtp_prompt_domain() {
  local default="$1"
  local domain=""
  local hint="empty = skip"
  [[ -n "$default" ]] && hint="$default"
  while true; do
    echo >&2
    read -rp "SMTP sender domain (mail leaves this host as *@domain) [$hint]: " domain || return 0
    domain="${domain:-$default}"
    [[ -z "$domain" ]] && return 0
    if smtp_is_valid_domain "$domain"; then
      echo "$domain"
      return 0
    fi
    echo "Invalid domain: $domain" >&2
  done
}

# Sets SMTP_DOMAIN; leaves it empty when none is configured.
smtp_resolve_domain() {
  local domain="${SMTP_DOMAIN:-}"
  if [[ -z "$domain" && "${PROVISION_NON_INTERACTIVE:-false}" != "true" ]]; then
    # The host's own domain is only offered as a default: it is often not the sender domain.
    domain="$(smtp_prompt_domain "$(smtp_domain_from_hostname)")"
  fi
  if [[ -n "$domain" ]] && ! smtp_is_valid_domain "$domain"; then
    log_status "failed" "run_smtp" "invalid SMTP_DOMAIN: $domain"
    return 1
  fi
  SMTP_DOMAIN="$domain"
}

smtp_render_env() {
  cat <<ENV
SMTP_DOMAIN=${SMTP_DOMAIN}
SMTP_HOSTNAME=${SMTP_HOSTNAME:-mail.${SMTP_DOMAIN}}
SMTP_ALLOWED_SENDER_DOMAINS=${SMTP_ALLOWED_SENDER_DOMAINS:-${SMTP_DOMAIN}}
SMTP_ALLOWED_NETWORKS=${SMTP_ALLOWED_NETWORKS:-127.0.0.0/8 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16}
SMTP_DKIM_SELECTOR=${SMTP_DKIM_SELECTOR:-mail}
SMTP_DKIM_BITS=${SMTP_DKIM_BITS:-2048}
SMTP_MESSAGE_SIZE_LIMIT=${SMTP_MESSAGE_SIZE_LIMIT:-26214400}
SMTP_RELAY_HOST=${SMTP_RELAY_HOST:-}
SMTP_RELAY_PORT=${SMTP_RELAY_PORT:-587}
SMTP_RELAY_USER=${SMTP_RELAY_USER:-}
SMTP_RELAY_PASSWORD=${SMTP_RELAY_PASSWORD:-}
SMTP_RELAY_TLS=${SMTP_RELAY_TLS:-true}
SMTP_DMARC_POLICY=${SMTP_DMARC_POLICY:-quarantine}
SMTP_DMARC_RUA=${SMTP_DMARC_RUA:-postmaster@${SMTP_DOMAIN}}
ENV
}

smtp_ensure_env_file() {
  local file="$1"
  local desired="$2"
  local current=""
  [[ -f "$file" ]] && current="$(cat "$file")"
  if [[ "$current" == "$desired" ]]; then
    ensure_file_mode "$file" 600
    log_status "ok" "run_smtp" "env file $file up to date"
    return 0
  fi
  if is_plan_mode; then
    log_status "changed" "run_smtp" "plan: would write $file"
    return 0
  fi
  mkdir -p "$(dirname "$file")"
  (umask 077 && printf '%s\n' "$desired" > "$file")
  chmod 600 "$file"
  log_status "changed" "run_smtp" "wrote $file"
}

smtp_ensure_volume() {
  local volume="$1"
  if docker volume ls --format '{{.Name}}' | grep -Fx "$volume" >/dev/null 2>&1; then
    log_status "ok" "run_smtp" "volume $volume exists"
  elif is_plan_mode; then
    log_status "changed" "run_smtp" "plan: would create volume $volume"
  else
    docker volume create "$volume" >/dev/null
    log_status "changed" "run_smtp" "created volume $volume"
  fi
}

smtp_ensure_network() {
  local network="$1"
  if docker network ls --format '{{.Name}}' | grep -Fx "$network" >/dev/null 2>&1; then
    log_status "ok" "run_smtp" "network $network exists"
  elif is_plan_mode; then
    log_status "changed" "run_smtp" "plan: would create network $network"
  else
    docker network create --driver bridge --attachable "$network" >/dev/null
    log_status "changed" "run_smtp" "created network $network"
  fi
}

smtp_ensure_image() {
  local image="$1"
  local source_dir="$2"
  local source_hash="$3"
  local current_hash
  local build_flags=()
  current_hash="$(docker image inspect --format "{{index .Config.Labels \"$SMTP_SOURCE_LABEL\"}}" "$image" 2>/dev/null || true)"
  if [[ "${SMTP_REBUILD_IMAGE:-false}" =~ ^(true|yes|1)$ ]]; then
    # Unchanged sources never rebuild, so this is the only way to pick up base image and apk patches.
    build_flags=(--pull --no-cache)
  elif [[ "$current_hash" == "$source_hash" ]]; then
    log_status "ok" "run_smtp" "image $image up to date"
    return 0
  fi
  if is_plan_mode; then
    log_status "changed" "run_smtp" "plan: would build $image from $source_dir"
    return 0
  fi
  if docker build "${build_flags[@]}" --label "$SMTP_SOURCE_LABEL=$source_hash" -t "$image" "$source_dir" >>"$LOG_FILE" 2>&1; then
    log_status "changed" "run_smtp" "built $image"
  else
    log_status "failed" "run_smtp" "docker build failed for $image (see $LOG_FILE)"
    return 1
  fi
}

# Prints one drift reason per line; empty output means the container matches.
smtp_container_drift() {
  local name="$1" image="$2" env_hash="$3" network="$4"
  local spool_volume="$5" dkim_volume="$6" host_bind="$7" host_port="$8"
  local desired_image_id current_image_id
  desired_image_id="$(docker image inspect --format '{{.Id}}' "$image" 2>/dev/null || true)"
  current_image_id="$(docker inspect --format '{{.Image}}' "$name" 2>/dev/null || true)"
  [[ -n "$desired_image_id" && "$current_image_id" != "$desired_image_id" ]] && echo "image changed"

  [[ "$(docker inspect --format '{{.HostConfig.RestartPolicy.Name}}' "$name" 2>/dev/null)" != "unless-stopped" ]] && echo "restart policy"
  [[ "$(docker inspect --format "{{index .Config.Labels \"$SMTP_ENV_LABEL\"}}" "$name" 2>/dev/null)" != "$env_hash" ]] && echo "env file"

  docker inspect --format '{{range $k, $_ := .NetworkSettings.Networks}}{{$k}}{{"\n"}}{{end}}' "$name" 2>/dev/null \
    | grep -Fx "$network" >/dev/null 2>&1 || echo "network $network"

  local mounts ports
  mounts="$(docker inspect --format '{{json .Mounts}}' "$name" 2>/dev/null || true)"
  printf '%s' "$mounts" | grep -F "\"Name\":\"$spool_volume\"" >/dev/null 2>&1 || echo "spool volume mount"
  printf '%s' "$mounts" | grep -F "\"Name\":\"$dkim_volume\"" >/dev/null 2>&1 || echo "dkim volume mount"

  ports="$(docker inspect --format '{{json .HostConfig.PortBindings}}' "$name" 2>/dev/null || true)"
  if [[ -n "$host_port" ]]; then
    printf '%s' "$ports" | grep -F "\"25/tcp\":[{\"HostIp\":\"$host_bind\",\"HostPort\":\"$host_port\"}]" >/dev/null 2>&1 || echo "port binding"
  else
    printf '%s' "$ports" | grep -F '"25/tcp"' >/dev/null 2>&1 && echo "port binding (should not be published)"
  fi
  return 0
}

smtp_run_container() {
  local name="$1" image="$2" env_file="$3" env_hash="$4" network="$5"
  local spool_volume="$6" dkim_volume="$7" host_bind="$8" host_port="$9" hostname="${10}"
  local publish=()
  [[ -n "$host_port" ]] && publish=(-p "$host_bind:$host_port:25")
  docker run -d --name "$name" --hostname "$hostname" --restart unless-stopped \
    --label "$SMTP_ENV_LABEL=$env_hash" \
    --network "$network" --network-alias smtp \
    --env-file "$env_file" \
    -v "$spool_volume:/var/spool/postfix" \
    -v "$dkim_volume:/etc/opendkim/keys" \
    "${publish[@]}" \
    "$image" >/dev/null
}

smtp_is_running() {
  [[ "$(docker inspect --format '{{.State.Running}} {{.State.Restarting}}' "$1" 2>/dev/null)" == "true false" ]]
}

smtp_write_dns_records() {
  local name="$1"
  local out="$2"
  local wait_sec="${SMTP_DNS_WAIT_SEC:-20}"
  local i
  # Wait for serve() to generate the DKIM key so `dns` does not race it.
  for i in $(seq 1 "$wait_sec"); do
    docker exec "$name" sh -c 'test -f "/etc/opendkim/keys/$SMTP_DOMAIN/$SMTP_DKIM_SELECTOR.private"' >/dev/null 2>&1 && break
    sleep 1
  done
  if docker exec "$name" entrypoint.sh dns > "$out.tmp" 2>/dev/null; then
    mv "$out.tmp" "$out"
    chmod 644 "$out"
    log_status "ok" "run_smtp" "DNS records to publish written to $out"
  else
    rm -f "$out.tmp"
    log_status "skipped" "run_smtp" "could not read DNS records yet; run: docker exec $name entrypoint.sh dns"
  fi
}

run_smtp() {
  log_info "Running task: smtp"
  if [[ "${ENABLE_SMTP:-true}" =~ ^(false|no|0)$ ]]; then
    log_status "skipped" "run_smtp" "disabled by config"
    return 0
  fi

  if ! command -v docker >/dev/null 2>&1; then
    log_status "failed" "run_smtp" "docker is required"
    return 1
  fi

  smtp_resolve_domain || return 1
  if [[ -z "$SMTP_DOMAIN" ]]; then
    log_status "skipped" "run_smtp" "SMTP_DOMAIN not set (set env.SMTP_DOMAIN in hosts/docker_host.local.yml to enable)"
    return 0
  fi

  local name="${SMTP_CONTAINER_NAME:-smtp}"
  local image="${SMTP_IMAGE:-provision/smtp:latest}"
  local network="${SMTP_NETWORK:-smtp}"
  local spool_volume="${SMTP_SPOOL_VOLUME:-smtp_spool}"
  local dkim_volume="${SMTP_DKIM_VOLUME:-smtp_dkim}"
  local host_port="${SMTP_HOST_PORT:-}"
  local host_bind="${SMTP_HOST_BIND:-127.0.0.1}"
  local env_file="${SMTP_ENV_FILE:-/etc/provision/smtp.env}"
  local source_dir="${SMTP_SOURCE_DIR:-$PROVISION_ROOT/docker/smtp}"

  if [[ ! -f "$source_dir/Dockerfile" ]]; then
    log_status "failed" "run_smtp" "missing $source_dir/Dockerfile"
    return 1
  fi

  local env_content env_hash source_hash
  env_content="$(smtp_render_env)"
  env_hash="$(smtp_hash_string "$env_content")"
  source_hash="$(smtp_hash_dir "$source_dir")"

  smtp_ensure_env_file "$env_file" "$env_content"
  smtp_ensure_volume "$spool_volume"
  smtp_ensure_volume "$dkim_volume"
  smtp_ensure_network "$network"
  smtp_ensure_image "$image" "$source_dir" "$source_hash" || return 1

  local container_exists=false
  if docker ps -a --format '{{.Names}}' | grep -Fx "$name" >/dev/null 2>&1; then
    container_exists=true
  fi

  local drift=""
  if [[ "$container_exists" == "true" ]]; then
    drift="$(smtp_container_drift "$name" "$image" "$env_hash" "$network" "$spool_volume" "$dkim_volume" "$host_bind" "$host_port")"
    if [[ -z "$drift" ]]; then
      if [[ "$(docker inspect --format '{{.State.Running}}' "$name" 2>/dev/null)" == "true" ]]; then
        log_status "ok" "run_smtp" "container $name already running with desired config"
      elif is_plan_mode; then
        log_status "changed" "run_smtp" "plan: would start stopped container $name"
      elif docker start "$name" >/dev/null; then
        log_status "changed" "run_smtp" "started existing container $name"
      else
        log_status "failed" "run_smtp" "docker start failed for $name"
        return 1
      fi
      return 0
    fi
    log_status "changed" "run_smtp" "drift detected: $(printf '%s' "$drift" | paste -sd, -)"
  fi

  if is_plan_mode; then
    if [[ "$container_exists" == "true" ]]; then
      log_status "changed" "run_smtp" "plan: would recreate $name"
    else
      log_status "changed" "run_smtp" "plan: would run $name container"
    fi
    return 0
  fi

  if [[ "$container_exists" == "true" ]]; then
    docker rm -f "$name" >/dev/null 2>&1 || true
  fi
  local hostname
  hostname="$(printf '%s' "$env_content" | awk -F= '$1=="SMTP_HOSTNAME"{print $2}')"
  if ! smtp_run_container "$name" "$image" "$env_file" "$env_hash" "$network" \
    "$spool_volume" "$dkim_volume" "$host_bind" "$host_port" "$hostname"; then
    log_status "failed" "run_smtp" "docker run failed for $name"
    return 1
  fi
  smtp_write_dns_records "$name" "${env_file%/*}/smtp-dns.txt"
  if ! smtp_is_running "$name"; then
    log_status "failed" "run_smtp" "container $name is not running (see: docker logs $name)"
    return 1
  fi
  if [[ "$container_exists" == "true" ]]; then
    log_status "changed" "run_smtp" "recreated $name with desired config"
  else
    log_status "changed" "run_smtp" "started $name"
  fi
}
