#!/bin/bash

# SSH key management script with enhanced error handling
# Adds SSH public keys to user's authorized_keys file

set -euo pipefail  # Exit on error, undefined vars, pipe failures

# Configuration
readonly LOG_FILE="/var/log/provision.log"

# Logging functions
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

log_error() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $1" | tee -a "$LOG_FILE" >&2
}

# Cleanup function for temporary files
cleanup() {
    local exit_code=$?
    if [[ -n "${TMP_KEY_FILE:-}" && -f "$TMP_KEY_FILE" ]]; then
        rm -f "$TMP_KEY_FILE"
    fi
    exit $exit_code
}

trap cleanup EXIT

# Usage information
show_usage() {
    echo "Usage: $0 <key_name> <ssh_public_key_content>"
    echo
    echo "Arguments:"
    echo "  key_name              A descriptive name for the SSH key"
    echo "  ssh_public_key_content The SSH public key content"
    echo
    echo "Examples:"
    echo "  $0 laptop 'ssh-rsa AAAAB3NzaC1yc2E...'"
    echo "  $0 work 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5...'"
    echo "  $0 deploy 'ecdsa-sha2-nistp256 AAAAE2VjZHNh...'"
    echo
    echo "Supported key types:"
    echo "  - ssh-rsa"
    echo "  - ssh-ed25519"
    echo "  - ecdsa-sha2-nistp256"
    echo "  - ecdsa-sha2-nistp384"
    echo "  - ecdsa-sha2-nistp521"
}

# Validate key name
validate_key_name() {
    local name=$1

    # Check if name contains only allowed characters
    if ! [[ "$name" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        log_error "Invalid key name: $name. Use only letters, numbers, underscore, and hyphen."
        return 1
    fi

    # Check name length (1-50 characters)
    if [[ ${#name} -lt 1 || ${#name} -gt 50 ]]; then
        log_error "Key name must be between 1 and 50 characters long"
        return 1
    fi

    return 0
}

# Validate SSH key format and content
validate_ssh_key() {
    local key=$1

    # Check basic format
    if ! echo "$key" | grep -qE '^(ssh-rsa|ssh-ed25519|ecdsa-sha2-nistp256|ecdsa-sha2-nistp384|ecdsa-sha2-nistp521) '; then
        log_error "Invalid SSH key format. Key should start with 'ssh-rsa', 'ssh-ed25519', or 'ecdsa-sha2-*'"
        return 1
    fi

    # Check if key has proper structure (type + key + optional comment)
    local key_parts
    read -ra key_parts <<< "$key"

    if [[ ${#key_parts[@]} -lt 2 ]]; then
        log_error "SSH key appears to be incomplete. Expected format: 'type key [comment]'"
        return 1
    fi

    # Validate key using ssh-keygen
    local tmp_file
    tmp_file=$(mktemp)
    echo "$key" > "$tmp_file"

    if ! ssh-keygen -l -f "$tmp_file" &>/dev/null; then
        rm -f "$tmp_file"
        log_error "SSH key validation failed. The key appears to be corrupted or invalid."
        return 1
    fi

    rm -f "$tmp_file"
    return 0
}

# Check if key already exists
check_key_exists() {
    local key_content=$1
    local key_name=$2
    local auth_keys_file="$HOME/.ssh/authorized_keys"

    if [[ -f "$auth_keys_file" ]]; then
        # Extract just the key part (second field) for comparison
        local new_key_part
        new_key_part=$(echo "$key_content" | awk '{print $2}')

        if grep -q "$new_key_part" "$auth_keys_file"; then
            log "Warning: This SSH key (or a very similar one) already exists in authorized_keys"
            read -p "Do you want to add it anyway? (y/N): " -n 1 -r
            echo
            if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                log "Key addition cancelled by user"
                return 1
            fi
        fi

        # Check if key name already exists
        if grep -q "# SSH key for $key_name" "$auth_keys_file"; then
            log "Warning: A key with name '$key_name' already exists"
            read -p "Do you want to add another key with the same name? (y/N): " -n 1 -r
            echo
            if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                log "Key addition cancelled by user"
                return 1
            fi
        fi
    fi

    return 0
}

# Main script logic
main() {
    # Check if both arguments are provided
    if [[ "$#" -ne 2 ]]; then
        log_error "Incorrect number of arguments"
        show_usage
        exit 1
    fi

    local key_name=$1
    local key_content=$2

    log "Starting SSH key addition process..."
    log "Key name: $key_name"
    log "User: $(whoami)"

    # Validate inputs
    if ! validate_key_name "$key_name"; then
        exit 1
    fi

    if ! validate_ssh_key "$key_content"; then
        exit 1
    fi

    # Check for existing keys
    if ! check_key_exists "$key_content" "$key_name"; then
        exit 1
    fi

    # Create .ssh directory if it doesn't exist
    log "Setting up SSH directory..."
    if ! mkdir -p ~/.ssh; then
        log_error "Failed to create .ssh directory"
        exit 1
    fi

    if ! chmod 700 ~/.ssh; then
        log_error "Failed to set permissions on .ssh directory"
        exit 1
    fi

    # Create authorized_keys file if it doesn't exist
    if ! touch ~/.ssh/authorized_keys; then
        log_error "Failed to create authorized_keys file"
        exit 1
    fi

    if ! chmod 600 ~/.ssh/authorized_keys; then
        log_error "Failed to set permissions on authorized_keys file"
        exit 1
    fi

    # Add the key
    log "Adding SSH key '$key_name'..."

    # Add a comment to identify the key
    if ! echo -e "\n# SSH key for $key_name (added on $(date '+%Y-%m-%d %H:%M:%S'))" >> ~/.ssh/authorized_keys; then
        log_error "Failed to add comment to authorized_keys"
        exit 1
    fi

    # Append the key with the name as a comment
    if ! echo "$key_content $key_name" >> ~/.ssh/authorized_keys; then
        log_error "Failed to add SSH key to authorized_keys"
        exit 1
    fi

    log "SSH key '$key_name' has been added successfully"

    # Display key fingerprint
    log "Generating key fingerprint..."
    TMP_KEY_FILE=$(mktemp)
    echo "$key_content" > "$TMP_KEY_FILE"

    local fingerprint
    if fingerprint=$(ssh-keygen -l -f "$TMP_KEY_FILE" 2>/dev/null); then
        log "Key fingerprint: $fingerprint"
        echo "🔑 Key fingerprint: $fingerprint"
    else
        log "Warning: Could not generate fingerprint for verification"
    fi

    echo
    echo "✅ SSH key added successfully!"
    echo "🏷️  Key name: $key_name"
    echo "👤 User: $(whoami)"
    echo "📁 Location: ~/.ssh/authorized_keys"
    echo
    echo "You can now connect using this key from the corresponding private key."
}

# Run main function with all arguments
main "$@"