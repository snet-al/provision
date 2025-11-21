#!/bin/bash

# Deployment script for a single repository
# Checks for Dockerfile.pf, builds and runs container, configures nginx

set -euo pipefail

# Configuration
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly LOG_FILE="/home/forge/deployment/logs/deployment.log"
readonly NETWORK_NAME="deployment-network"
readonly NGINX_CONTAINER_NAME="deployment-nginx"
readonly NGINX_CONFIG_DIR="/home/forge/deployment/nginx-configs"
readonly DOMAIN_SUFFIX="datafynow.ai"
readonly DEFAULT_PORT="8080"
readonly LOCK_DIR="/tmp/deployment-locks"
DEPLOY_LOCK_FD=""
readonly VITE_CONFIG_TS="vite.config.ts"
readonly VITE_CONFIG_JS="vite.config.js"

# Ensure log file is accessible
ensure_log_file() {
    local log_dir=$(dirname "$LOG_FILE")
    mkdir -p "$log_dir"
    if [[ ! -f "$LOG_FILE" ]]; then
        touch "$LOG_FILE"
        chmod 644 "$LOG_FILE"
    fi
}

# Logging functions
log() {
    ensure_log_file
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] DEPLOY: $1" | tee -a "$LOG_FILE" > /dev/null
    echo "DEPLOY: $1"
}

log_error() {
    ensure_log_file
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] DEPLOY ERROR: $1" | tee -a "$LOG_FILE" > /dev/null
    echo "DEPLOY ERROR: $1" >&2
}

# Deployment locking helpers
ensure_lock_dir() {
    mkdir -p "$LOCK_DIR"
}

acquire_deploy_lock() {
    local lock_name="$1"
    ensure_lock_dir
    local lock_file="$LOCK_DIR/${lock_name}.lock"
    exec {DEPLOY_LOCK_FD}> "$lock_file"
    if ! flock -n "$DEPLOY_LOCK_FD"; then
        log "Another deployment is already running for: $lock_name. Skipping."
        exit 0
    fi
}

release_deploy_lock() {
    if [[ -n "${DEPLOY_LOCK_FD:-}" ]]; then
        flock -u "$DEPLOY_LOCK_FD" 2>/dev/null || true
        exec {DEPLOY_LOCK_FD}>&-
        DEPLOY_LOCK_FD=""
    fi
}

# Detect and patch Vite config to allow nginx upstream hostnames
patch_vite_config() {
    local repo_path="$1"
    local port="$2"
    local config_file=""

    if [[ -f "$repo_path/$VITE_CONFIG_TS" ]]; then
        config_file="$repo_path/$VITE_CONFIG_TS"
    elif [[ -f "$repo_path/$VITE_CONFIG_JS" ]]; then
        config_file="$repo_path/$VITE_CONFIG_JS"
    else
        return 0
    fi

    local marker="// DEPLOY_ALLOWED_HOSTS_PATCH"
    if grep -q "$marker" "$config_file" 2>/dev/null; then
        log "Vite config already patched: $(basename "$config_file")"
        return 0
    fi
    log "Patching Vite config in-place: $(basename "$config_file")"

    node - "$config_file" "$port" <<'EOF'
const fs = require('fs');
const path = process.argv[2];
const port = parseInt(process.argv[3], 10) || 5173;
const marker = '// DEPLOY_ALLOWED_HOSTS_PATCH';

let source = fs.readFileSync(path, 'utf8');
if (source.includes(marker)) {
  process.exit(0);
}

const exportRegex = /export\s+default\s+/;
if (!exportRegex.test(source)) {
  process.exit(0);
}

source = source.replace(exportRegex, 'const __deploy_user_export = ');

const patch = `
${marker}
const __deploy_toFactory = (config) => {
  if (typeof config === 'function') {
    return config;
  }
  return () => config ?? {};
};

const __deploy_enhanceHosts = (config = {}) => {
  config.server = config.server || {};
  if (!config.server.host) {
    config.server.host = '0.0.0.0';
  }
  if (!config.server.port) {
    config.server.port = ${port};
  }
  if (!config.server.allowedHosts) {
    config.server.allowedHosts = [
      /^app_d[a-zA-Z0-9-]+_dataset\\d+(_upstream)?$/,
      '.datafynow.ai',
      'localhost',
    ];
  }
  return config;
};

const __deploy_config_factory = __deploy_toFactory(__deploy_user_export);

export default async (env) => {
  const resolved = await __deploy_config_factory(env);
  return __deploy_enhanceHosts(resolved);
};
`;

fs.writeFileSync(path, `${source.trimEnd()}\n\n${patch}\n`);
EOF
}

