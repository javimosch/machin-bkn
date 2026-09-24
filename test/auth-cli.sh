#!/bin/bash
# The auth CLI surface. The contract suites drive HTTP, so none of this is
# covered by them -- these verbs could rot silently.
#
#   ./test/auth-cli.sh <binary>
set -u
M="${1:?usage: auth-cli.sh <binary>}"
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
export BKN_DATA="$WORK/a.db" BKN_ADMIN_TOKEN=tok
export BKN_ENCRYPTION_KEY=0123456789abcdef0123456789abcdef
PASS=0; FAIL=0
chk() { if [ "$2" = "$3" ]; then PASS=$((PASS+1)); printf "   \033[32mok\033[0m   %-42s %s\n" "$1" "$2"
        else FAIL=$((FAIL+1)); printf "   \033[31mFAIL\033[0m %-42s got %s want %s\n" "$1" "$2" "$3"; fi }
j() { python3 -c "import json,sys;d=json.load(sys.stdin);print($1)" 2>/dev/null || echo "PARSE_ERROR"; }
rc() { "$@" >/dev/null 2>&1; echo $?; }

echo "=== auth CLI ==="
"$M" auth user create dev@dog.io --password auth-cli-pw-111 --name Dev >/dev/null
"$M" auth org create acme --name Acme >/dev/null
"$M" auth org create other --name Other >/dev/null
"$M" auth member add acme dev@dog.io --role owner >/dev/null
"$M" auth member add other dev@dog.io --role member >/dev/null

chk "create honours --role"      "$("$M" auth user create boss@dog.io --password boss-pw-1234 --role admin </dev/null | j 'd["user"]["role"]')" "admin"
chk "create --password-stdin"    "$(printf 'from-stdin-pw-1' | "$M" auth user create s@dog.io --password-stdin | j 'd["user"]["email"]')" "s@dog.io"

LOGIN=$("$M" auth login dev@dog.io --password auth-cli-pw-111 --org acme </dev/null)
ACC=$(echo "$LOGIN" | j 'd["tokens"]["access_token"]')
REF=$(echo "$LOGIN" | j 'd["tokens"]["refresh_token"]')
chk "login is org-scoped"        "$(echo "$LOGIN" | j 'd["tokens"]["org"]+"/"+d["tokens"]["org_role"]')" "acme/owner"
chk "login rejects a bad password" "$(rc "$M" auth login dev@dog.io --password wrong)" "85"
chk "me resolves the live user"  "$("$M" auth me "$ACC" </dev/null | j 'd["user"]["email"]+"/"+d["org"]')" "dev@dog.io/acme"
chk "sessions lists it as active" "$("$M" auth sessions dev@dog.io </dev/null | j 'str(d["count"])+"/"+str(d["sessions"][0]["active"])')" "1/True"

REF2=$("$M" auth refresh "$REF" </dev/null | j 'd["tokens"]["refresh_token"]')
chk "refresh rotates the token"  "$([ "$REF" != "$REF2" ] && echo rotated || echo same)" "rotated"
chk "the old token is dead"      "$("$M" auth refresh "$REF" </dev/null | j 'd["error"]["message"]')" "refresh token is unknown, revoked or expired"
chk "refresh keeps the org"      "$("$M" auth refresh "$REF2" </dev/null | j 'd["tokens"]["org"]')" "acme"

R3=$("$M" auth login dev@dog.io --password auth-cli-pw-111 --org acme </dev/null | j 'd["tokens"]["refresh_token"]')
chk "switch-org moves tenant"    "$("$M" auth switch-org "$R3" other </dev/null | j 'd["tokens"]["org"]+"/"+d["tokens"]["org_role"]')" "other/member"

R4=$("$M" auth login dev@dog.io --password auth-cli-pw-111 </dev/null | j 'd["tokens"]["refresh_token"]')
"$M" auth logout "$R4" >/dev/null 2>&1
chk "logout kills the session"   "$("$M" auth refresh "$R4" </dev/null | j 'd["error"]["message"]')" "refresh token is unknown, revoked or expired"
# the caller's goal is that the token stops working, and it already has
chk "logout of an unknown token succeeds" "$("$M" auth logout nonsense </dev/null | j 'str(d["logged_out"])')" "True"

"$M" auth login dev@dog.io --password auth-cli-pw-111 >/dev/null 2>&1
chk "revoke reports what it killed" "$([ "$("$M" auth revoke dev@dog.io </dev/null | j 'd["revoked"]')" -ge 1 ] && echo yes || echo no)" "yes"
chk "and leaves none active"     "$("$M" auth sessions dev@dog.io </dev/null | j 'sum(1 for s in d["sessions"] if s["active"])')" "0"

chk "update needs a field"       "$(rc "$M" auth user update dev@dog.io)" "85"
chk "a rename revokes nothing"   "$("$M" auth user update dev@dog.io --name Renamed </dev/null | j 'd["user"]["name"]+"/"+str(d["sessions_revoked"])')" "Renamed/False"
"$M" auth login dev@dog.io --password auth-cli-pw-111 >/dev/null 2>&1
chk "a password change revokes"  "$("$M" auth user update dev@dog.io --password brand-new-pw-22 </dev/null | j 'str(d["sessions_revoked"])')" "True"
chk "the old password is dead"   "$("$M" auth login dev@dog.io --password auth-cli-pw-111 </dev/null | j 'd["error"]["message"]')" "email or password is incorrect"
chk "the new password works"     "$("$M" auth login dev@dog.io --password brand-new-pw-22 </dev/null | j 'd["tokens"]["user"]["email"]')" "dev@dog.io"
chk "update --password-stdin"    "$(printf 'changed-via-stdin' | "$M" auth user update dev@dog.io --password-stdin | j 'str(d["sessions_revoked"])')" "True"
chk "--disable takes effect"     "$("$M" auth user update dev@dog.io --disable </dev/null | j 'str(d["user"]["disabled"])')" "True"
chk "a disabled user cannot log in" "$("$M" auth login dev@dog.io --password changed-via-stdin </dev/null | j 'd["error"]["message"]')" "user is disabled"
chk "--enable restores"          "$("$M" auth user update dev@dog.io --enable </dev/null | j 'str(d["user"]["disabled"])')" "False"

chk "member remove"              "$("$M" auth member remove acme dev@dog.io </dev/null | j 'str(d["removed"])')" "True"
chk "and the membership is gone" "$("$M" auth memberships dev@dog.io </dev/null | j 'str(d["count"])')" "1"
chk "org delete"                 "$("$M" auth org delete other </dev/null | j 'str(d["deleted"])')" "True"
chk "the org is gone"            "$(rc "$M" auth org show other)" "92"
# deleting an org must not delete its people
chk "the user survives it"       "$(rc "$M" auth user show dev@dog.io)" "0"
chk "user delete"                "$("$M" auth user delete dev@dog.io </dev/null | j 'str(d["deleted"])')" "True"
chk "the user is gone"           "$(rc "$M" auth user show dev@dog.io)" "92"

# not 85: updating a user who is not there is a not-found, and it used to
# answer 85 only because the library returns a message and the CLI could not
# tell the difference.
chk "unknown user: update"       "$(rc "$M" auth user update ghost@x.io --name N)" "92"
chk "unknown user: sessions"     "$(rc "$M" auth sessions ghost@x.io)" "92"
chk "unknown user: revoke"       "$(rc "$M" auth revoke ghost@x.io)" "92"
chk "unknown user: delete"       "$(rc "$M" auth user delete ghost@x.io)" "92"

echo "   [$PASS passed, $FAIL failed]"
[ "$FAIL" -eq 0 ]
