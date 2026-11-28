#!/bin/bash
# Bearer validity on the store surface. decideAccess must see a VALID
# credential, not a non-empty header: a garbage bearer used to satisfy every
# 'user' rule outright, and on org-scoped collections it answered 403 — the
# "give up" status — where an expired token needs 401 so clients refresh.
#
#   ./test/store-auth.sh <binary>
set -u
M="${1:?usage: store-auth.sh <binary>}"
WORK=$(mktemp -d); trap 'rm -rf "$WORK"; kill $SRV 2>/dev/null' EXIT
PORT=$((24000 + RANDOM % 9000))
B="http://127.0.0.1:$PORT"
export BKN_DATA="$WORK/bkn.db" BKN_OPEN_SIGNUP=1 BKN_ADMIN_TOKEN=adm
export BKN_AUTH_SECRET=store-auth-secret
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

echo "=== store bearer validity ==="
"$M" serve --host 127.0.0.1 --port $PORT >"$WORK/srv.log" 2>&1 &
SRV=$!
for _ in $(seq 1 100); do curl -sf "$B/_health" >/dev/null && break; sleep 0.1; done

# --- fixture: one user, orgless and org-scoped tokens ---------------------
req POST /v1/auth/register '' '{"email":"alice@example.com","password":"alice-pass-1"}' >/dev/null
ALICE_NOORG=$(req POST /v1/auth/login '' '{"email":"alice@example.com","password":"alice-pass-1"}' | j 'd["tokens"]["access_token"]')
AUID=$(req POST /v1/auth/login '' '{"email":"alice@example.com","password":"alice-pass-1"}' | j 'd["tokens"]["user"]["id"]')
req POST /v1/auth/orgs "$ALICE_NOORG" '{"slug":"aliceorg","name":"Alice Org"}' >/dev/null
ALICE=$(req POST /v1/auth/login '' '{"email":"alice@example.com","password":"alice-pass-1","org":"aliceorg"}' | j 'd["tokens"]["access_token"]')

chk "fixture: orgless token issued"   "$([ -n "$ALICE_NOORG" ] && [ "$ALICE_NOORG" != "PARSE_ERROR" ] && echo yes || echo no)" "yes"
chk "fixture: org token issued"       "$([ -n "$ALICE" ] && [ "$ALICE" != "PARSE_ERROR" ] && echo yes || echo no)" "yes"

# --- admin declares one collection per audience ---------------------------
chk "declare user collection"   "$(st PUT /v1/store/m365/usertest adm '{"access":{"rules":{"read":"user","create":"user","update":"user","delete":"user"}}}')" "200"
chk "declare org collection"    "$(st PUT /v1/store/m365/orgtest adm '{"access":{"rules":{"read":"org","create":"org","update":"org","delete":"org"},"org_field":"org"}}')" "200"
chk "declare owner collection"  "$(st PUT /v1/store/m365/ownertest adm '{"access":{"rules":{"read":"owner","create":"owner","update":"owner","delete":"owner"},"owner_field":"owner"}}')" "200"
chk "declare public collection" "$(st PUT /v1/store/m365/pubtest adm '{"access":{"rules":{"read":"public","create":"public","update":"public","delete":"public"}}}')" "200"
# m365/private stays undeclared: admin-only, and no credential helps.

GARBAGE="garbage.invalid.jwt"
JWTISH="eyJhbGciOiJub25lIn0.eyJzdWIiOiJ4In0.c2ln"

