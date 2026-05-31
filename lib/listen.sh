# shellcheck shell=bash
# lib/listen.sh — helpers for bin/elk-listen.
#
# Public functions:
#   listen::find_ls_host                  # echo first host with logstash role
#   listen::capture HOST VENDOR PORT SECS # writes to local SAMPLES_DIR
#   listen::syntax_check HOST CONF        # logstash -t on target
#   listen::deploy_pipeline HOST VENDOR CONF EXTERNAL_PORT INTERNAL_PORT
#       # copies conf to /etc/logstash/conf.d/, adds a temp rsyslog
#       # forwarder from EXTERNAL_PORT to INTERNAL_PORT, restarts both

if [[ -n "${_ELK_LISTEN_LOADED:-}" ]]; then return 0; fi
_ELK_LISTEN_LOADED=1

# shellcheck source=./common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
# shellcheck source=./ssh.sh
source "$(dirname "${BASH_SOURCE[0]}")/ssh.sh"
# shellcheck source=./inventory.sh
source "$(dirname "${BASH_SOURCE[0]}")/inventory.sh"
# shellcheck source=./rsyslog.sh
source "$(dirname "${BASH_SOURCE[0]}")/rsyslog.sh"

ELK_SAMPLES_DIR="${ELK_SAMPLES_DIR:-${ELK_REPO_ROOT}/samples}"
ELK_PIPELINES_DEV_DIR="${ELK_PIPELINES_DEV_DIR:-${ELK_REPO_ROOT}/pipelines}"

# Token reference (mirrors lib/ls.sh). Kept here so listen:: doesn't need to
# pull in lib/ls.sh (which sources lib/apt.sh — target-side concerns).
#   __VENDOR__            — vendor name as given
#   __VENDOR_DATASET__    — vendor name with '-' -> '.'
#   __LS_INTERNAL_PORT__  — LS pipeline port (5044 + index in inventory::vendors)
#   __LS_ES_USER__        — Elasticsearch user (logstash_internal)
#   __LS_ES_CA_PATH__     — path to ES HTTP CA on disk

# Echo the index of VENDOR among enabled vendors (0-based). Echoes empty if
# the vendor isn't enabled in inventory.
listen::vendor_index() {
  local target="$1" v idx=0
  while read -r v; do
    [[ "$v" == "$target" ]] && { echo "$idx"; return 0; }
    idx=$(( idx + 1 ))
  done < <(inventory::vendors)
  return 1
}

