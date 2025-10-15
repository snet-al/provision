#!/bin/bash

# Ubuntu 24.04 LTS Server Provisioning Script
# Main orchestration script for server setup

set -euo pipefail  # Exit on error, undefined vars, pipe failures

# Configuration
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly LOG_FILE="/var/log/provision.log"
readonly DEFAULT_USER="forge"

# Logging functions
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

log_error() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $1" | tee -a "$LOG_FILE" >&2
}

log_warning() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] WARNING: $1" | tee -a "$LOG_FILE"
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

    # Check Ubuntu version
    if ! grep -q "Ubuntu 24.04" /etc/os-release 2>/dev/null; then
        log_warning "This script is designed for Ubuntu 24.04 LTS"
        read -p "Continue anyway? (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            log "Setup cancelled by user"
            exit 0
        fi
    fi

    # Check internet connectivity with multiple methods
    log "Checking internet connectivity..."
    local connectivity_ok=false
    
    # Method 1: Try ping to Google DNS
    if ping -c 1 8.8.8.8 &>/dev/null; then
        connectivity_ok=true
        log "Internet connectivity confirmed via ping to 8.8.8.8"
    else
        log_warning "Ping to 8.8.8.8 failed, trying alternative methods..."
        
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
        log_error "Please check your network connection and try again."
        log_error "If you're behind a corporate firewall, ensure HTTP/HTTPS traffic is allowed."
        
        read -p "Do you want to continue anyway? (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            log "Setup cancelled due to network connectivity issues"
            exit 1
        else
            log_warning "Continuing setup without internet connectivity verification"
        fi
    fi

    # Check available disk space (minimum 2GB)
    local available_space=$(df / | awk 'NR==2 {print $4}')
    if [[ $available_space -lt 2097152 ]]; then  # 2GB in KB
        log_warning "Low disk space detected. At least 2GB recommended."
    fi

    log "Prerequisites check completed"
}

# Initialize logging
init_logging() {
    # Create log file if it doesn't exist
    sudo touch "$LOG_FILE"
    sudo chmod 644 "$LOG_FILE"

    log "=== Ubuntu Server Provisioning Started ==="
    log "Script version: $(date '+%Y%m%d')"
    log "Running as: $(whoami)"
    log "Working directory: $SCRIPT_DIR"
}

init_logging
check_prerequisites

log "Starting system package updates..."

# Update package lists first
if ! sudo apt update; then
    log_error "Failed to update package lists"
    exit 1
fi

# Add universe repository
log "Adding universe repository..."
if ! sudo add-apt-repository -y universe; then
    log_error "Failed to add universe repository"
    exit 1
fi

# Install basic system utilities
log "Installing basic system utilities..."
if ! sudo apt install -y \
    vim \
    git \
    net-tools \
    libfuse2 \
    htop \
    tmux \
    curl \
    wget \
    unzip \
    software-properties-common; then
    log_error "Failed to install basic system utilities"
    exit 1
fi

log "Basic system setup complete."

# User creation and validation
log "Checking user configuration..."

# Check if the user exists
if id -u "$DEFAULT_USER" >/dev/null 2>&1; then
    log "User '$DEFAULT_USER' already exists."
else
    log "Creating user '$DEFAULT_USER'..."
    if ! "$SCRIPT_DIR/create_user.sh" "$DEFAULT_USER"; then
        log_error "Failed to create user '$DEFAULT_USER'"
        exit 1
    fi
    log "User '$DEFAULT_USER' created successfully"
fi

# Verify user has sudo access
if ! sudo -u "$DEFAULT_USER" sudo -n true 2>/dev/null; then
    log_warning "User '$DEFAULT_USER' may not have proper sudo access"
fi

# Function to validate SSH key
validate_ssh_key() {
    local key=$1
    if ! echo "$key" | grep -qE '^(ssh-rsa|ssh-ed25519|ecdsa-sha2-nistp256|ecdsa-sha2-nistp384|ecdsa-sha2-nistp521) '; then
        return 1
    fi
    return 0
}

# Function to validate key name
validate_key_name() {
    local name=$1
    if ! echo "$name" | grep -qE '^[a-zA-Z0-9_-]+$'; then
        return 1
    fi
    return 0
}

