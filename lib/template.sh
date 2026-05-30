# shellcheck shell=bash
# lib/template.sh — vendor template bundle operations.
#
# Templates are versioned bundles under templates/<vendor>/. See
# templates/<vendor>/README.md for the bundle layout.
#
# Public functions (to be implemented):
#   template::list
#   template::show NAME
#   template::lint DIR
#   template::apply NAME
#   template::export VENDOR NEW_NAME
#   template::package DIR
#   template::manifest_field DIR FIELD

if [[ -n "${_ELK_TEMPLATE_LOADED:-}" ]]; then return 0; fi
_ELK_TEMPLATE_LOADED=1

template::list()           { :; }
template::show()           { :; }
template::lint()           { :; }
template::apply()          { :; }
template::export()         { :; }
template::package()        { :; }
template::manifest_field() { :; }
