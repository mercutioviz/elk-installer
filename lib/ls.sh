# shellcheck shell=bash
# lib/ls.sh — Logstash install + pipeline management.
#
# Lab scope: a single LS instance on the same host as ES, talking to ES over
# https://127.0.0.1:9200 using the ES auto-config CA and a dedicated
# `logstash_internal` user we create with the `logstash_writer` role.
#
# Public functions:
#   ls::install HOST
#   ls::distribute_es_ca HOST           # copy /etc/elasticsearch/certs/http_ca.crt
#   ls::ensure_es_role_and_user HOST    # creates logstash_writer + logstash_internal
#   ls::configure_heap HOST [HEAP]
#   ls::configure_keystore HOST         # adds LS_ES_PASSWORD
#   ls::configure_pipelines HOST        # pipelines.yml + per-vendor conf
#   ls::start HOST
#   ls::wait_for_api HOST
#   ls::teardown HOST [PURGE]

if [[ -n "${_ELK_LS_LOADED:-}" ]]; then return 0; fi
_ELK_LS_LOADED=1

# shellcheck source=./common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
# shellcheck source=./ssh.sh
source "$(dirname "${BASH_SOURCE[0]}")/ssh.sh"
# shellcheck source=./inventory.sh
source "$(dirname "${BASH_SOURCE[0]}")/inventory.sh"
# shellcheck source=./apt.sh
source "$(dirname "${BASH_SOURCE[0]}")/apt.sh"

LS_DEFAULT_HEAP="512m"
LS_ES_USER="logstash_internal"
LS_PIPELINE_PORT_BASE=5044   # generic-syslog: 5044, next vendor: 5045, ...

# Target-side directory for per-vendor grok patterns.
LS_PATTERNS_DIR="/etc/logstash/patterns"

# (No managed-block markers needed — we own pipelines.yml entirely now.)

ls::install() {
  local host="$1"
  local sv
  sv=$(inventory::stack_version)
  [[ -n "$sv" && "$sv" != "TBD" ]] || die "ls::install: inventory.stack_version is unset"

  apt::ensure_prereqs "$host"
  apt::ensure_elastic_repo "$host" "9.x"
  apt::install_held "$host" "logstash" "$sv"
}

# Copy the ES auto-config HTTP CA to a path LS can read. We pull via cat
# over ssh from the elasticsearch group's file, then push it down. Both
# steps run on the same host in the lab, but coding it general-purpose so
# multi-host later just needs to vary `source_host`.
ls::distribute_es_ca() {
  local host="$1"
  local src_host="${2:-$host}"   # for multi-host, where ES lives
  log_info "ls: distributing ES HTTP CA to ${host} (from ${src_host})"

  local pem
  pem=$(ssh::exec "$src_host" "sudo cat /etc/elasticsearch/certs/http_ca.crt") \
    || die "ls: could not read ES HTTP CA on ${src_host}"

  ssh::exec "$host" "sudo bash -s" <<REMOTE
set -euo pipefail
install -d -m 0750 -o root -g logstash /etc/logstash/certs
cat > /etc/logstash/certs/elasticsearch-http-ca.crt <<'PEM'
${pem}
PEM
chown root:logstash /etc/logstash/certs/elasticsearch-http-ca.crt
chmod 0640 /etc/logstash/certs/elasticsearch-http-ca.crt
echo "ca: ok"
REMOTE
}

