#!/bin/bash

# Docker installation script with enhanced error handling
# Installs Docker CE with compose plugin and configures user access

set -euo pipefail  # Exit on error, undefined vars, pipe failures

# Configuration
readonly LOG_FILE="/var/log/provision.log"
readonly DOCKER_GPG_URL="https://download.docker.com/linux/ubuntu/gpg"
readonly DOCKER_GPG_KEY="/etc/apt/keyrings/docker.asc"
readonly PORTAINER_IMAGE="portainer/portainer-ce:latest"
readonly PORTAINER_CONTAINER_NAME="portainer"
readonly PORTAINER_VOLUME_NAME="portainer_data"
readonly PORTAINER_HTTP_PORT="8000"
readonly PORTAINER_HTTPS_PORT="9443"

# Ensure log file is accessible
ensure_log_file() {
    if [[ ! -f "$LOG_FILE" ]]; then
        touch "$LOG_FILE"
        chmod 644 "$LOG_FILE"
    fi
}

# Logging functions
log() {
    ensure_log_file
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] DOCKER: $1"
}

log_error() {
    ensure_log_file
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] DOCKER ERROR: $1" >&2
}

log_warning() {
    ensure_log_file
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] DOCKER WARNING: $1"
}

# Check prerequisites
check_prerequisites() {
    log "Checking Docker installation prerequisites..."

    # Check if running as root or with sudo
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root or with sudo"
        exit 1
    fi

    # Check internet connectivity with multiple methods
    log "Checking internet connectivity..."
    local connectivity_ok=false
    
    # Method 1: Try ping to Google DNS
    if ping -c 1 8.8.8.8 &>/dev/null; then
        connectivity_ok=true
        log "Internet connectivity confirmed via ping to 8.8.8.8"
    else
        log "Ping to 8.8.8.8 failed, trying alternative methods..."
        
        # Method 2: Try curl to a reliable endpoint
        if curl -s --connect-timeout 5 --max-time 10 https://httpbin.org/ip &>/dev/null; then
            connectivity_ok=true
            log "Internet connectivity confirmed via HTTPS to httpbin.org"
        else
            # Method 3: Try DNS resolution
            if nslookup google.com &>/dev/null; then
                connectivity_ok=true
                log "Internet connectivity confirmed via DNS resolution"
            else
                # Method 4: Try apt update (which will fail gracefully if no internet)
                if timeout 10 apt update &>/dev/null; then
                    connectivity_ok=true
                    log "Internet connectivity confirmed via apt update"
                fi
            fi
        fi
    fi
    
    if [[ "$connectivity_ok" = false ]]; then
        log_error "No internet connectivity detected using multiple methods."
        log_error "Docker cannot be downloaded without internet access."
        
        read -p "Do you want to continue anyway? (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            log "Docker installation cancelled due to network connectivity issues"
            exit 1
        else
            log "Continuing Docker installation without internet connectivity verification"
        fi
    fi

    # Check if Docker is already installed
    if command -v docker &>/dev/null; then
        local docker_version
        docker_version=$(docker --version 2>/dev/null || echo "unknown")
        log "Docker is already installed: $docker_version"

        read -p "Docker is already installed. Do you want to continue anyway? (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            log "Docker installation cancelled by user"
            # exit 0 # continue in the case we are executing multiple time provision
        fi
    fi

    log "Prerequisites check completed"
}

# Install Docker dependencies
install_dependencies() {
    log "Installing Docker dependencies..."

    if ! sudo apt-get update; then
        log_error "Failed to update package lists"
        exit 1
    fi

    if ! sudo apt-get install -y ca-certificates curl; then
        log_error "Failed to install Docker dependencies"
        exit 1
    fi

    log "Docker dependencies installed successfully"
}

# Setup Docker GPG key
setup_docker_gpg() {
    log "Setting up Docker GPG key..."

    # Create keyrings directory
    if ! sudo install -m 0755 -d /etc/apt/keyrings; then
        log_error "Failed to create keyrings directory"
        exit 1
    fi

    # Download Docker GPG key
    if ! sudo curl -fsSL "$DOCKER_GPG_URL" -o "$DOCKER_GPG_KEY"; then
        log_error "Failed to download Docker GPG key"
        exit 1
    fi

    # Set proper permissions
    if ! sudo chmod a+r "$DOCKER_GPG_KEY"; then
        log_error "Failed to set permissions on Docker GPG key"
        exit 1
    fi

    log "Docker GPG key setup completed"
}

# Add Docker repository
add_docker_repository() {
    log "Adding Docker repository..."

    local repo_line
    repo_line="deb [arch=$(dpkg --print-architecture) signed-by=$DOCKER_GPG_KEY] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable"

    if ! echo "$repo_line" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null; then
        log_error "Failed to add Docker repository"
        exit 1
    fi

    log "Docker repository added successfully"
}

# Install Docker packages
install_docker_packages() {
    log "Installing Docker packages..."

    # Update package lists with new repository
    if ! sudo apt-get update; then
        log_error "Failed to update package lists after adding Docker repository"
        exit 1
    fi

    # Install Docker packages
    local packages=(
        "docker-ce"
        "docker-ce-cli"
        "containerd.io"
        "docker-buildx-plugin"
        "docker-compose-plugin"
    )

    if ! sudo apt-get install -y "${packages[@]}"; then
        log_error "Failed to install Docker packages"
        exit 1
    fi

    log "Docker packages installed successfully"
}

