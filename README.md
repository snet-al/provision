# Bash-First Provisioning Framework (Ubuntu 24.04)

This repository supports two execution styles through the same framework:

- **Interactive mode**: `sudo ./setup.sh`
- **Config-first declarative mode**: CLI flags and host config files

The project stays **bash-first** and does **not** require Ansible or Python runtime orchestration.

## What Changed

The provisioning logic is being refactored into Ansible-like layers:

- `lib/` shared idempotent helpers and runtime framework
- `tasks/` reusable provisioning units
- `profiles/` task compositions
- `inventory/` and `orchestrate.sh` for multi-host runs over SSH
- `reports/` machine-readable JSON execution summaries
- Interactive and non-interactive flows now share the same `lib/`, `tasks/`, and `profiles/` framework

## Folder Structure

```text
.
├── lib/
│   ├── core.sh
│   ├── logging.sh
│   ├── ensure.sh
│   ├── files.sh
│   ├── services.sh
│   ├── config.sh
│   └── inventory.sh
├── tasks/
│   ├── 10-system/
│   │   ├── base.sh
│   │   └── unattended_upgrades.sh
│   ├── 20-identity/
│   │   └── user_forge.sh
│   ├── 30-security/
│   │   ├── ssh_hardening.sh
│   │   ├── firewall.sh
│   │   ├── fail2ban.sh
│   │   └── microsoft_defender.sh
│   ├── 40-container/
│   │   ├── docker.sh
│   │   └── portainer.sh
│   ├── 50-extensions/
│   │   └── provision_servers.sh
│   └── 90-post/
│       └── post_setup.sh
├── profiles/
│   ├── basic.sh
│   ├── docker_host.sh
│   ├── agents.sh
│   └── multi_deployment.sh
├── hosts/
│   ├── basic.yml
│   ├── docker_host.yml
│   ├── agents.yml
│   ├── multi_deployment.yml
│   └── examples/
├── inventory/
│   ├── hosts.yml
│   ├── group_vars/
│   └── host_vars/
├── docs/
│   ├── microsoft-defender.md
│   └── security-modules-architecture.md
├── tests/
├── reports/
├── orchestrate.sh
└── setup.sh
```

## Profiles

- `basic` = base + user_forge + ssh_hardening + unattended_upgrades + firewall + fail2ban
- `docker_host` = basic + docker + portainer + post_setup
- `agents` = basic + docker + `provision-servers` agent extension + post_setup
- `multi_deployment` = basic + docker + `provision-servers` deployment extension + post_setup

## Optional Security Agent: Microsoft Defender

MDE support is available as an optional task module and is disabled by default.

- Task: `tasks/30-security/microsoft_defender.sh`
- Activation: `env.ENABLE_MDE=true`
- Behavior: idempotent install/config/health checks
- Kubernetes workers: explicit opt-in only (`ROLE_K8S_WORKER=true` + `ENABLE_MDE=true`)

Detailed guide:

- `docs/microsoft-defender.md`
- `docs/security-modules-architecture.md`

## Usage

### 1) Interactive Mode

```bash
sudo ./setup.sh
```

This starts profile selection prompts and runs the same framework used by non-interactive mode.

Interactive runs now require a real password for `DEFAULT_USER` (normally `forge`) so the account can use `sudo` after login. If the user does not already have a password, setup prompts for one securely during the identity task. SSH public keys are still prompted/configured separately.

### 2) Profile-Driven Non-Interactive Mode

```bash
sudo ./setup.sh --profile docker_host --non-interactive --apply
```

### 3) Declarative Host Config (YAML only)

YAML configs require `yq`:

```bash
sudo ./setup.sh --config ./hosts/basic.yml --apply --non-interactive
```

Non-interactive runs cannot prompt for the `forge` password. If the target user does not already have a password set, setup now fails rather than leaving the user passwordless.

### 4) Profile Baseline Config

Each profile reads:

- `hosts/<profile>.yml` (required baseline)
- `hosts/<profile>.local.yml` (optional local override, ignored by git)

Example:

```bash
sudo ./setup.sh --profile docker_host --non-interactive --apply
```

## Config Precedence

1. CLI arguments
2. Per-host config file (`--config`)
3. `hosts/<profile>.local.yml`
4. `hosts/<profile>.yml`

## Multi-Server Orchestration

Provision from a laptop/control machine over SSH (no dedicated server):

```bash
./orchestrate.sh --inventory inventory/hosts.yml --limit docker_hosts
./orchestrate.sh --inventory inventory/hosts.yml --limit docker-01
./orchestrate.sh --inventory inventory/hosts.yml --limit docker_hosts --batch-size 2
./orchestrate.sh --inventory inventory/hosts.yml --limit docker_hosts --parallel 4
```

`orchestrate.sh` streams a repo snapshot to remote hosts, runs `setup.sh` remotely in non-interactive mode, and collects JSON reports.

## Logging and Reports

- Host log file: `/var/log/provision.log`
- Local JSON report: `reports/<timestamp>/<hostname>.json`

Example report:

```json
{
  "host": "docker-01",
  "profile": "docker_host",
  "ok": 12,
  "changed": 4,
  "failed": 0,
  "skipped": 3,
  "duration_sec": 41
}
```

At the end of each run, setup prints:

- `OK`
- `CHANGED`
- `FAILED`
- `SKIPPED`

## Safety / Backups

Critical file operations (for example SSH config updates) use backup helpers and keep backups under:

- `BACKUP_DIR` from config if set
- fallback `/etc/provision-backups`

Post-setup permission normalization is careful not to recursively chmod files inside user Git worktrees. Directory permissions and ownership are normalized, but regular file modes are left intact to avoid spurious Git mode changes after root-run provisioning.

## Idempotency Notes

Idempotency primitives live in `lib/ensure.sh` (`ensure_package`, `ensure_user`, `ensure_line_in_file`, `ensure_sshd_option`, `ensure_service_*`, etc.).

Re-running the same config should result in mostly `ok`/`skipped`, with minimal `changed`.

## Testing and Validation

```bash
bash tests/test_mde.sh
bash tests/test_ensure.sh
bash tests/test_config.sh
bash tests/test_inventory.sh
bash tests/test_profiles.sh
bash -n setup.sh orchestrate.sh lib/*.sh tasks/10-system/*.sh tasks/20-identity/*.sh tasks/30-security/*.sh tasks/40-container/*.sh tasks/90-post/*.sh profiles/*.sh tests/*.sh
```

- `test_config.sh` requires `yq` for YAML config parsing checks.

## Migration Notes

- Use `sudo ./setup.sh` for interactive provisioning with the new framework.
- Use `--profile` and/or `--config` for deterministic automation.
- YAML is the only supported config format.
- Keep machine-local overrides in `hosts/<profile>.local.yml`.
- For MDE examples see `hosts/examples/`.
