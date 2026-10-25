#!/usr/bin/env python3
"""A minimal PE linker for the runtime self-test mod (GTA-188): COFF objects from
`clang -target x86_64-pc-windows-msvc -c` into a 64-bit Windows DLL (.asi), without Visual Studio's linker.

Every symbol no object defines becomes an import (the script mod layer resolves imports by name, so they all come
from one DLL name; Script Hook V's functions from ScriptHookV.dll). Calls get a "jmp [IAT]" thunk, __imp_ names the IAT
slot itself. Sections are merged by kind (.text, .rdata with .xdata, .data with .bss, .pdata), with base relocations
for 64-bit addresses, an import directory and the exception directory (.pdata).

    link_pe.py -o selftest.asi --entry DllMainCRTStartup a.obj b.obj ...
"""
import argparse
import struct

IMAGE_BASE = 0x180000000
SECTION_ALIGN, FILE_ALIGN = 0x1000, 0x200
LOCAL_DATA = {'??_7type_info@@6B@': 16, '_fltused': 4, '__security_cookie': 8}  # defined here, not imported
SCRIPT_HOOK = ('script', 'keyboardHandler', 'native', 'getGlobalPtr', 'getGameVersion', 'worldGetAll', 'createTexture', 'drawTexture')


def align(v, a):
    return (v + a - 1) & ~(a - 1)


class Obj:
    def __init__(self, path):
        d = open(path, 'rb').read()
        machine, nsec, _, symptr, nsym, optsize, _ = struct.unpack_from('<HHIIIHH', d, 0)
        assert machine == 0x8664, path
        strtab = symptr + 18 * nsym
        def name_at(raw):
            if raw[:4] == b'\0\0\0\0':
                off = struct.unpack_from('<I', raw, 4)[0]
                return d[strtab + off:d.index(b'\0', strtab + off)].decode()
            return raw.rstrip(b'\0').decode()
        self.sections = []
        for i in range(nsec):
            s = 20 + optsize + 40 * i
            raw = d[s:s + 8]
            name = raw.rstrip(b'\0').decode()
            if name.startswith('/'):
                off = int(name[1:])
                name = d[strtab + off:d.index(b'\0', strtab + off)].decode()
            vsize, va, size, rawptr, relptr, _, nrel, _, ch = struct.unpack_from('<IIIIIIHHI', d, s + 8)
            relocs = [struct.unpack_from('<IIH', d, relptr + 10 * k) for k in range(nrel)]
            data = bytearray(size) if ch & 0x80 else bytearray(d[rawptr:rawptr + size])
            self.sections.append({'name': name, 'data': data, 'relocs': relocs, 'ch': ch, 'align': 1 << max(((ch >> 20) & 15) - 1, 0)})
        self.symbols = {}
        i = 0
        while i < nsym:
            s = symptr + 18 * i
            name = name_at(d[s:s + 8])
            value, secnum, typ, cls, naux = struct.unpack_from('<IhHBB', d, s + 8)
            self.symbols[i] = (name, value, secnum, cls)
            i += 1 + naux


