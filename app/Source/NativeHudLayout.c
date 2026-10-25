// HUD layout (GTA-197): where the player put the character switch wheel, the phone and the HUD pieces that
// common/data/ui/frontend.xml places (Settings › Touch controls › HUD layout, App/HUDLayoutEditor.swift).
//
// - The character switch wheel is the "selector" script's: it draws the PLAYER_SWITCH movie (and the stats panel
//   beside it, PLAYER_SWITCH_STATS_PANEL) with DRAW_SCALEFORM_MOVIE, aligned to the HUD's bottom right
//   (SET_SCRIPT_GFX_ALIGN 'R', 'B'). Scripts/prepare_hud_layout.py has that command's handler call
//   pg_hud_scaleform first, which moves and sizes what the selector draws. Read every frame: a change applies at once.
// - The phone: SET_MOBILE_PHONE_POSITION keeps the scripts' place at 19505776 (x, y, z; CPhoneMgr), and
//   GET_MOBILE_PHONE_POSITION gives it back. The phone scripts compare the y they get back with their own places
//   (cellphone_flashhand: "is the phone up yet"), so pg_hud_phone_set moves the stored place and pg_hud_phone_get
//   gives the scripts back exactly what they set. Its size (SET/GET_MOBILE_PHONE_SCALE, 6973188) the same way.
//   Applies the next time a script places the phone.
// - The feed, the top-right stats, the subtitles and the vehicle and area names are frontend.xml entries, read once
//   at start (NativeAssets.m, PGFrontendRewrite).
#include "HostInternal.h"
#include <math.h>
#include <stdio.h>
#include <string.h>

enum { PIECES = 6 };
static volatile double pieceDX[PIECES], pieceDY[PIECES], pieceScale[PIECES] = {1, 1, 1, 1, 1, 1};

void PGSetHudPiece(int32_t piece, double dx, double dy, double scale) {
  if (piece < 0 || piece >= PIECES) return;
  pieceDX[piece] = isfinite(dx) && fabs(dx) < 1.2 ? dx : 0;
  pieceDY[piece] = isfinite(dy) && fabs(dy) < 1.2 ? dy : 0;
  pieceScale[piece] = isfinite(scale) && scale > 0.4 && scale < 2.5 ? scale : 1;
}
bool pg_hud_piece(int piece, double *dx, double *dy, double *scale) {
  if (piece < 0 || piece >= PIECES) return false;
  *dx = pieceDX[piece]; *dy = pieceDY[piece]; *scale = pieceScale[piece];
  return *dx != 0 || *dy != 0 || *scale != 1;
}

// The script that runs the command: the active thread (per engine thread, at g1 + 3088), its name at +428.
static bool running_script(w2c_game *instance, const char *name) {
  const uint8_t *m = (uint8_t *)instance->w2c_env_memory->data; const uint64_t size = instance->w2c_env_memory->size;
  const uint64_t slot = instance->w2c_g1 + 3088;
  uint64_t thread = 0;
  if (slot + 8 > size) return false;
  memcpy(&thread, m + slot, 8);
  if (!thread || thread + 428 + 32 > size) return false;
  return !strncmp((const char *)(m + thread + 428), name, 32);
}

// DRAW_SCALEFORM_MOVIE(movie, x, y, width, height, ...). The selector draws the wheel and the stats panel above it with
// the same alignment; both move together. Measured in the simulator (GTA-197): a unit of x or y moves them by the HUD
// area's width or height (1125 and 620 of 1120 × 630 points), and sizing both around the script's 0, 0 keeps the wheel's
// bottom-right corner in place, so the panel stays above the wheel.
void pg_hud_scaleform(w2c_game *instance, u32 movie, f32 *x, f32 *y, f32 *width, f32 *height) {
  (void)movie;
  const double dx = pieceDX[0], dy = pieceDY[0], s = pieceScale[0];
  if ((dx == 0 && dy == 0 && s == 1) || !running_script(instance, "selector")) return;
  *x = (f32)(*x * s + dx);
  *y = (f32)(*y * s + dy);
  *width = (f32)(*width * s);
  *height = (f32)(*height * s);
}

