#!/bin/bash

# Update package lists first
sudo apt update

# Add universe repository
sudo add-apt-repository -y universe

# Install basic system utilities
sudo apt install -y \
    vim \
    git \
    net-tools \
    libfuse2 \
    htop \
    tmux \
    curl \
    wget \
    unzip \
    software-properties-common

echo "Basic system setup complete."

# Now run the rest of the setup as the forge user
echo "Running remaining setup as forge user..."

#check first if the user exists
if id -u "forge" >/dev/null 2>&1; then
    echo "Forge user already exists."
else
    echo "Creating forge user..."
    ./create_user.sh
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
        read -p "Please enter the SSH public key for the forge user: " ssh_key
        
        if validate_ssh_key "$ssh_key"; then
            sudo -u forge ./add_ssh_key.sh "$key_name" "$ssh_key"
            if [ $? -eq 0 ]; then
                SSH_KEY_CONFIGURED=true
                echo "SSH key '$key_name' successfully configured for forge user."
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


# Execute Security hardening if user gives permission
read -p "Do you want to apply security hardening? (y/n): " security_hardening
if [ "$security_hardening" = "y" ]; then
    echo "Applying security hardening..."
    sudo -u forge ./security.sh
fi

# Execute rate limiting and service binding if user gives permission
read -p "Do you want to apply rate limiting and service binding security? (y/n): " rate_limiting
if [ "$rate_limiting" = "y" ]; then
    echo "Applying rate limiting and service binding security..."
    sudo -u forge ./security_ratelimit.sh
fi

# Execute Docker installation last
echo "Installing Docker..."
sudo -u forge ./docker.sh

echo "All installations and configurations complete. Please restart your system."
echo "After restart, you can login as the forge user using your SSH key."