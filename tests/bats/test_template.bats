#!/usr/bin/env bats
# Unit-ish tests for bin/elk-template list / show / lint. These shell out
# to the entrypoint so they cover argument parsing + the helper functions
# together. Fast (no network).

setup() {
  ELK_REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  export ELK_REPO_ROOT
  BIN="${ELK_REPO_ROOT}/bin/elk-template"
  # Use the fixture inventory so the port-collision check has predictable input.
  export ELK_INVENTORY_FILE="${BATS_TEST_DIRNAME}/fixtures/inventory_lab.yml"
}

@test "list shows the generic-syslog template" {
  run "$BIN" list
  [ "$status" -eq 0 ]
  [[ "$output" == *"generic-syslog"* ]]
  [[ "$output" == *"0.1.0"* ]]
}

@test "show errors on an unknown template" {
  run "$BIN" show no-such-template
  [ "$status" -ne 0 ]
  [[ "$output" == *"no such template"* ]]
}

@test "show prints the manifest for a known template" {
  run "$BIN" show generic-syslog
  [ "$status" -eq 0 ]
  [[ "$output" == *"name: generic-syslog"* ]]
  [[ "$output" == *"files:"* ]]
}

@test "lint passes on the shipped templates" {
  run "$BIN" -i "$ELK_INVENTORY_FILE" lint
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK"* ]]
  [[ "$output" != *"FAIL"* ]]
}

@test "lint catches an invalid ndjson line" {
  # Set up a temp template with a broken ndjson, isolated from the real ones.
  tmp_root=$(mktemp -d)
  mkdir -p "$tmp_root/templates/broken-test/kibana"
  cat > "$tmp_root/templates/broken-test/manifest.yml" <<EOF
name: broken-test
version: 0.0.1
description: intentionally bad
EOF
  printf '{"type":"index-pattern","id":"ok"}\n{not valid json\n' \
    > "$tmp_root/templates/broken-test/kibana/data-view.ndjson"

  # Override repo root so cmd_lint scans our temp tree.
  ELK_REPO_ROOT_SAVE="$ELK_REPO_ROOT"
  export ELK_REPO_ROOT="$tmp_root"
  run "$BIN" -i "$ELK_INVENTORY_FILE" lint broken-test
  export ELK_REPO_ROOT="$ELK_REPO_ROOT_SAVE"
  rm -rf "$tmp_root"

  [ "$status" -ne 0 ]
  [[ "$output" == *"invalid JSON"* ]]
  [[ "$output" == *"data-view.ndjson:2"* ]]
}

@test "export rejects missing --name" {
  run "$BIN" -i "$ELK_INVENTORY_FILE" export --version 0.1.0 --object dashboard:x
  [ "$status" -ne 0 ]
  [[ "$output" == *"--name required"* ]]
}

@test "export rejects missing --version" {
  run "$BIN" -i "$ELK_INVENTORY_FILE" export --name x --object dashboard:y
  [ "$status" -ne 0 ]
  [[ "$output" == *"--version required"* ]]
}

@test "export rejects missing --object" {
  run "$BIN" -i "$ELK_INVENTORY_FILE" export --name x --version 0.1.0
  [ "$status" -ne 0 ]
  [[ "$output" == *"--object"* ]]
}

@test "export rejects bad --object format" {
  run "$BIN" -i "$ELK_INVENTORY_FILE" export --name x --version 0.1.0 --object 'no-colon-here'
  [ "$status" -ne 0 ]
  [[ "$output" == *"expected TYPE:ID"* ]]
}

@test "export rejects empty type in --object" {
  run "$BIN" -i "$ELK_INVENTORY_FILE" export --name x --version 0.1.0 --object ':just-id'
  [ "$status" -ne 0 ]
  [[ "$output" == *"expected TYPE:ID"* ]]
}

@test "export rejects empty id in --object" {
  run "$BIN" -i "$ELK_INVENTORY_FILE" export --name x --version 0.1.0 --object 'type-only:'
  [ "$status" -ne 0 ]
  [[ "$output" == *"expected TYPE:ID"* ]]
}

@test "export --help works" {
  run "$BIN" export --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"saved_objects/_export"* ]]
}

@test "lint catches port collisions between two enabled vendors" {
  # Build a fixture inventory where two vendors share a port.
  bad_inv=$(mktemp --suffix=.yml)
  cat > "$bad_inv" <<EOF
profile: lab
stack_version: "9.4.2"
hosts:
  - name: x
    address: 10.0.0.1
    ssh_user: x
    ssh_key: ~/x
    roles: [logstash]
templates:
  - name: generic-syslog
    enabled: true
    udp_port: 5140
    tcp_port: 5140
  - name: barracuda-waf
    enabled: true
    udp_port: 5140    # collide with generic-syslog
    tcp_port: 5141
EOF
  run "$BIN" -i "$bad_inv" lint generic-syslog
  rm -f "$bad_inv"
  [ "$status" -ne 0 ]
  [[ "$output" == *"collides"* ]]
}
