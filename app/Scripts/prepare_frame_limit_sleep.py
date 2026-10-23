"""The frame limiter sleeps the last stretch instead of spinning (GTA-169: heat).

CSystem::EndRender (the render thread's "Frame Limit") waits for the frame's time with sysIpcSleep in whole
milliseconds, keeping back an estimate of how late sleeps wake up (at least 1.5 ms, at 7377528). When less than that
is left it loops reading the clock until it is within 5% of the frame time. In this port sleeps wake up within a
fraction of a millisecond, so that loop spins for 1-2 ms of every frame: the engine's own profile showed 5-10% of the
render thread as "Frame Limit" outside "[sleep]" (lab simulator, 30 FPS).

Where it would spin, it now sleeps what is left up to the same 5% margin (pg_frame_limit_sleep, microseconds), then
the loop sees the time is up as before. Frame pacing is unchanged; the core rests instead of spinning.
"""
from pathlib import Path
from engine_names import fn
import re
root = Path(__file__).resolve().parents[1]
NUMBER = fn('CSystem::EndRender()')
MEMORY = 'wasm_rt_local_memory_base, wasm_rt_local_memory_size, instance->w2c_env_memory, '
# The path where the remaining whole milliseconds are 0 or less: no sleep, the loop goes round again.
SPIN = ('      var_j0 = 7377528ull;\n'
        f'      var_f0 = f32_load_shared({MEMORY}(u64)(var_j0));\n'
        '      var_l16 = var_f0;\n'
        '      var_f0 = var_l18;\n'
        '      var_l15 = var_f0;\n'
        '      var_B30:;\n')
PATCH = '      pg_frame_limit_sleep(var_l17 - var_l19 - var_l18);   /* GTA-169: sleep instead of spinning */\n'
DECLARATION = 'extern void pg_frame_limit_sleep(f32 seconds);'

head_re = re.compile(r'^void w2c_game_f' + str(NUMBER) + r'\(w2c_game\* instance[^{]*\{$', re.M)
path = next(p for p in sorted((root / 'Generated').glob('game_*.c')) if head_re.search(p.read_text()))
s = path.read_text()
start = head_re.search(s).start(); end = s.index('\n}\n', start) + 3
body = s[start:end]
if 'pg_frame_limit_sleep(' in body:
    print('frame limit sleep: already patched'); raise SystemExit
if body.count(SPIN) != 1 or '324827ull' not in body: raise RuntimeError(f'Pinned f{NUMBER} (CSystem::EndRender frame limit) changed')
s = s[:start] + body.replace(SPIN, PATCH + SPIN, 1) + s[end:]
if DECLARATION not in s:
    first = re.search(r'^#include "game-[a-z-]*impl\.h"$', s, re.M)
    s = s[:first.end()] + '\n' + DECLARATION + s[first.end():]
path.write_text(s)
print(f'frame limit sleep: patched f{NUMBER} in {path.name}')
