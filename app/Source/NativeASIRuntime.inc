// The Microsoft C/C++ runtime for script mods built with /MD (GTA-188). Included by NativeASI.c.
//
// Mods built with Visual Studio's default settings (/MD) don't carry their own C runtime: they import it from the
// Universal CRT (api-ms-win-crt-*.dll), VCRUNTIME140.dll and MSVCP140.dll. This file answers those imports: the
// heap (malloc on the same guest heap as HeapAlloc), the start-up that runs a DLL's global constructors, stdio on
// the mod's folder, printf/scanf formatting, strings, math, time, C++ exceptions (a throw finds its catch block by
// walking the mod's stack with its x64 unwind data and __CxxFrameHandler4/3 tables, and runs the destructors on the
// way), RTTI (dynamic_cast), and the parts of the C++ library such mods call (iostreams, locale, mutexes, the std
// exceptions). Objects live in guest memory with Microsoft's layouts. Where the runtime calls back into a mod (a
// global constructor, a qsort comparator, a stream buffer's virtual function, a destructor during a throw) it runs
// that guest code nested on the script's own machine and stack (guestCall), as the real DLLs would.
#include <float.h>
#include <locale.h>
#include <math.h>
#include <xlocale.h>

static bool rawReturn;  // the import set the machine's registers itself (a throw, the end of a catch block): RAX stays
static bool thrown;     // the import started a C++ throw: it returns at once, and nothing after it may run guest code

// ---- Registers -------------------------------------------------------------------------------
// Windows x64: the first four arguments are in RCX, RDX, R8, R9, or XMM0-3 when they are floating point (by
// position); a double or float result goes back in XMM0.
static double argD(int n) { double v; memcpy(&v, cur->m->xmm[n], 8); return v; }
static float argF(int n) { float v; memcpy(&v, cur->m->xmm[n], 4); return v; }
static uint64_t retD(double v) { memset(cur->m->xmm[0], 0, 16); memcpy(cur->m->xmm[0], &v, 8); return 0; }
static uint64_t retF(float v) { memset(cur->m->xmm[0], 0, 16); memcpy(cur->m->xmm[0], &v, 4); return 0; }
static const char *gstr(uint64_t a) { return a ? (const char *)G(a) : ""; }
#define S(a) ((char *)G(a))
// The return address of the import being answered, and the module it is in (for log lines).
static uint64_t callerIp(void) { return rd64(Get64(cur->m->sp)); }
static const char *callerName(uint64_t *offset) { uint64_t ip = callerIp(); Module *mod = moduleAt(ip); *offset = mod ? ip - mod->base : ip; return mod ? mod->name : "?"; }

// Stubs for the runtime's own code addresses: vtable entries of objects it makes (a std::exception's what()), and the
// return points of nested calls and catch blocks. The return points keep the returning function's RAX in R10, as
// exitStub does ("mov r10, rax; mov eax, id; syscall; hlt").
static uint64_t hostStub(const char *name, Fn fn) {
  uint64_t at = stubFor(name); if (!at) return 0;
  stubFn[(at - stubs) / 16 - ID_FIRST] = fn; return at;
}
static uint64_t returnStub(const char *name, Fn fn) {
  uint64_t at = hostStub(name, fn); if (!at) return 0;
  uint32_t id = (uint32_t)((at - stubs) / 16);
  uint8_t code[16] = {0x49, 0x89, 0xC2, 0xB8, (uint8_t)id, (uint8_t)(id >> 8), (uint8_t)(id >> 16), (uint8_t)(id >> 24), 0x0F, 0x05, 0xF4, 0xCC, 0xCC, 0xCC, 0xCC, 0xCC};
  memcpy(G(at), code, 16); return at;
}

// ---- Stopping a script -----------------------------------------------------------------------
// Ends the running script at once (the caller has logged why): run() catches this like a fault.
static void stopScript(void) {
  if (!cur) return;
  cur->state = CO_DEAD; cur->yield = true;
  if (cur->m->canhalt) siglongjmp(cur->m->onhalt, HALT_QUIET);
}
static void fatalStop(const char *why) {
  uint64_t at; const char *name = callerName(&at);
  logf_("ASI %s: %s (called at +0x%llx); this script is stopped.", name, why, (unsigned long long)at);
  stopScript();
}

// ---- Nested calls into the mod ---------------------------------------------------------------
// guestCall runs a guest function to its end on the script's own machine, below the import's caller on the same
// stack, while the import that asked for it waits (the real runtime DLLs simply call the function). A C++ exception
// thrown inside and not caught there: NEST_PASS lets it go on past the import into the mod's own catch blocks;
// NEST_CATCH stops it here like a catch (...) in the runtime (the call reports it, the iostreams set badbit);
// NEST_STOP ends the script (an exception leaving a destructor or filter that the runtime called during a throw).
enum { NEST_PASS, NEST_CATCH, NEST_STOP };
typedef struct Nest {
  struct Nest *outer; int depth, kind;
  uint64_t site;              // stack pointer once the called function has returned (it returns to nestStub)
  uint64_t sp, ip;            // the import's stack pointer and next instruction, put back afterwards
  uint8_t regs[16][8], xmm[16][16];
  bool done, threw, caught;
} Nest;
static uint64_t nestStub, catchStub;  // return points of a nested call and of a catch block
static uint64_t stackFloor;  // while a throw is handled: the thrown object lives on the guest stack above this address
static uint64_t r_nestReturn(void) {
  Nest *n = cur->nest; rawReturn = true;
  if (n && Get64(cur->m->sp) == n->site) n->done = true;
  else { logf_("ASI: a call from the Windows runtime returned to the wrong place; this script is stopped."); stopScript(); }
  return 0;
}
static uint64_t guestCallAs(int kind, uint64_t fn, const uint64_t *a, int n, bool *caught) {
  Co *co = cur; struct Machine *m = co->m;
  if (caught) *caught = false;
  if (!fn || ((co->pending || thrown) && kind != NEST_STOP)) return 0;  // an exception is leaving the import: no more mod code
  Nest nest; memset(&nest, 0, sizeof nest);
  nest.outer = co->nest; nest.depth = co->nestDepth + 1; nest.kind = kind;
  memcpy(nest.regs, m->weg, sizeof nest.regs); memcpy(nest.xmm, m->xmm, sizeof nest.xmm);
  nest.ip = m->ip; nest.sp = Get64(m->sp);
  // Windows x64 call: 32 bytes of shadow space, arguments 5+ above it, the return address below.
  uint64_t top = nest.sp; if (stackFloor && stackFloor < top) top = stackFloor;
  uint64_t extra = n > 4 ? (uint64_t)(n - 4) : 0, site = (top - 256 - 32 - 8 * extra) & ~15ull;
  for (uint64_t i = 0; i < extra; i++) wr64(site + 32 + 8 * i, a[4 + i]);
  wr64(site - 8, nestStub); Put64(m->sp, site - 8); nest.site = site;
  Put64(m->cx, n > 0 ? a[0] : 0); Put64(m->dx, n > 1 ? a[1] : 0); Put64(m->r8, n > 2 ? a[2] : 0); Put64(m->r9, n > 3 ? a[3] : 0);
  m->ip = fn;
  co->nest = &nest; co->nestDepth++;
  bool raw = rawReturn, threw = thrown; uint64_t floor = stackFloor; stackFloor = 0;
  uint64_t count = 0;
  while (!nest.done) {
    ExecuteInstruction(m);
    if (co->state == CO_DEAD) stopScript();  // ExitProcess or the like inside: its import logged why
    if (++count >= 3000000000ull) {
      Module *mod = moduleAt(m->ip);
      logf_("ASI %s: a function called back from the Windows runtime ran too long (at +0x%llx); this script is stopped.", mod ? mod->name : "?", (unsigned long long)(mod ? m->ip - mod->base : m->ip));
      stopScript();
    }
  }
  ticks_instructions += count;
  stackFloor = floor; rawReturn = raw; thrown = threw;
  co->nest = nest.outer; co->nestDepth--;
  uint64_t result = Get64(m->r10);
  memcpy(m->weg, nest.regs, sizeof nest.regs); memcpy(m->xmm, nest.xmm, sizeof nest.xmm); m->ip = nest.ip;
  if (caught) *caught = nest.caught;
  return nest.threw || nest.caught ? 0 : result;
}
static uint64_t guestCall(uint64_t fn, const uint64_t *a, int n) { return guestCallAs(NEST_PASS, fn, a, n, 0); }
static uint64_t guestSafe(uint64_t fn, const uint64_t *a, int n) { return guestCallAs(NEST_STOP, fn, a, n, 0); }
#define GUEST(fn, ...) guestCall((fn), (uint64_t[]){__VA_ARGS__}, sizeof((uint64_t[]){__VA_ARGS__}) / 8)
#define GUEST_SAFE(fn, ...) guestSafe((fn), (uint64_t[]){__VA_ARGS__}, sizeof((uint64_t[]){__VA_ARGS__}) / 8)
// After a nested call: true when an exception left it and the import must return at once.
static bool leaving(void) { return cur->pending || thrown; }

// ---- Per-thread values -----------------------------------------------------------------------
// errno and friends live in the script thread's TEB block (makeTeb leaves 0x1F00-0x1FFF free).
#define TEB_ERRNO 0x1F00
#define TEB_DOSERRNO 0x1F04
#define TEB_CUR_EXCEPTION 0x1F08  // __current_exception(): the EXCEPTION_RECORD being handled
#define TEB_CUR_CONTEXT 0x1F10    // __current_exception_context()
#define TEB_STRTOK 0x1F18         // strtok's position
#define TEB_TM 0x1F20             // localtime/gmtime's result (36 bytes)
static void setErrno(int e) { if (cur) wr32(cur->teb + TEB_ERRNO, (uint32_t)e); }
static uint64_t c_errno(void) { return cur->teb + TEB_ERRNO; }
static uint64_t c_doserrno(void) { return cur->teb + TEB_DOSERRNO; }
static uint64_t c_set_errno(void) { setErrno((int)ARG(0)); return 0; }
static uint64_t c_get_errno(void) { if (ARG(0)) wr32(ARG(0), rd32(cur->teb + TEB_ERRNO)); return 0; }
static int hostErrno(int e) { return e == ENOENT ? 2 : e == EACCES || e == EPERM ? 13 : e == EEXIST ? 17 : e == ENOTDIR ? 20 : e == EISDIR ? 21 : e == ENOTEMPTY ? 41 : e == ENOSPC ? 28 : e == ERANGE ? 34 : 22; }

// ---- Heap (api-ms-win-crt-heap) ---------------------------------------------------------------
// The same blocks as HeapAlloc (a 16-byte header with the size), so memory from one may be freed by the other.
static uint64_t c_malloc(void) { uint64_t a = heapAlloc(ARG(0), false); if (!a) setErrno(12); return a; }
static uint64_t c_calloc(void) { uint64_t n = ARG(0), s = ARG(1); if (s && n > UINT64_MAX / 2 / s) { setErrno(12); return 0; } uint64_t a = heapAlloc(n * s, true); if (!a) setErrno(12); return a; }
static uint64_t c_free(void) { if (ARG(0)) H.free(ARG(0) - HEADER); return 0; }
static uint64_t c_msize(void) { return ARG(0) ? rd64(ARG(0) - HEADER) : (uint64_t)-1; }
static uint64_t reallocBlock(uint64_t old, uint64_t size) {
  if (!old) return heapAlloc(size, false);
  if (!size) { H.free(old - HEADER); return 0; }
  uint64_t was = rd64(old - HEADER), fresh = heapAlloc(size, false); if (!fresh) { setErrno(12); return 0; }
  memcpy(G(fresh), G(old), was < size ? was : size); H.free(old - HEADER); return fresh;
}
static uint64_t c_realloc(void) { return reallocBlock(ARG(0), ARG(1)); }
static uint64_t c_recalloc(void) {
  uint64_t old = ARG(0), size = ARG(1) * ARG(2), was = old ? rd64(old - HEADER) : 0, fresh = reallocBlock(old, size);
  if (fresh && size > was) memset(G(fresh + was), 0, size - was);
  return fresh;
}
// _aligned_malloc: the block from malloc sits just before the aligned address (kept at address - 8).
static uint64_t alignedAlloc(uint64_t size, uint64_t align) {
  if (!align || (align & (align - 1))) { setErrno(22); return 0; }
  if (align < 8) align = 8;
  uint64_t raw = heapAlloc(size + align + 8, false); if (!raw) { setErrno(12); return 0; }
  uint64_t p = (raw + 8 + align - 1) & ~(align - 1); wr64(p - 8, raw); return p;
}
static uint64_t c_aligned_malloc(void) { return alignedAlloc(ARG(0), ARG(1)); }
static uint64_t c_aligned_free(void) { if (ARG(0)) H.free(rd64(ARG(0) - 8) - HEADER); return 0; }
static uint64_t c_aligned_realloc(void) {
  uint64_t old = ARG(0), size = ARG(1), fresh = size ? alignedAlloc(size, ARG(2)) : 0;
  if (old && fresh) { uint64_t raw = rd64(old - 8), avail = rd64(raw - HEADER) - (old - raw); memcpy(G(fresh), G(old), avail < size ? avail : size); }
  if (old && (fresh || !size)) H.free(rd64(old - 8) - HEADER);
  return fresh;
}
static uint64_t c_callnewh(void) { return 0; }  // no new-handler installed: operator new throws std::bad_alloc

// ---- Start-up and shutdown (api-ms-win-crt-runtime) -------------------------------------------
// A DLL's CRT entry runs its C initializers (_initterm_e) and global constructors (_initterm), then DllMain.
static uint64_t c_initterm(void) {
  uint64_t p = ARG(0), end = ARG(1);
  for (; p < end; p += 8) { uint64_t fn = rd64(p); if (fn) { guestCall(fn, 0, 0); if (leaving()) return 0; } }
  return 0;
}
static uint64_t c_initterm_e(void) {
  uint64_t p = ARG(0), end = ARG(1);
  for (; p < end; p += 8) { uint64_t fn = rd64(p); if (fn) { int r = (int)guestCall(fn, 0, 0); if (leaving()) return 0; if (r) return (uint64_t)(int64_t)r; } }
  return 0;
}
// atexit tables: {first, last, end} pointers to an array of functions (the DLL's global destructors).
static uint64_t c_initialize_onexit_table(void) { uint64_t t = ARG(0); if (!t) return (uint64_t)-1; if (rd64(t) == rd64(t + 16)) { wr64(t, 0); wr64(t + 8, 0); wr64(t + 16, 0); } return 0; }
static uint64_t onexitAdd(uint64_t t, uint64_t fn) {
  uint64_t first = rd64(t), last = rd64(t + 8), end = rd64(t + 16);
  if (last == end) {
    uint64_t count = first ? (end - first) / 8 : 0, grown = heapAlloc((count ? count * 2 : 32) * 8, true); if (!grown) return (uint64_t)-1;
    if (first) { memcpy(G(grown), G(first), count * 8); H.free(first - HEADER); }
    first = grown; last = grown + count * 8; end = grown + (count ? count * 2 : 32) * 8;
  }
  wr64(last, fn); wr64(t, first); wr64(t + 8, last + 8); wr64(t + 16, end); return 0;
}
static uint64_t c_register_onexit_function(void) { return ARG(0) ? onexitAdd(ARG(0), ARG(1)) : (uint64_t)-1; }
static uint64_t c_execute_onexit_table(void) {
  uint64_t t = ARG(0); if (!t) return (uint64_t)-1;
  uint64_t first = rd64(t), last = rd64(t + 8); wr64(t, 0); wr64(t + 8, 0); wr64(t + 16, 0);
  while (first && last > first) { last -= 8; uint64_t fn = rd64(last); if (fn) { guestCall(fn, 0, 0); if (leaving()) return 0; } }
  if (first) H.free(first - HEADER);
  return 0;
}
static uint64_t exitTable;  // atexit() of an .exe-style mod: kept, never run (the game doesn't end a mod)
static uint64_t c_crt_atexit(void) { if (!exitTable) exitTable = galloc(24); return onexitAdd(exitTable, ARG(0)); }
static uint64_t c_zero(void) { return 0; }
static uint64_t argcCell, argvCell;
static uint64_t c_p_argc(void) { return argcCell; }
static uint64_t c_p_argv(void) { return argvCell; }
static uint64_t c_terminate(void) { fatalStop("the mod called terminate() (a C++ error it could not handle)"); return 0; }
static uint64_t c_abort(void) { fatalStop("the mod called abort()"); return 0; }
static uint64_t c_exit(void) { fatalStop("the mod tried to quit the game (exit)"); return 0; }
static uint64_t c_invoke_watson(void) { fatalStop("the C runtime found an invalid parameter or a damaged heap block"); return 0; }
static uint64_t c_purecall(void) { fatalStop("the mod called a pure virtual function"); return 0; }
static uint64_t c_endthread(void) { cur->state = CO_DEAD; cur->yield = true; return 0; }
static uint64_t c_configthreadlocale(void) { return 2; }  // _DISABLE_PER_THREAD_LOCALE: one locale ("C") for everyone

// ---- Strings (api-ms-win-crt-string, VCRUNTIME140) ---------------------------------------------
// Pointers come back as guest addresses: a host result inside the argument maps back by its offset.
#define BACK(a, p) ((p) ? (a) + (uint64_t)((const char *)(p) - (const char *)G(a)) : 0)
static int lower(int c) { return c >= 'A' && c <= 'Z' ? c + 32 : c; }
static int upper(int c) { return c >= 'a' && c <= 'z' ? c - 32 : c; }
static uint64_t ires(int v) { return (uint64_t)(int64_t)v; }
static uint64_t c_memcpy(void) { if (ARG(2)) memmove(G(ARG(0)), G(ARG(1)), ARG(2)); return ARG(0); }
static uint64_t c_memset(void) { if (ARG(2)) memset(G(ARG(0)), (int)ARG(1), ARG(2)); return ARG(0); }
static uint64_t c_memcmp(void) { return ARG(2) ? ires(memcmp(G(ARG(0)), G(ARG(1)), ARG(2))) : 0; }
static uint64_t c_memchr(void) { return ARG(2) ? BACK(ARG(0), memchr(G(ARG(0)), (int)(ARG(1) & 255), ARG(2))) : 0; }
static uint64_t c_memcpy_s(void) {
  uint64_t dst = ARG(0), cap = ARG(1), src = ARG(2), n = ARG(3);
  if (!n) return 0;
  if (!dst || !src || cap < n) { if (dst && cap) memset(G(dst), 0, cap); return 22; }
  memmove(G(dst), G(src), n); return 0;
}
static uint64_t c_strlen(void) { return strlen(S(ARG(0))); }
static uint64_t c_strnlen(void) { return strnlen(S(ARG(0)), ARG(1)); }
static uint64_t c_strcmp(void) { return ires(strcmp(S(ARG(0)), S(ARG(1)))); }
static uint64_t c_strncmp(void) { return ires(strncmp(S(ARG(0)), S(ARG(1)), ARG(2))); }
static int icmp(const char *a, const char *b, size_t n) {
  for (size_t i = 0; i < n; i++) { int x = lower((unsigned char)a[i]), y = lower((unsigned char)b[i]); if (x != y || !x) return x - y; }
  return 0;
}
static uint64_t c_stricmp(void) { return ires(icmp(S(ARG(0)), S(ARG(1)), SIZE_MAX)); }
static uint64_t c_strnicmp(void) { return ires(icmp(S(ARG(0)), S(ARG(1)), ARG(2))); }
static uint64_t c_strcpy(void) { memmove(G(ARG(0)), G(ARG(1)), strlen(S(ARG(1))) + 1); return ARG(0); }
static uint64_t c_strncpy(void) { uint64_t n = ARG(2), len = strnlen(S(ARG(1)), n); memmove(G(ARG(0)), G(ARG(1)), len); if (len < n) memset(G(ARG(0) + len), 0, n - len); return ARG(0); }
static uint64_t c_strcat(void) { uint64_t d = ARG(0) + strlen(S(ARG(0))); memmove(G(d), G(ARG(1)), strlen(S(ARG(1))) + 1); return ARG(0); }
static uint64_t c_strncat(void) { uint64_t d = ARG(0) + strlen(S(ARG(0))), len = strnlen(S(ARG(1)), ARG(2)); memmove(G(d), G(ARG(1)), len); *G(d + len) = 0; return ARG(0); }
static uint64_t c_strchr(void) { return BACK(ARG(0), strchr(S(ARG(0)), (int)(ARG(1) & 255))); }
static uint64_t c_strrchr(void) { return BACK(ARG(0), strrchr(S(ARG(0)), (int)(ARG(1) & 255))); }
static uint64_t c_strstr(void) { return BACK(ARG(0), strstr(S(ARG(0)), S(ARG(1)))); }
static uint64_t c_strpbrk(void) { return BACK(ARG(0), strpbrk(S(ARG(0)), S(ARG(1)))); }
static uint64_t c_strspn(void) { return strspn(S(ARG(0)), S(ARG(1))); }
static uint64_t c_strcspn(void) { return strcspn(S(ARG(0)), S(ARG(1))); }
static uint64_t gstrdup(const char *s) { size_t n = strlen(s) + 1; uint64_t a = heapAlloc(n, false); if (a) memcpy(G(a), s, n); return a; }
static uint64_t c_strdup(void) { return ARG(0) ? gstrdup(S(ARG(0))) : 0; }
static uint64_t c_strlwr(void) { for (char *s = S(ARG(0)); *s; s++) *s = (char)lower((unsigned char)*s); return ARG(0); }
static uint64_t c_strupr(void) { for (char *s = S(ARG(0)); *s; s++) *s = (char)upper((unsigned char)*s); return ARG(0); }
static uint64_t c_strlwr_s(void) { for (char *s = S(ARG(0)); *s; s++) *s = (char)lower((unsigned char)*s); return 0; }
static uint64_t c_strupr_s(void) { for (char *s = S(ARG(0)); *s; s++) *s = (char)upper((unsigned char)*s); return 0; }
// The _s copies: on a buffer too small they empty the destination and return ERANGE (Windows calls the invalid
// parameter handler first, which ends the program; here the mod just sees the error).
static uint64_t c_strcpy_s(void) {
  uint64_t d = ARG(0), cap = ARG(1), s = ARG(2); if (!d || !cap) return 22; if (!s) { *G(d) = 0; return 22; }
  size_t n = strlen(S(s)); if (n >= cap) { *G(d) = 0; return 34; }
  memmove(G(d), G(s), n + 1); return 0;
}
static uint64_t c_strcat_s(void) {
  uint64_t d = ARG(0), cap = ARG(1), s = ARG(2); if (!d || !cap) return 22;
  size_t have = strnlen(S(d), cap); if (have == cap || !s) { *G(d) = 0; return 22; }
  size_t n = strlen(S(s)); if (have + n >= cap) { *G(d) = 0; return 34; }
  memmove(G(d + have), G(s), n + 1); return 0;
}
static uint64_t c_strncpy_s(void) {
  uint64_t d = ARG(0), cap = ARG(1), s = ARG(2), count = ARG(3); if (!d || !cap) return 22;
  if (!s) { *G(d) = 0; return count ? 22 : 0; }
  bool truncate = count == (uint64_t)-1; size_t n = strnlen(S(s), truncate ? cap : count);
  if (n >= cap) { if (truncate) { memmove(G(d), G(s), cap - 1); *G(d + cap - 1) = 0; return 80; } *G(d) = 0; return 34; }
  memmove(G(d), G(s), n); *G(d + n) = 0; return 0;
}
static uint64_t c_strtok_at(uint64_t s, uint64_t delim, uint64_t ctxCell) {
  if (!s) s = rd64(ctxCell); if (!s) return 0;
  const char *d = S(delim); while (*G(s) && strchr(d, *G(s))) s++;
  if (!*G(s)) { wr64(ctxCell, 0); return 0; }
  uint64_t start = s; while (*G(s) && !strchr(d, *G(s))) s++;
  if (*G(s)) { *G(s) = 0; wr64(ctxCell, s + 1); } else wr64(ctxCell, s);
  return start;
}
static uint64_t c_strtok(void) { return c_strtok_at(ARG(0), ARG(1), cur->teb + TEB_STRTOK); }
static uint64_t c_strtok_s(void) { return c_strtok_at(ARG(0), ARG(1), ARG(2)); }
// <ctype.h> in the "C" locale.
static uint64_t c_tolower(void) { return ires(lower((int)ARG(0))); }
static uint64_t c_toupper(void) { return ires(upper((int)ARG(0))); }
#define CTYPE(name, test) static uint64_t c_##name(void) { int c = (int)ARG(0); return c >= 0 && c < 128 && test(c) ? 1 : 0; }
CTYPE(isalnum, isalnum) CTYPE(isalpha, isalpha) CTYPE(isdigit, isdigit) CTYPE(isxdigit, isxdigit) CTYPE(isspace, isspace)
CTYPE(isupper, isupper) CTYPE(islower, islower) CTYPE(isprint, isprint) CTYPE(ispunct, ispunct) CTYPE(iscntrl, iscntrl)
CTYPE(isgraph, isgraph) CTYPE(isblank, isblank)
static uint64_t c_isascii(void) { return ARG(0) < 128; }
// _mbsicmp: multibyte strings in the "C" locale's single-byte code page compare like _stricmp.
static uint64_t c_mbsicmp(void) { return ires(icmp(S(ARG(0)), S(ARG(1)), SIZE_MAX)); }
// Wide strings (UTF-16).
static uint64_t c_wcslen(void) { return wlen(ARG(0)); }
static int wcmp(uint64_t a, uint64_t b, size_t n, bool fold) {
  for (size_t i = 0; i < n; i++) {
    int x = rd16(a + 2 * i), y = rd16(b + 2 * i); if (fold) { x = lower(x); y = lower(y); }
    if (x != y || !x) return x - y;
  }
  return 0;
}
static uint64_t c_wcscmp(void) { return ires(wcmp(ARG(0), ARG(1), SIZE_MAX, false)); }
static uint64_t c_wcsncmp(void) { return ires(wcmp(ARG(0), ARG(1), ARG(2), false)); }
static uint64_t c_wcsicmp(void) { return ires(wcmp(ARG(0), ARG(1), SIZE_MAX, true)); }
static uint64_t c_wcsnicmp(void) { return ires(wcmp(ARG(0), ARG(1), ARG(2), true)); }
static uint64_t c_wcscpy(void) { memmove(G(ARG(0)), G(ARG(1)), 2 * (wlen(ARG(1)) + 1)); return ARG(0); }
static uint64_t c_wcscat(void) { uint64_t d = ARG(0) + 2 * wlen(ARG(0)); memmove(G(d), G(ARG(1)), 2 * (wlen(ARG(1)) + 1)); return ARG(0); }
static uint64_t c_wcsncpy(void) { uint64_t n = ARG(2), i = 0; for (; i < n && rd16(ARG(1) + 2 * i); i++) wr16(ARG(0) + 2 * i, rd16(ARG(1) + 2 * i)); for (; i < n; i++) wr16(ARG(0) + 2 * i, 0); return ARG(0); }
static uint64_t c_wcscpy_s(void) {
  uint64_t d = ARG(0), cap = ARG(1), s = ARG(2); if (!d || !cap) return 22; if (!s) { wr16(d, 0); return 22; }
  size_t n = wlen(s); if (n >= cap) { wr16(d, 0); return 34; }
  memmove(G(d), G(s), 2 * (n + 1)); return 0;
}
static uint64_t c_wcscat_s(void) {
  uint64_t d = ARG(0), cap = ARG(1), s = ARG(2); if (!d || !cap || !s) return 22;
  size_t have = wlen(d), n = wlen(s); if (have + n >= cap) { wr16(d, 0); return 34; }
  memmove(G(d + 2 * have), G(s), 2 * (n + 1)); return 0;
}
static uint64_t c_wcschr(void) { for (uint64_t p = ARG(0);; p += 2) { uint16_t c = rd16(p); if (c == (uint16_t)ARG(1)) return p; if (!c) return 0; } }
static uint64_t c_wcsrchr(void) { uint64_t found = 0; for (uint64_t p = ARG(0);; p += 2) { uint16_t c = rd16(p); if (c == (uint16_t)ARG(1)) found = p; if (!c) return found; } }
static uint64_t c_wcsstr(void) {
  uint64_t h = ARG(0), n = ARG(1); size_t ln = wlen(n); if (!ln) return h;
  for (; rd16(h); h += 2) if (!memcmp(G(h), G(n), 2 * ln)) return h;
  return 0;
}
static uint64_t c_wcsdup(void) { size_t n = 2 * (wlen(ARG(0)) + 1); uint64_t a = heapAlloc(n, false); if (a) memcpy(G(a), G(ARG(0)), n); return a; }
static uint64_t c_towlower(void) { return lower((int)(ARG(0) & 0xFFFF)); }
static uint64_t c_towupper(void) { return upper((int)(ARG(0) & 0xFFFF)); }
static uint64_t c_iswspace(void) { int c = (int)(ARG(0) & 0xFFFF); return c < 128 && isspace(c); }
static uint64_t c_iswalpha(void) { int c = (int)(ARG(0) & 0xFFFF); return c < 128 ? isalpha(c) != 0 : c >= 0xC0; }
static uint64_t c_iswdigit(void) { int c = (int)(ARG(0) & 0xFFFF); return c >= '0' && c <= '9'; }
static uint64_t c_iswalnum(void) { int c = (int)(ARG(0) & 0xFFFF); return c < 128 ? isalnum(c) != 0 : c >= 0xC0; }
// Multibyte <-> wide in the "C" locale: bytes are their own code points (Latin-1), as MultiByteToWideChar(CP_ACP).
static uint64_t mbToW(uint64_t dst, uint64_t src, uint64_t max) {
  size_t n = strlen(S(src)); if (!dst) return n;
  uint64_t i = 0; for (; i < n && i < max; i++) wr16(dst + 2 * i, *G(src + i)); if (i < max) wr16(dst + 2 * i, 0);
  return i;
}
static uint64_t wToMb(uint64_t dst, uint64_t src, uint64_t max) {
  size_t n = wlen(src); if (!dst) return n;
  uint64_t i = 0; for (; i < n && i < max; i++) { uint16_t c = rd16(src + 2 * i); *G(dst + i) = c < 256 ? (uint8_t)c : '?'; } if (i < max) *G(dst + i) = 0;
  return i;
}
static uint64_t c_mbstowcs(void) { return mbToW(ARG(0), ARG(1), ARG(2)); }
static uint64_t c_wcstombs(void) { return wToMb(ARG(0), ARG(1), ARG(2)); }
static uint64_t c_mbstowcs_s(void) { uint64_t n = mbToW(ARG(1), ARG(3), ARG(1) ? ARG(2) - 1 : 0); if (ARG(0)) wr64(ARG(0), n + 1); return 0; }
static uint64_t c_wcstombs_s(void) { uint64_t n = wToMb(ARG(1), ARG(3), ARG(1) ? ARG(2) - 1 : 0); if (ARG(0)) wr64(ARG(0), n + 1); return 0; }

