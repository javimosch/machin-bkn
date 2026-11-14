#!/bin/bash
# Org members self-provision collections. An org-scoped token may PUT an
# org-compatible access policy on a collection nobody has declared — the
# suite story is "signup, install, sync" — but the policy can never reach
# past the caller's own scope, and undeclared data access stays admin-only.
#
#   ./test/org-provision.sh <binary>
set -u
M="${1:?usage: org-provision.sh <binary>}"
WORK=$(mktemp -d); trap 'rm -rf "$WORK"; kill $SRV 2>/dev/null' EXIT
PORT=$((23000 + RANDOM % 9000))
B="http://127.0.0.1:$PORT"
export BKN_DATA="$WORK/bkn.db" BKN_OPEN_SIGNUP=1 BKN_ADMIN_TOKEN=adm
export BKN_AUTH_SECRET=org-provision-secret
export BKN_ENCRYPTION_KEY=0123456789abcdef0123456789abcdef
PASS=0; FAIL=0
chk() { if [ "$2" = "$3" ]; then PASS=$((PASS+1)); printf "   \033[32mok\033[0m   %-46s %s\n" "$1" "$2"
        else FAIL=$((FAIL+1)); printf "   \033[31mFAIL\033[0m %-46s got %s want %s\n" "$1" "$2" "$3"; fi }
j() { python3 -c "import json,sys;d=json.load(sys.stdin);print($1)" 2>/dev/null || echo "PARSE_ERROR"; }

req() { # method path token body -> response body
  local m="$1" p="$2" t="$3" b="$4"
  local args=(-s -X "$m" -H 'Content-Type: application/json')
  [ -n "$t" ] && args+=(-H "Authorization: Bearer $t")
  [ -n "$b" ] && args+=(-d "$b")
  curl "${args[@]}" "$B$p"
}
st() { # method path token body -> http status
  local m="$1" p="$2" t="$3" b="$4"
  local args=(-s -o /dev/null -X "$m" -w '%{http_code}' -H 'Content-Type: application/json')
  [ -n "$t" ] && args+=(-H "Authorization: Bearer $t")
  [ -n "$b" ] && args+=(-d "$b")
  curl "${args[@]}" "$B$p"
}

echo "=== org self-provisioning ==="
"$M" serve --host 127.0.0.1 --port $PORT >"$WORK/srv.log" 2>&1 &
SRV=$!
for _ in $(seq 1 100); do curl -sf "$B/_health" >/dev/null && break; sleep 0.1; done

# --- fixture: two orgs, one member each, plus an orgless login -----------
req POST /v1/auth/register '' '{"email":"alice@example.com","password":"alice-pass-1"}' >/dev/null
ALICE0=$(req POST /v1/auth/login '' '{"email":"alice@example.com","password":"alice-pass-1"}' | j 'd["tokens"]["access_token"]')
req POST /v1/auth/orgs "$ALICE0" '{"slug":"aliceorg","name":"Alice Org"}' >/dev/null
ALICE=$(req POST /v1/auth/login '' '{"email":"alice@example.com","password":"alice-pass-1","org":"aliceorg"}' | j 'd["tokens"]["access_token"]')
ALICE_NOORG=$(req POST /v1/auth/login '' '{"email":"alice@example.com","password":"alice-pass-1"}' | j 'd["tokens"]["access_token"]')

req POST /v1/auth/register '' '{"email":"bob@example.com","password":"bob-pass-123"}' >/dev/null
BOB0=$(req POST /v1/auth/login '' '{"email":"bob@example.com","password":"bob-pass-123"}' | j 'd["tokens"]["access_token"]')
req POST /v1/auth/orgs "$BOB0" '{"slug":"boborg","name":"Bob Org"}' >/dev/null
BOB=$(req POST /v1/auth/login '' '{"email":"bob@example.com","password":"bob-pass-123","org":"boborg"}' | j 'd["tokens"]["access_token"]')

chk "fixture: alice has an org token"  "$([ -n "$ALICE" ] && [ "$ALICE" != "PARSE_ERROR" ] && echo yes || echo no)" "yes"

ORG_POLICY='{"access":{"rules":{"read":"org","create":"org","update":"org","delete":"org"},"org_field":"org"}}'

