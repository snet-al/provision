#!/bin/bash

# System validation script
# Validates the server configuration after provisioning

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

# Configuration
readonly DEFAULT_USER="forge"
readonly LOG_FILE="/var/log/provision.log"

# Logging functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[PASS]${NC} $1"
    ((CHECKS++))
}

log_warning() {
    echo -e "${YELLOW}[WARN]${NC} $1"
    ((WARNINGS++))
    ((CHECKS++))
}

log_error() {
    echo -e "${RED}[FAIL]${NC} $1"
    ((ERRORS++))
    ((CHECKS++))
}

# Validate user configuration
validate_user() {
    log_info "Validating user configuration..."
    
    # Check if forge user exists
    if id "$DEFAULT_USER" &>/dev/null; then
        log_success "User '$DEFAULT_USER' exists"
        
        # Check sudo access
        if groups "$DEFAULT_USER" | grep -q "\bsudo\b"; then
            log_success "User '$DEFAULT_USER' has sudo access"
        else
            log_error "User '$DEFAULT_USER' does not have sudo access"
        fi
        
        # Check home directory
        if [[ -d "/home/$DEFAULT_USER" ]]; then
            log_success "User home directory exists: /home/$DEFAULT_USER"
        else
            log_error "User home directory missing: /home/$DEFAULT_USER"
        fi
        
        # Check SSH directory
        if [[ -d "/home/$DEFAULT_USER/.ssh" ]]; then
            log_success "SSH directory exists: /home/$DEFAULT_USER/.ssh"
            
            # Check SSH directory permissions
            local ssh_perms
            ssh_perms=$(stat -c "%a" "/home/$DEFAULT_USER/.ssh")
            if [[ "$ssh_perms" == "700" ]]; then
                log_success "SSH directory permissions: $ssh_perms (correct)"
            else
                log_error "SSH directory permissions: $ssh_perms (should be 700)"
            fi
            
            # Check authorized_keys
            if [[ -f "/home/$DEFAULT_USER/.ssh/authorized_keys" ]]; then
                log_success "SSH authorized_keys file exists"
                
                local key_perms
                key_perms=$(stat -c "%a" "/home/$DEFAULT_USER/.ssh/authorized_keys")
                if [[ "$key_perms" == "600" ]]; then
                    log_success "SSH authorized_keys permissions: $key_perms (correct)"
                else
                    log_error "SSH authorized_keys permissions: $key_perms (should be 600)"
                fi
                
                # Check if file has content
                if [[ -s "/home/$DEFAULT_USER/.ssh/authorized_keys" ]]; then
                    local key_count
                    key_count=$(grep -c "^ssh-" "/home/$DEFAULT_USER/.ssh/authorized_keys" 2>/dev/null || echo 0)
                    log_success "SSH keys configured: $key_count key(s) found"
                else
                    log_warning "SSH authorized_keys file is empty"
                fi
            else
                log_warning "SSH authorized_keys file not found"
            fi
        else
            log_error "SSH directory missing: /home/$DEFAULT_USER/.ssh"
        fi
    else
        log_error "User '$DEFAULT_USER' does not exist"
    fi
}

