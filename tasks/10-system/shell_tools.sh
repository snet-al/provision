#!/bin/bash

# Install and wire fzf (CTRL-R fuzzy history) and zoxide (`z` directory jumper)
# to match a typical interactive admin workstation setup.

SHELL_TOOLS_MARKER="provision:shell-tools"

shell_tools_bashrc_block() {
  cat <<'EOF'
# Larger shared history makes CTRL-R fuzzy search more useful
HISTCONTROL=ignoreboth:erasedups
HISTSIZE=50000
HISTFILESIZE=100000
shopt -s histappend
PROMPT_COMMAND="history -a; history -n${PROMPT_COMMAND:+; $PROMPT_COMMAND}"

# Fuzzy finder: CTRL-R history, CTRL-T file, ALT-C directory
if [ -f /usr/share/doc/fzf/examples/key-bindings.bash ]; then
  # shellcheck source=/dev/null
  source /usr/share/doc/fzf/examples/key-bindings.bash
fi
if [ -f /usr/share/doc/fzf/examples/completion.bash ]; then
  # shellcheck source=/dev/null
  source /usr/share/doc/fzf/examples/completion.bash
fi

# Smart cd: `z repoName` jumps to previously visited directories
if command -v zoxide >/dev/null 2>&1; then
  eval "$(zoxide init bash)"
fi
EOF
}

ensure_shell_tools_in_bashrc() {
  local bashrc="$1"
  local owner="${2:-}"
  local block

  if [[ ! -f "$bashrc" ]]; then
    if is_plan_mode; then
      log_status "changed" "ensure_shell_tools_in_bashrc" "plan: would create $bashrc with shell tools"
      return 0
    fi
    if [[ -f /etc/skel/.bashrc ]]; then
      cp /etc/skel/.bashrc "$bashrc"
    else
      touch "$bashrc"
    fi
    log_status "changed" "ensure_shell_tools_in_bashrc" "created $bashrc"
  fi

  block="$(shell_tools_bashrc_block)"
  ensure_block_in_file "$bashrc" "$SHELL_TOOLS_MARKER" "$block"

  if [[ -n "$owner" && "${PROVISION_MODE}" != "plan" ]]; then
    ensure_file_owner "$bashrc" "$owner"
  fi
}

run_shell_tools() {
  log_info "Running task: shell_tools"

  ensure_package fzf
  ensure_package zoxide

  ensure_shell_tools_in_bashrc "/home/$DEFAULT_USER/.bashrc" "$DEFAULT_USER:$DEFAULT_USER"
  ensure_shell_tools_in_bashrc "/root/.bashrc"
  ensure_shell_tools_in_bashrc "/etc/skel/.bashrc"

  log_status "ok" "run_shell_tools" "fzf + zoxide installed and wired into bashrc"
}