# --- undeclared stays admin-only for data, even for org members ----------
chk "data on undeclared: POST 403"      "$(st POST /v1/store/m365/tasks "$ALICE" '{"title":"t"}')" "403"
chk "data on undeclared: GET 403"       "$(st GET /v1/store/m365/tasks "$ALICE" '')" "403"
chk "declare without a token 403"       "$(st PUT /v1/store/m365/tasks '' "$ORG_POLICY")" "403"
chk "declare without an org claim 403"  "$(st PUT /v1/store/m365/tasks "$ALICE_NOORG" "$ORG_POLICY")" "403"
chk "declare with no access field 403"  "$(st PUT /v1/store/m365/tasks "$ALICE" '{"normalize":{"title":"trim"}}')" "403"
chk "declare a public policy 403"       "$(st PUT /v1/store/m365/tasks "$ALICE" '{"access":{"rules":{"read":"public"}}}')" "403"
chk "declare a user policy 403"         "$(st PUT /v1/store/m365/tasks "$ALICE" '{"access":{"rules":{"read":"user"}}}')" "403"
chk "org rule without org_field 400"    "$(st PUT /v1/store/m365/tasks "$ALICE" '{"access":{"rules":{"read":"org"}}}')" "400"
chk "unknown verb is a 400"             "$(st PUT /v1/store/m365/tasks "$ALICE" '{"access":{"rules":{"bogus":"org"},"org_field":"org"}}')" "400"

# --- the self-service declaration itself ---------------------------------
chk "org member declares the collection" "$(st PUT /v1/store/m365/tasks "$ALICE" "$ORG_POLICY")" "200"
chk "and it reads back org-scoped"      "$(req PUT /v1/store/m365/tasks "$ALICE" "$ORG_POLICY" | j 'd["collection"]["access"]["rules"]["read"]+"/"+d["collection"]["access"]["org_field"]')" "org/org"
chk "collection GET now answers"        "$(st GET /v1/store/m365/tasks "$ALICE" '')" "200"

# --- scoped data access, both directions ----------------------------------
req POST /v1/store/m365/tasks "$ALICE" '{"title":"alice task"}' >/dev/null
ALICE_LIST=$(req GET '/v1/store/m365/tasks' "$ALICE" '')
chk "alice sees her own write"          "$(echo "$ALICE_LIST" | j 'd["count"]')" "1"
chk "the org was stamped on create"     "$(echo "$ALICE_LIST" | j 'd["records"][0]["org"]')" "aliceorg"
chk "bob sees none of it"               "$(req GET '/v1/store/m365/tasks' "$BOB" '' | j 'd["count"]')" "0"
req POST /v1/store/m365/tasks "$BOB" '{"title":"bob task"}' >/dev/null
chk "alice still sees only hers"        "$(req GET '/v1/store/m365/tasks' "$ALICE" '' | j 'd["count"]')" "1"
ALICE_ID=$(echo "$ALICE_LIST" | j 'd["records"][0]["id"]')
chk "bob cannot read alice's record"    "$(st GET "/v1/store/m365/tasks/$ALICE_ID" "$BOB" '')" "404"
chk "alice can"                         "$(st GET "/v1/store/m365/tasks/$ALICE_ID" "$ALICE" '')" "200"

# --- the ceiling holds after provisioning, not just at first declare ------
chk "re-PUT to public is refused"       "$(st PUT /v1/store/m365/tasks "$ALICE" '{"access":{"rules":{"read":"public","create":"org"},"org_field":"org"}}')" "403"
chk "re-PUT to user is refused"         "$(st PUT /v1/store/m365/tasks "$ALICE" '{"access":{"rules":{"read":"user"}}}')" "403"
chk "re-PUT org-compatible is fine"     "$(st PUT /v1/store/m365/tasks "$ALICE" '{"access":{"rules":{"read":"org","create":"org","update":"org","delete":"admin"},"org_field":"org"}}')" "200"
chk "and it is still org-scoped"        "$(req GET '/v1/store/m365/tasks' "$ALICE" '' | j 'd["count"]')" "1"

# --- an admin-declared policy is not claimable ----------------------------
chk "admin declares a private collection" "$(st PUT /v1/store/ops/private adm '{"access":{"rules":{"read":"admin"}}}')" "200"
chk "member cannot claim it"            "$(st PUT /v1/store/ops/private "$ALICE" '{"access":{"rules":{"read":"org","create":"org"},"org_field":"org"}}')" "403"
chk "member cannot even read it"        "$(st GET /v1/store/ops/private "$ALICE" '')" "403"
chk "admin still reads it"              "$(st GET /v1/store/ops/private adm '')" "200"

# --- create permission does not widen past org scope ----------------------
chk "admin declares create:org only"    "$(st PUT /v1/store/shared/notes adm '{"access":{"rules":{"create":"org"},"org_field":"org"}}')" "200"
chk "member PUT to public refused"      "$(st PUT /v1/store/shared/notes "$ALICE" '{"access":{"rules":{"read":"public"}}}')" "403"
chk "member may still declare org rules" "$(st PUT /v1/store/shared/notes "$ALICE" '{"access":{"rules":{"read":"org","create":"org"},"org_field":"org"}}')" "200"
chk "and now reads are org-scoped"      "$(req POST /v1/store/shared/notes "$BOB" '{"note":"hi"}' >/dev/null; req GET '/v1/store/shared/notes' "$ALICE" '' | j 'd["count"]')" "0"

echo "   [$PASS passed, $FAIL failed]"
[ "$FAIL" -eq 0 ]
