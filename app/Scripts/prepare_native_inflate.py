"""Native zstd and zlib for the engine's decompression (Source/NativeDecompress.c, GTA-216).

The streamer decompresses every resource with the engine's own zstd (ZSTD_decompressStream) or zlib (inflate), as
translated wasm. A hook at the start of each function lets the native decoder take the call: it answers 1 and the
wasm body doesn't run, or 0 to let it run (PG_NATIVE_INFLATE=0, a stream the wasm decoder started, the verify mode's
own comparison call). inflateInit2_, inflateReset and inflateEnd tell the native side about each z_stream first and
then run as before, so the wasm decoder stays ready for any stream that stays with it. Idempotent.
"""
from pathlib import Path
from engine_names import fn
import re
root = Path(__file__).resolve().parents[1]
HOOKS = {   # engine function: (its generated head, the hook line)
    'ZSTD_decompressStream': ('u64 w2c_game_f{n}(w2c_game* instance, u64 var_p0, u64 var_p1, u64 var_p2) {{\n',
                              '  {{ u64 pg_r; if (pg_zstd_stream(instance, var_p0, var_p1, var_p2, &pg_r)) return pg_r; }}\n'),
    'inflate': ('u32 w2c_game_f{n}(w2c_game* instance, u64 var_p0, u32 var_p1) {{\n',
                '  {{ u32 pg_r; if (pg_inflate(instance, var_p0, var_p1, &pg_r)) return pg_r; }}\n'),
    'inflateInit2_': ('u32 w2c_game_f{n}(w2c_game* instance, u64 var_p0, u32 var_p1) {{\n', '  pg_inflate_lifecycle(instance, var_p0, 0, var_p1);\n'),
    'inflateReset': ('u32 w2c_game_f{n}(w2c_game* instance, u64 var_p0) {{\n', '  pg_inflate_lifecycle(instance, var_p0, 1, 0);\n'),
    'inflateEnd': ('u32 w2c_game_f{n}(w2c_game* instance, u64 var_p0) {{\n', '  pg_inflate_lifecycle(instance, var_p0, 2, 0);\n'),
}
DECLS = ('\nextern u32 pg_zstd_stream(w2c_game *instance, u64 dctx, u64 out, u64 in, u64 *result);'
         '\nextern u32 pg_inflate(w2c_game *instance, u64 strm, u32 flush, u32 *result);'
         '\nextern void pg_inflate_lifecycle(w2c_game *instance, u64 strm, u32 kind, u32 window_bits);')
files = sorted((root / 'Generated').glob('game_*.c'))
for name, (head, hook) in HOOKS.items():
    n = fn(name); head = head.format(n=n); hook = hook.format()
    for path in files:
        s = path.read_text()
        if head not in s: continue
        start = s.index(head); end = s.index('\n}\n', start); body = s[start:end]
        if hook in body: print(f'native decompression: {name} already hooked'); break
        if body.count('  FUNC_PROLOGUE;\n') != 1: raise RuntimeError(f'Pinned f{n} ({name}) changed')
        s = s[:start] + body.replace('  FUNC_PROLOGUE;\n', hook + '  FUNC_PROLOGUE;\n', 1) + s[end:]
        if 'extern u32 pg_zstd_stream(' not in s:
            first = re.search(r'^#include "game-[a-z-]*impl\.h"$', s, re.M)
            s = s[:first.end()] + DECLS + s[first.end():]
        path.write_text(s)
        print(f'native decompression: hooked {name} (f{n}) in {path.name}')
        break
    else:
        raise RuntimeError(f'f{n} ({name}) not found')
