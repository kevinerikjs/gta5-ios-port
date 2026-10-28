#!/usr/bin/env python3
"""Work per frame from the Perf lines of game logs (GTA-216), for A/B runs of builds on one phone.

Usage: perf_report.py [--base LABEL] LABEL=LOG [LABEL=LOG ...]
  Runs with the same LABEL are repeats of one build (arm). Each log should come from the built-in benchmark
  (PG_BENCHMARK=1) with PG_PERF_INTERVAL=2, so segments can be cut close to the benchmark's own scene changes.

For each run it cuts the same stretch of every benchmark pass: from its second scene (the benchmark clears the area
at 806,1101: the first scene of the first pass still loads the world) to the end of its last scene (the frontend audio
scene starts after the scene at -542.9,245.2). The Perf line printed just after each marker carries running totals, so
a stretch is the exact difference between two lines (to within one Perf interval).
Without benchmark markers (any other log) it uses everything after the first 60 s.

Per arm it prints the mean and spread of each figure, and each arm against the base arm (the first one, or --base):
the change in percent and the change divided by the larger arm's spread (above about 2 is more than run-to-run noise).
"""
import math, re, statistics, sys
from collections import defaultdict

PASS_START = 'COMMAND_CLEAR_AREA from "benchmark" Position (806.0,1101.2'
PASS_LAST = 'COMMAND_CLEAR_AREA from "benchmark" Position (-542.9,245.2'
PASS_END = 'Starting audio scene with settings FRONTEND_SCENE'
TOTALS = re.compile(r'totals (\d+) frames, (\d+) instructions, (\d+) cycles, (\d+) us CPU, (\d+) uJ, ([\d.]+) s')
GROUPS = re.compile(r' ([^;:·]+?) ([\d.]+)/([\d.]+)/([\d.]+)(?:/([\d.]+))?;')   # instr, mJ, ms per frame[, % on P cores]
THERMAL = re.compile(r'thermal (\w+)')
PSHARE = re.compile(r'P cores (\d+)%')
WINDOW = re.compile(r'Perf: (\d+) frames in ([\d.]+) s')

def parse(path):
    """Perf lines in order, each with its log position, and the positions of the benchmark markers."""
    perf, starts, lasts, ends = [], [], [], []
    with open(path, errors='replace') as f:
        for i, line in enumerate(f):
            if line.startswith('Perf: ') and 'totals' in line:
                m = TOTALS.search(line)
                if not m: continue
                frames, instr, cycles, cpu_us, energy_uj = (int(m.group(k)) for k in range(1, 6))
                groups = {g.group(1).strip(): (float(g.group(2)), float(g.group(3)), float(g.group(4)), float(g.group(5) or 0))
                          for g in GROUPS.finditer(line.split('):', 2)[-1])} if 'threads (' in line else {}
                w = WINDOW.search(line)
                perf.append(dict(pos=i, frames=frames, instr=instr, cycles=cycles, cpu_us=cpu_us, energy_uj=energy_uj, t=float(m.group(6)),
                                 thermal=(THERMAL.search(line) or [None, '?'])[1], pshare=int((PSHARE.search(line) or [0, 0])[1]),
                                 wframes=int(w.group(1)) if w else 0, groups=groups))
            elif PASS_START in line: starts.append(i)
            elif PASS_LAST in line: lasts.append(i)
            elif PASS_END in line: ends.append(i)
    return perf, starts, lasts, ends

def first_after(perf, pos):
    return next((k for k, p in enumerate(perf) if p['pos'] > pos), None)

