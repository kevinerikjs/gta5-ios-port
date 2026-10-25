"""Which keys a Script Hook V mod uses, found before it runs (GTA-177 investigation).

    python3 Harness/mod_keys.py MOD.asi [MOD_FOLDER]

Two sources, both read without running the mod:
- The .asi itself (Windows x64 PE): the keyboard functions it imports (GetAsyncKeyState, GetKeyState, Script Hook V's
  keyboardHandlerRegister), and the key codes passed to them as constants: `mov ecx, VK` before a call through the
  import, or before a call to a small helper that passes its argument on (IsKeyPressed(vk) style).
- The mod's .ini files: settings whose name says key/hotkey/button with a key code, and the comment that explains them.

A mod that registers Script Hook V's keyboard handler receives every key, so its keys can only come from its .ini or
from watching what it reacts to while it runs (the app's polled-keys list covers GetAsyncKeyState only).
"""
import re, struct, sys
from pathlib import Path

VK = {8: 'Backspace', 9: 'Tab', 13: 'Enter', 16: 'Shift', 17: 'Ctrl', 18: 'Alt', 27: 'Esc', 32: 'Space', 33: 'Page Up',
      34: 'Page Down', 35: 'End', 36: 'Home', 37: 'Left', 38: 'Up', 39: 'Right', 40: 'Down', 45: 'Insert', 46: 'Delete',
      106: 'Num *', 107: 'Num +', 109: 'Num -', 110: 'Num .', 111: 'Num /', 160: 'Left Shift', 161: 'Right Shift',
      162: 'Left Ctrl', 163: 'Right Ctrl', 164: 'Left Alt', 165: 'Right Alt'}
VK.update({48 + i: str(i) for i in range(10)}); VK.update({65 + i: chr(65 + i) for i in range(26)})
VK.update({96 + i: f'Num {i}' for i in range(10)}); VK.update({112 + i: f'F{i + 1}' for i in range(24)})
def key_name(v): return VK.get(v, f'key {v}')

def pe_keys(path):
    data = Path(path).read_bytes()
    pe = struct.unpack_from('<I', data, 0x3c)[0]
    if data[pe:pe + 4] != b'PE\0\0': raise SystemExit(f'{path}: not a PE file')
    nsec, = struct.unpack_from('<H', data, pe + 6); optsize, = struct.unpack_from('<H', data, pe + 20)
    opt = pe + 24; magic, = struct.unpack_from('<H', data, opt)
    dirs = opt + (112 if magic == 0x20b else 96)
    imp_rva, = struct.unpack_from('<I', data, dirs + 8)
    sections = []
    for i in range(nsec):
        o = opt + optsize + i * 40
        name = data[o:o + 8].rstrip(b'\0').decode(errors='replace')
        vsize, va, rsize, raw = struct.unpack_from('<IIII', data, o + 8)
        sections.append((name, va, max(vsize, rsize), raw, rsize))
    def off(rva):
        for _, va, size, raw, rsize in sections:
            if va <= rva < va + size: return raw + rva - va
        return None
    def cstr(rva):
        o = off(rva); e = data.index(b'\0', o); return data[o:e].decode(errors='replace')
    # Import table: function name -> IAT slot RVA, for the keyboard functions.
    wanted = {'GetAsyncKeyState', 'GetKeyState', 'GetKeyboardState', 'keyboardHandlerRegister', 'IsKeyPressed', 'IsKeyJustUp'}
    slots, imports = {}, []
    d = off(imp_rva) if imp_rva else None
    while d is not None:
        ilt, _, _, name_rva, iat = struct.unpack_from('<IIIII', data, d)
        if not name_rva: break
        dll = cstr(name_rva); k = 0
        while True:
            entry, = struct.unpack_from('<Q', data, off(ilt or iat) + k * 8)
            if not entry: break
            if not entry >> 63:
                fn = cstr((entry & 0x7fffffff) + 2)
                if fn in wanted: slots[iat + k * 8] = fn; imports.append(f'{dll}!{fn}')
            k += 1
        d += 20
    # Code: `mov ecx, imm32` (B9) or `mov ecx, imm8` via `B9 xx 00 00 00`, then within 16 bytes a call [rip+disp32]
    # (FF 15) to a keyboard import, or a call rel32 (E8) to a helper that itself calls one.
    text = [(va, raw, rsize) for name, va, size, raw, rsize in sections if name in ('.text', 'text', '.code')]
    helpers = set()
    calls = []  # (rva of the call, target rva, import name or None)
    for va, raw, rsize in text:
        code = data[raw:raw + rsize]
        for m in re.finditer(rb'\xff\x15', code):
            i = m.start(); disp, = struct.unpack_from('<i', code, i + 2); target = va + i + 6 + disp
            if target in slots: calls.append((va + i, slots[target]))
    # A helper: a short function whose body calls a keyboard import; its start is found by walking back to padding.
    for rva, fn in calls:
        for va, raw, rsize in text:
            if va <= rva < va + rsize:
                o = rva - va; start = o
                while start > 0 and o - start < 64 and data[raw + start - 1] not in (0xcc, 0xc3): start -= 1
                helpers.add(va + start)
    found = {}
    for va, raw, rsize in text:
        code = data[raw:raw + rsize]
        for m in re.finditer(rb'\xb9(.)\x00\x00\x00', code, re.S):
            v = m.group(1)[0]
            if not 1 <= v <= 254: continue
            window = code[m.end():m.end() + 16]
            for j in range(len(window) - 5):
                if window[j:j + 2] == b'\xff\x15':
                    disp, = struct.unpack_from('<i', window, j + 2); target = va + m.end() + j + 6 + disp
                    if target in slots: found.setdefault(v, set()).add(slots[target]); break
                if window[j] == 0xe8:
                    rel, = struct.unpack_from('<i', window, j + 1); target = va + m.end() + j + 5 + rel
                    if target in helpers: found.setdefault(v, set()).add('helper'); break
    return imports, found

def ini_keys(folder):
    out = []
    for ini in sorted(Path(folder).rglob('*.ini')):
        for line in ini.read_text(errors='replace').splitlines():
            m = re.match(r'\s*([A-Za-z_][\w ]*?)\s*=\s*(\d+)\s*(?:(?://|;)\s*(.*))?$', line)
            if not m or not re.search(r'key|button|hotkey|bind', m.group(1), re.I): continue
            value = int(m.group(2)); comment = (m.group(3) or '').strip()
            kind = 'pad' if re.search(r'button|controller|pad', m.group(1), re.I) and value >= 180 else 'key'
            out.append((ini.name, m.group(1).strip(), value, kind, comment))
    return out

if __name__ == '__main__':
    asi = sys.argv[1]; folder = sys.argv[2] if len(sys.argv) > 2 else str(Path(asi).parent)
    imports, found = pe_keys(asi)
    print(f'{Path(asi).name}: imports {", ".join(imports) or "no keyboard functions"}')
    for v in sorted(found): print(f'  code: {key_name(v)} ({v}) via {", ".join(sorted(found[v]))}')
    for ini, name, value, kind, comment in ini_keys(folder):
        label = key_name(value) if kind == 'key' else f'controller {value}'
        print(f'  {ini}: {name} = {label}' + (f'  ({comment})' if comment else ''))
