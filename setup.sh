#!/bin/bash

# Ubuntu 24.04 LTS Server Provisioning Script
# Main orchestration script for server setup

set -euo pipefail  # Exit on error, undefined vars, pipe failures

HANDOFF_COMPLETE=false
if [[ "${1:-}" == "--handoff" ]]; then
    HANDOFF_COMPLETE=true
    shift
fi

# Directory configuration
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly LINUX_DIR="$SCRIPT_DIR/0-linux"

# Source shared utilities (includes config loading and logging)
# shellcheck source=0-linux/utils.sh
source "$LINUX_DIR/utils.sh"

readonly SECURITY_DIR="$ROOT_DIR/1-security"
readonly DOCKER_DIR="$ROOT_DIR/2-docker"
readonly PRIVATE_REPO_DIR="$ROOT_DIR/provision-servers"
readonly TARGET_USER_REPO="/home/$DEFAULT_USER/provision"
readonly PORTAINER_CONTAINER_NAME="portainer"
readonly PORTAINER_HTTPS_PORT="9443"
readonly PORTAINER_PASSWORD_MIN_LENGTH=12

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

    # Always ensure scripts have execute permissions before continuing
    ensure_script_permissions
}

########################################
# Helper functions
########################################

ensure_script_permissions() {
    log "Ensuring all scripts have execute permissions..."
    
    local scripts=(
        "$LINUX_DIR/create_user.sh"
        "$LINUX_DIR/add_ssh_key.sh"
        "$LINUX_DIR/sshkeys.sh"
        "$SECURITY_DIR/security.sh"
        "$SECURITY_DIR/security_ratelimit.sh"
        "$DOCKER_DIR/docker.sh"
        "$LINUX_DIR/after-setup.sh"
    )
    
    for script_path in "${scripts[@]}"; do
        if [[ -f "$script_path" ]]; then
            if [[ ! -x "$script_path" ]]; then
                log "Making $(basename "$script_path") executable..."
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

    log "Installing basic system utilities from config..."
    log "Packages: $BASIC_PACKAGES"
    
    # Convert space-separated string to array and install
    # shellcheck disable=SC2086
    if ! sudo apt install -y $BASIC_PACKAGES; then
        log_error "Failed to install basic system utilities"
        exit 1
    fi

    log "Basic system setup complete."
}

configure_updates_cron() {
    log "Configuring daily unattended upgrades (3:00 AM)..."

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

SELECTED_SERVER_TYPE=""

choose_server_type() {
    log "Select the server type to provision:"
    echo "1) Basic server"
    echo "2) Multi-deployment server"
    echo "3) Agents server"
    local choice
    while true; do
        read -p "Enter choice [1-3]: " choice
        case "$choice" in
            1) SELECTED_SERVER_TYPE="basic"; return 0 ;;
            2) SELECTED_SERVER_TYPE="multi_deployment"; return 0 ;;
            3) SELECTED_SERVER_TYPE="agents"; return 0 ;;
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

# Map server types to their folder names in provision-servers repo
get_server_type_folder() {
    local type="$1"
    case "$type" in
        multi_deployment) echo "deployment" ;;
        agents) echo "agents" ;;
        *) echo "" ;;
    esac
}

run_server_type_setup() {
    local type="$1"
    local server_folder=$(get_server_type_folder "$type")
    local setup_script="$PRIVATE_REPO_DIR/$server_folder/setup.sh"

    if [[ -x "$setup_script" ]]; then
        log "Running server type setup script: $setup_script with type '$type'"
        if ! sudo -u "$DEFAULT_USER" "$setup_script" "$type"; then
            log_error "Server type setup script failed"
            exit 1
        fi
        log "Server type setup completed successfully"
    else
        log_warning "Server type setup script not found or not executable at $setup_script. Skipping."
    fi
}

# Security hardening
apply_security_hardening() {
    local security_hardening
    read -p "Do you want to apply security hardening? (y/n): " security_hardening
    if [[ "$security_hardening" = "y" ]]; then
        log "Applying security hardening..."
        if ! "$SECURITY_DIR/security.sh"; then
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
        if ! "$SECURITY_DIR/security_ratelimit.sh"; then
            log_error "Rate limiting configuration failed"
            exit 1
        fi
        log "Rate limiting and service binding completed successfully"
    else
        log "Rate limiting configuration skipped by user choice"
    fi
}

install_docker() {
    log "Ensuring Docker is installed (default)..."
    local docker_script="$DOCKER_DIR/docker.sh"

    if [[ ! -x "$docker_script" ]]; then
        log_error "Docker installation script not found or not executable at $docker_script"
        exit 1
    fi

    if ! "$docker_script"; then
        log_error "Docker installation script failed"
        exit 1
    fi

    log "Docker installation completed."
}

