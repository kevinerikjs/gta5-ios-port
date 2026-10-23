"""A script fault stops that script, not the game (GTA-158: the Jewel Store prep stopped the game).

These game files are a BankRelease build: when a script faults (an array index out of range, a stack overflow, an
unknown native...), the interpreter logs "FAULT: ...", then Quitf("Script fault (usually an array overrun ...)") ends
the program, and the port's engine stops with "Unreachable instruction executed". Log 1747: jewelry_prep1A,
"Array overrun, 4294967295 >= 5" in _SECURITY_AI_STATE, then the game stopped. A retail build only ends the script.

In the interpreter, rage::scrThread::Run (f16953, which an earlier patch may have renamed to
pg_script_run_original_f16953), every Quitf of that message is followed by the thread state becoming 2 (aborted) and
a return. The Quitf calls now go to pg_script_fault, which logs the fault and returns, so the faulting script ends
there and the game goes on.
"""
from pathlib import Path
from engine_names import fn
import re
root = Path(__file__).resolve().parents[1]
NUMBER = fn('rage::scrThread::Run(int)')
QUITF = fn('Quitf(char const*, ...)')
SITE = re.compile(r"(var_j0 = 3464332ull;\n\s*var_j1 = 0ull;\n\s*)w2c_game_f" + str(QUITF) + r"\(instance, var_j0, var_j1\);\n")
DECLARATION = 'extern void pg_script_fault(w2c_game *instance);'

head_re = re.compile(r'^(?:static )?u32 (?:w2c_game|pg_script_run_original)_f' + str(NUMBER) + r'\(w2c_game\* instance[^{]*\{$', re.M)
path = next(p for p in sorted((root / 'Generated').glob('game_*.c')) if head_re.search(p.read_text()))
s = path.read_text()
start = head_re.search(s).start(); end = s.index('\n}\n', start) + 3
body = s[start:end]
if 'pg_script_fault(instance)' in body:
    print('script fault abort: already patched'); raise SystemExit
sites = len(SITE.findall(body))
if sites != 26: raise RuntimeError(f'Pinned f{NUMBER} (script fault Quitf sites) changed: {sites} instead of 26')
body = SITE.sub(lambda m: m.group(1) + 'pg_script_fault(instance);   /* GTA-158: the script ends, the game goes on */\n', body)
s = s[:start] + body + s[end:]
if DECLARATION not in s:
    first = re.search(r'^#include "game-[a-z-]*impl\.h"$', s, re.M)
    s = s[:first.end()] + '\n' + DECLARATION + s[first.end():]
path.write_text(s)
print(f'script fault abort: patched {sites} sites in f{NUMBER} ({path.name})')
