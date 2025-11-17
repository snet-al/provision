#!/bin/bash

# Deployment Server Provisioning Script
# Main orchestration script that provisions the deployment server infrastructure
# Sets up Docker network and Nginx reverse proxy container

set -euo pipefail

# Configuration
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly LOG_FILE="/var/log/provision.log"

# Script paths
readonly DOCKER_NETWORK_SCRIPT="$SCRIPT_DIR/docker-network-setup.sh"
readonly NGINX_PROXY_SCRIPT="$SCRIPT_DIR/nginx-proxy-container.sh"

# Logging functions
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] PROVISION-DEPLOYMENT: $1" | tee -a "$LOG_FILE"
}

log_error() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] PROVISION-DEPLOYMENT ERROR: $1" | tee -a "$LOG_FILE" >&2
}

log_success() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] PROVISION-DEPLOYMENT SUCCESS: $1" | tee -a "$LOG_FILE"
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
    if ! command -v docker &> /dev/null; then
        log_error "Docker is not installed. Please install Docker first."
        log "Run: sudo $SCRIPT_DIR/docker.sh"
        exit 1
    fi

    # Check if Docker daemon is running
    if ! docker info &> /dev/null; then
        log_error "Docker daemon is not running. Please start Docker first."
        log "Run: sudo systemctl start docker"
        exit 1
    fi

    # Check if required scripts exist
    if [[ ! -f "$DOCKER_NETWORK_SCRIPT" ]]; then
        log_error "Docker network script not found: $DOCKER_NETWORK_SCRIPT"
        exit 1
    fi

    if [[ ! -x "$DOCKER_NETWORK_SCRIPT" ]]; then
        log "Making docker-network-setup.sh executable"
        chmod +x "$DOCKER_NETWORK_SCRIPT"
    fi

    if [[ ! -f "$NGINX_PROXY_SCRIPT" ]]; then
        log_error "Nginx proxy script not found: $NGINX_PROXY_SCRIPT"
        exit 1
    fi

    if [[ ! -x "$NGINX_PROXY_SCRIPT" ]]; then
        log "Making nginx-proxy-container.sh executable"
        chmod +x "$NGINX_PROXY_SCRIPT"
    fi

    log "Prerequisites check passed"
}

# Setup Docker network
setup_docker_network() {
    log "=== Setting up Docker network ==="
    
    if "$DOCKER_NETWORK_SCRIPT"; then
        log_success "Docker network setup completed"
        return 0
    else
        log_error "Docker network setup failed"
        return 1
    fi
}

# Setup Nginx proxy container
setup_nginx_proxy() {
    log "=== Setting up Nginx proxy container ==="
    
    if "$NGINX_PROXY_SCRIPT" create; then
        log_success "Nginx proxy container setup completed"
        return 0
    else
        log_error "Nginx proxy container setup failed"
        return 1
    fi
}

# Verify installation
verify_installation() {
    log "=== Verifying installation ==="

    local errors=0

    # Check if Docker network exists
    if docker network ls --format '{{.Name}}' | grep -q "^deployments-network$"; then
        log_success "Docker network 'deployments-network' exists"
    else
        log_error "Docker network 'deployments-network' does not exist"
        ((errors++))
    fi

    # Check if Nginx container is running
    if docker ps --format '{{.Names}}' | grep -q "^nginx-proxy$"; then
        log_success "Nginx proxy container is running"
    else
        log_error "Nginx proxy container is not running"
        ((errors++))
    fi

    # Check if Nginx container is on the correct network
    if docker inspect nginx-proxy --format '{{range $net, $conf := .NetworkSettings.Networks}}{{$net}}{{end}}' | grep -q "deployments-network"; then
        log_success "Nginx proxy container is on deployments-network"
    else
        log_error "Nginx proxy container is not on deployments-network"
        ((errors++))
    fi

    # Check if sites-enabled directory exists
    if [[ -d "/etc/nginx/sites-enabled" ]]; then
        log_success "Nginx sites-enabled directory exists"
    else
        log_error "Nginx sites-enabled directory does not exist"
        ((errors++))
    fi

    if [[ $errors -eq 0 ]]; then
        log_success "All verification checks passed"
        return 0
    else
        log_error "Verification failed with $errors error(s)"
        return 1
    fi
}

# Show status
show_status() {
    echo
    echo "=== Deployment Server Status ==="
    echo
    
    # Docker network status
    echo "Docker Network:"
    if docker network ls --format '{{.Name}}' | grep -q "^deployments-network$"; then
        local network_info
        network_info=$(docker network inspect deployments-network --format '{{.Name}} - {{.Driver}} - {{.Scope}}')
        echo "  ✅ $network_info"
    else
        echo "  ❌ deployments-network does not exist"
    fi
    echo
    
    # Nginx container status
    echo "Nginx Proxy Container:"
    if docker ps --format '{{.Names}}' | grep -q "^nginx-proxy$"; then
        local container_info
        container_info=$(docker ps --filter "name=nginx-proxy" --format "{{.Names}} - {{.Status}} - Ports: {{.Ports}}")
        echo "  ✅ $container_info"
    else
        echo "  ❌ nginx-proxy is not running"
    fi
    echo
    
    # Sites enabled count
    local site_count
    site_count=$(find /etc/nginx/sites-enabled -type f 2>/dev/null | wc -l)
    echo "Nginx Sites Enabled: $site_count"
    echo
}

# Main execution
main() {
    log "=== Deployment Server Provisioning Started ==="
    log "Script directory: $SCRIPT_DIR"
    
    check_prerequisites
    
    # Setup Docker network
    if ! setup_docker_network; then
        log_error "Failed to setup Docker network. Aborting."
        exit 1
    fi
    
    # Setup Nginx proxy container
    if ! setup_nginx_proxy; then
        log_error "Failed to setup Nginx proxy container. Aborting."
        exit 1
    fi
    
    # Verify installation
    if ! verify_installation; then
        log_error "Installation verification failed"
        exit 1
    fi
    
    log "=== Deployment Server Provisioning Completed ==="
    
    # Show status
    show_status
    
    echo "✅ Deployment server infrastructure is ready!"
    echo
    echo "Next steps:"
    echo "  1. Generate Nginx site configs using:"
    echo "     sudo $SCRIPT_DIR/nginx-site-template.sh <subdomain> <container_name> <port>"
    echo
    echo "  2. Enable a site by creating a symlink:"
    echo "     sudo ln -s /etc/nginx/sites-available/<subdomain> /etc/nginx/sites-enabled/<subdomain>"
    echo
    echo "  3. Reload Nginx proxy:"
    echo "     sudo $NGINX_PROXY_SCRIPT reload"
    echo
    echo "  4. Check Nginx proxy status:"
    echo "     sudo $NGINX_PROXY_SCRIPT status"
    echo
}

# Run main function
main "$@"

