"""Engine stops that the PC game would carry on from (GTA-194: the top "Native trap" groups in player logs).

These game files are a BankRelease build: a bounds check (an atArray index, a bone or vertex index) that the PC
release build compiles out becomes a wasm `unreachable` here, and the port's engine stops with "Unreachable
instruction executed" and no message. Each site below was found from symbolized player logs (v1.4.2-v1.4.7).
Where carrying on is safe, the site now does what the engine itself does
for a missing thing, logs one line (rate limited) and goes on. Where it is not safe, the site logs a "Fatal Error:"
line that names the file, so the stop panel (App/StopCause.swift, GTA-178) can say what to fix, and still stops.

Carry on:
  1. audMetadataManager::GetObjectMetadataPtrFromSpecificChunk: an add-on pack's audio game data (X_game.dat151)
     didn't load, so FindChunkId answers -1, and audMetadataDataFileMounter::LoadDataFile still looks up the pack's
     radio stations in chunk -1 (56 stops in 42 logs). Now "not found" (null), the engine's own answer for a missing
     object; the lock it took is released first. The car plays without its own sounds.
  2. PrimitiveTriangle::Collide: a collision triangle's neighbour across an edge doesn't share that edge's two
     vertices, so the neighbour's "opposite" vertex index is out of range (30 stops in 25 logs, mostly without
     mods). Now that edge is treated as having no neighbour, which the engine already does for an open edge: the
     triangle's own third vertex and its own polygon.
  3. CReplayEventManager::HasEventExpired<CPacketRequestCloudHat>: a cloud hat request from a weather or timecycle
     mod names a hat that doesn't exist (8 stops in 7 logs, all with weather.xml/timecycle/CloudKeyframes mods).
     Now the replay event counts as expired (dropped); the replay recorder is all that reads it.
  4. CTorsoVehicleIkSolver::Iterate: a bone index (spine, neck, arm) is past the ped's skeleton (13 stops in 10 logs,
     one heavily modded player). Now that ped's vehicle lean is skipped for the frame; the stack is put back as on
     return.
  5. grmShaderGroup::SetVar: a shader variable or shader index past the model's shader group (1 log, a ped mod). Now
     that texture isn't set.
Name the cause and stop:
  6. pgBase::pgBase: a resource chunk that can't go in its page map (24 stops in 19 logs). The page map is what frees
     the resource later, and a wrong entry would free the wrong memory, so this still stops, now with
     "Fatal Error: Resource '<name>' : chunk ..." naming the file and the bad value.
  7. CFileMgr::MountAudioPacks: a core audio archive is missing or unreadable (15 stops in 15 logs: missing files,
     archives not re-keyed, half downloads). "Fatal Error: Unable to find critical archive '<name>'".

Simulator tests: PG_TEST_GUARD=audio,triangle,cloudhat,ik,shader forces those paths (Generated/game-trap-guards.h).
Idempotent; matches the *_shared and the *_eplain (Scripts/prepare_plain_engine.py) spellings.
"""
from pathlib import Path
from engine_names import fn
import re
root = Path(__file__).resolve().parents[1]
MARK = 'GTA-194'
INCLUDE = '#include "game-trap-guards.h"'
L = r'(?:shared|eplain)'   # memory access spelling

