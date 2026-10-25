// CPU time per thread, for the Health line (GTA-162). The Health line has one CPU number for the whole app, and
// a hot phone can't say which part of the game heats it: the engine's main thread, its workers (audio, streaming,
// physics), the Metal renderer, file reads or iOS's own audio output. Each call reports the cores every group of
// threads used since the last call, heaviest first. Threads are grouped by name without trailing numbers
// ("gta.asset.read.3" counts as "gta.asset.read"); the engine's threads carry the names the game gives them
// (NativeThreads.c).
#include "EngineHost.h"
#include <mach/mach.h>
#include <pthread.h>
#include <stdio.h>
#include <string.h>
#include <time.h>

enum { MAX_THREADS = 512, MAX_GROUPS = 48, NAME = 48 };
typedef struct { uint64_t id, micros; } Seen;
typedef struct { char name[NAME]; uint64_t micros; unsigned threads; } Group;
static Seen seen[MAX_THREADS];
static unsigned seenCount;
static double lastWall;

// iOS has no pthread_main_thread_np; constructors run on the main thread at launch.
static pthread_t mainThread;
__attribute__((constructor)) static void rememberMainThread(void) { mainThread = pthread_self(); }

static double wallSeconds(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return t.tv_sec + t.tv_nsec / 1e9; }

static void groupName(thread_t port, char *out) {
  out[0] = 0;
  pthread_t thread = pthread_from_mach_thread_np(port);
  if (thread) {
    if (mainThread && pthread_equal(thread, mainThread)) { strcpy(out, "main (UI)"); return; }
    pthread_getname_np(thread, out, NAME);
  }
  size_t n = strlen(out);
  while (n && ((out[n - 1] >= '0' && out[n - 1] <= '9') || strchr(" ._-#:", out[n - 1]))) out[--n] = 0;
  if (!n) strcpy(out, "unnamed");
}

static void startProfiler(void);

size_t PGThreadCPU(char *out, size_t size) {
  if (!size) return 0;
  static int profiling;
  if (!profiling) { profiling = 1; startProfiler(); }
  out[0] = 0;
  thread_act_array_t list; mach_msg_type_number_t count;
  if (task_threads(mach_task_self(), &list, &count) != KERN_SUCCESS) return 0;
  static Seen now[MAX_THREADS];
  Group groups[MAX_GROUPS]; unsigned groupCount = 0, nowCount = 0;
  uint64_t total = 0;
  for (mach_msg_type_number_t i = 0; i < count; i++) {
    thread_identifier_info_data_t ident; mach_msg_type_number_t identCount = THREAD_IDENTIFIER_INFO_COUNT;
    thread_basic_info_data_t basic; mach_msg_type_number_t basicCount = THREAD_BASIC_INFO_COUNT;
    if (thread_info(list[i], THREAD_IDENTIFIER_INFO, (thread_info_t)&ident, &identCount) == KERN_SUCCESS &&
        thread_info(list[i], THREAD_BASIC_INFO, (thread_info_t)&basic, &basicCount) == KERN_SUCCESS && nowCount < MAX_THREADS) {
      uint64_t micros = (uint64_t)(basic.user_time.seconds + basic.system_time.seconds) * 1000000 + basic.user_time.microseconds + basic.system_time.microseconds;
      now[nowCount++] = (Seen){ident.thread_id, micros};
      // A thread seen last time counts what it used since; a new one counts all of its time (it started in between).
      uint64_t used = micros;
      for (unsigned j = 0; j < seenCount; j++) if (seen[j].id == ident.thread_id) { used = micros >= seen[j].micros ? micros - seen[j].micros : 0; break; }
      char name[NAME]; groupName(list[i], name);
      unsigned g = 0;
      while (g < groupCount && strcmp(groups[g].name, name)) g++;
      if (g == groupCount && groupCount < MAX_GROUPS) { groups[groupCount] = (Group){.micros = 0, .threads = 0}; strcpy(groups[groupCount].name, name); groupCount++; }
      if (g < groupCount) { groups[g].micros += used; groups[g].threads++; }
      total += used;
    }
    mach_port_deallocate(mach_task_self(), list[i]);
  }
  vm_deallocate(mach_task_self(), (vm_address_t)list, count * sizeof(thread_t));
  double wall = wallSeconds(), elapsed = wall - lastWall;
  int first = seenCount == 0;
  memcpy(seen, now, nowCount * sizeof(Seen)); seenCount = nowCount; lastWall = wall;
  if (first || elapsed <= 0.5) return 0;	// the first call only takes the starting point
  // Heaviest first; groups under 0.02 cores go into "other".
  for (unsigned a = 0; a < groupCount; a++)
    for (unsigned b = a + 1; b < groupCount; b++)
      if (groups[b].micros > groups[a].micros) { Group t = groups[a]; groups[a] = groups[b]; groups[b] = t; }
  size_t used = (size_t)snprintf(out, size, "Threads (CPU cores): total %.2f", total / 1e6 / elapsed);
  uint64_t other = 0;
  for (unsigned g = 0; g < groupCount; g++) {
    double cores = groups[g].micros / 1e6 / elapsed;
    if (cores < 0.02 || used >= size) { other += groups[g].micros; continue; }
    if (groups[g].threads > 1) used += (size_t)snprintf(out + used, size - used, " · %s ×%u %.2f", groups[g].name, groups[g].threads, cores);
    else used += (size_t)snprintf(out + used, size - used, " · %s %.2f", groups[g].name, cores);
  }
  if (other && used < size) used += (size_t)snprintf(out + used, size - used, " · other %.2f", other / 1e6 / elapsed);
  return used < size ? used : size - 1;
}

