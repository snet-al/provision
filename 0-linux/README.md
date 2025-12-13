# 0-linux (Core Provisioning)

Scripts inside this folder drive the end-to-end provisioning workflow for Ubuntu 24.04 servers:

- `setup.sh`: Main entry point for bootstrapping a server.
- `validate-config.sh`, `validate-system.sh`, `test-provision.sh`: Safety nets for config, post-provision checks, and dry-runs.
- `create_user.sh`, `add_ssh_key.sh`, `sshkeys.sh`: User and SSH key helpers.
- `after-setup.sh`: Copies the curated script tree to `/home/forge/provision`.
- `provision.conf`/`provision.local.conf`: Default + override configuration files.

All scripts assume you execute them from the repository root, e.g.:

```bash
./0-linux/validate-config.sh
sudo ./0-linux/setup.sh
```

