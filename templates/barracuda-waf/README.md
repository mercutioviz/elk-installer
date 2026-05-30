# barracuda-waf

Ingest template for Barracuda Web Application Firewall syslog.

## Status
**Scaffolding only.** No pipeline / mappings / dashboards yet. Do not enable
in an inventory until the manifest is filled in and lint passes.

## Authoring workflow
This template is the planned dogfood case for the export workflow:
1. Point a WAF at the LS host (default UDP/TCP 5141).
2. `elk-listen capture --vendor barracuda-waf --seconds 300` to grab samples.
3. `elk-listen analyze` to bootstrap a grok filter.
4. Iterate with `elk-listen test` until parses look right.
5. Build dashboards in Kibana against `barracuda-waf-*`.
6. `elk-template export --vendor barracuda-waf --name barracuda-waf-X.Y.Z`
   bundles everything back into this directory.

## Reference
Add product docs links here as they're found and verified.
