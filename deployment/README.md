# Deployment Pipeline

Automated deployment pipeline for managing applications in Docker containers with nginx reverse proxy.

## Overview

This deployment pipeline automatically:
1. Monitors `/home/forge/deployments` for new repositories
2. Checks for `Dockerfile.pf` in each repository
3. Builds and runs Docker containers for valid repositories
4. Configures nginx reverse proxy with subdomain routing
5. Manages a shared Docker network for all services

## Architecture

- **Nginx Container**: Runs nginx in Docker, exposed on ports 80 (HTTP) and 443 (HTTPS)
- **Docker Network**: `deployment-network` connects nginx and all application containers
- **Subdomain Format**: `d_{userId}_dataset{datasetId}.datafynow.ai`
- **SSL/TLS**: Managed by Cloudflare (SSL termination at Cloudflare)

## Prerequisites

- Docker installed and running
- User `forge` in docker group (or run with sudo)
- `inotify-tools` package installed
- Write access to `/home/forge/deployments`

## Quick Start

### 1. Initial Setup

Run the setup script to initialize the deployment pipeline:

```bash
cd deployment
sudo ./setup.sh
```

This will:
- Create the Docker network `deployment-network`
- Start the nginx container
- Create necessary directories
- Set up nginx configuration structure

### 2. Start the Watcher

Start monitoring for new repositories:

```bash
# Run in foreground (for testing)
./watch.sh

# Run as daemon (for production)
./watch.sh --daemon
```

### 3. Deploy a Repository

Repositories should be placed in `/home/forge/deployments` with the naming format:
```
/home/forge/deployments/d_{userId}_dataset{datasetId}/
```

Each repository must contain a `Dockerfile.pf` file in its root directory.

Example:
```
/home/forge/deployments/d_123_dataset456/
└── Dockerfile.pf
```

The watcher will automatically detect new directories and trigger deployment.

## Manual Deployment

To manually deploy a specific repository:

```bash
./deploy.sh /home/forge/deployments/d_123_dataset456
```

## File Structure

```
deployment/
├── setup.sh              # Initial setup script
├── deploy.sh             # Single repository deployment
├── watch.sh              # File system watcher
├── nginx-template.conf   # Nginx configuration template
└── README.md             # This file
```

## Configuration

### Nginx Configuration

Nginx configurations are generated from `nginx-template.conf` and stored in:
- Template: `deployment/nginx-template.conf`
- Generated configs: `/home/forge/deployment/nginx-configs/sites-enabled/`

### Docker Network

All containers run on the `deployment-network` network, allowing them to communicate by container name.

### Port Configuration

By default, application containers are expected to expose port `8080`. This can be overridden by specifying an `EXPOSE` directive in the `Dockerfile.pf`.

Example:
```dockerfile
FROM node:18
WORKDIR /app
COPY . .
RUN npm install
EXPOSE 3000
CMD ["node", "index.js"]
```

In this case, the application will be accessible on port 3000.

## Subdomain Routing

Each deployment gets a subdomain based on the repository directory name:
- Directory: `d_123_dataset456`
- Subdomain: `d_123_dataset456.datafynow.ai`

The nginx configuration automatically routes traffic to the corresponding Docker container.

## Logging

All deployment activities are logged to `/var/log/deployment.log`:

```bash
# View logs
tail -f /var/log/deployment.log

# View nginx logs
docker logs deployment-nginx
```

## Error Handling

### Missing Dockerfile.pf

If a repository doesn't contain `Dockerfile.pf`, the deployment will fail with an error message logged to the deployment log.

### Invalid Directory Name

Directory names must follow the format `d_{userId}_dataset{datasetId}`. Invalid names will cause deployment to fail.

### Container Failures

If a container fails to start, the deployment will rollback:
- Container is removed
- Nginx configuration is removed
- Error is logged

## Troubleshooting

### Check Deployment Status

```bash
# List running containers
docker ps

# Check nginx container
docker ps | grep deployment-nginx

# View container logs
docker logs app_d123_dataset456
```

### Verify Nginx Configuration

```bash
# Test nginx configuration
docker exec deployment-nginx nginx -t

# Reload nginx manually
docker exec deployment-nginx nginx -s reload
```

### Check Network

```bash
# List Docker networks
docker network ls

# Inspect deployment network
docker network inspect deployment-network
```

### Restart Services

```bash
# Restart nginx container
docker restart deployment-nginx

# Restart watcher (if running as daemon)
pkill -f watch.sh
./watch.sh --daemon
```

## Maintenance

### Update Nginx Template

Edit `nginx-template.conf` and redeploy affected services, or manually update configurations in `/home/forge/deployment/nginx-configs/sites-enabled/`.

### Remove a Deployment

```bash
# Stop and remove container
docker stop app_d123_dataset456
docker rm app_d123_dataset456

# Remove nginx config
rm /home/forge/deployment/nginx-configs/sites-enabled/site_d123_dataset456.conf

# Reload nginx
docker exec deployment-nginx nginx -s reload
```

### Clean Up

```bash
# Remove all stopped containers
docker container prune

# Remove unused images
docker image prune

# Remove unused networks (be careful!)
docker network prune
```

## Security Notes

- All containers run on an isolated Docker network
- Nginx handles reverse proxy with Cloudflare real IP headers
- SSL/TLS termination is handled by Cloudflare
- Containers are configured with `--restart unless-stopped` for resilience

## Support

For issues or questions, check:
1. Deployment logs: `/var/log/deployment.log`
2. Nginx logs: `docker logs deployment-nginx`
3. Container logs: `docker logs <container-name>`

