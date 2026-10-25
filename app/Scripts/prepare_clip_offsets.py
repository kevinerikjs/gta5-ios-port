"""The coin-op telescopes on the beach and the piers open their view again (GTA-193, player log 2366: "spent a dollar
at the beach but can't use the telescope").

ob_telescope walks the player to where the clip mini@telescope PUBLIC_ENTER_FRONT starts (GET_ANIM_INITIAL_OFFSET_*),
plays it and PUBLIC_IDLE from the telescope's position and rotation (TASK_PLAY_ANIM_ADVANCED), and opens the view only
if the player is then within 1 m of a spot 0.2 m right of and 0.96 m in front of the telescope. The game files' clips
start a quarter turn counter-clockwise from that spot: their InitialOffset properties put PUBLIC_ENTER_FRONT at
(-0.958, -0.095) facing -90 degrees in the telescope's frame, PUBLIC_IDLE at (-0.740, 0.203). The player looked through
the air beside the telescope, 1.2 m from the spot, and the script gave control back. Turned a quarter turn clockwise
the starts are (-0.095, 0.958) and (0.203, 0.740) facing the eyepiece, the spot the script was written for.
The engine reads these values correctly (simulator: the values in memory are exactly what it applies; the same
dictionary's UPRIGHT_ENTER_FRONT matches its own script spot), so this corrects the data, not the maths.

Both rage::fwAnimHelpers::ApplyInitialOffsetFromClip versions (the only readers of a clip's start: the GET_ANIM_
INITIAL_OFFSET_* natives, CTaskScriptedAnimation, synced scenes, animated cameras) now first call
pg_clip_offset_fix (Source/EngineHost.c), which corrects those three clips in place when it finds them by name and
exact values. Idempotent; the call goes at the function's start, so it matches every spelling of the body.
"""
from pathlib import Path
from engine_names import fn
import re
root = Path(__file__).resolve().parents[1]
MARK = '/* GTA-193: telescope clip start */'
DECLARATION = 'extern void pg_clip_offset_fix(w2c_game *instance, u64 clip);\n'
PROLOGUE = '  (void)wasm_rt_local_memory_size;\n'
TARGETS = {
    fn('rage::fwAnimHelpers::ApplyInitialOffsetFromClip(rage::crClip const&, rage::Vector3&, rage::Quaternion&)'):
        r'^u32 w2c_game_f%d\(w2c_game\* instance, u64 var_p0, u64 var_p1, u64 var_p2\) \{$',
    fn('rage::fwAnimHelpers::ApplyInitialOffsetFromClip(rage::crClip const&, rage::Matrix34&)'):
        r'^void w2c_game_f%d\(w2c_game\* instance, u64 var_p0, u64 var_p1\) \{$',
}
for number, pattern in TARGETS.items():
    head = re.compile(pattern % number, re.M)
    for path in sorted((root / 'Generated').glob('game_*.c')):
        s = path.read_text()
        found = head.search(s)
        if not found: continue
        end = s.index('\n}\n', found.start())
        body = s[found.start():end]
        if MARK in body: print(f'clip offsets: f{number} already patched'); break
        if body.count(PROLOGUE) != 1: raise RuntimeError(f'Pinned f{number} (ApplyInitialOffsetFromClip) changed')
        body = body.replace(PROLOGUE, PROLOGUE + f'  pg_clip_offset_fix(instance, var_p0);  {MARK}\n', 1)
        s = s[:found.start()] + body + s[end:]
        if DECLARATION not in s:
            header = re.search(r'^#include "game-[\w-]*impl\.h"\n', s, re.M)
            if not header: raise RuntimeError(f'{path.name}: no engine header include')
            s = s[:header.end()] + DECLARATION + s[header.end():]
        path.write_text(s)
        print(f'clip offsets: patched f{number} in {path.name}')
        break
    else:
        raise RuntimeError(f'Pinned function f{number} (ApplyInitialOffsetFromClip) not found')
