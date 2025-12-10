# Ubuntu 24.04 LTS Server Provisioning Scripts

A comprehensive collection of shell scripts for provisioning and securing Ubuntu 24.04 LTS servers with Docker, security hardening, and user management.

## 🚀 Quick Start

```bash
# 1. Validate configuration (recommended)
./validate-config.sh

# 2. (Optional) Run comprehensive tests
./test-provision.sh

# 3. Run the main setup (interactive)
#    - Installs basic utils
#    - Configures daily unattended-upgrades (3:00 AM cron)
#    - Shows forge user's SSH key (use it to grant access to the private repo)
#    - Clones git@github.com:datafynow/provision.git as forge (retries until success)
#    - Adds your SSH key to forge for passwordless login
sudo ./setup.sh

# 4. Validate the provisioned system
./validate-system.sh
```

## 📋 Prerequisites

- **Ubuntu 24.04 LTS** server (fresh installation recommended)
- **Root access** or user with sudo privileges
- **Internet connection** for package downloads
- **SSH public key** ready for secure access

## 📁 Script Overview

### Core Provisioning Scripts
| Script | Purpose | User Required |
|--------|---------|---------------|
| `setup.sh` | Main orchestration script with interactive flow | root/sudo |
| `create_user.sh` | Creates forge user with sudo access | root/sudo |
| `add_ssh_key.sh` | Adds SSH keys to user accounts | target user |
| `sshkeys.sh` | Interactive SSH key management | target user |
| `security.sh` | Security hardening (firewall, fail2ban, etc.) | root/sudo |
| `security_ratelimit.sh` | Additional security measures | root/sudo |
| `docker.sh` | Docker installation and configuration | root/sudo |
| `after-setup.sh` | Post-setup cleanup and file organization | root/sudo |

### Validation & Testing Scripts
| Script | Purpose | When to Use |
|--------|---------|-------------|
| `validate-config.sh` | Pre-provisioning validation | Before running setup |
| `test-provision.sh` | Comprehensive testing suite | Before deployment |
| `validate-system.sh` | Post-provisioning validation | After provisioning |


### Configuration Files
| File | Purpose | Required |
|------|---------|----------|
| `provision.conf` | Default configuration settings | Yes |
| `provision.local.conf` | Local configuration overrides | Optional |

## 🧭 Provisioning Flow (interactive)

1) Install basics: updates apt, adds universe, installs core utilities.  
2) Auto-updates: configures `unattended-upgrades` with a 3:00 AM daily cron.  
3) Repository access: shows the **forge user's** SSH public key; add it to `git@github.com:datafynow/provision.git`.  
4) Server type: prompts for desired server type and records it for the private repo.  
5) Repo sync + handoff: auto-clones/pulls the private repo into `provision-private/` inside this repo (retries every 5s) and, if `provision-private/setup.sh` exists and is executable, runs it passing the selected server type.  
6) Optional security: prompts for hardening and rate limiting.  
7) Forge access: adds your SSH public key to `forge` for passwordless login.  
8) Post-copy: scripts are copied to `/home/forge/provision` with proper perms.  

## 🔒 Security Features

### Firewall Configuration
- **UFW (Uncomplicated Firewall)** with restrictive defaults
- **SSH, HTTP, HTTPS** ports allowed
- **SSH rate limiting** to prevent brute force attacks

### SSH Hardening
- **Root login disabled**
- **Password authentication disabled**
- **Key-based authentication only**
- **Maximum 3 authentication attempts**

### System Hardening
- **Fail2ban** for intrusion prevention
- **Automatic security updates**
- **Audit logging** for system monitoring
- **Secure shared memory** configuration
- **System resource limits**

### Service Security
- **Database services** bound to localhost only
- **SSL/TLS** enabled by default
- **Protected mode** for Redis
- **Secure transport** required for MySQL

## 🛠️ Configuration

### Configuration Files

The provisioning scripts use a centralized configuration system:

- **`provision.conf`** - Default configuration settings
- **`provision.local.conf`** - Local overrides (optional, takes precedence)

### Default Settings
- **Default user**: `forge`
- **SSH directory**: `/home/forge/.ssh`
- **Scripts location**: `/home/forge/provision`
- **Log file**: `/var/log/provision.log`
- **Backup directory**: `/etc/provision-backups`
- **Service binding**: `127.0.0.1` (localhost only)

#### Configuration Validation
Always validate your configuration before provisioning:
```bash
# Validate configuration
./validate-config.sh

# This checks:
# - Configuration file syntax
# - Username format validation
# - SSH port ranges
# - Package availability
# - System requirements
```

## 🚨 Troubleshooting

### Automated Diagnostics

First, try the automated validation tools:

```bash
# Check if configuration is valid
./validate-config.sh

# Run comprehensive tests
./test-provision.sh

# Check if system is properly configured
./validate-system.sh
```

These scripts will identify most common issues automatically.

### Log Locations
- **Provisioning logs**: `/var/log/provision.log` (centralized logging for all scripts)
- **Test logs**: `/tmp/provision-test.log` (from test-provision.sh)
- **System logs**: `/var/log/syslog`
- **Authentication logs**: `/var/log/auth.log`
- **Fail2ban logs**: `/var/log/fail2ban.log`
- **Docker logs**: `journalctl -u docker.service`

## 🔄 Maintenance

### Regular Validation
```bash
# Run system validation regularly (weekly/monthly)
./validate-system.sh

# Check for configuration drift
./validate-config.sh

# Run comprehensive tests before major changes
./test-provision.sh
```

### Regular Tasks
```bash
# Update system packages
sudo apt update && sudo apt upgrade

# Check security updates
sudo unattended-upgrade --dry-run

# Review fail2ban status
sudo fail2ban-client status

# Check disk usage
df -h

# Monitor system resources
htop

# Review provisioning logs
tail -100 /var/log/provision.log
```