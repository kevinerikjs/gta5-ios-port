// Mesh release (GTA-152, PG_MESH_RELEASE=1): the engine keeps its own copy of every vertex and index buffer
// after the renderer has copied it into a Metal buffer (measured with PG_TRACE_HELD: 94% of mesh bytes, about
// 75-135 MB at a 2.1 GB limit). Those engine pages are handed back to iOS and protected; the Metal buffer, which
// the CPU can read (shared storage), holds the same bytes. The game still reads some meshes on the CPU
// (grcVertexBufferEditor, grcIndexBuffer::LockRO: vehicle glass, for example), so any access to a released page
// faults, and the handler below copies the page back from the Metal buffer and lets the access go on.
//
// 1. Scripts/prepare_mesh_release.py: wasm_null_d3d::NullDevice::CreateBuffer calls pg_mesh_source with the
//    buffer's object id and its source range after it has written the upload into the command ring.
// 2. The renderer, after it copied that upload into the Metal buffer, calls PGMeshRelease. Each page fully inside
//    the source is made read-only and compared with the Metal copy; only identical pages are released. A page the
//    engine wrote meanwhile (memory reused, an object id taken again) differs and stays.
// 3. Before the Metal buffer goes away (destroyed, or renamed because the game rewrote it) PGMeshForget puts the
//    bytes back, so the engine's memory is exactly as it was.
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <signal.h>
#include <stdatomic.h>
#include <sys/mman.h>
#include <sys/sysctl.h>
#include <unistd.h>
#include <time.h>
#include <mach/vm_page_size.h>
#include <mach/mach.h>
#include <os/lock.h>

extern const uint8_t *pg_engine_memory(uint64_t *size);	// EngineHost.c
extern uint64_t pg_engine_memory_capacity(void);
extern void pg_log(const char *line);

// A page's state. RELEASED and ORPHANED pages are protected; an ORPHANED page's buffer is gone (PG_MESH_RELEASE=2:
// a destroyed mesh's pages stay handed back, empty, instead of getting the old bytes again). REOPENING: a PENDING page
// (read-only) is made writable again; it turns NORMAL only once it is (GTA-245).
enum { NORMAL, PENDING, DISCARDING, RELEASED, RESTORING, ORPHANED, REOPENING };
static _Atomic uint8_t *state;		// per engine page
static uint8_t **copy;				// per released page: the same bytes in the Metal buffer
static uint8_t *base;
static uint64_t capacity, pageSize;
static int enabled = -1, mode;
static struct sigaction oldBus, oldSegv;
static _Atomic uint64_t releasedPages, restoredByFault, restoredByForget, mismatches, orphaned, orphanWrites, orphanReads, remapFallbacks;

// Mode 3 (GTA-217, PG_MESH_RELEASE=3): pages shared by several meshes. Mode 2 hands back only pages that lie wholly
// inside one mesh of a page or more; in a 6 GB phone's city drive that is about 60% of the engine's mesh copies, because
// most meshes are a few KB and share pages with their neighbours (54k meshes, 539 MB, on 42k pages). Mode 3 hands back
// a page when the meshes the renderer holds cover it but for a little (PG_MESH_RESIDUE_BYTES, 1024 by default): the
// page's record lists the pieces (where in the page, where in which Metal buffer) and keeps the uncovered bytes itself.
// Putting it back copies the pieces and the kept bytes; a piece whose mesh is gone comes back as zeros (as in mode 2).
struct PageRec {
	struct PageRec *next;		// on the free list, once the page is back (freed later by the renderer thread)
	uint8_t *truth;			// PG_MESH_VERIFY=1 (tests): the whole page as it was handed back, to check what comes back
	uint32_t count;
	struct Piece { uint16_t off, len; uint32_t oid; const uint8_t *src; } piece[];
};
static struct PageRec *_Atomic *recs;	// per engine page, mode 3: the released page's record
#define DEAD_OID 0xFFFFFFFEu		// a destroyed mesh's piece, its bytes kept in the record
// Mode 3: which 64-byte granules of engine memory the engine has freed (sysMemBuddyAllocator::Free) and not handed out
// again (Allocate clears them first). The engine often frees a mesh's memory before the renderer sees the mesh
// destroyed, so a destroyed mesh's piece whose memory is already free needn't keep its bytes (GTA-217).
static _Atomic uint64_t *freedBits;		// 256 bits per page
static void granules(uint64_t start, uint64_t end, int set) {		// set: granules wholly inside; clear: any it touches
	uint64_t g0 = set ? (start + 63) / 64 : start / 64, g1 = set ? end / 64 : (end + 63) / 64;
	for (uint64_t g = g0; g < g1; ) {
		const uint64_t word = g / 64, bit = g % 64, n = 64 - bit < g1 - g ? 64 - bit : g1 - g;
		const uint64_t mask = (n == 64 ? ~0ull : ((1ull << n) - 1)) << bit;
		if (set) atomic_fetch_or(&freedBits[word], mask); else atomic_fetch_and(&freedBits[word], ~mask);
		g += n;
	}
}
static bool allFreed(uint64_t start, uint64_t end) {		// every granule [start, end) touches is free
	if (!freedBits) return false;
	for (uint64_t g = start / 64; g < (end + 63) / 64; g++) if (!(atomic_load(&freedBits[g / 64]) >> (g % 64) & 1)) return false;
	return true;
}
static _Atomic int64_t deadBytes;		// bytes of dead pieces held in records (malloc)
static _Atomic uint64_t freedPieces;
static struct PageRec *_Atomic freeRecs;	// records of pages put back (pushed from any thread, also the fault handler)
static uint32_t **pageOids;			// mode 3, renderer thread only: per page, the live meshes on it ([0] count, [1] capacity, oids)
// Mode 3: when each page was last put back (seconds of uptime, any thread, also the fault handler). A page put back in
// the last few seconds isn't handed back again: the game is using it, and a host read (pread) may be filling it right
// now. The kernel can't fault a page back in for a system call (EFAULT), so a page handed back again between
// PGMeshTouch and the read would leave the read unfinished. Mode 2 handed a page back once, at its mesh's upload;
// mode 3 tries a page again at every upload of a mesh on it, which opened that window (GTA-217 phone stop, 2026-10-26).
static _Atomic uint32_t *backAt;
#define BACK_HOLD_S 10
static uint32_t uptimeSeconds(void) { return (uint32_t)(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) / 1000000000ull); }
static uint32_t residueMax = 1024;
static void recRetire(struct PageRec *r) {
	if (!r) return;
	struct PageRec *head = atomic_load(&freeRecs);
	do r->next = head; while (!atomic_compare_exchange_weak(&freeRecs, &head, r));
}

