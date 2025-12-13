#!/bin/bash

# Post-setup script for organizing provisioning files
# This script should be run after the main setup process

set -euo pipefail  # Exit on error, undefined vars, pipe failures

# Logging function
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a /var/log/provision.log
}

log_error() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $1" | tee -a /var/log/provision.log >&2
}

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
readonly DOCKER_PROXY_SCRIPT="$ROOT_DIR/2-docker-portainer/configure-docker-proxy.sh"

# Check if running as root or with sudo
if [[ $EUID -ne 0 ]]; then
    log_error "This script must be run as root or with sudo"
    exit 1
fi

# Verify forge user exists
if ! id "forge" &>/dev/null; then
    log_error "Forge user does not exist. Run create_user.sh first."
    exit 1
fi

log "Starting post-setup file organization..."

# Copy all provisioning scripts to forge user's home
log "Copying provisioning scripts to forge user's home directory..."
SCRIPTS_DIR="/home/forge/provision"

# Create directory with proper error handling
if ! sudo -u forge mkdir -p "$SCRIPTS_DIR"; then
    log_error "Failed to create scripts directory: $SCRIPTS_DIR"
    exit 1
fi

# Synchronize key script directories so forge has the same structure
declare -a SCRIPT_SUBDIRS=("0-linux" "1-security" "2-docker-portainer" "deployment")
for subdir in "${SCRIPT_SUBDIRS[@]}"; do
    local_source="$ROOT_DIR/$subdir"
    if [[ -d "$local_source" ]]; then
        log "Syncing $subdir to forge's provision directory..."
        if ! sudo rsync -a "$local_source/" "$SCRIPTS_DIR/$subdir/"; then
            log_error "Failed to sync $subdir to $SCRIPTS_DIR"
            exit 1
        fi
    fi
done

# Copy root-level shell scripts (if any remain) for completeness
if compgen -G "$ROOT_DIR/*.sh" > /dev/null; then
    if ! sudo cp "$ROOT_DIR"/*.sh "$SCRIPTS_DIR/"; then
        log_error "Failed to copy root-level shell scripts to $SCRIPTS_DIR"
        exit 1
    fi
fi

# Copy README (optional, don't fail if missing)
if [[ -f "$ROOT_DIR/README.md" ]]; then
    if sudo cp "$ROOT_DIR/README.md" "$SCRIPTS_DIR/"; then
        log "README.md copied successfully"
    else
        log "Warning: Failed to copy README.md (non-critical)"
    fi
else
    log "Warning: README.md not found (non-critical)"
fi

# Set ownership
if ! sudo chown -R forge:forge "$SCRIPTS_DIR"; then
    log_error "Failed to set ownership for $SCRIPTS_DIR"
    exit 1
fi

# Set permissions
if ! sudo chmod -R 750 "$SCRIPTS_DIR"; then
    log_error "Failed to set permissions for $SCRIPTS_DIR"
    exit 1
fi

log "Provisioning scripts copied to $SCRIPTS_DIR"

# Check if user wants to configure Docker proxy
log "Checking for Docker proxy configuration..."
if [[ -f "$DOCKER_PROXY_SCRIPT" ]]; then
    read -p "Do you want to configure Docker proxy settings? (y/n): " configure_proxy
    if [[ "$configure_proxy" = "y" ]]; then
        log "Running Docker proxy configuration..."
        
        # Make sure the script is executable
        if [[ ! -x "$DOCKER_PROXY_SCRIPT" ]]; then
            chmod +x "$DOCKER_PROXY_SCRIPT"
        fi
        
        # Run the Docker proxy configuration script
        if "$DOCKER_PROXY_SCRIPT"; then
            log "Docker proxy configuration completed successfully"
        else
            log_error "Docker proxy configuration failed"
            log_error "You can run it manually later: $DOCKER_PROXY_SCRIPT"
        fi
    else
        log "Docker proxy configuration skipped by user choice"
    fi
else
    log "Docker proxy configuration script not found at $DOCKER_PROXY_SCRIPT"
fi

log "Post-setup file organization completed successfully"