"""Constant buffers freed by a device restore while a D3D context still holds them (GTA-198; Source/EngineHost.c).

16 player logs (v1.4.3 to v1.4.6) stop with "Native trap 6" in __dynamic_cast (f91082, table index 0) called from
wasm_null_d3d::NullContext::SetCBuffers, a few frames after a live resize's device restore (a resolution change, a
TV). The cause, found with PG_CBUF_TRACE=1 in the simulator:
- rage::decalRenderStaticBatcher::FinishCurrentBatch binds the decal manager's own 12 KB constant buffer
  (decalManager +53736) to vertex shader slot 6 of the RageDirect3DDeviceContext11 wrapper.
- That wrapper keeps the buffers bound per stage (six arrays of 14 pointers from +1656). A null in a later call does
  not replace a slot, and the wrapper forwards its whole changed range, unchanged slots in between too, to the null
  context. Slot 6 keeps the decal buffer for good, and most draws (skinned peds, wheels, water) forward it again.
- A device restore runs decalManager::DeviceResetCallback, which destroys that buffer and makes a new one
  (CreateDX11Buffers). The wrapper's slot 6 still holds the old one. On iPhone its memory is soon something else,
  and the next draw that forwards slot 6 makes SetCBuffers cast garbage. In the simulator the new buffer lands at the
  old address, so nothing traps there.

The fix:
- The buffer destructors (pg_cbuffer_freed) clear a dying constant buffer from every wrapper context's slots, the
  way the wrapper's own VSClearConstantBuffers would. The wrapper's VSSetConstantBuffers tells the host each context
  it sees (pg_cbuffer_context).
- Guard: in SetCBuffers, a buffer whose vtable is not the D3D buffer's (read from NullDevice::CreateBuffer below) is
  bound as nothing, as the cast's own "not a buffer" answer does, and logged (pg_cbuffer_dead). Live buffers never
  get there: the vtable cache answers them first.
Diagnostics and tests:
- PG_CBUF_TRACE=1: the host keeps the freed constant buffers until CreateBuffer reuses the address
  (pg_cbuffer_made), and logs every bind of one (pg_cbuffer_bound) with the native frames that freed it.
- PG_TEST_CBUF_KEEP=1 (simulator only): the deleting destructor keeps a freed constant buffer's memory and fills it
  as freed memory reads on a phone (pg_cbuffer_keep), so the player's stop happens in the simulator too;
  PG_TEST_CBUF_NOCLEAR=1 leaves the context slots alone and PG_TEST_CBUF_NOGUARD=1 casts as before: with both, the
  simulator runs as the game did before this fix.
Idempotent; matches the *_shared and the *_eplain (Scripts/prepare_plain_engine.py) spellings.
"""
from pathlib import Path
from engine_names import fn
import re
root = Path(__file__).resolve().parents[1]
MARK = 'GTA-198'
L = r'(?:shared|eplain)'
SET_CBUFFERS = fn('wasm_null_d3d::NullContext::SetCBuffers(unsigned int, unsigned int, unsigned int, ID3D11Buffer* const*)')
CREATE = fn('wasm_null_d3d::NullDevice::CreateBuffer(D3D11_BUFFER_DESC const*, D3D11_SUBRESOURCE_DATA const*, ID3D11Buffer**)')
DTORS = [fn('wasm_null_d3d::NullResource<wasm_null_d3d::Stub_ID3D11Buffer, D3D11_BUFFER_DESC>::~NullResource()'),
         fn('wasm_null_d3d::NullResource<wasm_null_d3d::Stub_ID3D11Buffer, D3D11_BUFFER_DESC>::~NullResource()_567')]
CAST = fn('__dynamic_cast')
VS_SET = fn('RageDirect3DDeviceContext11::VSSetConstantBuffers(unsigned int, unsigned int, ID3D11Buffer* const*)')
DELETE = fn('operator delete(void*)')
PROLOGUE = '  (void)wasm_rt_local_memory_size;\n'
DECLARATIONS = ('extern u32 pg_cbuffer_dead(w2c_game *instance, u64 buffer, u64 vtable, u64 expected, u32 stage, u32 slot); '
                'extern void pg_cbuffer_bound(w2c_game *instance, u64 buffer, u32 stage, u32 slot); extern int pg_cbuffer_tracing; '
                'extern void pg_cbuffer_freed(w2c_game *instance, u64 buffer); extern void pg_cbuffer_made(u64 buffer); '
                'extern u32 pg_cbuffer_keep(w2c_game *instance, u64 buffer); extern u64 pg_cbuffer_seen_context; extern void pg_cbuffer_context(u64 context);')
FREE_CALL = f'  var_j0 = var_p0;\n  w2c_game_f{DELETE}(instance, var_j0);\n  FUNC_EPILOGUE;\n}}\n'

def body_range(s, number):
    head = re.search(r'^(?:u32|u64|void) w2c_game_f' + str(number) + r'\(w2c_game\* instance[^{]*\{$', s, re.M)
    if not head: return None
    return head.start(), s.index('\n}\n', head.start()) + 3

files = {}
def source(number):
    for path in sorted((root / 'Generated').glob('game_*.c')):
        if path not in files: files[path] = path.read_text()
        if body_range(files[path], number): return path
    raise RuntimeError(f'Pinned f{number} not found')