HEADER = r'''/* Engine stops the PC game would carry on from (Scripts/prepare_trap_guards.py, GTA-194). */
#ifndef PG_TRAP_GUARDS_H
#define PG_TRAP_GUARDS_H
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <TargetConditionals.h>
extern void pg_log(const char *message);

enum { PG_GUARD_AUDIO, PG_GUARD_TRIANGLE, PG_GUARD_CLOUD_HAT, PG_GUARD_IK, PG_GUARD_SHADER, PG_GUARD_COUNT };
__attribute__((unused)) static const char *const pgGuardNames[PG_GUARD_COUNT] = {"audio", "triangle", "cloudhat", "ik", "shader"};
__attribute__((unused)) static _Atomic int pgGuardSeen[PG_GUARD_COUNT];

/* Simulator tests: PG_TEST_GUARD=triangle,ik forces those guards' paths. Always 0 on devices. */
static inline int pg_guard_forced(int site) {
#if TARGET_OS_SIMULATOR
  static _Atomic int mask = -1;
  int m = mask;
  if (__builtin_expect(m < 0, 0)) {
    const char *list = getenv("PG_TEST_GUARD"); m = 0;
    for (int i = 0; list && i < PG_GUARD_COUNT; i++) if (strstr(list, pgGuardNames[i])) m |= 1 << i;
    mask = m;
  }
  return __builtin_expect((m >> site) & 1, 0);
#else
  (void)site; return 0;
#endif
}
/* One line per guard: the first 3 times, then at 10, 100, 1000... */
__attribute__((unused)) static void pg_guard_note(int site, const char *format, ...) {
  int n = ++pgGuardSeen[site];
  if (n > 3 && n != 10 && n != 100 && n != 1000 && n != 10000) return;
  char text[300], line[400]; va_list args; va_start(args, format); vsnprintf(text, sizeof text, format, args); va_end(args);
  snprintf(line, sizeof line, "Engine guard (GTA-194): %s%s", text, n > 1 ? "" : " The PC game carries on here; so does this one.");
  if (n > 1) { size_t used = strlen(line); snprintf(line + used, sizeof line - used, " (%d times)", n); }
  pg_log(line);
}
static inline uint64_t pg_guard_u64(w2c_game *instance, u64 address) { uint64_t v; memcpy(&v, (const void *)MEM_ADDR(instance->w2c_env_memory, address, 8), 8); return v; }
static inline uint32_t pg_guard_u32(w2c_game *instance, u64 address) { uint32_t v; memcpy(&v, (const void *)MEM_ADDR(instance->w2c_env_memory, address, 4), 4); return v; }
static inline uint32_t pg_guard_u16(w2c_game *instance, u64 address) { uint16_t v; memcpy(&v, (const void *)MEM_ADDR(instance->w2c_env_memory, address, 2), 2); return v; }
static inline const char *pg_guard_text(w2c_game *instance, u64 address) {
  if (!address || address >= instance->w2c_env_memory->size) return "?";
  const char *s = (const char *)MEM_ADDR(instance->w2c_env_memory, address, 1);
  return memchr(s, 0, (size_t)(instance->w2c_env_memory->size - address < 512 ? instance->w2c_env_memory->size - address : 512)) ? s : "?";
}

/* 1. Audio metadata: chunk -1 (its data file didn't load). "Not found". */
__attribute__((unused)) static u64 pg_guard_audio_chunk(w2c_game *instance, u64 manager, u32 hash, u32 chunk) {
  pg_guard_note(PG_GUARD_AUDIO, "audio object %u looked up in chunk %d of %u: that data file didn't load (see the \"Failed to find\" line before), so the object is missing.",
                hash, (int)chunk, pg_guard_u16(instance, manager + 88));
  return 0;
}
/* 2. Collision triangle edge whose neighbour doesn't share it: the engine's open-edge answer (own third vertex, own polygon). */
__attribute__((unused)) static u32 pg_guard_triangle(w2c_game *instance, u64 triangle, u64 bound, u32 edge, u64 *neighbour) {
  static const u32 third[3] = {488, 484, 486};   /* edge 0 = v0-v1, edge 1 = v1-v2, edge 2 = v0-v2 */
  u32 own = pg_guard_u16(instance, triangle + 194);
  *neighbour = pg_guard_u64(instance, bound + 136) + 16ull * own;
  pg_guard_note(PG_GUARD_TRIANGLE, "collision bound 0x%llx, polygon %u: edge %u's neighbour doesn't share the edge (vertex count %u); that edge is treated as open.",
                (unsigned long long)bound, own, edge, pg_guard_u32(instance, bound + 208));
  return pg_guard_u16(instance, triangle + third[edge]) & 32767u;
}
/* 3. Replay: a cloud hat request for a hat that doesn't exist counts as expired. */
__attribute__((unused)) static u32 pg_guard_cloud_hat(w2c_game *instance, u32 hat) {
  u64 manager = pg_guard_u64(instance, 28411080ull);
  pg_guard_note(PG_GUARD_CLOUD_HAT, "replay: cloud hat %d requested, the game has %u (a weather or timecycle mod); the request is dropped.",
                (int)hat, manager ? pg_guard_u16(instance, manager + 48) : 0);
  return 1;
}
/* 4. Vehicle lean IK with a bone past the skeleton: skipped for this frame. */
__attribute__((unused)) static void pg_guard_ik(w2c_game *instance, u64 skeleton, u32 site) {
  pg_guard_note(PG_GUARD_IK, "vehicle lean (torso IK) needs a bone this ped's skeleton (%u bones) doesn't have (check %u); skipped for this ped. A ped model mod is the usual cause.",
                skeleton ? pg_guard_u32(instance, skeleton + 32) : 0, site);
}
/* 5. Shader group variable past the model's shaders: the texture isn't set. */
__attribute__((unused)) static void pg_guard_shader(w2c_game *instance, u64 group, u32 variable) {
  pg_guard_note(PG_GUARD_SHADER, "a model's shader group has no variable %u (%u variables, %u shaders); that texture isn't set. A model mod is the usual cause.",
                variable, pg_guard_u16(instance, group + 40), pg_guard_u16(instance, group + 24));
}
/* 6. Page map: name the resource and the chunk, then stop as before (a wrong entry would free the wrong memory later). */
__attribute__((unused)) static void pg_guard_page_map(w2c_game *instance, u64 current, u64 index) {
  u64 resource = current ? pg_guard_u64(instance, current) : 0, map = resource ? pg_guard_u64(instance, resource) : 0;
  const char *name = resource ? pg_guard_text(instance, pg_guard_u64(instance, resource + 16)) : "?";
  unsigned count = map ? pg_guard_u16(instance, map) & 0xFF : 0, physical = map ? pg_guard_u16(instance, map) >> 8 : 0;
  u64 chunk = map + 16 + 24 * index;
  char line[400];
  snprintf(line, sizeof line, "Fatal Error: Resource '%.200s' : chunk %u of %u can't go in its page map (address 0x%llx, size 0x%llx).", name,
           (unsigned)index, count + physical, map ? (unsigned long long)pg_guard_u64(instance, chunk + 8) : 0ull, map ? (unsigned long long)pg_guard_u64(instance, chunk + 16) : 0ull);
  pg_log(line);
}
/* 7. A core audio archive is missing: name it, then stop as before. */
__attribute__((unused)) static void pg_guard_critical_archive(w2c_game *instance, u64 name) {
  char line[400];
  snprintf(line, sizeof line, "Fatal Error: Unable to find critical archive '%.300s' (a game file is missing or damaged).", pg_guard_text(instance, name));
  pg_log(line);
}
#endif
'''