// The phone's place, in CPhoneMgr's units (x to the right, y up). Measured in the simulator (GTA-197): 186 units move the
// phone across a 16:9 HUD area's width, 130 across the screen's height (the app scales x for a narrower screen). The
// last place a script set and what was stored.
static float phoneSetY, phoneStoredY, phoneSetX, phoneStoredX;
static bool phoneMoved;
static float scaleSet, scaleStored;
static bool scaleMoved;
static void phone_scale(uint8_t *m) {
  // Until a script sets the size, the phone has the size the game gave it when it made it.
  if (scaleSet <= 0) memcpy(&scaleSet, m + 6973188, 4);
  if (scaleSet <= 0) return;
  scaleStored = (float)(scaleSet * pieceScale[1]);
  scaleMoved = scaleStored != scaleSet;
  memcpy(m + 6973188, &scaleStored, 4);
}
void pg_hud_phone_set(w2c_game *instance) {
  uint8_t *m = (uint8_t *)instance->w2c_env_memory->data;
  const double dx = pieceDX[1], dy = pieceDY[1];
  float place[2];
  memcpy(place, m + 19505776, 8);
  phoneSetX = place[0]; phoneSetY = place[1];
  // The size too: the scripts set it once, when they make the phone, but the player's size can change since.
  phone_scale(m);
  phoneMoved = dx != 0 || dy != 0;
  if (!phoneMoved) return;
  place[0] = (float)(place[0] + dx * 186.3);
  place[1] = (float)(place[1] - dy * 130.0);
  phoneStoredX = place[0]; phoneStoredY = place[1];
  memcpy(m + 19505776, place, 8);
}
void pg_hud_phone_get(w2c_game *instance, u64 out) {
  uint8_t *m = (uint8_t *)instance->w2c_env_memory->data; const uint64_t size = instance->w2c_env_memory->size;
  if (!phoneMoved || !out || out + 8 > size) return;
  float place[2];
  memcpy(place, m + out, 8);
  if (place[0] == phoneStoredX) place[0] = phoneSetX;
  if (place[1] == phoneStoredY) place[1] = phoneSetY;
  memcpy(m + out, place, 8);
}

// The phone's size (SET_MOBILE_PHONE_SCALE, 6973188; the phone scripts set 500, larger for some apps). Scaled by the
// player's size, and given back as set, as the place is.
void pg_hud_phone_scale_set(w2c_game *instance) {
  uint8_t *m = (uint8_t *)instance->w2c_env_memory->data;
  memcpy(&scaleSet, m + 6973188, 4);
  phone_scale(m);
}
void pg_hud_phone_scale_get(w2c_game *instance, u64 out) {
  uint8_t *m = (uint8_t *)instance->w2c_env_memory->data; const uint64_t size = instance->w2c_env_memory->size;
  if (!scaleMoved || !out || out + 4 > size) return;
  float scale;
  memcpy(&scale, m + out, 4);
  if (scale == scaleStored) memcpy(m + out, &scaleSet, 4);
}

static const char *pieceNames[PIECES] = {"character wheel", "phone", "feed", "top-right stats", "subtitles", "vehicle and area names"};
void pg_hud_log(void) {
  for (int piece = 0; piece < PIECES; piece++) {
    if (pieceDX[piece] == 0 && pieceDY[piece] == 0 && pieceScale[piece] == 1) continue;
    char line[160];
    snprintf(line, sizeof line, "HUD layout: %s moved by %.3f, %.3f, size %.2f.", pieceNames[piece], pieceDX[piece], pieceDY[piece], pieceScale[piece]);
    pg_log(line);
  }
}
#if TARGET_OS_SIMULATOR
#include <stdlib.h>
// Test (PG_HUD="piece:dx,dy,scale;..."): pieces placed without the app's Settings, e.g. "0:-0.5,-0.3,1;1:-0.4,0,1".
void pg_hud_test_environment(void) {
  const char *test = getenv("PG_HUD");
  for (const char *at = test; at && *at;) {
    int piece; double dx, dy, s;
    if (sscanf(at, "%d:%lf,%lf,%lf", &piece, &dx, &dy, &s) == 4) PGSetHudPiece(piece, dx, dy, s);
    at = strchr(at, ';'); if (at) at++;
  }
}
#endif
