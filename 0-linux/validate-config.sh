#!/bin/bash

# Configuration validation script
# Validates the provisioning configuration and system requirements

set -euo pipefail

# Colors for output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m' # No Color

# Counters
ERRORS=0
WARNINGS=0
CHECKS=0

# Validation-specific logging functions (with colors and counters)
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[PASS]${NC} $1"
    ((CHECKS++))
}

# Override log_warning for validation (with counter)
log_warning() {
    echo -e "${YELLOW}[WARN]${NC} $1"
    ((WARNINGS++))
    ((CHECKS++))
}

# Override log_error for validation (with counter)
log_error() {
    echo -e "${RED}[FAIL]${NC} $1"
    ((ERRORS++))
    ((CHECKS++))
}

# Config is already loaded by utils.sh, this function validates the load
load_config() {
    log_info "Configuration already loaded via utils.sh"
    log_success "Configuration loaded from: $PROVISION_CONFIG_FILE"
}

# Validate system requirements
validate_system() {
    log_info "Validating system requirements..."
    
    # Check Ubuntu version
    if [[ -f /etc/os-release ]]; then
        local version
        version=$(grep VERSION_ID /etc/os-release | cut -d'"' -f2)
        if [[ "$version" == "$REQUIRED_UBUNTU_VERSION" ]]; then
            log_success "Ubuntu version: $version (matches required $REQUIRED_UBUNTU_VERSION)"
        else
            log_warning "Ubuntu version: $version (expected $REQUIRED_UBUNTU_VERSION)"
        fi
    else
        log_error "Cannot determine Ubuntu version (/etc/os-release not found)"
    fi
    
    # Check disk space
    local available_space
    available_space=$(df / | awk 'NR==2 {print $4}')
    if [[ $available_space -ge $MIN_DISK_SPACE ]]; then
        local space_gb=$((available_space / 1024 / 1024))
        log_success "Available disk space: ${space_gb}GB (sufficient)"
    else
        local space_gb=$((available_space / 1024 / 1024))
        local required_gb=$((MIN_DISK_SPACE / 1024 / 1024))
        log_error "Available disk space: ${space_gb}GB (minimum ${required_gb}GB required)"
    fi
    
    # Check internet connectivity
    if ping -c 1 "$CONNECTIVITY_TEST_HOST" &>/dev/null; then
        log_success "Internet connectivity: Available"
    else
        log_error "Internet connectivity: Not available (required for package downloads)"
    fi
    
    # Check if running as root or with sudo
    if [[ $EUID -eq 0 ]]; then
        log_success "Privileges: Running as root"
    elif sudo -n true 2>/dev/null; then
        log_success "Privileges: Sudo access available"
    else
        log_error "Privileges: Root or sudo access required"
    fi
}

# Validate configuration values
validate_config() {
    log_info "Validating configuration values..."
    
    # Validate username
    if [[ "$DEFAULT_USER" =~ $USERNAME_PATTERN ]]; then
        log_success "Username: '$DEFAULT_USER' (valid format)"
    else
        log_error "Username: '$DEFAULT_USER' (invalid format - must start with letter, 3-32 chars, alphanumeric/underscore/hyphen only)"
    fi
    
    # Validate SSH port
    if [[ "$SSH_PORT" =~ ^[0-9]+$ ]] && [[ $SSH_PORT -ge $SSH_PORT_MIN ]] && [[ $SSH_PORT -le $SSH_PORT_MAX ]]; then
        log_success "SSH port: $SSH_PORT (valid range)"
    else
        log_error "SSH port: $SSH_PORT (must be between $SSH_PORT_MIN and $SSH_PORT_MAX)"
    fi
    
    # Validate log file path
    local log_dir
    log_dir=$(dirname "$LOG_FILE")
    if [[ -d "$log_dir" ]] || [[ "$log_dir" == "/var/log" ]]; then
        log_success "Log file path: $LOG_FILE (directory exists or is standard)"
    else
        log_warning "Log file path: $LOG_FILE (directory may need to be created)"
    fi
    
    # Validate backup directory
    local backup_parent
    backup_parent=$(dirname "$BACKUP_DIR")
    if [[ -d "$backup_parent" ]]; then
        log_success "Backup directory: $BACKUP_DIR (parent directory exists)"
    else
        log_error "Backup directory: $BACKUP_DIR (parent directory does not exist)"
    fi
    
    # Validate boolean values
    local boolean_vars=("AUTO_SECURITY_UPDATES" "ENABLE_AUDIT_LOGGING" "SECURE_SHARED_MEMORY" "BIND_SERVICES_LOCALHOST")
    for var in "${boolean_vars[@]}"; do
        local value="${!var}"
        if [[ "$value" =~ ^(true|false)$ ]]; then
            log_success "$var: $value (valid boolean)"
        else
            log_error "$var: $value (must be 'true' or 'false')"
        fi
    done
}

