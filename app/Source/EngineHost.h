#pragma once
#include <stdint.h>
#include <stdbool.h>

typedef void (*PGLogCallback)(const char *, void *);
typedef struct {
  float leftX, leftY, rightX, rightY, leftTrigger, rightTrigger;
  uint32_t buttons;
  // Extra mouse pixels this poll (gyro look), added to the stick look.
  int32_t lookDX, lookDY;
} PGControllerState;
// buttons: A B X Y LB RB Menu Up Down Left Right in bits 0...10.
// Touch additions: Sprint (11), Weapon Wheel (12), Camera (13),
// Gas (14), Brake (15), Headlights (16). They use the game's PC bindings.
// Flight: Roll left/right (17/18), Pitch forward/back (19/20),
// Yaw left/right (21/22), Landing gear (23). Throttle uses Gas/Brake.
// Bit 24 identifies a vehicle touch layout: Tab cycles weapons rather than
// using the walking weapon-wheel cursor.
// Before PGStartEngine: engine quality options (e.g. "-shadowQuality=0"),
// back-buffer size and frame limit (0 none, 1 = 60, 2 = 30 FPS).
void PGConfigureEngine(const char *const *quality, unsigned count, int width, int height, int frameLimit);
// Changes the frame limit while the game runs (0 off, 1 60 FPS, 2 30 FPS).
void PGSetFrameLimit(int frameLimit);
// Settings › Memory cap in MB (0 automatic); call before the engine starts.
void PGSetMemoryCap(int mb);
// Before PGStartEngine: 1 Story Mode (the release startup: continues the
// newest save in /userdata/Documents, else a new game from the Prologue),
// 2 Sandbox Mode (free roam on the GTA V map; its files go to
// /sandbox/Documents), 3 Sandbox Mode on the test level (env_test). Default 2.
void PGSetStartMode(int32_t mode);
// Live back-buffer resize after the engine has started.
void PGSetBackBufferSize(int width, int height);
// Base URL of your own game-file server, e.g. https://pc.tailnet.ts.net
void PGSetAssetServer(const char *url);
// Before PGStartEngine: a folder on this device that contains the game's data/
// files (the app holds security-scoped access to it); NULL streams from the server.
void PGSetLocalGameFolder(const char *dataPath);
bool PGUsingLocalGameFolder(void);
void PGStartEngine(const char *manifestPath, const char *filesRoot, PGLogCallback, void *context);
void PGUpdateController(PGControllerState state, double elapsedSeconds);
// Player context: 0 on foot, otherwise the vehicle type + 1 (see NativeTouchContext.h).
uint32_t PGCurrentTouchContext(void);
// Game state for the touch layout: 1 control off, 2 phone out, 4 cutscene, 8 warning screen, 16 no player.
uint32_t PGGameStatus(void);
// What the touch controls need to know to show a button only when it applies (all memory reads).
typedef struct {
  bool specialShown;   // the character has a usable special ability here
  bool specialReady;   // charged enough to start
  bool specialActive;  // running now
  float specialFill;   // meter, 0...1
  bool canDetonate;    // the player has sticky bombs placed
  bool helpShown;      // a help message is on screen
  bool helpContext;    // ...and it asks for the context input (D-pad right)
  bool radioWheelOpen; // the radio wheel is up
  uint32_t vehicleModel; // model name hash (joaat) of the vehicle the player is in, 0 on foot
  bool passenger;        // in a vehicle, not in the driver's seat (taxi rides)
  bool taxiMenu;         // the taxi ride script (taxiservice) is running
} PGControlHints;
PGControlHints PGReadControlHints(uint32_t touchContext);
// The next weapon of the aircraft the player flies (applied on the game thread).
void PGNextAircraftWeapon(void);
/// Story cheat "Set money": the playing character's cash becomes `amount` at the next engine frame.
void PGSetPlayerCash(int32_t amount);
// Vehicle menu: UIKit exchanges snapshots/requests only; engine calls run in the main script update phase.
typedef struct {
  uint32_t model, vehicleClass;
  char name[64], label[64];
} PGVehicleEntry;
void PGRequestVehicleCatalog(void);
// -1 while reading (or before the first request), -2 on failure, otherwise entry count.
int32_t PGVehicleCatalogCount(void);
bool PGVehicleCatalogEntryAt(uint32_t index, PGVehicleEntry *entry);
typedef enum {
  PGVehicleSpawnIdle, PGVehicleSpawnWaiting, PGVehicleSpawnLoading,
  PGVehicleSpawnSucceeded, PGVehicleSpawnUnavailable, PGVehicleSpawnTimedOut,
  PGVehicleSpawnNotReady, PGVehicleSpawnFailed,
  PGVehicleSpawnLowMemory, PGVehicleSpawnVehicleLimit
} PGVehicleSpawnStatus;
bool PGSpawnVehicle(uint32_t model, bool enterVehicle);
PGVehicleSpawnStatus PGGetVehicleSpawnStatus(void);
typedef enum {
  PGCheatRepairVehicle, PGCheatCleanVehicle, PGCheatSetTime,
  PGCheatSetWeather, PGCheatNaturalWeather, PGCheatGodMode, PGCheatNeverWanted
} PGCheatCommand;
typedef enum {
  PGCheatIdle, PGCheatWaiting, PGCheatSucceeded, PGCheatNoVehicle, PGCheatNotReady
} PGCheatStatus;
// Weather values: clear, extra sunny, cloudy, overcast, rain, thunder, fog.
bool PGQueueCheat(PGCheatCommand command, int32_t value);
PGCheatStatus PGGetCheatStatus(void);
// Requested session state. Switches apply at the next safe gameplay update,
// independently of the single-action queue, without expiring while paused.
bool PGCheatEnabled(PGCheatCommand command);
bool PGSetPersistentCheatEnabled(PGCheatCommand command, bool enabled);
/// Seconds the engine has been in a load scene (respawn, warp, story transition), 0 when none.
int PGLoadSceneSeconds(void);
/// Whether a script asked for input `action` (the engine's input id) in the last `ms` milliseconds.
int PGInputPolledWithin(int action, double ms);
/// Presses Start (opens the pause menu, or closes it when open): held for the next three engine frames.
void PGRequestPauseMenu(void);
// Keyboard and mouse, through the game's own PC input (the block the browser build wrote): key
// state bytes indexed by Windows virtual-key code, and mouse words after them.
void PGSetKey(uint8_t virtualKey, bool down);
// The radio wheel's direction (stick-style, up positive). Its two inputs have no controller binding
// in this build, so the value is written into them directly while the wheel is held.
void PGSetRadioWheelDirection(float x, float y, bool active);
void PGReleaseAllKeys(void);
// Mouse movement in pixels since the last call, buttons (bit 0 left, 1 right, 2 middle).
void PGMouseInput(int32_t dx, int32_t dy, int32_t buttons);
void PGMouseWheel(int32_t notches);
// The window has focus / the pointer is captured for looking around.
void PGSetMouseFocus(bool focused, bool locked);
bool PGDebugReadMemory(uint64_t address, void *out, uint64_t length);
// Virtual controller fed into the engine's own pad 0 (see
// Scripts/prepare_virtual_pad.py). Buttons use the engine's pad bits:
// L2 1, R2 2, L1 4, R1 8, Y 16, B 32, A 64, X 128, Select 256, L3 512,
// R3 1024, Start 2048, D-pad up/right/down/left 4096/8192/16384/32768.
// Sticks -1...1 with up positive; triggers 0...1.
typedef struct {
  uint32_t buttons;
  float leftX, leftY, rightX, rightY, leftTrigger, rightTrigger;
} PGPadState;
void PGUpdateVirtualPad(PGPadState state);
// Existing controller-swipe impulse bridge, consumed on engine input sampling.
void PGQueueCameraSwipe(float x, float y);
void PGClearCameraSwipe(void);
// The engine's last input device for the player: -4 keyboard/mouse,
// 0...3 pads, -3 unknown. Assisted aim needs a pad.
int32_t PGLastInputDevice(void);
// Targeting preference: 0 traditional lock, 1 assisted, 2 assisted free, 3 free.
int32_t PGTargetingMode(void);
// Applied on the engine thread once the local player exists.
void PGSetTargetingMode(int32_t mode);
// The engine's pause menu / frontend is open.
bool PGPauseMenuActive(void);
void PGFillAudio(float *left, float *right, uint32_t count);
// Health counters for the periodic log line.
uint64_t PGMemoryBudgetQueries(void);
uint64_t PGMemoryBudgetClamps(void);
/// Memory the renderer's textures hold on the GPU (estimated in the simulator, where it isn't in the footprint).
uint64_t PGGPUTextureBytes(void);
/// Logs how much of each engine memory pool iOS really holds (diagnostics, every minute).
void PGLogMemoryPools(void);
uint64_t PGMemoryBudgetEvictions(void);
void PGAssetHealth(uint64_t out[6]);
