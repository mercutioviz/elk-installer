# shellcheck shell=bash
# lib/ssh.sh — shared ssh wrapper.
#
# Centralizes ssh options so every phase talks to targets the same way,
# and uses ControlMaster to multiplex many short-lived commands over a
# single TCP connection (fast per-host check batteries).
#
# Public functions:
#   ssh::for_host HOST          # prepare options for HOST (reads inventory)
#   ssh::exec     HOST CMD...   # run CMD on HOST, return its exit code
#   ssh::exec_sudo HOST CMD...  # run CMD on HOST via sudo -n
#   ssh::shutdown HOST          # close the multiplexed master
#   ssh::shutdown_all           # close all masters opened this run

if [[ -n "${_ELK_SSH_LOADED:-}" ]]; then return 0; fi
_ELK_SSH_LOADED=1

# shellcheck source=./common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
# shellcheck source=./inventory.sh
source "$(dirname "${BASH_SOURCE[0]}")/inventory.sh"

# Per-run socket directory. Always under the user's home so ssh's strict
# permission checks on ControlPath are satisfied.
ELK_SSH_CTRL_DIR="${ELK_SSH_CTRL_DIR:-${HOME}/.cache/elk-installer/ssh}"

_ssh::ensure_ctrl_dir() {
  if [[ ! -d "$ELK_SSH_CTRL_DIR" ]]; then
    mkdir -p "$ELK_SSH_CTRL_DIR"
    chmod 700 "$ELK_SSH_CTRL_DIR"
  fi
}

# Build the ssh argument array for a given host. We resolve inventory
# values each call (cheap; yq is fast) so callers don't have to manage state.
_ssh::args_for() {
  local host="$1"
  local user key addr
  user=$(inventory::host_field "$host" ssh_user)
  key=$(inventory::host_field "$host" ssh_key)
  addr=$(inventory::host_field "$host" address)
  # expand leading ~ in key path
  key="${key/#\~/$HOME}"

  if [[ -z "$user" || -z "$key" || -z "$addr" ]]; then
    die "ssh: incomplete inventory for host '$host' (user='$user' key='$key' addr='$addr')"
  fi
  if [[ ! -r "$key" ]]; then
    die "ssh: key not readable: $key"
  fi

  _ssh::ensure_ctrl_dir
  local ctrl_path="${ELK_SSH_CTRL_DIR}/${host}.%C"

  printf '%s\0' \
    -i "$key" \
    -o BatchMode=yes \
    -o ConnectTimeout=8 \
    -o StrictHostKeyChecking=accept-new \
    -o ServerAliveInterval=30 \
    -o ServerAliveCountMax=3 \
    -o ControlMaster=auto \
    -o "ControlPath=${ctrl_path}" \
    -o ControlPersist=60s \
    "${user}@${addr}"
}

ssh::for_host() {
  # Reserved for future per-host setup (e.g. priming known_hosts). Today
  # accept-new handles first-contact host keys safely.
  local host="$1"
  inventory::host_field "$host" address >/dev/null \
    || die "ssh::for_host: unknown host '$host'"
}

ssh::exec() {
  local host="$1"; shift
  local args=()
  # Read NUL-separated ssh args back into an array.
  while IFS= read -r -d '' arg; do
    args+=("$arg")
  done < <(_ssh::args_for "$host")
  ssh "${args[@]}" -- "$@"
}

ssh::exec_sudo() {
  local host="$1"; shift
  # Wrap the command in sudo -n. We pass it as a single string to the
  # remote shell so quoting survives.
  ssh::exec "$host" "sudo -n bash -lc $(printf '%q' "$*")"
}

ssh::shutdown() {
  local host="$1"
  local args=()
  while IFS= read -r -d '' arg; do
    args+=("$arg")
  done < <(_ssh::args_for "$host" 2>/dev/null) || return 0
  ssh -O exit "${args[@]}" 2>/dev/null || true
}

ssh::shutdown_all() {
  local h
  while read -r h; do
    [[ -n "$h" ]] && ssh::shutdown "$h"
  done < <(inventory::hosts 2>/dev/null)
}
