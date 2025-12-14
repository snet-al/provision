#!/bin/bash

# File watcher script for deployment pipeline
# Monitors /home/forge/deployments for new repositories and triggers deployment

set -euo pipefail

# Configuration
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly LOG_FILE="/home/forge/deployment/logs/deployment.log"
readonly DEPLOYMENTS_DIR="/home/forge/deployments"
readonly DEPLOY_SCRIPT="$SCRIPT_DIR/deploy.sh"
readonly WATCH_INTERVAL=5  # seconds to wait before processing new directory
readonly NGINX_CONTAINER_NAME="deployment-nginx"
readonly NGINX_CONFIG_DIR="/home/forge/deployment/nginx-configs"
readonly WATCH_LOCK_DIR="/tmp/deployment-watch-locks"
declare -a WATCHER_PIDS=()
# Ensure watcher lock directory exists
ensure_watch_lock_dir() {
    mkdir -p "$WATCH_LOCK_DIR"
}


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
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] WATCH: $1" | tee -a "$LOG_FILE" > /dev/null
    echo "WATCH: $1"
}

log_error() {
    ensure_log_file
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] WATCH ERROR: $1" | tee -a "$LOG_FILE" > /dev/null
    echo "WATCH ERROR: $1" >&2
}

# Check prerequisites
check_prerequisites() {
    log "Checking prerequisites..."

    # Check if inotifywait is installed
    if ! command -v inotifywait &> /dev/null; then
        log_error "inotifywait is not installed. Please install inotify-tools."
        exit 1
    fi

    # Check if deployments directory exists
    if [[ ! -d "$DEPLOYMENTS_DIR" ]]; then
        log_error "Deployments directory does not exist: $DEPLOYMENTS_DIR"
        log_error "Please run setup.sh first"
        exit 1
    fi

    # Check if deploy script exists
    if [[ ! -f "$DEPLOY_SCRIPT" ]]; then
        log_error "Deploy script not found: $DEPLOY_SCRIPT"
        exit 1
    fi

    # Make deploy script executable
    chmod +x "$DEPLOY_SCRIPT"

    # Ensure watcher lock directory exists
    ensure_watch_lock_dir

    log "Prerequisites check completed"
}

# Process existing directories (for initial run)
process_existing_dirs() {
    log "Processing existing directories in $DEPLOYMENTS_DIR..."

    local count=0
    while IFS= read -r -d '' dir; do
        if [[ -d "$dir" ]] && [[ -f "$dir/Dockerfile.pf" ]]; then
            log "Found existing repository: $(basename "$dir")"
            if "$DEPLOY_SCRIPT" "$dir"; then
                ((count+=1))
                log "Deployed existing repository: $(basename "$dir")"
            else
                log_error "Failed to deploy existing repository: $(basename "$dir")"
            fi
        fi
    done < <(find "$DEPLOYMENTS_DIR" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null)

    if [[ $count -gt 0 ]]; then
        log "Processed $count existing repositories"
    else
        log "No existing repositories found to deploy"
    fi
}

# Deploy a repository
deploy_repository() {
    local repo_path="$1"
    local trigger_reason="${2:-"New repository detected"}"
    local watch_lock_path="${3:-""}"
    local force_redeploy="${4:-0}"
    local dir_name
    dir_name=$(basename "$repo_path")

    if [[ -n "$watch_lock_path" ]]; then
        trap "rm -rf '$watch_lock_path'" EXIT
    fi
    
    if [[ "$force_redeploy" == "1" ]]; then
        log "$trigger_reason: $dir_name (force redeploy enabled)"
    else
        log "$trigger_reason: $dir_name"
    fi
    
    # Wait a bit for directory to be fully created
    sleep "$WATCH_INTERVAL"
    
    # Verify directory still exists and is accessible
    if [[ ! -d "$repo_path" ]]; then
        log_error "Directory disappeared: $repo_path"
        return 1
    fi
    
    # Check if it's a valid directory (not a file)
    if [[ ! -d "$repo_path" ]]; then
        log_error "Path is not a directory: $repo_path"
        return 1
    fi
    
    # Run deployment
    log "Starting deployment for: $repo_path"

    local deploy_status=0
    if [[ "$force_redeploy" == "1" ]]; then
        DEPLOY_FORCE_REDEPLOY=1 "$DEPLOY_SCRIPT" "$repo_path"
        deploy_status=$?
    else
        "$DEPLOY_SCRIPT" "$repo_path"
        deploy_status=$?
    fi

    if [[ $deploy_status -eq 0 ]]; then
        log "Deployment completed successfully for: $dir_name"
    else
        log_error "Deployment failed for: $dir_name"
        return 1
    fi
}