# Validate security configuration
validate_security() {
    log_info "Validating security configuration..."
    
    # Check UFW firewall
    if command -v ufw &>/dev/null; then
        log_success "UFW firewall is installed"
        
        local ufw_status
        ufw_status=$(sudo ufw status | head -1)
        if echo "$ufw_status" | grep -q "Status: active"; then
            log_success "UFW firewall is active"
            
            # Check specific rules
            if sudo ufw status | grep -q "22/tcp"; then
                log_success "SSH access allowed through firewall"
            else
                log_warning "SSH access not explicitly allowed through firewall"
            fi
            
            if sudo ufw status | grep -q "80/tcp"; then
                log_success "HTTP access allowed through firewall"
            else
                log_info "HTTP access not allowed through firewall (may be intentional)"
            fi
            
            if sudo ufw status | grep -q "443/tcp"; then
                log_success "HTTPS access allowed through firewall"
            else
                log_info "HTTPS access not allowed through firewall (may be intentional)"
            fi
        else
            log_error "UFW firewall is not active"
        fi
    else
        log_error "UFW firewall is not installed"
    fi
    
    # Check Fail2ban
    if command -v fail2ban-client &>/dev/null; then
        log_success "Fail2ban is installed"
        
        if systemctl is-active --quiet fail2ban; then
            log_success "Fail2ban service is running"
            
            # Check SSH jail
            if sudo fail2ban-client status sshd &>/dev/null; then
                log_success "Fail2ban SSH jail is active"
            else
                log_warning "Fail2ban SSH jail is not active"
            fi
        else
            log_error "Fail2ban service is not running"
        fi
    else
        log_error "Fail2ban is not installed"
    fi
    
    # Check SSH configuration
    if [[ -f /etc/ssh/sshd_config ]]; then
        log_success "SSH configuration file exists"
        
        # Check key security settings
        if grep -q "PermitRootLogin no" /etc/ssh/sshd_config; then
            log_success "Root login disabled in SSH"
        else
            log_warning "Root login may be enabled in SSH"
        fi
        
        if grep -q "PasswordAuthentication no" /etc/ssh/sshd_config; then
            log_success "Password authentication disabled in SSH"
        else
            log_warning "Password authentication may be enabled in SSH"
        fi
        
        if grep -q "X11Forwarding no" /etc/ssh/sshd_config; then
            log_success "X11 forwarding disabled in SSH"
        else
            log_info "X11 forwarding may be enabled in SSH"
        fi
    else
        log_error "SSH configuration file not found"
    fi
}

# Validate Docker installation
validate_docker() {
    log_info "Validating Docker installation..."
    
    # Check if Docker is installed
    if command -v docker &>/dev/null; then
        log_success "Docker is installed"
        
        # Check Docker version
        local docker_version
        docker_version=$(docker --version 2>/dev/null || echo "unknown")
        log_success "Docker version: $docker_version"
        
        # Check Docker service
        if systemctl is-active --quiet docker; then
            log_success "Docker service is running"
        else
            log_error "Docker service is not running"
        fi
        
        # Check Docker group
        if getent group docker &>/dev/null; then
            log_success "Docker group exists"
            
            # Check if user is in docker group
            if groups "$DEFAULT_USER" 2>/dev/null | grep -q "\bdocker\b"; then
                log_success "User '$DEFAULT_USER' is in docker group"
            else
                log_warning "User '$DEFAULT_USER' is not in docker group"
            fi
        else
            log_error "Docker group does not exist"
        fi
        
        # Check Docker Compose
        if docker compose version &>/dev/null; then
            local compose_version
            compose_version=$(docker compose version 2>/dev/null || echo "unknown")
            log_success "Docker Compose version: $compose_version"
        else
            log_warning "Docker Compose not available"
        fi
    else
        log_info "Docker is not installed (may be intentional)"
    fi
}

