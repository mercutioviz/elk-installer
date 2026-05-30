# shellcheck shell=bash
# lib/tls.sh — internal CA + per-node cert issuance.
#
# Bootstraps a small offline CA stored encrypted under secrets/, issues:
#   - ES transport certs (one per node)
#   - ES HTTP certs
#   - Logstash pipeline TLS (when enabled)
#   - Internal Kibana <-> ES cert
# Public-facing Kibana TLS is handled by nginx + Let's Encrypt in
# lib/kibana.sh, not here.
#
# Public functions (to be implemented):
#   tls::bootstrap_ca
#   tls::issue_node_cert HOST ROLE
#   tls::distribute_truststores

if [[ -n "${_ELK_TLS_LOADED:-}" ]]; then return 0; fi
_ELK_TLS_LOADED=1

tls::bootstrap_ca()           { :; }
tls::issue_node_cert()        { :; }
tls::distribute_truststores() { :; }