# Schedule deployment with per-repo locking
schedule_deployment() {
    local repo_path="$1"
    local trigger_reason="${2:-"New repository detected"}"
    local force_redeploy="${3:-0}"
    local dir_name
    dir_name=$(basename "$repo_path")
    ensure_watch_lock_dir

    local lock_path="$WATCH_LOCK_DIR/${dir_name}.lock"

    if ! mkdir "$lock_path" 2>/dev/null; then
        return
    fi

    (
        deploy_repository "$repo_path" "$trigger_reason" "$lock_path" "$force_redeploy" || true
    ) &
}

# Watch for new directories
watch_for_new_dirs() {
    log "Starting file watcher on: $DEPLOYMENTS_DIR"
    log "Watching for new repositories..."
    
    # Use inotifywait to monitor for new directories
    inotifywait -m "$DEPLOYMENTS_DIR" \
        -e create \
        --format '%w%f' \
        -q 2>/dev/null | while read -r path; do
        
        # Check if it's a directory
        if [[ -d "$path" ]]; then
            # Ignore if it's the deployments directory itself
            if [[ "$path" != "$DEPLOYMENTS_DIR" ]]; then
                schedule_deployment "$path" "New repository detected"
            fi
        fi
    done
}

watch_for_file_content_changes() {
    log "Watching for file changes in $DEPLOYMENTS_DIR..."

    inotifywait -m -r "$DEPLOYMENTS_DIR" \
        --exclude '(^|/)(node_modules|\.git|dist|build|logs|storage|tmp|coverage|\.angular|target|\.gradle|gradle|out|\.m2|maven|venv|\.venv|\.env|\.idea|\.vscode|\.cache|\.npm|\.yarn|\.pnp|\.next|\.nuxt|\.turbo|\.swc|\.parcel-cache|\.svelte-kit|\.vercel|\.netlify|\.nx|\.docusaurus|\.nextjs|\.remix|\.redwood|\.expo|\.expo-shared|\.react-native|\.react|\.storybook|\.jest|\.cypress|\.playwright|\.test|\.spec|\.DS_Store|\.\w+\.\w+)(/|$)' \
        -e close_write -e moved_to -e moved_from -e create -e delete \
        --format '%w%f' \
        -q 2>/dev/null | while read -r changed_path; do

        if [[ "$changed_path" == "$DEPLOYMENTS_DIR" ]] || [[ "$changed_path" == "$DEPLOYMENTS_DIR/" ]]; then
            continue
        fi

        local relative_path="${changed_path#$DEPLOYMENTS_DIR/}"
        if [[ "$relative_path" == "$changed_path" ]] || [[ -z "$relative_path" ]]; then
            continue
        fi

        # Extra safety: skip any path in ignored dirs and temporary files
        # Pattern matches: /dir/, dir/, /dir, or dir at start/end of path
        if [[ "$relative_path" =~ ^(node_modules|\.git|dist|build|logs|storage|tmp|coverage|\.angular|target|\.gradle|gradle|out|\.m2|maven|venv|\.venv|\.idea|\.vscode|\.cache|\.npm|\.yarn|\.next|\.nuxt)(/|$) ]] || \
           [[ "$relative_path" =~ /(node_modules|\.git|dist|build|logs|storage|tmp|coverage|\.angular|target|\.gradle|gradle|out|\.m2|maven|venv|\.venv|\.idea|\.vscode|\.cache|\.npm|\.yarn|\.next|\.nuxt)(/|$) ]] || \
           [[ "$relative_path" == .env ]]; then
            continue
        fi
        
        # Skip temporary files (e.g., .Layout.jsx.u4D5Ib) but not Dockerfile.pf
        if [[ "$relative_path" =~ \.[a-zA-Z0-9_-]+\.[a-zA-Z0-9]+$ ]] && [[ ! "$relative_path" =~ Dockerfile\.pf$ ]]; then
            continue
        fi

        local repo_name="${relative_path%%/*}"
        if [[ -z "$repo_name" ]]; then
            continue
        fi

        local repo_path="$DEPLOYMENTS_DIR/$repo_name"
        if [[ ! -d "$repo_path" ]]; then
            continue
        fi

        if [[ -f "$repo_path/Dockerfile.pf" ]]; then
            if [[ "$relative_path" == "$repo_name/Dockerfile.pf" ]]; then
                schedule_deployment "$repo_path" "Dockerfile change detected" "1"
            else
                log "File change detected in $repo_name ($relative_path). Skipping redeploy because Dockerfile.pf was not modified."
            fi
        else
            log_error "File change detected in $repo_name but Dockerfile.pf is missing"
        fi
    done
}

