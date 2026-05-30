# shellcheck shell=bash
# lib/es.sh — Elasticsearch install + configure + bootstrap.
#
# Scope (current milestone): single-node lab. Multi-node bootstrap
# (transport TLS using our own CA, master_elect roles, etc.) lands in a
# later milestone — this file is intentionally small.
#
# Public functions:
#   es::install HOST
#   es::configure HOST                # heap + managed elasticsearch.yml block
#   es::start HOST
#   es::wait_for_api HOST
#   es::reset_elastic_password HOST   # idempotent against secrets/
#   es::wait_for_status HOST STATUS   # yellow | green

if [[ -n "${_ELK_ES_LOADED:-}" ]]; then return 0; fi
_ELK_ES_LOADED=1

# shellcheck source=./common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
# shellcheck source=./ssh.sh
source "$(dirname "${BASH_SOURCE[0]}")/ssh.sh"
# shellcheck source=./inventory.sh
source "$(dirname "${BASH_SOURCE[0]}")/inventory.sh"
# shellcheck source=./apt.sh
source "$(dirname "${BASH_SOURCE[0]}")/apt.sh"

# Heap default — conservative for the lab (3.8 GB host that will also
# host LS + Kibana later).
ES_DEFAULT_HEAP="1g"

ES_MANAGED_BEGIN="# >>> elk-installer managed >>>"
ES_MANAGED_END="# <<< elk-installer managed <<<"

es::install() {
  local host="$1"
  local sv
  sv=$(inventory::stack_version)
  [[ -n "$sv" && "$sv" != "TBD" ]] || die "es::install: inventory.stack_version is unset"

  apt::ensure_prereqs "$host"
  apt::ensure_elastic_repo "$host" "9.x"
  apt::install_held "$host" "elasticsearch" "$sv"
}

# es::configure — write heap drop-in and the managed elasticsearch.yml
# block. Idempotent: the managed block is bracketed by marker comments
# and replaced wholesale every run.
#
# Design note: the .deb postinst's security auto-config already writes a
# complete, working single-node config (xpack.security.*, HTTP TLS,
# node.name=hostname, cluster.initial_master_nodes=[hostname], http.host).
# We deliberately keep the managed block MINIMAL to avoid colliding with
# any of that:
#   - We do NOT set discovery.type (conflicts with initial_master_nodes).
#   - We do NOT override node.name (would invalidate initial_master_nodes).
#   - We do NOT override network.host (auto-config sets http.host:0.0.0.0).
# Multi-node deployments will need a richer block; that lands when we
# implement our own CA + the multi-node bootstrap phase.
es::configure() {
  local host="$1"
  local heap="${2:-$ES_DEFAULT_HEAP}"
  local cluster_name="elk-lab"   # TODO: read from inventory once we add a cluster section

  log_info "es: writing heap drop-in (${heap}) and managed yaml block on ${host}"

  ssh::exec "$host" "sudo bash -s" <<REMOTE
set -euo pipefail
heap="${heap}"
cluster="${cluster_name}"
begin="${ES_MANAGED_BEGIN}"
end="${ES_MANAGED_END}"

# 1) Heap drop-in (ES supports jvm.options.d/ natively).
install -d -m 2750 -o root -g elasticsearch /etc/elasticsearch/jvm.options.d
heap_file=/etc/elasticsearch/jvm.options.d/elk-heap.options
new_heap=\$(printf -- '-Xms%s\n-Xmx%s\n' "\$heap" "\$heap")
if [ ! -f "\$heap_file" ] || ! diff -q <(printf '%s' "\$new_heap") "\$heap_file" >/dev/null 2>&1; then
  printf '%s' "\$new_heap" > "\$heap_file"
  chown root:elasticsearch "\$heap_file"
  chmod 0640 "\$heap_file"
fi

# 2) Minimal managed block: only cluster.name (cosmetic override of the
#    "elasticsearch" default). Strip any prior block, then append a fresh
#    one. Idempotent: re-runs converge.
ymlfile=/etc/elasticsearch/elasticsearch.yml
tmp=\$(mktemp)
awk -v b="\$begin" -v e="\$end" '
  \$0==b {skip=1; next}
  \$0==e {skip=0; next}
  !skip {print}
' "\$ymlfile" > "\$tmp"

cat >> "\$tmp" <<EOF
\$begin
cluster.name: \$cluster
\$end
EOF

chown --reference="\$ymlfile" "\$tmp"
chmod --reference="\$ymlfile" "\$tmp"
mv "\$tmp" "\$ymlfile"
echo "configure: ok"
REMOTE
}

es::start() {
  local host="$1"
  log_info "es: enabling + starting elasticsearch.service on ${host}"
  ssh::exec "$host" "sudo bash -s" <<'REMOTE'
set -euo pipefail
systemctl daemon-reload
systemctl enable --now elasticsearch.service >/dev/null
echo "service: $(systemctl is-active elasticsearch.service)"
REMOTE
}

# Poll the HTTPS API until ES responds. We don't have the password yet at
# this point; a 401 "missing authentication credentials" is proof the API
# is up. Cert is self-signed (auto-config) so -k. Note: we deliberately
# omit -f / --fail — that flag silently zeros out the output on HTTP
# errors >= 400, so a 401 would parse as empty and the loop would time out.
es::wait_for_api() {
  local host="$1" deadline=$(( SECONDS + 180 ))
  log_info "es: waiting for HTTPS API on ${host} (up to 180s)"
  while (( SECONDS < deadline )); do
    local code
    code=$(ssh::exec "$host" \
      "curl -sSk -o /dev/null -w '%{http_code}' https://127.0.0.1:9200/ 2>/dev/null" \
      || true)
    if [[ "$code" =~ ^(200|401)$ ]]; then
      log_info "es: API responsive (HTTP ${code})"
      return 0
    fi
    sleep 3
  done
  die "es::wait_for_api: timed out after 180s"
}

