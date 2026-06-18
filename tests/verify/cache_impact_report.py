#!/usr/bin/env python3
"""
Cache-Control impact report for Barracuda WaaS static content.

Queries Elasticsearch and simulates the bandwidth and request savings
that would result from adding Cache-Control: max-age=<TTL> to all
static assets (images, JS, CSS, fonts).

Methodology
-----------
For each static asset path, ES returns:
  - total_requests  : total hits for that path
  - unique_clients  : cardinality of source.ip for that path

The delta (total_requests - unique_clients) is the estimated number of
repeat requests from the same client within the capture window — i.e.,
requests that would be served from browser cache with a sufficiently
long max-age, eliminating both the origin request and the bandwidth.

This is a conservative lower-bound estimate:
  - unique_clients is approximate (ES cardinality ± ~3%)
  - Bots/crawlers with many unique IPs reduce the apparent repeat rate
  - A longer TTL than the capture window improves real-world savings further

Usage:
    python3 cache_impact_report.py <es_url> <password> [unit_name] [--ttl 7200]

    es_url     https://elk.waaslab.com:9200  (or internal IP)
    password   elastic user password
    unit_name  waas.unit_name value to filter (default: all apps)
    --ttl      max-age in seconds for the headline (informational only)

Example:
    python3 cache_impact_report.py https://10.10.24.233:9200 y5nQ=A_QP3jzeD3LaH50 Lightology
"""

import sys
import json
import ssl
import urllib.request
import urllib.error
import base64
import argparse
from datetime import datetime, timezone

# ── helpers ──────────────────────────────────────────────────────────────────

