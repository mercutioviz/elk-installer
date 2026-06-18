# barracuda-waas

Logstash pipeline for Barracuda WAF-as-a-Service (WaaS) syslog.

## Status
v0.2.0 — functional. Parses TR (Traffic/Access) and WF (Web Firewall)
record types into separate ECS-shaped data streams.

## WaaS syslog format configuration

Set in each WaaS app's **Log > Custom Syslog** configuration. TR and WF
are separate format string fields in the UI. The pipeline uses `kv` filter
and requires **KEY=VALUE** format — do not use positional format strings.

**Syslog server settings:**
- **Server:** IP or hostname of the Logstash/rsyslog host
- **Port:** 5141 (TCP preferred; UDP also accepted)
- **Protocol:** TCP
- **Facility / Severity:** any — rsyslog normalizes the header before forwarding

**Access Log (TR) — paste verbatim into the Access Log format field:**
```
TS=%t UN=%un LT=%lt AI=%ai AP=%ap CI=%ci CP=%cp ID=%id CU=%cu M=%m P=%p H=%h V=%v S=%s BS=%bs BR=%br CH=%ch TT=%tt SI=%si SP=%sp ST=%st SID=%sid RTF=%rtf PMF=%pmf PF=%pf WMF=%wmf U=%u Q=%q R=%r C=%c UA="%ua" PX=%px PP=%pp AU=%au CS1=%cs1 CS2=%cs2 CS3=%cs3 CC=%cc UID=%uid
```

**Web Firewall Log (WF) — paste verbatim into the Web Firewall Log format field:**
```
TS=%t UN=%un LT=%lt SL=%sl AD=%ad CI=%ci CP=%cp AI=%ai AP=%ap RI=%ri RT=%rt AT=%at FA=%fa M=%m U=%u Q=%q P=%p SID=%sid UA="%ua" PX=%px PP=%pp AU=%au R=%r CC=%cc UID=%uid ADL=%adl
```

## Access Log (TR) — field reference

| WaaS token | KEY | ECS / `waas.*` field | Type | Notes |
|---|---|---|---|---|
| `%t` | TS | _(drives `@timestamp` via rsyslog header)_ | date | WaaS timestamp; rsyslog ISO8601 header used instead |
| `%un` | UN | `waas.unit_name` | keyword | App/service name configured in WaaS |
| `%lt` | LT | `waas.log_type` | keyword | Always `TR` for access logs |
| `%ai` | AI | `destination.ip` | ip | App/WAF IP (inbound side) |
| `%ap` | AP | `destination.port` | integer | |
| `%ci` | CI | `source.ip` | ip | Client (end-user) IP |
| `%cp` | CP | `source.port` | integer | |
| `%id` | ID | `waas.login_id` | keyword | |
| `%cu` | CU | `waas.cert_user` | keyword | |
| `%m` | M | `http.request.method` | keyword | GET, POST, etc. |
| `%p` | P | `network.transport` | keyword | HTTP or HTTPS |
| `%h` | H | `url.domain` | keyword | Host header value |
| `%v` | V | `http.version` | keyword | 1.0, 1.1, 2 |
| `%s` | S | `http.response.status_code` | integer | |
| `%bs` | BS | `http.response.body.bytes` | integer | |
| `%br` | BR | `http.request.body.bytes` | integer | |
| `%ch` | CH | `waas.cache_hit` | integer | 0 or 1 |
| `%tt` | TT | `waas.time_taken_ms` | integer | Total request time |
| `%si` | SI | `waas.server_ip` | keyword | Backend server IP |
| `%sp` | SP | `waas.server_port` | integer | |
| `%st` | ST | `waas.server_time_ms` | integer | Backend response time |
| `%sid` | SID | `waas.session_id` | keyword | |
| `%rtf` | RTF | `waas.response_type` | keyword | |
| `%pmf` | PMF | `waas.profile_matched` | keyword | |
| `%pf` | PF | `waas.protected` | keyword | |
| `%wmf` | WMF | `waas.wf_matched` | keyword | |
| `%u` | U | `url.path` | keyword | |
| `%q` | Q | `url.query` | keyword | Empty string when `-` |
| `%r` | R | `http.request.referrer` | keyword | |
| `%c` | C | _(dropped)_ | — | Cookie — parsed but not indexed |
| `%ua` | UA | `user_agent.original` | keyword | Quoted in format string |
| `%px` | PX | `waas.proxy_ip` | keyword | |
| `%pp` | PP | `waas.proxy_port` | integer | |
| `%au` | AU | `waas.auth_user` | keyword | |
| `%cs1` | CS1 | `waas.custom_header_1` | keyword | |
| `%cs2` | CS2 | `waas.custom_header_2` | keyword | |
| `%cs3` | CS3 | `waas.custom_header_3` | keyword | |
| `%cc` | CC | `source.geo.country_iso_code` | keyword | ISO 3166-1 alpha-2 |
| `%uid` | UID | `waas.event_id` | keyword | |

## Web Firewall Log (WF) — field reference

| WaaS token | KEY | ECS / `waas.*` field | Type | Notes |
|---|---|---|---|---|
| `%t` | TS | _(drives `@timestamp` via rsyslog header)_ | date | |
| `%un` | UN | `waas.unit_name` | keyword | |
| `%lt` | LT | `waas.log_type` | keyword | Always `WF` |
| `%sl` | SL | `waas.severity` | keyword | EMERGENCY … DEBUG |
| `%ad` | AD | `waas.attack_type` | keyword | E.g. `SQL Injection` |
| `%ci` | CI | `source.ip` | ip | Client IP |
| `%cp` | CP | `source.port` | integer | |
| `%ai` | AI | `destination.ip` | ip | |
| `%ap` | AP | `destination.port` | integer | |
| `%ri` | RI | `waas.rule_id` | keyword | |
| `%rt` | RT | `waas.rule_type` | keyword | |
| `%at` | AT | `waas.action` / `event.action` | keyword | DENY or ALLOW |
| `%fa` | FA | `waas.follow_up_action` | keyword | |
| `%m` | M | `http.request.method` | keyword | |
| `%u` | U | `url.path` | keyword | |
| `%q` | Q | `url.query` | keyword | |
| `%p` | P | `network.transport` | keyword | |
| `%sid` | SID | `waas.session_id` | keyword | |
| `%ua` | UA | `user_agent.original` | keyword | Quoted |
| `%px` | PX | `waas.proxy_ip` | keyword | |
| `%pp` | PP | `waas.proxy_port` | integer | |
| `%au` | AU | `waas.auth_user` | keyword | |
| `%r` | R | `http.request.referrer` | keyword | |
| `%cc` | CC | `source.geo.country_iso_code` | keyword | |
| `%uid` | UID | `waas.event_id` | keyword | |
| `%adl` | ADL | `waas.attack_detail` | keyword | Attack payload / rule detail; `-` stripped |

`event.outcome` is derived from `%at`: `DENY` → `failure`, anything else → `success`.

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
