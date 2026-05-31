# barracuda-waas

Logstash pipeline for Barracuda WAF-as-a-Service (WaaS) syslog.

## Status
v0.1.0 — functional. Parses TR (Traffic/Access) and WF (Web Firewall)
record types into separate ECS-shaped data streams.

## WaaS syslog format configuration

Set in each WaaS app's Log > Custom Syslog configuration — **TR and WF
are separate fields in the UI**.

**Access Log (TR):**
```
%t %un %lt %ai %ap %ci %cp "%id" "%cu" %m %p "%h" %v %s %bs %br %ch %tt %si %sp %st "%sid" %rtf %pmf %pf %wmf "%u" "%q" "%r" "%c" "%ua" %px %pp "%au" "%cs1" "%cs2" "%cs3" %cc %uid
```

**Web Firewall Log (WF):**
```
%t %un %lt %sl %ad %ci %cp %ai %ap %ri %rt %at %fa %m "%u" "%q" %p "%sid" "%ua" %px %pp "%au" "%r" %cc %uid %adl
```

## Data streams produced

| Log type | Data stream |
|---|---|
| TR | `logs-barracuda.waas.access-default` |
| WF | `logs-barracuda.waas.firewall-default` |

## ECS fields populated

| ECS field | WaaS source |
|---|---|
| `@timestamp` | `%t` (WaaS time, ms precision) |
| `source.ip` | `%ci` |
| `source.port` | `%cp` |
| `destination.ip` | `%ai` |
| `destination.port` | `%ap` |
| `http.request.method` | `%m` |
| `http.response.status_code` | `%s` (TR only) |
| `http.response.body.bytes` | `%bs` (TR only) |
| `url.path` | `%u` |
| `url.query` | `%q` |
| `url.domain` | `%h` (TR only) |
| `http.request.referrer` | `%r` |
| `user_agent.original` | `%ua` |
| `network.transport` | `%p` |
| `source.geo.country_iso_code` | `%cc` |
| `event.action` | `%at` (WF: DENY/ALLOW) |
| `event.outcome` | derived from `%at` |

## Vendor-specific fields (`waas.*`)

`unit_name`, `log_type`, `event_id`, `session_id`, `response_type`,
`profile_matched`, `protected`, `wf_matched`, `severity`, `attack_type`,
`action`, `rule_id`, `rule_type`, `attack_detail`, `cache_hit`,
`time_taken_ms`, `server_ip`, `server_port`, `proxy_ip`, `proxy_port`,
`cookie`, `auth_user`, `custom_header_1/2/3`.