# Read templates/<vendor>/logstash/*.conf, substitute tokens, write to stdout.
# Returns 1 if the directory or any .conf is missing.
#
# Resolves the internal LS port from the inventory if the vendor is enabled;
# otherwise uses 5044 as a placeholder — fine for offline syntax checking
# but caller is responsible for picking the right port at deploy time.
listen::tokenize_vendor_conf() {
  local vendor="$1"
  local dir="${ELK_TEMPLATES_DIR}/${vendor}/logstash"
  [[ -d "$dir" ]] || return 1

  local internal_port=5044
  local idx
  if idx=$(listen::vendor_index "$vendor"); then
    internal_port=$(( 5044 + idx ))
  fi

  # Resolve ES host; fall back to 127.0.0.1 for offline syntax checking
  # (preflight / syntax-check runs where no real ES exists yet).
  local es_host="127.0.0.1"
  if es_host=$(inventory::es_host_address 2>/dev/null); then
    : # got it from inventory
  fi

  local f had=0
  for f in "$dir"/*.conf; do
    [[ -e "$f" ]] || continue
    had=1
    sed \
      -e "s|__VENDOR__|${vendor}|g" \
      -e "s|__VENDOR_DATASET__|${vendor//-/.}|g" \
      -e "s|__LS_INTERNAL_PORT__|${internal_port}|g" \
      -e "s|__LS_ES_USER__|logstash_internal|g" \
      -e "s|__LS_ES_CA_PATH__|/etc/logstash/certs/elasticsearch-http-ca.crt|g" \
      -e "s|__ES_HOST__|${es_host}|g" \
      -e "s|__PATTERNS_DIR__|/etc/logstash/patterns|g" \
      "$f"
    echo
  done
  return $(( had == 1 ? 0 : 1 ))
}

listen::find_ls_host() {
  local host
  while read -r host; do
    if inventory::roles_for "$host" | grep -qx logstash; then
      echo "$host"; return 0
    fi
  done < <(inventory::hosts)
  return 1
}

# Drop a temporary rsyslog config on HOST that listens on PORT and writes
# raw events to /tmp/elk-listen-<vendor>.log. NO forwarding to Logstash —
# this is a dev capture, isolated from the running pipeline.
listen::capture() {
  local host="$1" vendor="$2" port="$3" seconds="${4:-60}"
  # NOT /tmp — rsyslog runs with systemd PrivateTmp=yes so /tmp inside
  # the service is a different namespace from the host. /var/log is
  # writable by rsyslog and visible to us.
  local sample_dir="/var/log/elk-listen"
  local sample_file="${sample_dir}/${vendor}.log"
  local dropin="/etc/rsyslog.d/95-elk-listen-${vendor}.conf"
  local ruleset; ruleset="capture_${vendor//[^A-Za-z0-9_]/_}"

  install -d -m 0755 "$ELK_SAMPLES_DIR"

  # Make sure imudp/imtcp are loaded by the modules file (they may not be
  # if no vendor is enabled yet).
  rsyslog::ensure_modules "$host"

  log_info "listen: setting up capture on ${host} udp/tcp ${port} -> ${sample_file}"
  ssh::exec "$host" "sudo bash -s" <<REMOTE
set -euo pipefail
install -d -m 0755 '${sample_dir}'
cat > '${dropin}' <<'CONF'
# elk-listen temporary capture for ${vendor}. Removed after timeout.
# Module loads live in 00-elk-modules.conf.
#
# We use a custom template that writes the message exactly as received
# on the wire (including the original PRI / RFC3164 or 5424 framing) so
# downstream analyze/test see what a real device sends, not rsyslog's
# rewritten internal format.
template(name="elk_listen_raw_${vendor//-/_}" type="string"
         string="%rawmsg%\n")

input(type="imudp" port="${port}" ruleset="${ruleset}")
input(type="imtcp" port="${port}" ruleset="${ruleset}")
ruleset(name="${ruleset}") {
  action(type="omfile"
         fileCreateMode="0644"
         template="elk_listen_raw_${vendor//-/_}"
         file="${sample_file}")
  stop
}
CONF
chmod 0644 '${dropin}'
: > '${sample_file}'
chmod 0644 '${sample_file}'
systemctl restart rsyslog
echo "capture: listening on udp/tcp ${port}"
REMOTE

  log_info "listen: capturing for ${seconds}s — point your device at \$LS_HOST:${port}"
  # Live progress: tail size every 5s while we wait.
  local elapsed=0
  while (( elapsed < seconds )); do
    sleep 5
    elapsed=$(( elapsed + 5 ))
    # Use sudo cat to avoid permission noise (file mode 0644 owner root).
    local size lines
    size=$(ssh::exec "$host" "sudo stat -c '%s' '${sample_file}' 2>/dev/null" || echo 0)
    lines=$(ssh::exec "$host" "sudo grep -c '' '${sample_file}' 2>/dev/null" || echo 0)
    log_info "  [${elapsed}s] ${lines} lines / ${size} bytes captured"
  done

  log_info "listen: removing capture drop-in"
  ssh::exec "$host" "sudo bash -s" <<REMOTE
set -euo pipefail
rm -f '${dropin}'
systemctl restart rsyslog
echo "capture: drop-in removed"
REMOTE

  # Copy sample back. We do it via cat-over-ssh to avoid touching scp
  # which would need its own auth config.
  local out_file ts
  ts=$(date -u +%Y%m%dT%H%M%SZ)
  out_file="${ELK_SAMPLES_DIR}/${vendor}-${ts}.log"
  ssh::exec "$host" "sudo cat ${sample_file}" > "$out_file"
  local lines
  lines=$(wc -l < "$out_file")
  log_info "listen: ${lines} line(s) saved to ${out_file}"

  # Best-effort remote cleanup.
  ssh::exec "$host" "sudo rm -f ${sample_file}" >/dev/null 2>&1 || true

  echo "$out_file"
}

# Validate a candidate pipeline conf using `logstash -t`. We scp the conf
# into a tempdir on the target, then run logstash with --path.config that
# tempdir so it only validates our conf (not the whole installed set).
listen::syntax_check() {
  local host="$1" conf="$2"
  [[ -s "$conf" ]] || die "listen::syntax_check: empty/missing conf: $conf"

  log_info "listen: syntax check via logstash -t on ${host}"
  local body
  body=$(cat "$conf")

  ssh::exec "$host" "sudo bash -s" <<REMOTE
set -euo pipefail
tmp=\$(mktemp -d)
cat > "\$tmp/pipeline.conf" <<'CONF'
${body}
CONF
chown -R logstash:logstash "\$tmp"
# Run as the logstash user; --path.config => only our conf is validated.
# --log.level=warn keeps stdout brief.
if sudo -u logstash /usr/share/logstash/bin/logstash \\
     --path.settings /etc/logstash \\
     --path.config "\$tmp" \\
     --config.test_and_exit \\
     --log.level=warn \\
     2>&1
then
  echo "syntax-check: ok"
else
  echo "syntax-check: FAILED"
  rm -rf "\$tmp"
  exit 1
fi
rm -rf "\$tmp"
REMOTE
}

# Deploy a tested pipeline to /etc/logstash/conf.d/<vendor>.conf, register
# it in pipelines.yml, AND drop a temporary rsyslog forwarder from the
# external port to LS's pipeline port. Both reloaded.
#
# This is the dev-loop "promote" — not a full template install. Once the
# config is finalized, `elk-template export` + `elk-install apply` make
# it permanent.
listen::deploy_pipeline() {
  local host="$1" vendor="$2" conf="$3"
  local external="$4" internal="$5"
  [[ -s "$conf" ]] || die "listen::deploy_pipeline: empty/missing conf: $conf"

  log_info "listen: deploying ${vendor} pipeline (LS listens on ${internal}; rsyslog tap ${external} -> ${internal})"

  local body
  body=$(cat "$conf")

  ssh::exec "$host" "sudo bash -s" <<REMOTE
set -euo pipefail
ls_conf="/etc/logstash/conf.d/${vendor}.conf"
rs_dropin="/etc/rsyslog.d/96-elk-listen-promote-${vendor}.conf"
pipelines_yml="/etc/logstash/pipelines.yml"
vendor="${vendor}"

cat > "\$ls_conf" <<'CONF'
${body}
CONF
chown root:logstash "\$ls_conf"
chmod 0640 "\$ls_conf"

# Add pipeline entry to pipelines.yml if not present (idempotent).
if ! grep -q "^- pipeline.id: \${vendor}\$" "\$pipelines_yml"; then
cat >> "\$pipelines_yml" <<EOF

- pipeline.id: \${vendor}
  path.config: "/etc/logstash/conf.d/\${vendor}.conf"
  pipeline.workers: 1
EOF
fi

# Temp rsyslog forwarder: external port -> local TCP to LS internal port.
ruleset="promote_\${vendor//[^A-Za-z0-9_]/_}"
cat > "\$rs_dropin" <<EOF
module(load="imudp")
module(load="imtcp")
input(type="imudp" port="${external}" ruleset="\$ruleset")
input(type="imtcp" port="${external}" ruleset="\$ruleset")
ruleset(name="\$ruleset") {
  action(type="omfile" file="/var/log/elk-ingest/\${vendor}/raw.log"
         dirCreateMode="0755" fileCreateMode="0640")
  action(type="omfwd" target="127.0.0.1" port="${internal}" protocol="tcp"
         action.resumeRetryCount="-1"
         queue.type="LinkedList" queue.size="10000")
  stop
}
EOF
chmod 0644 "\$rs_dropin"
install -d -m 0755 "/var/log/elk-ingest/\${vendor}"

systemctl restart logstash.service
systemctl reload rsyslog 2>/dev/null || systemctl restart rsyslog

echo "promote: \${vendor} deployed"
REMOTE
}
