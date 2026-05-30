# shellcheck shell=bash
# lib/rsyslog.sh — rsyslog front door.
#
# Per-vendor design:
#   - rsyslog listens on the vendor's external UDP + TCP ports (from inventory)
#   - writes raw events to /var/log/elk-ingest/<vendor>/raw.log (for replay)
#   - forwards over local TCP to the matching LS pipeline port
#     (LS pipelines bind LS_PIPELINE_PORT_BASE + N — see lib/ls.sh)
#
# Public functions:
#   rsyslog::install HOST
#   rsyslog::configure HOST              # one drop-in per enabled vendor
#   rsyslog::reload HOST
#   rsyslog::teardown HOST [PURGE]

if [[ -n "${_ELK_RSYSLOG_LOADED:-}" ]]; then return 0; fi
_ELK_RSYSLOG_LOADED=1

# shellcheck source=./common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
# shellcheck source=./ssh.sh
source "$(dirname "${BASH_SOURCE[0]}")/ssh.sh"
# shellcheck source=./inventory.sh
source "$(dirname "${BASH_SOURCE[0]}")/inventory.sh"
# shellcheck source=./ls.sh
source "$(dirname "${BASH_SOURCE[0]}")/ls.sh"   # for LS_PIPELINE_PORT_BASE

RSYSLOG_DROPIN_PREFIX="10-elk"
RSYSLOG_MODULES_CONF="/etc/rsyslog.d/00-elk-modules.conf"

# rsyslog refuses to load the same module twice. So we centralize all
# module loads in a single "00-" prefixed file (loaded before any vendor
# drop-in), and every vendor config does inputs + rulesets only.
rsyslog::ensure_modules() {
  local host="$1"
  ssh::exec "$host" "sudo bash -s" <<REMOTE
set -euo pipefail
mods='${RSYSLOG_MODULES_CONF}'
desired='# elk-installer managed — single source of truth for rsyslog modules.
# Per-vendor drop-ins (10-elk-*.conf, 95-elk-listen-*.conf, etc.) must NOT
# re-load these — rsyslog 8.x rejects a config with the same module loaded
# twice. Add new modules here and reload rsyslog.
module(load="imudp")
module(load="imtcp")
'
if [ ! -f "\$mods" ] || ! diff -q <(printf '%s' "\$desired") "\$mods" >/dev/null 2>&1; then
  printf '%s' "\$desired" > "\$mods"
  chmod 0644 "\$mods"
  echo "modules: written"
else
  echo "modules: already up to date"
fi
REMOTE
}

rsyslog::install() {
  local host="$1"
  log_info "rsyslog: ensuring rsyslog package on ${host}"
  ssh::exec "$host" "sudo bash -s" <<'REMOTE'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
if ! dpkg-query -s rsyslog >/dev/null 2>&1; then
  apt-get update -qq
  apt-get install -y -qq rsyslog
fi
echo "rsyslog: $(dpkg-query -W -f='${Version}' rsyslog)"
REMOTE
}