def segment(perf, a, b, name):
    """The stretch between Perf lines a and b (indexes), as per-frame figures."""
    pa, pb = perf[a], perf[b]
    frames = pb['frames'] - pa['frames']
    if frames <= 0: return None
    seconds = pb['t'] - pa['t']
    groups = defaultdict(lambda: [0.0, 0.0, 0.0, 0.0])
    for p in perf[a + 1:b + 1]:   # the windows inside the stretch, weighted by their frames
        for g, v in p['groups'].items():
            for k in range(3): groups[g][k] += v[k] * p['wframes']
            groups[g][3] += v[3] * v[0] * p['wframes']   # P-core instructions, for the share
    thermal = [p['thermal'] for p in perf[a + 1:b + 1]]
    return dict(name=name, frames=frames, seconds=seconds, fps=frames / seconds if seconds else 0,
                instr=(pb['instr'] - pa['instr']) / frames / 1e6, cycles=(pb['cycles'] - pa['cycles']) / frames / 1e6,
                cpu=(pb['cpu_us'] - pa['cpu_us']) / frames / 1e3, energy=(pb['energy_uj'] - pa['energy_uj']) / frames / 1e3,
                watts=(pb['energy_uj'] - pa['energy_uj']) / 1e6 / seconds if seconds else 0,
                groups={g: [v[0] / frames, v[1] / frames, v[2] / frames, v[3] / v[0] if v[0] else 0] for g, v in groups.items()},
                pshare=sum(p['pshare'] * p['wframes'] for p in perf[a + 1:b + 1]) / max(1, sum(p['wframes'] for p in perf[a + 1:b + 1])),
                thermal=','.join(sorted(set(thermal), key=['nominal', 'fair', 'serious', 'critical', '?'].index)),
                serious=sum(t in ('serious', 'critical') for t in thermal) / max(1, len(thermal)))

def segments(path):
    perf, starts, lasts, ends = parse(path)
    out = []
    if not perf: return out
    for n, s in enumerate(starts):
        last = next((l for l in lasts if l > s), None)
        nxt = starts[n + 1] if n + 1 < len(starts) else None
        if last is None or (nxt is not None and last > nxt): continue
        e = next((x for x in ends if x > last), None)
        if e is None or (nxt is not None and e > nxt): continue
        a, b = first_after(perf, s), first_after(perf, e)
        if a is None or b is None or b <= a: continue
        seg = segment(perf, a, b, f'pass {n + 1}')
        if seg: out.append(seg)
    if not out:   # not a benchmark: everything after the first minute
        a = next((k for k, p in enumerate(perf) if p['t'] >= 60), None)
        if a is not None and a < len(perf) - 1:
            seg = segment(perf, a, len(perf) - 1, 'after 60 s')
            if seg: out.append(seg)
    return out

FIELDS = [('instr', 'M instr/frame'), ('cycles', 'M cycles/frame'), ('cpu', 'CPU ms/frame'), ('energy', 'mJ/frame'), ('watts', 'W'), ('fps', 'FPS')]

def stats(values):
    if not values: return (math.nan, math.nan, 0)
    m = statistics.fmean(values)
    sd = statistics.stdev(values) if len(values) > 1 else math.nan
    return (m, sd, len(values))

