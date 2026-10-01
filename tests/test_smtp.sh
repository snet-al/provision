#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/lib/core.sh"
source "$ROOT_DIR/lib/logging.sh"
source "$ROOT_DIR/lib/files.sh"
source "$ROOT_DIR/lib/services.sh"
source "$ROOT_DIR/lib/ensure.sh"
source "$ROOT_DIR/tasks/40-container/smtp.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
LOG_FILE="$TMP/test.log"
SMTP_ENV_FILE="$TMP/etc/smtp.env"
SMTP_DNS_WAIT_SEC=0
PROVISION_NON_INTERACTIVE="true"

# Stub docker: records calls and keeps container/image state in $STATE files,
# because run_smtp runs in a subshell here. Flag files: run_fails, start_fails.
STATE="$TMP/state"
mkdir -p "$STATE"

docker_inspect_stub() {
  [[ -f "$STATE/container" ]] || return 1
  case "$*" in
    *State.Restarting*) cat "$STATE/running" ;;
    *State.Running*) cut -d' ' -f1 "$STATE/running" ;;
    *RestartPolicy*) echo "unless-stopped" ;;
    *Config.Labels*) cat "$STATE/env_label" ;;
    *NetworkSettings*) echo "smtp" ;;
    *Mounts*) echo '[{"Name":"smtp_spool"},{"Name":"smtp_dkim"}]' ;;
    *PortBindings*) cat "$STATE/ports" ;;
    *.Image*) echo "sha256:image" ;;
  esac
}

docker_run_stub() {
  [[ -f "$STATE/run_fails" ]] && return 1
  local ports="{}"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --label) printf '%s\n' "${2#*=}" > "$STATE/env_label" ;;
      -p) ports="{\"25/tcp\":[{\"HostIp\":\"${2%%:*}\",\"HostPort\":\"$(cut -d: -f2 <<<"$2")\"}]}" ;;
    esac
    shift
  done
  printf '%s\n' "$ports" > "$STATE/ports"
  [[ -f "$STATE/running" ]] || echo "true false" > "$STATE/running"
  touch "$STATE/container"
}

docker() {
  printf '%s\n' "$*" >> "$TMP/docker.calls"
  case "$1 ${2:-}" in
    "image inspect")
      [[ -f "$STATE/image" ]] || return 1
      case "$*" in
        *Config.Labels*) cat "$STATE/image" ;;
        *) echo "sha256:image" ;;
      esac
      ;;
    "build "*)
      shift
      while [[ $# -gt 0 ]]; do
        [[ "$1" == "--label" ]] && printf '%s\n' "${2#*=}" > "$STATE/image"
        shift
      done
      ;;
    "ps "*) [[ -f "$STATE/container" ]] && echo "smtp" ;;
    "inspect "*) docker_inspect_stub "$@" || return 1 ;;
    "run "*) docker_run_stub "$@" || return 1 ;;
    "start "*)
      [[ -f "$STATE/start_fails" ]] && return 1
      echo "true false" > "$STATE/running"
      ;;
    "rm "*) rm -f "$STATE/container" "$STATE/running" ;;
    "exec "*) return 1 ;;
  esac
  return 0
}

expect() {
  local out="$1" needle="$2"
  if ! printf '%s\n' "$out" | grep -F -- "$needle" >/dev/null 2>&1; then
    echo "Expected output containing: $needle"
    printf '%s\n' "$out"
    exit 1
  fi
}

expect_not() {
  local out="$1" needle="$2"
  if printf '%s\n' "$out" | grep -F -- "$needle" >/dev/null 2>&1; then
    echo "Unexpected output containing: $needle"
    printf '%s\n' "$out"
    exit 1
  fi
}

# Case 1: disabled -> skipped
PROVISION_MODE="plan"
ENABLE_SMTP="false"
out="$(run_smtp 2>&1 || true)"
expect "$out" "disabled by config"

# Case 2: no domain, non-interactive -> skipped, even when the host has an FQDN
ENABLE_SMTP="true"
SMTP_DOMAIN=""
hostname() { echo "derived.example.com"; }
out="$(run_smtp 2>&1)"
expect "$out" "SMTP_DOMAIN not set"
expect_not "$out" "plan: would"

# Case 3: interactive prompt -> typed domain is used, host domain is only the default
PROVISION_NON_INTERACTIVE="false"
out="$(run_smtp 2>&1 <<<"typed.example.org")"
expect "$out" "plan: would write $SMTP_ENV_FILE"
[[ "$(smtp_prompt_domain "derived.example.com" 2>/dev/null <<<"")" == "derived.example.com" ]]
[[ "$(smtp_prompt_domain "" 2>/dev/null <<<"typed.example.org")" == "typed.example.org" ]]
[[ "$(smtp_prompt_domain "" 2>/dev/null < <(printf 'bad domain\nok.example.org\n'))" == "ok.example.org" ]]
unset -f hostname
hostname() { echo "localdomain"; }
out="$(run_smtp 2>&1 <<<"")"
expect "$out" "SMTP_DOMAIN not set"
out="$(run_smtp 2>&1 </dev/null)"
expect "$out" "SMTP_DOMAIN not set"
unset -f hostname
PROVISION_NON_INTERACTIVE="true"

