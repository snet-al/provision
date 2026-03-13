#!/bin/bash

ENSURE_LAST_STATUS="ok"

_set_ensure_status() {
  ENSURE_LAST_STATUS="$1"
  log_status "$1" "$2" "$3"
}

ensure_package() {
  local package="$1"
  if dpkg -s "$package" >/dev/null 2>&1; then
    _set_ensure_status "ok" "ensure_package" "$package already installed"
    return 0
  fi
  if is_plan_mode; then
    _set_ensure_status "changed" "ensure_package" "plan: would install $package"
    return 0
  fi
  if apt-get install -y "$package" >/dev/null; then
    _set_ensure_status "changed" "ensure_package" "installed $package"
  else
    _set_ensure_status "failed" "ensure_package" "failed installing $package"
    return 1
  fi
}

ensure_packages() {
  local pkg
  for pkg in "$@"; do
    ensure_package "$pkg"
  done
}

ensure_group_exists() {
  local group="$1"
  if getent group "$group" >/dev/null; then
    _set_ensure_status "ok" "ensure_group_exists" "$group already exists"
    return 0
  fi
  if is_plan_mode; then
    _set_ensure_status "changed" "ensure_group_exists" "plan: would create group $group"
    return 0
  fi
  groupadd "$group"
  _set_ensure_status "changed" "ensure_group_exists" "created group $group"
}

ensure_user() {
  local user="$1"
  if id "$user" >/dev/null 2>&1; then
    _set_ensure_status "ok" "ensure_user" "$user already exists"
    return 0
  fi
  if is_plan_mode; then
    _set_ensure_status "changed" "ensure_user" "plan: would create user $user"
    return 0
  fi
  adduser --gecos "" --disabled-password "$user" >/dev/null
  _set_ensure_status "changed" "ensure_user" "created user $user"
}

ensure_user_in_group() {
  local user="$1"
  local group="$2"
  if ! id "$user" >/dev/null 2>&1; then
    if is_plan_mode; then
      _set_ensure_status "changed" "ensure_user_in_group" "plan: would add $user to $group (user pending)"
      return 0
    fi
    _set_ensure_status "failed" "ensure_user_in_group" "user $user does not exist"
    return 1
  fi
  if id -nG "$user" | tr ' ' '\n' | grep -Fx "$group" >/dev/null 2>&1; then
    _set_ensure_status "ok" "ensure_user_in_group" "$user already in $group"
    return 0
  fi
  if is_plan_mode; then
    _set_ensure_status "changed" "ensure_user_in_group" "plan: would add $user to $group"
    return 0
  fi
  usermod -aG "$group" "$user"
  _set_ensure_status "changed" "ensure_user_in_group" "added $user to $group"
}

ensure_directory() {
  local dir="$1"
  local mode="${2:-}"
  local owner="${3:-}"
  if [[ -d "$dir" ]]; then
    _set_ensure_status "ok" "ensure_directory" "$dir exists"
  else
    if is_plan_mode; then
      _set_ensure_status "changed" "ensure_directory" "plan: would create $dir"
      return 0
    fi
    mkdir -p "$dir"
    _set_ensure_status "changed" "ensure_directory" "created $dir"
  fi
  [[ -n "$mode" ]] && ensure_file_mode "$dir" "$mode"
  [[ -n "$owner" ]] && ensure_file_owner "$dir" "$owner"
}

ensure_file_mode() {
  local path="$1"
  local mode="$2"
  local current
  current="$(stat -c '%a' "$path" 2>/dev/null || true)"
  if [[ "$current" == "$mode" ]]; then
    _set_ensure_status "ok" "ensure_file_mode" "$path mode already $mode"
    return 0
  fi
  if is_plan_mode; then
    _set_ensure_status "changed" "ensure_file_mode" "plan: would chmod $mode $path"
    return 0
  fi
  chmod "$mode" "$path"
  _set_ensure_status "changed" "ensure_file_mode" "set mode $mode on $path"
}

