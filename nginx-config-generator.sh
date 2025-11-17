#!/bin/bash

# Nginx Config Generator
# Wrapper script that calls nginx-site-template.sh
# This script generates Nginx site configurations from template

set -euo pipefail

# Configuration
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly TEMPLATE_SCRIPT="$SCRIPT_DIR/nginx-site-template.sh"

# Check if template script exists
if [[ ! -f "$TEMPLATE_SCRIPT" ]]; then
    echo "Error: nginx-site-template.sh not found: $TEMPLATE_SCRIPT" >&2
    exit 1
fi

# Make sure template script is executable
if [[ ! -x "$TEMPLATE_SCRIPT" ]]; then
    chmod +x "$TEMPLATE_SCRIPT"
fi

# Call the template script with all arguments
exec "$TEMPLATE_SCRIPT" "$@"

