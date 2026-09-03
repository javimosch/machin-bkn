#!/bin/bash
# Drive one implementation through the scenario set and emit one JSON object
# per scenario on stdout, plus process metrics.
#
# Usage: BIN=<path> BKN_DATA=<db> PORT=<n> NAME=<label> ./run.sh
set -euo pipefail
: "${BIN:?}" "${BKN_DATA:?}" "${PORT:?}" "${NAME:?}"
LOAD=${LOAD:-/tmp/bench-load}
CONC=${CONC:-8}
DUR=${DUR:-5s}
TOK=bench-admin
B="http://127.0.0.1:$PORT"
export BKN_DATA BKN_PORT=$PORT BKN_ADMIN_TOKEN=$TOK
export BKN_AUTH_SECRET=${BKN_AUTH_SECRET:-bench-secret}
export BKN_ENCRYPTION_KEY=${BKN_ENCRYPTION_KEY:-0000000000000000000000000000000000000000000000000000000000000000}

# Cold start is measured as the wall time from exec to the first answered
# request, which is what a scale-to-zero platform actually pays.
T0=$(date +%s%N)
"$BIN" serve >/tmp/bench-$NAME.log 2>&1 &
PID=$!
for _ in $(seq 1 2000); do
  curl -sf -o /dev/null -H "Authorization: Bearer $TOK" "$B/v1/kv/dog.name" && break
  sleep 0.005
done
T1=$(date +%s%N)
START_MS=$(( (T1 - T0) / 1000000 ))

cleanup() { kill $PID 2>/dev/null || true; wait $PID 2>/dev/null || true; }
trap cleanup EXIT

rss() { awk '/^VmRSS:/{print $2}' /proc/$PID/status 2>/dev/null || echo 0; }
IDLE_RSS=$(rss)

# The blob upload lives here, not in setup.sh, because the MFL CLI has no
# `files put` — over HTTP both implementations take the same request.
# Deleted first so a re-run is idempotent: Go refuses to overwrite an existing
# name (MFL allows it), which failed the second run of this harness.
curl -s -o /dev/null -X DELETE -H "Authorization: Bearer $TOK" "$B/v1/files/benchns/blob.bin"
curl -sf -X POST -H "Authorization: Bearer $TOK" -H 'Content-Type: application/octet-stream' \
  --data-binary @/tmp/bench-blob.bin "$B/v1/files/benchns/blob.bin" >/dev/null

# Refuse to benchmark a fixture that is not there. An earlier version of this
# harness would happily have reported the throughput of 404s.
for probe in "/v1/kv/dog.name" "/v1/store/dog/products/p42" "/v1/files/benchns/blob.bin" "/v1/hooks/bench?locale=en"; do
  c=$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $TOK" "$B$probe")
  [ "$c" = "200" ] || { echo "fixture check failed: $probe -> $c" >&2; exit 1; }
done
SUM=$(curl -s -H "Authorization: Bearer $TOK" "$B/v1/files/benchns/blob.bin" | sha256sum | cut -c1-12)
# The hook body is recorded so the comparison can prove both servers produced
# the same answer, not just that both answered quickly.
HOOK=$(curl -s "$B/v1/hooks/bench?locale=en" | python3 -c 'import json,sys;b=json.load(sys.stdin);print(b.get("tag",""),b.get("n",""))')
NDOC=$(curl -s -H "Authorization: Bearer $TOK" "$B/v1/store/dog/products?limit=1000" \
        | python3 -c 'import json,sys;d=json.load(sys.stdin);print(len(d.get("records") or d.get("documents") or d.get("docs") or []))')

run() { # run <label> <method> <url> [body] [extra-header]
  local label=$1 method=$2 url=$3 body=${4:-} hdr=${5:-}
  local args=(-label "$label" -method "$method" -url "$B$url" -c "$CONC" -d "$DUR"
              -H "Authorization: Bearer $TOK")
  [ -n "$body" ] && args+=(-body "$body" -H "Content-Type: application/json")
  [ -n "$hdr" ] && args+=(-H "$hdr")
  "$LOAD" "${args[@]}" | python3 -c "
import json,sys
o=json.load(sys.stdin); o['impl']='$NAME'; print(json.dumps(o))"
}

run "kv-get"      GET  "/v1/kv/dog.name"
run "store-get"   GET  "/v1/store/dog/products/p42"
run "store-list"  GET  "/v1/store/dog/products?limit=20"
run "store-query" GET  "/v1/store/dog/products?price=gt:20&order_by=price&limit=20"
run "store-write" POST "/v1/store/dog/products?id=benchw" '{"name":"w","price":1,"stock":1,"status":"live"}'
run "file-64k"    GET  "/v1/files/benchns/blob.bin"
run "hook-script" GET  "/v1/hooks/bench?locale=en"

LOAD_RSS=$(rss)
python3 -c "
import json
print(json.dumps({'impl':'$NAME','label':'_process','start_ms':$START_MS,
 'idle_rss_kb':$IDLE_RSS,'load_rss_kb':$LOAD_RSS,'blob_sha12':'$SUM','docs':$NDOC,'hook':'$HOOK'}))"
