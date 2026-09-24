#!/bin/bash
# Seed a fresh machin-bkn so bkn's contract suites (~/ai/bkn/test) can run
# against it.
#
# Those suites were written against the LIVE dogfood instance and assume data
# that was seeded there by hand. Run against an empty database they fail in
# ways that look like missing features but are missing fixtures -- t-files
# scored 1/12 for want of two namespaces. This script is that seed, written
# down so a score means something.
#
#   ./test/seed-fixtures.sh <path-to-machin-bkn-binary> <bkn-examples-dir>
#
# Afterwards, start the binary and point the suites at it:
#   SP=<bkn>/test BKN_TEST_URL=http://127.0.0.1:<port> bash <bkn>/test/t-store.sh
#
# One assertion a freshly seeded database cannot satisfy on the FIRST run:
# t-stripe's "event ledger grew" wants >= 4 ledgered events and one run writes
# three, because the live instance it was written against had history. Run
# t-stripe twice; the second run passes. Nothing is wrong with the port.
#
# Two things the suites take from elsewhere and this script cannot supply:
#   - $SP/admin.tok must hold the SAME token the server was started with.
#     dog.sh reads the token from that file, NOT from $BKN_ADMIN_TOKEN, so a
#     mismatch turns every write into a 403 and cascades.
#   - $SP/cmstok.txt gets written here (line 1 read-write, line 2 read-only).
set -euo pipefail
M="${1:?usage: seed-fixtures.sh <binary> <bkn-examples-dir> [bkn-test-dir]}"
EX="${2:?pass the path to bkn/examples}"
SP="${3:-$(cd "$EX/../test" && pwd)}"
: "${BKN_DATA:?set BKN_DATA to the database the server will use}"
: "${BKN_ADMIN_TOKEN:?set BKN_ADMIN_TOKEN, and put the same value in \$SP/admin.tok}"
: "${BKN_ENCRYPTION_KEY:?set BKN_ENCRYPTION_KEY (32 chars)}"
export BKN_DATA BKN_ADMIN_TOKEN BKN_ENCRYPTION_KEY

val() { python3 -c 'import json,sys;print(json.load(sys.stdin)["value"]["token"])'; }

# --- userland scripts and their hooks -------------------------------------
"$M" script create forms          --file "$EX/forms/forms.js"              >/dev/null
"$M" script create exports        --file "$EX/forms/waitlist-export.js"    >/dev/null
"$M" script create i18n           --file "$EX/i18n/i18n.js"                >/dev/null
"$M" script create i18n-import    --file "$EX/i18n/i18n-import.js"         >/dev/null
"$M" script create redirects      --file "$EX/redirects/redirects.js"      >/dev/null
"$M" script create feature-flags  --file "$EX/flags/feature-flags.js"      >/dev/null
"$M" script create configs        --file "$EX/configs/configs.js"          >/dev/null
"$M" script create config-save    --file "$EX/configs/config-save.js"      >/dev/null
"$M" script create headless       --file "$EX/headless/headless.js"        >/dev/null
"$M" script create headless-model --file "$EX/headless/headless-model.js"  >/dev/null
"$M" script create stripe-webhook --file "$EX/stripe-webhook/stripe-webhook.js" >/dev/null

"$M" hooks create forms     --script forms          >/dev/null
"$M" hooks create exports   --script exports        >/dev/null
"$M" hooks create i18n      --script i18n           >/dev/null
"$M" hooks create redirects --script redirects      >/dev/null
"$M" hooks create flags     --script feature-flags  >/dev/null
"$M" hooks create configs   --script configs        >/dev/null
"$M" hooks create cms       --script headless       >/dev/null
"$M" hooks create stripe    --script stripe-webhook >/dev/null

# --- t-auth ----------------------------------------------------------------
"$M" auth user create ada@dog.io --password dogfood-password-1 --name "Ada Lovelace" >/dev/null
"$M" auth org create dogcorp --name "Dog Corp" >/dev/null
"$M" auth member add dogcorp ada@dog.io --role owner >/dev/null

# --- t-files: dogpub is type-restricted, dogpriv is not public -------------
"$M" files ns create dogpub  --public --allow-type 'image/*' >/dev/null
"$M" files ns create dogpriv >/dev/null

