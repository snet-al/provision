#!/bin/bash

# Comprehensive testing script for provisioning
# Tests all aspects of the server provisioning

set -euo pipefail

# Colors for output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly CYAN='\033[0;36m'
readonly NC='\033[0m' # No Color

# Directory configuration
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SECURITY_DIR="$ROOT_DIR/1-security"
readonly DOCKER_DIR="$ROOT_DIR/2-docker"
readonly TEST_LOG="/tmp/provision-test.log"

# Source shared utilities (includes config loading)
# shellcheck source=utils.sh
source "$SCRIPT_DIR/utils.sh"

# Counters
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

# Test functions
log_test() {
    echo -e "${CYAN}[TEST]${NC} $1"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] TEST: $1" >> "$TEST_LOG"
}

log_pass() {
    echo -e "${GREEN}[PASS]${NC} $1"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] PASS: $1" >> "$TEST_LOG"
    ((TESTS_PASSED++))
    ((TESTS_RUN++))
}

log_fail() {
    echo -e "${RED}[FAIL]${NC} $1"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] FAIL: $1" >> "$TEST_LOG"
    ((TESTS_FAILED++))
    ((TESTS_RUN++))
}

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] INFO: $1" >> "$TEST_LOG"
}

# Initialize test log
init_test_log() {
    echo "=== Provisioning Test Log ===" > "$TEST_LOG"
    echo "Started: $(date)" >> "$TEST_LOG"
    echo "User: $(whoami)" >> "$TEST_LOG"
    echo "Host: $(hostname)" >> "$TEST_LOG"
    echo "================================" >> "$TEST_LOG"
}

# Test script existence and permissions
test_scripts() {
    log_info "Testing script files..."
    
    local scripts=(
        "$SCRIPT_DIR/setup.sh"
        "$SCRIPT_DIR/create_user.sh"
        "$SCRIPT_DIR/add_ssh_key.sh"
        "$SCRIPT_DIR/sshkeys.sh"
        "$SCRIPT_DIR/after-setup.sh"
        "$SCRIPT_DIR/validate-config.sh"
        "$SCRIPT_DIR/validate-system.sh"
        "$SECURITY_DIR/security.sh"
        "$SECURITY_DIR/security_ratelimit.sh"
        "$DOCKER_DIR/docker.sh"
    )
    
    for script_path in "${scripts[@]}"; do
        local display_path="${script_path#$ROOT_DIR/}"
        log_test "Checking script: ${display_path:-$script_path}"
        
        if [[ -f "$script_path" ]]; then
            if [[ -x "$script_path" ]]; then
                log_pass "Script ${display_path:-$script_path} exists and is executable"
            else
                log_fail "Script ${display_path:-$script_path} exists but is not executable"
            fi
        else
            log_fail "Script ${display_path:-$script_path} is missing"
        fi
    done
}

# Test configuration files
test_config() {
    log_info "Testing configuration files..."
    
    log_test "Checking provision.conf"
    if [[ -f "$ROOT_DIR/provision.conf" ]]; then
        if [[ -r "$ROOT_DIR/provision.conf" ]]; then
            log_pass "Configuration file provision.conf exists and is readable"
        else
            log_fail "Configuration file provision.conf exists but is not readable"
        fi
    else
        log_fail "Configuration file provision.conf is missing"
    fi
    
    log_test "Checking README.md"
    if [[ -f "$ROOT_DIR/README.md" ]]; then
        local readme_size
        readme_size=$(wc -l < "$ROOT_DIR/README.md")
        if [[ $readme_size -gt 50 ]]; then
            log_pass "README.md exists and has substantial content ($readme_size lines)"
        else
            log_fail "README.md exists but appears incomplete ($readme_size lines)"
        fi
    else
        log_fail "README.md is missing"
    fi
}

# Test SSH key validation
test_ssh_validation() {
    log_info "Testing SSH key validation..."
    
    # Test valid SSH keys
    local valid_keys=(
        "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQC7vbqajDhA test@example.com"
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIG4rT3vTt99Ox5kndS4HmgTrKBT8SKzhK4rhGkEVGlCI test@example.com"
        "ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBEmKSENjQEezOmxkZMy7opKgwFB9nkt5YRrYMjNuG5N87uRgg6CLrbo5wAdT/y6v0mKV0U2w0WZ2YB/++Tpockg= test@example.com"
    )
    
    for key in "${valid_keys[@]}"; do
        local key_type
        key_type=$(echo "$key" | awk '{print $1}')
        log_test "Validating $key_type key format"
        
        if echo "$key" | grep -qE '^(ssh-rsa|ssh-ed25519|ecdsa-sha2-nistp256|ecdsa-sha2-nistp384|ecdsa-sha2-nistp521) '; then
            log_pass "$key_type key format validation passed"
        else
            log_fail "$key_type key format validation failed"
        fi
    done
    
    # Test invalid SSH keys
    local invalid_keys=(
        "invalid-key AAAAB3NzaC1yc2EAAAADAQABAAABgQC7vbqajDhA test@example.com"
        "ssh-rsa"
        ""
        "not-a-key-at-all"
    )
    
    for key in "${invalid_keys[@]}"; do
        log_test "Testing invalid key rejection: '${key:0:20}...'"
        
        if echo "$key" | grep -qE '^(ssh-rsa|ssh-ed25519|ecdsa-sha2-nistp256|ecdsa-sha2-nistp384|ecdsa-sha2-nistp521) '; then
            log_fail "Invalid key was incorrectly accepted"
        else
            log_pass "Invalid key was correctly rejected"
        fi
    done
}

