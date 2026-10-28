"""Plain memory accesses for a chosen set of engine functions (the plain-memory work after the audio, GTA-187).

wasm2c compiles every ordinary load and store on the engine's shared memory as a relaxed atomic on a volatile
pointer with a forced read (see prepare_plain_dsp.py), which keeps the compiler from optimising engine code. The
audio got plain accesses in v1.3.3 (about a third cheaper). This does the same for any set of engine functions, so
the whole engine can be tried and, if something breaks, the set can be halved until the functions that need atomic
accesses are found. Wasm atomics (i32_atomic_*, wait, notify) are never touched.

The set comes from PG_PLAIN_ENGINE (or the first argument):
    off                 nothing (functions converted earlier go back to atomic)
    all                 every engine function (the default since v1.5.2, GTA-216: -31% instructions and -25% CPU energy
                        per frame on an iPhone 13 Pro Max at 30 FPS together with the other v1.5.2 engine changes)
    all-but:FILE        every function except the numbers in FILE (one per line, "f123" or "123", # comments)
    only:FILE           just the numbers in FILE
The functions in Scripts/plain-engine-keep.txt stay atomic in every set (hand-offs with no atomic on either side).
PG_PLAIN_V128=0 leaves the SIMD (v128) accesses atomic in the converted functions: today each of them is a full
compiler barrier, so making them plain is the biggest single change and the first thing to rule out if a set stalls.
Sync rules (GTA-216; PG_PLAIN_SYNC=1, the default for any set but off; PG_PLAIN_SYNC=0 converts as before). Another
team's native port of the game froze until its job scheduler got real barriers, volatile accesses with acquire and
release meaning (as MSVC compiles them) and full fences after interlocked operations. Here, in a plain set:
  - the engine's synchronisation code (by function name, SYNC_NAMES below: sysIpc*, sysInterlocked*, the dependency
    scheduler and task manager, message queues, GMutex/GWaitCondition, the streamer's request queues, musl's locks,
    waits and futexes) keeps atomic accesses, each ordinary load followed by an acquire fence and each ordinary store
    preceded by a release fence (*_sync helpers), and every wasm read-modify-write is followed by a full fence (*_fenced);
  - the functions with a loop that waits on another thread's memory (Scripts/plain-engine-waiting.txt, from
    Harness/plain_scan.py) keep their atomic accesses as today;
  - everything else gets plain accesses.
Engine conversions use *_eplain helpers (defined in game-plain-impl.h like the audio's *_plain, so PG_ATOMIC_DSP=1
turns both back into atomic accesses for comparisons). Running it again with another set converts and reverts in
place; the audio's *_plain accesses are left alone.
"""
import os, re, sys
from pathlib import Path

root = Path(__file__).resolve().parents[1]
spec = (sys.argv[1] if len(sys.argv) > 1 else os.environ.get('PG_PLAIN_ENGINE', 'all')).strip()

def numbers(path):
    out = set()
    for line in Path(path).read_text().splitlines():
        line = line.split('#', 1)[0].strip()
        if line: out.add(int(line.lstrip('f')))
    return out

atomic_always = numbers(root / 'Scripts/plain-engine-keep.txt')
if spec == 'off': picked = lambda n: False
elif spec == 'all': picked = lambda n: True
elif spec.startswith('all-but:'): skip = numbers(spec[8:]); picked = lambda n: n not in skip
elif spec.startswith('only:'): keep = numbers(spec[5:]); picked = lambda n: n in keep
else: raise SystemExit(f'PG_PLAIN_ENGINE: unknown set {spec!r} (off, all, all-but:FILE, only:FILE)')
chosen = lambda n: picked(n) and n not in atomic_always

