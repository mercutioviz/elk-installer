# shellcheck shell=bash
# lib/preflight.sh — per-target preflight checks.
#
# Each check function name is prefixed `_check_`. Each one prints a single
# line in the form `LEVEL|NAME|MESSAGE` to fd 3 and always returns 0; that
# way one fragile check can't take down the whole battery.
#
# LEVEL is one of: PASS  (everything good)
#                  WARN  (acceptable but worth noting)
#                  FAIL  (must be fixed before install can proceed)
#                  INFO  (purely informational)

if [[ -n "${_ELK_PREFLIGHT_LOADED:-}" ]]; then return 0; fi
_ELK_PREFLIGHT_LOADED=1

# shellcheck source=./common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
# shellcheck source=./inventory.sh
source "$(dirname "${BASH_SOURCE[0]}")/inventory.sh"
# shellcheck source=./ssh.sh
source "$(dirname "${BASH_SOURCE[0]}")/ssh.sh"

# Minimum thresholds — generous-ish defaults for a lab. Phases that need
# more (real ES data nodes) layer their own checks on top.
PREFLIGHT_MIN_RAM_MB=3500            # 3.5 GB; warns on smaller
PREFLIGHT_MIN_DISK_GB=20             # /var/lib/elasticsearch lives on /
PREFLIGHT_MIN_DEBIAN_VERSION=12      # bookworm or newer
PREFLIGHT_REQ_MAP_COUNT=262144       # ES requirement