// Where those threads spend their time (GTA-169: heat). The Threads line says which threads use the cores; this
// says which functions inside them. A sampling profiler inside the app, because Instruments needs the developer
// mode of the Mac it runs on and a phone has none: a thread wakes PG_PROFILE_HZ times a second (100), pauses each
// chosen thread that is running (not waiting) for a few microseconds, reads its program counter and walks its frame
// pointers, so the shares are of the time a thread works. Every
// PG_PROFILE_REPORT seconds (300) the log gets the hottest functions of each chosen group, by their own time
// (with the call they mostly come from) and with what they call, counted from the start; the full table goes to
// Library/Caches/thread-profile.txt for atos. Off unless PG_PROFILE (environment) or PGProfileThreads (Info.plist)
// lists thread names to sample, comma-separated, matched as pieces of the names in the Threads line. Releases
// from v1.4.7 list the engine's busy threads, so player logs show where each phone model's CPU goes.
#if defined(__arm64__)
#include <CoreFoundation/CoreFoundation.h>
#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <mach-o/nlist.h>
extern void pg_log(const char *line);
#include <stdlib.h>

enum { PROFILE_GROUPS = 8, PROFILE_TARGETS = 64, PROFILE_SLOTS = 1 << 16, PROFILE_DEPTH = 48, PROFILE_TOP = 12 };
// A slot counts one address of one group; a caller slot (group + CALLER) counts one leaf address called from one place.
typedef struct { uintptr_t pc, caller, start; uint32_t self, in; uint8_t group, used; } Slot;	// start: the function, once looked up
enum { CALLER = 0x80 };
typedef struct { thread_t port; uintptr_t low, high; uint8_t group; } Target;
static Slot slots[PROFILE_SLOTS];
static unsigned slotsUsed;
static uint64_t groupSamples[PROFILE_GROUPS], groupTries[PROFILE_GROUPS], droppedSamples;
static char profileNames[PROFILE_GROUPS][NAME];
static unsigned profileCount;
static Target targets[PROFILE_TARGETS];
static unsigned targetCount;

static Slot *slotFor(uintptr_t pc, uintptr_t caller, uint8_t group) {
  uint32_t i = (uint32_t)((((pc ^ caller * 31) >> 2) * 0x9E3779B97F4A7C15ull) >> 40 ^ group) & (PROFILE_SLOTS - 1);
  while (slots[i].used && (slots[i].pc != pc || slots[i].caller != caller || slots[i].group != group)) i = (i + 1) & (PROFILE_SLOTS - 1);
  if (!slots[i].used) {
    if (slotsUsed >= PROFILE_SLOTS * 3 / 4) return NULL;
    slots[i] = (Slot){.pc = pc, .caller = caller, .group = group, .used = 1}; slotsUsed++;
  }
  return &slots[i];
}