// ---- Number conversions (api-ms-win-crt-convert) ---------------------------------------------
// Windows sizes: long and unsigned long are 32 bits. The digits are read here so the limits and errno (ERANGE) are
// Windows' for each type; the result is sign-extended into RAX for the signed ones.
static int digitOf(int c) { return c >= '0' && c <= '9' ? c - '0' : c >= 'a' && c <= 'z' ? c - 'a' + 10 : c >= 'A' && c <= 'Z' ? c - 'A' + 10 : 99; }
static uint64_t parseInt(const char *p0, size_t *used, int base, bool isSigned, int bits) {
  const char *p = p0; *used = 0;
  while (*p == ' ' || (*p >= '\t' && *p <= '\r')) p++;
  bool neg = false; if (*p == '+' || *p == '-') neg = *p++ == '-';
  if ((base == 0 || base == 16) && p[0] == '0' && (p[1] == 'x' || p[1] == 'X') && digitOf((unsigned char)p[2]) < 16) { p += 2; base = 16; }
  else if (base == 0) base = p[0] == '0' ? 8 : 10;
  if (base < 2 || base > 36) { setErrno(22); return 0; }
  uint64_t v = 0; bool overflow = false; const char *digits = p;
  for (;; p++) { int d = digitOf((unsigned char)*p); if (d >= base) break; if (v > (UINT64_MAX - (uint64_t)d) / (uint64_t)base) overflow = true; else v = v * (uint64_t)base + (uint64_t)d; }
  if (p == digits) return 0;
  *used = (size_t)(p - p0);
  uint64_t max = bits == 64 ? UINT64_MAX : (1ull << bits) - 1;
  if (isSigned) {
    uint64_t limit = (max >> 1) + (neg ? 1 : 0);
    if (overflow || v > limit) { setErrno(34); return neg ? (uint64_t)-(int64_t)limit : limit; }
    int64_t r = neg ? -(int64_t)v : (int64_t)v; return (uint64_t)r;
  }
  if (overflow || v > max) { setErrno(34); return max; }
  return neg ? (uint64_t)(-(int64_t)v) & max : v;
}
static uint64_t strtoInt(bool isSigned, int bits) {
  size_t used; uint64_t v = parseInt(S(ARG(0)), &used, (int)ARG(2), isSigned, bits);
  if (ARG(1)) wr64(ARG(1), ARG(0) + used);
  return isSigned && bits == 32 ? (uint64_t)(int64_t)(int32_t)v : v;
}
static uint64_t c_strtol(void) { return strtoInt(true, 32); }
static uint64_t c_strtoul(void) { return strtoInt(false, 32); }
static uint64_t c_strtoll(void) { return strtoInt(true, 64); }
static uint64_t c_strtoull(void) { return strtoInt(false, 64); }
static uint64_t c_atoi(void) { size_t used; return (uint64_t)(int64_t)(int32_t)parseInt(S(ARG(0)), &used, 10, true, 32); }
static uint64_t c_atoll(void) { size_t used; return parseInt(S(ARG(0)), &used, 10, true, 64); }
static locale_t cLocale(void) { static locale_t c; if (!c) c = newlocale(LC_ALL_MASK, "C", 0); return c; }
static double parseDouble(const char *s, size_t *used) {
  char *end; errno = 0; double v = strtod_l(s, &end, cLocale()); *used = (size_t)(end - s);
  if (errno == ERANGE) setErrno(34);
  return v;
}
static uint64_t c_strtod(void) { size_t used; double v = parseDouble(S(ARG(0)), &used); if (ARG(1)) wr64(ARG(1), ARG(0) + used); return retD(v); }
static uint64_t c_strtof(void) {
  size_t used; double v = parseDouble(S(ARG(0)), &used); if (ARG(1)) wr64(ARG(1), ARG(0) + used);
  if (isfinite(v) && fabs(v) > FLT_MAX) setErrno(34);
  return retF((float)v);
}
static uint64_t c_atof(void) { size_t used; return retD(parseDouble(S(ARG(0)), &used)); }
// Wide versions: the digits are ASCII, so they are read through a narrow copy.
static void narrowCopy(uint64_t w, char *out, size_t cap) { size_t i = 0; for (; i + 1 < cap; i++) { uint16_t c = rd16(w + 2 * i); if (!c) break; out[i] = c < 128 ? (char)c : '?'; } out[i] = 0; }
static uint64_t wstrtoInt(bool isSigned, int bits) {
  char s[128]; narrowCopy(ARG(0), s, sizeof s); size_t used; uint64_t v = parseInt(s, &used, (int)ARG(2), isSigned, bits);
  if (ARG(1)) wr64(ARG(1), ARG(0) + 2 * used);
  return isSigned && bits == 32 ? (uint64_t)(int64_t)(int32_t)v : v;
}
static uint64_t c_wcstol(void) { return wstrtoInt(true, 32); }
static uint64_t c_wcstoul(void) { return wstrtoInt(false, 32); }
static uint64_t c_wcstoll(void) { return wstrtoInt(true, 64); }
static uint64_t c_wcstoull(void) { return wstrtoInt(false, 64); }
static uint64_t c_wcstod(void) { char s[256]; narrowCopy(ARG(0), s, sizeof s); size_t used; double v = parseDouble(s, &used); if (ARG(1)) wr64(ARG(1), ARG(0) + 2 * used); return retD(v); }
static uint64_t c_wtoi(void) { char s[128]; narrowCopy(ARG(0), s, sizeof s); size_t used; return (uint64_t)(int64_t)(int32_t)parseInt(s, &used, 10, true, 32); }
static uint64_t c_wtof(void) { char s[256]; narrowCopy(ARG(0), s, sizeof s); size_t used; return retD(parseDouble(s, &used)); }
// _itoa and friends: value, buffer, (size,) radix.
static void toText(uint64_t v, bool neg, int radix, char *out) {
  char tmp[72]; int n = 0; if (radix < 2 || radix > 36) radix = 10;
  do { int d = (int)(v % (uint64_t)radix); tmp[n++] = (char)(d < 10 ? '0' + d : 'a' + d - 10); v /= (uint64_t)radix; } while (v);
  int o = 0; if (neg) out[o++] = '-'; while (n) out[o++] = tmp[--n]; out[o] = 0;
}
static uint64_t itoaTo(uint64_t dst, uint64_t cap, int64_t value, bool isSigned, int bits, int radix) {
  uint64_t u = bits == 32 ? (uint32_t)value : (uint64_t)value; bool neg = false;
  if (isSigned && radix == 10 && value < 0) { neg = true; u = (uint64_t)(-(bits == 32 ? (int64_t)(int32_t)value : value)); }
  char text[72]; toText(u, neg, radix, text); size_t n = strlen(text);
  if (n >= cap) { if (cap) *G(dst) = 0; return 34; }
  memcpy(G(dst), text, n + 1); return 0;
}
static uint64_t c_itoa(void) { itoaTo(ARG(1), 66, (int64_t)ARG(0), true, 32, (int)ARG(2)); return ARG(1); }
static uint64_t c_ultoa(void) { itoaTo(ARG(1), 66, (int64_t)ARG(0), false, 32, (int)ARG(2)); return ARG(1); }
static uint64_t c_i64toa(void) { itoaTo(ARG(1), 66, (int64_t)ARG(0), true, 64, (int)ARG(2)); return ARG(1); }
static uint64_t c_ui64toa(void) { itoaTo(ARG(1), 66, (int64_t)ARG(0), false, 64, (int)ARG(2)); return ARG(1); }
static uint64_t c_itoa_s(void) { return itoaTo(ARG(1), ARG(2), (int64_t)ARG(0), true, 32, (int)ARG(3)); }
static uint64_t c_i64toa_s(void) { return itoaTo(ARG(1), ARG(2), (int64_t)ARG(0), true, 64, (int)ARG(3)); }
static uint64_t c_ui64toa_s(void) { return itoaTo(ARG(1), ARG(2), (int64_t)ARG(0), false, 64, (int)ARG(3)); }

// ---- Math (api-ms-win-crt-math) ---------------------------------------------------------------
#define MATH1(fn) static uint64_t m_##fn(void) { return retD(fn(argD(0))); }
#define MATH1F(fn) static uint64_t m_##fn(void) { return retF(fn(argF(0))); }
#define MATH2(fn) static uint64_t m_##fn(void) { return retD(fn(argD(0), argD(1))); }
#define MATH2F(fn) static uint64_t m_##fn(void) { return retF(fn(argF(0), argF(1))); }
MATH1(sin) MATH1(cos) MATH1(tan) MATH1(asin) MATH1(acos) MATH1(atan) MATH1(sinh) MATH1(cosh) MATH1(tanh) MATH1(exp) MATH1(exp2)
MATH1(log) MATH1(log10) MATH1(log2) MATH1(log1p) MATH1(expm1) MATH1(sqrt) MATH1(cbrt) MATH1(ceil) MATH1(floor) MATH1(fabs) MATH1(round)
MATH1(trunc) MATH1(rint) MATH1(nearbyint) MATH1(erf) MATH1(erfc) MATH1(tgamma) MATH1(lgamma) MATH1(asinh) MATH1(acosh) MATH1(atanh)
MATH1F(sinf) MATH1F(cosf) MATH1F(tanf) MATH1F(asinf) MATH1F(acosf) MATH1F(atanf) MATH1F(sinhf) MATH1F(coshf) MATH1F(tanhf) MATH1F(expf)
MATH1F(logf) MATH1F(log10f) MATH1F(log2f) MATH1F(sqrtf) MATH1F(cbrtf) MATH1F(ceilf) MATH1F(floorf) MATH1F(fabsf) MATH1F(roundf) MATH1F(truncf)
MATH1F(exp2f) MATH1F(rintf)
MATH2(atan2) MATH2(pow) MATH2(fmod) MATH2(hypot) MATH2(fmin) MATH2(fmax) MATH2(copysign) MATH2(remainder) MATH2(fdim) MATH2(nextafter)
MATH2F(atan2f) MATH2F(powf) MATH2F(fmodf) MATH2F(hypotf) MATH2F(fminf) MATH2F(fmaxf) MATH2F(copysignf) MATH2F(remainderf)
static uint64_t m_ldexp(void) { return retD(ldexp(argD(0), (int)ARG(1))); }
static uint64_t m_ldexpf(void) { return retF(ldexpf(argF(0), (int)ARG(1))); }
static uint64_t m_frexp(void) { int e; double v = frexp(argD(0), &e); if (ARG(1)) wr32(ARG(1), (uint32_t)e); return retD(v); }
static uint64_t m_modf(void) { double whole; double v = modf(argD(0), &whole); if (ARG(1)) memcpy(G(ARG(1)), &whole, 8); return retD(v); }
static uint64_t m_modff(void) { float whole; float v = modff(argF(0), &whole); if (ARG(1)) memcpy(G(ARG(1)), &whole, 4); return retF(v); }
static uint64_t m_lround(void) { return (uint64_t)(int64_t)(int32_t)lround(argD(0)); }
static uint64_t m_lroundf(void) { return (uint64_t)(int64_t)(int32_t)lroundf(argF(0)); }
static uint64_t m_llround(void) { return (uint64_t)llround(argD(0)); }
static uint64_t m_lrint(void) { return (uint64_t)(int64_t)(int32_t)lrint(argD(0)); }
static uint64_t m_abs(void) { int v = (int)ARG(0); return (uint64_t)(int64_t)(v < 0 ? -v : v); }
static uint64_t m_llabs(void) { int64_t v = (int64_t)ARG(0); return (uint64_t)(v < 0 ? -v : v); }
// Microsoft's classification: _dclass returns FP_INFINITE 1, FP_NAN 2, FP_NORMAL -1, FP_SUBNORMAL -2, FP_ZERO 0.
static int dclass(double v) { switch (fpclassify(v)) { case FP_INFINITE: return 1; case FP_NAN: return 2; case FP_NORMAL: return -1; case FP_SUBNORMAL: return -2; default: return 0; } }
static uint64_t m_dclass(void) { return ires(dclass(argD(0))); }
static uint64_t m_fdclass(void) { return ires(dclass(argF(0))); }
static uint64_t m_dsign(void) { return signbit(argD(0)) ? 0x8000 : 0; }
static uint64_t m_fdsign(void) { return signbit(argF(0)) ? 0x8000 : 0; }
static uint64_t m_dtest(void) { double v; memcpy(&v, G(ARG(0)), 8); return ires(dclass(v)); }
static uint64_t m_fdtest(void) { float v; memcpy(&v, G(ARG(0)), 4); return ires(dclass(v)); }
static uint64_t m_isnan(void) { return isnan(argD(0)) ? 1 : 0; }
static uint64_t m_finite(void) { return isfinite(argD(0)) ? 1 : 0; }

// ---- Time (api-ms-win-crt-time) --------------------------------------------------------------
// struct tm is nine ints on Windows too; time_t is 64 bits (_time64), the *32 versions take 32-bit times.
static void tmToGuest(const struct tm *tm, uint64_t out) {
  int v[9] = {tm->tm_sec, tm->tm_min, tm->tm_hour, tm->tm_mday, tm->tm_mon, tm->tm_year, tm->tm_wday, tm->tm_yday, tm->tm_isdst};
  for (int i = 0; i < 9; i++) wr32(out + 4 * (uint64_t)i, (uint32_t)v[i]);
}
static void tmFromGuest(uint64_t in, struct tm *tm) {
  memset(tm, 0, sizeof *tm); int v[9]; for (int i = 0; i < 9; i++) v[i] = (int)rd32(in + 4 * (uint64_t)i);
  tm->tm_sec = v[0]; tm->tm_min = v[1]; tm->tm_hour = v[2]; tm->tm_mday = v[3]; tm->tm_mon = v[4]; tm->tm_year = v[5]; tm->tm_wday = v[6]; tm->tm_yday = v[7]; tm->tm_isdst = v[8];
}
static uint64_t c_time64(void) { uint64_t t = (uint64_t)time(0); if (ARG(0)) wr64(ARG(0), t); return t; }
static uint64_t c_time32(void) { uint32_t t = (uint32_t)time(0); if (ARG(0)) wr32(ARG(0), t); return t; }
static uint64_t breakTime(time_t t, bool local, uint64_t out) { struct tm tm; if (!(local ? localtime_r(&t, &tm) : gmtime_r(&t, &tm))) return 22; tmToGuest(&tm, out); return 0; }
static uint64_t c_localtime64_s(void) { return ARG(0) && ARG(1) ? breakTime((time_t)(int64_t)rd64(ARG(1)), true, ARG(0)) : 22; }
static uint64_t c_gmtime64_s(void) { return ARG(0) && ARG(1) ? breakTime((time_t)(int64_t)rd64(ARG(1)), false, ARG(0)) : 22; }
static uint64_t c_localtime32_s(void) { return ARG(0) && ARG(1) ? breakTime((time_t)(int32_t)rd32(ARG(1)), true, ARG(0)) : 22; }
static uint64_t c_localtime64(void) { return ARG(0) && !breakTime((time_t)(int64_t)rd64(ARG(0)), true, cur->teb + TEB_TM) ? cur->teb + TEB_TM : 0; }
static uint64_t c_gmtime64(void) { return ARG(0) && !breakTime((time_t)(int64_t)rd64(ARG(0)), false, cur->teb + TEB_TM) ? cur->teb + TEB_TM : 0; }
static uint64_t c_localtime32(void) { return ARG(0) && !breakTime((time_t)(int32_t)rd32(ARG(0)), true, cur->teb + TEB_TM) ? cur->teb + TEB_TM : 0; }
static uint64_t c_mktime64(void) { struct tm tm; tmFromGuest(ARG(0), &tm); time_t t = mktime(&tm); tmToGuest(&tm, ARG(0)); return (uint64_t)(int64_t)t; }
static uint64_t c_difftime64(void) { return retD((double)((int64_t)ARG(0) - (int64_t)ARG(1))); }
static uint64_t startUs;
static uint64_t c_clock(void) { return (now_us() - startUs) / 1000; }  // CLOCKS_PER_SEC is 1000 on Windows
static uint64_t c_strftime(void) {
  struct tm tm; tmFromGuest(ARG(3), &tm); size_t cap = ARG(1); if (!cap) return 0;
  char *out = malloc(cap); size_t n = strftime_l(out, cap, S(ARG(2)), &tm, cLocale());
  if (n) memcpy(G(ARG(0)), out, n + 1); else *G(ARG(0)) = 0;
  free(out); return n;
}
static uint64_t c_timespec64_get(void) {
  if (ARG(1) != 1) return 0;  // TIME_UTC
  struct timespec ts; clock_gettime(CLOCK_REALTIME, &ts); wr64(ARG(0), (uint64_t)ts.tv_sec); wr32(ARG(0) + 8, (uint32_t)ts.tv_nsec); return 1;
}

// ---- Locale (api-ms-win-crt-locale): the "C" locale ------------------------------------------
static uint64_t lconvCell, cName, cNameW;
static uint64_t c_localeconv(void) { return lconvCell; }
static uint64_t c_setlocale(void) { return cName; }
static uint64_t c_wsetlocale(void) { return cNameW; }
static uint64_t c_lc_codepage(void) { return 1252; }
static uint64_t c_mb_cur_max(void) { return 1; }

// ---- Utility (api-ms-win-crt-utility) ---------------------------------------------------------
// rand: Microsoft's generator, so a mod seeded with srand gets the numbers it would on Windows.
static uint32_t randState = 1;
static uint64_t c_srand(void) { randState = (uint32_t)ARG(0); return 0; }
static uint64_t c_rand(void) { randState = randState * 214013u + 2531011u; return (randState >> 16) & 0x7FFF; }
static uint64_t c_rand_s(void) { if (!ARG(0)) return 22; wr32(ARG(0), arc4random()); return 0; }
// qsort: a heap sort in place, comparing through the mod's own comparator (a nested call per comparison).
static void swapBytes(uint64_t a, uint64_t b, uint64_t w) {
  uint8_t tmp[256];
  while (w) { uint64_t k = w < sizeof tmp ? w : sizeof tmp; memcpy(tmp, G(a), k); memmove(G(a), G(b), k); memcpy(G(b), tmp, k); a += k; b += k; w -= k; }
}
static int sortCompare(uint64_t cmp, uint64_t context, bool hasContext, uint64_t a, uint64_t b) {
  return (int)(hasContext ? GUEST(cmp, context, a, b) : GUEST(cmp, a, b));
}
static void heapSort(uint64_t base, uint64_t n, uint64_t w, uint64_t cmp, uint64_t context, bool hasContext) {
  for (uint64_t start = n / 2; start-- > 0;) {
    for (uint64_t root = start;;) {
      uint64_t child = 2 * root + 1; if (child >= n) break;
      if (child + 1 < n && sortCompare(cmp, context, hasContext, base + child * w, base + (child + 1) * w) < 0) child++;
      if (leaving()) return;
      if (sortCompare(cmp, context, hasContext, base + root * w, base + child * w) >= 0) break;
      if (leaving()) return;
      swapBytes(base + root * w, base + child * w, w); root = child;
    }
  }
  for (uint64_t end = n; end-- > 1;) {
    swapBytes(base, base + end * w, w);
    for (uint64_t root = 0;;) {
      uint64_t child = 2 * root + 1; if (child >= end) break;
      if (child + 1 < end && sortCompare(cmp, context, hasContext, base + child * w, base + (child + 1) * w) < 0) child++;
      if (leaving()) return;
      if (sortCompare(cmp, context, hasContext, base + root * w, base + child * w) >= 0) break;
      if (leaving()) return;
      swapBytes(base + root * w, base + child * w, w); root = child;
    }
  }
}
static uint64_t c_qsort(void) { uint64_t base = ARG(0), n = ARG(1), w = ARG(2), cmp = ARG(3); if (n > 1 && w) heapSort(base, n, w, cmp, 0, false); return 0; }
static uint64_t c_qsort_s(void) { uint64_t base = ARG(0), n = ARG(1), w = ARG(2), cmp = ARG(3), ctx = ARG(4); if (n > 1 && w) heapSort(base, n, w, cmp, ctx, true); return 0; }
static uint64_t c_bsearch(void) {
  uint64_t key = ARG(0), base = ARG(1), lo = 0, hi = ARG(2), w = ARG(3), cmp = ARG(4);
  while (lo < hi) {
    uint64_t mid = (lo + hi) / 2; int r = (int)GUEST(cmp, key, base + mid * w); if (leaving()) return 0;
    if (!r) return base + mid * w;
    if (r < 0) hi = mid; else lo = mid + 1;
  }
  return 0;
}

// ---- Files and folders (api-ms-win-crt-filesystem) --------------------------------------------
// Paths resolve like CreateFileW: inside the mod's folder, which stands in for the game folder.
static void pathOf(uint64_t a, bool wide, char *out, size_t cap) {
  char n[1024]; if (wide) wToUtf8(a, -1, n, sizeof n); else snprintf(n, sizeof n, "%s", gstr(a));
  hostPath(n, out, cap);
}
// struct _stat64i32 (48 bytes), _stat64 (56) and _stat32 (36): dev, ino, mode, nlink, uid, gid, rdev, then size and the times.
static uint64_t statTo(uint64_t pathA, bool wide, uint64_t out, int layout) {
  char p[1100]; pathOf(pathA, wide, p, sizeof p); struct stat st;
  if (stat(p, &st)) { setErrno(hostErrno(errno)); return (uint64_t)-1; }
  memset(G(out), 0, layout == 1 ? 56 : layout == 2 ? 36 : 48);
  uint16_t mode = S_ISDIR(st.st_mode) ? 0x41FF : 0x81B6;  // _S_IFDIR or _S_IFREG, readable and writable by everyone
  wr32(out, 2); wr16(out + 6, mode); wr16(out + 8, 1); wr32(out + 16, 2);  // drive C:
  if (layout == 1) { wr64(out + 24, (uint64_t)st.st_size); wr64(out + 32, (uint64_t)st.st_atime); wr64(out + 40, (uint64_t)st.st_mtime); wr64(out + 48, (uint64_t)st.st_ctime); }
  else if (layout == 2) { wr32(out + 20, (uint32_t)st.st_size); wr32(out + 24, (uint32_t)st.st_atime); wr32(out + 28, (uint32_t)st.st_mtime); wr32(out + 32, (uint32_t)st.st_ctime); }
  else { wr32(out + 20, (uint32_t)st.st_size); wr64(out + 24, (uint64_t)st.st_atime); wr64(out + 32, (uint64_t)st.st_mtime); wr64(out + 40, (uint64_t)st.st_ctime); }
  return 0;
}
static uint64_t c_stat64i32(void) { return statTo(ARG(0), false, ARG(1), 0); }
static uint64_t c_wstat64i32(void) { return statTo(ARG(0), true, ARG(1), 0); }
static uint64_t c_stat64(void) { return statTo(ARG(0), false, ARG(1), 1); }
static uint64_t c_wstat64(void) { return statTo(ARG(0), true, ARG(1), 1); }
static uint64_t c_stat32(void) { return statTo(ARG(0), false, ARG(1), 2); }
static uint64_t fsResult(int r) { if (r) { setErrno(hostErrno(errno)); return (uint64_t)-1; } return 0; }
static uint64_t c_access(void) { char p[1100]; pathOf(ARG(0), false, p, sizeof p); return fsResult(access(p, F_OK)); }
static uint64_t c_waccess(void) { char p[1100]; pathOf(ARG(0), true, p, sizeof p); return fsResult(access(p, F_OK)); }
static uint64_t c_mkdir(void) { char p[1100]; pathOf(ARG(0), false, p, sizeof p); return fsResult(mkdir(p, 0755)); }
static uint64_t c_wmkdir(void) { char p[1100]; pathOf(ARG(0), true, p, sizeof p); return fsResult(mkdir(p, 0755)); }
static uint64_t c_rmdir(void) { char p[1100]; pathOf(ARG(0), false, p, sizeof p); return fsResult(rmdir(p)); }
static uint64_t c_remove(void) { char p[1100]; pathOf(ARG(0), false, p, sizeof p); return fsResult(unlink(p)); }
static uint64_t c_wremove(void) { char p[1100]; pathOf(ARG(0), true, p, sizeof p); return fsResult(unlink(p)); }
static uint64_t c_rename(void) { char a[1100], b[1100]; pathOf(ARG(0), false, a, sizeof a); pathOf(ARG(1), false, b, sizeof b); return fsResult(rename(a, b)); }
static uint64_t c_wrename(void) { char a[1100], b[1100]; pathOf(ARG(0), true, a, sizeof a); pathOf(ARG(1), true, b, sizeof b); return fsResult(rename(a, b)); }
static uint64_t c_getcwd(void) {
  const char *d = "C:\\GTA5"; size_t n = strlen(d) + 1; uint64_t buf = ARG(0), cap = ARG(1);
  if (!buf) { buf = heapAlloc(cap > n ? cap : n, true); if (!buf) return 0; } else if (cap < n) { setErrno(34); return 0; }
  memcpy(G(buf), d, n); return buf;
}
static uint64_t c_fullpath(void) {
  uint64_t buf = ARG(0), rel = ARG(1), cap = ARG(2); const char *r = gstr(rel); char full[1100];
  if (r[0] && r[1] == ':') snprintf(full, sizeof full, "%s", r); else snprintf(full, sizeof full, "C:\\GTA5\\%s", r);
  for (char *c = full; *c; c++) if (*c == '/') *c = '\\';
  size_t n = strlen(full) + 1;
  if (!buf) { buf = heapAlloc(n, false); if (!buf) return 0; } else if (cap < n) { setErrno(34); return 0; }
  memcpy(G(buf), full, n); return buf;
}
// _findfirst64i32 / _findnext64i32: struct _finddata64i32_t {attrib, create, access, write times, size, name[260]}.
static bool findData(Handle *f, uint64_t out) {
  struct dirent *e;
  while ((e = readdir(f->dir))) if (match(f->pattern, e->d_name)) {
    char p[1300]; struct stat st; snprintf(p, sizeof p, "%s/%s", f->path, e->d_name); bool dir = !stat(p, &st) && S_ISDIR(st.st_mode);
    memset(G(out), 0, 296); wr32(out, dir ? 0x10 : 0x20);
    wr64(out + 8, (uint64_t)st.st_ctime); wr64(out + 16, (uint64_t)st.st_atime); wr64(out + 24, (uint64_t)st.st_mtime); wr32(out + 32, dir ? 0 : (uint32_t)st.st_size);
    snprintf(S(out + 36), 260, "%s", e->d_name); return true;
  }
  return false;
}
static uint64_t c_findfirst64i32(void) {
  char p[1100]; pathOf(ARG(0), false, p, sizeof p); char *slash = strrchr(p, '/'); if (!slash) { setErrno(2); return (uint64_t)-1; }
  *slash = 0; DIR *dir = opendir(p); if (!dir) { setErrno(2); return (uint64_t)-1; }
  uint64_t h = newHandle(0, dir); Handle *f = handleFor(h); if (!f) { closedir(dir); return (uint64_t)-1; }
  snprintf(f->pattern, sizeof f->pattern, "%s", slash + 1); snprintf(f->path, sizeof f->path, "%s", p);
  if (!findData(f, ARG(1))) { closedir(dir); memset(f, 0, sizeof *f); setErrno(2); return (uint64_t)-1; }
  return h;
}
static uint64_t c_findnext64i32(void) { Handle *f = handleFor(ARG(0)); if (f && f->dir && findData(f, ARG(1))) return 0; setErrno(2); return (uint64_t)-1; }
static uint64_t c_findclose(void) { Handle *f = handleFor(ARG(0)); if (!f) return (uint64_t)-1; if (f->dir) closedir(f->dir); memset(f, 0, sizeof *f); return 0; }

