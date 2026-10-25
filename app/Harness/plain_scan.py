"""Which engine functions are safe to compile with plain memory accesses (the plain-memory work after GTA-173).

wasm2c compiles every ordinary load and store on the engine's shared memory as a relaxed atomic on a volatile
pointer, which keeps the compiler from optimising anything. A plain access is the same machine instruction, but
the compiler may then keep a value in a register across loop iterations. That only goes wrong in one shape: a loop
that reads the same address again and again while it writes no memory, calls no function and uses no atomic, because
then nothing tells the compiler the value can change (another thread is what changes it: a wait or spin loop).

For every function in Generated/game_*.c this finds its loops (a label with a backward goto) and marks a loop
"waiting" when it loads from an address that doesn't change inside the loop and has no store, call or atomic. The
functions with such a loop stay atomic; everything else is a plain-memory candidate.

    python3 Harness/plain_scan.py [--out plain-scan.json]
"""
import json, re, sys
from concurrent.futures import ProcessPoolExecutor
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MEM = r'wasm_rt_local_memory_base, wasm_rt_local_memory_size, instance->w2c_env_memory, '
FUNC = re.compile(r'^(?:static )?[a-z0-9]+ w2c_game_f(\d+)\(w2c_game\* instance[^\n]*\{$', re.M)
LOAD = re.compile(r'\b[if](?:32|64)_load\w*?_(?:shared|plain)\(' + MEM + r'\(u64\)(?:checked_add_u64\()?\(?(var_j\d+)')
STORE = re.compile(r'\b(?:[if](?:32|64)|v128)_store\w*?_(?:shared|plain)\(')
CALL = re.compile(r'\bw2c_game_f\d+\(instance|CALL_INDIRECT|\bw2c_env_\w+\(|\bpg_\w+\(|\bmemory_(?:copy|fill)\(')
ATOMIC = re.compile(r'_atomic_|atomic_(?:wait|notify)|memory_atomic')
ASSIGN = re.compile(r'^\s*(var_[a-z]+\d+) = (.*?);$', re.M)

def loops(body):
    """(label, loop text) for each label with a later backward goto."""
    for m in re.finditer(r'^\s*(var_L\d+):', body, re.M):
        label = m.group(1)
        last = body.rfind(f'goto {label};')
        if last > m.end(): yield label, body[m.end():last]

COMPOUND = re.compile(r'^\s*(var_[a-z]+\d+) (?:\+|-|\*|&|\||\^|<<|>>)= (var_[a-z]+\d+|\d+u?l*l?);$', re.M)

def invariant(var, text, at, depth=0):
    """Is register var, where it's used at position at in the loop text, the same on every iteration? Follows its
    definition inside the loop through copies and compound arithmetic (wasm2c writes a + b as a = ...; a += b)."""
    if depth > 12: return False
    defs = [d for d in ASSIGN.finditer(text, 0, at) if d.group(1) == var]
    if not defs:   # comes from before the loop: the same each time unless the loop assigns it somewhere
        return not any(d.group(1) == var for d in ASSIGN.finditer(text)) and not any(c.group(1) == var for c in COMPOUND.finditer(text))
    d = defs[-1]
    for c in COMPOUND.finditer(text, d.end(), at):      # arithmetic on it between its definition and this use
        if c.group(1) == var and not (re.fullmatch(r'\d+u?l*l?', c.group(2)) or invariant(c.group(2), text, c.start(), depth + 1)):
            return False
    expr = d.group(2).strip()
    if re.fullmatch(r'\d+u?l*l?', expr): return True                        # a fixed address (a global)
    source = re.fullmatch(r'(var_[a-z]+\d+)', expr)
    return bool(source) and invariant(source.group(1), text, d.start(), depth + 1)