ensure_file_owner() {
  local path="$1"
  local owner="$2"
  local current
  current="$(stat -c '%U:%G' "$path" 2>/dev/null || true)"
  if [[ "$current" == "$owner" ]]; then
    _set_ensure_status "ok" "ensure_file_owner" "$path owner already $owner"
    return 0
  fi
  if is_plan_mode; then
    _set_ensure_status "changed" "ensure_file_owner" "plan: would chown $owner $path"
    return 0
  fi
  chown "$owner" "$path"
  _set_ensure_status "changed" "ensure_file_owner" "set owner $owner on $path"
}

ensure_line_in_file() {
  local file="$1"
  local line="$2"
  if [[ -f "$file" ]] && grep -F -- "$line" "$file" >/dev/null 2>&1; then
    _set_ensure_status "ok" "ensure_line_in_file" "$line already present in $file"
    return 0
  fi
  if is_plan_mode; then
    _set_ensure_status "changed" "ensure_line_in_file" "plan: would append line in $file"
    return 0
  fi
  touch "$file"
  printf '%s\n' "$line" >> "$file"
  _set_ensure_status "changed" "ensure_line_in_file" "added line to $file"
}

ensure_block_in_file() {
  local file="$1"
  local marker="$2"
  local block="$3"
  if [[ -f "$file" ]] && grep -F -- "$marker" "$file" >/dev/null 2>&1; then
    _set_ensure_status "ok" "ensure_block_in_file" "$marker already present in $file"
    return 0
  fi
  if is_plan_mode; then
    _set_ensure_status "changed" "ensure_block_in_file" "plan: would append block in $file"
    return 0
  fi
  touch "$file"
  {
    printf '\n# %s\n' "$marker"
    printf '%s\n' "$block"
  } >> "$file"
  _set_ensure_status "changed" "ensure_block_in_file" "added block to $file"
}

ensure_service_enabled() {
  local service="$1"
  if systemctl is-enabled "$service" >/dev/null 2>&1; then
    _set_ensure_status "ok" "ensure_service_enabled" "$service already enabled"
    return 0
  fi
  if is_plan_mode; then
    _set_ensure_status "changed" "ensure_service_enabled" "plan: would enable $service"
    return 0
  fi
  systemctl enable "$service" >/dev/null
  _set_ensure_status "changed" "ensure_service_enabled" "enabled $service"
}

ensure_service_running() {
  local service="$1"
  if systemctl is-active "$service" >/dev/null 2>&1; then
    _set_ensure_status "ok" "ensure_service_running" "$service already running"
    return 0
  fi
  if is_plan_mode; then
    _set_ensure_status "changed" "ensure_service_running" "plan: would start $service"
    return 0
  fi
  systemctl start "$service"
  _set_ensure_status "changed" "ensure_service_running" "started $service"
}

ensure_service_restarted_if_changed() {
  local service="$1"
  local changed_flag="$2"
  if [[ "$changed_flag" != "true" ]]; then
    _set_ensure_status "skipped" "ensure_service_restarted_if_changed" "$service unchanged"
    return 0
  fi
  if is_plan_mode; then
    _set_ensure_status "changed" "ensure_service_restarted_if_changed" "plan: would restart $service"
    return 0
  fi
  systemctl restart "$service"
  _set_ensure_status "changed" "ensure_service_restarted_if_changed" "restarted $service"
}

ensure_symlink() {
  local target="$1"
  local link="$2"
  if [[ -L "$link" ]] && [[ "$(readlink "$link")" == "$target" ]]; then
    _set_ensure_status "ok" "ensure_symlink" "$link already -> $target"
    return 0
  fi
  if is_plan_mode; then
    _set_ensure_status "changed" "ensure_symlink" "plan: would link $link -> $target"
    return 0
  fi
  ln -sfn "$target" "$link"
  _set_ensure_status "changed" "ensure_symlink" "linked $link -> $target"
}

ensure_cron_job() {
  local name="$1"
  local schedule="$2"
  local command="$3"
  local file="/etc/cron.d/$name"
  local desired="SHELL=/bin/bash\nPATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin\n$schedule root $command\n"
  local current=""
  [[ -f "$file" ]] && current="$(cat "$file")"
  if [[ "$current" == "$desired" ]]; then
    _set_ensure_status "ok" "ensure_cron_job" "$name already configured"
    return 0
  fi
  if is_plan_mode; then
    _set_ensure_status "changed" "ensure_cron_job" "plan: would write $file"
    return 0
  fi
  printf '%b' "$desired" > "$file"
  chmod 0644 "$file"
  _set_ensure_status "changed" "ensure_cron_job" "updated $file"
}