// Object id → source range, from the engine thread to the renderer thread. A stale or reused entry is harmless:
// the renderer only releases pages whose bytes equal the Metal buffer's.
#define SOURCES 8192u
static struct { uint32_t oid; uint32_t size; uint64_t src; } sources[SOURCES];
static os_unfair_lock sourceLock = OS_UNFAIR_LOCK_INIT;

static void spin(void) { __asm__ volatile("yield"); }
// A PENDING page back to NORMAL (any thread, also the fault handler), after the caller took it from PENDING to
// REOPENING: writable first, NORMAL after (GTA-245). It used to be NORMAL first. In between, the page said NORMAL but was
// still read-only, and a thread writing there faulted again at once: the handler takes a fault on a NORMAL page for a
// stale one and lets it repeat, and after 1,000 repeats for a real crash. When the thread making the page writable was
// held up for a moment (2 ms is enough on an M-series Mac), the other one stopped the app: the cloth thread on the phone,
// twice (2026-10-27/28). Now a fault meanwhile finds REOPENING and waits in restore().
// PG_MESH_TEST_REOPEN_DELAY_US=n (tests): hold here n microseconds, to show the wait.
static uint64_t reopenDelayUs;
// Faults that found a page REOPENING and waited for it, and the longest wait (each was a run of repeated faults before);
// faults past the 1,000 repeats; pages the renderer found reopened right after its read-only step (stillPending).
static _Atomic uint64_t reopenWaits, reopenWaitMaxUs, slowFaults, lateReopens;
static void reopen(uint64_t page) {
	if (reopenDelayUs) { struct timespec t = {(time_t)(reopenDelayUs / 1000000), (long)(reopenDelayUs % 1000000) * 1000}; nanosleep(&t, NULL); }
	mprotect(base + page * pageSize, pageSize, PROT_READ | PROT_WRITE);
	atomic_store(&state[page], NORMAL);
}
// Renderer thread, right after it made a PENDING page read-only. A fault from before (the page protected for an earlier
// hand-back, the handler run late) can find the page PENDING before that and reopen it: writable, NORMAL. The read-only
// step then came after and the page stayed read-only while NORMAL, so every write to it faulted until the handler gave
// up (GTA-245, the host stress test). If it isn't PENDING any more, it is made writable again; nothing else protects
// it meanwhile, the renderer thread being the only one that hands pages back.
static bool stillPending(uint64_t page) {
	if (atomic_load(&state[page]) == PENDING) return true;
	mprotect(base + page * pageSize, pageSize, PROT_READ | PROT_WRITE);
	atomic_fetch_add(&lateReopens, 1);
	return false;
}
static void noteReopenWait(uint64_t since) {
	const uint64_t us = (clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - since) / 1000;
	atomic_fetch_add(&reopenWaits, 1);
	uint64_t max = atomic_load(&reopenWaitMaxUs);
	while (us > max && !atomic_compare_exchange_weak(&reopenWaitMaxUs, &max, us)) {}
}
void PGMeshFaultWaitStats(uint64_t *waits, uint64_t *maxUs, uint64_t *slow, uint64_t *late) { *waits = atomic_load(&reopenWaits); *maxUs = atomic_load(&reopenWaitMaxUs); *slow = atomic_load(&slowFaults); *late = atomic_load(&lateReopens); }
// PG_MESH_VERIFY=1 (simulator tests): every page put back is compared with a copy taken when it was handed back.
static int verify;
static _Atomic uint64_t verified, verifyBad, verifyBadPage, verifyBadOffset;
static char verifyDetail[400];		// the first difference: what covers it (written once, from any thread)
static void verifyRestore(uint64_t page, const uint8_t *at, const uint8_t *truth, const struct PageRec *r) {
	atomic_fetch_add(&verified, 1);
	if (!memcmp(at, truth, pageSize)) return;
	uint64_t off = 0; while (off < pageSize && at[off] == truth[off]) off++;
	uint64_t last = pageSize - 1; while (last > off && at[last] == truth[last]) last--;
	if (atomic_fetch_add(&verifyBad, 1) == 0) {
		atomic_store(&verifyBadPage, page); atomic_store(&verifyBadOffset, off);
		int n = snprintf(verifyDetail, sizeof verifyDetail, "bytes %llu-%llu differ, came back %02x%02x%02x%02x had %02x%02x%02x%02x; pieces:", (unsigned long long)off, (unsigned long long)last,
		                 at[off], at[off + 1 < pageSize ? off + 1 : off], at[off + 2 < pageSize ? off + 2 : off], at[off + 3 < pageSize ? off + 3 : off],
		                 truth[off], truth[off + 1 < pageSize ? off + 1 : off], truth[off + 2 < pageSize ? off + 2 : off], truth[off + 3 < pageSize ? off + 3 : off]);
		for (uint32_t i = 0; r && i < r->count && n > 0 && n < (int)sizeof verifyDetail - 40; i++)
			n += snprintf(verifyDetail + n, sizeof verifyDetail - n, " %u+%u%s", r->piece[i].off, r->piece[i].len, r->piece[i].oid == 0 ? "k" : r->piece[i].oid == 0xFFFFFFFEu ? "d" : !r->piece[i].src ? "z" : "m");
	}
}
const char *PGMeshVerifyDetail(void) { return verifyDetail; }
uint64_t PGMeshRemapFallbacks(void) { return atomic_load(&remapFallbacks); }
void PGMeshVerifyStats(uint64_t *checked, uint64_t *bad, uint64_t *badPage, uint64_t *badOffset) {
	*checked = atomic_load(&verified); *bad = atomic_load(&verifyBad); *badPage = atomic_load(&verifyBadPage); *badOffset = atomic_load(&verifyBadOffset);
}

