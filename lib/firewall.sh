# shellcheck shell=bash
# lib/firewall.sh — host firewall management.
#
# We use nftables (Debian 12+ default) and manage a dedicated table named
# `elk` so we never touch the user's other rules. Rules are derived from
# the inventory: per-role port openings plus per-vendor syslog ports.
#
# Per CLAUDE.md: rules are additive and tagged; reapply diffs against the
# desired state and only changes what is needed.
#
# Public functions (to be implemented):
#   firewall::apply HOST
#   firewall::reapply HOST
#   firewall::teardown HOST

if [[ -n "${_ELK_FIREWALL_LOADED:-}" ]]; then return 0; fi
_ELK_FIREWALL_LOADED=1

firewall::apply()    { :; }
firewall::reapply()  { :; }
firewall::teardown() { :; }
