#!/bin/bash
# The non-auth CLI verbs. Like auth-cli.sh, none of this is reachable from the
# contract suites, which drive HTTP.
#
#   ./test/cli-surface.sh <binary>
set -u
M="${1:?usage: cli-surface.sh <binary>}"
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
OLD=$(openssl rand -hex 32); NEW=$(openssl rand -hex 32)
export BKN_DATA="$WORK/s.db" BKN_ADMIN_TOKEN=tok BKN_ENCRYPTION_KEY="$OLD"
PASS=0; FAIL=0
chk() { if [ "$2" = "$3" ]; then PASS=$((PASS+1)); printf "   \033[32mok\033[0m   %-44s %s\n" "$1" "$2"
        else FAIL=$((FAIL+1)); printf "   \033[31mFAIL\033[0m %-44s got %s want %s\n" "$1" "$2" "$3"; fi }
j() { python3 -c "import json,sys;d=json.load(sys.stdin);print($1)" 2>/dev/null || echo PARSE_ERROR; }
rc() { "$@" >/dev/null 2>&1; echo $?; }

echo "=== store / kv / events / files / lock / cron / hooks / script ==="

# --- store ----------------------------------------------------------------
chk "create declares normalizers" "$("$M" store create shop/items --normalize sku=trim_lower </dev/null | j 'd["collection"]["normalize"]["sku"]')" "trim_lower"
"$M" store put shop/items --id a1 --data '{"sku":"  AB-9 ","qty":3}' >/dev/null 2>&1
chk "and they are applied"        "$("$M" store get shop/items a1 </dev/null | j 'd["record"]["sku"]')" "ab-9"
chk "patch is partial"            "$("$M" store patch shop/items a1 --data '{"qty":7}' </dev/null | j 'str(d["record"]["qty"])+"/"+d["record"]["sku"]')" "7/ab-9"
chk "delete"                      "$("$M" store delete shop/items a1 </dev/null | j 'str(d["deleted"])')" "True"
chk "delete of a gone record"     "$(rc "$M" store delete shop/items a1)" "81"
chk "patch needs --data"          "$(rc "$M" store patch shop/items a1)" "85"

# --- kv --------------------------------------------------------------------
"$M" kv set tmp.k v1 >/dev/null 2>&1
chk "kv delete"                   "$("$M" kv delete tmp.k </dev/null | j 'str(d["deleted"])')" "True"
chk "kv delete of a gone key"     "$(rc "$M" kv delete tmp.k)" "81"

# --- events ----------------------------------------------------------------
"$M" events emit probe old --subject s1 >/dev/null 2>&1
"$M" events emit other keep >/dev/null 2>&1
python3 -c "import time;time.sleep(2.2)"
"$M" events emit probe fresh >/dev/null 2>&1
chk "prune drops only the old"    "$("$M" events prune --older-than 1s --stream probe </dev/null | j 'str(d["removed"])')" "1"
chk "the fresh event survives"    "$("$M" events list probe </dev/null | j 'str(d["count"])')" "1"
chk "another stream is untouched" "$("$M" events list other </dev/null | j 'str(d["count"])')" "1"
chk "prune rejects a bad age"     "$(rc "$M" events prune --older-than nonsense)" "85"

# --- files -----------------------------------------------------------------
"$M" files ns create pics --public >/dev/null 2>&1
printf 'hello' > "$WORK/f.txt"
"$M" files put pics "$WORK/f.txt" --name f.txt >/dev/null 2>&1
chk "file is listed"              "$("$M" files list pics </dev/null | j 'len(d["files"])')" "1"
chk "files delete"                "$("$M" files delete pics f.txt </dev/null | j 'str(d["deleted"])')" "True"
chk "and it is gone"              "$("$M" files list pics </dev/null | j 'len(d["files"])')" "0"
chk "delete of a gone file"       "$(rc "$M" files delete pics f.txt)" "81"

# --- lock ------------------------------------------------------------------
OWNER=$("$M" lock acquire job.x --ttl 5m </dev/null | j 'd["owner"]')
chk "acquire returns an owner"    "$([ -n "$OWNER" ] && echo yes || echo no)" "yes"
# held-by-someone-else is an answer, not an error
chk "a held lock refuses politely" "$("$M" lock acquire job.x </dev/null | j 'str(d["acquired"])')" "False"
chk "the wrong owner cannot release" "$(rc "$M" lock release job.x wrongtoken)" "81"
chk "the right owner can"         "$("$M" lock release job.x "$OWNER" </dev/null | j 'str(d["released"])')" "True"
chk "release needs owner or --force" "$(rc "$M" lock release job.x)" "85"
"$M" lock acquire job.x >/dev/null 2>&1
chk "--force breaks a live lease" "$("$M" lock release job.x --force </dev/null | j 'str(d["forced"])')" "True"

