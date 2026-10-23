"""Names for the in-app profiler's functions (GTA-169, Source/NativeThreadCPU.c).

The log's "Profile ..." lines name engine functions fN, as wasm2c does; this puts the game's own C++ names in.
With --table it reads the full table the app writes to Library/Caches/thread-profile.txt instead, looks every
address up with atos in the app binary that wrote it, and prints the busiest functions of each thread group.

    python3 Harness/profile_names.py LOG
    python3 Harness/profile_names.py --table thread-profile.txt --binary PlayGTA5Native.app/PlayGTA5Native [--top 30]
"""
import argparse, collections, os, re, subprocess, sys, tempfile
from pathlib import Path

root = Path(__file__).resolve().parents[1]
names = {}
for line in open(root / 'Generated/funcnames.tsv', errors='replace'):
    number, _, name = line.rstrip('\n').partition('\t')
    names[number] = name

def engine_name(symbol):
    m = re.fullmatch(r'(?:w2c_game_)?f(\d+)', symbol)
    return names.get(m.group(1), symbol) if m else symbol

parser = argparse.ArgumentParser()
parser.add_argument('log', nargs='?')
parser.add_argument('--table')
parser.add_argument('--binary')
parser.add_argument('--top', type=int, default=25)
options = parser.parse_args()

if not options.table:
    for line in open(options.log, errors='replace'):
        if 'Profile ' in line:
            print(re.sub(r'(?<= · )(f\d+)(?= \d+%)', lambda m: engine_name(m.group(1)), line.rstrip('\n')))
    sys.exit()

rows = []
for line in open(options.table, errors='replace'):
    if line.startswith('#'): continue
    group, image, address, own, calls = line.rstrip('\n').split('\t')
    rows.append((group, image, int(address, 16), int(own), int(calls)))
# Addresses in the app binary go to atos; those in system libraries keep the library's name.
binary_name = os.path.basename(options.binary)
ours = sorted({r[2] for r in rows if os.path.basename(r[1]) == binary_name})
symbol = {}
with tempfile.NamedTemporaryFile('w', suffix='.txt', delete=False) as listing:
    listing.write('\n'.join(hex(0x100000000 + a) for a in ours))
answer = subprocess.run(['xcrun', 'atos', '-o', options.binary, '-l', '0x100000000', '-f', listing.name],
                        capture_output=True, text=True).stdout.splitlines()
os.unlink(listing.name)
for address, text in zip(ours, answer):
    symbol[address] = engine_name(text.split(' (in ')[0].strip())
totals = collections.defaultdict(lambda: collections.Counter())
samples = collections.Counter()
for group, image, address, own, calls in rows:
    name = symbol.get(address) if os.path.basename(image) == binary_name else os.path.basename(image)
    totals[group, 'own'][name] += own
    totals[group, 'in'][name] += calls
    samples[group] += own
for group in sorted(samples):
    for kind, title in (('own', 'own time'), ('in', 'with what it calls')):
        print(f'\n{group}, {title} ({samples[group]} samples)')
        for name, n in totals[group, kind].most_common(options.top):
            print(f'  {n * 100 / samples[group]:5.1f}%  {name}')
