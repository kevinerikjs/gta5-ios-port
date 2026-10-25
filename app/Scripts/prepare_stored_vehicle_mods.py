"""A garage car restored from a save keeps only the mod parts its kit has here (GTA-52; see Source/StoredVehicleMods.c).

CVehicle::SetVariationInstance(CStoredVehicleVariations const&) gives a safehouse garage car back its kit (the store to
+1012) and then each slot's saved part (SetModIndex for slots 0-41, then the wheels, 48 and 49). Saved part indices that
are past the end of the kit's lists made SetModIndex trap: a PC save's Zentorno stopped the engine every time it loaded
near Michael's garage (logs 1824, 1832). pg_stored_vehicle_kit sees the kit first (one of the model's kits, or none)
and pg_stored_vehicle_mod each part (one the kit has, or the stock part, 255).
"""
from pathlib import Path
from engine_names import fn
import re
root = Path(__file__).resolve().parents[1]
FUNCTION = fn('CVehicle::SetVariationInstance(CStoredVehicleVariations const&)')
SET_MOD = fn('CVehicleVariationInstance::SetModIndex(eVehicleModType, unsigned char, CVehicle*, bool, unsigned int)')
HEAD = f'void w2c_game_f{FUNCTION}(w2c_game* instance, u64 var_p0, u64 var_p1) {{'
# The kit store: var_i1 is the saved kit (or none in a network game), var_j0 the variation base (+64 is the instance).
KIT = re.compile(r'(?P<i>[ ]+)(?P<store>i32_store16\w*\([^;\n]*checked_add_u64\(var_j0, 1012u\), var_i1\);)\n')
# Each SetModIndex call: var_j0 the variation instance, var_i1 the slot, var_i2 the saved part.
CALL = f'  w2c_game_f{SET_MOD}(instance, var_j0, var_i1, var_i2, var_j3, var_i4, var_i5);\n'
DECLARATIONS = ('extern u32 pg_stored_vehicle_kit(w2c_game *instance, u64 vehicle, u32 kit);\n'
                'extern u32 pg_stored_vehicle_mod(w2c_game *instance, u64 variation, u32 slot, u32 index, u64 vehicle);\n')

for path in sorted((root / 'Generated').glob('game_*.c')):
    s = path.read_text()
    if HEAD not in s: continue
    start = s.index(HEAD); end = s.index('\n}\n', start); body = s[start:end]
    if 'pg_stored_vehicle_kit(' in body: print(f'stored vehicle mods: f{FUNCTION} already patched'); break
    calls = re.findall(r'^[ ]+' + re.escape(CALL.strip()) + r'\n', body, re.M)
    if len(KIT.findall(body)) != 1 or len(calls) != 3:
        raise RuntimeError(f'Pinned f{FUNCTION} (CVehicle::SetVariationInstance) changed')
    body = KIT.sub(lambda k: f'{k["i"]}var_i1 = pg_stored_vehicle_kit(instance, var_p0, var_i1);\n{k["i"]}{k["store"]}\n', body, 1)
    body = re.sub(r'^(?P<i>[ ]+)(?P<call>' + re.escape(CALL.strip()) + r')\n',
                  lambda c: f'{c["i"]}var_i2 = pg_stored_vehicle_mod(instance, var_j0, var_i1, var_i2, var_p0);\n{c["i"]}{c["call"]}\n', body, flags=re.M)
    s = s[:start] + body + s[end:]
    first = re.search(r'^#include "game-[\w-]*impl\.h"\n', s, re.M)
    if not first: raise RuntimeError(f'{path.name}: no engine header include')
    s = s[:first.end()] + DECLARATIONS + s[first.end():]
    path.write_text(s)
    print(f'stored vehicle mods: patched f{FUNCTION} in {path.name}')
    break
else:
    raise RuntimeError(f'Pinned function f{FUNCTION} (CVehicle::SetVariationInstance) not found')