prompt_portainer_admin_password() {
    log "Checking if Portainer admin password needs to be configured..."

    if ! command -v docker &>/dev/null; then
        log_warning "Docker CLI not available; skipping Portainer admin password prompt."
        return 0
    fi

    if ! sudo docker ps --format '{{.Names}}' | grep -Fxq "$PORTAINER_CONTAINER_NAME"; then
        log_warning "Portainer container '$PORTAINER_CONTAINER_NAME' is not running; skipping password prompt."
        return 0
    fi

    if ! command -v python3 &>/dev/null; then
        log_warning "python3 is required to securely prepare the Portainer password payload; skipping automatic initialization."
        log_warning "Complete the Portainer setup manually at https://<server-ip>:${PORTAINER_HTTPS_PORT}"
        return 0
    fi

    local status_code="000"
    local portainer_ready=false
    local attempt
    local max_attempts=20
    for ((attempt=1; attempt<=max_attempts; attempt++)); do
        if ! status_code=$(curl -sk --connect-timeout 5 --max-time 10 -o /dev/null -w '%{http_code}' "https://127.0.0.1:${PORTAINER_HTTPS_PORT}/api/status"); then
            status_code="000"
        fi

        if [[ "$status_code" == "200" ]]; then
            portainer_ready=true
            break
        fi

        sleep 2
    done

    if [[ "$portainer_ready" != true ]]; then
        log_warning "Portainer API is not reachable yet; complete the admin password setup manually via https://<server-ip>:${PORTAINER_HTTPS_PORT}"
        return 0
    fi

    echo
    echo "Portainer requires an admin password before its API and dashboard become available."
    echo "Leave the password blank to skip and finish the setup manually in your browser later."
    echo

    local portainer_password=""
    local portainer_password_confirm=""
    while true; do
        if ! read -rsp "Enter new Portainer admin password (min ${PORTAINER_PASSWORD_MIN_LENGTH} chars, blank to skip): " portainer_password; then
            echo
            log_warning "Input aborted; skipping Portainer admin password initialization."
            return 0
        fi
        echo

        if [[ -z "$portainer_password" ]]; then
            log_warning "Portainer admin password initialization skipped by user."
            return 0
        fi

        if ((${#portainer_password} < PORTAINER_PASSWORD_MIN_LENGTH)); then
            echo "Password must be at least ${PORTAINER_PASSWORD_MIN_LENGTH} characters."
            continue
        fi

        if ! read -rsp "Confirm Portainer admin password: " portainer_password_confirm; then
            echo
            log_warning "Input aborted; skipping Portainer admin password initialization."
            return 0
        fi
        echo

        if [[ "$portainer_password" != "$portainer_password_confirm" ]]; then
            echo "Passwords do not match. Please try again."
            continue
        fi

        break
    done

    local json_payload=""
    if ! json_payload=$(python3 - <<'PY' <<<"$portainer_password"
import json
import sys

password = sys.stdin.read().rstrip("\n")
print(json.dumps({"Username": "admin", "Password": password, "PasswordConfirm": password}))
PY
    ); then
        log_warning "Failed to prepare Portainer password payload; please finish the setup manually."
        return 0
    fi

    local response_file=""
    if ! response_file=$(mktemp); then
        log_warning "Unable to create temporary file for Portainer API response; please finish the setup manually."
        return 0
    fi

    local http_code="000"
    if ! http_code=$(curl -sk \
        --connect-timeout 5 \
        --max-time 15 \
        -w '%{http_code}' \
        -o "$response_file" \
        -H 'Content-Type: application/json' \
        -X POST "https://127.0.0.1:${PORTAINER_HTTPS_PORT}/api/users/admin/init" \
        --data "$json_payload"); then
        http_code="000"
    fi

    local response_body=""
    if ! response_body=$(cat "$response_file"); then
        response_body=""
    fi
    rm -f "$response_file"

    case "$http_code" in
        200|204)
            log "Portainer admin password configured successfully."
            ;;
        409)
            log "Portainer admin account already initialized; skipping password prompt."
            ;;
        *)
            log_warning "Failed to initialize Portainer admin user (HTTP $http_code). Response: ${response_body:-<empty>}"
            log_warning "Complete the Portainer setup manually by visiting https://<server-ip>:${PORTAINER_HTTPS_PORT}"
            ;;
    esac

    unset -v portainer_password portainer_password_confirm json_payload
}

