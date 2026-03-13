#!/bin/bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$ROOT_DIR/lib/core.sh"
source "$ROOT_DIR/lib/logging.sh"
source "$ROOT_DIR/lib/inventory.sh"

INV_FILE=""
LIMIT=""
BATCH_SIZE=0
PARALLEL=1

usage() {
  cat <<USAGE
Usage:
  ./orchestrate.sh --inventory inventory/hosts.yml --limit docker_hosts

Options:
  --inventory <file>   Inventory file (.yml/.yaml with yq, or .json)
  --limit <target>     Group name or host name
  --batch-size <n>     Process hosts in batches
  --parallel <n>       Parallel workers
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --inventory) INV_FILE="$2"; shift 2 ;;
    --limit) LIMIT="$2"; shift 2 ;;
    --batch-size) BATCH_SIZE="$2"; shift 2 ;;
    --parallel) PARALLEL="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown arg: $1"; usage; exit 1 ;;
  esac
done

[[ -n "$INV_FILE" ]] || { echo "--inventory is required" >&2; exit 1; }
[[ -n "$LIMIT" ]] || { echo "--limit is required" >&2; exit 1; }

mkdir -p "$ROOT_DIR/reports/orchestrate"
RUN_DIR="$ROOT_DIR/reports/orchestrate/$(date +%Y%m%d_%H%M%S)"
mkdir -p "$RUN_DIR"

mapfile -t HOST_ROWS < <(inventory_select_hosts "$INV_FILE" "$LIMIT")
if [[ ${#HOST_ROWS[@]} -eq 0 ]]; then
  echo "No hosts matched limit '$LIMIT'" >&2
  exit 1
fi

run_remote() {
  local name="$1"
  local host="$2"
  local user="$3"
  local profile="$4"

  local remote_args=("--profile" "$profile" "--non-interactive" "--apply")

  local remote_dir="/tmp/provision-run-${name}-$$"
  echo "[$name] Syncing repository to $user@$host:$remote_dir"

  tar -C "$ROOT_DIR" -czf - . | ssh -o BatchMode=yes "$user@$host" "mkdir -p '$remote_dir' && tar -xzf - -C '$remote_dir'"

  echo "[$name] Executing setup.sh ${remote_args[*]}"
  if ssh -o BatchMode=yes "$user@$host" "cd '$remote_dir' && sudo ./setup.sh ${remote_args[*]}"; then
    echo "[$name] SUCCESS"
  else
    echo "[$name] FAILED"
  fi

  scp -q "$user@$host:$remote_dir/reports"/*/*.json "$RUN_DIR/${name}.json" 2>/dev/null || true
  ssh -o BatchMode=yes "$user@$host" "rm -rf '$remote_dir'" || true
}

process_slice() {
  local start="$1"
  local end="$2"
  local running=0
  local row

  for ((i=start; i<end; i++)); do
    row="${HOST_ROWS[$i]}"
    local name host user profile
    name="$(awk '{print $1}' <<<"$row")"
    host="$(awk '{print $2}' <<<"$row")"
    user="$(awk '{print $3}' <<<"$row")"
    profile="$(awk '{print $4}' <<<"$row")"

    run_remote "$name" "$host" "$user" "$profile" &
    running=$((running + 1))

    if [[ "$running" -ge "$PARALLEL" ]]; then
      wait -n
      running=$((running - 1))
    fi
  done
  wait || true
}

if [[ "$BATCH_SIZE" -gt 0 ]]; then
  total="${#HOST_ROWS[@]}"
  for ((offset=0; offset<total; offset+=BATCH_SIZE)); do
    end=$((offset + BATCH_SIZE))
    [[ "$end" -gt "$total" ]] && end="$total"
    echo "Processing batch $offset..$((end-1))"
    process_slice "$offset" "$end"
  done
else
  process_slice 0 "${#HOST_ROWS[@]}"
fi

echo "Per-host reports stored in: $RUN_DIR"
