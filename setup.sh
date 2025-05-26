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

# Execute Docker installation
echo "Installing Docker..."
sudo ./docker.sh

# Execute Security hardening
echo "Applying security hardening..."
sudo ./security.sh

echo "All installations and configurations complete. Please restart your system."