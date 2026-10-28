#!/bin/bash
# Build the Mac app from YOUR OWN game files: GTA5Port-mac.zip with "GTA V Port.app" inside.
# Usage: ./build_mac_app.sh --mirror /path/to/game-folder   (the folder with data/manifest.json and b/)
# Needs: an Apple Silicon Mac, Xcode, xcodegen. The app runs on Apple Silicon Macs with macOS 13 or newer.
set -euo pipefail
[ "${1:-}" = "--mirror" ] && [ -n "${2:-}" ] || { echo "Usage: ./build_mac_app.sh --mirror /path/to/game-folder"; exit 1; }
MIRROR="$(cd "$2" && pwd)"
cd "$(dirname "$0")/app"
# The system Python runs natively on Apple Silicon (a Rosetta Python would
# make the engine tools build for the wrong CPU).
PY="${PYTHON:-/usr/bin/python3}"
"$PY" Scripts/check_game_files.py --mirror "$MIRROR"
"$PY" Scripts/prepare.py --mirror "$MIRROR"
MAC_JOBS="${JOBS:-$(sysctl -n hw.ncpu)}" Scripts/build_mac.sh > Build/xcodebuild-mac.log 2>&1 || {
  grep -E 'error:' Build/xcodebuild-mac.log | head -20
  echo "Build failed; the full log is app/Build/xcodebuild-mac.log"; exit 1; }
grep -E 'BUILD SUCCEEDED' Build/xcodebuild-mac.log
if [ -n "${PG_PGO_PROFILE:-}" ]; then "$PY" Scripts/pgo_check.py Build/xcodebuild-mac.log || exit 1; fi

# build_mac.sh signs the app ad hoc (not notarized): macOS asks once before it opens a downloaded copy
# (System Settings › Privacy & Security › Open Anyway). docs/MAC.md explains it.
STAGE=Build/MacZip
rm -rf "$STAGE" && mkdir -p "$STAGE"
ditto Build/Mac/Build/Products/Release-maccatalyst/PlayGTA5Native.app "$STAGE/GTA V Port.app"
codesign --verify --strict "$STAGE/GTA V Port.app"
rm -f ../GTA5Port-mac.zip
ditto -c -k --keepParent "$STAGE/GTA V Port.app" ../GTA5Port-mac.zip
echo "Done: $(cd .. && pwd)/GTA5Port-mac.zip"
