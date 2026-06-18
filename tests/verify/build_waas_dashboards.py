#!/usr/bin/env python3
"""
Build Kibana dashboards for Barracuda WaaS data.
Two dashboards:
  1. WAF Security Monitor  — attack-focused (uses firewall data stream)
  2. Application Traffic   — traffic-focused (uses access data stream, filters health probes)

Usage:
    python3 build_waas_dashboards.py <kibana_url> <elastic_password>
"""
import sys
import json
import urllib.request
import urllib.error
import base64

def kbn(method, url, password, body=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(
        url,
        data=data,
        method=method,
        headers={
            "Content-Type": "application/json",
            "kbn-xsrf": "true",
            "Authorization": "Basic " + base64.b64encode(
                f"elastic:{password}".encode()).decode(),
        }
    )
    ctx = __import__("ssl").create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = __import__("ssl").CERT_NONE
    try:
        with urllib.request.urlopen(req, context=ctx, timeout=15) as r:
            return json.loads(r.read())
    except urllib.error.HTTPError as e:
        body_text = e.read().decode()
        print(f"  HTTP {e.code} {method} {url}: {body_text[:200]}")
        return None

def create_dv(base, pw, dv_id, title, index_pattern):
    print(f"  data view: {title}")
    resp = kbn("DELETE", f"{base}/api/data_views/data_view/{dv_id}", pw)
    resp = kbn("POST", f"{base}/api/data_views/data_view", pw, {
        "data_view": {
            "id": dv_id, "name": title,
            "title": index_pattern, "timeFieldName": "@timestamp"
        }
    })
    return resp and resp.get("data_view", {}).get("id") == dv_id

def upsert_viz(base, pw, viz_id, title, vis_state, search_source):
    print(f"  viz: {title}")
    kbn("DELETE", f"{base}/api/saved_objects/visualization/{viz_id}", pw)
    body = {
        "attributes": {
            "title": title,
            "visState": json.dumps(vis_state),
            "uiStateJSON": "{}",
            "description": "",
            "kibanaSavedObjectMeta": {
                "searchSourceJSON": json.dumps(search_source)
            }
        }
    }
    resp = kbn("POST", f"{base}/api/saved_objects/visualization/{viz_id}", pw, body)
    return resp is not None

def upsert_dashboard(base, pw, dash_id, title, panels, filters=None):
    print(f"  dashboard: {title}")
    kbn("DELETE", f"{base}/api/saved_objects/dashboard/{dash_id}", pw)
    panels_json = []
    for i, p in enumerate(panels):
        panels_json.append({
            "version": "9.4.2",
            "type": "visualization",
            "gridData": p["grid"],
            "panelIndex": str(i + 1),
            "embeddableConfig": {"enhancements": {}},
            "panelRefName": f"panel_{i+1}"
        })
    refs = [{"name": f"panel_{i+1}", "type": "visualization", "id": p["id"]}
            for i, p in enumerate(panels)]
    body = {
        "attributes": {
            "title": title,
            "hits": 0,
            "description": "",
            "panelsJSON": json.dumps(panels_json),
            "optionsJSON": json.dumps({"useMargins": True, "syncColors": False, "hidePanelTitles": False}),
            "timeRestore": False,
            "kibanaSavedObjectMeta": {
                "searchSourceJSON": json.dumps({
                    "query": {"language": "kuery", "query": ""},
                    "filter": filters or []
                })
            }
        },
        "references": refs
    }
    resp = kbn("POST", f"{base}/api/saved_objects/dashboard/{dash_id}", pw, body)
    return resp is not None

# ── Visualization helpers ───────────────────────────────────────────────────

def metric_vis(dv_id, label, metric_agg="count"):
    return {
        "type": "metric",
        "aggs": [{"id": "1", "enabled": True, "type": metric_agg,
                  "params": {"id": "1", "field": None if metric_agg == "count" else "_id"},
                  "schema": "metric"}],
        "params": {
            "metric": {"percentageMode": False, "useRanges": False,
                       "colorSchema": "Green to Red", "metricColorMode": "None",
                       "colorsRange": [{"from": 0, "to": 10000}],
                       "labels": {"show": True}, "invertColors": False,
                       "style": {"bgFill": "#000", "bgColor": False, "labelColor": False,
                                 "subText": label, "fontSize": 60}},
            "dimensions": {}
        }
    }, {"index": dv_id, "query": {"query": "", "language": "kuery"}, "filter": []}

def pie_vis(dv_id, field, size=8, title=None):
    return {
        "type": "pie",
        "aggs": [
            {"id": "1", "enabled": True, "type": "count", "params": {}, "schema": "metric"},
            {"id": "2", "enabled": True, "type": "terms", "schema": "segment",
             "params": {"field": field, "size": size, "order": "desc", "orderBy": "1",
                        "otherBucket": True, "otherBucketLabel": "Other",
                        "missingBucket": False}}
        ],
        "params": {
            "type": "pie", "addTooltip": True, "addLegend": True,
            "legendPosition": "right", "isDonut": False,
            "labels": {"show": True, "values": True, "last_level": True, "truncate": 100}
        }
    }, {"index": dv_id, "query": {"query": "", "language": "kuery"}, "filter": []}

def hbar_vis(dv_id, field, size=10):
    return {
        "type": "horizontal_bar",
        "aggs": [
            {"id": "1", "enabled": True, "type": "count", "params": {}, "schema": "metric"},
            {"id": "2", "enabled": True, "type": "terms", "schema": "segment",
             "params": {"field": field, "size": size, "order": "desc", "orderBy": "1",
                        "otherBucket": False}}
        ],
        "params": {
            "type": "histogram",
            "grid": {"categoryLines": False},
            "categoryAxes": [{"id": "CategoryAxis-1", "type": "category",
                              "position": "left", "show": True,
                              "style": {}, "scale": {"type": "linear"},
                              "labels": {"show": True, "rotate": 0, "filter": False, "truncate": 200},
                              "title": {}}],
            "valueAxes": [{"id": "ValueAxis-1", "name": "LeftAxis-1",
                           "type": "value", "position": "bottom", "show": True,
                           "style": {}, "scale": {"type": "linear", "mode": "normal"},
                           "labels": {"show": True, "rotate": 0, "filter": True, "truncate": 100},
                           "title": {"text": "Count"}}],
            "seriesParams": [{"show": True, "type": "histogram", "mode": "stacked",
                              "data": {"label": "Count", "id": "1"},
                              "valueAxis": "ValueAxis-1",
                              "drawLinesBetweenPoints": True, "lineWidth": 2,
                              "showCircles": True}],
            "addTooltip": True, "addLegend": True, "legendPosition": "right",
            "times": [], "addTimeMarker": False, "maxLegendLines": 1, "truncateLegend": True
        }
    }, {"index": dv_id, "query": {"query": "", "language": "kuery"}, "filter": []}

def area_vis(dv_id, interval="auto"):
    return {
        "type": "area",
        "aggs": [
            {"id": "1", "enabled": True, "type": "count", "params": {}, "schema": "metric"},
            {"id": "2", "enabled": True, "type": "date_histogram", "schema": "segment",
             "params": {"field": "@timestamp", "useNormalizedEsInterval": True,
                        "interval": interval, "drop_partials": False,
                        "min_doc_count": 1, "extended_bounds": {}}}
        ],
        "params": {
            "type": "area", "grid": {"categoryLines": False},
            "categoryAxes": [{"id": "CategoryAxis-1", "type": "category",
                              "position": "bottom", "show": True, "style": {},
                              "scale": {"type": "linear"},
                              "labels": {"show": True, "filter": True, "truncate": 100},
                              "title": {}}],
            "valueAxes": [{"id": "ValueAxis-1", "name": "LeftAxis-1",
                           "type": "value", "position": "left", "show": True,
                           "style": {}, "scale": {"type": "linear", "mode": "normal"},
                           "labels": {"show": True, "rotate": 0, "filter": False, "truncate": 100},
                           "title": {"text": "Count"}}],
            "seriesParams": [{"show": True, "type": "area", "mode": "stacked",
                              "data": {"label": "Count", "id": "1"},
                              "drawLinesBetweenPoints": True, "lineWidth": 2,
                              "interpolate": "linear", "valueAxis": "ValueAxis-1",
                              "showCircles": True}],
            "addTooltip": True, "addLegend": True, "legendPosition": "right",
            "times": [], "addTimeMarker": False, "thresholdLine": {"show": False,
            "value": 10, "width": 1, "style": "full", "color": "#E7664C"}
        }
    }, {"index": dv_id, "query": {"query": "", "language": "kuery"}, "filter": []}

def table_vis(dv_id, field, size=15, extra_metrics=None):
    aggs = [{"id": "1", "enabled": True, "type": "count", "params": {}, "schema": "metric"}]
    if extra_metrics:
        for i, (metric_type, metric_field) in enumerate(extra_metrics, 2):
            aggs.append({"id": str(i), "enabled": True, "type": metric_type,
                         "params": {"field": metric_field}, "schema": "metric"})
    aggs.append({"id": str(len(aggs)+1), "enabled": True, "type": "terms",
                 "schema": "bucket",
                 "params": {"field": field, "size": size, "order": "desc",
                            "orderBy": "1", "otherBucket": False}})
    return {
        "type": "table",
        "aggs": aggs,
        "params": {
            "perPage": 15, "showPartialRows": False, "showMetricsAtAllLevels": False,
            "showTotal": False, "totalFunc": "sum",
            "percentageCol": "", "row": False
        }
    }, {"index": dv_id, "query": {"query": "", "language": "kuery"}, "filter": []}

# ── Main ────────────────────────────────────────────────────────────────────

def main():
    if len(sys.argv) < 3:
        print("Usage: build_waas_dashboards.py <kibana_url> <elastic_password>")
        sys.exit(1)
    base = sys.argv[1].rstrip("/")
    pw = sys.argv[2]

    print("=== Creating data views ===")
    create_dv(base, pw, "elk-waas-firewall",
              "WaaS Firewall Events", "logs-barracuda.waas.firewall-default")
    create_dv(base, pw, "elk-waas-access",
              "WaaS Access Events", "logs-barracuda.waas.access-default")

    # ── Security Dashboard visualizations ─────────────────────────────────
    print("\n=== Building Security visualizations ===")
    DV_F = "elk-waas-firewall"
    # Health-probe filter for the access data view
    HP_FILTER = {"meta": {"type": "phrases", "key": "url.domain",
                          "negate": True, "disabled": False, "alias": "Exclude health probes"},
                 "query": {"bool": {"should": [
                     {"match_phrase": {"url.domain": {"query": "waas-prod-app"}}},
                 ]}}}

    # 1. Total attack events
    vs, ss = metric_vis(DV_F, "WAF Events")
    upsert_viz(base, pw, "waas-sec-total-events", "Total WAF Events", vs, ss)

    # 2. Action breakdown: DENY vs LOG (with explicit note about detection mode)
    vs, ss = pie_vis(DV_F, "waas.action", size=8)
    upsert_viz(base, pw, "waas-sec-actions",
               "WAF Actions: DENY vs LOG (enforcement vs detection mode)", vs, ss)

    # 3. Top attack types
    vs, ss = hbar_vis(DV_F, "waas.attack_type", size=12)
    upsert_viz(base, pw, "waas-sec-attack-types", "Attack Types", vs, ss)

    # 4. Attack timeline
    vs, ss = area_vis(DV_F, "auto")
    upsert_viz(base, pw, "waas-sec-timeline", "Attack Events Over Time", vs, ss)

    # 5. Top attacked URLs
    vs, ss = table_vis(DV_F, "url.path", size=15)
    upsert_viz(base, pw, "waas-sec-top-urls", "Top Attacked URLs", vs, ss)

    # 6. Attack source countries
    vs, ss = hbar_vis(DV_F, "source.geo.country_iso_code", size=15)
    upsert_viz(base, pw, "waas-sec-countries", "Attack Source Countries", vs, ss)

    # 7. Severity breakdown (ALER / NOTI / CRIT)
    vs, ss = pie_vis(DV_F, "waas.severity", size=6)
    upsert_viz(base, pw, "waas-sec-severity", "Attack Severity", vs, ss)

    # 8. Follow-up actions (NONE / CHALLENGE / BLOCK etc.)
    vs, ss = pie_vis(DV_F, "waas.follow_up_action", size=8)
    upsert_viz(base, pw, "waas-sec-followup",
               "WAF Follow-Up Actions (CAPTCHA, block, none)", vs, ss)

    # 9. Top attacking source IPs
    vs, ss = table_vis(DV_F, "source.ip", size=15)
    upsert_viz(base, pw, "waas-sec-src-ips", "Top Attacking Source IPs", vs, ss)

    # 10. Attacked domain breakdown
    vs, ss = pie_vis(DV_F, "url.domain", size=10)
    upsert_viz(base, pw, "waas-sec-domains",
               "Attacks by Protected Application", vs, ss)

    # ── Traffic Dashboard visualizations ──────────────────────────────────
    print("\n=== Building Traffic visualizations ===")
    DV_A = "elk-waas-access"

    # 11. Total requests (with kuery to exclude health probes)
    vs_total = {
        "type": "metric",
        "aggs": [{"id": "1", "enabled": True, "type": "count",
                  "params": {}, "schema": "metric"}],
        "params": {
            "metric": {
                "percentageMode": False, "useRanges": False,
                "colorSchema": "Green to Red", "metricColorMode": "None",
                "colorsRange": [{"from": 0, "to": 10000}],
                "labels": {"show": True},
                "invertColors": False,
                "style": {"bgFill": "#000", "bgColor": False, "labelColor": False,
                          "subText": "App Requests (excl. health probes)", "fontSize": 60}
            },
            "dimensions": {}
        }
    }
    ss_total = {"index": DV_A,
                "query": {"query": 'NOT url.domain:waas-prod-app*', "language": "kuery"},
                "filter": []}
    upsert_viz(base, pw, "waas-tr-total", "Total App Requests", vs_total, ss_total)

    # 12. Requests by application (excl. health probes)
    vs, ss = pie_vis(DV_A, "url.domain", size=10)
    ss["query"] = {"query": "NOT url.domain:waas-prod-app*", "language": "kuery"}
    upsert_viz(base, pw, "waas-tr-by-app", "Requests by Application", vs, ss)

    # 13. HTTP status code distribution
    vs, ss = pie_vis(DV_A, "http.response.status_code", size=10)
    ss["query"] = {"query": "NOT url.domain:waas-prod-app*", "language": "kuery"}
    upsert_viz(base, pw, "waas-tr-status", "HTTP Status Code Distribution", vs, ss)

    # 14. Request timeline (excl. health probes)
    vs, ss = area_vis(DV_A, "auto")
    ss["query"] = {"query": "NOT url.domain:waas-prod-app*", "language": "kuery"}
    upsert_viz(base, pw, "waas-tr-timeline", "Request Volume Over Time", vs, ss)

    # 15. Top pages (Hackazon specific)
    vs, ss = table_vis(DV_A, "url.path", size=20,
                       extra_metrics=[("avg", "http.response.body.bytes"),
                                      ("avg", "waas.time_taken_ms")])
    ss["query"] = {"query": 'url.domain:"www.darklab.cudalabx.net"', "language": "kuery"}
    upsert_viz(base, pw, "waas-tr-top-pages",
               "Top Pages — Hackazon (www.darklab.cudalabx.net)", vs, ss)

    # 16. WAF protection mode (PROTECTED / PASSIVE / UNPROTECTED)
    vs, ss = pie_vis(DV_A, "waas.protected", size=5)
    ss["query"] = {"query": "NOT url.domain:waas-prod-app*", "language": "kuery"}
    upsert_viz(base, pw, "waas-tr-protection",
               "WAF Protection Mode per Request", vs, ss)

    # 17. HTTP methods
    vs, ss = pie_vis(DV_A, "http.request.method", size=8)
    ss["query"] = {"query": "NOT url.domain:waas-prod-app*", "language": "kuery"}
    upsert_viz(base, pw, "waas-tr-methods", "HTTP Methods", vs, ss)

    # 18. Top user agents (abbreviated)
    vs, ss = table_vis(DV_A, "user_agent.original", size=12)
    ss["query"] = {"query": "NOT url.domain:waas-prod-app*", "language": "kuery"}
    upsert_viz(base, pw, "waas-tr-uas", "Top User Agents", vs, ss)

    # ── Dashboards ──────────────────────────────────────────────────────────
    print("\n=== Building dashboards ===")

    # Security dashboard layout (4-column grid, each unit = 4px)
    # w, h are in grid units; 1 col = 6 units wide (total 24)
    sec_panels = [
        # Row 1: 3 metrics + action pie
        {"id": "waas-sec-total-events",    "grid": {"x":0,  "y":0,  "w":6,  "h":8}},
        {"id": "waas-sec-severity",        "grid": {"x":6,  "y":0,  "w":6,  "h":8}},
        {"id": "waas-sec-followup",        "grid": {"x":12, "y":0,  "w":6,  "h":8}},
        {"id": "waas-sec-actions",         "grid": {"x":18, "y":0,  "w":6,  "h":8}},
        # Row 2: timeline full width
        {"id": "waas-sec-timeline",        "grid": {"x":0,  "y":8,  "w":24, "h":10}},
        # Row 3: attack types + countries
        {"id": "waas-sec-attack-types",    "grid": {"x":0,  "y":18, "w":12, "h":12}},
        {"id": "waas-sec-countries",       "grid": {"x":12, "y":18, "w":12, "h":12}},
        # Row 4: top URLs + top IPs + domains
        {"id": "waas-sec-top-urls",        "grid": {"x":0,  "y":30, "w":8,  "h":12}},
        {"id": "waas-sec-src-ips",         "grid": {"x":8,  "y":30, "w":8,  "h":12}},
        {"id": "waas-sec-domains",         "grid": {"x":16, "y":30, "w":8,  "h":12}},
    ]
    upsert_dashboard(base, pw, "waas-security-overview",
                     "WAF Security Monitor", sec_panels)

    # Traffic dashboard layout
    tr_panels = [
        # Row 1: metrics
        {"id": "waas-tr-total",       "grid": {"x":0,  "y":0,  "w":6,  "h":8}},
        {"id": "waas-tr-protection",  "grid": {"x":6,  "y":0,  "w":6,  "h":8}},
        {"id": "waas-tr-methods",     "grid": {"x":12, "y":0,  "w":6,  "h":8}},
        {"id": "waas-tr-by-app",      "grid": {"x":18, "y":0,  "w":6,  "h":8}},
        # Row 2: timeline
        {"id": "waas-tr-timeline",    "grid": {"x":0,  "y":8,  "w":24, "h":10}},
        # Row 3: status + methods
        {"id": "waas-tr-status",      "grid": {"x":0,  "y":18, "w":12, "h":12}},
        {"id": "waas-tr-uas",         "grid": {"x":12, "y":18, "w":12, "h":12}},
        # Row 4: top pages
        {"id": "waas-tr-top-pages",   "grid": {"x":0,  "y":30, "w":24, "h":14}},
    ]
    upsert_dashboard(base, pw, "waas-traffic-overview",
                     "Application Traffic", tr_panels)

    print("\n=== Done ===")
    print("Dashboards created:")
    print(f"  Security: {base}/app/dashboards#/view/waas-security-overview")
    print(f"  Traffic:  {base}/app/dashboards#/view/waas-traffic-overview")

if __name__ == "__main__":
    main()
