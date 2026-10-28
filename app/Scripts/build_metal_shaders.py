#!/usr/bin/env python3
"""Precompiles the game's translated shaders for the native Metal renderer.

The game ships its shaders as WGSL (b/<build>/shaders: index.json, <hash>.wgsl, <hash>.consts.json). This script
translates every vertex, pixel and compute shader to Metal Shading Language with ShaderTool/pgmsl (Tint, with the
D3D11 register slots mapped straight onto Metal argument indices), compiles them to AIR in parallel and links one
metallib per SDK. It also writes the reflection table the renderer loads at startup (one JSON object per line).

Outputs (GeneratedResources/, bundled by project.yml):
  shaders-<sdk>.metallib   every shader, entry point s_<hash>
  shader-reflection.jsonl  bindings, stage inputs/outputs, workgroup sizes, constant tables

Usage: build_metal_shaders.py <shader dir> [--sdk iphoneos|iphonesimulator ...]
"""
import argparse, concurrent.futures, json, os, re, shutil, subprocess, sys, tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WORK = os.path.join(ROOT, 'Build', 'MetalShaders')
OUT = os.path.join(ROOT, 'GeneratedResources')
# The oldest iOS the app runs on (project.yml deploymentTarget); a metallib built for a newer one won't load.
TARGETS = {'iphoneos': 'air64-apple-ios16.0', 'iphonesimulator': 'air64-apple-ios16.0-simulator',
           'maccatalyst': 'air64-apple-ios16.0-macabi'}
TOOL_SDK = {'maccatalyst': 'macosx'}  # Mac Catalyst uses the macOS Metal toolchain


def run(cmd, cwd=None):
    r = subprocess.run(cmd, capture_output=True, text=True, cwd=cwd)
    if r.returncode:
        raise RuntimeError(' '.join(cmd) + '\n' + r.stderr[-2000:])


def compile_batch(sdk, compiler, sources, air):
    """Compiles a batch of .metal files in one compiler process (process start-up dominates single-file compiles)."""
    tmp = tempfile.mkdtemp(dir=air)
    try:
        run([compiler, '-c', '-std=metal3.0', '-target', TARGETS[sdk], '-ffast-math', '-Wno-unused-variable'] + sources, cwd=tmp)
        for src in sources:
            name = os.path.splitext(os.path.basename(src))[0] + '.air'
            os.replace(os.path.join(tmp, name), os.path.join(air, name))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


# GTA-77: every pixel shader cleans its colour outputs of NaN and infinity where the renderer asks (pg_nanc, buffer 30:
# a mask of outputs, a zero the compiler can't see, then each target's largest finite value as float bits). The renderer
# asks for RG11B10 and RGB9E5 targets (MRRenderer.mm, ensurePass; PG_NAN_CLAMP_OLD=1 never asks). The shaders are compiled
# with -ffast-math, where isnan() may fold to false, so the test works on the bits, xor'ed with the hidden zero: NaN
# becomes 0, infinity and anything past the format's largest value become that value, and the sign stays.
# PG_NO_SHADER_NAN_CLAMP=1 builds the library without it (the renderer then has nothing to switch).
NANC_BUFFER = 30
NANC_HELPERS = '''
static inline uint pg_nanc_bits(uint u, uint maxbits) { uint m = u & 0x7fffffffu; m = m > 0x7f800000u ? 0u : min(m, maxbits); return (u & 0x80000000u) | m; }
static inline float pg_nanc_clean(float v, uint salt, uint maxbits) { return as_type<float>(pg_nanc_bits(as_type<uint>(v) ^ salt, maxbits)); }
static inline float2 pg_nanc_clean(float2 v, uint salt, uint maxbits) { uint2 u = as_type<uint2>(v) ^ salt; return as_type<float2>(uint2(pg_nanc_bits(u.x, maxbits), pg_nanc_bits(u.y, maxbits))); }
static inline float3 pg_nanc_clean(float3 v, uint salt, uint maxbits) { return float3(pg_nanc_clean(v.x, salt, maxbits), pg_nanc_clean(v.y, salt, maxbits), pg_nanc_clean(v.z, salt, maxbits)); }
static inline float4 pg_nanc_clean(float4 v, uint salt, uint maxbits) { uint4 u = as_type<uint4>(v) ^ salt; return as_type<float4>(uint4(pg_nanc_bits(u.x, maxbits), pg_nanc_bits(u.y, maxbits), pg_nanc_bits(u.z, maxbits), pg_nanc_bits(u.w, maxbits))); }
'''


