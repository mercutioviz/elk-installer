# shellcheck shell=bash
# lib/nginx.sh — nginx as TLS terminator for Kibana.
#
# Lab scope: self-signed cert with SANs covering 127.0.0.1, the host's
# private IP, and (if detectable) its public IP. Production / public-DNS
# deployments will swap to Let's Encrypt in a later milestone.
#
# Public functions:
#   nginx::install HOST
#   nginx::self_signed_cert HOST       # generates only once; idempotent
#   nginx::configure_kibana_vhost HOST # /etc/nginx/conf.d/elk-kibana.conf
#   nginx::disable_default HOST        # removes the welcome page on :80
#   nginx::reload HOST
#   nginx::teardown HOST [PURGE]

if [[ -n "${_ELK_NGINX_LOADED:-}" ]]; then return 0; fi
_ELK_NGINX_LOADED=1

# shellcheck source=./common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
# shellcheck source=./ssh.sh
source "$(dirname "${BASH_SOURCE[0]}")/ssh.sh"
# shellcheck source=./inventory.sh
source "$(dirname "${BASH_SOURCE[0]}")/inventory.sh"

NGINX_CERT_DIR="/etc/nginx/ssl"
NGINX_CERT="${NGINX_CERT_DIR}/elk-kibana.crt"
NGINX_KEY="${NGINX_CERT_DIR}/elk-kibana.key"
NGINX_VHOST="/etc/nginx/conf.d/elk-kibana.conf"

nginx::install() {
  local host="$1"
  log_info "nginx: ensuring nginx package on ${host}"
  ssh::exec "$host" "sudo bash -s" <<'REMOTE'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
if ! dpkg-query -s nginx >/dev/null 2>&1; then
  apt-get update -qq
  apt-get install -y -qq nginx
fi
echo "nginx: $(dpkg-query -W -f='${Version}' nginx)"
REMOTE
}

# Generate a self-signed cert once. We collect the host's private + public
# IPs at run-time and bake them into the SAN list so the cert validates
# regardless of which address the user hits.
nginx::self_signed_cert() {
  local host="$1"
  log_info "nginx: ensuring self-signed cert on ${host}"

  # Collect the host's primary private IP from the inventory (we know
  # that one) plus its public IP via IMDS (if AWS). Hostname goes in too.
  local inv_addr
  inv_addr=$(inventory::host_field "$host" address)

  ssh::exec "$host" "INV_ADDR=$(printf '%q' "$inv_addr") bash -s" <<'REMOTE'
set -euo pipefail
crt=/etc/nginx/ssl/elk-kibana.crt
key=/etc/nginx/ssl/elk-kibana.key

if sudo test -s "$crt" && sudo test -s "$key"; then
  echo "cert: already present, skipping"
  exit 0
fi

sudo install -d -m 0750 -o root -g root /etc/nginx/ssl

# Try IMDSv2 for public IP; ignore errors silently.
PUBLIC_IP=""
TOKEN=$(curl -fsS -X PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 60" 2>/dev/null || true)
if [ -n "$TOKEN" ]; then
  PUBLIC_IP=$(curl -fsS -H "X-aws-ec2-metadata-token: $TOKEN" \
    "http://169.254.169.254/latest/meta-data/public-ipv4" 2>/dev/null || true)
fi

HN=$(hostname)
HN_FQDN=$(hostname -f 2>/dev/null || echo "$HN")

# Build SAN list — dedupe trivial duplicates.
declare -A SANS
SANS[127.0.0.1]=IP
SANS[$INV_ADDR]=IP
[ -n "$PUBLIC_IP" ] && SANS[$PUBLIC_IP]=IP
SANS[$HN]=DNS
[ "$HN" != "$HN_FQDN" ] && SANS[$HN_FQDN]=DNS
SANS[localhost]=DNS

san=""
for k in "${!SANS[@]}"; do
  type="${SANS[$k]}"
  san+="${san:+,}${type}:${k}"
done

echo "  cert SANs: $san"

sudo openssl req -x509 -newkey rsa:4096 -days 825 -nodes \
  -keyout "$key" -out "$crt" \
  -subj "/CN=$HN/O=elk-installer/OU=lab" \
  -addext "subjectAltName=$san" \
  >/dev/null 2>&1

sudo chmod 0640 "$key"
sudo chmod 0644 "$crt"
sudo chown root:root "$key" "$crt"
echo "cert: generated"
REMOTE
}

# nginx::configure_kibana_vhost HOST [CERT_PATH] [KEY_PATH]
# CERT_PATH / KEY_PATH default to the self-signed paths; pass LE paths
# after certbot has obtained a certificate.
nginx::configure_kibana_vhost() {
  local host="$1"
  local crt="${2:-$NGINX_CERT}"
  local key="${3:-$NGINX_KEY}"
  local allowed_cidrs
  allowed_cidrs=$(inventory::kibana_allowed_cidrs | paste -sd ',' -)
  log_info "nginx: writing kibana vhost on ${host} (allow=${allowed_cidrs:-any})"

  local allow_block=""
  if [[ -n "$allowed_cidrs" ]]; then
    while IFS= read -r c; do
      [[ -z "$c" || "$c" == "TBD" ]] && continue
      allow_block+="        allow ${c};"$'\n'
    done < <(inventory::kibana_allowed_cidrs)
    allow_block+="        deny all;"$'\n'
  fi

  ssh::exec "$host" "sudo bash -s" <<REMOTE
set -euo pipefail
vhost="${NGINX_VHOST}"
crt="${crt}"
key="${key}"

cat > "\$vhost" <<EOF
# elk-installer managed. Hand edits will be overwritten.
# nginx -> Kibana (loopback). TLS terminated here; backend is plaintext.
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;
    return 301 https://\\\$host\\\$request_uri;
}

server {
    listen 443 ssl default_server;
    listen [::]:443 ssl default_server;
    http2 on;
    server_name _;

    ssl_certificate     \$crt;
    ssl_certificate_key \$key;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         HIGH:!aNULL:!MD5;
    ssl_session_cache   shared:SSL:10m;
    ssl_session_timeout 1d;

    # Kibana is a heavy SPA; long timeouts and large upstreams.
    client_max_body_size 100m;
    proxy_read_timeout   90s;
    proxy_send_timeout   90s;
    proxy_buffering      off;

    location / {
${allow_block}
        proxy_pass http://127.0.0.1:5601;
        proxy_http_version 1.1;
        proxy_set_header Host              \\\$host;
        proxy_set_header X-Real-IP         \\\$remote_addr;
        proxy_set_header X-Forwarded-For   \\\$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \\\$scheme;
        proxy_set_header X-Forwarded-Host  \\\$host;
        # Kibana websockets (live tail, etc.)
        proxy_set_header Upgrade           \\\$http_upgrade;
        proxy_set_header Connection        "upgrade";
    }
}
EOF

chmod 0644 "\$vhost"
echo "vhost: ok"
REMOTE
}

