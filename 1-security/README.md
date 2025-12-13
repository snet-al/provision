# 1-security (Hardening Utilities)

This folder contains optional security layers that can be executed from `0-linux/setup.sh` or on-demand:

- `security.sh`: Comprehensive hardening (UFW, fail2ban, sysctl, audit rules, etc.).
- `security_ratelimit.sh`: Lightweight rate limiting and service binding rules.

Run them directly if you want to re-apply security changes:

```bash
sudo ./1-security/security.sh
sudo ./1-security/security_ratelimit.sh
```