// Which threads to sample, again every second: threads come and go. No thread is paused while this runs, so the
// locks pthread takes here can't be held by a paused thread.
static void findTargets(void) {
  for (unsigned i = 0; i < targetCount; i++) mach_port_deallocate(mach_task_self(), targets[i].port);
  targetCount = 0;
  thread_act_array_t list; mach_msg_type_number_t count;
  if (task_threads(mach_task_self(), &list, &count) != KERN_SUCCESS) return;
  thread_t self = mach_thread_self();
  for (mach_msg_type_number_t i = 0; i < count; i++) {
    int keep = 0;
    if (list[i] != self && targetCount < PROFILE_TARGETS) {
      char name[NAME]; groupName(list[i], name);
      pthread_t thread = pthread_from_mach_thread_np(list[i]);
      for (unsigned g = 0; g < profileCount && !keep && thread; g++)
        if (strstr(name, profileNames[g])) {
          uintptr_t high = (uintptr_t)pthread_get_stackaddr_np(thread);
          targets[targetCount++] = (Target){list[i], high - pthread_get_stacksize_np(thread), high, (uint8_t)g};
          keep = 1;
        }
    }
    if (!keep) mach_port_deallocate(mach_task_self(), list[i]);
  }
  mach_port_deallocate(mach_task_self(), self);
  vm_deallocate(mach_task_self(), (vm_address_t)list, count * sizeof(thread_t));
}

// On iPhones from the A12 on, the system libraries sign the return addresses they save (pointer authentication):
// the signature sits in the address's top bits. XPACLRI takes it off the address in x30; it is a hint instruction,
// so CPUs without pointer authentication run it as a no-op.
static uintptr_t unsigned_address(uintptr_t address) {
  register uintptr_t x30 __asm__("x30") = address;
  __asm__("hint #7" : "+r"(x30));	// XPACLRI
  return x30;
}

// While the thread is paused nothing here may take a lock or allocate: the paused thread could hold it.
static void sample(const Target *t) {
  groupTries[t->group]++;
  thread_basic_info_data_t basic; mach_msg_type_number_t basicCount = THREAD_BASIC_INFO_COUNT;
  if (thread_info(t->port, THREAD_BASIC_INFO, (thread_info_t)&basic, &basicCount) != KERN_SUCCESS || basic.run_state != TH_STATE_RUNNING) return;
  if (thread_suspend(t->port) != KERN_SUCCESS) return;
  arm_thread_state64_t state; mach_msg_type_number_t n = ARM_THREAD_STATE64_COUNT;
  uintptr_t frames[PROFILE_DEPTH]; unsigned depth = 0;
  if (thread_get_state(t->port, ARM_THREAD_STATE64, (thread_state_t)&state, &n) == KERN_SUCCESS) {
    frames[depth++] = unsigned_address((uintptr_t)arm_thread_state64_get_pc(state));
    uintptr_t fp = (uintptr_t)arm_thread_state64_get_fp(state);
    // Each frame record is {caller's frame pointer, return address}, higher on the stack than the last.
    while (depth < PROFILE_DEPTH && fp >= t->low && fp + 16 <= t->high && !(fp & 7)) {
      uintptr_t next = ((uintptr_t *)fp)[0], ret = unsigned_address(((uintptr_t *)fp)[1]);
      if (!ret) break;
      frames[depth++] = ret - 4;	// the call, not the instruction after it
      if (next <= fp) break;
      fp = next;
    }
  }
  thread_resume(t->port);
  if (!depth) return;
  groupSamples[t->group]++;
  Slot *leaf = slotFor(frames[0], 0, t->group);
  if (!leaf) { droppedSamples++; return; }
  leaf->self++;
  Slot *edge = depth > 1 ? slotFor(frames[0], frames[1], t->group | CALLER) : NULL;
  if (edge) edge->self++;
  for (unsigned i = 0; i < depth; i++) {
    unsigned j = 0;
    while (j < i && frames[j] != frames[i]) j++;	// a function on the stack twice (recursion) counts once
    Slot *s = j == i ? slotFor(frames[i], 0, t->group) : NULL;
    if (s) s->in++;
  }
}