// ---- stdio (api-ms-win-crt-stdio) ---------------------------------------------------------------
// A FILE is a 64-byte guest block whose first fields are UCRT's own: _ptr (+0), _base (+8) and _cnt (+16). Data is
// buffered in guest memory as UCRT does it, because the C++ file streams (basic_filebuf) read and write that buffer
// directly through _get_stream_buffer_pointers and call fgetc/fputc only when it is empty or full: a 13 MB text file
// goes through a stream without an import call per character. Reading, _ptr/_cnt are the next byte and the bytes
// left; writing, the next free byte and the space left. Text mode (no "b" in the mode) turns "\r\n" into "\n" when
// reading (Ctrl-Z ends the file) and "\n" into "\r\n" when writing, as on Windows. stdout and stderr go to the log.
#define FILE_BUF 4096
typedef struct GFile {
  uint64_t guest, buf;   // the FILE the mod holds, and its buffer
  int fd, std;           // the host file, or a standard stream (1 stdin: empty; 2 stdout, 3 stderr: the log)
  bool text, canRead, canWrite, eof, error, ctrlZ, unbuffered;
  int mode;              // 0 idle, 'r' the buffer holds data read ahead, 'w' it holds data not written yet
  int64_t bufPos;        // reading: the file offset of the buffer's first byte
  int filled;            // reading: bytes in the buffer
  uint8_t crlf[FILE_BUF / 8];  // reading in text mode: which buffered '\n' were "\r\n" in the file (for ftell)
  char line[600]; size_t lineLength;  // stdout/stderr: the line being written
} GFile;
static GFile *gfiles[64];
static uint64_t stdFiles[3];
static GFile *gfileFor(uint64_t stream) { if (!stream) return 0; for (int i = 0; i < 64; i++) if (gfiles[i] && gfiles[i]->guest == stream) return gfiles[i]; return 0; }
static uint64_t fPtr(GFile *f) { return rd64(f->guest); }
static int fCnt(GFile *f) { return (int)rd32(f->guest + 16); }
static void setBuffer(GFile *f, uint64_t ptr, int cnt) { wr64(f->guest, ptr); wr64(f->guest + 8, f->buf); wr32(f->guest + 16, (uint32_t)cnt); }
static GFile *newFile(int fd, int std, bool text, bool canRead, bool canWrite) {
  int slot = -1; for (int i = 0; i < 64 && slot < 0; i++) if (!gfiles[i]) slot = i;
  if (slot < 0) return 0;
  GFile *f = calloc(1, sizeof *f); f->guest = galloc(64); f->buf = galloc(FILE_BUF);
  if (!f->guest || !f->buf) { if (f->guest) H.free(f->guest); if (f->buf) H.free(f->buf); free(f); return 0; }
  f->fd = fd; f->std = std; f->text = text; f->canRead = canRead; f->canWrite = canWrite; setBuffer(f, f->buf, 0);
  gfiles[slot] = f; return f;
}
static bool writeOut(GFile *f, const char *data, size_t n) {
  if (f->std) {  // a standard stream: whole lines go to the log
    for (size_t i = 0; i < n; i++) {
      if (data[i] != '\n' && f->lineLength < sizeof f->line - 1) { f->line[f->lineLength++] = data[i]; continue; }
      f->line[f->lineLength] = 0; consoleWrite(f->line, f->lineLength); f->lineLength = 0;
      if (data[i] != '\n') f->line[f->lineLength++] = data[i];
    }
    return true;
  }
  char *tmp = 0;
  if (f->text) { size_t lf = 0; for (size_t i = 0; i < n; i++) lf += data[i] == '\n'; if (lf) { tmp = malloc(n + lf); size_t o = 0; for (size_t i = 0; i < n; i++) { if (data[i] == '\n') tmp[o++] = '\r'; tmp[o++] = data[i]; } data = tmp; n = o; } }
  bool ok = true;
  while (n) { ssize_t w = write(f->fd, data, n); if (w <= 0) { if (w < 0 && errno == EINTR) continue; ok = false; f->error = true; break; } data += w; n -= (size_t)w; }
  free(tmp); return ok;
}
// Writes out what the buffer holds. Returns 0, or EOF on a write error.
static int flushWrite(GFile *f) {
  if (f->mode != 'w') return 0;
  uint64_t p = fPtr(f); size_t n = p > f->buf && p <= f->buf + FILE_BUF ? (size_t)(p - f->buf) : 0;
  char tmp[FILE_BUF]; memcpy(tmp, G(f->buf), n);
  setBuffer(f, f->buf, 0); f->mode = 0;
  return writeOut(f, tmp, n) ? 0 : -1;
}
// Reading: the file offset of the next byte the mod will get.
static int64_t tellRead(GFile *f) {
  uint64_t p = fPtr(f); int at = p >= f->buf && p <= f->buf + (uint64_t)f->filled ? (int)(p - f->buf) : f->filled;
  int64_t raw = f->bufPos + at;
  if (f->text) for (int i = 0; i < at; i++) if (f->crlf[i / 8] >> (i % 8) & 1) raw++;
  return raw;
}
// Switches to writing. Standard streams and unbuffered files get no buffer space: every byte comes to fputc/fwrite.
static bool beginWrite(GFile *f) {
  if (!f->canWrite) { f->error = true; return false; }
  if (f->mode == 'r') { if (f->fd >= 0) lseek(f->fd, tellRead(f), SEEK_SET); f->mode = 0; }
  if (f->mode != 'w') { f->mode = 'w'; setBuffer(f, f->buf, f->std || f->unbuffered ? 0 : FILE_BUF); }
  return true;
}
// Refills the buffer from the file (UCRT's _filbuf without taking a byte). Returns 0, or EOF.
static int fill(GFile *f) {
  if (!f->canRead) { f->error = true; return -1; }
  if (f->mode == 'w' && flushWrite(f)) return -1;
  f->mode = 'r'; f->filled = 0; setBuffer(f, f->buf, 0);
  if (f->std || f->fd < 0 || f->ctrlZ) { f->eof = true; return -1; }
  uint8_t raw[FILE_BUF], out[FILE_BUF]; int64_t at = lseek(f->fd, 0, SEEK_CUR); ssize_t n = read(f->fd, raw, FILE_BUF);
  if (n < 0) { f->error = true; return -1; }
  f->bufPos = at; memset(f->crlf, 0, sizeof f->crlf); int o = 0;
  for (ssize_t i = 0; i < n; i++) {
    uint8_t c = raw[i];
    if (f->text && c == 0x1A) { f->ctrlZ = true; lseek(f->fd, at + i, SEEK_SET); break; }
    if (f->text && c == '\r') {
      uint8_t next = 0; bool have = i + 1 < n;
      if (have) next = raw[i + 1];
      else if (read(f->fd, &next, 1) == 1) { have = true; if (next != '\n') lseek(f->fd, -1, SEEK_CUR); }
      if (have && next == '\n') { f->crlf[o / 8] |= (uint8_t)(1 << (o % 8)); out[o++] = '\n'; if (i + 1 < n) i++; continue; }
    }
    out[o++] = c;
  }
  if (!o) { f->eof = true; return -1; }
  memcpy(G(f->buf), out, (size_t)o); f->filled = o; setBuffer(f, f->buf, o);
  return 0;
}
static int getByte(GFile *f) {
  if (f->mode != 'r' || fCnt(f) <= 0) { if (fill(f)) return -1; }
  uint64_t p = fPtr(f); uint8_t c = *G(p); wr64(f->guest, p + 1); wr32(f->guest + 16, (uint32_t)(fCnt(f) - 1)); return c;
}
static int putByte(GFile *f, int c) {
  if (f->mode == 'w' && fCnt(f) > 0) { uint64_t p = fPtr(f); *G(p) = (uint8_t)c; wr64(f->guest, p + 1); wr32(f->guest + 16, (uint32_t)(fCnt(f) - 1)); return (uint8_t)c; }
  if (!beginWrite(f)) return -1;
  if (f->std || f->unbuffered) { char ch = (char)c; return writeOut(f, &ch, 1) ? (uint8_t)c : -1; }
  if (fCnt(f) <= 0) { if (flushWrite(f) || !beginWrite(f)) return -1; }
  uint64_t p = fPtr(f); *G(p) = (uint8_t)c; wr64(f->guest, p + 1); wr32(f->guest + 16, (uint32_t)(fCnt(f) - 1)); return (uint8_t)c;
}
static size_t writeBytes(GFile *f, uint64_t src, size_t total) {
  if (!total || !beginWrite(f)) return 0;
  if (f->std || f->unbuffered || total >= FILE_BUF) {
    if (flushWrite(f)) return 0;
    char *tmp = malloc(total); memcpy(tmp, G(src), total); bool ok = writeOut(f, tmp, total); free(tmp);
    beginWrite(f); return ok ? total : 0;
  }
  size_t done = 0;
  while (done < total) {
    int space = fCnt(f);
    if (space <= 0) { if (flushWrite(f) || !beginWrite(f)) break; continue; }
    size_t k = total - done < (size_t)space ? total - done : (size_t)space; uint64_t p = fPtr(f);
    memmove(G(p), G(src + done), k); wr64(f->guest, p + k); wr32(f->guest + 16, (uint32_t)(space - (int)k)); done += k;
  }
  return done;
}
static size_t readBytes(GFile *f, uint64_t dst, size_t total) {
  size_t done = 0;
  while (done < total) {
    int have = f->mode == 'r' ? fCnt(f) : 0;
    if (have > 0) {
      size_t k = total - done < (size_t)have ? total - done : (size_t)have; uint64_t p = fPtr(f);
      memmove(G(dst + done), G(p), k); wr64(f->guest, p + k); wr32(f->guest + 16, (uint32_t)(have - (int)k)); done += k; continue;
    }
    if (!f->text && !f->std && f->fd >= 0 && f->canRead && total - done >= FILE_BUF) {  // a big binary read: straight from the file
      if (f->mode == 'w' && flushWrite(f)) break;
      f->mode = 0; setBuffer(f, f->buf, 0);
      PGMeshTouch(G(dst + done), total - done);
      ssize_t n = read(f->fd, G(dst + done), total - done);
      if (n < 0) { f->error = true; break; }
      if (n == 0) { f->eof = true; break; }
      done += (size_t)n; continue;
    }
    if (fill(f)) break;
  }
  return done;
}
// Opens a file in the mod's folder with a C mode string ("r", "wb", "a+", "rt, ccs=UTF-8"...).
static uint64_t openStream(const char *hostPathName, const char *mode) {
  int flags = 0; bool text = true, plus = strchr(mode, '+') != 0;
  switch (mode[0]) {
    case 'r': flags = plus ? O_RDWR : O_RDONLY; break;
    case 'w': flags = (plus ? O_RDWR : O_WRONLY) | O_CREAT | O_TRUNC; break;
    case 'a': flags = (plus ? O_RDWR : O_WRONLY) | O_CREAT | O_APPEND; break;
    default: setErrno(22); return 0;
  }
  for (const char *c = mode + 1; *c && *c != ','; c++) { if (*c == 'b') text = false; else if (*c == 't') text = true; else if (*c == 'x') flags |= O_EXCL; }
  int fd = open(hostPathName, flags | O_CLOEXEC, 0644);
  if (getenv("ASI_TRACE")) logf_("ASI trace: open %s (%s): %s", hostPathName, mode, fd < 0 ? strerror(errno) : "ok");
  if (fd < 0) { setErrno(hostErrno(errno)); return 0; }
  GFile *f = newFile(fd, 0, text, mode[0] == 'r' || plus, mode[0] != 'r' || plus);
  if (!f) { close(fd); setErrno(24); return 0; }
  return f->guest;
}
static uint64_t c_fopen(void) { char p[1100]; pathOf(ARG(0), false, p, sizeof p); return openStream(p, gstr(ARG(1))); }
static uint64_t c_fsopen(void) { return c_fopen(); }
static uint64_t c_wfopen(void) { char p[1100], m[32]; pathOf(ARG(0), true, p, sizeof p); wToUtf8(ARG(1), -1, m, sizeof m); return openStream(p, m); }
static uint64_t c_fopen_s(void) {
  if (!ARG(0)) return 22;
  char p[1100]; pathOf(ARG(1), false, p, sizeof p); uint64_t f = openStream(p, gstr(ARG(2)));
  wr64(ARG(0), f); return f ? 0 : rd32(cur->teb + TEB_ERRNO);
}
static uint64_t c_wfopen_s(void) {
  if (!ARG(0)) return 22;
  char p[1100], m[32]; pathOf(ARG(1), true, p, sizeof p); wToUtf8(ARG(2), -1, m, sizeof m); uint64_t f = openStream(p, m);
  wr64(ARG(0), f); return f ? 0 : rd32(cur->teb + TEB_ERRNO);
}
static int closeStream(GFile *f) {
  if (f->std) return 0;
  int r = flushWrite(f); if (f->fd >= 0 && close(f->fd)) r = -1;
  for (int i = 0; i < 64; i++) if (gfiles[i] == f) gfiles[i] = 0;
  H.free(f->buf); H.free(f->guest); free(f);
  return r;
}
static uint64_t c_fclose(void) { GFile *f = gfileFor(ARG(0)); return f ? (uint64_t)(int64_t)closeStream(f) : (uint64_t)-1; }
static uint64_t c_fflush(void) {
  if (!ARG(0)) { int r = 0; for (int i = 0; i < 64; i++) if (gfiles[i] && flushWrite(gfiles[i])) r = -1; return (uint64_t)(int64_t)r; }
  GFile *f = gfileFor(ARG(0)); return f ? (uint64_t)(int64_t)flushWrite(f) : (uint64_t)-1;
}
static uint64_t c_fread(void) {
  GFile *f = gfileFor(ARG(3)); uint64_t size = ARG(1), count = ARG(2); if (!f || !size || !count) return 0;
  if (count > UINT64_MAX / size) return 0;
  return readBytes(f, ARG(0), size * count) / size;
}
static uint64_t c_fwrite(void) {
  GFile *f = gfileFor(ARG(3)); uint64_t size = ARG(1), count = ARG(2); if (!f || !size || !count) return 0;
  if (count > UINT64_MAX / size) return 0;
  return writeBytes(f, ARG(0), size * count) / size;
}
static uint64_t c_fgetc(void) { GFile *f = gfileFor(ARG(0)); return f ? (uint64_t)(int64_t)getByte(f) : (uint64_t)-1; }
static uint64_t c_fputc(void) { GFile *f = gfileFor(ARG(1)); return f ? (uint64_t)(int64_t)putByte(f, (int)ARG(0)) : (uint64_t)-1; }
static uint64_t c_putchar(void) { GFile *f = gfileFor(stdFiles[1]); return (uint64_t)(int64_t)putByte(f, (int)ARG(0)); }
static uint64_t c_fputs(void) { GFile *f = gfileFor(ARG(1)); size_t n = strlen(S(ARG(0))); if (!f) return (uint64_t)-1; return writeBytes(f, ARG(0), n) == n ? 0 : (uint64_t)-1; }
static uint64_t c_puts(void) { GFile *f = gfileFor(stdFiles[1]); size_t n = strlen(S(ARG(0))); writeBytes(f, ARG(0), n); putByte(f, '\n'); return 0; }
static uint64_t c_fgets(void) {
  uint64_t dst = ARG(0); int cap = (int)ARG(1); GFile *f = gfileFor(ARG(2)); if (!f || cap <= 0) return 0;
  int n = 0;
  while (n < cap - 1) { int c = getByte(f); if (c < 0) break; *G(dst + (uint64_t)n++) = (uint8_t)c; if (c == '\n') break; }
  if (!n) return 0;
  *G(dst + (uint64_t)n) = 0; return dst;
}
static uint64_t c_ungetc(void) {
  int c = (int)ARG(0); GFile *f = gfileFor(ARG(1)); if (!f || c < 0 || f->mode == 'w') return (uint64_t)-1;
  uint64_t p = fPtr(f);
  if (f->mode != 'r' || p <= f->buf || p > f->buf + (uint64_t)f->filled) {
    if (f->mode == 'r' && fCnt(f) > 0) return (uint64_t)-1;  // no room before unread data
    int64_t at = f->mode == 'r' ? tellRead(f) : f->fd >= 0 ? lseek(f->fd, 0, SEEK_CUR) : 0;
    if (f->fd >= 0) lseek(f->fd, at, SEEK_SET);
    f->mode = 'r'; f->bufPos = at > 0 ? at - 1 : 0; f->filled = 1; memset(f->crlf, 0, sizeof f->crlf);
    *G(f->buf) = (uint8_t)c; setBuffer(f, f->buf, 1); f->eof = false; return (uint8_t)c;
  }
  p--; *G(p) = (uint8_t)c; wr64(f->guest, p); wr32(f->guest + 16, (uint32_t)(fCnt(f) + 1)); f->eof = false;
  return (uint8_t)c;
}
static int64_t streamTell(GFile *f) {
  if (f->std || f->fd < 0) return 0;
  if (f->mode == 'r') return tellRead(f);
  int64_t at = lseek(f->fd, 0, SEEK_CUR);
  if (f->mode == 'w') {
    uint64_t p = fPtr(f); size_t n = p > f->buf && p <= f->buf + FILE_BUF ? (size_t)(p - f->buf) : 0;
    at += (int64_t)n; if (f->text) for (size_t i = 0; i < n; i++) at += *G(f->buf + i) == '\n';
  }
  return at;
}
static int streamSeek(GFile *f, int64_t offset, int origin) {
  if (f->std || f->fd < 0) return -1;
  if (origin == SEEK_CUR) { offset += streamTell(f); origin = SEEK_SET; }
  if (f->mode == 'w' && flushWrite(f)) return -1;
  f->mode = 0; f->filled = 0; setBuffer(f, f->buf, 0); f->eof = false; f->ctrlZ = false;
  if (lseek(f->fd, offset, origin) < 0) { setErrno(22); return -1; }
  return 0;
}
static uint64_t c_fseek(void) { GFile *f = gfileFor(ARG(0)); return f ? (uint64_t)(int64_t)streamSeek(f, (int32_t)ARG(1), (int)ARG(2)) : (uint64_t)-1; }
static uint64_t c_fseeki64(void) { GFile *f = gfileFor(ARG(0)); return f ? (uint64_t)(int64_t)streamSeek(f, (int64_t)ARG(1), (int)ARG(2)) : (uint64_t)-1; }
static uint64_t c_ftell(void) { GFile *f = gfileFor(ARG(0)); return f ? (uint64_t)(int64_t)(int32_t)streamTell(f) : (uint64_t)-1; }
static uint64_t c_ftelli64(void) { GFile *f = gfileFor(ARG(0)); return f ? (uint64_t)streamTell(f) : (uint64_t)-1; }
static uint64_t c_fgetpos(void) { GFile *f = gfileFor(ARG(0)); if (!f || !ARG(1)) return 22; wr64(ARG(1), (uint64_t)streamTell(f)); return 0; }
static uint64_t c_fsetpos(void) { GFile *f = gfileFor(ARG(0)); if (!f || !ARG(1)) return 22; return (uint64_t)(int64_t)streamSeek(f, (int64_t)rd64(ARG(1)), SEEK_SET); }
static uint64_t c_rewind(void) { GFile *f = gfileFor(ARG(0)); if (f) { streamSeek(f, 0, SEEK_SET); f->error = false; } return 0; }
static uint64_t c_feof(void) { GFile *f = gfileFor(ARG(0)); return f && f->eof ? 1 : 0; }
static uint64_t c_ferror(void) { GFile *f = gfileFor(ARG(0)); return f && f->error ? 1 : 0; }
static uint64_t c_clearerr(void) { GFile *f = gfileFor(ARG(0)); if (f) f->eof = f->error = false; return 0; }
static uint64_t c_setvbuf(void) { GFile *f = gfileFor(ARG(0)); if (!f) return (uint64_t)-1; if (f->mode == 'w') flushWrite(f); f->unbuffered = (int)ARG(2) == 4; return 0; }  // _IONBF
static uint64_t c_fileno(void) { for (int i = 0; i < 64; i++) if (gfiles[i] && gfiles[i]->guest == ARG(0)) return gfiles[i]->std ? (uint64_t)(gfiles[i]->std - 1) : (uint64_t)(i + 3); return (uint64_t)-1; }
static uint64_t c_iob(void) { return ARG(0) < 3 ? stdFiles[ARG(0)] : 0; }
// basic_filebuf reads and writes the FILE's buffer itself: it gets the addresses of _base, _ptr and _cnt.
static uint64_t c_get_stream_buffer_pointers(void) {
  uint64_t s = ARG(0); if (!gfileFor(s)) return 22;
  if (ARG(1)) wr64(ARG(1), s + 8);
  if (ARG(2)) wr64(ARG(2), s);
  if (ARG(3)) wr64(ARG(3), s + 16);
  return 0;
}

// ---- printf and scanf ------------------------------------------------------------------------
// Windows formatting: long is 32 bits, %I64d/%lld/%zu are 64, %p prints 16 upper-case hex digits, %S and %ls print
// UTF-16 strings, "(null)" for a null string. A Windows va_list is a pointer to 8-byte slots in guest memory.
typedef struct { char *s; size_t n, cap; } Buf;
static void bput(Buf *b, const char *s, size_t n) {
  if (b->n + n + 1 > b->cap) { size_t c = b->cap ? b->cap : 256; while (c < b->n + n + 1) c *= 2; b->s = realloc(b->s, c); b->cap = c; }
  if (n) memcpy(b->s + b->n, s, n);
  b->n += n; b->s[b->n] = 0;
}
static void bputf(Buf *b, const char *format, ...) __attribute__((format(printf, 2, 3)));
static void bputf(Buf *b, const char *format, ...) {
  char tmp[512]; va_list a; va_start(a, format); int n = vsnprintf(tmp, sizeof tmp, format, a); va_end(a);
  if (n < 0) return;
  if ((size_t)n < sizeof tmp) { bput(b, tmp, (size_t)n); return; }
  char *big = malloc((size_t)n + 1); va_start(a, format); vsnprintf(big, (size_t)n + 1, format, a); va_end(a); bput(b, big, (size_t)n); free(big);
}
static void bpad(Buf *b, long n) { while (n-- > 0) bput(b, " ", 1); }
static void bfield(Buf *b, const char *s, size_t n, int width, bool left) {
  if (!left) bpad(b, width - (long)n);
  bput(b, s, n);
  if (left) bpad(b, width - (long)n);
}
// UTF-16 (at most max code units, -1 for all, stopping at a NUL) to UTF-8.
static void bputWide(Buf *b, uint64_t w, long max) {
  for (long i = 0; max < 0 || i < max; i++) {
    uint32_t c = rd16(w + 2 * (uint64_t)i); if (!c) break;
    if (c >= 0xD800 && c < 0xDC00) { uint32_t d = rd16(w + 2 * (uint64_t)i + 2); if (d >= 0xDC00 && d < 0xE000) { c = 0x10000 + ((c - 0xD800) << 10) + (d - 0xDC00); i++; } }
    char u[4]; int k = 0;
    if (c < 0x80) u[k++] = (char)c;
    else if (c < 0x800) { u[k++] = (char)(0xC0 | c >> 6); u[k++] = (char)(0x80 | (c & 63)); }
    else if (c < 0x10000) { u[k++] = (char)(0xE0 | c >> 12); u[k++] = (char)(0x80 | (c >> 6 & 63)); u[k++] = (char)(0x80 | (c & 63)); }
    else { u[k++] = (char)(0xF0 | c >> 18); u[k++] = (char)(0x80 | (c >> 12 & 63)); u[k++] = (char)(0x80 | (c >> 6 & 63)); u[k++] = (char)(0x80 | (c & 63)); }
    bput(b, u, (size_t)k);
  }
}
static uint64_t vaNext(uint64_t *ap) { uint64_t v = rd64(*ap); *ap += 8; return v; }
// Length modifiers: 'H' hh, 'h', 0 (int), 'l' (long: 32 bits on Windows), 'q' (64 bits: ll I64 I j z t), 'L', 'w'.
static int sizeModifier(const char **fp) {
  const char *f = *fp; int size = 0;
  if (f[0] == 'h' && f[1] == 'h') { size = 'H'; f += 2; }
  else if (f[0] == 'h') { size = 'h'; f++; }
  else if (f[0] == 'l' && f[1] == 'l') { size = 'q'; f += 2; }
  else if (f[0] == 'l') { size = 'l'; f++; }
  else if (f[0] == 'L') { size = 'L'; f++; }
  else if (f[0] == 'w') { size = 'w'; f++; }
  else if (f[0] == 'I' && f[1] == '6' && f[2] == '4') { size = 'q'; f += 3; }
  else if (f[0] == 'I' && f[1] == '3' && f[2] == '2') { size = 0; f += 3; }
  else if (f[0] == 'I' || f[0] == 'j' || f[0] == 'z' || f[0] == 't') { size = 'q'; f++; }
  *fp = f; return size;
}
// wideFn: the wprintf family; legacyWide: Microsoft's default meaning there, %s is a wide string and %S a narrow one.
static void formatGuest(Buf *b, const char *f, uint64_t ap, bool wideFn, bool legacyWide) {
  bput(b, "", 0);
  while (*f) {
    if (*f != '%') { const char *e = strchr(f, '%'); size_t n = e ? (size_t)(e - f) : strlen(f); bput(b, f, n); f += n; continue; }
    f++;
    if (*f == '%') { bput(b, "%", 1); f++; continue; }
    char flags[8] = ""; int nf = 0; bool left = false;
    while (*f && strchr("-+ #0", *f)) { if (*f == '-') left = true; if (nf < 6 && !strchr(flags, *f)) { flags[nf++] = *f; flags[nf] = 0; } f++; }
    int width = -1, prec = -1;
    if (*f == '*') { f++; int w = (int)(int32_t)vaNext(&ap); if (w < 0) { w = -w; if (!left && nf < 6) { flags[nf++] = '-'; flags[nf] = 0; } left = true; } width = w; }
    else while (*f >= '0' && *f <= '9') width = (width < 0 ? 0 : width) * 10 + (*f++ - '0');
    if (*f == '.') { f++; prec = 0; if (*f == '*') { f++; int p = (int)(int32_t)vaNext(&ap); prec = p < 0 ? -1 : p; } else while (*f >= '0' && *f <= '9') prec = prec * 10 + (*f++ - '0'); }
    int size = sizeModifier(&f);
    char conv = *f; if (!conv) break;
    f++;
    char spec[40]; int o = snprintf(spec, sizeof spec, "%%%s", flags);
    if (width >= 0) o += snprintf(spec + o, sizeof spec - (size_t)o, "%d", width);
    if (prec >= 0) o += snprintf(spec + o, sizeof spec - (size_t)o, ".%d", prec);
    bool wide = size == 'l' || size == 'w' ? true : size == 'h' ? false : (wideFn && legacyWide) ? (conv == 's' || conv == 'c') : (conv == 'S' || conv == 'C');
    switch (conv) {
      case 'd': case 'i': {
        uint64_t v = vaNext(&ap); long long x = size == 'q' || size == 'L' ? (long long)v : size == 'h' ? (short)v : size == 'H' ? (signed char)v : (int)(int32_t)v;
        snprintf(spec + o, sizeof spec - (size_t)o, "lld"); bputf(b, spec, x); break;
      }
      case 'u': case 'o': case 'x': case 'X': {
        uint64_t v = vaNext(&ap); unsigned long long x = size == 'q' || size == 'L' ? v : size == 'h' ? (uint16_t)v : size == 'H' ? (uint8_t)v : (uint32_t)v;
        snprintf(spec + o, sizeof spec - (size_t)o, "ll%c", conv); bputf(b, spec, x); break;
      }
      case 'e': case 'E': case 'f': case 'F': case 'g': case 'G': case 'a': case 'A': {
        uint64_t v = vaNext(&ap); double x; memcpy(&x, &v, 8);
        snprintf(spec + o, sizeof spec - (size_t)o, "%c", conv); bputf(b, spec, x); break;
      }
      case 'p': { char t[24]; snprintf(t, sizeof t, "%016llX", (unsigned long long)vaNext(&ap)); bfield(b, t, 16, width, left); break; }
      case 'c': case 'C': {
        uint64_t v = vaNext(&ap); Buf t = {0};
        if (wide) { uint64_t one = galloc(4); wr16(one, (uint16_t)v); bputWide(&t, one, 1); H.free(one); } else { char c = (char)v; bput(&t, &c, 1); }
        bfield(b, t.s, t.n, width, left); free(t.s); break;
      }
      case 's': case 'S': {
        uint64_t p = vaNext(&ap); Buf t = {0};
        if (!p) bput(&t, "(null)", 6);
        else if (wide) bputWide(&t, p, prec);
        else bput(&t, S(p), prec >= 0 ? strnlen(S(p), (size_t)prec) : strlen(S(p)));
        bfield(b, t.s ? t.s : "", t.n, width, left); free(t.s); break;
      }
      case 'n': case 'Z': vaNext(&ap); break;  // %n is refused by the UCRT; %Z (ANSI_STRING) isn't for mods
      default: bput(b, "%", 1); bput(b, &conv, 1); break;
    }
  }
}
// Copies a formatted result into the mod's buffer with the rules of each sprintf flavour (UCRT option bit 2: C99
// snprintf, else the legacy _vsnprintf/vsprintf: no terminator when the text fills the buffer exactly, -1 if longer).
static uint64_t storeFormatted(Buf *b, uint64_t options, uint64_t dst, uint64_t count) {
  const char *s = b->s ? b->s : ""; size_t len = b->n; int64_t r;
  if (!dst) r = (int64_t)len;
  else if (options & 2) { if (count) { size_t k = len < count - 1 ? len : count - 1; memcpy(G(dst), s, k); *G(dst + k) = 0; } r = (int64_t)len; }
  else if (len < count) { memcpy(G(dst), s, len + 1); r = (int64_t)len; }
  else { memcpy(G(dst), s, count); r = len == count ? (int64_t)len : -1; }
  return (uint64_t)r;
}
static uint64_t c_vsprintf(void) {  // __stdio_common_vsprintf(options, buffer, count, format, locale, args)
  uint64_t options = ARG(0), dst = ARG(1), count = ARG(2); Buf b = {0};
  formatGuest(&b, gstr(ARG(3)), arg(5), false, false);
  uint64_t r = storeFormatted(&b, options, dst, count); free(b.s); return r;
}
static uint64_t c_vsprintf_s(void) {  // sprintf_s: the text must fit, or the buffer is emptied and -1 returned
  uint64_t dst = ARG(1), count = ARG(2); Buf b = {0};
  formatGuest(&b, gstr(ARG(3)), arg(5), false, false);
  int64_t r;
  if (!dst || !count) r = -1;
  else if (b.n >= count) { *G(dst) = 0; r = -1; static bool told; if (!told) { told = true; logf_("ASI: sprintf_s got a buffer too small for its text; it returns an empty string."); } }
  else { memcpy(G(dst), b.s ? b.s : "", b.n + 1); r = (int64_t)b.n; }
  free(b.s); return (uint64_t)r;
}
static uint64_t c_vsnprintf_s(void) {  // _vsnprintf_s(options, buffer, count, maxCount, format, locale, args); _TRUNCATE = -1
  uint64_t dst = ARG(1), count = ARG(2), max = ARG(3); Buf b = {0};
  formatGuest(&b, gstr(ARG(4)), arg(6), false, false);
  int64_t r; const char *s = b.s ? b.s : "";
  if (!dst || !count) r = -1;
  else if (max == (uint64_t)-1) { if (b.n < count) { memcpy(G(dst), s, b.n + 1); r = (int64_t)b.n; } else { memcpy(G(dst), s, count - 1); *G(dst + count - 1) = 0; r = -1; } }
  else { size_t k = b.n < max ? b.n : max; if (k >= count) { *G(dst) = 0; r = -1; } else { memcpy(G(dst), s, k); *G(dst + k) = 0; r = k < b.n ? -1 : (int64_t)k; } }
  free(b.s); return (uint64_t)r;
}
static uint64_t c_vfprintf(void) {  // __stdio_common_vfprintf(options, stream, format, locale, args)
  GFile *f = gfileFor(ARG(1)); Buf b = {0};
  formatGuest(&b, gstr(ARG(2)), arg(4), false, false);
  int64_t r = -1;
  if (f && beginWrite(f)) {
    if (f->std || f->unbuffered) r = writeOut(f, b.s ? b.s : "", b.n) ? (int64_t)b.n : -1;
    else { r = (int64_t)b.n; for (size_t i = 0; i < b.n; i++) if (putByte(f, (uint8_t)b.s[i]) < 0) { r = -1; break; } }
  }
  free(b.s); return (uint64_t)r;
}
// The wide family (swprintf): the format and the result are UTF-16; it is formatted through UTF-8.
static void utf8ToGuestWide(const char *s, size_t n, uint64_t dst, uint64_t count, size_t *units) {
  size_t o = 0;
  for (size_t i = 0; i < n;) {
    uint32_t c = (uint8_t)s[i++];
    if (c >= 0xC0) { int more = c >= 0xF0 ? 3 : c >= 0xE0 ? 2 : 1; c &= 0x3F >> more; while (more-- && i < n) c = c << 6 | ((uint8_t)s[i++] & 63); }
    if (c >= 0x10000) { if (dst && o + 1 < count) { wr16(dst + 2 * o, (uint16_t)(0xD800 + ((c - 0x10000) >> 10))); wr16(dst + 2 * o + 2, (uint16_t)(0xDC00 + ((c - 0x10000) & 0x3FF))); } o += 2; }
    else { if (dst && o < count) wr16(dst + 2 * o, (uint16_t)c); o++; }
  }
  *units = o;
}
static uint64_t c_vswprintf(void) {  // __stdio_common_vswprintf(options, buffer, count, format, locale, args)
  uint64_t options = ARG(0), dst = ARG(1), count = ARG(2); Buf fb = {0}, b = {0};
  bputWide(&fb, ARG(3), -1); const char *fmt = fb.s ? fb.s : "";
  formatGuest(&b, fmt, arg(5), true, (options & 4) != 0);
  size_t units; utf8ToGuestWide(b.s ? b.s : "", b.n, 0, 0, &units);
  int64_t r;
  if (!dst) r = (int64_t)units;
  else {
    size_t written; utf8ToGuestWide(b.s ? b.s : "", b.n, dst, count, &written);
    if (units < count) { wr16(dst + 2 * units, 0); r = (int64_t)units; }
    else if (options & 2) { if (count) wr16(dst + 2 * (count - 1), 0); r = (int64_t)units; }
    else r = units == count ? (int64_t)units : -1;
  }
  free(fb.s); free(b.s); return (uint64_t)r;
}
static uint64_t c_vswprintf_s(void) {
  uint64_t options = ARG(0), dst = ARG(1), count = ARG(2); Buf fb = {0}, b = {0};
  bputWide(&fb, ARG(3), -1);
  formatGuest(&b, fb.s ? fb.s : "", arg(5), true, (options & 4) != 0);
  size_t units; utf8ToGuestWide(b.s ? b.s : "", b.n, 0, 0, &units);
  int64_t r = -1;
  if (dst && count) { if (units >= count) wr16(dst, 0); else { size_t w; utf8ToGuestWide(b.s ? b.s : "", b.n, dst, count, &w); wr16(dst + 2 * units, 0); r = (int64_t)units; } }
  free(fb.s); free(b.s); return (uint64_t)r;
}
// scanf: the input is a guest string; results go to the pointers in the va_list. secure (sscanf_s): %s, %c and %[
// take a buffer size after the pointer.
static void storeInt(uint64_t dst, int size, uint64_t v) {
  if (size == 'H') *G(dst) = (uint8_t)v; else if (size == 'h') wr16(dst, (uint16_t)v); else if (size == 'q' || size == 'L') wr64(dst, v); else wr32(dst, (uint32_t)v);
}
static bool inScanSet(int c, const char *set, const char *end) {
  for (const char *p = set; p < end; p++) {
    if (p + 2 < end && p[1] == '-' && p != set) { if (c >= (unsigned char)p[0] && c <= (unsigned char)p[2]) return true; p += 2; continue; }
    if (c == (unsigned char)*p) return true;
  }
  return false;
}
static int scanGuest(const char *in, const char *f, uint64_t ap, bool secure) {
  const char *s = in; int assigned = 0; bool converted = false;
  while (*f) {
    if (isspace((unsigned char)*f)) { while (isspace((unsigned char)*f)) f++; while (isspace((unsigned char)*s)) s++; continue; }
    if (*f != '%' || f[1] == '%') {
      if (*f == '%') { f++; while (isspace((unsigned char)*s)) s++; }
      if (*s != *f) break;
      s++; f++; continue;
    }
    f++;
    bool skip = *f == '*'; if (skip) f++;
    size_t width = 0; while (*f >= '0' && *f <= '9') width = width * 10 + (size_t)(*f++ - '0');
    int size = sizeModifier(&f); char conv = *f; if (!conv) break;
    f++;
    const char *setStart = 0, *setEnd = 0; bool negate = false;
    if (conv == '[') { if (*f == '^') { negate = true; f++; } setStart = f; if (*f == ']') f++; while (*f && *f != ']') f++; setEnd = f; if (*f) f++; }
    if (conv == 'n') { if (!skip) storeInt(vaNext(&ap), size, (uint64_t)(s - in)); continue; }
    if (conv != 'c' && conv != 'C' && conv != '[') while (isspace((unsigned char)*s)) s++;
    if (!*s) return converted || assigned ? assigned : -1;
    bool wide = size == 'l' || size == 'w' || conv == 'S' || conv == 'C';
    uint64_t dst = skip ? 0 : vaNext(&ap), cap = !skip && secure && strchr("sScC[", conv) ? (uint32_t)vaNext(&ap) : UINT64_MAX;
    switch (conv) {
      case 'd': case 'i': case 'u': case 'o': case 'x': case 'X': case 'p': {
        char tmp[80]; size_t lim = width && width < 79 ? width : 79; snprintf(tmp, sizeof tmp, "%.*s", (int)lim, s);
        size_t used; int base = conv == 'd' || conv == 'u' ? 10 : conv == 'o' ? 8 : conv == 'i' ? 0 : 16;
        uint64_t v = parseInt(tmp, &used, base, conv == 'd' || conv == 'i', 64);
        if (!used) return assigned;
        s += used; converted = true;
        if (!skip) { storeInt(dst, conv == 'p' ? 'q' : size, v); assigned++; }
        break;
      }
      case 'e': case 'E': case 'f': case 'F': case 'g': case 'G': case 'a': case 'A': {
        char tmp[128]; size_t lim = width && width < 127 ? width : 127; snprintf(tmp, sizeof tmp, "%.*s", (int)lim, s);
        size_t used; double v = parseDouble(tmp, &used); if (!used) return assigned;
        s += used; converted = true;
        if (!skip) { if (size == 'l' || size == 'L' || size == 'q') memcpy(G(dst), &v, 8); else { float x = (float)v; memcpy(G(dst), &x, 4); } assigned++; }
        break;
      }
      case 's': case 'S': case '[': case 'c': case 'C': {
        size_t n = 0, lim = width ? width : (conv == 'c' || conv == 'C') ? 1 : SIZE_MAX;
        while (s[n] && n < lim) {
          int c = (unsigned char)s[n];
          if (conv == '[' ? inScanSet(c, setStart, setEnd) == negate : (conv == 's' || conv == 'S') && isspace(c)) break;
          n++;
        }
        if (!n || ((conv == 'c' || conv == 'C') && n < lim)) return assigned;
        bool terminate = conv != 'c' && conv != 'C';
        if (!skip) {
          if (n + (terminate ? 1 : 0) > cap) { if (cap) { if (wide) wr16(dst, 0); else *G(dst) = 0; } return assigned; }
          for (size_t i = 0; i < n; i++) { if (wide) wr16(dst + 2 * i, (uint8_t)s[i]); else *G(dst + i) = (uint8_t)s[i]; }
          if (terminate) { if (wide) wr16(dst + 2 * n, 0); else *G(dst + n) = 0; }
          assigned++;
        }
        s += n; converted = true; break;
      }
      default: return assigned;
    }
  }
  return assigned;
}
static uint64_t c_vsscanf(void) {  // __stdio_common_vsscanf(options, buffer, count, format, locale, args)
  uint64_t count = ARG(2); size_t n = strnlen(S(ARG(1)), count == (uint64_t)-1 ? SIZE_MAX : count);
  char *in = malloc(n + 1); memcpy(in, G(ARG(1)), n); in[n] = 0;
  int r = scanGuest(in, gstr(ARG(3)), arg(5), ARG(0) & 1);
  free(in); return ires(r);
}

