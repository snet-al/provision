#!/bin/bash

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

# Get key name
while true; do
    read -p "Enter a name for this SSH key (e.g., laptop, work, deploy): " key_name
    if validate_key_name "$key_name"; then
        break
    else
        echo "Invalid key name. Use only letters, numbers, underscore, and hyphen."
    fi
done

# Get SSH key
read -p "Please enter the SSH public key: " ssh_key

if validate_ssh_key "$ssh_key"; then
    ./add_ssh_key.sh "$key_name" "$ssh_key"
    if [ $? -eq 0 ]; then
        echo "SSH key '$key_name' successfully added."
    else
        echo "Failed to add SSH key."
        exit 1
    fi
else
    echo "Invalid SSH key format. Key should start with 'ssh-rsa', 'ssh-ed25519', or 'ecdsa-sha2-*'"
    exit 1
fi