// The functions behind the sampled addresses. The app's own functions come from its symbol table, read once and
// sorted (dladdr searches all 160,000 symbols for each address: a report took 6 s of CPU); the system libraries'
// few addresses go to dladdr.
typedef struct { uintptr_t start; const char *name; } Symbol;
static Symbol *symbols;
static unsigned symbolCount;
static uintptr_t appLow, appHigh;
static const char *appPath = "?";
static int byStart(const void *a, const void *b) { uintptr_t x = ((const Symbol *)a)->start, y = ((const Symbol *)b)->start; return x < y ? -1 : x > y; }

static void loadSymbols(void) {
  Dl_info self;
  if (!dladdr((const void *)loadSymbols, &self)) return;
  const struct mach_header_64 *header = self.dli_fbase;
  if (self.dli_fname) appPath = self.dli_fname;
  intptr_t slide = 0;
  for (uint32_t i = 0; i < _dyld_image_count(); i++) if (_dyld_get_image_header(i) == (const void *)header) slide = _dyld_get_image_vmaddr_slide(i);
  const struct segment_command_64 *linkedit = NULL, *text = NULL; const struct symtab_command *table = NULL;
  const struct load_command *command = (const void *)(header + 1);
  for (uint32_t i = 0; i < header->ncmds; i++, command = (const void *)((const char *)command + command->cmdsize)) {
    if (command->cmd == LC_SEGMENT_64) {
      const struct segment_command_64 *segment = (const void *)command;
      if (!strcmp(segment->segname, SEG_LINKEDIT)) linkedit = segment;
      if (!strcmp(segment->segname, SEG_TEXT)) text = segment;
    } else if (command->cmd == LC_SYMTAB) table = (const void *)command;
  }
  if (!linkedit || !text || !table || !(symbols = malloc(table->nsyms * sizeof(Symbol)))) return;
  uintptr_t base = (uintptr_t)slide + linkedit->vmaddr - linkedit->fileoff;
  const struct nlist_64 *list = (const void *)(base + table->symoff);
  const char *strings = (const char *)(base + table->stroff);
  for (uint32_t i = 0; i < table->nsyms; i++) {
    if (list[i].n_type & N_STAB || (list[i].n_type & N_TYPE) != N_SECT || list[i].n_sect != 1) continue;	// functions: section 1 is __text
    const char *name = strings + list[i].n_un.n_strx;
    symbols[symbolCount++] = (Symbol){(uintptr_t)list[i].n_value + (uintptr_t)slide, name[0] == '_' ? name + 1 : name};
  }
  qsort(symbols, symbolCount, sizeof(Symbol), byStart);
  appLow = (uintptr_t)header; appHigh = (uintptr_t)slide + text->vmaddr + text->vmsize;
}

static pthread_once_t symbolsOnce = PTHREAD_ONCE_INIT;
// The app function an address is in (NULL outside the app), for the trap log too (GTA-178).
const char *pg_app_symbol(uintptr_t pc);

static const Symbol *symbolAt(uintptr_t pc) {
  if (pc < appLow || pc >= appHigh || !symbolCount) return NULL;
  unsigned low = 0, high = symbolCount;
  while (high - low > 1) { unsigned mid = (low + high) / 2; if (symbols[mid].start <= pc) low = mid; else high = mid; }
  return symbols[low].start <= pc ? &symbols[low] : NULL;
}

const char *pg_app_symbol(uintptr_t pc) {
  pthread_once(&symbolsOnce, loadSymbols);
  const Symbol *symbol = symbolAt(pc);
  return symbol ? symbol->name : NULL;
}

