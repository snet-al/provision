#!/bin/bash

# Nginx Proxy Container Setup Script
# Sets up and manages Nginx reverse proxy container on deployments-network

set -euo pipefail

# Configuration
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly LOG_FILE="/var/log/provision.log"

# Load Docker network configuration
if [[ -f "$SCRIPT_DIR/docker-network.conf" ]]; then
    # shellcheck source=docker-network.conf
    source "$SCRIPT_DIR/docker-network.conf"
else
    DEPLOYMENTS_NETWORK="deployments-network"
fi

# Set default ports if not configured
NGINX_PROXY_HTTP_PORT="${NGINX_PROXY_HTTP_PORT:-8080}"
NGINX_PROXY_HTTPS_PORT="${NGINX_PROXY_HTTPS_PORT:-8443}"

# Container configuration
readonly CONTAINER_NAME="nginx-proxy"
readonly NGINX_IMAGE="nginx:alpine"
readonly NGINX_CONF_DIR="/etc/nginx"
readonly HOST_SITES_ENABLED="/etc/nginx/sites-enabled"
readonly HOST_NGINX_CONF="$SCRIPT_DIR/nginx-proxy.conf"
readonly HOST_NGINX_CONF_PERMANENT="/etc/nginx/nginx-proxy.conf"
readonly CONTAINER_NGINX_CONF="$NGINX_CONF_DIR/nginx.conf"

# Logging functions
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] NGINX-PROXY: $1" | tee -a "$LOG_FILE"
}

log_error() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] NGINX-PROXY ERROR: $1" | tee -a "$LOG_FILE" >&2
}

# Check prerequisites
check_prerequisites() {
    log "Checking prerequisites..."

    # Check if Docker is installed
    if ! command -v docker &> /dev/null; then
        log_error "Docker is not installed. Please install Docker first."
        exit 1
    fi

    # Check if Docker daemon is running
    if ! docker info &> /dev/null; then
        log_error "Docker daemon is not running. Please start Docker first."
        exit 1
    fi

    # Check if network exists
    if ! docker network ls --format '{{.Name}}' | grep -q "^${DEPLOYMENTS_NETWORK}$"; then
        log_error "Docker network ${DEPLOYMENTS_NETWORK} does not exist."
        log "Please run docker-network-setup.sh first."
        exit 1
    fi

    # Check if nginx-proxy.conf exists
    if [[ ! -f "$HOST_NGINX_CONF" ]]; then
        log_error "Nginx configuration file not found: $HOST_NGINX_CONF"
        exit 1
    fi

    # Ensure sites-enabled directory exists
    if [[ ! -d "$HOST_SITES_ENABLED" ]]; then
        log "Creating sites-enabled directory: $HOST_SITES_ENABLED"
        mkdir -p "$HOST_SITES_ENABLED"
    fi

    # Check if ports are available
    check_port_availability "$NGINX_PROXY_HTTP_PORT" "HTTP"
    check_port_availability "$NGINX_PROXY_HTTPS_PORT" "HTTPS"

    log "Prerequisites check passed"
}

# Check if a port is available
check_port_availability() {
    local port=$1
    local name=$2

    if command -v ss &> /dev/null; then
        if ss -tuln | grep -q ":${port} "; then
            log_error "Port ${port} (${name}) is already in use"
            log "Please change NGINX_PROXY_HTTP_PORT or NGINX_PROXY_HTTPS_PORT in docker-network.conf"
            exit 1
        fi
    elif command -v netstat &> /dev/null; then
        if netstat -tuln | grep -q ":${port} "; then
            log_error "Port ${port} (${name}) is already in use"
            log "Please change NGINX_PROXY_HTTP_PORT or NGINX_PROXY_HTTPS_PORT in docker-network.conf"
            exit 1
        fi
    else
        log "Warning: Cannot check port availability (ss/netstat not available)"
    fi
}

# Check if container exists
container_exists() {
    docker ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"
}

# Check if container is running
container_running() {
    docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"
}

# Stop and remove existing container
remove_existing_container() {
    if container_exists; then
        log "Removing existing container: $CONTAINER_NAME"
        
        if container_running; then
            log "Stopping container: $CONTAINER_NAME"
            docker stop "$CONTAINER_NAME" > /dev/null
        fi
        
        docker rm "$CONTAINER_NAME" > /dev/null
        log "Container removed: $CONTAINER_NAME"
    fi
}

# Pull Nginx image if needed
pull_nginx_image() {
    log "Checking Nginx image: $NGINX_IMAGE"
    
    if ! docker image inspect "$NGINX_IMAGE" &> /dev/null; then
        log "Pulling Nginx image: $NGINX_IMAGE"
        docker pull "$NGINX_IMAGE"
        log "Nginx image pulled successfully"
    else
        log "Nginx image already exists"
    fi
}

