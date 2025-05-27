validate_ssh_key() {
    local key=$1
    if ! echo "$key" | grep -qE '^(ssh-rsa|ssh-ed25519|ecdsa-sha2-nistp256|ecdsa-sha2-nistp384|ecdsa-sha2-nistp521) '; then
        return 1
    fi
    return 0
}

# Ensure SSH key is set up
echo "Checking SSH key configuration..."
MAX_ATTEMPTS=3
ATTEMPT=1
SSH_KEY_CONFIGURED=false

while [ $ATTEMPT -le $MAX_ATTEMPTS ] && [ "$SSH_KEY_CONFIGURED" = false ]; do
    if sudo -u forge test -f /home/forge/.ssh/authorized_keys && [ -s /home/forge/.ssh/authorized_keys ]; then
        echo "Forge user already has SSH key(s) configured."
        SSH_KEY_CONFIGURED=true
    else
        echo "No SSH key found for forge user. This is required for secure SSH access."
        echo "Attempt $ATTEMPT of $MAX_ATTEMPTS"
        read -p "Please enter the SSH public key for the forge user: " ssh_key
        
        if validate_ssh_key "$ssh_key"; then
            sudo -u forge ./add_ssh_key.sh "initial_key" "$ssh_key"
            if [ $? -eq 0 ]; then
                SSH_KEY_CONFIGURED=true
                echo "SSH key successfully configured for forge user."
            else
                echo "Failed to add SSH key. Please try again."
            fi
        else
            echo "Invalid SSH key format. Key should start with 'ssh-rsa', 'ssh-ed25519', or 'ecdsa-sha2-*'"
        fi
    fi
    ATTEMPT=$((ATTEMPT + 1))
done

if [ "$SSH_KEY_CONFIGURED" = false ]; then
    echo "Failed to configure SSH key after $MAX_ATTEMPTS attempts."
    echo "Setup cannot continue without proper SSH access configuration."
    exit 1
fi