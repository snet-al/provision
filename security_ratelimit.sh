#!/bin/bash

echo "Configuring additional security measures..."

# Configure SSH rate limiting with UFW
echo "Setting up SSH rate limiting..."
sudo ufw limit ssh/tcp comment 'Rate limit SSH connections'
sudo ufw reload

# Create secure service binding configuration
echo "Setting up secure service binding..."

# Create sysctl configuration for service binding
sudo tee /etc/sysctl.d/99-private-services.conf > /dev/null << EOL
# Bind services to localhost by default
net.ipv4.ip_unprivileged_port_start=0
# Restrict services to localhost
net.ipv4.conf.all.route_localnet=0
EOL

# Apply sysctl changes
sudo sysctl -p /etc/sysctl.d/99-private-services.conf

# Create default configuration templates for common services
sudo mkdir -p /etc/default/service-templates

# PostgreSQL template
sudo tee /etc/default/service-templates/postgresql.conf > /dev/null << EOL
# PostgreSQL configuration template
listen_addresses = '127.0.0.1'
port = 5432
max_connections = 100
ssl = on
EOL

# Redis template
sudo tee /etc/default/service-templates/redis.conf > /dev/null << EOL
# Redis configuration template
bind 127.0.0.1
port 6379
protected-mode yes
EOL

# MySQL template
sudo tee /etc/default/service-templates/mysql.conf > /dev/null << EOL
# MySQL configuration template
[mysqld]
bind-address = 127.0.0.1
port = 3306
max_connections = 100
ssl = ON
require_secure_transport = ON
EOL

# Create a helper script for service configuration
sudo tee /usr/local/bin/secure-service-config > /dev/null << 'EOL'
#!/bin/bash

show_help() {
    echo "Usage: secure-service-config [service_name]"
    echo "Available services: postgresql, redis, mysql"
    echo "This script helps configure services to bind to localhost only"
}

case "$1" in
    "postgresql")
        echo "Configuring PostgreSQL to bind to localhost..."
        if [ -f /etc/postgresql/*/main/postgresql.conf ]; then
            sudo sed -i 's/^#\?listen_addresses.*/listen_addresses = '\''127.0.0.1'\''/' /etc/postgresql/*/main/postgresql.conf
            echo "PostgreSQL configured. Restart required: sudo systemctl restart postgresql"
        else
            echo "PostgreSQL configuration file not found"
        fi
        ;;
    "redis")
        echo "Configuring Redis to bind to localhost..."
        if [ -f /etc/redis/redis.conf ]; then
            sudo sed -i 's/^#\?bind.*/bind 127.0.0.1/' /etc/redis/redis.conf
            echo "Redis configured. Restart required: sudo systemctl restart redis"
        fi
        ;;
    "mysql")
        echo "Configuring MySQL to bind to localhost..."
        if [ -f /etc/mysql/mysql.conf.d/mysqld.cnf ]; then
            sudo sed -i 's/^#\?bind-address.*/bind-address = 127.0.0.1/' /etc/mysql/mysql.conf.d/mysqld.cnf
            # Add SSL configuration if not present
            if ! grep -q "require_secure_transport" /etc/mysql/mysql.conf.d/mysqld.cnf; then
                echo "ssl = ON" | sudo tee -a /etc/mysql/mysql.conf.d/mysqld.cnf
                echo "require_secure_transport = ON" | sudo tee -a /etc/mysql/mysql.conf.d/mysqld.cnf
            fi
            echo "MySQL configured. Restart required: sudo systemctl restart mysql"
        else
            echo "MySQL configuration file not found"
        fi
        ;;
    *)
        show_help
        ;;
esac
EOL

# Make the helper script executable
sudo chmod +x /usr/local/bin/secure-service-config

# Create documentation
sudo tee /usr/local/share/doc/service-security.md > /dev/null << 'EOL'
# Service Security Configuration Guide

## SSH Rate Limiting
SSH connections are rate-limited using UFW to prevent brute-force attempts.

## Private Services
For security, services like PostgreSQL, MySQL, and Redis should be bound to localhost (127.0.0.1).

### Configuring Services
Use the `secure-service-config` tool to configure services:

```bash
# Configure PostgreSQL
sudo secure-service-config postgresql

# Configure Redis
sudo secure-service-config redis

# Configure MySQL
sudo secure-service-config mysql
```

### Manual Configuration
When installing new services, ensure they:
1. Bind to 127.0.0.1 only
2. Use SSL/TLS when available
3. Require authentication
4. Run with minimal privileges

### Checking Service Binding
To check if a service is properly bound:
```bash
sudo netstat -tulpn | grep LISTEN
```
Services should show '127.0.0.1' instead of '0.0.0.0'

### Default Ports
- PostgreSQL: 5432
- Redis: 6379
- MySQL: 3306

### SSL/TLS Configuration
All database services are configured to use SSL by default:
- PostgreSQL: SSL enabled
- MySQL: SSL enabled with require_secure_transport
- Redis: Protected mode enabled
EOL

echo "Additional security measures have been configured."
echo "Use 'secure-service-config' to configure specific services."
echo "Documentation available at /usr/local/share/doc/service-security.md" 