ensure_apt_repo() {
  local name="$1"
  local repo_line="$2"
  local list_file="/etc/apt/sources.list.d/${name}.list"
  local changed=false

  if [[ ! -f "$list_file" ]] || ! grep -F -- "$repo_line" "$list_file" >/dev/null 2>&1; then
    changed=true
    if is_plan_mode; then
      _set_ensure_status "changed" "ensure_apt_repo" "plan: would set apt repo $name"
    else
      printf '%s\n' "$repo_line" > "$list_file"
      _set_ensure_status "changed" "ensure_apt_repo" "set apt repo $name"
    fi
  else
    _set_ensure_status "ok" "ensure_apt_repo" "apt repo $name already present"
  fi

  if [[ "$changed" == "true" && "${PROVISION_MODE}" != "plan" ]]; then
    apt-get update -y >/dev/null || true
  fi
}

ensure_ufw_rule() {
  local rule="$1"
  local normalized="$rule"
  if [[ "$rule" =~ ^[0-9]+$ ]]; then
    normalized="${rule}/tcp"
  fi

  local numbered_status
  numbered_status="$(ufw status numbered 2>/dev/null || true)"

  # Port rules appear as "22/tcp", "443/tcp", etc.
  if [[ "$normalized" =~ ^[0-9]+/(tcp|udp)$ ]]; then
    if printf '%s\n' "$numbered_status" | grep -E "[[:space:]]${normalized}[[:space:]]+ALLOW[[:space:]]+IN" >/dev/null 2>&1; then
      _set_ensure_status "ok" "ensure_ufw_rule" "$normalized already configured"
      return 0
    fi
  else
    # Service name rules (ssh, http, https, etc.).
    if printf '%s\n' "$numbered_status" | grep -E "[[:space:]]${rule}[[:space:]]+ALLOW[[:space:]]+IN" >/dev/null 2>&1; then
      _set_ensure_status "ok" "ensure_ufw_rule" "$rule already configured"
      return 0
    fi
  fi

  if is_plan_mode; then
    _set_ensure_status "changed" "ensure_ufw_rule" "plan: would ufw allow $normalized"
    return 0
  fi
  ufw allow "$normalized" >/dev/null
  _set_ensure_status "changed" "ensure_ufw_rule" "allowed $normalized"
}

ensure_sshd_option() {
  local key="$1"
  local value="$2"
  local dropin_dir="/etc/ssh/sshd_config.d"
  local file="${dropin_dir}/99-provision.conf"

  local current=""
  if [[ -f "$file" ]]; then
    current="$(awk -v key="$key" '
      BEGIN { IGNORECASE=1 }
      $0 ~ "^[[:space:]]*#" { next }
      $1 == key { print $0 }
    ' "$file" | awk 'END{print}' || true)"
  fi
  if [[ "$current" == "$key $value" ]]; then
    _set_ensure_status "ok" "ensure_sshd_option" "$key already $value (drop-in)"
    return 0
  fi

  if is_plan_mode; then
    _set_ensure_status "changed" "ensure_sshd_option" "plan: would set $key $value in ssh drop-in"
    return 0
  fi

  mkdir -p "$dropin_dir"
  backup_file_if_exists "$file"

  local tmp_file
  tmp_file="$(mktemp)"
  if [[ -f "$file" ]]; then
    awk -v key="$key" '
      BEGIN { IGNORECASE=1 }
      $0 ~ "^[[:space:]]*#" { print; next }
      $1 == key { next }
      { print }
    ' "$file" > "$tmp_file"
  fi
  printf '%s %s\n' "$key" "$value" >> "$tmp_file"
  mv "$tmp_file" "$file"
  chmod 0644 "$file"

  if sshd -t; then
    _set_ensure_status "changed" "ensure_sshd_option" "$key set to $value (drop-in)"
  else
    _set_ensure_status "failed" "ensure_sshd_option" "invalid sshd config after setting $key"
    return 1
  fi
}
