# Profiles and Inventory

## Profiles

A profile is an ordered composition of tasks. Profiles live in `profiles/` and are selected at run time via `--profile <name>` or the `profile` field in an inventory host entry.

### `basic`

The foundation profile. Included by every other profile.

| Task | What it does |
|---|---|
| `run_base` | Installs core packages (`ca-certificates`, `curl`, `git`, `rsync`, `software-properties-common`), sets timezone |
| `run_user_forge` | Creates `DEFAULT_USER`, adds them to `sudo`, provisions `~/.ssh/authorized_keys` |
| `run_ssh_hardening` | Locks down sshd: port, root login, password auth, X11, max auth tries |
| `run_unattended_upgrades` | Enables automatic security/update patches via APT, schedules daily cron at 03:00 |
| `run_firewall` | Configures `ufw`: default deny-incoming / allow-outgoing, opens ports 22/80/443 |
| `run_fail2ban` | Installs fail2ban and applies SSH jail (configurable retries, ban time, find time) |
| `run_microsoft_defender` | **Off by default** (`ENABLE_MDE=false`). Installs and configures `mdatp` when enabled |

Config baseline: `hosts/basic.yml`

---

### `docker_host`

Extends `basic` with a Docker runtime, Portainer UI and a send-only SMTP relay.

```
profile_basic
  → run_docker
  → run_portainer
  → run_smtp
  → run_post_setup
```

| Extra task | What it adds |
|---|---|
| `run_docker` | Installs Docker CE + CLI, containerd, buildx, compose plugin; adds user to `docker` group |
| `run_portainer` | Deploys Portainer CE container on ports 9000/9443; detects and reconciles config drift |
| `run_smtp` | Builds and runs the Postfix + OpenDKIM relay container on the `smtp` network; reconciles drift |
| `run_post_setup` | Normalizes ownership and directory modes under `~/provision/` workspace |

Key defaults vs `basic`: `ENABLE_DOCKER=true`, `ENABLE_PORTAINER=true`, `ENABLE_SMTP=true` (skipped until `SMTP_DOMAIN` is set)

Config baseline: `hosts/docker_host.yml`

---

### `agents`

Extends `basic` with Docker and the private `provision-servers` agent extension.

```
profile_basic
  → run_docker
  → run_provision_servers_extension   (folder: agents/)
  → run_post_setup
```

| Extra task | What it adds |
|---|---|
| `run_docker` | Same as `docker_host` |
| `run_provision_servers_extension` | Generates SSH key for `DEFAULT_USER`, adds GitHub to `known_hosts`, clones/pulls `provision-servers` repo, records profile in `.server_type`, runs `agents/setup.sh` |
| `run_post_setup` | Same as `docker_host` |

Key defaults vs `basic`: `ENABLE_DOCKER=true`, `ENABLE_PORTAINER=false`

Config baseline: `hosts/agents.yml`

---

### `multi_deployment`

Identical task pipeline to `agents` but maps to the `deployment/` folder inside the `provision-servers` repo.

```
profile_basic
  → run_docker
  → run_provision_servers_extension   (folder: deployment/)
  → run_post_setup
```

The only difference from `agents` is the sub-folder resolved by `provision_servers_profile_folder()`:

| Profile | Repo folder |
|---|---|
| `agents` | `agents/` |
| `multi_deployment` | `deployment/` |

Config baseline: `hosts/multi_deployment.yml`

---

## Inventory and Hosts

### Host config files (`hosts/`)

Each profile ships a baseline YAML config in `hosts/<profile>.yml`. These files set all env variables consumed by tasks. An optional `hosts/<profile>.local.yml` (git-ignored) can override values for a specific machine without touching the baseline.

Config precedence (highest → lowest):

1. CLI arguments (`--profile`, `--config`)
2. Per-host file (`--config <path>`)
3. `hosts/<profile>.local.yml`
4. `hosts/<profile>.yml`

**Key variables declared in host configs**

