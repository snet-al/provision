#!/bin/bash

set -euo pipefail

readonly LOG_FILE="/home/forge/logs/agents.log"
readonly AGENTS_DIR="/home/forge/agents"
readonly COMPOSE_FILE_NAME="docker-compose.pf.yaml"
readonly DETECTION_DELAY=5

ensure_log_file() {
    local log_dir
    log_dir=$(dirname "$LOG_FILE")
    mkdir -p "$log_dir"
    if [[ ! -f "$LOG_FILE" ]]; then
        touch "$LOG_FILE"
        chmod 644 "$LOG_FILE"
    fi
}

log() {
    ensure_log_file
    local message="$1"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] WATCH: $message" | tee -a "$LOG_FILE" >/dev/null
    echo "WATCH: $message"
}

log_error() {
    ensure_log_file
    local message="$1"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] WATCH ERROR: $message" | tee -a "$LOG_FILE" >/dev/null
    echo "WATCH ERROR: $message" >&2
}

check_prerequisites() {
    log "Checking prerequisites..."

    mkdir -p "$AGENTS_DIR"

    if ! command -v inotifywait >/dev/null 2>&1; then
        log_error "inotifywait is required but not installed"
        exit 1
    fi

    if ! command -v docker >/dev/null 2>&1; then
        log_error "docker CLI is required but not installed"
        exit 1
    fi

    if ! docker compose version >/dev/null 2>&1; then
        log_error "Docker Compose plugin (docker compose) is not available"
        exit 1
    fi

    log "Prerequisites check completed"
}

deploy_agent_dir() {
    local repo_path="$1"
    local dir_name
    dir_name=$(basename "$repo_path")
    local compose_file="$repo_path/$COMPOSE_FILE_NAME"

    log "New agent detected: $dir_name"

    if [[ ! -f "$compose_file" ]]; then
        log_error "Missing $COMPOSE_FILE_NAME in $dir_name. Skipping deployment."
        return 1
    fi

    log "Deploying $dir_name using $COMPOSE_FILE_NAME"
    if docker compose --project-directory "$repo_path" -f "$compose_file" up -d >> "$LOG_FILE" 2>&1; then
        log "Deployment completed for $dir_name"
    else
        log_error "Deployment failed for $dir_name. Check logs for details."
        return 1
    fi
}

watch_for_new_agents() {
    log "Watching for new agents in $AGENTS_DIR..."

    inotifywait -m "$AGENTS_DIR" \
        -e create -e moved_to \
        --format '%w%f' \
        -q | while read -r raw_path; do
            local path="${raw_path%/}"

            if [[ ! -d "$path" ]]; then
                continue
            fi

            if [[ "$(dirname "$path")" != "$AGENTS_DIR" ]]; then
                continue
            fi

            sleep "$DETECTION_DELAY"
            deploy_agent_dir "$path" || true
        done
}

main() {
    log "Starting agents watcher (docker-compose deployments only)..."
    check_prerequisites
    watch_for_new_agents
}

trap 'log "Shutting down agents watcher"; exit 0' SIGINT SIGTERM

main "$@"
