// Script Hook V mods (.asi) on iOS (GTA-69): a Windows x64 DLL loader, the Windows and Script Hook V
// functions such DLLs import, and cooperative script threads, on top of the Blink x86-64
// interpreter. See NativeASI.h.
#include "NativeASI.h"
#include <ctype.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <setjmp.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <time.h>
#include <pthread.h>
#include <signal.h>
#include <unistd.h>
#include "blink/bus.h"
#include "blink/endian.h"
#include "blink/log.h"
#include "blink/machine.h"
#include "blink/map.h"

unsigned long long pg_blink_skew, pg_blink_low, pg_blink_high;
unsigned char *pg_blink_sink;
extern bool (*pg_blink_syscall_hook)(struct Machine *);

static PGAsiHost H;
static struct System *sys;
#define G(a) (H.memory + (uint64_t)(a))
static uint64_t rd64(uint64_t a) { uint64_t v; memcpy(&v, G(a), 8); return v; }
static uint32_t rd32(uint64_t a) { uint32_t v; memcpy(&v, G(a), 4); return v; }
static uint16_t rd16(uint64_t a) { uint16_t v; memcpy(&v, G(a), 2); return v; }
static void wr64(uint64_t a, uint64_t v) { memcpy(G(a), &v, 8); }
static void wr32(uint64_t a, uint32_t v) { memcpy(G(a), &v, 4); }
static void wr16(uint64_t a, uint16_t v) { memcpy(G(a), &v, 2); }
static void logf_(const char *format, ...) __attribute__((format(printf, 1, 2)));
static void logf_(const char *format, ...) {
  char line[512]; va_list list; va_start(list, format); vsnprintf(line, sizeof line, format, list); va_end(list);
  if (H.log) H.log(line);
}
static uint64_t now_us(void) { struct timeval t; gettimeofday(&t, 0); return (uint64_t)t.tv_sec * 1000000 + (uint64_t)t.tv_usec; }

// ---- Modules -------------------------------------------------------------------------------
// pdata: the module's unwind table (RUNTIME_FUNCTION entries), which C++ exceptions walk the stack with (GTA-188).
typedef struct { char name[64]; char root[1024]; uint64_t base, size, entry; uint64_t tlsIndexAddress, tlsStart, tlsEnd; uint32_t tlsZero; bool dead; uint64_t pdata; uint32_t pdataCount; } Module;
static Module modules[16]; static int moduleCount;
static uint64_t fakeExe;  // stands in for GTA5.exe: header only, so pattern scans find nothing (and say so)
static int moduleIndex(uint64_t a);
static Module *moduleAt(uint64_t a) { for (int i = 0; i < moduleCount; i++) if (a >= modules[i].base && a < modules[i].base + modules[i].size) return &modules[i]; return 0; }
static int moduleIndex(uint64_t a) { Module *m = moduleAt(a); return m ? (int)(m - modules) : -1; }

// ---- Coroutines: script threads (scriptRegister, CreateThread) and one-off calls -------------
enum { CO_NEW, CO_READY, CO_WAIT, CO_DEAD };
struct Nest; struct Catch; struct Throw;
typedef struct Co {
  struct Machine *m; uint64_t stack, stackSize, teb, entry, param; int state, module; uint64_t wakeAt;
  bool script, yield, finished; uint64_t result;  // native result buffer
  uint64_t unwaited; bool slowLogged;  // instructions since it last waited (run's time slices, GTA-165)
  uint64_t args[32]; uint32_t argc; uint64_t hash;
  uint64_t tls[64], fls[64];
  // The C/C++ runtime (NativeASIRuntime.inc, GTA-188): calls from an import back into the mod (a constructor, a
  // comparator, a stream's virtual function) run nested on this thread; catch blocks running; a C++ throw that
  // left such a nested call and goes on outside it; exceptions thrown and not caught yet.
  struct Nest *nest; int nestDepth; struct Catch *catches; struct Throw *pending; int uncaught;
} Co;
#define HALT_QUIET (-100)  // run() stops a script without a log line of its own (the reason is already logged)
static void ehAbandon(Co *co);
static Co *threads[64]; static int threadCount; static Co *cur;
static pthread_t runner; static volatile sig_atomic_t running;  // a mod's code is running on this thread
static uint64_t stubs;  // import stubs: mov eax, id; syscall; ret
static uint64_t exitStub;
static uint64_t ticks_instructions, tick_us;
static uint64_t keyboardHandlers[8]; static int keyboardCount;
static uint32_t tlsNext = 1, flsNext = 1;

static uint64_t galloc(uint64_t size) { uint64_t a = H.alloc(size ? size : 16); if (a) memset(G(a), 0, size); return a; }

static uint64_t makeTeb(Co *co, int module) {
  uint64_t teb = galloc(0x2000);  // TEB + its TLS slot array
  wr64(teb + 0x08, co->stack + co->stackSize);  // StackBase
  wr64(teb + 0x10, co->stack);                  // StackLimit
  wr64(teb + 0x30, teb);                        // Self
  wr64(teb + 0x58, teb + 0x1000);               // ThreadLocalStoragePointer
  wr32(teb + 0x40, 1); wr32(teb + 0x48, 2);     // ClientId (process, thread)
  for (int i = 0; i < moduleCount; i++) if (modules[i].tlsIndexAddress) {
    Module *mod = &modules[i]; uint64_t size = mod->tlsEnd - mod->tlsStart + mod->tlsZero;
    uint64_t block = galloc(size + 16); memcpy(G(block), G(mod->tlsStart), mod->tlsEnd - mod->tlsStart);
    wr64(teb + 0x1000 + 8ull * rd32(mod->tlsIndexAddress), block);
  }
  (void)module; return teb;
}
static Co *newCo(uint64_t entry, uint64_t param, bool script, int module) {
  Co *co = 0;
  for (int i = 0; i < threadCount && !co; i++) if (threads[i]->state == CO_DEAD) co = threads[i];  // reuse a finished one
  if (co) ehAbandon(co);
  if (!co) {
    if (threadCount >= 64) { logf_("ASI: too many script threads; one was not started."); return 0; }
    co = calloc(1, sizeof *co); co->m = NewMachine(sys, 0); co->stackSize = 1 << 20; co->stack = galloc(co->stackSize);
    co->result = galloc(256); co->teb = makeTeb(co, module); threads[threadCount++] = co;
  }
  co->entry = entry; co->param = param; co->script = script; co->module = module; co->state = CO_NEW; co->argc = 0;
  co->unwaited = 0; co->slowLogged = false;
  co->m->gs.base = co->teb; return co;
}
static void startCall(Co *co, uint64_t function, const uint64_t *a, int n) {
  // Windows x64: at the call site rsp is 16-byte aligned with 32 bytes of shadow space, then
  // arguments 5+; on entry [rsp] is the return address (exitStub, which ends the call).
  struct Machine *m = co->m; uint64_t extra = n > 4 ? (uint64_t)(n - 4) : 0;
  uint64_t site = (co->stack + co->stackSize - 256 - 32 - 8 * extra) & ~15ull;
  for (uint64_t i = 0; i < extra; i++) wr64(site + 32 + 8 * i, a[4 + i]);
  wr64(site - 8, exitStub); Put64(m->sp, site - 8);
  Put64(m->cx, n > 0 ? a[0] : 0); Put64(m->dx, n > 1 ? a[1] : 0); Put64(m->r8, n > 2 ? a[2] : 0); Put64(m->r9, n > 3 ? a[3] : 0);
  m->ip = function; co->finished = false; co->yield = false;
}
static const char *faultName(int rc) {
  switch (rc) {
    case kMachineSegmentationFault: return "memory fault"; case kMachineUndefinedInstruction: return "unsupported instruction";
    case kMachineDecodeError: return "bad instruction"; case kMachineDivideError: return "divide error";
    case kMachineProtectionFault: return "protection fault"; case kMachineHalt: return "halt";
    default: return "fault";
  }
}
// A script still busy from earlier frames (a mod starting up, like Menyoo reading its lists): which mod and when,
// for the app's "Loading <mod>" notice while the game runs slowly (GTA-209). Written on the game thread only.
static const char *volatile busyModName; static volatile double busyModAt;
static double asiNow(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return t.tv_sec + t.tv_nsec / 1e9; }
const char *PGAsiBusyModName(void) {
  double at = busyModAt; const char *name = busyModName;
  return name && at > 0 && asiNow() - at < 0.5 ? name : NULL;
}
// Runs a coroutine until it yields (scriptWait/Sleep), returns from its function, or faults.
static bool run(Co *co) {
  Co *outer = cur; cur = co; co->yield = false;
  struct Machine *m = co->m; sigjmp_buf saved; memcpy(saved, m->onhalt, sizeof saved);
  bool ok = true; int rc;
  g_machine = m;
  if ((rc = sigsetjmp(m->onhalt, 1))) {
    Module *mod = moduleAt(m->ip);
    running = outer != 0;
    if (rc != HALT_QUIET)
      logf_("ASI %s: %s at +0x%llx (address 0x%llx); this script is stopped.", mod ? mod->name : "?", faultName(rc),
            (unsigned long long)(mod ? m->ip - mod->base : m->ip), (unsigned long long)m->faultaddr);
    co->state = CO_DEAD; ok = false; ehAbandon(co);
  } else {
    m->canhalt = true; uint64_t count = 0; runner = pthread_self(); running = 1;
    // A script runs about 20 million instructions (about 0.1 s) per frame at most, then the game goes on and the
    // script continues where it was on the next frame. Stock Menyoo builds its menus for far longer than that on its
    // first frame and used to be stopped as stuck (GTA-165). Only script threads get more frames: start-up code
    // (DllMain, keyboard handlers) runs before the game goes on, so it still stops at the first limit. A script that
    // hasn't waited for 3 billion instructions (about 15 s of frames) is stuck: it would slow every frame, so it stops.
    // A script still busy from earlier frames gets 8 million a frame (about 40 ms), so the game keeps moving meanwhile.
    uint64_t slice = co->script && co->unwaited ? 8000000 : 20000000;
    while (!co->yield && !co->finished && count < slice) { ExecuteInstruction(m); count++; }
    if (co->yield || co->finished) co->unwaited = 0;
    else if (!co->script || (co->unwaited += count) >= 3000000000ull) {   // start-up code (DllMain) still stops at once
      Module *mod = moduleAt(m->ip);
      logf_("ASI %s: a script ran too long without waiting (at +0x%llx); it is stopped.", mod ? mod->name : "?", (unsigned long long)(mod ? m->ip - mod->base : m->ip));
      co->state = CO_DEAD;
    } else {
      if (co->module >= 0 && co->module < moduleCount) { busyModName = modules[co->module].name; busyModAt = asiNow(); }
      if (!co->slowLogged) {
        Module *mod = moduleAt(m->ip); co->slowLogged = true;
        logf_("ASI %s: a script is busy for longer than a frame; it goes on over the next frames.", mod ? mod->name : "?");
      }
    }
    running = outer != 0; ticks_instructions += count;
  }
  m->canhalt = false; memcpy(m->onhalt, saved, sizeof saved);
  cur = outer; if (outer) g_machine = outer->m;
  return ok;
}
// Calls a guest function to completion on a fresh coroutine (DllMain, TLS callbacks, keyboard handlers).
static uint64_t callGuest(uint64_t function, const uint64_t *a, int n) {
  Co *co = newCo(function, 0, false, moduleIndex(function)); if (!co) return 0;
  startCall(co, function, a, n); co->state = CO_READY;
  for (int guard = 0; !co->finished && co->state != CO_DEAD && guard < 1000; guard++) run(co);
  uint64_t value = Get64(co->m->r10); co->state = CO_DEAD; return value;
}