| Variable | Purpose |
|---|---|
| `DEFAULT_USER` | System user created and used throughout provisioning |
| `SSH_PORT` / `SSH_MAX_AUTH_TRIES` | SSH hardening knobs |
| `SSH_PERMIT_ROOT_LOGIN` / `SSH_PASSWORD_AUTH` | SSH access policy |
| `UFW_ALLOWED_PORTS` | Space-separated ports opened by firewall task |
| `FAIL2BAN_SSH_MAXRETRY` / `FAIL2BAN_SSH_BANTIME` | Fail2ban SSH jail tuning |
| `ENABLE_DOCKER` / `ENABLE_PORTAINER` / `ENABLE_SMTP` | Toggle container tasks on/off |
| `SMTP_DOMAIN` | Sender domain for the SMTP relay; the task is skipped while empty |
| `ENABLE_FAIL2BAN` | Toggle fail2ban on/off |
| `ENABLE_MDE` | Toggle Microsoft Defender install (default `false`) |
| `PROVISION_SERVERS_REPO_URL` | Git URL for the private `provision-servers` repo (agents/multi_deployment) |

---

### Inventory file (`inventory/hosts.yml`)

Used by `orchestrate.sh` for multi-host runs. Structure:

```yaml
groups:
  <group-name>:
    - <host-alias>
    - ...

hosts:
  <host-alias>:
    host: <IP or hostname>
    user: <ssh user>
    profile: <profile name>
```

`lib/inventory.sh` exposes two functions:

| Function | What it does |
|---|---|
| `inventory_to_json <file>` | Normalises `.json` or `.yml`/`.yaml` inventory to JSON (requires `yq` for YAML) |
| `inventory_select_hosts <file> <limit>` | Resolves a `--limit` value to a list of `name host user profile` rows. Matches a single host alias first; falls back to a group name |

**`--limit` resolution**

```
--limit docker-01       → resolves the single host entry
--limit docker_hosts    → resolves every host in the group
```

Output format per host (one line):

```
<alias> <ip/hostname> <user> <profile>
```

This output is consumed by `orchestrate.sh` to fan out SSH connections.

---

## Tasks

Tasks are the atomic provisioning units. They live in numbered directories under `tasks/` — the number controls execution order within a profile.

---

### `10-system/base.sh` — `run_base`

Bootstraps the minimum viable package set and system clock.

**What it does**
- Installs `ca-certificates`, `curl`, `git`, `rsync`, `software-properties-common` via `ensure_package`
- Sets system timezone via `timedatectl` when `SERVER_TIMEZONE` is defined; skipped otherwise

**Config variables**

| Variable | Default | Purpose |
|---|---|---|
| `SERVER_TIMEZONE` | _(unset)_ | Target timezone, e.g. `Europe/Tirane`. Skipped if empty |

---

### `10-system/unattended_upgrades.sh` — `run_unattended_upgrades`

Enables automatic background security patching via APT.

**What it does**
- Installs `unattended-upgrades`
- Writes `/etc/apt/apt.conf.d/50unattended-upgrades` — limits automatic upgrades to `-security` and `-updates` origins; disables automatic reboots
- Writes `/etc/apt/apt.conf.d/20auto-upgrades` — enables daily package list refresh and unattended upgrade
- Adds a cron job `0 3 * * *` that runs `unattended-upgrade -v`
- Enables and starts the `unattended-upgrades` service

No config variables — behaviour is fully determined by the Ubuntu release codename detected at runtime.

---

### `20-identity/user_forge.sh` — `run_user_forge`

Creates the operational system user and sets up SSH access.

**What it does**
- Creates `DEFAULT_USER` if absent
- Ensures the `sudo` group exists and adds the user to it
- Creates `~/.ssh/` with mode `700` and correct ownership
- For each key in `USER_SSH_KEYS[]`: appends it to `~/.ssh/authorized_keys` (idempotent, one key per line)

**Config variables**

| Variable | Default | Purpose |
|---|---|---|
| `DEFAULT_USER` | `forge` | Username to create |
| `USER_SSH_KEYS` | `[]` | Bash array of public key strings to authorize |

---

### `30-security/ssh_hardening.sh` — `run_ssh_hardening`

Enforces a hardened SSH daemon configuration.

**What it does**
- Backs up `/etc/ssh/sshd_config` and `/etc/ssh/sshd_config.d/99-provision.conf`
- Applies each option via `ensure_sshd_option` (idempotent per directive)
- Restarts `sshd` only when at least one value actually changed