def es(method, url, password, body=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    creds = base64.b64encode(f"elastic:{password}".encode()).decode()
    req.add_header("Authorization", f"Basic {creds}")
    req.add_header("Content-Type", "application/json")
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    with urllib.request.urlopen(req, context=ctx) as r:
        return json.loads(r.read())

def mb(b):
    return round(b / 1_048_576, 1)

def gb(b):
    return round(b / 1_073_741_824, 2)

def pct(n, d):
    return round(n * 100 / d, 1) if d else 0.0

def hr(n):
    return f"{n:,}"

# ── static content filter clauses ────────────────────────────────────────────

IMAGE_CLAUSES = [
    {"wildcard": {"url.path": f"*.{ext}"}}
    for ext in ["jpg", "jpeg", "png", "gif", "svg", "webp", "ico", "avif"]
] + [{"wildcard": {"url.path": "/img/*"}}]

JS_CLAUSE    = {"wildcard": {"url.path": "*.js"}}
CSS_CLAUSE   = {"wildcard": {"url.path": "*.css"}}
FONT_CLAUSES = [
    {"wildcard": {"url.path": f"*.{ext}"}} for ext in ["woff", "woff2", "ttf"]
]

ALL_STATIC = IMAGE_CLAUSES + [JS_CLAUSE, CSS_CLAUSE] + FONT_CLAUSES

def type_filter(clauses):
    return {"bool": {"should": clauses, "minimum_should_match": 1}}

# ── queries ───────────────────────────────────────────────────────────────────

def query_totals(es_url, password, unit_filter):
    body = {
        "size": 0,
        "query": unit_filter,
        "aggs": {
            "all_traffic": {
                "filter": {"match_all": {}},
                "aggs": {
                    "total_bytes":   {"sum":        {"field": "http.response.body.bytes"}},
                    "status_200":    {"filter":     {"term": {"http.response.status_code": 200}}},
                    "status_304":    {"filter":     {"term": {"http.response.status_code": 304}}},
                    "ts_min":        {"min":        {"field": "@timestamp"}},
                    "ts_max":        {"max":        {"field": "@timestamp"}},
                }
            },
            "all_static": {
                "filter": type_filter(ALL_STATIC),
                "aggs": {
                    "total_bytes":     {"sum":       {"field": "http.response.body.bytes"}},
                    "unique_clients":  {"cardinality":{"field": "source.ip", "precision_threshold": 5000}},
                    "status_304":      {"filter":    {"term": {"http.response.status_code": 304}}},
                }
            },
            "images": {
                "filter": type_filter(IMAGE_CLAUSES),
                "aggs": {
                    "total_bytes":    {"sum":        {"field": "http.response.body.bytes"}},
                    "avg_bytes":      {"avg":        {"field": "http.response.body.bytes"}},
                    "unique_clients": {"cardinality":{"field": "source.ip", "precision_threshold": 5000}},
                }
            },
            "javascript": {
                "filter": JS_CLAUSE,
                "aggs": {
                    "total_bytes":    {"sum":        {"field": "http.response.body.bytes"}},
                    "avg_bytes":      {"avg":        {"field": "http.response.body.bytes"}},
                    "unique_clients": {"cardinality":{"field": "source.ip", "precision_threshold": 5000}},
                }
            },
            "css": {
                "filter": CSS_CLAUSE,
                "aggs": {
                    "total_bytes":    {"sum":        {"field": "http.response.body.bytes"}},
                    "avg_bytes":      {"avg":        {"field": "http.response.body.bytes"}},
                    "unique_clients": {"cardinality":{"field": "source.ip", "precision_threshold": 5000}},
                }
            },
            "fonts": {
                "filter": type_filter(FONT_CLAUSES),
                "aggs": {
                    "total_bytes":    {"sum":        {"field": "http.response.body.bytes"}},
                    "avg_bytes":      {"avg":        {"field": "http.response.body.bytes"}},
                    "unique_clients": {"cardinality":{"field": "source.ip", "precision_threshold": 5000}},
                }
            },
        }
    }
    url = f"{es_url}/logs-barracuda.waas.access-default/_search"
    r = es("POST", url, password, body)
    return r["aggregations"], r["hits"]["total"]["value"]

def query_top_assets(es_url, password, unit_filter, n=100):
    """Per-asset repeat rate for JS/CSS — the most reliable cacheable estimate."""
    body = {
        "size": 0,
        "query": {
            "bool": {
                "must": [unit_filter],
                "should": [JS_CLAUSE, CSS_CLAUSE] + FONT_CLAUSES,
                "minimum_should_match": 1,
            }
        },
        "aggs": {
            "assets": {
                "terms": {"field": "url.path", "size": n, "order": {"_count": "desc"}},
                "aggs": {
                    "unique_clients": {"cardinality": {"field": "source.ip", "precision_threshold": 2000}},
                    "total_bytes":    {"sum": {"field": "http.response.body.bytes"}},
                    "avg_bytes":      {"avg": {"field": "http.response.body.bytes"}},
                }
            }
        }
    }
    url = f"{es_url}/logs-barracuda.waas.access-default/_search"
    r = es("POST", url, password, body)
    return r["aggregations"]["assets"]["buckets"]

def query_top_image_assets(es_url, password, unit_filter, n=50):
    """Per-asset stats for top images."""
    body = {
        "size": 0,
        "query": {
            "bool": {
                "must": [unit_filter],
                "should": IMAGE_CLAUSES,
                "minimum_should_match": 1,
            }
        },
        "aggs": {
            "assets": {
                "terms": {"field": "url.path", "size": n, "order": {"_count": "desc"}},
                "aggs": {
                    "unique_clients": {"cardinality": {"field": "source.ip", "precision_threshold": 2000}},
                    "total_bytes":    {"sum": {"field": "http.response.body.bytes"}},
                    "avg_bytes":      {"avg": {"field": "http.response.body.bytes"}},
                }
            }
        }
    }
    url = f"{es_url}/logs-barracuda.waas.access-default/_search"
    r = es("POST", url, password, body)
    return r["aggregations"]["assets"]["buckets"]

# ── simulation ────────────────────────────────────────────────────────────────

def simulate(total_requests, unique_clients, total_bytes, avg_bytes):
    """
    Estimate cacheable requests and bytes within a single capture window.
    Cacheable = requests that come from the same client after the first fetch.
    Lower-bound: uses unique_clients as a proxy for first-request count.
    """
    first_requests  = min(unique_clients, total_requests)
    cacheable_reqs  = max(0, total_requests - first_requests)
    cacheable_bytes = int(cacheable_reqs * (avg_bytes or 0))
    cache_pct       = pct(cacheable_reqs, total_requests)
    return cacheable_reqs, cacheable_bytes, cache_pct

def simulate_from_assets(buckets):
    """Per-asset simulation — more accurate for JS/CSS shared across all pages."""
    total_reqs  = 0
    total_cache = 0
    total_bytes = 0
    total_cbytes = 0
    for b in buckets:
        reqs        = b["doc_count"]
        unique      = b["unique_clients"]["value"]
        avg_b       = b["avg_bytes"]["value"] or 0
        cacheable   = max(0, reqs - unique)
        total_reqs  += reqs
        total_cache += cacheable
        total_bytes += b["total_bytes"]["value"] or 0
        total_cbytes += int(cacheable * avg_b)
    return total_reqs, total_cache, total_bytes, total_cbytes

# ── report ────────────────────────────────────────────────────────────────────

def render(aggs, total_hits, jscss_buckets, image_buckets, ttl, unit_name):
    at  = aggs["all_traffic"]
    ast = aggs["all_static"]
    img = aggs["images"]
    js  = aggs["javascript"]
    css = aggs["css"]
    fnt = aggs["fonts"]

    total_requests   = at["doc_count"] if "doc_count" in at else total_hits
    total_bytes_all  = at["total_bytes"]["value"] or 0
    total_304_all    = at["status_304"]["doc_count"]

    static_requests  = ast["doc_count"]
    static_bytes     = ast["total_bytes"]["value"] or 0
    static_304       = ast["status_304"]["doc_count"]

    # Per-asset simulation for JS/CSS/fonts (most accurate)
    jscss_total, jscss_cache, jscss_bytes, jscss_cbytes = simulate_from_assets(jscss_buckets)

    # Per-asset simulation for top images
    img_pa_total, img_pa_cache, img_pa_bytes, img_pa_cbytes = simulate_from_assets(image_buckets)
    # Scale per-asset image result to full image set
    img_total    = img["doc_count"]
    img_bytes_all = img["total_bytes"]["value"] or 0
    img_avg_b    = img["avg_bytes"]["value"] or 0
    if img_pa_total > 0:
        img_cache_pct = img_pa_cache / img_pa_total
    else:
        img_cache_pct = 0.0
    img_cache  = int(img_total * img_cache_pct)
    img_cbytes = int(img_cache * img_avg_b)

    # Font simulation (type-level, few assets)
    fnt_c, fnt_cb, _ = simulate(
        fnt["doc_count"],
        fnt["unique_clients"]["value"],
        fnt["total_bytes"]["value"] or 0,
        fnt["avg_bytes"]["value"] or 0,
    )

    total_cache_reqs  = jscss_cache + img_cache + fnt_c
    total_cache_bytes = jscss_cbytes + img_cbytes + fnt_cb

    now = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC")

    lines = []
    def p(s=""): lines.append(s)

    p("=" * 72)
    p(f"  Cache-Control Impact Report — max-age={ttl}s ({ttl//3600}h)")
    p(f"  App: {unit_name or 'all WaaS apps'}")
    p(f"  Generated: {now}")
    p("=" * 72)

    p()
    p("DATASET")
    p(f"  Total requests       : {hr(total_requests)}")
    p(f"  Total bandwidth      : {gb(total_bytes_all)} GB")
    p(f"  Existing 304s (all)  : {hr(total_304_all)}  ({pct(total_304_all, total_requests)}% browser cache hits)")
    p()

    p("STATIC CONTENT — CURRENT")
    p(f"  {'Type':<14} {'Requests':>10}  {'% of total':>10}  {'Bandwidth':>10}  {'Avg size':>10}")
    p(f"  {'-'*14} {'-'*10}  {'-'*10}  {'-'*10}  {'-'*10}")

    rows = [
        ("Images",     img["doc_count"], img_bytes_all, img_avg_b),
        ("JavaScript", js["doc_count"],  js["total_bytes"]["value"] or 0, js["avg_bytes"]["value"] or 0),
        ("CSS",        css["doc_count"], css["total_bytes"]["value"] or 0, css["avg_bytes"]["value"] or 0),
        ("Fonts",      fnt["doc_count"], fnt["total_bytes"]["value"] or 0, fnt["avg_bytes"]["value"] or 0),
    ]
    for label, reqs, tbytes, avg_b in rows:
        p(f"  {label:<14} {hr(reqs):>10}  {pct(reqs, total_requests):>9}%  {mb(tbytes):>8.1f} MB  {avg_b/1024:>8.1f} KB")
    p(f"  {'TOTAL static':<14} {hr(static_requests):>10}  {pct(static_requests, total_requests):>9}%  {mb(static_bytes):>8.1f} MB")
    p(f"  {'  of which 304':<14} {hr(static_304):>10}  {pct(static_304, static_requests):>9}%  (browser cache already working)")
    p()

    p("SIMULATION — Cache-Control: max-age={} ({}h)".format(ttl, ttl // 3600))
    p("  Method: (total_requests - unique_clients) per asset = repeat requests")
    p("          that would be served from browser cache.")
    p()
    p(f"  {'Type':<14} {'Cacheable req':>13}  {'Cache %':>8}  {'BW saved':>10}")
    p(f"  {'-'*14} {'-'*13}  {'-'*8}  {'-'*10}")

    jscss_reqs = js["doc_count"] + css["doc_count"]
    p(f"  {'Images':<14} {hr(img_cache):>13}  {pct(img_cache, img_total):>7}%  {mb(img_cbytes):>8.1f} MB")
    p(f"  {'JS + CSS':<14} {hr(jscss_cache):>13}  {pct(jscss_cache, jscss_total):>7}%  {mb(jscss_cbytes):>8.1f} MB")
    p(f"  {'Fonts':<14} {hr(fnt_c):>13}  {pct(fnt_c, fnt['doc_count']):>7}%  {mb(fnt_cb):>8.1f} MB")
    p(f"  {'TOTAL':<14} {hr(total_cache_reqs):>13}  {pct(total_cache_reqs, static_requests):>7}%  {mb(total_cache_bytes):>8.1f} MB")
    p()

    p("PROJECTED IMPACT")
    p(f"  Static requests eliminated  : {hr(total_cache_reqs)}"
      f"  ({pct(total_cache_reqs, static_requests)}% of static,"
      f" {pct(total_cache_reqs, total_requests)}% of all traffic)")
    p(f"  Static bandwidth saved      : {mb(total_cache_bytes):.0f} MB"
      f"  ({pct(total_cache_bytes, static_bytes):.0f}% of static bandwidth)")
    p(f"  Total bandwidth saved       : {mb(total_cache_bytes):.0f} MB"
      f"  ({pct(total_cache_bytes, total_bytes_all):.1f}% of all bandwidth)")
    p()
    p("  Combined with existing 304s:")
    combined_cache = total_cache_reqs + static_304
    combined_bytes = total_cache_bytes  # 304s already save bytes
    p(f"    Static requests served from cache  : {hr(combined_cache)}"
      f"  ({pct(combined_cache, static_requests):.0f}% of static)")
    p()

    # Top wasted assets
    top_waste = sorted(
        [b for b in jscss_buckets if b["doc_count"] > 10],
        key=lambda b: max(0, b["doc_count"] - b["unique_clients"]["value"])
                      * (b["avg_bytes"]["value"] or 0),
        reverse=True
    )[:15]

    if top_waste:
        p("TOP 15 JS/CSS ASSETS BY WASTED BANDWIDTH")
        p(f"  {'Path':<55} {'Requests':>8}  {'Cacheable':>9}  {'Wasted MB':>9}")
        p(f"  {'-'*55} {'-'*8}  {'-'*9}  {'-'*9}")
        for b in top_waste:
            reqs      = b["doc_count"]
            unique    = b["unique_clients"]["value"]
            cacheable = max(0, reqs - unique)
            avg_b     = b["avg_bytes"]["value"] or 0
            wasted    = cacheable * avg_b / 1_048_576
            path      = b["key"]
            if len(path) > 55:
                path = "..." + path[-52:]
            p(f"  {path:<55} {hr(reqs):>8}  {hr(cacheable):>9}  {wasted:>9.1f}")
        p()

    top_img_waste = sorted(
        [b for b in image_buckets if b["doc_count"] > 5],
        key=lambda b: max(0, b["doc_count"] - b["unique_clients"]["value"])
                      * (b["avg_bytes"]["value"] or 0),
        reverse=True
    )[:10]

    if top_img_waste:
        p("TOP 10 IMAGES BY WASTED BANDWIDTH")
        p(f"  {'Path':<55} {'Requests':>8}  {'Cacheable':>9}  {'Wasted MB':>9}")
        p(f"  {'-'*55} {'-'*8}  {'-'*9}  {'-'*9}")
        for b in top_img_waste:
            reqs      = b["doc_count"]
            unique    = b["unique_clients"]["value"]
            cacheable = max(0, reqs - unique)
            avg_b     = b["avg_bytes"]["value"] or 0
            wasted    = cacheable * avg_b / 1_048_576
            path      = b["key"]
            if len(path) > 55:
                path = "..." + path[-52:]
            p(f"  {path:<55} {hr(reqs):>8}  {hr(cacheable):>9}  {wasted:>9.1f}")
        p()

    p("NOTES")
    p(f"  1. 'Cacheable' = requests from clients that already fetched the asset")
    p(f"     within the capture window. These would return from browser cache")
    p(f"     and generate zero origin requests and zero bandwidth.")
    p(f"  2. Estimate is conservative: bots (ClaudeBot, SleepBot, MetaCrawler,")
    p(f"     Googlebot) each use unique IPs and inflate unique_client counts,")
    p(f"     reducing the apparent repeat rate. Human user savings are higher.")
    p(f"  3. Existing WaaS cache hits are not double-counted: those requests")
    p(f"     already avoid origin but still count as WaaS requests and bandwidth.")
    p(f"     Browser caching eliminates the WaaS request entirely.")
    p(f"  4. Recommended header: Cache-Control: public, max-age={ttl}, immutable")
    p(f"     'immutable' prevents conditional revalidation on browser reload,")
    p(f"     further reducing 304 round-trips.")
    p()
    p("=" * 72)

    return "\n".join(lines)

# ── main ──────────────────────────────────────────────────────────────────────

def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("es_url",   help="Elasticsearch base URL (https://host:9200)")
    ap.add_argument("password", help="elastic user password")
    ap.add_argument("unit_name", nargs="?", default=None, help="waas.unit_name to filter")
    ap.add_argument("--ttl", type=int, default=7200, help="Cache-Control max-age in seconds (default 7200)")
    args = ap.parse_args()

    unit_filter = (
        {"term": {"waas.unit_name": args.unit_name}}
        if args.unit_name else {"match_all": {}}
    )

    print(f"Querying {args.es_url} ...", file=sys.stderr)
    aggs, total_hits = query_totals(args.es_url, args.password, unit_filter)

    print("Fetching per-asset JS/CSS stats ...", file=sys.stderr)
    jscss_buckets = query_top_assets(args.es_url, args.password, unit_filter, n=200)

    print("Fetching per-asset image stats ...", file=sys.stderr)
    image_buckets = query_top_image_assets(args.es_url, args.password, unit_filter, n=200)

    report = render(aggs, total_hits, jscss_buckets, image_buckets, args.ttl, args.unit_name)
    print(report)

if __name__ == "__main__":
    main()