// ---- C++ exceptions (VCRUNTIME140, VCRUNTIME140_1) -------------------------------------------------
// _CxxThrowException(object, ThrowInfo) is answered here like Windows' RaiseException and the C++ frame handler
// together. The throw walks the guest stack from the throw point upwards with the mod's unwind data: .pdata
// RUNTIME_FUNCTION entries and their UNWIND_INFO, which say how each function's prologue moved the stack and where it
// saved registers. A frame whose handler is __CxxFrameHandler4 (directly or through the /GS cookie-check wrapper the
// compiler links into the mod) is searched with its FuncInfo4 tables: the state at the frame's instruction pointer,
// the try blocks around that state, their catch clauses' types against the thrown object's catchable types (by
// type name, as across DLLs on Windows). __CxxFrameHandler3 tables (older compilers) and __C_specific_handler
// scopes (__try/__except/__finally) are read the same way. Once a catch is found (first pass), the destructors of
// the frames in between run from their unwind maps (second pass), the catch object is made, and the catch block (a
// "funclet" the compiler split out of the function) runs on the same stack below the thrown object; when it returns,
// the object is destroyed and the function goes on at the continuation address with the registers it had at the
// call that threw. A catch block that throws again ("throw;" or a new exception) starts a nested throw: when its
// walk reaches the catch block's end (catchStub), it carries on in the function that holds the catch, from the
// catch's own state. Nothing catches it: only that script stops, with a log line naming the exception.
typedef struct { uint64_t r[16]; uint64_t rip; uint8_t xmm[16][16]; } Ctx;  // registers by x86 number (0 RAX ... 4 RSP ... 15 R15)
enum { HK_NONE, HK_FH4, HK_FH3, HK_SEH };
enum { FR_CODE, FR_NEST, FR_PARENT };
typedef struct Exc {               // a thrown object, held by a throw and by the catch blocks handling it
  uint64_t object, info, base;     // the object, its ThrowInfo, and the image the ThrowInfo's offsets count from
  uint64_t record;                 // EXCEPTION_RECORD (152 bytes), CONTEXT (1232) and EXCEPTION_POINTERS (16) for filters
  int refs; bool hostObject;       // made by the runtime (std::out_of_range...): its memory goes after its destructor
} Exc;
typedef struct { int tryLow, tryHigh, catchHigh; } TryBlock;
typedef struct { uint32_t adjectives; uint64_t type, handler, cont[2]; int contCount; int32_t catchObj; bool hasCatchObj; } Handler;
typedef struct Frame {
  int kind; Ctx ctx;               // ctx: the frame's registers, ctx.rip where it is (the return address of its call)
  uint64_t base, begin, end, frame;  // image base, function start and end, establisher frame
  int hk; uint64_t data; uint8_t phases;  // handler kind and data; the passes it takes part in (1 search, 2 unwind)
  int state;                       // FR_PARENT: the state inside its running catch block; -2: from ctx.rip
  bool skipUnwind;                 // FR_PARENT whose catch funclet's frame already unwound it (FH3 shares tables)
  Nest *nest; struct Catch *boundary;  // FR_PARENT: the catch block it comes out of; FR_CODE: the catch block whose funclet it is
} Frame;
typedef struct Catch {             // a catch block running
  struct Catch *outer; Exc *exc;
  Frame parent;                    // the function that holds it (resumed at a continuation address afterwards)
  TryBlock tb; Handler h;
  uint64_t sp;                     // stack pointer when the catch block returns into catchStub
  uint64_t savedException, savedContext;  // __current_exception() outside it
  struct Catch *within;            // found in the frame of another catch block's funclet (FH3): its function may go on instead
} Catch;
typedef struct Throw {
  Exc *exc; Frame *frames; int count, cap, next, target, resumeDepth;
  TryBlock tb; Handler h; uint64_t catchable; int scope;  // the catch found (or the __except scope record)
  uint64_t sp, at;                 // stack pointer and return address of the throw: the object may live just above sp
  const char *why;                 // why it stops the script, when nothing catches it
} Throw;
static uint64_t rtBase;  // the runtime's own image (its RTTI and ThrowInfos count offsets from here)

static Frame *addFrame(Throw *t) {
  if (t->count == t->cap) { t->cap = t->cap ? 2 * t->cap : 32; t->frames = realloc(t->frames, sizeof(Frame) * (size_t)t->cap); }
  Frame *f = &t->frames[t->count++]; memset(f, 0, sizeof *f); f->state = -2; return f;
}
static void freeThrow(Throw *t) { free(t->frames); free(t); }
static void ctxFromMachine(Ctx *c) {
  struct Machine *m = cur->m; for (int i = 0; i < 16; i++) c->r[i] = Get64(m->weg[i]);
  memcpy(c->xmm, m->xmm, sizeof c->xmm); c->rip = rd64(c->r[4]); c->r[4] += 8;  // the import stub: a leaf, its return address on top
}
static void ctxFromNest(Ctx *c, Nest *n) {
  for (int i = 0; i < 16; i++) c->r[i] = Get64(n->regs[i]);
  memcpy(c->xmm, n->xmm, sizeof c->xmm); c->rip = rd64(n->sp); c->r[4] = n->sp + 8;
}
static void ctxToMachine(const Ctx *c, uint64_t ip) {
  struct Machine *m = cur->m;
  static int debug = -1; if (debug < 0) debug = getenv("ASI_DEBUG_EH") != 0;  // ASI_DEBUG_EH: log where throws resume
  if (debug) { Module *mod = moduleAt(ip); logf_("ASI EH: resume at %s+0x%llx with rsp 0x%llx rbp 0x%llx rbx 0x%llx rsi 0x%llx rdi 0x%llx (was rsp 0x%llx)", mod ? mod->name : "?", (unsigned long long)(mod ? ip - mod->base : ip),
                       (unsigned long long)c->r[4], (unsigned long long)c->r[5], (unsigned long long)c->r[3], (unsigned long long)c->r[6], (unsigned long long)c->r[7], (unsigned long long)Get64(m->sp)); }
  for (int i = 0; i < 16; i++) Put64(m->weg[i], c->r[i]);
  memcpy(m->xmm, c->xmm, sizeof c->xmm); m->ip = ip;
}

// The RUNTIME_FUNCTION entry around pc, 0 for a leaf function (no entry: its return address is on top of the stack).
static uint64_t functionEntry(Module *mod, uint64_t pc) {
  if (!mod || !mod->pdata) return 0;
  uint32_t rva = (uint32_t)(pc - mod->base); uint64_t lo = 0, hi = mod->pdataCount;
  while (lo < hi) { uint64_t mid = (lo + hi) / 2, e = mod->pdata + 12 * mid; if (rva < rd32(e)) hi = mid; else if (rva >= rd32(e + 4)) lo = mid + 1; else return e; }
  return 0;
}
// One frame up, as RtlVirtualUnwind: c becomes the caller's registers. Gives the establisher frame (the stack pointer
// after the prologue, or the frame register minus its offset) and the handler with its data and UNW_FLAG bits.
static bool unwindFrame(uint64_t base, uint64_t fe, Ctx *c, uint64_t *establisher, uint64_t *handler, uint64_t *data, uint8_t *flagsOut) {
  uint64_t pc = c->rip, frame = c->r[4], info = 0; uint8_t flags = 0; bool inProlog = false, machineFrame = false;
  *handler = 0; *data = 0; *flagsOut = 0;
  for (int chain = 0; chain < 32; chain++) {
    info = base + rd32(fe + 8);
    uint8_t vf = *G(info), prolog = *G(info + 1), count = *G(info + 2), fr = *G(info + 3);
    if ((vf & 7) != 1 && (vf & 7) != 2) return false;
    flags = vf >> 3;
    if (fr & 15) frame = c->r[fr & 15] - 16ull * (fr >> 4);
    uint64_t begin = base + rd32(fe); uint32_t prologOffset = pc >= begin && pc < begin + prolog ? (uint32_t)(pc - begin) : 0xFFFFFFFFu;
    inProlog = prologOffset != 0xFFFFFFFFu;
    for (int i = 0; i < count;) {
      uint64_t code = info + 4 + 2 * (uint64_t)i; uint8_t offset = *G(code), op = *G(code + 1) & 15, opInfo = *G(code + 1) >> 4;
      int slots = op == 1 ? (opInfo ? 3 : 2) : op == 4 || op == 6 || op == 8 ? 2 : op == 5 || op == 9 ? 3 : 1;
      if (prologOffset < offset) { i += slots; continue; }  // that prologue instruction hasn't run yet
      switch (op) {
        case 0: c->r[opInfo] = rd64(c->r[4]); c->r[4] += 8; break;                     // UWOP_PUSH_NONVOL
        case 1: c->r[4] += opInfo ? rd32(code + 2) : 8ull * rd16(code + 2); break;     // UWOP_ALLOC_LARGE
        case 2: c->r[4] += 8ull * opInfo + 8; break;                                   // UWOP_ALLOC_SMALL
        case 3: c->r[4] = frame; break;                                                // UWOP_SET_FPREG
        case 4: c->r[opInfo] = rd64(frame + 8ull * rd16(code + 2)); break;             // UWOP_SAVE_NONVOL
        case 5: c->r[opInfo] = rd64(frame + rd32(code + 2)); break;                    // UWOP_SAVE_NONVOL_FAR
        case 6: break;                                                                 // UWOP_EPILOG (version 2)
        case 8: memcpy(c->xmm[opInfo], G(frame + 16ull * rd16(code + 2)), 16); break;  // UWOP_SAVE_XMM128
        case 9: memcpy(c->xmm[opInfo], G(frame + rd32(code + 2)), 16); break;          // UWOP_SAVE_XMM128_FAR
        case 10: if (opInfo) c->r[4] += 8; c->rip = rd64(c->r[4]); c->r[4] = rd64(c->r[4] + 24); machineFrame = true; break;  // UWOP_PUSH_MACHFRAME
        default: return false;
      }
      i += slots;
    }
    if (!(flags & 4)) break;
    fe = info + 4 + 2 * (uint64_t)((count + 1) & ~1);  // UNW_FLAG_CHAININFO: the primary RUNTIME_FUNCTION follows the codes
  }
  if (!machineFrame) { c->rip = rd64(c->r[4]); c->r[4] += 8; }
  *establisher = frame;
  if ((flags & 3) && !inProlog) {
    uint8_t count = *G(info + 2); uint64_t at = info + 4 + 2 * (uint64_t)((count + 1) & ~1);
    *handler = base + rd32(at); *data = at + 4; *flagsOut = flags & 3;
  }
  return true;
}
static bool stepOut(Ctx *c) {  // one frame up, nothing recorded
  Module *mod = moduleAt(c->rip); if (!mod) return false;
  uint64_t fe = functionEntry(mod, c->rip), frame, handler, data; uint8_t flags;
  if (!fe) { c->rip = rd64(c->r[4]); c->r[4] += 8; return true; }
  return unwindFrame(mod->base, fe, c, &frame, &handler, &data, &flags);
}

// Which runtime handler a frame's handler is: the import itself (through its "jmp [rip+x]" thunk), or a /GS wrapper
// in the mod (__GSHandlerCheck_EH4, _EH, _SEH) that checks the stack cookie and then calls one of them (gs: the
// handler data then carries the wrapper's flags). Plain __GSHandlerCheck only checks the cookie: no handler.
static const char *stubNameAt(uint64_t a) {
  if (a < stubs + 16 * ID_FIRST || a >= stubs + 16 * (uint64_t)(ID_FIRST + stubCount) || (a - stubs) % 16) return 0;
  return stubName[(a - stubs) / 16 - ID_FIRST];
}
static const char *thunkImport(Module *mod, uint64_t a) {
  if (a < mod->base || a + 6 > mod->base + mod->size || rd16(a) != 0x25FF) return 0;
  uint64_t slot = a + 6 + (uint64_t)(int64_t)(int32_t)rd32(a + 2);
  return slot >= mod->base && slot + 8 <= mod->base + mod->size ? stubNameAt(rd64(slot)) : 0;
}
static int handlerKindOf(const char *name) {
  return !name ? HK_NONE : !strcmp(name, "__CxxFrameHandler4") ? HK_FH4 : !strcmp(name, "__CxxFrameHandler3") ? HK_FH3 : !strcmp(name, "__C_specific_handler") ? HK_SEH : HK_NONE;
}
static int classifyHandler(uint64_t h, bool *gs) {
  static struct { uint64_t at; int kind; bool gs; } seen[128]; static int seenCount;
  for (int i = 0; i < seenCount; i++) if (seen[i].at == h) { *gs = seen[i].gs; return seen[i].kind; }
  Module *mod = moduleAt(h); int kind = mod ? handlerKindOf(thunkImport(mod, h)) : HK_NONE; *gs = false;
  if (mod && kind == HK_NONE) {
    uint64_t fe = functionEntry(mod, h), end = fe ? mod->base + rd32(fe + 4) : h + 256;
    for (uint64_t a = h; a + 6 <= end && kind == HK_NONE; a++) {
      uint8_t b = *G(a);
      if (!fe && b == 0xC3 && *G(a + 1) == 0xCC) break;  // the end of the function (ret, then padding)
      if (b == 0xE8 || b == 0xE9) kind = handlerKindOf(thunkImport(mod, a + 5 + (uint64_t)(int64_t)(int32_t)rd32(a + 1)));
      if (kind == HK_NONE && b == 0xFF && (*G(a + 1) == 0x15 || *G(a + 1) == 0x25)) {
        uint64_t slot = a + 6 + (uint64_t)(int64_t)(int32_t)rd32(a + 2);
        if (slot >= mod->base && slot + 8 <= mod->base + mod->size) kind = handlerKindOf(stubNameAt(rd64(slot)));
      }
    }
    *gs = kind != HK_NONE;
  }
  if (seenCount < 128) { seen[seenCount].at = h; seen[seenCount].kind = kind; seen[seenCount].gs = *gs; seenCount++; }
  return kind;
}

// The thrown object: Windows' C++ exception record for filters and __current_exception.
static Exc *newExc(uint64_t object, uint64_t info, uint64_t base, bool hostObject) {
  Exc *x = calloc(1, sizeof *x); x->object = object; x->info = info; x->base = base; x->hostObject = hostObject; x->refs = 1;
  x->record = galloc(152 + 1232 + 16);
  if (x->record) {
    uint64_t r = x->record, ctx = r + 152, pointers = ctx + 1232;
    wr32(r, 0xE06D7363); wr32(r + 4, 1); wr64(r + 16, callerIp()); wr32(r + 24, 4);  // C++ exception, non-continuable, 4 parameters
    wr64(r + 32, 0x19930520); wr64(r + 40, object); wr64(r + 48, info); wr64(r + 56, base);
    wr32(ctx + 48, 0x10000B);  // CONTEXT_FULL; RAX..R15 at 120, RIP at 248
    for (int i = 0; i < 16; i++) wr64(ctx + 120 + 8 * (uint64_t)i, Get64(cur->m->weg[i]));
    wr64(ctx + 248, callerIp()); wr64(pointers, r); wr64(pointers + 8, ctx);
  }
  return x;
}
static uint64_t excPointers(Exc *x) { return x->record ? x->record + 152 + 1232 : 0; }
static void releaseExc(Exc *x, bool destroy) {
  if (!x || --x->refs > 0) return;
  if (destroy && x->info && x->object) { int32_t dtor = (int32_t)rd32(x->info + 4); if (dtor) GUEST_SAFE(x->base + (uint64_t)(int64_t)dtor, x->object); }
  if (x->hostObject && x->object) H.free(x->object - HEADER);
  if (x->record) H.free(x->record);
  free(x);
}
// An object pointer moved to a base class (PMD: member displacement, virtual base table displacement and entry).
static uint64_t adjustPointer(uint64_t p, int32_t mdisp, int32_t pdisp, int32_t vdisp) {
  uint64_t r = p + (uint64_t)(int64_t)mdisp;
  if (pdisp >= 0) r += (uint64_t)(int64_t)pdisp + (uint64_t)(int64_t)(int32_t)rd32(rd64(p + (uint64_t)(int64_t)pdisp) + (uint64_t)(int64_t)vdisp);
  return r;
}
// ".?AVout_of_range@std@@" -> "std::out_of_range", ".H" -> "int": for log lines.
static void typeName(const char *d, char *out, size_t cap) {
  if (!strncmp(d, ".?AV", 4) || !strncmp(d, ".?AU", 4)) {
    const char *parts[8]; int lens[8], n = 0;
    for (const char *p = d + 4; *p && *p != '@' && n < 8;) { const char *e = strchr(p, '@'); if (!e) break; parts[n] = p; lens[n++] = (int)(e - p); p = e + 1; }
    size_t o = 0; out[0] = 0;
    for (int i = n - 1; i >= 0 && o < cap; i--) o += (size_t)snprintf(out + o, cap - o, "%s%.*s", i < n - 1 ? "::" : "", lens[i], parts[i]);
    return;
  }
  static const char *basic[][2] = {{".H", "int"}, {".I", "unsigned int"}, {".J", "long"}, {".K", "unsigned long"}, {".N", "double"}, {".M", "float"},
    {".D", "char"}, {".E", "unsigned char"}, {".F", "short"}, {".G", "unsigned short"}, {"._N", "bool"}, {"._J", "__int64"}, {"._K", "unsigned __int64"},
    {".PEAD", "char *"}, {".PEBD", "const char *"}, {".PEA_W", "wchar_t *"}, {".PEB_W", "const wchar_t *"}};
  for (size_t i = 0; i < sizeof basic / sizeof *basic; i++) if (!strcmp(d, basic[i][0])) { snprintf(out, cap, "%s", basic[i][1]); return; }
  snprintf(out, cap, "%s", d);
}
static void describeExc(Exc *x, char *out, size_t cap) {
  if (!x || !x->info) { snprintf(out, cap, "of an unknown type"); return; }
  uint64_t list = x->base + (uint64_t)(int64_t)(int32_t)rd32(x->info + 12); uint32_t n = rd32(list);
  char name[160] = "?"; const char *what = 0;
  for (uint32_t i = 0; i < n && i < 32; i++) {
    uint64_t ct = x->base + (uint64_t)(int64_t)(int32_t)rd32(list + 4 + 4 * i), td = x->base + (uint64_t)(int64_t)(int32_t)rd32(ct + 4);
    if (!i) typeName(S(td + 16), name, sizeof name);
    if (!strcmp(S(td + 16), ".?AVexception@std@@") && x->object) {
      uint64_t e = adjustPointer(x->object, (int32_t)rd32(ct + 8), (int32_t)rd32(ct + 12), (int32_t)rd32(ct + 16)), w = rd64(e + 8);
      if (w) what = S(w);
    }
  }
  if (what) snprintf(out, cap, "%s: \"%.200s\"", name, what); else snprintf(out, cap, "%s", name);
}

// The catch clause's type against the thrown object's catchable types: by TypeDescriptor or by its decorated name,
// then reference, const, volatile and unaligned qualifiers (as Microsoft's TypeMatch). 1: catch (...).
#define MATCH_ANY 1
static uint64_t matchCatch(const Handler *c, Exc *x) {
  if (!c->type || (c->adjectives & 0x40) || !*S(c->type + 16)) return MATCH_ANY;  // catch (...), or std's catch-all
  if (!x->info) return 0;
  uint32_t attributes = rd32(x->info); uint64_t list = x->base + (uint64_t)(int64_t)(int32_t)rd32(x->info + 12); uint32_t n = rd32(list);
  for (uint32_t i = 0; i < n && i < 64; i++) {
    uint64_t ct = x->base + (uint64_t)(int64_t)(int32_t)rd32(list + 4 + 4 * i), td = x->base + (uint64_t)(int64_t)(int32_t)rd32(ct + 4);
    if (td != c->type && strcmp(S(td + 16), S(c->type + 16))) continue;
    if ((rd32(ct) & 2) && !(c->adjectives & 8)) continue;          // only catchable by reference
    if ((attributes & 1) && !(c->adjectives & 1)) continue;        // const object, non-const catch
    if ((attributes & 4) && !(c->adjectives & 4)) continue;        // unaligned
    if ((attributes & 2) && !(c->adjectives & 2)) continue;        // volatile
    return ct;
  }
  return 0;
}
// The catch object in the catching function's frame: a reference to the thrown object, a copy of a scalar or
// pointer, or a copy made by the type's copy constructor (as Microsoft's BuildCatchObject).
static void buildCatchObject(const Handler *c, uint64_t ct, Exc *x, uint64_t frame) {
  if (ct == MATCH_ANY || !c->hasCatchObj || !c->type || !x->object) return;
  uint64_t dst = frame + (uint64_t)(int64_t)c->catchObj;
  int32_t mdisp = (int32_t)rd32(ct + 8), pdisp = (int32_t)rd32(ct + 12), vdisp = (int32_t)rd32(ct + 16);
  uint32_t properties = rd32(ct), size = rd32(ct + 20); int32_t copy = (int32_t)rd32(ct + 24);
  if (c->adjectives & 8) wr64(dst, adjustPointer(x->object, mdisp, pdisp, vdisp));
  else if (properties & 1) { memmove(G(dst), G(x->object), size); if (size == 8 && rd64(dst)) wr64(dst, adjustPointer(rd64(dst), mdisp, pdisp, vdisp)); }
  else if (!copy) memmove(G(dst), G(adjustPointer(x->object, mdisp, pdisp, vdisp)), size);
  else if (properties & 4) GUEST_SAFE(x->base + (uint64_t)(int64_t)copy, dst, adjustPointer(x->object, mdisp, pdisp, vdisp), 1);  // has a virtual base
  else GUEST_SAFE(x->base + (uint64_t)(int64_t)copy, dst, adjustPointer(x->object, mdisp, pdisp, vdisp));
}

