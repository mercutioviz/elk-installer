# shellcheck shell=bash
# lib/inventory.sh — inventory + profile YAML reader.
#
# Backed by yq (Debian python-yq, a jq wrapper). Read-only: this module
# never mutates the inventory file.
#
# Public functions:
#   inventory::load PATH                  # validate + set ELK_INVENTORY_FILE
#   inventory::stack_version              # echo pinned version (or empty)
#   inventory::profile                    # echo profile name
#   inventory::hosts                      # echo every host name, one per line
#   inventory::host_field HOST FIELD      # echo a top-level host field
#   inventory::roles_for HOST             # echo roles for one host
#   inventory::vendors                    # echo enabled template names
#   inventory::vendor_field VENDOR FIELD  # echo a field from one templates[] entry
#   inventory::kibana_fqdn                # echo kibana.public_fqdn
#   inventory::kibana_email               # echo kibana.letsencrypt_email
#   inventory::kibana_allowed_cidrs       # echo allowed_cidrs, one per line

if [[ -n "${_ELK_INVENTORY_LOADED:-}" ]]; then return 0; fi
_ELK_INVENTORY_LOADED=1

# shellcheck source=./common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

ELK_INVENTORY_FILE="${ELK_INVENTORY_FILE:-${ELK_REPO_ROOT}/inventory.yml}"

_inv::_yq() {
  # Wrap yq invocation so we can swap parsers later if we choose.
  yq -r "$@" "$ELK_INVENTORY_FILE"
}

# Return 0 if a yq expression yields non-empty/non-null output.
_inv::_has() {
  local out
  out=$(_inv::_yq "$1" 2>/dev/null) || return 1
  [[ -n "$out" && "$out" != "null" ]]
}

inventory::load() {
  local path="${1:-$ELK_INVENTORY_FILE}"
  [[ -r "$path" ]] || die "inventory: file not readable: $path"
  ELK_INVENTORY_FILE="$path"
  export ELK_INVENTORY_FILE

  # Minimal structural validation. Phases do their own deeper checks.
  _inv::_has '.profile' \
    || die "inventory: missing required field .profile in $path"
  _inv::_has '.hosts | length > 0' \
    || die "inventory: .hosts must be a non-empty list in $path"
  local h
  while read -r h; do
    [[ -n "$h" && "$h" != "null" ]] \
      || die "inventory: every host needs a .name in $path"
  done < <(_inv::_yq '.hosts[].name')
}

inventory::profile()        { _inv::_yq '.profile // ""'; }
inventory::stack_version()  { _inv::_yq '.stack_version // ""'; }

inventory::hosts() {
  _inv::_yq '.hosts[].name'
}

inventory::host_field() {
  local host="$1" field="$2"
  # shellcheck disable=SC2016 # $h/$f are jq vars supplied via --arg, not shell expansions
  _inv::_yq --arg h "$host" --arg f "$field" \
    '.hosts[] | select(.name == $h) | .[$f] // ""'
}

inventory::roles_for() {
  local host="$1"
  # shellcheck disable=SC2016 # $h is a jq var
  _inv::_yq --arg h "$host" \
    '.hosts[] | select(.name == $h) | .roles[]?'
}

inventory::vendors() {
  _inv::_yq '.templates[]? | select(.enabled == true) | .name'
}

inventory::vendor_field() {
  local vendor="$1" field="$2"
  # shellcheck disable=SC2016 # $v/$f are jq vars
  _inv::_yq --arg v "$vendor" --arg f "$field" \
    '.templates[]? | select(.name == $v) | .[$f] // ""'
}

inventory::kibana_fqdn()           { _inv::_yq '.kibana.public_fqdn // ""'; }
inventory::kibana_email()          { _inv::_yq '.kibana.letsencrypt_email // ""'; }
inventory::kibana_allowed_cidrs()  { _inv::_yq '.kibana.allowed_cidrs[]? // empty'; }
