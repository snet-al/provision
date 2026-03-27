#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/lib/core.sh"
source "$ROOT_DIR/lib/logging.sh"
source "$ROOT_DIR/lib/files.sh"
source "$ROOT_DIR/lib/services.sh"
source "$ROOT_DIR/lib/ensure.sh"
source "$ROOT_DIR/tasks/30-security/microsoft_defender.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
LOG_FILE="$TMP/test.log"

# Case 1: disabled -> skipped
PROVISION_MODE="plan"
ENABLE_MDE="false"
ROLE_K8S_WORKER="false"
out="$(run_microsoft_defender 2>&1 || true)"
if ! printf '%s\n' "$out" | grep -F "disabled by config" >/dev/null 2>&1; then
  echo "Expected disabled-by-config skip not found"
  exit 1
fi

# Case 2: k8s worker without opt-in -> skipped
ENABLE_MDE="false"
ROLE_K8S_WORKER="true"
out="$(run_microsoft_defender 2>&1 || true)"
if ! printf '%s\n' "$out" | grep -F "k8s worker detected; MDE is opt-in" >/dev/null 2>&1; then
  echo "Expected k8s opt-in skip not found"
  exit 1
fi

# Case 3: enabled in plan mode with unsupported distro function override -> skipped safely
ENABLE_MDE="true"
ROLE_K8S_WORKER="false"
mde_os_supported() { return 1; }
out="$(run_microsoft_defender 2>&1 || true)"
if ! printf '%s\n' "$out" | grep -F "unsupported distro" >/dev/null 2>&1; then
  echo "Expected unsupported-distro skip not found"
  exit 1
fi

echo "test_mde.sh passed"