// FuncInfo4 (__CxxFrameHandler4): compressed tables. Numbers are variable-length (the low bits of the first byte say
// how many bytes), offsets are plain 32-bit image offsets.
typedef struct { uint8_t header; uint64_t unwindMap, tryMap, ipMap; uint32_t dispFrame; } FuncInfo4;
static uint32_t readU(uint64_t *p) {
  uint8_t b = *G(*p);
  if (!(b & 1)) { *p += 1; return b >> 1; }
  if ((b & 3) == 1) { uint32_t v = rd16(*p) >> 2; *p += 2; return v; }
  if ((b & 7) == 3) { uint32_t v = (rd32(*p) & 0xFFFFFF) >> 3; *p += 3; return v; }
  if ((b & 15) == 7) { uint32_t v = rd32(*p) >> 4; *p += 4; return v; }
  uint32_t v = rd32(*p + 1); *p += 5; return v;
}
static int32_t readI(uint64_t *p) { int32_t v = (int32_t)rd32(*p); *p += 4; return v; }
// Header bits: 1 a catch funclet's own tables, 2 separated code (a table of IP maps per code segment), 4 BBT flags,
// 8 unwind map, 16 try block map, 32 /EHs, 64 noexcept.
static void funcInfo4(const Frame *f, FuncInfo4 *fi) {
  uint64_t p = f->base + rd32(f->data); fi->header = *G(p); p++;
  if (fi->header & 4) readU(&p);
  fi->unwindMap = fi->header & 8 ? f->base + (uint64_t)(int64_t)readI(&p) : 0;
  fi->tryMap = fi->header & 16 ? f->base + (uint64_t)(int64_t)readI(&p) : 0;
  fi->ipMap = 0;
  if (fi->header & 2) {
    uint64_t seg = f->base + (uint64_t)(int64_t)readI(&p); uint32_t n = readU(&seg), start = (uint32_t)(f->begin - f->base);
    for (uint32_t i = 0; i < n; i++) { uint32_t s = (uint32_t)readI(&seg); int32_t map = readI(&seg); if (s == start) { fi->ipMap = f->base + (uint64_t)(int64_t)map; break; } }
  } else fi->ipMap = f->base + (uint64_t)(int64_t)readI(&p);
  fi->dispFrame = fi->header & 1 ? readU(&p) : 0;
}
static int state4(const Frame *f, const FuncInfo4 *fi) {
  if (f->state != -2) return f->state;
  if (!fi->ipMap) return -1;
  uint64_t p = fi->ipMap, at = f->begin; uint32_t n = readU(&p); int state = -1;
  for (uint32_t i = 0; i < n; i++) { at += readU(&p); int s = (int)readU(&p) - 1; if (f->ctx.rip < at) break; state = s; }
  return state;
}
// A catch funclet's tables say where its function's frame pointer is kept: its objects live in that frame.
static uint64_t objectFrame4(const Frame *f, const FuncInfo4 *fi) { return fi->header & 1 ? rd64(f->frame + fi->dispFrame) : f->frame; }
// The unwind map: entries in state order; each says what to destroy and how far back (in bytes) the next state's
// entry is (before the start: state -1). Runs the actions from state `from` down to (not including) state `to`.
static void unwind4(const Frame *f, const FuncInfo4 *fi, uint64_t frame, int from, int to) {
  if (!fi->unwindMap || from <= to) return;
  uint64_t p = fi->unwindMap; uint32_t n = readU(&p); uint64_t start = p, last = start - 1, at = start;
  if (from >= (int)n) return;
  for (uint64_t q = start, i = 0; i < (uint64_t)from; i++) {  // find the entries of states `from` and `to`
    uint64_t entry = q; uint32_t v = readU(&q); if ((v & 3) == 1 || (v & 3) == 2) { readI(&q); readU(&q); } else if ((v & 3) == 3) readI(&q);
    if ((int)i == to) last = entry;
    at = q;
  }
  for (int guard = 0; at > last && at >= start && guard < 100000; guard++) {
    uint64_t entry = at, q = at; uint32_t v = readU(&q); int type = (int)(v & 3); uint32_t back = v >> 2; int32_t action = 0; uint32_t object = 0;
    if (type == 1 || type == 2) { action = readI(&q); object = readU(&q); } else if (type == 3) action = readI(&q);
    if (type == 1) GUEST_SAFE(f->base + (uint64_t)(int64_t)action, frame + object, frame);                 // destructor of an object in the frame
    else if (type == 2) GUEST_SAFE(f->base + (uint64_t)(int64_t)action, rd64(frame + object), frame);      // destructor through a pointer in the frame
    else if (type == 3) GUEST_SAFE(f->base + (uint64_t)(int64_t)action, frame, frame);                     // an unwind funclet
    if (!back) break;
    at = entry - back;
  }
}
static void decodeHandler4(uint64_t *q, const Frame *f, Handler *c) {
  memset(c, 0, sizeof *c);
  uint8_t h = *G(*q); (*q)++;
  if (h & 1) c->adjectives = readU(q);
  if (h & 2) c->type = f->base + (uint64_t)(int64_t)readI(q);
  if (h & 4) { c->catchObj = (int32_t)readU(q); c->hasCatchObj = true; }
  c->handler = f->base + (uint64_t)(int64_t)readI(q);
  c->contCount = (h >> 4) & 3; if (c->contCount == 3) c->contCount = 0;
  for (int k = 0; k < c->contCount; k++) c->cont[k] = h & 8 ? f->base + (uint64_t)(int64_t)readI(q) : f->begin + readU(q);
}
static bool findCatch4(const Frame *f, const FuncInfo4 *fi, int state, Throw *t) {
  if (!fi->tryMap) return false;
  uint64_t p = fi->tryMap; uint32_t n = readU(&p);
  for (uint32_t i = 0; i < n; i++) {
    TryBlock tb; tb.tryLow = (int)readU(&p); tb.tryHigh = (int)readU(&p); tb.catchHigh = (int)readU(&p); int32_t handlers = readI(&p);
    if (state < tb.tryLow || state > tb.tryHigh) continue;
    uint64_t q = f->base + (uint64_t)(int64_t)handlers; uint32_t m = readU(&q);
    for (uint32_t j = 0; j < m; j++) {
      Handler c; decodeHandler4(&q, f, &c); uint64_t ct = matchCatch(&c, t->exc);
      if (ct) { t->tb = tb; t->h = c; t->catchable = ct; return true; }
    }
  }
  return false;
}
// FuncInfo (__CxxFrameHandler3): plain tables of 32-bit fields; catch funclets share their function's tables.
typedef struct { uint32_t magic, nTry, nIp, flags; int maxState; uint64_t unwind, tryMap, ipMap; } FuncInfo3;
static void funcInfo3(const Frame *f, FuncInfo3 *fi) {
  uint64_t p = f->base + rd32(f->data);
  fi->magic = rd32(p) & 0x1FFFFFFF; fi->maxState = (int)rd32(p + 4);
  fi->unwind = rd32(p + 8) ? f->base + rd32(p + 8) : 0; fi->nTry = rd32(p + 12); fi->tryMap = f->base + rd32(p + 16);
  fi->nIp = rd32(p + 20); fi->ipMap = f->base + rd32(p + 24); fi->flags = fi->magic >= 0x19930522 ? rd32(p + 36) : 0;
}
static int state3(const Frame *f, const FuncInfo3 *fi) {
  if (f->state != -2) return f->state;
  uint32_t rva = (uint32_t)(f->ctx.rip - f->base); int state = -1;
  for (uint32_t i = 0; i < fi->nIp && i < 100000; i++) { if (rva < rd32(fi->ipMap + 8ull * i)) break; state = (int)rd32(fi->ipMap + 8ull * i + 4); }
  return state;
}
static void handler3(const Frame *f, uint64_t h, Handler *c) {
  memset(c, 0, sizeof *c); c->adjectives = rd32(h); int32_t type = (int32_t)rd32(h + 4); c->type = type ? f->base + (uint64_t)(int64_t)type : 0;
  c->catchObj = (int32_t)rd32(h + 8); c->hasCatchObj = c->catchObj != 0; c->handler = f->base + rd32(h + 12);
}
// In a catch funclet (its state is inside a catch region and it is that clause's handler), the objects live in its
// function's frame, kept at the clause's frame displacement (Microsoft's GetEstablisherFrame).
static uint64_t objectFrame3(const Frame *f, const FuncInfo3 *fi, int state) {
  uint32_t begin = (uint32_t)(f->begin - f->base);
  for (uint32_t i = fi->nTry; i-- > 0;) {
    uint64_t e = fi->tryMap + 20ull * i; int high = (int)rd32(e + 4), catchHigh = (int)rd32(e + 8);
    if (state <= high || state > catchHigh) continue;
    uint32_t n = rd32(e + 12); uint64_t hs = f->base + rd32(e + 16);
    for (uint32_t j = 0; j < n; j++) if (rd32(hs + 20ull * j + 12) == begin) return rd64(f->frame + (uint64_t)(int64_t)(int32_t)rd32(hs + 20ull * j + 16));
  }
  return f->frame;
}
static void unwind3(const Frame *f, const FuncInfo3 *fi, uint64_t frame, int from, int to) {
  for (int s = from, guard = 0; s > to && s >= 0 && s < fi->maxState && fi->unwind && guard < 100000; guard++) {
    uint64_t e = fi->unwind + 8ull * (uint64_t)s; int next = (int)rd32(e); int32_t action = (int32_t)rd32(e + 4);
    if (action) GUEST_SAFE(f->base + (uint64_t)(int64_t)action, frame, frame);
    s = next;
  }
}
static bool findCatch3(const Frame *f, const FuncInfo3 *fi, int state, Throw *t) {
  for (uint32_t i = 0; i < fi->nTry; i++) {
    uint64_t e = fi->tryMap + 20ull * i; TryBlock tb = {(int)rd32(e), (int)rd32(e + 4), (int)rd32(e + 8)};
    uint32_t n = rd32(e + 12); uint64_t hs = f->base + rd32(e + 16);
    if (state < tb.tryLow || state > tb.tryHigh) continue;
    for (uint32_t j = 0; j < n; j++) {
      Handler c; handler3(f, hs + 20ull * j, &c); uint64_t ct = matchCatch(&c, t->exc);
      if (ct) { t->tb = tb; t->h = c; t->catchable = ct; return true; }
    }
  }
  return false;
}
// The frame a catch block and its catch object use.
static uint64_t catchFrame(const Frame *f) {
  if (f->hk == HK_FH4) { FuncInfo4 fi; funcInfo4(f, &fi); return objectFrame4(f, &fi); }
  if (f->hk == HK_FH3) { FuncInfo3 fi; funcInfo3(f, &fi); return objectFrame3(f, &fi, state3(f, &fi)); }
  return f->frame;
}
// First pass over one frame. 1: it catches (t holds the try block and clause, or the __except scope); -1: the
// exception may not leave this function (noexcept: std::terminate); 0: on to the caller.
static int searchFrame(Throw *t, const Frame *f) {
  if (f->hk == HK_FH4) {
    FuncInfo4 fi; funcInfo4(f, &fi);
    if (findCatch4(f, &fi, state4(f, &fi), t)) return 1;
    if (fi.header & 0x40) { t->why = "left a function that may not throw (noexcept)"; return -1; }
  } else if (f->hk == HK_FH3) {
    FuncInfo3 fi; funcInfo3(f, &fi);
    if (findCatch3(f, &fi, state3(f, &fi), t)) return 1;
    if (fi.flags & 4) { t->why = "left a function that may not throw (noexcept)"; return -1; }
  } else if (f->hk == HK_SEH) {  // __try/__except: the filter decides (1 run the __except block, 0 search on)
    uint32_t n = rd32(f->data), rva = (uint32_t)(f->ctx.rip - f->base);
    for (uint32_t i = 0; i < n && i < 1000; i++) {
      uint64_t r = f->data + 4 + 16ull * i; uint32_t begin = rd32(r), end = rd32(r + 4), filter = rd32(r + 8), target = rd32(r + 12);
      if (rva < begin || rva >= end || !target) continue;
      int verdict = filter == 1 ? 1 : (int)(int32_t)GUEST_SAFE(f->base + filter, excPointers(t->exc), f->frame);
      if (verdict > 0) { t->scope = (int)i; return 1; }
    }
  }
  return 0;
}
// Second pass over one frame: its destructors down to state `to` (-1: all), or its __finally blocks.
static void unwindFrameTo(const Frame *f, int to) {
  if (f->hk == HK_FH4) { FuncInfo4 fi; funcInfo4(f, &fi); unwind4(f, &fi, objectFrame4(f, &fi), state4(f, &fi), to); }
  else if (f->hk == HK_FH3) { FuncInfo3 fi; funcInfo3(f, &fi); int s = state3(f, &fi); unwind3(f, &fi, objectFrame3(f, &fi, s), s, to); }
  else if (f->hk == HK_SEH) {
    uint32_t n = rd32(f->data), rva = (uint32_t)(f->ctx.rip - f->base), stop = to >= 0 ? (uint32_t)to : n;  // to: the target __except scope
    for (uint32_t i = 0; i < n && i < stop; i++) {
      uint64_t r = f->data + 4 + 16ull * i;
      if (rva >= rd32(r) && rva < rd32(r + 4) && !rd32(r + 12)) GUEST_SAFE(f->base + rd32(r + 8), 1, f->frame);  // __finally, abnormal end
    }
  }
}
static void endCatch(Catch *k) {
  Catch **p = &cur->catches; while (*p && *p != k) p = &(*p)->outer;
  if (*p) *p = k->outer;
  wr64(cur->teb + TEB_CUR_EXCEPTION, k->savedException); wr64(cur->teb + TEB_CUR_CONTEXT, k->savedContext);
  Exc *x = k->exc; free(k); releaseExc(x, true);
}
static void uncaughtStop(Throw *t) {
  char what[400]; describeExc(t->exc, what, sizeof what); Module *mod = moduleAt(t->at);
  logf_("ASI %s: a C++ exception (%s) %s (thrown at +0x%llx); this script is stopped.", mod ? mod->name : "?", what,
        t->why ? t->why : "was not caught", (unsigned long long)(mod ? t->at - mod->base : t->at));
  freeThrow(t); stopScript();
}
// The first few exceptions caught are logged (type, message, where thrown and caught), for support.
static void logCaught(Throw *t, uint64_t where, const char *how) {
  static int logged; if (logged >= 8) return;
  char what[400]; describeExc(t->exc, what, sizeof what); Module *from = moduleAt(t->at), *to = moduleAt(where);
  logf_("ASI %s: a C++ exception (%s) thrown at +0x%llx is caught %s +0x%llx%s", from ? from->name : "?", what,
        (unsigned long long)(from ? t->at - from->base : t->at), how, (unsigned long long)(to ? where - to->base : where), ++logged == 8 ? " (later ones aren't logged)." : ".");
}
// The second pass from t->next, then the catch. Leaving a nested call made by an import ends that call (the import
// returns at once) and goes on in onSyscall outside it (cur->pending).
static void continueThrow(Throw *t) {
  uint64_t floor = stackFloor; stackFloor = t->sp;
  for (; t->next < t->target; t->next++) {
    Frame *f = &t->frames[t->next];
    if (f->kind == FR_CODE && f->hk && (f->phases & 2)) unwindFrameTo(f, -1);
    else if (f->kind == FR_PARENT) { if (!f->skipUnwind && (f->phases & 2)) unwindFrameTo(f, -1); endCatch(f->boundary); }
    else if (f->kind == FR_NEST) {
      Nest *n = f->nest; n->done = n->threw = true;
      t->next++; t->resumeDepth = n->depth - 1; cur->pending = t;
      stackFloor = floor; rawReturn = thrown = true; return;
    }
  }
  Frame *f = &t->frames[t->target];
  if (f->kind == FR_NEST) {  // caught by a runtime function that handles exceptions itself (catch (...))
    logCaught(t, rd64(f->nest->sp), "by the C++ library called at");
    f->nest->done = f->nest->caught = true; cur->uncaught--;
    releaseExc(t->exc, true); freeThrow(t); stackFloor = floor; rawReturn = thrown = true; return;
  }
  if (f->hk == HK_SEH) {  // an __except block: its scope's inner __finally blocks first; RAX holds the exception code
    logCaught(t, f->ctx.rip, "by a __try/__except at");
    unwindFrameTo(f, t->scope); cur->uncaught--;
    Ctx c = f->ctx; c.r[0] = 0xE06D7363; uint64_t target = f->base + rd32(f->data + 4 + 16ull * (uint64_t)t->scope + 12);
    releaseExc(t->exc, false); freeThrow(t); stackFloor = floor;
    ctxToMachine(&c, target); rawReturn = thrown = true; return;
  }
  logCaught(t, f->ctx.rip, "by a catch block at");
  uint64_t frame = catchFrame(f);
  buildCatchObject(&t->h, t->catchable, t->exc, frame);
  unwindFrameTo(f, t->tb.tryLow);
  if (f->kind == FR_PARENT) endCatch(f->boundary);  // the catch block it came out of is over as well
  Catch *k = calloc(1, sizeof *k); k->exc = t->exc; k->parent = *f; k->parent.kind = FR_CODE; k->parent.state = -2; k->parent.boundary = 0; k->parent.skipUnwind = false;
  k->tb = t->tb; k->h = t->h; k->within = f->kind == FR_CODE ? f->boundary : 0;
  k->savedException = rd64(cur->teb + TEB_CUR_EXCEPTION); k->savedContext = rd64(cur->teb + TEB_CUR_CONTEXT);
  if (t->exc->record) { wr64(cur->teb + TEB_CUR_EXCEPTION, t->exc->record); wr64(cur->teb + TEB_CUR_CONTEXT, t->exc->record + 152); }
  k->outer = cur->catches; cur->catches = k; cur->uncaught--;
  // The catch block runs below the thrown object (and below every frame it may still need), returning to catchStub;
  // it finds its function's frame in RDX.
  struct Machine *m = cur->m; uint64_t top = t->sp < Get64(m->sp) ? t->sp : Get64(m->sp), site = (top - 512) & ~15ull;
  k->sp = site; wr64(site - 8, catchStub); Put64(m->sp, site - 8); Put64(m->cx, frame); Put64(m->dx, frame); m->ip = t->h.handler;
  freeThrow(t); stackFloor = floor; rawReturn = thrown = true;
}
static void continuePending(void) { Throw *t = cur->pending; cur->pending = 0; continueThrow(t); }
// The first pass: walk up from the import that threw until a frame catches, then the second pass.
static void runThrow(Exc *x) {
  Throw *t = calloc(1, sizeof *t); t->exc = x; t->sp = Get64(cur->m->sp); t->at = callerIp(); t->scope = -1;
  cur->uncaught++;
  Ctx c; ctxFromMachine(&c);
  Nest *nest = cur->nest; Catch *catches = cur->catches; bool found = false;
  for (int guard = 0; guard < 4096 && !found; guard++) {
    if (c.rip == exitStub || !c.rip) break;  // the bottom of the script's stack: nothing caught it
    if (c.rip == nestStub) {  // the end of a nested call: on in the import that made it, if that lets exceptions pass
      Nest *n = nest; while (n && n->site != c.r[4]) n = n->outer;
      if (!n) { t->why = "could not be followed up the stack"; break; }
      Frame *f = addFrame(t); f->kind = FR_NEST; f->nest = n; f->ctx = c;
      if (n->kind == NEST_CATCH) { t->target = t->count - 1; found = true; break; }
      if (n->kind == NEST_STOP) { t->why = "left a destructor or filter that ran during another exception"; break; }
      ctxFromNest(&c, n); nest = n->outer; continue;
    }
    if (c.rip == catchStub) {  // the end of a catch block: on in its function, from the catch block's state
      Catch *k = catches; while (k && k->sp != c.r[4]) k = k->outer;
      if (!k) { t->why = "could not be followed up the stack"; break; }
      catches = k->outer;
      Frame *f = addFrame(t); *f = k->parent; f->kind = FR_PARENT; f->boundary = k;
      f->state = k->tb.catchHigh;
      if (k->parent.hk == HK_FH3) f->skipUnwind = true;  // FH3: the catch funclet's frame (same tables) already covered it
      else if (k->parent.hk && (k->parent.phases & 1)) {
        int r = searchFrame(t, f);
        if (r > 0) { t->target = t->count - 1; found = true; break; }
        if (r < 0) break;
      }
      c = k->parent.ctx;
      if (!stepOut(&c)) { t->why = "could not be followed up the stack"; break; }
      continue;
    }
    Module *mod = moduleAt(c.rip);
    if (!mod) { t->why = "could not be followed up the stack"; break; }
    uint64_t fe = functionEntry(mod, c.rip);
    if (!fe) { c.rip = rd64(c.r[4]); c.r[4] += 8; continue; }  // a leaf function: just its return address
    Frame *f = addFrame(t); f->kind = FR_CODE; f->ctx = c; f->base = mod->base; f->begin = mod->base + rd32(fe); f->end = mod->base + rd32(fe + 4);
    uint64_t handler, data; uint8_t flags;
    if (!unwindFrame(mod->base, fe, &c, &f->frame, &handler, &data, &flags)) { t->why = "could not be followed up the stack"; break; }
    if (c.rip == catchStub) for (Catch *k = catches; k; k = k->outer) if (k->sp == c.r[4]) f->boundary = k;  // a catch block's funclet
    if (handler) {
      bool gs; f->hk = classifyHandler(handler, &gs); f->data = data; f->phases = flags;
      if (gs) f->phases = (uint8_t)(f->hk == HK_SEH ? rd32(data + 4 + 16ull * rd32(data)) : rd32(data + 4)) & 3;  // the /GS wrapper's own flags
    }
    if (f->hk && (f->phases & 1)) { int r = searchFrame(t, f); if (r > 0) { t->target = t->count - 1; found = true; break; } if (r < 0) break; }
    if (c.r[4] <= f->ctx.r[4]) { t->why = "could not be followed up the stack"; break; }  // callers sit higher on the stack
  }
  if (!found) { uncaughtStop(t); return; }
  continueThrow(t);
}
// A catch block returned into catchStub (its RAX in R10): the continuation is that address, or for FH4 clauses that
// list continuation addresses, an index into them. The thrown object is destroyed, then its function goes on.
static uint64_t r_catchReturn(void) {
  struct Machine *m = cur->m; uint64_t sp = Get64(m->sp); rawReturn = true;
  Catch *k = cur->catches; while (k && k->sp != sp) k = k->outer;
  if (!k) { logf_("ASI: a catch block returned to the wrong place; this script is stopped."); stopScript(); return 0; }
  uint64_t r = Get64(m->r10), cont = k->h.contCount && r < (uint64_t)k->h.contCount ? k->h.cont[r] : r;
  if (!moduleAt(cont)) { logf_("ASI: a catch block gave back a bad continuation address (0x%llx); this script is stopped.", (unsigned long long)cont); stopScript(); return 0; }
  // Found in another catch block's funclet (FH3 tables are shared): a try block inside that catch block goes on in the
  // funclet; one around it goes on in the function, and that catch block is over too.
  Catch *within = k->within; bool outside = within && (cont < k->parent.begin || cont >= k->parent.end);
  Ctx c = outside ? within->parent.ctx : k->parent.ctx;
  endCatch(k);
  if (outside) endCatch(within);
  ctxToMachine(&c, cont);
  return 0;
}
// Called when a script stops (or its thread is reused): catch blocks and throws it had are dropped.
static void ehAbandon(Co *co) {
  while (co->catches) { Catch *k = co->catches; co->catches = k->outer; if (k->exc && --k->exc->refs <= 0) { if (k->exc->record) H.free(k->exc->record); free(k->exc); } free(k); }
  if (co->pending) { freeThrow(co->pending); co->pending = 0; }
  co->nest = 0; co->nestDepth = 0; co->uncaught = 0; stackFloor = 0;
}

// ---- The C++ runtime's own exception types --------------------------------------------------------
// For exceptions the runtime itself throws (std::out_of_range from _Xout_of_range, std::bad_alloc...): RTTI type
// descriptors, catchable types, ThrowInfos and vtables in the runtime's own little image (rtBase), so a mod's
// catch (const std::exception &e) matches them by name and e.what() works.
enum { X_EXCEPTION, X_BAD_ALLOC, X_BAD_ARRAY_NEW_LENGTH, X_LOGIC_ERROR, X_LENGTH_ERROR, X_OUT_OF_RANGE, X_INVALID_ARGUMENT,
       X_RUNTIME_ERROR, X_BAD_FUNCTION_CALL, X_BAD_CAST, X_BAD_TYPEID, X_SYSTEM_ERROR_BASE, X_SYSTEM_ERROR, X_IOS_FAILURE, X_COUNT };
static const struct { const char *name; int base; uint32_t size; } stdClasses[X_COUNT] = {
  {".?AVexception@std@@", -1, 24}, {".?AVbad_alloc@std@@", X_EXCEPTION, 24}, {".?AVbad_array_new_length@std@@", X_BAD_ALLOC, 24},
  {".?AVlogic_error@std@@", X_EXCEPTION, 24}, {".?AVlength_error@std@@", X_LOGIC_ERROR, 24}, {".?AVout_of_range@std@@", X_LOGIC_ERROR, 24},
  {".?AVinvalid_argument@std@@", X_LOGIC_ERROR, 24}, {".?AVruntime_error@std@@", X_EXCEPTION, 24}, {".?AVbad_function_call@std@@", X_EXCEPTION, 24},
  {".?AVbad_cast@std@@", X_EXCEPTION, 24}, {".?AVbad_typeid@std@@", X_EXCEPTION, 24}, {".?AV_System_error@std@@", X_RUNTIME_ERROR, 40},
  {".?AVsystem_error@std@@", X_SYSTEM_ERROR_BASE, 40}, {".?AVfailure@ios_base@std@@", X_SYSTEM_ERROR, 40}};
static uint64_t stdVtable[X_COUNT], stdThrowInfo[X_COUNT], rtTop, rtEnd, genericCategory, iostreamCategory;
static uint64_t rtAlloc(uint64_t size) { uint64_t a = (rtTop + 15) & ~15ull; if (a + size > rtEnd) return 0; rtTop = a + size; return a; }
static uint32_t rtRva(uint64_t a) { return (uint32_t)(a - rtBase); }
// std::exception's data: {const char *what; bool doFree} (__std_exception_data).
static void excDataCopy(uint64_t from, uint64_t to) {
  uint64_t what = rd64(from); bool doFree = *G(from + 8);
  if (!doFree || !what) { wr64(to, what); *G(to + 8) = 0; return; }
  uint64_t copy = gstrdup(S(what)); wr64(to, copy); *G(to + 8) = copy ? 1 : 0;
}
static void excDataDestroy(uint64_t data) { if (*G(data + 8) && rd64(data)) H.free(rd64(data) - HEADER); wr64(data, 0); *G(data + 8) = 0; }
static uint64_t x_std_exception_copy(void) { excDataCopy(ARG(0), ARG(1)); return 0; }
static uint64_t x_std_exception_destroy(void) { excDataDestroy(ARG(0)); return 0; }
static uint64_t stdCopy(int cls) {
  uint64_t dst = ARG(0), src = ARG(1); excDataCopy(src + 8, dst + 8);
  if (stdClasses[cls].size > 24) memcpy(G(dst + 24), G(src + 24), 16);  // system_error's error_code
  wr64(dst, stdVtable[cls]); return dst;
}
#define STDCOPY(i) static uint64_t stdCopy##i(void) { return stdCopy(i); }
STDCOPY(0) STDCOPY(1) STDCOPY(2) STDCOPY(3) STDCOPY(4) STDCOPY(5) STDCOPY(6) STDCOPY(7) STDCOPY(8) STDCOPY(9) STDCOPY(10) STDCOPY(11) STDCOPY(12) STDCOPY(13)
static const Fn stdCopies[X_COUNT] = {stdCopy0, stdCopy1, stdCopy2, stdCopy3, stdCopy4, stdCopy5, stdCopy6, stdCopy7, stdCopy8, stdCopy9, stdCopy10, stdCopy11, stdCopy12, stdCopy13};
static uint64_t unknownWhat;
static uint64_t stdWhat(void) { uint64_t w = rd64(ARG(0) + 8); return w ? w : unknownWhat; }
static uint64_t stdDestroy(void) { excDataDestroy(ARG(0) + 8); return 0; }  // the destructor (ThrowInfo's)
static uint64_t stdDelete(void) { excDataDestroy(ARG(0) + 8); if (ARG(1) & 1) H.free(ARG(0) - HEADER); return ARG(0); }  // vtable[0]: scalar deleting destructor
static uint64_t nothing(void) { return ARG(0); }
// error_category for system_error's error_code: name() and the rest, enough for code().category().name().
static uint64_t catName(void) { return rd64(ARG(0) + 8) == 5 ? (uint64_t)rd64(rtBase + 8) : (uint64_t)rd64(rtBase); }
static uint64_t catMessage(void) { uint64_t s = ARG(1); memset(G(s), 0, 32); wr64(s + 24, 15); return s; }  // an empty std::string
static uint64_t catCondition(void) { uint64_t out = ARG(1); wr32(out, (uint32_t)ARG(2)); wr64(out + 8, ARG(0)); return out; }
static bool runtimeTypesInit(void) {
  rtBase = galloc(0x10000); if (!rtBase) return false;
  rtTop = rtBase + 16; rtEnd = rtBase + 0x10000;
  wr64(rtBase, rtAlloc(8)); memcpy(G(rd64(rtBase)), "generic", 8); wr64(rtBase + 8, rtAlloc(9)); memcpy(G(rd64(rtBase + 8)), "iostream", 9);
  unknownWhat = rtAlloc(18); memcpy(G(unknownWhat), "Unknown exception", 18);
  uint64_t typeInfoVtable = rtAlloc(16); wr64(typeInfoVtable + 8, hostStub("<type_info::~type_info>", nothing));
  uint64_t dtor = hostStub("<std::exception::~exception>", stdDestroy), del = hostStub("<std::exception::scalar deleting destructor>", stdDelete), what = hostStub("<std::exception::what>", stdWhat);
  uint64_t td[X_COUNT], ct[X_COUNT], chd[X_COUNT], bcd[X_COUNT];
  for (int i = 0; i < X_COUNT; i++) {
    size_t n = strlen(stdClasses[i].name) + 1; td[i] = rtAlloc(16 + n);
    wr64(td[i], typeInfoVtable + 8); memcpy(G(td[i] + 16), stdClasses[i].name, n);
    ct[i] = rtAlloc(28); wr32(ct[i], 0); wr32(ct[i] + 4, rtRva(td[i])); wr32(ct[i] + 8, 0); wr32(ct[i] + 12, (uint32_t)-1); wr32(ct[i] + 16, 0);
    wr32(ct[i] + 20, stdClasses[i].size); wr32(ct[i] + 24, rtRva(hostStub(stdClasses[i].name, stdCopies[i])));
  }
  for (int i = 0; i < X_COUNT; i++) {  // the class and its bases, most derived first
    int chain[8], n = 0; for (int c = i; c >= 0 && n < 8; c = stdClasses[c].base) chain[n++] = c;
    uint64_t list = rtAlloc(4 + 4ull * (uint64_t)n); wr32(list, (uint32_t)n); for (int k = 0; k < n; k++) wr32(list + 4 + 4ull * (uint64_t)k, rtRva(ct[chain[k]]));
    stdThrowInfo[i] = rtAlloc(16); wr32(stdThrowInfo[i], 0); wr32(stdThrowInfo[i] + 4, rtRva(dtor)); wr32(stdThrowInfo[i] + 8, 0); wr32(stdThrowInfo[i] + 12, rtRva(list));
    // RTTI for dynamic_cast and typeid: complete object locator, class hierarchy, base class descriptors.
    chd[i] = rtAlloc(16); bcd[i] = rtAlloc(28);
    uint64_t bases = rtAlloc(4ull * (uint64_t)n);
    wr32(chd[i], 0); wr32(chd[i] + 4, 0); wr32(chd[i] + 8, (uint32_t)n); wr32(chd[i] + 12, rtRva(bases));
    wr32(bcd[i], rtRva(td[i])); wr32(bcd[i] + 4, (uint32_t)(n - 1)); wr32(bcd[i] + 8, 0); wr32(bcd[i] + 12, (uint32_t)-1); wr32(bcd[i] + 16, 0); wr32(bcd[i] + 20, 0x40); wr32(bcd[i] + 24, rtRva(chd[i]));
    for (int k = 0; k < n; k++) wr32(bases + 4ull * (uint64_t)k, rtRva(bcd[chain[k]]));  // bases are built before their derived classes (lower index)
    uint64_t col = rtAlloc(24); wr32(col, 1); wr32(col + 4, 0); wr32(col + 8, 0); wr32(col + 12, rtRva(td[i])); wr32(col + 16, rtRva(chd[i])); wr32(col + 20, rtRva(col));
    uint64_t vt = rtAlloc(24); wr64(vt, col); wr64(vt + 8, del); wr64(vt + 16, what); stdVtable[i] = vt + 8;
  }
  uint64_t catVt = rtAlloc(56);
  wr64(catVt, hostStub("<error_category::~error_category>", nothing)); wr64(catVt + 8, hostStub("<error_category::name>", catName));
  wr64(catVt + 16, hostStub("<error_category::message>", catMessage)); wr64(catVt + 24, hostStub("<error_category::default_error_condition>", catCondition));
  wr64(catVt + 32, hostStub("<error_category::equivalent>", c_zero)); wr64(catVt + 40, hostStub("<error_category::equivalent 2>", c_zero));
  genericCategory = rtAlloc(16); wr64(genericCategory, catVt); wr64(genericCategory + 8, 3);   // _Generic_addr
  iostreamCategory = rtAlloc(16); wr64(iostreamCategory, catVt); wr64(iostreamCategory + 8, 5);  // _Iostream_addr
  return true;
}
// Throws one of the runtime's std exceptions from the import being answered. message: a guest string kept as is,
// or text copied to the guest heap.
static void throwStd(int cls, uint64_t guestMessage, const char *text, int code, uint64_t category) {
  uint64_t obj = heapAlloc(stdClasses[cls].size, true);
  if (!obj) { fatalStop("there was no memory left to throw a C++ exception"); return; }
  wr64(obj, stdVtable[cls]);
  if (guestMessage) wr64(obj + 8, guestMessage);
  else if (text) { wr64(obj + 8, gstrdup(text)); *G(obj + 16) = 1; }
  if (stdClasses[cls].size > 24) { wr32(obj + 24, (uint32_t)code); wr64(obj + 32, category); }
  runThrow(newExc(obj, stdThrowInfo[cls], rtBase, true));
}

