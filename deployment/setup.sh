#!/bin/bash

# Deployment pipeline setup script
# Sets up nginx container, Docker network, and initial configuration

set -euo pipefail

# Configuration
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly LOG_FILE="/var/log/deployment.log"
readonly NETWORK_NAME="deployment-network"
readonly NGINX_CONTAINER_NAME="deployment-nginx"
readonly NGINX_CONFIG_DIR="/home/forge/deployment/nginx-configs"
readonly DEPLOYMENTS_DIR="/home/forge/deployments"
readonly DOMAIN_SUFFIX="datafynow.ai"

# Ensure log file is accessible
ensure_log_file() {
    if [[ ! -f "$LOG_FILE" ]]; then
        sudo touch "$LOG_FILE"
        sudo chmod 644 "$LOG_FILE"
    fi
}

# Logging functions
log() {
    ensure_log_file
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] SETUP: $1" | sudo tee -a "$LOG_FILE" > /dev/null
    echo "SETUP: $1"
}

log_error() {
    ensure_log_file
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] SETUP ERROR: $1" | sudo tee -a "$LOG_FILE" > /dev/null
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

    sudo mkdir -p "$NGINX_CONFIG_DIR/sites-available"
    sudo mkdir -p "$NGINX_CONFIG_DIR/sites-enabled"
    sudo chown -R forge:forge "$NGINX_CONFIG_DIR" || true

    log "Nginx configuration directories created"
}

# Create nginx main config
create_nginx_main_config() {
    log "Creating nginx main configuration..."

    local nginx_conf="$NGINX_CONFIG_DIR/nginx.conf"
    
    sudo tee "$nginx_conf" > /dev/null <<'EOF'
user nginx;
worker_processes auto;
error_log /var/log/nginx/error.log warn;
pid /var/run/nginx.pid;

events {
    worker_connections 1024;
}

http {
    include /etc/nginx/mime.types;
    default_type application/octet-stream;

    log_format main '$remote_addr - $remote_user [$time_local] "$request" '
                    '$status $body_bytes_sent "$http_referer" '
                    '"$http_user_agent" "$http_x_forwarded_for"';

    access_log /var/log/nginx/access.log main;

    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    keepalive_timeout 65;
    types_hash_max_size 2048;

    # WebSocket upgrade map
    map $http_upgrade $connection_upgrade {
        default upgrade;
        '' close;
    }

    include /etc/nginx/conf.d/*.conf;
    include /etc/nginx/sites-enabled/*.conf;
}
EOF

    sudo chown forge:forge "$nginx_conf" || true
    log "Nginx main configuration created"
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

# Create deployments directory if it doesn't exist
create_deployments_dir() {
    log "Ensuring deployments directory exists..."

    if [[ ! -d "$DEPLOYMENTS_DIR" ]]; then
        sudo mkdir -p "$DEPLOYMENTS_DIR"
        sudo chown forge:forge "$DEPLOYMENTS_DIR"
        log "Created deployments directory: $DEPLOYMENTS_DIR"
    else
        log "Deployments directory already exists: $DEPLOYMENTS_DIR"
    fi
}

# Main setup function
main() {
    log "Starting deployment pipeline setup..."

    check_prerequisites
    create_network
    create_nginx_dirs
    create_nginx_main_config
    setup_nginx_container
    create_deployments_dir

    log "Deployment pipeline setup completed successfully"
    echo
    echo "✅ Setup completed!"
    echo "📋 Next steps:"
    echo "   1. Start the watcher: ./watch.sh"
    echo "   2. Add repos to: $DEPLOYMENTS_DIR"
    echo "   3. Check logs: tail -f $LOG_FILE"
    echo
}

# Run main function
main "$@"

