#pragma once
#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>

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
// The minimap's place (GTA-131, NativeAssets.m): offsets in the game's HUD units and a size factor; before the engine starts.
void PGSetMinimapLayout(double dx, double dy, double scale);
// Where help messages show (NativeAssets.m): the box's top-left corner in the game's HUD units (fractions of the
// 16:9 HUD area from its top left; 0, 0 is the game's own place) and a size factor; before the engine starts.
void PGSetHelpTextLayout(double x, double y, double scale);
// HUD layout (GTA-197, NativeHudLayout.c): a piece's offset in the game's HUD units (fractions of the 16:9 HUD area, x to
// the right, y down) and a size factor. Pieces: 0 character switch wheel, 1 phone (both apply live), 2 notification
// feed, 3 top-right stats, 4 subtitles, 5 vehicle and area names (read from frontend.xml when the engine starts).
void PGSetHudPiece(int32_t piece, double dx, double dy, double scale);
bool PGUsingLocalGameFolder(void);
// Before PGStartEngine: Self Radio's song list from the songs in musicFolder (GTA-5, Source/NativeUserMusic.c).
// Returns how many songs it lists; the game shows the station with 3 or more.
int32_t PGUserMusicPrepare(const char *musicFolder, const char *filesRoot);
// Self Radio's play order: 0 like a radio station (songs join midway, no skipping), 1 in order, 2 shuffle.
void PGSetSelfRadioMode(int32_t mode);
// A Self Radio song is playing now (its sound reached the game in the last second).
bool PGSelfRadioAudible(void);
// The next song, as the radio wheel's Next track does (not in the radio-station order).
void PGSelfRadioNext(void);
// Before PGStartEngine (GTA-153): true starts this once without anything from the Mods folder ("Start without mods").
void PGSetModsOff(bool off);
// The mods the game used this launch (GTA-153): the names of the Mods folder's top-level entries (a mod's folder,
// or a file or game folder put in by hand), one per line, into out. Returns the length.
size_t PGModsUsed(char *out, size_t capacity);
void PGStartEngine(const char *manifestPath, const char *filesRoot, PGLogCallback, void *context);
void PGUpdateController(PGControllerState state, double elapsedSeconds);
// Player context: 0 on foot, otherwise the vehicle type + 1 (see NativeTouchContext.h).
uint32_t PGCurrentTouchContext(void);
// Game state for the touch layout: 1 control off, 2 phone out, 4 cutscene, 8 warning screen, 16 no player, 32 game paused.
uint32_t PGGameStatus(void);
// Friend Request's Lifeinvader presentation on the TV: how far it is (ms) and how long; false when not on.
bool PGTVPresentation(int32_t *playMs, int32_t *durationMs);
// Subtitles above the home bar (GTA-95): how far up the subtitle line moves, in fractions of the screen height.
void PGSetSubtitleRaise(double raise);
// A mod file the game can't read (made for GTA V Enhanced): true, with the reason (NativeAssets.m).
bool PGModFileProblem(const char *path, char *why, size_t n);
// Script mods (.asi): press or release a Windows virtual-key code for them; which keys they poll.
void PGAsiSetKey(int virtualKey, bool down);
bool PGAsiModKeys(uint8_t keys[256]);
// One mod (.asi file name): the keys it checked while it ran, and whether it takes keyboard events (GTA-179).
bool PGAsiModuleKeys(const char *module, uint8_t keys[256], bool *keyboardHandler);
// Another key answers a mod's own key (GTA-181); cleared and set again whenever the player changes one.
void PGAsiSetKeyRemap(const char *module, int modKey, int key);
void PGAsiClearKeyRemaps(void);
/// The mod whose script is still starting up over several frames, or NULL (GTA-209: the app shows "Loading <mod>").
const char *PGAsiBusyModName(void);
// What the Mod keys pad shows: see PGAsiKeyInfo in NativeASI.h.
#include "NativeASI.h"
void PGAsiGetKeyInfo(PGAsiKeyInfo *info);
// A script mod asks for typed text: true once per request, with its title, default text and length limit.
bool PGAsiTextRequest(char *title, size_t titleSize, char *text, size_t textSize, int *maxLength);
// The typed text for that request, or NULL when cancelled.
void PGAsiTextFinish(const char *text);
// What the touch controls need to know to show a button only when it applies (all memory reads).
typedef struct {
  bool specialShown;   // the character has a usable special ability here
  bool specialReady;   // charged enough to start
  bool specialActive;  // running now
  float specialFill;   // meter, 0...1
  bool canDetonate;    // the player has sticky bombs placed
  bool helpDetonate;   // a help message asks for INPUT_DETONATE (explosives a mission planted)
  bool helpShown;      // a help message is on screen
  bool helpContext;    // ...and it asks for the context input (D-pad right)
  bool contextPrompt;  // a script's context prompt waits for that input, with or without its help text (GTA-104)
  uint32_t helpInputs; // ...and the script inputs it names: bit n is input 218 + n (sticks 218-221, buttons 222-231, D-pad 232-235)
  bool radioWheelOpen; // the radio wheel is up
  bool helpExit;       // a help message names INPUT_VEH_EXIT or INPUT_ENTER (Y on a controller), e.g. diving off the boat (GTA-189)
  uint32_t vehicleModel; // model name hash (joaat) of the vehicle the player is in, 0 on foot
  uint32_t pedModel;     // model name hash (joaat) of the player ped (a_c_chop while playing as Chop)
  bool trailerAttached;  // the player's vehicle pulls a trailer (the touch controls show Detach trailer)
  bool selfRadioPlaying; // a Self Radio song is playing (the touch controls show Next song)
  bool passenger;        // in a vehicle, not in the driver's seat (taxi rides)
  bool taxiMenu;         // the taxi ride script (taxiservice) is running
  bool phoneBrowser;     // the phone's internet app (appinternet) is open
} PGControlHints;
PGControlHints PGReadControlHints(uint32_t touchContext);
// For player logs: the story mission running ("docks_setup (DH1)", empty when none), the player's position and
// the replay controller's state (1: the Mission failed screen). False before the engine runs.
bool PGStoryContext(char *mission, size_t size, float position[3], int32_t *replayState);
// Simulator only (Source/NativeDebugChannel.inc): runs one test-harness command and writes its JSON reply.
void PGDebugCommand(const char *command, char *reply, size_t size);
// The next weapon of the aircraft the player flies (applied on the game thread).
void PGNextAircraftWeapon(void);
/// Story cheat "Set money": the playing character's cash becomes `amount` at the next engine frame.
void PGSetPlayerCash(int32_t amount);
// Settings › Cheats (Source/NativeVehicleSpawn.inc, Source/NativeCheats.inc). The app only queues
// requests and reads copies here; the game commands run on the game thread during the "main"
// script's turn, never from UIKit or the controller thread.
// One vehicle the game knows: its model name hash, class (0 compacts ... 20 commercial; trains are
// left out), model name ("adder") and the name the game shows for it, in the game's language ("Adder";
// empty when the game files have no text for it).
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
// Spawns the vehicle in front of the player once the game runs; false while another spawn is pending.
bool PGSpawnVehicle(uint32_t model, bool enterVehicle);
PGVehicleSpawnStatus PGGetVehicleSpawnStatus(void);
// One-off actions. Time takes the hour (0-23); weather takes 0 clear, 1 extra sunny, 2 clouds,
// 3 overcast, 4 rain, 5 thunder, 6 fog.
typedef enum {
  PGCheatRepairVehicle, PGCheatCleanVehicle, PGCheatSetTime,
  PGCheatSetWeather, PGCheatNaturalWeather
} PGCheatCommand;
typedef enum {
  PGCheatIdle, PGCheatWaiting, PGCheatSucceeded, PGCheatNoVehicle, PGCheatNotReady
} PGCheatStatus;
// Queues one action (one at a time); false while another is pending or for a bad value.
bool PGQueueCheat(PGCheatCommand command, int32_t value);
PGCheatStatus PGGetCheatStatus(void);
// Switches that stay on until turned off (or the app closes), through respawns and character
// switches. Flipping one works while Settings has the game paused; it takes effect once play resumes.
typedef enum { PGCheatGodMode, PGCheatNeverWanted } PGCheatSwitch;
// The switch as the player last set it.
bool PGCheatEnabled(PGCheatSwitch cheat);
bool PGSetPersistentCheatEnabled(PGCheatSwitch cheat, bool enabled);
/// Seconds the engine has been in a load scene (respawn, warp, story transition), 0 when none.
int PGLoadSceneSeconds(void);
/// Whether a script asked for input `action` (the engine's input id) in the last `ms` milliseconds.
int PGInputPolledWithin(int action, double ms);
/// Whether a script read input `action` in any way in the last `ms` milliseconds (for diagnostics; GTA-129).
int PGInputReadWithin(int action, double ms);
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
// The game's own mouse cursor as a fraction of the screen (0...1); false before the game reads input.
bool PGMousePosition(float *x, float *y);
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
// Memory the app may still use before the system stops it (on the Mac: a limit the app sets itself).
uint64_t PGProcessAvailableMemory(void);
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
void PGStreamingHealth(uint64_t out[6]);		// NativeStreamingHealth.c (GTA-116)
double PGGPUFrameMilliseconds(void);		// MRRenderer.mm
size_t PGThreadCPU(char *out, size_t size);	// NativeThreadCPU.c: cores per thread group since the last call (GTA-162)
