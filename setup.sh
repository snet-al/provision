#!/bin/bash

# Ubuntu 24.04 LTS Server Provisioning Script
# Main orchestration script for server setup

set -euo pipefail  # Exit on error, undefined vars, pipe failures

# Configuration
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly LOG_FILE="/var/log/provision.log"
readonly DEFAULT_USER="forge"
readonly PRIVATE_REPO_DIR="$SCRIPT_DIR/provision-private"

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

########################################
# Helper functions
########################################

# Basic input validators reused later
validate_ssh_key() {
    local key=$1
    if ! echo "$key" | grep -qE '^(ssh-rsa|ssh-ed25519|ecdsa-sha2-nistp256|ecdsa-sha2-nistp384|ecdsa-sha2-nistp521) '; then
        return 1
    fi
    return 0
}

validate_key_name() {
    local name=$1
    if ! echo "$name" | grep -qE '^[a-zA-Z0-9_-]+$'; then
        return 1
    fi
    return 0
}

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

install_basic_utilities() {
    log "Starting system package updates..."

    if ! sudo apt update; then
        log_error "Failed to update package lists"
        exit 1
    fi

    log "Adding universe repository..."
    if ! sudo add-apt-repository -y universe; then
        log_error "Failed to add universe repository"
        exit 1
    fi

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
        rsync \
        software-properties-common; then
        log_error "Failed to install basic system utilities"
        exit 1
    fi

    log "Basic system setup complete."
}

configure_updates_cron() {
    log "Configuring daily unattended upgrades (3:00 AM)..."

    if ! sudo apt-get install -y unattended-upgrades; then
        log_error "Failed to install unattended-upgrades"
        exit 1
    fi

    # Ensure release upgrades stay on LTS track (no automatic distro jumps)
    if [[ -f /etc/update-manager/release-upgrades ]]; then
        sudo sed -i 's/^Prompt=.*/Prompt=lts/' /etc/update-manager/release-upgrades
    else
        echo -e "Prompt=lts\n" | sudo tee /etc/update-manager/release-upgrades >/dev/null
    fi

    # Restrict unattended upgrades to security and regular updates for this codename
    local codename
    codename=$(. /etc/os-release && echo "$VERSION_CODENAME")
    cat <<EOF | sudo tee /etc/apt/apt.conf.d/50unattended-upgrades > /dev/null
Unattended-Upgrade::Origins-Pattern {
        "origin=Ubuntu,archive=\${distro_codename}-security";
        "origin=Ubuntu,archive=\${distro_codename}-updates";
};
Unattended-Upgrade::Automatic-Reboot "false";
EOF

    # Enable unattended upgrades
    cat <<'EOF' | sudo tee /etc/apt/apt.conf.d/20auto-upgrades > /dev/null
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF

    # Cron entry to run unattended-upgrade at 3 AM daily
    cat <<'EOF' | sudo tee /etc/cron.d/provision-unattended-upgrades > /dev/null
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin
0 3 * * * root unattended-upgrade -v
EOF

    sudo chmod 644 /etc/cron.d/provision-unattended-upgrades
    sudo systemctl enable --now unattended-upgrades || true

    log "Daily unattended upgrades configured."
}

choose_server_type() {
    log "Select the server type to provision:"
    echo "1) Multi-deployment server"
    echo "2) Agents server"
    echo "3) Docker + nginx (all apps in Docker)"

    local choice
    while true; do
        read -p "Enter choice [1-3]: " choice
        case "$choice" in
            1) echo "multi_deployment"; return 0 ;;
            2) echo "agents"; return 0 ;;
            3) echo "docker_nginx"; return 0 ;;
            *) echo "Invalid choice. Please enter 1, 2, or 3." ;;
        esac
    done
}

record_server_type() {
    local type="$1"
    local type_file="$PRIVATE_REPO_DIR/.server_type"

    sudo -u "$DEFAULT_USER" mkdir -p "$PRIVATE_REPO_DIR"
    echo "$type" | sudo -u "$DEFAULT_USER" tee "$type_file" >/dev/null
    log "Saved server type '$type' to $type_file"
}

run_private_repo_setup() {
    local type="$1"
    local repo_script="$PRIVATE_REPO_DIR/setup.sh"

    if [[ -x "$repo_script" ]]; then
        log "Running private repo setup with server type '$type'..."
        if ! sudo -u "$DEFAULT_USER" "$repo_script" "$type"; then
            log_error "Private repo setup script failed"
            exit 1
        fi
    else
        log_warning "Private repo setup script not found or not executable at $repo_script. Skipping."
    fi
}