// ---- Windows strings ------------------------------------------------------------------------
static size_t wlen(uint64_t a) { size_t n = 0; while (rd16(a + 2 * n)) n++; return n; }
static void wToUtf8(uint64_t a, long n, char *out, size_t cap) {  // n < 0: zero-terminated
  size_t o = 0; for (long i = 0; (n < 0 || i < n); i++) {
    uint32_t c = rd16(a + 2 * (uint64_t)i); if (n < 0 && !c) break;
    if (c < 0x80) { if (o + 1 < cap) out[o++] = (char)c; }
    else if (c < 0x800) { if (o + 2 < cap) { out[o++] = (char)(0xC0 | c >> 6); out[o++] = (char)(0x80 | (c & 63)); } }
    else if (o + 3 < cap) { out[o++] = (char)(0xE0 | c >> 12); out[o++] = (char)(0x80 | (c >> 6 & 63)); out[o++] = (char)(0x80 | (c & 63)); }
  }
  out[o < cap ? o : cap - 1] = 0;
}
// Windows paths map into the mod folder: the game folder (C:\GTA5\...) and anything else by name.
// Windows names ignore case and the iPhone's may not, so each part takes the case of an existing
// file or folder ("TrainerV.ini" finds "trainerv.ini").
static void hostPath(const char *windows, char *out, size_t cap) {
  char p[1024]; snprintf(p, sizeof p, "%s", windows);
  for (char *c = p; *c; c++) if (*c == '\\') *c = '/';
  const char *rel = p; if (rel[0] && rel[1] == ':') rel += 2;
  while (*rel == '/') rel++;
  if (!strncasecmp(rel, "GTA5/", 5)) rel += 5;
  // Each script's folder stands in for the game folder (Mods/<mod>/ when installed per mod).
  const char *base = cur && cur->module >= 0 && cur->module < moduleCount && modules[cur->module].root[0] ? modules[cur->module].root : H.files;
  size_t o = (size_t)snprintf(out, cap, "%s", base);
  for (const char *s = rel; *s && o + 2 < cap;) {
    const char *e = strchr(s, '/'); size_t len = e ? (size_t)(e - s) : strlen(s);
    if (!(len == 0 || (len == 1 && s[0] == '.') || (len == 2 && s[0] == '.' && s[1] == '.'))) {
      char part[256]; snprintf(part, sizeof part, "%.*s", (int)(len < 255 ? len : 255), s);
      DIR *dir = opendir(out); struct dirent *entry;
      if (dir) { while ((entry = readdir(dir))) if (!strcasecmp(entry->d_name, part)) { snprintf(part, sizeof part, "%s", entry->d_name); break; } closedir(dir); }
      o += (size_t)snprintf(out + o, cap - o, "/%s", part);
    }
    s += len; if (*s == '/') s++;
  }
}

// ---- Imports --------------------------------------------------------------------------------
typedef uint64_t (*Fn)(void);
typedef struct { const char *name; Fn fn; } Import;
static const char *stubName[4096]; static Fn stubFn[4096]; static int stubCount;
enum { ID_EXIT = 0, ID_FIRST = 1 };  // stub ids: 0 ends a call (exitStub), the rest are imports (stubName/stubFn index + 1)
#define ARG(n) arg(n)
static uint64_t arg(int n) {
  struct Machine *m = cur->m;
  switch (n) { case 0: return Get64(m->cx); case 1: return Get64(m->dx); case 2: return Get64(m->r8); case 3: return Get64(m->r9); }
  return rd64(Get64(m->sp) + 8 + 8 * (uint64_t)n);
}
static void setError(uint32_t e) { if (cur) wr32(cur->teb + 0x68, e); }

static uint64_t unimplemented(void) { return 0; }

