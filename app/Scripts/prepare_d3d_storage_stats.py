"""The D3D layer's CPU copies of resources, counted per resource (GTA-174: memory on 4 GB iPhones).

The null D3D layer (wasm_null_d3d) gives a resource a CPU copy when the CPU may write or read it: CreateBuffer and
CreateTexture1D/2D/3D for CPU access flags or staging, NullContext::Map when a resource has none yet (calloc, zeroed),
and GpuReadback. The copy is a {pointer, size} pair inside the resource and is only freed with the resource; the
engine keeps a total at 8324208 (bytes), 8324216 (count) and 8324224 (peak), about 110 MB in a city drive.

This adds calls around those places so the host can tell which copies are idle and how they are mapped: pg_d3d_made
(pair, size, kind) where one is allocated, pg_d3d_gone(pair) where a resource frees it, and pg_d3d_map_type /
pg_d3d_mapped(pair) in Map. The host counts only with PG_D3D_STATS=1 (EngineHost.c); otherwise each call is one load.
"""
from pathlib import Path
from engine_names import fn
import re
root = Path(__file__).resolve().parents[1]
MEMORY = 'wasm_rt_local_memory_base, wasm_rt_local_memory_size, instance->w2c_env_memory, '
# Groups: 1 indent, 2 and 3 the two registers (3 holds the total), then each pattern's own.
LOAD_TOTAL = r'var_j(\d) = 8324208ull;\n\s+var_j(\d) = 8324208ull;\n\s+var_j\3 = i64_load_shared\(' + re.escape(MEMORY) + r'\(u64\)\(var_j\3\)\);\n'
MADE = re.compile(r'\n(\s+)' + LOAD_TOTAL + r'\s+var_j\d = (var_\w+);\n\s+var_j\3 \+= var_j\d;')
GONE = re.compile(r'\n(\s+)' + LOAD_TOTAL + r'\s+var_j(\d) = (var_\w+);\n\s+var_j\4 = i64_load_shared\(' + re.escape(MEMORY) + r'\(u64\)checked_add_u64\(var_j\4, (\d+)u\)\);\n\s+var_j\3 -= var_j\4;')
STORE_PAIR = re.compile(r'i64_store_shared\(' + re.escape(MEMORY) + r'\(u64\)checked_add_u64\(var_j1, (\d+)u\), var_j2\);\n\s*$')
DECLARATIONS = ('extern void pg_d3d_made(u64 pair, u64 size, u32 kind); extern void pg_d3d_gone(u64 pair); '
                'extern void pg_d3d_map_type(u32 type); extern void pg_d3d_mapped(u64 pair);')
CREATE = {fn('wasm_null_d3d::NullDevice::CreateBuffer(D3D11_BUFFER_DESC const*, D3D11_SUBRESOURCE_DATA const*, ID3D11Buffer**)'): 1,
          fn('wasm_null_d3d::NullDevice::CreateTexture1D(D3D11_TEXTURE1D_DESC const*, D3D11_SUBRESOURCE_DATA const*, ID3D11Texture1D**)'): 2,
          fn('wasm_null_d3d::NullDevice::CreateTexture2D(D3D11_TEXTURE2D_DESC const*, D3D11_SUBRESOURCE_DATA const*, ID3D11Texture2D**)'): 3,
          fn('wasm_null_d3d::NullDevice::CreateTexture3D(D3D11_TEXTURE3D_DESC const*, D3D11_SUBRESOURCE_DATA const*, ID3D11Texture3D**)'): 4}
MAP = fn('wasm_null_d3d::NullContext::Map(ID3D11Resource*, unsigned int, D3D11_MAP, unsigned int, D3D11_MAPPED_SUBRESOURCE*)')
READBACK = next(int(line.split('\t')[0]) for line in open(root / 'Generated/funcnames.tsv') if line.split('\t')[1].startswith('wasm_null_d3d::GpuReadback('))

def function_at(s, at):
    head = max(s.rfind('\nu32 w2c_game_f', 0, at), s.rfind('\nu64 w2c_game_f', 0, at), s.rfind('\nvoid w2c_game_f', 0, at))
    return int(re.match(r'\n\w+ w2c_game_f(\d+)', s[head:head + 40]).group(1))

