#!/bin/bash

# Deployment directory setup script
# Creates the directory structure for application deployments

set -euo pipefail  # Exit on error, undefined vars, pipe failures

# Configuration
readonly LOG_FILE="/var/log/provision.log"

# Load configuration first (before setting readonly variables)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "$SCRIPT_DIR/provision.local.conf" ]]; then
    source "$SCRIPT_DIR/provision.local.conf"
elif [[ -f "$SCRIPT_DIR/provision.conf" ]]; then
    source "$SCRIPT_DIR/provision.conf"
fi

# Set DEFAULT_USER from config or use default, then make it readonly
DEFAULT_USER="${DEFAULT_USER:-forge}"
readonly DEFAULT_USER

# Default values if not set in config
TRAEFIK_DEPLOYMENT_DIR="${TRAEFIK_DEPLOYMENT_DIR:-/srv/deployments}"

# Logging functions
log() {
    ensure_log_file
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] DEPLOYMENT: $1" | tee -a "$LOG_FILE"
}

log_error() {
    ensure_log_file
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] DEPLOYMENT ERROR: $1" | tee -a "$LOG_FILE" >&2
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

    # Check if forge user exists
    if ! id "$DEFAULT_USER" &>/dev/null; then
        log_error "User '$DEFAULT_USER' does not exist. Run create_user.sh first."
        exit 1
    fi

    log "Prerequisites check completed"
}

# Create deployment directory structure
create_deployment_directories() {
    log "Creating deployment directory structure..."

    # Create base deployment directory
    if [[ ! -d "$TRAEFIK_DEPLOYMENT_DIR" ]]; then
        log "Creating base deployment directory: $TRAEFIK_DEPLOYMENT_DIR"
        if ! mkdir -p "$TRAEFIK_DEPLOYMENT_DIR"; then
            log_error "Failed to create deployment directory: $TRAEFIK_DEPLOYMENT_DIR"
            exit 1
        fi
        log "Base deployment directory created successfully"
    else
        log "Base deployment directory already exists: $TRAEFIK_DEPLOYMENT_DIR"
    fi

    # Set ownership to forge user
    log "Setting ownership to user '$DEFAULT_USER'..."
    if ! chown "$DEFAULT_USER:$DEFAULT_USER" "$TRAEFIK_DEPLOYMENT_DIR"; then
        log_error "Failed to set ownership for $TRAEFIK_DEPLOYMENT_DIR"
        exit 1
    fi

    # Set permissions (750: owner and group can read/write/execute, others have no access)
    log "Setting permissions to 750..."
    if ! chmod 750 "$TRAEFIK_DEPLOYMENT_DIR"; then
        log_error "Failed to set permissions for $TRAEFIK_DEPLOYMENT_DIR"
        exit 1
    fi

    log "Deployment directory structure created successfully"
}

# Verify directory structure
verify_setup() {
    log "Verifying deployment directory setup..."

    # Check if directory exists
    if [[ ! -d "$TRAEFIK_DEPLOYMENT_DIR" ]]; then
        log_error "Deployment directory does not exist: $TRAEFIK_DEPLOYMENT_DIR"
        exit 1
    fi

    # Check ownership
    local dir_owner
    dir_owner=$(stat -c "%U" "$TRAEFIK_DEPLOYMENT_DIR")
    if [[ "$dir_owner" != "$DEFAULT_USER" ]]; then
        log_error "Deployment directory ownership is incorrect: $dir_owner (expected: $DEFAULT_USER)"
        exit 1
    fi

    # Check permissions
    local dir_perms
    dir_perms=$(stat -c "%a" "$TRAEFIK_DEPLOYMENT_DIR")
    if [[ "$dir_perms" != "750" ]]; then
        log_error "Deployment directory permissions are incorrect: $dir_perms (expected: 750)"
        exit 1
    fi

    log "Deployment directory setup verified successfully"
}

# Main installation process
main() {
    log "Starting deployment directory setup..."

    check_prerequisites
    create_deployment_directories
    verify_setup

    log "Deployment directory setup completed successfully"

    echo
    echo "✅ Deployment directory setup completed successfully!"
    echo "📁 Deployment directory: $TRAEFIK_DEPLOYMENT_DIR"
    echo "👤 Owner: $DEFAULT_USER"
    echo "🔒 Permissions: 750"
    echo
    echo "📋 Next steps:"
    echo "   Individual deployments will be created in: $TRAEFIK_DEPLOYMENT_DIR/<deployment-id>/"
    echo "   Each deployment will contain a 'repo' subdirectory for the application code"
}

# Run main function
main "$@"

