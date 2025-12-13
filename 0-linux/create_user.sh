#!/bin/bash

# User creation script with enhanced error handling
# Creates a new user with sudo access and proper SSH configuration

set -euo pipefail  # Exit on error, undefined vars, pipe failures

# Source shared utilities
source "$(dirname "${BASH_SOURCE[0]}")/utils.sh"

# Validate username
validate_username() {
    local username=$1

    # Check if username is valid (alphanumeric, underscore, hyphen)
    if ! [[ "$username" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        log_error "Invalid username: $username. Use only letters, numbers, underscore, and hyphen."
        return 1
    fi

    # Check username length (3-32 characters)
    if [[ ${#username} -lt 3 || ${#username} -gt 32 ]]; then
        log_error "Username must be between 3 and 32 characters long"
        return 1
    fi

    # Check if username starts with a letter
    if ! [[ "$username" =~ ^[a-zA-Z] ]]; then
        log_error "Username must start with a letter"
        return 1
    fi

    return 0
}

# Check prerequisites
check_prerequisites() {
    # Check if running as root or with sudo
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root or with sudo"
        exit 1
    fi
}

# Set default username from config if no argument provided
USERNAME=${1:-$DEFAULT_USER}

# Validate inputs
if ! validate_username "$USERNAME"; then
    exit 1
fi

check_prerequisites

log "Starting user creation process for: $USERNAME"

# Check if user already exists
if id "$USERNAME" &>/dev/null; then
    log "User '$USERNAME' already exists. Checking configuration..."

    # Verify user is in sudo group
    if groups "$USERNAME" | grep -q "\bsudo\b"; then
        log "User '$USERNAME' already has sudo access"
    else
        log "Adding user '$USERNAME' to sudo group..."
        if ! sudo usermod -aG sudo "$USERNAME"; then
            log_error "Failed to add user '$USERNAME' to sudo group"
            exit 1
        fi
    fi
else
    # Create new user
    log "Creating new user: $USERNAME"
    if ! sudo adduser --gecos "" "$USERNAME"; then
        log_error "Failed to create user: $USERNAME"
        exit 1
    fi

    # Add user to sudo group
    log "Adding user '$USERNAME' to sudo group..."
    if ! sudo usermod -aG sudo "$USERNAME"; then
        log_error "Failed to add user '$USERNAME' to sudo group"
        exit 1
    fi
fi

# Create SSH directory for the new user
log "Setting up SSH directory for user '$USERNAME'..."
USER_HOME="/home/$USERNAME"
SSH_DIR="$USER_HOME/.ssh"

if ! sudo mkdir -p "$SSH_DIR"; then
    log_error "Failed to create SSH directory: $SSH_DIR"
    exit 1
fi

if ! sudo chmod 700 "$SSH_DIR"; then
    log_error "Failed to set permissions on SSH directory: $SSH_DIR"
    exit 1
fi

# Copy the authorized_keys if it exists in root
if [[ -f ~/.ssh/authorized_keys ]]; then
    log "Copying existing authorized_keys from root to user '$USERNAME'..."
    if sudo cp ~/.ssh/authorized_keys "$SSH_DIR/"; then
        log "Authorized keys copied successfully"
    else
        log_error "Failed to copy authorized_keys"
        exit 1
    fi

    # Set proper ownership and permissions
    if ! sudo chown -R "$USERNAME:$USERNAME" "$SSH_DIR"; then
        log_error "Failed to set ownership for SSH directory"
        exit 1
    fi

    if ! sudo chmod 600 "$SSH_DIR/authorized_keys"; then
        log_error "Failed to set permissions on authorized_keys"
        exit 1
    fi
else
    # Just set ownership for the SSH directory
    if ! sudo chown -R "$USERNAME:$USERNAME" "$SSH_DIR"; then
        log_error "Failed to set ownership for SSH directory"
        exit 1
    fi
    log "No existing authorized_keys found in root directory"
fi

# Add user to docker group if docker is installed
if command -v docker &>/dev/null; then
    log "Docker detected. Adding user '$USERNAME' to docker group..."
    if sudo usermod -aG docker "$USERNAME"; then
        log "User '$USERNAME' added to docker group successfully"
    else
        log_error "Failed to add user '$USERNAME' to docker group"
        exit 1
    fi
else
    log "Docker not installed. Skipping docker group assignment."
fi

log "User '$USERNAME' has been created and configured successfully with:"
log "  - Sudo access"
log "  - SSH directory setup"
log "  - Docker group membership (if Docker is installed)"

echo
echo "✅ User creation completed successfully!"
echo "👤 Username: $USERNAME"
echo "🏠 Home directory: $USER_HOME"
echo "🔑 SSH directory: $SSH_DIR"
echo
echo "📋 Next steps:"
echo "   1. Add SSH keys using: ./add_ssh_key.sh <key_name> '<public_key>'"
echo "   2. Or use interactive script: ./sshkeys.sh"
echo "   3. Test sudo access: sudo -u $USERNAME sudo -l"