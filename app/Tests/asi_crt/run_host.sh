#!/bin/bash
# Builds Tests/asi_crt/asi_host (Source/NativeASI.c and Blink for macOS) and runs a script mod in it (GTA-188).
#   Tests/asi_crt/run_host.sh <mod.asi> [its folder] [frames] [key code to press] [frame to press it at]
# Build output goes to $ASI_HOST_BUILD (default: /tmp/asi_host). The C++ self-test mod is built by build_selftest.sh.
set -e
cd "$(dirname "$0")/../.."
OUT=${ASI_HOST_BUILD:-/tmp/asi_host}; mkdir -p "$OUT/blink"
if [ ! -f "$OUT/libblink.a" ]; then
  for f in Vendor/blink/blink/*.c; do
    xcrun -sdk macosx clang -c -arch arm64 -target arm64-apple-macos13 -O2 -DNDEBUG -w -D_GNU_SOURCE -I Vendor/blink -o "$OUT/blink/$(basename "$f" .c).o" "$f"
  done
  xcrun ar rcs "$OUT/libblink.a" "$OUT"/blink/*.o
fi
xcrun -sdk macosx clang -arch arm64 -target arm64-apple-macos13 -O2 -g -Wall -Wno-unused-function -I Source -I Vendor/blink \
  -o "$OUT/asi_host" Tests/asi_crt/asi_host.c Source/NativeASI.c "$OUT/libblink.a"
MOD=$1; FOLDER=${2:-$(dirname "$MOD")}
[ -n "$MOD" ] && exec "$OUT/asi_host" "$MOD" "$FOLDER" "${3:-60}" "${4:-0}" "${5:-10}"
