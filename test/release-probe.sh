#!/bin/bash
# release-probe — catch release lag in days, not weeks (issue #26).
#
# demo-probe.sh watches the hand-deployed demo; this watches the artifact
# users actually install: the newest GitHub release binary that
# `machin-365 service install` fetches. v0.2.0 sat eight commits behind main
# — missing /v1/collections, a member-removal security fix, and more —
# before anyone noticed, because nothing compared the release to master.
#
# Two checks, because they see different kinds of staleness:
#
#   1. behavioral — boot the released binary and run the same public-surface
#      probes demo-probe.sh runs against the demo. That probe list is main's
#      surface (kept current there); a build that predates a route answers
#      "no such route" and fails here the same way it fails there.
#
#   2. currency — git distance between the tag and main, counted over the
#      paths that compile into the binary (cmd/, src/, vendor/, build.sh).
#      Public probes cannot see fixes that only change authenticated
#      behavior — the member-removal access-kill (#14) shipped eight
#      commits late exactly this way — so binary-surface lag fails even
#      when every probe is green. Docs-, contract- and test-only commits do
#      not count: they cannot change what the binary does.
#
#   ./test/release-probe.sh [tag]     # default: latest GitHub release
#
# Exits non-zero on any failure. Run from CI on a schedule
# (.github/workflows/release-probe.yml), or by hand right after cutting a
# tag to prove the published asset is the commit that was tagged.
set -u

REPO="${GITHUB_REPOSITORY:-javimosch/machin-bkn}"
ARCH="${RELEASE_PROBE_ARCH:-amd64}"
TAG="${1:-}"
HERE="$(cd "$(dirname "$0")" && pwd)"
PASS=0; FAIL=0; SRV=""

ok()  { PASS=$((PASS+1)); printf "   \033[32mok\033[0m   %-44s\n" "$1"; }
bad() { FAIL=$((FAIL+1)); printf "   \033[31mFAIL\033[0m %-44s\n" "$1"; }

if [ -z "$TAG" ]; then
  TAG=$(gh release view -R "$REPO" --json tagName --jq .tagName 2>/dev/null)
  if [ -z "$TAG" ]; then
    echo "release-probe: no tag argument and no latest GitHub release found — is gh authenticated?" >&2
    exit 1
  fi
fi
ASSET="mbkn-${TAG}-linux-${ARCH}"

echo "=== release probe: $REPO $TAG ($ASSET) ==="

WORK=$(mktemp -d /tmp/release-probe-XXXXXX)
trap 'kill $SRV 2>/dev/null; rm -rf "$WORK"' EXIT

# --- fetch and boot the released binary -------------------------------------

if gh release download "$TAG" -R "$REPO" -p "$ASSET" --clobber -D "$WORK" >/dev/null 2>"$WORK/dl.err"; then
  ok "download $ASSET"
else
  bad "download $ASSET"
  sed 's/^/        /' "$WORK/dl.err" | head -5
  echo "   [$PASS passed, $FAIL failed]"
  exit 1
fi

BIN="$WORK/$ASSET"
chmod +x "$BIN"
DB="$WORK/probe.db"
PORT=0; UP=""
# serve_on exits non-zero when the port is taken, so a dead child means try
# another port rather than debugging a bind failure.
for attempt in 1 2 3 4 5; do
  PORT=$((20000 + RANDOM % 40000))
  BKN_DATA="$DB" BKN_PORT="$PORT" BKN_ADMIN_TOKEN="release-probe" \
    "$BIN" serve >"$WORK/serve-$attempt.log" 2>&1 &
  SRV=$!
  for _ in $(seq 1 50); do
    if curl -s -m 2 "http://127.0.0.1:$PORT/_health" 2>/dev/null | grep -q '"ok":true'; then
      UP=1; break
    fi
    kill -0 "$SRV" 2>/dev/null || break
    sleep 0.2
  done
  if [ -n "$UP" ]; then break; fi
  kill "$SRV" 2>/dev/null; wait "$SRV" 2>/dev/null; SRV=""
done

if [ -z "$UP" ]; then
  bad "serve did not come up"
  tail -5 "$WORK"/serve-*.log 2>/dev/null | sed 's/^/        /'
else
  ok "serve up on 127.0.0.1:$PORT"
  # The same nine unauthenticated probes the demo gets. BKN_ADMIN_TOKEN is
  # set above so the authed routes answer not_authenticated exactly as they
  # do on a real deployment — with it unset, loopback is implicitly admin
  # and /v1/events would answer ok:true where main's surface expects a 403.
  if bash "$HERE/demo-probe.sh" "http://127.0.0.1:$PORT"; then
    ok "public surface probes"
  else
    bad "public surface probes — release predates routes main serves"
  fi
fi

# --- currency: git distance from main over the binary's own paths -----------

echo "   release currency:"
CUR=0
if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  printf "   \033[33mnote\033[0m   %-44s\n" "not a git checkout — currency check skipped"
elif ! git rev-parse --verify -q "$TAG^{commit}" >/dev/null 2>&1; then
  # A shallow or branch-only checkout may lack the tag object; fetch it once.
  GIT_TERMINAL_PROMPT=0 git fetch --quiet origin "refs/tags/$TAG:refs/tags/$TAG" 2>/dev/null || true
  if git rev-parse --verify -q "$TAG^{commit}" >/dev/null 2>&1; then
    CUR=1
  else
    bad "cannot resolve tag $TAG in this checkout"
  fi
else
  CUR=1
fi

if [ "$CUR" -eq 1 ]; then
  MAIN_REF=""
  for r in origin/main main HEAD; do
    if git rev-parse --verify -q "$r" >/dev/null 2>&1; then MAIN_REF="$r"; break; fi
  done
  if [ -z "$MAIN_REF" ]; then
    bad "cannot resolve a main ref (tried origin/main, main, HEAD)"
  elif ! git merge-base --is-ancestor "$TAG" "$MAIN_REF"; then
    bad "tag $TAG is not an ancestor of $MAIN_REF — release was cut off-main"
  else
    behind_all=$(git rev-list --count "$TAG..$MAIN_REF")
    behind_bin=$(git rev-list --count "$TAG..$MAIN_REF" -- cmd src vendor build.sh)
    if [ "$behind_bin" -gt 0 ]; then
      bad "release is $behind_bin binary-surface commit(s) behind $MAIN_REF ($behind_all total) — cut a new tag"
      git log --oneline "$TAG..$MAIN_REF" -- cmd src vendor build.sh | sed 's/^/        /' | head -10
    else
      ok "tag current with $MAIN_REF ($behind_all non-binary commit(s) ahead)"
    fi
  fi
fi

echo "   [$PASS passed, $FAIL failed]"
[ "$FAIL" -eq 0 ]
