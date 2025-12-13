#!/bin/bash

# Security hardening script for Ubuntu 24.04 LTS
# Implements comprehensive security measures including firewall, fail2ban, and system hardening

set -euo pipefail  # Exit on error, undefined vars, pipe failures

# Directory configuration
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly LINUX_DIR="$SCRIPT_DIR/../0-linux"

# Source shared utilities (includes config loading and logging)
LOG_PREFIX="SECURITY"
# shellcheck source=../0-linux/utils.sh
source "$LINUX_DIR/utils.sh"

# Create backup directory
create_backup_dir() {
    if ! sudo mkdir -p "$BACKUP_DIR"; then
        log_error "Failed to create backup directory: $BACKUP_DIR"
        exit 1
    fi
    sudo chmod 700 "$BACKUP_DIR"
}

# Backup configuration file
backup_config() {
    local file=$1
    local backup_name
    backup_name="$(basename "$file").backup.$(date +%Y%m%d_%H%M%S)"

    if [[ -f "$file" ]]; then
        if sudo cp "$file" "$BACKUP_DIR/$backup_name"; then
            log "Backed up $file to $BACKUP_DIR/$backup_name"
        else
            log_error "Failed to backup $file"
            exit 1
        fi
    fi
}

# Check prerequisites
check_prerequisites() {
    log "Checking security hardening prerequisites..."

    # Check if running as root or with sudo
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root or with sudo"
        exit 1
    fi

    # Check internet connectivity
    if ! ping -c 1 8.8.8.8 &>/dev/null; then
        log_error "No internet connectivity detected. Security packages cannot be downloaded."
        exit 1
    fi

    log "Prerequisites check completed"
}

create_backup_dir
check_prerequisites

log "Starting security hardening process..."

# Update system first
log "Updating system packages..."
if ! sudo apt update; then
    log_error "Failed to update package lists"
    exit 1
fi

if ! sudo apt upgrade -y; then
    log_error "Failed to upgrade system packages"
    exit 1
fi

# Install security essentials from config
log "Installing security packages: $SECURITY_PACKAGES"
# shellcheck disable=SC2086
if ! sudo apt install -y $SECURITY_PACKAGES; then
    log_error "Failed to install security packages"
    exit 1
fi
log "Security packages installed successfully"

# Configure UFW (Uncomplicated Firewall)
configure_firewall() {
    log "Configuring UFW firewall..."

    # Check if UFW is already configured
    if sudo ufw status | grep -q "Status: active"; then
        log "UFW is already active. Checking configuration..."
    fi

    # Set default policies from config
    log "Setting default incoming policy: $UFW_DEFAULT_INCOMING"
    if ! sudo ufw --force default "$UFW_DEFAULT_INCOMING" incoming; then
        log_error "Failed to set UFW default $UFW_DEFAULT_INCOMING incoming"
        exit 1
    fi

    log "Setting default outgoing policy: $UFW_DEFAULT_OUTGOING"
    if ! sudo ufw --force default "$UFW_DEFAULT_OUTGOING" outgoing; then
        log_error "Failed to set UFW default $UFW_DEFAULT_OUTGOING outgoing"
        exit 1
    fi

    # Allow services from config
    log "Allowing services: $UFW_ALLOWED_SERVICES"
    for service in $UFW_ALLOWED_SERVICES; do
        if ! sudo ufw allow "$service"; then
            log_error "Failed to allow $service through firewall"
            exit 1
        fi
        log "Allowed $service through firewall"
    done

    # Enable firewall
    if ! sudo ufw --force enable; then
        log_error "Failed to enable UFW firewall"
        exit 1
    fi

    log "UFW firewall configured and enabled successfully"
}

configure_firewall

# Configure automatic security updates
configure_auto_updates() {
    log "Configuring automatic security updates..."

    # Configure unattended-upgrades non-interactively
    echo 'unattended-upgrades unattended-upgrades/enable_auto_updates boolean true' | sudo debconf-set-selections

    if ! sudo dpkg-reconfigure -f noninteractive unattended-upgrades; then
        log_error "Failed to configure automatic updates"
        exit 1
    fi

    log "Automatic security updates configured successfully"
}

# Configure Fail2ban
configure_fail2ban() {
    log "Configuring Fail2ban..."

    # Create jail.d directory
    if ! sudo mkdir -p /etc/fail2ban/jail.d; then
        log_error "Failed to create fail2ban jail.d directory"
        exit 1
    fi

    # Backup existing configuration
    backup_config "/etc/fail2ban/jail.d/sshd-hardening.conf"

    # Create SSH hardening configuration using values from config
    log "Fail2ban settings: maxretry=$FAIL2BAN_SSH_MAXRETRY, bantime=$FAIL2BAN_SSH_BANTIME, findtime=$FAIL2BAN_SSH_FINDTIME"
    if ! sudo tee /etc/fail2ban/jail.d/sshd-hardening.conf > /dev/null << EOF; then
[sshd]
enabled  = true
maxretry = $FAIL2BAN_SSH_MAXRETRY
bantime  = $FAIL2BAN_SSH_BANTIME
findtime = $FAIL2BAN_SSH_FINDTIME
EOF
        log_error "Failed to create fail2ban SSH configuration"
        exit 1
    fi

    # Start and enable Fail2ban
    if ! sudo systemctl restart fail2ban; then
        log_error "Failed to restart fail2ban service"
        exit 1
    fi

    if ! sudo systemctl enable fail2ban; then
        log_error "Failed to enable fail2ban service"
        exit 1
    fi

    log "Fail2ban configured and started successfully"
}

