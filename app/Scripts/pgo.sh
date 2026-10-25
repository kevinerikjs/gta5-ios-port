#!/bin/bash
# Profile-guided optimization of the app (GTA-172): an instrumented simulator build plays representative scenes, and its
# profile (plus a list of the hottest functions for the linker) feeds the release build:
#   PG_PGO_PROFILE=Build/PGO/game.profdata PG_ORDER_FILE=Build/PGO/hot.order ./build_ipa.sh ...
# Run from app/ after Scripts/prepare.py (Generated/ must be the code being released). Headless: needs a booted-able
# simulator (GTA_SIM, its UDID), the game files (GTA_GAME_FOLDER) and about 25 minutes.
#   Scripts/pgo.sh gen      instrumented simulator build -> Build/PGOGen
#   Scripts/pgo.sh train    the city drive, the built-in benchmark and Story mode; profiles -> Build/PGO/raw
#   Scripts/pgo.sh merge    -> Build/PGO/game.profdata and Build/PGO/hot.order
set -u
cd "$(dirname "$0")/.." || exit 1
P=$PWD/Build/PGO; mkdir -p "$P/raw"
GEN=Build/PGOGen
APP=$PWD/$GEN/Build/Products/Release-iphonesimulator/PlayGTA5Native.app
case "${1:-}" in
gen)
  python3 Scripts/build_opus.py --sdk iphonesimulator >/dev/null && python3 Scripts/build_blink.py --sdk iphonesimulator >/dev/null &&
  python3 Scripts/build_metal_shaders.py Build/Inputs/shaders --sdk iphonesimulator >/dev/null || exit 1
  xcodebuild -project PlayGTA5Native.xcodeproj -scheme PlayGTA5Native -configuration Release -sdk iphonesimulator \
    -destination 'generic/platform=iOS Simulator' -derivedDataPath "$GEN" -jobs "${JOBS:-8}" ARCHS=arm64 ONLY_ACTIVE_ARCH=YES \
    GCC_OPTIMIZATION_LEVEL=2 SWIFT_OPTIMIZATION_LEVEL=-O CODE_SIGNING_ALLOWED=NO DEBUG_INFORMATION_FORMAT=dwarf \
    OTHER_CFLAGS='$(inherited) -fprofile-instr-generate' OTHER_LDFLAGS='$(inherited) -fprofile-instr-generate' build > "$GEN.log" 2>&1
  grep -E "error:|BUILD (SUCCEEDED|FAILED)" "$GEN.log" | head -5 ;;
train)
  : "${GTA_SIM:?the simulator UDID}" "${GTA_GAME_FOLDER:?the game folder}"
  export GTA_APP=$APP
  rm -f "$P"/raw/*.profraw
  # %m: the runs of one binary merge into one file. The debug channel's "pgo" writes it (a run ends by killing the app).
  PROFILE="LLVM_PROFILE_FILE=$P/raw/game-%m.profraw"
  python3 Harness/gta.py launch sandbox --install --arg -graphicsPreset --arg 1 --env PG_SIM_MEMORY_LIMIT_MB=6144 --env "$PROFILE" | tail -1
  python3 Harness/scenarios/texture_thrash.py 240 pgo-drive > "$P/train-drive.txt" 2>&1
  python3 Harness/gta.py raw pgo | tail -1
  SIMCTL_CHILD_PG_BENCHMARK=1 SIMCTL_CHILD_PG_BENCHMARK_ITERATIONS=2 SIMCTL_CHILD_PG_BENCHMARK_FRAME_LIMIT=2 \
  SIMCTL_CHILD_LLVM_PROFILE_FILE="$P/raw/game-%m.profraw" SIMCTL_CHILD_PG_TEST_NO_MODS_NOTICE=1 \
    xcrun simctl launch --terminate-running-process "$GTA_SIM" io.github.playgta5ios.app --local-game-folder "$GTA_GAME_FOLDER" --mute --boot-engine > /dev/null
  python3 -c "import time; time.sleep(330)"
  python3 Harness/gta.py raw pgo | tail -1
  python3 Harness/gta.py launch story --env "$PROFILE" | tail -1
  python3 -c "import time; time.sleep(180)"
  python3 Harness/gta.py raw pgo | tail -1
  xcrun simctl shutdown "$GTA_SIM"
  ls -la "$P"/raw ;;
merge)
  xcrun llvm-profdata merge -o "$P/game.profdata" "$P"/raw/*.profraw || exit 1
  # The linker order: the hottest global functions first (an order file names only global ones).
  xcrun llvm-profdata show --topn=12000 "$P/game.profdata" | python3 -c '
import re, sys
names = [m.group(1) for m in (re.match(r"\s+(\S+), max count = \d+", l) for l in sys.stdin) if m and ":" not in m.group(1)]
open(sys.argv[1], "w").write("".join("_" + n + "\n" for n in names)); print(len(names), "functions in", sys.argv[1])' "$P/hot.order"
  ls -la "$P/game.profdata" ;;
*) echo "usage: Scripts/pgo.sh gen|train|merge"; exit 1 ;;
esac
