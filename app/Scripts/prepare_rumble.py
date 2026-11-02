"""Controller rumble: hand the engine's pad actuator values to the host.

rage::ioPad::SetActuatorValue (f10523) gets both motor intensities for a pad
every frame from ioPadActuatorDevice::Update (actuator 0 the heavy
low-frequency motor, 1 the light one). The browser build had nowhere to send
them; the hook gives them to pg_pad_actuator, and the app reads pad 0's
values with PGReadRumble to drive the controller's haptics.
"""
from pathlib import Path
root=Path(__file__).resolve().parents[1]
p=root/'Generated/game_0.c'
s=p.read_text()
start=s.index('void w2c_game_f10523(w2c_game* instance, u64 var_p0, u32 var_p1, f32 var_p2) {')
end=s.index('\nvoid w2c_game_f',start+10)
f=s[start:end]
anchor='  f32 var_f1, var_f2, var_f3, var_f4;\n'
hook='  pg_pad_actuator(instance, var_p0, var_p1, var_p2);\n'
if hook not in f:
    if f.count(anchor)!=1 or '65535.0f' not in f or ', 66u)' not in f:raise RuntimeError('Pinned ioPad::SetActuatorValue changed')
    f=f.replace(anchor,anchor+hook)
    s=s[:start]+f+s[end:]
include='#include "game-rumble-impl.h"\n'
if include not in s:
    first=s.index('#include "game-')
    s=s[:s.index('\n',first)+1]+include+s[s.index('\n',first)+1:]
# game_0.c already has game-impl.h through game-virtual-pad-impl.h (it has no include guard).
(root/'Generated/game-rumble-impl.h').write_text('extern void pg_pad_actuator(w2c_game *instance, uint64_t pad, uint32_t actuator, float value);\n')
if p.read_text()!=s:p.write_text(s)
