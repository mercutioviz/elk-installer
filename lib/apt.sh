# shellcheck shell=bash
# lib/apt.sh — apt repository + package install helpers (target-side).
#
# Public functions:
#   apt::ensure_prereqs HOST              # gnupg + wget + ca-certificates
#   apt::ensure_elastic_repo HOST LINE    # 9.x | 8.x | etc.
#   apt::install_held HOST PKG VERSION    # install exact version, then apt-mark hold
#   apt::purge_held HOST PKG              # apt-mark unhold + purge (teardown)

if [[ -n "${_ELK_APT_LOADED:-}" ]]; then return 0; fi
_ELK_APT_LOADED=1

# shellcheck source=./common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
# shellcheck source=./ssh.sh
source "$(dirname "${BASH_SOURCE[0]}")/ssh.sh"

# Paths (target-side). Match Elastic's documented install instructions verbatim:
#   /usr/share/keyrings/elasticsearch-keyring.gpg
#   /etc/apt/sources.list.d/elastic-<line>.list
ELK_APT_KEYRING="/usr/share/keyrings/elasticsearch-keyring.gpg"
ELK_APT_KEY_URL="https://artifacts.elastic.co/GPG-KEY-elasticsearch"

apt::ensure_prereqs() {
  local host="$1"
  log_info "apt: ensuring prereqs on ${host} (gnupg, wget, ca-certificates, apt-transport-https)"
  ssh::exec "$host" "sudo bash -s" <<'REMOTE'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
need=()
for p in gnupg wget ca-certificates apt-transport-https; do
  dpkg-query -s "$p" >/dev/null 2>&1 || need+=("$p")
done
if [ ${#need[@]} -gt 0 ]; then
  apt-get update -qq
  apt-get install -y -qq "${need[@]}"
fi
REMOTE
}

apt::ensure_elastic_repo() {
  local host="$1" line="${2:-9.x}"
  log_info "apt: ensuring Elastic ${line} repo on ${host}"
  ssh::exec "$host" "sudo bash -s" <<REMOTE
set -euo pipefail
keyring="${ELK_APT_KEYRING}"
key_url="${ELK_APT_KEY_URL}"
list_file="/etc/apt/sources.list.d/elastic-${line}.list"
expected_line="deb [signed-by=\$keyring] https://artifacts.elastic.co/packages/${line}/apt stable main"

changed=0

if [ ! -s "\$keyring" ]; then
  install -d -m 0755 /usr/share/keyrings
  tmp=\$(mktemp)
  wget -qO "\$tmp" "\$key_url"
  gpg --dearmor < "\$tmp" > "\$keyring"
  rm -f "\$tmp"
  chmod 0644 "\$keyring"
  changed=1
fi

if [ ! -f "\$list_file" ] || ! grep -Fq "\$expected_line" "\$list_file"; then
  echo "\$expected_line" > "\$list_file"
  chmod 0644 "\$list_file"
  changed=1
fi

if [ \$changed -eq 1 ]; then
  apt-get update -qq
fi
echo "elastic-repo: ok"
REMOTE
}

apt::install_held() {
  local host="$1" pkg="$2" upstream="$3"
  log_info "apt: installing ${pkg}=${upstream} on ${host} (held)"
  # Resolve the upstream patch (e.g. "9.4.2") into the actual apt version
  # string. ES ships as "9.4.2", Logstash as "1:9.4.2-1" (epoch+Debian
  # revision), and Kibana similarly. We strip epoch + revision off each
  # candidate and match upstream.
  ssh::exec "$host" "sudo bash -s" <<REMOTE
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
pkg="${pkg}"
upstream="${upstream}"

resolved=\$(apt-cache madison "\$pkg" 2>/dev/null \
  | awk -v u="\$upstream" '
      {
        v = \$3
        x = v
        sub(/^[0-9]+:/, "", x)      # strip epoch
        sub(/-[^-]+$/, "", x)        # strip Debian revision
        if (x == u) { print v; exit }
      }')

if [ -z "\$resolved" ]; then
  echo "ERROR: no candidate matches upstream '\$upstream' for package '\$pkg'" >&2
  apt-cache madison "\$pkg" >&2
  exit 100
fi

have=\$(dpkg-query -W -f='\${Version}' "\$pkg" 2>/dev/null || true)
if [ "\$have" = "\$resolved" ]; then
  apt-mark hold "\$pkg" >/dev/null
  echo "\$pkg already at \$resolved, held"
  exit 0
fi

if apt-mark showhold | grep -qx "\$pkg"; then
  apt-mark unhold "\$pkg" >/dev/null
fi

apt-get install -y -qq --no-install-recommends "\${pkg}=\${resolved}"
apt-mark hold "\$pkg" >/dev/null
echo "installed and held \$pkg=\$resolved"
REMOTE
}

apt::purge_held() {
  local host="$1" pkg="$2"
  log_warn "apt: purging ${pkg} on ${host} (TEARDOWN — removes binaries + config)"
  ssh::exec "$host" "sudo bash -s" <<REMOTE
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
pkg="${pkg}"
# Not-installed? Nothing to do.
if ! dpkg-query -s "\$pkg" >/dev/null 2>&1; then
  echo "\$pkg: not installed"
  exit 0
fi
apt-mark unhold "\$pkg" 2>/dev/null || true
apt-get purge -y -qq "\$pkg"
apt-get autoremove -y -qq
echo "\$pkg: purged"
REMOTE
}

# apt::remove_elastic_repo — drops our sources.list.d file. Removes the
# keyring only if no other elastic-*.list still references it. Idempotent.
apt::remove_elastic_repo() {
  local host="$1" line="${2:-9.x}"
  log_info "apt: removing Elastic ${line} repo on ${host}"
  ssh::exec "$host" "sudo bash -s" <<REMOTE
set -euo pipefail
keyring="${ELK_APT_KEYRING}"
list_file="/etc/apt/sources.list.d/elastic-${line}.list"

rm -f "\$list_file"

# Keyring shared across major-version lines? Only remove if nothing else
# references it.
if [ -e "\$keyring" ] && ! grep -lr -- "\$keyring" /etc/apt/sources.list /etc/apt/sources.list.d 2>/dev/null | grep -q .; then
  rm -f "\$keyring"
fi

apt-get update -qq || true
echo "elastic-repo-removed"
REMOTE
}