def function_body(number, signature_re):
    head = re.compile(signature_re.replace('NUMBER', str(number)), re.M)
    for path in sorted((root / 'Generated').glob('game_*.c')):
        s = path.read_text()
        m = head.search(s)
        if m: return path, s, m.start(), s.index('\n}\n', m.start()) + 3
    raise RuntimeError(f'Pinned function f{number} not found')

def patch(name, number, edits, signature=r'^(?:static )?\w+ w2c_game_fNUMBER\(w2c_game\* instance[^{]*\{$'):
    """edits: list of (regex, replacement, expected count). Applied in the function body once."""
    path, s, start, end = function_body(number, signature)
    body = s[start:end]
    if MARK in body: print(f'trap guards: {name} already patched'); return
    for pattern, replacement, expected in edits:
        found = len(re.findall(pattern, body))
        if found != expected: raise RuntimeError(f'Pinned f{number} ({name}) changed: {found} matches instead of {expected} for {pattern[:60]!r}')
        body = re.sub(pattern, replacement, body)
    if MARK not in body: raise RuntimeError(f'{name}: no {MARK} mark after patching')
    s = s[:start] + body + s[end:]
    if INCLUDE not in s:
        first = re.search(r'^#include "game-[a-z-]*impl\.h"$', s, re.M)
        s = s[:first.end()] + '\n' + INCLUDE + s[first.end():]
    path.write_text(s)
    print(f'trap guards: {name} patched in f{number} ({path.name})')

(root / 'Generated/game-trap-guards.h').write_text(HEADER)