typedef struct { uintptr_t start; const char *name, *image; uint64_t self, in; uintptr_t caller; uint64_t fromCaller; } Function;

// The function an address is in: its start and name. System libraries go to dladdr, at most *budget times.
static uintptr_t functionAt(uintptr_t pc, const char **name, const char **image, unsigned *budget) {
  *name = NULL; *image = "?";
  const Symbol *symbol = symbolAt(pc);
  if (symbol) { *name = symbol->name; *image = "app"; return symbol->start; }
  Dl_info info;
  if (*budget && (*budget)-- && dladdr((void *)pc, &info)) {
    if (info.dli_fname) { *image = strrchr(info.dli_fname, '/'); *image = *image ? *image + 1 : info.dli_fname; }
    if (info.dli_saddr) { *name = info.dli_sname; return (uintptr_t)info.dli_saddr; }
  }
  return pc;
}
static const char *shortName(const char *name) {
  if (!name) return "?";
  return strncmp(name, "w2c_game_", 9) ? name : name + 9;	// f12345: Scripts/engine_names.py names it
}
static int bySelf(const void *a, const void *b) { uint64_t x = ((const Function *)a)->self, y = ((const Function *)b)->self; return x < y ? 1 : x > y ? -1 : 0; }
static int byIn(const void *a, const void *b) { uint64_t x = ((const Function *)a)->in, y = ((const Function *)b)->in; return x < y ? 1 : x > y ? -1 : 0; }
static int slotBySelf(const void *a, const void *b) { const Slot *x = *(Slot *const *)a, *y = *(Slot *const *)b; return (int)(y->self + y->in) - (int)(x->self + x->in); }

static void report(double seconds) {
  static Slot *busy[PROFILE_SLOTS];
  static Function functions[2048];
  pthread_once(&symbolsOnce, loadSymbols);
  for (unsigned g = 0; g < profileCount; g++) {
    if (!groupSamples[g]) continue;
    unsigned count = 0;
    for (unsigned i = 0; i < PROFILE_SLOTS; i++) if (slots[i].used && slots[i].group == g) busy[count++] = &slots[i];
    qsort(busy, count, sizeof busy[0], slotBySelf);
    unsigned functionCount = 0, budget = 200;
    for (unsigned i = 0; i < count; i++) {
      const char *name, *image;
      uintptr_t start = busy[i]->start = functionAt(busy[i]->pc, &name, &image, &budget);
      unsigned f = 0;
      while (f < functionCount && functions[f].start != start) f++;
      if (f == functionCount) { if (functionCount == 2048) continue; functions[functionCount++] = (Function){start, name, image, 0, 0, 0, 0}; }
      functions[f].self += busy[i]->self; functions[f].in += busy[i]->in;
    }
    // Each function's busiest call site, from the caller slots.
    for (unsigned i = 0; i < PROFILE_SLOTS; i++) {
      if (!slots[i].used || slots[i].group != (g | CALLER)) continue;
      const Slot *leaf = slotFor(slots[i].pc, 0, (uint8_t)g);	// there since the same sample counted it
      uintptr_t start = leaf ? leaf->start : 0;
      for (unsigned f = 0; start && f < functionCount; f++)
        if (functions[f].start == start) {
          if (slots[i].self > functions[f].fromCaller) { functions[f].fromCaller = slots[i].self; functions[f].caller = slots[i].caller; }
          break;
        }
    }
    char line[1400]; size_t used;
    for (int kind = 0; kind < 2; kind++) {
      qsort(functions, functionCount, sizeof functions[0], kind ? byIn : bySelf);
      used = (size_t)snprintf(line, sizeof line, "Profile %s, %s (%llu samples while running, %.0f%% of %.0f s):", profileNames[g],
                              kind ? "with what it calls" : "own time", (unsigned long long)groupSamples[g],
                              groupSamples[g] * 100.0 / (groupTries[g] ? groupTries[g] : 1), seconds);
      for (unsigned f = 0, shown = 0; f < functionCount && shown < PROFILE_TOP && used < sizeof line; f++) {
        uint64_t n = kind ? functions[f].in : functions[f].self;
        if (n * 100 < groupSamples[g]) break;	// under 1%
        if (kind && n * 100 >= groupSamples[g] * 98) continue;	// the thread's own start: in every sample, says nothing
        shown++;
        used += (size_t)snprintf(line + used, sizeof line - used, " · %s %.0f%%", shortName(functions[f].name), n * 100.0 / groupSamples[g]);
        if (!kind && functions[f].caller && used < sizeof line) {
          const char *caller, *image; unsigned one = 1;
          functionAt(functions[f].caller, &caller, &image, &one);
          used += (size_t)snprintf(line + used, sizeof line - used, " (%.0f%% from %s)", functions[f].fromCaller * 100.0 / (functions[f].self ? functions[f].self : 1), shortName(caller));
        }
      }
      pg_log(line);
    }
  }
  // The whole table, as addresses in each image, for atos (the simulator's container keeps it).
  const char *home = getenv("HOME");
  char path[1024]; snprintf(path, sizeof path, "%s/Library/Caches/thread-profile.txt", home ? home : "/tmp");
  FILE *file = fopen(path, "w");
  if (!file) return;
  fprintf(file, "# group\timage\taddress in image\town\twith calls\t(%.0f s, %llu dropped)\n", seconds, (unsigned long long)droppedSamples);
  for (unsigned i = 0; i < PROFILE_SLOTS; i++) {
    if (!slots[i].used || slots[i].group & CALLER) continue;
    Dl_info info; uintptr_t base = 0; const char *image = "?";
    if (slots[i].pc >= appLow && slots[i].pc < appHigh) { base = appLow; image = appPath; }
    else if (dladdr((void *)slots[i].pc, &info) && info.dli_fbase) { base = (uintptr_t)info.dli_fbase; image = info.dli_fname; }
    fprintf(file, "%s\t%s\t0x%lx\t%u\t%u\n", profileNames[slots[i].group], image, (unsigned long)(slots[i].pc - base), slots[i].self, slots[i].in);
  }
  fclose(file);
}

