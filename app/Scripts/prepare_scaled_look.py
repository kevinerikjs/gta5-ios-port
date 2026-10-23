"""Scaled look follows the look stick (GTA-163: Eye in the Sky's helicopter camera can't be aimed).

Some mission cameras read INPUT_SCALED_LOOK_LR/UD (290/291) instead of INPUT_LOOK_LR/UD (1/2): the helicopter camera in
Eye in the Sky (carsteal2) points itself with GET_DISABLED_CONTROL_NORMAL and GET_DISABLED_CONTROL_UNBOUND_NORMAL of
290/291 every frame. In this port the scaled look inputs stay at 0 for the pad: with the right stick held, input 1
read 1.0 and input 220 (the script right stick) 1.0, but 290 read 0 (simulator), so the camera never moved, neither
from the touch controls nor from a controller, and the target got out of range.

Where a script reads 290 or 291 and gets 0, it now gets the look input on the same axis (1 or 2) instead. With a mouse
the scaled inputs carry the mouse movement, so they aren't 0 and nothing changes there.

Needs Scripts/prepare_control_trace.py first: it wraps these commands, and this patches the wrappers.
"""
from pathlib import Path
from engine_names import fn
import re
root = Path(__file__).resolve().parents[1]
MEMORY = 'wasm_rt_local_memory_base, wasm_rt_local_memory_size, instance->w2c_env_memory, '
MARK = '/* GTA-163: scaled look */'

# The command functions (the original is pg_control_original_fN, the wrapper calls it once).
COMMANDS = ['pad_commands::CommandGetControlNormal(int, int)', 'pad_commands::CommandGetDisabledControlNormal(int, int)',
            'pad_commands::CommandGetControlUnboundNormal(int, int)', 'pad_commands::CommandGetDisabledControlUnboundNormal(int, int)']
# The script commands that read the input themselves (the wrapper calls pg_control_script_original_fN): the answer is
# written through the thread info (+0 where the answer goes, +16 the arguments: control, input); the look value comes
# from the matching command function above.
SCRIPT_COMMANDS = {'GET_CONTROL_UNBOUND_NORMAL': 'pad_commands::CommandGetControlUnboundNormal(int, int)',
                   'GET_DISABLED_CONTROL_UNBOUND_NORMAL': 'pad_commands::CommandGetDisabledControlUnboundNormal(int, int)'}

def files():
    return sorted((root / 'Generated').glob('game_*.c'))

def patch(path, s):
    path.write_text(s)

for name in COMMANDS:
    function = fn(name)
    call = f'  f32 value = pg_control_original_f{function}(instance, var_p0, var_p1);\n'
    path = next((p for p in files() if call in p.read_text()), None)
    if path is None: raise RuntimeError(f'f{function} ({name}) has no control trace wrapper: run prepare_control_trace.py first')
    s = path.read_text()
    if MARK in s[s.index(call):s.index(call) + 600]: print(f'scaled look: f{function} already patched'); continue
    fallback = (f'  if ((var_p1 == 290u || var_p1 == 291u) && value == 0.0f) {MARK}\n'
                f'    value = pg_control_original_f{function}(instance, var_p0, var_p1 == 290u ? 1u : 2u);\n')
    patch(path, s.replace(call, call + fallback, 1))
    print(f'scaled look: patched f{function} in {path.name}')

for command, source in SCRIPT_COMMANDS.items():
    function = fn(f'pad_commands::SetupScriptCommands()::scrWrapped_{command}::Call(rage::scrThread::Info&)')
    call = f'  pg_control_script_original_f{function}(instance, var_p0);\n'
    path = next((p for p in files() if call in p.read_text()), None)
    if path is None: raise RuntimeError(f'f{function} ({command}) has no control trace wrapper: run prepare_control_trace.py first')
    s = path.read_text()
    if MARK in s[s.index(call):s.index(call) + 900]: print(f'scaled look: f{function} ({command}) already patched'); continue
    fallback = (f'  {{ {MARK}\n'
                f'    u64 a = i64_load_shared({MEMORY}(u64)checked_add_u64(var_p0, 16u)), out = i64_load_shared({MEMORY}(u64)(var_p0));\n'
                f'    u32 input = i32_load_shared({MEMORY}(u64)checked_add_u64(a, 8u));\n'
                f'    if ((input == 290u || input == 291u) && f32_load_shared({MEMORY}(u64)(out)) == 0.0f)\n'
                f'      f32_store_shared({MEMORY}(u64)(out), w2c_game_f{fn(source)}(instance, i32_load_shared({MEMORY}(u64)(a)), input == 290u ? 1u : 2u));\n'
                f'  }}\n')
    patch(path, s.replace(call, call + fallback, 1))
    print(f'scaled look: patched f{function} ({command}) in {path.name}')