**Config variables**

| Variable | Default | Purpose |
|---|---|---|
| `SSH_PORT` | `22` | Port sshd listens on |
| `SSH_PERMIT_ROOT_LOGIN` | `no` | `yes`/`no` |
| `SSH_PASSWORD_AUTH` | `no` | `yes`/`no` |
| `SSH_X11_FORWARDING` | `no` | `yes`/`no` |
| `SSH_MAX_AUTH_TRIES` | `3` | Max authentication attempts per connection |

---

### `30-security/firewall.sh` — `run_firewall`

Configures `ufw` with sensible defaults.

**What it does**
- Installs `ufw`
- Backs up existing user rule files
- Sets default incoming/outgoing policies
- Enables ufw if not already active
- Opens each port/service in `UFW_ALLOWED_PORTS` (falls back to `UFW_ALLOWED_SERVICES`, then `22 80 443`)

**Config variables**

| Variable | Default | Purpose |
|---|---|---|
| `UFW_DEFAULT_INCOMING` | `deny` | Default policy for incoming traffic |
| `UFW_DEFAULT_OUTGOING` | `allow` | Default policy for outgoing traffic |
| `UFW_ALLOWED_PORTS` | `22 80 443` | Space-separated ports to allow |
| `UFW_ALLOWED_SERVICES` | _(unset)_ | Space-separated ufw service names (used when `UFW_ALLOWED_PORTS` is empty) |

---

### `30-security/fail2ban.sh` — `run_fail2ban`

Protects SSH against brute-force login attempts.

**What it does**
- Short-circuits with `skipped` when `ENABLE_FAIL2BAN=false`
- Installs `fail2ban`
- Writes `/etc/fail2ban/jail.d/sshd-hardening.conf` with the configured SSH jail
- Enables and starts the `fail2ban` service

**Config variables**

| Variable | Default | Purpose |
|---|---|---|
| `ENABLE_FAIL2BAN` | `true` | Set to `false`/`no`/`0` to skip entirely |
| `FAIL2BAN_SSH_MAXRETRY` | `3` | Failed attempts before ban |
| `FAIL2BAN_SSH_BANTIME` | `1h` | Duration of ban |
| `FAIL2BAN_SSH_FINDTIME` | `10m` | Window in which retries are counted |

---

### `30-security/microsoft_defender.sh` — `run_microsoft_defender`

Installs and configures Microsoft Defender for Endpoint (MDE/mdatp). **Disabled by default.**

**What it does**
1. Guards: skipped if `ENABLE_MDE=false` or distro is not Ubuntu
2. Installs the Microsoft APT repo and signing key, then installs `mdatp`
3. Enables and starts the `mdatp` service
4. Sets active vs passive mode (`MDE_MODE`)
5. Runs onboarding script or command if `MDE_ONBOARDING_ENABLED=true`
6. Performs a health check (installed, running, healthy flags); can fail the run when `MDE_FAIL_ON_UNHEALTHY=true`

**Config variables**

| Variable | Default | Purpose |
|---|---|---|
| `ENABLE_MDE` | `false` | Master switch |
| `MDE_MODE` | `active` | `active` or `passive` |
| `MDE_ALLOW_PASSIVE_MODE` | `false` | Must be `true` to allow passive mode |
| `MDE_ONBOARDING_ENABLED` | `false` | Run onboarding step |
| `MDE_ONBOARDING_SCRIPT` | _(unset)_ | Path to executable onboarding script |
| `MDE_ONBOARDING_COMMAND` | _(unset)_ | Shell command string for onboarding |
| `MDE_HEALTHCHECK_ENABLED` | `true` | Run health check after setup |
| `MDE_FAIL_ON_UNHEALTHY` | `false` | Exit non-zero if health check fails |
| `ROLE_K8S_WORKER` | `false` | When `true`, MDE is skipped unless `ENABLE_MDE=true` |

See `docs/microsoft-defender.md` for a detailed usage guide.

---

### `40-container/docker.sh` — `run_docker`

Installs the official Docker Engine from Docker's APT repository.