static void *profiler(void *unused) {
  (void)unused;
  pthread_setname_np("gta.profiler");
  const char *value = getenv("PG_PROFILE_HZ");
  double hz = value ? atof(value) : 100; if (!(hz >= 10 && hz <= 2000)) hz = 100;
  value = getenv("PG_PROFILE_REPORT");
  double every = value ? atof(value) : 300; if (!(every >= 5)) every = 300;
  struct timespec wait = {0, (long)(1e9 / hz)};
  double start = wallSeconds(), lastFind = 0, lastReport = start;
  char line[256]; snprintf(line, sizeof line, "Profile: sampling %u thread groups %.0f times a second (GTA-169)", profileCount, hz); pg_log(line);
  for (;;) {
    double now = wallSeconds();
    if (now - lastFind >= 1) { findTargets(); lastFind = now; }
    if (now - lastReport >= every) { report(now - start); lastReport = now; }
    for (unsigned i = 0; i < targetCount; i++) sample(&targets[i]);
    nanosleep(&wait, NULL);
  }
  return NULL;
}

static void startProfiler(void) {
  char list[512] = "";
  const char *value = getenv("PG_PROFILE");
  if (value) snprintf(list, sizeof list, "%s", value);
  else {
    CFTypeRef plist = CFBundleGetValueForInfoDictionaryKey(CFBundleGetMainBundle(), CFSTR("PGProfileThreads"));
    if (plist && CFGetTypeID(plist) == CFStringGetTypeID()) CFStringGetCString(plist, list, sizeof list, kCFStringEncodingUTF8);
  }
  for (char *piece = strtok(list, ","); piece && profileCount < PROFILE_GROUPS; piece = strtok(NULL, ",")) {
    while (*piece == ' ') piece++;
    if (*piece) snprintf(profileNames[profileCount++], NAME, "%s", piece);
  }
  if (!profileCount) return;
  pthread_t thread;
  pthread_create(&thread, NULL, profiler, NULL);
  pthread_detach(thread);
}
#else
static void startProfiler(void) {}
#endif
