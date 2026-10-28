"""Each engine function reads the engine memory's address once (GTA-216).

wasm2c gives every generated function a local `wasm_rt_local_memory_base` and passes it to every load and store
helper, but for a shared memory it sets it to NULL, and the helpers find the memory through
instance->w2c_env_memory->data on every access. Those are two dependent loads per access, and because any store
to engine memory may alias them (the instance and the memory descriptor are ordinary memory to the compiler), they
are loaded again after every store. The engine's memory is reserved in full at boot and never moves (growing it
only raises its size, NativeThreads.c), so the address can be read once per call and kept in a register.

With PG_LOCAL_MEMORY_BASE=1 (project.yml) every function starts with the memory's address in that local and the
helpers (game-impl.h, game-heap-impl.h, game-plain-impl.h, Source/SharedSIMD.h) add to it. With 0 the local is NULL
and the helpers use instance->w2c_env_memory->data as before. Idempotent; run after every script that writes
generated code (last in prepare.py and build_native.sh).
"""
from pathlib import Path
import re
root = Path(__file__).resolve().parents[1]
OLD = '  uint8_t* const wasm_rt_local_memory_base = NULL;\n'
NEW = '  uint8_t* const wasm_rt_local_memory_base = PG_FUNCTION_MEMORY_BASE(instance);\n'
functions = files = 0
for path in sorted((root / 'Generated').glob('game_*.c')):
    s = path.read_text()
    n = s.count(OLD)
    if n:
        path.write_text(s.replace(OLD, NEW)); functions += n; files += 1
done = sum(p.read_text().count(NEW) for p in (root / 'Generated').glob('game_*.c'))
# The helpers: shared (atomic) and plain accesses address the memory through the function's local base.
helpers = 0
for name in ['game-impl.h', 'game-heap-impl.h', 'game-plain-impl.h']:
    path = root / 'Generated' / name
    if not path.exists(): continue
    s = path.read_text(); t = s
    t = re.sub(r'MEM_ADDR\(mem, addr, (sizeof\(t[12]\)|16)\)', r'PG_MEM_ADDR(wasm_rt_local_memory_base, mem, addr, \1)', t)
    if name == 'game-plain-impl.h':   # its helpers name the base parameter "base"
        t = t.replace('PG_MEM_ADDR(wasm_rt_local_memory_base, mem,', 'PG_MEM_ADDR(base, mem,')
        t = t.replace('(void)base; ', '')
    if t != s: path.write_text(t); helpers += 1
left = sum(len(re.findall(r'MEM_ADDR\(mem, addr, (?:sizeof\(t[12]\)|16)\)', (root / 'Generated' / n).read_text()))
           for n in ['game-impl.h', 'game-heap-impl.h', 'game-plain-impl.h'] if (root / 'Generated' / n).exists())
if left: raise RuntimeError(f'memory base: {left} helper accesses still use MEM_ADDR(mem, ...)')
print(f'memory base: {functions} functions changed now in {files} files ({done} in all), {helpers} helper headers changed')