# --- t-stripe: the secret sign.py signs with, and the user it links to -----
"$M" kv set stripe.webhook_secret whsec_dogfood --type encrypted >/dev/null
"$M" auth user create buyer@dog.io --password stripe-buyer-pw-1 >/dev/null

# --- t-runtime -------------------------------------------------------------
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/dogjob.js" <<'JS'
function main(d) {
  return { hmac12: bkn.crypto.hmac("k", "m").slice(0, 12),
           has: Object.keys(bkn).sort().join(",") };
}
JS
"$M" script create dogjob --file "$TMP/dogjob.js" >/dev/null
"$M" cron create dogtick --schedule '* * * * *' --script dogjob >/dev/null

# --- t-cms: i18n, redirects, flags, configs --------------------------------
"$M" store put i18n/locales --id en --data '{"name":"English","default":true}' >/dev/null
"$M" store put i18n/locales --id fr --data '{"name":"Francais"}' >/dev/null
# interpolation is {{name}}, not {name}
"$M" script run i18n-import --input '{"locale":"en","entries":{"nav":{"home":"Home","about":"About us"},"cta":{"hi":"Hi, {{name}}"}}}' >/dev/null
"$M" script run i18n-import --input '{"locale":"fr","entries":{"nav":{"home":"Accueil"}}}' >/dev/null

# The rule id is the hash of the normalised path, so the resolver finds it in
# one lookup -- see examples/redirects/add-redirect.sh.
add_redirect() {
  local from id
  from=$(printf '%s' "$1" | tr 'A-Z' 'a-z' | sed 's:/*$::')
  id=$(printf '%s' "$from" | sha256sum | cut -c1-32)
  "$M" store put redirects/rules --id "$id" \
    --data "{\"from\":\"$from\",\"to\":\"$2\",\"type\":${3:-301},\"enabled\":true}" >/dev/null
}
add_redirect /dog-old /dog-new 301
"$M" store put redirects/prefixes --id dogdocs \
  --data '{"from":"/dogdocs","to":"https://docs.example.com","type":301,"enabled":true}' >/dev/null

"$M" kv set flag.dog-public  '{"enabled":true,"public":true}'                        --type json >/dev/null
"$M" kv set flag.dog-rollout '{"enabled":false,"public":true,"rollout_percentage":50}' --type json >/dev/null
"$M" kv set flag.dog-private '{"enabled":true,"public":false}'                       --type json >/dev/null

"$M" script run config-save --input '{"title":"Dog Pricing","alias":"dogprice","public":true,"value":{"plans":[{"name":"pro","price":29}]}}' >/dev/null
"$M" script run config-save --input '{"slug":"dog-pricing","cache_ttl_seconds":120,"value":{"plans":[{"name":"pro","price":29}]}}' >/dev/null

# --- t-forms: the two definitions the suite submits to, and the export ------
# The suite posts to forms named dogcontact/dogwait; the shapes are the
# examples' own contact-form.json and waitlist-form.json.
"$M" store put forms/definitions --id dogcontact --data "@$EX/forms/contact-form.json"  >/dev/null
"$M" store put forms/definitions --id dogwait    --data "@$EX/forms/waitlist-form.json" >/dev/null
"$M" store put forms/exports --id dogwait --data '{"form":"dogwait","format":"csv","enabled":true,"limit":5000,"fields":["id","email","source","submitted_at"],"password_setting":"exports.dogwait_password"}' >/dev/null
"$M" kv set exports.dogwait_password dog-export-secret >/dev/null

# --- t-headless: models, then the two tokens the suite reads ---------------
"$M" script run headless-model --input "$(cat "$EX/headless/article-model.json")" >/dev/null
"$M" script run headless-model --input "$(cat "$EX/headless/author-model.json")"  >/dev/null
RW=$("$M" script run headless-model --input '{"token":{"name":"rw","permissions":{"articles":["read","write"],"authors":["read","write"]}}}' | val)
RO=$("$M" script run headless-model --input '{"token":{"name":"ro","permissions":{"articles":["read"],"authors":["read"]}}}' | val)
printf '%s\n%s\n' "$RW" "$RO" > "$SP/cmstok.txt"

echo "seeded $BKN_DATA; wrote $SP/cmstok.txt"
echo "remember: \$SP/admin.tok must contain \$BKN_ADMIN_TOKEN"