# 1. GetObjectMetadataPtrFromSpecificChunk: two bounds checks of the chunk index jump to the unreachable; the first
# holds the manager's lock (taken at +144), which is released before "not found".
CHUNK = fn('rage::audMetadataManager::GetObjectMetadataPtrFromSpecificChunk(unsigned int, unsigned int) const')
def audio_chunk():
    path, s, start, end = function_body(CHUNK, r'^(?:static )?\w+ w2c_game_fNUMBER\(w2c_game\* instance[^{]*\{$')
    body = s[start:end]
    if MARK in body: print('trap guards: audio chunk already patched'); return
    # The lock and unlock the function itself calls (sysCriticalSection enter/exit at manager+144).
    calls = re.findall(r'  w2c_game_f(\d+)\(instance, var_j0\);\n', body)
    if len(calls) < 2: raise RuntimeError(f'Pinned f{CHUNK} (audio chunk) changed: lock calls {calls}')
    lock, unlock = calls[0], calls[1]
    if (lock, unlock) != (str(fn('rage::sysCriticalSectionToken::Lock()')), str(fn('rage::sysCriticalSectionToken::Unlock()'))):
        raise RuntimeError(f'Pinned f{CHUNK} (audio chunk) changed: lock calls {calls[:2]}')
    locked = re.compile(r'(  w2c_game_f' + lock + r'\(instance, var_j0\);\n  var_i0 = var_p2;\n  var_j1 = var_p0;\n  var_i1 = i32_load16_u_' + L
                        + r'\([^\n]*88u\)\);\n  var_i0 = var_i0 >= var_i1;\n)  if \(var_i0\) \{goto var_B0;\}\n')
    trap = '  var_B0:;\n  UNREACHABLE;\n  var_Bfunc:;\n'
    if len(locked.findall(body)) != 1 or body.count(trap) != 1 or 'var_l6 = var_j0;' not in body:
        raise RuntimeError(f'Pinned f{CHUNK} (audio chunk) changed')
    body = locked.sub(lambda m: m.group(1) + f'  if (var_i0 || pg_guard_forced(PG_GUARD_AUDIO)) {{w2c_game_f{unlock}(instance, var_l6); goto var_B0;}}   /* {MARK}: release the lock */\n', body)
    body = body.replace(trap, f'  var_B0:;\n  var_j0 = pg_guard_audio_chunk(instance, var_p0, var_p1, var_p2);   /* {MARK}: not found, as for a missing object */\n  var_Bfunc:;\n')
    s = s[:start] + body + s[end:]
    if INCLUDE not in s:
        first = re.search(r'^#include "game-[a-z-]*impl\.h"$', s, re.M)
        s = s[:first.end()] + '\n' + INCLUDE + s[first.end():]
    path.write_text(s)
    print(f'trap guards: audio chunk patched in f{CHUNK} ({path.name})')
audio_chunk()

# 2. PrimitiveTriangle::Collide: per edge, the neighbour's opposite vertex index is checked against the bound's vertex
# count (+208); the index goes to var_l36 (edge 0) or var_l33 (edges 1, 2), the neighbour polygon to var_l46/53/54.
TRIANGLE = fn('rage::PrimitiveTriangle::Collide(rage::Mat34V const&, rage::Vec3V const&, rage::NewCollisionInput const&, DiscreteCollisionDetectorInterface::SimpleResult&)')
EDGE = (r'(      var_l{index} = var_i0;\n      var_j1 = var_p1;\n      var_i1 = i32_load_' + L + r'\([^\n]*208u\)\);\n'
        r'      var_i0 = \(u32\)\(\(s32\)var_i0 >= \(s32\)var_i1\);\n)      if \(var_i0\) \{{goto var_B3;\}}\n(      var_j0 = var_l{after};\n)')
def edge(index, after, number, neighbour):
    return (EDGE.format(index=index, after=after),
            lambda m: m.group(1) + f'      if (var_i0 || pg_guard_forced(PG_GUARD_TRIANGLE)) {{var_l{index} = pg_guard_triangle(instance, var_p0, var_p1, {number}, &var_l{neighbour});}}   /* {MARK}: open edge */\n' + m.group(2), 1)
patch('collision triangle', TRIANGLE, [edge(36, 47, 0, 46), edge(33, 48, 1, 53), edge(33, 49, 2, 54),
                                      (r'    var_B3:;\n    UNREACHABLE;\n', '', 1)])

# 3. HasEventExpired<CPacketRequestCloudHat>: hat index (var_l3) < count (+48 of the cloud hat manager), else unreachable.
CLOUD = fn('bool CReplayEventManager::HasEventExpired<CPacketRequestCloudHat, void>(CPacketEvent const*, CHistoryPacketController&)')
patch('replay cloud hat', CLOUD, [
    (r'(  var_i1 = i32_load16_u_' + L + r'\([^\n]*48u\)\);\n  var_i0 = var_i0 < var_i1;\n)',
     lambda m: m.group(1) + f'  if (pg_guard_forced(PG_GUARD_CLOUD_HAT)) var_i0 = 0;   /* {MARK} test */\n', 1),
    (r'  UNREACHABLE;\n  var_B3:;\n', f'  var_i0 = pg_guard_cloud_hat(instance, var_l3);   /* {MARK}: expired */\n  var_B3:;\n', 1),
])

