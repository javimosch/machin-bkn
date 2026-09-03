#!/bin/bash
# Compile QuickJS + the bridge into one static archive. Cached: the archive is
# rebuilt only when a source is newer, because quickjs.c alone is ~1 minute.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
Q="$HERE/quickjs"
OBJ="$HERE/.obj"
LIB="$HERE/libbknqjs.a"

newest=$(ls -t "$Q"/*.c "$Q"/*.h "$HERE/bkn_qjs.c" | head -1)
if [ -f "$LIB" ] && [ "$LIB" -nt "$newest" ]; then exit 0; fi

mkdir -p "$OBJ"
VER=$(cat "$Q/VERSION")
CFLAGS="-O2 -fno-strict-aliasing -Wno-implicit-fallthrough -Wno-sign-compare -Wno-unused -DCONFIG_VERSION=\"$VER\" -I$Q"
echo "[qjs] compiling QuickJS $VER (once; cached in vendor/libbknqjs.a)" >&2
for f in quickjs libregexp libunicode cutils dtoa; do
  cc $CFLAGS -c "$Q/$f.c" -o "$OBJ/$f.o" &
done
wait
cc $CFLAGS -c "$HERE/bkn_qjs.c" -o "$OBJ/bkn_qjs.o"
ar rcs "$LIB" "$OBJ"/*.o
echo "[qjs] built $LIB" >&2