# --- cron ------------------------------------------------------------------
cat > "$WORK/p.js" <<'JS'
function main(d) { return { saw: d.method || "none", body: d.body || "", hdr: (d.headers||{})["x-token"] || "" }; }
JS
"$M" script create probe --file "$WORK/p.js" >/dev/null 2>&1
"$M" cron create nightly --schedule '0 3 * * *' --script probe >/dev/null 2>&1
chk "cron show"                   "$("$M" cron show nightly </dev/null | j 'd["job"]["schedule"]')" "0 3 * * *"
chk "cron update --schedule"      "$("$M" cron update nightly --schedule '@every 10m' </dev/null | j 'd["job"]["schedule"]')" "@every 10m"
chk "cron update --disable"       "$("$M" cron update nightly --disable </dev/null | j 'str(d["job"]["enabled"])')" "False"
chk "cron update --enable"        "$("$M" cron update nightly --enable </dev/null | j 'str(d["job"]["enabled"])')" "True"
chk "cron rejects a bad schedule" "$(rc "$M" cron update nightly --schedule nope)" "85"
chk "cron rejects bad input JSON" "$(rc "$M" cron update nightly --input 'not json')" "85"
chk "cron update needs a field"   "$(rc "$M" cron update nightly)" "85"
chk "cron show of an unknown job" "$(rc "$M" cron show ghost)" "81"

# --- hooks -----------------------------------------------------------------
"$M" hooks create probe --script probe >/dev/null 2>&1
chk "hooks show"                  "$("$M" hooks show probe </dev/null | j 'd["hook"]["script"]')" "probe"
chk "hooks update several fields" "$("$M" hooks update probe --rate-limit 30 --max-bytes 4096 </dev/null | j 'str(d["hook"]["rate_limit"])+"/"+str(d["hook"]["max_bytes"])')" "30/4096"
# zero is a real value for both, so a later partial update must not reset them
chk "a partial update keeps the rest" "$("$M" hooks update probe --max-bytes 10 </dev/null | j 'str(d["hook"]["rate_limit"])')" "30"
chk "hooks update --disable"      "$("$M" hooks update probe --disable </dev/null | j 'str(d["hook"]["enabled"])')" "False"
"$M" hooks update probe --enable >/dev/null 2>&1
chk "a hook cannot point at nothing" "$(rc "$M" hooks update probe --script ghost)" "85"
chk "hooks update needs a field"  "$(rc "$M" hooks update probe)" "85"
# the test must exercise the REAL envelope, or it tests nothing
chk "hooks test passes the method" "$("$M" hooks test probe --method PUT --body '{}' </dev/null | j 'd["value"]["saw"]')" "PUT"
chk "hooks test passes the body"  "$("$M" hooks test probe --body 'raw-body' </dev/null | j 'd["value"]["body"]')" "raw-body"
chk "hooks test passes headers"   "$("$M" hooks test probe --header 'X-Token=abc' --body '{}' </dev/null | j 'd["value"]["hdr"]')" "abc"
chk "hooks test of an unknown hook" "$(rc "$M" hooks test ghost)" "81"

# --- script ----------------------------------------------------------------
chk "script show"                 "$("$M" script show probe </dev/null | j 'd["script"]["name"]+"/"+d["script"]["run_access"]')" "probe/admin"
chk "script show of an unknown"   "$(rc "$M" script show ghost)" "81"
echo 'function main(i){ return { doubled: (i.n||0)*2 }; }' > "$WORK/u.js"
chk "script test runs uninstalled" "$("$M" script test --file "$WORK/u.js" --input '{"n":21}' </dev/null | j 'str(d["value"]["doubled"])')" "42"
# a test must not install, and must not litter the run history
chk "and does not install it"     "$("$M" script list </dev/null | j 'str(len(d["scripts"]))')" "1"
chk "nor record a run"            "$("$M" script runs probe --limit 5 </dev/null | j 'str(d["count"])')" "0"
echo 'function main(){ throw new Error("boom"); }' > "$WORK/bad.js"
chk "a throwing test exits 85"    "$(rc "$M" script test --file "$WORK/bad.js")" "85"
echo 'function main(){ while(true){} }' > "$WORK/loop.js"
chk "a runaway test times out"    "$(rc "$M" script test --file "$WORK/loop.js" --timeout 300)" "85"
chk "script test needs --file"    "$(rc "$M" script test)" "85"

