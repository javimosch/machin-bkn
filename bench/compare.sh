#!/bin/bash
# Alternate the two implementations across N repetitions and report medians.
#
# Interleaving matters: a first pass measured Go's kv-get at 6.5k rps and the
# second at 13.2k on an unchanged binary. Whatever drifts on this machine --
# page cache, CPU frequency, another process -- drifts across both if they take
# turns, and cancels in the median. Back-to-back blocks would have handed the
# first-run penalty entirely to whichever went first.
set -uo pipefail
# Deliberately not `set -e`: `pgrep | xargs` exits non-zero when there is
# nothing to kill, which is the normal case, and killed an earlier version of
# this script on its first line.
HERE=$(cd "$(dirname "$0")" && pwd)
REPS=${REPS:-5}
MFL_BIN=${MFL_BIN:-/tmp/mbkn}
export DUR=${DUR:-5s} CONC=${CONC:-8}
OUT=${OUT:-/tmp/bench-all.jsonl}
: > "$OUT"
for r in $(seq 1 "$REPS"); do
  # Reseed both databases before every repetition. script_runs grows by one row
  # per hook call and store-write leaves rows behind, so without this the later
  # reps measure a bigger database than the earlier ones -- a drift that
  # interleaving cannot cancel because it accumulates on both sides at once.
  # Fresh per rep makes each repetition the same experiment.
  rm -f /tmp/bench-go.db /tmp/bench-mfl.db
  rm -f /tmp/bench-go.db-shm /tmp/bench-go.db-wal /tmp/bench-mfl.db-shm /tmp/bench-mfl.db-wal
  rm -rf "$HERE/../blobs"
  BIN=$HOME/ai/bkn/bin/bkn BKN_DATA=/tmp/bench-go.db  "$HERE/setup.sh" >/tmp/seed-go.log  2>&1 || { echo "seed go failed"  >&2; cat /tmp/seed-go.log  >&2; exit 1; }
  BIN=$MFL_BIN            BKN_DATA=/tmp/bench-mfl.db "$HERE/setup.sh" >/tmp/seed-mfl.log 2>&1 || { echo "seed mfl failed" >&2; cat /tmp/seed-mfl.log >&2; exit 1; }
  for impl in go mfl; do
    case $impl in
      go)  BIN=$HOME/ai/bkn/bin/bkn; DB=/tmp/bench-go.db;  PORT=$((49000 + r * 10));     PROC=bkn ;;
      mfl) BIN=$MFL_BIN;             DB=/tmp/bench-mfl.db; PORT=$((49000 + r * 10 + 1)); PROC=$(basename "$MFL_BIN") ;;
    esac
    { pgrep -x "$PROC" || true; } | xargs -r kill; sleep 0.4
    BIN=$BIN BKN_DATA=$DB PORT=$PORT NAME=$impl "$HERE/run.sh" >> "$OUT" 2>/dev/null || echo "rep $r $impl FAILED" >&2
    { pgrep -x "$PROC" || true; } | xargs -r kill; sleep 0.4
  done
done
echo "wrote $OUT" >&2
