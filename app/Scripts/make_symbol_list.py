#!/usr/bin/python3
"""Writes Resources/sf-symbols.json: every SF Symbol name in Apple's own order, the iOS version that has it, and
Apple's search words, from the Mac's CoreGlyphs bundle (GTA-210: the full icon grid for on-screen mod buttons).
Run with the system Python (plistlib): /usr/bin/python3 Scripts/make_symbol_list.py. Language variants (.ar, .hi,
.ja ...) are left out: the base symbol stands for them."""
import json, plistlib, re
from pathlib import Path
R = Path('/System/Library/CoreServices/CoreGlyphs.bundle/Contents/Resources')
order = plistlib.load(open(R / 'symbol_order.plist', 'rb'))
avail = plistlib.load(open(R / 'name_availability.plist', 'rb'))
search = plistlib.load(open(R / 'symbol_search.plist', 'rb'))
years = {y: v['iOS'] for y, v in avail['year_to_release'].items()}
LANG = re.compile(r'\.(ar|he|hi|ja|ko|th|zh|zh\.traditional|rtl|my|km|bn|gu|kn|ml|mr|or|pa|ta|te|sat|mni|el|ru|sr|uk|bg|kk|mn|ky|tg|be|ka|hy|am|si|ne|lo|bo|dv|ug|fa|ur|ps|ks|sd|my|vi|tr|lt|lv|et|pl|cs|sk|sl|hr|hu|ro|is|ga|mt|cy|eu|ca|gl|latin|cyrillic)$')
out, seen = [], set()
for name in order:
    if name in seen or LANG.search(name) or name not in avail['symbols']: continue
    seen.add(name)
    ios = years.get(avail['symbols'][name], '13.0')
    words = ' '.join(search.get(name, []))
    out.append([name, ios, words] if words else [name, ios])
Path(__file__).resolve().parent.parent.joinpath('Resources', 'sf-symbols.json').write_text(json.dumps(out, separators=(',', ':')))
print(len(out), 'symbols')