# es::reset_elastic_password — idempotent. If we already have a saved
# password for this host, we trust it and skip the reset. Otherwise we
# reset and persist.
#
# Plaintext on disk under secrets/ for the lab milestone; the sops/age
# round-trip lands in a later phase. The file is gitignored.
es::reset_elastic_password() {
  local host="$1"
  local secret_file="${ELK_REPO_ROOT}/secrets/${host}.elastic.password"

  if [[ -s "$secret_file" ]]; then
    log_info "es: elastic password already captured for ${host} (skipping reset)"
    return 0
  fi

  log_info "es: resetting elastic user password on ${host}"
  local output
  output=$(ssh::exec "$host" "sudo /usr/share/elasticsearch/bin/elasticsearch-reset-password -u elastic --batch --auto" 2>&1) \
    || die "es: reset-password failed:\n$output"

  local pw
  pw=$(echo "$output" | awk -F': ' '/^New value:/ {print $2; exit}')
  [[ -n "$pw" ]] || die "es: could not parse new password from output:\n$output"

  install -d -m 0700 "${ELK_REPO_ROOT}/secrets"
  umask 0177
  printf '%s\n' "$pw" > "$secret_file"
  chmod 0600 "$secret_file"
  log_warn "es: password saved PLAINTEXT to ${secret_file} (sops/age wiring deferred)"
}

# es::teardown — reverse of es::install + es::configure + es::start.
#
# Default: stop + disable + purge package (removes binaries and
# /etc/elasticsearch via the package's postrm). Keeps /var/lib/elasticsearch,
# /var/log/elasticsearch, the apt repo, and the locally-saved password.
#
# With purge=1: also wipes data + logs on the target, removes the Elastic
# apt repo + key, and deletes the local secrets/<host>.elastic.password.
#
# Idempotent. If ES isn't installed, all sub-steps are no-ops.
es::teardown() {
  local host="$1" purge="${2:-0}"
  log_warn "es: tearing down on ${host} (purge=${purge})"

  # 1) Stop + disable the service if it exists. Tolerate either being absent.
  ssh::exec "$host" "sudo bash -s" <<'REMOTE'
set -euo pipefail
if systemctl list-unit-files elasticsearch.service >/dev/null 2>&1; then
  systemctl disable --now elasticsearch.service 2>/dev/null || true
  echo "service: stopped + disabled"
else
  echo "service: not present"
fi
REMOTE

  # 2) Purge the package (drops /etc/elasticsearch via postrm).
  apt::purge_held "$host" "elasticsearch"

  if (( purge == 1 )); then
    # 3) Wipe data + logs on target.
    log_warn "es: --purge — wiping /var/lib/elasticsearch and /var/log/elasticsearch on ${host}"
    ssh::exec "$host" "sudo bash -s" <<'REMOTE'
set -euo pipefail
for d in /var/lib/elasticsearch /var/log/elasticsearch /etc/elasticsearch; do
  if [ -d "$d" ]; then
    rm -rf -- "$d"
    echo "removed $d"
  fi
done
REMOTE

    # 4) Drop the Elastic apt repo + (maybe) the shared keyring.
    apt::remove_elastic_repo "$host" "9.x"

    # 5) Local secrets cleanup.
    local secret_file="${ELK_REPO_ROOT}/secrets/${host}.elastic.password"
    if [[ -e "$secret_file" ]]; then
      rm -f -- "$secret_file"
      log_info "es: removed local secret ${secret_file}"
    fi
  fi

  log_info "es: teardown complete on ${host}"
}

# es::wait_for_status — poll _cluster/health until reaching at least STATUS.
# Uses the saved elastic password. For single-node we accept yellow.
es::wait_for_status() {
  local host="$1" status="${2:-yellow}"
  local secret_file="${ELK_REPO_ROOT}/secrets/${host}.elastic.password"
  [[ -s "$secret_file" ]] || die "es::wait_for_status: no password at $secret_file"

  local pw target_levels
  pw=$(cat "$secret_file")
  case "$status" in
    green)  target_levels="green" ;;
    yellow) target_levels="yellow|green" ;;
    *) die "es::wait_for_status: unknown status '$status'" ;;
  esac

  log_info "es: waiting for cluster status >= ${status} on ${host}"
  local deadline=$(( SECONDS + 120 ))
  while (( SECONDS < deadline )); do
    local body
    body=$(ssh::exec "$host" \
      "curl -sSk -u elastic:$(printf '%q' "$pw") https://127.0.0.1:9200/_cluster/health 2>/dev/null" || true)
    if [[ -n "$body" ]]; then
      local got
      got=$(echo "$body" | jq -r '.status' 2>/dev/null || echo "")
      if [[ "$got" =~ ^($target_levels)$ ]]; then
        log_info "es: cluster status=${got}"
        return 0
      fi
      log_debug "es: cluster status=${got:-unknown}, waiting"
    fi
    sleep 3
  done
  die "es::wait_for_status: never reached ${status}"
}