// Puts one released page back (any thread, also inside the fault handler): only syscalls and memcpy. `faulted`:
// the caller is the fault handler, so a PENDING page is read-only and was written to.
static void restore(uint64_t page, _Atomic uint64_t *counter, int faulted) {
	if (backAt) atomic_store(&backAt[page], uptimeSeconds());		// first: shareTry checks it after taking the page
	uint64_t waitSince = 0;		// a fault waiting for a page REOPENING
	for (;;) {
		uint8_t s = atomic_load(&state[page]);
		if (s == NORMAL) { if (waitSince) noteReopenWait(waitSince); return; }
		if (s == RELEASED) {
			uint8_t expected = RELEASED;
			if (!atomic_compare_exchange_strong(&state[page], &expected, RESTORING)) continue;
			uint8_t *at = base + page * pageSize;
			// The page's bytes are put together in a scratch page and that page is mapped over the handed-back one in one
			// step (GTA-217). Making the page writable first and copying into it let another engine thread write there in
			// between, and the copy then wiped that write out (a lost write: a pointer read back as 0 is what stopped the
			// game on the phone). Until the remap the page stays protected, so other threads fault and wait here.
			uint8_t *fill = mmap(NULL, pageSize, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
			uint8_t *into = fill != MAP_FAILED ? fill : at;
			if (fill == MAP_FAILED) { atomic_fetch_add(&remapFallbacks, 1); mprotect(at, pageSize, PROT_READ | PROT_WRITE); madvise(at, pageSize, MADV_FREE_REUSE); }
			struct PageRec *r = recs ? atomic_exchange(&recs[page], NULL) : NULL;
			if (recs) {		// mode 3: the pieces and the kept bytes
				if (into == at) memset(at, 0, pageSize);		// a fresh scratch page is zeros already
				if (r) for (uint32_t i = 0; i < r->count; i++) if (r->piece[i].src) memcpy(into + r->piece[i].off, r->piece[i].src, r->piece[i].len);
			} else memcpy(into, copy[page], pageSize);
			if (r && r->truth) verifyRestore(page, into, r->truth, r);		// before the page can be written again
			if (r) for (uint32_t i = 0; i < r->count; i++) if (r->piece[i].oid == DEAD_OID) atomic_fetch_sub(&deadBytes, r->piece[i].len);
			if (into == fill) {
				vm_address_t target = (vm_address_t)at; vm_prot_t cur, max;
				if (vm_remap(mach_task_self(), &target, pageSize, 0, VM_FLAGS_FIXED | VM_FLAGS_OVERWRITE, mach_task_self(), (vm_address_t)fill, FALSE, &cur, &max, VM_INHERIT_DEFAULT) != KERN_SUCCESS || target != (vm_address_t)at) {
					atomic_fetch_add(&remapFallbacks, 1);		// the old way, as a last resort
					mprotect(at, pageSize, PROT_READ | PROT_WRITE); madvise(at, pageSize, MADV_FREE_REUSE); memcpy(at, fill, pageSize);
				}
				munmap(fill, pageSize);
			}
			recRetire(r);
			atomic_store(&state[page], NORMAL);
			atomic_fetch_add(counter, 1);
			return;
		}
		if (s == ORPHANED) {		// handed back for good: the page comes back empty
			uint8_t expected = ORPHANED;
			if (!atomic_compare_exchange_strong(&state[page], &expected, RESTORING)) continue;
			uint8_t *at = base + page * pageSize;
			mprotect(at, pageSize, PROT_READ | PROT_WRITE);
			madvise(at, pageSize, MADV_FREE_REUSE);
			atomic_store(&state[page], NORMAL);
			atomic_fetch_add(faulted == 2 ? &orphanReads : &orphanWrites, 1);
			return;
		}
		if (s == PENDING && faulted) {		// read-only while the renderer compares it: the bytes are intact
			uint8_t expected = PENDING;
			if (atomic_compare_exchange_strong(&state[page], &expected, REOPENING)) { reopen(page); return; }
			continue;
		}
		if (s == REOPENING && faulted && !waitSince) waitSince = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
		spin();		// PENDING (not from a fault), DISCARDING, RESTORING or REOPENING: the other thread finishes in a moment
	}
}

// Engine memory is read-write except for released pages, so a fault inside it is one: put the page back and let
// the access run again. A page already NORMAL was put back by another thread between the fault and here; the
// access just runs again. Only a fault that keeps coming back on a NORMAL page (a bug) goes on to the old handler,
// after 1,000 repeats and a second of short sleeps (GTA-245: if another thread is still between two steps we haven't
// found, it gets the time to finish; counted, so the log shows it).
static _Thread_local uintptr_t lastFault; static _Thread_local unsigned repeats; static _Thread_local uint64_t slowSince;
static void fault(int sig, siginfo_t *info, void *context) {
	uintptr_t at = (uintptr_t)info->si_addr;
	if (state && at >= (uintptr_t)base && at < (uintptr_t)base + capacity) {
		uint64_t page = (at - (uintptr_t)base) / pageSize;
		// The data abort's WnR bit tells a read (2) from a write (1): reading an orphaned page means something
		// still used the dead mesh's bytes, which mode 2 can't give back.
		int read = !((((ucontext_t *)context)->uc_mcontext->__es.__esr >> 6) & 1);
		if (atomic_load(&state[page]) != NORMAL) { repeats = 0; restore(page, &restoredByFault, read ? 2 : 1); return; }
		if (at != lastFault) { lastFault = at; repeats = 0; }
		if (++repeats < 1000) return;
		const uint64_t now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
		if (repeats == 1000) { slowSince = now; atomic_fetch_add(&slowFaults, 1); }
		if (now - slowSince < 1000000000ull) { struct timespec t = {0, 50000}; nanosleep(&t, NULL); return; }
	}
	struct sigaction *old = sig == SIGBUS ? &oldBus : &oldSegv;
	if ((old->sa_flags & SA_SIGINFO) && old->sa_sigaction) { old->sa_sigaction(sig, info, context); return; }
	if (old->sa_handler == SIG_IGN) return;
	if (old->sa_handler && old->sa_handler != SIG_DFL) { old->sa_handler(sig); return; }
	sigaction(sig, old, NULL);		// a real crash: the access repeats and the default action follows
}

static int debugged(void) {
	struct kinfo_proc info = {0}; size_t size = sizeof info; int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()};
	return sysctl(mib, 4, &info, &size, NULL, 0) == 0 && (info.kp_proc.p_flag & P_TRACED);
}

