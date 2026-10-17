// Engine-free checks of the production menu bridge against a simulated model registry.
// clang -std=c11 -fsanitize=address,undefined app/Tests/vehicle_spawn.c -o /tmp/vehicle-spawn && /tmp/vehicle-spawn
#include "../Source/EngineHost.h"
#include <assert.h>
#include <math.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
typedef uint32_t u32;
typedef uint64_t u64;
typedef float f32;
typedef struct { u64 w2c_g1, w2c_g0; } w2c_game;
static int env;
static unsigned char memory[16000000];
static double now = 1;
static u32 gameStatus, category, seats = 2;
static bool paused, loaded, hasScript = true;
static int requests, releases, creations, entered, grounded, deleted;
static u32 playerVehicle, nextVehicle = 123;
static bool existing[2048], owned[2048], occupied[2048], failCreate, failDelete, reenter;
static int liveVehicles, peakVehicles;
static int occupiedSeat[2048];
static u64 handler = 42, headroom = 1024ull << 20;
static bool nativeProcessHeadroom(uint64_t *room) { *room = headroom; return true; }
static uint64_t guardReserve(void) { return 384ull << 20; }
static int loadSeconds;
static float spawned[3];
static void *pg_pointer(void *host, u64 address, u64 size) {
  assert(address + size <= sizeof memory); return memory + address;
}
static const char *pg_string(void *host, u64 address) { return (const char *)memory + address; }
static void pg_log(const char *line) { (void)line; }
static double timeMS(clockid_t clock) { return now; }
u32 PGGameStatus(void) { return gameStatus; }
bool PGPauseMenuActive(void) { return paused; }
int PGLoadSceneSeconds(void) { return loadSeconds; }
static u64 pg_enter_main_script(w2c_game *instance) {
  u64 *active = pg_pointer(&env, instance->w2c_g1 + 3088, 8), old = *active;
  *active = hasScript ? 42 : 0; return old;
}
static void pg_leave_main_script(w2c_game *instance, u64 old) {
  *(u64 *)pg_pointer(&env, instance->w2c_g1 + 3088, 8) = old;
}
static u32 playerID = 3, playerPed = 7, maxWanted = 5, wanted;
static bool invincible[32];
static int invincibleWrites, wantedClears;
u32 PG_FN_PLAYER_PED_ID(w2c_game *instance) { return playerPed; }
u32 PG_FN_PLAYER_ID(w2c_game *instance) { return playerID; }
void PG_FN_SET_PLAYER_INVINCIBLE(w2c_game *instance, u32 player, u32 enabled) {
  assert(player == playerID && player < 32 && !paused && !gameStatus && !loadSeconds);
  invincible[player] = enabled; invincibleWrites++;
}
u32 PG_FN_GET_PLAYER_INVINCIBLE(w2c_game *instance, u32 player) { assert(player < 32); return invincible[player]; }
void PG_FN_CLEAR_WANTED(w2c_game *instance, u32 player) { assert(player == playerID); wanted = 0; wantedClears++; }
u32 PG_FN_GET_WANTED(w2c_game *instance, u32 player) { assert(player == playerID); return wanted; }
void PG_FN_SET_MAX_WANTED(w2c_game *instance, u32 value) { maxWanted = value; }
u32 PG_FN_GET_MAX_WANTED(w2c_game *instance) { return maxWanted; }
#include "../Source/NativeCheats.inc"
#include "../Source/NativeVehicleSpawn.inc"
static int repaired, cleaned, clockSet = -1, weatherCleared, overridesCleared;
static char weather[32];
u32 PG_FN_PED_VEHICLE(w2c_game *instance, u32 ped, u32 last) { assert(!last); return playerVehicle; }
void PG_FN_VEHICLE_ENGINE_HEALTH(w2c_game *instance, u32 vehicle, f32 value) { assert(vehicle == playerVehicle && value == 1000); }
void PG_FN_REPAIR_VEHICLE(w2c_game *instance, u32 vehicle) { assert(vehicle == playerVehicle); repaired++; }
void PG_FN_VEHICLE_DIRT(w2c_game *instance, u32 vehicle, f32 value) { assert(vehicle == playerVehicle && value == 0); cleaned++; }
void PG_FN_SET_CLOCK(w2c_game *instance, u32 hour, u32 minute, u32 second) { assert(!minute && !second); clockSet = hour; }
void PG_FN_SET_WEATHER(w2c_game *instance, u64 name) { assert(name == instance->w2c_g0); snprintf(weather, sizeof weather, "%s", pg_string(&env, name)); }
void PG_FN_CLEAR_WEATHER(w2c_game *instance) { weatherCleared++; }
void PG_FN_CLEAR_WEATHER_OVERRIDE(w2c_game *instance) { overridesCleared++; }