// kernel32: memory
#define HEADER 16
static uint64_t heapAlloc(uint64_t size, bool zero) { uint64_t a = H.alloc(size + HEADER); if (!a) return 0; wr64(a, size); if (zero) memset(G(a + HEADER), 0, size); return a + HEADER; }
static uint64_t k_HeapAlloc(void) { return heapAlloc(ARG(2), ARG(1) & 8); }
static uint64_t k_HeapFree(void) { if (ARG(2)) H.free(ARG(2) - HEADER); return 1; }
static uint64_t k_HeapSize(void) { return ARG(2) ? rd64(ARG(2) - HEADER) : (uint64_t)-1; }
static uint64_t k_HeapReAlloc(void) {
  uint64_t old = ARG(2), size = ARG(3), fresh = heapAlloc(size, ARG(1) & 8); if (!fresh) return 0;
  if (old) { uint64_t was = rd64(old - HEADER); memcpy(G(fresh), G(old), was < size ? was : size); H.free(old - HEADER); }
  return fresh;
}
static uint64_t k_GetProcessHeap(void) { return 0x1000; }
// Private heaps (HeapCreate): a handle of their own, with blocks from the same allocator as the process heap. Menyoo's newest
// desktop build (4.4 MB) creates one at start-up and throws std::bad_alloc when it gets none: 26 player logs from v1.4.1 to
// v1.4.7 stop at the same int3 after that throw (GTA-186). HeapDestroy leaves the blocks to their own HeapFree calls.
static uint64_t k_HeapCreate(void) { static uint64_t next = 0x2000; return next += 0x10; }
static uint64_t k_HeapDestroy(void) { return 1; }
static uint64_t k_HeapValidate(void) { return 1; }
static uint64_t k_VirtualAlloc(void) {
  if (ARG(0)) return ARG(0);  // commit inside an earlier reservation: already backed
  uint64_t size = ARG(1), raw = H.alloc(size + 0x10000); if (!raw) return 0;
  uint64_t a = (raw + 0xFFFF) & ~0xFFFFull; memset(G(a), 0, size); return a;
}
static uint64_t k_VirtualFree(void) { return 1; }
static uint64_t k_VirtualProtect(void) { if (ARG(3)) wr32(ARG(3), 0x40); return 1; }
static uint64_t k_VirtualQuery(void) {
  uint64_t a = ARG(0), out = ARG(1); Module *mod = moduleAt(a); memset(G(out), 0, 48);
  uint64_t base = mod ? mod->base : (a & ~0xFFFFull), size = mod ? mod->size : 0x10000;
  if (a >= fakeExe && a < fakeExe + 0x1000) { base = fakeExe; size = 0x1000; }
  wr64(out, base); wr64(out + 8, base); wr32(out + 16, 0x40); wr64(out + 24, size); wr32(out + 32, 0x1000); wr32(out + 36, 0x40); wr32(out + 40, mod ? 0x1000000 : 0x20000);
  return 48;
}
// kernel32: modules
static uint64_t moduleByName(const char *name) {
  if (!name || !*name) return fakeExe;
  const char *slash = strrchr(name, '\\'); if (slash) name = slash + 1;
  for (int i = 0; i < moduleCount; i++) if (!strcasecmp(modules[i].name, name)) return modules[i].base;
  if (!strncasecmp(name, "gta5", 4)) return fakeExe;
  static const char *system[] = {"kernel32", "user32", "ntdll", "kernelbase", "shlwapi", "scripthookv", "advapi32", "ole32", "shell32"};
  for (int i = 0; i < 9; i++) if (!strncasecmp(name, system[i], strlen(system[i]))) return 0x7FF000000000ull + (uint64_t)i * 0x10000;  // handles, never dereferenced
  return 0;
}
static uint64_t k_GetModuleHandleA(void) { return moduleByName(ARG(0) ? (const char *)G(ARG(0)) : 0); }
static uint64_t k_GetModuleHandleW(void) { char n[256]; if (!ARG(0)) return fakeExe; wToUtf8(ARG(0), -1, n, sizeof n); return moduleByName(n); }
static uint64_t k_GetModuleHandleExW(void) { char n[256]; uint64_t h = fakeExe; if (ARG(0) & 4) { Module *mod = moduleAt(ARG(1)); h = mod ? mod->base : 0; } else if (ARG(1)) { wToUtf8(ARG(1), -1, n, sizeof n); h = moduleByName(n); } if (ARG(2)) wr64(ARG(2), h); return h != 0; }
static void modulePath(uint64_t h, char *out, size_t cap) {
  for (int i = 0; i < moduleCount; i++) if (modules[i].base == h) { snprintf(out, cap, "C:\\GTA5\\%s", modules[i].name); return; }
  snprintf(out, cap, "C:\\GTA5\\GTA5.exe");
}
static uint64_t k_GetModuleFileNameA(void) { char p[300]; modulePath(ARG(0), p, sizeof p); size_t n = strlen(p), cap = ARG(2); if (!cap) return 0; if (n >= cap) n = cap - 1; memcpy(G(ARG(1)), p, n); *G(ARG(1) + n) = 0; return n; }
static uint64_t k_GetModuleFileNameW(void) { char p[300]; modulePath(ARG(0), p, sizeof p); size_t n = strlen(p), cap = ARG(2); if (!cap) return 0; if (n >= cap) n = cap - 1; for (size_t i = 0; i < n; i++) wr16(ARG(1) + 2 * i, (uint8_t)p[i]); wr16(ARG(1) + 2 * n, 0); return n; }
static uint64_t K32GetModuleInformation_(void) {
  uint64_t h = ARG(1), out = ARG(2); Module *mod = moduleAt(h);
  wr64(out, mod ? mod->base : fakeExe); wr32(out + 8, (uint32_t)(mod ? mod->size : 0x1000)); wr64(out + 16, mod ? mod->entry : 0);
  if (!mod) { static bool told; if (!told) { told = true; logf_("ASI: a mod looks for code inside GTA5.exe; that doesn't exist on iOS, so those features stay off."); } }
  return 1;
}
static uint64_t stubFor(const char *name);
static uint64_t k_GetProcAddress(void) {
  uint64_t h = ARG(0), nameAt = ARG(1); if (nameAt < 0x10000) return 0;  // by ordinal: unsupported
  const char *name = (const char *)G(nameAt);
  for (int i = 0; i < moduleCount; i++) if (modules[i].base == h) {  // a loaded mod's exports
    uint64_t base = h, dir = base + rd32(base + rd32(base + 0x3C) + 24 + 112);
    if (dir == base) return 0;
    uint32_t count = rd32(dir + 24); uint64_t names = base + rd32(dir + 32), ordinals = base + rd32(dir + 36), functions = base + rd32(dir + 28);
    for (uint32_t k = 0; k < count; k++) if (!strcmp((const char *)G(base + rd32(names + 4 * k)), name)) return base + rd32(functions + 4ull * rd16(ordinals + 2 * k));
    return 0;
  }
  return stubFor(name);
}
static uint64_t k_LoadLibraryA(void) { return moduleByName((const char *)G(ARG(0))); }
static uint64_t k_LoadLibraryW(void) { char n[256]; wToUtf8(ARG(0), -1, n, sizeof n); return moduleByName(n); }
static uint64_t k_one(void) { return 1; }
// kernel32: threads and synchronization (scripts are cooperative: one runs at a time)
static uint64_t k_GetCurrentThreadId(void) { for (int i = 0; i < threadCount; i++) if (threads[i] == cur) return 100 + (uint64_t)i; return 100; }
static uint64_t k_GetCurrentProcessId(void) { return 4; }
static uint64_t k_GetCurrentProcess(void) { return (uint64_t)-1; }
static uint64_t k_Sleep(void) { if (cur && cur->script) { cur->wakeAt = now_us() + ARG(0) * 1000; cur->state = CO_WAIT; cur->yield = true; } return 0; }
static uint64_t k_CreateThread(void) {
  Co *co = newCo(ARG(2), ARG(3), true, cur ? cur->module : -1); if (!co) return 0;
  startCall(co, ARG(2), (uint64_t[]){ARG(3)}, 1); co->state = CO_READY;
  if (ARG(5)) wr32(ARG(5), (uint32_t)(100 + threadCount - 1));
  logf_("ASI: a mod started a background thread; it runs between game frames.");
  return 0x2000 + (uint64_t)threadCount;
}
static uint64_t k_TlsAlloc(void) { return tlsNext < 64 ? tlsNext++ : 0xFFFFFFFF; }
static uint64_t k_TlsGetValue(void) { return ARG(0) < 64 ? cur->tls[ARG(0)] : 0; }
static uint64_t k_TlsSetValue(void) { if (ARG(0) < 64) cur->tls[ARG(0)] = ARG(1); return 1; }
static uint64_t k_FlsAlloc(void) { return flsNext < 64 ? flsNext++ : 0xFFFFFFFF; }
static uint64_t k_FlsGetValue(void) { return ARG(0) < 64 ? cur->fls[ARG(0)] : 0; }
static uint64_t k_FlsSetValue(void) { if (ARG(0) < 64) cur->fls[ARG(0)] = ARG(1); return 1; }
static uint64_t k_GetLastError(void) { return cur ? rd32(cur->teb + 0x68) : 0; }
static uint64_t k_SetLastError(void) { setError((uint32_t)ARG(0)); return 0; }
static uint64_t k_EncodePointer(void) { return ARG(0); }
static uint64_t k_InterlockedFlushSList(void) { uint64_t head = ARG(0), first = rd64(head); wr64(head, 0); wr64(head + 8, 0); return first; }
static uint64_t k_InitializeSListHead(void) { wr64(ARG(0), 0); wr64(ARG(0) + 8, 0); return 0; }
// kernel32: time
static uint64_t k_GetTickCount(void) { return now_us() / 1000; }
static uint64_t k_QueryPerformanceCounter(void) { wr64(ARG(0), now_us()); return 1; }
static uint64_t k_QueryPerformanceFrequency(void) { wr64(ARG(0), 1000000); return 1; }
static uint64_t k_GetSystemTimeAsFileTime(void) { wr64(ARG(0), now_us() * 10 + 116444736000000000ull); return 0; }
static uint64_t k_GetLocalTime(void) {
  time_t t = time(0); struct tm tm; localtime_r(&t, &tm); uint64_t o = ARG(0);
  wr16(o, (uint16_t)(tm.tm_year + 1900)); wr16(o + 2, (uint16_t)(tm.tm_mon + 1)); wr16(o + 4, (uint16_t)tm.tm_wday); wr16(o + 6, (uint16_t)tm.tm_mday);
  wr16(o + 8, (uint16_t)tm.tm_hour); wr16(o + 10, (uint16_t)tm.tm_min); wr16(o + 12, (uint16_t)tm.tm_sec); wr16(o + 14, (uint16_t)((now_us() / 1000) % 1000)); return 0;
}
// kernel32: process, environment, system
static uint64_t cmdA, cmdW, envW;
static uint64_t k_GetCommandLineA(void) { return cmdA; }
static uint64_t k_GetCommandLineW(void) { return cmdW; }
static uint64_t k_GetEnvironmentStringsW(void) { return envW; }
static uint64_t k_GetEnvironmentVariableA(void) {
  const char *n = (const char *)G(ARG(0)), *v = !strcasecmp(n, "APPDATA") || !strcasecmp(n, "LOCALAPPDATA") ? "C:\\GTA5\\AppData" : !strcasecmp(n, "USERPROFILE") ? "C:\\GTA5" : 0;
  if (!v) { setError(203); return 0; }
  size_t len = strlen(v); if (ARG(2) <= len) return len + 1; memcpy(G(ARG(1)), v, len + 1); return len;
}
static uint64_t k_GetStartupInfoW(void) { memset(G(ARG(0)), 0, 104); wr32(ARG(0), 104); return 0; }
static uint64_t k_GetSystemInfo(void) {
  uint64_t o = ARG(0); memset(G(o), 0, 48); wr16(o, 9); wr32(o + 4, 4096); wr64(o + 8, 0x10000); wr64(o + 16, 0x7FFFFFFEFFFFull);
  wr64(o + 24, 1); wr32(o + 32, 1); wr32(o + 36, 8664); wr32(o + 40, 0x10000); wr16(o + 44, 6); return 0;
}
static uint64_t k_IsProcessorFeaturePresent(void) { uint64_t f = ARG(0); return f == 6 || f == 10 || f == 13 || f == 17 || f == 23; }  // SSE, SSE2, SSE3, NX, fastfail
static uint64_t k_ExitProcess(void) { logf_("ASI: a mod tried to quit the game; that script is stopped."); cur->state = CO_DEAD; cur->yield = true; return 0; }
static uint64_t k_RaiseException(void) {
  uint32_t code = (uint32_t)ARG(0); Module *mod = moduleAt(cur->m->ip);
  logf_("ASI %s: %s (0x%08x); this script is stopped.", mod ? mod->name : "?", code == 0xE06D7363 ? "C++ exception" : "Windows exception", code);
  cur->state = CO_DEAD; cur->yield = true; return 0;
}
// kernel32: code pages and locale ("C" locale, Windows-1252 bytes or UTF-8)
static uint64_t k_GetACP(void) { return 1252; }
static uint64_t k_GetOEMCP(void) { return 437; }
static uint64_t k_GetCPInfo(void) { uint64_t o = ARG(1); memset(G(o), 0, 20); wr32(o, 1); *G(o + 4) = '?'; return 1; }
static uint64_t k_MultiByteToWideChar(void) {
  uint32_t cp = (uint32_t)ARG(0); uint64_t src = ARG(2), dst = ARG(4); long n = (long)(int32_t)ARG(3); uint64_t cap = (uint32_t)ARG(5);
  if (n < 0) n = (long)strlen((const char *)G(src)) + 1;
  uint64_t out = 0;
  for (long i = 0; i < n;) {
    uint32_t c = *G(src + (uint64_t)i++);
    if (cp == 65001 && c >= 0xC0) { int more = c >= 0xE0 ? (c >= 0xF0 ? 3 : 2) : 1; c &= 0x3F >> more; while (more-- && i < n) c = c << 6 | (*G(src + (uint64_t)i++) & 63); if (c > 0xFFFF) c = '?'; }
    if (cap) { if (out >= cap) { setError(122); return 0; } wr16(dst + 2 * out, (uint16_t)c); }
    out++;
  }
  return out;
}
static uint64_t k_WideCharToMultiByte(void) {
  uint32_t cp = (uint32_t)ARG(0); uint64_t src = ARG(2), dst = ARG(4); long n = (long)(int32_t)ARG(3); uint64_t cap = (uint32_t)ARG(5);
  if (n < 0) n = (long)wlen(src) + 1;
  uint64_t out = 0;
  for (long i = 0; i < n; i++) {
    uint32_t c = rd16(src + 2 * (uint64_t)i); uint8_t b[3]; int k = 1;
    if (cp == 65001 && c >= 0x80) { if (c < 0x800) { b[0] = (uint8_t)(0xC0 | c >> 6); b[1] = (uint8_t)(0x80 | (c & 63)); k = 2; } else { b[0] = (uint8_t)(0xE0 | c >> 12); b[1] = (uint8_t)(0x80 | (c >> 6 & 63)); b[2] = (uint8_t)(0x80 | (c & 63)); k = 3; } }
    else b[0] = c < 256 ? (uint8_t)c : '?';
    for (int j = 0; j < k; j++) { if (cap) { if (out >= cap) { setError(122); return 0; } *G(dst + out) = b[j]; } out++; }
  }
  return out;
}
static uint64_t lcmap(uint32_t flags, uint64_t src, long n, uint64_t dst, uint64_t cap) {
  if (n < 0) n = (long)wlen(src) + 1;
  if (!cap) return (uint64_t)n;
  if ((uint64_t)n > cap) { setError(122); return 0; }
  for (long i = 0; i < n; i++) { uint32_t c = rd16(src + 2 * (uint64_t)i); if (c < 128) c = (uint32_t)(flags & 0x100 ? tolower((int)c) : flags & 0x200 ? toupper((int)c) : (int)c); wr16(dst + 2 * (uint64_t)i, (uint16_t)c); }
  return (uint64_t)n;
}
static uint64_t k_LCMapStringEx(void) { return lcmap((uint32_t)ARG(1), ARG(2), (long)(int32_t)ARG(3), ARG(4), (uint32_t)ARG(5)); }
static uint64_t k_LCMapStringW(void) { return lcmap((uint32_t)ARG(1), ARG(2), (long)(int32_t)ARG(3), ARG(4), (uint32_t)ARG(5)); }
static uint64_t k_GetStringTypeW(void) {
  long n = (long)(int32_t)ARG(2); uint64_t src = ARG(1), out = ARG(3); if (n < 0) n = (long)wlen(src) + 1;
  for (long i = 0; i < n; i++) {
    uint32_t c = rd16(src + 2 * (uint64_t)i); uint16_t t = 0;
    if (c < 128) { if (isupper((int)c)) t |= 0x1; if (islower((int)c)) t |= 0x2; if (isdigit((int)c)) t |= 0x4; if (isspace((int)c)) t |= 0x8; if (ispunct((int)c)) t |= 0x10; if (iscntrl((int)c)) t |= 0x20; if (c == ' ' || c == '\t') t |= 0x40; if (isxdigit((int)c)) t |= 0x80; if (isalpha((int)c)) t |= 0x100; }
    else t = 0x100 | 0x2;
    wr16(out + 2 * (uint64_t)i, t);
  }
  return 1;
}
static uint64_t k_CompareStringW(void) {
  bool fold = ARG(1) & 1; uint64_t a = ARG(2), b = ARG(4); long na = (long)(int32_t)ARG(3), nb = (long)(int32_t)ARG(5);
  if (na < 0) na = (long)wlen(a); if (nb < 0) nb = (long)wlen(b);
  for (long i = 0; i < na && i < nb; i++) { uint32_t x = rd16(a + 2 * (uint64_t)i), y = rd16(b + 2 * (uint64_t)i); if (fold && x < 128) x = (uint32_t)tolower((int)x); if (fold && y < 128) y = (uint32_t)tolower((int)y); if (x != y) return x < y ? 1 : 3; }
  return na == nb ? 2 : na < nb ? 1 : 3;
}
static uint64_t k_GetUserDefaultLCID(void) { return 0x409; }
static uint64_t k_GetTimeZoneInformation(void) { memset(G(ARG(0)), 0, 172); return 0; }
// kernel32: files (inside the mod folder) and the console (the port's log)
typedef struct { int fd; DIR *dir; char pattern[128]; char path[1024]; } Handle;
static Handle handles[64];
static uint64_t newHandle(int fd, DIR *dir) { for (int i = 0; i < 64; i++) if (!handles[i].fd && !handles[i].dir) { handles[i].fd = fd ? fd : -2; handles[i].dir = dir; return 0x100 + (uint64_t)i * 4; } return (uint64_t)-1; }
static Handle *handleFor(uint64_t h) { uint64_t i = (h - 0x100) / 4; return h >= 0x100 && i < 64 && (handles[i].fd || handles[i].dir) ? &handles[i] : 0; }
static uint64_t openFile(const char *windows, uint64_t access, uint64_t disposition) {
  char p[1100]; hostPath(windows, p, sizeof p);
  int flags = (access & 0x40000000) ? ((access & 0x80000000) ? O_RDWR : O_WRONLY) : O_RDONLY;
  if (disposition == 1) flags |= O_CREAT | O_EXCL; else if (disposition == 2) flags |= O_CREAT | O_TRUNC; else if (disposition == 4) flags |= O_CREAT; else if (disposition == 5) flags |= O_TRUNC;
  if (flags & O_CREAT) { char dir[1100]; snprintf(dir, sizeof dir, "%s", p); char *s = strrchr(dir, '/'); if (s) { *s = 0; for (char *c = dir + strlen(H.files) + 1; c < dir + strlen(dir) && *c; c++) if (*c == '/') { *c = 0; mkdir(dir, 0755); *c = '/'; } mkdir(dir, 0755); } }
  int fd = open(p, flags | O_CLOEXEC, 0644);
  if (fd < 0) { setError(errno == ENOENT ? 2 : errno == EEXIST ? 80 : 5); return (uint64_t)-1; }
  return newHandle(fd, 0);
}
static uint64_t k_CreateFileW(void) { char n[1024]; wToUtf8(ARG(0), -1, n, sizeof n); return openFile(n, ARG(1), ARG(4)); }
static uint64_t k_CreateFileA(void) { return openFile((const char *)G(ARG(0)), ARG(1), ARG(4)); }
void PGMeshTouch(const void *start, uint64_t length);	// NativeMeshRelease.c (GTA-152)
static uint64_t k_ReadFile(void) {
  Handle *f = handleFor(ARG(0)); if (!f || f->fd < 0) { if (ARG(3)) wr32(ARG(3), 0); return ARG(0) == 0x10 ? 1 : 0; }
  PGMeshTouch(G(ARG(1)), (uint32_t)ARG(2));
  ssize_t n = read(f->fd, G(ARG(1)), (size_t)(uint32_t)ARG(2)); if (n < 0) return 0; if (ARG(3)) wr32(ARG(3), (uint32_t)n); return 1;
}
static void consoleWrite(const char *s, size_t n) { char line[512]; size_t k = n < sizeof line - 1 ? n : sizeof line - 1; memcpy(line, s, k); line[k] = 0; while (k && (line[k - 1] == '\n' || line[k - 1] == '\r')) line[--k] = 0; if (k) logf_("ASI console: %s", line); }
static uint64_t k_WriteFile(void) {
  uint64_t h = ARG(0); uint32_t n = (uint32_t)ARG(2);
  if (h == 0x11 || h == 0x12) { consoleWrite((const char *)G(ARG(1)), n); if (ARG(3)) wr32(ARG(3), n); return 1; }
  Handle *f = handleFor(h); if (!f || f->fd < 0) return 0;
  ssize_t w = write(f->fd, G(ARG(1)), n); if (w < 0) return 0; if (ARG(3)) wr32(ARG(3), (uint32_t)w); return 1;
}
static uint64_t k_WriteConsoleW(void) { char s[512]; wToUtf8(ARG(1), (long)(uint32_t)ARG(2), s, sizeof s); consoleWrite(s, strlen(s)); if (ARG(3)) wr32(ARG(3), (uint32_t)ARG(2)); return 1; }
static uint64_t k_CloseHandle(void) { Handle *f = handleFor(ARG(0)); if (f) { if (f->fd > 0) close(f->fd); if (f->dir) closedir(f->dir); memset(f, 0, sizeof *f); } return 1; }
static uint64_t k_GetFileSizeEx(void) { Handle *f = handleFor(ARG(0)); struct stat st; if (!f || f->fd < 0 || fstat(f->fd, &st)) return 0; wr64(ARG(1), (uint64_t)st.st_size); return 1; }
static uint64_t k_SetFilePointerEx(void) { Handle *f = handleFor(ARG(0)); if (!f || f->fd < 0) return 0; off_t at = lseek(f->fd, (off_t)ARG(1), (int)ARG(3)); if (at < 0) return 0; if (ARG(2)) wr64(ARG(2), (uint64_t)at); return 1; }
static uint64_t k_SetEndOfFile(void) { Handle *f = handleFor(ARG(0)); if (!f || f->fd < 0) return 0; return ftruncate(f->fd, lseek(f->fd, 0, SEEK_CUR)) == 0; }
static uint64_t k_GetFileType(void) { return ARG(0) <= 0x12 ? 2 : 1; }
static uint64_t k_GetStdHandle(void) { int32_t n = (int32_t)ARG(0); return n == -10 ? 0x10 : n == -11 ? 0x11 : n == -12 ? 0x12 : (uint64_t)-1; }
static uint64_t k_GetConsoleMode(void) { return 0; }
static uint64_t k_GetConsoleOutputCP(void) { return 65001; }
static uint64_t k_DeleteFileA(void) { char p[1100]; hostPath((const char *)G(ARG(0)), p, sizeof p); return unlink(p) == 0; }
static uint64_t k_DeleteFileW(void) { char n[1024], p[1100]; wToUtf8(ARG(0), -1, n, sizeof n); hostPath(n, p, sizeof p); return unlink(p) == 0; }
static uint64_t k_CreateDirectoryA(void) { char p[1100]; hostPath((const char *)G(ARG(0)), p, sizeof p); return mkdir(p, 0755) == 0 || errno == EEXIST; }
static uint64_t k_CopyFileA(void) {
  char a[1100], b[1100]; hostPath((const char *)G(ARG(0)), a, sizeof a); hostPath((const char *)G(ARG(1)), b, sizeof b);
  int in = open(a, O_RDONLY), out = in < 0 ? -1 : open(b, O_WRONLY | O_CREAT | (ARG(2) ? O_EXCL : O_TRUNC), 0644); char buf[65536]; ssize_t n;
  if (in < 0 || out < 0) { if (in >= 0) close(in); return 0; }
  while ((n = read(in, buf, sizeof buf)) > 0) (void)!write(out, buf, (size_t)n);
  close(in); close(out); return 1;
}
static uint64_t k_GetFileAttributesA(void) { char p[1100]; struct stat st; hostPath((const char *)G(ARG(0)), p, sizeof p); if (stat(p, &st)) { setError(2); return 0xFFFFFFFF; } return S_ISDIR(st.st_mode) ? 0x10 : 0x80; }
static bool match(const char *pattern, const char *name) {
  if (!*pattern) return !*name;
  if (*pattern == '*') return match(pattern + 1, name) || (*name && match(pattern, name + 1));
  return *name && (*pattern == '?' || tolower((unsigned char)*pattern) == tolower((unsigned char)*name)) && match(pattern + 1, name + 1);
}
static bool findNext(Handle *f, uint64_t out, bool wide) {
  struct dirent *e;
  while ((e = readdir(f->dir))) if (match(f->pattern, e->d_name)) {
    char p[1300]; struct stat st; snprintf(p, sizeof p, "%s/%s", f->path, e->d_name); bool dir = !stat(p, &st) && S_ISDIR(st.st_mode);
    memset(G(out), 0, wide ? 592 : 320); wr32(out, dir ? 0x10 : 0x80); wr32(out + 32, (uint32_t)(dir ? 0 : st.st_size));
    for (size_t i = 0; e->d_name[i] && i < 259; i++) { if (wide) wr16(out + 44 + 2 * i, (uint8_t)e->d_name[i]); else *G(out + 44 + i) = (uint8_t)e->d_name[i]; }
    return true;
  }
  setError(18); return false;
}
static uint64_t findFirst(const char *windows, uint64_t out, bool wide) {
  char p[1100]; hostPath(windows, p, sizeof p); char *slash = strrchr(p, '/'); if (!slash) return (uint64_t)-1;
  *slash = 0; DIR *dir = opendir(p); if (!dir) { setError(3); return (uint64_t)-1; }
  uint64_t h = newHandle(0, dir); Handle *f = handleFor(h); if (!f) { closedir(dir); return (uint64_t)-1; }
  snprintf(f->pattern, sizeof f->pattern, "%s", slash + 1); snprintf(f->path, sizeof f->path, "%s", p);
  if (!findNext(f, out, wide)) { closedir(dir); memset(f, 0, sizeof *f); return (uint64_t)-1; }
  return h;
}
static uint64_t k_FindFirstFileA(void) { return findFirst((const char *)G(ARG(0)), ARG(1), false); }
static uint64_t k_FindFirstFileExW(void) { char n[1024]; wToUtf8(ARG(0), -1, n, sizeof n); return findFirst(n, ARG(2), true); }
static uint64_t k_FindNextFileA(void) { Handle *f = handleFor(ARG(0)); return f && f->dir && findNext(f, ARG(1), false); }
static uint64_t k_FindNextFileW(void) { Handle *f = handleFor(ARG(0)); return f && f->dir && findNext(f, ARG(1), true); }
static uint64_t k_GetFullPathNameW(void) {
  uint64_t src = ARG(0), cap = (uint32_t)ARG(1), dst = ARG(2); size_t n = wlen(src); bool absolute = n > 1 && rd16(src + 2) == ':';
  const char *prefix = absolute ? "" : "C:\\GTA5\\"; size_t p = strlen(prefix);
  if (cap < n + p + 1) return n + p + 1;
  for (size_t i = 0; i < p; i++) wr16(dst + 2 * i, (uint8_t)prefix[i]);
  for (size_t i = 0; i <= n; i++) wr16(dst + 2 * (p + i), rd16(src + 2 * i));
  if (ARG(3)) wr64(ARG(3), 0); return n + p;
}
static uint64_t k_GetCurrentDirectoryW(void) { const char *d = "C:\\GTA5"; size_t n = strlen(d); if (ARG(0) <= n) return n + 1; for (size_t i = 0; i <= n; i++) wr16(ARG(1) + 2 * i, (uint8_t)d[i]); return n; }
static uint64_t k_GetDriveTypeW(void) { return 3; }
// Settings files (.ini), the way most trainers keep their options.
static char *readText(const char *windows) {
  char p[1100]; hostPath(windows, p, sizeof p); FILE *f = fopen(p, "rb"); if (!f) return 0;
  fseek(f, 0, SEEK_END); long n = ftell(f); rewind(f); char *s = malloc((size_t)n + 1); if (fread(s, 1, (size_t)n, f) != (size_t)n) n = 0; s[n] = 0; fclose(f); return s;
}
static bool iniFind(const char *text, const char *section, const char *key, char *out, size_t cap) {
  bool in = false; const char *line = text;
  while (line && *line) {
    const char *end = strchr(line, '\n'); size_t len = end ? (size_t)(end - line) : strlen(line);
    char l[1024]; snprintf(l, sizeof l, "%.*s", (int)(len < 1023 ? len : 1023), line);
    char *s = l; while (isspace((unsigned char)*s)) s++; size_t k = strlen(s); while (k && isspace((unsigned char)s[k - 1])) s[--k] = 0;
    if (*s == '[') { char *e = strchr(s, ']'); if (e) *e = 0; in = !strcasecmp(s + 1, section); }
    else if (in && *s && *s != ';') { char *eq = strchr(s, '='); if (eq) { *eq = 0; char *v = eq + 1; size_t kl = strlen(s); while (kl && isspace((unsigned char)s[kl - 1])) s[--kl] = 0; while (isspace((unsigned char)*v)) v++; if (!strcasecmp(s, key)) { snprintf(out, cap, "%s", v); return true; } } }
    line = end ? end + 1 : 0;
  }
  return false;
}
static uint64_t k_GetPrivateProfileStringA(void) {
  const char *section = ARG(0) ? (const char *)G(ARG(0)) : 0, *key = ARG(1) ? (const char *)G(ARG(1)) : 0, *def = ARG(2) ? (const char *)G(ARG(2)) : "";
  uint64_t out = ARG(3), cap = (uint32_t)ARG(4); if (!cap) return 0;
  char value[1024]; char *text = readText((const char *)G(arg(5)));
  if (!section || !key) { if (cap >= 2) { *G(out) = 0; *G(out + 1) = 0; } free(text); return 0; }  // listing sections/keys: none reported
  if (!text || !iniFind(text, section, key, value, sizeof value)) snprintf(value, sizeof value, "%s", def);
  free(text); size_t n = strlen(value); if (n >= cap) n = cap - 1; memcpy(G(out), value, n); *G(out + n) = 0; return n;
}
static uint64_t k_GetPrivateProfileIntA(void) {
  char value[64]; char *text = readText((const char *)G(ARG(3))); bool found = text && iniFind(text, (const char *)G(ARG(0)), (const char *)G(ARG(1)), value, sizeof value);
  free(text); return found ? (uint64_t)(uint32_t)strtol(value, 0, 0) : (uint32_t)ARG(2);
}
static uint64_t k_WritePrivateProfileStringA(void) {
  const char *section = (const char *)G(ARG(0)), *key = ARG(1) ? (const char *)G(ARG(1)) : 0, *value = ARG(2) ? (const char *)G(ARG(2)) : 0, *file = (const char *)G(ARG(3));
  if (!key) return 1;
  char *text = readText(file); size_t cap = (text ? strlen(text) : 0) + strlen(section) + strlen(key) + (value ? strlen(value) : 0) + 64; char *out = malloc(cap); size_t o = 0; bool in = false, done = false, sawSection = false;
  for (const char *line = text; line && *line;) {
    const char *end = strchr(line, '\n'); size_t len = end ? (size_t)(end - line + 1) : strlen(line);
    char l[1024]; snprintf(l, sizeof l, "%.*s", (int)(len < 1023 ? len : 1023), line); char *s = l; while (isspace((unsigned char)*s)) s++;
    if (*s == '[') { if (in && !done && value) { o += (size_t)sprintf(out + o, "%s=%s\r\n", key, value); done = true; } char *e = strchr(s, ']'); if (e) *e = 0; in = !strcasecmp(s + 1, section); if (in) sawSection = true; }
    else if (in && !done) { char *eq = strchr(s, '='); if (eq) { *eq = 0; size_t kl = strlen(s); while (kl && isspace((unsigned char)s[kl - 1])) s[--kl] = 0; if (!strcasecmp(s, key)) { if (value) o += (size_t)sprintf(out + o, "%s=%s\r\n", key, value); done = true; line += len; continue; } } }
    memcpy(out + o, line, len); o += len; line += len;
  }
  if (!done && value) { if (!sawSection) o += (size_t)sprintf(out + o, "[%s]\r\n", section); o += (size_t)sprintf(out + o, "%s=%s\r\n", key, value); }
  char p[1100]; hostPath(file, p, sizeof p); FILE *f = fopen(p, "wb"); if (f) { fwrite(out, 1, o, f); fclose(f); }
  free(out); free(text); return f != 0;
}
// user32 / shlwapi
static uint8_t polledKeys[256], polledThisFrame[256];
static uint8_t keysClosed[256], keysOpen[256], keysOpening[256], keysHinted[256];
static uint32_t frameDraws, tickNumber, lastPressed[256];
static uint64_t lastModKeyUs;  // when the player last pressed a key for the mods (the Mod keys pad presses Windows keys)
// ASI_TRACE=n: log n import calls (from game frame ASI_TRACE_FRAME on, or from the first mod key with
// ASI_TRACE_FRAME=key) and the game commands' results, for debugging a mod.
static long traceLeft = -1, traceFrom;
static bool tracing(void) {
  if (traceLeft < 0) {
    const char *from = getenv("ASI_TRACE_FRAME");
    traceLeft = getenv("ASI_TRACE") ? atol(getenv("ASI_TRACE")) : 0;
    traceFrom = !from ? 0 : !strcmp(from, "key") ? LONG_MAX : atol(from);
  }
  return traceLeft > 0 && (long)tickNumber >= traceFrom;
}
static bool menuVisible;
// Keys a player chose to answer a mod's key (Settings › Mods › the mod's keys, GTA-181): the mod asks about modKey and
// sees whether key is down; keyboard handlers get key's events as modKey's, and modKey's own not at all. By .asi
// file name, set from the main thread before or while the mods run.
static pthread_mutex_t remapLock = PTHREAD_MUTEX_INITIALIZER;
static struct { char module[64]; uint8_t modKey, key; } remaps[64]; static volatile int remapCount;
void pg_asi_set_key_remap(const char *module, int modKey, int key) {
  if (modKey <= 0 || modKey > 255 || key <= 0 || key > 255) return;
  pthread_mutex_lock(&remapLock);
  if (remapCount < 64) { snprintf(remaps[remapCount].module, 64, "%s", module); remaps[remapCount].modKey = (uint8_t)modKey; remaps[remapCount].key = (uint8_t)key; remapCount++; }
  pthread_mutex_unlock(&remapLock);
}
void pg_asi_clear_key_remaps(void) { pthread_mutex_lock(&remapLock); remapCount = 0; pthread_mutex_unlock(&remapLock); }
// For a module: the key that answers its modKey (forward), or the modKey that key answers (backward); 0 when none.
static int remapped(int module, int vk, bool forward) {
  if (!remapCount || module < 0 || module >= moduleCount) return 0;
  int found = 0; pthread_mutex_lock(&remapLock);
  for (int i = 0; i < remapCount && !found; i++)
    if ((forward ? remaps[i].modKey : remaps[i].key) == vk && !strcasecmp(remaps[i].module, modules[module].name)) found = forward ? remaps[i].key : remaps[i].modKey;
  pthread_mutex_unlock(&remapLock); return found;
}
// Keys each mod asked about while it ran (the mod's keys list in Settings shows them as "seen while playing").
static uint8_t polledByModule[16][256];
static uint64_t u_GetAsyncKeyState(void) {
  int vk = (int)(ARG(0) & 255), module = cur ? cur->module : -1, key = remapped(module, vk, true);
  if (!key) key = vk;
  if (module >= 0 && module < 16) polledByModule[module][vk] = 1;
  polledKeys[key] = 1; polledThisFrame[key] = 1; return H.key_down && H.key_down(key) ? 0x8000 : 0;
}
static uint64_t s_PathFindFileNameA(void) { uint64_t p = ARG(0), last = p; for (uint64_t a = p; *G(a); a++) if (*G(a) == '\\' || *G(a) == '/') last = a + 1; return last; }