// ---- VCRUNTIME140: throwing, RTTI, the frame handlers -------------------------------------------
static uint64_t x_CxxThrowException(void) {
  uint64_t object = ARG(0), info = ARG(1);
  if (!object && !info) {  // "throw;": the exception of the innermost catch block running goes on
    Catch *k = cur->catches;
    if (!k) { fatalStop("the mod rethrew an exception while none was being handled (std::terminate)"); return 0; }
    k->exc->refs++; runThrow(k->exc); return 0;
  }
  Module *mod = moduleAt(info);
  runThrow(newExc(object, info, mod ? mod->base : rtBase, false)); return 0;
}
// The handlers themselves only run from the dispatcher above, never from the mod: if called, "search on".
static uint64_t x_frameHandler(void) { return 1; }  // ExceptionContinueSearch
static uint64_t x_current_exception(void) { return cur->teb + TEB_CUR_EXCEPTION; }
static uint64_t x_current_exception_context(void) { return cur->teb + TEB_CUR_CONTEXT; }
static uint64_t x_uncaught_exceptions(void) { return (uint64_t)cur->uncaught; }
static uint64_t x_std_terminate(void) { fatalStop("std::terminate was called (a C++ exception where none may be)"); return 0; }
// dynamic_cast: the complete object's RTTI (vtable[-1] is its CompleteObjectLocator) lists every base class with
// where it sits; the first visible one with the target's type name is the answer.
static bool completeObject(uint64_t obj, uint64_t *complete, uint64_t *col, uint64_t *base) {
  uint64_t vt = rd64(obj); Module *mod = moduleAt(vt);
  if (!vt || (!mod && (vt < rtBase || vt >= rtBase + 0x10000))) return false;
  *col = rd64(vt - 8); if (!*col || rd32(*col) != 1) return false;
  *base = *col - (uint64_t)(int64_t)(int32_t)rd32(*col + 20);
  *complete = obj - rd32(*col + 4); uint32_t cd = rd32(*col + 8);
  if (cd) *complete += (uint64_t)(int64_t)(int32_t)rd32(obj - cd);
  return true;
}
static uint64_t x_RTDynamicCast(void) {
  uint64_t obj = ARG(0), target = ARG(3); bool isReference = ARG(4) & 1;
  if (!obj) return 0;
  uint64_t complete, col, base;
  if (completeObject(obj, &complete, &col, &base)) {
    uint64_t chd = base + rd32(col + 16), bases = base + rd32(chd + 12); uint32_t n = rd32(chd + 8);
    for (uint32_t i = 0; i < n && i < 1024; i++) {
      uint64_t bcd = base + rd32(bases + 4ull * i), td = base + rd32(bcd);
      if (td != target && strcmp(S(td + 16), S(target + 16))) continue;
      if (i && (rd32(bcd + 20) & 1)) continue;  // not visible (a private base)
      int32_t mdisp = (int32_t)rd32(bcd + 8), pdisp = (int32_t)rd32(bcd + 12), vdisp = (int32_t)rd32(bcd + 16);
      uint64_t offset = (uint64_t)(int64_t)mdisp;
      if (pdisp >= 0) offset += (uint64_t)(int64_t)pdisp + (uint64_t)(int64_t)(int32_t)rd32(rd64(complete + (uint64_t)(int64_t)pdisp) + (uint64_t)(int64_t)vdisp);
      return complete + offset;
    }
  }
  if (isReference) throwStd(X_BAD_CAST, 0, "Bad dynamic_cast!", 0, 0);
  return 0;
}
static uint64_t x_RTtypeid(void) {
  uint64_t complete, col, base;
  if (!ARG(0) || !completeObject(ARG(0), &complete, &col, &base)) { throwStd(X_BAD_TYPEID, 0, ARG(0) ? "Bad read pointer - no RTTI data!" : "Attempted a typeid of nullptr pointer!", 0, 0); return 0; }
  return base + rd32(col + 12);
}
static uint64_t x_RTCastToVoid(void) { uint64_t complete, col, base; return ARG(0) && completeObject(ARG(0), &complete, &col, &base) ? complete : ARG(0); }
// type_info: {vtable; _UndecoratedName; _DecoratedName[]}, the functions get &_UndecoratedName.
static uint64_t x_type_info_compare(void) { return ires(strcmp(S(ARG(0) + 9), S(ARG(1) + 9))); }
static uint64_t x_type_info_hash(void) { uint64_t h = 14695981039346656037ull; for (const char *s = S(ARG(0) + 9); *s; s++) h = (h ^ (uint8_t)*s) * 1099511628211ull; return h; }
static uint64_t x_type_info_name(void) {
  uint64_t data = ARG(0); if (rd64(data)) return rd64(data);
  const char *d = S(data + 8); char name[200], full[220]; typeName(d, name, sizeof name);
  snprintf(full, sizeof full, "%s%s", !strncmp(d, ".?AV", 4) ? "class " : !strncmp(d, ".?AU", 4) ? "struct " : "", name);
  uint64_t s = gstrdup(full); wr64(data, s); return s;
}

// ---- MSVCP140: the C++ library's compiled parts ---------------------------------------------------
// Microsoft's x64 layouts (Visual Studio 2015-2022), checked against the inline code of mods that use them:
// ios_base: vtable, _Stdstr +8, _Mystate +16, _Except +20, _Fmtfl +24, _Prec +32, _Wide +40, _Arr +48, _Calls +56,
//   _Ploc +64; basic_ios adds _Mystrbuf +72, _Tiestr +80, _Fillch +88 (96 bytes).
// basic_streambuf: vtable, _Gfirst, _Pfirst, _IGfirst, _IPfirst, _Gnext, _Pnext, _IGnext +56, _IPnext +64, _Gcount,
//   _Pcount, _IGcount +80, _IPcount +88, _Plocale +96 (104 bytes). The get and put positions are reached through the
//   _I* pointers (a file buffer points them at its FILE's _ptr/_cnt). Its virtual functions: 0 destructor, 1 _Lock,
//   2 _Unlock, 3 overflow, 4 pbackfail, 5 showmanyc, 6 underflow, 7 uflow, 8 xsgetn, 9 xsputn, 10 seekoff, 11 seekpos,
//   12 setbuf, 13 sync, 14 imbue.
// basic_ostream and basic_istream begin with a pointer to their virtual base table (entry 1: the offset of their
//   basic_ios); basic_istream adds _Chcount (+8). Their constructors take a last hidden "construct the virtual base"
//   flag. Member functions get `this` in RCX; a class returned by value goes through a hidden pointer in RDX.
// The iostream functions that catch exceptions inside (operator<<, flush...) call the stream buffer with NEST_CATCH:
// an exception from the buffer sets badbit, as their _CATCH_IO_END does.
#define IOS_STATE 16
#define IOS_EXCEPT 20
#define IOS_FLAGS 24
#define IOS_PREC 32
#define IOS_WIDE 40
#define IOS_LOC 64
#define IOS_BUF 72
#define IOS_TIE 80
#define IOS_FILL 88
static uint64_t globalLocimp, ctypeTable, ctypeVtable, codecvtVtable, streambufVtable, iosVtable, ostreamVbtable, istreamVbtable, iostreamVbtable;
static uint64_t vbase(uint64_t stream) { return stream + (uint64_t)(int64_t)(int32_t)rd32(rd64(stream) + 4); }  // its basic_ios
// A std::locale is 16 bytes on x64 (its two empty base classes take the first 8): _Ptr, its _Locimp, is at +8.
static uint64_t newLocale(void) { uint64_t l = heapAlloc(16, true); if (l) wr64(l + 8, globalLocimp); return l; }  // new locale (the "C" one)

// Locale: one "C" locale; facets are made on demand (_Getcat) and live for good (their reference count never ends them).
static uint64_t p_Getgloballocale(void) { return globalLocimp; }
static uint64_t p_Lockit(void) { wr32(ARG(0), (uint32_t)ARG(1)); return ARG(0); }  // one script runs at a time: nothing to lock
static uint64_t facetIncref(void) { wr32(ARG(0) + 8, rd32(ARG(0) + 8) + 1); return 0; }
static uint64_t facetDecref(void) { uint32_t n = rd32(ARG(0) + 8); if (n > 1) wr32(ARG(0) + 8, n - 1); return 0; }  // never "delete me"
static uint64_t newFacet(uint64_t vtable, uint64_t size) { uint64_t f = heapAlloc(size, true); if (f) { wr64(f, vtable); wr32(f + 8, 1); } return f; }
static uint64_t p_ctype_Getcat(void) {  // ctype<char>: {vtable, refs, _Ctype {_Page, _Table, _Delfl, _LocaleName}}
  uint64_t pp = ARG(0); if (pp && !rd64(pp)) { uint64_t f = newFacet(ctypeVtable, 48); if (f) wr64(f + 24, ctypeTable); wr64(pp, f); }
  return 2;  // _X_CTYPE
}
static uint64_t p_codecvt_Getcat(void) { uint64_t pp = ARG(0); if (pp && !rd64(pp)) wr64(pp, newFacet(codecvtVtable, 24)); return 2; }
// codecvt<char, char, mbstate_t> converts nothing: always_noconv, and in/out/unshift answer "noconv" (3).
static uint64_t p_always_noconv(void) { return 1; }
static uint64_t p_codecvt_inout(void) { wr64(ARG(4), ARG(2)); wr64(ARG(7), ARG(5)); return 3; }  // (this, state, from, from_end, &from_next, to, to_end, &to_next)
static uint64_t p_codecvt_unshift(void) { wr64(ARG(4), ARG(2)); return 3; }
// ctype<char>'s virtual functions after _Incref/_Decref: do_tolower, do_toupper, do_widen and do_narrow, each as a
// range and a single char (Microsoft puts overloads in reverse order: the range first). A char argument is below 256
// and a pointer never is, so each also answers the other form.
static bool looksLikeRange(void) { return ARG(1) >= 0x10000 && ARG(2) >= ARG(1); }
static uint64_t caseRange(int (*fn)(int)) { for (uint64_t p = ARG(1); p < ARG(2); p++) *G(p) = (uint8_t)fn(*G(p)); return ARG(2); }
static uint64_t ctLowerRange(void) { return ARG(1) < 256 ? (uint64_t)lower((int)(ARG(1) & 255)) : caseRange(lower); }
static uint64_t ctLowerChar(void) { return looksLikeRange() ? caseRange(lower) : (uint64_t)lower((int)(ARG(1) & 255)); }
static uint64_t ctUpperRange(void) { return ARG(1) < 256 ? (uint64_t)upper((int)(ARG(1) & 255)) : caseRange(upper); }
static uint64_t ctUpperChar(void) { return looksLikeRange() ? caseRange(upper) : (uint64_t)upper((int)(ARG(1) & 255)); }
static uint64_t ctWidenRange(void) { if (ARG(1) < 256) return ARG(1) & 255; memmove(G(ARG(3)), G(ARG(1)), ARG(2) - ARG(1)); return ARG(2); }
static uint64_t ctWidenChar(void) { if (looksLikeRange()) { memmove(G(ARG(3)), G(ARG(1)), ARG(2) - ARG(1)); return ARG(2); } return ARG(1) & 255; }
static uint64_t ctNarrowRange(void) { if (ARG(1) < 256) return ARG(1) & 255; memmove(G(ARG(4)), G(ARG(1)), ARG(2) - ARG(1)); return ARG(2); }
static uint64_t ctNarrowChar(void) { if (looksLikeRange()) { memmove(G(ARG(4)), G(ARG(1)), ARG(2) - ARG(1)); return ARG(2); } return ARG(1) & 255; }
// getloc() returns a locale by value (hidden pointer in RDX): the same "C" locale, one more reference.
static uint64_t localeCopy(uint64_t locPtr, uint64_t out) {
  uint64_t imp = locPtr ? rd64(locPtr + 8) : globalLocimp; if (!imp) imp = globalLocimp;
  wr64(out, 0); wr64(out + 8, imp); wr32(imp + 8, rd32(imp + 8) + 1); return out;
}
static uint64_t p_ios_getloc(void) { return localeCopy(rd64(ARG(0) + IOS_LOC), ARG(1)); }
static uint64_t p_sb_getloc(void) { return localeCopy(rd64(ARG(0) + 96), ARG(1)); }

// Stream buffers: the non-virtual members work on the get/put areas and call the virtual functions when they are
// empty or full, which may be the mod's own (a stringbuf's overflow, a filebuf's underflow).
static uint64_t gptr(uint64_t sb) { return rd64(rd64(sb + 56)); }
static uint64_t pptr(uint64_t sb) { return rd64(rd64(sb + 64)); }
static int gavail(uint64_t sb) { return gptr(sb) ? (int)rd32(rd64(sb + 80)) : 0; }
static int pavail(uint64_t sb) { return pptr(sb) ? (int)rd32(rd64(sb + 88)) : 0; }
static void gbump(uint64_t sb, int n) { uint64_t c = rd64(sb + 80), p = rd64(sb + 56); wr32(c, rd32(c) - (uint32_t)n); wr64(p, rd64(p) + (uint64_t)(int64_t)n); }
static void pbump(uint64_t sb, int n) { uint64_t c = rd64(sb + 88), p = rd64(sb + 64); wr32(c, rd32(c) - (uint32_t)n); wr64(p, rd64(p) + (uint64_t)(int64_t)n); }
static int64_t vcall(int kind, bool *caught, uint64_t obj, int slot, int n, uint64_t a1, uint64_t a2) {
  uint64_t args[3] = {obj, a1, a2};
  return (int64_t)guestCallAs(kind, rd64(rd64(obj) + 8 * (uint64_t)slot), args, n + 1, caught);
}
#define EOF_ (-1)
static int sbSgetc(uint64_t sb, int kind, bool *caught) { return gavail(sb) > 0 ? *G(gptr(sb)) : (int)vcall(kind, caught, sb, 6, 0, 0, 0); }
static int sbSbumpc(uint64_t sb, int kind, bool *caught) {
  if (gavail(sb) > 0) { uint8_t c = *G(gptr(sb)); gbump(sb, 1); return c; }
  return (int)vcall(kind, caught, sb, 7, 0, 0, 0);
}
static int sbSnextc(uint64_t sb, int kind, bool *caught) {
  if (gavail(sb) > 1) { gbump(sb, 1); return *G(gptr(sb)); }
  if (sbSbumpc(sb, kind, caught) == EOF_ || leaving() || (caught && *caught)) return EOF_;
  return sbSgetc(sb, kind, caught);
}
static int sbSputc(uint64_t sb, int c, int kind, bool *caught) {
  if (pavail(sb) > 0) { *G(pptr(sb)) = (uint8_t)c; pbump(sb, 1); return (uint8_t)c; }
  return (int)vcall(kind, caught, sb, 3, 1, (uint8_t)c, 0);
}
static uint64_t p_sgetc(void) { return ires(sbSgetc(ARG(0), NEST_PASS, 0)); }
static uint64_t p_sbumpc(void) { return ires(sbSbumpc(ARG(0), NEST_PASS, 0)); }
static uint64_t p_snextc(void) { return ires(sbSnextc(ARG(0), NEST_PASS, 0)); }
static uint64_t p_sputc(void) { return ires(sbSputc(ARG(0), (int)(ARG(1) & 255), NEST_PASS, 0)); }
static uint64_t p_sputn(void) { return (uint64_t)vcall(NEST_PASS, 0, ARG(0), 9, 2, ARG(1), ARG(2)); }  // xsputn
// basic_streambuf's own virtual functions (a derived buffer that doesn't override one calls these).
static uint64_t p_sb_uflow(void) {
  uint64_t sb = ARG(0); if ((int)vcall(NEST_PASS, 0, sb, 6, 0, 0, 0) == EOF_ || leaving()) return ires(EOF_);
  uint8_t c = *G(gptr(sb)); gbump(sb, 1); return c;
}
static uint64_t p_sb_xsgetn(void) {
  uint64_t sb = ARG(0), dst = ARG(1); int64_t count = (int64_t)ARG(2), copied = 0;
  while (count > 0) {
    int have = gavail(sb);
    if (have > 0) { int64_t k = count < have ? count : have; memmove(G(dst), G(gptr(sb)), (size_t)k); dst += (uint64_t)k; copied += k; count -= k; gbump(sb, (int)k); continue; }
    int c = (int)vcall(NEST_PASS, 0, sb, 7, 0, 0, 0); if (leaving() || c == EOF_) break;
    *G(dst++) = (uint8_t)c; copied++; count--;
  }
  return (uint64_t)copied;
}
static uint64_t p_sb_xsputn(void) {
  uint64_t sb = ARG(0), src = ARG(1); int64_t count = (int64_t)ARG(2), copied = 0;
  while (count > 0) {
    int room = pavail(sb);
    if (room > 0) { int64_t k = count < room ? count : room; memmove(G(pptr(sb)), G(src), (size_t)k); src += (uint64_t)k; copied += k; count -= k; pbump(sb, (int)k); continue; }
    int c = (int)vcall(NEST_PASS, 0, sb, 3, 1, *G(src), 0); if (leaving() || c == EOF_) break;
    src++; copied++; count--;
  }
  return (uint64_t)copied;
}
static uint64_t p_eof(void) { return ires(EOF_); }
static uint64_t p_this(void) { return ARG(0); }
static uint64_t p_seekfail(void) { uint64_t out = ARG(1); wr64(out, (uint64_t)-1); wr64(out + 8, 0); wr64(out + 16, 0); return out; }  // pos_type(-1), by hidden pointer
static uint64_t p_sb_Init(void) {
  uint64_t sb = ARG(0);
  wr64(sb + 24, sb + 8); wr64(sb + 32, sb + 16); wr64(sb + 56, sb + 40); wr64(sb + 64, sb + 48); wr64(sb + 80, sb + 72); wr64(sb + 88, sb + 76);
  wr64(sb + 8, 0); wr64(sb + 16, 0); wr64(sb + 40, 0); wr64(sb + 48, 0); wr32(sb + 72, 0); wr32(sb + 76, 0);
  return 0;
}
static uint64_t p_sb_Init6(void) {  // _Init(&gfirst, &gnext, &gcount, &pfirst, &pnext, &pcount)
  uint64_t sb = ARG(0); wr64(sb + 24, ARG(1)); wr64(sb + 56, ARG(2)); wr64(sb + 80, ARG(3)); wr64(sb + 32, ARG(4)); wr64(sb + 64, ARG(5)); wr64(sb + 88, ARG(6));
  return 0;
}
static uint64_t p_sb_ctor(void) { uint64_t sb = ARG(0); memset(G(sb), 0, 104); wr64(sb, streambufVtable); wr64(sb + 96, newLocale()); p_sb_Init(); return sb; }
static uint64_t p_sb_dtor(void) { uint64_t l = rd64(ARG(0) + 96); if (l) H.free(l - HEADER); wr64(ARG(0) + 96, 0); return 0; }
static uint64_t p_sb_delete(void) { uint64_t sb = ARG(0), flags = ARG(1); p_sb_dtor(); if (flags & 1) H.free(sb - HEADER); return sb; }

// basic_ios / ios_base.
static void iosInit(uint64_t ios, uint64_t sb, bool isStd) {
  (void)isStd;
  wr64(ios + 8, 0); wr32(ios + IOS_EXCEPT, 0); wr32(ios + IOS_FLAGS, 0x201); wr64(ios + IOS_PREC, 6); wr64(ios + IOS_WIDE, 0);  // skipws | dec
  wr64(ios + 48, 0); wr64(ios + 56, 0); wr64(ios + IOS_LOC, newLocale());
  wr64(ios + IOS_BUF, sb); wr64(ios + IOS_TIE, 0); *G(ios + IOS_FILL) = ' ';
  wr32(ios + IOS_STATE, sb ? 0 : 4);
}
// clear(): the new state; when it meets the exceptions mask, std::ios_base::failure is thrown (or, from a mod's own
// catch block with reraise set, that block's exception goes on).
static void iosClear(uint64_t ios, int state, bool reraise) {
  if (!rd64(ios + IOS_BUF)) state |= 4;
  state &= 0x17; wr32(ios + IOS_STATE, (uint32_t)state);
  int hit = state & (int)rd32(ios + IOS_EXCEPT);
  if (!hit) return;
  if (reraise && cur->catches) { Catch *k = cur->catches; k->exc->refs++; runThrow(k->exc); return; }
  throwStd(X_IOS_FAILURE, 0, hit & 4 ? "ios_base::badbit set" : hit & 2 ? "ios_base::failbit set" : "ios_base::eofbit set", 1, iostreamCategory);
}
static void iosSetstate(uint64_t ios, int state) { if (state) iosClear(ios, (int)rd32(ios + IOS_STATE) | state, false); }
static bool good(uint64_t ios) { return rd32(ios + IOS_STATE) == 0; }
static uint64_t p_ios_ctor(void) { memset(G(ARG(0)), 0, 96); wr64(ARG(0), iosVtable); return ARG(0); }
static uint64_t p_ios_dtor(void) { uint64_t ios = ARG(0), l = rd64(ios + IOS_LOC); if (l && !rd64(ios + 8)) { H.free(l - HEADER); wr64(ios + IOS_LOC, 0); } return 0; }
static uint64_t p_ios_delete(void) { uint64_t ios = ARG(0), flags = ARG(1); p_ios_dtor(); if (flags & 1) H.free(ios - HEADER); return ios; }
static uint64_t p_ios_clear(void) { iosClear(ARG(0), (int)ARG(1), ARG(2) & 1); return 0; }
static uint64_t p_ios_setstate(void) { uint64_t ios = ARG(0); iosClear(ios, (int)rd32(ios + IOS_STATE) | (int)ARG(1), ARG(2) & 1); return 0; }
static uint64_t p_ios_widen(void) { return ARG(1) & 255; }
static uint64_t p_ios_narrow(void) { return ARG(1) & 255; }
static uint64_t p_ios_bool(void) { return (rd32(ARG(0) + IOS_STATE) & 6) == 0; }
static uint64_t p_ios_not(void) { return (rd32(ARG(0) + IOS_STATE) & 6) != 0; }
// Manipulators: setw(n) and setprecision(n) return {function, n} by hidden pointer; the inline operator<< calls the
// function with the stream's ios_base.
static uint64_t p_setw_fn(void) { wr64(ARG(0) + IOS_WIDE, ARG(1)); return 0; }
static uint64_t p_setprecision_fn(void) { wr64(ARG(0) + IOS_PREC, ARG(1)); return 0; }
static uint64_t setwFn, setprecisionFn, setiosflagsFn, resetiosflagsFn;
static uint64_t p_setiosflags_fn(void) { wr32(ARG(0) + IOS_FLAGS, rd32(ARG(0) + IOS_FLAGS) | (uint32_t)ARG(1)); return 0; }
static uint64_t p_resetiosflags_fn(void) { wr32(ARG(0) + IOS_FLAGS, rd32(ARG(0) + IOS_FLAGS) & ~(uint32_t)ARG(1)); return 0; }
static uint64_t smanip(uint64_t fn) { wr64(ARG(0), fn); wr64(ARG(0) + 8, ARG(1)); return ARG(0); }
static uint64_t p_setw(void) { return smanip(setwFn); }
static uint64_t p_setprecision(void) { return smanip(setprecisionFn); }
static uint64_t p_setiosflags(void) { return smanip(setiosflagsFn); }
static uint64_t p_resetiosflags(void) { return smanip(resetiosflagsFn); }