configure_auto_updates
configure_fail2ban

# Secure shared memory
secure_shared_memory() {
    log "Securing shared memory..."

    # Check if already configured
    if grep -q "/run/shm" /etc/fstab; then
        log "Shared memory security already configured"
        return 0
    fi

    # Backup fstab
    backup_config "/etc/fstab"

    # Add secure shared memory configuration
    if ! echo "tmpfs     /run/shm     tmpfs     defaults,noexec,nosuid     0     0" | sudo tee -a /etc/fstab > /dev/null; then
        log_error "Failed to configure secure shared memory"
        exit 1
    fi

    log "Shared memory secured successfully"
}

# Secure SSH configuration
secure_ssh_config() {
    log "Securing SSH configuration..."

    local sshd_config="/etc/ssh/sshd_config"

    # Backup SSH configuration
    backup_config "$sshd_config"

    # Check if security settings already exist
    if grep -q "# Security hardening" "$sshd_config"; then
        log "SSH security hardening already applied"
        return 0
    fi

    # Add security hardening settings using values from config
    log "SSH settings: Port=$SSH_PORT, MaxAuthTries=$SSH_MAX_AUTH_TRIES, PermitRootLogin=$SSH_PERMIT_ROOT_LOGIN"
    if ! sudo tee -a "$sshd_config" > /dev/null << EOL; then

# Security hardening (added by provision script)
Port $SSH_PORT
PermitRootLogin $SSH_PERMIT_ROOT_LOGIN
PasswordAuthentication $SSH_PASSWORD_AUTH
X11Forwarding $SSH_X11_FORWARDING
MaxAuthTries $SSH_MAX_AUTH_TRIES
Protocol 2
EOL
        log_error "Failed to update SSH configuration"
        exit 1
    fi

    # Validate SSH configuration
    if ! sudo sshd -t; then
        log_error "SSH configuration validation failed. Restoring backup."
        sudo cp "$BACKUP_DIR/$(basename "$sshd_config").backup."* "$sshd_config" 2>/dev/null || true
        exit 1
    fi

    log "SSH configuration secured successfully"
}

secure_shared_memory
secure_ssh_config

# Configure system-wide security limits
sudo tee -a /etc/security/limits.conf > /dev/null << EOL

# System-wide security limits
* soft core 0
* hard core 0
* soft nproc 1000
* hard nproc 2000
EOL

# Configure sysctl security parameters
sudo tee /etc/sysctl.d/99-security.conf > /dev/null << EOL
# IP Spoofing protection
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1

# Ignore ICMP broadcast requests
net.ipv4.icmp_echo_ignore_broadcasts = 1

# Disable source packet routing
net.ipv4.conf.all.accept_source_route = 0
net.ipv6.conf.all.accept_source_route = 0

# Ignore send redirects
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0

# Block SYN attacks
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_max_syn_backlog = 2048
net.ipv4.tcp_synack_retries = 2
net.ipv4.tcp_syn_retries = 5

# Log Martians
net.ipv4.conf.all.log_martians = 1
net.ipv4.conf.default.log_martians = 1

# Disable IPv6 if not needed
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
EOL

# Apply sysctl changes
sudo sysctl -p /etc/sysctl.d/99-security.conf

# Setup audit logging
sudo systemctl enable auditd
sudo systemctl start auditd

# Setup basic audit rules
sudo tee /etc/audit/rules.d/audit.rules > /dev/null << EOL
# Delete all existing rules
-D

# Buffer Size
-b 8192

# Failure Mode
-f 1

# Monitor file system mounts
-a always,exit -F arch=b64 -S mount -F auid>=1000 -F auid!=4294967295 -k mounts

# Monitor system admin actions
-w /etc/sudoers -p wa -k sudoers
-w /etc/sudoers.d/ -p wa -k sudoers

# Monitor security relevant files
-w /var/log/auth.log -p wa -k auth_log
-w /var/log/syslog -p wa -k syslog

# Monitor user and group files
-w /etc/group -p wa -k user_group_modification
-w /etc/passwd -p wa -k user_group_modification
-w /etc/gshadow -p wa -k user_group_modification
-w /etc/shadow -p wa -k user_group_modification
EOL

# Make script executable
sudo chmod +x /etc/audit/rules.d/audit.rules

# Restart audit daemon to apply rules
sudo service auditd restart

# Final message
echo "Security hardening complete. Please review the configurations and restart the system." 