# Validate script files
validate_scripts() {
    log_info "Validating script files..."
    
    local required_scripts=(
        "$SCRIPT_DIR/setup.sh"
        "$SCRIPT_DIR/create_user.sh"
        "$SCRIPT_DIR/add_ssh_key.sh"
        "$SCRIPT_DIR/sshkeys.sh"
        "$SCRIPT_DIR/after-setup.sh"
        "$SECURITY_DIR/security.sh"
        "$SECURITY_DIR/security_ratelimit.sh"
        "$DOCKER_DIR/docker.sh"
    )
    
    for script_path in "${required_scripts[@]}"; do
        local display_path="${script_path#$ROOT_DIR/}"
        if [[ -f "$script_path" ]]; then
            if [[ -x "$script_path" ]]; then
                log_success "Script: ${display_path:-$script_path} (exists and executable)"
            else
                log_warning "Script: ${display_path:-$script_path} (exists but not executable)"
            fi
        else
            log_error "Script: ${display_path:-$script_path} (missing)"
        fi
    done
}

# Validate package availability
validate_packages() {
    log_info "Validating package availability..."
    
    # Update package lists (quietly)
    if sudo apt update &>/dev/null; then
        log_success "Package lists: Updated successfully"
    else
        log_error "Package lists: Failed to update"
        return 1
    fi
    
    # Check basic packages
    local missing_basic=()
    for package in $BASIC_PACKAGES; do
        if apt-cache show "$package" &>/dev/null; then
            continue
        else
            missing_basic+=("$package")
        fi
    done
    
    if [[ ${#missing_basic[@]} -eq 0 ]]; then
        log_success "Basic packages: All available"
    else
        log_error "Basic packages: Missing - ${missing_basic[*]}"
    fi
    
    # Check security packages
    local missing_security=()
    for package in $SECURITY_PACKAGES; do
        if apt-cache show "$package" &>/dev/null; then
            continue
        else
            missing_security+=("$package")
        fi
    done
    
    if [[ ${#missing_security[@]} -eq 0 ]]; then
        log_success "Security packages: All available"
    else
        log_error "Security packages: Missing - ${missing_security[*]}"
    fi
}

# Main validation function
main() {
    echo "🔍 Ubuntu Server Provisioning - Configuration Validation"
    echo "========================================================"
    echo
    
    # Change to script directory
    cd "$SCRIPT_DIR"
    
    # Run validation checks
    load_config || exit 1
    validate_system
    validate_config
    validate_scripts
    validate_packages
    
    echo
    echo "========================================================"
    echo "📊 Validation Summary"
    echo "========================================================"
    echo "Total checks: $CHECKS"
    echo -e "Passed: ${GREEN}$((CHECKS - WARNINGS - ERRORS))${NC}"
    echo -e "Warnings: ${YELLOW}$WARNINGS${NC}"
    echo -e "Errors: ${RED}$ERRORS${NC}"
    echo
    
    if [[ $ERRORS -eq 0 ]]; then
        echo -e "${GREEN}✅ Configuration validation passed!${NC}"
        echo "The system is ready for provisioning."
        exit 0
    else
        echo -e "${RED}❌ Configuration validation failed!${NC}"
        echo "Please fix the errors above before running the provisioning scripts."
        exit 1
    fi
}

# Show help
show_help() {
    echo "Ubuntu Server Provisioning - Configuration Validator"
    echo
    echo "Usage: $0 [options]"
    echo
    echo "Options:"
    echo "  -h, --help    Show this help message"
    echo "  -q, --quiet   Suppress informational messages"
    echo
    echo "This script validates:"
    echo "  • System requirements (Ubuntu version, disk space, connectivity)"
    echo "  • Configuration values (usernames, ports, paths)"
    echo "  • Required script files"
    echo "  • Package availability"
    echo
    echo "Configuration files:"
    echo "  • $DEFAULT_CONFIG (default settings)"
    echo "  • $LOCAL_CONFIG (local overrides, optional)"
}

# Parse command line arguments
case "${1:-}" in
    -h|--help)
        show_help
        exit 0
        ;;
    -q|--quiet)
        exec > /dev/null
        main
        ;;
    "")
        main
        ;;
    *)
        echo "Unknown option: $1"
        echo "Use -h or --help for usage information"
        exit 1
        ;;
esac
