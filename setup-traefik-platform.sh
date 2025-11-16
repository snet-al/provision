#!/bin/bash

# Traefik Deployment Platform Setup Script
# Standalone script to set up Traefik and deployment infrastructure
# Use this script on servers that will host and deploy applications
# This script can be run independently of the main provisioning

set -euo pipefail  # Exit on error, undefined vars, pipe failures

# Configuration
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly LOG_FILE="/var/log/provision.log"
readonly DEFAULT_USER="forge"

# Logging functions
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] TRAEFIK-PLATFORM: $1" | tee -a "$LOG_FILE"
}

log_error() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] TRAEFIK-PLATFORM ERROR: $1" | tee -a "$LOG_FILE" >&2
}

log_warning() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] TRAEFIK-PLATFORM WARNING: $1" | tee -a "$LOG_FILE"
}

# Error handling
cleanup() {
    local exit_code=$?
    if [[ $exit_code -ne 0 ]]; then
        log_error "Script failed with exit code $exit_code"
        log_error "Check $LOG_FILE for details"
    fi
    exit $exit_code
}

trap cleanup EXIT

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
        log_error "Docker is not installed. Please install Docker first."
        log_error "You can run: sudo $SCRIPT_DIR/docker.sh"
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

    # Check if forge user exists
    if ! id "$DEFAULT_USER" &>/dev/null; then
        log_error "User '$DEFAULT_USER' does not exist. Please create the user first."
        exit 1
    fi

    log "Prerequisites check completed"
}

# Main setup function
main() {
    echo "================================================="
    echo "🚀 Traefik Deployment Platform Setup"
    echo "================================================="
    echo
    echo "This script will set up:"
    echo "  • Deployment directory structure (/srv/deployments)"
    echo "  • Traefik reverse proxy with Docker provider"
    echo "  • Docker network for application containers"
    echo "  • Let's Encrypt SSL certificate configuration"
    echo
    echo "This setup is for servers that will host and deploy applications."
    echo "Skip this if this server is not intended for application deployments."
    echo
    read -p "Do you want to continue? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log "Setup cancelled by user"
        exit 0
    fi

    log "Starting Traefik deployment platform setup..."

    check_prerequisites

    # Setup deployment directories
    log "Setting up deployment directories..."
    if ! "$SCRIPT_DIR/deployment-setup.sh"; then
        log_error "Deployment directory setup failed"
        exit 1
    fi
    log "Deployment directory setup completed successfully"

    # Install Traefik
    log "Installing Traefik reverse proxy..."
    if ! "$SCRIPT_DIR/traefik.sh"; then
        log_error "Traefik installation failed"
        exit 1
    fi
    log "Traefik installation completed successfully"

    # Load configuration for final message
    if [[ -f "$SCRIPT_DIR/provision.local.conf" ]]; then
        source "$SCRIPT_DIR/provision.local.conf"
    elif [[ -f "$SCRIPT_DIR/provision.conf" ]]; then
        source "$SCRIPT_DIR/provision.conf"
    fi
    TRAEFIK_DOMAIN="${TRAEFIK_DOMAIN:-datafynow.ai}"

    log "=== Traefik Deployment Platform Setup Complete ==="
    log "Setup completed successfully at $(date)"

    echo
    echo "✅ Traefik deployment platform setup completed successfully!"
    echo
    echo "📋 Next steps:"
    echo "   1. Ensure DNS points *.$TRAEFIK_DOMAIN to this server"
    echo "   2. Deploy containers with Traefik labels to enable automatic routing"
    echo "   3. Check Traefik logs: docker logs traefik"
    echo "   4. Verify setup: $SCRIPT_DIR/validate-system.sh"
    echo
}

# Show help
show_help() {
    echo "Traefik Deployment Platform Setup"
    echo
    echo "Usage: $0 [options]"
    echo
    echo "Options:"
    echo "  -h, --help    Show this help message"
    echo
    echo "This script sets up:"
    echo "  • Deployment directory structure for application deployments"
    echo "  • Traefik reverse proxy with automatic container discovery"
    echo "  • Docker network for application containers"
    echo "  • Let's Encrypt SSL certificate configuration"
    echo
    echo "Prerequisites:"
    echo "  • Docker must be installed and running"
    echo "  • User 'forge' must exist"
    echo "  • Root or sudo access required"
    echo
    echo "This script can be run independently of the main provisioning script."
    echo "Use this on servers that will host and deploy applications."
}

# Parse command line arguments
case "${1:-}" in
    -h|--help)
        show_help
        exit 0
        ;;
    "")
        main
        ;;
    *)
        echo "Unknown option: $1"
        echo "Use -h or --help for usage information"
        exit 1
        ;;
esac