def scan(path):
    s = path.read_text(errors='replace'); out = {}
    heads = list(FUNC.finditer(s))
    for i, h in enumerate(heads):
        body = s[h.end(): heads[i + 1].start() if i + 1 < len(heads) else len(s)]
        n_loops = waiting = spinning = 0
        for label, text in loops(body):
            n_loops += 1
            if STORE.search(text) or CALL.search(text) or ATOMIC.search(text): continue
            for load in LOAD.finditer(text):
                if invariant(load.group(1), text, load.start()):
                    waiting += 1
                    # A pure wait: the loop updates no lasting local (no counter, no pointer walking), so only memory
                    # that another thread changes can end it.
                    if not re.search(r'^\s*var_[lp]\d+ (?:[-+*&|^]|<<|>>)?= ', text, re.M): spinning += 1
                    break
        own = bool(STORE.search(body) or ATOMIC.search(body) or re.search(r'CALL_INDIRECT|\bw2c_env_\w+\(|\bpg_\w+\(|\bmemory_(?:copy|fill)\(', body))
        callees = sorted({int(c) for c in re.findall(r'\bw2c_game_f(\d+)\(instance', body)})
        loop_calls = [sorted({int(c) for c in re.findall(r'\bw2c_game_f(\d+)\(instance', t)}) for _, t in loops(body)
                      if not (STORE.search(t) or ATOMIC.search(t) or re.search(r'CALL_INDIRECT|\bw2c_env_\w+\(|\bpg_\w+\(|\bmemory_(?:copy|fill)\(', t))
                      and re.search(r'\bw2c_game_f\d+\(instance', t) and any(invariant(l.group(1), t, l.start()) for l in LOAD.finditer(t))]
        out[int(h.group(1))] = (n_loops, waiting, len(body), spinning, own, callees, loop_calls, path.name, bool(ATOMIC.search(body)))
    return out

if __name__ == '__main__':
    files = sorted((ROOT / 'Generated').glob('game_*.c'))
    result = {}
    with ProcessPoolExecutor() as pool:
        for part in pool.map(scan, files): result.update(part)
    names = dict(l.rstrip('\n').split('\t', 1) for l in open(ROOT / 'Generated/funcnames.tsv'))
    # Side-effect-free functions: no store, atomic, host call or indirect call, and every callee the same. A loop whose
    # only calls go to such functions in the same file can be inlined into a loop with no barrier at all.
    pure = {n for n, r in result.items() if not r[4]}
    changed = True
    while changed:
        changed = False
        for n in list(pure):
            if any(c not in pure for c in result[n][5]): pure.discard(n); changed = True
    hidden = sorted((n for n, r in result.items() if any(all(c in pure and result.get(c, (0,) * 8)[7] == r[7] for c in calls) for calls in r[6])),
                    key=lambda n: -result[n][2])
    atomics = [n for n, r in result.items() if r[8]]
    print(f'side-effect-free functions: {len(pure)}; loops that wait through only such same-file calls: {len(hidden)} functions; functions using atomics: {len(atomics)}')
    for n in hidden[:40]: print(f'  hidden wait? f{n} {names.get(str(n), "")[:100]}  calls ' + ', '.join(f'f{c} {names.get(str(c), "")[:40]}' for calls in result[n][6] for c in calls[:2]))
    waiting = sorted((n for n, r in result.items() if r[1]), key=lambda n: -result[n][2])
    spinning = sorted((n for n, r in result.items() if r[3]), key=lambda n: -result[n][2])
    no_loops = sum(1 for r in result.values() if not r[0])
    size = sum(r[2] for r in result.values())
    share = lambda ns: 100 * sum(result[n][2] for n in ns) / max(1, size)
    print(f'{len(result)} functions: {no_loops} without loops, {len(result) - no_loops - len(waiting)} with only safe loops, '
          f'{len(waiting)} reading a fixed address in a loop ({share(waiting):.1f}% of the code), {len(spinning)} of them pure waits ({share(spinning):.1f}%)')
    for n in spinning[:80]: print(f'  f{n} {names.get(str(n), "")[:110]}')
    out = sys.argv[sys.argv.index('--out') + 1] if '--out' in sys.argv else None
    if out: Path(out).write_text(json.dumps({'waiting': waiting, 'spinning': spinning, 'hidden': hidden, 'atomics': atomics, 'functions': len(result)}, indent=0))