// basic_ostream. A stream made as the most derived object (flag set) gets the runtime's virtual base table: the
// basic_ios then sits at +16 (+24 for basic_istream, +32 for basic_iostream).
static uint64_t constructVirtualBase(uint64_t stream, uint64_t vbtable) { wr64(stream, vbtable); uint64_t ios = vbase(stream); memset(G(ios), 0, 96); wr64(ios, iosVtable); return ios; }
static uint64_t p_ostream_ctor(void) {
  uint64_t os = ARG(0), sb = ARG(1); bool isStd = ARG(2) & 1, most = arg(3) & 1;
  if (most) constructVirtualBase(os, ostreamVbtable);
  iosInit(vbase(os), sb, isStd); return os;
}
static uint64_t p_istream_ctor(void) {
  uint64_t is = ARG(0), sb = ARG(1); bool isStd = ARG(2) & 1, most = arg(3) & 1;
  if (most) constructVirtualBase(is, istreamVbtable);
  wr64(is + 8, 0); iosInit(vbase(is), sb, isStd); return is;
}
static uint64_t p_iostream_ctor(void) {  // its basic_istream part initializes the basic_ios; the basic_ostream part only notes it
  uint64_t s = ARG(0), sb = ARG(1); bool most = ARG(2) & 1;
  if (most) { constructVirtualBase(s, iostreamVbtable); wr64(s + 16, iostreamVbtable + 8); }
  wr64(s + 8, 0); iosInit(vbase(s), sb, false); return s;
}
static uint64_t p_nothing(void) { return 0; }
static uint64_t osFlush(uint64_t os);
// The sentry: a good stream first flushes the stream it is tied to.
static bool osPrefix(uint64_t os) {
  uint64_t ios = vbase(os), tie = rd64(ios + IOS_TIE);
  if (good(ios) && tie && tie != os) { osFlush(tie); if (leaving()) return false; }
  return good(ios);
}
static void osSuffix(uint64_t os) {  // _Osfx: unitbuf streams flush after each output (not while an exception is on its way)
  uint64_t ios = vbase(os), sb = rd64(ios + IOS_BUF);
  if (!cur->uncaught && good(ios) && (rd32(ios + IOS_FLAGS) & 2) && sb) {
    bool caught = false; int r = (int)vcall(NEST_CATCH, &caught, sb, 13, 0, 0, 0);
    if (!leaving() && (r == -1 || caught)) iosSetstate(ios, 4);
  }
}
static uint64_t osFlush(uint64_t os) {
  uint64_t ios = vbase(os), sb = rd64(ios + IOS_BUF);
  if (sb && osPrefix(os)) {
    bool caught = false; int r = (int)vcall(NEST_CATCH, &caught, sb, 13, 0, 0, 0);  // pubsync
    if (leaving()) return 0;
    if (r == -1 || caught) iosSetstate(ios, 4);
  }
  return os;
}
static uint64_t p_flush(void) { return osFlush(ARG(0)); }
static uint64_t p_Osfx(void) { osSuffix(ARG(0)); return 0; }
// Writes a field as num_put does: the fill character makes it the stream's width (before it, after it when left
// adjusted, or after the sign/"0x" when internal), the width goes back to 0, and the characters go through sputc.
static uint64_t osField(uint64_t os, const char *text, size_t n, size_t prefix) {
  uint64_t ios = vbase(os); int state = 0;
  if (osPrefix(os)) {
    int64_t width = (int64_t)rd64(ios + IOS_WIDE); uint32_t adjust = rd32(ios + IOS_FLAGS) & 0x1C0; char fill = (char)*G(ios + IOS_FILL);
    size_t pad = width > 0 && (uint64_t)width > n ? (size_t)width - n : 0;
    char *out = malloc(n + pad + 1); size_t o = 0;
    if (adjust == 0x40) { memcpy(out, text, n); o = n; memset(out + o, fill, pad); o += pad; }
    else if (adjust == 0x100) { memcpy(out, text, prefix); o = prefix; memset(out + o, fill, pad); o += pad; memcpy(out + o, text + prefix, n - prefix); o += n - prefix; }
    else { memset(out, fill, pad); o = pad; memcpy(out + o, text, n); o += n; }
    wr64(ios + IOS_WIDE, 0);
    uint64_t sb = rd64(ios + IOS_BUF); bool caught = false;
    for (size_t i = 0; i < o; i++) {
      if (sbSputc(sb, (uint8_t)out[i], NEST_CATCH, &caught) == EOF_ || caught) { state |= 4; break; }
      if (leaving()) { free(out); return 0; }
    }
    free(out);
  }
  osSuffix(os); if (leaving()) return 0;
  iosSetstate(ios, state); return os;
}
static size_t signPrefix(const char *s) { return s[0] == '+' || s[0] == '-' ? 1 : s[0] == '0' && (s[1] == 'x' || s[1] == 'X') ? 2 : 0; }
// Integers as num_put formats them: showpos +, showbase #, oct/hex/dec, uppercase.
static uint64_t osInteger(uint64_t os, uint64_t value, bool isSigned) {
  uint32_t flags = rd32(vbase(os) + IOS_FLAGS), base = flags & 0xE00; char fmt[16], text[80]; int o = 0;
  fmt[o++] = '%'; if (flags & 0x20) fmt[o++] = '+'; if (flags & 0x8) fmt[o++] = '#'; fmt[o++] = 'l'; fmt[o++] = 'l';
  fmt[o++] = base == 0x400 ? 'o' : base == 0x800 ? (flags & 4 ? 'X' : 'x') : isSigned ? 'd' : 'u'; fmt[o] = 0;
  if (isSigned && base != 0x400 && base != 0x800) snprintf(text, sizeof text, fmt, (long long)value); else snprintf(text, sizeof text, fmt, (unsigned long long)value);
  return osField(os, text, strlen(text), signPrefix(text));
}
static uint64_t osFloating(uint64_t os, double v) {
  uint32_t flags = rd32(vbase(os) + IOS_FLAGS), field = flags & 0x3000; int prec = (int)(int64_t)rd64(vbase(os) + IOS_PREC);
  char fmt[16]; int o = 0; fmt[o++] = '%'; if (flags & 0x20) fmt[o++] = '+'; if ((flags & 0x10) && isfinite(v)) fmt[o++] = '#'; fmt[o++] = '.'; fmt[o++] = '*';
  bool up = flags & 4; fmt[o++] = field == 0x2000 ? 'f' : field == 0x3000 ? (up ? 'A' : 'a') : field == 0x1000 ? (up ? 'E' : 'e') : (up ? 'G' : 'g'); fmt[o] = 0;
  if (field == 0x3000) prec = -1;
  int n = snprintf(0, 0, fmt, prec, v); char *text = malloc((size_t)n + 1); snprintf(text, (size_t)n + 1, fmt, prec, v);
  uint64_t r = osField(os, text, (size_t)n, text[0] == '+' || text[0] == '-' ? 1 : 0); free(text); return r;
}
static uint64_t p_os_int(void) { uint32_t base = rd32(vbase(ARG(0)) + IOS_FLAGS) & 0xE00; int v = (int)ARG(1); return base == 0x400 || base == 0x800 ? osInteger(ARG(0), (uint32_t)v, false) : osInteger(ARG(0), (uint64_t)(int64_t)v, true); }
static uint64_t p_os_short(void) { uint32_t base = rd32(vbase(ARG(0)) + IOS_FLAGS) & 0xE00; short v = (short)ARG(1); return base == 0x400 || base == 0x800 ? osInteger(ARG(0), (uint16_t)v, false) : osInteger(ARG(0), (uint64_t)(int64_t)v, true); }
static uint64_t p_os_uint(void) { return osInteger(ARG(0), (uint32_t)ARG(1), false); }
static uint64_t p_os_ushort(void) { return osInteger(ARG(0), (uint16_t)ARG(1), false); }
static uint64_t p_os_int64(void) { return osInteger(ARG(0), ARG(1), true); }
static uint64_t p_os_uint64(void) { return osInteger(ARG(0), ARG(1), false); }
static uint64_t p_os_float(void) { return osFloating(ARG(0), argF(1)); }
static uint64_t p_os_double(void) { return osFloating(ARG(0), argD(1)); }
static uint64_t p_os_bool(void) {
  if (rd32(vbase(ARG(0)) + IOS_FLAGS) & 0x4000) { const char *t = ARG(1) & 1 ? "true" : "false"; return osField(ARG(0), t, strlen(t), 0); }  // boolalpha
  return osInteger(ARG(0), ARG(1) & 1, true);
}
static uint64_t p_os_pointer(void) { char text[24]; snprintf(text, sizeof text, "%016llX", (unsigned long long)ARG(1)); return osField(ARG(0), text, 16, 0); }  // num_put's %p
static uint64_t p_os_manip(void) { GUEST(ARG(1), ARG(0)); return leaving() ? 0 : ARG(0); }          // os << endl
static uint64_t p_os_iosmanip(void) { GUEST(ARG(1), vbase(ARG(0))); return leaving() ? 0 : ARG(0); }  // os << hex (ios_base&)
static uint64_t p_put(void) {
  uint64_t os = ARG(0), ios = vbase(os); int state = 0;
  if (osPrefix(os)) { bool caught = false; if (sbSputc(rd64(ios + IOS_BUF), (int)(ARG(1) & 255), NEST_CATCH, &caught) == EOF_ || caught) state = 4; if (leaving()) return 0; }
  osSuffix(os); if (leaving()) return 0;
  iosSetstate(ios, state); return os;
}
static uint64_t p_os_write(void) {  // write(s, n)
  uint64_t os = ARG(0), ios = vbase(os), s = ARG(1); int64_t n = (int64_t)ARG(2); int state = 0;
  if (osPrefix(os)) { bool caught = false; int64_t w = vcall(NEST_CATCH, &caught, rd64(ios + IOS_BUF), 9, 2, s, (uint64_t)n); if (leaving()) return 0; if (w != n || caught) state = 4; }
  osSuffix(os); if (leaving()) return 0;
  iosSetstate(ios, state); return os;
}

// basic_istream. _Ipfx: a good stream flushes its tie, then skips white space unless told not to (eof sets eof|fail).
static bool isPrefix(uint64_t is, bool noskip) {
  uint64_t ios = vbase(is);
  if (!good(ios)) { iosSetstate(ios, 2); return false; }
  uint64_t tie = rd64(ios + IOS_TIE); if (tie) { osFlush(tie); if (leaving()) return false; }
  if (!noskip && (rd32(ios + IOS_FLAGS) & 1)) {
    uint64_t sb = rd64(ios + IOS_BUF); bool caught = false;
    for (int c = sbSgetc(sb, NEST_CATCH, &caught);; c = sbSnextc(sb, NEST_CATCH, &caught)) {
      if (leaving()) return false;
      if (caught) { iosSetstate(ios, 4); return false; }
      if (c == EOF_) { iosSetstate(ios, 3); return false; }
      if (c >= 128 || !isspace(c)) break;
    }
  }
  return good(ios);
}
static uint64_t p_Ipfx(void) { return isPrefix(ARG(0), ARG(1) & 1); }
// The characters of a number as num_get takes them (sign, base prefix, digits; for floating point a fraction and an
// exponent), from the stream buffer; eof sets eofbit.
static size_t isNumberText(uint64_t is, bool floating, char *out, size_t cap, int *state) {
  uint64_t ios = vbase(is), sb = rd64(ios + IOS_BUF); uint32_t base = rd32(ios + IOS_FLAGS) & 0xE00; bool caught = false;
  size_t n = 0; int c = sbSgetc(sb, NEST_CATCH, &caught);
  #define TAKE() do { if (n + 1 < cap) out[n++] = (char)c; c = sbSnextc(sb, NEST_CATCH, &caught); } while (0)
  if (c == '+' || c == '-') TAKE();
  if (!floating && (base == 0x800 || base == 0) && c == '0') { TAKE(); if (c == 'x' || c == 'X') TAKE(); }
  for (bool dot = false, exp = false; c != EOF_ && !caught && !leaving();) {
    if (isdigit(c) || (!floating && base != 0x200 && base != 0x400 && isxdigit(c) && (base == 0x800 || (n > 1 && (out[1] == 'x' || out[1] == 'X'))))) TAKE();
    else if (floating && c == '.' && !dot && !exp) { dot = true; TAKE(); }
    else if (floating && (c == 'e' || c == 'E') && !exp && n) { exp = true; TAKE(); if (c == '+' || c == '-') TAKE(); }
    else break;
  }
  #undef TAKE
  out[n] = 0;
  if (caught) *state |= 4; else if (c == EOF_) *state |= 1;
  return n;
}
static uint64_t isInteger(int bits, bool isSigned) {
  uint64_t is = ARG(0), dst = ARG(1), ios = vbase(is); int state = 0;
  if (isPrefix(is, false)) {
    char text[80]; isNumberText(is, false, text, sizeof text, &state); if (leaving()) return 0;
    uint32_t base = rd32(ios + IOS_FLAGS) & 0xE00; size_t used; int saved = (int)rd32(cur->teb + TEB_ERRNO); setErrno(0);
    uint64_t v = parseInt(text, &used, base == 0x400 ? 8 : base == 0x800 ? 16 : base == 0x200 ? 10 : 0, isSigned, bits);
    bool range = rd32(cur->teb + TEB_ERRNO) == 34; setErrno(saved);
    if (!used || used != strlen(text) || range) state |= 2;
    else if (bits == 8) *G(dst) = (uint8_t)v; else if (bits == 16) wr16(dst, (uint16_t)v); else if (bits == 32) wr32(dst, (uint32_t)v); else wr64(dst, v);
  }
  iosSetstate(ios, state); return thrown ? 0 : is;
}
static uint64_t isFloating(bool isDouble) {
  uint64_t is = ARG(0), dst = ARG(1), ios = vbase(is); int state = 0;
  if (isPrefix(is, false)) {
    char text[128]; isNumberText(is, true, text, sizeof text, &state); if (leaving()) return 0;
    size_t used; double v = parseDouble(text, &used);
    if (!used || used != strlen(text)) state |= 2;
    else if (isDouble) memcpy(G(dst), &v, 8); else { float x = (float)v; memcpy(G(dst), &x, 4); }
  }
  iosSetstate(ios, state); return thrown ? 0 : is;
}
static uint64_t p_is_uint(void) { return isInteger(32, false); }
static uint64_t p_is_int(void) { return isInteger(32, true); }
static uint64_t p_is_ushort(void) { return isInteger(16, false); }
static uint64_t p_is_short(void) { return isInteger(16, true); }
static uint64_t p_is_int64(void) { return isInteger(64, true); }
static uint64_t p_is_uint64(void) { return isInteger(64, false); }
static uint64_t p_is_float(void) { return isFloating(false); }
static uint64_t p_is_double(void) { return isFloating(true); }
static uint64_t p_is_iosmanip(void) { GUEST(ARG(1), vbase(ARG(0))); return leaving() ? 0 : ARG(0); }
static uint64_t p_is_manip(void) { GUEST(ARG(1), ARG(0)); return leaving() ? 0 : ARG(0); }

// Mutexes and condition variables. Scripts take turns, so a lock is only held across a wait (scriptWait, Sleep): a
// script that finds a lock held by another waits for its next turn and asks again; a dead owner's lock is taken over.
// A mutex here: type (+0), owner thread (+8, 0 free), count (+16).
static uint64_t threadNumber(void) { for (int i = 0; i < threadCount; i++) if (threads[i] == cur) return (uint64_t)i + 1; return 0; }
static uint64_t askAgainLater(void) {  // the import runs again on the script's next turn ("mov eax, id; syscall" is 7 bytes back)
  cur->m->ip -= 7; cur->wakeAt = now_us(); cur->state = CO_WAIT; cur->yield = true; rawReturn = true; return 0;
}
static bool lockFree(uint64_t mtx, uint64_t me) {
  uint64_t owner = rd64(mtx + 8);
  return !owner || owner == me || owner > (uint64_t)threadCount || threads[owner - 1]->state == CO_DEAD;
}
static uint64_t p_Mtx_init_in_situ(void) { wr32(ARG(0), (uint32_t)ARG(1)); wr64(ARG(0) + 8, 0); wr32(ARG(0) + 16, 0); return 0; }
static uint64_t p_Mtx_init(void) { uint64_t m = heapAlloc(80, true); if (!m) return 1; wr32(m, (uint32_t)ARG(1)); wr64(ARG(0), m); return 0; }
static uint64_t p_Mtx_destroy(void) { if (ARG(0)) H.free(ARG(0) - HEADER); return 0; }
static uint64_t p_Mtx_lock(void) {
  uint64_t mtx = ARG(0), me = threadNumber();
  if (!lockFree(mtx, me)) { if (cur->script && !cur->nestDepth) return askAgainLater(); }
  if (rd64(mtx + 8) != me) { wr64(mtx + 8, me); wr32(mtx + 16, 0); }
  wr32(mtx + 16, rd32(mtx + 16) + 1); return 0;  // _Thrd_result::_Success
}
static uint64_t p_Mtx_trylock(void) {
  uint64_t mtx = ARG(0), me = threadNumber();
  if (!lockFree(mtx, me)) return 3;  // _Busy
  if (rd64(mtx + 8) != me) { wr64(mtx + 8, me); wr32(mtx + 16, 0); }
  wr32(mtx + 16, rd32(mtx + 16) + 1); return 0;
}
static uint64_t p_Mtx_unlock(void) { uint64_t mtx = ARG(0); uint32_t n = rd32(mtx + 16); if (n > 1) wr32(mtx + 16, n - 1); else { wr32(mtx + 16, 0); wr64(mtx + 8, 0); } return 0; }
static uint64_t p_Mtx_current_owns(void) { return rd64(ARG(0) + 8) == threadNumber() && rd32(ARG(0) + 16) > 0; }
// A condition wait gives the lock up for one turn and takes it back: waking without a signal is allowed, and the
// mod's own loop checks its condition again. The wait's two halves are told apart by the lock's owner.
static uint64_t p_Cnd_wait(void) {
  uint64_t mtx = ARG(1), me = threadNumber();
  if (!cur->script || cur->nestDepth) return 0;
  if (rd64(mtx + 8) == me) { wr64(mtx + 8, 0); wr32(mtx + 16, 0); cur->wakeAt = now_us() + 1000; cur->state = CO_WAIT; cur->yield = true; cur->m->ip -= 7; rawReturn = true; return 0; }
  if (!lockFree(mtx, me)) return askAgainLater();
  wr64(mtx + 8, me); wr32(mtx + 16, 1); return 0;
}
static uint64_t p_Cnd_init(void) { uint64_t c = heapAlloc(16, true); if (!c) return 1; wr64(ARG(0), c); return 0; }
static uint64_t p_Query_perf_frequency(void) { return 1000000; }
static uint64_t p_Query_perf_counter(void) { return now_us(); }
static uint64_t p_Xtime_get_ticks(void) { return now_us() * 10; }  // 100 ns ticks since 1970
static uint64_t p_Thrd_sleep_for(void) { if (cur->script) { cur->wakeAt = now_us() + (uint64_t)(uint32_t)ARG(0) * 1000; cur->state = CO_WAIT; cur->yield = true; } return 0; }
static uint64_t p_Thrd_yield(void) { if (cur->script) { cur->wakeAt = now_us(); cur->state = CO_WAIT; cur->yield = true; } return 0; }
static uint64_t p_Thrd_id(void) { return k_GetCurrentThreadId(); }
static uint64_t p_hardware_concurrency(void) { return 4; }
static uint64_t p_Random_device(void) { return arc4random(); }
static uint64_t p_uncaught_exception(void) { return cur->uncaught > 0; }
static uint64_t syserrorText;
static uint64_t p_Syserror_map(void) { return syserrorText; }
// The std exceptions the library throws for the mod's containers and strings.
static uint64_t p_Xinvalid_argument(void) { throwStd(X_INVALID_ARGUMENT, ARG(0), "invalid argument", 0, 0); return 0; }
static uint64_t p_Xlength_error(void) { throwStd(X_LENGTH_ERROR, ARG(0), "length error", 0, 0); return 0; }
static uint64_t p_Xout_of_range(void) { throwStd(X_OUT_OF_RANGE, ARG(0), "out of range", 0, 0); return 0; }
static uint64_t p_Xruntime_error(void) { throwStd(X_RUNTIME_ERROR, ARG(0), "runtime error", 0, 0); return 0; }
static uint64_t p_Xbad_alloc(void) { throwStd(X_BAD_ALLOC, 0, "bad allocation", 0, 0); return 0; }
static uint64_t p_Xbad_function_call(void) { throwStd(X_BAD_FUNCTION_CALL, 0, "bad function call", 0, 0); return 0; }
static uint64_t p_Throw_Cpp_error(void) {  // std::system_error for a thread or mutex error (std::errc values)
  static const char *text[] = {"device or resource busy", "invalid argument", "no such process", "not enough memory", "operation not permitted", "resource deadlock would occur", "resource unavailable try again"};
  static const int errc[] = {16, 22, 3, 12, 1, 36, 11};
  int code = (int)ARG(0); if (code < 0 || code > 6) code = 1;
  throwStd(X_SYSTEM_ERROR, 0, text[code], errc[code], genericCategory); return 0;
}
static uint64_t p_Throw_C_error(void) {  // _Thrd_result: 1 nomem, 2 timedout, 3 busy, 4 error
  int code = (int)ARG(0), map = code == 1 ? 3 : code == 3 ? 0 : 1; throwStd(X_SYSTEM_ERROR, 0, map == 3 ? "not enough memory" : map == 0 ? "device or resource busy" : "invalid argument", map == 3 ? 12 : map == 0 ? 16 : 22, genericCategory); return 0;
}
// _Fiopen: the file a basic_filebuf opens, from an ios_base::openmode (in 1, out 2, ate 4, app 8, trunc 0x10,
// binary 0x20, _Nocreate 0x40, _Noreplace 0x80), as Microsoft's table of valid combinations.
static uint64_t fiopen(const char *path, int mode) {
  static const int valid[] = {1, 2, 0x12, 0xA, 0x21, 0x22, 0x32, 0x2A, 3, 0x13, 0xB, 0x23, 0x33, 0x2B, 0};
  static const char *modes[] = {"r", "w", "w", "a", "rb", "wb", "wb", "ab", "r+", "w+", "a+", "r+b", "w+b", "a+b"};
  bool atEnd = mode & 4, noReplace = mode & 0x80;
  if (mode & 0x40) mode |= 1;
  if (mode & 8) mode |= 2;
  mode &= ~(4 | 0x40 | 0x80);
  int i = 0; while (valid[i] && valid[i] != mode) i++;
  if (!valid[i]) return 0;
  if (noReplace && (mode & (2 | 8)) && !access(path, F_OK)) return 0;
  uint64_t f = openStream(path, modes[i]); if (!f) return 0;
  if (atEnd && streamSeek(gfileFor(f), 0, SEEK_END)) { closeStream(gfileFor(f)); return 0; }  // can't be at the end: no file
  return f;
}
static uint64_t p_Fiopen(void) { char p[1100]; pathOf(ARG(0), false, p, sizeof p); return fiopen(p, (int)ARG(1)); }
static uint64_t p_Fiopen_w(void) { char p[1100]; pathOf(ARG(0), true, p, sizeof p); return fiopen(p, (int)ARG(1)); }

// ---- Windows functions such mods also call -------------------------------------------------------
static uint64_t attributesOf(const char *p) { struct stat st; if (stat(p, &st)) { setError(2); return 0xFFFFFFFF; } return S_ISDIR(st.st_mode) ? 0x10 : 0x80; }
static uint64_t k_GetFileAttributesW(void) { char p[1100]; pathOf(ARG(0), true, p, sizeof p); return attributesOf(p); }
static uint64_t fileAttributesEx(const char *p, uint64_t out) {  // WIN32_FILE_ATTRIBUTE_DATA: attributes, 3 FILETIMEs, size high/low
  struct stat st; if (stat(p, &st)) { setError(2); return 0; }
  memset(G(out), 0, 36); wr32(out, S_ISDIR(st.st_mode) ? 0x10 : 0x80);
  uint64_t t = (uint64_t)st.st_mtime * 10000000ull + 116444736000000000ull; wr64(out + 4, t); wr64(out + 12, t); wr64(out + 20, t);
  wr32(out + 28, (uint32_t)((uint64_t)st.st_size >> 32)); wr32(out + 32, (uint32_t)st.st_size); return 1;
}
static uint64_t k_GetFileAttributesExA(void) { char p[1100]; pathOf(ARG(0), false, p, sizeof p); return fileAttributesEx(p, ARG(2)); }
static uint64_t k_GetFileAttributesExW(void) { char p[1100]; pathOf(ARG(0), true, p, sizeof p); return fileAttributesEx(p, ARG(2)); }
static uint64_t k_CreateDirectoryW(void) { char p[1100]; pathOf(ARG(0), true, p, sizeof p); if (!mkdir(p, 0755)) return 1; setError(errno == EEXIST ? 183 : 3); return 0; }
static uint64_t k_CompareFileTime(void) { uint64_t a = rd64(ARG(0)), b = rd64(ARG(1)); return a < b ? (uint64_t)-1 : a > b; }
static uint64_t s_PathIsDirectoryA(void) { char p[1100]; pathOf(ARG(0), false, p, sizeof p); return attributesOf(p) == 0x10 ? 0x10 : 0; }
static uint64_t s_PathFileExistsA(void) { char p[1100]; pathOf(ARG(0), false, p, sizeof p); return access(p, F_OK) == 0; }
static uint64_t s_PathFileExistsW(void) { char p[1100]; pathOf(ARG(0), true, p, sizeof p); return access(p, F_OK) == 0; }
static uint64_t localeInfo(uint32_t type, char *out, size_t cap) {
  const char *v = (type & 0xFFFF) == 0x0E ? "." : (type & 0xFFFF) == 0x0F ? "," : (type & 0xFFFF) == 0x1004 ? "1252" : (type & 0xFFFF) == 0x0B ? "437" : (type & 0xFFFF) == 0x59 ? "en" : (type & 0xFFFF) == 0x5A ? "US" : (type & 0xFFFF) == 0x1001 ? "English" : "";
  snprintf(out, cap, "%s", v); return strlen(v) + 1;
}
static uint64_t k_GetLocaleInfoA(void) { char v[32]; uint64_t n = localeInfo((uint32_t)ARG(1), v, sizeof v); if (!ARG(3)) return n; if (ARG(3) < n) { setError(122); return 0; } memcpy(G(ARG(2)), v, n); return n; }
static uint64_t k_GetLocaleInfoW(void) { char v[32]; uint64_t n = localeInfo((uint32_t)ARG(1), v, sizeof v); if (!ARG(3)) return n; if (ARG(3) < n) { setError(122); return 0; } for (uint64_t i = 0; i < n; i++) wr16(ARG(2) + 2 * i, (uint8_t)v[i]); return n; }
static uint64_t k_GlobalAlloc(void) { return heapAlloc(ARG(1), ARG(0) & 0x40); }
static uint64_t k_GlobalFree(void) { if (ARG(0)) H.free(ARG(0) - HEADER); return 0; }
static uint64_t k_GlobalSize(void) { return ARG(0) ? rd64(ARG(0) - HEADER) : 0; }
static uint64_t k_invalidHandle(void) { return (uint64_t)-1; }
static uint64_t k_minusOne32(void) { return 0xFFFFFFFF; }
static uint64_t u_GetCursorPos(void) { if (ARG(0)) { wr32(ARG(0), 0); wr32(ARG(0) + 4, 0); } return 1; }
static uint64_t u_GetClientRect(void) { if (ARG(1)) { wr32(ARG(1), 0); wr32(ARG(1) + 4, 0); wr32(ARG(1) + 8, 1920); wr32(ARG(1) + 12, 1080); } return 1; }
static uint64_t u_GetKeyboardLayout(void) { return 0x04090409; }
static uint64_t d_D3DCompile(void) { if (ARG(9)) wr64(ARG(9), 0); if (arg(10)) wr64(arg(10), 0); return 0x80004005; }  // E_FAIL: no shader compiler here

// ---- Start-up of the runtime --------------------------------------------------------------------
// Data the C++ library exports (locale::id objects, the id counter) gets a cell of guest memory per name.
static struct { char name[200]; uint64_t cell; } dataCells[32]; static int dataCellCount;
static uint64_t dataImport(const char *name) {
  bool isData = !strcmp(name, "?_Id_cnt@id@locale@std@@0HA") || (!strncmp(name, "?id@", 4) && strstr(name, "@2V0locale@2@A"));
  if (!isData || strlen(name) >= sizeof dataCells[0].name) return 0;
  for (int i = 0; i < dataCellCount; i++) if (!strcmp(dataCells[i].name, name)) return dataCells[i].cell;
  if (dataCellCount >= 32) return 0;
  uint64_t cell = galloc(16); if (!cell) return 0;
  snprintf(dataCells[dataCellCount].name, sizeof dataCells[0].name, "%s", name); dataCells[dataCellCount++].cell = cell;
  return cell;
}
static uint64_t vtableOf(const char *names[], const Fn fns[], int n) {
  uint64_t vt = galloc(8 * (uint64_t)n); if (!vt) return 0;
  for (int i = 0; i < n; i++) wr64(vt + 8 * (uint64_t)i, hostStub(names[i], fns[i]));
  return vt;
}
static uint64_t codecvtMaxLength(void) { return 1; }
static uint64_t codecvtLength(void) { uint64_t n = ARG(3) - ARG(2), max = arg(4); return n < max ? n : max; }
static bool runtimeInit(void) {
  static bool ready; if (ready) return true;
  startUs = now_us();
  nestStub = returnStub("<return from a call by the runtime>", r_nestReturn);
  catchStub = returnStub("<end of a catch block>", r_catchReturn);
  if (!nestStub || !catchStub || !runtimeTypesInit()) return false;
  // The "C" locale's lconv (ten char pointers, eight chars, ten wchar_t pointers) and names.
  lconvCell = galloc(168); uint64_t dot = galloc(4), empty = galloc(4); memcpy(G(dot), ".", 2); uint64_t wdot = galloc(4); wr16(wdot, '.');
  for (int i = 0; i < 10; i++) { wr64(lconvCell + 8 * (uint64_t)i, i ? empty : dot); wr64(lconvCell + 88 + 8 * (uint64_t)i, i ? empty : wdot); }
  memset(G(lconvCell + 80), 127, 8);  // CHAR_MAX: not available
  cName = galloc(4); memcpy(G(cName), "C", 2); cNameW = galloc(4); wr16(cNameW, 'C');
  argcCell = galloc(8); wr32(argcCell, 1); argvCell = galloc(32); wr64(argvCell, argvCell + 16); wr64(argvCell + 16, cmdA);
  syserrorText = galloc(16); memcpy(G(syserrorText), "unknown error", 14);
  for (int i = 0; i < 3; i++) { GFile *f = newFile(-1, i + 1, false, i == 0, i != 0); stdFiles[i] = f ? f->guest : 0; }
  // The C++ library's objects: the global locale implementation and facet vtables, stream vtables, manipulators.
  static const char *facetNames[] = {"<facet destructor>", "<facet::_Incref>", "<facet::_Decref>",
    "<ctype<char>::do_tolower range>", "<ctype<char>::do_tolower>", "<ctype<char>::do_toupper range>", "<ctype<char>::do_toupper>",
    "<ctype<char>::do_widen range>", "<ctype<char>::do_widen>", "<ctype<char>::do_narrow range>", "<ctype<char>::do_narrow>"};
  static const Fn facetFns[] = {p_this, facetIncref, facetDecref, ctLowerRange, ctLowerChar, ctUpperRange, ctUpperChar, ctWidenRange, ctWidenChar, ctNarrowRange, ctNarrowChar};
  ctypeVtable = vtableOf(facetNames, facetFns, 11);
  static const char *codecvtNames[] = {"<facet destructor>", "<facet::_Incref>", "<facet::_Decref>", "<codecvt::do_always_noconv>", "<codecvt::do_max_length>",
    "<codecvt::do_encoding>", "<codecvt::do_in>", "<codecvt::do_out>", "<codecvt::do_unshift>", "<codecvt::do_length>"};
  static const Fn codecvtFns[] = {p_this, facetIncref, facetDecref, p_always_noconv, codecvtMaxLength, codecvtMaxLength, p_codecvt_inout, p_codecvt_inout, p_codecvt_unshift, codecvtLength};
  codecvtVtable = vtableOf(codecvtNames, codecvtFns, 10);
  globalLocimp = galloc(56); if (!globalLocimp || !ctypeVtable || !codecvtVtable) return false;
  wr64(globalLocimp, ctypeVtable); wr32(globalLocimp + 8, 1u << 30);  // its vtable: destructor, _Incref, _Decref (a facet's first three)
  wr32(globalLocimp + 32, 0x3F); wr64(globalLocimp + 40, cName);  // no facets, not transparent
  ctypeTable = galloc(512);
  for (int c = 0; c < 256; c++) {  // Microsoft's "C" classification bits
    int m = 0; if (c < 128) { if (iscntrl(c)) m |= 0x20; if (isspace(c)) m |= 0x8; if (c == ' ' || c == '\t') m |= 0x40; if (ispunct(c)) m |= 0x10;
      if (isdigit(c)) m |= 0x4; if (isxdigit(c)) m |= 0x80; if (isupper(c)) m |= 0x101; if (islower(c)) m |= 0x102; }
    wr16(ctypeTable + 2 * (uint64_t)c, (uint16_t)m);
  }
  static const char *sbNames[] = {"<basic_streambuf::scalar deleting destructor>", "<basic_streambuf::_Lock>", "<basic_streambuf::_Unlock>", "<basic_streambuf::overflow>",
    "<basic_streambuf::pbackfail>", "<basic_streambuf::showmanyc>", "<basic_streambuf::underflow>", "<basic_streambuf::uflow>", "<basic_streambuf::xsgetn>",
    "<basic_streambuf::xsputn>", "<basic_streambuf::seekoff>", "<basic_streambuf::seekpos>", "<basic_streambuf::setbuf>", "<basic_streambuf::sync>", "<basic_streambuf::imbue>"};
  static const Fn sbFns[] = {p_sb_delete, p_nothing, p_nothing, p_eof, p_eof, c_zero, p_eof, p_sb_uflow, p_sb_xsgetn, p_sb_xsputn, p_seekfail, p_seekfail, p_this, c_zero, p_nothing};
  streambufVtable = vtableOf(sbNames, sbFns, 15);
  static const char *iosNames[] = {"<basic_ios::scalar deleting destructor>"}; static const Fn iosFns[] = {p_ios_delete};
  iosVtable = vtableOf(iosNames, iosFns, 1);
  ostreamVbtable = galloc(8); wr32(ostreamVbtable + 4, 16);
  istreamVbtable = galloc(8); wr32(istreamVbtable + 4, 24);
  iostreamVbtable = galloc(16); wr32(iostreamVbtable + 4, 32); wr32(iostreamVbtable + 12, 16);
  setwFn = hostStub("<setw's function>", p_setw_fn); setprecisionFn = hostStub("<setprecision's function>", p_setprecision_fn);
  setiosflagsFn = hostStub("<setiosflags's function>", p_setiosflags_fn); resetiosflagsFn = hostStub("<resetiosflags's function>", p_resetiosflags_fn);
  ready = streambufVtable && iosVtable && setwFn;
  return ready;
}