# Case 4: invalid domain -> failed
SMTP_DOMAIN="not a domain"
out="$(run_smtp 2>&1 || true)"
expect "$out" "invalid SMTP_DOMAIN"

# Case 5: plan mode, nothing exists -> only "would" actions, no side effects
SMTP_DOMAIN="example.com"
out="$(run_smtp 2>&1 || true)"
expect "$out" "plan: would write $SMTP_ENV_FILE"
expect "$out" "plan: would create volume smtp_spool"
expect "$out" "plan: would create volume smtp_dkim"
expect "$out" "plan: would create network smtp"
expect "$out" "plan: would build provision/smtp:latest"
expect "$out" "plan: would run smtp container"
[[ ! -e "$SMTP_ENV_FILE" ]]
if grep -E '^(run|build|volume create|network create)' "$TMP/docker.calls" >/dev/null 2>&1; then
  echo "plan mode must not mutate docker"
  exit 1
fi

# Case 6: apply mode -> env file written 600, image built, container run without a port
PROVISION_MODE="apply"
: > "$TMP/docker.calls"
out="$(run_smtp 2>&1)"
expect "$out" "wrote $SMTP_ENV_FILE"
expect "$out" "built provision/smtp:latest"
expect "$out" "started smtp"
[[ "$(stat -c '%a' "$SMTP_ENV_FILE")" == "600" ]]
grep -Fx "SMTP_DOMAIN=example.com" "$SMTP_ENV_FILE" >/dev/null
grep -Fx "SMTP_HOSTNAME=mail.example.com" "$SMTP_ENV_FILE" >/dev/null
grep -Fx "SMTP_DMARC_RUA=postmaster@example.com" "$SMTP_ENV_FILE" >/dev/null
grep -F "run -d --name smtp --hostname mail.example.com --restart unless-stopped" "$TMP/docker.calls" >/dev/null
grep -F -- "--network smtp --network-alias smtp --env-file $SMTP_ENV_FILE" "$TMP/docker.calls" >/dev/null
if grep -F -- " -p " "$TMP/docker.calls" >/dev/null 2>&1; then
  echo "port must not be published by default"
  exit 1
fi

# Case 7: rerun with same config -> nothing rebuilt or recreated
: > "$TMP/docker.calls"
out="$(run_smtp 2>&1)"
expect "$out" "env file $SMTP_ENV_FILE up to date"
expect "$out" "image provision/smtp:latest up to date"
expect "$out" "already running with desired config"
if grep -E '^(run|build|rm) ' "$TMP/docker.calls" >/dev/null 2>&1; then
  echo "rerun must not rebuild or recreate"
  exit 1
fi

# Case 8: stopped container -> started; a failing start is reported as failed
echo "false false" > "$STATE/running"
out="$(run_smtp 2>&1)"
expect "$out" "started existing container smtp"
echo "false false" > "$STATE/running"
touch "$STATE/start_fails"
out="$(run_smtp 2>&1)" && rc=0 || rc=$?
expect "$out" "docker start failed for smtp"
[[ "$rc" -ne 0 ]]
rm -f "$STATE/start_fails"
echo "true false" > "$STATE/running"

# Case 9: env change -> drift -> recreated
SMTP_MESSAGE_SIZE_LIMIT="1000000"
out="$(run_smtp 2>&1)"
expect "$out" "drift detected: env file"
expect "$out" "recreated smtp with desired config"

# Case 10: publishing a host port -> drift -> binding added
SMTP_HOST_PORT="2525"
: > "$TMP/docker.calls"
out="$(run_smtp 2>&1)"
expect "$out" "drift detected: port binding"
grep -F -- "-p 127.0.0.1:2525:25" "$TMP/docker.calls" >/dev/null
out="$(run_smtp 2>&1)"
expect "$out" "already running with desired config"

# Case 11: docker run fails during recreate -> failed, never reported as recreated
SMTP_HOST_PORT="2526"
touch "$STATE/run_fails"
out="$(run_smtp 2>&1)" && rc=0 || rc=$?
expect "$out" "docker run failed for smtp"
expect_not "$out" "recreated smtp"
[[ "$rc" -ne 0 ]]
rm -f "$STATE/run_fails"

# Case 12: container created but crash-looping -> failed
echo "true true" > "$STATE/running"
out="$(run_smtp 2>&1)" && rc=0 || rc=$?
expect "$out" "container smtp is not running"
expect_not "$out" "started smtp"
[[ "$rc" -ne 0 ]]
echo "true false" > "$STATE/running"
out="$(run_smtp 2>&1)"

# Case 13: SMTP_REBUILD_IMAGE forces a patched rebuild even when sources are unchanged
SMTP_REBUILD_IMAGE="true"
: > "$TMP/docker.calls"
out="$(run_smtp 2>&1)"
expect "$out" "built provision/smtp:latest"
grep -E '^build --pull --no-cache ' "$TMP/docker.calls" >/dev/null

echo "test_smtp.sh passed"