cleanup_removed_repository() {
    local dir_name="$1"

    local dir_pattern='^d_([[:alnum:]_-]+)_dataset([[:alnum:]_-]+)(_[[:alnum:]_-]+)?(\.[[:alnum:]._-]+)?$'
    if [[ ! "$dir_name" =~ $dir_pattern ]]; then
        log "Skipping cleanup for unrecognized directory: $dir_name"
        return
    fi

    local user_id="${BASH_REMATCH[1]}"
    local dataset_id="${BASH_REMATCH[2]}"
    local container_name="app_d${user_id}_dataset${dataset_id}"
    local config_file="$NGINX_CONFIG_DIR/sites-enabled/site_d${user_id}_dataset${dataset_id}.conf"

    if docker ps -a --format '{{.Names}}' | grep -Fx "$container_name" >/dev/null 2>&1; then
        log "Stopping container for removed repository: $dir_name"
        docker stop "$container_name" >/dev/null 2>&1 || true
        docker rm "$container_name" >/dev/null 2>&1 || true
        log "Removed container: $container_name"
    else
        log "No container to remove for: $dir_name"
    fi

    if [[ -f "$config_file" ]]; then
        log "Removing nginx config for removed repository: $dir_name"
        rm -f "$config_file"
        if docker exec "$NGINX_CONTAINER_NAME" nginx -s reload >/dev/null 2>&1; then
            log "Reloaded nginx after removing config for: $dir_name"
        else
            log_error "Failed to reload nginx after removing config for: $dir_name"
        fi
    else
        log "No nginx config found for: $dir_name"
    fi
}

watch_for_removed_dirs() {
    log "Watching for repository deletions in $DEPLOYMENTS_DIR..."

    inotifywait -m "$DEPLOYMENTS_DIR" \
        -e delete -e moved_from \
        --format '%e %f' \
        -q 2>/dev/null | while read -r event name; do

        if [[ -z "$name" ]]; then
            continue
        fi

        if [[ "$event" == *"ISDIR"* ]]; then
            cleanup_removed_repository "$name"
        fi
    done
}

# Signal handler for graceful shutdown
cleanup() {
    log "Received shutdown signal. Stopping watcher..."
    if [[ ${#WATCHER_PIDS[@]} -gt 0 ]]; then
        kill "${WATCHER_PIDS[@]}" 2>/dev/null || true
    fi
    exit 0
}

trap cleanup SIGINT SIGTERM

# Main function
main() {
    log "Starting deployment watcher..."
    
    check_prerequisites
    
    # Process existing directories first
    process_existing_dirs
    
    # Start watchers
    watch_for_new_dirs &
    WATCHER_PIDS+=($!)

    watch_for_file_content_changes &
    WATCHER_PIDS+=($!)

    watch_for_removed_dirs &
    WATCHER_PIDS+=($!)

    wait "${WATCHER_PIDS[@]}"
}

# Check if running as daemon
if [[ "${1:-}" == "--daemon" ]]; then
    # Run in background and redirect output
    nohup "$0" >> "$LOG_FILE" 2>&1 &
    echo "Watcher started in background. PID: $!"
    echo "Check logs: tail -f $LOG_FILE"
    exit 0
fi

# Run main function
main "$@"