made = gone = mapped = 0
for path in sorted((root / 'Generated').glob('game_*.c')):
    s = path.read_text()
    if '8324208ull' not in s: continue
    if 'pg_d3d_made(' in s or 'pg_d3d_gone(' in s:
        print(f'd3d storage stats: {path.name} already patched'); continue
    edits = []
    for m in MADE.finditer(s):
        number, size, indent = function_at(s, m.start()), m.group(4), m.group(1)
        if number in CREATE:
            store = STORE_PAIR.search(s[max(0, m.start() - 400):m.start() + 1])
            if not store: raise RuntimeError(f'f{number}: the CPU copy store moved')
            pair, kind = f'var_p0 + {store.group(1)}ull', CREATE[number]
        elif number == MAP: pair, kind = 'var_p1', 5
        elif number == READBACK: pair, kind = 'var_l7', 6
        else: raise RuntimeError(f'f{number}: an unknown place makes a CPU copy')
        edits.append((m.start() + 1, f'{indent}pg_d3d_made({pair}, {size}, {kind});   /* GTA-174 */\n'))
        made += 1
    for m in GONE.finditer(s):
        indent, holder, size_at = m.group(1), m.group(5), int(m.group(6))
        edits.append((m.start() + 1, f'{indent}pg_d3d_gone({holder} + {size_at - 8}ull);   /* GTA-174 */\n'))
        gone += 1
    if not edits and not re.search(r'^u32 w2c_game_f' + str(MAP) + r'\(w2c_game\* instance', s, re.M): continue
    for at, text in sorted(edits, reverse=True): s = s[:at] + text + s[at:]
    head = re.search(r'^u32 w2c_game_f' + str(MAP) + r'\(w2c_game\* instance[^{]*\{$', s, re.M)
    if head:
        start = head.start(); end = s.index('\n}\n', start) + 3; body = s[start:end]
        if body.count('  FUNC_PROLOGUE;\n') != 1 or body.count('\n  var_B33:;\n') != 1: raise RuntimeError(f'Pinned f{MAP} (NullContext::Map) changed')
        body = body.replace('  FUNC_PROLOGUE;\n', '  FUNC_PROLOGUE;\n  pg_d3d_map_type(var_p3);   /* GTA-174 */\n', 1)
        body = body.replace('\n  var_B33:;\n', '\n  var_B33:;\n  pg_d3d_mapped(var_p1);   /* GTA-174 */\n', 1)
        s = s[:start] + body + s[end:]; mapped += 1
    first = re.search(r'^#include "game-[a-z-]*impl\.h"$', s, re.M)
    s = s[:first.end()] + '\n' + DECLARATIONS + s[first.end():]
    path.write_text(s)
print(f'd3d storage stats: {made} places make a CPU copy, {gone} free one, Map {"hooked" if mapped else "not found"}')

# Who else touches a resource (and so may read or write its CPU copy): Unmap, CopyResource, CopySubresourceRegion,
# UpdateSubresource and GpuReadback, each with the resources it is given. pg_d3d_touch(resource, what) marks them.
TOUCH = {fn('wasm_null_d3d::NullContext::Unmap(ID3D11Resource*, unsigned int)'): [('var_p1', 1)],
         fn('wasm_null_d3d::NullContext::CopySubresourceRegion(ID3D11Resource*, unsigned int, unsigned int, unsigned int, unsigned int, ID3D11Resource*, unsigned int, D3D11_BOX const*)'): [('var_p1', 2), ('var_p6', 4)],
         READBACK: [('var_p0', 8), ('var_p2', 16)],
         fn('wasm_null_d3d::NullContext::CopyResource(ID3D11Resource*, ID3D11Resource*)'): [('var_p1', 2), ('var_p2', 4)],
         fn('wasm_null_d3d::NullContext::UpdateSubresource(ID3D11Resource*, unsigned int, D3D11_BOX const*, void const*, unsigned int, unsigned int)'): [('var_p1', 32)]}
touched = 0
for path in sorted((root / 'Generated').glob('game_*.c')):
    s = path.read_text(); changed = False
    for number, args in TOUCH.items():
        head = re.search(r'^\w+ w2c_game_f' + str(number) + r'\(w2c_game\* instance[^{]*\{$', s, re.M)
        if not head: continue
        start = head.start(); end = s.index('\n}\n', start) + 3; body = s[start:end]
        if 'pg_d3d_touch(' in body: continue
        if body.count('  FUNC_PROLOGUE;\n') != 1: raise RuntimeError(f'Pinned f{number} changed')
        calls = ''.join(f'  pg_d3d_touch({var}, {bit});   /* GTA-174 */\n' for var, bit in args)
        s = s[:start] + body.replace('  FUNC_PROLOGUE;\n', '  FUNC_PROLOGUE;\n' + calls, 1) + s[end:]
        changed = True; touched += 1
    if changed:
        if 'extern void pg_d3d_touch(' not in s:
            first = re.search(r'^#include "game-[a-z-]*impl\.h"$', s, re.M)
            s = s[:first.end()] + '\nextern void pg_d3d_touch(u64 resource, u32 what);' + s[first.end():]
        path.write_text(s)
print(f'd3d storage stats: {touched} functions that may touch a CPU copy marked')

if made and (made != 6 or gone != 24 or mapped != 1): raise RuntimeError('the D3D layer changed: expected 6 makes, 24 frees and Map')
