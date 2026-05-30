#!/usr/bin/env bats
# Offline tests for bin/elk-listen and lib/listen.sh::tokenize_vendor_conf.

setup() {
  ELK_REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  export ELK_REPO_ROOT
  BIN="${ELK_REPO_ROOT}/bin/elk-listen"
  # Real fixture inventory: both generic-syslog and barracuda-waf enabled.
  export ELK_INVENTORY_FILE="${BATS_TEST_DIRNAME}/fixtures/inventory_lab.yml"
}

# ---- arg validation (no network) ----

@test "test rejects both --vendor and PIPELINE.conf" {
  run "$BIN" test --vendor x some-file.conf
  [ "$status" -ne 0 ]
  [[ "$output" == *"not both"* ]]
}

@test "test rejects neither --vendor nor PIPELINE.conf" {
  run "$BIN" test
  [ "$status" -ne 0 ]
  [[ "$output" == *"either"* ]]
}

@test "test rejects PIPELINE.conf given twice" {
  run "$BIN" test a.conf b.conf
  [ "$status" -ne 0 ]
  [[ "$output" == *"only be given once"* ]]
}

@test "test --vendor with missing template directory fails clearly" {
  run "$BIN" test --vendor no-such-vendor
  [ "$status" -ne 0 ]
  [[ "$output" == *"no templates/no-such-vendor/logstash/*.conf"* ]]
}

@test "test --help works" {
  run "$BIN" test --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"PIPELINE.conf"* ]]
  [[ "$output" == *"--vendor"* ]]
}

@test "capture requires --vendor and --port" {
  run "$BIN" capture --vendor x
  [ "$status" -ne 0 ]
  [[ "$output" == *"--port required"* ]]

  run "$BIN" capture --port 5141
  [ "$status" -ne 0 ]
  [[ "$output" == *"--vendor required"* ]]
}

@test "capture --seconds must be numeric" {
  run "$BIN" capture --vendor x --port 5141 --seconds notanumber
  [ "$status" -ne 0 ]
  [[ "$output" == *"--seconds must be numeric"* ]]
}

@test "promote requires every flag" {
  run "$BIN" promote pipelines/x.conf --vendor x
  [ "$status" -ne 0 ]
  [[ "$output" == *"--external-port required"* ]]
}

# ---- tokenization (pure, no ssh) ----

@test "tokenize_vendor_conf substitutes __VENDOR__ and __VENDOR_DATASET__" {
  # shellcheck source=../../lib/inventory.sh
  source "${ELK_REPO_ROOT}/lib/inventory.sh"
  # shellcheck source=../../lib/listen.sh
  source "${ELK_REPO_ROOT}/lib/listen.sh"
  inventory::load "$ELK_INVENTORY_FILE"

  out=$(listen::tokenize_vendor_conf barracuda-waf)
  [ -n "$out" ]
  # Tokens should be gone, values present.
  echo "$out" | grep -qv '__VENDOR__'
  echo "$out" | grep -qv '__VENDOR_DATASET__'
  echo "$out" | grep -qv '__LS_INTERNAL_PORT__'
  echo "$out" | grep -qv '__LS_ES_USER__'
  echo "$out" | grep -qv '__LS_ES_CA_PATH__'
  # Value substitutions.
  echo "$out" | grep -q 'data_stream_dataset.*barracuda\.waf'
  echo "$out" | grep -q 'user.*logstash_internal'
}

@test "tokenize_vendor_conf picks the right internal port from inventory" {
  source "${ELK_REPO_ROOT}/lib/inventory.sh"
  source "${ELK_REPO_ROOT}/lib/listen.sh"
  inventory::load "$ELK_INVENTORY_FILE"

  # Fixture order: generic-syslog (idx 0 -> 5044), barracuda-waf (idx 1 -> 5045)
  generic_out=$(listen::tokenize_vendor_conf generic-syslog)
  waf_out=$(listen::tokenize_vendor_conf barracuda-waf)

  echo "$generic_out" | grep -q 'port => 5044'
  echo "$waf_out"     | grep -q 'port => 5045'
}

@test "tokenize_vendor_conf returns non-zero for an unknown vendor" {
  source "${ELK_REPO_ROOT}/lib/inventory.sh"
  source "${ELK_REPO_ROOT}/lib/listen.sh"
  inventory::load "$ELK_INVENTORY_FILE"

  run listen::tokenize_vendor_conf no-such-vendor
  [ "$status" -ne 0 ]
}

@test "vendor_index returns 0 for first enabled and 1 for second" {
  source "${ELK_REPO_ROOT}/lib/inventory.sh"
  source "${ELK_REPO_ROOT}/lib/listen.sh"
  inventory::load "$ELK_INVENTORY_FILE"

  result=$(listen::vendor_index generic-syslog)
  [ "$result" = "0" ]
  result=$(listen::vendor_index barracuda-waf)
  [ "$result" = "1" ]
}