create_forge_user() {
    log "Ensuring user '$DEFAULT_USER' exists..."
    if id -u "$DEFAULT_USER" >/dev/null 2>&1; then
        log "User '$DEFAULT_USER' already exists."
    else
        log "Creating user '$DEFAULT_USER'..."
        if ! "$LINUX_DIR/create_user.sh" "$DEFAULT_USER"; then
            log_error "Failed to create user '$DEFAULT_USER'"
            exit 1
        fi
        log "User '$DEFAULT_USER' created successfully"
    fi

    if ! sudo -u "$DEFAULT_USER" sudo -n true 2>/dev/null; then
        log_warning "User '$DEFAULT_USER' may not have proper sudo access"
    fi

    sudo touch "$LOG_FILE"
    sudo chown "$DEFAULT_USER:$DEFAULT_USER" "$LOG_FILE"
    sudo chmod 664 "$LOG_FILE"
}

handoff_to_user_repo() {
    if [[ "$HANDOFF_COMPLETE" == true ]]; then
        log "Running setup from user repository copy at $SCRIPT_DIR"
        return 0
    fi

    if [[ "$SCRIPT_DIR" == "$TARGET_USER_REPO" ]]; then
        log "Already executing from $TARGET_USER_REPO"
        return 0
    fi

    log "Synchronizing provisioning repo to $TARGET_USER_REPO..."

    if ! sudo -u "$DEFAULT_USER" mkdir -p "$TARGET_USER_REPO"; then
        log_error "Failed to create target directory $TARGET_USER_REPO"
        exit 1
    fi

    if ! rsync -a --delete "$ROOT_DIR/" "$TARGET_USER_REPO/"; then
        log_error "Failed to synchronize provisioning repo to $TARGET_USER_REPO"
        exit 1
    fi

    if ! chown -R "$DEFAULT_USER:$DEFAULT_USER" "$TARGET_USER_REPO"; then
        log_error "Failed to set ownership for $TARGET_USER_REPO"
        exit 1
    fi

    log "Re-launching setup from $TARGET_USER_REPO..."
    exec "$TARGET_USER_REPO/setup.sh" --handoff "$@"
}

ensure_provision_repo_access() {
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
    local known_hosts="$ssh_dir/known_hosts"
    if ! sudo -u "$DEFAULT_USER" ssh-keygen -F github.com >/dev/null; then
        sudo -u "$DEFAULT_USER" touch "$known_hosts"
        if ! sudo -u "$DEFAULT_USER" sh -c "ssh-keyscan github.com >> '$known_hosts' 2>/dev/null"; then
            log_warning "Failed to add github.com to known_hosts for $DEFAULT_USER"
        fi
    fi
    sudo chmod 644 "$known_hosts" || true

    log "Forge user SSH public key (add to git@github.com:snet-al/provision-servers.git access):"
    echo "--------------------------------------------"
    sudo -u "$DEFAULT_USER" cat "$pub_file"
    echo "--------------------------------------------"
    echo
    read -p "Press Enter after this key has been granted access to the private repo to continue..." _
}

clone_provision_servers_repo() {
    local target_dir="$PRIVATE_REPO_DIR"
    local repo_url="git@github.com:snet-al/provision-servers.git"

    log "Ensuring provision-servers repo is present at $target_dir ..."

    sudo -u "$DEFAULT_USER" mkdir -p "$target_dir"

    while true; do
        if [[ -d "$target_dir/.git" ]]; then
            log "Repo already exists, pulling latest..."
            if sudo -u "$DEFAULT_USER" git -C "$target_dir" pull --rebase --autostash; then
                log "Provision-servers repo updated at $target_dir"
                break
            else
                log_warning "Pull failed; retrying in 5s..."
                sleep 5
            fi
        else
            log "Cloning $repo_url into $target_dir ..."
            if sudo -u "$DEFAULT_USER" git clone "$repo_url" "$target_dir"; then
                log "Provision-servers repo cloned to $target_dir"
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
    
    if sudo -u "$DEFAULT_USER" "$LINUX_DIR/sshkeys.sh"; then
        log "SSH key configured for user '$DEFAULT_USER'."
    else
        log_error "Failed to add SSH key for '$DEFAULT_USER'"
        exit 1
    fi
}

run_post_setup() {
    log "Running post-setup cleanup..."
    if ! "$LINUX_DIR/after-setup.sh"; then
        log_error "Post-setup cleanup failed"
        exit 1
    fi
    log "Post-setup cleanup completed successfully"
}

########################################
# Main flow
########################################

if [[ "$HANDOFF_COMPLETE" == false && "$SCRIPT_DIR" != "$TARGET_USER_REPO" ]]; then
    init_logging
    create_forge_user
    handoff_to_user_repo "$@"
    exit 0
fi

init_logging
check_prerequisites
install_basic_utilities
configure_updates_cron

create_forge_user
install_docker
prompt_portainer_admin_password
choose_server_type
selected_type="$SELECTED_SERVER_TYPE"

if [[ "$selected_type" == "basic" ]]; then
    log "Basic server selected; skipping private provision repository setup."
else
    ensure_provision_repo_access
    clone_provision_servers_repo
    record_server_type "$selected_type"
    run_server_type_setup "$selected_type"
fi

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