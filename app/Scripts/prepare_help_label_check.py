"""A help with no text is never "being displayed" (GTA-190: the Atomic Blimp and Interaction Menu helps came back forever).

Scripts/prepare_missing_text.py (GTA-99) gives labels the game files don't have empty text instead of "<LABEL>
missing". END_TEXT_COMMAND_IS_THIS_HELP_MESSAGE_BEING_DISPLAYED (CScriptTextConstruction::
EndIsThisHelpMessageBeingDisplayed) formats the label and compares it with the help on screen, so for a missing label
it compared "" with "" whenever no help was up and answered yes. main asks that about HELP_DCK (the duck help of a later
update, missing here) and, when the answer turns from yes to no, clears flow help's "help shown now" label: so every
flow help lost that label the moment it appeared. ambientBlimp and main wait to see their help there before they mark
it seen; they never did, and queued "The Blimp has now been unlocked..." and "The Interaction Menu is now available..."
again and again (simulator: player save from log 2496, the label at Global 121124 read "\\0LIMP_UNLOCK" while its help
showed).

Now a label whose text is empty answers no (pg_help_label_empty in Source/EngineHost.c), as "<LABEL> missing" never
matched an empty help on PC.
"""
from pathlib import Path
from engine_names import fn
import re
root = Path(__file__).resolve().parents[1]
NAME = 'CScriptTextConstruction::EndIsThisHelpMessageBeingDisplayed(int)'
DECLARATION = 'extern u32 pg_help_label_empty(u64);\n'
MARK = '/* GTA-190: empty help text */'

number = fn(NAME)
head = re.compile(r'^u32 w2c_game_f%d\(w2c_game\* instance, u32 var_p0\) \{$' % number, re.M)
for path in sorted((root / 'Generated').glob('game_*.c')):
    s = path.read_text()
    found = head.search(s)
    if not found: continue
    end = s.index('\n}\n', found.start())
    body = s[found.start():end]
    if MARK in body: print(f'help label check: f{number} already patched'); break
    # The label's text is formatted into the frame's 1200-byte buffer (var_l2), then compared with the help shown.
    compare = ('    var_j1 = w2c_game_f%d(instance, var_i1);\n'
               '    var_i0 = w2c_game_f%d(instance, var_j0, var_j1);\n'
               '    var_l1 = var_i0;\n') % (fn('CHelpMessage::GetMessageText(int)'), fn('strcmp'))
    if body.count(compare) != 1 or 'var_j0 = var_l2;\n    var_i1 = var_p0;\n' + compare not in body:
        raise RuntimeError(f'Pinned f{number} ({NAME}) changed')
    body = body.replace(compare, compare + f'    if (pg_help_label_empty(var_l2)) var_l1 = 1u;  {MARK}\n', 1)
    s = s[:found.start()] + body + s[end:]
    if DECLARATION not in s:
        header = re.search(r'^#include "game-[\w-]*impl\.h"\n', s, re.M)
        if not header: raise RuntimeError(f'{path.name}: no engine header include')
        s = s[:header.end()] + DECLARATION + s[header.end():]
    path.write_text(s)
    print(f'help label check: patched f{number} in {path.name}')
    break
else:
    raise RuntimeError(f'Pinned function f{number} ({NAME}) not found')
