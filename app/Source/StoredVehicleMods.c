// Cars restored from a safehouse garage with mod parts this game doesn't have (GTA-52, Scripts/prepare_stored_vehicle_mods.py).
//
// A garage car's mods are saved as raw indices into its mod kit's part lists (CSaveGarages: the kit by its id, then the
// index of each slot's part). CVehicle::SetVariationInstance(CStoredVehicleVariations const&) gives them back to
// CVehicleVariationInstance::SetModIndex unchecked, and that traps on an index past the end of the kit's list. Saves
// from a game with more parts in a kit do that: a PC save's Zentorno in Michael's garage had 15 parts with indices up to
// 52, and the port's game files have 18 parts in that kit (players' logs 1824 and 1832, v1.4.4 and v1.4.6: the engine
// stopped every time the save loaded near the garage). A kit id that now names another model's kit (add-on vehicle
// packs give out kit ids in load order) does the same. The PC game reads past the list instead.
//
// pg_stored_vehicle_kit keeps the saved kit only when it is one of the vehicle model's kits, and pg_stored_vehicle_mod
// leaves out a part the kit doesn't have (index 255: the stock part); each part left out is logged.
#include "HostInternal.h"
#include <stdio.h>
#include <string.h>

enum { NO_KIT = 0xffff, STOCK = 255 };
// CVehicleModelInfoVarGlobal (pointer at 19660176): the kits at +88, their count (u16) at +96, 112 bytes each.
// A kit: id (u16) at +4, visible parts (slots 0-35) count at +24, stat parts (engine, brakes, gearbox, horn,
// suspension, armour: slots 36-41) count at +56; the counts SetModIndex checks (f38976).
static const uint8_t *kit_at(const uint8_t *m, uint64_t size, uint32_t kit) {
  uint64_t global = 0, kits = 0; uint16_t count = 0;
  memcpy(&global, m + 19660176, 8);
  if (!global || global + 98 > size) return NULL;
  memcpy(&kits, m + global + 88, 8); memcpy(&count, m + global + 96, 2);
  if (kit >= count || !kits || kits + 112ull * (kit + 1) > size) return NULL;
  return m + kits + 112ull * kit;
}
static uint32_t model_of(const uint8_t *m, uint64_t size, u64 vehicle, uint64_t *info) {
  uint32_t hash = 0; *info = 0;
  if (vehicle && vehicle + 40 <= size) memcpy(info, m + vehicle + 32, 8);
  if (*info && *info + 700 <= size) memcpy(&hash, m + *info + 24, 4); else *info = 0;
  return hash;
}
static void report(const char *line) {
  static int lines;
  if (lines++ < 40) pg_log(line);
}

// The kit SetVariationInstance is about to give the restored car: kept when it is one of the model's kits
// (CVehicleModelInfo: kit indices (u16) at +688, their count at +696), otherwise none.
u32 pg_stored_vehicle_kit(w2c_game *instance, u64 vehicle, u32 kit) {
  if ((kit & 0xffff) == NO_KIT) return kit;
  const uint8_t *m = instance->w2c_env_memory->data; const uint64_t size = instance->w2c_env_memory->size;
  uint64_t info, list = 0; uint16_t count = 0;
  const uint32_t model = model_of(m, size, vehicle, &info);
  if (info) { memcpy(&list, m + info + 688, 8); memcpy(&count, m + info + 696, 2); }
  for (uint16_t i = 0; list && i < count && list + 2ull * (i + 1) <= size; i++) {
    uint16_t own; memcpy(&own, m + list + 2ull * i, 2);
    if (own == (kit & 0xffff)) return kit;
  }
  const uint8_t *k = kit_at(m, size, kit & 0xffff); uint16_t id = 0;
  if (k) memcpy(&id, k + 4, 2);
  char line[220];
  snprintf(line, sizeof line, "Garage: a stored car (model 0x%08x) came with mod kit %u (id %u), which isn't one of that model's %u kits; it is restored without mods.",
           model, kit & 0xffff, id, count);
  report(line);
  return NO_KIT;
}

// The part SetVariationInstance is about to put in a slot: kept when the kit has it, otherwise the stock part.
u32 pg_stored_vehicle_mod(w2c_game *instance, u64 variation, u32 slot, u32 index, u64 vehicle) {
  if ((index & 0xff) == STOCK || slot > 41) return index;   // wheels (48, 49): SetModIndex checks those itself
  const uint8_t *m = instance->w2c_env_memory->data; const uint64_t size = instance->w2c_env_memory->size;
  uint16_t kit = NO_KIT;
  if (variation + 950 <= size) memcpy(&kit, m + variation + 948, 2);
  const uint8_t *k = kit_at(m, size, kit);
  if (!k) return index;   // no kit: SetModIndex leaves the slot alone
  uint16_t parts; memcpy(&parts, k + (slot <= 35 ? 24 : 56), 2);
  if ((index & 0xff) < parts) return index;
  uint64_t info; uint16_t id; memcpy(&id, k + 4, 2);
  char line[220];
  snprintf(line, sizeof line, "Garage: a stored car (model 0x%08x) has mod part %u in slot %u, but its kit (id %u) has %u %s parts here; restored with the stock part.",
           model_of(m, size, vehicle, &info), index & 0xff, slot, id, parts, slot <= 35 ? "body" : "performance");
  report(line);
  return STOCK;
}
