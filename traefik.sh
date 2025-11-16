#!/bin/bash

# Traefik installation script
# Installs and configures Traefik reverse proxy with Docker provider and Let's Encrypt

set -euo pipefail  # Exit on error, undefined vars, pipe failures

# Configuration
readonly LOG_FILE="/var/log/provision.log"
readonly DEFAULT_USER="forge"

# Load configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "$SCRIPT_DIR/provision.local.conf" ]]; then
    source "$SCRIPT_DIR/provision.local.conf"
elif [[ -f "$SCRIPT_DIR/provision.conf" ]]; then
    source "$SCRIPT_DIR/provision.conf"
fi

# Default values if not set in config
TRAEFIK_DOMAIN="${TRAEFIK_DOMAIN:-datafynow.ai}"
TRAEFIK_EMAIL="${TRAEFIK_EMAIL:-admin@datafynow.ai}"
TRAEFIK_NETWORK="${TRAEFIK_NETWORK:-datafynow-platform}"
TRAEFIK_VERSION="${TRAEFIK_VERSION:-latest}"
TRAEFIK_DASHBOARD_ENABLED="${TRAEFIK_DASHBOARD_ENABLED:-false}"
TRAEFIK_CONTAINER_NAME="${TRAEFIK_CONTAINER_NAME:-traefik}"
TRAEFIK_CERTS_DIR="${TRAEFIK_CERTS_DIR:-/srv/traefik/certs}"
TRAEFIK_CONFIG_DIR="${TRAEFIK_CONFIG_DIR:-/srv/traefik/config}"

# Logging functions
log() {
    ensure_log_file
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] TRAEFIK: $1" | tee -a "$LOG_FILE"
}

log_error() {
    ensure_log_file
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] TRAEFIK ERROR: $1" | tee -a "$LOG_FILE" >&2
}

log_warning() {
    ensure_log_file
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] TRAEFIK WARNING: $1" | tee -a "$LOG_FILE"
}

# Ensure log file is accessible
ensure_log_file() {
    if [[ ! -f "$LOG_FILE" ]]; then
        touch "$LOG_FILE"
        chmod 644 "$LOG_FILE"
    fi
}

# Check prerequisites
check_prerequisites() {
    log "Checking prerequisites..."

    # Check if running as root or with sudo
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root or with sudo"
        exit 1
    fi

    # Check if Docker is installed
    if ! command -v docker &>/dev/null; then
        log_error "Docker is not installed. Please run docker.sh first."
        exit 1
    fi

    # Check if Docker service is running
    if ! systemctl is-active --quiet docker; then
        log_error "Docker service is not running. Please start Docker first."
        exit 1
    fi

    # Verify Docker is accessible
    if ! docker info &>/dev/null; then
        log_error "Cannot access Docker daemon. Ensure Docker is running and user has permissions."
        exit 1
    fi

    log "Prerequisites check completed"
}

# Create Traefik directories
create_traefik_directories() {
    log "Creating Traefik directories..."

    # Create certificates directory
    if [[ ! -d "$TRAEFIK_CERTS_DIR" ]]; then
        log "Creating certificates directory: $TRAEFIK_CERTS_DIR"
        if ! mkdir -p "$TRAEFIK_CERTS_DIR"; then
            log_error "Failed to create certificates directory: $TRAEFIK_CERTS_DIR"
            exit 1
        fi
        chmod 755 "$TRAEFIK_CERTS_DIR"
        log "Certificates directory created successfully"
    else
        log "Certificates directory already exists: $TRAEFIK_CERTS_DIR"
    fi

    # Create configuration directory
    if [[ ! -d "$TRAEFIK_CONFIG_DIR" ]]; then
        log "Creating configuration directory: $TRAEFIK_CONFIG_DIR"
        if ! mkdir -p "$TRAEFIK_CONFIG_DIR"; then
            log_error "Failed to create configuration directory: $TRAEFIK_CONFIG_DIR"
            exit 1
        fi
        chmod 755 "$TRAEFIK_CONFIG_DIR"
        log "Configuration directory created successfully"
    else
        log "Configuration directory already exists: $TRAEFIK_CONFIG_DIR"
    fi

    log "Traefik directories created successfully"
}

# Create Docker network
create_docker_network() {
    log "Creating Docker network: $TRAEFIK_NETWORK"

    # Check if network already exists
    if docker network inspect "$TRAEFIK_NETWORK" &>/dev/null; then
        log "Docker network '$TRAEFIK_NETWORK' already exists"
        return 0
    fi

    # Create bridge network
    if ! docker network create "$TRAEFIK_NETWORK"; then
        log_error "Failed to create Docker network: $TRAEFIK_NETWORK"
        exit 1
    fi

    log "Docker network '$TRAEFIK_NETWORK' created successfully"
}

# Stop and remove existing Traefik container (if exists)
remove_existing_traefik() {
    log "Checking for existing Traefik container..."

    if docker ps -a --format '{{.Names}}' | grep -q "^${TRAEFIK_CONTAINER_NAME}$"; then
        log_warning "Existing Traefik container found. Stopping and removing..."
        
        if docker stop "$TRAEFIK_CONTAINER_NAME" &>/dev/null; then
            log "Stopped existing Traefik container"
        fi
        
        if docker rm "$TRAEFIK_CONTAINER_NAME" &>/dev/null; then
            log "Removed existing Traefik container"
        fi
    else
        log "No existing Traefik container found"
    fi
}

