# shellcheck shell=bash
# lib/kibana.sh — Kibana install + configure.
#
# Lab scope: Kibana bound to 127.0.0.1, fronted by nginx (lib/nginx.sh)
# with a self-signed cert. Authenticates to ES as kibana_system over
# https://127.0.0.1:9200 with the ES auto-config CA.
#
# Public functions:
#   kibana::install HOST
#   kibana::reset_kibana_system_password HOST_WITH_ES
#   kibana::distribute_es_ca HOST [SRC_HOST]
#   kibana::ensure_encryption_keys HOST
#   kibana::configure HOST [PUBLIC_BASE_URL]
#   kibana::configure_keystore HOST
#   kibana::start HOST
#   kibana::wait_for_api HOST
#   kibana::teardown HOST [PURGE]

if [[ -n "${_ELK_KIBANA_LOADED:-}" ]]; then return 0; fi
_ELK_KIBANA_LOADED=1

# shellcheck source=./common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
# shellcheck source=./ssh.sh
source "$(dirname "${BASH_SOURCE[0]}")/ssh.sh"
# shellcheck source=./inventory.sh
source "$(dirname "${BASH_SOURCE[0]}")/inventory.sh"
# shellcheck source=./apt.sh
source "$(dirname "${BASH_SOURCE[0]}")/apt.sh"

KBN_MANAGED_BEGIN="# >>> elk-installer managed >>>"
KBN_MANAGED_END="# <<< elk-installer managed <<<"

kibana::install() {
  local host="$1"
  local sv
  sv=$(inventory::stack_version)
  [[ -n "$sv" && "$sv" != "TBD" ]] || die "kibana::install: stack_version unset"

  apt::ensure_prereqs "$host"
  apt::ensure_elastic_repo "$host" "9.x"
  apt::install_held "$host" "kibana" "$sv"
}

# Reset the kibana_system built-in user's password via ES on the ES host.
# Idempotent against secrets/.
kibana::reset_kibana_system_password() {
  local host="$1"   # host with ES installed
  local secret_file="${ELK_REPO_ROOT}/secrets/${host}.kibana_system.password"

  if [[ -s "$secret_file" ]]; then
    log_info "kibana: kibana_system password already captured for ${host} (skipping reset)"
    return 0
  fi

  log_info "kibana: resetting kibana_system user password via ES on ${host}"
  local output
  output=$(ssh::exec "$host" "sudo /usr/share/elasticsearch/bin/elasticsearch-reset-password -u kibana_system --batch --auto" 2>&1) \
    || die "kibana: reset-password failed:\n$output"

  local pw
  pw=$(echo "$output" | awk -F': ' '/^New value:/ {print $2; exit}')
  [[ -n "$pw" ]] || die "kibana: could not parse new password from output:\n$output"

  install -d -m 0700 "${ELK_REPO_ROOT}/secrets"
  umask 0177
  printf '%s\n' "$pw" > "$secret_file"
  chmod 0600 "$secret_file"
  log_warn "kibana: kibana_system password saved PLAINTEXT to ${secret_file}"
}

# Copy ES HTTP CA to /etc/kibana/certs/ so kibana can verify ES.
kibana::distribute_es_ca() {
  local host="$1"
  local src_host="${2:-$host}"
  log_info "kibana: distributing ES HTTP CA to ${host} (from ${src_host})"

  local pem
  pem=$(ssh::exec "$src_host" "sudo cat /etc/elasticsearch/certs/http_ca.crt") \
    || die "kibana: could not read ES HTTP CA on ${src_host}"

  ssh::exec "$host" "sudo bash -s" <<REMOTE
set -euo pipefail
install -d -m 0750 -o root -g kibana /etc/kibana/certs
cat > /etc/kibana/certs/elasticsearch-http-ca.crt <<'PEM'
${pem}
PEM
chown root:kibana /etc/kibana/certs/elasticsearch-http-ca.crt
chmod 0640 /etc/kibana/certs/elasticsearch-http-ca.crt
echo "ca: ok"
REMOTE
}

# Generate three 32-char encryption keys ONCE and persist locally. These
# MUST be stable across restarts and re-runs — regenerating them
# invalidates every encrypted saved object.
kibana::ensure_encryption_keys() {
  local host="$1"
  local keys_file="${ELK_REPO_ROOT}/secrets/${host}.kibana.encryption.keys"

  if [[ -s "$keys_file" ]]; then
    log_info "kibana: encryption keys already present at ${keys_file}"
    return 0
  fi

  log_info "kibana: generating encryption keys for ${host}"
  install -d -m 0700 "${ELK_REPO_ROOT}/secrets"
  umask 0177
  {
    printf 'encryptedSavedObjects=%s\n' "$(openssl rand -hex 16)"
    printf 'reporting=%s\n'              "$(openssl rand -hex 16)"
    printf 'security=%s\n'               "$(openssl rand -hex 16)"
  } > "$keys_file"
  chmod 0600 "$keys_file"
  log_warn "kibana: encryption keys saved PLAINTEXT to ${keys_file} — NEVER regenerate"
}

