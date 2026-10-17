#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
python3 Scripts/generate_imports.py
python3 Scripts/prepare_heap_diagnostics.py
python3 Scripts/prepare_memory_pressure.py
python3 Scripts/prepare_virtual_pad.py
python3 Scripts/prepare_script_menu.py
python3 Scripts/prepare_movie_wait.py
python3 Scripts/prepare_tv_without_video.py
python3 Scripts/prepare_missing_txd.py
python3 Scripts/prepare_missing_scaleform.py
python3 Scripts/prepare_unchecked_memory.py
python3 Scripts/prepare_trap_context.py
python3 Scripts/prepare_scenario_blockers.py
python3 Scripts/prepare_level_index.py
python3 Scripts/prepare_fixup_guard.py
python3 Scripts/prepare_format_strings.py
python3 Scripts/prepare_video_memory.py
python3 Scripts/prepare_plain_dsp.py
python3 Scripts/prepare_cash_stats.py
python3 Scripts/prepare_native_opus.py
python3 Scripts/prepare_render_list_guard.py
python3 Scripts/prepare_stale_texture_slots.py
python3 Scripts/prepare_control_trace.py
python3 Scripts/prepare_pause_ready.py
python3 Scripts/prepare_heap_return.py
python3 Scripts/prepare_memory_file_create.py
python3 Scripts/prepare_longjmp.py
python3 Scripts/build_opus.py --sdk iphoneos
python3 Scripts/build_metal_shaders.py "${PG_SHADER_DIR:-Build/Inputs/shaders}" --sdk iphoneos
xcodegen generate --spec project.yml
xcodebuild -project PlayGTA5Native.xcodeproj -scheme PlayGTA5Native \
  -configuration Release -sdk iphoneos -destination 'generic/platform=iOS' \
  -derivedDataPath Build/Release -jobs 2 -allowProvisioningUpdates \
  GCC_OPTIMIZATION_LEVEL=2 SWIFT_OPTIMIZATION_LEVEL=-O build
