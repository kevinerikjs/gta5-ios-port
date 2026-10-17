// Included by EngineHost.c. Entity operations run in the main script update phase.
// Layouts are pinned to 8b0b5899ed (prepare.py verifies the WASM SHA-256):
// GetModelInfoFromLocalIndex reads pool capacity at 10872120; archetypes store
// their name hash at +24 and type at +157. Vehicle archetypes have type 5.
u64 PG_FN_MODEL_INFO_AT_INDEX(w2c_game*, u32);
u32 PG_FN_IS_VEHICLE_MODEL(w2c_game*, u32);
u64 PG_FN_HASH_STRING_TRY_GET(w2c_game*, u32, u32);
u32 PG_FN_VEHICLE_CLASS(w2c_game*, u32);
u64 PG_FN_VEHICLE_LABEL(w2c_game*, u32);
u32 PG_FN_VEHICLE_SEATS(w2c_game*, u32);
void PG_FN_REQUEST_MODEL(w2c_game*, u32);
void PG_FN_RELEASE_MODEL(w2c_game*, u32);
u32 PG_FN_HAS_MODEL_LOADED(w2c_game*, u32);
void PG_FN_GET_ENTITY_COORDS(w2c_game*, u64, u32, u32);
f32 PG_FN_GET_ENTITY_HEADING(w2c_game*, u32);
u32 PG_FN_CREATE_VEHICLE(w2c_game*, u32, u64, f32, u32, u32, u32);
void PG_FN_SET_PED_INTO_VEHICLE(w2c_game*, u32, u32, u32);
u32 PG_FN_GROUND_VEHICLE(w2c_game*, u32, f32);
u32 PG_FN_ENTITY_EXISTS(w2c_game*, u32);
u32 PG_FN_ENTITY_OWNED(w2c_game*, u32, u32);
void PG_FN_DELETE_VEHICLE(w2c_game*, u64);
u32 PG_FN_VEHICLE_OCCUPANT(w2c_game*, u32, u32, u32);
u64 PG_FN_CURRENT_SCRIPT_HANDLER(w2c_game*);

// Keep ownership until explicitly retired. "No longer needed" alone leaves nearby
// vehicles (and their streamed assets) alive, so repeated spawns grow without bound.
static u32 menuVehicles[2];
static u64 menuVehicleOwner;
static bool pg_vehicle_make_room(w2c_game *instance, u64 scratch, u64 owner) {
  if (menuVehicleOwner != owner) {
    memset(menuVehicles, 0, sizeof menuVehicles);
    menuVehicleOwner = owner; // Old script teardown owns its old entities.
  }
  for (int i = 0; i < 2; i++) {
    u32 vehicle = menuVehicles[i];
    if (vehicle && (!PG_FN_ENTITY_EXISTS(instance, vehicle) || !PG_FN_ENTITY_OWNED(instance, vehicle, 0)))
      menuVehicles[i] = 0; // Never take an entity back from a mission.
  }
  if (!menuVehicles[0] || !menuVehicles[1]) return true;
  for (int i = 0; i < 2; i++) {
    bool occupied = false;
    // This build has 16 seat slots; include peds currently getting into a seat.
    for (int seat = -1; seat < 15; seat++)
      if (PG_FN_VEHICLE_OCCUPANT(instance, menuVehicles[i], (u32)seat, 1)) { occupied = true; break; }
    if (occupied) continue;
    u32 vehicle = menuVehicles[i];
    *(u32 *)pg_pointer(&env, scratch, 4) = vehicle;
    PG_FN_DELETE_VEHICLE(instance, scratch);
    // Delete clears its argument even on failure in this build. Check the GUID.
    if (PG_FN_ENTITY_EXISTS(instance, vehicle)) continue;
    menuVehicles[i] = 0;
    pg_log("Vehicle menu: retired an older empty menu vehicle before loading another.");
    return true;
  }
  return false;
}
static bool pg_vehicle_memory_available(void) {
  uint64_t headroom;
  return !nativeProcessHeadroom(&headroom) || headroom >= guardReserve();
}