# kibana.yml managed block. server.host=127.0.0.1 (nginx fronts us); the
# elasticsearch.password lives in the kibana keystore (not here).
kibana::configure() {
  local host="$1"
  local public_base_url="${2:-}"
  local keys_file="${ELK_REPO_ROOT}/secrets/${host}.kibana.encryption.keys"
  [[ -s "$keys_file" ]] || die "kibana::configure: encryption keys not present"

  local k_eso k_report k_sec
  k_eso=$(awk -F= '/^encryptedSavedObjects=/{print $2; exit}' "$keys_file")
  k_report=$(awk -F= '/^reporting=/{print $2; exit}' "$keys_file")
  k_sec=$(awk -F= '/^security=/{print $2; exit}' "$keys_file")

  log_info "kibana: writing managed kibana.yml block on ${host}"
  ssh::exec "$host" "sudo bash -s" <<REMOTE
set -euo pipefail
begin="${KBN_MANAGED_BEGIN}"
end="${KBN_MANAGED_END}"
yml=/etc/kibana/kibana.yml

tmp=\$(mktemp)
awk -v b="\$begin" -v e="\$end" '\$0==b{skip=1;next} \$0==e{skip=0;next} !skip' "\$yml" > "\$tmp"
cat >> "\$tmp" <<EOF
\$begin
server.host: "127.0.0.1"
server.port: 5601
$(if [[ -n "$public_base_url" ]]; then echo "server.publicBaseUrl: \"${public_base_url}\""; fi)

elasticsearch.hosts: ["https://127.0.0.1:9200"]
elasticsearch.username: "kibana_system"
# password lives in the kibana keystore (key: elasticsearch.password)
elasticsearch.ssl.certificateAuthorities: ["/etc/kibana/certs/elasticsearch-http-ca.crt"]
elasticsearch.ssl.verificationMode: "certificate"

xpack.encryptedSavedObjects.encryptionKey: "${k_eso}"
xpack.reporting.encryptionKey: "${k_report}"
xpack.security.encryptionKey: "${k_sec}"
\$end
EOF
chown --reference="\$yml" "\$tmp"
chmod --reference="\$yml" "\$tmp"
mv "\$tmp" "\$yml"
echo "configure: ok"
REMOTE
}

# Add elasticsearch.password to the Kibana keystore.
kibana::configure_keystore() {
  local host="$1"
  local secret_file="${ELK_REPO_ROOT}/secrets/${host}.kibana_system.password"
  [[ -s "$secret_file" ]] || die "kibana::configure_keystore: no kibana_system password"
  local pw
  pw=$(cat "$secret_file")

  log_info "kibana: adding elasticsearch.password to keystore on ${host}"
  ssh::exec "$host" "KBN_PW=$(printf '%q' "$pw") bash -s" <<'REMOTE'
set -euo pipefail
keystore_bin=/usr/share/kibana/bin/kibana-keystore

# Ensure keystore exists. The create command is idempotent — it asks for
# confirmation to overwrite if the keystore exists, so we only create
# when it doesn't.
if ! sudo $keystore_bin list >/dev/null 2>&1; then
  sudo $keystore_bin create >/dev/null
fi

# Add (replacing if present). `kibana-keystore add KEY --stdin` reads
# from stdin; pass --force to skip the "already exists, overwrite?" prompt.
printf '%s' "$KBN_PW" | sudo $keystore_bin add elasticsearch.password --stdin --force >/dev/null

echo "keystore: ok"
REMOTE
}

kibana::start() {
  local host="$1"
  log_info "kibana: enabling + starting kibana.service on ${host}"
  ssh::exec "$host" "sudo bash -s" <<'REMOTE'
set -euo pipefail
systemctl daemon-reload
systemctl enable --now kibana.service >/dev/null
systemctl restart kibana.service
echo "service: $(systemctl is-active kibana.service)"
REMOTE
}

# Kibana takes a while to come up — first start does optimisation passes
# that can run a couple of minutes on small hosts.
kibana::wait_for_api() {
  local host="$1" deadline=$(( SECONDS + 300 ))
  log_info "kibana: waiting for status API on ${host} (up to 300s)"
  while (( SECONDS < deadline )); do
    local code
    code=$(ssh::exec "$host" \
      "curl -sS -o /dev/null -w '%{http_code}' http://127.0.0.1:5601/api/status 2>/dev/null" \
      || true)
    if [[ "$code" =~ ^(200|302)$ ]]; then
      log_info "kibana: API responsive (HTTP ${code})"
      return 0
    fi
    sleep 5
  done
  die "kibana::wait_for_api: timed out after 300s"
}

kibana::teardown() {
  local host="$1" purge="${2:-0}"
  log_warn "kibana: tearing down on ${host} (purge=${purge})"

  ssh::exec "$host" "sudo bash -s" <<'REMOTE'
set -euo pipefail
if systemctl list-unit-files kibana.service >/dev/null 2>&1; then
  systemctl disable --now kibana.service 2>/dev/null || true
  echo "service: stopped + disabled"
else
  echo "service: not present"
fi
REMOTE

  apt::purge_held "$host" "kibana"

  if (( purge == 1 )); then
    log_warn "kibana: --purge — wiping /etc/kibana + /var/lib/kibana + /var/log/kibana on ${host}"
    ssh::exec "$host" "sudo bash -s" <<'REMOTE'
set -euo pipefail
for d in /etc/kibana /var/lib/kibana /var/log/kibana; do
  if [ -d "$d" ]; then
    rm -rf -- "$d"
    echo "removed $d"
  fi
done
REMOTE
    for f in "${ELK_REPO_ROOT}/secrets/${host}.kibana_system.password" \
             "${ELK_REPO_ROOT}/secrets/${host}.kibana.encryption.keys"; do
      [[ -e "$f" ]] && rm -f -- "$f" && log_info "kibana: removed local secret $f"
    done
  fi

  log_info "kibana: teardown complete on ${host}"
}
