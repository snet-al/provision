#!/bin/bash

# Interactive SSH key management script
# Provides a user-friendly interface for adding SSH keys

set -euo pipefail  # Exit on error, undefined vars, pipe failures

# Configuration
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source shared utilities with prefix
LOG_PREFIX="SSH-KEYS"
source "$SCRIPT_DIR/utils.sh"

# Colors for output
readonly GREEN='\033[0;32m'
readonly RED='\033[0;31m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m' # No Color

# Function to validate SSH key
validate_ssh_key() {
    local key=$1

    # Check basic format
    if ! echo "$key" | grep -qE '^(ssh-rsa|ssh-ed25519|ecdsa-sha2-nistp256|ecdsa-sha2-nistp384|ecdsa-sha2-nistp521) '; then
        return 1
    fi

    # Check if key has proper structure
    local key_parts
    read -ra key_parts <<< "$key"

    if [[ ${#key_parts[@]} -lt 2 ]]; then
        return 1
    fi

    return 0
}

# Function to validate key name
validate_key_name() {
    local name=$1

    # Check if name contains only allowed characters
    if ! echo "$name" | grep -qE '^[a-zA-Z0-9_-]+$'; then
        return 1
    fi

    # Check name length
    if [[ ${#name} -lt 1 || ${#name} -gt 50 ]]; then
        return 1
    fi

    return 0
}

# Show welcome message
show_welcome() {
    echo -e "${BLUE}🔑 SSH Key Management Tool${NC}"
    echo "================================"
    echo
    echo "This tool helps you add SSH public keys to your account."
    echo "You'll need your SSH public key content (usually from ~/.ssh/id_rsa.pub)"
    echo
}

# Show key format help
show_key_help() {
    echo -e "${YELLOW}📋 SSH Key Format Help${NC}"
    echo "======================"
    echo
    echo "Supported key types:"
    echo "  • ssh-rsa (RSA keys)"
    echo "  • ssh-ed25519 (Ed25519 keys - recommended)"
    echo "  • ecdsa-sha2-nistp256 (ECDSA keys)"
    echo "  • ecdsa-sha2-nistp384 (ECDSA keys)"
    echo "  • ecdsa-sha2-nistp521 (ECDSA keys)"
    echo
    echo "Example key format:"
    echo "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIG4rT3vTt99Ox5kndS4HmgTrKBT8SKzhK4rhGkEVGlCI user@hostname"
    echo
    echo "To get your public key:"
    echo "  cat ~/.ssh/id_rsa.pub     (for RSA keys)"
    echo "  cat ~/.ssh/id_ed25519.pub (for Ed25519 keys)"
    echo
}

# Get key name with validation
get_key_name() {
    local key_name
    local attempts=0
    local max_attempts=3

    while [[ $attempts -lt $max_attempts ]]; do
        {
            echo -e "${BLUE}Step 1: Key Name${NC}"
            echo "Enter a descriptive name for this SSH key."
            echo "Examples: laptop, work, deploy, personal, server1"
            echo
        } >&2
        read -p "Key name: " key_name

        if validate_key_name "$key_name"; then
            echo -e "${GREEN}✓ Key name '$key_name' is valid${NC}" >&2
            echo "$key_name"
            return 0
        else
            ((attempts++))
            {
                echo -e "${RED}✗ Invalid key name${NC}"
                echo "Key name must:"
                echo "  • Be 1-50 characters long"
                echo "  • Use only letters, numbers, underscore, and hyphen"
                echo "  • Not contain spaces or special characters"
                echo
            } >&2

            if [[ $attempts -lt $max_attempts ]]; then
                {
                    echo "Please try again ($((max_attempts - attempts)) attempts remaining):"
                    echo
                } >&2
            fi
        fi
    done

    log_error "Failed to get valid key name after $max_attempts attempts"
    return 1
}

# Get SSH key with validation
get_ssh_key() {
    local ssh_key
    local attempts=0
    local max_attempts=3

    while [[ $attempts -lt $max_attempts ]]; do
        {
            echo -e "${BLUE}Step 2: SSH Public Key${NC}"
            echo "Paste your SSH public key below."
            echo "The key should start with ssh-rsa, ssh-ed25519, or ecdsa-sha2-*"
            echo
            echo "Need help? Type 'help' to see key format examples."
            echo
        } >&2
        read -p "SSH public key: " ssh_key

        # Check for help request
        if [[ "$ssh_key" == "help" ]]; then
            echo
            show_key_help
            continue
        fi

        if validate_ssh_key "$ssh_key"; then
            echo -e "${GREEN}✓ SSH key format is valid${NC}" >&2
            echo "$ssh_key"
            return 0
        else
            ((attempts++))
            {
                echo -e "${RED}✗ Invalid SSH key format${NC}"
                echo "The key should:"
                echo "  • Start with ssh-rsa, ssh-ed25519, or ecdsa-sha2-*"
                echo "  • Have at least two parts (type and key data)"
                echo "  • Be a complete public key"
                echo
            } >&2

            if [[ $attempts -lt $max_attempts ]]; then
                {
                    echo "Please try again ($((max_attempts - attempts)) attempts remaining):"
                    echo "Type 'help' for format examples."
                    echo
                } >&2
            fi
        fi
    done

    log_error "Failed to get valid SSH key after $max_attempts attempts"
    return 1
}

# Main function
main() {
    log "Starting interactive SSH key addition..."

    show_welcome

    # Get key name
    local key_name
    if ! key_name=$(get_key_name); then
        echo -e "${RED}❌ Failed to get valid key name. Exiting.${NC}"
        exit 1
    fi

    echo

    # Get SSH key
    local ssh_key
    if ! ssh_key=$(get_ssh_key); then
        echo -e "${RED}❌ Failed to get valid SSH key. Exiting.${NC}"
        exit 1
    fi

    echo
    echo -e "${BLUE}Step 3: Adding SSH Key${NC}"
    echo "Adding SSH key '$key_name'..."

    # Add the key using the add_ssh_key.sh script
    if "$SCRIPT_DIR/add_ssh_key.sh" "$key_name" "$ssh_key"; then
        echo
        echo -e "${GREEN}✅ SSH key '$key_name' successfully added!${NC}"
        echo
        echo "You can now connect to this server using your private key:"
        echo "  ssh $(whoami)@your-server-ip"
        echo
        log "SSH key '$key_name' added successfully for user $(whoami)"
    else
        echo
        echo -e "${RED}❌ Failed to add SSH key '$key_name'${NC}"
        echo "Please check the error messages above and try again."
        log_error "Failed to add SSH key '$key_name' for user $(whoami)"
        exit 1
    fi
}

# Show help
show_help() {
    echo "Interactive SSH Key Management Tool"
    echo
    echo "Usage: $0 [options]"
    echo
    echo "Options:"
    echo "  -h, --help    Show this help message"
    echo
    echo "This script provides an interactive interface for adding SSH public keys"
    echo "to your user account. It will guide you through:"
    echo "  1. Choosing a descriptive name for your key"
    echo "  2. Entering your SSH public key"
    echo "  3. Adding the key to your authorized_keys file"
    echo
    echo "The script validates input and provides helpful error messages."
    echo "Type 'help' when prompted for the SSH key to see format examples."
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