// ---- Script Hook V ----------------------------------------------------------------------------
static uint64_t v_scriptRegister(void) {
  uint64_t module = ARG(0), fn = ARG(1); Co *co = newCo(fn, 0, true, moduleIndex(module)); if (!co) return 0;
  startCall(co, fn, 0, 0); co->state = CO_READY;
  Module *mod = moduleAt(module); logf_("ASI %s: script registered.", mod ? mod->name : "?"); return 0;
}
static uint64_t v_scriptUnregister(void) {
  uint64_t x = ARG(0); for (int i = 0; i < threadCount; i++) if (threads[i]->script && (threads[i]->entry == x || moduleAt(threads[i]->entry) == moduleAt(x))) threads[i]->state = CO_DEAD;
  return 0;
}
static uint64_t v_scriptWait(void) { cur->wakeAt = now_us() + (uint64_t)(uint32_t)ARG(0) * 1000; cur->state = CO_WAIT; cur->yield = true; return 0; }
static uint64_t v_keyboardHandlerRegister(void) { if (keyboardCount < 8) keyboardHandlers[keyboardCount++] = ARG(0); return 0; }
static uint64_t v_keyboardHandlerUnregister(void) { for (int i = 0; i < keyboardCount; i++) if (keyboardHandlers[i] == ARG(0)) keyboardHandlers[i] = keyboardHandlers[--keyboardCount]; return 0; }
static uint64_t v_nativeInit(void) { cur->hash = ARG(0); cur->argc = 0; return 0; }
static uint64_t v_nativePush64(void) { if (cur->argc < 32) cur->args[cur->argc++] = ARG(0); return 0; }
static uint64_t nativeArgs;  // guest copy of the arguments
static uint64_t v_nativeCall(void) {
  if (!nativeArgs) nativeArgs = galloc(8 * 32);
  // DRAW_RECT, DRAW_SPRITE, END_TEXT_COMMAND_DISPLAY_TEXT: a mod drawing its menu (Mod keys pad).
  if (cur->hash == 0x3a618a217e5154f0ull || cur->hash == 0xe7ffae5ebf23d890ull || cur->hash == 0xcd015e5bb0d96a57ull) frameDraws++;
  memcpy(G(nativeArgs), cur->args, 8 * cur->argc); memset(G(cur->result), 0, 64);
  // IS_USING_KEYBOARD_AND_MOUSE: on a PC the game says yes once the player presses a key, and the Mod keys pad presses
  // Windows keys, so for half a minute after a mod key the answer is yes. Desktop Menyoo only reads its F8 then; when
  // the game says no keyboard it waits for its controller button combination instead (GTA-188).
  if (cur->hash == 0xa571d46727e2b718ull && lastModKeyUs && now_us() - lastModKeyUs < 30000000) { wr64(cur->result, 1); return cur->result; }
  if (!H.native(cur->hash, nativeArgs, cur->argc, cur->result)) {
    static uint64_t told[64]; static int toldCount; bool seen = false;
    for (int i = 0; i < toldCount; i++) if (told[i] == cur->hash) seen = true;
    if (!seen && toldCount < 64) { told[toldCount++] = cur->hash; logf_("ASI: game command 0x%016llx isn't in this game version; it does nothing.", (unsigned long long)cur->hash); }
  }
  if (tracing()) logf_("ASI trace: game command 0x%016llx = 0x%llx", (unsigned long long)cur->hash, (unsigned long long)rd64(cur->result));
  return cur->result;
}
static uint64_t v_getGlobalPtr(void) { return H.global ? H.global((int)ARG(0)) : 0; }
static uint64_t v_worldGetAll(int kind) { return H.world_entities ? H.world_entities(kind, ARG(0), (uint32_t)ARG(1)) : 0; }
static uint64_t v_worldGetAllVehicles(void) { return v_worldGetAll(0); }
static uint64_t v_worldGetAllPeds(void) { return v_worldGetAll(1); }
static uint64_t v_worldGetAllObjects(void) { return v_worldGetAll(2); }
static uint64_t v_getGameVersion(void) { return (uint64_t)H.game_version; }
static uint64_t v_minusOne(void) { return (uint64_t)-1; }