u64 PG_FN_MODEL_INFO_AT_INDEX(w2c_game *instance, u32 index) {
  // A car, a duplicate, a non-vehicle, a hole, and a DLC vehicle on a later page.
  if (index == 0 || index == 1) return 8192;
  if (index == 2) return 9000;
  if (index == 599) return 10000;
  return 0;
}
u32 PG_FN_IS_VEHICLE_MODEL(w2c_game *instance, u32 model) { return model == 100 || model == 200; }
u64 PG_FN_HASH_STRING_TRY_GET(w2c_game *instance, u32 space, u32 model) { return model == 100 ? 11000 : 0; }
u32 PG_FN_VEHICLE_CLASS(w2c_game *instance, u32 model) { return category; }
u64 PG_FN_VEHICLE_LABEL(w2c_game *instance, u32 model) { return 11100; }
u32 PG_FN_VEHICLE_SEATS(w2c_game *instance, u32 model) { return seats; }
void PG_FN_REQUEST_MODEL(w2c_game *instance, u32 model) { requests++; }
void PG_FN_RELEASE_MODEL(w2c_game *instance, u32 model) { releases++; }
u32 PG_FN_HAS_MODEL_LOADED(w2c_game *instance, u32 model) { return loaded; }
void PG_FN_GET_ENTITY_COORDS(w2c_game *instance, u64 vector, u32 ped, u32 alive) {
  float *v = pg_pointer(&env, vector, 24); v[0] = 10; v[2] = 20; v[4] = 30;
}
f32 PG_FN_GET_ENTITY_HEADING(w2c_game *instance, u32 ped) { return 90; }
u32 PG_FN_CREATE_VEHICLE(w2c_game *instance, u32 model, u64 vector, f32 heading, u32 network, u32 script, u32 flag) {
  assert(loaded && !paused && gameStatus == 0);
  float *v = pg_pointer(&env, vector, 24);
  for (int i = 0; i < 3; i++) spawned[i] = v[i * 2];
  assert(instance->w2c_g0 == 4096 - 32);
  if (reenter) pg_vehicle_menu_tick(instance);
  creations++;
  if (failCreate) return 0;
  u32 vehicle = nextVehicle++;
  assert(vehicle < 2048);
  existing[vehicle] = owned[vehicle] = true;
  liveVehicles++;
  if (liveVehicles > peakVehicles) peakVehicles = liveVehicles;
  return vehicle;
}
void PG_FN_SET_PED_INTO_VEHICLE(w2c_game *instance, u32 ped, u32 vehicle, u32 seat) {
  assert(seat == (u32)-1);
  occupied[playerVehicle] = false; occupied[vehicle] = true; occupiedSeat[vehicle] = -1; playerVehicle = vehicle; entered++;
}
u32 PG_FN_GROUND_VEHICLE(w2c_game *instance, u32 vehicle, f32 height) { grounded++; return 1; }
u32 PG_FN_ENTITY_EXISTS(w2c_game *instance, u32 vehicle) { return existing[vehicle]; }
u32 PG_FN_ENTITY_OWNED(w2c_game *instance, u32 vehicle, u32 unused) { return owned[vehicle]; }
u32 PG_FN_VEHICLE_OCCUPANT(w2c_game *instance, u32 vehicle, u32 seat, u32 includeEntering) {
  assert(includeEntering == 1);
  return occupied[vehicle] && seat == (u32)occupiedSeat[vehicle];
}
u64 PG_FN_CURRENT_SCRIPT_HANDLER(w2c_game *instance) { return handler; }
void PG_FN_DELETE_VEHICLE(w2c_game *instance, u64 pointer) {
  u32 vehicle = *(u32 *)pg_pointer(&env, pointer, 4);
  assert(existing[vehicle] && owned[vehicle] && !occupied[vehicle] && playerVehicle != vehicle);
  if (!failDelete) { existing[vehicle] = false; liveVehicles--; deleted++; }
  *(u32 *)pg_pointer(&env, pointer, 4) = 0;
}
static void tick(w2c_game *instance) {
  *(u64 *)pg_pointer(&env, instance->w2c_g1 + 3088, 8) = 999;
  pg_script_menu_tick(instance, 1024);
  assert(*(u64 *)pg_pointer(&env, instance->w2c_g1 + 3088, 8) == 999);
  assert(instance->w2c_g0 == 4096);
  now += 16;
}
int main(void) {
  w2c_game instance = {.w2c_g0 = 4096};
  strcpy((char *)memory + 1024 + 428, "main");
  *(u32 *)pg_pointer(&env, 10872120, 4) = 600;
  memory[8192 + 157] = memory[10000 + 157] = 5;
  *(u32 *)pg_pointer(&env, 8192 + 24, 4) = 100;
  *(u32 *)pg_pointer(&env, 10000 + 24, 4) = 200;
  strcpy((char *)memory + 11000, "testcar"); strcpy((char *)memory + 11100, "TEST_CAR");
  PGRequestVehicleCatalog(); gameStatus = 16; tick(&instance);
  assert(PGVehicleCatalogCount() == -1);
  gameStatus = 0; tick(&instance); assert(PGVehicleCatalogCount() == -1);
  tick(&instance); assert(PGVehicleCatalogCount() == 2);
  PGVehicleEntry entry;
  assert(PGVehicleCatalogEntryAt(0, &entry) && !strcmp(entry.name, "testcar"));
  assert(PGVehicleCatalogEntryAt(1, &entry) && entry.model == 200 && !strcmp(entry.name, "0x000000C8"));
  assert(!PGVehicleCatalogEntryAt(2, &entry) && !PGVehicleCatalogEntryAt(0, NULL));
  assert(!requests); // Listing never loads models.

  paused = true; assert(PGSpawnVehicle(100, true)); assert(!PGSpawnVehicle(200, true));
  tick(&instance); assert(!requests && !creations);
  paused = false; tick(&instance); assert(requests == 1 && PGGetVehicleSpawnStatus() == PGVehicleSpawnLoading);
  tick(&instance); assert(requests == 1 && !creations);
  loaded = true; tick(&instance);
  assert(PGGetVehicleSpawnStatus() == PGVehicleSpawnSucceeded && entered == 1 && releases == 1 && liveVehicles == 1);
  assert(fabsf(spawned[0] - 2) < 0.001f && fabsf(spawned[1] - 20) < 0.001f && spawned[2] == 30.5f);

  assert(PGSpawnVehicle(999, false)); tick(&instance);
  assert(PGGetVehicleSpawnStatus() == PGVehicleSpawnUnavailable && creations == 1 && requests == 1);
  loaded = false; assert(PGSpawnVehicle(100, false)); tick(&instance); now += 31000; tick(&instance);
  assert(PGGetVehicleSpawnStatus() == PGVehicleSpawnTimedOut && releases == 2 && creations == 1);
  assert(PGSpawnVehicle(100, false)); tick(&instance); gameStatus = 4; tick(&instance);
  assert(PGGetVehicleSpawnStatus() == PGVehicleSpawnNotReady && releases == 3);
  assert(PGSpawnVehicle(100, false)); tick(&instance); now += 11000; tick(&instance);
  assert(PGGetVehicleSpawnStatus() == PGVehicleSpawnNotReady && requests == 3);
  gameStatus = 0; hasScript = false; assert(PGSpawnVehicle(100, false)); tick(&instance);
  assert(PGGetVehicleSpawnStatus() == PGVehicleSpawnNotReady && requests == 3);

  hasScript = loaded = true; category = 14; assert(PGSpawnVehicle(200, false)); tick(&instance);
  assert(PGGetVehicleSpawnStatus() == PGVehicleSpawnSucceeded && grounded == 1 && entered == 1);
  category = 16; seats = 0; assert(PGSpawnVehicle(200, true)); tick(&instance);
  assert(fabsf(spawned[0] + 10) < 0.001f && entered == 1);
  failCreate = true; assert(PGSpawnVehicle(100, false)); tick(&instance);
  assert(PGGetVehicleSpawnStatus() == PGVehicleSpawnFailed && releases == 6 && liveVehicles <= 2);
  assert(!PGSpawnVehicle(0, true));

  // Third spawn and sustained replacement must not accumulate model requests or
  // live vehicles. The player can repeatedly jump from one spawn to the next.
  failCreate = false; seats = 2; category = 0; reenter = true;
  for (int i = 0; i < 100; i++) {
    assert(PGSpawnVehicle(i % 2 ? 100 : 200, true)); tick(&instance);
    assert(PGGetVehicleSpawnStatus() == PGVehicleSpawnSucceeded);
    assert(liveVehicles == 2 && peakVehicles == 2 && requests == releases);
    assert(occupied[playerVehicle]);
  }
  assert(deleted >= 100);
  reenter = false;
  u32 protectedVehicle = playerVehicle;
  for (int i = 0; i < 100; i++) {
    assert(PGSpawnVehicle(i % 2 ? 100 : 200, false)); tick(&instance);
    assert(PGGetVehicleSpawnStatus() == PGVehicleSpawnSucceeded);
    assert(liveVehicles == 2 && peakVehicles == 2 && requests == releases);
    assert(playerVehicle == protectedVehicle && existing[protectedVehicle]);
  }

  // The player exits; NPCs occupy both menu vehicles.
  playerVehicle = 0;
  // No deletion of either an occupied vehicle or one a mission has claimed.
  occupied[menuVehicles[0]] = occupied[menuVehicles[1]] = true;
  occupiedSeat[menuVehicles[0]] = 14; // Last passenger slot, including an entering ped.
  int before = requests;
  assert(PGSpawnVehicle(100, false)); tick(&instance);
  assert(PGGetVehicleSpawnStatus() == PGVehicleSpawnVehicleLimit && requests == before);
  occupied[menuVehicles[0]] = false;
  failDelete = true;
  assert(PGSpawnVehicle(100, false)); tick(&instance);
  assert(PGGetVehicleSpawnStatus() == PGVehicleSpawnVehicleLimit && requests == before);
  failDelete = false;
  u32 claimed = menuVehicles[0]; owned[claimed] = false;
  int oldDeleted = deleted;
  assert(PGSpawnVehicle(100, false)); tick(&instance);
  assert(PGGetVehicleSpawnStatus() == PGVehicleSpawnSucceeded);
  assert(existing[claimed] && deleted == oldDeleted);
  // Mission ownership is outside the menu cap; simulate its later cleanup.
  existing[claimed] = false; liveVehicles--;

  // Memory pressure before requesting assets, and after loading has started.
  headroom = 100ull << 20; before = requests;
  assert(PGSpawnVehicle(100, false)); tick(&instance);
  assert(PGGetVehicleSpawnStatus() == PGVehicleSpawnLowMemory && requests == before);
  headroom = 1024ull << 20; loaded = false;
  assert(PGSpawnVehicle(100, false)); tick(&instance);
  assert(PGGetVehicleSpawnStatus() == PGVehicleSpawnLoading);
  headroom = 100ull << 20; tick(&instance);
  assert(PGGetVehicleSpawnStatus() == PGVehicleSpawnLowMemory && requests == releases);
  headroom = 1024ull << 20;

  // A live main thread without a handler is not safe for REQUEST_MODEL.
  handler = 0; before = requests;
  assert(PGSpawnVehicle(100, false)); tick(&instance);
  assert(PGGetVehicleSpawnStatus() == PGVehicleSpawnNotReady && requests == before);
  handler = 42;
  assert(PGSpawnVehicle(100, false)); tick(&instance);
  int oldReleases = releases;
  handler = 43; tick(&instance);
  assert(PGGetVehicleSpawnStatus() == PGVehicleSpawnNotReady && releases == oldReleases);
  // Original handler teardown releases the old request; never use the new one.
  releases++;
  memset(existing, 0, sizeof existing); memset(occupied, 0, sizeof occupied);
  liveVehicles = 0; playerVehicle = 0; loaded = true;
  assert(PGSpawnVehicle(100, true)); tick(&instance);
  assert(PGGetVehicleSpawnStatus() == PGVehicleSpawnSucceeded && liveVehicles == 1);
  assert(requests == releases);
  // Only the main script's update may consume menu requests.
  before = requests;
  assert(PGSpawnVehicle(100, false));
  strcpy((char *)memory + 2048 + 428, "mission");
  pg_script_menu_tick(&instance, 2048);
  assert(requests == before && PGGetVehicleSpawnStatus() == PGVehicleSpawnWaiting);
  memory[1024 + 614] = 1;
  tick(&instance); assert(requests == before);
  memory[1024 + 614] = 0;
  tick(&instance); assert(PGGetVehicleSpawnStatus() == PGVehicleSpawnSucceeded);

  assert(!PGQueueCheat(PGCheatSetTime, 24));
  assert(!PGQueueCheat(PGCheatSetWeather, -1));
  assert(!PGQueueCheat(PGCheatSetWeather, 7));
  assert(!PGQueueCheat((PGCheatCommand)99, 0));
  assert(PGQueueCheat(PGCheatRepairVehicle, 0));
  assert(!PGQueueCheat(PGCheatCleanVehicle, 0));
  paused = true; tick(&instance); assert(!repaired && PGGetCheatStatus() == PGCheatWaiting);
  paused = false; tick(&instance);
  assert(PGGetCheatStatus() == PGCheatSucceeded && repaired == 1 && cleaned == 1);
  assert(PGQueueCheat(PGCheatCleanVehicle, 0)); tick(&instance);
  assert(repaired == 1 && cleaned == 2);
  playerVehicle = 0;
  assert(PGQueueCheat(PGCheatRepairVehicle, 0)); tick(&instance);
  assert(PGGetCheatStatus() == PGCheatNoVehicle && repaired == 1);
  assert(PGQueueCheat(PGCheatSetTime, 18)); tick(&instance); assert(clockSet == 18);
  for (int i = 0; i < 7; i++) {
    assert(PGQueueCheat(PGCheatSetWeather, i)); tick(&instance);
    assert(!strcmp(weather, menuWeather[i]));
  }
  assert(PGQueueCheat(PGCheatNaturalWeather, 0)); tick(&instance);
  assert(overridesCleared == 8 && weatherCleared == 1);
  assert(PGQueueCheat(PGCheatSetTime, 0));
  gameStatus = 4; tick(&instance); now += 11000; tick(&instance);
  assert(PGGetCheatStatus() == PGCheatNotReady && clockSet == 18);
  gameStatus = 0;
  before = requests;
  assert(PGSpawnVehicle(100, false));
  assert(PGQueueCheat(PGCheatSetTime, 12));
  // No script updates while paused: both old requests must expire even when
  // normal gameplay is ready again on the first subsequent tick.
  now += 11000; tick(&instance);
  assert(PGGetVehicleSpawnStatus() == PGVehicleSpawnNotReady && requests == before);
  assert(PGGetCheatStatus() == PGCheatNotReady && clockSet == 18);
  assert(!PGCheatEnabled(PGCheatGodMode) && !PGCheatEnabled(PGCheatNeverWanted));
  assert(!PGQueueCheat(PGCheatGodMode, 2) && !PGQueueCheat(PGCheatNeverWanted, -1));
  assert(PGQueueCheat(PGCheatGodMode, 1));
  paused = true; tick(&instance); assert(!PGCheatEnabled(PGCheatGodMode));
  paused = false; tick(&instance);
  assert(PGCheatEnabled(PGCheatGodMode) && invincible[playerID]);
  int oldWrites = invincibleWrites;
  for (int i = 0; i < 100; i++) tick(&instance);
  assert(invincibleWrites == oldWrites); // No repeated writes/log spam when already protected.
  invincible[playerID] = false; tick(&instance); assert(invincible[playerID]);
  playerID = 0; playerPed = 8; tick(&instance); assert(invincible[0]);
  invincible[0] = false; loadSeconds = 1; tick(&instance); assert(!invincible[0]);
  loadSeconds = 0; tick(&instance); assert(invincible[0]);
  assert(PGQueueCheat(PGCheatGodMode, 0)); tick(&instance);
  assert(!PGCheatEnabled(PGCheatGodMode) && !invincible[0]);
  oldWrites = invincibleWrites; tick(&instance); assert(invincibleWrites == oldWrites);

  wanted = 4;
  assert(PGQueueCheat(PGCheatNeverWanted, 1)); tick(&instance);
  assert(PGCheatEnabled(PGCheatNeverWanted) && !wanted && !maxWanted);
  int oldClears = wantedClears;
  for (int i = 0; i < 100; i++) tick(&instance);
  assert(wantedClears == oldClears);
  // Re-enabling must not replace the saved limit with our own zero.
  assert(PGQueueCheat(PGCheatNeverWanted, 1)); tick(&instance);
  assert(PGQueueCheat(PGCheatNeverWanted, 0)); tick(&instance); assert(maxWanted == 5);
  assert(PGQueueCheat(PGCheatNeverWanted, 1)); tick(&instance);
  maxWanted = 3; wanted = 2; tick(&instance); assert(!maxWanted && !wanted);
  assert(PGQueueCheat(PGCheatNeverWanted, 0)); tick(&instance);
  assert(!PGCheatEnabled(PGCheatNeverWanted) && maxWanted == 3);
  wanted = 2; tick(&instance); assert(wanted == 2);
  maxWanted = 0; // Sandbox/mission already disables wanted levels.
  assert(PGQueueCheat(PGCheatNeverWanted, 1)); tick(&instance);
  assert(PGQueueCheat(PGCheatNeverWanted, 0)); tick(&instance); assert(maxWanted == 0);
  playerPed = 0;
  assert(PGQueueCheat(PGCheatGodMode, 1)); tick(&instance);
  assert(PGGetCheatStatus() == PGCheatWaiting && !PGCheatEnabled(PGCheatGodMode));
  now += 11000; tick(&instance); assert(PGGetCheatStatus() == PGCheatNotReady);
  playerPed = 7; playerID = UINT32_MAX;
  assert(PGQueueCheat(PGCheatGodMode, 1)); tick(&instance);
  assert(PGGetCheatStatus() == PGCheatWaiting);
  playerID = 0; tick(&instance); assert(invincible[0]);
  assert(PGQueueCheat(PGCheatGodMode, 0)); tick(&instance);
  // Switches stay usable while Settings pauses the engine, and both choices
  // survive a long pause without occupying the single-action queue.
  assert(!PGSetPersistentCheatEnabled(PGCheatSetTime, true));
  maxWanted = 5; wanted = 3; paused = true;
  assert(PGSetPersistentCheatEnabled(PGCheatGodMode, true));
  assert(PGSetPersistentCheatEnabled(PGCheatNeverWanted, true));
  assert(PGCheatEnabled(PGCheatGodMode) && PGCheatEnabled(PGCheatNeverWanted));
  now += 60000; tick(&instance);
  assert(!invincible[playerID] && maxWanted == 5 && wanted == 3);
  assert(PGQueueCheat(PGCheatSetTime, 12));
  paused = false; tick(&instance);
  assert(invincible[playerID] && maxWanted == 0 && wanted == 0 && clockSet == 12);
  paused = true;
  PGSetPersistentCheatEnabled(PGCheatGodMode, false);
  PGSetPersistentCheatEnabled(PGCheatGodMode, true);
  PGSetPersistentCheatEnabled(PGCheatGodMode, false);
  PGSetPersistentCheatEnabled(PGCheatNeverWanted, false);
  assert(!PGCheatEnabled(PGCheatGodMode) && !PGCheatEnabled(PGCheatNeverWanted));
  tick(&instance); assert(invincible[playerID] && maxWanted == 0);
  paused = false; playerPed = 0; tick(&instance);
  assert(invincible[playerID] && maxWanted == 0);
  playerPed = 7; tick(&instance);
  assert(!invincible[playerID] && maxWanted == 5);
  oldWrites = invincibleWrites;
  PGSetPersistentCheatEnabled(PGCheatGodMode, true);
  PGSetPersistentCheatEnabled(PGCheatGodMode, false);
  tick(&instance); assert(invincibleWrites == oldWrites);

  free(vehicleCatalog);
  puts("VEHICLE SPAWN AND NATIVE CHEAT CHECKS PASSED");
}
