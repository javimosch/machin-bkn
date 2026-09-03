#!/bin/bash
# MFL composes by concatenation (`machin encode` joins multiple sources), so a
# build is: every library, then exactly one file with main().
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
MACHIN="${MACHIN:-$HOME/ai/machin/bin/machin}"
MAIN="${1:?usage: build.sh <file-with-main.mfl> [-o out]}"
shift || true
OUT="$(mktemp /tmp/machin-bkn-XXXX.mfl)"
FW="${MACHIN_FW:-$HOME/ai/machin/framework}"

# `encode` takes every source at once and concatenates them — appending after a
# lone `encode` of the framework yields a file the compiler sees as empty.
if grep -lq "serve(" "$MAIN" 2>/dev/null; then
  "$MACHIN" encode "$FW/machweb.src" "$HERE"/src/*.mfl "$MAIN" > "$OUT"
else
  "$MACHIN" encode "$HERE"/src/*.mfl "$MAIN" > "$OUT"
fi

if [ "${1:-}" = "-o" ]; then "$MACHIN" build "$OUT" -o "$2"; else "$MACHIN" run "$OUT"; fi