static pthread_mutex_t vehicleMenuLock = PTHREAD_MUTEX_INITIALIZER;
static PGVehicleEntry *vehicleCatalog;
static int32_t vehicleCatalogCount = -1;
static bool vehicleCatalogRequested = true; // Warm the list before Settings pauses script updates.
static PGVehicleSpawnStatus vehicleSpawnStatus;
static uint32_t vehicleSpawnModel;
static bool vehicleSpawnEnter;
static double vehicleSpawnQueuedAt;

void PGRequestVehicleCatalog(void) {
  pthread_mutex_lock(&vehicleMenuLock);
  if (vehicleCatalogCount <= 0) { vehicleCatalogRequested = true; vehicleCatalogCount = -1; }
  pthread_mutex_unlock(&vehicleMenuLock);
}
int32_t PGVehicleCatalogCount(void) {
  pthread_mutex_lock(&vehicleMenuLock);
  int32_t count = vehicleCatalogCount;
  pthread_mutex_unlock(&vehicleMenuLock);
  return count;
}
bool PGVehicleCatalogEntryAt(uint32_t index, PGVehicleEntry *entry) {
  pthread_mutex_lock(&vehicleMenuLock);
  bool valid = entry && vehicleCatalogCount > 0 && index < (uint32_t)vehicleCatalogCount;
  if (valid) *entry = vehicleCatalog[index];
  pthread_mutex_unlock(&vehicleMenuLock);
  return valid;
}
bool PGSpawnVehicle(uint32_t model, bool enterVehicle) {
  pthread_mutex_lock(&vehicleMenuLock);
  bool accepted = model && vehicleSpawnStatus != PGVehicleSpawnWaiting && vehicleSpawnStatus != PGVehicleSpawnLoading;
  if (accepted) {
    vehicleSpawnModel = model; vehicleSpawnEnter = enterVehicle;
    vehicleSpawnQueuedAt = timeMS(CLOCK_MONOTONIC);
    vehicleSpawnStatus = PGVehicleSpawnWaiting;
  }
  pthread_mutex_unlock(&vehicleMenuLock);
  return accepted;
}
PGVehicleSpawnStatus PGGetVehicleSpawnStatus(void) {
  pthread_mutex_lock(&vehicleMenuLock);
  PGVehicleSpawnStatus status = vehicleSpawnStatus;
  pthread_mutex_unlock(&vehicleMenuLock);
  return status;
}
static void pg_vehicle_spawn_status(PGVehicleSpawnStatus status) {
  pthread_mutex_lock(&vehicleMenuLock);
  vehicleSpawnStatus = status;
  pthread_mutex_unlock(&vehicleMenuLock);
}
static void pg_vehicle_catalog_tick(w2c_game *instance) {
  static PGVehicleEntry *building;
  static uint32_t index, capacity, count;
  pthread_mutex_lock(&vehicleMenuLock);
  bool requested = vehicleCatalogRequested;
  pthread_mutex_unlock(&vehicleMenuLock);
  if (!requested || (PGGameStatus() & 16)) return;
  if (!building) {
    capacity = *(uint32_t *)pg_pointer(&env, 10872120, 4);
    if (!capacity) return;
    // Local model indices are uint16_t. Reject a changed/corrupt pool layout.
    if (capacity <= 65536) building = calloc(capacity, sizeof *building);
    if (!building) {
      pthread_mutex_lock(&vehicleMenuLock);
      vehicleCatalogCount = -2; vehicleCatalogRequested = false;
      pthread_mutex_unlock(&vehicleMenuLock);
      return;
    }
    index = count = 0;
  }
  // Spread discovery across frames; do not stream every model just to list it.
  uint32_t end = index + 512 < capacity ? index + 512 : capacity;
  for (; index < end; index++) {
    u64 info = PG_FN_MODEL_INFO_AT_INDEX(instance, index);
    if (!info || (*(uint8_t *)pg_pointer(&env, info + 157, 1) & 31) != 5) continue;
    uint32_t hash = *(uint32_t *)pg_pointer(&env, info + 24, 4);
    if (!hash || !PG_FN_IS_VEHICLE_MODEL(instance, hash)) continue;
    bool duplicate = false;
    for (uint32_t i = 0; i < count; i++) if (building[i].model == hash) { duplicate = true; break; }
    if (duplicate) continue;
    PGVehicleEntry *entry = &building[count++];
    entry->model = hash;
    entry->vehicleClass = PG_FN_VEHICLE_CLASS(instance, hash);
    u64 name = PG_FN_HASH_STRING_TRY_GET(instance, 0, hash);
    u64 label = PG_FN_VEHICLE_LABEL(instance, hash);
    if (name) snprintf(entry->name, sizeof entry->name, "%s", pg_string(&env, name));
    if (!entry->name[0]) snprintf(entry->name, sizeof entry->name, "0x%08X", hash);
    if (label) snprintf(entry->label, sizeof entry->label, "%s", pg_string(&env, label));
  }
  if (index < capacity) return;
  // The model pool includes every world object; retain only the much smaller vehicle list.
  if (count) {
    PGVehicleEntry *compact = realloc(building, count * sizeof *building);
    if (compact) building = compact;
  } else { free(building); building = NULL; }
  pthread_mutex_lock(&vehicleMenuLock);
  free(vehicleCatalog); vehicleCatalog = building; building = NULL;
  vehicleCatalogCount = (int32_t)count; vehicleCatalogRequested = false;
  pthread_mutex_unlock(&vehicleMenuLock);
  char line[96]; snprintf(line, sizeof line, "Vehicle menu: found %u registered vehicle models.", count); pg_log(line);
}
static void pg_vehicle_menu_step(w2c_game *instance, u64 vector) {
  pg_vehicle_catalog_tick(instance);
  static double began;
  static bool requested;
  static u64 requestOwner;
  pthread_mutex_lock(&vehicleMenuLock);
  PGVehicleSpawnStatus status = vehicleSpawnStatus;
  uint32_t model = vehicleSpawnModel;
  bool enter = vehicleSpawnEnter;
  double queuedAt = vehicleSpawnQueuedAt;
  pthread_mutex_unlock(&vehicleMenuLock);
  if (status != PGVehicleSpawnWaiting && status != PGVehicleSpawnLoading) { began = 0; return; }
  double now = timeMS(CLOCK_MONOTONIC);
  if (!began) { began = queuedAt; requested = false; }
  // A paused/suspended script may not tick at all. Expire from submission time
  // so returning from a long pause cannot execute an old menu request.
  if (!requested && now - began >= 10000) {
    began = 0; pg_vehicle_spawn_status(PGVehicleSpawnNotReady); return;
  }
  bool ready = !PGPauseMenuActive() && PGGameStatus() == 0 && PGLoadSceneSeconds() == 0;
  // Settings closes the pause menu. Wait for real readiness instead of relying on a UI delay.
  if (!requested && !ready) {
    if (now - began > 10000) { began = 0; pg_vehicle_spawn_status(PGVehicleSpawnNotReady); }
    return;
  }
  u64 previous = pg_enter_main_script(instance);
  u64 active = *(u64 *)pg_pointer(&env, instance->w2c_g1 + 3088, 8);
  u64 owner = active ? PG_FN_CURRENT_SCRIPT_HANDLER(instance) : 0;
  if (!owner || (requested && owner != requestOwner)) {
    // Never release a request through a different script's handler. The original
    // handler tears down its references when the main script is destroyed.
    pg_leave_main_script(instance, previous);
    began = 0; requested = false;
    pg_log("Vehicle menu: script context disappeared or changed; cancelled spawn.");
    pg_vehicle_spawn_status(PGVehicleSpawnNotReady); return;
  }
  PGVehicleSpawnStatus result = PGVehicleSpawnLoading;
  if (!requested) {
    if (!PG_FN_IS_VEHICLE_MODEL(instance, model)) result = PGVehicleSpawnUnavailable;
    else if (!pg_vehicle_make_room(instance, vector, owner)) result = PGVehicleSpawnVehicleLimit;
    else if (!pg_vehicle_memory_available()) result = PGVehicleSpawnLowMemory;
    else {
      pg_log("Vehicle menu: requesting model assets.");
      PG_FN_REQUEST_MODEL(instance, model); requested = true; requestOwner = owner; began = now;
      pg_vehicle_spawn_status(PGVehicleSpawnLoading);
    }
  }
  if (requested) {
    if (!ready) result = PGVehicleSpawnNotReady;
    else if (now - began > 30000) result = PGVehicleSpawnTimedOut;
    else if (!pg_vehicle_memory_available()) result = PGVehicleSpawnLowMemory;
    else if (PG_FN_HAS_MODEL_LOADED(instance, model)) {
      const u32 ped = PG_FN_PLAYER_PED_ID(instance);
      if (!vector || !ped) result = PGVehicleSpawnNotReady;
      else {
        PG_FN_GET_ENTITY_COORDS(instance, vector, ped, 1);
        float *v = pg_pointer(&env, vector, 24);
        float heading = PG_FN_GET_ENTITY_HEADING(instance, ped);
        uint32_t category = PG_FN_VEHICLE_CLASS(instance, model);
        float distance = (category == 15 || category == 16 || category == 21) ? 20.0f : 8.0f;
        float angle = heading * 0.017453292519943295f;
        v[0] -= sinf(angle) * distance; v[2] += cosf(angle) * distance; v[4] += 0.5f;
        pg_log("Vehicle menu: model loaded; creating vehicle.");
        u32 vehicle = PG_FN_CREATE_VEHICLE(instance, model, vector, heading, 0, 0, 1);
        result = vehicle ? PGVehicleSpawnSucceeded : PGVehicleSpawnFailed;
        if (vehicle) {
          // Boats/submarines and rail vehicles retain their natural placement.
          if (category != 14 && category != 21) PG_FN_GROUND_VEHICLE(instance, vehicle, 5.0f);
          if (enter && PG_FN_VEHICLE_SEATS(instance, model) > 0) PG_FN_SET_PED_INTO_VEHICLE(instance, ped, vehicle, (u32)-1);
          // Ordered oldest to newest. Room was made before requesting assets.
          if (!menuVehicles[0]) menuVehicles[0] = menuVehicles[1];
          menuVehicles[1] = vehicle;
        }
      }
    }
  }
  if (result != PGVehicleSpawnLoading && requested) PG_FN_RELEASE_MODEL(instance, model);
  pg_leave_main_script(instance, previous);
  if (result != PGVehicleSpawnLoading) {
    char line[128]; snprintf(line, sizeof line, "Vehicle menu: model 0x%08x finished with status %d.", model, result); pg_log(line);
    began = 0; requested = false;
    pg_vehicle_spawn_status(result);
  }
}