# Configure Docker access
configure_docker_access() {
    log "Configuring Docker access for user: forge"

    # Create docker group (may already exist)
    if ! sudo groupadd docker 2>/dev/null; then
        log "Docker group already exists"
    else
        log "Docker group created"
    fi

    # Add current user to docker group
    if ! sudo usermod -aG docker "forge"; then
        log_error "Failed to add user forge to docker group"
        exit 1
    fi

    log "User forge added to docker group successfully"
}

# Start and enable Docker service
start_docker_service() {
    log "Starting Docker service..."

    # Start Docker service
    if ! sudo systemctl start docker; then
        log_error "Failed to start Docker service"
        exit 1
    fi

    # Enable Docker service to start on boot
    if ! sudo systemctl enable docker; then
        log_error "Failed to enable Docker service"
        exit 1
    fi

    # Verify Docker is running
    if ! sudo systemctl is-active --quiet docker; then
        log_error "Docker service is not running after start attempt"
        exit 1
    fi

    log "Docker service started and enabled successfully"
}

# Verify Docker installation
verify_installation() {
    log "Verifying Docker installation..."

    # Check Docker version
    local docker_version
    if docker_version=$(sudo docker --version 2>/dev/null); then
        log "Docker version: $docker_version"
    else
        log_error "Failed to get Docker version"
        exit 1
    fi

    # Check Docker Compose version
    local compose_version
    if compose_version=$(sudo docker compose version 2>/dev/null); then
        log "Docker Compose version: $compose_version"
    else
        log_error "Failed to get Docker Compose version"
        exit 1
    fi

    # Test Docker with hello-world (optional)
    log "Testing Docker installation..."
    if sudo docker run --rm hello-world &>/dev/null; then
        log "Docker test completed successfully"
    else
        log_error "Docker test failed"
        exit 1
    fi

    log "Docker installation verification completed"
}

# Install / update Portainer
install_portainer() {
    log "Setting up Portainer CE dashboard..."

    # Ensure data volume exists
    if sudo docker volume ls --format '{{.Name}}' | grep -Fx "$PORTAINER_VOLUME_NAME" &>/dev/null; then
        log "Portainer data volume already exists ($PORTAINER_VOLUME_NAME)"
    else
        log "Creating Portainer data volume ($PORTAINER_VOLUME_NAME)..."
        if ! sudo docker volume create "$PORTAINER_VOLUME_NAME" >/dev/null; then
            log_error "Failed to create Portainer volume"
            exit 1
        fi
    fi

    # Pull latest Portainer image (tolerate failure but warn)
    if ! sudo docker pull "$PORTAINER_IMAGE"; then
        log_error "Failed to pull $PORTAINER_IMAGE"
        exit 1
    fi

    # If container exists, ensure it's running and updated
    if sudo docker ps -a --format '{{.Names}}' | grep -Fx "$PORTAINER_CONTAINER_NAME" &>/dev/null; then
        log "Portainer container already exists"
        log "Updating Portainer container to latest image..."
        if ! sudo docker stop "$PORTAINER_CONTAINER_NAME" >/dev/null 2>&1; then
            log_warning "Could not stop existing Portainer container (it may already be stopped)"
        fi
        sudo docker rm "$PORTAINER_CONTAINER_NAME" >/dev/null 2>&1 || true
    fi

    log "Creating Portainer container..."
    if ! sudo docker run -d \
        --name "$PORTAINER_CONTAINER_NAME" \
        --restart unless-stopped \
        -p "${PORTAINER_HTTP_PORT}:8000" \
        -p "${PORTAINER_HTTPS_PORT}:9443" \
        -v /var/run/docker.sock:/var/run/docker.sock \
        -v "${PORTAINER_VOLUME_NAME}":/data \
        "$PORTAINER_IMAGE" >/dev/null; then
        log_error "Failed to start Portainer container"
        exit 1
    fi

    log "Portainer is running (HTTPS port ${PORTAINER_HTTPS_PORT}, HTTP port ${PORTAINER_HTTP_PORT})."
    log "Access it via https://<server-ip>:${PORTAINER_HTTPS_PORT} after setting up the admin user."
}

# Main installation process
main() {
    log "Starting Docker installation process..."

    check_prerequisites
    install_dependencies
    setup_docker_gpg
    add_docker_repository
    install_docker_packages
    configure_docker_access
    start_docker_service
    verify_installation
    install_portainer

    log "Docker installation completed successfully"

    echo
    echo "✅ Docker installation completed successfully!"
    echo "🐳 Docker version: $(sudo docker --version)"
    echo "🔧 Docker Compose version: $(sudo docker compose version)"
    echo "👤 User 'forge' has been added to the docker group"
    echo
    echo "🛳  Portainer CE has been deployed on ports ${PORTAINER_HTTP_PORT} (HTTP) / ${PORTAINER_HTTPS_PORT} (HTTPS)"
    echo
    echo "📋 Next steps:"
    echo "   1. Visit https://<server-ip>:${PORTAINER_HTTPS_PORT} to finish Portainer setup"
    echo "   2. Log out and back in for docker group membership to take effect"
    echo "   3. Test Docker access: docker run hello-world"
    echo "   4. Check Docker status: systemctl status docker"
    echo
    echo "⚠️  Important: You must log out and log back in before using Docker without sudo!"
}

# Run main function
main "$@"