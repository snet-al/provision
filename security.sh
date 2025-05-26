#!/bin/bash

# Update system first
sudo apt update && sudo apt upgrade -y

# Install security essentials
sudo apt install -y \
    ufw \
    fail2ban \
    unattended-upgrades \
    apt-listchanges \
    logwatch \
    auditd \
    rkhunter

# Configure UFW (Uncomplicated Firewall)
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow ssh
sudo ufw allow http
sudo ufw allow https
sudo ufw --force enable

# Configure automatic security updates
sudo dpkg-reconfigure -plow unattended-upgrades

# Configure Fail2ban
echo "Configuring Fail2ban..."
sudo mkdir -p /etc/fail2ban/jail.d
sudo tee /etc/fail2ban/jail.d/sshd-hardening.conf > /dev/null << 'EOF'
[sshd]
enabled  = true
maxretry = 3
bantime  = 1h
findtime = 10m
EOF

# Start and enable Fail2ban
sudo systemctl restart fail2ban
sudo systemctl enable fail2ban

# Secure shared memory
echo "tmpfs     /run/shm     tmpfs     defaults,noexec,nosuid     0     0" | sudo tee -a /etc/fstab

# Secure SSH configuration
sudo cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak
sudo tee -a /etc/ssh/sshd_config > /dev/null << EOL

# Security hardening
PermitRootLogin no
PasswordAuthentication no
X11Forwarding no
MaxAuthTries 3
Protocol 2
EOL

# Configure system-wide security limits
sudo tee -a /etc/security/limits.conf > /dev/null << EOL

# System-wide security limits
* soft core 0
* hard core 0
* soft nproc 1000
* hard nproc 2000
EOL

# Configure sysctl security parameters
sudo tee /etc/sysctl.d/99-security.conf > /dev/null << EOL
# IP Spoofing protection
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1

# Ignore ICMP broadcast requests
net.ipv4.icmp_echo_ignore_broadcasts = 1

# Disable source packet routing
net.ipv4.conf.all.accept_source_route = 0
net.ipv6.conf.all.accept_source_route = 0

# Ignore send redirects
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0

# Block SYN attacks
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_max_syn_backlog = 2048
net.ipv4.tcp_synack_retries = 2
net.ipv4.tcp_syn_retries = 5

# Log Martians
net.ipv4.conf.all.log_martians = 1
net.ipv4.conf.default.log_martians = 1

# Disable IPv6 if not needed
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
EOL

# Apply sysctl changes
sudo sysctl -p /etc/sysctl.d/99-security.conf

# Setup audit logging
sudo systemctl enable auditd
sudo systemctl start auditd

# Setup basic audit rules
sudo tee /etc/audit/rules.d/audit.rules > /dev/null << EOL
# Delete all existing rules
-D

# Buffer Size
-b 8192

# Failure Mode
-f 1

# Monitor file system mounts
-a always,exit -F arch=b64 -S mount -F auid>=1000 -F auid!=4294967295 -k mounts

# Monitor system admin actions
-w /etc/sudoers -p wa -k sudoers
-w /etc/sudoers.d/ -p wa -k sudoers

# Monitor security relevant files
-w /var/log/auth.log -p wa -k auth_log
-w /var/log/syslog -p wa -k syslog

# Monitor user and group files
-w /etc/group -p wa -k user_group_modification
-w /etc/passwd -p wa -k user_group_modification
-w /etc/gshadow -p wa -k user_group_modification
-w /etc/shadow -p wa -k user_group_modification
EOL

# Make script executable
sudo chmod +x /etc/audit/rules.d/audit.rules

# Restart audit daemon to apply rules
sudo service auditd restart

# Final message
echo "Security hardening complete. Please review the configurations and restart the system." 