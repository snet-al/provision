#!/bin/bash

# Check if both arguments are provided
if [ "$#" -ne 2 ]; then
    echo "Usage: $0 <key_name> <ssh_public_key_content>"
    echo "Example: $0 laptop 'ssh-rsa AAAAB3NzaC1...'"
    echo "Example: $0 work 'ssh-ed25519 AAAAC3Nz...'"
    exit 1
fi

KEY_NAME=$1
KEY_CONTENT=$2

# Validate SSH key format
if ! echo "$KEY_CONTENT" | grep -qE '^(ssh-rsa|ssh-ed25519|ecdsa-sha2-nistp256|ecdsa-sha2-nistp384|ecdsa-sha2-nistp521) '; then
    echo "Error: Invalid SSH key format"
    echo "Key should start with 'ssh-rsa', 'ssh-ed25519', or 'ecdsa-sha2-*'"
    exit 1
fi

# Create .ssh directory if it doesn't exist
mkdir -p ~/.ssh
chmod 700 ~/.ssh

# Create authorized_keys file if it doesn't exist
touch ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys

# Add a comment to identify the key
echo -e "\n# SSH key for $KEY_NAME (added on $(date '+%Y-%m-%d'))" >> ~/.ssh/authorized_keys

# Append the key with the name as a comment
echo "$KEY_CONTENT $KEY_NAME" >> ~/.ssh/authorized_keys

echo "SSH key '$KEY_NAME' has been added successfully"
echo "You can now connect using this key"

# Create a temporary file to display the fingerprint
TMP_KEY_FILE=$(mktemp)
echo "$KEY_CONTENT" > "$TMP_KEY_FILE"
ssh-keygen -l -f "$TMP_KEY_FILE"
rm "$TMP_KEY_FILE" 