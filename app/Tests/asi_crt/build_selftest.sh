#!/bin/bash
# Builds the runtime self-test mod (GTA-188) with Apple's clang for x86_64-pc-windows-msvc and Tests/asi_crt/link_pe.py.
#   Tests/asi_crt/build_selftest.sh <output folder>   -> <output folder>/RuntimeSelfTest.asi
# Run it with Tests/asi_crt/run_host.sh <output folder>/RuntimeSelfTest.asi, or install it as a mod.
set -e
cd "$(dirname "$0")"
OUT=${1:-/tmp/asi_selftest}; mkdir -p "$OUT"
FLAGS="-target x86_64-pc-windows-msvc -fms-extensions -fms-compatibility -O1 -fno-builtin -fno-stack-protector"
xcrun clang $FLAGS -fexceptions -fcxx-exceptions -std=c++17 -c selftest.cpp -o "$OUT/selftest.obj"
xcrun clang $FLAGS -c selftest_seh.c -o "$OUT/selftest_seh.obj"
python3 link_pe.py -o "$OUT/RuntimeSelfTest.asi" "$OUT/selftest.obj" "$OUT/selftest_seh.obj"