def add_nan_clamp(text, h):
    """The pixel shader's MSL with the clean at its return, or None when it has no float colour output."""
    m = re.search(r'\nfragment (\S+) s_' + h + r'\((.*)\) \{\n', text)
    if not m or m.group(1) == 'void':
        return None
    sm = re.search(r'\nstruct ' + re.escape(m.group(1)) + r' \{\n(.*?)\n\};', text, re.S)
    if not sm:
        return None
    outs = []
    for line in sm.group(1).split('\n'):
        mm = re.match(r'\s*(float|float2|float3|float4) (\w+) \[\[color\((\d+)\)\]\];$', line)
        if mm and int(mm.group(3)) < 8:
            outs.append((mm.group(2), int(mm.group(3))))
    if not outs:
        return None
    body_at = m.end()
    ret = re.compile(r'\n(\s*)return ([^;]+);').search(text, body_at)
    if not ret or '\nfragment ' in text[body_at:ret.start()]:
        return None
    ind = ret.group(1)
    clean = [ind + 'if (pg_nanc[0] != 0u) {']
    for member, k in outs:
        clean.append('%s  if ((pg_nanc[0] & %du) != 0u) pg_out.%s = pg_nanc_clean(pg_out.%s, pg_nanc[1], pg_nanc[%d]);' % (ind, 1 << k, member, member, 4 + k))
    clean.append(ind + '}')
    new_ret = '\n%s%s pg_out = %s;\n%s\n%sreturn pg_out;' % (ind, m.group(1), ret.group(2), '\n'.join(clean), ind)
    params = m.group(2)
    param = 'const constant uint* pg_nanc [[buffer(%d)]]' % NANC_BUFFER
    sig = '\nfragment %s s_%s(%s%s) {\n' % (m.group(1), h, params + ', ' if params.strip() else '', param)
    out = text[:m.start()] + sig + text[m.end():ret.start()] + new_ret + text[ret.end():]
    ns = 'namespace n_%s {\n' % h
    at = out.find(ns)
    if at < 0:
        return None
    return out[:at + len(ns)] + NANC_HELPERS + out[at + len(ns):]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('shaders')
    ap.add_argument('--sdk', action='append', choices=sorted(TARGETS))
    args = ap.parse_args()
    sdks = args.sdk or ['iphoneos', 'iphonesimulator']
    tool = os.environ.get('PGMSL') or os.path.join(ROOT, 'Tools', 'pgmsl', 'pgmsl')
    if not os.path.exists(tool):
        sys.exit('The shader translator is missing: run Scripts/fetch_shader_tool.py (or build it with ShaderTool/build_pgmsl.sh).')
    index = json.load(open(os.path.join(args.shaders, 'index.json')))
    msl = os.path.join(WORK, 'msl')
    os.makedirs(msl, exist_ok=True)
    os.makedirs(OUT, exist_ok=True)
    entries = [(h, r) for h, r in index.items() if not h.startswith('_') and r.get('ok') and r['stage'] in ('vs', 'ps', 'cs')]
    listing = os.path.join(WORK, 'list.txt')
    with open(listing, 'w') as f:
        for h, r in entries:
            f.write('%s %s %s\n' % (h, r['stage'], os.path.join(args.shaders, h + '.wgsl')))
    reflection = os.path.join(WORK, 'reflection.jsonl')
    r = subprocess.run([tool, listing, msl, reflection], capture_output=True, text=True)
    print(r.stderr.strip().splitlines()[-1] if r.stderr.strip() else 'pgmsl: no output')
    if r.returncode:
        sys.exit(r.stderr)

    # GTA-77: pixel shaders with the NaN/infinity clean go to msl-nanc/ (written only when changed, so unchanged shaders
    # keep their compiled AIR); the others compile from msl/ as translated.
    nanc_dir = os.path.join(WORK, 'msl-nanc')
    os.makedirs(nanc_dir, exist_ok=True)
    sources, cleaned = {}, set()
    for line in open(reflection):
        o = json.loads(line)
        h = o['h']
        src = os.path.join(msl, h + '.metal')
        sources[h] = src
        if o['st'] != 'ps' or os.environ.get('PG_NO_SHADER_NAN_CLAMP') == '1':
            continue
        patched = add_nan_clamp(open(src).read(), h)
        if patched is None:
            continue
        dst = os.path.join(nanc_dir, h + '.metal')
        if not (os.path.exists(dst) and open(dst).read() == patched):
            with open(dst, 'w') as f:
                f.write(patched)
        sources[h] = dst
        cleaned.add(h)
    print('NaN/infinity clean (GTA-77): %d pixel shaders' % len(cleaned))

    # reflection + labels + constant tables (binding 15: one u32 per 16-byte row)
    with open(os.path.join(OUT, 'shader-reflection.jsonl'), 'w') as out:
        for line in open(reflection):
            o = json.loads(line)
            rec = index[o['h']]
            o['label'] = rec.get('effect', '?') + '::' + rec.get('program', '?')
            if rec.get('consts'):
                o['k'] = json.load(open(os.path.join(args.shaders, o['h'] + '.consts.json')))
            if o['h'] in cleaned:
                o['nc'] = 1
            out.write(json.dumps(o, separators=(',', ':')) + '\n')

    hashes = [json.loads(l)['h'] for l in open(reflection)]
    for sdk in sdks:
        air = os.path.join(WORK, 'air-' + sdk + '-' + TARGETS[sdk].split('-')[2])  # a new target compiles afresh
        os.makedirs(air, exist_ok=True)
        compiler = subprocess.run(['xcrun', '-sdk', TOOL_SDK.get(sdk, sdk), '-f', 'metal'], capture_output=True, text=True).stdout.strip()
        stale = []
        for h in hashes:
            src, dst = sources[h], os.path.join(air, h + '.air')
            # a shader that moved between msl/ and msl-nanc/ compiles again even if its AIR is newer than the source
            mark = dst + '.from'
            if not (os.path.exists(dst) and os.path.getmtime(dst) >= os.path.getmtime(src) and os.path.exists(mark) and open(mark).read() == src):
                stale.append(src)
                with open(mark, 'w') as f:
                    f.write(src)
        batches = [stale[i:i + 48] for i in range(0, len(stale), 48)]
        failed = 0
        with concurrent.futures.ThreadPoolExecutor(os.cpu_count() or 8) as pool:
            for fut in concurrent.futures.as_completed([pool.submit(compile_batch, sdk, compiler, b, air) for b in batches]):
                try:
                    fut.result()
                except Exception as e:
                    failed += 1
                    if failed <= 3:
                        print(str(e)[-3000:])
        print('%s: compiled %d shaders in %d batches' % (sdk, len(stale), len(batches)))
        files = os.path.join(WORK, 'air-' + sdk + '.txt')
        with open(files, 'w') as f:
            for h in hashes:
                f.write(os.path.join(air, h + '.air') + '\n')
        lib = os.path.join(OUT, 'shaders-%s.metallib' % sdk)
        run(['xcrun', '-sdk', TOOL_SDK.get(sdk, sdk), 'metallib', '@' + files, '-o', lib])
        print('%s: %d shaders, %.1f MB' % (sdk, len(hashes), os.path.getsize(lib) / 1048576))


if __name__ == '__main__':
    main()
