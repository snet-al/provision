#!/bin/bash

# Configuration
PROXY_HOST="172.28.255.10"
PROXY_PORT="3128"
HTTP_PROXY="http://${PROXY_HOST}:${PROXY_PORT}"
HTTPS_PROXY="${HTTP_PROXY}"
NO_PROXY="localhost,127.0.0.1"

# Create Docker systemd drop-in directory if it doesn't exist
echo "Creating systemd override directory for Docker..."
sudo mkdir -p /etc/systemd/system/docker.service.d

# Create or overwrite proxy config file
echo "Writing Docker proxy configuration..."
cat <<EOF | sudo tee /etc/systemd/system/docker.service.d/http-proxy.conf > /dev/null
[Service]
Environment="HTTP_PROXY=${HTTP_PROXY}"
Environment="HTTPS_PROXY=${HTTPS_PROXY}"
Environment="NO_PROXY=${NO_PROXY}"
EOF

# Reload and restart Docker daemon
echo "Reloading and restarting Docker..."
sudo systemctl daemon-reexec
sudo systemctl daemon-reload
sudo systemctl restart docker

# Verify Docker daemon environment
echo "Verifying Docker daemon environment variables..."
sudo systemctl show --property=Environment docker

echo "✅ Docker proxy configuration applied."
echo "Try running: docker pull hello-world"