# SSH key configuration
configure_ssh_keys() {
    log "Checking SSH key configuration..."
    local max_attempts=3
    local attempt=1
    local ssh_key_configured=false
    local user_home="/home/$DEFAULT_USER"

    while [[ $attempt -le $max_attempts ]] && [[ "$ssh_key_configured" = false ]]; do
        if sudo -u "$DEFAULT_USER" test -f "$user_home/.ssh/authorized_keys" && [[ -s "$user_home/.ssh/authorized_keys" ]]; then
            log "User '$DEFAULT_USER' already has SSH key(s) configured."
            ssh_key_configured=true
        else
            log "No SSH key found for user '$DEFAULT_USER'. This is required for secure SSH access."
            log "Attempt $attempt of $max_attempts"

            # Get key name with validation
            local key_name
            while true; do
                read -p "Enter a name for this SSH key (e.g., laptop, work, deploy): " key_name
                if validate_key_name "$key_name"; then
                    break
                else
                    echo "Invalid key name. Use only letters, numbers, underscore, and hyphen."
                fi
            done

            # Get SSH key with validation
            local ssh_key
            read -p "Please enter the SSH public key for the $DEFAULT_USER user: " ssh_key

            if validate_ssh_key "$ssh_key"; then
                if sudo -u "$DEFAULT_USER" "$SCRIPT_DIR/add_ssh_key.sh" "$key_name" "$ssh_key"; then
                    ssh_key_configured=true
                    log "SSH key '$key_name' successfully configured for user '$DEFAULT_USER'."
                else
                    log_error "Failed to add SSH key. Please try again."
                fi
            else
                log_error "Invalid SSH key format. Key should start with 'ssh-rsa', 'ssh-ed25519', or 'ecdsa-sha2-*'"
            fi
        fi
        ((attempt++))
    done

    if [[ "$ssh_key_configured" = false ]]; then
        log_error "Failed to configure SSH key after $max_attempts attempts."
        log_error "Setup cannot continue without proper SSH access configuration."
        exit 1
    fi
}

configure_ssh_keys

# Ensure all scripts have execute permissions
ensure_script_permissions() {
    log "Ensuring all scripts have execute permissions..."
    
    local scripts=(
        "create_user.sh"
        "add_ssh_key.sh"
        "security.sh"
        "security_ratelimit.sh"
        "docker.sh"
        "after-setup.sh"
    )
    
    for script in "${scripts[@]}"; do
        local script_path="$SCRIPT_DIR/$script"
        if [[ -f "$script_path" ]]; then
            if [[ ! -x "$script_path" ]]; then
                log "Making $script executable..."
                chmod +x "$script_path"
            fi
        else
            log_warning "Script not found: $script_path"
        fi
    done
    
    log "Script permissions check completed"
}

# Ensure all scripts have execute permissions before proceeding
ensure_script_permissions

# Security hardening
apply_security_hardening() {
    local security_hardening
    read -p "Do you want to apply security hardening? (y/n): " security_hardening
    if [[ "$security_hardening" = "y" ]]; then
        log "Applying security hardening..."
        if ! sudo -u "$DEFAULT_USER" "$SCRIPT_DIR/security.sh"; then
            log_error "Security hardening failed"
            exit 1
        fi
        log "Security hardening completed successfully"
    else
        log "Security hardening skipped by user choice"
    fi
}

# Rate limiting and service binding
apply_rate_limiting() {
    local rate_limiting
    read -p "Do you want to apply rate limiting and service binding security? (y/n): " rate_limiting
    if [[ "$rate_limiting" = "y" ]]; then
        log "Applying rate limiting and service binding security..."
        if ! sudo -u "$DEFAULT_USER" "$SCRIPT_DIR/security_ratelimit.sh"; then
            log_error "Rate limiting configuration failed"
            exit 1
        fi
        log "Rate limiting and service binding completed successfully"
    else
        log "Rate limiting configuration skipped by user choice"
    fi
}

# Docker installation
install_docker() {
    log "Installing Docker..."
    if ! "$SCRIPT_DIR/docker.sh"; then
        log_error "Docker installation failed"
        exit 1
    fi
    log "Docker installation completed successfully"
}

# Post-setup cleanup
run_post_setup() {
    log "Running post-setup cleanup..."
    if ! "$SCRIPT_DIR/after-setup.sh"; then
        log_error "Post-setup cleanup failed"
        exit 1
    fi
    log "Post-setup cleanup completed successfully"
}

# Execute main setup steps
apply_security_hardening
apply_rate_limiting
install_docker
run_post_setup

log "=== All installations and configurations complete ==="
log "Please restart your system to ensure all changes take effect."
log "After restart, you can login as the '$DEFAULT_USER' user using your SSH key."
log "Setup completed successfully at $(date)"

echo
echo "✅ Server provisioning completed successfully!"
echo "📋 Next steps:"
echo "   1. Restart the system: sudo reboot"
echo "   2. Test SSH access: ssh $DEFAULT_USER@your-server-ip"
echo "   3. Check logs: tail -f $LOG_FILE"
echo "   4. Review security settings in the README"