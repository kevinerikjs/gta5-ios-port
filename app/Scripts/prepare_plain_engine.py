"""Plain memory accesses for a chosen set of engine functions (the plain-memory work after the audio, GTA-187).

wasm2c compiles every ordinary load and store on the engine's shared memory as a relaxed atomic on a volatile
pointer with a forced read (see prepare_plain_dsp.py), which keeps the compiler from optimising engine code. The
audio got plain accesses in v1.3.3 (about a third cheaper). This does the same for any set of engine functions, so
the whole engine can be tried and, if something breaks, the set can be halved until the functions that need atomic
accesses are found. Wasm atomics (i32_atomic_*, wait, notify) are never touched.

The set comes from PG_PLAIN_ENGINE (or the first argument):
    off                 nothing (the default; functions converted earlier go back to atomic)
    all                 every engine function
    all-but:FILE        every function except the numbers in FILE (one per line, "f123" or "123", # comments)
    only:FILE           just the numbers in FILE
The functions in Scripts/plain-engine-keep.txt stay atomic in every set (hand-offs with no atomic on either side).
PG_PLAIN_V128=0 leaves the SIMD (v128) accesses atomic in the converted functions: today each of them is a full
compiler barrier, so making them plain is the biggest single change and the first thing to rule out if a set stalls.
Engine conversions use *_eplain helpers (defined in game-plain-impl.h like the audio's *_plain, so PG_ATOMIC_DSP=1
turns both back into atomic accesses for comparisons). Running it again with another set converts and reverts in
place; the audio's *_plain accesses are left alone.
"""
import os, re, sys
from pathlib import Path

root = Path(__file__).resolve().parents[1]
spec = (sys.argv[1] if len(sys.argv) > 1 else os.environ.get('PG_PLAIN_ENGINE', 'off')).strip()

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

SCALAR = r'(?:i32|i64|f32|f64)_(?:load|store)(?:8_s|8_u|16_s|16_u|32_s|32_u|8|16|32)?'
ACCESS = r'(?:' + SCALAR + r'|v128_(?:load|store))'
V128 = os.environ.get('PG_PLAIN_V128', '1') != '0'
TO_PLAIN = re.compile(r'\b(' + (ACCESS if V128 else SCALAR) + r')_shared\(')
TO_ATOMIC = re.compile(r'\b(' + ACCESS + r')_eplain\(')
V128_TO_ATOMIC = re.compile(r'\b(v128_(?:load|store))_eplain\(')

def convert(body, plain):
    if not plain: return TO_ATOMIC.sub(r'\1_shared(', body)
    body = TO_PLAIN.sub(r'\1_eplain(', body)
    return body if V128 else V128_TO_ATOMIC.sub(r'\1_shared(', body)
HEAD = re.compile(r'^[a-z0-9]+ w2c_game_f(\d+)\(w2c_game\* instance[^\n]*\{$', re.M)
ALIASES = '\n'.join(f'#define {a}_eplain {a}_plain' for a in [
    'i32_load', 'i64_load', 'f32_load', 'f64_load', 'i32_load8_s', 'i64_load8_s', 'i32_load8_u', 'i64_load8_u',
    'i32_load16_s', 'i64_load16_s', 'i32_load16_u', 'i64_load16_u', 'i64_load32_s', 'i64_load32_u',
    'i32_store', 'i64_store', 'f32_store', 'f64_store', 'i32_store8', 'i32_store16', 'i64_store8', 'i64_store16', 'i64_store32',
    'v128_load', 'v128_store'])
include = '#include "game-plain-impl.h"'

plain = atomic = 0
for path in sorted((root / 'Generated').glob('game_*.c')):
    s = path.read_text()
    heads = list(HEAD.finditer(s))
    if not heads: continue
    parts, last, changed = [], 0, False
    for i, h in enumerate(heads):
        end = heads[i + 1].start() if i + 1 < len(heads) else len(s)
        body = s[h.start():end]
        new = convert(body, chosen(int(h.group(1))))
        if new != body:
            changed = True
            if '_eplain(' in new: plain += 1
            else: atomic += 1
        parts.append(s[last:h.start()]); parts.append(new); last = end
    parts.append(s[last:])
    if changed:
        s = ''.join(parts)
        if '_eplain(' in s and include not in s:
            first = re.search(r'^#include "game-[a-z-]*impl\.h"$', s, re.M)
            s = s[:first.end()] + '\n' + include + s[first.end():]
        elif include in s and not re.search(r'_e?plain\(', s):   # nothing plain left in this file: as it was
            s = s.replace('\n' + include, '', 1)
        path.write_text(s)

header = root / 'Generated/game-plain-impl.h'
if header.exists():
    h = header.read_text()
    if '_eplain' not in h:
        header.write_text(h.rstrip('\n') + '\n// Engine functions made plain by Scripts/prepare_plain_engine.py: the same accesses.\n' + ALIASES + '\n')
print(f'plain engine ({spec}{"" if V128 else ", v128 atomic"}): {plain} functions made plain, {atomic} back to atomic')