# Validate repo path
validate_repo_path() {
    local repo_path="$1"
    
    if [[ ! -d "$repo_path" ]]; then
        log_error "Repository path does not exist: $repo_path"
        exit 1
    fi

    if [[ ! -r "$repo_path" ]]; then
        log_error "Repository path is not readable: $repo_path"
        exit 1
    fi
}

# Extract userid and datasetid from directory name
extract_ids() {
    local repo_path="$1"
    local dir_name
    dir_name=$(basename "$repo_path")
    
    # Expected format: d_{userId}_dataset{datasetId}[.domain]
    if [[ ! "$dir_name" =~ ^d_([a-zA-Z0-9_-]+)_dataset([a-zA-Z0-9_-]+)(\.[a-zA-Z0-9._-]+)?$ ]]; then
        log_error "Invalid directory name format. Expected: d_{userId}_dataset{datasetId}[.domain], got: $dir_name"
        exit 1
    fi

    USERID="${BASH_REMATCH[1]}"
    DATASETID="${BASH_REMATCH[2]}"
    
    log "Extracted userid: $USERID, datasetid: $DATASETID"
}

# Check for Dockerfile.pf
check_dockerfile() {
    local repo_path="$1"
    local dockerfile_path="$repo_path/Dockerfile.pf"
    
    if [[ ! -f "$dockerfile_path" ]]; then
        log_error "Dockerfile.pf not found in repository: $repo_path"
        log_error "Deployment failed for: $(basename "$repo_path")"
        exit 1
    fi
    
    log "Dockerfile.pf found: $dockerfile_path"
}

# Extract port from Dockerfile (if specified)
extract_port_from_dockerfile() {
    local dockerfile_path="$1"
    local port
    
    # Try to extract EXPOSE directive
    if port=$(grep -i "^EXPOSE" "$dockerfile_path" | head -1 | awk '{print $2}' | tr -d '\r\n'); then
        if [[ -n "$port" ]] && [[ "$port" =~ ^[0-9]+$ ]]; then
            echo "$port"
            return 0
        fi
    fi
    
    # Default port
    echo "$DEFAULT_PORT"
}

# Build Docker image
build_image() {
    local repo_path="$1"
    local image_name="$2"
    
    log "Building Docker image: $image_name"

    # Ensure no stale tag remains from previous builds
    cleanup_image "$image_name"
    
    if docker build --no-cache -t "$image_name" -f "$repo_path/Dockerfile.pf" "$repo_path"; then
        log "Docker image built successfully: $image_name"
    else
        log_error "Failed to build Docker image: $image_name"
        exit 1
    fi
}

# Stop and remove existing container if it exists
cleanup_existing_container() {
    local container_name="$1"
    
    if docker ps -a --format '{{.Names}}' | grep -q "^${container_name}$"; then
        log "Stopping existing container: $container_name"
        docker stop "$container_name" || true
        docker rm "$container_name" || true
        log "Existing container removed: $container_name"
    fi
}

# Remove existing image if present
cleanup_image() {
    local image_name="$1"
    
    if docker images --format '{{.Repository}}:{{.Tag}}' | grep -Fx "$image_name" >/dev/null 2>&1; then
        log "Removing Docker image: $image_name"
        docker image rm "$image_name" >/dev/null 2>&1 || true
    else
        log "No Docker image found to remove: $image_name"
    fi
}

# Wait until nginx container can resolve the app container hostname
wait_for_container_dns() {
    local container_name="$1"
    local retries=5
    local delay=5
    local attempt=1

    while (( attempt <= retries )); do
        if docker exec "$NGINX_CONTAINER_NAME" getent hosts "$container_name" >/dev/null 2>&1; then
            log "DNS ready inside nginx for container: $container_name"
            return 0
        fi

        log "Waiting for container DNS registration ($attempt/$retries): $container_name"
        sleep "$delay"
        ((attempt++))
    done

    log_error "Container $container_name is not resolvable inside nginx after ${retries} attempts"
    return 1
}

# Run Docker container
run_container() {
    local container_name="$1"
    local image_name="$2"
    local port="$3"
    
    log "Running container: $container_name on port $port"
    
    if docker run -d \
        --name "$container_name" \
        --network "$NETWORK_NAME" \
        --restart unless-stopped \
        "$image_name"; then
        log "Container started successfully: $container_name"
    else
        log_error "Failed to start container: $container_name"
        exit 1
    fi
    
    # Wait a moment for container to start
    sleep 2
    
    # Verify container is running
    if docker ps --format '{{.Names}}' | grep -q "^${container_name}$"; then
        log "Container is running: $container_name"
    else
        log_error "Container failed to start: $container_name"
        docker logs "$container_name" || true
        exit 1
    fi
}

