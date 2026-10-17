"""Run menu commands with the main script, never on the asynchronous pad worker.

GtaThread::Update is a virtual call in both the normal frame and session startup.
Hooking CTheScripts::Process alone misses the inlined copy in CApp::UpdateState.
The host filters for the main script and temporarily borrows its script context.
"""
from pathlib import Path
from engine_names import fn
import re


def patch(source, function):
    head = f'u32 w2c_game_f{function}(w2c_game* instance, u64 var_p0, u32 var_p1) {{'
    start = source.index(head)
    end = source.index('\n}\n', start)
    body = source[start:end]
    hook = '  pg_script_menu_tick(instance, var_p0);'
    if hook in body:
        return source
    if body.count('  FUNC_PROLOGUE;') != 1 or '614u' not in body or '428ull' not in body:
        raise RuntimeError('Pinned GtaThread::Update layout changed')
    body = body.replace('  FUNC_PROLOGUE;', '  FUNC_PROLOGUE;\n' + hook, 1)
    source = source[:start] + body + source[end:]
    include = re.search(r'^#include "game-[a-z-]*impl\.h"$', source, re.M)
    if not include:
        raise RuntimeError('Missing generated implementation header')
    declaration = '\nextern void pg_script_menu_tick(w2c_game *instance, u64 thread);'
    return source[:include.end()] + declaration + source[include.end():]


if __name__ == '__main__':
    root = Path(__file__).resolve().parents[1]
    function = fn('GtaThread::Update(int)')
    head = f'u32 w2c_game_f{function}(w2c_game* instance, u64 var_p0, u32 var_p1) {{'
    for path in sorted((root / 'Generated').glob('game_*.c')):
        source = path.read_text()
        if head not in source:
            continue
        updated = patch(source, function)
        if updated != source:
            path.write_text(updated)
        print(f'script menu: hooked GtaThread::Update in {path.name}')
        break
    else:
        raise RuntimeError('GtaThread::Update not found')
