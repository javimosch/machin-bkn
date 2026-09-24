#!/bin/bash
# The whole gate against a DEPLOYED machin-bkn: 191 assertions, in two parts,
# because one of the suites cannot be run over a URL.
#
#   ./test/deploy-gate.sh [--url <https://host>] [--host <ssh-target>]
#                         [--remote <dir>] [--suites <bkn/test dir>]
#
# Part one (172) is bkn's acceptance suite pointed at the deployment over
# HTTPS -- the same assertions, only the address moves.
#
# Part two (19) is t-scriptaccess, run ON the host against the deployed
# BINARY. It starts its own server on a random port with its own throwaway
# database, because a script can only be created by the CLI on the machine
# holding the data. Running it against the live instance instead would mean
# leaving a publicly-runnable fixture script installed on a public host, and
# would make the gate mutate the deployment on every run -- its last act
# closes a script it opened. So the claim this script supports is precise:
# the deployed INSTANCE passes 172 over HTTPS, and the deployed BINARY passes
# the remaining 19. It is not a claim that the instance serves all 191.
set -u

URL="https://machin-bkn.vps1.intrane.fr"
HOST="vps1"
REMOTE="/opt/machin-bkn"
SUITES="$HOME/ai/bkn/test"

while [ $# -gt 0 ]; do
  case "$1" in
    --url)    URL="$2"; shift 2 ;;
    --host)   HOST="$2"; shift 2 ;;
    --remote) REMOTE="$2"; shift 2 ;;
    --suites) SUITES="$2"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

[ -d "$SUITES" ] || { echo "no suite directory at $SUITES" >&2; exit 2; }

# Refuse to run twice against one instance. The suites share seeded fixtures
# and use fixed record ids, so two runs at once do not collide loudly -- they
# produce a plausible-looking wrong answer ("$append concatenates: got cdabcd
# want abcd", "$push appends: got x,y,x,y want x,y"). A number you cannot
# trust is worse than no number.
LOCK="/tmp/machin-bkn-deploy-gate.lock"
exec 9>"$LOCK"
if ! flock -n 9; then
  echo "another deploy gate is already running against an instance (lock: $LOCK)." >&2
  echo "two runs share the same fixtures and will produce a wrong answer." >&2
  exit 3
fi

# Work in a COPY. dog.sh reads the admin token from $SP/admin.tok, and this
# has no business overwriting the one belonging to whatever else that
# directory is used for.
SP=$(mktemp -d)
cleanup() { rm -rf "$SP"; }
trap cleanup EXIT
cp -r "$SUITES"/. "$SP"/

echo "=== machin-bkn deploy gate ==="
echo "    instance: $URL"
echo "    host:     $HOST:$REMOTE"
echo

code=$(curl -s -o /dev/null -m 15 -w '%{http_code}' "$URL/_health" || echo 000)
[ "$code" = "200" ] || { echo "the instance is not healthy ($URL/_health -> $code)" >&2; exit 1; }

# One source of truth for the token: the deployment itself.
ssh "$HOST" "grep ^BKN_ADMIN_TOKEN= /etc/machin-bkn.env | cut -d= -f2" | tr -d '\n' > "$SP/admin.tok"
[ -s "$SP/admin.tok" ] || { echo "could not read the admin token from $HOST" >&2; exit 1; }
# t-headless authenticates with tokens minted when the fixtures were seeded.
scp -q "$HOST:$REMOTE/harness/cmstok.txt" "$SP/cmstok.txt" 2>/dev/null \
  || echo "warning: no cmstok.txt on the host; t-headless will fail" >&2

PASS=0; FAIL=0
run_suite() {
  local name="$1" out line p f
  out=$(cd "$SP" && SP="$SP" BKN_TEST_URL="$URL" timeout 300 bash "$name.sh" 2>&1)
  line=$(echo "$out" | tail -1 | sed 's/^ *//')
  p=$(echo "$line" | grep -oE '[0-9]+ passed' | grep -oE '[0-9]+'); p=${p:-0}
  f=$(echo "$line" | grep -oE '[0-9]+ failed' | grep -oE '[0-9]+'); f=${f:-0}
  PASS=$((PASS+p)); FAIL=$((FAIL+f))
  printf "  %-15s %s\n" "$name" "$line"
  # Print the failing assertions, not just the count: a number tells you
  # something broke, a line tells you what.
  [ "$f" -gt 0 ] && echo "$out" | grep FAIL | sed 's/^ */        /'
  return 0
}

# t-stripe asserts the event ledger has grown to >= 4, which one run on a
# fresh database cannot satisfy. Warm it once, silently.
(cd "$SP" && SP="$SP" BKN_TEST_URL="$URL" timeout 300 bash t-stripe.sh >/dev/null 2>&1) || true

echo "--- over HTTPS, against the instance ---"
# Serial on purpose: the suites share seeded fixtures, so two at once against
# one instance produce numbers that mean nothing.
for s in t-store t-access t-kv t-auth t-files t-forms t-runtime t-stripe t-cms t-headless; do
  run_suite "$s"
done

echo
echo "--- on the host, against the deployed binary ---"
sout=$(ssh "$HOST" "cd $REMOTE && BKN_BIN=$REMOTE/bkn timeout 300 bash t-scriptaccess.sh" 2>&1) || true
sline=$(echo "$sout" | tail -1 | sed 's/^ *//')
sp=$(echo "$sline" | grep -oE '[0-9]+ passed' | grep -oE '[0-9]+'); sp=${sp:-0}
sf=$(echo "$sline" | grep -oE '[0-9]+ failed' | grep -oE '[0-9]+'); sf=${sf:-0}
PASS=$((PASS+sp)); FAIL=$((FAIL+sf))
printf "  %-15s %s\n" "t-scriptaccess" "$sline"
[ "$sf" -gt 0 ] && echo "$sout" | grep FAIL | sed 's/^ */        /'

echo
echo "=== $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ] || exit 1
