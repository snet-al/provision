# Security Modules Architecture Note

## Placement rationale

MDE was added as `tasks/30-security/microsoft_defender.sh` to match the repository's task/profile architecture and keep security agents modular.

## Idempotency strategy

- Package and service state use existing ensure helpers (`ensure_package`, `ensure_service_enabled`, `ensure_service_running`, `ensure_apt_repo`).
- Mode changes and onboarding are applied conditionally.
- Health checks are non-destructive by default.

## Role/profile activation

- Controlled through profile env defaults and host overrides.
- `ENABLE_MDE` gates execution.
- `ROLE_K8S_WORKER` + disabled `ENABLE_MDE` explicitly skips by design.

## Extensibility path

Future security agents should follow the same pattern:

- add `tasks/<NN-domain>/<agent>.sh`
- add optional env keys in profile YAML
- call from profile pipeline with opt-in guard

This keeps multi-agent growth structured without polluting bootstrap core scripts.