**What it does**
- Short-circuits when `ENABLE_DOCKER=false`
- Downloads and installs the Docker GPG signing key to `/etc/apt/keyrings/docker.asc`
- Adds the Docker stable APT repo
- Installs `docker-ce`, `docker-ce-cli`, `containerd.io`, `docker-buildx-plugin`, `docker-compose-plugin`
- Creates the `docker` group and adds `DEFAULT_USER` to it
- Enables and starts the `docker` service

**Config variables**

| Variable | Default | Purpose |
|---|---|---|
| `ENABLE_DOCKER` | varies by profile | Set to `false` to skip |
| `DOCKER_GPG_URL` | Docker's official URL | Override for air-gapped mirrors |

---

### `40-container/portainer.sh` — `run_portainer`

Deploys Portainer CE as a persistent Docker container.

**What it does**
- Short-circuits when `ENABLE_PORTAINER=false` or Docker is not installed
- Creates the named data volume if absent
- Pulls the image when `PORTAINER_PULL_IMAGE=true`
- Detects drift in: image tag, restart policy, HTTP/HTTPS port bindings, docker socket mount, data volume mount
- Recreates the container if any drift is detected; starts it if stopped

**Config variables**

| Variable | Default | Purpose |
|---|---|---|
| `ENABLE_PORTAINER` | varies by profile | Set to `false` to skip |
| `PORTAINER_IMAGE` | `portainer/portainer-ce:latest` | Image to deploy |
| `PORTAINER_CONTAINER_NAME` | `portainer` | Container name |
| `PORTAINER_VOLUME_NAME` | `portainer_data` | Named volume for persistent data |
| `PORTAINER_HTTP_PORT` | `9000` | Host port mapped to container port 9000 |
| `PORTAINER_HTTPS_PORT` | `9443` | Host port mapped to container port 9443 |
| `PORTAINER_PULL_IMAGE` | `false` | Pull latest image before run |

---

### `40-container/smtp.sh` — `run_smtp`

Builds `docker/smtp/` (Alpine, Postfix + OpenDKIM, ported from `boilerplate_iac`) and runs it as a
send-only relay for every stack on the host.

**What it does**
- Short-circuits when `ENABLE_SMTP=false` or Docker is not installed
- Resolves `SMTP_DOMAIN`: config → interactive prompt (host FQDN domain offered as default); skips the task if still empty
- Renders `/etc/provision/smtp.env` (mode 600) from the `SMTP_*` variables
- Creates the `smtp_spool` / `smtp_dkim` volumes and the attachable `smtp` bridge network
- Builds the image, labelled with a hash of `docker/smtp/`; rebuilds only when those files change
- Detects drift in: image, restart policy, env file (label hash), network, volume mounts, port binding; recreates the container when any differs
- Reports `failed` when `docker run` / `docker start` fails or the container is not running afterwards
- Writes the SPF / DKIM / DMARC records to publish (one block per sender domain) to `/etc/provision/smtp-dns.txt`

Apps join the `smtp` network (`networks: smtp: external: true`) and send to `smtp:25`, no auth, no TLS
inside the network. Only envelope senders `@SMTP_ALLOWED_SENDER_DOMAINS` are accepted (rejected at `RCPT TO`).
The DKIM key is generated on first start into `smtp_dkim`; a fresh volume means a new DNS record.
If OpenDKIM is down, mail is deferred (`451`) instead of leaving unsigned, and the container exits so the restart policy revives it.

**Config variables**

