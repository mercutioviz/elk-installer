# shellcheck shell=bash
# lib/kbn_api.sh — Kibana HTTP API helpers (called from the control node).
#
# Talks to Kibana through the nginx-fronted HTTPS endpoint on the target's
# private address (from the inventory). Auth is Basic with `elastic` for
# simplicity in v1 — switch to a dedicated automation user later.
#
# Public functions:
#   kbn::base_url HOST              # echo https://<addr>/
#   kbn::curl HOST [curl_args...]   # auth + kbn-xsrf + -k baked in
#   kbn::ping HOST                  # 200/302 = up
#   kbn::create_data_view HOST ID TITLE TIMEFIELD [NAME]
#   kbn::import_ndjson HOST FILE [OVERWRITE]

if [[ -n "${_ELK_KBN_API_LOADED:-}" ]]; then return 0; fi
_ELK_KBN_API_LOADED=1

# shellcheck source=./common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
# shellcheck source=./inventory.sh
source "$(dirname "${BASH_SOURCE[0]}")/inventory.sh"

kbn::base_url() {
  local host="$1" addr
  addr=$(inventory::host_field "$host" address)
  [[ -n "$addr" ]] || die "kbn: no address for ${host}"
  printf 'https://%s' "$addr"
}

kbn::_pw_for() {
  local host="$1"
  local f="${ELK_REPO_ROOT}/secrets/${host}.elastic.password"
  [[ -s "$f" ]] || die "kbn: no elastic password at ${f}"
  cat "$f"
}

# kbn::curl HOST [curl_args...]
# Forwards the remaining args verbatim; caller passes -X, -d, -F, URL.
kbn::curl() {
  local host="$1"; shift
  local base pw
  base=$(kbn::base_url "$host")
  pw=$(kbn::_pw_for "$host")
  curl -sSk \
    -u "elastic:${pw}" \
    -H "kbn-xsrf: true" \
    -H "Accept: application/json" \
    "$@" \
    --connect-timeout 10
}

kbn::ping() {
  local host="$1"
  local code
  code=$(kbn::curl "$host" -o /dev/null -w '%{http_code}' \
    "$(kbn::base_url "$host")/api/status" 2>/dev/null || echo 000)
  [[ "$code" =~ ^(200|302)$ ]]
}

# Create or update a data view via the data_views API. Idempotent: if it
# exists, DELETE+POST. Cheaper than tracking diffs.
kbn::create_data_view() {
  local host="$1" id="$2" title="$3"
  local timefield="${4:-@timestamp}"
  local name="${5:-$title}"
  local base
  base=$(kbn::base_url "$host")

  log_info "kbn: ensure data view id=${id} title=${title}"

  # DELETE first (404 is fine). We use the "default" space.
  local del_code
  del_code=$(kbn::curl "$host" -o /dev/null -w '%{http_code}' \
    -X DELETE "${base}/api/data_views/data_view/${id}" \
    -d '{}' || true)
  log_debug "kbn: delete returned ${del_code}"

  local body
  body=$(printf '{"data_view":{"id":"%s","name":"%s","title":"%s","timeFieldName":"%s"}}' \
    "$id" "$name" "$title" "$timefield")
  local resp http
  resp=$(mktemp)
  http=$(kbn::curl "$host" \
    -X POST "${base}/api/data_views/data_view" \
    -H 'Content-Type: application/json' \
    -d "$body" \
    -o "$resp" -w '%{http_code}')
  case "$http" in
    200|201)
      log_info "kbn: data view '${id}' ok (${http})"
      rm -f "$resp"
      ;;
    *)
      log_error "kbn: data view '${id}' failed (${http})"
      cat "$resp" >&2
      rm -f "$resp"
      return 1
      ;;
  esac
}

# kbn::import_ndjson HOST FILE [OVERWRITE]
# OVERWRITE: 1 (default) | 0
kbn::import_ndjson() {
  local host="$1" file="$2" overwrite="${3:-1}"
  [[ -s "$file" ]] || die "kbn: ndjson file empty or missing: $file"
  local base
  base=$(kbn::base_url "$host")

  log_info "kbn: importing $(basename "$file") via saved_objects/_import"
  local resp http url
  url="${base}/api/saved_objects/_import"
  (( overwrite == 1 )) && url="${url}?overwrite=true"
  resp=$(mktemp)
  http=$(kbn::curl "$host" \
    -X POST "$url" \
    -F "file=@${file}" \
    -o "$resp" -w '%{http_code}')
  case "$http" in
    200)
      local ok errors
      ok=$(jq -r '.success' "$resp" 2>/dev/null || echo unknown)
      errors=$(jq -r '.errors // [] | length' "$resp" 2>/dev/null || echo 0)
      if [[ "$ok" == "true" && "$errors" == "0" ]]; then
        log_info "kbn: import ok ($(jq -r '.successCount' "$resp" 2>/dev/null) objects)"
        rm -f "$resp"
        return 0
      fi
      log_error "kbn: import returned errors:"
      jq '.errors' "$resp" >&2 2>/dev/null || cat "$resp" >&2
      rm -f "$resp"
      return 1
      ;;
    *)
      log_error "kbn: import HTTP ${http}"
      cat "$resp" >&2
      rm -f "$resp"
      return 1
      ;;
  esac
}