# Remove the default debian welcome site so nothing else binds :80.
nginx::disable_default() {
  local host="$1"
  ssh::exec "$host" "sudo bash -s" <<'REMOTE'
set -euo pipefail
if [ -e /etc/nginx/sites-enabled/default ]; then
  rm -f /etc/nginx/sites-enabled/default
  echo "default site disabled"
fi
REMOTE
}

# nginx::letsencrypt HOST FQDN EMAIL
# Install certbot, obtain a certificate for FQDN via the nginx plugin
# (nginx must already be running with a server block matching FQDN),
# then rewrite the vhost to use the LE certificate paths.
nginx::letsencrypt() {
  local host="$1" fqdn="$2" email="$3"
  [[ -n "$fqdn" && -n "$email" ]] \
    || die "nginx::letsencrypt: fqdn and email are required"

  log_info "nginx: installing certbot on ${host}"
  ssh::exec "$host" "sudo bash -s" <<'REMOTE'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
if ! dpkg-query -s certbot >/dev/null 2>&1; then
  apt-get update -qq
  apt-get install -y -qq certbot python3-certbot-nginx
fi
echo "certbot: $(certbot --version 2>&1 | head -1)"
REMOTE

  log_info "nginx: obtaining Let's Encrypt cert for ${fqdn}"
  # Certbot must run as root. --nginx plugin handles ACME challenge via
  # the running nginx (port 80 must be reachable from LE servers).
  # certonly = we manage the vhost ourselves; certbot only fetches the cert.
  ssh::exec "$host" "sudo FQDN=$(printf '%q' "$fqdn") EMAIL=$(printf '%q' "$email") bash -s" <<'REMOTE'
set -euo pipefail
certbot certonly --nginx \
  -d "$FQDN" \
  --email "$EMAIL" \
  --agree-tos \
  --non-interactive \
  --expand \
  2>&1
# Verify cert file was actually created before declaring success.
test -s "/etc/letsencrypt/live/$FQDN/fullchain.pem" \
  || { echo "certbot: cert file missing after run"; exit 1; }
echo "certbot: cert obtained for $FQDN"
REMOTE

  # Only swap vhost if certbot succeeded (cert files exist).
  local le_cert="/etc/letsencrypt/live/${fqdn}/fullchain.pem"
  local le_key="/etc/letsencrypt/live/${fqdn}/privkey.pem"
  log_info "nginx: switching vhost to LE cert (${le_cert})"
  nginx::configure_kibana_vhost "$host" "$le_cert" "$le_key"
  nginx::reload "$host"

  log_info "nginx: Let's Encrypt cert live for ${fqdn}"
  log_info "nginx: auto-renewal via certbot systemd timer (verify: systemctl status certbot.timer)"
}

nginx::reload() {
  local host="$1"
  log_info "nginx: validating + reloading on ${host}"
  ssh::exec "$host" "sudo bash -s" <<'REMOTE'
set -euo pipefail
nginx -t
systemctl enable nginx.service >/dev/null
systemctl restart nginx.service
echo "nginx: $(systemctl is-active nginx.service)"
REMOTE
}

nginx::teardown() {
  local host="$1" purge="${2:-0}"
  log_warn "nginx: removing our vhost on ${host} (purge=${purge})"

  ssh::exec "$host" "sudo bash -s" <<REMOTE
set -euo pipefail
rm -f "${NGINX_VHOST}" "${NGINX_CERT}" "${NGINX_KEY}"
rmdir "${NGINX_CERT_DIR}" 2>/dev/null || true
if systemctl is-active nginx.service >/dev/null 2>&1; then
  if [ -e /etc/nginx/sites-enabled/default ] || ls /etc/nginx/conf.d/*.conf 2>/dev/null | grep -q .; then
    systemctl reload nginx.service
  fi
fi
echo "nginx vhost removed"
REMOTE

  if (( purge == 1 )); then
    log_warn "nginx: --purge — uninstalling nginx package on ${host}"
    ssh::exec "$host" "sudo bash -s" <<'REMOTE'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
systemctl disable --now nginx.service 2>/dev/null || true
apt-get purge -y -qq nginx nginx-common 2>/dev/null || true
apt-get autoremove -y -qq
REMOTE
  fi
}
