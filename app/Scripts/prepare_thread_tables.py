"""Engine thread function tables from Source/NativeThreads.c (GTA-192: the app crashed right after Casing the Jewel Store).

Every engine thread is a module instance with its own indirect function table (89368 entries, 2.9 MB), and
wasm2c_game_instantiate calloc'd it on the new thread without checking: on a player's iPad the calloc for the autosave's
save list thread returned NULL, and the table fill wrote to address 0x20 (log 2438, wasm2c_game_instantiate+0x1cc).

init_tables now takes its table from pg_allocate_funcref_table (a table reserved in pthread_create, a kept one, or a new
one), and wasm2c_game_free gives it back through pg_free_funcref_table, so later threads reuse it.

    python3 Scripts/prepare_thread_tables.py [GENERATED_DIR]
"""
from pathlib import Path
import sys
root = Path(__file__).resolve().parents[1]
generated = Path(sys.argv[1]) if len(sys.argv) > 1 else root / 'Generated'
MARK = '/* GTA-192: thread tables */'
DECLARATION = (f'{MARK}\nvoid pg_allocate_funcref_table(wasm_rt_funcref_table_t*, uint32_t, uint32_t);\n'
               'void pg_free_funcref_table(wasm_rt_funcref_table_t*);\n')
ALLOCATE = '  wasm_rt_allocate_funcref_table(&instance->w2c_0x5F_indirect_function_table, '
FREE = '  wasm_rt_free_funcref_table(&instance->w2c_0x5F_indirect_function_table);\n'

path = next(p for p in sorted(generated.glob('game_*.c')) if 'static void init_tables(w2c_game* instance) {' in p.read_text())
s = path.read_text()
if MARK in s:
    print(f'thread tables: {path.name} already patched'); sys.exit(0)
head = 'static void init_tables(w2c_game* instance) {\n'
start = s.index(head)
if s.count(ALLOCATE) != 1 or s.index(ALLOCATE) != start + len(head): raise RuntimeError('init_tables changed')
free_head = 'void wasm2c_game_free(w2c_game* instance) {\n'
if s.count(free_head) != 1 or s.count(FREE) != 1 or s.index(FREE) != s.index(free_head) + len(free_head):
    raise RuntimeError('wasm2c_game_free changed')
s = s.replace(ALLOCATE, ALLOCATE.replace('wasm_rt_allocate_funcref_table', 'pg_allocate_funcref_table'), 1)
s = s.replace(FREE, FREE.replace('wasm_rt_free_funcref_table', 'pg_free_funcref_table'), 1)
s = s[:start] + DECLARATION + s[start:]
path.write_text(s)
print(f'thread tables: patched init_tables and wasm2c_game_free in {path.name}')
