# elk-installer

Reproducible ELK stack installer for Debian-based hosts in Azure, AWS, and GCP.
Native `.deb` packages and `systemd` services, driven from a **control node**
over `ssh`. Inventory + profile YAML is the single source of truth.

> **Status:** lab profile (single host, all roles) works end-to-end on
> Debian 13 / Elastic 9.4.2 — Elasticsearch + Logstash + rsyslog + Kibana
> behind nginx with a self-signed cert. Templates can be applied to Kibana
> over the API. Headless UI verification via Playwright.
>
> Read [`CLAUDE.md`](CLAUDE.md) before contributing — accuracy over speed,
> ask rather than guess.

## What works today

| Capability | Status |
|---|---|
| `lab` profile (single host, all roles) | Working end-to-end |
| Elasticsearch 9.4.2 + security auto-config | Working |
| Logstash 9.4.2 + LS keystore + ES data stream output | Working |
| rsyslog front door (per-vendor port + file + LS forward) | Working |
| Kibana 9.4.2 behind nginx with self-signed TLS | Working |
| `elk-install init / preflight / apply / teardown` | Working, idempotent |
| `elk-kibana bootstrap / whoami` | Working |
| `elk-template list / show / apply / lint` | Working |
| `elk-template export / package` | Not implemented |
| `small-prod` / `prod` profiles | Stubs only |
| Multi-host (ES + LS + Kibana on separate boxes) | Code shape ready; not exercised |
| Let's Encrypt for Kibana | Not implemented |
| `elk-listen` syslog capture utility | Not implemented |
| `elk-doctor` health checks | Stub |
| Snapshot repos / ILM tuning / OIDC | v2 |

## Concepts

### Profiles
Pick a shape for the deployment:
- **`lab`** — single host, all roles, self-signed TLS, no Let's Encrypt.
- **`small-prod`** — three hosts (ES, Logstash + rsyslog, Kibana + nginx). *Stub.*
- **`prod`** — multi-node ES + 2× LS + 2× Kibana. *Stub.*

Profiles map abstract **roles** (`es-master`, `es-data`, `logstash`, `kibana`)
onto hosts in your inventory.

### Templates
A **template** is a versioned bundle of everything needed to ingest, store,
and visualize one vendor's data:

```
templates/<vendor>/
  manifest.yml
  rsyslog/        # /etc/rsyslog.d/ snippets (deferred — currently inline)
  logstash/       # /etc/logstash/conf.d/ snippets (deferred — currently inline)
  elasticsearch/  # component / index templates + ILM policy (deferred)
  kibana/         # data views, dashboards, lenses (ndjson) — WORKING
  docs/
```

v1 templates ship Kibana saved objects (data view) and a manifest. Logstash
+ rsyslog pipelines are currently generated inline in `lib/`; moving them
fully into template bundles is the next refactor.

### Syslog capture utility
`bin/elk-listen` (planned) will help go from "a Barracuda is pointed at this
port" to "a clean Logstash filter." Not implemented yet.

## Entrypoints

| Command | Status | Purpose |
|---|---|---|
| `bin/elk-install init` | Working | Generate starter `inventory.yml` from a profile |
| `bin/elk-install preflight` | Working | OS / RAM / disk / time / egress / port checks per host |
| `bin/elk-install apply` | Working | Install ES + LS + rsyslog + Kibana + nginx |
| `bin/elk-install reapply` | Stub | (use `apply --skip-preflight` for now) |
| `bin/elk-install status` | Stub | |
| `bin/elk-install teardown` | Working | `--purge` for full removal |
| `bin/elk-kibana bootstrap` | Working | Baseline data view via Kibana API |
| `bin/elk-kibana whoami` | Working | Auth sanity check + data-view count |
| `bin/elk-template list / show` | Working | Browse `templates/` |
| `bin/elk-template apply` | Working | Import `kibana/*.ndjson` via saved_objects/_import |
| `bin/elk-template lint` | Working | Manifest + ndjson + port-collision check |
| `bin/elk-template export / package` | Stub | |
| `bin/elk-doctor` | Stub | |

## Requirements

- **Control node:** Linux or macOS with `bash`, `ssh`, `jq`, `yq` (Debian
  python-yq, jq wrapper), `python3` ≥ 3.11, `curl`, `openssl`. Optional:
  `sops` + `age` (encrypted secrets — wiring deferred), `shellcheck`,
  `bats-core` (for tests), Playwright in a venv (for UI verification).
- **Targets:** Debian 12 (bookworm) or 13 (trixie), sudo, network egress
  to `artifacts.elastic.co`. For all-in-one lab: ≥ 5 GB RAM strongly
  recommended (t3.medium / 3.8 GB OOMs during Kibana startup — confirmed).

