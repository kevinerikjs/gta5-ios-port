// The simulator, and the Mac app with PG_DEBUG_PORT set: the engine half of the test harness's debug channel (App/DebugChannel.swift serves it,
// Harness/gta.py drives it). PGDebugCommand runs one text command and writes a one-line JSON reply.
// Memory, script globals and the game state are read right away on the calling thread; game commands
// ("native") wait for the next frame of the main script (pg_debug_tick, from pg_asi_script_tick) and run
// there inside a script, the way a Script Hook V mod calls them. The pause menu stops the main script; then
// they run before whichever script still does (the pause menu's own).
#include <ctype.h>
#include <errno.h>
#include <stdarg.h>

static _Atomic uint64_t pg_debug_frames;   // main script frames: whether scripts (and so game commands) run
static _Atomic double pg_debug_main_at;      // when the main script last ran (CLOCK_MONOTONIC ms)
static uint8_t *pg_debug_memory(void) { return (uint8_t *)(void *)env.memory.data; }

typedef struct { char *at; size_t left; } pg_json;
static void pg_json_put(pg_json *j, const char *format, ...) {
  if (j->left < 2) return;
  va_list list; va_start(list, format);
  const int n = vsnprintf(j->at, j->left, format, list);
  va_end(list);
  if (n < 0) return;
  const size_t used = (size_t)n < j->left ? (size_t)n : j->left - 1;
  j->at += used; j->left -= used;
}
// Game text is UTF-8: bytes from 128 pass through, control characters are escaped.
static void pg_json_string(pg_json *j, const char *s, size_t max) {
  pg_json_put(j, "\"");
  for (size_t i = 0; i < max && s[i]; i++) {
    const unsigned char c = (unsigned char)s[i];
    if (c == '"' || c == '\\') pg_json_put(j, "\\%c", c);
    else if (c < 32) pg_json_put(j, "\\u%04x", c);
    else pg_json_put(j, "%c", c);
  }
  pg_json_put(j, "\"");
}
static bool pg_debug_range(uint64_t address, uint64_t length) {
  return address && address <= env.memory.size && length <= env.memory.size - address;
}
static uint64_t pg_debug_global_address(uint64_t index) { return pg_script_global(index); }
static void pg_debug_word(pg_json *j, uint64_t word) {
  float f; memcpy(&f, &word, 4);
  pg_json_put(j, "{\"u\":\"0x%llx\",\"i\":%d,\"f\":%g}", (unsigned long long)word, (int32_t)word, isfinite(f) ? f : 0);
}

// MARK: Game state, read on the calling thread
static void pg_debug_state_json(pg_json *j) {
  const uint8_t *m = pg_debug_memory(); const uint64_t size = env.memory.size;
  pg_json_put(j, "{\"ok\":true,\"status\":%u,\"frames\":%llu,\"context\":%u", PGGameStatus(),
              (unsigned long long)atomic_load(&pg_debug_frames), PGCurrentTouchContext());
  uint64_t info, ped, archetype, vehicle;
  uint32_t model;
  if (pg_context_u64(m, size, 20159720, &info) && info && pg_context_u64(m, size, info + 8, &ped) && ped && ped + 5584 < size) {
    float p[3]; memcpy(p, m + ped + 144, 12);
    pg_json_put(j, ",\"pos\":[%.2f,%.2f,%.2f]", p[0], p[1], p[2]);
    if (pg_context_u64(m, size, ped + 32, &archetype) && archetype && pg_context_u32(m, size, archetype + 24, &model))
      pg_json_put(j, ",\"pedModel\":\"0x%08x\"", model);
    if (PGCurrentTouchContext() && pg_context_u64(m, size, ped + 5576, &vehicle) && vehicle &&
        pg_context_u64(m, size, vehicle + 32, &archetype) && archetype && pg_context_u32(m, size, archetype + 24, &model))
      pg_json_put(j, ",\"vehicleModel\":\"0x%08x\"", model);
  }
  uint8_t help = 0;
  pg_json_put(j, ",\"help\":");
  if (pg_context_u8(m, size, 25477136, &help) && help && size > 25477136 + 600) pg_json_string(j, (const char *)(m + 25477136), 600);
  else pg_json_put(j, "null");
  // Script threads: array at 15409704, count (u16) at 15409712, name at +428 of each.
  pg_json_put(j, ",\"scripts\":[");
  uint64_t threads; uint16_t count = 0; bool first = true;
  if (pg_context_u64(m, size, 15409704, &threads) && threads && pg_context_u16(m, size, 15409712, &count)) {
    for (uint16_t i = 0; i < count && i < 512; i++) {
      uint64_t thread;
      if (!pg_context_u64(m, size, threads + 8ull * i, &thread) || !thread || thread + 492 > size) continue;
      // Unused slots keep bits of old names: only names of letters, digits and _, two or more.
      const char *name = (const char *)(m + thread + 428); size_t n = 0;
      while (n < 64 && (isalnum((unsigned char)name[n]) || name[n] == '_')) n++;
      if (n < 2 || name[n]) continue;
      pg_json_put(j, first ? "" : ","); first = false;
      pg_json_string(j, (const char *)(m + thread + 428), 64);
    }
  }
  pg_json_put(j, "]}");
}