# --- kv rekey: the rotation the contract describes -------------------------
"$M" kv set app.secret sk_live_ORIGINAL --type encrypted >/dev/null 2>&1
unset BKN_ENCRYPTION_KEY
export BKN_ENCRYPTION_KEYS="v1:$OLD,v2:$NEW" BKN_ENCRYPTION_KEY_ID=v2
chk "readable across the key set" "$("$M" kv get app.secret </dev/null | j 'd["entry"]["value"]')" "sk_live_ORIGINAL"
chk "rekey moves it"              "$("$M" kv rekey </dev/null | j 'str(d["rekeyed"])+"/"+str(d["failed"])+"/"+d["key_id"]')" "1/0/v2"
chk "rekey is idempotent"         "$("$M" kv rekey </dev/null | j 'str(d["rekeyed"])+"/"+str(d["skipped"])')" "0/1"
# the proof it really moved: retire the old key entirely
export BKN_ENCRYPTION_KEYS="v2:$NEW"
chk "readable with ONLY the new key" "$("$M" kv get app.secret </dev/null | j 'd["entry"]["value"]')" "sk_live_ORIGINAL"
export BKN_ENCRYPTION_KEYS="v1:$OLD" BKN_ENCRYPTION_KEY_ID=v1
chk "and names the id it needs"   "$("$M" kv get app.secret </dev/null 2>&1 | j 'd["error"]["message"]')" "cannot read app.secret: no key with id v2 in BKN_ENCRYPTION_KEYS"
# a value whose key is absent must be LEFT ALONE, never overwritten
"$M" kv set app.second second-val --type encrypted >/dev/null 2>&1
export BKN_ENCRYPTION_KEYS="v1:$OLD,v9:$NEW" BKN_ENCRYPTION_KEY_ID=v9
chk "rekey reports what it could not open" "$("$M" kv rekey </dev/null 2>&1 | j 'str(d["rekeyed"])+"/"+str(d["failed"])')" "1/1"
chk "and exits non-zero"          "$(rc "$M" kv rekey)" "85"
export BKN_ENCRYPTION_KEYS="v1:$OLD,v2:$NEW,v9:$NEW"
chk "the unopenable value survived" "$("$M" kv get app.secret </dev/null | j 'd["entry"]["value"]')" "sk_live_ORIGINAL"
chk "and the rekeyed one too"     "$("$M" kv get app.second </dev/null | j 'd["entry"]["value"]')" "second-val"

# --- store count ------------------------------------------------------------
"$M" store put shop/items --id c1 --data '{"kind":"a"}' >/dev/null 2>&1
"$M" store put shop/items --id c2 --data '{"kind":"a"}' >/dev/null 2>&1
"$M" store put shop/items --id c3 --data '{"kind":"b"}' >/dev/null 2>&1
chk "count answers how many"      "$("$M" store count shop/items </dev/null | j 'str(d["total"])')" "3"
chk "count honours --where"       "$("$M" store count shop/items --where kind=a </dev/null | j 'str(d["total"])')" "2"
chk "count --by buckets, largest first" "$("$M" store count shop/items --by kind </dev/null | j '",".join(b["key"]+"="+str(b["count"]) for b in d["buckets"])')" "a=2,b=1"
# groups and truncated exist so a --limit cannot hide that there was more
chk "count --limit shows truncation" "$("$M" store count shop/items --by kind --limit 1 </dev/null | j 'str(len(d["buckets"]))+"/"+str(d["groups"])+"/"+str(d["truncated"])')" "1/2/True"
chk "count rejects a bad --by"    "$(rc "$M" store count shop/items --by 'no such')" "85"

# --- store access -----------------------------------------------------------
chk "access sets rules"           "$("$M" store access shop/items --access read=owner --access create=user --owner-field uid </dev/null | j 'd["collection"]["access"]["rules"]["read"]+"/"+d["collection"]["access"]["owner_field"]')" "owner/uid"
chk "no flags reads it back"      "$("$M" store access shop/items </dev/null | j 'd["rules"]')" "read=owner,create=user"
chk "--clear makes it undeclared" "$("$M" store access shop/items --clear </dev/null | j 'str("access" in d["collection"])')" "False"
chk "and the read-back is empty"  "$("$M" store access shop/items </dev/null | j 'd["rules"]')" ""
chk "access rejects a bad audience" "$(rc "$M" store access shop/items --access read=nonsense)" "85"

