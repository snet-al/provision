#!/bin/bash

INVENTORY_FILE=""

inventory_to_json() {
  local input="$1"
  case "$input" in
    *.json)
      cat "$input"
      ;;
    *.yml|*.yaml)
      if command -v yq >/dev/null 2>&1; then
        yq -o=json "$input"
      else
        log_error "Inventory YAML requires yq. Provide JSON inventory or install yq."
        return 1
      fi
      ;;
    *)
      log_error "Unsupported inventory format: $input"
      return 1
      ;;
  esac
}

inventory_select_hosts() {
  local inventory_file="$1"
  local limit="$2"
  local tmp_json
  tmp_json="$(mktemp)"
  inventory_to_json "$inventory_file" > "$tmp_json"

  if jq -e --arg l "$limit" '.hosts[$l]' "$tmp_json" >/dev/null; then
    jq -r --arg l "$limit" '.hosts[$l] | "\($l) \(.host) \(.user // "root") \(.profile // "basic")"' "$tmp_json"
  else
    jq -r --arg l "$limit" '.groups[$l][]? as $h | .hosts[$h] | "\($h) \(.host) \(.user // "root") \(.profile // "basic")"' "$tmp_json"
  fi

  rm -f "$tmp_json"
}