// MARK: Game commands, run on the game thread
static pthread_mutex_t pg_debug_caller = PTHREAD_MUTEX_INITIALIZER;   // one request in flight
static pthread_mutex_t pg_debug_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t pg_debug_answered = PTHREAD_COND_INITIALIZER;
static char pg_debug_request[16384];
static pg_json pg_debug_out;
static int pg_debug_state;   // 0 idle, 1 waiting for the game thread, 2 answered
static _Atomic bool pg_debug_pending;

static int pg_debug_hex(char c) { return c >= '0' && c <= '9' ? c - '0' : (c | 32) >= 'a' && (c | 32) <= 'f' ? (c | 32) - 'a' + 10 : -1; }
// "native <hash> [args]": i:N (or a plain number), f:X, b:0/1, u:N (a raw word), s:text (%20 for a space,
// %XX any byte), p:N (an out-parameter of N zeroed words, returned after the call), r:K (the result of the
// batch's command K, counting from 0). Strings and out-parameters live until the end of the frame's batch,
// so BEGIN_TEXT_COMMAND...END_TEXT_COMMAND can share one.
static void pg_debug_native(char *line, pg_json *j, uint64_t *allocated, int *allocations, uint64_t *results, int index) {
  char *save = NULL;
  strtok_r(line, " ", &save);
  const char *hashText = strtok_r(NULL, " ", &save);
  const uint64_t hash = hashText ? strtoull(hashText, NULL, 16) : 0;
  uint64_t arguments[32]; int count = 0;
  struct { uint64_t address; int words; } outs[8]; int outCount = 0;
  for (char *token; (token = strtok_r(NULL, " ", &save)) && count < 32;) {
    const char kind = token[1] == ':' ? token[0] : 'i';
    const char *value = token[1] == ':' ? token + 2 : token;
    uint64_t word = 0;
    if (kind == 'f') { const float f = strtof(value, NULL); memcpy(&word, &f, 4); }
    else if (kind == 's' && *allocations < 32) {
      char text[1024]; size_t n = 0;
      for (const char *c = value; *c && n < sizeof text - 1; c++) {
        if (*c == '%' && pg_debug_hex(c[1]) >= 0 && pg_debug_hex(c[2]) >= 0) { text[n++] = (char)(pg_debug_hex(c[1]) * 16 + pg_debug_hex(c[2])); c += 2; }
        else text[n++] = *c;
      }
      text[n] = 0;
      word = pg_asi_alloc(n + 1); memcpy(pg_pointer(&env, word, n + 1), text, n + 1);
      allocated[(*allocations)++] = word;
    } else if (kind == 'p' && *allocations < 32 && outCount < 8) {
      const int words = atoi(value) < 1 ? 1 : atoi(value) > 32 ? 32 : atoi(value);
      word = pg_asi_alloc(8ull * words); memset(pg_pointer(&env, word, 8ull * words), 0, 8ull * words);
      allocated[(*allocations)++] = word;
      outs[outCount].address = word; outs[outCount++].words = words;
    } else if (kind == 'r') { const int k = atoi(value); word = k >= 0 && k < index ? results[k] : 0; }
    else if (kind == 'u') word = strtoull(value, NULL, 0);
    else word = (uint64_t)strtoll(value, NULL, 0);
    arguments[count++] = word;
  }
  static uint64_t buffer;   // arguments, then the result words from +8 * 32
  if (!buffer) buffer = pg_asi_alloc(8 * 40);
  if (count) memcpy(pg_pointer(&env, buffer, 8ull * count), arguments, 8ull * count);
  memset(pg_pointer(&env, buffer + 8 * 32, 64), 0, 64);
  if (!pg_asi_native(hash, buffer, (uint32_t)count, buffer + 8 * 32)) {
    pg_json_put(j, "{\"ok\":false,\"error\":\"unknown native 0x%016llx\"}", (unsigned long long)hash);
    return;
  }
  const uint64_t *result = pg_pointer(&env, buffer + 8 * 32, 24);
  results[index] = result[0];
  pg_json_put(j, "{\"ok\":true,\"r\":");
  pg_debug_word(j, result[0]);
  float v[3]; for (int i = 0; i < 3; i++) memcpy(&v[i], &result[i], 4);
  pg_json_put(j, ",\"v\":[%g,%g,%g]", isfinite(v[0]) ? v[0] : 0, isfinite(v[1]) ? v[1] : 0, isfinite(v[2]) ? v[2] : 0);
  // A result that points at text (GET_LABEL_TEXT, GET_THIS_SCRIPT_NAME): the text too.
  if (result[0] > 65536 && pg_debug_range(result[0], 256)) {
    const char *text = (const char *)pg_debug_memory() + result[0];
    size_t n = 0; while (n < 256 && text[n] && ((unsigned char)text[n] >= 32 || text[n] == '\n')) n++;
    if (n && n < 256 && !text[n]) { pg_json_put(j, ",\"s\":"); pg_json_string(j, text, n); }
  }
  if (outCount) {
    pg_json_put(j, ",\"out\":[");
    for (int o = 0; o < outCount; o++) {
      pg_json_put(j, o ? ",[" : "[");
      const uint64_t *words = pg_pointer(&env, outs[o].address, 8ull * outs[o].words);
      for (int w = 0; w < outs[o].words; w++) { pg_json_put(j, w ? "," : ""); pg_debug_word(j, words[w]); }
      pg_json_put(j, "]");
    }
    pg_json_put(j, "]");
  }
  pg_json_put(j, "}");
}
static void pg_debug_tick(w2c_game *instance, bool mainScript) {
  if (mainScript) { atomic_fetch_add(&pg_debug_frames, 1); atomic_store(&pg_debug_main_at, timeMS(CLOCK_MONOTONIC)); }
  if (!atomic_load(&pg_debug_pending)) return;
  if (!mainScript && timeMS(CLOCK_MONOTONIC) - atomic_load(&pg_debug_main_at) < 300) return;
  pthread_mutex_lock(&pg_debug_lock);
  if (pg_debug_state == 1) {
    pg_asi_game = instance;
    const uint64_t previous = pg_asi_enter_script(instance);
    uint64_t allocated[32], results[64] = {0}; int allocations = 0, index = 0;
    pg_json_put(&pg_debug_out, "{\"ok\":true,\"results\":[");
    char *save = NULL; bool first = true;
    for (char *command = strtok_r(pg_debug_request, ";", &save); command && index < 64; command = strtok_r(NULL, ";", &save), index++) {
      while (*command == ' ') command++;
      if (!*command) continue;
      pg_json_put(&pg_debug_out, first ? "" : ","); first = false;
      if (!strncmp(command, "native ", 7)) pg_debug_native(command, &pg_debug_out, allocated, &allocations, results, index);
#if TARGET_OS_SIMULATOR
      // trap: an engine trap on the game thread, where script mods' commands run, to test the trap log's function
      // names and the stop panel (GTA-178). The game stops.
      else if (!strcmp(command, "trap")) { pg_log("TEST: trap on the game thread"); wasm_rt_trap(WASM_RT_TRAP_UNREACHABLE); }
#endif
      else { pg_json_put(&pg_debug_out, "{\"ok\":false,\"error\":"); pg_json_string(&pg_debug_out, command, 80); pg_json_put(&pg_debug_out, "}"); }
    }
    pg_json_put(&pg_debug_out, "]}");
    for (int i = 0; i < allocations; i++) pg_asi_free(allocated[i]);
    pg_asi_leave_script(instance, previous);
    pg_debug_state = 2;
    pthread_cond_signal(&pg_debug_answered);
  }
  pthread_mutex_unlock(&pg_debug_lock);
}
static void pg_debug_on_game_thread(const char *command, pg_json *j) {
  pthread_mutex_lock(&pg_debug_caller);
  pthread_mutex_lock(&pg_debug_lock);
  snprintf(pg_debug_request, sizeof pg_debug_request, "%s", command);
  pg_debug_out = *j;
  pg_debug_state = 1;
  atomic_store(&pg_debug_pending, true);
  struct timespec until; clock_gettime(CLOCK_REALTIME, &until); until.tv_sec += 10;
  while (pg_debug_state == 1 && pthread_cond_timedwait(&pg_debug_answered, &pg_debug_lock, &until) != ETIMEDOUT) {}
  const bool answered = pg_debug_state == 2;
  if (answered) *j = pg_debug_out;
  pg_debug_state = 0;
  atomic_store(&pg_debug_pending, false);
  pthread_mutex_unlock(&pg_debug_lock);
  pthread_mutex_unlock(&pg_debug_caller);
  if (!answered) pg_json_put(j, "{\"ok\":false,\"error\":\"the main script didn't run for 10 s (loading or paused)\"}");
}