static int on(void) {
	if (enabled >= 0) return enabled;
	const char *v = getenv("PG_MESH_RELEASE");
	enabled = 0;
	if (!v || (strcmp(v, "1") && strcmp(v, "2") && strcmp(v, "3"))) return 0;
	mode = atoi(v);
	// A debugger stops at every protected-page access (EXC_BAD_ACCESS) before the handler sees it.
	if (debugged()) { pg_log("Mesh release: off under a debugger."); return 0; }
	uint64_t size; base = (uint8_t *)pg_engine_memory(&size);
	pageSize = vm_page_size;
	capacity = pg_engine_memory_capacity();		// the whole reservation: the engine's memory grows into it
	uint64_t pages = capacity / pageSize;
	state = (_Atomic uint8_t *)mmap(NULL, pages, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
	copy = (uint8_t **)mmap(NULL, pages * sizeof *copy, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
	if (!base || state == MAP_FAILED || copy == MAP_FAILED) { state = NULL; pg_log("Mesh release: off (no table)."); return 0; }
	if (mode == 3) {
		recs = (struct PageRec *_Atomic *)mmap(NULL, pages * sizeof *recs, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
		pageOids = (uint32_t **)mmap(NULL, pages * sizeof *pageOids, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
		backAt = (_Atomic uint32_t *)mmap(NULL, pages * sizeof *backAt, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
		freedBits = (_Atomic uint64_t *)mmap(NULL, pages * 4 * sizeof(uint64_t), PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
		if (freedBits == MAP_FAILED) freedBits = NULL;
		if (recs == MAP_FAILED || pageOids == MAP_FAILED || backAt == MAP_FAILED) { state = NULL; recs = NULL; backAt = NULL; pg_log("Mesh release: off (no page records)."); return 0; }
		const char *r = getenv("PG_MESH_RESIDUE_BYTES"); long b = r ? atol(r) : 1024; residueMax = (uint32_t)(b >= 0 && b <= 8192 ? b : 1024);
		verify = getenv("PG_MESH_VERIFY") && atoi(getenv("PG_MESH_VERIFY"));
		if (verify) pg_log("Mesh release: every page put back is checked against a copy (PG_MESH_VERIFY).");
	}
	struct sigaction handler = {0};
	handler.sa_sigaction = fault; handler.sa_flags = SA_SIGINFO | SA_ONSTACK; sigemptyset(&handler.sa_mask);
	sigaction(SIGBUS, &handler, &oldBus); sigaction(SIGSEGV, &handler, &oldSegv);
	{ const char *d = getenv("PG_MESH_TEST_REOPEN_DELAY_US"); reopenDelayUs = d ? strtoull(d, NULL, 10) : 0; }
	if (reopenDelayUs) { char line[120]; snprintf(line, sizeof line, "Mesh release: test hold of %llu us while a page is made writable again (PG_MESH_TEST_REOPEN_DELAY_US).", (unsigned long long)reopenDelayUs); pg_log(line); }
	if (mode == 3) { char line[160]; snprintf(line, sizeof line, "Mesh release: on, pages shared by several meshes too, up to %u bytes kept per page (GTA-217).", residueMax); pg_log(line); }
	else pg_log(mode == 2 ? "Mesh release: on, destroyed meshes stay handed back (GTA-152)." : "Mesh release: on (GTA-152).");
	return enabled = 1;
}

// Engine thread, from CreateBuffer: `desc` is the D3D11_BUFFER_DESC (Usage +4, BindFlags +8, CPUAccessFlags +12,
// MiscFlags +16). Only plain vertex and index buffers the CPU can't map, and at least one whole page.
// Coverage trace (GTA-217, PG_TRACE_MESH_COVERAGE=1): every live plain mesh's source range, to see how much of the
// engine's copy of the meshes could be handed back if pages shared by several meshes counted too.
static int coverage = -1;
#define COVER_SLOTS (1u << 19)
static struct { uint32_t oid; uint32_t size; uint64_t src; } *cover;	// oid 0 empty, ~0u deleted
static os_unfair_lock coverLock = OS_UNFAIR_LOCK_INIT;
static uint64_t coverLive;
static int coverageOn(void) {
	if (coverage < 0) {
		coverage = getenv("PG_TRACE_MESH_COVERAGE") && atoi(getenv("PG_TRACE_MESH_COVERAGE"));
		if (coverage) { cover = calloc(COVER_SLOTS, sizeof *cover); if (!cover) coverage = 0; else pg_log("Mesh coverage trace on (PG_TRACE_MESH_COVERAGE)."); }
	}
	return coverage;
}
static void coverAdd(uint32_t oid, uint64_t src, uint32_t size) {
	os_unfair_lock_lock(&coverLock);
	uint32_t slot = (oid * 2654435761u) & (COVER_SLOTS - 1);
	for (uint32_t n = 0; n < COVER_SLOTS; n++, slot = (slot + 1) & (COVER_SLOTS - 1))
		if (cover[slot].oid == 0 || cover[slot].oid == ~0u || cover[slot].oid == oid) {
			if (cover[slot].oid != oid) coverLive++;
			cover[slot].oid = oid; cover[slot].src = src; cover[slot].size = size; break;
		}
	os_unfair_lock_unlock(&coverLock);
}
void PGMeshGone(uint32_t oid) {
	if (coverage != 1 || !oid) return;
	os_unfair_lock_lock(&coverLock);
	uint32_t slot = (oid * 2654435761u) & (COVER_SLOTS - 1);
	for (uint32_t n = 0; n < COVER_SLOTS && cover[slot].oid; n++, slot = (slot + 1) & (COVER_SLOTS - 1))
		if (cover[slot].oid == oid) { cover[slot].oid = ~0u; coverLive--; break; }
	os_unfair_lock_unlock(&coverLock);
}
static int byStart(const void *a, const void *b) { uint64_t x = ((const uint64_t *)a)[0], y = ((const uint64_t *)b)[0]; return x < y ? -1 : x > y; }
void PGMeshCoverage(char *out, size_t outSize) {
	out[0] = 0;
	if (coverage != 1) return;
	os_unfair_lock_lock(&coverLock);
	uint64_t n = 0, *r = malloc((coverLive + 1) * 16);
	if (r) for (uint32_t i = 0; i < COVER_SLOTS; i++) if (cover[i].oid && cover[i].oid != ~0u && n <= coverLive) { r[2 * n] = cover[i].src; r[2 * n + 1] = cover[i].src + cover[i].size; n++; }
	os_unfair_lock_unlock(&coverLock);
	if (!r) return;
	qsort(r, n, 16, byStart);
	const uint64_t page = vm_page_size;
	uint64_t meshBytes = 0, bigBytes = 0, unionBytes = 0, pages = 0, full = 0, p95 = 0, p75 = 0, inFull = 0, in95 = 0, overlap = 0;
	uint64_t curPage = UINT64_MAX, curCovered = 0;
	uint64_t a = 0, b = 0;	// current merged interval
	#define FLUSH_PAGE() do { if (curPage != UINT64_MAX) { pages++; if (curCovered >= page) { full++; inFull += curCovered; } if (curCovered * 100 >= page * 95) { p95++; in95 += curCovered; } if (curCovered * 100 >= page * 75) p75++; } } while (0)
	#define ADD_INTERVAL(s, e) do { for (uint64_t x = (s); x < (e);) { uint64_t pg = x / page, end = (pg + 1) * page < (e) ? (pg + 1) * page : (e); if (pg != curPage) { FLUSH_PAGE(); curPage = pg; curCovered = 0; } curCovered += end - x; x = end; } } while (0)
	for (uint64_t i = 0; i < n; i++) {
		uint64_t s0 = r[2 * i], e0 = r[2 * i + 1];
		meshBytes += e0 - s0; if (e0 - s0 >= page) bigBytes += e0 - s0;
		if (i && s0 < b) overlap += (e0 < b ? e0 : b) - s0;
		if (!i || s0 > b) { if (i) { unionBytes += b - a; ADD_INTERVAL(a, b); } a = s0; b = e0; }
		else if (e0 > b) b = e0;
	}
	if (n) { unionBytes += b - a; ADD_INTERVAL(a, b); }
	FLUSH_PAGE();
	#undef ADD_INTERVAL
	#undef FLUSH_PAGE
	free(r);
	snprintf(out, outSize, " | mesh sources [trace]: %llu live, %llu MB (%llu MB in buffers of a page or more), union %llu MB on %llu pages; pages wholly covered %llu (%llu MB), 95%%+ %llu (%llu MB), 75%%+ %llu; overlapping %llu MB",
	         (unsigned long long)n, (unsigned long long)(meshBytes >> 20), (unsigned long long)(bigBytes >> 20), (unsigned long long)(unionBytes >> 20), (unsigned long long)pages,
	         (unsigned long long)full, (unsigned long long)(inFull >> 20), (unsigned long long)p95, (unsigned long long)(in95 >> 20), (unsigned long long)p75, (unsigned long long)(overlap >> 20));
}

void pg_mesh_source(uint32_t oid, uint64_t src, uint32_t size, uint64_t desc) {
	if (coverageOn() && pageSize == 0) pageSize = vm_page_size;
	if (coverage == 1 && size && desc + 20 <= pg_engine_memory_capacity() && src + size <= pg_engine_memory_capacity()) {
		const uint8_t *m; uint64_t msize; m = pg_engine_memory(&msize);
		uint32_t usage, bind, cpu, misc;
		memcpy(&usage, m + desc + 4, 4); memcpy(&bind, m + desc + 8, 4); memcpy(&cpu, m + desc + 12, 4); memcpy(&misc, m + desc + 16, 4);
		if (usage <= 1 && !cpu && !misc && (bind & 3) && !(bind & ~3u)) coverAdd(oid, src, size);
	}
	if (!on() || (size < pageSize && mode != 3) || !size || desc + 20 > capacity || src + size > capacity) return;
	uint32_t usage, bind, cpu, misc;
	memcpy(&usage, base + desc + 4, 4); memcpy(&bind, base + desc + 8, 4); memcpy(&cpu, base + desc + 12, 4); memcpy(&misc, base + desc + 16, 4);
	if (usage > 1 || cpu || misc || !(bind & 3) || (bind & ~3u)) return;		// DEFAULT or IMMUTABLE; VB (1) / IB (2) only
	os_unfair_lock_lock(&sourceLock);
	uint32_t slot = (oid * 2654435761u) % SOURCES;
	sources[slot].oid = oid; sources[slot].size = size; sources[slot].src = src;
	os_unfair_lock_unlock(&sourceLock);
}

// A handed-back page's record rewritten: `oid`'s pieces become dead pieces with their bytes in the record (a destroyed
// mesh), or (oid 0) dead pieces wholly inside [freeStart, freeEnd) (engine addresses) are dropped (memory the engine
// freed: they come back as zeros). Any thread but the fault handler. Holds the page (RESTORING) meanwhile, so a fault
// waits. False if the page isn't handed back or there's no memory (the caller then puts the page back instead).
static bool recRewrite(uint64_t page, uint32_t oid, uint64_t freeStart, uint64_t freeEnd) {
	uint8_t expected = RELEASED;
	for (;;) {
		expected = RELEASED;
		if (atomic_compare_exchange_strong(&state[page], &expected, RESTORING)) break;
		if (expected != RESTORING && expected != PENDING && expected != DISCARDING) return false;		// NORMAL: nothing to do
		spin();
	}
	struct PageRec *r = atomic_load(&recs[page]);
	if (!r) { atomic_store(&state[page], RELEASED); return true; }
	const uint64_t start = page * pageSize;
	size_t tail = 0; uint32_t keep = 0; bool change = false;
	for (uint32_t i = 0; i < r->count; i++) {
		const struct Piece *q = &r->piece[i];
		const bool dropped = (!oid && q->oid == DEAD_OID && start + q->off >= freeStart && start + q->off + q->len <= freeEnd) ||
		                     (oid && q->oid == oid && allFreed(start + q->off, start + q->off + q->len));
		if (dropped || (oid && q->oid == oid)) change = true;
		if (dropped) continue;
		keep++;
		if (!q->oid || q->oid == DEAD_OID || q->oid == oid) tail += q->len;
	}
	if (!change) { atomic_store(&state[page], RELEASED); return true; }
	struct PageRec *n = malloc(sizeof *n + keep * sizeof(struct Piece) + tail);
	if (!n) { atomic_store(&state[page], RELEASED); return false; }
	n->next = NULL; n->count = keep; n->truth = NULL;
	uint8_t *kept = (uint8_t *)&n->piece[keep];
	int64_t dead = 0; uint32_t k = 0; bool droppedAny = false;
	for (uint32_t i = 0; i < r->count; i++) {
		const struct Piece *q = &r->piece[i];
		const bool dropped = (!oid && q->oid == DEAD_OID && start + q->off >= freeStart && start + q->off + q->len <= freeEnd) ||
		                     (oid && q->oid == oid && allFreed(start + q->off, start + q->off + q->len));
		if (dropped) { if (q->oid == DEAD_OID) dead -= q->len; atomic_fetch_add(&freedPieces, 1); droppedAny = true; continue; }
		struct Piece *d = &n->piece[k++]; *d = *q;
		if (!q->oid || q->oid == DEAD_OID || q->oid == oid) {		// bytes move into this record
			if (q->src) memcpy(kept, q->src, q->len); else memset(kept, 0, q->len);
			d->src = kept; kept += q->len;
			if (oid && q->oid == oid) { d->oid = DEAD_OID; dead += q->len; }
		}
	}
	// The check copy: dropped pieces come back as zeros, so the copy becomes zeros with the kept pieces' bytes on top
	// (as restore() builds the page). Before, it was thrown away, and those pages went unchecked.
	if (droppedAny && r->truth && (n->truth = malloc(pageSize))) {
		memset(n->truth, 0, pageSize);
		for (uint32_t i = 0; i < n->count; i++) memcpy(n->truth + n->piece[i].off, r->truth + n->piece[i].off, n->piece[i].len);
	} else if (!droppedAny) { n->truth = r->truth; r->truth = NULL; }
	free(r->truth); r->truth = NULL;
	atomic_store(&recs[page], n);
	atomic_store(&state[page], RELEASED);
	atomic_fetch_add(&deadBytes, dead);
	recRetire(r);
	return true;
}
// Engine thread (pg_buddy_free): the engine freed [start, start + size). Dead pieces inside it are dropped.
void PGMeshAllocated(uint64_t start, uint64_t size) {		// engine thread, before the caller writes the block
	if (enabled != 1 || mode != 3 || !freedBits || !size || start >= capacity) return;
	granules(start, start + size < capacity ? start + size : capacity, 0);
}
void PGMeshFreed(uint64_t start, uint64_t size) {
	if (enabled != 1 || mode != 3 || !size || start >= capacity) return;
	uint64_t end = start + size; if (end > capacity) end = capacity;
	if (freedBits) granules(start, end, 1);
	for (uint64_t page = start / pageSize; page * pageSize < end; page++)
		if (atomic_load(&state[page]) == RELEASED) recRewrite(page, 0, start, end);
}
void PGMeshForget(uint64_t firstPage, uint32_t pageCount, int gone);
// Mode 3, renderer thread only: the live meshes (object id -> source range and Metal bytes), open addressing.
#define LIVE_SLOTS (1u << 18)
static struct Live { uint32_t oid, size; uint64_t src; const uint8_t *contents; } *live;	// oid 0 empty, ~0u deleted
static uint32_t liveCount;
static uint32_t liveTombs;
static void liveRebuild(void) {		// tombstones would fill the table over a long session: put the live ones in a fresh one
	struct Live *old = live, *fresh = calloc(LIVE_SLOTS, sizeof *fresh);
	if (!fresh) return;
	for (uint32_t i = 0; i < LIVE_SLOTS; i++) if (old[i].oid && old[i].oid != ~0u) {
		uint32_t slot = (old[i].oid * 2654435761u) & (LIVE_SLOTS - 1);
		while (fresh[slot].oid) slot = (slot + 1) & (LIVE_SLOTS - 1);
		fresh[slot] = old[i];
	}
	live = fresh; liveTombs = 0; free(old);
}
static struct Live *liveFind(uint32_t oid, int add) {
	if (!live) { live = calloc(LIVE_SLOTS, sizeof *live); if (!live) return NULL; }
	if (add && liveCount + liveTombs > LIVE_SLOTS / 2) liveRebuild();
	uint32_t slot = (oid * 2654435761u) & (LIVE_SLOTS - 1); struct Live *tomb = NULL;
	for (uint32_t n = 0; n < LIVE_SLOTS; n++, slot = (slot + 1) & (LIVE_SLOTS - 1)) {
		struct Live *e = &live[slot];
		if (e->oid == oid) return e;
		if (e->oid == ~0u) { if (!tomb) tomb = e; continue; }
		if (!e->oid) { if (!add) return NULL; if (liveCount >= LIVE_SLOTS / 2) return NULL; if (!tomb) tomb = e; else liveTombs--; tomb->oid = oid; liveCount++; return tomb; }
	}
	return NULL;
}
static void pageAddOid(uint64_t page, uint32_t oid) {
	uint32_t *a = pageOids[page];
	if (!a || a[0] == a[1]) {
		uint32_t cap = a ? a[1] * 2 : 4, *b = realloc(a, (cap + 2) * sizeof *b);
		if (!b) return;
		if (!a) b[0] = 0;
		b[1] = cap; a = pageOids[page] = b;
	}
	a[2 + a[0]++] = oid;
}
static void pageRemoveOid(uint64_t page, uint32_t oid) {
	uint32_t *a = pageOids[page];
	if (!a) return;
	for (uint32_t i = 0; i < a[0]; i++) if (a[2 + i] == oid) { a[2 + i] = a[2 + --a[0]]; break; }
	if (!a[0]) { free(a); pageOids[page] = NULL; }
}
static int byOff(const void *x, const void *y) { const struct Piece *a = x, *b = y; return (int)a->off - (int)b->off; }
static _Atomic uint64_t sharedPages, residueBytes, heldBack, reusableSkipped;
// Hands one page back if the live meshes on it cover all but residueMax bytes and hold its bytes.
static int shareTry(uint64_t page) {
	uint32_t *a = pageOids[page];
	if (!a || !a[0] || a[0] > 512 || atomic_load(&state[page]) != NORMAL) return 0;
	struct Piece pieces[512]; uint32_t n = 0;
	const uint64_t start = page * pageSize, end = start + pageSize;
	for (uint32_t i = 0; i < a[0]; i++) {
		struct Live *e = liveFind(a[2 + i], 0);
		if (!e) continue;
		uint64_t s0 = e->src > start ? e->src : start, e0 = e->src + e->size < end ? e->src + e->size : end;
		if (e0 <= s0) continue;
		pieces[n].off = (uint16_t)(s0 - start); pieces[n].len = (uint16_t)(e0 - s0); pieces[n].oid = e->oid; pieces[n].src = e->contents + (s0 - e->src); n++;
	}
	if (!n) return 0;
	qsort(pieces, n, sizeof *pieces, byOff);
	// The uncovered runs, and their size.
	struct { uint16_t off, len; } gaps[64]; uint32_t gapCount = 0, uncovered = 0, reach = 0;
	for (uint32_t i = 0; i <= n; i++) {
		uint32_t s0 = i < n ? pieces[i].off : (uint32_t)pageSize;
		if (s0 > reach) { if (gapCount == 64) return 0; gaps[gapCount].off = (uint16_t)reach; gaps[gapCount].len = (uint16_t)(s0 - reach); gapCount++; uncovered += s0 - reach; if (uncovered > residueMax) return 0; }
		if (i < n && (uint32_t)pieces[i].off + pieces[i].len > reach) reach = (uint32_t)pieces[i].off + pieces[i].len;
	}
	uint8_t *at = base + start;
	uint8_t expected = NORMAL;
	if (!atomic_compare_exchange_strong(&state[page], &expected, PENDING)) return 0;
	// Put back in the last BACK_HOLD_S seconds (by the game, a host read or a destroyed mesh): leave it. Read after the CAS,
	// so a PGMeshTouch that stamped before it is seen here, and one that stamps after it waits for this page in restore().
	const uint32_t back = atomic_load(&backAt[page]);
	if (back && uptimeSeconds() - back < BACK_HOLD_S) { atomic_store(&state[page], NORMAL); atomic_fetch_add(&heldBack, 1); return 0; }
	// Freed memory heap return already marked reusable: iOS no longer counts it and may take it back (zero it) at any
	// moment, also while the bytes here are compared and copied. Handing it back gains nothing and would snapshot bytes
	// that can change under the copy, so it's left alone.
	{ integer_t disposition = 0, refs = 0;
	  if (vm_map_page_query(mach_task_self(), (vm_offset_t)(uintptr_t)at, &disposition, &refs) == KERN_SUCCESS && (disposition & VM_PAGE_QUERY_PAGE_REUSABLE)) {
		atomic_store(&state[page], NORMAL); atomic_fetch_add(&reusableSkipped, 1); return 0; } }
	mprotect(at, pageSize, PROT_READ);
	if (!stillPending(page)) return 0;
	for (uint32_t i = 0; i < n; i++) if (memcmp(at + pieces[i].off, pieces[i].src, pieces[i].len)) {
		expected = PENDING;
		if (atomic_compare_exchange_strong(&state[page], &expected, REOPENING)) reopen(page);
		atomic_fetch_add(&mismatches, 1);
		return 0;
	}
	// The record: the mesh pieces, then the kept bytes as pieces of their own (oid 0) pointing into the record.
	struct PageRec *r = malloc(sizeof *r + (n + gapCount) * sizeof(struct Piece) + uncovered);
	if (!r) { expected = PENDING; if (atomic_compare_exchange_strong(&state[page], &expected, REOPENING)) reopen(page); return 0; }
	r->next = NULL; r->count = n + gapCount; r->truth = NULL;
	if (verify && (r->truth = malloc(pageSize))) memcpy(r->truth, at, pageSize);
	memcpy(r->piece, pieces, n * sizeof *pieces);
	uint8_t *kept = (uint8_t *)&r->piece[n + gapCount];
	for (uint32_t g = 0; g < gapCount; g++) {
		memcpy(kept, at + gaps[g].off, gaps[g].len);
		r->piece[n + g] = (struct Piece){gaps[g].off, gaps[g].len, 0, kept};
		kept += gaps[g].len;
	}
	expected = PENDING;
	if (!atomic_compare_exchange_strong(&state[page], &expected, DISCARDING)) { free(r->truth); free(r); return 0; }	// the engine touched it meanwhile
	atomic_store(&recs[page], r);
	mprotect(at, pageSize, PROT_NONE);		// first: once handed back, a read would see zeros without a fault
	madvise(at, pageSize, MADV_FREE_REUSABLE);
	atomic_store(&state[page], RELEASED);
	atomic_fetch_add(&releasedPages, 1); atomic_fetch_add(&sharedPages, 1); atomic_fetch_add(&residueBytes, uncovered);
	return 1;
}
static uint32_t shareRelease(uint32_t oid, uint64_t src, uint32_t size, const uint8_t *contents, uint64_t *firstPage, uint32_t *pageCount, uint32_t *pageOffset) {
	// Free the records of pages put back since last time (the fault handler can't free).
	for (struct PageRec *r = atomic_exchange(&freeRecs, NULL); r;) {
		struct PageRec *next = r->next;
		free(r->truth); free(r); r = next;
	}
	struct Live *e = liveFind(oid, 1);
	if (!e) return 0;
	e->src = src; e->size = size; e->contents = contents;
	const uint64_t first = src / pageSize, last = (src + size - 1) / pageSize;
	for (uint64_t page = first; page <= last; page++) pageAddOid(page, oid);
	uint32_t released = 0;
	for (uint64_t page = first; page <= last; page++) released += (uint32_t)shareTry(page);
	*firstPage = first; *pageCount = (uint32_t)(last - first + 1); *pageOffset = 0;
	return released ? released : 0x80000000u;		// non-zero: the renderer must call PGMeshForgetMesh later in any case
}
// Mode 3, renderer thread: the mesh `oid` (on pages first .. first + count) is destroyed (`gone`) or rewritten. Its
// pieces in released pages become zeros (a destroyed mesh, as mode 2) or its pages come back (a rewritten one).
void PGMeshForgetMesh(uint32_t oid, uint64_t firstPage, uint32_t pageCount, int gone) {
	if (enabled != 1 || mode != 3) { PGMeshForget(firstPage, pageCount, gone); return; }
	for (uint64_t page = firstPage; page < firstPage + pageCount; page++) {
		pageRemoveOid(page, oid);
		// Rewritten: its pages come back first. Destroyed: its Metal buffer is about to go, so its pieces' bytes move into
		// the page's record ("dead" pieces): the page stays handed back and still comes back exactly. Mode 2 left a
		// destroyed mesh's pages empty (zeros), but the game does read that memory again ("read again" in player logs):
		// a destroyed GPU buffer doesn't mean the game is done with the bytes. Only once the engine frees that memory
		// (PGMeshFreed) do the dead pieces go, and the freed part comes back as zeros.
		if (!gone || !recRewrite(page, oid, 0, 0)) restore(page, &restoredByForget, 0);
	}
	struct Live *e = liveFind(oid, 0);
	if (e) { e->oid = ~0u; liveCount--; liveTombs++; }
}
void PGMeshShareStats(uint64_t *pages, uint64_t *kept, uint64_t *held) { *pages = atomic_load(&sharedPages); *kept = atomic_load(&residueBytes); *held = atomic_load(&heldBack); }
void PGMeshDeadStats(int64_t *bytes, uint64_t *freed, uint64_t *reusable) { *bytes = atomic_load(&deadBytes); *freed = atomic_load(&freedPieces); *reusable = atomic_load(&reusableSkipped); }

// Renderer thread, after an upload of `oid` filled its Metal buffer (`contents`, the buffer's `bytes`). Returns
// the number of pages released; the renderer remembers the range for PGMeshForget.
uint32_t PGMeshRelease(uint32_t oid, const uint8_t *contents, uint32_t bytes, uint64_t *firstPage, uint32_t *pageCount, uint32_t *pageOffset) {
	if (enabled != 1) return 0;
	os_unfair_lock_lock(&sourceLock);
	uint32_t slot = (oid * 2654435761u) % SOURCES;
	uint64_t src = sources[slot].oid == oid ? sources[slot].src : 0; uint32_t size = sources[slot].oid == oid ? sources[slot].size : 0;
	if (sources[slot].oid == oid) sources[slot].oid = 0;
	os_unfair_lock_unlock(&sourceLock);
	if (!size || size > bytes) return 0;
	if (mode == 3) return shareRelease(oid, src, size, contents, firstPage, pageCount, pageOffset);
	uint64_t first = (src + pageSize - 1) / pageSize, end = (src + size) / pageSize;
	if (end <= first) return 0;
	uint32_t released = 0;
	for (uint64_t page = first; page < end; page++) {
		uint8_t *at = base + page * pageSize;
		const uint8_t *same = contents + (page * pageSize - src);
		uint8_t expected = NORMAL;
		if (!atomic_compare_exchange_strong(&state[page], &expected, PENDING)) continue;	// already another buffer's
		mprotect(at, pageSize, PROT_READ);
		if (!stillPending(page)) continue;
		if (memcmp(at, same, pageSize)) {
			expected = PENDING;
			if (atomic_compare_exchange_strong(&state[page], &expected, REOPENING)) reopen(page);
			atomic_fetch_add(&mismatches, 1);
			continue;
		}
		expected = PENDING;
		if (!atomic_compare_exchange_strong(&state[page], &expected, DISCARDING)) continue;	// the engine touched it
		copy[page] = (uint8_t *)same;
		mprotect(at, pageSize, PROT_NONE);		// first: once handed back, a read would see zeros without a fault
		madvise(at, pageSize, MADV_FREE_REUSABLE);
		atomic_store(&state[page], RELEASED);
		released++;
	}
	atomic_fetch_add(&releasedPages, released);
	*firstPage = first; *pageCount = (uint32_t)(end - first); *pageOffset = (uint32_t)(first * pageSize - src);
	return released;
}

// Renderer thread, before the Metal buffer that holds these pages' bytes goes away (`gone`: destroyed, not
// rewritten). Mode 2 leaves a destroyed buffer's pages handed back: the engine freed that mesh with it.
void PGMeshForget(uint64_t firstPage, uint32_t pageCount, int gone) {
	if (enabled != 1) return;
	for (uint64_t page = firstPage; page < firstPage + pageCount; page++) {
		uint8_t expected = RELEASED;
		if (gone && mode == 2 && atomic_compare_exchange_strong(&state[page], &expected, ORPHANED)) { atomic_fetch_add(&orphaned, 1); continue; }
		restore(page, &restoredByForget, 0);
	}
}

// Host code that hands engine memory to a system call (pread into it, write from it) calls this first: the kernel
// doesn't fault on a protected page, the call fails with EFAULT. Memory the engine freed and reused for a new read
// can still be released until the renderer has seen the old buffer's destroy.
static _Atomic uint64_t restoredByTouch;
void PGMeshTouch(const void *start, uint64_t length) {
	if (enabled != 1 || !length) return;
	uintptr_t a = (uintptr_t)start, b = (uintptr_t)base;
	if (a >= b + capacity || a + length <= b) return;
	uint64_t first = a > b ? (a - b) / pageSize : 0, last = (a + length - 1 - b) / pageSize;
	if (last >= capacity / pageSize) last = capacity / pageSize - 1;
	// Mode 3: every page of the range is stamped first, also the ones not handed back, so shareTry leaves them alone
	// while the system call fills them (it reads the stamp after taking a page; this restores after stamping).
	if (backAt) { const uint32_t now = uptimeSeconds(); for (uint64_t page = first; page <= last; page++) atomic_store(&backAt[page], now); }
	for (uint64_t page = first; page <= last; page++) if (atomic_load(&state[page]) != NORMAL) restore(page, &restoredByTouch, 0);
}

// For the renderer's periodic report.
void PGMeshReleaseStats(uint64_t *released, uint64_t *byFault, uint64_t *byForget, uint64_t *byTouch, uint64_t *mismatched, uint64_t *page,
                        uint64_t *orphanedPages, uint64_t *orphanWritten, uint64_t *orphanRead) {
	*released = atomic_load(&releasedPages); *byFault = atomic_load(&restoredByFault); *byForget = atomic_load(&restoredByForget); *byTouch = atomic_load(&restoredByTouch);
	*orphanedPages = atomic_load(&orphaned); *orphanWritten = atomic_load(&orphanWrites); *orphanRead = atomic_load(&orphanReads);
	*mismatched = atomic_load(&mismatches); *page = pageSize;
}
int PGMeshReleaseOn(void) { return enabled == 1; }
// Whether the engine page at this offset is handed back (protected): diagnostics that read engine memory skip it, or
// they would put it back (GTA-217: the memory breakdown's shader scan did, 26,000 pages at once).
int PGMeshPageHandedBack(uint64_t offset) { return enabled == 1 && state && offset < capacity && atomic_load(&state[offset / pageSize]) != NORMAL; }