# 4. CTorsoVehicleIkSolver::Iterate: three bone index checks against the skeleton's bone count (+32 of var_p2). Return
# with the stack pointer as on entry: the first site is in the 96-byte frame (var_l29), the others in the 240-byte one
# (var_l25).
IK = fn('CTorsoVehicleIkSolver::Iterate(float, rage::crSkeleton&)')
patch('vehicle lean IK', IK, [
    (r'(  var_l41 = var_i0;\n  var_j1 = var_p2;\n  var_i1 = i32_load_' + L + r'\([^\n]*32u\)\);\n  var_i0 = var_i0 >= var_i1;\n)  if \(var_i0\) \{goto var_B21;\}\n',
     lambda m: m.group(1) + f'  if (var_i0 || pg_guard_forced(PG_GUARD_IK)) {{goto var_B21;}}   /* {MARK} */\n', 1),
    (r'  var_B21:;\n  UNREACHABLE;\n', f'  var_B21:;\n  pg_guard_ik(instance, var_p2, 1); instance->w2c_g0 = var_l29 + 96ull; goto var_B0;   /* {MARK}: skip this frame */\n', 1),
    (r'    var_B45:;\n    UNREACHABLE;\n', f'    var_B45:;\n    pg_guard_ik(instance, var_p2, 2); instance->w2c_g0 = var_l25 + 240ull; goto var_B0;   /* {MARK} */\n', 1),
    (r'  var_B38:;\n  UNREACHABLE;\n', f'  var_B38:;\n  pg_guard_ik(instance, var_p2, 3); instance->w2c_g0 = var_l25 + 240ull; goto var_B0;   /* {MARK} */\n', 1),
])

# 5. grmShaderGroup::SetVar(var, texture): no stack frame; the unreachable becomes a plain return.
SHADER = fn('rage::grmShaderGroup::SetVar(rage::__grmShaderGroupVar, rage::grcTexture const*) const')
patch('shader group variable', SHADER, [
    (r'(  var_i0 = var_p1;\n  var_i1 = 1u;\n  var_i0 -= var_i1;\n  var_p1 = var_i0;\n  var_j1 = var_p0;\n  var_i1 = i32_load16_u_' + L + r'\([^\n]*40u\)\);\n  var_i0 = var_i0 >= var_i1;\n)  if \(var_i0\) \{goto var_B0;\}\n',
     lambda m: m.group(1) + f'  if (var_i0 || pg_guard_forced(PG_GUARD_SHADER)) {{goto var_B0;}}   /* {MARK} */\n', 1),
    (r'  var_B0:;\n  UNREACHABLE;\n  var_Bfunc:;\n', f'  var_B0:;\n  pg_guard_shader(instance, var_p0, var_p1);   /* {MARK}: the texture is not set */\n  var_Bfunc:;\n', 1),
])

# 6. pgBase::pgBase: page map checks of chunk var_l1; var_l8 is the address of the current datResource pointer.
PGBASE = fn('rage::pgBase::pgBase()')
patch('page map', PGBASE, [
    (r'  var_B0:;\n  UNREACHABLE;\n', f'  var_B0:;\n  pg_guard_page_map(instance, var_l8, var_l1);   /* {MARK}: name it, then stop */\n  UNREACHABLE;\n', 1),
])

# 7. CFileMgr::MountAudioPacks: each "Unable to find critical archive" error is followed by unreachable.
AUDIO_PACKS = fn('CFileMgr::MountAudioPacks(char const*)')
patch('critical audio archive', AUDIO_PACKS, [
    (r'(  var_j3 = (224|112|16)ull;\n  var_j2 \+= var_j3;\n  w2c_game_f\d+\(instance, var_j0, var_j1, var_j2\);\n)  UNREACHABLE;\n',
     lambda m: m.group(1) + f'  pg_guard_critical_archive(instance, pg_guard_u64(instance, var_l0 + {m.group(2)}ull));   /* {MARK}: name it, then stop */\n  UNREACHABLE;\n', 3),
])