def main(argv):
    base = None
    if len(argv) > 1 and argv[0] == '--base': base, argv = argv[1], argv[2:]
    arms, order = defaultdict(list), []
    for item in argv:
        label, path = item.split('=', 1)
        if label not in arms: order.append(label)
        segs = segments(path)
        arms[label].append((path, segs))
        print(f'{label}: {path}')
        if not segs: print('    no Perf segments (no Perf lines, or the run ended before a pass)'); continue
        perf = parse(path)[0]
        by = defaultdict(lambda: [0, 0.0, 0, 0, 0, 0])   # thermal: windows, seconds, frames, instructions, energy uJ, P-share*frames
        for prev, p in zip(perf, perf[1:]):
            if p['t'] < 60: continue
            b_ = by[p['thermal']]; b_[0] += 1; b_[1] += p['t'] - prev['t']; b_[2] += p['frames'] - prev['frames']
            b_[3] += p['instr'] - prev['instr']; b_[4] += p['energy_uj'] - prev['energy_uj']; b_[5] += p['pshare'] * (p['frames'] - prev['frames'])
        if by:
            print('    by thermal state (after the first minute): ' + ' · '.join(
                f"{t} {v[1]:.0f} s {v[2] / v[1]:.1f} FPS {v[3] / max(1, v[2]) / 1e6:.1f} M instr/frame {v[4] / max(1, v[2]) / 1e3:.2f} mJ/frame {v[4] / 1e6 / v[1]:.2f} W P-cores {v[5] / max(1, v[2]):.0f}%"
                for t, v in sorted(by.items(), key=lambda kv: ['nominal', 'fair', 'serious', 'critical', '?'].index(kv[0])) if v[1] > 0))
        for s in segs:
            top = sorted(s['groups'].items(), key=lambda kv: -kv[1][0])[:6]
            print(f"    {s['name']}: {s['frames']} frames {s['seconds']:.0f} s {s['fps']:.1f} FPS · {s['instr']:.2f} M instr, {s['cycles']:.2f} M cycles, "
                  f"CPU {s['cpu']:.2f} ms, {s['energy']:.2f} mJ ({s['watts']:.2f} W) per frame · thermal {s['thermal']}")
            print(f"        P cores {s['pshare']:.0f}% of instructions · " + ' · '.join(f'{g} {v[0]:.2f}' + (f' ({v[3]:.0f}% P)' if v[3] else '') for g, v in top))
    base = base or order[0]
    print('\nPer arm (segments of the same pass pooled across runs; mean ± stdev, n):')
    names = sorted({s['name'] for runs in arms.values() for _, segs in runs for s in segs})
    for name in names:
        print(f'  {name}:')
        table = {}
        for label in order:
            segs = [s for _, ss in arms[label] for s in ss if s['name'] == name]
            table[label] = {f: stats([s[f] for s in segs]) for f, _ in FIELDS}
            table[label]['groups'] = defaultdict(list); table[label]['gms'] = defaultdict(list)
            for s in segs:
                for g, v in s['groups'].items(): table[label]['groups'][g].append(v[0]); table[label]['gms'][g].append(v[2])
            row = ' · '.join(f'{title} {table[label][f][0]:.3f} ± {table[label][f][1]:.3f}' for f, title in FIELDS[:5])
            print(f'    {label:>14} (n={table[label]["instr"][2]}): {row}')
        if base not in table: continue
        for label in order:
            if label == base: continue
            parts = []
            for f, title in FIELDS[:5]:
                b, x = table[base][f], table[label][f]
                if not (b[0] and x[0] == x[0]): continue
                change = (x[0] - b[0]) / b[0] * 100
                noise = max(v for v in (b[1], x[1]) if v == v) if (b[1] == b[1] or x[1] == x[1]) else math.nan
                z = abs(x[0] - b[0]) / noise if noise and noise == noise else math.nan
                parts.append(f'{title} {change:+.1f}% ({z:.1f}x noise)')
            print(f'    {label} vs {base}: ' + ' · '.join(parts))
            gb, gx = table[base]['groups'], table[label]['groups']
            moved = []
            for g in gb:
                if g in gx and gb[g] and gx[g]:
                    mb, mx = statistics.fmean(gb[g]), statistics.fmean(gx[g])
                    if mb > 0.5: moved.append((mx - mb, g, mb, mx))
            moved.sort()
            print('        threads (M instr/frame): ' + ' · '.join(f'{g} {mb:.2f}→{mx:.2f} ({(mx - mb) / mb * 100:+.0f}%)' for _, g, mb, mx in moved[:8]))
            mb_, mx_ = table[base]['gms'], table[label]['gms']
            ms = sorted(((statistics.fmean(mx_[g]) - statistics.fmean(mb_[g]), g, statistics.fmean(mb_[g]), statistics.fmean(mx_[g]))
                         for g in mb_ if g in mx_ and mb_[g] and mx_[g] and statistics.fmean(mb_[g]) > 0.2))
            print('        threads (CPU ms/frame): ' + ' · '.join(f'{g} {b:.2f}→{x:.2f} ({(x - b) / b * 100:+.0f}%)' for _, g, b, x in ms[:8]))

if __name__ == '__main__':
    if len(sys.argv) < 2: print(__doc__); sys.exit(1)
    main(sys.argv[1:])