## Testing

Three layers (see `tests/`):

- **`tests/bats/`** — `bats-core` unit tests against `lib/`. Currently 18
  passing tests covering inventory reader + template list/show/lint.
  Run `bats tests/bats/`.
- **`tests/verify/`** — Python venv + Playwright headless verification.
  `kibana_login.py` drives Chromium against the live target, exercises
  the login flow, and screenshots Home + Discover. Run:
  `./.venv/bin/python kibana_login.py https://<host>/ elastic <password>`
- **`tests/compose/`** — Reserved for Docker-Compose integration tests
  (test harness only — never an install path). Not populated yet.

### Linting

```
shellcheck -x -e SC1091 bin/* lib/*.sh   # currently clean
./bin/elk-template lint                  # template manifest + port-collision check
```

## End-to-end loop

1. Device sends syslog to `udp/5140` on the LS host.
2. `rsyslog` writes a per-vendor file under `/var/log/elk-ingest/<vendor>/` AND
   forwards over local TCP to Logstash.
3. Logstash pipeline parses (grok `SYSLOGLINE`), normalizes ECS-ish fields.
4. Logstash writes to the ES **data stream** `logs-syslog.generic-default`
   via the data_stream API (op_type=create).
5. ES's built-in `logs` index template applies, with ILM policy `logs` and
   logsdb index mode.
6. Kibana data view `elk-installer-syslog-generic` (created by `elk-kibana
   bootstrap` or `elk-template apply generic-syslog`) points at the data
   stream.
7. Discover renders the events with `@timestamp`, `host.hostname`,
   `message`, `data_stream.*`, etc.

## Barracuda WaaS log export configuration

The `barracuda-waas` template requires specific **KEY=VALUE** format strings
configured in the WaaS portal. See `templates/barracuda-waas/README.md` for
complete field tables. Quick reference:

### Where to configure

1. Log in to the Barracuda WaaS portal and select your application.
2. Navigate to **Log > Export Log > Syslog**.
3. Set the **Syslog Server** to the IP of the Logstash/rsyslog host and
   **Port** to `5141`. **TCP** is preferred over UDP.
4. Paste the format strings below into the respective format fields.
5. Save and enable. Events appear in Kibana within seconds.

> **Syslog header settings** (facility, severity, protocol version): no
> specific values required — rsyslog normalizes the header to ISO8601 before
> forwarding to Logstash. Leave at WaaS defaults.

### Access Log format string (TR)

Paste verbatim into the **Access Log** format field:

```
TS=%t UN=%un LT=%lt AI=%ai AP=%ap CI=%ci CP=%cp ID=%id CU=%cu M=%m P=%p H=%h V=%v S=%s BS=%bs BR=%br CH=%ch TT=%tt SI=%si SP=%sp ST=%st SID=%sid RTF=%rtf PMF=%pmf PF=%pf WMF=%wmf U=%u Q=%q R=%r C=%c UA="%ua" PX=%px PP=%pp AU=%au CS1=%cs1 CS2=%cs2 CS3=%cs3 CC=%cc UID=%uid
```

### Web Firewall Log format string (WF)

Paste verbatim into the **Web Firewall Log** format field:

```
TS=%t UN=%un LT=%lt SL=%sl AD=%ad CI=%ci CP=%cp AI=%ai AP=%ap RI=%ri RT=%rt AT=%at FA=%fa M=%m U=%u Q=%q P=%p SID=%sid UA="%ua" PX=%px PP=%pp AU=%au R=%r CC=%cc UID=%uid ADL=%adl
```

### Data streams and field mapping summary

| Log type | Data stream | Key ECS fields |
|---|---|---|
| TR (access) | `logs-barracuda.waas.access-default` | `source.ip`, `url.path`, `http.response.status_code`, `user_agent.original`, `waas.time_taken_ms` |
| WF (firewall) | `logs-barracuda.waas.firewall-default` | `source.ip`, `waas.attack_type`, `waas.severity`, `event.action`, `waas.attack_detail` |

`UA="%ua"` must include the surrounding double-quotes in the format string —
the `kv` filter cannot parse quoted multi-word values, so the UA is extracted
by a separate grok step and the quotes are part of the delimiter.

## Contributing

Read [`CLAUDE.md`](CLAUDE.md) first. Short version: accuracy over speed,
ask rather than guess, every change is idempotent and reversible, templates
are versioned, and the UI gets opened in a browser before anything is
called "done."

## License

See [`LICENSE`](LICENSE).