// ---- Import tables ------------------------------------------------------------------------------
// By plain name (any DLL): the Universal CRT, VCRUNTIME140, the C parts of MSVCP140, and Windows functions.
static const Import crtImports[] = {
  // heap
  {"malloc", c_malloc}, {"free", c_free}, {"calloc", c_calloc}, {"realloc", c_realloc}, {"_recalloc", c_recalloc}, {"_msize", c_msize},
  {"_aligned_malloc", c_aligned_malloc}, {"_aligned_free", c_aligned_free}, {"_aligned_realloc", c_aligned_realloc}, {"_callnewh", c_callnewh},
  {"_set_new_mode", c_zero}, {"_query_new_mode", c_zero},
  // runtime
  {"_initterm", c_initterm}, {"_initterm_e", c_initterm_e}, {"_initialize_onexit_table", c_initialize_onexit_table},
  {"_register_onexit_function", c_register_onexit_function}, {"_execute_onexit_table", c_execute_onexit_table}, {"_crt_atexit", c_crt_atexit},
  {"_crt_at_quick_exit", c_zero}, {"_configure_narrow_argv", c_zero}, {"_configure_wide_argv", c_zero}, {"_initialize_narrow_environment", c_zero},
  {"_initialize_wide_environment", c_zero}, {"__p___argc", c_p_argc}, {"__p___argv", c_p_argv}, {"_seh_filter_dll", c_zero}, {"_seh_filter_exe", c_zero},
  {"_cexit", c_zero}, {"_c_exit", c_zero}, {"exit", c_exit}, {"_exit", c_exit}, {"quick_exit", c_exit}, {"abort", c_abort}, {"terminate", c_terminate},
  {"_invoke_watson", c_invoke_watson}, {"_invalid_parameter_noinfo", c_invoke_watson}, {"_invalid_parameter_noinfo_noreturn", c_invoke_watson},
  {"_errno", c_errno}, {"__doserrno", c_doserrno}, {"_set_errno", c_set_errno}, {"_get_errno", c_get_errno}, {"_set_app_type", c_zero},
  {"__setusermatherr", c_zero}, {"_configthreadlocale", c_configthreadlocale}, {"_set_fmode", c_zero}, {"_set_invalid_parameter_handler", c_zero},
  {"_set_thread_local_invalid_parameter_handler", c_zero}, {"_beginthreadex", k_CreateThread}, {"_endthreadex", c_endthread}, {"signal", c_zero},
  {"_register_thread_local_exe_atexit_callback", c_zero},
  // strings
  {"memcpy", c_memcpy}, {"memmove", c_memcpy}, {"memset", c_memset}, {"memcmp", c_memcmp}, {"memchr", c_memchr}, {"memcpy_s", c_memcpy_s}, {"memmove_s", c_memcpy_s},
  {"strlen", c_strlen}, {"strnlen", c_strnlen}, {"strcmp", c_strcmp}, {"strncmp", c_strncmp}, {"_stricmp", c_stricmp}, {"_strcmpi", c_stricmp},
  {"_strnicmp", c_strnicmp}, {"strcpy", c_strcpy}, {"strncpy", c_strncpy}, {"strcat", c_strcat}, {"strncat", c_strncat}, {"strchr", c_strchr},
  {"strrchr", c_strrchr}, {"strstr", c_strstr}, {"strpbrk", c_strpbrk}, {"strspn", c_strspn}, {"strcspn", c_strcspn}, {"_strdup", c_strdup},
  {"_strlwr", c_strlwr}, {"_strupr", c_strupr}, {"_strlwr_s", c_strlwr_s}, {"_strupr_s", c_strupr_s}, {"strcpy_s", c_strcpy_s}, {"strcat_s", c_strcat_s},
  {"strncpy_s", c_strncpy_s}, {"strtok", c_strtok}, {"strtok_s", c_strtok_s}, {"tolower", c_tolower}, {"toupper", c_toupper}, {"_tolower", c_tolower},
  {"_toupper", c_toupper}, {"isalnum", c_isalnum}, {"isalpha", c_isalpha}, {"isdigit", c_isdigit}, {"isxdigit", c_isxdigit}, {"isspace", c_isspace},
  {"isupper", c_isupper}, {"islower", c_islower}, {"isprint", c_isprint}, {"ispunct", c_ispunct}, {"iscntrl", c_iscntrl}, {"isgraph", c_isgraph},
  {"isblank", c_isblank}, {"__isascii", c_isascii}, {"_mbsicmp", c_mbsicmp},
  {"wcslen", c_wcslen}, {"wcscmp", c_wcscmp}, {"wcsncmp", c_wcsncmp}, {"_wcsicmp", c_wcsicmp}, {"_wcsnicmp", c_wcsnicmp}, {"wcscpy", c_wcscpy},
  {"wcscat", c_wcscat}, {"wcsncpy", c_wcsncpy}, {"wcscpy_s", c_wcscpy_s}, {"wcscat_s", c_wcscat_s}, {"wcschr", c_wcschr}, {"wcsrchr", c_wcsrchr},
  {"wcsstr", c_wcsstr}, {"_wcsdup", c_wcsdup}, {"towlower", c_towlower}, {"towupper", c_towupper}, {"iswspace", c_iswspace}, {"iswalpha", c_iswalpha},
  {"iswdigit", c_iswdigit}, {"iswalnum", c_iswalnum}, {"mbstowcs", c_mbstowcs}, {"wcstombs", c_wcstombs}, {"mbstowcs_s", c_mbstowcs_s}, {"wcstombs_s", c_wcstombs_s},
  // number conversions
  {"strtol", c_strtol}, {"strtoul", c_strtoul}, {"strtoll", c_strtoll}, {"strtoull", c_strtoull}, {"_strtoi64", c_strtoll}, {"_strtoui64", c_strtoull},
  {"strtod", c_strtod}, {"strtof", c_strtof}, {"atof", c_atof}, {"atoi", c_atoi}, {"atol", c_atoi}, {"atoll", c_atoll}, {"_atoi64", c_atoll},
  {"wcstol", c_wcstol}, {"wcstoul", c_wcstoul}, {"wcstoll", c_wcstoll}, {"wcstoull", c_wcstoull}, {"_wcstoi64", c_wcstoll}, {"_wcstoui64", c_wcstoull},
  {"wcstod", c_wcstod}, {"_wtoi", c_wtoi}, {"_wtol", c_wtoi}, {"_wtof", c_wtof}, {"_itoa", c_itoa}, {"_ltoa", c_itoa}, {"_ultoa", c_ultoa},
  {"_i64toa", c_i64toa}, {"_ui64toa", c_ui64toa}, {"_itoa_s", c_itoa_s}, {"_ltoa_s", c_itoa_s}, {"_i64toa_s", c_i64toa_s}, {"_ui64toa_s", c_ui64toa_s},
  // math
  {"sin", m_sin}, {"cos", m_cos}, {"tan", m_tan}, {"asin", m_asin}, {"acos", m_acos}, {"atan", m_atan}, {"sinh", m_sinh}, {"cosh", m_cosh}, {"tanh", m_tanh},
  {"exp", m_exp}, {"exp2", m_exp2}, {"log", m_log}, {"log10", m_log10}, {"log2", m_log2}, {"log1p", m_log1p}, {"expm1", m_expm1}, {"sqrt", m_sqrt},
  {"cbrt", m_cbrt}, {"ceil", m_ceil}, {"floor", m_floor}, {"fabs", m_fabs}, {"round", m_round}, {"trunc", m_trunc}, {"rint", m_rint}, {"nearbyint", m_nearbyint},
  {"erf", m_erf}, {"erfc", m_erfc}, {"tgamma", m_tgamma}, {"lgamma", m_lgamma}, {"asinh", m_asinh}, {"acosh", m_acosh}, {"atanh", m_atanh},
  {"sinf", m_sinf}, {"cosf", m_cosf}, {"tanf", m_tanf}, {"asinf", m_asinf}, {"acosf", m_acosf}, {"atanf", m_atanf}, {"sinhf", m_sinhf}, {"coshf", m_coshf},
  {"tanhf", m_tanhf}, {"expf", m_expf}, {"logf", m_logf}, {"log10f", m_log10f}, {"log2f", m_log2f}, {"sqrtf", m_sqrtf}, {"cbrtf", m_cbrtf}, {"ceilf", m_ceilf},
  {"floorf", m_floorf}, {"fabsf", m_fabsf}, {"roundf", m_roundf}, {"truncf", m_truncf}, {"exp2f", m_exp2f}, {"rintf", m_rintf},
  {"atan2", m_atan2}, {"pow", m_pow}, {"fmod", m_fmod}, {"hypot", m_hypot}, {"_hypot", m_hypot}, {"fmin", m_fmin}, {"fmax", m_fmax}, {"copysign", m_copysign},
  {"_copysign", m_copysign}, {"remainder", m_remainder}, {"fdim", m_fdim}, {"nextafter", m_nextafter}, {"_nextafter", m_nextafter},
  {"atan2f", m_atan2f}, {"powf", m_powf}, {"fmodf", m_fmodf}, {"hypotf", m_hypotf}, {"_hypotf", m_hypotf}, {"fminf", m_fminf}, {"fmaxf", m_fmaxf},
  {"copysignf", m_copysignf}, {"_copysignf", m_copysignf}, {"remainderf", m_remainderf}, {"ldexp", m_ldexp}, {"ldexpf", m_ldexpf}, {"frexp", m_frexp},
  {"modf", m_modf}, {"modff", m_modff}, {"lround", m_lround}, {"lroundf", m_lroundf}, {"llround", m_llround}, {"lrint", m_lrint}, {"abs", m_abs},
  {"labs", m_abs}, {"llabs", m_llabs}, {"_abs64", m_llabs}, {"_dclass", m_dclass}, {"_fdclass", m_fdclass}, {"_dsign", m_dsign}, {"_fdsign", m_fdsign},
  {"_dtest", m_dtest}, {"_fdtest", m_fdtest}, {"_isnan", m_isnan}, {"_finite", m_finite},
  // time
  {"_time64", c_time64}, {"_time32", c_time32}, {"_localtime64_s", c_localtime64_s}, {"_gmtime64_s", c_gmtime64_s}, {"_localtime32_s", c_localtime32_s},
  {"_localtime64", c_localtime64}, {"_gmtime64", c_gmtime64}, {"_localtime32", c_localtime32}, {"_mktime64", c_mktime64}, {"_difftime64", c_difftime64},
  {"clock", c_clock}, {"strftime", c_strftime}, {"_timespec64_get", c_timespec64_get},
  // locale
  {"localeconv", c_localeconv}, {"setlocale", c_setlocale}, {"_wsetlocale", c_wsetlocale}, {"___lc_codepage_func", c_lc_codepage},
  {"___mb_cur_max_func", c_mb_cur_max}, {"_create_locale", c_setlocale}, {"_free_locale", c_zero}, {"_get_current_locale", c_setlocale},
  // utility
  {"rand", c_rand}, {"srand", c_srand}, {"rand_s", c_rand_s}, {"qsort", c_qsort}, {"qsort_s", c_qsort_s}, {"bsearch", c_bsearch},
  // files and folders
  {"_stat64i32", c_stat64i32}, {"_wstat64i32", c_wstat64i32}, {"_stat64", c_stat64}, {"_wstat64", c_wstat64}, {"_stat32", c_stat32}, {"_access", c_access},
  {"_waccess", c_waccess}, {"_mkdir", c_mkdir}, {"_wmkdir", c_wmkdir}, {"_rmdir", c_rmdir}, {"remove", c_remove}, {"_unlink", c_remove}, {"_wremove", c_wremove},
  {"_wunlink", c_wremove}, {"rename", c_rename}, {"_wrename", c_wrename}, {"_getcwd", c_getcwd}, {"_fullpath", c_fullpath}, {"_findfirst64i32", c_findfirst64i32},
  {"_findnext64i32", c_findnext64i32}, {"_findclose", c_findclose}, {"_lock_file", c_zero}, {"_unlock_file", c_zero},
  // stdio
  {"fopen", c_fopen}, {"_fsopen", c_fsopen}, {"_wfopen", c_wfopen}, {"_wfsopen", c_wfopen}, {"fopen_s", c_fopen_s}, {"_wfopen_s", c_wfopen_s}, {"fclose", c_fclose},
  {"_fclose_nolock", c_fclose}, {"fflush", c_fflush}, {"_fflush_nolock", c_fflush}, {"fread", c_fread}, {"_fread_nolock", c_fread}, {"fwrite", c_fwrite},
  {"_fwrite_nolock", c_fwrite}, {"fgetc", c_fgetc}, {"getc", c_fgetc}, {"_fgetc_nolock", c_fgetc}, {"_getc_nolock", c_fgetc}, {"fputc", c_fputc}, {"putc", c_fputc},
  {"_fputc_nolock", c_fputc}, {"_putc_nolock", c_fputc}, {"putchar", c_putchar}, {"fputs", c_fputs}, {"puts", c_puts}, {"fgets", c_fgets}, {"ungetc", c_ungetc},
  {"_ungetc_nolock", c_ungetc}, {"fseek", c_fseek}, {"_fseek_nolock", c_fseek}, {"_fseeki64", c_fseeki64}, {"_fseeki64_nolock", c_fseeki64}, {"ftell", c_ftell},
  {"_ftell_nolock", c_ftell}, {"_ftelli64", c_ftelli64}, {"_ftelli64_nolock", c_ftelli64}, {"fgetpos", c_fgetpos}, {"fsetpos", c_fsetpos}, {"rewind", c_rewind},
  {"feof", c_feof}, {"ferror", c_ferror}, {"clearerr", c_clearerr}, {"setvbuf", c_setvbuf}, {"_fileno", c_fileno}, {"__acrt_iob_func", c_iob},
  {"_get_stream_buffer_pointers", c_get_stream_buffer_pointers}, {"__stdio_common_vsprintf", c_vsprintf}, {"__stdio_common_vsprintf_s", c_vsprintf_s},
  {"__stdio_common_vsnprintf_s", c_vsnprintf_s}, {"__stdio_common_vfprintf", c_vfprintf}, {"__stdio_common_vfprintf_s", c_vfprintf},
  {"__stdio_common_vsscanf", c_vsscanf}, {"__stdio_common_vswprintf", c_vswprintf}, {"__stdio_common_vswprintf_s", c_vswprintf_s},
  // VCRUNTIME140: exceptions, RTTI
  {"_CxxThrowException", x_CxxThrowException}, {"__CxxFrameHandler4", x_frameHandler}, {"__CxxFrameHandler3", x_frameHandler},
  {"__C_specific_handler", x_frameHandler}, {"__current_exception", x_current_exception}, {"__current_exception_context", x_current_exception_context},
  {"__uncaught_exceptions", x_uncaught_exceptions}, {"__std_exception_copy", x_std_exception_copy}, {"__std_exception_destroy", x_std_exception_destroy},
  {"__std_type_info_destroy_list", c_zero}, {"__std_type_info_compare", x_type_info_compare}, {"__std_type_info_hash", x_type_info_hash},
  {"__std_type_info_name", x_type_info_name}, {"__std_terminate", x_std_terminate}, {"_purecall", c_purecall}, {"__RTDynamicCast", x_RTDynamicCast},
  {"__RTtypeid", x_RTtypeid}, {"__RTCastToVoid", x_RTCastToVoid},
  // MSVCP140's C functions: mutexes, condition variables, time, threads
  {"_Mtx_init_in_situ", p_Mtx_init_in_situ}, {"_Mtx_destroy_in_situ", c_zero}, {"_Mtx_init", p_Mtx_init}, {"_Mtx_destroy", p_Mtx_destroy},
  {"_Mtx_lock", p_Mtx_lock}, {"_Mtx_trylock", p_Mtx_trylock}, {"_Mtx_timedlock", p_Mtx_lock}, {"_Mtx_unlock", p_Mtx_unlock},
  {"_Mtx_current_owns", p_Mtx_current_owns}, {"_Cnd_init_in_situ", c_zero}, {"_Cnd_destroy_in_situ", c_zero}, {"_Cnd_init", p_Cnd_init},
  {"_Cnd_destroy", p_Mtx_destroy}, {"_Cnd_wait", p_Cnd_wait}, {"_Cnd_timedwait", p_Cnd_wait}, {"_Cnd_signal", c_zero}, {"_Cnd_broadcast", c_zero},
  {"_Cnd_do_broadcast_at_thread_exit", c_zero}, {"_Query_perf_frequency", p_Query_perf_frequency}, {"_Query_perf_counter", p_Query_perf_counter},
  {"_Xtime_get_ticks", p_Xtime_get_ticks}, {"_Thrd_sleep_for", p_Thrd_sleep_for}, {"_Thrd_yield", p_Thrd_yield}, {"_Thrd_id", p_Thrd_id},
  {"_Thrd_hardware_concurrency", p_hardware_concurrency},
  // Windows functions
  {"GetFileAttributesW", k_GetFileAttributesW}, {"GetFileAttributesExA", k_GetFileAttributesExA}, {"GetFileAttributesExW", k_GetFileAttributesExW},
  {"SetFileAttributesW", k_one}, {"SetFileAttributesA", k_one}, {"CreateDirectoryW", k_CreateDirectoryW}, {"CompareFileTime", k_CompareFileTime},
  {"GetLocaleInfoA", k_GetLocaleInfoA}, {"GetLocaleInfoW", k_GetLocaleInfoW}, {"GlobalAlloc", k_GlobalAlloc}, {"GlobalFree", k_GlobalFree},
  {"GlobalLock", p_this}, {"GlobalUnlock", k_one}, {"GlobalSize", k_GlobalSize}, {"CreateToolhelp32Snapshot", k_invalidHandle},
  {"SuspendThread", k_minusOne32}, {"ResumeThread", k_minusOne32}, {"FlushInstructionCache", k_one}, {"PathIsDirectoryA", s_PathIsDirectoryA},
  {"PathFileExistsA", s_PathFileExistsA}, {"PathFileExistsW", s_PathFileExistsW}, {"GetCursorPos", u_GetCursorPos}, {"GetClientRect", u_GetClientRect},
  {"GetKeyboardLayout", u_GetKeyboardLayout}, {"IsWindowUnicode", k_one}, {"D3DCompile", d_D3DCompile},
};
// MSVCP140's C++ functions by their full decorated names (their plain names collide).
#define OSTREAM "?$basic_ostream@DU?$char_traits@D@std@@@std@@"
#define ISTREAM "?$basic_istream@DU?$char_traits@D@std@@@std@@"
#define IOSTREAM "?$basic_iostream@DU?$char_traits@D@std@@@std@@"
#define STREAMBUF "?$basic_streambuf@DU?$char_traits@D@std@@@std@@"
#define BASIC_IOS "?$basic_ios@DU?$char_traits@D@std@@@std@@"
#define STREAMBUF_PARAM "?$basic_streambuf@DU?$char_traits@D@std@@@1@"  // as a parameter: "std" is back-reference 1
#define CODECVT "?$codecvt@DDU_Mbstatet@@@std@@"
static const Import cppImports[] = {
  {"??0" OSTREAM "QEAA@PEAV" STREAMBUF_PARAM "_N@Z", p_ostream_ctor}, {"??1" OSTREAM "UEAA@XZ", p_nothing},
  {"??6" OSTREAM "QEAAAEAV01@H@Z", p_os_int}, {"??6" OSTREAM "QEAAAEAV01@J@Z", p_os_int}, {"??6" OSTREAM "QEAAAEAV01@F@Z", p_os_short},
  {"??6" OSTREAM "QEAAAEAV01@I@Z", p_os_uint}, {"??6" OSTREAM "QEAAAEAV01@K@Z", p_os_uint}, {"??6" OSTREAM "QEAAAEAV01@G@Z", p_os_ushort},
  {"??6" OSTREAM "QEAAAEAV01@_J@Z", p_os_int64}, {"??6" OSTREAM "QEAAAEAV01@_K@Z", p_os_uint64}, {"??6" OSTREAM "QEAAAEAV01@M@Z", p_os_float},
  {"??6" OSTREAM "QEAAAEAV01@N@Z", p_os_double}, {"??6" OSTREAM "QEAAAEAV01@O@Z", p_os_double}, {"??6" OSTREAM "QEAAAEAV01@_N@Z", p_os_bool},
  {"??6" OSTREAM "QEAAAEAV01@PEBX@Z", p_os_pointer}, {"??6" OSTREAM "QEAAAEAV01@P6AAEAV01@AEAV01@@Z@Z", p_os_manip},
  {"??6" OSTREAM "QEAAAEAV01@P6AAEAVios_base@1@AEAV21@@Z@Z", p_os_iosmanip}, {"??6" OSTREAM "QEAAAEAV01@P6AAEAV?$basic_ios@DU?$char_traits@D@std@@@1@AEAV21@@Z@Z", p_os_iosmanip},
  {"?put@" OSTREAM "QEAAAEAV12@D@Z", p_put}, {"?write@" OSTREAM "QEAAAEAV12@PEBD_J@Z", p_os_write}, {"?flush@" OSTREAM "QEAAAEAV12@XZ", p_flush},
  {"?_Osfx@" OSTREAM "QEAAXXZ", p_Osfx},
  {"??0" ISTREAM "QEAA@PEAV" STREAMBUF_PARAM "_N@Z", p_istream_ctor}, {"??1" ISTREAM "UEAA@XZ", p_nothing}, {"?_Ipfx@" ISTREAM "QEAA_N_N@Z", p_Ipfx},
  {"??5" ISTREAM "QEAAAEAV01@AEAI@Z", p_is_uint}, {"??5" ISTREAM "QEAAAEAV01@AEAK@Z", p_is_uint}, {"??5" ISTREAM "QEAAAEAV01@AEAH@Z", p_is_int},
  {"??5" ISTREAM "QEAAAEAV01@AEAJ@Z", p_is_int}, {"??5" ISTREAM "QEAAAEAV01@AEAF@Z", p_is_short}, {"??5" ISTREAM "QEAAAEAV01@AEAG@Z", p_is_ushort},
  {"??5" ISTREAM "QEAAAEAV01@AEA_J@Z", p_is_int64}, {"??5" ISTREAM "QEAAAEAV01@AEA_K@Z", p_is_uint64}, {"??5" ISTREAM "QEAAAEAV01@AEAM@Z", p_is_float},
  {"??5" ISTREAM "QEAAAEAV01@AEAN@Z", p_is_double}, {"??5" ISTREAM "QEAAAEAV01@AEAO@Z", p_is_double},
  {"??5" ISTREAM "QEAAAEAV01@P6AAEAVios_base@1@AEAV21@@Z@Z", p_is_iosmanip}, {"??5" ISTREAM "QEAAAEAV01@P6AAEAV01@AEAV01@@Z@Z", p_is_manip},
  {"??0" IOSTREAM "QEAA@PEAV" STREAMBUF_PARAM "@Z", p_iostream_ctor}, {"??1" IOSTREAM "UEAA@XZ", p_nothing},
  {"??0" BASIC_IOS "IEAA@XZ", p_ios_ctor}, {"??1" BASIC_IOS "UEAA@XZ", p_ios_dtor}, {"?clear@" BASIC_IOS "QEAAXH_N@Z", p_ios_clear},
  {"?setstate@" BASIC_IOS "QEAAXH_N@Z", p_ios_setstate}, {"?widen@" BASIC_IOS "QEBADD@Z", p_ios_widen}, {"?narrow@" BASIC_IOS "QEBADDD@Z", p_ios_narrow},
  {"??Bios_base@std@@QEBA_NXZ", p_ios_bool}, {"??7ios_base@std@@QEBA_NXZ", p_ios_not}, {"?getloc@ios_base@std@@QEBA?AVlocale@2@XZ", p_ios_getloc},
  {"??0" STREAMBUF "IEAA@XZ", p_sb_ctor}, {"??1" STREAMBUF "UEAA@XZ", p_sb_dtor}, {"?_Lock@" STREAMBUF "UEAAXXZ", p_nothing},
  {"?_Unlock@" STREAMBUF "UEAAXXZ", p_nothing}, {"?showmanyc@" STREAMBUF "MEAA_JXZ", c_zero}, {"?uflow@" STREAMBUF "MEAAHXZ", p_sb_uflow},
  {"?underflow@" STREAMBUF "MEAAHXZ", p_eof}, {"?overflow@" STREAMBUF "MEAAHH@Z", p_eof}, {"?pbackfail@" STREAMBUF "MEAAHH@Z", p_eof},
  {"?xsgetn@" STREAMBUF "MEAA_JPEAD_J@Z", p_sb_xsgetn}, {"?xsputn@" STREAMBUF "MEAA_JPEBD_J@Z", p_sb_xsputn},
  {"?setbuf@" STREAMBUF "MEAAPEAV12@PEAD_J@Z", p_this}, {"?sync@" STREAMBUF "MEAAHXZ", c_zero}, {"?imbue@" STREAMBUF "MEAAXAEBVlocale@2@@Z", p_nothing},
  {"?_Init@" STREAMBUF "IEAAXXZ", p_sb_Init}, {"?_Init@" STREAMBUF "IEAAXPEAPEAD0PEAH001@Z", p_sb_Init6},
  {"?sgetc@" STREAMBUF "QEAAHXZ", p_sgetc}, {"?snextc@" STREAMBUF "QEAAHXZ", p_snextc}, {"?sbumpc@" STREAMBUF "QEAAHXZ", p_sbumpc},
  {"?sputc@" STREAMBUF "QEAAHD@Z", p_sputc}, {"?sputn@" STREAMBUF "QEAA_JPEBD_J@Z", p_sputn},
  {"?getloc@" STREAMBUF "QEBA?AVlocale@2@XZ", p_sb_getloc},
  {"?setw@std@@YA?AU?$_Smanip@_J@1@_J@Z", p_setw}, {"?setprecision@std@@YA?AU?$_Smanip@_J@1@_J@Z", p_setprecision},
  {"?setiosflags@std@@YA?AU?$_Smanip@H@1@H@Z", p_setiosflags}, {"?resetiosflags@std@@YA?AU?$_Smanip@H@1@H@Z", p_resetiosflags},
  {"??0_Lockit@std@@QEAA@H@Z", p_Lockit}, {"??1_Lockit@std@@QEAA@XZ", p_nothing}, {"?_Getgloballocale@locale@std@@CAPEAV_Locimp@12@XZ", p_Getgloballocale},
  {"?_Getcat@?$ctype@D@std@@SA_KPEAPEBVfacet@locale@2@PEBV42@@Z", p_ctype_Getcat}, {"?_Getcat@" CODECVT "SA_KPEAPEBVfacet@locale@2@PEBV42@@Z", p_codecvt_Getcat},
  {"?always_noconv@codecvt_base@std@@QEBA_NXZ", p_always_noconv}, {"?in@" CODECVT "QEBAHAEAU_Mbstatet@@PEBD1AEAPEBDPEAD3AEAPEAD@Z", p_codecvt_inout},
  {"?out@" CODECVT "QEBAHAEAU_Mbstatet@@PEBD1AEAPEBDPEAD3AEAPEAD@Z", p_codecvt_inout}, {"?unshift@" CODECVT "QEBAHAEAU_Mbstatet@@PEAD1AEAPEAD@Z", p_codecvt_unshift},
  {"?_Fiopen@std@@YAPEAU_iobuf@@PEBDHH@Z", p_Fiopen}, {"?_Fiopen@std@@YAPEAU_iobuf@@PEB_WHH@Z", p_Fiopen_w},
  {"?_Xinvalid_argument@std@@YAXPEBD@Z", p_Xinvalid_argument}, {"?_Xlength_error@std@@YAXPEBD@Z", p_Xlength_error},
  {"?_Xout_of_range@std@@YAXPEBD@Z", p_Xout_of_range}, {"?_Xruntime_error@std@@YAXPEBD@Z", p_Xruntime_error}, {"?_Xbad_alloc@std@@YAXXZ", p_Xbad_alloc},
  {"?_Xbad_function_call@std@@YAXXZ", p_Xbad_function_call}, {"?_Throw_Cpp_error@std@@YAXH@Z", p_Throw_Cpp_error}, {"?_Throw_C_error@std@@YAXH@Z", p_Throw_C_error},
  {"?_Syserror_map@std@@YAPEBDH@Z", p_Syserror_map}, {"?_Winerror_map@std@@YAHH@Z", c_zero},
  {"?uncaught_exceptions@std@@YAHXZ", x_uncaught_exceptions}, {"?uncaught_exception@std@@YA_NXZ", p_uncaught_exception},
  {"?_Random_device@std@@YAIXZ", p_Random_device},
};