# Validate Traefik installation
validate_traefik() {
    log_info "Validating Traefik installation..."
    
    # Load configuration
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    if [[ -f "$SCRIPT_DIR/provision.local.conf" ]]; then
        source "$SCRIPT_DIR/provision.local.conf"
    elif [[ -f "$SCRIPT_DIR/provision.conf" ]]; then
        source "$SCRIPT_DIR/provision.conf"
    fi
    
    # Default values if not set in config
    TRAEFIK_CONTAINER_NAME="${TRAEFIK_CONTAINER_NAME:-traefik}"
    TRAEFIK_NETWORK="${TRAEFIK_NETWORK:-datafynow-platform}"
    TRAEFIK_CERTS_DIR="${TRAEFIK_CERTS_DIR:-/srv/traefik/certs}"
    
    # Check if Traefik container exists
    if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q "^${TRAEFIK_CONTAINER_NAME}$"; then
        log_success "Traefik container exists: $TRAEFIK_CONTAINER_NAME"
        
        # Check if Traefik container is running
        if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${TRAEFIK_CONTAINER_NAME}$"; then
            log_success "Traefik container is running"
            
            # Check if Traefik is listening on ports
            if netstat -tuln 2>/dev/null | grep -q ":80 " || ss -tuln 2>/dev/null | grep -q ":80 "; then
                log_success "Traefik is listening on port 80"
            else
                log_warning "Traefik may not be listening on port 80"
            fi
            
            if netstat -tuln 2>/dev/null | grep -q ":443 " || ss -tuln 2>/dev/null | grep -q ":443 "; then
                log_success "Traefik is listening on port 443"
            else
                log_warning "Traefik may not be listening on port 443"
            fi
        else
            log_error "Traefik container exists but is not running"
        fi
    else
        log_info "Traefik container not found (may be intentional)"
    fi
    
    # Check Docker network
    if docker network inspect "$TRAEFIK_NETWORK" &>/dev/null 2>&1; then
        log_success "Docker network exists: $TRAEFIK_NETWORK"
        
        # Check if Traefik container is connected to network
        if docker network inspect "$TRAEFIK_NETWORK" 2>/dev/null | grep -q "$TRAEFIK_CONTAINER_NAME"; then
            log_success "Traefik container is connected to network"
        else
            log_warning "Traefik container may not be connected to network"
        fi
    else
        log_info "Docker network '$TRAEFIK_NETWORK' not found (may be intentional)"
    fi
    
    # Check certificates directory
    if [[ -d "$TRAEFIK_CERTS_DIR" ]]; then
        log_success "Traefik certificates directory exists: $TRAEFIK_CERTS_DIR"
    else
        log_info "Traefik certificates directory not found: $TRAEFIK_CERTS_DIR (will be created on first use)"
    fi
}

# Validate deployment directory
validate_deployment_directory() {
    log_info "Validating deployment directory..."
    
    # Load configuration
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    if [[ -f "$SCRIPT_DIR/provision.local.conf" ]]; then
        source "$SCRIPT_DIR/provision.local.conf"
    elif [[ -f "$SCRIPT_DIR/provision.conf" ]]; then
        source "$SCRIPT_DIR/provision.conf"
    fi
    
    # Default values if not set in config
    TRAEFIK_DEPLOYMENT_DIR="${TRAEFIK_DEPLOYMENT_DIR:-/srv/deployments}"
    
    # Check if deployment directory exists
    if [[ -d "$TRAEFIK_DEPLOYMENT_DIR" ]]; then
        log_success "Deployment directory exists: $TRAEFIK_DEPLOYMENT_DIR"
        
        # Check ownership
        local dir_owner
        dir_owner=$(stat -c "%U" "$TRAEFIK_DEPLOYMENT_DIR" 2>/dev/null || echo "unknown")
        if [[ "$dir_owner" == "$DEFAULT_USER" ]]; then
            log_success "Deployment directory ownership is correct: $dir_owner"
        else
            log_warning "Deployment directory ownership: $dir_owner (expected: $DEFAULT_USER)"
        fi
        
        # Check permissions
        local dir_perms
        dir_perms=$(stat -c "%a" "$TRAEFIK_DEPLOYMENT_DIR" 2>/dev/null || echo "unknown")
        if [[ "$dir_perms" == "750" ]]; then
            log_success "Deployment directory permissions are correct: $dir_perms"
        else
            log_warning "Deployment directory permissions: $dir_perms (expected: 750)"
        fi
    else
        log_info "Deployment directory not found: $TRAEFIK_DEPLOYMENT_DIR (may be intentional)"
    fi
}

# Validate system services
validate_services() {
    log_info "Validating system services..."
    
    # Check essential services
    local essential_services=("ssh" "systemd-resolved" "systemd-networkd")
    
    for service in "${essential_services[@]}"; do
        if systemctl is-active --quiet "$service"; then
            log_success "Service '$service' is running"
        else
            log_warning "Service '$service' is not running"
        fi
    done
    
    # Check if unattended-upgrades is configured
    if systemctl is-enabled --quiet unattended-upgrades 2>/dev/null; then
        log_success "Automatic security updates are enabled"
    else
        log_warning "Automatic security updates may not be enabled"
    fi
}