# --- files sign -------------------------------------------------------------
"$M" files ns create signed --signing-key auto >/dev/null 2>&1
"$M" files ns create unsigned >/dev/null 2>&1
printf 'secret bytes' > "$WORK/s.txt"
"$M" files put signed "$WORK/s.txt" --name s.txt >/dev/null 2>&1
"$M" files put unsigned "$WORK/s.txt" --name u.txt >/dev/null 2>&1
chk "ns reports signed_urls"      "$("$M" files ns list </dev/null | j 'str(next(n["signed_urls"] for n in d["namespaces"] if n["name"]=="signed"))')" "True"
# the key itself must never be echoed: it makes every link forgeable
chk "the signing key is not echoed" "$("$M" files ns list </dev/null | grep -c signing_key)" "0"
chk "sign returns a url"          "$("$M" files sign signed s.txt --ttl 10m </dev/null | j '"sig=" in d["url"] and "exp=" in d["url"]')" "True"
chk "--base-url prefixes it"      "$("$M" files sign signed s.txt --base-url https://cdn.example.com </dev/null | j 'd["url"].startswith("https://cdn.example.com/v1/files/")')" "True"
chk "a ns with no key refuses"    "$(rc "$M" files sign unsigned u.txt)" "81"
chk "signing a missing file"      "$(rc "$M" files sign signed nope.txt)" "81"

PORT=$((21000 + RANDOM % 9000))
"$M" serve --host 127.0.0.1 --port $PORT >"$WORK/srv.log" 2>&1 &
SRV=$!
for _ in $(seq 1 50); do curl -sf "http://127.0.0.1:$PORT/_health" >/dev/null && break; sleep 0.1; done
B="http://127.0.0.1:$PORT"
U=$("$M" files sign signed s.txt --ttl 10m </dev/null | j 'd["url"]')
code() { curl -s -o /dev/null -w '%{http_code}' "$1"; }
chk "private ns is 404 unsigned"  "$(code "$B/v1/files/signed/s.txt")" "404"
chk "a signed link opens it"      "$(code "$B$U")" "200"
chk "and serves the bytes"        "$(curl -s "$B$U")" "secret bytes"
chk "a tampered sig is 404"       "$(code "$B$(echo "$U" | sed 's/sig=./sig=X/')")" "404"
# Editing exp in the URL only proves the signature covers it. To test the
# EXPIRY, sign a correctly-signed link with a 1s life and let it die.
chk "editing exp breaks the sig"  "$(code "$B$(echo "$U" | sed -E 's/exp=[0-9]+/exp=1000000000/')")" "404"
SHORT=$("$M" files sign signed s.txt --ttl 1s </dev/null | j 'd["url"]')
chk "a fresh short link opens"    "$(code "$B$SHORT")" "200"
sleep 2
chk "and is 404 once it expires"  "$(code "$B$SHORT")" "404"
SIG=$(echo "$U" | grep -oE 'sig=[^&]+')
chk "a sig does not open another file" "$(code "$B/v1/files/unsigned/u.txt?$SIG&exp=9999999999")" "404"
kill $SRV 2>/dev/null

# --- backup -----------------------------------------------------------------
chk "backup needs a destination"  "$(rc "$M" backup)" "85"
chk "backup --to reports integrity" "$("$M" backup --to "$WORK/snap.db" </dev/null | j 'd["integrity"]')" "ok"
chk "and the byte count is real"  "$("$M" backup --to "$WORK/snap2.db" </dev/null | j 'str(d["bytes"] == __import__("os").path.getsize("'"$WORK"'/snap2.db"))')" "True"
# a snapshot nobody can open is a hope, not a backup
chk "the snapshot is a real db"   "$(BKN_DATA=$WORK/snap.db "$M" store count shop/items </dev/null | j 'str(d["total"])')" "3"
chk "it will not overwrite"       "$(rc "$M" backup --to "$WORK/snap.db")" "85"
# Count only temps this run creates: the glob is shared with any other bkn on
# the machine, so an absolute count is somebody else's state.
BEFORE=$(ls /tmp/bkn-backup-*.db 2>/dev/null | wc -l)
"$M" backup --stdout > "$WORK/piped.db" 2>/dev/null
chk "--stdout streams the bytes"  "$(head -c 15 "$WORK/piped.db")" "SQLite format 3"
chk "and that stream is a real db" "$(BKN_DATA=$WORK/piped.db "$M" store count shop/items </dev/null | j 'str(d["total"])')" "3"
chk "no temp file left behind"    "$(( $(ls /tmp/bkn-backup-*.db 2>/dev/null | wc -l) - BEFORE ))" "0"

echo "   [$PASS passed, $FAIL failed]"
[ "$FAIL" -eq 0 ]
