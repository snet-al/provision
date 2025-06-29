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

# Copy shell scripts
if ! sudo cp ./*.sh "$SCRIPTS_DIR/"; then
    log_error "Failed to copy shell scripts to $SCRIPTS_DIR"
    exit 1
fi

# Copy README (optional, don't fail if missing)
if [[ -f "README.md" ]]; then
    if sudo cp README.md "$SCRIPTS_DIR/"; then
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
log "Post-setup file organization completed successfully"