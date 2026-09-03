#!/bin/bash
# The concurrency gate.
#
# The 113-assertion acceptance suite is 113 sequential curls. It certified a
# build that died at concurrency 2 on a public hook route (a use-after-free in
# the id minter) and answered 500 to half of concurrent hook requests (a run
# context kept in process globals). Neither could be seen by a suite that never
# issues two requests at once, and neither `machin check` nor `--race-safe`
# caught them either. This closes that hole.
#
# It asserts three things per route class, at concurrency 8:
#   - every request answered 2xx
#   - no request failed at the transport (a dead server refuses connections)
#   - the process is still alive afterwards
#
# Usage: ./test/concurrency.sh [path-to-binary]     (default: builds one)
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
BIN=${1:-}
PORT=${PORT:-48950}
DUR=${DUR:-4s}
CONC=${CONC:-8}
DB=$(mktemp /tmp/bkn-conc-XXXX.db)
TOK=conc-admin
B="http://127.0.0.1:$PORT"
PASS=0; FAIL=0

if [ -z "$BIN" ]; then
  BIN=$(mktemp /tmp/mbkn-conc-XXXX)
  echo "building $BIN ..."
  "$ROOT/build.sh" cmd/serve.mfl -o "$BIN" >/tmp/conc-build.log 2>&1 || { echo "build failed"; cat /tmp/conc-build.log; exit 1; }
fi

LOAD=$(mktemp /tmp/conc-load-XXXX)
( cd "$ROOT/bench" && go build -o "$LOAD" load.go ) || { echo "cannot build the load generator"; exit 1; }

export BKN_DATA=$DB BKN_AUTH_SECRET=conc-secret
export BKN_ENCRYPTION_KEY=0000000000000000000000000000000000000000000000000000000000000000

# Fixture. Kept small on purpose: this gate is about survival under overlap,
# not about throughput, so it should run in well under a minute.
"$BIN" kv set conc.name "Ada" >/dev/null || { echo "seed failed"; exit 1; }
for i in 1 2 3 4 5 6 7 8 9 10; do
  "$BIN" store put conc/items --id "i$i" --data "{\"n\":$i,\"status\":\"live\"}" >/dev/null
done
"$BIN" files ns create concns --allow-type application/octet-stream --public >/dev/null
"$BIN" store put i18n/bundles --id en --data @"$ROOT/scripts/seed/i18n-en.json" >/dev/null
"$BIN" script create conchook --file "$ROOT/bench/bench-hook.js" >/dev/null
# A rate limit high enough that the limiter never fires: a 429 here would be
# the gate testing its own fixture rather than the server.
"$BIN" hooks create conchook --script conchook --rate-limit 1000000 >/dev/null

BKN_PORT=$PORT BKN_ADMIN_TOKEN=$TOK "$BIN" serve >/tmp/conc-server.log 2>&1 &
SRV=$!
cleanup() { kill $SRV 2>/dev/null; rm -f "$DB" "$DB-shm" "$DB-wal" "$LOAD"; }
trap cleanup EXIT

for _ in $(seq 1 400); do
  curl -sf -o /dev/null -H "Authorization: Bearer $TOK" "$B/v1/kv/conc.name" && break
  sleep 0.01
done

head -c 4096 /dev/urandom > /tmp/conc-blob.bin
curl -sf -X POST -H "Authorization: Bearer $TOK" -H 'Content-Type: application/octet-stream' \
  --data-binary @/tmp/conc-blob.bin "$B/v1/files/concns/b.bin" >/dev/null