def kind(sec):
    n = sec['name']
    if sec['ch'] & 0xA00 or n.startswith(('.debug', '.llvm', '.drectve')):
        return None
    if n.startswith('.text'):
        return '.text'
    if n.startswith('.pdata'):
        return '.pdata'
    if n.startswith(('.rdata', '.xdata')):
        return '.rdata'
    if n.startswith(('.data', '.bss', '.CRT', '.tls')):
        return '.data'
    return '.rdata'


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('-o', required=True)
    ap.add_argument('--entry', default='DllMainCRTStartup')
    ap.add_argument('objects', nargs='+')
    args = ap.parse_args()
    objs = [Obj(p) for p in args.objects]
    out = {k: bytearray() for k in ('.text', '.rdata', '.data', '.pdata')}
    placed = {}  # (obj, section index) -> (kind, offset)
    for oi, o in enumerate(objs):
        for si, sec in enumerate(o.sections):
            k = kind(sec)
            if not k:
                continue
            buf = out[k]
            buf.extend(b'\0' * (align(len(buf), sec['align']) - len(buf)))
            placed[(oi, si)] = (k, len(buf))
            buf.extend(sec['data'])
    defined = {}  # global name -> (kind, offset)
    for oi, o in enumerate(objs):
        for name, value, secnum, cls in o.symbols.values():
            if secnum > 0 and cls == 2 and (oi, secnum - 1) in placed:
                k, off = placed[(oi, secnum - 1)]
                defined.setdefault(name, (k, off + value))
    for name, size in LOCAL_DATA.items():
        buf = out['.data']; buf.extend(b'\0' * (align(len(buf), 16) - len(buf)))
        defined.setdefault(name, ('.data', len(buf))); buf.extend(b'\0' * size)
    if '__chkstk' not in defined:  # stack probes aren't needed in the interpreter: just return
        buf = out['.text']; buf.extend(b'\xcc' * (align(len(buf), 16) - len(buf)))
        defined['__chkstk'] = ('.text', len(buf)); buf.extend(b'\xc3')
    imports = []
    for o in objs:
        for name, value, secnum, cls in o.symbols.values():
            if secnum == 0 and cls == 2:
                target = name[6:] if name.startswith('__imp_') else name
                if target not in defined and target not in imports:
                    imports.append(target)
    # thunks: jmp [rip+IAT slot], filled in once the IAT is placed
    thunks = {}
    for name in imports:
        buf = out['.text']; buf.extend(b'\xcc' * (align(len(buf), 8) - len(buf)))
        thunks[name] = len(buf); buf.extend(b'\xff\x25\0\0\0\0\xcc\xcc')
    # import directory in .rdata: descriptors, lookup table, IAT, names
    rd = out['.rdata']; rd.extend(b'\0' * (align(len(rd), 16) - len(rd)))
    groups = [('ScriptHookV.dll', [n for n in imports if n.startswith(SCRIPT_HOOK)]),
              ('api-ms-win-crt-runtime-l1-1-0.dll', [n for n in imports if not n.startswith(SCRIPT_HOOK)])]
    groups = [g for g in groups if g[1]]
    desc_at = len(rd); rd.extend(b'\0' * 20 * (len(groups) + 1))
    layout = []
    for dll, names in groups:
        ilt = len(rd); rd.extend(b'\0' * 8 * (len(names) + 1))
        iat = len(rd); rd.extend(b'\0' * 8 * (len(names) + 1))
        hints = []
        for n in names:
            rd.extend(b'\0' * (len(rd) & 1)); hints.append(len(rd)); rd.extend(b'\0\0' + n.encode() + b'\0')
        dllname = len(rd); rd.extend(dll.encode() + b'\0')
        layout.append((ilt, iat, hints, dllname, names))
    # section RVAs
    rvas = {}; rva = SECTION_ALIGN
    for k in ('.text', '.rdata', '.data', '.pdata'):
        rvas[k] = rva; rva = align(rva + max(len(out[k]), 1), SECTION_ALIGN)
    reloc_rva = rva
    def addr(loc):
        return rvas[loc[0]] + loc[1]
    iat_slot = {}
    for i, (ilt, iat, hints, dllname, names) in enumerate(layout):
        struct.pack_into('<IIIII', rd, desc_at + 20 * i, rvas['.rdata'] + ilt, 0, 0, rvas['.rdata'] + dllname, rvas['.rdata'] + iat)
        for j, n in enumerate(names):
            struct.pack_into('<Q', rd, ilt + 8 * j, rvas['.rdata'] + hints[j])
            struct.pack_into('<Q', rd, iat + 8 * j, rvas['.rdata'] + hints[j])
            iat_slot[n] = rvas['.rdata'] + iat + 8 * j
    for n, off in thunks.items():
        struct.pack_into('<i', out['.text'], off + 2, iat_slot[n] - (rvas['.text'] + off + 6))
    # relocations
    fixups = []
    for oi, o in enumerate(objs):
        for si, sec in enumerate(o.sections):
            if (oi, si) not in placed:
                continue
            k, base = placed[(oi, si)]
            buf = out[k]
            for va, symidx, typ in sec['relocs']:
                name, value, secnum, cls = o.symbols[symidx]
                if secnum > 0:
                    if (oi, secnum - 1) not in placed:
                        raise SystemExit('reference to a dropped section: %s' % name)
                    sk, soff = placed[(oi, secnum - 1)]; target = rvas[sk] + soff + value
                elif name in defined:
                    target = addr(defined[name])
                elif name.startswith('__imp_'):
                    target = iat_slot[name[6:]]
                elif name in thunks:
                    target = rvas['.text'] + thunks[name]
                else:
                    raise SystemExit('undefined: %s' % name)
                at = base + va; place = rvas[k] + at
                if typ == 1:  # ADDR64
                    struct.pack_into('<Q', buf, at, struct.unpack_from('<Q', buf, at)[0] + IMAGE_BASE + target); fixups.append(place)
                elif typ == 3:  # ADDR32NB
                    struct.pack_into('<I', buf, at, (struct.unpack_from('<I', buf, at)[0] + target) & 0xFFFFFFFF)
                elif 4 <= typ <= 9:  # REL32, REL32_1..5
                    struct.pack_into('<i', buf, at, struct.unpack_from('<i', buf, at)[0] + target - (place + 4 + typ - 4))
                elif typ in (0xA, 0xB):  # SECTION, SECREL (debug only)
                    pass
                else:
                    raise SystemExit('relocation type %d not handled' % typ)
    # base relocations
    reloc = bytearray()
    pages = {}
    for f in sorted(fixups):
        pages.setdefault(f & ~0xFFF, []).append(f & 0xFFF)
    for page, offs in sorted(pages.items()):
        entries = [(10 << 12) | o for o in offs]
        if len(entries) & 1:
            entries.append(0)
        reloc += struct.pack('<II', page, 8 + 2 * len(entries)) + struct.pack('<%dH' % len(entries), *entries)
    out['.reloc'] = reloc
    rvas['.reloc'] = reloc_rva
    size_of_image = align(reloc_rva + max(len(reloc), 1), SECTION_ALIGN)
    # headers
    names = ['.text', '.rdata', '.data', '.pdata', '.reloc']
    ch = {'.text': 0x60000020, '.rdata': 0x40000040, '.data': 0xC0000040, '.pdata': 0x40000040, '.reloc': 0x42000040}
    headers = 0x400
    img = bytearray(headers)
    img[0:2] = b'MZ'; struct.pack_into('<I', img, 0x3C, 0x80)
    pe = 0x80; img[pe:pe + 4] = b'PE\0\0'
    struct.pack_into('<HHIIIHH', img, pe + 4, 0x8664, len(names), 0, 0, 0, 240, 0x2022)
    opt = pe + 24
    entry = addr(defined[args.entry])
    struct.pack_into('<HBBIIIII', img, opt, 0x20B, 14, 0, len(out['.text']), 0, 0, entry, rvas['.text'])
    struct.pack_into('<QIIHHHHHHIIIIHHQQQQII', img, opt + 24, IMAGE_BASE, SECTION_ALIGN, FILE_ALIGN, 6, 0, 0, 0, 6, 0, 0,
                     size_of_image, headers, 0, 2, 0x160, 0x100000, 0x1000, 0x100000, 0x1000, 0, 16)
    dirs = opt + 112
    struct.pack_into('<II', img, dirs + 8 * 1, rvas['.rdata'] + desc_at, 20 * (len(groups) + 1))
    struct.pack_into('<II', img, dirs + 8 * 3, rvas['.pdata'], len(out['.pdata']))
    struct.pack_into('<II', img, dirs + 8 * 5, rvas['.reloc'], len(reloc))
    raw = headers
    body = bytearray()
    for i, n in enumerate(names):
        data = out[n]; size = align(len(data), FILE_ALIGN)
        s = opt + 240 + 40 * i
        img[s:s + 8] = n.encode().ljust(8, b'\0')
        struct.pack_into('<IIIIIIHHI', img, s + 8, max(len(data), 1), rvas[n], size, raw + len(body), 0, 0, 0, 0, ch[n])
        body += data + b'\0' * (size - len(data))
    open(args.o, 'wb').write(img + body)
    print('%s: %d imports, entry +0x%x, %d KB' % (args.o, len(imports), entry, (len(img) + len(body)) // 1024))


main()
