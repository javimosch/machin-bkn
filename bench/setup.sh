#!/bin/bash
# Seed one implementation's database with the benchmark fixture.
# Both implementations get byte-identical inputs from the same files, so any
# difference in the numbers is the implementation and not the data.
#
# Only subcommands BOTH CLIs implement are used here. The MFL build has no
# `files put` (the acceptance suite uploads over HTTP, so the CLI never needed
# it), and with `set -e` that gap silently truncated an earlier version of this
# fixture — the blob, the bundles, the script and the hook were all missing and
# the benchmark would have measured 404s. The blob upload therefore happens
# over HTTP in run.sh, once the server is listening.
#
# Usage: BIN=<path> BKN_DATA=<db> ./setup.sh
set -euo pipefail
SRC=$(cd "$(dirname "$0")/.." && pwd)
: "${BIN:?BIN required}" "${BKN_DATA:?BKN_DATA required}"
export BKN_DATA
export BKN_AUTH_SECRET=${BKN_AUTH_SECRET:-bench-secret}
export BKN_ENCRYPTION_KEY=${BKN_ENCRYPTION_KEY:-0000000000000000000000000000000000000000000000000000000000000000}

$BIN kv set dog.name "Ada Lovelace" >/dev/null

# 200 documents, so list/query has something to sort and filter rather than
# measuring the cost of returning an empty array.
for i in $(seq 1 200); do
  $BIN store put dog/products --id "p$i" \
    --data "{\"name\":\"widget $i\",\"price\":$((i % 97)),\"stock\":$((i % 13)),\"status\":\"live\"}" >/dev/null
done

$BIN files ns create benchns --allow-type application/octet-stream --public >/dev/null

# The script path: a read-only handler that reads a store document and formats
# a response, which is the shape most hook workloads actually have.
for f in en fr; do
  $BIN store put i18n/bundles --id $f --data @"$SRC/scripts/seed/i18n-$f.json" >/dev/null
done
$BIN script create bench --file "$SRC/bench/bench-hook.js" >/dev/null
$BIN hooks create bench --script bench --rate-limit 1000000 >/dev/null