# The D3D buffer's vtable: what CreateBuffer stores at offset 0 of the object it makes.
path = source(CREATE)
start, end = body_range(files[path], CREATE)
body = files[path][start:end]
stores = re.findall(r'\n(\s+)var_j2 = (\d+)ull;\n\s+i64_store_' + L + r'\([^;]*\(u64\)\(var_j1\), var_j2\);\n', body)
if len(stores) != 1: raise RuntimeError(f'Pinned f{CREATE} (CreateBuffer): the vtable store changed')
indent, VTABLE = stores[0]
if MARK not in body:
    at = re.search(r'\n\s+var_j2 = ' + VTABLE + r'ull;\n\s+i64_store_' + L + r'\([^;]*\(u64\)\(var_j1\), var_j2\);\n', body).end()
    body = body[:at] + f'{indent}if (pg_cbuffer_tracing) pg_cbuffer_made(var_j1);   /* {MARK} */\n' + body[at:]
    files[path] = files[path][:start] + body + files[path][end:]

kept = False
for number in DTORS:
    path = source(number)
    start, end = body_range(files[path], number)
    body = files[path][start:end]
    if MARK in body: kept = True; continue
    if body.count(PROLOGUE) != 1 or VTABLE + 'ull;' not in body: raise RuntimeError(f'Pinned f{number} (buffer destructor) changed')
    body = body.replace(PROLOGUE, PROLOGUE + f'  pg_cbuffer_freed(instance, var_p0);   /* {MARK}: out of the D3D contexts\' constant buffer slots */\n', 1)
    if body.endswith(FREE_CALL):   # the deleting destructor: PG_TEST_CBUF_KEEP=1 (simulator) keeps the memory, as garbage
        body = body[:-len(FREE_CALL)] + f'  var_j0 = var_p0;\n  if (!pg_cbuffer_keep(instance, var_j0)) w2c_game_f{DELETE}(instance, var_j0);   /* {MARK} */\n  FUNC_EPILOGUE;\n}}\n'
        kept = True
    files[path] = files[path][:start] + body + files[path][end:]

if not kept: raise RuntimeError('Pinned buffer destructors: the deleting one no longer ends in operator delete')

# RageDirect3DDeviceContext11 keeps the constant buffers bound per stage (six arrays of 14 from +1656) and forwards
# its whole changed range, unchanged slots in between too: the host learns each such context here.
path = source(VS_SET)
start, end = body_range(files[path], VS_SET)
body = files[path][start:end]
if MARK not in body:
    if body.count(PROLOGUE) != 1 or '1656ull;' not in body: raise RuntimeError(f'Pinned f{VS_SET} (RageDirect3DDeviceContext11::VSSetConstantBuffers) changed')
    body = body.replace(PROLOGUE, PROLOGUE + f'  if (var_p0 != pg_cbuffer_seen_context) pg_cbuffer_context(var_p0);   /* {MARK} */\n', 1)
    files[path] = files[path][:start] + body + files[path][end:]

path = source(SET_CBUFFERS)
start, end = body_range(files[path], SET_CBUFFERS)
body = files[path][start:end]
if MARK not in body:
    # var_l6: the buffer (0 binds nothing, var_B3), var_l9: its vtable, var_p1: the stage, var_p2 + var_l7: the slot.
    LOADED = re.compile(r'(\n(\s+)var_l6 = var_j0;\n\s+var_i0 = !\(var_j0\);\n\s+if \(var_i0\) \{goto var_B3;\}\n)')
    CALL = re.compile(r'(\n(\s+)var_j0 = var_l6;\n\s+var_j1 = \d+ull;\n\s+var_j2 = \d+ull;\n\s+var_j3 = 18446744073709551614ull;\n'
                      r'\s+var_j0 = w2c_game_f' + str(CAST) + r'\(instance, var_j0, var_j1, var_j2, var_j3\);\n)')
    if len(LOADED.findall(body)) != 1 or len(CALL.findall(body)) != 1 or 'var_B3:;' not in body or 'var_l9 = var_j0;' not in body:
        raise RuntimeError(f'Pinned f{SET_CBUFFERS} (SetCBuffers) changed')
    body = LOADED.sub(lambda m: m.group(1) + f'{m.group(2)}if (pg_cbuffer_tracing) pg_cbuffer_bound(instance, var_l6, var_p1, var_p2 + (u32)var_l7);   /* {MARK} */\n', body, 1)
    body = CALL.sub(lambda m: f'\n{m.group(2)}if (pg_cbuffer_dead(instance, var_l6, var_l9, {VTABLE}ull, var_p1, var_p2 + (u32)var_l7)) goto var_B3;   /* {MARK}: a freed buffer binds nothing */' + m.group(1), body, 1)
    files[path] = files[path][:start] + body + files[path][end:]

changed = 0
for path, s in files.items():
    if MARK not in s or s == path.read_text(): continue
    if 'pg_cbuffer_dead(w2c_game' not in s:
        first = re.search(r'^#include "game-[a-z-]*(?:impl|guards)\.h"$', s, re.M)
        s = s[:first.end()] + '\n' + DECLARATIONS + s[first.end():]
    path.write_text(s); changed += 1
print(f'stale constant buffers: patched {changed} files' if changed else 'stale constant buffers: already patched')
