"""Lazy D3D CPU copies (GTA-174: memory on 4 GB iPhones; EngineHost.c pg_d3d_lazy_create / pg_d3d_lazy_need).

The null D3D layer (wasm_null_d3d) gives every resource the CPU may map, and every staging resource, a CPU copy
inside the engine's memory when it is created: CreateBuffer and CreateTexture1D/2D/3D calloc a {pointer, size}
pair's copy and fill it with the initial data, if any. In a city drive that is about 110 MB, and 77 MB of it is
never mapped, copied or read back (prepare_d3d_storage_stats.py, PG_D3D_STATS=1). On a 4 GB iPhone the game gets
about 2.3 GB, so those bytes come out of city streaming.

What reads or writes a copy after creation (the whole layer: the only functions that reach a copy through the
resource's Storage() are these five, and only Create and the destructors touch the pair directly):
- NullContext::Map hands the game a pointer into it, whatever the map type (for READ and READ_WRITE it first waits
  for a pending readback). If the pair has no copy yet, Map callocs a zeroed one.
- NullContext::Unmap uploads from it (the mapped range, or what changed against its own shadow); it returns at
  once for a resource that was not mapped.
- NullContext::CopyResource copies the source's copy into the destination's on the CPU when both have one, besides
  the GPU copy; UpdateSubresource writes the update into the destination's copy; GpuReadback (staging destinations
  of CopyResource and CopySubresourceRegion) has the renderer write GPU contents into the destination's copy, and
  callocs one if needed.
- The renderer (Source/MetalRenderer/MRRenderer.mm) never reads a copy: uploads travel inside the command ring
  (wasm_gpu::EmitData copies the bytes), and it writes engine memory only for readbacks, fences and queries.

So a copy made without initial data holds zeros until the first of those calls, and making it then, zeroed, gives
the game exactly the same bytes. This makes the four Create functions ask the host before they make a copy
(pg_d3d_lazy_create: when it says wait, they skip the calloc and the initial-data copy, as they do for a resource
without CPU access, and the host leaves the pair as {0, size}), and makes Map, CopyResource (both resources),
CopySubresourceRegion, UpdateSubresource and GpuReadback (the destination) call pg_d3d_lazy_need first, which makes
a waiting copy. One engine call for the host is added at the end of the file that holds Map (pg_d3d_engine_calloc).

The inserted calls pass only variables and constants, so they read the same whether prepare_plain_engine.py has
turned the function's memory accesses plain or not, and the patterns below take either spelling. The order of the
calls after FUNC_PROLOGUE is the same whichever of this and prepare_d3d_storage_stats.py runs first.
"""
from pathlib import Path
from engine_names import fn
import re
root = Path(__file__).resolve().parents[1]
MEMORY = re.escape('wasm_rt_local_memory_base, wasm_rt_local_memory_size, instance->w2c_env_memory, ')
ACCESS = r'_(?:shared|eplain)\(' + MEMORY      # prepare_plain_engine.py may have made the function's accesses plain
DECLARATIONS = ('extern u32 pg_d3d_lazy_create(w2c_game *instance, u64 resource, u64 pair, u64 size, u64 init, u32 kind); '
                'extern void pg_d3d_lazy_need(w2c_game *instance, u64 resource);')

# Create function: kind (as in prepare_d3d_storage_stats.py), where its pair sits, and where Usage sits in its
# D3D11_*_DESC (pinned: the Usage check that skips the copy reads it there).
CREATE = {fn('wasm_null_d3d::NullDevice::CreateBuffer(D3D11_BUFFER_DESC const*, D3D11_SUBRESOURCE_DATA const*, ID3D11Buffer**)'): (1, 120, 4),
          fn('wasm_null_d3d::NullDevice::CreateTexture1D(D3D11_TEXTURE1D_DESC const*, D3D11_SUBRESOURCE_DATA const*, ID3D11Texture1D**)'): (2, 128, 16),
          fn('wasm_null_d3d::NullDevice::CreateTexture2D(D3D11_TEXTURE2D_DESC const*, D3D11_SUBRESOURCE_DATA const*, ID3D11Texture2D**)'): (3, 144, 28),
          fn('wasm_null_d3d::NullDevice::CreateTexture3D(D3D11_TEXTURE3D_DESC const*, D3D11_SUBRESOURCE_DATA const*, ID3D11Texture3D**)'): (4, 136, 20)}
MAP = fn('wasm_null_d3d::NullContext::Map(ID3D11Resource*, unsigned int, D3D11_MAP, unsigned int, D3D11_MAPPED_SUBRESOURCE*)')
READBACK = next(int(line.split('\t')[0]) for line in open(root / 'Generated/funcnames.tsv') if line.split('\t')[1].startswith('wasm_null_d3d::GpuReadback('))
# Who needs a copy: Map(resource, ...), CopyResource(dst, src), CopySubresourceRegion(dst, ..., src, ...) and
# UpdateSubresource(dst, ...) on the context, GpuReadback(dst, ..., src, ...). CopySubresourceRegion never reads its
# source's copy, nor GpuReadback its source's.
NEED = {MAP: ['var_p1'],
        fn('wasm_null_d3d::NullContext::CopyResource(ID3D11Resource*, ID3D11Resource*)'): ['var_p1', 'var_p2'],
        fn('wasm_null_d3d::NullContext::CopySubresourceRegion(ID3D11Resource*, unsigned int, unsigned int, unsigned int, unsigned int, ID3D11Resource*, unsigned int, D3D11_BOX const*)'): ['var_p1'],
        fn('wasm_null_d3d::NullContext::UpdateSubresource(ID3D11Resource*, unsigned int, D3D11_BOX const*, void const*, unsigned int, unsigned int)'): ['var_p1'],
        READBACK: ['var_p0']}