// The Microsoft C/C++ runtime (UCRT, VCRUNTIME140, MSVCP140) for mods built with /MD, and C++ exceptions (GTA-188).
#include "NativeASIRuntime.inc"

static const Import imports[] = {
  {"HeapAlloc", k_HeapAlloc}, {"HeapFree", k_HeapFree}, {"HeapSize", k_HeapSize}, {"HeapReAlloc", k_HeapReAlloc}, {"GetProcessHeap", k_GetProcessHeap}, {"HeapCreate", k_HeapCreate}, {"HeapDestroy", k_HeapDestroy}, {"HeapValidate", k_HeapValidate},
  {"VirtualAlloc", k_VirtualAlloc}, {"VirtualFree", k_VirtualFree}, {"VirtualProtect", k_VirtualProtect}, {"VirtualQuery", k_VirtualQuery},
  {"GetModuleHandleA", k_GetModuleHandleA}, {"GetModuleHandleW", k_GetModuleHandleW}, {"GetModuleHandleExW", k_GetModuleHandleExW},
  {"GetModuleFileNameA", k_GetModuleFileNameA}, {"GetModuleFileNameW", k_GetModuleFileNameW}, {"K32GetModuleInformation", K32GetModuleInformation_},
  {"GetProcAddress", k_GetProcAddress}, {"LoadLibraryA", k_LoadLibraryA}, {"LoadLibraryW", k_LoadLibraryW}, {"LoadLibraryExW", k_LoadLibraryW}, {"FreeLibrary", k_one},
  {"GetCurrentThreadId", k_GetCurrentThreadId}, {"GetCurrentProcessId", k_GetCurrentProcessId}, {"GetCurrentProcess", k_GetCurrentProcess},
  {"Sleep", k_Sleep}, {"CreateThread", k_CreateThread},
  {"InitializeCriticalSectionEx", k_one}, {"InitializeCriticalSectionAndSpinCount", k_one}, {"InitializeCriticalSection", k_one}, {"EnterCriticalSection", unimplemented},
  {"LeaveCriticalSection", unimplemented}, {"DeleteCriticalSection", unimplemented}, {"AcquireSRWLockExclusive", unimplemented}, {"ReleaseSRWLockExclusive", unimplemented},
  {"AcquireSRWLockShared", unimplemented}, {"ReleaseSRWLockShared", unimplemented}, {"WakeAllConditionVariable", unimplemented}, {"WakeConditionVariable", unimplemented},
  {"SleepConditionVariableSRW", k_one},
  {"TlsAlloc", k_TlsAlloc}, {"TlsGetValue", k_TlsGetValue}, {"TlsSetValue", k_TlsSetValue}, {"TlsFree", k_one},
  {"FlsAlloc", k_FlsAlloc}, {"FlsGetValue", k_FlsGetValue}, {"FlsGetValue2", k_FlsGetValue}, {"AreFileApisANSI", k_one},
  {"GetTimeZoneInformation", k_GetTimeZoneInformation}, {"DeleteFileW", k_DeleteFileW}, {"RtlUnwind", k_RaiseException}, {"FlsSetValue", k_FlsSetValue}, {"FlsFree", k_one},
  {"GetLastError", k_GetLastError}, {"SetLastError", k_SetLastError}, {"EncodePointer", k_EncodePointer}, {"DecodePointer", k_EncodePointer},
  {"InitializeSListHead", k_InitializeSListHead}, {"InterlockedFlushSList", k_InterlockedFlushSList},
  {"GetTickCount", k_GetTickCount}, {"GetTickCount64", k_GetTickCount}, {"QueryPerformanceCounter", k_QueryPerformanceCounter}, {"QueryPerformanceFrequency", k_QueryPerformanceFrequency},
  {"GetSystemTimeAsFileTime", k_GetSystemTimeAsFileTime}, {"GetSystemTimePreciseAsFileTime", k_GetSystemTimeAsFileTime}, {"GetLocalTime", k_GetLocalTime},
  {"GetCommandLineA", k_GetCommandLineA}, {"GetCommandLineW", k_GetCommandLineW}, {"GetEnvironmentStringsW", k_GetEnvironmentStringsW}, {"FreeEnvironmentStringsW", k_one},
  {"GetEnvironmentVariableA", k_GetEnvironmentVariableA}, {"SetEnvironmentVariableW", k_one}, {"GetStartupInfoW", k_GetStartupInfoW}, {"GetSystemInfo", k_GetSystemInfo},
  {"IsProcessorFeaturePresent", k_IsProcessorFeaturePresent}, {"IsDebuggerPresent", unimplemented}, {"ExitProcess", k_ExitProcess}, {"TerminateProcess", k_ExitProcess},
  {"RaiseException", k_RaiseException}, {"SetUnhandledExceptionFilter", unimplemented}, {"UnhandledExceptionFilter", unimplemented},
  {"RtlCaptureContext", unimplemented}, {"RtlLookupFunctionEntry", unimplemented}, {"RtlVirtualUnwind", unimplemented}, {"RtlUnwindEx", k_RaiseException}, {"RtlPcToFileHeader", unimplemented},
  {"GetACP", k_GetACP}, {"GetOEMCP", k_GetOEMCP}, {"IsValidCodePage", k_one}, {"GetCPInfo", k_GetCPInfo}, {"MultiByteToWideChar", k_MultiByteToWideChar}, {"WideCharToMultiByte", k_WideCharToMultiByte},
  {"LCMapStringEx", k_LCMapStringEx}, {"LCMapStringW", k_LCMapStringW}, {"GetStringTypeW", k_GetStringTypeW}, {"CompareStringW", k_CompareStringW},
  {"IsValidLocale", k_one}, {"GetUserDefaultLCID", k_GetUserDefaultLCID}, {"EnumSystemLocalesW", k_one},
  {"CreateFileW", k_CreateFileW}, {"CreateFileA", k_CreateFileA}, {"ReadFile", k_ReadFile}, {"WriteFile", k_WriteFile}, {"WriteConsoleW", k_WriteConsoleW}, {"ReadConsoleW", unimplemented},
  {"CloseHandle", k_CloseHandle}, {"GetFileSizeEx", k_GetFileSizeEx}, {"SetFilePointerEx", k_SetFilePointerEx}, {"SetEndOfFile", k_SetEndOfFile}, {"FlushFileBuffers", k_one},
  {"GetFileType", k_GetFileType}, {"GetStdHandle", k_GetStdHandle}, {"SetStdHandle", k_one}, {"GetConsoleMode", k_GetConsoleMode}, {"GetConsoleOutputCP", k_GetConsoleOutputCP},
  {"DeleteFileA", k_DeleteFileA}, {"CreateDirectoryA", k_CreateDirectoryA}, {"CopyFileA", k_CopyFileA}, {"GetFileAttributesA", k_GetFileAttributesA},
  {"FindFirstFileA", k_FindFirstFileA}, {"FindFirstFileExW", k_FindFirstFileExW}, {"FindNextFileA", k_FindNextFileA}, {"FindNextFileW", k_FindNextFileW}, {"FindClose", k_CloseHandle},
  {"GetFullPathNameW", k_GetFullPathNameW}, {"GetCurrentDirectoryW", k_GetCurrentDirectoryW}, {"GetDriveTypeW", k_GetDriveTypeW},
  {"GetPrivateProfileStringA", k_GetPrivateProfileStringA}, {"GetPrivateProfileIntA", k_GetPrivateProfileIntA}, {"WritePrivateProfileStringA", k_WritePrivateProfileStringA},
  {"GetAsyncKeyState", u_GetAsyncKeyState}, {"GetKeyState", u_GetAsyncKeyState}, {"PathFindFileNameA", s_PathFindFileNameA},
  {"scriptRegister", v_scriptRegister}, {"scriptRegisterAdditionalThread", v_scriptRegister}, {"scriptUnregister", v_scriptUnregister}, {"scriptWait", v_scriptWait},
  {"keyboardHandlerRegister", v_keyboardHandlerRegister}, {"keyboardHandlerUnregister", v_keyboardHandlerUnregister},
  {"nativeInit", v_nativeInit}, {"nativePush64", v_nativePush64}, {"nativeCall", v_nativeCall}, {"getGlobalPtr", v_getGlobalPtr},
  {"worldGetAllVehicles", v_worldGetAllVehicles}, {"worldGetAllPeds", v_worldGetAllPeds}, {"worldGetAllObjects", v_worldGetAllObjects}, {"worldGetAllPickups", unimplemented},
  {"getGameVersion", v_getGameVersion}, {"getScriptHandleBaseAddress", unimplemented}, {"createTexture", v_minusOne}, {"drawTexture", unimplemented},
  {"presentCallbackRegister", unimplemented}, {"presentCallbackUnregister", unimplemented},
};
// "?nativeInit@@YAX_K@Z" -> "nativeInit"
static void plainName(const char *name, char *out, size_t cap) {
  if (name[0] == '?') { const char *at = strchr(name + 1, '@'); size_t n = at ? (size_t)(at - name - 1) : strlen(name + 1); snprintf(out, cap, "%.*s", (int)n, name + 1); }
  else snprintf(out, cap, "%s", name);
}
// The host function for an import: C++ library functions by their full decorated name first (their plain names
// collide: every basic_ostream::operator<< is "?6?$basic_ostream"), then by plain name (Script Hook V's
// decorated names, kernel32, the C runtime).
static Fn importFn(const char *name) {
  for (size_t i = 0; i < sizeof cppImports / sizeof *cppImports; i++) if (!strcmp(cppImports[i].name, name)) return cppImports[i].fn;
  char plain[128]; plainName(name, plain, sizeof plain);
  for (size_t i = 0; i < sizeof imports / sizeof *imports; i++) if (!strcmp(imports[i].name, plain)) return imports[i].fn;
  for (size_t i = 0; i < sizeof crtImports / sizeof *crtImports; i++) if (!strcmp(crtImports[i].name, plain)) return crtImports[i].fn;
  return 0;
}
static uint64_t stubFor(const char *name) {
  for (int i = 0; i < stubCount; i++) if (!strcmp(stubName[i], name)) return stubs + 16 * (uint64_t)(ID_FIRST + i);
  if (stubCount >= 4000) return 0;
  Fn fn = importFn(name);
  stubName[stubCount] = strdup(name); stubFn[stubCount] = fn;
  uint64_t at = stubs + 16 * (uint64_t)(ID_FIRST + stubCount); uint32_t id = (uint32_t)(ID_FIRST + stubCount);
  uint8_t code[16] = {0xB8, (uint8_t)id, (uint8_t)(id >> 8), (uint8_t)(id >> 16), (uint8_t)(id >> 24), 0x0F, 0x05, 0xC3, 0xCC, 0xCC, 0xCC, 0xCC, 0xCC, 0xCC, 0xCC, 0xCC};
  memcpy(G(at), code, 16); stubCount++; return at;
}
static bool onSyscall(struct Machine *m) {
  uint32_t id = (uint32_t)Get64(m->ax);
  if (!cur || m != cur->m) return false;
  if (id == ID_EXIT) { cur->finished = true; cur->yield = true; if (cur->script) cur->state = CO_DEAD; return true; }
  int i = (int)id - ID_FIRST;
  if (i < 0 || i >= stubCount) { logf_("ASI: unknown system call %u; this script is stopped.", id); cur->state = CO_DEAD; cur->yield = true; return true; }
  if (!stubFn[i]) {
    static char told[4096]; if (!told[i]) { told[i] = 1; logf_("ASI: Windows function %s isn't available on iOS; it returns 0.", stubName[i]); }
    Put64(m->ax, 0); return true;
  }
  // An import may set the machine's registers itself (a C++ throw jumping to a catch block): then RAX is left as
  // it set it. A throw that left a nested call made by this import goes on here, outside that call (GTA-188).
  if (tracing()) {
    traceLeft--; uint64_t from = rd64(Get64(m->sp)); Module *mod = moduleAt(from);
    logf_("ASI trace: %s(0x%llx, 0x%llx, 0x%llx) from %s+0x%llx", stubName[i], (unsigned long long)Get64(m->cx), (unsigned long long)Get64(m->dx), (unsigned long long)Get64(m->r8),
          mod ? mod->name : "?", (unsigned long long)(mod ? from - mod->base : from));
  }
  int depth = cur->nestDepth; rawReturn = false; thrown = false;
  uint64_t value = stubFn[i]();
  if (cur->pending && cur->pending->resumeDepth == depth) { continuePending(); return true; }
  if (!rawReturn) Put64(m->ax, value);
  return true;
}

