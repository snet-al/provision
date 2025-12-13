# 2-docker-portainer (Container Tooling)

Docker-related helpers live here:

- `docker.sh`: Installs Docker CE, Compose plugin, and configures the `forge` user.
- `configure-docker-proxy.sh`: Optional proxy override for environments behind corporate gateways.

Typical usage:

```bash
sudo ./2-docker-portainer/docker.sh
./2-docker-portainer/configure-docker-proxy.sh    # only when a proxy is required
```