CALLOC = fn('emscripten_builtin_calloc')
ENGINE_CALLS = f'''
/* GTA-174 (Scripts/prepare_d3d_lazy_copies.py): the engine's calloc for EngineHost.c's lazy D3D CPU copies. */
u64 pg_d3d_engine_calloc(w2c_game* instance, u64 size) {{ return w2c_game_f{CALLOC}(instance, 1ull, size); }}
'''

# In a Create function the CPU copy is made right after the Usage check that skips it ("no CPU access and not
# staging": goto LABEL) and the virtual StorageSize() call (var_p1 = the size). The hook goes after that call, and
# LABEL is where the function goes on without a copy (after the initial-data copy).
COPY_BLOCK = re.compile(
    r'var_i1 = i32_load' + ACCESS + r'\(u64\)checked_add_u64\(var_j1, (\d+)u\)\);\n\s+var_i2 = 3u;\n\s+var_i1 = var_i1 != var_i2;\n'
    r'\s+if \(var_i1\) \{goto (var_B\d+);\}\n\s+\}\n'
    r'(\s+)var_j1 = var_p0;\n\s+var_j2 = var_p0;\n\s+var_j2 = i64_load' + ACCESS + r'\(u64\)\(var_j2\)\);\n'
    r'\s+var_j2 = i64_load' + ACCESS + r'\(u64\)checked_add_u64\(var_j2, \d+u\)\);\n'
    r'\s+var_j1 = CALL_INDIRECT\([^\n]*w2c_game_t0[^\n]*\);\n\s+var_p1 = var_j1;\n'
    r'(?=\s+var_j1 = var_p0;\n\s+var_j1 = i64_load' + ACCESS + r'\(u64\)checked_add_u64\(var_j1, (\d+)u\)\);\n(?:\s+var_p3 = var_j1;\n)?\s+var_j2 = 0ull;\n)')
# The desc's copy in the resource starts at +96 (EngineHost.c reads a 2D texture's there for its statistics).
DESC_AT_96 = re.compile(r'var_j2 = var_p1;\n\s+var_(j2|o2) = (?:i64|v128)_load' + ACCESS + r'\(u64\)\(var_j2\)\);\n\s+(?:i64|v128)_store' + ACCESS + r'\(u64\)checked_add_u64\(var_j1, 96u\), var_\1\);')
STATS_CALLS = re.compile(r'(?:  pg_d3d_(?:map_type|touch)\([^\n]*/\* GTA-174 \*/\n)*')

def function(s, number):
    if f' w2c_game_f{number}(w2c_game* instance' not in s: return None     # quick: most files don't have it
    head = re.search(r'^\w+ w2c_game_f' + str(number) + r'\(w2c_game\* instance[^{]*\{$', s, re.M)
    if not head: return None
    return head.start(), s.index('\n}\n', head.start()) + 3

def declare(s):
    if DECLARATIONS in s: return s
    first = re.search(r'^#include "game-[a-z-]*impl\.h"$', s, re.M)
    return s[:first.end()] + '\n' + DECLARATIONS + s[first.end():]

created = needs = 0
for path in sorted((root / 'Generated').glob('game_*.c')):
    s = path.read_text(); changed = False
    for number, (kind, pair, usage) in CREATE.items():
        at = function(s, number)
        if not at: continue
        body = s[at[0]:at[1]]
        if 'pg_d3d_lazy_create(' in body: print(f'd3d lazy copies: f{number} already patched'); continue
        blocks = list(COPY_BLOCK.finditer(body))
        if len(blocks) != 1 or len(DESC_AT_96.findall(body)) != 1: raise RuntimeError(f'Pinned f{number} (Create, kind {kind}) changed: CPU copy block not found')
        m = blocks[0]
        if (int(m.group(1)), int(m.group(4))) != (usage, pair): raise RuntimeError(f'f{number}: Usage at +{m.group(1)}, pair at +{m.group(4)}')
        call = (f'{m.group(3)}if (pg_d3d_lazy_create(instance, var_p0, var_p0 + {pair}ull, var_p1, var_p2, {kind})) '
                f'{{goto {m.group(2)};}}   /* GTA-174: the copy waits until needed */')
        body = body[:m.end()] + call + '\n' + body[m.end():]
        s = s[:at[0]] + body + s[at[1]:]; changed = True; created += 1
    for number, resources in NEED.items():
        at = function(s, number)
        if not at: continue
        body = s[at[0]:at[1]]
        if 'pg_d3d_lazy_need(' in body: continue
        if body.count('  FUNC_PROLOGUE;\n') != 1: raise RuntimeError(f'Pinned f{number} changed')
        calls = ''.join(f'  pg_d3d_lazy_need(instance, {var});   /* GTA-174 */\n' for var in resources)
        # After prepare_d3d_storage_stats.py's calls, which it puts right after FUNC_PROLOGUE.
        place = STATS_CALLS.match(body, body.index('  FUNC_PROLOGUE;\n') + len('  FUNC_PROLOGUE;\n')).end()
        s = s[:at[0]] + body[:place] + calls + body[place:] + s[at[1]:]; changed = True; needs += 1
    if function(s, MAP) and 'pg_d3d_engine_calloc(' not in s:
        s = s.rstrip('\n') + '\n' + ENGINE_CALLS; changed = True
    if changed: path.write_text(declare(s))
print(f'd3d lazy copies: {created} Create functions ask before making a CPU copy, {needs} functions make a waiting one first')
if created and (created != 4 or needs != 5): raise RuntimeError('the D3D layer changed: expected 4 Create functions and 5 that need copies')