// ---- Faults ---------------------------------------------------------------------------------
// A mod that touches memory outside the engine's (a null pointer, say) faults on the host. While
// a mod's code runs, that fault stops only its script; any other fault goes to whoever handled
// it before (the engine uses these signals itself for its memory guards).
static struct sigaction previousSegv, previousBus;
// Mesh release (GTA-152/GTA-217) keeps the pages it has handed back protected and puts one back when anything touches
// it, through its own fault handler, installed before this one. A fault on such a page while a script runs (the mod
// reading game memory, or game code a native runs) is the engine's, not the mod's: it goes to that handler, and the
// access runs again. Before (GTA-244), this handler took it, stopped the script and jumped out of whatever was running,
// game code included, leaving its locks and stack behind; with mode 3 on every iPhone (it also hands back pages that
// hold up to 1 KB of other game data) Menyoo stopped the app within minutes.
int PGMeshReleaseOn(void);
static void onFault(int sig, siginfo_t *info, void *context) {
  uintptr_t at = (uintptr_t)info->si_addr, low = (uintptr_t)H.memory;
  if (PGMeshReleaseOn() && at >= low && at - low < H.size) {
    struct sigaction *old = sig == SIGBUS ? &previousBus : &previousSegv;
    if (old->sa_flags & SA_SIGINFO) { old->sa_sigaction(sig, info, context); return; }
  }
  if (running && pthread_equal(pthread_self(), runner) && cur && cur->m->canhalt) {
    cur->m->faultaddr = (i64)((uintptr_t)info->si_addr - (uintptr_t)H.memory);
    siglongjmp(cur->m->onhalt, kMachineSegmentationFault);
  }
  struct sigaction *old = sig == SIGBUS ? &previousBus : &previousSegv;
  if (old->sa_flags & SA_SIGINFO) old->sa_sigaction(sig, info, context);
  else if (old->sa_handler != SIG_DFL && old->sa_handler != SIG_IGN) old->sa_handler(sig);
  else { sigaction(sig, old, 0); raise(sig); }
}
static void installFaultHandler(void) {
  struct sigaction sa; memset(&sa, 0, sizeof sa); sa.sa_sigaction = onFault; sa.sa_flags = SA_SIGINFO | SA_ONSTACK; sigemptyset(&sa.sa_mask);
  sigaction(SIGSEGV, &sa, &previousSegv); sigaction(SIGBUS, &sa, &previousBus);
}