# The sync rules (see above).
SYNC = spec != 'off' and os.environ.get('PG_PLAIN_SYNC', '1') != '0'
SYNC_NAMES = re.compile(r'^(?:[\w:<>, *&]*?\b)?(?:rage::)?(?:sysIpc\w*|sysInterlocked\w*|sysDependencyScheduler::\w+|sysTaskManager::\w+|'
    r'sysMessageQueue\w*|sysCriticalSection\w*|sysSpinLock\w*|sysLockFree\w*|sysCondVar\w*|GMutex\w*::\w+|GWaitCondition\w*::\w+|'
    r'pgStreamer(?:DeviceHandler)?::\w+|strStreamingLoader::\w+|strStreamingEngine::\w+|strRequestManager::\w+|'
    r'__pthread_\w+|pthread_\w+|__wait|__lock|__unlock|__lockfile|__unlockfile|__futexwait|_do_futex_wait|emscripten_futex_\w+|'
    r'__timedwait\w*|sem_\w+|__private_cond_signal|__pthread_cond_timedwait)(?:\(|$)')
def engine_names():
    out = {}
    path = root / 'Generated/funcnames.tsv'
    if path.exists():
        for line in path.read_text(errors='replace').splitlines():
            k, _, v = line.partition('\t')
            if k.isdigit(): out[int(k)] = v
    return out
sync_set, waiting_set = set(), set()
if SYNC:
    names = engine_names()
    if not names: raise SystemExit('PG_PLAIN_SYNC: Generated/funcnames.tsv is missing (Scripts/engine_names.py makes it)')
    sync_set = {n for n, v in names.items() if SYNC_NAMES.match(v)}
    waiting_set = numbers(root / 'Scripts/plain-engine-waiting.txt')

SCALAR = r'(?:i32|i64|f32|f64)_(?:load|store)(?:8_s|8_u|16_s|16_u|32_s|32_u|8|16|32)?'
ACCESS = r'(?:' + SCALAR + r'|v128_(?:load|store))'
V128 = os.environ.get('PG_PLAIN_V128', '1') != '0'
TO_PLAIN = re.compile(r'\b(' + (ACCESS if V128 else SCALAR) + r')_shared\(')
TO_ATOMIC = re.compile(r'\b(' + ACCESS + r')_(?:eplain|sync)\(')
V128_TO_ATOMIC = re.compile(r'\b(v128_(?:load|store))_eplain\(')
RMW = r'i(?:32|64)_atomic_rmw\w*'
RMW_FENCED = re.compile(r'\b(' + RMW + r')_fenced\(')
RMW_SHARED = re.compile(r'\b(' + RMW + r')_shared\(')
SCALAR_SHARED = re.compile(r'\b(' + SCALAR + r')_shared\(')

def convert(body, n):
    body = RMW_FENCED.sub(r'\1_shared(', TO_ATOMIC.sub(r'\1_shared(', body))   # back to wasm2c's code first
    if not chosen(n) or n in waiting_set: return body
    if n in sync_set: return RMW_SHARED.sub(r'\1_fenced(', SCALAR_SHARED.sub(r'\1_sync(', body))
    body = TO_PLAIN.sub(r'\1_eplain(', body)
    return body if V128 else V128_TO_ATOMIC.sub(r'\1_shared(', body)
HEAD = re.compile(r'^[a-z0-9]+ w2c_game_f(\d+)\(w2c_game\* instance[^\n]*\{$', re.M)
ALIASES = '\n'.join(f'#define {a}_eplain {a}_plain' for a in [
    'i32_load', 'i64_load', 'f32_load', 'f64_load', 'i32_load8_s', 'i64_load8_s', 'i32_load8_u', 'i64_load8_u',
    'i32_load16_s', 'i64_load16_s', 'i32_load16_u', 'i64_load16_u', 'i64_load32_s', 'i64_load32_u',
    'i32_store', 'i64_store', 'f32_store', 'f64_store', 'i32_store8', 'i32_store16', 'i64_store8', 'i64_store16', 'i64_store32',
    'v128_load', 'v128_store'])
include = '#include "game-plain-impl.h"'