# Write one /etc/rsyslog.d/10-elk-<vendor>.conf per enabled vendor.
# Removes any of OUR previous drop-ins that no longer correspond to an
# enabled vendor (in case a vendor was disabled in inventory).
rsyslog::configure() {
  local host="$1"
  log_info "rsyslog: writing per-vendor drop-ins on ${host}"
  rsyslog::ensure_modules "$host"

  local idx=0
  local vendor configs=""    # build a packed list for the remote awk demuxer
  local enabled_names=""
  while read -r vendor; do
    [[ -z "$vendor" ]] && continue
    enabled_names+="${vendor} "
    local udp tcp internal
    udp=$(inventory::vendor_field "$vendor" udp_port)
    tcp=$(inventory::vendor_field "$vendor" tcp_port)
    internal=$(( LS_PIPELINE_PORT_BASE + idx ))
    [[ -n "$udp" && -n "$tcp" ]] \
      || die "rsyslog: vendor ${vendor} missing udp_port/tcp_port in inventory"

    configs+="===${RSYSLOG_DROPIN_PREFIX}-${vendor}.conf==="$'\n'
    configs+=$(cat <<EOF
# elk-installer managed — vendor: ${vendor}
# External (devices send here): udp/${udp}, tcp/${tcp}
# Internal (forward to Logstash): tcp/${internal}
# File copy: /var/log/elk-ingest/${vendor}/raw.log
#
# Module loads (imudp/imtcp) live in 00-elk-modules.conf — not here.

input(type="imudp" port="${udp}" ruleset="elk_${vendor//-/_}")
input(type="imtcp" port="${tcp}" ruleset="elk_${vendor//-/_}")

ruleset(name="elk_${vendor//-/_}") {
  action(type="omfile"
         dirCreateMode="0755"
         fileCreateMode="0640"
         file="/var/log/elk-ingest/${vendor}/raw.log")
  action(type="omfwd"
         target="127.0.0.1" port="${internal}" protocol="tcp"
         action.resumeRetryCount="-1"
         queue.type="LinkedList" queue.size="10000")
  stop
}
EOF
)
    configs+=$'\n'
    idx=$(( idx + 1 ))
  done < <(inventory::vendors)

  ssh::exec "$host" "sudo bash -s" <<REMOTE
set -euo pipefail
PREFIX="${RSYSLOG_DROPIN_PREFIX}"
ENABLED="${enabled_names}"

# 1) Reap our previous drop-ins that no longer match an enabled vendor.
for f in /etc/rsyslog.d/\${PREFIX}-*.conf; do
  [ -e "\$f" ] || continue
  base=\$(basename "\$f" .conf)               # 10-elk-generic-syslog
  vendor=\${base#\${PREFIX}-}                 # generic-syslog
  case " \$ENABLED " in
    *" \$vendor "*) ;;
    *) rm -f -- "\$f"; echo "reaped \$f" ;;
  esac
done

# 2) Drop fresh confs into /etc/rsyslog.d/.
awk '
  /^===/ {
    name = \$0; gsub(/^===|===\$/, "", name)
    out = "/etc/rsyslog.d/" name
    print "writing " out > "/dev/stderr"
    next
  }
  { print > out }
' <<'CONFS'
${configs}CONFS

# 3) Create per-vendor file destination dirs. rsyslog will create the
#    file but the dir must exist. On Debian 13 rsyslogd runs as root, so
#    root:root + 0755 is sufficient.
for v in \$ENABLED; do
  install -d -m 0755 "/var/log/elk-ingest/\$v"
done

echo "rsyslog: configured"
REMOTE
}

rsyslog::reload() {
  local host="$1"
  log_info "rsyslog: reloading on ${host}"
  ssh::exec "$host" "sudo bash -s" <<'REMOTE'
set -euo pipefail
systemctl enable rsyslog.service >/dev/null
# Use restart over reload: restart fully re-binds listeners, which is what
# we want after port changes. Cheaper than tracking diff.
systemctl restart rsyslog.service
echo "rsyslog: $(systemctl is-active rsyslog.service)"
REMOTE
}

rsyslog::teardown() {
  local host="$1" purge="${2:-0}"
  log_warn "rsyslog: tearing down our drop-ins on ${host} (purge=${purge})"

  ssh::exec "$host" "PREFIX='${RSYSLOG_DROPIN_PREFIX}' bash -s" <<'REMOTE'
set -euo pipefail
PREFIX="${PREFIX}"
rm -f /etc/rsyslog.d/${PREFIX}-*.conf
if systemctl is-active rsyslog.service >/dev/null 2>&1; then
  systemctl restart rsyslog.service
fi
echo "rsyslog drop-ins removed"
REMOTE

  if (( purge == 1 )); then
    log_warn "rsyslog: --purge — wiping /var/log/elk-ingest on ${host}"
    ssh::exec "$host" "sudo bash -s" <<'REMOTE'
set -euo pipefail
if [ -d /var/log/elk-ingest ]; then
  rm -rf -- /var/log/elk-ingest
  echo "removed /var/log/elk-ingest"
fi
REMOTE
  fi
}