static void pg_vehicle_menu_tick(w2c_game *instance) {
  // Engine calls may pump input while doing work. Never execute a request twice.
  static bool ticking;
  if (ticking) return;
  ticking = true;
  // Temporary script arguments belong on this thread's WASM stack, not in a
  // cached allocation whose lifetime can cross script/world resets.
  u64 stack = instance->w2c_g0;
  instance->w2c_g0 -= 32;
  pg_vehicle_menu_step(instance, instance->w2c_g0);
  instance->w2c_g0 = stack;
  ticking = false;
}

// The pad callback runs on CControlMgr's worker in parallel with main-thread
// vehicle-pool traversal. Mutating entities there races partially constructed
// vtables (native-port.log: f29099, index 1585769, Besra spawn). GtaThread::Update
// is the engine's serialized script phase and is also used during session init.
void pg_script_menu_tick(w2c_game *instance, u64 thread) {
  if (!thread || strcmp(pg_string(&env, thread + 428), "main")) return;
  if (*(uint8_t *)pg_pointer(&env, thread + 614, 1) == 1) return; // Suspended script.
  static bool logged;
  if (!logged) { pg_log("Cheats: main script update hook active; vehicle spawning serialized."); logged = true; }
  pg_vehicle_menu_tick(instance);
  pg_native_cheats_tick(instance);
}