// MARK: Commands
void PGDebugCommand(const char *command, char *reply, size_t size) {
  pg_json j = {reply, size};
  reply[0] = 0;
  char word[16] = ""; sscanf(command, "%15s", word);
  const char *rest = command + strlen(word);
  if (!atomic_load(&inputBlock) && strcmp(word, "ping") && strcmp(word, "pgo") && strcmp(word, "burst")) { pg_json_put(&j, "{\"ok\":false,\"error\":\"the engine isn't running yet\"}"); return; }
  if (!strcmp(word, "ping")) {
    pg_json_put(&j, "{\"ok\":true,\"engine\":%s,\"frames\":%llu}", atomic_load(&inputBlock) ? "true" : "false", (unsigned long long)atomic_load(&pg_debug_frames));
  } else if (!strcmp(word, "burst")) {
    // burst <name> <frames>: the next frames as Documents/NativeFrames/<name>-NNN.png (GTA-176 flicker measurements).
    extern void PGMetalRendererBurst(const char *name, int frames);
    char name[128] = ""; int frames = 0;
    sscanf(rest, "%127s %d", name, &frames);
    if (!name[0] || frames <= 0) { pg_json_put(&j, "{\"ok\":false,\"error\":\"burst <name> <frames up to 300>\"}"); return; }
    PGMetalRendererBurst(name, frames);
    pg_json_put(&j, "{\"ok\":true}");
  } else if (!strcmp(word, "pgo")) {
    // pgo: an instrumented build (-fprofile-instr-generate, GTA-172) writes its profile to LLVM_PROFILE_FILE now.
    // A simulator run ends by killing the app, so the profile runtime's own write at exit never comes.
#ifdef __LLVM_INSTR_PROFILE_GENERATE
    extern int __llvm_profile_write_file(void);	// compiler-rt's, hidden: called directly, not through dlsym
    pg_json_put(&j, "{\"ok\":%s}", __llvm_profile_write_file() ? "false" : "true");
#else
    pg_json_put(&j, "{\"ok\":false,\"error\":\"not an instrumented build\"}");
#endif
  } else if (!strcmp(word, "state")) {
    pg_debug_state_json(&j);
  } else if (!strcmp(word, "audiodump")) {
    // audiodump <path> <seconds>: the next seconds of the game's sound into a file (see PGFillAudio)
    char path[1024] = ""; double seconds = 0;
    sscanf(rest, "%1023s %lf", path, &seconds);
    if (pg_audio_dump || !path[0] || seconds <= 0 || seconds > 120 || !(pg_audio_dump = fopen(path, "wb"))) { pg_json_put(&j, "{\"ok\":false,\"error\":\"audiodump <path> <seconds up to 120>, one at a time\"}"); return; }
    atomic_store(&pg_audio_dump_frames, (int64_t)(seconds * 48000));
    pg_json_put(&j, "{\"ok\":true}");
  } else if (!strcmp(word, "native") || !strcmp(word, "trap")) {
    pg_debug_on_game_thread(command, &j);
  } else if (!strcmp(word, "peek")) {
    // peek <address> <length>: the bytes as hex
    unsigned long long address = 0, length = 0;
    sscanf(rest, "%lli %lli", &address, &length);
    if (length > 65536 || !pg_debug_range(address, length)) { pg_json_put(&j, "{\"ok\":false,\"error\":\"out of range\"}"); return; }
    pg_json_put(&j, "{\"ok\":true,\"hex\":\"");
    for (uint64_t i = 0; i < length; i++) pg_json_put(&j, "%02x", pg_debug_memory()[address + i]);
    pg_json_put(&j, "\"}");
  } else if (!strcmp(word, "poke")) {
    // poke <address> <hex bytes>
    unsigned long long address = 0; char hex[8192] = "";
    sscanf(rest, "%lli %8191s", &address, hex);
    const size_t length = strlen(hex) / 2;
    if (!length || !pg_debug_range(address, length)) { pg_json_put(&j, "{\"ok\":false,\"error\":\"out of range\"}"); return; }
    uint8_t *to = pg_debug_memory() + address;
    for (size_t i = 0; i < length; i++) to[i] = (uint8_t)(pg_debug_hex(hex[2 * i]) * 16 + pg_debug_hex(hex[2 * i + 1]));
    pg_json_put(&j, "{\"ok\":true,\"bytes\":%zu}", length);
  } else if (!strcmp(word, "gget")) {
    // gget <index> [count]: script globals
    unsigned long long index = 0, count = 1;
    sscanf(rest, "%lli %lli", &index, &count);
    if (count > 4096) count = 4096;
    pg_json_put(&j, "{\"ok\":true,\"index\":%llu,\"values\":[", index);
    for (uint64_t i = 0; i < count; i++) {
      const uint64_t address = pg_debug_global_address(index + i);
      pg_json_put(&j, i ? "," : "");
      if (address) { uint64_t value; memcpy(&value, pg_debug_memory() + address, 8); pg_debug_word(&j, value); }
      else pg_json_put(&j, "null");
    }
    pg_json_put(&j, "]}");
  } else if (!strcmp(word, "hud")) {
    // hud <piece> <dx> <dy> <scale>: a HUD layout piece's place now (GTA-197; the wheel and the phone apply at once).
    int piece = -1; double dx = 0, dy = 0, scale = 1;
    if (sscanf(rest, "%d %lf %lf %lf", &piece, &dx, &dy, &scale) < 3 || piece < 0 || piece > 5) { pg_json_put(&j, "{\"ok\":false,\"error\":\"hud <piece 0-5> <dx> <dy> [scale]\"}"); return; }
    PGSetHudPiece(piece, dx, dy, scale);
    pg_json_put(&j, "{\"ok\":true}");
  } else if (!strcmp(word, "gset")) {
    // gset <index> <value>: i:N (or a number), f:X, u:N
    unsigned long long index = 0; char value[64] = "";
    sscanf(rest, "%lli %63s", &index, value);
    const uint64_t address = pg_debug_global_address(index);
    if (!address || !value[0]) { pg_json_put(&j, "{\"ok\":false,\"error\":\"no such global\"}"); return; }
    uint64_t word = 0;
    if (value[0] == 'f' && value[1] == ':') { const float f = strtof(value + 2, NULL); memcpy(&word, &f, 4); }
    else if (value[0] == 'u' && value[1] == ':') word = strtoull(value + 2, NULL, 0);
    else word = (uint64_t)strtoll(value[1] == ':' ? value + 2 : value, NULL, 0);
    memcpy(pg_debug_memory() + address, &word, 8);
    pg_json_put(&j, "{\"ok\":true,\"address\":%llu}", (unsigned long long)address);
  } else {
    pg_json_put(&j, "{\"ok\":false,\"error\":\"unknown command\"}");
  }
}
