# shellcheck shell=bash
# lib/common.sh — shared helpers for bin/ entrypoints.
# Source this once at the top of every entrypoint. Idempotent: safe to
# re-source.

# Guard against double-sourcing.
if [[ -n "${_ELK_COMMON_LOADED:-}" ]]; then
  return 0
fi
_ELK_COMMON_LOADED=1

# Repo root, resolved from this file's path. BASH_SOURCE works whether the
# script is run directly or sourced. Respect an env override so tests can
# point the installer at a temporary scratch tree.
ELK_REPO_ROOT="${ELK_REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
export ELK_REPO_ROOT

ELK_LIB_DIR="${ELK_LIB_DIR:-${ELK_REPO_ROOT}/lib}"
ELK_BIN_DIR="${ELK_BIN_DIR:-${ELK_REPO_ROOT}/bin}"
ELK_PROFILES_DIR="${ELK_PROFILES_DIR:-${ELK_REPO_ROOT}/profiles}"
ELK_TEMPLATES_DIR="${ELK_TEMPLATES_DIR:-${ELK_REPO_ROOT}/templates}"
export ELK_LIB_DIR ELK_BIN_DIR ELK_PROFILES_DIR ELK_TEMPLATES_DIR

# ----------------------------------------------------------------------------
# Logging. Every line is tagged with the current phase (set via _phase()).
# We log to stdout/stderr; bin/elk-install additionally tees to a log file
# under /var/log/elk-installer/ on the target host.
# ----------------------------------------------------------------------------
_ELK_PHASE="${_ELK_PHASE:-init}"
_ELK_USE_COLOR=1
if [[ ! -t 2 ]] || [[ -n "${NO_COLOR:-}" ]]; then
  _ELK_USE_COLOR=0
fi

_phase() { _ELK_PHASE="$1"; }

_log() {
  local level="$1"; shift
  local color_open="" color_close=""
  if (( _ELK_USE_COLOR )); then
    case "$level" in
      ERROR) color_open=$'\e[31m'; color_close=$'\e[0m' ;;
      WARN)  color_open=$'\e[33m'; color_close=$'\e[0m' ;;
      INFO)  color_open=$'\e[36m'; color_close=$'\e[0m' ;;
      DEBUG) color_open=$'\e[90m'; color_close=$'\e[0m' ;;
    esac
  fi
  printf '%s[%s] [phase=%s] %s%s\n' \
    "$color_open" "$level" "$_ELK_PHASE" "$*" "$color_close" >&2
}

log_info()  { _log INFO  "$@"; }
log_warn()  { _log WARN  "$@"; }
log_error() { _log ERROR "$@"; }
log_debug() {
  if [[ -n "${ELK_DEBUG:-}" ]]; then
    _log DEBUG "$@"
  fi
}

die() {
  log_error "$@"
  exit 1
}

# ----------------------------------------------------------------------------
# Stub helper: every unimplemented subcommand calls this so the user gets a
# consistent message and a non-zero exit, and we have one grep target to find
# what's left to build.
# ----------------------------------------------------------------------------
not_implemented() {
  local what="${1:-this subcommand}"
  log_warn "${what}: not yet implemented"
  log_warn "see README.md milestones for the build order"
  exit 64
}

# ----------------------------------------------------------------------------
# Dependency checks for the control node. Targets get a separate, stricter
# preflight in lib/preflight.sh.
# ----------------------------------------------------------------------------
require_cmd() {
  local cmd="$1"
  command -v "$cmd" >/dev/null 2>&1 \
    || die "required command not found on PATH: ${cmd}"
}

# ----------------------------------------------------------------------------
# Confirmation prompt. Returns 0 on yes, 1 on no. Honors ELK_ASSUME_YES.
# Per CLAUDE.md: destructive flags require confirmation unless the user
# explicitly opted in AND named the flag on the command line.
# ----------------------------------------------------------------------------
confirm() {
  local prompt="${1:-Proceed?}"
  if [[ -n "${ELK_ASSUME_YES:-}" ]]; then
    log_info "${prompt} [auto-yes]"
    return 0
  fi
  local reply
  read -r -p "${prompt} [y/N] " reply
  [[ "${reply,,}" == "y" || "${reply,,}" == "yes" ]]
}
