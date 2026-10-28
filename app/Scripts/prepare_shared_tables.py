"""One function table for every engine thread (GTA-217; Source/NativeThreads.c pg_allocate_funcref_table).

Every engine thread is a module instance with its own copy of the indirect function table (89368 entries, 2.9 MB;
28 copies, 76 MB, in a city drive). Each entry holds the instance its function belongs to, but every entry of this
module's table is one of its own functions (module offset 0 in elem_segment_exprs), so that instance is always the one
whose table it is: the caller's. This passes the caller's `instance` to indirect calls instead of the entry's
module_instance (the same pointer today), and lets init_tables leave a shared table alone, so the threads can use the
main instance's table. Must run after every other prepare script that matches call_indirect lines.

    python3 Scripts/prepare_shared_tables.py [GENERATED_DIR]
"""
from pathlib import Path
import re
import sys
root = Path(__file__).resolve().parents[1]
generated = Path(sys.argv[1]) if len(sys.argv) > 1 else root / 'Generated'
MARK = '/* GTA-217: shared function table */'
ENTRY = re.compile(r'instance->w2c_0x5F_indirect_function_table\.data\[(var_[A-Za-z0-9_]+)\]\.module_instance')
INIT = '  funcref_table_init(&instance->w2c_0x5F_indirect_function_table, '
DECLARATION = f'{MARK}\n#include <stdbool.h>\nbool pg_funcref_table_shared(wasm_rt_funcref_table_t*);\n'

files = sorted(generated.glob('game_*.c'))
calls = 0
patched = 0
for path in files:
    s = path.read_text()
    if MARK in s:
        continue
    t, n = ENTRY.subn('instance', s)
    if 'static void init_tables(w2c_game* instance) {' in t:
        # The module's own elements only: a non-zero module offset would be an import with another instance.
        e0 = t.index('elem_segment_exprs_w2c_game_e0[] = {')
        body = t[e0:t.index('\n};\n', e0)]
        others = [l for l in body.split('\n')[1:] if l.strip() and not l.rstrip().endswith(', 0},')]
        if others:
            raise RuntimeError(f'the function table has entries with another instance: {others[:2]}')
        if t.count(INIT) != 1:
            raise RuntimeError('init_tables changed: funcref_table_init of the indirect function table not found once')
        t = t.replace(INIT, '  if (!pg_funcref_table_shared(&instance->w2c_0x5F_indirect_function_table))\n' + INIT, 1)
        start = t.index('static void init_tables(w2c_game* instance) {')
        t = t[:start] + DECLARATION + t[start:]
    if n or t != s:
        t = MARK + '\n' + t if MARK not in t else t
        path.write_text(t)
        patched += 1
        calls += n
left = sum(len(ENTRY.findall(p.read_text())) for p in files)
if left:
    raise RuntimeError(f'{left} indirect calls still pass the entry instance')
print(f'shared function table: {calls} indirect calls pass the caller instance, {patched} files patched')