# Validate system resources
validate_resources() {
    log_info "Validating system resources..."
    
    # Check disk space
    local disk_usage
    disk_usage=$(df / | awk 'NR==2 {print $5}' | sed 's/%//')
    if [[ $disk_usage -lt 80 ]]; then
        log_success "Disk usage: ${disk_usage}% (healthy)"
    elif [[ $disk_usage -lt 90 ]]; then
        log_warning "Disk usage: ${disk_usage}% (monitor closely)"
    else
        log_error "Disk usage: ${disk_usage}% (critically high)"
    fi
    
    # Check memory
    local mem_total mem_available mem_usage_percent
    mem_total=$(free -m | awk 'NR==2{print $2}')
    mem_available=$(free -m | awk 'NR==2{print $7}')
    mem_usage_percent=$(( (mem_total - mem_available) * 100 / mem_total ))
    
    if [[ $mem_usage_percent -lt 80 ]]; then
        log_success "Memory usage: ${mem_usage_percent}% (healthy)"
    elif [[ $mem_usage_percent -lt 90 ]]; then
        log_warning "Memory usage: ${mem_usage_percent}% (monitor closely)"
    else
        log_error "Memory usage: ${mem_usage_percent}% (critically high)"
    fi
    
    # Check load average
    local load_avg
    load_avg=$(uptime | awk -F'load average:' '{print $2}' | awk '{print $1}' | sed 's/,//')
    log_success "Load average: $load_avg"
}

# Validate log files
validate_logs() {
    log_info "Validating log files..."
    
    # Check provision log
    if [[ -f "$LOG_FILE" ]]; then
        log_success "Provision log file exists: $LOG_FILE"
        
        local log_size
        log_size=$(du -h "$LOG_FILE" | cut -f1)
        log_success "Provision log size: $log_size"
        
        # Check for recent entries
        if [[ -s "$LOG_FILE" ]]; then
            local recent_entries
            recent_entries=$(tail -10 "$LOG_FILE" | wc -l)
            log_success "Recent log entries: $recent_entries"
        else
            log_warning "Provision log file is empty"
        fi
    else
        log_warning "Provision log file not found: $LOG_FILE"
    fi
    
    # Check system logs
    if [[ -f /var/log/auth.log ]]; then
        log_success "Authentication log exists"
    else
        log_warning "Authentication log not found"
    fi
    
    if [[ -f /var/log/syslog ]]; then
        log_success "System log exists"
    else
        log_warning "System log not found"
    fi
}

# Main validation function
main() {
    echo "🔍 Ubuntu Server Provisioning - System Validation"
    echo "================================================="
    echo
    
    validate_user
    validate_security
    validate_docker
    validate_traefik
    validate_deployment_directory
    validate_services
    validate_resources
    validate_logs
    
    echo
    echo "================================================="
    echo "📊 Validation Summary"
    echo "================================================="
    echo "Total checks: $CHECKS"
    echo -e "Passed: ${GREEN}$((CHECKS - WARNINGS - ERRORS))${NC}"
    echo -e "Warnings: ${YELLOW}$WARNINGS${NC}"
    echo -e "Errors: ${RED}$ERRORS${NC}"
    echo
    
    if [[ $ERRORS -eq 0 ]]; then
        if [[ $WARNINGS -eq 0 ]]; then
            echo -e "${GREEN}✅ System validation passed perfectly!${NC}"
            echo "Your server is properly configured and ready for use."
        else
            echo -e "${YELLOW}⚠️  System validation passed with warnings.${NC}"
            echo "Your server is functional but some optimizations may be needed."
        fi
        exit 0
    else
        echo -e "${RED}❌ System validation failed!${NC}"
        echo "Please review and fix the errors above."
        exit 1
    fi
}

# Show help
show_help() {
    echo "Ubuntu Server Provisioning - System Validator"
    echo
    echo "Usage: $0 [options]"
    echo
    echo "Options:"
    echo "  -h, --help    Show this help message"
    echo
    echo "This script validates:"
    echo "  • User configuration and SSH setup"
    echo "  • Security settings (firewall, fail2ban, SSH)"
    echo "  • Docker installation and configuration"
    echo "  • Traefik reverse proxy installation and network"
    echo "  • Deployment directory structure"
    echo "  • System services and resources"
    echo "  • Log files and system health"
    echo
    echo "Run this script after provisioning to verify everything is working correctly."
}

# Parse command line arguments
case "${1:-}" in
    -h|--help)
        show_help
        exit 0
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
