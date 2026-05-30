# tests/

Three layers of test, each catching different bugs.

## `bats/`
Shell unit tests via [bats-core](https://github.com/bats-core/bats-core).
Targets pure functions in `lib/`: argument parsing, port-collision detection,
template lint, grok suggestion heuristics. Fast; runs on every push.

## `compose/`
Docker Compose stack — single-node ES + LS + Kibana — used **only as a test
harness**, not as an install path. Exercises `elk-template apply`, the
rsyslog → LS forwarding path, and ingest end-to-end via `_search`. Runs in CI.

## `multipass/`
Full VM smoke tests against the real installer. Spin up 1 or 3 Debian
[multipass](https://multipass.run/) VMs, run the orchestrator over ssh,
verify lab and small-prod profiles end-to-end including nftables and
self-signed TLS. Runs nightly / on release branches.

## `fixtures/syslog/`
Anonymized sample streams per vendor. These double as `elk-listen` regression
inputs — the same sample drives both unit-level grok tests and the integration
end-to-end check.