// ---- Loader -----------------------------------------------------------------------------------
bool pg_asi_init(const PGAsiHost *host) {
  H = *host; pg_blink_skew = (uintptr_t)H.memory; pg_blink_low = 0x10000; pg_blink_high = H.size;
  if (!pg_blink_sink) pg_blink_sink = calloc(1, 0x2000);
  static bool blinkReady; if (!blinkReady) { WriteErrorInit(); InitMap(); InitBus(); blinkReady = true; }
  if (!(sys = NewSystem(XED_MACHINE_MODE_LONG))) return false;
  pg_blink_syscall_hook = onSyscall; installFaultHandler();
  stubs = galloc(16 * 4096); exitStub = stubs;
  uint8_t exitCode[16] = {0x49, 0x89, 0xC2, 0xB8, 0, 0, 0, 0, 0x0F, 0x05, 0xF4};  // mov r10, rax (the result); mov eax, 0; syscall; hlt
  memcpy(G(exitStub), exitCode, 11);
  fakeExe = galloc(0x1000); memcpy(G(fakeExe), "MZ", 2);
  cmdA = galloc(16); memcpy(G(cmdA), "GTA5.exe", 9);
  cmdW = galloc(32); for (int i = 0; i < 9; i++) wr16(cmdW + 2 * (uint64_t)i, (uint8_t)"GTA5.exe"[i]);
  envW = galloc(8);
  return runtimeInit();
}
// A mod's menu key from its settings: trainers that take keys through a Script Hook V keyboard handler
// never ask about them, but their .ini files name them ("MenuKey=114", "OpenKey=0x77", "ToggleKey=F8").
static int keyFromName(const char *v) {
  while (*v == ' ' || *v == '\t') v++;
  if ((v[0] == 'F' || v[0] == 'f') && v[1] >= '1' && v[1] <= '9') { int n = atoi(v + 1); if (n >= 1 && n <= 24) return 0x6F + n; }
  if (v[0] == '0' && (v[1] == 'x' || v[1] == 'X')) return (int)strtol(v, 0, 16);
  if (v[0] >= '0' && v[0] <= '9') return atoi(v);
  return 0;
}
static void hintKeys(const char *folder, int depth) {
  DIR *dir = opendir(folder); struct dirent *entry; if (!dir) return;
  while ((entry = readdir(dir))) {
    size_t n = strlen(entry->d_name);
    if (entry->d_name[0] != '.' && entry->d_type == DT_DIR && depth == 0) {   // the mod's own folder (Menyoo: menyooStuff)
      char sub[1200]; snprintf(sub, sizeof sub, "%s/%s", folder, entry->d_name); hintKeys(sub, 1); continue;
    }
    if (n < 5 || strcasecmp(entry->d_name + n - 4, ".ini")) continue;
    char path[1200]; snprintf(path, sizeof path, "%s/%s", folder, entry->d_name);
    FILE *f = fopen(path, "r"); if (!f) continue; char line[512];
    while (fgets(line, sizeof line, f)) {
      char *eq = strchr(line, '='); if (!eq) continue; *eq = 0;
      char key[128]; size_t k = 0; for (char *c = line; *c && k < sizeof key - 1; c++) if (*c != ' ' && *c != '\t' && *c != '_' && *c != '-') key[k++] = (char)tolower((unsigned char)*c);
      key[k] = 0;
      // Only settings that mean "open the menu": MenuKey, OpenKey, MenuOpenKey, ToggleMenuKey...
      static const char *names[] = {"menukey", "openkey", "menuopenkey", "openmenukey", "togglekey", "togglemenukey", "menutogglekey",
                                     "keymenu", "keyopen", "openmenu", "menuopen", "togglemenu", "menutoggle", "menuhotkey", "openmenuhotkey"};
      bool wanted = false; for (size_t i = 0; i < sizeof names / sizeof *names; i++) if (!strcmp(key, names[i])) wanted = true;
      if (!wanted) continue;
      int vk = keyFromName(eq + 1);
      if (vk > 0 && vk < 256) { keysHinted[vk] = 1; logf_("ASI: %s names key 0x%02x as a menu key.", entry->d_name, vk); }
    }
    fclose(f);
  }
  closedir(dir);
}
// Desktop Menyoo (GTA-188) keeps "the submenu to open next" in a variable that starts at 0 instead of "none" (-1),
// so the frame after the first F8 it opens submenu 0, which is "closed": the menu shows for one frame and F8 has to
// be pressed again. Menyoo's own iOS build starts it at -1; this does the same for the desktop build. The variable
// is found by the one place that uses it: mov ecx, [x]; cmp ecx, -1; je over; call; mov dword [x], -1.
static void menyooFirstOpen(const Module *mod) {
  if (strncasecmp(mod->name, "Menyoo", 6)) return;
  const uint8_t *image = G(mod->base);
  for (uint64_t i = 0; i + 26 <= mod->size; i++) {
    const uint8_t *p = image + i;
    if (p[0] != 0x8B || p[1] != 0x0D || p[6] != 0x83 || p[7] != 0xF9 || p[8] != 0xFF || p[9] != 0x74 || p[10] != 0x0F || p[11] != 0xE8 ||
        p[16] != 0xC7 || p[17] != 0x05 || rd32(mod->base + i + 22) != 0xFFFFFFFFu) continue;
    uint64_t x = mod->base + i + 6 + (uint64_t)(int64_t)(int32_t)rd32(mod->base + i + 2), y = mod->base + i + 26 + (uint64_t)(int64_t)(int32_t)rd32(mod->base + i + 18);
    if (x != y || x < mod->base || x + 4 > mod->base + mod->size || rd32(x) != 0) continue;
    wr32(x, 0xFFFFFFFFu); logf_("ASI %s: its menu now opens on the first key press.", mod->name); return;
  }
}
int pg_asi_load(const char *name, const char *root, const uint8_t *bytes, uint64_t length) {
  #define BAD(why) do { logf_("ASI %s: %s; not loaded.", name, why); return 0; } while (0)
  if (moduleCount >= 16) BAD("too many mods");
  if (length < 0x200 || bytes[0] != 'M' || bytes[1] != 'Z') BAD("not a Windows DLL");
  uint32_t pe; memcpy(&pe, bytes + 0x3C, 4); if (pe + 264 > length || memcmp(bytes + pe, "PE\0\0", 4)) BAD("not a Windows DLL");
  uint16_t machine, sections, optionalSize, magic; memcpy(&machine, bytes + pe + 4, 2); memcpy(&sections, bytes + pe + 6, 2); memcpy(&optionalSize, bytes + pe + 20, 2);
  uint64_t opt = pe + 24; memcpy(&magic, bytes + opt, 2);
  if (machine != 0x8664 || magic != 0x20B) BAD("not a 64-bit Windows DLL");
  uint32_t entry, sizeOfImage, sizeOfHeaders; uint64_t imageBase;
  memcpy(&entry, bytes + opt + 16, 4); memcpy(&imageBase, bytes + opt + 24, 8); memcpy(&sizeOfImage, bytes + opt + 56, 4); memcpy(&sizeOfHeaders, bytes + opt + 60, 4);
  uint64_t raw = H.alloc((uint64_t)sizeOfImage + 0x10000); if (!raw) BAD("not enough memory");
  uint64_t base = (raw + 0xFFFF) & ~0xFFFFull; memset(G(base), 0, sizeOfImage);
  memcpy(G(base), bytes, sizeOfHeaders < length ? sizeOfHeaders : length);
  for (uint16_t i = 0; i < sections; i++) {
    uint64_t s = opt + optionalSize + 40ull * i; uint32_t vsize, va, rawSize, rawAt;
    memcpy(&vsize, bytes + s + 8, 4); memcpy(&va, bytes + s + 12, 4); memcpy(&rawSize, bytes + s + 16, 4); memcpy(&rawAt, bytes + s + 20, 4);
    if ((uint64_t)va + (rawSize < vsize || !vsize ? rawSize : vsize) > sizeOfImage || (uint64_t)rawAt + rawSize > length) BAD("damaged section table");
    memcpy(G(base + va), bytes + rawAt, rawSize < vsize || !vsize ? rawSize : vsize);
  }
  #define DIR(n) rd32(base + opt + 112 + 8 * (n)), rd32(base + opt + 112 + 8 * (n) + 4)
  uint32_t relocAt, relocSize, importAt, importSize, tlsAt, tlsSize;
  { uint32_t d[2] = {DIR(5)}; relocAt = d[0]; relocSize = d[1]; }
  { uint32_t d[2] = {DIR(1)}; importAt = d[0]; importSize = d[1]; }
  { uint32_t d[2] = {DIR(9)}; tlsAt = d[0]; tlsSize = d[1]; }
  (void)importSize; (void)tlsSize;
  int64_t delta = (int64_t)(base - imageBase);
  for (uint64_t block = base + relocAt; relocSize && block < base + relocAt + relocSize;) {
    uint32_t page = rd32(block), size = rd32(block + 4); if (size < 8) break;
    for (uint32_t k = 8; k + 2 <= size; k += 2) {
      uint16_t e = rd16(block + k); uint64_t at = base + page + (e & 0xFFF);
      if (e >> 12 == 10) wr64(at, rd64(at) + (uint64_t)delta); else if (e >> 12 == 3) wr32(at, rd32(at) + (uint32_t)delta);
    }
    block += size;
  }
  int missing = 0; char missingList[512] = "";
  for (uint64_t d = base + importAt; importAt && rd32(d + 12); d += 20) {
    const char *dll = (const char *)G(base + rd32(d + 12)); uint64_t lookup = base + (rd32(d) ? rd32(d) : rd32(d + 16)), iat = base + rd32(d + 16);
    for (uint64_t k = 0;; k++) {
      uint64_t t = rd64(lookup + 8 * k); if (!t) break;
      char name[400]; if (t >> 63) snprintf(name, sizeof name, "%s#%u", dll, (unsigned)(t & 0xFFFF)); else snprintf(name, sizeof name, "%s", (const char *)G(base + (t & 0x7FFFFFFF) + 2));
      // Data exports (the C++ library's locale ids) get a cell of guest memory; functions get a stub.
      uint64_t cell = dataImport(name), stub = cell ? cell : stubFor(name); wr64(iat + 8 * k, stub);
      char plain[128]; plainName(name, plain, sizeof plain); bool known = cell || importFn(name);
      if (!known) { missing++; if (strlen(missingList) < 400) { strcat(missingList, missingList[0] ? ", " : ""); strcat(missingList, plain); } }
    }
  }
  if (missing) logf_("ASI %s: %d Windows function%s not available on iOS (they return 0): %s", name, missing, missing == 1 ? "" : "s", missingList);
  Module *mod = &modules[moduleCount++]; snprintf(mod->name, sizeof mod->name, "%s", name); snprintf(mod->root, sizeof mod->root, "%s", root ? root : H.files);
  hintKeys(mod->root, 0); mod->base = base; mod->size = sizeOfImage; mod->entry = entry ? base + entry : 0;
  { uint32_t d[2] = {DIR(3)}; mod->pdata = d[0] ? base + d[0] : 0; mod->pdataCount = d[0] && (uint64_t)d[0] + d[1] <= sizeOfImage ? d[1] / 12 : 0; }
  if (tlsAt) {
    uint64_t t = base + tlsAt; mod->tlsStart = rd64(t); mod->tlsEnd = rd64(t + 8); mod->tlsIndexAddress = rd64(t + 16); mod->tlsZero = rd32(t + 32);
    wr32(mod->tlsIndexAddress, (uint32_t)(moduleCount - 1));
    for (uint64_t cb = rd64(t + 24); cb && rd64(cb); cb += 8) callGuest(rd64(cb), (uint64_t[]){base, 1, 0}, 3);
  }
  logf_("ASI %s: loaded at 0x%llx (%u KB).", name, (unsigned long long)base, sizeOfImage / 1024);
  menyooFirstOpen(mod);
  if (mod->entry) {
    uint64_t ok = callGuest(mod->entry, (uint64_t[]){base, 1, 0}, 3);
    if (!(uint32_t)ok) { logf_("ASI %s: its start-up (DllMain) reported failure; not loaded.", name); mod->dead = true; return 0; }
  }
  return moduleCount;
}
void pg_asi_tick(void) {
  uint64_t start = now_us(), t = start; ticks_instructions = 0;
  for (int i = 0; i < threadCount; i++) {
    Co *co = threads[i];
    if (co->state == CO_WAIT && t >= co->wakeAt) co->state = CO_READY;
    if (co->state == CO_READY && co->script) run(co);
  }
  tick_us = now_us() - start;
  // Mod keys: a menu is on screen when the mods drew a fair amount this frame. Keys checked now are
  // menu keys (navigation) or not (hotkeys); a key pressed just before a menu appeared opens it.
  bool visible = frameDraws >= 4;
  static int drawDebug = -1; if (drawDebug < 0) drawDebug = getenv("ASI_DEBUG_DRAWS") != 0;  // ASI_DEBUG_DRAWS: when a mod menu shows and goes
  if (drawDebug && visible != menuVisible) logf_("ASI: frame %u: a mod menu is %s (%u draws).", tickNumber, visible ? "drawn" : "gone", frameDraws);
  if (visible && !menuVisible) for (int k = 1; k < 256; k++) if (lastPressed[k] && tickNumber - lastPressed[k] < 20 && keysOpening[k] < 255) keysOpening[k]++;
  menuVisible = visible; frameDraws = 0; tickNumber++;
  for (int k = 1; k < 256; k++) if (polledThisFrame[k]) { uint8_t *count = visible ? &keysOpen[k] : &keysClosed[k]; if (*count < 255) (*count)++; polledThisFrame[k] = 0; }
  static int debug = -1; if (debug < 0) debug = getenv("ASI_DEBUG") != 0;
  if (debug) for (int i = 0; i < threadCount; i++) { Co *co = threads[i]; Module *mod = moduleAt(co->m->ip);
    logf_("  thread %d: state %d script %d wait %lld ms ip %s+0x%llx", i, co->state, co->script, co->state == CO_WAIT ? (long long)(co->wakeAt - now_us()) / 1000 : 0LL, mod ? "mod" : "?", (unsigned long long)(mod ? co->m->ip - mod->base : co->m->ip)); }
}
void pg_asi_key_info(PGAsiKeyInfo *info) {
  memcpy(info->closed, keysClosed, 256); memcpy(info->open, keysOpen, 256); memcpy(info->opens, keysOpening, 256); memcpy(info->hinted, keysHinted, 256);
  // A menu key answered by another key (GTA-181): the pad offers that key too.
  pthread_mutex_lock(&remapLock);
  for (int i = 0; i < remapCount; i++) if (keysHinted[remaps[i].modKey] && !info->hinted[remaps[i].key]) info->hinted[remaps[i].key] = keysHinted[remaps[i].modKey];
  pthread_mutex_unlock(&remapLock);
  info->menuVisible = menuVisible; info->keyboardHandler = keyboardCount > 0;
}
void pg_asi_key(int vk, bool down) {
  if (down && vk > 0 && vk < 256) lastPressed[vk] = tickNumber ? tickNumber : 1;
  lastModKeyUs = now_us();
  tracing(); if (traceFrom == LONG_MAX) traceFrom = tickNumber;
  for (int i = 0; i < keyboardCount; i++) {
    int module = moduleIndex(keyboardHandlers[i]), key = remapped(module, vk, false);
    if (!key) { if (remapped(module, vk, true)) continue; key = vk; }  // a key answered by another one isn't its own any more
    if (getenv("ASI_TRACE")) logf_("ASI trace: key 0x%02x %s to the keyboard handler at +0x%llx", key, down ? "down" : "up", (unsigned long long)(module >= 0 ? keyboardHandlers[i] - modules[module].base : keyboardHandlers[i]));
    callGuest(keyboardHandlers[i], (uint64_t[]){(uint64_t)key, 1, 0, 0, 0, down ? 0 : 1, down ? 0 : 1}, 7);
  }
}
bool pg_asi_polled_keys(uint8_t polled[256]) { memcpy(polled, polledKeys, 256); return keyboardCount > 0; }
bool pg_asi_module_keys(const char *name, uint8_t polled[256], bool *keyboardHandler) {
  for (int m = 0; m < moduleCount && m < 16; m++) {
    if (strcasecmp(modules[m].name, name)) continue;
    memcpy(polled, polledByModule[m], 256);
    *keyboardHandler = false; for (int i = 0; i < keyboardCount; i++) if (moduleIndex(keyboardHandlers[i]) == m) *keyboardHandler = true;
    return true;
  }
  return false;
}
void pg_asi_stats(uint64_t *us, uint64_t *instructions) { *us = tick_us; *instructions = ticks_instructions; }
// Blink delivers an unhandled guest signal here (its own main() would end the process): only
// the mod's script stops.
void TerminateSignal(struct Machine *m, int sig, int code) {
  (void)code; Module *mod = moduleAt(m->ip);
  logf_("ASI %s: stopped by signal %d at +0x%llx.", mod ? mod->name : "?", sig, (unsigned long long)(mod ? m->ip - mod->base : m->ip));
  if (cur) { cur->state = CO_DEAD; cur->yield = true; }
  if (m->canhalt) siglongjmp(m->onhalt, kMachineHalt);
}