| Variable | Default | Purpose |
|---|---|---|
| `ENABLE_SMTP` | `true` on `docker_host` | Set to `false` to skip |
| `SMTP_DOMAIN` | empty = skip | Mail leaves as `*@domain`; DKIM-signed for it |
| `SMTP_HOSTNAME` | `mail.$SMTP_DOMAIN` | HELO name; needs A + PTR for direct delivery |
| `SMTP_ALLOWED_SENDER_DOMAINS` | `$SMTP_DOMAIN` | Space-separated envelope-sender allowlist |
| `SMTP_ALLOWED_NETWORKS` | RFC 1918 ranges | Who may submit mail (Postfix `mynetworks`) |
| `SMTP_DKIM_SELECTOR` / `SMTP_DKIM_BITS` | `mail` / `2048` | DKIM selector and key size |
| `SMTP_MESSAGE_SIZE_LIMIT` | `26214400` | Max message size in bytes |
| `SMTP_RELAY_HOST/PORT/USER/PASSWORD` | empty / `587` | Optional upstream relay (SES, Mailgun, Postmark); empty = direct delivery |
| `SMTP_RELAY_TLS` | `true` | Require TLS to the upstream relay |
| `SMTP_DMARC_POLICY` / `SMTP_DMARC_RUA` | `quarantine` / `postmaster@$SMTP_DOMAIN` | Values printed in the DMARC record |
| `SMTP_CONTAINER_NAME` | `smtp` | Container name |
| `SMTP_IMAGE` | `provision/smtp:latest` | Image tag built from `docker/smtp` |
| `SMTP_REBUILD_IMAGE` | `false` | `true` rebuilds with `--pull --no-cache` on every run (base image and apk patches) and recreates the container |
| `SMTP_NETWORK` | `smtp` | Attachable bridge network apps join; alias `smtp` |
| `SMTP_SPOOL_VOLUME` / `SMTP_DKIM_VOLUME` | `smtp_spool` / `smtp_dkim` | Postfix queue and DKIM key volumes |
| `SMTP_ENV_FILE` | `/etc/provision/smtp.env` | Rendered env file passed to the container |
| `SMTP_HOST_PORT` / `SMTP_HOST_BIND` | empty / `127.0.0.1` | Publish port 25 on the host; empty = not published |

`--config` files may also set `docker.smtp`, `smtp.domain`, `smtp.hostname`, `smtp.relay_host`.

---

### `50-extensions/provision_servers.sh` — `run_provision_servers_extension`

Bootstraps the private `provision-servers` repository onto the machine. Only runs for `agents` and `multi_deployment` profiles.

**What it does**
1. Generates an `ed25519` SSH key for `DEFAULT_USER` if absent
2. Adds `github.com` to `~/.ssh/known_hosts` via `ssh-keyscan`
3. Clones or pulls the `provision-servers` repo; prompts for manual key grant in interactive mode if access fails
4. Writes the active profile name to `.server_type` inside the repo
5. Resolves the profile-specific sub-folder (`agents/` or `deployment/`) and runs its `setup.sh`

**Config variables**

| Variable | Default | Purpose |
|---|---|---|
| `PROVISION_SERVERS_REPO_URL` | `git@github.com:snet-al/provision-servers.git` | SSH URL of the private repo |
| `PROVISION_SERVERS_DIR` | `/home/$DEFAULT_USER/provision/provision-servers` | Clone destination |
| `PROVISION_NON_INTERACTIVE` | `false` | When `true`, fails instead of prompting for key access |

---

### `90-post/post_setup.sh` — `run_post_setup`

Cleans up workspace permissions after all other tasks have run.

**What it does**
- Ensures `~/provision/` exists with mode `750` and owned by `DEFAULT_USER`
- Recursively sets ownership to `DEFAULT_USER:DEFAULT_USER` under that directory
- Tightens all **directory** modes to `750` — regular file modes are intentionally left untouched to avoid spurious Git mode changes after a root-run provisioning

No config variables.

---

## Profile × Task Matrix

| Task | basic | docker_host | agents | multi_deployment |
|---|:---:|:---:|:---:|:---:|
| base | ✓ | ✓ | ✓ | ✓ |
| user_forge | ✓ | ✓ | ✓ | ✓ |
| ssh_hardening | ✓ | ✓ | ✓ | ✓ |
| unattended_upgrades | ✓ | ✓ | ✓ | ✓ |
| firewall | ✓ | ✓ | ✓ | ✓ |
| fail2ban | ✓ | ✓ | ✓ | ✓ |
| microsoft_defender | opt-in | opt-in | opt-in | opt-in |
| docker | — | ✓ | ✓ | ✓ |
| portainer | — | ✓ | — | — |
| smtp | — | ✓ | — | — |
| provision_servers_extension | — | — | ✓ | ✓ |
| post_setup | — | ✓ | ✓ | ✓ |
