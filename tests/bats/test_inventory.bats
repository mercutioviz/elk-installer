#!/usr/bin/env bats
# Unit tests for lib/inventory.sh against a fixed fixture.

setup() {
  ELK_REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  export ELK_REPO_ROOT
  ELK_INVENTORY_FILE="${BATS_TEST_DIRNAME}/fixtures/inventory_lab.yml"
  export ELK_INVENTORY_FILE
  # shellcheck source=../../lib/inventory.sh
  source "${ELK_REPO_ROOT}/lib/inventory.sh"
  inventory::load "$ELK_INVENTORY_FILE"
}

@test "profile is read" {
  result=$(inventory::profile)
  [ "$result" = "lab" ]
}

@test "stack_version is read" {
  result=$(inventory::stack_version)
  [ "$result" = "9.4.2" ]
}

@test "hosts lists both hosts in order" {
  result=$(inventory::hosts | paste -sd, -)
  [ "$result" = "elk-test-a,elk-test-b" ]
}

@test "host_field returns address for a known host" {
  result=$(inventory::host_field "elk-test-a" address)
  [ "$result" = "10.99.0.10" ]
}

@test "host_field returns ssh_user for the second host" {
  result=$(inventory::host_field "elk-test-b" ssh_user)
  [ "$result" = "ubuntu" ]
}

@test "host_field returns empty for an unknown host" {
  result=$(inventory::host_field "nope" address)
  [ -z "$result" ]
}

@test "roles_for returns all 4 roles for host a" {
  result=$(inventory::roles_for "elk-test-a" | paste -sd, -)
  [ "$result" = "es-master,es-data,logstash,kibana" ]
}

@test "roles_for returns only logstash for host b" {
  result=$(inventory::roles_for "elk-test-b" | paste -sd, -)
  [ "$result" = "logstash" ]
}

@test "vendors returns only ENABLED templates" {
  result=$(inventory::vendors | paste -sd, -)
  # not-enabled-vendor must be excluded
  [ "$result" = "generic-syslog,barracuda-waf" ]
}

@test "vendor_field returns udp_port" {
  result=$(inventory::vendor_field "barracuda-waf" udp_port)
  [ "$result" = "5141" ]
}

@test "kibana_fqdn / email / allowed_cidrs are populated" {
  fqdn=$(inventory::kibana_fqdn)
  email=$(inventory::kibana_email)
  cidrs=$(inventory::kibana_allowed_cidrs | paste -sd, -)
  [ "$fqdn"  = "kibana.test.example.com" ]
  [ "$email" = "admin@test.example.com" ]
  [ "$cidrs" = "10.99.0.0/16,192.168.1.5/32" ]
}

@test "load rejects missing files" {
  run inventory::load "/nope.yml"
  [ "$status" -ne 0 ]
  [[ "$output" == *"not readable"* ]]
}