hit() { # hit <label> <method> <path> [body]
  local label=$1 method=$2 path=$3 body=${4:-}
  local args=(-label "$label" -method "$method" -url "$B$path" -c "$CONC" -d "$DUR" -warmup 0s
              -H "Authorization: Bearer $TOK")
  [ -n "$body" ] && args+=(-body "$body" -H "Content-Type: application/json")
  local out; out=$("$LOAD" "${args[@]}" 2>/dev/null)
  local n e b
  n=$(echo "$out" | python3 -c 'import json,sys;print(json.load(sys.stdin)["requests"])' 2>/dev/null)
  e=$(echo "$out" | python3 -c 'import json,sys;print(json.load(sys.stdin)["errors"])'   2>/dev/null)
  b=$(echo "$out" | python3 -c 'import json,sys;print(json.load(sys.stdin)["non2xx"])'   2>/dev/null)
  local alive=dead; kill -0 $SRV 2>/dev/null && alive=alive
  if [ "$alive" = alive ] && [ "${e:-1}" = 0 ] && [ "${b:-1}" = 0 ] && [ "${n:-0}" -gt 0 ]; then
    PASS=$((PASS+1)); printf "   \033[32mok\033[0m   %-22s %6s requests, 0 failed\n" "$label" "$n"
  else
    FAIL=$((FAIL+1))
    printf "   \033[31mFAIL\033[0m %-22s requests=%s transport_errors=%s non2xx=%s server=%s\n" \
      "$label" "${n:-?}" "${e:-?}" "${b:-?}" "$alive"
    [ "$alive" = dead ] && { echo "   server died -- remaining classes skipped"; tail -5 /tmp/conc-server.log; return 1; }
  fi
  return 0
}

echo "=== concurrency: every route class at c=$CONC for $DUR ==="
hit "kv read"      GET  "/v1/kv/conc.name"                    || true
hit "store read"   GET  "/v1/store/conc/items/i5"             || true
hit "store list"   GET  "/v1/store/conc/items?limit=5"        || true
hit "store write"  POST "/v1/store/conc/items?id=cw" '{"n":1,"status":"live"}' || true
hit "file read"    GET  "/v1/files/concns/b.bin"              || true
hit "script (hook)" GET "/v1/hooks/conchook?locale=en"        || true

# Minting ids from several connections at once is its own assertion: the
# use-after-free that started all this lived in newID(), and a duplicate id
# would mean the lock around it is gone even if nothing crashed.
echo "=== id uniqueness under concurrent writes ==="
rm -f /tmp/conc-ids-*.txt
# One file per worker. Eight processes appending to a single file interleave
# their writes, which mangles lines and undercounts -- the first version of this
# check reported 146 of 200 ids for that reason and would have hidden a real
# shortfall. Explicit pids too: a bare `wait` would also wait on the server
# started above, which never exits.
PIDS=()
for w in 1 2 3 4 5 6 7 8; do
  ( for _ in $(seq 1 25); do
      curl -s -X POST -H "Authorization: Bearer $TOK" -H 'Content-Type: application/json' \
        -d '{"n":1}' "$B/v1/store/conc/minted" >> "/tmp/conc-ids-$w.txt"; echo >> "/tmp/conc-ids-$w.txt"
    done ) &
  PIDS+=($!)
done
wait "${PIDS[@]}"
cat /tmp/conc-ids-*.txt > /tmp/conc-ids.txt
read -r TOTAL UNIQ < <(python3 -c "
import json
ids=[]
for l in open('/tmp/conc-ids.txt'):
    l=l.strip()
    if not l: continue
    try: ids.append(json.loads(l)['record']['id'])
    except Exception: pass
print(len(ids), len(set(ids)))")
WANT=200
if [ "${TOTAL:-0}" = "$WANT" ] && [ "$TOTAL" = "$UNIQ" ]; then
  PASS=$((PASS+1)); printf "   \033[32mok\033[0m   %-22s %6s ids, all unique\n" "id uniqueness" "$TOTAL"
else
  FAIL=$((FAIL+1)); printf "   \033[31mFAIL\033[0m %-22s %s ids of %s expected, %s unique\n" "id uniqueness" "${TOTAL:-?}" "$WANT" "${UNIQ:-?}"
fi

kill -0 $SRV 2>/dev/null && S=alive || S=DEAD
echo "   server after all of it: $S"
[ "$S" = alive ] || FAIL=$((FAIL+1))
echo "   [$PASS passed, $FAIL failed]"
[ "$FAIL" -eq 0 ]
