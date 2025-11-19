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
                ((count++))
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
    local dir_name
    dir_name=$(basename "$repo_path")
    
    log "New repository detected: $dir_name"
    
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
    if "$DEPLOY_SCRIPT" "$repo_path"; then
        log "Deployment completed successfully for: $dir_name"
    else
        log_error "Deployment failed for: $dir_name"
        return 1
    fi
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
                # Deploy in background to allow processing multiple events
                (deploy_repository "$path" || true) &
            fi
        fi
    done
}

# Signal handler for graceful shutdown
cleanup() {
    log "Received shutdown signal. Stopping watcher..."
    exit 0
}

trap cleanup SIGINT SIGTERM

# Main function
main() {
    log "Starting deployment watcher..."
    
    check_prerequisites
    
    # Process existing directories first
    process_existing_dirs
    
    # Start watching for new directories
    watch_for_new_dirs
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

