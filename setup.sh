#!/bin/bash

# Update package lists
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

# Execute Security hardening
echo "Applying security hardening..."
sudo ./security.sh

# Execute additional security configurations
echo "Applying additional security configurations..."
sudo ./extras.sh

# Create forge user
echo "Creating forge user..."
./create_user.sh

# Execute Docker installation last
echo "Installing Docker..."
sudo ./docker.sh

echo "All installations and configurations complete. Please restart your system."
echo "After restart, you can login as the forge user."