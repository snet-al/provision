#!/bin/bash

# Shared utility functions for provisioning scripts
# Source this file in scripts that need logging: source "$(dirname "${BASH_SOURCE[0]}")/utils.sh"

# Configuration - can be overridden before sourcing
readonly LOG_FILE="${LOG_FILE:-/var/log/provision.log}"

# Optional prefix for log messages (e.g., "SSH-KEYS", "SECURITY")
# Set LOG_PREFIX before sourcing to add a prefix to log messages
LOG_PREFIX="${LOG_PREFIX:-}"

# Logging function
# Usage: log "message"
log() {
    local prefix=""
    [[ -n "$LOG_PREFIX" ]] && prefix="$LOG_PREFIX: "
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ${prefix}$1" | tee -a "$LOG_FILE"
}

# Error logging function (outputs to stderr)
# Usage: log_error "error message"
log_error() {
    local prefix="ERROR: "
    [[ -n "$LOG_PREFIX" ]] && prefix="$LOG_PREFIX ERROR: "
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ${prefix}$1" | tee -a "$LOG_FILE" >&2
}

