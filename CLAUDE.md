# elk-installer — working agreement

## What this repo is
A reproducible ELK stack installer for Debian-based hosts in Azure / AWS / GCP.
Native .deb packages + systemd, driven from a control node over ssh. The
inventory + profile YAML is the single source of truth for what a deployment
looks like.

## Operating principles — read these every time

### Accuracy over speed
- If you are not certain about an Elastic version, a config key, an ES API
  shape, a systemd unit name, a sysctl, an rsyslog directive, or a grok pattern:
  stop and verify. Read the file, run `--help`, fetch the official docs. Do not
  pattern-match from training data and ship it.
- Never invent flags, paths, package names, or API endpoints. If you cannot
  confirm one exists in this repo or in the installed software, ask.
- When in doubt about whether a change is safe, run it in `tests/multipass/`
  first and report what you saw before applying anywhere else.

### Ask, do not guess
- If the user's request is ambiguous in any way that affects security,
  networking, data shape, or destructive operations: ASK before acting.
  A short clarifying question is always cheaper than a wrong install.
- Examples that require asking, not guessing: which CIDRs to allow, which
  hostname to put on the cert, whether to wipe `/var/lib/elasticsearch`,
  whether a template should overwrite an existing one, which Elastic version
  to pin, which profile to apply.
- "I'll assume X" is not acceptable for any of the above. Use AskUserQuestion.

### Idempotence is non-negotiable
- Every action must be safe to run twice. Use marker comments in generated
  files, check before create, diff before overwrite.
- Never edit a user-owned config file in place without a backup and a marker
  block. Drop ours into `/etc/<svc>/<svc>.d/` or `conf.d/` where possible.

### Reversibility
- Every install phase has a corresponding teardown. If you add a new phase,
  add the teardown in the same PR.
- Destructive flags (`--purge`, `--reapply`, `--force`) require confirmation
  unless the user already opted into non-interactive mode AND named the flag
  on the command line.

### Security defaults are on
- Stack security on. TLS on transport and HTTP. No anonymous access.
- Kibana never binds to a public interface — nginx fronts it.
- Secrets live in sops/age-encrypted files under `secrets/`. Never commit
  plaintext passwords, keys, or CA material.
- Firewall rules are additive and tagged `elk`; we never flush or replace
  rules outside our tagged table/chain.

### Templates are the contract
- A template change is a versioned change. Bump `manifest.yml` version and
  add a `CHANGELOG` entry for any field, mapping, dashboard, or pipeline
  change. Do not silently mutate templates users have already applied.
- `elk-template lint` must pass before any template is committed.

### Testing before claiming "done"
- Shell changes: run `bats tests/bats/`.
- Pipeline or template changes: run `tests/compose/` and verify events land
  in ES via `_search`, not just "logstash started without errors."
- End-to-end installer changes: run against a Multipass VM. UI / dashboard
  changes: open Kibana in a browser and confirm the view renders with data.
  If you cannot run the UI, say so explicitly — do not claim success.

### Communication
- Short, factual updates. State what you changed, what you verified, what
  you did NOT verify, and any assumption you made (and want confirmed).
- When you make a judgment call the user might want to revisit, say so once
  and move on — do not hedge every sentence.

## Where things live
- Orchestration entrypoints: `bin/`
- Sourced bash modules: `lib/`
- Deployment profiles (YAML): `profiles/`
- Vendor bundles: `templates/<vendor>/`
- Encrypted secrets: `secrets/` (sops/age)
- Tests: `tests/bats/`, `tests/compose/`, `tests/multipass/`, `tests/fixtures/`

## House style
- Bash: `set -euo pipefail`, `shellcheck` clean, functions in `lib/`,
  no global state beyond what `lib/inventory.sh` exposes.
- Python helpers: stdlib only, 3.11+, no third-party deps without discussion.
- Logging: every script logs to stdout AND `/var/log/elk-installer/<phase>.log`
  on the target. Phases tag every line `[phase=<name>]`.
- One thing per script; orchestration in `bin/elk-install`, never in `lib/`.

## When you are unsure
Ask. This file exists because the cost of a wrong install in a security
ingest path is much higher than the cost of one extra question.