# Generate nginx config from template
generate_nginx_config() {
    local template_file="$1"
    local output_dir="$2"
    local user_id="$3"
    local dataset_id="$4"
    local internal_port="$5"
    
    # Build names dynamically
    local subdomain="d_${user_id}_dataset${dataset_id}.${DOMAIN_SUFFIX}"
    local container_name="app_d${user_id}_dataset${dataset_id}"
    local output_file="${output_dir}/site_d${user_id}_dataset${dataset_id}.conf"
    
    log "Generating nginx config: $output_file"
    
    if [[ ! -f "$template_file" ]]; then
        log_error "Template file not found: $template_file"
        exit 1
    fi
    
    # Create output directory if it doesn't exist
    mkdir -p "$output_dir"
    
    # Process template with sed
    sed \
        -e "s#__SUBDOMAIN__#${subdomain}#g" \
        -e "s#__CONTAINER_NAME__#${container_name}#g" \
        -e "s#__INTERNAL_PORT__#${internal_port}#g" \
        -e "s#__USER_ID__#${user_id}#g" \
        -e "s#__DATASET_ID__#${dataset_id}#g" \
        "$template_file" | tee "$output_file" > /dev/null
    
    log "Generated: $output_file"
}

# Reload nginx
reload_nginx() {
    log "Reloading nginx configuration..."
    
    if docker exec "$NGINX_CONTAINER_NAME" nginx -t; then
        if docker exec "$NGINX_CONTAINER_NAME" nginx -s reload; then
            log "Nginx reloaded successfully"
        else
            log_error "Failed to reload nginx"
            exit 1
        fi
    else
        log_error "Nginx configuration test failed"
        docker exec "$NGINX_CONTAINER_NAME" nginx -t || true
        exit 1
    fi
}

# Rollback on failure
rollback() {
    local container_name="$1"
    local config_file="$2"
    local image_name="$3"
    
    log_error "Rolling back deployment..."
    
    # Remove container
    docker stop "$container_name" 2>/dev/null || true
    docker rm "$container_name" 2>/dev/null || true
    
    # Remove nginx config
    rm -f "$config_file" 2>/dev/null || true
    
    # Try to reload nginx
    docker exec "$NGINX_CONTAINER_NAME" nginx -s reload 2>/dev/null || true
    
    # Remove built image to avoid stale artifacts
    cleanup_image "$image_name"
    
    log_error "Rollback completed"
}

# Main deployment function
main() {
    local repo_path="${1:-}"
    
    if [[ -z "$repo_path" ]]; then
        log_error "Usage: $0 <repo_path>"
        exit 1
    fi
    
    # Convert to absolute path
    repo_path=$(readlink -f "$repo_path" || echo "$repo_path")
    
    log "Starting deployment for: $repo_path"
    
    # Validate and extract information
    validate_repo_path "$repo_path"
    extract_ids "$repo_path"
    check_dockerfile "$repo_path"
    
    # Set variables with new naming convention
    local container_name="app_d${USERID}_dataset${DATASETID}"
    local image_name="${container_name}:latest"
    local subdomain="d_${USERID}_dataset${DATASETID}.${DOMAIN_SUFFIX}"
    local dockerfile_path="$repo_path/Dockerfile.pf"
    local port
    port=$(extract_port_from_dockerfile "$dockerfile_path")
    local config_file="$NGINX_CONFIG_DIR/sites-enabled/site_d${USERID}_dataset${DATASETID}.conf"

    patch_vite_config "$repo_path" "$port"

    acquire_deploy_lock "$container_name"
    trap release_deploy_lock EXIT
    
    # Check if already deployed
    if docker ps --format '{{.Names}}' | grep -q "^${container_name}$"; then
        log "Container $container_name is already running. Skipping deployment."
        exit 0
    fi
    
    # Deploy with error handling
    local template_file="$SCRIPT_DIR/nginx-template.conf"
    if ! (
        cleanup_existing_container "$container_name"
        build_image "$repo_path" "$image_name"
        run_container "$container_name" "$image_name" "$port"
        wait_for_container_dns "$container_name"
        generate_nginx_config "$template_file" "$NGINX_CONFIG_DIR/sites-enabled" "$USERID" "$DATASETID" "$port"
        reload_nginx
    ); then
        rollback "$container_name" "$config_file" "$image_name"
        exit 1
    fi
    
    log "Deployment completed successfully for: $subdomain"
    log "Container: $container_name"
    log "Nginx config: $config_file"
    log "Access URL: http://$subdomain"
}

# Run main function
main "$@"

