#!/bin/bash

# Shared utility functions for provisioning scripts
# Source this file in scripts that need logging and config access
# Usage: source "$(dirname "${BASH_SOURCE[0]}")/utils.sh"
#    or: source "/path/to/0-linux/utils.sh"

# Prevent multiple sourcing
[[ -n "${_UTILS_SOURCED:-}" ]] && return 0
readonly _UTILS_SOURCED=1

# =============================================================================
# CONFIGURATION LOADING
# =============================================================================

# Determine the directory where utils.sh lives (0-linux/) and project root
readonly UTILS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly ROOT_DIR="$(cd "$UTILS_DIR/.." && pwd)"
readonly CONFIG_FILE="$ROOT_DIR/provision.conf"
readonly LOCAL_CONFIG_FILE="$ROOT_DIR/provision.local.conf"

# Source configuration file (use exported path if available, else find it)
if [[ -n "${PROVISION_CONFIG_FILE:-}" ]] && [[ -f "$PROVISION_CONFIG_FILE" ]]; then
    # shellcheck source=provision.conf
    source "$PROVISION_CONFIG_FILE"
elif [[ -f "$LOCAL_CONFIG_FILE" ]]; then
    # shellcheck source=provision.conf
    source "$LOCAL_CONFIG_FILE"
elif [[ -f "$CONFIG_FILE" ]]; then
    # shellcheck source=provision.conf
    source "$CONFIG_FILE"
else
    echo "ERROR: Configuration file not found: $CONFIG_FILE"
    exit 1
fi

# Export config path for any sub-processes
if [[ -f "$LOCAL_CONFIG_FILE" ]]; then
    export PROVISION_CONFIG_FILE="$LOCAL_CONFIG_FILE"
else
    export PROVISION_CONFIG_FILE="$CONFIG_FILE"
fi

# =============================================================================
# LOGGING FUNCTIONS
# =============================================================================

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

# Warning logging function
# Usage: log_warning "warning message"
log_warning() {
    local prefix="WARNING: "
    [[ -n "$LOG_PREFIX" ]] && prefix="$LOG_PREFIX WARNING: "
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ${prefix}$1" | tee -a "$LOG_FILE"
}