# Create Nginx container
create_container() {
    log "Creating Nginx proxy container: $CONTAINER_NAME"

    # Copy nginx.conf to a permanent location
    log "Copying Nginx configuration to permanent location"
    mkdir -p "$(dirname "$HOST_NGINX_CONF_PERMANENT")"
    cp "$HOST_NGINX_CONF" "$HOST_NGINX_CONF_PERMANENT"
    chmod 644 "$HOST_NGINX_CONF_PERMANENT"

    # Create container with volume mounts
    log "Using ports: HTTP=${NGINX_PROXY_HTTP_PORT}, HTTPS=${NGINX_PROXY_HTTPS_PORT}"
    docker create \
        --name "$CONTAINER_NAME" \
        --network "$DEPLOYMENTS_NETWORK" \
        --restart unless-stopped \
        -p "${NGINX_PROXY_HTTP_PORT}:80" \
        -p "${NGINX_PROXY_HTTPS_PORT}:443" \
        -v "$HOST_SITES_ENABLED:/etc/nginx/sites-enabled:ro" \
        -v "$HOST_NGINX_CONF_PERMANENT:$CONTAINER_NGINX_CONF:ro" \
        "$NGINX_IMAGE" > /dev/null

    log "Container created: $CONTAINER_NAME"
}

# Start container
start_container() {
    log "Starting container: $CONTAINER_NAME"
    
    if docker start "$CONTAINER_NAME" > /dev/null; then
        log "Container started: $CONTAINER_NAME"
    else
        log_error "Failed to start container: $CONTAINER_NAME"
        exit 1
    fi
}

# Verify container
verify_container() {
    log "Verifying container: $CONTAINER_NAME"

    # Wait a moment for container to start
    sleep 2

    if ! container_running; then
        log_error "Container $CONTAINER_NAME is not running"
        log "Container logs:"
        docker logs "$CONTAINER_NAME" 2>&1 | tail -20
        exit 1
    fi

    # Test Nginx configuration
    if docker exec "$CONTAINER_NAME" nginx -t > /dev/null 2>&1; then
        log "Nginx configuration is valid"
    else
        log_error "Nginx configuration test failed"
        log "Configuration test output:"
        docker exec "$CONTAINER_NAME" nginx -t 2>&1 || true
        exit 1
    fi

    # Get container info
    local container_ip
    container_ip=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$CONTAINER_NAME")
    
    log "Container is running"
    log "Container IP on ${DEPLOYMENTS_NETWORK}: ${container_ip}"
    log "Container ports: ${NGINX_PROXY_HTTP_PORT}:80 (HTTP), ${NGINX_PROXY_HTTPS_PORT}:443 (HTTPS)"
}

# Reload Nginx configuration
reload_nginx() {
    if container_running; then
        log "Reloading Nginx configuration"
        if docker exec "$CONTAINER_NAME" nginx -s reload > /dev/null 2>&1; then
            log "Nginx configuration reloaded successfully"
        else
            log_error "Failed to reload Nginx configuration"
            return 1
        fi
    else
        log_error "Container is not running, cannot reload"
        return 1
    fi
}

# Main execution
main() {
    local action=${1:-create}

    case "$action" in
        create)
            log "=== Nginx Proxy Container Setup Started ==="
            check_prerequisites
            pull_nginx_image
            remove_existing_container
            create_container
            start_container
            verify_container
            log "=== Nginx Proxy Container Setup Completed ==="
            echo
            echo "✅ Nginx proxy container is running"
            echo "   Container name: $CONTAINER_NAME"
            echo "   Network: $DEPLOYMENTS_NETWORK"
            echo "   Ports: ${NGINX_PROXY_HTTP_PORT}:80 (HTTP), ${NGINX_PROXY_HTTPS_PORT}:443 (HTTPS)"
            echo "   To reload config: $0 reload"
            echo "   To view logs: docker logs $CONTAINER_NAME"
            echo ""
            echo "⚠️  Note: If host Nginx is running, configure it to proxy deployment subdomains"
            echo "   to http://localhost:${NGINX_PROXY_HTTP_PORT} or https://localhost:${NGINX_PROXY_HTTPS_PORT}"
            ;;
        reload)
            reload_nginx
            ;;
        restart)
            log "Restarting container: $CONTAINER_NAME"
            if container_exists; then
                docker restart "$CONTAINER_NAME" > /dev/null
                log "Container restarted"
            else
                log_error "Container does not exist"
                exit 1
            fi
            ;;
        stop)
            log "Stopping container: $CONTAINER_NAME"
            if container_running; then
                docker stop "$CONTAINER_NAME" > /dev/null
                log "Container stopped"
            else
                log "Container is not running"
            fi
            ;;
        start)
            log "Starting container: $CONTAINER_NAME"
            if container_exists; then
                start_container
                verify_container
            else
                log_error "Container does not exist. Run with 'create' action first."
                exit 1
            fi
            ;;
        status)
            if container_running; then
                echo "Container is running"
                docker ps --filter "name=$CONTAINER_NAME" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
            elif container_exists; then
                echo "Container exists but is not running"
            else
                echo "Container does not exist"
            fi
            ;;
        *)
            echo "Usage: $0 {create|reload|restart|stop|start|status}"
            echo
            echo "Actions:"
            echo "  create   - Create and start the Nginx proxy container"
            echo "  reload   - Reload Nginx configuration"
            echo "  restart  - Restart the container"
            echo "  stop     - Stop the container"
            echo "  start    - Start the container"
            echo "  status   - Show container status"
            exit 1
            ;;
    esac
}

# Run main function
main "$@"