# A single remote bash snippet collects everything in one ssh call. Keeps
# per-target latency low and avoids the non-interactive PATH gotcha — we
# explicitly extend PATH and prefer absolute paths for /sbin tools.
_preflight::_remote_probe() {
  cat <<'REMOTE'
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"
set -u

_kv() { printf '%s=%s\n' "$1" "$2"; }

# OS
. /etc/os-release 2>/dev/null
_kv os_id        "${ID:-unknown}"
_kv os_version   "${VERSION_ID:-unknown}"
_kv os_codename  "${VERSION_CODENAME:-unknown}"

# Kernel / arch
_kv kernel "$(uname -sr 2>/dev/null || echo unknown)"
_kv arch   "$(dpkg --print-architecture 2>/dev/null || uname -m)"

# Identity
_kv user   "$(id -un 2>/dev/null)"
_kv sudo_nopasswd "$(sudo -n true 2>/dev/null && echo yes || echo no)"

# Host
_kv hostname "$(hostname 2>/dev/null)"
_kv fqdn     "$(hostname -f 2>/dev/null || echo unknown)"
_kv ips      "$(hostname -I 2>/dev/null | tr -s ' ' ',' | sed 's/,$//')"

# Memory / disk
_kv mem_mb $(awk '/^MemTotal:/{printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || echo 0)
_kv root_disk_gb "$(df -BG --output=avail / 2>/dev/null | awk 'NR==2{gsub(/G/,"",$1); print $1+0}')"

# CPU
_kv cores $(nproc 2>/dev/null || echo 1)

# Time
_kv time_synced "$(timedatectl show -p NTPSynchronized --value 2>/dev/null || echo unknown)"
_kv ntp_active  "$(timedatectl show -p NTP             --value 2>/dev/null || echo unknown)"

# Sysctl
_kv vm_max_map_count "$(sysctl -n vm.max_map_count 2>/dev/null || echo unknown)"
_kv swappiness       "$(sysctl -n vm.swappiness     2>/dev/null || echo unknown)"

# Swap
_kv swap_bytes "$(awk '/^SwapTotal:/{print $2*1024}' /proc/meminfo 2>/dev/null || echo 0)"

# Firewall tooling
for t in nft iptables ufw; do
  if command -v "$t" >/dev/null 2>&1; then _kv "have_$t" yes; else _kv "have_$t" no; fi
done

# Already-installed ELK?
elk_pkgs=$(dpkg-query -W -f='${Package} ' 2>/dev/null | tr ' ' '\n' \
  | grep -E '^(elasticsearch|logstash|kibana|filebeat|metricbeat)$' | paste -sd, -)
_kv elk_pkgs "${elk_pkgs:-none}"

# Egress
for host in artifacts.elastic.co deb.debian.org; do
  if timeout 5 bash -c "</dev/tcp/$host/443" 2>/dev/null; then
    _kv "egress_${host//./_}" yes
  else
    _kv "egress_${host//./_}" no
  fi
done

# Listening ports we care about (anything binding 80/443/9200/9300/5044/5140/5141)
ports_in_use=$(sudo -n ss -tunlH 2>/dev/null | awk '{print $5}' | awk -F: '{print $NF}' \
  | sort -u | grep -E '^(22|80|443|514|5044|5140|5141|9200|9300|9600)$' | paste -sd, -)
_kv ports_in_use "${ports_in_use:-none}"

# Cloud metadata (AWS IMDSv2; silent on non-AWS)
TOKEN=$(curl -fsS -X PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 60" 2>/dev/null) || TOKEN=""
if [ -n "$TOKEN" ]; then
  _kv cloud aws
  for k in instance-id instance-type placement/region public-ipv4; do
    v=$(curl -fsS -H "X-aws-ec2-metadata-token: $TOKEN" \
        "http://169.254.169.254/latest/meta-data/$k" 2>/dev/null || echo "")
    safe_k=$(printf '%s' "$k" | tr '/-' '__')
    _kv "aws_$safe_k" "${v:-}"
  done
else
  _kv cloud unknown
fi
REMOTE
}

# Parse a key=value line out of the remote probe output. Trims trailing CR.
_preflight::_get() {
  local key="$1"
  awk -F= -v k="$key" '$1==k{for(i=2;i<=NF;i++){printf "%s%s",(i>2?"=":""),$i};print""}' \
    "$ELK_PROBE_OUT" | tr -d '\r'
}

# ---- individual checks ----
# Each prints LEVEL|NAME|MESSAGE on fd 3.

_check_ssh_login() {
  # By the time we get here, the probe ran. Existence of mandatory fields
  # is the proof; absence means the remote command never ran.
  if [[ -s "$ELK_PROBE_OUT" ]] && [[ -n "$(_preflight::_get os_id)" ]]; then
    echo "PASS|ssh-login|connected as $(_preflight::_get user)" >&3
  else
    echo "FAIL|ssh-login|remote probe produced no output" >&3
  fi
}

_check_sudo() {
  case "$(_preflight::_get sudo_nopasswd)" in
    yes) echo "PASS|sudo|passwordless sudo available" >&3 ;;
    no)  echo "FAIL|sudo|passwordless sudo required (got no)" >&3 ;;
    *)   echo "FAIL|sudo|could not determine sudo state" >&3 ;;
  esac
}

_check_os() {
  local id ver
  id=$(_preflight::_get os_id)
  ver=$(_preflight::_get os_version)
  if [[ "$id" != "debian" ]]; then
    echo "FAIL|os|expected debian, got '${id}'" >&3
    return
  fi
  local major="${ver%%.*}"
  if [[ "$major" -ge "$PREFLIGHT_MIN_DEBIAN_VERSION" ]]; then
    echo "PASS|os|debian $ver ($(_preflight::_get os_codename))" >&3
  else
    echo "FAIL|os|debian $ver < required ${PREFLIGHT_MIN_DEBIAN_VERSION}" >&3
  fi
}

_check_arch() {
  local a
  a=$(_preflight::_get arch)
  if [[ "$a" == "amd64" || "$a" == "arm64" ]]; then
    echo "PASS|arch|$a" >&3
  else
    echo "FAIL|arch|unsupported architecture: $a" >&3
  fi
}

