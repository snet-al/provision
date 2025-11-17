#!/bin/bash

# Docker Network Setup Script
# Creates and manages the shared deployments-network Docker network

set -euo pipefail

# Configuration
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly LOG_FILE="/var/log/provision.log"

# Load configuration
if [[ -f "$SCRIPT_DIR/docker-network.conf" ]]; then
    # shellcheck source=docker-network.conf
    source "$SCRIPT_DIR/docker-network.conf"
else
    # Default values if config file doesn't exist
    DEPLOYMENTS_NETWORK="deployments-network"
    NETWORK_DRIVER="bridge"
fi

# Logging functions
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] DOCKER-NETWORK: $1" | tee -a "$LOG_FILE"
}

log_error() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] DOCKER-NETWORK ERROR: $1" | tee -a "$LOG_FILE" >&2
}

# Check prerequisites
check_prerequisites() {
    log "Checking prerequisites..."

    # Check if Docker is installed
    if ! command -v docker &> /dev/null; then
        log_error "Docker is not installed. Please install Docker first."
        exit 1
    fi

    # Check if Docker daemon is running
    if ! docker info &> /dev/null; then
        log_error "Docker daemon is not running. Please start Docker first."
        exit 1
    fi

    log "Prerequisites check passed"
}

# Check if network exists
network_exists() {
    docker network ls --format '{{.Name}}' | grep -q "^${DEPLOYMENTS_NETWORK}$"
}

# Create the Docker network
create_network() {
    log "Creating Docker network: ${DEPLOYMENTS_NETWORK}"

    if network_exists; then
        log "Network ${DEPLOYMENTS_NETWORK} already exists"
        return 0
    fi

    # Build docker network create command
    local create_cmd=("docker" "network" "create" "--driver" "$NETWORK_DRIVER")

    # Add subnet if specified
    if [[ -n "${NETWORK_SUBNET:-}" ]]; then
        create_cmd+=("--subnet" "$NETWORK_SUBNET")
    fi

    # Add gateway if specified
    if [[ -n "${NETWORK_GATEWAY:-}" ]]; then
        create_cmd+=("--gateway" "$NETWORK_GATEWAY")
    fi

    # Add network name
    create_cmd+=("$DEPLOYMENTS_NETWORK")

    # Create the network
    if "${create_cmd[@]}"; then
        log "Network ${DEPLOYMENTS_NETWORK} created successfully"
    else
        log_error "Failed to create network ${DEPLOYMENTS_NETWORK}"
        exit 1
    fi
}

# Verify network creation
verify_network() {
    log "Verifying network: ${DEPLOYMENTS_NETWORK}"

    if ! network_exists; then
        log_error "Network ${DEPLOYMENTS_NETWORK} does not exist after creation"
        exit 1
    fi

    # Get network details
    local network_info
    network_info=$(docker network inspect "$DEPLOYMENTS_NETWORK" --format '{{.Name}} - {{.Driver}} - {{.Scope}}')

    log "Network details: $network_info"
    log "Network ${DEPLOYMENTS_NETWORK} is ready"
}

# Main execution
main() {
    log "=== Docker Network Setup Started ==="
    
    check_prerequisites
    create_network
    verify_network
    
    log "=== Docker Network Setup Completed ==="
    echo
    echo "✅ Docker network '${DEPLOYMENTS_NETWORK}' is ready"
    echo "   Network driver: ${NETWORK_DRIVER}"
    echo "   To inspect: docker network inspect ${DEPLOYMENTS_NETWORK}"
}

# Run main function
main "$@"