plain = atomic = synced = 0
rmw_names = set()   # every wasm read-modify-write helper the engine uses, for the *_fenced definitions
for path in sorted((root / 'Generated').glob('game_*.c')):
    s = path.read_text()
    rmw_names.update(re.findall(r'\b(' + RMW + r')_(?:shared|fenced)\(', s))
    heads = list(HEAD.finditer(s))
    if not heads: continue
    parts, last, changed = [], 0, False
    for i, h in enumerate(heads):
        end = heads[i + 1].start() if i + 1 < len(heads) else len(s)
        body = s[h.start():end]
        new = convert(body, int(h.group(1)))
        if new != body:
            changed = True
            if '_eplain(' in new: plain += 1
            elif '_sync(' in new or '_fenced(' in new: synced += 1
            else: atomic += 1
        parts.append(s[last:h.start()]); parts.append(new); last = end
    parts.append(s[last:])
    if changed:
        s = ''.join(parts)
        if re.search(r'_(?:eplain|sync|fenced)\(', s) and include not in s:
            first = re.search(r'^#include "game-[a-z-]*impl\.h"$', s, re.M)
            s = s[:first.end()] + '\n' + include + s[first.end():]
        elif include in s and not re.search(r'_(?:e?plain|sync|fenced)\(', s):   # nothing plain left in this file: as it was
            s = s.replace('\n' + include, '', 1)
        path.write_text(s)

# The sync rules' helpers: wasm2c's atomic accesses with fences (acquire after a load, release before a store), and
# read-modify-writes followed by a full fence.
SYNC_HELPERS = """// Synchronisation code in a plain build (prepare_plain_engine.py sync rules, GTA-216): volatile-style ordering.
#define PG_SYNC_LOAD(name, t3) static inline t3 name##_sync(uint8_t* const base, uint64_t size, wasm_rt_shared_memory_t* mem, u64 addr) { \\
  t3 value = name##_shared(base, size, mem, addr); atomic_thread_fence(memory_order_acquire); return value; }
#define PG_SYNC_STORE(name, t2) static inline void name##_sync(uint8_t* const base, uint64_t size, wasm_rt_shared_memory_t* mem, u64 addr, t2 value) { \\
  atomic_thread_fence(memory_order_release); name##_shared(base, size, mem, addr, value); }
PG_SYNC_LOAD(i32_load, u32) PG_SYNC_LOAD(i64_load, u64) PG_SYNC_LOAD(f32_load, f32) PG_SYNC_LOAD(f64_load, f64)
PG_SYNC_LOAD(i32_load8_s, u32) PG_SYNC_LOAD(i64_load8_s, u64) PG_SYNC_LOAD(i32_load8_u, u32) PG_SYNC_LOAD(i64_load8_u, u64)
PG_SYNC_LOAD(i32_load16_s, u32) PG_SYNC_LOAD(i64_load16_s, u64) PG_SYNC_LOAD(i32_load16_u, u32) PG_SYNC_LOAD(i64_load16_u, u64)
PG_SYNC_LOAD(i64_load32_s, u64) PG_SYNC_LOAD(i64_load32_u, u64)
PG_SYNC_STORE(i32_store, u32) PG_SYNC_STORE(i64_store, u64) PG_SYNC_STORE(f32_store, f32) PG_SYNC_STORE(f64_store, f64)
PG_SYNC_STORE(i32_store8, u32) PG_SYNC_STORE(i32_store16, u32) PG_SYNC_STORE(i64_store8, u64) PG_SYNC_STORE(i64_store16, u64) PG_SYNC_STORE(i64_store32, u64)
#define PG_FENCED(call) ({ __typeof__(call) pg_fenced_result = (call); atomic_thread_fence(memory_order_seq_cst); pg_fenced_result; })
""" + ''.join(f'#define {n}_fenced(...) PG_FENCED({n}_shared(__VA_ARGS__))\n' for n in sorted(rmw_names))

header = root / 'Generated/game-plain-impl.h'
if header.exists():
    h = header.read_text()
    if '_eplain' not in h:
        h = h.rstrip('\n') + '\n// Engine functions made plain by Scripts/prepare_plain_engine.py: the same accesses.\n' + ALIASES + '\n'
    if 'PG_SYNC_LOAD' in h: h = h[:h.index('// Synchronisation code in a plain build')]   # rewritten: the set of helpers may grow
    h = h.rstrip('\n') + '\n' + SYNC_HELPERS
    if h != header.read_text(): header.write_text(h)
print(f'plain engine ({spec}{"" if V128 else ", v128 atomic"}{", sync rules: %d sync functions, %d waiting kept atomic" % (len(sync_set), len(waiting_set)) if SYNC else ""}): '
      f'{plain} functions made plain, {synced} with fenced accesses, {atomic} back to atomic')