# Create the logstash_writer role + logstash_internal user via the ES API.
# Idempotent: PUT is replace-or-create. Password is generated once and
# stored locally; re-runs PUT the same password back, so LS keystore stays
# in sync.
ls::ensure_es_role_and_user() {
  local host="$1"
  # Elastic password is saved under the ES host name, not the LS host name.
  # Resolve the ES host name first so we look in the right place.
  local es_addr
  es_addr=$(inventory::es_host_address)     || die "ls::ensure_es_role_and_user: cannot resolve ES host address"
  local es_host_early
  while IFS= read -r -u 5 h; do
    if [[ "$(inventory::host_field "$h" address)" == "$es_addr" ]]; then
      es_host_early="$h"; break
    fi
  done 5< <(inventory::hosts)
  [[ -n "$es_host_early" ]]     || die "ls::ensure_es_role_and_user: no inventory host matches ES address ${es_addr}"

  local es_pw_file="${ELK_REPO_ROOT}/secrets/${es_host_early}.elastic.password"
  local ls_pw_file="${ELK_REPO_ROOT}/secrets/${host}.${LS_ES_USER}.password"
  [[ -s "$es_pw_file" ]] || die "ls: no elastic password at ${es_pw_file}"

  local es_pw ls_pw
  es_pw=$(cat "$es_pw_file")

  if [[ -s "$ls_pw_file" ]]; then
    ls_pw=$(cat "$ls_pw_file")
    log_info "ls: reusing existing ${LS_ES_USER} password from ${ls_pw_file}"
  else
    # 24 hex chars = 96 bits. Avoiding `tr | head` because head closing
    # early SIGPIPEs tr, and with pipefail the whole script dies silently.
    ls_pw=$(openssl rand -hex 12)
    install -d -m 0700 "${ELK_REPO_ROOT}/secrets"
    umask 0177
    printf '%s\n' "$ls_pw" > "$ls_pw_file"
    chmod 0600 "$ls_pw_file"
    log_warn "ls: generated ${LS_ES_USER} password saved PLAINTEXT to ${ls_pw_file}"
  fi

  # Reuse es_host_early / es_addr resolved above for the curl target.
  log_info "ls: ensuring logstash_writer role + ${LS_ES_USER} user via ES API on ${es_host_early}"

  ssh::exec "$es_host_early" "ES_PW=$(printf '%q' "$es_pw") LS_PW=$(printf '%q' "$ls_pw") bash -s" <<'REMOTE'
set -euo pipefail
api="https://127.0.0.1:9200"
curl_args=( -sSk -u "elastic:${ES_PW}" -H 'Content-Type: application/json' )

# Role.
role_body='{
  "cluster": ["manage_index_templates", "monitor", "manage_ilm"],
  "indices": [{
    "names": ["logs-*", "logstash-*", ".ds-logs-*", "metrics-*"],
    "privileges": ["write", "create", "create_index", "manage", "manage_ilm", "view_index_metadata"]
  }]
}'
code=$(curl "${curl_args[@]}" -o /tmp/role_resp.json -w '%{http_code}' \
        -X PUT "$api/_security/role/logstash_writer" -d "$role_body")
case "$code" in
  200|201) echo "role logstash_writer: ok ($code)" ;;
  *) echo "role create failed ($code):"; cat /tmp/role_resp.json; exit 1 ;;
esac
rm -f /tmp/role_resp.json

# User.
user_body=$(printf '{"password": "%s", "roles": ["logstash_writer"], "full_name": "Logstash internal writer (elk-installer)"}' "$LS_PW")
code=$(curl "${curl_args[@]}" -o /tmp/user_resp.json -w '%{http_code}' \
        -X PUT "$api/_security/user/logstash_internal" -d "$user_body")
case "$code" in
  200|201) echo "user logstash_internal: ok ($code)" ;;
  *) echo "user create failed ($code):"; cat /tmp/user_resp.json; exit 1 ;;
esac
rm -f /tmp/user_resp.json
REMOTE
}