# Test username validation
test_username_validation() {
    log_info "Testing username validation..."
    
    # Valid usernames
    local valid_usernames=("forge" "user123" "test-user" "admin_user" "developer")
    
    for username in "${valid_usernames[@]}"; do
        log_test "Validating username: $username"
        
        if [[ "$username" =~ ^[a-zA-Z][a-zA-Z0-9_-]{2,31}$ ]]; then
            log_pass "Username '$username' validation passed"
        else
            log_fail "Username '$username' validation failed"
        fi
    done
    
    # Invalid usernames
    local invalid_usernames=("1user" "us" "user@domain" "user.name" "very-long-username-that-exceeds-limits")
    
    for username in "${invalid_usernames[@]}"; do
        log_test "Testing invalid username rejection: $username"
        
        if [[ "$username" =~ ^[a-zA-Z][a-zA-Z0-9_-]{2,31}$ ]]; then
            log_fail "Invalid username '$username' was incorrectly accepted"
        else
            log_pass "Invalid username '$username' was correctly rejected"
        fi
    done
}

# Test system requirements
test_system_requirements() {
    log_info "Testing system requirements..."
    
    # Test Ubuntu version detection
    log_test "Ubuntu version detection"
    if [[ -f /etc/os-release ]]; then
        local version
        version=$(grep VERSION_ID /etc/os-release | cut -d'"' -f2)
        log_pass "Ubuntu version detected: $version"
    else
        log_fail "Cannot detect Ubuntu version"
    fi
    
    # Test disk space check
    log_test "Disk space availability"
    local available_space
    available_space=$(df / | awk 'NR==2 {print $4}')
    local space_gb=$((available_space / 1024 / 1024))
    if [[ $space_gb -ge 1 ]]; then
        log_pass "Sufficient disk space available: ${space_gb}GB"
    else
        log_fail "Insufficient disk space: ${space_gb}GB"
    fi
    
    # Test internet connectivity
    log_test "Internet connectivity"
    if ping -c 1 8.8.8.8 &>/dev/null; then
        log_pass "Internet connectivity available"
    else
        log_fail "No internet connectivity"
    fi
    
    # Test required commands
    local required_commands=("sudo" "apt" "systemctl" "grep" "awk" "sed")
    
    for cmd in "${required_commands[@]}"; do
        log_test "Command availability: $cmd"
        
        if command -v "$cmd" &>/dev/null; then
            log_pass "Command '$cmd' is available"
        else
            log_fail "Command '$cmd' is not available"
        fi
    done
}

# Test package availability
test_package_availability() {
    log_info "Testing package availability..."
    
    # Update package lists quietly
    log_test "Package list update"
    if sudo apt update &>/dev/null; then
        log_pass "Package lists updated successfully"
    else
        log_fail "Failed to update package lists"
        return 1
    fi
    
    # Test basic packages
    local basic_packages=("vim" "git" "curl" "wget" "htop")
    
    for package in "${basic_packages[@]}"; do
        log_test "Package availability: $package"
        
        if apt-cache show "$package" &>/dev/null; then
            log_pass "Package '$package' is available"
        else
            log_fail "Package '$package' is not available"
        fi
    done
    
    # Test security packages
    local security_packages=("ufw" "fail2ban" "unattended-upgrades")
    
    for package in "${security_packages[@]}"; do
        log_test "Security package availability: $package"
        
        if apt-cache show "$package" &>/dev/null; then
            log_pass "Security package '$package' is available"
        else
            log_fail "Security package '$package' is not available"
        fi
    done
}