_check_ram() {
  local mb host="$1"
  mb=$(_preflight::_get mem_mb)
  if [[ "$mb" -lt "$PREFLIGHT_MIN_RAM_MB" ]]; then
    echo "WARN|ram|${mb} MB < recommended ${PREFLIGHT_MIN_RAM_MB} MB; ES heap will be tight" >&3
    return
  fi
  # If this host has all four heavy roles (es + ls + kibana) AND it's
  # under 5 GB, we know from earlier experience that Kibana startup +
  # nginx install can OOM. Lab on t3.medium hit this; learning preserved.
  local has_es=0 has_ls=0 has_kbn=0 r
  while read -r r; do
    case "$r" in
      es-master|es-data|es-coord) has_es=1 ;;
      logstash)                   has_ls=1 ;;
      kibana)                     has_kbn=1 ;;
    esac
  done < <(inventory::roles_for "$host")

  if (( has_es && has_ls && has_kbn )) && [[ "$mb" -lt 5000 ]]; then
    echo "WARN|ram|${mb} MB on an all-in-one host; previously OOM'd during Kibana startup, expect to resize to 8 GB" >&3
  else
    echo "PASS|ram|${mb} MB" >&3
  fi
}

_check_disk() {
  local gb
  gb=$(_preflight::_get root_disk_gb)
  if [[ "$gb" -ge "$PREFLIGHT_MIN_DISK_GB" ]]; then
    echo "PASS|disk|${gb} GB free on /" >&3
  else
    echo "WARN|disk|${gb} GB free on / (< ${PREFLIGHT_MIN_DISK_GB} GB recommended)" >&3
  fi
}

_check_time() {
  local synced
  synced=$(_preflight::_get time_synced)
  if [[ "$synced" == "yes" ]]; then
    echo "PASS|time-sync|NTP synced" >&3
  else
    echo "FAIL|time-sync|clock not NTP synchronized (got '${synced}')" >&3
  fi
}

_check_max_map_count() {
  local v
  v=$(_preflight::_get vm_max_map_count)
  if [[ -z "$v" || "$v" == "unknown" ]]; then
    echo "WARN|max-map-count|could not read sysctl (will set during install)" >&3
  elif [[ "$v" -ge "$PREFLIGHT_REQ_MAP_COUNT" ]]; then
    echo "PASS|max-map-count|$v" >&3
  else
    echo "WARN|max-map-count|$v < required $PREFLIGHT_REQ_MAP_COUNT (will raise during install)" >&3
  fi
}

_check_swap() {
  local b
  b=$(_preflight::_get swap_bytes)
  if [[ "$b" == "0" ]]; then
    echo "PASS|swap|off" >&3
  else
    echo "WARN|swap|swap is on (${b} bytes); will disable for ES" >&3
  fi
}

_check_no_prior_elk() {
  local pkgs
  pkgs=$(_preflight::_get elk_pkgs)
  if [[ "$pkgs" == "none" ]]; then
    echo "PASS|prior-elk|no existing ELK packages" >&3
  else
    echo "FAIL|prior-elk|existing packages present: $pkgs" >&3
  fi
}

_check_egress() {
  local a b
  a=$(_preflight::_get egress_artifacts_elastic_co)
  b=$(_preflight::_get egress_deb_debian_org)
  if [[ "$a" == "yes" && "$b" == "yes" ]]; then
    echo "PASS|egress|artifacts.elastic.co + deb.debian.org reachable (443)" >&3
  else
    echo "FAIL|egress|artifacts.elastic.co=$a deb.debian.org=$b" >&3
  fi
}

_check_ports_free() {
  local used
  used=$(_preflight::_get ports_in_use)
  if [[ "$used" == "none" ]]; then
    echo "PASS|ports|no conflicts on 80/443/514/5044/5140/5141/9200/9300/9600" >&3
    return
  fi
  # Strip 22 (sshd) — always expected.
  local stripped
  stripped=$(echo "$used" | tr ',' '\n' | grep -v '^22$' | paste -sd, -)
  if [[ -z "$stripped" ]]; then
    echo "PASS|ports|only 22 (sshd) bound" >&3
  else
    echo "WARN|ports|already bound: $stripped" >&3
  fi
}

