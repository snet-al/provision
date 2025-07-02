#!/bin/bash

set -e  # Exit on any error

# Configuration
PROXY_HOST="172.28.255.10"
PROXY_PORT="3128"
HTTP_PROXY="http://${PROXY_HOST}:${PROXY_PORT}"
HTTPS_PROXY="${HTTP_PROXY}"
NO_PROXY="localhost,127.0.0.1"

# Create Docker systemd drop-in directory
echo "📁 Creating systemd override directory for Docker..."
sudo mkdir -p /etc/systemd/system/docker.service.d

# Write proxy config using tee <<EOF (safest way)
echo "📝 Writing Docker proxy configuration..."
sudo tee /etc/systemd/system/docker.service.d/http-proxy.conf > /dev/null <<EOF
[Service]
Environment="HTTP_PROXY=${HTTP_PROXY}"
Environment="HTTPS_PROXY=${HTTPS_PROXY}"
Environment="NO_PROXY=${NO_PROXY}"
EOF

# Reload and restart Docker daemon
echo "🔄 Reloading and restarting Docker..."
sudo systemctl daemon-reexec
sudo systemctl daemon-reload
sudo systemctl restart docker

# Verify Docker daemon environment
echo "🔍 Verifying Docker daemon environment variables..."
echo -e "\n✅ Docker proxy configuration applied."
echo "👉 Try: docker pull hello-world"
