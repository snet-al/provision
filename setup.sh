#!/bin/bash

# Update package lists first
sudo apt update

# Add universe repository
sudo add-apt-repository universe

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

# Create forge user first
echo "Creating forge user..."
./create_user.sh

# Now run the rest of the setup as the forge user
echo "Running remaining setup as forge user..."

# Execute Security hardening
echo "Applying security hardening..."
sudo -u forge ./security.sh

# Execute rate limiting and service binding
echo "Applying rate limiting and service binding security..."
sudo -u forge ./security_ratelimit.sh

# Execute Docker installation last
echo "Installing Docker..."
sudo -u forge ./docker.sh

echo "All installations and configurations complete. Please restart your system."
echo "After restart, you can login as the forge user."