_check_inventory_role_sanity() {
  local host="$1" roles
  roles=$(inventory::roles_for "$host" | paste -sd, -)
  if [[ -z "$roles" ]]; then
    echo "FAIL|roles|host has no roles assigned in inventory" >&3
  else
    echo "INFO|roles|$roles" >&3
  fi
}

_check_cloud() {
  local cloud
  cloud=$(_preflight::_get cloud)
  case "$cloud" in
    aws)
      local id ity reg pip
      id=$(_preflight::_get aws_instance_id)
      ity=$(_preflight::_get aws_instance_type)
      reg=$(_preflight::_get aws_placement_region)
      pip=$(_preflight::_get aws_public_ipv4)
      echo "INFO|cloud|aws $ity $reg $id (public-ip=${pip:-none})" >&3
      ;;
    *)
      echo "INFO|cloud|not detected" >&3
      ;;
  esac
}

# ----------------------------------------------------------------------------
# preflight::check_target HOST
#
# Runs the probe over ssh once, then runs every check against the captured
# output. Prints a table per host. Returns 0 if no FAIL lines, 1 otherwise.
# ----------------------------------------------------------------------------
preflight::check_target() {
  local host="$1"
  log_info "preflight: $host"

  # Run remote probe.
  ELK_PROBE_OUT="$(mktemp -t elk-probe.XXXXXX)"
  trap 'rm -f "$ELK_PROBE_OUT"' RETURN

  local probe
  probe=$(_preflight::_remote_probe)
  if ! ssh::exec "$host" "bash -s" <<<"$probe" >"$ELK_PROBE_OUT" 2>/dev/null; then
    log_error "preflight: ssh probe failed for $host"
    return 1
  fi

  # Collect check output via fd 3 -> tempfile.
  local results
  results="$(mktemp -t elk-results.XXXXXX)"
  exec 3>"$results"

  _check_ssh_login
  _check_inventory_role_sanity "$host"
  _check_sudo
  _check_os
  _check_arch
  _check_ram "$host"
  _check_disk
  _check_time
  _check_max_map_count
  _check_swap
  _check_no_prior_elk
  _check_egress
  _check_ports_free
  _check_cloud

  exec 3>&-

  # Print table.
  _preflight::_print_table "$host" "$results"

  # Exit status.
  if grep -q '^FAIL|' "$results"; then
    rm -f "$results"
    return 1
  fi
  rm -f "$results"
  return 0
}

_preflight::_print_table() {
  local host="$1" results="$2"
  echo
  printf '  %-6s  %-20s  %s\n' "LEVEL" "CHECK" "MESSAGE"
  printf '  %-6s  %-20s  %s\n' "------" "--------------------" "--------------------------------------------"
  local color
  while IFS='|' read -r level name msg; do
    if [[ -t 1 ]]; then
      case "$level" in
        PASS) color=$'\e[32m' ;;
        WARN) color=$'\e[33m' ;;
        FAIL) color=$'\e[31m' ;;
        INFO) color=$'\e[36m' ;;
        *)    color="" ;;
      esac
      printf '  %s%-6s\e[0m  %-20s  %s\n' "$color" "$level" "$name" "$msg"
    else
      printf '  %-6s  %-20s  %s\n' "$level" "$name" "$msg"
    fi
  done <"$results"
  echo
  local pass warn fail
  pass=$(grep -c '^PASS|' "$results" || true)
  warn=$(grep -c '^WARN|' "$results" || true)
  fail=$(grep -c '^FAIL|' "$results" || true)
  log_info "summary for ${host}: ${pass} pass, ${warn} warn, ${fail} fail"
}
