// Script Hook V mods (.asi) for the GTA V iOS port (GTA-69).
//
// An .asi is a 64-bit Windows DLL written against Script Hook V. It runs here in an x86-64
// interpreter (Blink) whose guest addresses are the engine's own (wasm) memory addresses, so
// every pointer a mod passes to a game command is valid for the engine as is. Its Windows and
// Script Hook V imports are small stubs that trap into this layer.
#pragma once
#include <stdbool.h>
#include <stdint.h>

typedef struct PGAsiHost {
  uint8_t *memory;  // host address of guest address 0 (the engine's memory base)
  uint64_t size;    // engine memory size; guest accesses outside [64 KB, size) go to a scratch page
  uint64_t (*alloc)(uint64_t size);  // guest memory from the engine's heap, 16-byte aligned; 0 on failure
  void (*free)(uint64_t address);
  void (*log)(const char *line);
  // Runs one game command (native) by its Script Hook V hash on the calling (script) thread.
  // Arguments and the result live in guest memory. Returns false for a hash this game build lacks.
  bool (*native)(uint64_t hash, uint64_t arguments, uint32_t count, uint64_t result);
  uint64_t (*global)(int index);  // guest address of a script global, 0 if unknown
  bool (*key_down)(int virtualKey);
  uint32_t (*world_entities)(int kind, uint64_t out, uint32_t capacity);  // kind 0 vehicles, 1 peds, 2 objects
  int game_version;  // Script Hook V eGameVersion reported to mods
  const char *files;  // host folder that stands in for the game folder (ini files, logs)
} PGAsiHost;

bool pg_asi_init(const PGAsiHost *host);
// Loads an .asi (file bytes) and runs its DllMain. root: its folder, which stands in for the game folder
// (its .ini files). Returns a module id (>0) or 0 on failure.
int pg_asi_load(const char *name, const char *root, const uint8_t *bytes, uint64_t length);
// Runs every registered script until it waits again. Call once per game frame on the script thread.
void pg_asi_tick(void);
// Keyboard events for mods that registered a keyboard handler (Windows virtual-key codes).
void pg_asi_key(int virtualKey, bool down);
// What the Mod keys pad learns from the mods (Windows virtual-key codes): how often each key was
// checked while no mod menu was drawn and while one was, which key presses made a menu appear,
// and whether a menu is on screen now (mods drawing rectangles, sprites and text this frame).
// hinted: keys a mod's own .ini names as its menu key (MenuKey=114, OpenKey=0x77, ToggleKey=F8).
typedef struct { uint8_t closed[256], open[256], opens[256], hinted[256]; bool menuVisible, keyboardHandler; } PGAsiKeyInfo;
void pg_asi_key_info(PGAsiKeyInfo *info);
// Keys (Windows virtual-key codes, 0-255) that mods have asked about through GetAsyncKeyState or
// GetKeyState since start: the on-screen Mod keys pad offers these. Returns true when a mod also
// registered a keyboard handler (it may react to any key).
bool pg_asi_polled_keys(uint8_t polled[256]);
// One mod (by .asi file name): the keys it asked about while it ran, and whether it registered a keyboard handler.
// False when no such mod is loaded.
bool pg_asi_module_keys(const char *name, uint8_t polled[256], bool *keyboardHandler);
// A key that answers a mod's own key (GTA-181): that mod sees `key` as `modKey`, and no longer sees `modKey` itself.
void pg_asi_set_key_remap(const char *module, int modKey, int key);
void pg_asi_clear_key_remaps(void);
// Interpreter time spent in the last tick, in microseconds, and instructions executed.
void pg_asi_stats(uint64_t *microseconds, uint64_t *instructions);