# --- the bug: presence is not validity ------------------------------------
chk "garbage read on user 401"    "$(st GET /v1/store/m365/usertest "$GARBAGE" '')" "401"
chk "garbage write on user 401"   "$(st POST /v1/store/m365/usertest "$GARBAGE" '{"note":"pwned"}')" "401"
chk "garbage read on org 401"     "$(st GET /v1/store/m365/orgtest "$GARBAGE" '')" "401"
chk "garbage write on org 401"    "$(st POST /v1/store/m365/orgtest "$GARBAGE" '{"note":"pwned"}')" "401"
chk "garbage read on owner 401"   "$(st GET /v1/store/m365/ownertest "$GARBAGE" '')" "401"
chk "jwt-shaped garbage 401"      "$(st GET /v1/store/m365/usertest "$JWTISH" '')" "401"
chk "garbage on public still 200" "$(st GET /v1/store/m365/pubtest "$GARBAGE" '')" "200"
chk "garbage on undeclared 403"   "$(st GET /v1/store/m365/private "$GARBAGE" '')" "403"
chk "and nothing was written"     "$(req GET /v1/store/m365/usertest adm '' | j 'd["count"]')" "0"

# --- no credential behaves exactly as before ------------------------------
chk "no token on user 401"        "$(st GET /v1/store/m365/usertest '' '')" "401"
chk "no token on org 401"         "$(st GET /v1/store/m365/orgtest '' '')" "401"

# --- valid credentials are unaffected --------------------------------------
chk "valid user reads user coll"  "$(st GET /v1/store/m365/usertest "$ALICE_NOORG" '')" "200"
chk "valid user writes user coll" "$(st POST /v1/store/m365/usertest "$ALICE_NOORG" '{"note":"mine"}')" "200"
chk "and it reads back"           "$(req GET /v1/store/m365/usertest "$ALICE_NOORG" '' | j 'd["count"]')" "1"
chk "orgless token on org 403"    "$(st GET /v1/store/m365/orgtest "$ALICE_NOORG" '')" "403"
chk "org token reads org coll"    "$(st GET /v1/store/m365/orgtest "$ALICE" '')" "200"
chk "org token writes org coll"   "$(st POST /v1/store/m365/orgtest "$ALICE" '{"note":"org doc"}')" "200"
chk "and the org was stamped"     "$(req GET /v1/store/m365/orgtest "$ALICE" '' | j 'd["records"][0]["org"]')" "aliceorg"
chk "owner token reads owner"     "$(st GET /v1/store/m365/ownertest "$ALICE_NOORG" '')" "200"
chk "owner token writes owner"    "$(st POST /v1/store/m365/ownertest "$ALICE_NOORG" '{"note":"owned"}')" "200"
chk "owner scope stamped sub"     "$(req GET /v1/store/m365/ownertest "$ALICE_NOORG" '' | j 'd["records"][0]["owner"]')" "$AUID"
chk "admin token unaffected"      "$(st GET /v1/store/m365/usertest adm '')" "200"
chk "admin reads undeclared"      "$(st GET /v1/store/m365/private adm '')" "200"

# --- the collection listing resolves callers the same way ------------------
refs() { req GET /v1/collections "$1" '' | j '",".join(sorted(c["ref"] for c in d["collections"]))'; }
ANON_REFS=$(refs '')
chk "anon lists only public"      "$ANON_REFS" "m365/pubtest"
chk "garbage lists as anonymous"  "$(refs "$GARBAGE")" "$ANON_REFS"
chk "jwt-shaped lists as anon"    "$(refs "$JWTISH")" "$ANON_REFS"
chk "valid user lists more"       "$(refs "$ALICE_NOORG")" "m365/ownertest,m365/pubtest,m365/usertest"
chk "admin lists user coll"       "$(refs adm | tr , '\n' | grep -c '^m365/usertest$')" "1"

# --- a disabled user's token is not a credential either --------------------
chk "admin disables alice"        "$(st PATCH /v1/auth/users/alice@example.com adm '{"disabled":true}')" "200"
chk "disabled token on user 401"  "$(st GET /v1/store/m365/usertest "$ALICE_NOORG" '')" "401"
chk "disabled token on org 401"   "$(st GET /v1/store/m365/orgtest "$ALICE" '')" "401"
chk "disabled token lists as anon" "$(refs "$ALICE_NOORG")" "$ANON_REFS"

echo "   [$PASS passed, $FAIL failed]"
[ "$FAIL" -eq 0 ]
