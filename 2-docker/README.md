# 2-docker (Docker and Docker Container Tooling)

Docker-related helpers live here:

- `docker.sh`: Installs Docker CE, Docker Compose plugin, configures the `forge` user, and deploys **Portainer CE** (accessible on `https://<server-ip>:9443`).
- `configure-docker-proxy.sh`: Optional proxy override for environments behind corporate gateways.

Typical usage:

```bash
# Install Docker + Portainer
sudo ./2-docker/docker.sh

# Add proxy settings (optional)
./2-docker/configure-docker-proxy.sh
```

After running `docker.sh`, open Portainer in your browser and finish the onboarding flow:

- URL: `https://<server-ip>:9443`
- Default volume: `portainer_data`
- Container name: `portainer` (restart with `docker restart portainer` if needed)

