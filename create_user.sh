#!/bin/bash

# Set default username to forge if no argument provided
USERNAME=${1:-forge}

# Create new user
sudo adduser $USERNAME

# Add user to sudo group
sudo usermod -aG sudo $USERNAME

# Create SSH directory for the new user
sudo mkdir -p /home/$USERNAME/.ssh
sudo chmod 700 /home/$USERNAME/.ssh

# Copy the authorized_keys if it exists in root
if [ -f ~/.ssh/authorized_keys ]; then
    sudo cp ~/.ssh/authorized_keys /home/$USERNAME/.ssh/
    sudo chown -R $USERNAME:$USERNAME /home/$USERNAME/.ssh
    sudo chmod 600 /home/$USERNAME/.ssh/authorized_keys
fi

# Add user to docker group if docker is installed
if command -v docker &> /dev/null; then
    sudo usermod -aG docker $USERNAME
fi

echo "User $USERNAME has been created and configured with sudo access."
echo "If you want to add an SSH key for this user, use:"
echo "ssh-copy-id $USERNAME@<server-ip>" 