# Deploy any grok pattern files from templates/<vendor>/logstash/patterns/
# to LS_PATTERNS_DIR on the target. Idempotent: files are overwritten.
_ls::deploy_patterns() {
  local host="$1" vendor="$2"
  local src_dir="${ELK_TEMPLATES_DIR}/${vendor}/logstash/patterns"
  [[ -d "$src_dir" ]] || return 0
  local f
  for f in "$src_dir"/*; do
    [[ -e "$f" ]] || continue
    local content basename
    basename=$(basename "$f")
    content=$(cat "$f")
    log_info "ls: deploying pattern file ${basename} for ${vendor}"
    ssh::exec "$host" "sudo bash -s" <<REMOTE
set -euo pipefail
install -d -m 0755 "${LS_PATTERNS_DIR}"
cat > "${LS_PATTERNS_DIR}/${basename}" <<'PAT'
${content}
PAT
chmod 0644 "${LS_PATTERNS_DIR}/${basename}"
echo "pattern ${basename}: ok"
REMOTE
  done
}

ls::configure_heap() {
  local host="$1" heap="${2:-$LS_DEFAULT_HEAP}"
  log_info "ls: writing heap drop-in (${heap}) on ${host}"
  ssh::exec "$host" "sudo bash -s" <<REMOTE
set -euo pipefail
heap="${heap}"
install -d -m 0750 -o root -g logstash /etc/logstash/jvm.options.d
heap_file=/etc/logstash/jvm.options.d/elk-heap.options
new_heap=\$(printf -- '-Xms%s\n-Xmx%s\n' "\$heap" "\$heap")
if [ ! -f "\$heap_file" ] || ! diff -q <(printf '%s' "\$new_heap") "\$heap_file" >/dev/null 2>&1; then
  printf '%s' "\$new_heap" > "\$heap_file"
  chown root:logstash "\$heap_file"
  chmod 0640 "\$heap_file"
fi
echo "heap: ok"
REMOTE
}

# Add LS_ES_PASSWORD to the LS keystore so pipeline configs can reference
# ${LS_ES_PASSWORD} without exposing it on disk in plaintext.
ls::configure_keystore() {
  local host="$1"
  local ls_pw_file="${ELK_REPO_ROOT}/secrets/${host}.${LS_ES_USER}.password"
  [[ -s "$ls_pw_file" ]] || die "ls::configure_keystore: no LS password at $ls_pw_file"

  log_info "ls: adding LS_ES_PASSWORD to keystore on ${host}"
  local ls_pw
  ls_pw=$(cat "$ls_pw_file")

  # logstash-keystore needs HOME writable for its bootstrap; the
  # `logstash` system user has /usr/share/logstash. SYSTEMD_RESOLVED etc.
  # aren't relevant here. We invoke as root and pass --path.settings to
  # point at the system config dir.
  ssh::exec "$host" "LS_PW=$(printf '%q' "$ls_pw") bash -s" <<'REMOTE'
set -euo pipefail
keystore_bin=/usr/share/logstash/bin/logstash-keystore
settings=/etc/logstash

# Create the keystore if it doesn't exist (first run). It prompts:
#   "Continue without password protection on the keystore? [y/N]"
# We answer y for now; switching to LOGSTASH_KEYSTORE_PASS-based
# encryption is a v2 item (needs the env var also wired into the systemd
# unit). The keystore itself is still mode 0600 owned by root.
if [ ! -f "$settings/logstash.keystore" ]; then
  echo y | sudo -E $keystore_bin --path.settings $settings create >/dev/null
fi

# Remove any existing key (idempotent overwrite), then add fresh.
sudo -E $keystore_bin --path.settings $settings remove LS_ES_PASSWORD >/dev/null 2>&1 || true
printf '%s' "$LS_PW" | sudo -E $keystore_bin --path.settings $settings add LS_ES_PASSWORD --stdin >/dev/null

echo "keystore: ok"
REMOTE
}

# Token-substitute a template logstash conf and return the contents.
# Token reference is documented at the top of every template conf.
_ls::tokenize_template() {
  local file="$1" vendor="$2" internal_port="$3"
  local dataset="${vendor//-/.}"
  local es_host
  es_host=$(inventory::es_host_address) \
    || die "_ls::tokenize_template: cannot resolve ES host (no es-master in inventory)"
  # NOTE: we use | as the sed delimiter to avoid clashes with paths.
  sed \
    -e "s|__VENDOR__|${vendor}|g" \
    -e "s|__VENDOR_DATASET__|${dataset}|g" \
    -e "s|__LS_INTERNAL_PORT__|${internal_port}|g" \
    -e "s|__LS_ES_USER__|${LS_ES_USER}|g" \
    -e "s|__LS_ES_CA_PATH__|/etc/logstash/certs/elasticsearch-http-ca.crt|g" \
    -e "s|__ES_HOST__|${es_host}|g" \
    -e "s|__PATTERNS_DIR__|${LS_PATTERNS_DIR}|g" \
    "$file"
}

# Resolve the on-disk logstash conf for a vendor.
#   templates/<vendor>/logstash/*.conf — the canonical source. We expect
#   exactly one .conf per template for now; multiple are concatenated.
# Returns 1 if no template is available.
_ls::collect_template_conf() {
  local vendor="$1" internal_port="$2"
  local dir="${ELK_TEMPLATES_DIR}/${vendor}/logstash"
  [[ -d "$dir" ]] || return 1
  local f had=0
  for f in "$dir"/*.conf; do
    [[ -e "$f" ]] || continue
    had=1
    _ls::tokenize_template "$f" "$vendor" "$internal_port"
    echo
  done
  return $(( had == 1 ? 0 : 1 ))
}

# Fallback placeholder conf for a vendor that has no template/logstash/*.conf
# in the repo. Useful so the vendor is "registered" but a hand-roll is needed.
_ls::placeholder_conf() {
  local vendor="$1" internal_port="$2"
  cat <<EOF
# Placeholder pipeline for ${vendor} — no templates/${vendor}/logstash/*.conf
# in the repo. Drop one in and re-run elk-install apply (or elk-template apply
# ${vendor}) to install a real pipeline.
input  { tcp { port => ${internal_port} type => "${vendor}" } }
filter { }
output {
  elasticsearch {
    hosts => ["https://127.0.0.1:9200"]
    user  => "${LS_ES_USER}"
    password => "\${LS_ES_PASSWORD}"
    ssl_certificate_authorities => ["/etc/logstash/certs/elasticsearch-http-ca.crt"]
    data_stream => "true"
    data_stream_type      => "logs"
    data_stream_dataset   => "${vendor//-/.}"
    data_stream_namespace => "default"
  }
}
EOF
}

# Write pipelines.yml + one per-vendor pipeline conf for each enabled
# template in the inventory. Vendor port assignment:
#   - external (rsyslog listener): the inventory's templates[].udp_port / tcp_port
#   - internal (LS receives from rsyslog): LS_PIPELINE_PORT_BASE + N where N is
#     the index among enabled vendors. So generic-syslog gets 5044, second
#     vendor 5045, etc. The mapping is also written into rsyslog's forward
#     config (see lib/rsyslog.sh).
#
# Per-vendor conf source: templates/<vendor>/logstash/*.conf (canonical).
# Vendors without a templates/<vendor>/logstash/ directory get a placeholder
# with a WARN — they'll receive events but won't parse them.
ls::configure_pipelines() {
  local host="$1"
  log_info "ls: writing pipelines.yml + per-vendor confs on ${host}"

  local idx=0
  local vendor pipelines_yml="" vendor_confs=""
  while read -r vendor; do
    [[ -z "$vendor" ]] && continue
    local internal_port=$(( LS_PIPELINE_PORT_BASE + idx ))
    pipelines_yml+="- pipeline.id: ${vendor}"$'\n'
    pipelines_yml+="  path.config: \"/etc/logstash/conf.d/${vendor}.conf\""$'\n'
    pipelines_yml+="  pipeline.workers: 1"$'\n'

    vendor_confs+="===${vendor}.conf==="$'\n'
    if _ls::collect_template_conf "$vendor" "$internal_port" \
         >> /tmp/.ls_vendor_tmp 2>/dev/null
    then
      vendor_confs+=$(cat /tmp/.ls_vendor_tmp)
      log_info "ls: using template templates/${vendor}/logstash/*.conf"
      _ls::deploy_patterns "$host" "$vendor"
    else
      log_warn "ls: no template logstash conf for ${vendor}; using placeholder"
      vendor_confs+=$(_ls::placeholder_conf "$vendor" "$internal_port")
    fi
    vendor_confs+=$'\n'
    rm -f /tmp/.ls_vendor_tmp
    idx=$(( idx + 1 ))
  done < <(inventory::vendors)

  [[ -n "$pipelines_yml" ]] || die "ls::configure_pipelines: no enabled vendors in inventory"

  ssh::exec "$host" "sudo bash -s" <<REMOTE
set -euo pipefail
yml=/etc/logstash/pipelines.yml

# We OWN pipelines.yml entirely — replacing the default \`main: conf.d/*.conf\`
# (which would otherwise compete for input ports). One pipeline per enabled
# vendor, each pointing at its own conf file.
tmp=\$(mktemp)
{
  printf '# elk-installer managed file. Hand edits will be overwritten.\n'
  printf '# To disable a vendor, set enabled: false in inventory.yml.\n\n'
  cat <<'PIPES'
${pipelines_yml}PIPES
} > "\$tmp"
chown --reference="\$yml" "\$tmp"
chmod --reference="\$yml" "\$tmp"
mv "\$tmp" "\$yml"

# Drop per-vendor confs into /etc/logstash/conf.d/.
install -d -m 0750 -o root -g logstash /etc/logstash/conf.d
awk '
  /^===/ {
    name = \$0; gsub(/^===|===$/, "", name)
    out = "/etc/logstash/conf.d/" name
    print "writing " out > "/dev/stderr"
    next
  }
  { print > out }
' <<'CONFS'
${vendor_confs}CONFS

# Permissions on conf.d/*
chown -R root:logstash /etc/logstash/conf.d
chmod 0640 /etc/logstash/conf.d/*.conf 2>/dev/null || true
echo "pipelines: ok"
REMOTE
}

ls::start() {
  local host="$1"
  log_info "ls: enabling + starting logstash.service on ${host}"
  ssh::exec "$host" "sudo bash -s" <<'REMOTE'
set -euo pipefail
systemctl daemon-reload
systemctl enable --now logstash.service >/dev/null
# Some configs need a restart to pick up keystore changes; safe to bounce.
systemctl restart logstash.service
echo "service: $(systemctl is-active logstash.service)"
REMOTE
}

# LS exposes a monitoring API on :9600 (HTTP, no auth in the lab).
ls::wait_for_api() {
  local host="$1" deadline=$(( SECONDS + 180 ))
  log_info "ls: waiting for monitoring API on ${host} (up to 180s)"
  while (( SECONDS < deadline )); do
    local code
    code=$(ssh::exec "$host" \
      "curl -sS -o /dev/null -w '%{http_code}' http://127.0.0.1:9600/ 2>/dev/null" \
      || true)
    if [[ "$code" == "200" ]]; then
      log_info "ls: API responsive (HTTP 200)"
      return 0
    fi
    sleep 3
  done
  die "ls::wait_for_api: timed out after 180s"
}

ls::teardown() {
  local host="$1" purge="${2:-0}"
  log_warn "ls: tearing down on ${host} (purge=${purge})"

  ssh::exec "$host" "sudo bash -s" <<'REMOTE'
set -euo pipefail
if systemctl list-unit-files logstash.service >/dev/null 2>&1; then
  systemctl disable --now logstash.service 2>/dev/null || true
  echo "service: stopped + disabled"
else
  echo "service: not present"
fi
REMOTE

  apt::purge_held "$host" "logstash"

  if (( purge == 1 )); then
    log_warn "ls: --purge — wiping /etc/logstash + /var/lib/logstash + /var/log/logstash on ${host}"
    ssh::exec "$host" "sudo bash -s" <<'REMOTE'
set -euo pipefail
for d in /etc/logstash /var/lib/logstash /var/log/logstash; do
  if [ -d "$d" ]; then
    rm -rf -- "$d"
    echo "removed $d"
  fi
done
REMOTE
    # Remove the user/role from ES too — but only if ES is still running.
    # If ES was already torn down, this is a no-op.
    local es_pw_file="${ELK_REPO_ROOT}/secrets/${host}.elastic.password"
    if [[ -s "$es_pw_file" ]]; then
      local es_pw
      es_pw=$(cat "$es_pw_file")
      ssh::exec "$host" "ES_PW=$(printf '%q' "$es_pw") bash -s" <<'REMOTE' || true
set -euo pipefail
api="https://127.0.0.1:9200"
curl -sSk -u "elastic:${ES_PW}" -X DELETE "$api/_security/user/logstash_internal" -o /dev/null -w 'user delete: %{http_code}\n' 2>/dev/null || true
curl -sSk -u "elastic:${ES_PW}" -X DELETE "$api/_security/role/logstash_writer" -o /dev/null -w 'role delete: %{http_code}\n' 2>/dev/null || true
REMOTE
    fi

    local ls_pw_file="${ELK_REPO_ROOT}/secrets/${host}.${LS_ES_USER}.password"
    if [[ -e "$ls_pw_file" ]]; then
      rm -f -- "$ls_pw_file"
      log_info "ls: removed local secret ${ls_pw_file}"
    fi
  fi

  log_info "ls: teardown complete on ${host}"
}
