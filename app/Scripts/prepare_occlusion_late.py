"""A late occlusion query answer keeps the last one instead of reading as "hidden" (GTA-176: lights flicker).

rage::grcDevice::GetOcclusionQueryData asks D3D's GetData for a query's visible pixel count and writes it to the caller's
variable; when the answer isn't there yet (S_FALSE) it writes 0 and returns false. OcclusionQueries (in
CGtaRenderThreadGameInterface::PerformSafeModeOperations) ignores the return and keeps that 0 in its results array, so
an answer that comes late reads as "no pixel visible" for that frame. On PC answers come back within a frame or two;
here they arrive when the Metal command buffer completes, later while the game streams. Players and Kevin saw lights
flicker at night, most while the game was loading (Telegram 27977; the Mac app too).

Now a late answer leaves the variable as it was (the last answer), and pg_occlusion_late counts it for the log.
PG_OQ_ZERO_LATE=1 keeps the old behavior, for A/B runs. PG_OQ_LATE_READY=1 also reports the late answer as ready,
so callers that check (one stores -1, "unknown", when an answer is late) use the last answer too.
"""
from pathlib import Path
from engine_names import fn
import re
root = Path(__file__).resolve().parents[1]
NUMBER = fn('rage::grcDevice::GetOcclusionQueryData(IUnknown*, unsigned int&)')
MEMORY = 'wasm_rt_local_memory_base, wasm_rt_local_memory_size, instance->w2c_env_memory, '
STORE = ('  var_i3 = var_l4;\n'
         '  var_i1 = var_i3 ? var_i1 : var_i2;\n'
         f'  i32_store_shared({MEMORY}(u64)(var_j0), var_i1);\n')
PATCH = ('  var_i3 = var_l4;\n'
         '  var_i1 = var_i3 ? var_i1 : var_i2;\n'
         f'  {{ u32 late = pg_occlusion_late(var_i3); if (!late) i32_store_shared({MEMORY}(u64)(var_j0), var_i1); else if (late == 2) var_l4 = 0; }}   /* GTA-176 */\n')
DECLARATION = 'extern u32 pg_occlusion_late(u32 hr);'

head_re = re.compile(r'^u32 w2c_game_f' + str(NUMBER) + r'\(w2c_game\* instance[^{]*\{$', re.M)
path = next(p for p in sorted((root / 'Generated').glob('game_*.c')) if head_re.search(p.read_text()))
s = path.read_text()
start = head_re.search(s).start(); end = s.index('\n}\n', start) + 3
body = s[start:end]
if 'pg_occlusion_late(' in body:
    print('occlusion late: already patched'); raise SystemExit
if body.count(STORE) != 1: raise RuntimeError(f'Pinned f{NUMBER} (grcDevice::GetOcclusionQueryData) changed')
s = s[:start] + body.replace(STORE, PATCH, 1) + s[end:]
if DECLARATION not in s:
    first = re.search(r'^#include "game-[a-z-]*impl\.h"$', s, re.M)
    s = s[:first.end()] + '\n' + DECLARATION + s[first.end():]
path.write_text(s)
print(f'occlusion late: patched f{NUMBER} in {path.name}')
