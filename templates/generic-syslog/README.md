# generic-syslog

Catch-all template for RFC3164 / RFC5424 syslog. Lands raw events in ES with
just the universal fields parsed (timestamp, host, program, severity, message).
Useful as a safety net for sources that don't have a dedicated template yet.

## Status
Scaffolding only. No pipeline / template / dashboard content yet.

## Default ports
- UDP 5140
- TCP 5140

Override in your inventory under `templates:` if these clash.

## Layout
See `manifest.yml` for the canonical layout.
