"""HUD layout (GTA-197): the character switch wheel and the phone go where the player put them (Source/NativeHudLayout.c).

- DRAW_SCALEFORM_MOVIE's handler calls pg_hud_scaleform before it draws: the "selector" script's switch wheel and its
  stats panel move and size by the player's choice.
- SET_MOBILE_PHONE_POSITION's handler calls pg_hud_phone_set after it stores the phone's place (19505776); the
  GET_MOBILE_PHONE_POSITION handler calls pg_hud_phone_get before it returns, so the phone scripts get back the
  place they set (they compare it with their own to see whether the phone is up).
- SET_MOBILE_PHONE_SCALE / GET_MOBILE_PHONE_SCALE (6973188) the same way for the phone's size (GTA-197 follow-up).

Idempotent; the anchors don't depend on the memory accessors' spelling, so it works before or after
prepare_plain_engine.py.
"""
from pathlib import Path
from engine_names import fn
import re
root = Path(__file__).resolve().parents[1]
DRAW = fn('graphics_commands::SetupScriptCommands()::scrWrapped_DRAW_SCALEFORM_MOVIE::Call(rage::scrThread::Info&)')
SET = fn('gta_commands::SetupScriptCommands()::scrWrapped_SET_MOBILE_PHONE_POSITION::Call(rage::scrThread::Info&)')
GET = fn('gta_commands::SetupScriptCommands()::scrWrapped_GET_MOBILE_PHONE_POSITION::Call(rage::scrThread::Info&)')
SET_SCALE = fn('gta_commands::SetupScriptCommands()::scrWrapped_SET_MOBILE_PHONE_SCALE::Call(rage::scrThread::Info&)')
GET_SCALE = fn('gta_commands::SetupScriptCommands()::scrWrapped_GET_MOBILE_PHONE_SCALE::Call(rage::scrThread::Info&)')
DECLARATIONS = ('extern void pg_hud_scaleform(w2c_game *instance, u32 movie, f32 *x, f32 *y, f32 *width, f32 *height);\n'
                'extern void pg_hud_phone_set(w2c_game *instance);\n'
                'extern void pg_hud_phone_get(w2c_game *instance, u64 out);\n'
                'extern void pg_hud_phone_scale_set(w2c_game *instance);\n'
                'extern void pg_hud_phone_scale_get(w2c_game *instance, u64 out);\n')
# The draw: the handler unpacks the movie (var_i0) and x, y, width, height (var_f1-4), then calls the command.
DRAW_CALL = re.compile(r'^(?P<i>[ ]+)(?P<call>w2c_game_f\d+\(instance, var_i0, var_f1, var_f2, var_f3, var_f4, var_i5, var_i6, var_i7, var_i8, var_i9\);)\n', re.M)
HOOKS = {
    DRAW: ('pg_hud_scaleform(', lambda body: DRAW_CALL.subn(
        lambda m: f'{m["i"]}pg_hud_scaleform(instance, var_i0, &var_f1, &var_f2, &var_f3, &var_f4);\n{m["i"]}{m["call"]}\n', body, count=1)),
    # The set stores x, y, z at 19505776-84 last; the get leaves its out pointer in var_p0.
    SET: ('pg_hud_phone_set(', lambda body: re.subn(r'\n  FUNC_EPILOGUE;$', '\n  pg_hud_phone_set(instance);\n  FUNC_EPILOGUE;', body, count=1)),
    GET: ('pg_hud_phone_get(', lambda body: re.subn(r'\n  FUNC_EPILOGUE;$', '\n  pg_hud_phone_get(instance, var_p0);\n  FUNC_EPILOGUE;', body, count=1)),
    # The scale's set stores it at 6973188 last; the get loads its out pointer into var_j0 and stores the scale there.
    SET_SCALE: ('pg_hud_phone_scale_set(', lambda body: re.subn(r'\n  FUNC_EPILOGUE;$', '\n  pg_hud_phone_scale_set(instance);\n  FUNC_EPILOGUE;', body, count=1)),
    GET_SCALE: ('pg_hud_phone_scale_get(', lambda body: re.subn(r'\n  FUNC_EPILOGUE;$', '\n  pg_hud_phone_scale_get(instance, var_j0);\n  FUNC_EPILOGUE;', body, count=1)),
}
CHECKS = {SET: '19505776ull', GET: '19505788ull', SET_SCALE: '6973188ull', GET_SCALE: '6973188ull'}
done = set()
for path in sorted((root / 'Generated').glob('game_*.c')):
    s = original = path.read_text()
    for function, (marker, patch) in HOOKS.items():
        found = re.search(r'^void w2c_game_f' + str(function) + r'\(w2c_game\* instance, u64 var_p0\) \{$', s, re.M)
        if not found: continue
        start = found.start(); end = s.index('\n}\n', start); body = s[start:end]
        done.add(function)
        if marker in body: continue
        if function in CHECKS and CHECKS[function] not in body:
            raise RuntimeError(f'Pinned f{function} (phone position handler) changed')
        body, count = patch(body)
        if count != 1: raise RuntimeError(f'Pinned f{function} (HUD layout hook) changed')
        s = s[:start] + body + s[end:]
    if s != original:
        if 'pg_hud_phone_scale_get(w2c_game' not in s:
            first = re.search(r'^#include "game-[\w-]*impl\.h"\n', s, re.M)
            if not first: raise RuntimeError(f'{path.name}: no engine header include')
            s = s[:first.end()] + DECLARATIONS + s[first.end():]
        path.write_text(s)
        print(f'HUD layout: hooks in {path.name}')
missing = set(HOOKS) - done
if missing: raise RuntimeError('Pinned functions not found: ' + ', '.join(f'f{f}' for f in sorted(missing)))
