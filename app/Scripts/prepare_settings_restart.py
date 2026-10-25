"""Pause menu "Restart now?" no longer freezes the game (GTA-166).

Settings › Graphics in the game's own pause menu asks "Restart now? A restart is required for these changes
to take effect" when texture, shader, particle or grass quality, the DirectX version, stereo 3D or the
fullscreen adapter changed (CSettingsMenu::ApplyGfxSettings). "Yes" saved settings.xml and set the restart
flag; CApp::CheckExit then ran the network exit flow and the browser build's restart (an embedded JS call
the port doesn't have) and exit(0), which the port can't do: the game froze there.

"Yes" now saves as before but leaves the restart flag alone. Source/EngineHost.c (pg_settings_restart)
logs the graphics the player chose that the app sets at launch ("Pause menu graphics for the next start:
textureQuality=2 ..."); the app keeps them in Settings › Graphics and says they apply the next time the game
starts. The menu then shows the graphics in use again, as "No" does. PG_TEST_SETTINGS_RESTART_OLD=1 keeps
the old answer in the simulator.
"""
from pathlib import Path
from engine_names import fn
import re
root = Path(__file__).resolve().parents[1]
NAME = 'CSettingsMenu::Update()'
NUMBER = fn(NAME)
WRITE = fn('CSettingsMenu::WriteGfxSettings()')
BACKOUT = fn('CPauseMenu::BackoutGraphicalChanges(bool, bool)')
# The "Yes" branch: WriteGfxSettings, then the restart flag (CApp::CheckExit reads it) = saved (+37 is 1 when
# the save failed).
FLAG = re.compile(
    r'(    w2c_game_f%d\(instance, var_j0\);\n)'
    r'    var_j0 = 19566058ull;\n'
    r'    var_j1 = var_p0;\n'
    r'(    var_i1 = i32_load8_u\w*\(.*?\(u64\)checked_add_u64\(var_j1, 37u\)\);\n)'
    r'    var_i2 = 1u;\n'
    r'    var_i1 \^= var_i2;\n'
    r'(    i32_store8\w*\(.*?\(u64\)\(var_j0\), var_i1\);\n)' % WRITE)
MARK = 'pg_settings_restart(instance, var_p0, var_i1)'
DECLARATION = 'extern u32 pg_settings_restart(w2c_game*, u64, u32);\n'

done = False
for path in sorted((root / 'Generated').glob('game_*.c')):
    s = path.read_text()
    found = re.search(r'^void w2c_game_f%d\(w2c_game\* instance, u64 var_p0\) \{$' % NUMBER, s, re.M)
    if not found: continue
    end = s.index('\n}\n', found.start())
    body = s[found.start():end]
    done = True
    if MARK in body: print(f'settings restart: f{NUMBER} already patched'); break
    matches = list(FLAG.finditer(body))
    if len(matches) != 1: raise RuntimeError(f'Pinned f{NUMBER} ({NAME}) changed')
    m = matches[0]
    replacement = (m.group(1) + '    var_j0 = 19566058ull;\n    var_j1 = var_p0;\n' + m.group(2) +
        '    var_i2 = 1u;\n    var_i1 ^= var_i2;\n'
        "    /* GTA-166: the port can't restart the game; the host keeps the choices for the next start. */\n"
        f'    if ({MARK}) {{\n  ' + m.group(3) + '    } else {\n'
        f'      var_i0 = 0u;\n      var_i1 = 1u;\n      w2c_game_f{BACKOUT}(instance, var_i0, var_i1);\n'
        # As "No" does: the menu shows the graphics in use again, and no "apply your changes?" follows.
        '      var_j0 = 19566063ull;\n      var_i1 = 0u;\n  ' + m.group(3) +
        '    }\n')
    s = s[:found.start()] + body[:m.start()] + replacement + body[m.end():] + s[end:]
    if DECLARATION not in s:
        header = re.search(r'^#include "game-[\w-]*impl\.h"\n', s, re.M)
        if not header: raise RuntimeError(f'{path.name}: no engine header include')
        s = s[:header.end()] + DECLARATION + s[header.end():]
    path.write_text(s)
    print(f'settings restart: f{NUMBER} patched')
    break
if not done: raise RuntimeError(f'Pinned function f{NUMBER} ({NAME}) not found')
