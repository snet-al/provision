#!/bin/bash

# Agents server setup script
# Sets up agents server, Docker network with nginx, and initial configuration

set -euo pipefail

# Configuration
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly LOG_FILE="/home/forge/logs/agents.log"
readonly NETWORK_NAME="agents-network"
readonly NGINX_CONTAINER_NAME="agents-nginx"
readonly NGINX_CONFIG_DIR="/home/forge/agents/nginx-configs"
readonly AGENTS_DIR="/home/forge/agents/"
readonly DOMAIN="agents.datafynow.ai"

# Ensure log file is accessible
ensure_log_file() {
    local log_dir=$(dirname "$LOG_FILE")
    # Create log directory as current user (forge if running without sudo, or root if with sudo)
    mkdir -p "$log_dir"
    if [[ ! -f "$LOG_FILE" ]]; then
        touch "$LOG_FILE"
        chmod 644 "$LOG_FILE"
        # If running with sudo, change ownership to forge
        if [[ $EUID -eq 0 ]]; then
            chown forge:forge "$LOG_FILE" 2>/dev/null || true
            chown forge:forge "$log_dir" 2>/dev/null || true
        fi
    fi
}

# Logging functions
log() {
    ensure_log_file
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] SETUP: $1" | tee -a "$LOG_FILE" > /dev/null
    echo "SETUP: $1"
}

log_error() {
    ensure_log_file
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] SETUP ERROR: $1" | tee -a "$LOG_FILE" > /dev/null
    echo "SETUP ERROR: $1" >&2
}

# Check prerequisites
check_prerequisites() {
    log "Checking prerequisites..."

    # Check if Docker is installed
    if ! command -v docker &> /dev/null; then
        log_error "Docker is not installed. Please run docker.sh first."
        exit 1
    fi

    # Check if user is in docker group or has sudo
    if ! docker ps &> /dev/null && [[ $EUID -ne 0 ]]; then
        log_error "User must be in docker group or run with sudo"
        exit 1
    fi

    # Check if inotify-tools is installed
    if ! command -v inotifywait &> /dev/null; then
        log "Installing inotify-tools..."
        sudo apt-get update -qq
        sudo apt-get install -y inotify-tools
    fi

    log "Prerequisites check completed"
}

# Create Docker network
create_network() {
    log "Creating Docker network: $NETWORK_NAME"

    if docker network inspect "$NETWORK_NAME" &> /dev/null; then
        log "Network $NETWORK_NAME already exists"
    else
        if docker network create "$NETWORK_NAME"; then
            log "Network $NETWORK_NAME created successfully"
        else
            log_error "Failed to create network $NETWORK_NAME"
            exit 1
        fi
    fi
}

# Create nginx config directory
create_nginx_dirs() {
    log "Creating nginx configuration directories..."

    mkdir -p "$NGINX_CONFIG_DIR/sites-available"
    mkdir -p "$NGINX_CONFIG_DIR/sites-enabled"
    # If running with sudo, ensure ownership is set to forge
    if [[ $EUID -eq 0 ]]; then
        chown -R forge:forge "$NGINX_CONFIG_DIR" || true
    fi

    log "Nginx configuration directories created"
}


# Setup nginx container
setup_nginx_container() {
    log "Setting up nginx container..."

    # Stop and remove existing container if it exists
    if docker ps -a --format '{{.Names}}' | grep -q "^${NGINX_CONTAINER_NAME}$"; then
        log "Stopping existing nginx container..."
        docker stop "$NGINX_CONTAINER_NAME" || true
        docker rm "$NGINX_CONTAINER_NAME" || true
    fi

    # Run nginx container
    log "Starting nginx container..."
    if docker run -d \
        --name "$NGINX_CONTAINER_NAME" \
        --network "$NETWORK_NAME" \
        --restart unless-stopped \
        -p 80:80 \
        -p 443:443 \
        -v "$NGINX_CONFIG_DIR/sites-enabled:/etc/nginx/sites-enabled:ro" \
        -v "$NGINX_CONFIG_DIR/nginx.conf:/etc/nginx/nginx.conf:ro" \
        -v /var/log/nginx:/var/log/nginx \
        nginx:latest; then
        log "Nginx container started successfully"
    else
        log_error "Failed to start nginx container"
        exit 1
    fi

    # Wait a moment for nginx to start
    sleep 2

    # Verify container is running
    if docker ps --format '{{.Names}}' | grep -q "^${NGINX_CONTAINER_NAME}$"; then
        log "Nginx container is running"
    else
        log_error "Nginx container failed to start"
        docker logs "$NGINX_CONTAINER_NAME" || true
        exit 1
    fi
}

# Create agents directory if it doesn't exist
create_agents_dir() {
    log "Ensuring agents directory exists..."

    if [[ ! -d "$AGENTS_DIR" ]]; then
        mkdir -p "$AGENTS_DIR"
        # If running with sudo, ensure ownership is set to forge
        if [[ $EUID -eq 0 ]]; then
            chown forge:forge "$AGENTS_DIR"
        fi
        log "Created agents directory: $AGENTS_DIR"
    else
        log "Agents directory already exists: $AGENTS_DIR"
    fi
}

# Main setup function
main() {
    log "Starting agents server setup..."

    check_prerequisites
    create_network
    create_nginx_dirs
    create_nginx_main_config
    setup_nginx_container
    create_agents_dir

    log "Agents server setup completed successfully"
    echo
    echo "✅ Setup completed!"
    echo "📋 Next steps:"
    echo "   1. Start the watcher: ./watch.sh --daemon"
    echo "   2. Add repos to: $DEPLOYMENTS_DIR"
    echo "   3. Check logs: tail -f $LOG_FILE"
    echo
}

# Run main function
main "$@"

