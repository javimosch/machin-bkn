#!/bin/bash
# demo-probe — catch demo staleness in days, not weeks (issue #18).
#
# The public demo is deployed by hand, and twice it has silently fallen
# behind main: first missing org self-service provisioning (#7), then missing
# GET /v1/collections, so machin-365 sync discovery 404'd against it (#18).
# /version carries no commit, so the only honest staleness signal is
# behavioral: does the deployment answer the routes main serves?
#
# This probes the PUBLIC surface only — no credentials, nothing mutated. Each
# check names the route class it guards; when a new public route lands on
# main, add it here or the probe cannot see its absence. A stale build answers
# "no such route" where a current one answers a resource-level error.
#
#   ./test/demo-probe.sh [url]        # default: the demo instance
#
# Exits non-zero when any probe fails. Run from CI on a schedule
# (.github/workflows/demo-probe.yml), by hand before/after a deploy, or as
# the cheap first half of a redeploy checklist.
set -u

URL="${1:-https://machin-bkn.vps1.intrane.fr}"
PASS=0; FAIL=0

# probe <label> <expected-substring> <curl args...>
# The response body must contain the expected substring. "no such route"
# never appears in a passing answer: it is the signature of a build that
# predates the route entirely.
probe() {
  local label="$1" want="$2"; shift 2
  local body code
  body=$(curl -s -m 20 "$@" 2>/dev/null)
  code=$?
  if [ $code -ne 0 ]; then
    FAIL=$((FAIL+1)); printf "   \033[31mFAIL\033[0m %-44s transport error\n" "$label"; return
  fi
  if echo "$body" | grep -q "no such route"; then
    FAIL=$((FAIL+1)); printf "   \033[31mFAIL\033[0m %-44s route missing — demo is stale\n" "$label"; return
  fi
  if ! echo "$body" | grep -q "$want"; then
    FAIL=$((FAIL+1)); printf "   \033[31mFAIL\033[0m %-44s got: %s\n" "$label" "$(echo "$body" | head -c 90)"; return
  fi
  PASS=$((PASS+1)); printf "   \033[32mok\033[0m   %-44s\n" "$label"
}

echo "=== demo probe: $URL ==="

# The open surface: liveness, identity, documentation.
probe "GET /_health"            '"ok":true'            "$URL/_health"
probe "GET /version"            '"tool":"bkn"'         "$URL/version"
probe "GET /guide"              '"guide"'              "$URL/guide"
probe "GET /llms.txt"           'bkn'                  "$URL/llms.txt"

# The route whose absence proved the Nov-16 staleness: suite sync discovery
# probes this before any credential exists, so it must answer ok:true
# anonymously. A "no such route" here means the demo predates #12/#13.
probe "GET /v1/collections"     '"ok":true'            "$URL/v1/collections"

# The /v1 routers, proven mounted by their resource-level refusals — a stale
# build that never grew the subtree answers "no such route" instead.
probe "POST /v1/auth/login"     'bad_credentials' \
  -X POST -H 'Content-Type: application/json' -d '{}' "$URL/v1/auth/login"
probe "GET /v1/store/<ns>/<c>"  'forbidden' \
  "$URL/v1/store/demo-probe/coll"
probe "GET /v1/kv/<key>"        'key not found'        "$URL/v1/kv/demo-probe-key"
probe "GET /v1/events"          'not_authenticated'    "$URL/v1/events"

echo "   [$PASS passed, $FAIL failed]"
[ "$FAIL" -eq 0 ]
