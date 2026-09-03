#!/bin/bash
# MFL composes by concatenation (`machin encode` joins multiple sources), so a
# build is: every library, then exactly one file with main().
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
MACHIN="${MACHIN:-$HOME/ai/machin/bin/machin}"
MAIN="${1:?usage: build.sh <file-with-main.mfl> [-o out]}"
shift || true
OUT="$(mktemp /tmp/machin-bkn-XXXX.mfl)"
cat "$HERE"/src/*.mfl "$MAIN" > "$OUT"
if [ "${1:-}" = "-o" ]; then "$MACHIN" build "$OUT" -o "$2"; else "$MACHIN" run "$OUT"; fi
