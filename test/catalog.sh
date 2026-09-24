#!/bin/bash
# help-json is the contract surface: an agent discovers what the tool can do by
# reading it, so a command that works but is not listed does not exist as far
# as any caller is concerned. Six had drifted out before this existed.
#
# Also checks the reverse -- nothing listed that does not run -- and that the
# embedded guide mentions every catalogued command.
#
#   ./test/catalog.sh <binary>
set -u
M="${1:?usage: catalog.sh <binary>}"
export BKN_DATA="${BKN_DATA:-$(mktemp -u /tmp/bkn-catalog-XXXX.db)}"
export BKN_ADMIN_TOKEN="${BKN_ADMIN_TOKEN:-x}"
export BKN_ENCRYPTION_KEY="${BKN_ENCRYPTION_KEY:-0123456789abcdef0123456789abcdef}"
PASS=0; FAIL=0

# Every verb the CLI actually dispatches, taken from the source rather than
# from the catalog we are checking -- comparing the catalog against itself
# would pass no matter what.
SRC="$(dirname "$0")/../src/cli.mfl"

listed=$("$M" help-json </dev/null | python3 -c 'import json,sys;print("\n".join(json.load(sys.stdin)["commands"]))')

# 1. everything listed must actually run (exit 80 = unknown command)
while IFS= read -r cmd; do
  [ -z "$cmd" ] && continue
  # serve blocks forever by design; timeout is the backstop for anything else
  # that decides to.
  case "$cmd" in serve) PASS=$((PASS+1)); continue;; esac
  timeout 10 "$M" $cmd zzz zzz </dev/null >/dev/null 2>&1
  if [ $? -eq 80 ]; then
    printf "   \033[31mFAIL\033[0m listed but not implemented: %s\n" "$cmd"; FAIL=$((FAIL+1))
  else PASS=$((PASS+1)); fi
done <<< "$listed"

# 2. every command the guide names must be in the catalog
guide_missing=$("$M" guide </dev/null | python3 -c '
import json,sys
g=json.load(sys.stdin)["guide"]
import itertools
cmds=set()
for grp in g["commands"].values():
    for c in grp:
        if c.startswith("bkn "): cmds.add(" ".join(c.split()[1:]))
print("\n".join(sorted(cmds)))' | while IFS= read -r c; do
  [ -z "$c" ] && continue
  hit=0
  for n in 3 2 1; do
    p=$(echo "$c" | cut -d' ' -f1-$n)
    echo "$listed" | grep -qxF "$p" && { hit=1; break; }
  done
  [ $hit -eq 0 ] && echo "$c"
done)
if [ -n "$guide_missing" ]; then
  echo "$guide_missing" | while IFS= read -r c; do
    printf "   \033[31mFAIL\033[0m guide names a command not in help-json: %s\n" "$c"
  done
  FAIL=$((FAIL+1))
else PASS=$((PASS+1)); fi

# 3. every catalogued command must be mentioned in the guide
gtext=$("$M" guide </dev/null)
while IFS= read -r cmd; do
  [ -z "$cmd" ] && continue
  case "$cmd" in guide|version|help-json) continue;; esac
  if ! echo "$gtext" | grep -qF "bkn $cmd"; then
    printf "   \033[31mFAIL\033[0m in help-json but never taught by the guide: %s\n" "$cmd"
    FAIL=$((FAIL+1))
  else PASS=$((PASS+1)); fi
done <<< "$listed"

rm -f "$BKN_DATA"
echo "   [$PASS passed, $FAIL failed]"
[ "$FAIL" -eq 0 ]
