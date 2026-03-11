# Microsoft Defender for Endpoint (Optional Module)

This repository includes optional support for Microsoft Defender for Endpoint (MDE) on Linux through `tasks/30-security/microsoft_defender.sh`.

## Why optional

MDE is intentionally not forced globally. Hosts can opt in per profile or per host override using YAML config values.

## Activation model

- Baseline config keys live in `hosts/<profile>.yml` under `env:`.
- Optional local overrides are supported in `hosts/<profile>.local.yml`.
- Host-level override via `--config` can enable MDE only where needed.

Primary switch:

- `ENABLE_MDE=true|false`

## Kubernetes note

Kubernetes worker nodes are **not enabled by default**. Set:

- `ROLE_K8S_WORKER=true`
- `ENABLE_MDE=true` (explicit opt-in)

This avoids forcing endpoint AV behavior on cluster workers without explicit approval.

## Supported OS behavior

Current guard supports Ubuntu targets only (aligned with this repository scope). Unsupported distro handling is safe and explicit (`skipped` with explanation).

## Configuration keys

```yaml
env:
  ENABLE_MDE: "false"
  MDE_MODE: active                  # active|passive
  MDE_ONBOARDING_ENABLED: "false"
  MDE_PACKAGE_STATE: present
  MDE_HEALTHCHECK_ENABLED: "true"
  MDE_ALLOW_PASSIVE_MODE: "false"
  MDE_FAIL_ON_UNHEALTHY: "false"
  MDE_TAGS: ""
  MDE_EXCLUSIONS_PATHS: ""
  MDE_EXCLUSIONS_PROCESSES: ""
  MDE_EXCLUSIONS_EXTENSIONS: ""
  MDE_ONBOARDING_SCRIPT: ""
  MDE_ONBOARDING_COMMAND: ""
  ROLE_K8S_WORKER: "false"
```

## Onboarding and secrets

Do not hardcode onboarding payloads in tracked files.

Use one of:

- `MDE_ONBOARDING_SCRIPT` -> executable local script path injected securely
- `MDE_ONBOARDING_COMMAND` -> secure command injected via runtime/local override

## Health checks and output

When enabled, task runs health checks and logs a structured line:

- installed
- service running
- passive mode
- antivirus enabled
- real-time protection enabled
- healthy

Soft issues are warnings by default. To enforce strict failure:

- `MDE_FAIL_ON_UNHEALTHY=true`

## Troubleshooting

### Package installed but service not running

- Check `systemctl status mdatp`
- Re-run provisioning with `--apply`

### MDE shows passive mode unexpectedly

- Ensure `MDE_MODE=active`
- Ensure `MDE_ALLOW_PASSIVE_MODE=false`

### Health command not found

- Verify `mdatp` package installation
- Check PATH and package integrity

### Unsupported distro message

- Confirm host is Ubuntu target supported by your provisioning policy