# Install and configure Traefik
install_traefik() {
    log "Installing Traefik container..."

    # Build Traefik docker run command arguments
    local docker_args=(
        "run"
        "-d"
        "--name" "$TRAEFIK_CONTAINER_NAME"
        "--restart" "always"
        "--network" "$TRAEFIK_NETWORK"
        "--publish" "80:80"
        "--publish" "443:443"
        "--volume" "/var/run/docker.sock:/var/run/docker.sock:ro"
        "--volume" "$TRAEFIK_CERTS_DIR:/data/certs"
        "--label" "traefik.enable=true"
    )

    # Add dashboard labels if enabled
    if [[ "$TRAEFIK_DASHBOARD_ENABLED" == "true" ]]; then
        log "Traefik dashboard will be enabled"
        docker_args+=(
            "--label" "traefik.http.routers.traefik.rule=Host(\`traefik.${TRAEFIK_DOMAIN}\`)"
            "--label" "traefik.http.routers.traefik.entrypoints=websecure"
            "--label" "traefik.http.routers.traefik.tls.certresolver=le"
            "--label" "traefik.http.routers.traefik.service=api@internal"
        )
    fi

    # Add Traefik image and command arguments
    docker_args+=(
        "traefik:${TRAEFIK_VERSION}"
        "--api.insecure=false"
        "--providers.docker=true"
        "--providers.docker.exposedbydefault=false"
        "--providers.docker.network=${TRAEFIK_NETWORK}"
        "--entrypoints.web.address=:80"
        "--entrypoints.websecure.address=:443"
        "--certificatesresolvers.le.acme.email=${TRAEFIK_EMAIL}"
        "--certificatesresolvers.le.acme.storage=/data/certs/acme.json"
        "--certificatesresolvers.le.acme.httpchallenge.entrypoint=web"
    )

    # Run Traefik container
    log "Starting Traefik container with version: $TRAEFIK_VERSION"
    if ! docker "${docker_args[@]}"; then
        log_error "Failed to start Traefik container"
        exit 1
    fi

    log "Traefik container started successfully"
}

# Verify Traefik installation
verify_installation() {
    log "Verifying Traefik installation..."

    # Wait a moment for container to start
    sleep 3

    # Check if container is running
    if ! docker ps --format '{{.Names}}' | grep -q "^${TRAEFIK_CONTAINER_NAME}$"; then
        log_error "Traefik container is not running"
        log "Container logs:"
        docker logs "$TRAEFIK_CONTAINER_NAME" 2>&1 | tail -20
        exit 1
    fi

    log "Traefik container is running"

    # Check if Traefik is listening on ports
    if ! netstat -tuln 2>/dev/null | grep -q ":80 " && ! ss -tuln 2>/dev/null | grep -q ":80 "; then
        log_warning "Traefik may not be listening on port 80"
    else
        log "Traefik is listening on port 80"
    fi

    if ! netstat -tuln 2>/dev/null | grep -q ":443 " && ! ss -tuln 2>/dev/null | grep -q ":443 "; then
        log_warning "Traefik may not be listening on port 443"
    else
        log "Traefik is listening on port 443"
    fi

    # Check Docker network
    if docker network inspect "$TRAEFIK_NETWORK" &>/dev/null; then
        log "Docker network '$TRAEFIK_NETWORK' exists and is configured"
    else
        log_error "Docker network '$TRAEFIK_NETWORK' does not exist"
        exit 1
    fi

    log "Traefik installation verification completed"
}

# Main installation process
main() {
    log "Starting Traefik installation process..."

    check_prerequisites
    create_traefik_directories
    create_docker_network
    remove_existing_traefik
    install_traefik
    verify_installation

    log "Traefik installation completed successfully"

    echo
    echo "✅ Traefik installation completed successfully!"
    echo "🐳 Container name: $TRAEFIK_CONTAINER_NAME"
    echo "🌐 Network: $TRAEFIK_NETWORK"
    echo "📧 Let's Encrypt email: $TRAEFIK_EMAIL"
    echo "🔒 Domain: $TRAEFIK_DOMAIN"
    echo "📁 Certificates: $TRAEFIK_CERTS_DIR"
    echo
    echo "📋 Next steps:"
    echo "   1. Ensure DNS points *.${TRAEFIK_DOMAIN} to this server"
    echo "   2. Deploy containers with Traefik labels to enable automatic routing"
    echo "   3. Check Traefik logs: docker logs $TRAEFIK_CONTAINER_NAME"
    echo "   4. Verify network: docker network inspect $TRAEFIK_NETWORK"
    if [[ "$TRAEFIK_DASHBOARD_ENABLED" == "true" ]]; then
        echo "   5. Access dashboard: https://traefik.${TRAEFIK_DOMAIN}"
    fi
    echo
}

# Run main function
main "$@"

