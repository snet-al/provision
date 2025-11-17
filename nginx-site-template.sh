#!/bin/bash

# Nginx Site Configuration Generator
# Generates Nginx site configurations from template

set -euo pipefail

# Configuration
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly TEMPLATE_FILE="$SCRIPT_DIR/nginx-site-template.conf"
readonly LOG_FILE="/var/log/provision.log"

# Logging functions
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] NGINX-TEMPLATE: $1" | tee -a "$LOG_FILE"
}

log_error() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] NGINX-TEMPLATE ERROR: $1" | tee -a "$LOG_FILE" >&2
}

# Show usage
show_usage() {
    cat << EOF
Usage: $0 <subdomain> <container_name> <container_port> [output_file]

Generates an Nginx site configuration from template.

Arguments:
  subdomain        The subdomain (e.g., d-user1-dataset1.datafynow.ai)
  container_name   The Docker container name (e.g., deploy-user1-dataset1)
  container_port   The port the container listens on (e.g., 8080)
  output_file      Optional output file path (default: /etc/nginx/sites-available/{subdomain})

Examples:
  $0 d-user1-dataset1.datafynow.ai deploy-user1-dataset1 8080
  $0 d-user2-dataset2.datafynow.ai deploy-user2-dataset2 3000 /tmp/test.conf

EOF
}

# Validate arguments
validate_args() {
    if [[ $# -lt 3 ]]; then
        log_error "Missing required arguments"
        show_usage
        exit 1
    fi

    local subdomain=$1
    local container_name=$2
    local container_port=$3

    # Validate subdomain format
    if [[ ! "$subdomain" =~ ^[a-zA-Z0-9.-]+\.datafynow\.ai$ ]]; then
        log_error "Invalid subdomain format: $subdomain (must end with .datafynow.ai)"
        exit 1
    fi

    # Validate container name format
    if [[ ! "$container_name" =~ ^[a-zA-Z0-9][a-zA-Z0-9_-]*$ ]]; then
        log_error "Invalid container name format: $container_name"
        exit 1
    fi

    # Validate port is a number
    if [[ ! "$container_port" =~ ^[0-9]+$ ]] || [[ $container_port -lt 1 ]] || [[ $container_port -gt 65535 ]]; then
        log_error "Invalid port number: $container_port (must be 1-65535)"
        exit 1
    fi
}

# Check if template file exists
check_template() {
    if [[ ! -f "$TEMPLATE_FILE" ]]; then
        log_error "Template file not found: $TEMPLATE_FILE"
        exit 1
    fi
}

# Generate configuration from template
generate_config() {
    local subdomain=$1
    local container_name=$2
    local container_port=$3
    local output_file=${4:-"/etc/nginx/sites-available/${subdomain}"}

    log "Generating Nginx config for $subdomain -> $container_name:$container_port"

    # Create output directory if it doesn't exist
    local output_dir
    output_dir=$(dirname "$output_file")
    if [[ ! -d "$output_dir" ]]; then
        log "Creating directory: $output_dir"
        sudo mkdir -p "$output_dir"
    fi

    # Generate config by replacing template variables
    sed -e "s/{SUBDOMAIN}/$subdomain/g" \
        -e "s/{CONTAINER_NAME}/$container_name/g" \
        -e "s/{CONTAINER_PORT}/$container_port/g" \
        "$TEMPLATE_FILE" | sudo tee "$output_file" > /dev/null

    log "Configuration generated: $output_file"
    echo "$output_file"
}

# Main execution
main() {
    local subdomain=$1
    local container_name=$2
    local container_port=$3
    local output_file=${4:-}

    validate_args "$@"
    check_template
    generate_config "$subdomain" "$container_name" "$container_port" "$output_file"
}

# Run main function
main "$@"