# Test Docker repository access
test_docker_repository() {
    log_info "Testing Docker repository access..."
    
    log_test "Docker GPG key download"
    if curl -fsSL https://download.docker.com/linux/ubuntu/gpg &>/dev/null; then
        log_pass "Docker GPG key is accessible"
    else
        log_fail "Cannot access Docker GPG key"
    fi
    
    log_test "Docker repository accessibility"
    local ubuntu_codename
    ubuntu_codename=$(. /etc/os-release && echo "$VERSION_CODENAME")
    local docker_repo_url="https://download.docker.com/linux/ubuntu/dists/$ubuntu_codename/stable/binary-amd64/Packages"
    
    if curl -fsSL "$docker_repo_url" &>/dev/null; then
        log_pass "Docker repository is accessible for $ubuntu_codename"
    else
        log_fail "Cannot access Docker repository for $ubuntu_codename"
    fi
}

# Test file permissions and security
test_file_security() {
    log_info "Testing file permissions and security..."
    
    # Test script permissions
    local script_paths=(
        "$SCRIPT_DIR/setup.sh"
        "$SECURITY_DIR/security.sh"
        "$DOCKER_DIR/docker.sh"
    )
    
    for script_path in "${script_paths[@]}"; do
        if [[ -f "$script_path" ]]; then
            local display_path="${script_path#$ROOT_DIR/}"
            log_test "Script permissions: ${display_path:-$script_path}"
            
            local perms
            perms=$(stat -c "%a" "$script_path")
            if [[ "$perms" =~ ^7[0-5][0-5]$ ]]; then
                log_pass "Script '${display_path:-$script_path}' has secure permissions: $perms"
            else
                log_fail "Script '${display_path:-$script_path}' has insecure permissions: $perms"
            fi
        fi
    done
    
    # Test configuration file permissions
    if [[ -f "$ROOT_DIR/provision.conf" ]]; then
        log_test "Configuration file permissions"
        
        local conf_perms
        conf_perms=$(stat -c "%a" "$ROOT_DIR/provision.conf")
        if [[ "$conf_perms" =~ ^6[0-4][0-4]$ ]]; then
            log_pass "Configuration file has secure permissions: $conf_perms"
        else
            log_fail "Configuration file has insecure permissions: $conf_perms"
        fi
    fi
}

# Run validation scripts
test_validation_scripts() {
    log_info "Testing validation scripts..."
    
    # Test config validation script
    if [[ -f "$SCRIPT_DIR/validate-config.sh" ]]; then
        log_test "Configuration validation script"
        
        if "$SCRIPT_DIR/validate-config.sh" --help &>/dev/null; then
            log_pass "Configuration validation script works"
        else
            log_fail "Configuration validation script has issues"
        fi
    else
        log_fail "Configuration validation script is missing"
    fi
    
    # Test system validation script
    if [[ -f "$SCRIPT_DIR/validate-system.sh" ]]; then
        log_test "System validation script"
        
        if "$SCRIPT_DIR/validate-system.sh" --help &>/dev/null; then
            log_pass "System validation script works"
        else
            log_fail "System validation script has issues"
        fi
    else
        log_fail "System validation script is missing"
    fi
}

# Main test function
main() {
    echo "🧪 Ubuntu Server Provisioning - Comprehensive Testing"
    echo "====================================================="
    echo
    
    init_test_log
    
    # Run all tests
    test_scripts
    test_config
    test_ssh_validation
    test_username_validation
    test_system_requirements
    test_package_availability
    test_docker_repository
    test_file_security
    test_validation_scripts
    
    echo
    echo "====================================================="
    echo "📊 Test Summary"
    echo "====================================================="
    echo "Total tests: $TESTS_RUN"
    echo -e "Passed: ${GREEN}$TESTS_PASSED${NC}"
    echo -e "Failed: ${RED}$TESTS_FAILED${NC}"
    echo "Success rate: $(( TESTS_PASSED * 100 / TESTS_RUN ))%"
    echo
    echo "Test log saved to: $TEST_LOG"
    echo
    
    if [[ $TESTS_FAILED -eq 0 ]]; then
        echo -e "${GREEN}✅ All tests passed!${NC}"
        echo "The provisioning scripts are ready for use."
        exit 0
    else
        echo -e "${RED}❌ Some tests failed!${NC}"
        echo "Please review the failures above and fix any issues."
        exit 1
    fi
}

# Show help
show_help() {
    echo "Ubuntu Server Provisioning - Test Suite"
    echo
    echo "Usage: $0 [options]"
    echo
    echo "Options:"
    echo "  -h, --help    Show this help message"
    echo
    echo "This script tests:"
    echo "  • Script files and permissions"
    echo "  • Configuration files"
    echo "  • SSH key validation"
    echo "  • Username validation"
    echo "  • System requirements"
    echo "  • Package availability"
    echo "  • Docker repository access"
    echo "  • File security"
    echo "  • Validation scripts"
    echo
    echo "Run this script before provisioning to ensure everything is ready."
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