# Security hardening
apply_security_hardening() {
    local security_hardening
    read -p "Do you want to apply security hardening? (y/n): " security_hardening
    if [[ "$security_hardening" = "y" ]]; then
        log "Applying security hardening..."
        if ! "$SCRIPT_DIR/security.sh"; then
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
        if ! "$SCRIPT_DIR/security_ratelimit.sh"; then
            log_error "Rate limiting configuration failed"
            exit 1
        fi
        log "Rate limiting and service binding completed successfully"
    else
        log "Rate limiting configuration skipped by user choice"
    fi
}

# Docker installation
create_forge_user() {
    log "Ensuring user '$DEFAULT_USER' exists..."
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

    if ! sudo -u "$DEFAULT_USER" sudo -n true 2>/dev/null; then
        log_warning "User '$DEFAULT_USER' may not have proper sudo access"
    fi
}

ensure_forge_repo_key() {
    local ssh_dir="/home/$DEFAULT_USER/.ssh"
    local key_file="$ssh_dir/id_ed25519"
    local pub_file="$key_file.pub"

    log "Preparing '$DEFAULT_USER' SSH key for repo access..."
    sudo -u "$DEFAULT_USER" mkdir -p "$ssh_dir"
    sudo chmod 700 "$ssh_dir"

    if [[ ! -f "$pub_file" ]]; then
        log "No SSH key found for '$DEFAULT_USER'. Generating ed25519 key..."
        if ! sudo -u "$DEFAULT_USER" ssh-keygen -t ed25519 -N "" -f "$key_file" >/dev/null; then
            log_error "Failed to generate SSH key for '$DEFAULT_USER'"
            exit 1
        fi
    fi

    # Ensure known_hosts has github.com to avoid prompts
    if ! sudo -u "$DEFAULT_USER" ssh-keygen -F github.com >/dev/null; then
        sudo -u "$DEFAULT_USER" ssh-keyscan github.com >> "$ssh_dir/known_hosts" 2>/dev/null || true
    fi
    sudo chmod 644 "$ssh_dir/known_hosts" || true

    log "Forge user SSH public key (add to git@github.com:datafynow/provision.git access):"
    echo "--------------------------------------------"
    sudo -u "$DEFAULT_USER" cat "$pub_file"
    echo "--------------------------------------------"
    echo
    read -p "Press Enter after this key has been granted access to the private repo to continue..." _
}

clone_provision_repo() {
    local target_dir="$PRIVATE_REPO_DIR"
    local repo_url="git@github.com:datafynow/provision.git"

    log "Ensuring private provision repo is present at $target_dir ..."

    sudo -u "$DEFAULT_USER" mkdir -p "$target_dir"

    while true; do
        if [[ -d "$target_dir/.git" ]]; then
            log "Repo already exists, pulling latest..."
            if sudo -u "$DEFAULT_USER" git -C "$target_dir" pull --rebase --autostash; then
                log "Provision repo updated at $target_dir"
                break
            else
                log_warning "Pull failed; retrying in 5s..."
                sleep 5
            fi
        else
            log "Cloning $repo_url into $target_dir ..."
            if sudo -u "$DEFAULT_USER" git clone "$repo_url" "$target_dir"; then
                log "Provision repo cloned to $target_dir"
                break
            else
                log_warning "Clone failed; retrying in 5s..."
                sleep 5
            fi
        fi
    done
}

prompt_forge_ssh_key() {
    log "Configure SSH key for user '$DEFAULT_USER' (passwordless login)..."
    local key_name ssh_key

    while true; do
        read -p "Enter a name for the forge SSH key (e.g., laptop, work): " key_name
        if validate_key_name "$key_name"; then
            break
        fi
        echo "Invalid key name. Use letters, numbers, underscore, or hyphen."
    done

    while true; do
        read -p "Paste the SSH public key for $DEFAULT_USER: " ssh_key
        if validate_ssh_key "$ssh_key"; then
            break
        fi
        echo "Invalid SSH key format. Must start with ssh-rsa/ssh-ed25519/ecdsa-sha2-*"
    done

    if sudo -u "$DEFAULT_USER" "$SCRIPT_DIR/add_ssh_key.sh" "$key_name" "$ssh_key"; then
        log "SSH key '$key_name' configured for user '$DEFAULT_USER'."
    else
        log_error "Failed to add SSH key for '$DEFAULT_USER'"
        exit 1
    fi
}

run_post_setup() {
    log "Running post-setup cleanup..."
    if ! "$SCRIPT_DIR/after-setup.sh"; then
        log_error "Post-setup cleanup failed"
        exit 1
    fi
    log "Post-setup cleanup completed successfully"
}

########################################
# Main flow
########################################

init_logging
check_prerequisites
ensure_script_permissions
install_basic_utilities
configure_updates_cron

create_forge_user
ensure_forge_repo_key
selected_type=$(choose_server_type)
clone_provision_repo
record_server_type "$selected_type"
run_private_repo_setup "$selected_type"

apply_security_hardening
apply_rate_limiting
prompt_forge_ssh_key
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