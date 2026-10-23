#include "HostInternal.h"
#include <dirent.h>
#include <sys/stat.h>
static uint64_t pg_mod_test_entry,pg_mod_test_value;
static _Atomic int pg_mods_reported_missing;
static void pg_mod_test_recheck(void);
#include "wasm-rt-impl.h"
#include "engine-functions.h" // PG_FN_*: engine functions by name (Scripts/engine_names.py)
#include <pthread.h>
#include "NativeEngineConfiguration.h"
#include "NativeControllerLook.h"
#include "NativeTouchContext.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>
#include <math.h>
#include <sys/mman.h>
#include <TargetConditionals.h>
#include <os/proc.h>
#include <mach/mach.h>
#include "NativeMemoryBudget.h"
#if TARGET_OS_MACCATALYST
#include <sys/sysctl.h>
#endif

// The memory the app may still use before the system stops it (iOS's Jetsam limit). macOS has no such
// limit, so the Mac app gives itself one, by default 60% of the Mac's memory (PG_STREAM_MEMORY_LIMIT_MB
// overrides), and every budget built on the iPhone limit works the same there (GTA-9).
uint64_t PGProcessAvailableMemory(void) {
#if TARGET_OS_MACCATALYST
  static uint64_t limit;
  if (!limit) {
    const char *configured = getenv("PG_STREAM_MEMORY_LIMIT_MB");
    long mb = configured ? atol(configured) : 0;
    uint64_t ram = 0; size_t size = sizeof ram;
    sysctlbyname("hw.memsize", &ram, &size, NULL, 0);
    limit = mb >= 2048 ? (uint64_t)mb << 20 : ram / 10 * 6;
    if (limit < (4096ull << 20)) limit = 4096ull << 20;
  }
  task_vm_info_data_t info = {}; mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
  if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&info, &count) != KERN_SUCCESS) return 0;
  return limit > info.phys_footprint ? limit - info.phys_footprint : 0;
#else
  return os_proc_available_memory();
#endif
}

static struct w2c_env env;
static struct w2c_wasi__snapshot__preview1 wasi = { .env = &env };
static PGLogCallback logCallback;
static void *logContext;
static char *manifestPath;
static char missingImport[256];
static _Atomic uint64_t inputBlock;
static int configuredWidth=960,configuredHeight=540,configuredFrameLimit=2;
// Start mode for the engine's loading-screen choice (WasmInputBlock.startMode):
// 1 Story Mode, 2 Sandbox Mode on the GTA V map. Read by f569 (game_36.c).
static int configuredStartMode=2;
static _Atomic uint64_t audioRing;
static _Atomic uint32_t audioCapacity;
static _Atomic bool started;
static bool benchmarkEnabled(void) { const char *value=getenv("PG_BENCHMARK");return value&&atoi(value)!=0; }
void pg_record_memory_fault(unsigned long long address,unsigned long long bytes,unsigned long long limit) {
 char line[240];snprintf(line,sizeof line,"Native heap access fault: address 0x%llx, bytes %llu, memory limit %llu",address,bytes,limit);pg_log(line);
}

// Lines from before the engine starts (the Settings preloader configures the assets and Mods early)
// wait here for the log.
static char earlyLines[32][256];
static int earlyCount;
static void pg_log_line(const char *message) {
  fprintf(stderr, "[native-port] %s\n", message);
  if (logCallback) logCallback(message, logContext);
  else if (earlyCount < 32) snprintf(earlyLines[earlyCount++], sizeof earlyLines[0], "%s", message);
}
// Engine lines arrive from several threads. A bare severity prefix (an engine message that
// formatted to nothing) is dropped, and a run of identical lines is written once with a count,
// so a long session's log keeps what happened instead of thousands of copies.
static pthread_mutex_t logLock = PTHREAD_MUTEX_INITIALIZER;
static char lastLogLine[512];
static uint64_t lastLogRepeats;
// The engine's memory pools, from its own "[wasm] region 0x... +N MB" lines: PGLogMemoryPools measures
// how much of each iOS really holds (mincore), to see where the memory goes.
static struct { uint64_t base, bytes; } engineRegions[64];
static _Atomic int engineRegionCount;
static void pg_note_region(const char *message) {
  unsigned long long base = 0, mb = 0;
  if (sscanf(message, "[wasm] region 0x%llx +%llu MB", &base, &mb) != 2) return;
  int i = atomic_fetch_add(&engineRegionCount, 1);
  if (i < 64) { engineRegions[i].base = base; engineRegions[i].bytes = mb << 20; } else atomic_store(&engineRegionCount, 64);
}
static void pg_note_engine_memory(const char *line);
static void pg_note_pool_failure(void);
void pg_log(const char *message) {
  if (!strncmp(message, "[wasm] region 0x", 16)) pg_note_region(message);
  if (!strncmp(message, "[wasm] mem: malloc arena ", 25)) pg_note_engine_memory(message);	// the address-space guard (GTA-70)
  if (strstr(message, "Failed to allocation virtual memory")) pg_note_pool_failure();	// the pool's free space is in pieces (GTA-128)
  // Script mods like Simple Trainer query interior entity sets every frame, and the engine prints each find:
  // hundreds of thousands of lines that filled the 50 MB log (GTA-135). Count them instead.
  if (!strncmp(message, "[scene] <ENTITY SET FOUND", 25)) {
    static _Atomic uint64_t entitySetLines;
    uint64_t n = atomic_fetch_add(&entitySetLines, 1);
    if (!(n & (n + 1)) && n >= 1023) { char line[128]; snprintf(line, sizeof line, "[scene] %llu \"ENTITY SET FOUND\" lines so far, left out of the log", (unsigned long long)n + 1); pg_log(line); }
    return;
  }
  size_t length = strlen(message);
  while (length && (message[length-1] == '\n' || message[length-1] == ' ')) length--;
  if (!length || (length == 6 && !memcmp(message, "Error:", 6)) || (length == 8 && !memcmp(message, "Warning:", 8)) ||
      (length == 12 && !memcmp(message, "Fatal Error:", 12))) return;
  pthread_mutex_lock(&logLock);
  if (length < sizeof lastLogLine && !strncmp(message, lastLogLine, sizeof lastLogLine)) { lastLogRepeats++; pthread_mutex_unlock(&logLock); return; }
  if (lastLogRepeats) {
    char line[96]; snprintf(line, sizeof line, "(previous line repeated %llu more times)", (unsigned long long)lastLogRepeats);
    pg_log_line(line); lastLogRepeats = 0;
  }
  snprintf(lastLogLine, sizeof lastLogLine, "%s", message);
  pg_log_line(message);
  pthread_mutex_unlock(&logLock);
}

void pg_missing_import(const char *name) {
  snprintf(missingImport, sizeof(missingImport), "%s", name);
  char message[384];
  snprintf(message, sizeof(message), "Engine stopped at unported host function: %s", name);
  pg_log(message);
  wasm_rt_trap(WASM_RT_TRAP_UNREACHABLE);
}

// Emscripten's longjmp, used by libjpeg's error exit among others: the engine records where to
// jump (setThrew) and throws, and the innermost invoke_* import catches the throw, as emscripten's
// JavaScript does with try/catch. Each invoke_* keeps a native jump point (Scripts/prepare_longjmp.py);
// this returns there, and the engine code after that invoke finds its setjmp target on its own.
// It used to stop the game, so a photo whose JPEG could not be read ended the game (GTA-21).
_Thread_local pg_invoke_frame *pg_invoke_top;
void w2c_env_0x5Femscripten_throw_longjmp(struct w2c_env *host) {
  pg_invoke_frame *frame = pg_invoke_top;
#if TARGET_OS_SIMULATOR
  if (getenv("PG_TEST_NO_LONGJMP")) frame = NULL; // reproduces the old behaviour
#endif
  if (!frame) pg_missing_import("env._emscripten_throw_longjmp");
  static _Atomic int logged;
  if (atomic_fetch_add(&logged, 1) < 20) pg_log("The engine handled an error with longjmp; the game continues.");
  _longjmp(frame->jump, 1);
}
// Where fiDeviceMemory::Create finds the address in "memory:$0x...,size,flags:name"
// (Scripts/prepare_memory_file_create.py): after "memory:$" and the "0x" this build's %p writes,
// as fiDeviceMemory::Open does. Without it a photo's JPEG was written to address 0 (GTA-21).
#if TARGET_OS_SIMULATOR
static _Atomic uint64_t pgTestLastMemoryFile; // PG_TEST_PHOTO=corrupt: where the last one starts
#endif
u64 pg_memory_file_address_start(w2c_game *instance, u64 name) {
#if TARGET_OS_SIMULATOR
  if (getenv("PG_TEST_OLD_MEMORY_FILE")) return 8; // reproduces the old behaviour
  atomic_store(&pgTestLastMemoryFile, strtoull(pg_string(&env, name + 8), NULL, 16));
#endif
  return *(const char *)pg_pointer(&env, name + 9, 1) == 'x' ? 10 : 8;
}

void *pg_pointer(struct w2c_env *host, uint64_t address, uint64_t size) {
  wasm_rt_shared_memory_t *memory=w2c_env_memory(host);
  if (address > memory->size || size > memory->size - address)
    wasm_rt_trap(WASM_RT_TRAP_OOB);
  return (uint8_t *)(void *)memory->data + address;
}

const char *pg_string(struct w2c_env *host, uint64_t address) {
  const char *s = pg_pointer(host, address, 1);
  if (!memchr(s, 0, w2c_env_memory(host)->size - address)) wasm_rt_trap(WASM_RT_TRAP_OOB);
  return s;
}

wasm_rt_shared_memory_t *w2c_env_memory(struct w2c_env *host) { return &env.memory; }
// The engine's memory for host code that reads its tables (NativeStreamingHealth.c).
const uint8_t *pg_engine_memory(uint64_t *size) { *size = env.memory.size; return env.memory.data; }
uint64_t pg_engine_memory_capacity(void) { return env.memory.max_pages * env.memory.page_size; }
static double timeMS(clockid_t clock) {
  struct timespec time;
  clock_gettime(clock, &time);
  return time.tv_sec * 1000.0 + time.tv_nsec / 1000000.0;
}
f64 w2c_env_emscripten_get_now(struct w2c_env *host) { return timeMS(CLOCK_MONOTONIC); }
f64 w2c_env_wasm_now_ms(struct w2c_env *host) { return timeMS(CLOCK_REALTIME); }
f64 w2c_env_emscripten_date_now(struct w2c_env *host) { return timeMS(CLOCK_REALTIME); }
u64 w2c_env_emscripten_get_heap_max(struct w2c_env *host) { wasm_rt_shared_memory_t *memory=w2c_env_memory(host);return memory->max_pages*memory->page_size; }
static bool nativeMemoryGuard;
static _Atomic uint64_t memoryBudgetClamps,memoryBudgetEvictions,memoryBudgetQueries,memoryBudgetNudges;
uint64_t PGMemoryBudgetQueries(void){return atomic_load(&memoryBudgetQueries);}
// Times the guard stopped streaming from growing, and times it asked the engine to evict.
uint64_t PGMemoryBudgetClamps(void){return atomic_load(&memoryBudgetClamps);}
// Memory the engine frees, back to iOS (GTA-34, Scripts/prepare_heap_return.py). A freed buddy block
// keeps counting against the app's limit until it is reused; its whole pages are marked reusable (as
// Apple's malloc does) and marked in use again when a block is handed out. PG_HEAP_RETURN=0 turns it off.
u64 PG_FN_BUDDY_GET_SIZE(w2c_game*, u64, u64);
static int heapReturn=-1;
static _Atomic uint64_t heapReturnedBytes,heapReturnedBlocks;
static bool heapReturnOn(void){
 if(heapReturn<0){const char *v=getenv("PG_HEAP_RETURN");heapReturn=!(v&&!strcmp(v,"0"));
  if(heapReturn)pg_log("Engine memory: freed blocks go back to iOS.");}
 return heapReturn;
}
void pg_buddy_free(w2c_game *instance,u64 allocator,u64 block){
 if(!block||!heapReturnOn())return;
 const uint64_t page=16384,size=PG_FN_BUDDY_GET_SIZE(instance,allocator,block);
 if(size<65536||block+size>env.memory.size)return;
 uint64_t b=(block+page-1)&~(page-1),e=(block+size)&~(page-1);
 if(e<=b)return;
 if(madvise(env.memory.data+b,(size_t)(e-b),MADV_FREE_REUSABLE)==0){atomic_fetch_add(&heapReturnedBytes,e-b);atomic_fetch_add(&heapReturnedBlocks,1);}
}
void pg_buddy_allocated(w2c_game *instance,u64 block,u64 size){
 (void)instance;
 if(!block||!size||heapReturn!=1)return;
 const uint64_t page=16384;
 uint64_t b=block&~(page-1),e=(block+size+page-1)&~(page-1);
 if(e>env.memory.size)e=env.memory.size;
 if(e>b)madvise(env.memory.data+b,(size_t)(e-b),MADV_FREE_REUSE);
}
// Defragment moves blocks without Allocate: the allocator's whole heap (base +8, size +24) in use first.
void pg_buddy_defragment(w2c_game *instance,u64 allocator){
 (void)instance;
 if(heapReturn!=1||allocator+32>env.memory.size)return;
 uint64_t base,size;memcpy(&base,env.memory.data+allocator+8,8);memcpy(&size,env.memory.data+allocator+24,8);
 if(!size||base+size>env.memory.size)return;
 madvise(env.memory.data+base,(size_t)size,MADV_FREE_REUSE);
 static bool logged;if(!logged){logged=true;pg_log("Engine memory: the engine defragments a pool (marked in use first).");}
}
// Resident memory per engine pool region and in the rest of the engine heap, plus the D3D layer's
// CPU copies of dynamic buffers (bytes, count, peak at 8324208/16/24).
void PGLogMemoryPools(void){
 uint8_t *data=env.memory.data;uint64_t size=env.memory.size;
 if(!data||!size)return;
 const uint64_t page=16384;
 int n=atomic_load(&engineRegionCount);if(n>64)n=64;
 char line[1024];int at=snprintf(line,sizeof line,"Engine memory held:");
 uint64_t inRegions=0;
 for(int i=0;i<n;i++){
  uint64_t b=engineRegions[i].base&~(page-1),e=engineRegions[i].base+engineRegions[i].bytes;
  if(e>size)e=size; if(b>=e)continue;
  size_t pages=(size_t)((e-b+page-1)/page);char *vec=malloc(pages);if(!vec)continue;
  uint64_t held=0;
  if(mincore(data+b,(size_t)(e-b),vec)==0)for(size_t k=0;k<pages;k++)if(vec[k]&(MINCORE_INCORE|MINCORE_PAGED_OUT))held+=page;
  free(vec);inRegions+=held;
  if(at<(int)sizeof line-48)at+=snprintf(line+at,sizeof line-at," %lluMB@%llx=%llu",(unsigned long long)(engineRegions[i].bytes>>20),(unsigned long long)engineRegions[i].base,(unsigned long long)(held>>20));
 }
 // The whole heap, to get what lies outside the pools (the engine's general allocations).
 uint64_t total=0;size_t pages=(size_t)(size/page);char *vec=malloc(pages);
 if(vec&&mincore(data,(size_t)(pages*page),vec)==0)for(size_t k=0;k<pages;k++)if(vec[k]&(MINCORE_INCORE|MINCORE_PAGED_OUT))total+=page;
 free(vec);
 uint64_t cpuCopies=0,copies=0,peak=0;
 if(8324232<=size){memcpy(&cpuCopies,data+8324208,8);memcpy(&copies,data+8324216,8);memcpy(&peak,data+8324224,8);}
 if(at<(int)sizeof line-160)snprintf(line+at,sizeof line-at," | pools %lluMB, rest %lluMB, all %lluMB | D3D CPU copies %lluMB (%llu, peak %lluMB) | returned to iOS %lluMB in %llu frees",(unsigned long long)(inRegions>>20),(unsigned long long)((total>inRegions?total-inRegions:0)>>20),(unsigned long long)(total>>20),(unsigned long long)(cpuCopies>>20),(unsigned long long)copies,(unsigned long long)(peak>>20),(unsigned long long)(atomic_load(&heapReturnedBytes)>>20),(unsigned long long)atomic_load(&heapReturnedBlocks));
 pg_log(line);
}
uint64_t PGMemoryBudgetEvictions(void){return atomic_load(&memoryBudgetEvictions);}
static uint64_t simulatedProcessLimit;
uint64_t PGGPUTextureBytes(void);
static uint64_t processLimitMB; // the app's memory limit at boot, or the player's cap (0 in the simulator)
// Settings › Memory cap (0 automatic): the game behaves as if iOS allowed only this much.
static uint64_t memoryCapMB, capReserveBytes;
// The engine's own address space (its 4 GB reservation) runs out before the phone's memory on phones
// with a 6-8 GB limit: v1.4 hands freed engine pages back to iOS, so the process headroom looked huge
// while the engine heap filled its reservation, and the game aborted on a failed allocation ("Read
// request ... destination addresses, some of which are NULL", "zstd ... not enough memory"; 25 of 63
// v1.4 logs, 2026-10-17). The engine reports its malloc use about every 10 s ("[wasm] mem: malloc arena
// A MB (in use U MB)"); headroom is the reservation minus that use, plus anything the heap grew since.
static _Atomic uint64_t engineInUseBytes, engineSizeAtSample;
static _Atomic bool engineLimited;		// the address space holds streaming back while the phone has memory to spare
// The resource pool, where streamed textures and models live, grows in 256 MB regions up to 2 GB and keeps
// them: once it has peaked, malloc counts a mostly empty pool as used ("resource virtual 586/2048 MB" with
// 3655 of 4095 MB in use, log 982), the guard sees ~400 MB of room and holds streaming, and the ground
// turns grey after a while (GTA-128). PG_GUARD_POOL_ROOM=1 counts the pool's free space as room too, less
// one region for its pieces, and not for a minute after the engine reports it couldn't place a block
// ("Failed to allocation virtual memory ... Largest Free Block 0", log 991). On by default since v1.4.3.
static _Atomic uint64_t poolFreeBytes;
static _Atomic double poolFailedAt=-1e9;
static void pg_note_pool_failure(void){atomic_store(&poolFailedAt,timeMS(CLOCK_MONOTONIC));}
static void pg_note_engine_memory(const char *line){
 const char *at=line;
 double arena=0,inUse=0,gameUsed=0,gameSize=0,poolUsed=0,poolSize=0;
 int fields=sscanf(at,"[wasm] mem: malloc arena %lf MB (in use %lf MB), game virtual %lf/%lf MB, resource virtual %lf/%lf MB",&arena,&inUse,&gameUsed,&gameSize,&poolUsed,&poolSize);
 if(fields<2||inUse<=0)return;
 atomic_store(&engineSizeAtSample,env.memory.size);
 atomic_store(&engineInUseBytes,(uint64_t)(inUse*1048576.0));
 atomic_store(&poolFreeBytes,fields==6&&poolSize>poolUsed?(uint64_t)((poolSize-poolUsed)*1048576.0):0);
}
static uint64_t engineAddressHeadroom(void){
 // Until the engine's first report there's no limit: the heap starts at 3328 MB, mostly unused.
 uint64_t inUse=atomic_load(&engineInUseBytes);if(!inUse)return UINT64_MAX;
 uint64_t capacity=env.memory.max_pages*env.memory.page_size,size=env.memory.size;
 uint64_t sampled=atomic_load(&engineSizeAtSample),used=inUse+(size>sampled?size-sampled:0);if(used>size)used=size;
 uint64_t room=capacity>used?capacity-used:0;
 // On by default since v1.4.3 (Kevin, 2026-10-20); PG_GUARD_POOL_ROOM=0 turns it off.
 static int poolRoom=-1;if(poolRoom<0){const char *v=getenv("PG_GUARD_POOL_ROOM");poolRoom=!(v&&atoi(v)==0);}
 const uint64_t region=256ull<<20,pool=atomic_load(&poolFreeBytes);
 // Only while the engine still has a whole region of address space of its own (GTA-145): the pool's free space
 // comes in pieces (log 1137: 790 MB free, largest piece 8 MB), and a block too big for them needs a new region.
 // With 112 MB really left the pieces counted as 534 MB more room, streaming went on, and a 37 MB block was fatal.
 if(poolRoom&&room>=region&&pool>region&&timeMS(CLOCK_MONOTONIC)-atomic_load(&poolFailedAt)>60000)room+=pool-region;
 return room;
}
static bool nativeProcessHeadroom(uint64_t *headroom){
 if(!nativeMemoryGuard)return false;
 atomic_fetch_add(&memoryBudgetQueries,1);
 uint64_t available;
#if TARGET_OS_SIMULATOR
 // Simulator has no iOS Jetsam ceiling. Use an explicit simulated process limit.
 if(!simulatedProcessLimit)return false;
 task_vm_info_data_t info={};mach_msg_type_number_t count=TASK_VM_INFO_COUNT;
 if(task_info(mach_task_self(),TASK_VM_INFO,(task_info_t)&info,&count)!=KERN_SUCCESS)return false;
 // Textures live in the Mac's GPU memory here, outside the footprint; on an iPhone they count against the limit.
 uint64_t footprint=info.phys_footprint+PGGPUTextureBytes();
 available=simulatedProcessLimit>footprint?simulatedProcessLimit-footprint:0;
#else
 available=PGProcessAvailableMemory();
 available=available>capReserveBytes?available-capReserveBytes:0;
#endif
 uint64_t engine=engineAddressHeadroom();
 // The fast nudges (guardNudge) are for phones with memory to spare beyond the engine's room (8 GB:
 // about 2 GB more). On 5-6 GB phones the two sit within ~100 MB of each other (v1.4.1 logs: median
 // 78 MB), so the engine mode fired there too and threw textures out ~12x faster than v1.4 (GTA-117).
 // PG_GUARD_SPARE_MB is that margin (512 in the A/B); 0, the default until a device A/B, keeps v1.4.1's rule.
 static uint64_t spare=UINT64_MAX;
 if(spare==UINT64_MAX){const char *v=getenv("PG_GUARD_SPARE_MB");long mb=v?atol(v):0;spare=(uint64_t)(mb>0&&mb<=4096?mb:0)<<20;}
 atomic_store(&engineLimited,engine<available&&available-engine>spare);
 if(engine<available){
  available=engine;
  static _Atomic double loggedAt;double now=timeMS(CLOCK_MONOTONIC);
  if(now-atomic_load(&loggedAt)>60000){atomic_store(&loggedAt,now);
   char line[128];snprintf(line,sizeof line,"Memory guard: the engine's address space is the limit (%llu MB left).",(unsigned long long)(engine>>20));pg_log(line);}
 }
 *headroom=available;
 return true;
}
// The guard's reserve (below it the engine evicts) and band (above reserve+band streaming grows):
// 384 and 256 MB. PG_GUARD_RESERVE_MB and PG_GUARD_BAND_MB change them, for tests and the Lite build.
static uint64_t guardReserve(void){
 static uint64_t value;
 if(!value){const char *v=getenv("PG_GUARD_RESERVE_MB");long mb=v?atol(v):0;value=(uint64_t)(mb>=128&&mb<=1024?mb:384)<<20;}
 return value;
}
static uint64_t guardBand(void){
 static uint64_t value;
 // Ultra Performance (PG_LITE) uses 64 MB: it sits around 600 MB free, so the 256 MB band (growth stops
 // below reserve + band = 640 MB) held every detail load and far areas stayed "clay" (GTA-38). Simulator,
 // 2348 MB, one teleport then 90 s: band 256 clay (no ground), 128 partly, 64 fully detailed; same FPS,
 // 3-7 evictions, 449 MB still free. The normal preset keeps 256 (it thrashed with smaller bands).
 if(!value){const char *v=getenv("PG_GUARD_BAND_MB"),*lite=getenv("PG_LITE");long mb=v?atol(v):0;
  value=(uint64_t)(mb>=16&&mb<=1024?mb:lite&&strcmp(lite,"0")?64:256)<<20;}
 return value;
}
// The player's weapon must load even when memory is tight: with the guard holding, the selected gun's
// model never streamed in, so it was invisible and unusable (GTA-55; simulator at 2098 MB: weapon
// object 0 for a minute). While the player has a weapon selected on foot with no weapon object
// (pg_keep_weapon_loaded), the guard gives streaming 64 MB of room.
static _Atomic double weaponGrantUntil;
static int64_t weaponGrant(int64_t result){
 const int64_t room=64ll<<20;
 if(result>=room||timeMS(CLOCK_MONOTONIC)>atomic_load(&weaponGrantUntil))return result;
 return room;
}
uint64_t pg_streaming_available_memory(uint64_t engineAvailable){
 uint64_t available;
 if(!nativeProcessHeadroom(&available))return engineAvailable;
 uint64_t result=pg_streaming_headroom_budget(engineAvailable,available,guardReserve(),guardBand());
 int64_t granted=weaponGrant((int64_t)result);
 return granted>(int64_t)result&&(uint64_t)granted<=engineAvailable?(uint64_t)granted:result;
}
// The engine heap has its own ceiling (the reservation), below the process limit on phones that
// allow more memory. Once it refuses to grow, streaming more only loops on failed allocations
// (input then stalls), so for a while after a refusal streaming stops growing, and right after
// one it evicts. Process headroom never sees this: the phone still has memory free.
extern _Atomic uint64_t pgHeapRefusedAt;
static int64_t heapCeilingBudget(int64_t result){
 uint64_t bits=atomic_load(&pgHeapRefusedAt);if(!bits)return result;
 double refusedAt;memcpy(&refusedAt,&bits,8);
 struct timespec now;clock_gettime(CLOCK_MONOTONIC,&now);double since=now.tv_sec+now.tv_nsec/1e9-refusedAt;
 if(since<2)return result<-(int64_t)(64ull<<20)?result:-(int64_t)(64ull<<20);
 if(since<30)return result<0?result:0;
 return result;
}
// A hold that lasts (free memory inside the band: growth stopped, nothing evicted) also stops the
// engine from dropping what the player left behind, so new areas never load their detailed models
// and textures ("sea of clay", GTA-38). After 1.5 s of holding, the engine is asked to free a small
// slice, which its own cleanup takes from objects no longer needed; loading then resumes.
// PG_GUARD_NUDGE_MB sets the slice (default 16, 0 turns it off).
// During a load scene (respawn, warp, story transition) everything at the old place is dead weight and
// the player waits: holds made respawns take minutes (GTA-50), so the nudge comes after 0.25 s and frees
// 96 MB at a time.
static _Atomic double loadSceneSince;		// CLOCK_MONOTONIC ms when a load scene started, 0 none
int PGLoadSceneSeconds(void){
 double since=atomic_load(&loadSceneSince);if(since==0)return 0;
 double s=(timeMS(CLOCK_MONOTONIC)-since)/1000;
 if(s>180){atomic_store(&loadSceneSince,0);return 0;}		// a stop line that never came
 return (int)s;
}
static void pg_note_load_scene(const char *line){
 if(strstr(line,"Starting new load scene")||strstr(line,"calling LoadScene.Start()")||strstr(line,"Awaiting LoadScene.IsLoaded()")){
  double none=0;atomic_compare_exchange_strong(&loadSceneSince,&none,timeMS(CLOCK_MONOTONIC));
 }else if(strstr(line,"LoadScene.Stop()")||strstr(line,"NEW_LOAD_SCENE_STOP")){
  double since=atomic_exchange(&loadSceneSince,0);
  if(since>0&&timeMS(CLOCK_MONOTONIC)-since>3000){char out[96];snprintf(out,sizeof out,"Load scene finished after %.1f s.",(timeMS(CLOCK_MONOTONIC)-since)/1000);pg_log(out);}
 }
}
static int64_t guardNudge(int64_t result){
 static int64_t slice=-1;static _Atomic double holdingSince;
 if(slice<0){const char *v=getenv("PG_GUARD_NUDGE_MB");long mb=v?atol(v):16;slice=(int64_t)(mb>=0&&mb<=256?mb:16)<<20;}
 if(result!=0||!slice){atomic_store(&holdingSince,0);return result;}
 struct timespec now;clock_gettime(CLOCK_MONOTONIC,&now);double t=now.tv_sec+now.tv_nsec/1e9;
 double since=atomic_load(&holdingSince);
 if(since==0){atomic_store(&holdingSince,t);return result;}
 const bool loading=atomic_load(&loadSceneSince)>0;
 // Held by the engine's address space (GTA-70): the phone has memory, so making room is cheap and a new
 // area must still load; in the simulator 16 MB every 1.5 s left a teleport's new area empty.
 const bool engine=atomic_load(&engineLimited);
 if(t-since<(loading?0.25:engine?0.5:1.5))return result;
 atomic_store(&holdingSince,t);atomic_fetch_add(&memoryBudgetNudges,1);
 if(loading)return -(slice>(96ll<<20)?slice:(96ll<<20));
 return engine?-(slice>(64ll<<20)?slice:(64ll<<20)):-slice;
}
uint64_t pg_streaming_resource_memory(uint64_t engineAvailable){
 uint64_t available;
 int64_t result=(int64_t)engineAvailable;
 if(nativeProcessHeadroom(&available))result=weaponGrant(guardNudge(pg_streaming_resource_budget((int64_t)engineAvailable,available,guardReserve(),guardBand())));
 if(result>(int64_t)engineAvailable)result=(int64_t)engineAvailable;
 result=heapCeilingBudget(result);
 if(result<(int64_t)engineAvailable&&result<=0)atomic_fetch_add(result<0?&memoryBudgetEvictions:&memoryBudgetClamps,1);
 return (uint64_t)result;
}
// The engine heap's reservation: the limit less 1 GB, at least 4095 MB and at most 7168 MB. The engine runs out of
// address space long before the phone runs out of memory: in every player log where the heap refused to grow
// (2026-10-22, 102 logs), the app still had about 2 GB (5 GB limits) to 3.2 GB (6.6 GB limits) to 4 GB+ (8 GB
// limits) free at that moment, because the engine hands freed pages back to iOS. The old rule (4095 MB below a
// 7.7 GB limit, else the limit less 3 GB) left that unused. The memory guard still holds streaming before the
// process limit, with the textures counted; if iOS won't reserve this much (no extended-address entitlement),
// the reservation steps down (the fallback steps where it is mapped).
void PGSetMemoryCap(int mb) { if (!atomic_load(&started)) memoryCapMB = mb > 0 ? (uint64_t)mb : 0; }
static uint64_t pg_engine_memory_mb(void){
 const char *configured=getenv("PG_ENGINE_MEMORY_MB");
 if(configured){long mb=atol(configured);if(mb>=1024&&mb<=8192)return (uint64_t)mb;}
#if !TARGET_OS_SIMULATOR
 task_vm_info_data_t info={};mach_msg_type_number_t count=TASK_VM_INFO_COUNT;
 if(task_info(mach_task_self(),TASK_VM_INFO,(task_info_t)&info,&count)==KERN_SUCCESS){
  uint64_t limitMB=(PGProcessAvailableMemory()+info.phys_footprint)>>20;
  if(memoryCapMB&&memoryCapMB<limitMB){
   capReserveBytes=(limitMB-memoryCapMB)<<20; // headroom the guard leaves unused
   char line[96];snprintf(line,sizeof line,"Memory cap: %llu MB of the %llu MB limit.",(unsigned long long)memoryCapMB,(unsigned long long)limitMB);pg_log(line);
   limitMB=memoryCapMB;
  }
  processLimitMB=limitMB;
  if(limitMB>4095+1024)return limitMB-1024<7168?limitMB-1024:7168;
 }
#endif
 return 4095;
}
// The adapter's video memory as the engine reads it (Scripts/prepare_video_memory.py). The
// browser build reports about 4 GB on every device, so the engine streams textures as if a phone
// had 4 GB of video memory to spare. On GPUs that decode BC textures they also take about 4 times
// what the engine counts. Memory then fills within minutes and the streaming guard throttles the
// game for the rest of the session (the slowdown players report). The budget is what the limit
// leaves after about 1.8 GB for the rest of the game and the guard's reserve, divided by what the
// textures take on this GPU per counted byte (PGTextureRatioPercent: measured in earlier sessions,
// GTA-123; it was a fixed halving).
int PGGPUReadsBC(void);
int PGTextureRatioPercent(void);
u64 pg_video_memory(u64 reported){
 uint64_t mb=0;
 const char *configured=getenv("PG_VIDEO_MEMORY_MB");
 if(configured)mb=(uint64_t)atol(configured);
 else if(processLimitMB){
  uint64_t textures=processLimitMB>1800+640?processLimitMB-1800:640;
  mb=textures*100/(uint64_t)PGTextureRatioPercent();
  if(mb<640)mb=640;
 }
 if(!mb||(mb<<20)>=reported)return reported;
 char line[200];snprintf(line,sizeof line,"Video memory for the engine: %llu MB (memory limit %llu MB, textures x%.2f, %s).",(unsigned long long)mb,(unsigned long long)processLimitMB,PGTextureRatioPercent()/100.0,PGGPUReadsBC()?"GPU reads BC textures":"BC textures decoded");pg_log(line);
 return mb<<20;
}
static u32 nativeEngineCores=2;
u32 w2c_env_emscripten_num_logical_cores(struct w2c_env *host) { return nativeEngineCores; }
void w2c_env_emscripten_check_blocking_allowed(struct w2c_env *host) {}
static _Atomic double saveLoadedAt = -1e9;		// when the engine last read a save's script data (cash guard below)
void w2c_env_wasm_print_line_js(struct w2c_env *host, u64 address) {
  const char *line = pg_string(host, address);
  if (line[0] == '[' && strstr(line, "ReadScriptTreesFromLoadedPso")) atomic_store(&saveLoadedAt, timeMS(CLOCK_MONOTONIC));
  pg_note_load_scene(line);
  pg_log(line);
}
void w2c_env_wasm_hang_line_js(struct w2c_env *host, u64 address) { pg_log(pg_string(host, address)); }
u32 w2c_env_wasm_has_page_js(struct w2c_env *host) { return 1; }
u32 w2c_env_wasm_userdata_page_js(struct w2c_env *host) { return 0; }
u32 w2c_env_wasm_module_int_js(struct w2c_env *host, u64 address, u32 fallback) {
  const char *key = pg_string(host, address);
  if (!strcmp(key, "lowMemory")) return 1;
  return fallback;
}
void w2c_env_0x5Femscripten_init_main_thread_js(struct w2c_env *host, u64 thread) {
  w2c_game_0x5Femscripten_thread_init(&host->game, thread, 0, 1, 1, 1048576, 0);
  w2c_game_0x5Femscripten_tls_init(&host->game);
}
void w2c_env_0x5Femscripten_thread_mailbox_await(struct w2c_env *host, u64 thread) {
  // The initial probe runs on a native blocking thread with no JS event loop.
}
void w2c_env_0x5Femscripten_thread_set_strongref(struct w2c_env *host, u64 thread) {}

static void writeTM(struct w2c_env *host, uint64_t at, const struct tm *time) {
  int32_t *out = pg_pointer(host, at, 48);
  out[0] = time->tm_sec; out[1] = time->tm_min; out[2] = time->tm_hour;
  out[3] = time->tm_mday; out[4] = time->tm_mon; out[5] = time->tm_year;
  out[6] = time->tm_wday; out[7] = time->tm_yday; out[8] = time->tm_isdst;
  *(int64_t *)((uint8_t *)out + 40) = time->tm_gmtoff;
}
u32 w2c_env_0x5Fgmtime_js(struct w2c_env *host, u64 seconds, u64 at) {
  time_t value = (int64_t)seconds;
  struct tm time;
  if (!gmtime_r(&value, &time)) return 1;
  writeTM(host, at, &time);
  return 0;
}
u32 w2c_env_0x5Flocaltime_js(struct w2c_env *host, u64 seconds, u64 at) {
  time_t value = (int64_t)seconds;
  struct tm time;
  if (!localtime_r(&value, &time)) return 1;
  writeTM(host, at, &time);
  return 0;
}
u64 w2c_env_0x5Fmktime_js(struct w2c_env *host, u64 at) {
  int32_t *in = pg_pointer(host, at, 36);
  struct tm time = {0};
  time.tm_sec = in[0]; time.tm_min = in[1]; time.tm_hour = in[2];
  time.tm_mday = in[3]; time.tm_mon = in[4]; time.tm_year = in[5];
  time.tm_isdst = in[8];
  time_t result = mktime(&time);
  if (result != -1) writeTM(host, at, &time);
  return (u64)result;
}
void w2c_env_0x5Ftzset_js(struct w2c_env *host, u64 zone, u64 daylight, u64 standardName, u64 daylightName) {
  tzset();
  time_t now = time(NULL);
  struct tm current, january = {0}, july = {0};
  localtime_r(&now, &current);
  january.tm_year = july.tm_year = current.tm_year;
  january.tm_mday = july.tm_mday = 1;
  january.tm_isdst = july.tm_isdst = -1;
  july.tm_mon = 6;
  mktime(&january); mktime(&july);
  const struct tm *standard = january.tm_gmtoff <= july.tm_gmtoff ? &january : &july;
  const struct tm *summer = standard == &january ? &july : &january;
  *(int64_t *)pg_pointer(host, zone, 8) = -standard->tm_gmtoff;
  *(int32_t *)pg_pointer(host, daylight, 4) = january.tm_gmtoff != july.tm_gmtoff;
  char *stdName = pg_pointer(host, standardName, 17);
  char *dstName = pg_pointer(host, daylightName, 17);
  snprintf(stdName, 17, "%s", standard->tm_zone ? standard->tm_zone : "UTC");
  snprintf(dstName, 17, "%s", summer->tm_zone ? summer->tm_zone : "UTC");
}

u32 w2c_env_wasm_httpfs_manifest_js(struct w2c_env *host, u64 address, u32 capacity) {
  const char *mods = pg_assets_manifest_override();		// Mods change file sizes (NativeAssets.m)
  FILE *file = fopen(mods ? mods : manifestPath, "rb");
  if (!file) return (u32)-1;
  fseek(file, 0, SEEK_END);
  long length = ftell(file);
  rewind(file);
  if (length < 0 || length >= UINT32_MAX) { fclose(file); return (u32)-1; }
  if (capacity > (uint32_t)length) {
    char *output = pg_pointer(host, address, length + 1);
    if (fread(output, 1, length, file) != (size_t)length) { fclose(file); return (u32)-1; }
    output[length] = 0;
  }
  fclose(file);
  return (u32)length;
}

extern const char *PGSelectedGameLanguage(void);
u32 w2c_env_emscripten_asm_const_int(struct w2c_env *host, u64 code, u64 sig, u64 arguments) {
  if (code == 7980558) {
    // Emscripten's language query is the only boot-time embedded JS expression.
    u64 destinationAddress = *(u64 *)pg_pointer(host, arguments, 8);
    u32 capacity = *(u32 *)pg_pointer(host, arguments + 8, 4);
    const char *language = PGSelectedGameLanguage();
    if (capacity) {
      char *destination = pg_pointer(host, destinationAddress, capacity);
      snprintf(destination, capacity, "%s", language);
    }
    return 0;
  }
  pg_missing_import("emscripten_asm_const_int: non-language expression");
  return 0;
}
u32 w2c_env_emscripten_asm_const_int_sync_on_main_thread(struct w2c_env *host, u64 code, u64 sig, u64 args) {
  return w2c_env_emscripten_asm_const_int(host, code, sig, args);
}

u32 w2c_wasi__snapshot__preview1_clock_time_get(struct w2c_wasi__snapshot__preview1 *host, u32 clock, u64 precision, u64 output) {
  if (clock > 3) return 28;
  struct timespec t;
  clock_gettime(clock == 0 ? CLOCK_REALTIME : CLOCK_MONOTONIC, &t);
  *(u64 *)pg_pointer(host->env, output, 8) = (u64)t.tv_sec * 1000000000 + t.tv_nsec;
  return 0;
}
u32 w2c_wasi__snapshot__preview1_environ_sizes_get(struct w2c_wasi__snapshot__preview1 *host, u64 count, u64 size) {
  *(u64 *)pg_pointer(host->env, count, 8) = 0;
  *(u64 *)pg_pointer(host->env, size, 8) = 0;
  return 0;
}
u32 w2c_wasi__snapshot__preview1_environ_get(struct w2c_wasi__snapshot__preview1 *host, u64 array, u64 buffer) { return 0; }
u32 w2c_wasi__snapshot__preview1_fd_write(struct w2c_wasi__snapshot__preview1 *host, u32 fd, u64 vectors, u64 count, u64 written) {
  return pg_file_io(host->env, fd, vectors, count, 0, written, true, false);
}

void w2c_env_wasm_input_publish_js(struct w2c_env *host, u64 block) {
  uint8_t *base = pg_pointer(host, block, 444);
  atomic_store((_Atomic int32_t *)(base + 256), configuredWidth / 2);
  atomic_store((_Atomic int32_t *)(base + 256 + 4), configuredHeight / 2);
  atomic_store((_Atomic int32_t *)(base + 256 + 6 * 4), 1);
  atomic_store((_Atomic int32_t *)(base + 256 + 7 * 4), 1);
  atomic_store((_Atomic int32_t *)(base + 424), -1);
  atomic_store((_Atomic int32_t *)(base + 432), configuredWidth);
  atomic_store((_Atomic int32_t *)(base + 436), configuredHeight);
  // The engine reads this word where it would ask for Story/Sandbox on the
  // loading screen. Benchmarks always use the release (story) startup.
  int startMode=benchmarkEnabled()?1:configuredStartMode;
  atomic_store((_Atomic int32_t *)(base + 440), startMode);
  pg_log(startMode==1?"Start mode: Story Mode (continues the newest save, or a new game from the Prologue).":startMode==3?"Start mode: Sandbox Mode on the test level (env_test).":"Start mode: Sandbox Mode on the GTA V map.");
  atomic_store(&inputBlock, block);
  pg_log("Native controller bridge attached to the game's input block.");
}
void w2c_env_wasm_audio_publish_js(struct w2c_env *host, u64 ring, u32 capacity) {
  if (!capacity || (capacity & (capacity - 1))) wasm_rt_trap(WASM_RT_TRAP_OOB);
  pg_pointer(host, ring, 64 + (u64)capacity * 8);
  atomic_store(&audioCapacity, capacity);
  atomic_store(&audioRing, ring);
  pg_log("Native stereo audio ring attached.");
}

// Read-only game-state snapshot for the touch layout (no script native is called from UIKit).
// Bits: 1 player control off (IS_PLAYER_CONTROL_ON == false, single player: the player info's
// control-disabled flags at *(ped+4328)+936), 2 phone on screen (a CPhoneMgr flag at 19505653 that
// CPhoneMgr::Render/Delete and the phone-model render phase use; set while the phone is up),
// 4 cutscene playing (IS_CUTSCENE_PLAYING, *(19339168)+3215), 8 warning screen
// (IS_WARNING_MESSAGE_ACTIVE: 19577926 or 19577929 bit 0), 16 no local player yet, 32 game paused (fwTimer's
// paused flag, 12321468, set by fwTimer::Update f8924: the pause menu, and screens like Mission failed that pause
// the game without taking player control away).
uint32_t PGGameStatus(void){
 if(!atomic_load(&inputBlock))return 16;
 const uint8_t *m=(const uint8_t *)(void *)env.memory.data;uint64_t size=env.memory.size;
 uint32_t bits=0;uint64_t info,ped,playerInfo,cutscene;uint32_t controls;
 if(pg_context_u64(m,size,20159720,&info)&&info&&pg_context_u64(m,size,info+8,&ped)&&ped&&
    pg_context_u64(m,size,ped+4328,&playerInfo)&&playerInfo&&pg_context_u32(m,size,playerInfo+936,&controls)){
  if(controls)bits|=1;
 }else bits|=16;
 #define PG_BYTE(address) atomic_load_explicit((const _Atomic uint8_t *)(m+(address)),memory_order_relaxed)
 if(size>19577930){
  if(PG_BYTE(12321468))bits|=32;
  if(PG_BYTE(19505653))bits|=2;
  if(PG_BYTE(19577926)||(PG_BYTE(19577929)&1))bits|=8;
 }
 if(pg_context_u64(m,size,19339168,&cutscene)&&cutscene&&cutscene<size-3216&&PG_BYTE(cutscene+3215))bits|=4;
 #undef PG_BYTE
 return bits;
}
// Touch control hints, from the pinned engine's memory (layouts traced in the disassembly of the
// pinned game.wasm). Every read is bounds-checked, so a torn or stale value can
// at worst show or hide a button for a frame.
static bool pg_context_u8(const uint8_t *m,uint64_t size,uint64_t address,uint8_t *value){
 if(!m||address>=size)return false;
 *value=atomic_load_explicit((const _Atomic uint8_t *)(m+address),memory_order_relaxed);return true;
}
static bool pg_context_f32(const uint8_t *m,uint64_t size,uint64_t address,float *value){
 uint32_t bits;if(!pg_context_u32(m,size,address,&bits))return false;memcpy(value,&bits,4);return true;
}
static bool pg_context_u16(const uint8_t *m,uint64_t size,uint64_t address,uint16_t *value){
 if(!m||size<2||address>size-2||(address&1))return false;
 *value=atomic_load_explicit((const _Atomic uint16_t *)(m+address),memory_order_relaxed);return true;
}
// CProjectileManager::CanExplodeTriggeredProjectiles (f82725): a sticky bomb of the player's that
// can be set off: up to 50 projectiles, each with owner, weapon hash and an armed flag.
static bool pg_can_detonate(const uint8_t *m,uint64_t size,uint64_t ped){
 uint32_t count;uint64_t table;uint16_t infos;
 if(!pg_context_u32(m,size,28498240,&count)||!pg_context_u64(m,size,28496576,&table)||!pg_context_u16(m,size,28496584,&infos)||!table)return false;
 if(count>50)count=50;
 for(uint32_t i=0;i<count;i++){
  uint64_t p,owner;uint32_t hash;uint8_t armed;
  if(!pg_context_u64(m,size,28497840+8ull*i,&p)||!p)continue;
  if(!pg_context_u64(m,size,p+1320,&owner)||owner!=ped)continue;
  if(!pg_context_u32(m,size,p+1312,&hash)||!hash)continue;
  // Binary search of the weapon infos by hash (key at +16).
  int lo=0,hi=(int)infos-1;uint64_t info=0;
  for(int steps=0;lo<=hi&&steps<20;steps++){
   int mid=(lo+hi)/2;uint64_t candidate;uint32_t key;
   if(!pg_context_u64(m,size,table+8ull*mid,&candidate)||!candidate||!pg_context_u32(m,size,candidate+16,&key))break;
   if(key==hash){info=candidate;break;}
   if(key<hash)lo=mid+1;else hi=mid-1;
  }
  uint8_t flags;
  if(info&&pg_context_u8(m,size,info+2255,&flags)&&(flags&4)&&pg_context_u8(m,size,p+1538,&armed)&&armed)return true;
 }
 return false;
}
// Set on the game thread by pg_trailer_tick (below), read with the other hints.
static _Atomic bool pg_trailer_attached;
PGControlHints PGReadControlHints(uint32_t touchContext){
 PGControlHints hints={0};
 if(!atomic_load(&inputBlock))return hints;
 const uint8_t *m=(const uint8_t *)(void *)env.memory.data;uint64_t size=env.memory.size;
 uint64_t info,ped;
 if(!pg_context_u64(m,size,20159720,&info)||!info||!pg_context_u64(m,size,info+8,&ped)||!ped)return hints;
 // Special ability (f46103, f41591, f41600, f41588): the ped's active ability slot.
 uint32_t slot;uint64_t ability,data,modelInfo;
 if(getenv("PG_DEBUG_HINTS")){
  static double lastChain;
  if(timeMS(CLOCK_MONOTONIC)-lastChain>10000){
   lastChain=timeMS(CLOCK_MONOTONIC);uint32_t rawSlot=99;uint64_t a0=0,a1=0;
   pg_context_u32(m,size,ped+5088,&rawSlot);pg_context_u64(m,size,ped+5072,&a0);pg_context_u64(m,size,ped+5080,&a1);
   char line[160];snprintf(line,sizeof line,"Hints debug: ped 0x%llx slot %u abilities 0x%llx 0x%llx",(unsigned long long)ped,rawSlot,(unsigned long long)a0,(unsigned long long)a1);pg_log(line);
  }
 }
 if(pg_context_u32(m,size,ped+5088,&slot)&&slot<2&&pg_context_u64(m,size,ped+5072+8ull*slot,&ability)&&ability&&
    pg_context_u64(m,size,ability,&data)&&data&&pg_context_u64(m,size,ped+32,&modelInfo)&&modelInfo){
  uint8_t enabled=0,active=0,unlocked=0;float current=0,maximum=0;uint32_t minimum=0,kind=0,model=0,michael=0,franklin=0,trevor=0;
  pg_context_u8(m,size,ability+106,&enabled);pg_context_u8(m,size,ability+107,&active);
  pg_context_f32(m,size,ability+52,&current);pg_context_f32(m,size,ability+60,&maximum);
  pg_context_u32(m,size,data+8,&minimum);pg_context_u32(m,size,data+60,&kind);
  pg_context_u32(m,size,modelInfo+24,&model);
  pg_context_u32(m,size,19625424,&michael);pg_context_u32(m,size,19625440,&franklin);pg_context_u32(m,size,19625456,&trevor);
  if(model&&model==michael)pg_context_u8(m,size,20197688,&unlocked);
  else if(model&&model==franklin)pg_context_u8(m,size,20197689,&unlocked);
  else if(model&&model==trevor)pg_context_u8(m,size,20197690,&unlocked);
  // kind -1: never; 0: only driving a car, quad or bike (Franklin); 1+: anywhere.
  bool driving=touchContext!=0&&touchContext!=2&&touchContext!=9&&touchContext!=10&&touchContext!=11&&touchContext!=13&&touchContext!=14&&touchContext!=16;
  bool usableHere=(int32_t)kind>=1||((int32_t)kind==0&&driving);
  // Debug (PG_DEBUG_HINTS=1): the raw values every 10 s, to check the layout on a new build.
  static double lastDebug;
  if(getenv("PG_DEBUG_HINTS")&&timeMS(CLOCK_MONOTONIC)-lastDebug>10000){
   lastDebug=timeMS(CLOCK_MONOTONIC);char line[240];
   snprintf(line,sizeof line,"Hints debug: slot %u ability 0x%llx enabled %u active %u kind %d min %u cur %.2f max %.2f model 0x%x michael 0x%x franklin 0x%x trevor 0x%x unlocked %u",
    slot,(unsigned long long)ability,enabled,active,(int32_t)kind,minimum,current,maximum,model,michael,franklin,trevor,unlocked);pg_log(line);
  }
  if((enabled&1)&&unlocked&&(int32_t)kind!=-1&&usableHere){
   hints.specialShown=true;
   hints.specialActive=active&1;
   hints.specialFill=maximum>0?fminf(1,fmaxf(0,current/maximum)):0;
   hints.specialReady=!hints.specialActive&&current>0&&floorf(current)>=3&&lroundf(current)>=(long)(int32_t)minimum;
  }
 }
 hints.canDetonate=pg_can_detonate(m,size,ped);
 hints.trailerAttached=atomic_load(&pg_trailer_attached);
 hints.selfRadioPlaying=PGSelfRadioAudible();
 uint64_t pedInfo;
 if(pg_context_u64(m,size,ped+32,&pedInfo)&&pedInfo)pg_context_u32(m,size,pedInfo+24,&hints.pedModel);
 // Help messages (CMessages, 3 slots of 600 bytes; "is help showing" is the first byte).
 uint8_t first=0;
 if(pg_context_u8(m,size,25477136,&first)&&first&&size>25477136+1800){
  hints.helpShown=true;
  const char *text=(const char *)(m+25477136);
  // D-pad right: also the script's own pad input, as in "Press ~INPUT_SCRIPT_PAD_RIGHT~ to pick up a container" (the
  // docks crane; 3 player logs had no button for it, report 953).
  static const char *const tokens[]={"INPUT_CONTEXT","INPUT_TALK","~INPUT_SCRIPT_PAD_RIGHT~"};
  for(int t=0;t<3&&!hints.helpContext;t++)if(memmem(text,1800,tokens[t],strlen(tokens[t])))hints.helpContext=true;
  // "Detonate the explosives using ~INPUT_DETONATE~": missions that plant the explosives themselves, so the player
  // has no sticky bombs of their own and canDetonate stays off (log 563, report 946).
  if(memmem(text,1800,"~INPUT_DETONATE~",16))hints.helpDetonate=true;
  // The script inputs the help names (GTA-94): "Hold ~INPUT_SCRIPT_RT~ to grip a tooth" asks for RT however the
  // script then reads it, which the poll check doesn't always see; the right stick by its group or either axis.
  // By the Book's next step, "Rotate ~PAD_RSTICK_ROTATE~ to pull it out.", names only the rotation, but RT has to stay
  // held while rotating (let go and it's back to "Hold RT"): it asks for both, so the RT button stays and keeps its
  // latch. The script D-pad (232-235) by its group or a direction: the torture tool cart says "Use
  // ~INPUTGROUP_SCRIPT_LSTICK_ALL~/~INPUTGROUP_SCRIPT_DPAD_ALL~ and ~INPUT_SCRIPT_RDOWN~" and reads the stick too, and
  // the touch arrows stay for it (harness, fbi3).
  // The left stick's axes: a TV couch's "Use ~INPUT_SCRIPT_LEFT_AXIS_X~ to change the channel" (the touch layout shows
  // arrows for it; Friend Request waits for a channel change, GTA-73).
  static const struct{const char *token;int input;}named[]={{"~INPUT_SCRIPT_LEFT_AXIS_X~",218},{"~INPUT_SCRIPT_LEFT_AXIS_Y~",219},{"~INPUT_SCRIPT_RIGHT_AXIS_X~",220},{"~INPUT_SCRIPT_RIGHT_AXIS_Y~",221},
    {"~INPUTGROUP_SCRIPT_RSTICK_ALL~",220},{"~INPUT_SCRIPT_RUP~",222},{"~INPUT_SCRIPT_RDOWN~",223},{"~INPUT_SCRIPT_RLEFT~",224},
    {"~INPUT_SCRIPT_RRIGHT~",225},{"~INPUT_SCRIPT_LB~",226},{"~INPUT_SCRIPT_RB~",227},{"~INPUT_SCRIPT_LT~",228},{"~INPUT_SCRIPT_RT~",229},
    {"~INPUT_SCRIPT_LS~",230},{"~INPUT_SCRIPT_RS~",231},{"~PAD_RSTICK_ROTATE~",220},{"~PAD_RSTICK_ROTATE~",229},
    {"~INPUTGROUP_SCRIPT_DPAD_ALL~",232},{"~INPUT_SCRIPT_PAD_UP~",232},{"~INPUT_SCRIPT_PAD_DOWN~",233},{"~INPUT_SCRIPT_PAD_LEFT~",234}};
  const size_t length=strnlen(text,1800);
  for(size_t t=0;t<sizeof named/sizeof named[0];t++)if(memmem(text,length,named[t].token,strlen(named[t].token)))hints.helpInputs|=1u<<(named[t].input-218);
  // Logged once per new message, so the prompts' button tokens can be checked in logs.
  static char last[320];char now[320];size_t n=strnlen(text,319);memcpy(now,text,n);now[n]=0;
  if(strcmp(now,last)){memcpy(last,now,sizeof last);char line[360];snprintf(line,sizeof line,"Help message: %s",now);pg_log(line);}
 }
 uint32_t wheel=0;
 if(pg_context_u32(m,size,19480044,&wheel))hints.radioWheelOpen=wheel&1;
 // The vehicle's model hash: entity archetype at +32, its name hash at +24 (as for the ped above).
 uint64_t vehicle,vehicleInfo;uint32_t vehicleModel;
 if(touchContext&&pg_context_u64(m,size,ped+5576,&vehicle)&&vehicle&&pg_context_u64(m,size,vehicle+32,&vehicleInfo)&&vehicleInfo&&
    pg_context_u32(m,size,vehicleInfo+24,&vehicleModel))hints.vehicleModel=vehicleModel;
 // The seat manager is at +3208, seat pointers from +8 (CSeatManager, f61366/f37888); seat 0 drives.
 uint64_t driver;
 if(hints.vehicleModel&&pg_context_u64(m,size,vehicle+3216,&driver))hints.passenger=driver!=ped;
 // The taxi ride menu is the story's taxiservice script; Sandbox doesn't run it. Script threads:
 // array at 15409704, count (u16) at 15409712, name at +428 of each thread.
 // The phone's internet app (appinternet) is full screen and scrolls with the right stick; with the swipe
 // camera the touch controls sent camera swipes there instead, so stores couldn't be scrolled.
 {
  uint64_t threads;uint16_t count=0;
  if(pg_context_u64(m,size,15409704,&threads)&&threads&&pg_context_u16(m,size,15409712,&count)){
   for(uint16_t i=0;i<count&&i<512;i++){
    uint64_t thread;
    if(!pg_context_u64(m,size,threads+8ull*i,&thread)||!thread||thread+440>size)continue;
    const char *name=(const char *)(m+thread+428);
    if(hints.passenger&&!strncasecmp(name,"taxiservice",12))hints.taxiMenu=true;
    if(!strncasecmp(name,"appinternet",12))hints.phoneBrowser=true;
   }
  }
 }
 return hints;
}
// Script globals of the pinned build: Global_N is slot N & 0x3ffff of block N >> 18 (block pointers from 15408128).
static uint64_t pg_script_global(uint64_t index) {
  const uint8_t *m = (const uint8_t *)(void *)env.memory.data; const uint64_t size = env.memory.size;
  uint64_t block;
  if (!pg_context_u64(m, size, 15408128 + 8 * (index >> 18), &block) || !block) return 0;
  const uint64_t address = block + 8 * (index & 0x3ffff);
  return address + 8 <= size ? address : 0;
}
// Story context for player logs (GTA-106): the mission running (its script, matched against the game's mission
// table: Global_99461, 34 words a mission, the script name first; the label at word 8), the player's position,
// and the replay controller's state (Global_109375: 1 is the Mission failed screen). Harness/gta.py uses the same
// numbers to start a mission in the simulator at the moment a log describes.
bool PGStoryContext(char *mission, size_t size, float position[3], int32_t *replayState) {
  mission[0] = 0; position[0] = position[1] = position[2] = 0; *replayState = -1;
  if (!atomic_load(&inputBlock)) return false;
  const uint8_t *m = (const uint8_t *)(void *)env.memory.data; const uint64_t msize = env.memory.size;
  uint64_t info, ped, threads; uint16_t count = 0;
  if (pg_context_u64(m, msize, 20159720, &info) && info && pg_context_u64(m, msize, info + 8, &ped) && ped && ped + 156 < msize)
    memcpy(position, m + ped + 144, 12);
  const uint64_t state = pg_script_global(109375);
  if (state) { uint32_t value; memcpy(&value, m + state, 4); *replayState = (int32_t)value; }
  if (!pg_context_u64(m, msize, 15409704, &threads) || !threads || !pg_context_u16(m, msize, 15409712, &count)) return true;
  for (int number = 0; number < 110; number++) {
    const uint64_t entry = pg_script_global(99461 + 34 * number), label = pg_script_global(99461 + 34 * number + 8);
    if (!entry || !label || entry + 32 > msize) break;
    char name[25]; memcpy(name, m + entry, 24); name[24] = 0;
    if (!name[0] || strlen(name) < 3) break;
    for (uint16_t i = 0; i < count && i < 512; i++) {
      uint64_t thread;
      if (!pg_context_u64(m, msize, threads + 8ull * i, &thread) || !thread || thread + 460 > msize) continue;
      if (strncasecmp((const char *)(m + thread + 428), name, 24)) continue;
      char tag[9]; memcpy(tag, m + label, 8); tag[8] = 0;
      snprintf(mission, size, "%s (%s)", name, tag);
      return true;
    }
  }
  return true;
}
// The radio wheel reads INPUT_RADIO_WHEEL_UD/LR (332/333) from the main frontend control
// (CRadioWheel::GetInputAxis f35894 -> CControlMgr::GetMainFrontendControl f65461: 24660320, or
// 24488864 once a session runs), and neither has a controller binding here, so their value stays 0.
// An ioValue's value is float[0] * float[1] (ioValue::GetUnboundNorm f10519); [1] is written.
void PGSetRadioWheelDirection(float x, float y, bool active) {
  static bool wasActive;
  if (!active && !wasActive) return;
  wasActive = active;
  if (!atomic_load(&inputBlock)) return;
  const uint64_t controls[] = {24660320, 24488864};
  const float values[] = {active ? -y : 0, active ? x : 0}; // UD: up is negative, as on the pad
  for (int c = 0; c < 2; c++) for (int a = 0; a < 2; a++) {
    uint64_t at = controls[c] + 33704 + 72ull * (332 + a);
    float *value = pg_pointer(&env, at + 4, 4);
    *value = fmaxf(-1, fminf(1, values[a]));
  }
}
// Keyboard and mouse. The input block holds 256 key bytes (0x80 = down) followed by int32 words:
// 0 x, 1 y, 2 dx, 3 dy, 4 wheel, 5 buttons, 6 focus, 7 locked; 44/45 hold the back-buffer size.
static _Atomic uint8_t *pg_input_keys(void) {
  uint64_t block = atomic_load(&inputBlock);
  return block ? pg_pointer(&env, block, 444) : NULL;
}
void PGSetKey(uint8_t virtualKey, bool down) {
  _Atomic uint8_t *keys = pg_input_keys();
  if (keys) atomic_store(keys + virtualKey, down ? 0x80 : 0);
}
void PGReleaseAllKeys(void) {
  _Atomic uint8_t *keys = pg_input_keys();
  if (keys) for (int i = 0; i < 256; i++) atomic_store(keys + i, 0);
}
void PGMouseInput(int32_t dx, int32_t dy, int32_t buttons) {
  _Atomic uint8_t *keys = pg_input_keys();
  if (!keys) return;
  _Atomic int32_t *words = (_Atomic int32_t *)((uint8_t *)(void *)keys + 256);
  int32_t width = atomic_load(words + 44), height = atomic_load(words + 45);
  if (width < 320 || height < 180) { width = 960; height = 540; }
  int32_t x = atomic_load(words) + dx, y = atomic_load(words + 1) + dy;
  atomic_store(words, x < 0 ? 0 : x > width - 1 ? width - 1 : x);
  atomic_store(words + 1, y < 0 ? 0 : y > height - 1 ? height - 1 : y);
  if (dx) atomic_fetch_add(words + 2, dx);
  if (dy) atomic_fetch_add(words + 3, dy);
  atomic_store(words + 5, buttons);
}
// The game's own mouse cursor (pause menus, the map) as a fraction of the screen, 0...1.
bool PGMousePosition(float *x, float *y) {
  _Atomic uint8_t *keys = pg_input_keys();
  if (!keys) return false;
  _Atomic int32_t *words = (_Atomic int32_t *)((uint8_t *)(void *)keys + 256);
  int32_t width = atomic_load(words + 44), height = atomic_load(words + 45);
  if (width < 320 || height < 180) { width = 960; height = 540; }
  *x = (float)atomic_load(words) / (float)width; *y = (float)atomic_load(words + 1) / (float)height;
  return true;
}
void PGMouseWheel(int32_t notches) {
  _Atomic uint8_t *keys = pg_input_keys();
  if (keys && notches) atomic_fetch_add((_Atomic int32_t *)((uint8_t *)(void *)keys + 256) + 4, notches);
}
void PGSetMouseFocus(bool focused, bool locked) {
  _Atomic uint8_t *keys = pg_input_keys();
  if (!keys) return;
  _Atomic int32_t *words = (_Atomic int32_t *)((uint8_t *)(void *)keys + 256);
  atomic_store(words + 6, focused ? 1 : 0);
  atomic_store(words + 7, locked ? 1 : 0);
}
// Debug: copies [address, address+length) of engine memory (for finding state flags).
bool PGDebugReadMemory(uint64_t address,void *out,uint64_t length){
 if(!atomic_load(&inputBlock)||address>env.memory.size||length>env.memory.size-address)return false;
 memcpy(out,(const uint8_t *)(void *)env.memory.data+address,length);return true;
}
uint32_t PGCurrentTouchContext(void){
 if(!atomic_load(&inputBlock))return 0;
 return pg_touch_context((const uint8_t *)(void *)env.memory.data,env.memory.size);
}
void PGUpdateController(PGControllerState state, double elapsedSeconds) {
  uint64_t block = atomic_load(&inputBlock);
  if (!block) return;
  _Atomic uint8_t *keys = pg_pointer(&env, block, 444);
  const int codes[] = {0x20,0x11,0x52,0x46,0x51,0x45,0x1b,0x26,0x28,0x25,0x27};
  for (int i = 0; i < 11; i++) atomic_store(keys + codes[i], state.buttons & (1u << i) ? 0x80 : 0);
  atomic_store(keys + 0xa2, state.buttons & (1u << 1) ? 0x80 : 0);
  atomic_store(keys + 0xa0, state.buttons & (1u << 11) ? 0x80 : 0);
  atomic_store(keys + 0x09, state.buttons & (1u << 12) ? 0x80 : 0);
  atomic_store(keys + 0x56, state.buttons & (1u << 13) ? 0x80 : 0);
  atomic_store(keys + 0x48, state.buttons & (1u << 16) ? 0x80 : 0);
  atomic_store(keys + 0x64, state.buttons & (1u << 17) ? 0x80 : 0);
  atomic_store(keys + 0x66, state.buttons & (1u << 18) ? 0x80 : 0);
  atomic_store(keys + 0x68, state.buttons & (1u << 19) ? 0x80 : 0);
  atomic_store(keys + 0x62, state.buttons & (1u << 20) ? 0x80 : 0);
  atomic_store(keys + 0x47, state.buttons & (1u << 23) ? 0x80 : 0);
  atomic_store(keys + 0x57, state.leftY > .2f || (state.buttons & (1u << 14)) ? 0x80 : 0);
  atomic_store(keys + 0x53, state.leftY < -.2f || (state.buttons & (1u << 15)) ? 0x80 : 0);
  atomic_store(keys + 0x41, state.leftX < -.2f || (state.buttons & (1u << 21)) ? 0x80 : 0);
  atomic_store(keys + 0x44, state.leftX > .2f || (state.buttons & (1u << 22)) ? 0x80 : 0);
  atomic_store(keys + 0x0d, state.buttons & 1u ? 0x80 : 0);
  _Atomic int32_t *words = (_Atomic int32_t *)((uint8_t *)(void *)keys + 256);
  static PGLookRemainder lookRemainder;
  static bool weaponWheelHeld;
  bool wheel = (state.buttons & (1u << 12)) != 0 && !(state.buttons & (1u << 24));
  // Mouse coordinates follow the current back buffer (it can be resized live).
  int32_t width=atomic_load(words+44),height=atomic_load(words+45);
  if(width<320||height<180){width=960;height=540;}
  int32_t centerX=width/2,centerY=height/2,wheelRadius=height*4/9;
  if(wheel && !weaponWheelHeld){atomic_store(words,centerX);atomic_store(words+1,centerY);}
  weaponWheelHeld=wheel;
  int32_t dx, dy;
  if(wheel){
    pg_controller_look(&lookRemainder, 0, 0, 0, &dx, &dy);
    if(fabsf(state.rightX)>.1f || fabsf(state.rightY)>.1f){
      dx=centerX+(int32_t)lroundf(fmaxf(-1,fminf(1,state.rightX))*wheelRadius)-atomic_load(words);
      dy=centerY-(int32_t)lroundf(fmaxf(-1,fminf(1,state.rightY))*wheelRadius)-atomic_load(words+1);
    }
  }else pg_controller_look(&lookRemainder, state.rightX, state.rightY, elapsedSeconds, &dx, &dy);
  if(!wheel){dx+=state.lookDX;dy+=state.lookDY;}
  int32_t mouseX=atomic_load(words)+dx,mouseY=atomic_load(words+1)+dy;
  atomic_store(words,mouseX<0?0:mouseX>width-1?width-1:mouseX);
  atomic_store(words+1,mouseY<0?0:mouseY>height-1?height-1:mouseY);
  atomic_fetch_add(words + 2, dx);
  atomic_fetch_add(words + 3, dy);
  atomic_store(words + 5, (state.rightTrigger > .1f ? 1 : 0) | (state.leftTrigger > .1f ? 2 : 0));
}


// Controller-swipe A/B reference: gestures are impulses, not held sticks.
// UIKit and the engine sample at different times, so consume queued motion
// only at the engine's ioPad update (never immediately clear on the UI tick).
#define PG_CAMERA_SWIPE_SCALE 1024.0f
static _Atomic int32_t pendingCameraSwipeX;
static _Atomic int32_t pendingCameraSwipeY;
void PGQueueCameraSwipe(float x, float y) {
  if (!isfinite(x) || !isfinite(y)) return;
  x = fmaxf(-1000, fminf(1000, x));
  y = fmaxf(-1000, fminf(1000, y));
  atomic_fetch_add(&pendingCameraSwipeX, (int32_t)lroundf(x * PG_CAMERA_SWIPE_SCALE));
  atomic_fetch_add(&pendingCameraSwipeY, (int32_t)lroundf(y * PG_CAMERA_SWIPE_SCALE));
}
void PGClearCameraSwipe(void) {
  atomic_exchange(&pendingCameraSwipeX, 0);
  atomic_exchange(&pendingCameraSwipeY, 0);
}
static float pg_camera_swipe_axis(float delta, double elapsed) {
  const float velocity = fabsf(delta) / fmaxf(1.f/240.f, fminf(1.f/15.f, (float)elapsed));
  const float normalized = fminf(1.f, velocity / 1100.f);
  if (normalized <= 0.025f) return 0;
  return copysignf(0.245f + 0.755f * powf(normalized, 0.85f), delta);
}

// Virtual pad: packed so the engine thread reads one consistent sample.
// bits 0-15 buttons, then LX LY RX RY L2 R2 bytes (0x80 = centred stick).
static _Atomic uint64_t virtualPad = 0x0000808080800000ull;
static _Atomic bool virtualPadActive;
// Pause menu request (app going inactive): Start is held for the next few frames the engine actually
// runs. A timed press could fall entirely into the time the engine waits while the app is inactive.
static _Atomic int pauseFrames;
void PGRequestPauseMenu(void) { atomic_store(&pauseFrames, 3); atomic_store(&virtualPadActive, true); }
static uint8_t pg_pad_axis(float value, bool up) {
  if (!isfinite(value)) return 0x80;
  value = fmaxf(-1, fminf(1, value));
  if (up) value = -value;  // The engine's sticks use 0 for left and up.
  return (uint8_t)lroundf(127.5f + value * 127.5f);
}
static uint8_t pg_pad_trigger(float value) {
  return isfinite(value) ? (uint8_t)lroundf(fmaxf(0, fminf(1, value)) * 255) : 0;
}
void PGUpdateVirtualPad(PGPadState state) {
  uint64_t packed = (state.buttons & 0xffff) |
    (uint64_t)pg_pad_axis(state.leftX, false) << 16 | (uint64_t)pg_pad_axis(state.leftY, true) << 24 |
    (uint64_t)pg_pad_axis(state.rightX, false) << 32 | (uint64_t)pg_pad_axis(state.rightY, true) << 40 |
    (uint64_t)pg_pad_trigger(state.leftTrigger) << 48 | (uint64_t)pg_pad_trigger(state.rightTrigger) << 56;
  atomic_store(&virtualPad, packed);
  atomic_store(&virtualPadActive, true);
}
// SET_PLAYER_TARGETING_MODE (f58997): store menu preference 3, then apply it
// to the local player. Requested by the host, run here on the engine's own
// control-update thread.
void PG_FN_SET_MENU_PREFERENCE(w2c_game*, u32, u32);
void PG_FN_PROFILE_SETTINGS_SET(w2c_game*, u64, u32, u32);
void PG_FN_SYS_IPC_SLEEP(w2c_game*, u32); // rage::sysIpcSleep
static _Atomic int32_t pendingTargetingMode = -1;
void PGSetTargetingMode(int32_t mode) { if (mode >= 0 && mode <= 3) atomic_store(&pendingTargetingMode, mode); }
// `instance` is the calling engine thread's own (its wasm stack pointer).
static void pg_apply_targeting_mode(w2c_game *instance) {
  int32_t mode = atomic_exchange(&pendingTargetingMode, -1);
  if (mode < 0) return;
  PG_FN_SET_MENU_PREFERENCE(instance, 3, (u32)mode);
  uint64_t listeners = *(uint64_t *)pg_pointer(&env, 19571440, 8);
  if (listeners) PG_FN_PROFILE_SETTINGS_SET(instance, listeners, 0, (u32)mode);
  char line[96]; snprintf(line, sizeof line, "Targeting mode set to %d.", mode); pg_log(line);
}
// Self Radio's play order (GTA-5, Settings › Self Radio): the pause menu's Self Radio Mode, menu preference 168
// (19566784: 0 like a radio station, 1 in order, 2 shuffle) and profile setting 316, set the same way.
static _Atomic int32_t pendingSelfRadioMode = -1;
void PGSetSelfRadioMode(int32_t mode) { if (mode >= 0 && mode <= 2) atomic_store(&pendingSelfRadioMode, mode); }
static void pg_apply_self_radio_mode(w2c_game *instance) {
  int32_t mode = atomic_exchange(&pendingSelfRadioMode, -1);
  if (mode < 0) return;
  PG_FN_SET_MENU_PREFERENCE(instance, 168, (u32)mode);
  uint64_t listeners = *(uint64_t *)pg_pointer(&env, 19571440, 8);
  if (listeners) PG_FN_PROFILE_SETTINGS_SET(instance, listeners, 316, (u32)mode);
  char line[96]; snprintf(line, sizeof line, "Self Radio: play order %s.", mode == 0 ? "like a radio station" : mode == 1 ? "in order" : "shuffle"); pg_log(line);
}
u64 PG_FN_OPERATOR_NEW(w2c_game*, u64); // operator new
// Used outside the simulator tests below too (the weapon streaming guard, the saved-cash restore).
u32 PG_FN_STAT_GET_INT(w2c_game*, u32, u64, u32); // stats_commands::CommandStatGetInt
u32 PG_FN_WEAPON_ENTITY(w2c_game*, u32, u32); // weapon_commands::CommandGetCurrentPedWeaponEntityIndex
u32 PG_FN_SELECTED_WEAPON(w2c_game*, u32); // weapon_commands::CommandGetSelectedPedWeapon
u32 PG_FN_PLAYER_PED_ID(w2c_game*); // player_commands::CommandPlayerPedId
void PG_FN_SET_ENTITY_COORDS_NO_OFFSET(w2c_game*, u32, u64, u32, u32, u32); // entity_commands::CommandSetEntityCoordsNoOffset
// Scripts the game files can't stream (GTA-102): a request for apptrackify (the phone's Trackify app, The Merryweather
// Heist and Monkey Business in the sub) is never turned into a read, and every later request on its streaming device
// waits behind it: no script loads again that session, and a respawn's streaming flush waits for it for good (logs
// 745, 749, 896; harness: Email and Zit never load after it). The request is turned away (REQUEST_SCRIPT and
// REQUEST_SCRIPT_WITH_NAME_HASH, Scripts/prepare_script_request_guard.py): the app doesn't open, nothing else hangs.
static _Atomic double pgTrackifyRequestedAt;   // the phone asks again every frame while it waits for the app
static void pg_script_request_refused(const char *name) {
  atomic_store(&pgTrackifyRequestedAt, timeMS(CLOCK_MONOTONIC));
  static _Atomic int logged;
  if (atomic_exchange(&logged, 1)) return;
  char line[200]; snprintf(line, sizeof line, "Scripts: %s isn't loaded: these game files can't stream it, and the request would hold up every later script (GTA-102).", name);
  pg_log(line);
}
// Test: PG_ALLOW_BLOCKED_SCRIPTS=1 lets the requests through (to study or verify the streaming fault itself).
static bool pg_blocked_scripts_allowed(void) {
  static int allowed = -1;
  if (allowed < 0) allowed = getenv("PG_ALLOW_BLOCKED_SCRIPTS") != NULL;
  return allowed;
}
u32 pg_script_request_allowed(u64 name) {
  const char *text = name ? pg_string(&env, name) : NULL;
  if (!text || strcasecmp(text, "apptrackify") || pg_blocked_scripts_allowed()) return 1;
  pg_script_request_refused("apptrackify");
  return 0;
}
// The script is "loaded" and starting it starts nothing, so a mission that opens the app itself (The Merryweather
// Heist: REQUEST_SCRIPT, then wait for HAS_SCRIPT_LOADED, then START_NEW_SCRIPT; it waited there for good) goes on,
// with the phone in its app state, where the port-made Trackify draws (GTA-134).
u32 pg_script_name_blocked(u64 name) {
  const char *text = name ? pg_string(&env, name) : NULL;
  return text && !strcasecmp(text, "apptrackify") && !pg_blocked_scripts_allowed();
}
u32 pg_script_hash_blocked(u32 hash) { return hash == 0x15902b0eu && !pg_blocked_scripts_allowed(); }
u32 pg_script_hash_request_allowed(u32 hash) {
  if (hash != 0x15902b0eu || pg_blocked_scripts_allowed()) return 1;   // joaat("apptrackify")
  pg_script_request_refused("apptrackify");
  return 0;
}
#if TARGET_OS_SIMULATOR
u32 PG_FN_PRELOAD_MOVIE(w2c_game*, u64, u64); // CMovieMgr::PreloadMovie
void PG_FN_PLAY_MOVIE(w2c_game*, u32); // CMovieMgr::Play
// Test (PG_TEST_TELEPORT="x,y,z"): about 30 s in, moves the player there (a script vector is 3
// floats 8 bytes apart).
// Test (PG_TEST_TELEPORT="x,y,z"): moves the player there about 15 s in. With
// "x,y,z;x2,y2,z2;seconds" it then alternates between the two places, so what streams in at
// the first place is unloaded and loaded again (the fence crash in the Vinewood Hills).
static void pg_test_teleport(w2c_game *instance) {
  static int frames, jumps;
  const char *target = getenv("PG_TEST_TELEPORT");
  float p[2][3]; float seconds = 0;
  if (frames < 0 || !target) return;
  int fields = sscanf(target, "%f,%f,%f;%f,%f,%f;%f", &p[0][0], &p[0][1], &p[0][2], &p[1][0], &p[1][1], &p[1][2], &seconds);
  if (fields != 3 && fields != 7) return;
  const int period = fields == 7 && seconds >= 5 ? (int)(seconds * 30) : 0;
  const char *after = getenv("PG_TEST_TELEPORT_AFTER");		// seconds before the first move (default 30)
  const int first = after ? atoi(after) * 30 : 900;
  // Frames count only once there's a player: an optimized build runs the pad update many more times during the
  // loading screens, and a teleport there exhausts the script GUID pool (fwPool<fwScriptGuid>::PoolFullCallback).
  if (PGGameStatus() & 16) return;
  if (++frames < first || (frames - first) % (period ? period : 1)) return;
  if (!period) frames = -1;
  const float *t = p[jumps++ & 1];
  uint64_t vector = PG_FN_OPERATOR_NEW(instance, 32);
  float *v = pg_pointer(&env, vector, 24); v[0] = t[0]; v[2] = t[1]; v[4] = t[2];
  PG_FN_SET_ENTITY_COORDS_NO_OFFSET(instance, PG_FN_PLAYER_PED_ID(instance), vector, 0, 0, 0);
  char line[96]; snprintf(line, sizeof line, "TEST: player moved to %.1f, %.1f, %.1f (jump %d).", t[0], t[1], t[2], jumps); pg_log(line);
}
void w2c_game_f3111(w2c_game*, u64); // rage::sysDependencyScheduler::InsertInternal(rage::sysDependency*)
// Test (PG_TEST_STALE_JOB=1): about 20 s after there's a player, queues one dependency job that looks like a freed one
// (job function and scratch size filled with 0xDD, as RAGE fills freed memory), as players' logs show for GTA-144.
// Without Scripts/prepare_dependency_guard.py the worker asks for a 3722304989-byte scratch buffer and the game stops;
// with it the log says "Dependency worker: dropped a stale job" and play goes on.
static void pg_test_stale_job(w2c_game *instance) {
  static int frames;
  if (frames < 0 || !getenv("PG_TEST_STALE_JOB") || (PGGameStatus() & 16) || ++frames < 600) return;
  frames = -1;
  uint64_t job = PG_FN_OPERATOR_NEW(instance, 160);
  uint8_t *d = pg_pointer(&env, job, 160);
  memset(d, 0, 160);
  memset(d + 80, 0xDD, 16);   // parents (+80, +88): freed memory too
  memset(d + 96, 0xDD, 8);    // job function
  d[110] = 1;                 // needs scratch memory...
  memset(d + 112, 0xDD, 4);   // ...of 0xDDDDDDDD bytes
  d[146] = 0;                 // priority (InsertInternal picks the queue by it)
  char line[96]; snprintf(line, sizeof line, "TEST: queued a stale dependency job at 0x%llx.", (unsigned long long)job); pg_log(line);
  w2c_game_f3111(instance, job);
}
u32 PG_FN_STAT_GET_INT(w2c_game*, u32, u64, u32); // stats_commands::CommandStatGetInt
static uint32_t pg_joaat(const char *text);
u32 PG_FN_STAT_SET_INT(w2c_game*, u32, u32, u32); // stats_commands::CommandStatSetInt
void PG_FN_DO_AUTO_SAVE(w2c_game*); // misc_commands::CommandDoAutoSave
void PG_FN_SET_ENTITY_HEALTH(w2c_game*, u32, u32, u32); // entity_commands::CommandSetEntityHealth
u32 PG_FN_PLAYER_PED_ID(w2c_game*); // PLAYER_PED_ID
// Test (PG_TEST_CASH=1): every 30 s from about 30 s in, logs each character's cash stat (the save-load
// cash guard above). PG_TEST_CASH=set first gives them 1111, 2222 and 3333 and autosaves, so a later
// run can load a save with known amounts.
static void pg_test_cash(w2c_game *instance) {
  static int frames;
  const char *mode = getenv("PG_TEST_CASH");
  if (!mode) return;
  ++frames;
  // PG_TEST_CASH=spend: 30 s after the save loads, Set money to 500000 as Settings does; 15 s later the
  // player dies, so the scripts charge the hospital bill through their own payment code.
  // PG_TEST_CASH=die skips the Set money (a run on the autosave the spend run made at its end).
  if ((!strcmp(mode, "spend") || !strcmp(mode, "die")) && atomic_load(&saveLoadedAt) >= 0) {
    static int sinceLoad;
    if (++sinceLoad == 900 && !strcmp(mode, "spend")) { pg_log("TEST: Set money 500000."); PGSetPlayerCash(500000); }
    if (sinceLoad == 1350) { pg_log("TEST: the player dies (hospital bill)."); PG_FN_SET_ENTITY_HEALTH(instance, PG_FN_PLAYER_PED_ID(instance), 0, 0); }
    if (sinceLoad == 2100 && !strcmp(mode, "spend")) { PG_FN_DO_AUTO_SAVE(instance); pg_log("TEST: autosave requested."); }
  }
  if (!strcmp(mode, "set") && frames == 600) {
    for (int k = 0; k < 3; k++) { char name[16]; snprintf(name, sizeof name, "SP%d_TOTAL_CASH", k); PG_FN_STAT_SET_INT(instance, pg_joaat(name), 1111u * (k + 1), 1); }
    PG_FN_DO_AUTO_SAVE(instance);
    pg_log("TEST: cash set to 1111/2222/3333, autosave requested.");
  }
  if (atomic_load(&saveLoadedAt) < 0 || frames % 3) return;		// from the save load on (stats exist then), 10 times a second; logged on change
  static uint64_t out; static int32_t last[3] = {-2, -2, -2};
  if (!out) out = PG_FN_OPERATOR_NEW(instance, 16);
  int32_t now[3]; bool changed = false;
  for (int k = 0; k < 3; k++) {
    char name[16]; snprintf(name, sizeof name, "SP%d_TOTAL_CASH", k);
    int32_t *value = pg_pointer(&env, out, 4); *value = -1;
    now[k] = PG_FN_STAT_GET_INT(instance, pg_joaat(name), out, (u32)-1) ? *value : -1;
    changed |= now[k] != last[k]; last[k] = now[k];
  }
  if (!changed) return;
  char line[120]; snprintf(line, sizeof line, "TEST: cash SP0 %d SP1 %d SP2 %d (frame %d)", now[0], now[1], now[2], frames);
  pg_log(line);
}
f32 PG_FN_GET_ENTITY_SPEED(w2c_game*, u32); // entity_commands::CommandGetEntitySpeed
u32 PG_FN_GET_ENTITY_MODEL(w2c_game*, u32); // entity_commands::CommandGetEntityModel
u64 PG_FN_INSTRUCTIONAL_BUTTON(w2c_game*, u32, u32, u32); // pad_commands::CommandGetInputInstructionalButtonsString
// Test (PG_TEST_PROMPTS=1): about 40 s in, logs the button glyphs the game would show for the mission
// passed screen's inputs (215 ENDSCREEN_ACCEPT, 216 ENDSCREEN_EXPAND) next to FRONTEND_ACCEPT (201)
// and FRONTEND_X (203) (GTA-48). Empty means "???" on screen.
static void pg_test_prompts(w2c_game *instance) {
  static int frames;
  if (frames < 0 || !getenv("PG_TEST_PROMPTS") || ++frames < 1200) return;
  frames = -1;
  static const u32 inputs[4] = {215, 216, 201, 203};
  for (int i = 0; i < 4; i++) {
    u64 text = PG_FN_INSTRUCTIONAL_BUTTON(instance, 2, inputs[i], 1);
    char line[160]; snprintf(line, sizeof line, "TEST: input %u shows \"%.80s\".", inputs[i], text ? pg_string(&env, text) : "");
    pg_log(line);
  }
}
u32 PG_FN_GET_PED_DRAWABLE(w2c_game*, u32, u32); // ped_commands::CommandGetPedDrawableVariation
u32 PG_FN_GET_PED_TEXTURE(w2c_game*, u32, u32); // ped_commands::CommandGetPedTextureVariation
// Test (PG_TEST_OUTFIT=1): 60 s after a save loads, logs the player's clothing (drawable/texture of the
// 12 ped components), so a save and a reload can be compared (GTA-60).
static void pg_test_outfit(w2c_game *instance) {
  static int sinceLoad;
  if (!getenv("PG_TEST_OUTFIT") || atomic_load(&saveLoadedAt) < 0 || ++sinceLoad != 1800 || PGGameStatus() & 16) return;
  const u32 ped = PG_FN_PLAYER_PED_ID(instance);
  char line[256]; int at = snprintf(line, sizeof line, "TEST: outfit");
  for (u32 c = 0; c < 12; c++) at += snprintf(line + at, sizeof line - at, " %u:%u/%u", c, PG_FN_GET_PED_DRAWABLE(instance, ped, c), PG_FN_GET_PED_TEXTURE(instance, ped, c));
  pg_log(line);
}
void PG_FN_GIVE_WEAPON(w2c_game*, u32, u32, u32, u32, u32); // weapon_commands::CommandGiveWeaponToPed
u32 PG_FN_WEAPON_ENTITY(w2c_game*, u32, u32); // weapon_commands::CommandGetCurrentPedWeaponEntityIndex
u32 PG_FN_SELECTED_WEAPON(w2c_game*, u32); // weapon_commands::CommandGetSelectedPedWeapon
static uint64_t pg_test_enter_script(w2c_game *instance);
static void pg_test_leave_script(w2c_game *instance, uint64_t previous);
static uint64_t pg_test_call(w2c_game *instance, uint64_t hash, int count, const uint64_t *arguments);
// Test (PG_TEST_WEAPON=1): 30 s after the world is ready, gives the player a pistol in hand, then logs
// every 5 s whether its weapon object exists (the gun is visible and usable) (GTA-55).
static void pg_test_weapon(w2c_game *instance) {
  static int frames;
  if (!getenv("PG_TEST_WEAPON") || PGGameStatus() & 16) return;
  ++frames;
  const u32 ped = PG_FN_PLAYER_PED_ID(instance);
  if (frames == 900) { PG_FN_GIVE_WEAPON(instance, ped, pg_joaat("weapon_pistol"), 100, 0, 1); pg_log("TEST: pistol given and equipped."); }
  if (frames > 900 && frames % 150 == 0 && frames < 900 + 150 * 12) {
    char line[120]; snprintf(line, sizeof line, "TEST: selected weapon 0x%x, weapon object %u.", PG_FN_SELECTED_WEAPON(instance, ped), PG_FN_WEAPON_ENTITY(instance, ped, 0));
    pg_log(line);
  }
  // Aiming (GTA-83): IS_PED_DOING_DRIVEBY from a vehicle, IS_PLAYER_FREE_AIMING on foot, logged when it changes.
  if (frames > 900 && frames % 15 == 0) {
    static int last = -1;
    uint64_t previous = pg_test_enter_script(instance);
    const uint64_t pedArg[1] = {ped}, playerArg[1] = {0};
    int driveby = (int)(pg_test_call(instance, 0xb2c086cc1bf8f2bfull, 1, pedArg) & 1);
    int aiming = (int)(pg_test_call(instance, 0x2e397fd2ecd37c87ull, 1, playerArg) & 1);
    pg_test_leave_script(instance, previous);
    if (driveby * 2 + aiming != last) { last = driveby * 2 + aiming; char line[96]; snprintf(line, sizeof line, "TEST: aiming from a vehicle %d, on foot %d (frame %d).", driveby, aiming, frames); pg_log(line); }
  }
}
// Test (PG_TEST_SPEED=1): logs the player's speed (m/s) twice a second when it changes, to compare
// walking, jogging and sprinting from the touch controls (GTA-46).
static void pg_test_speed(w2c_game *instance) {
  static int frames; static int last = -1;
  if (!getenv("PG_TEST_SPEED") || ++frames % 15 || PGGameStatus() & 16) return;		// only once there is a player
  static u32 model;		// which character is played (character switch tests)
  u32 now = PG_FN_GET_ENTITY_MODEL(instance, PG_FN_PLAYER_PED_ID(instance));
  if (now != model) {
    model = now;
    char line[96]; snprintf(line, sizeof line, "TEST: playing %s (model 0x%x, frame %d)", now == pg_joaat("player_zero") ? "Michael" : now == pg_joaat("player_one") ? "Franklin" : now == pg_joaat("player_two") ? "Trevor" : "someone else", now, frames);
    pg_log(line);
  }
  int tenths = (int)(PG_FN_GET_ENTITY_SPEED(instance, PG_FN_PLAYER_PED_ID(instance)) * 10 + 0.5f);
  if (abs(tenths - last) < 3) return;
  last = tenths;
  char line[64]; snprintf(line, sizeof line, "TEST: speed %.1f m/s (frame %d)", tenths / 10.0, frames); pg_log(line);
}
void PG_FN_SET_TV_CHANNEL(w2c_game*, u32); // graphics_commands::CommandSetTVChannel
// Test (PG_TEST_TV=1): from about 45 s in, switches the TV on as a script does (SET_TV_CHANNEL),
// then to the next channel every 30 s, so new shows load without waiting for the playlist.
static void pg_test_tv(w2c_game *instance) {
  static int frames;
  if (!getenv("PG_TEST_TV") || ++frames < 1350 || (frames - 1350) % 900) return;
  int channel = (frames - 1350) / 900 % 3;
  char line[64]; snprintf(line, sizeof line, "TEST: TV on channel %d.", channel); pg_log(line);
  PG_FN_SET_TV_CHANNEL(instance, (u32)channel);
}
#endif
// Text the game files don't have (Scripts/prepare_missing_text.py): CTextFile::Get's "<LABEL> missing" becomes
// empty text, so help boxes from later updates stay away instead of showing a raw label. The simulator test
// PG_TEST_MISSING_TEXT_OLD=1 keeps the old answer for comparison.
void pg_missing_text(u64 buffer) {
#if TARGET_OS_SIMULATOR
  if (getenv("PG_TEST_MISSING_TEXT_OLD")) return;
#endif
  if (buffer) *(char *)pg_pointer(&env, buffer, 1) = 0;
}
// GTA-96 (Scripts/prepare_menu_shadow.py): in the pause menu's "graphics changed" check, a shadow quality below the
// menu's lowest choice (Normal, 1) counts as that choice. The check's frame holds the settings in use at +576 and
// the menu's at +128, shadow quality at +16 in each; only the frame's copy changes.
void pg_menu_shadow_floor(w2c_game *instance, u64 frame) {
  (void)instance;
  int32_t *used = pg_pointer(&env, frame + 576 + 16, 4);
  if (*used < 1 && *(int32_t *)pg_pointer(&env, frame + 128 + 16, 4) == 1) *used = 1;
}
// GTA-72 (Scripts/prepare_bink_queue.py): video commands are dropped, since no AsyncBink thread reads their
// queue; 1 keeps them (the old behaviour, PG_TEST_BINK_QUEUE_OLD in the simulator).
u32 pg_bink_queue_kept(void) {
#if TARGET_OS_SIMULATOR
  return getenv("PG_TEST_BINK_QUEUE_OLD") != NULL;
#else
  return 0;
#endif
}
#if TARGET_OS_SIMULATOR
void PG_FN_UI_SETTINGS(w2c_game*, u64); // CSettingsManager::GetUISettings (returns a CSettings)
void PG_FN_MENU_GRAPHICS_SETTINGS(w2c_game*, u64, u32); // CPauseMenu::GetMenuGraphicsSettings
u32 PG_FN_RESOLUTION_INDEX(w2c_game*); // CSettingsManager::GetResolutionIndex
u32 PG_FN_DIRTY_GFX_SETTINGS(w2c_game*); // CPauseMenu::DirtyGfxSettings
u32 PG_FN_DIRTY_ADV_GFX_SETTINGS(w2c_game*); // CPauseMenu::DirtyAdvGfxSettings
// Test (PG_TEST_GFX_DIRTY=1, GTA-96): every 20 s, whether the pause menu counts its graphics as changed (it then
// asks "You made changes but did not apply them" on every tab change), the resolution index against the menu's,
// and each 4-byte slot where the applied settings (GetUISettings) and the menu's copy differ.
static void pg_test_gfx_dirty(w2c_game *instance) {
  static int frames;
  if (!getenv("PG_TEST_GFX_DIRTY") || ++frames % 600) return;
  static uint64_t ui, menu;
  if (!ui) { ui = PG_FN_OPERATOR_NEW(instance, 1024); menu = PG_FN_OPERATOR_NEW(instance, 1024); }
  memset(pg_pointer(&env, ui, 1024), 0, 1024); memset(pg_pointer(&env, menu, 1024), 0, 1024);
  PG_FN_UI_SETTINGS(instance, ui); PG_FN_MENU_GRAPHICS_SETTINGS(instance, menu, 0);
  const uint8_t *a = pg_pointer(&env, ui, 1024), *b = pg_pointer(&env, menu, 1024);
  char line[2048]; int at = snprintf(line, sizeof line, "TEST: gfx dirty %u, advanced dirty %u, resolution index %u (menu %d); differ:",
    PG_FN_DIRTY_GFX_SETTINGS(instance), PG_FN_DIRTY_ADV_GFX_SETTINGS(instance), PG_FN_RESOLUTION_INDEX(instance), *(int32_t *)pg_pointer(&env, 19566336, 4));
  for (int k = 0; k < 288 && at < (int)sizeof line - 64; k += 4) {
    if (k == 280 || !memcmp(a + k, b + k, 4)) continue;
    int32_t x, y; float fx, fy; memcpy(&x, a + k, 4); memcpy(&y, b + k, 4); memcpy(&fx, a + k, 4); memcpy(&fy, b + k, 4);
    at += snprintf(line + at, sizeof line - at, " +%d %d/%d (%.3g/%.3g)", k, x, y, fx, fy);
  }
  pg_log(line);
}
// Test (PG_TEST_POSITION=1): every 5 s, the player's position (an entity's position is at +144).
static void pg_test_position(void) {
  static int frames;
  if (!getenv("PG_TEST_POSITION") || ++frames % 150) return;
  const uint8_t *m = (const uint8_t *)(void *)env.memory.data; uint64_t info, ped;
  if (!pg_context_u64(m, env.memory.size, 20159720, &info) || !info || !pg_context_u64(m, env.memory.size, info + 8, &ped) || !ped) return;
  const float *position = pg_pointer(&env, ped + 144, 12);
  char line[96]; snprintf(line, sizeof line, "TEST: player at %.1f, %.1f, %.1f.", position[0], position[1], position[2]); pg_log(line);
}
// Test (PG_TEST_TV_FLOOD=1, GTA-72): from about 45 s in, changes the TV channel every 10 frames, 80 times,
// as players flicking through channels do; each change queues video commands.
static void pg_test_tv_flood(w2c_game *instance) {
  static int frames;
  if (!getenv("PG_TEST_TV_FLOOD") || ++frames < 1350 || (frames - 1350) % 10 || (frames - 1350) / 10 >= 80) return;
  int change = (frames - 1350) / 10;
  if (change % 10 == 0) { char line[64]; snprintf(line, sizeof line, "TEST: TV channel change %d.", change); pg_log(line); }
  PG_FN_SET_TV_CHANNEL(instance, (u32)(change % 3));
}
// Test (PG_TEST_VIDEO=1): about a minute in, loads and plays a video that doesn't exist, the way a
// TV switching on does, and logs how long the engine was held up.
static void pg_test_video(w2c_game *instance) {
  static int frames;
  if (frames < 0 || !getenv("PG_TEST_VIDEO") || ++frames < 1800) return;
  frames = -1;
  uint64_t name = PG_FN_OPERATOR_NEW(instance, 32);
  memcpy(pg_pointer(&env, name, 32), "pg_test_video", 14);
  pg_log("TEST: loading a video that doesn't exist.");
  double start = timeMS(CLOCK_MONOTONIC);
  uint32_t handle = PG_FN_PRELOAD_MOVIE(instance, 28366608, name);
  PG_FN_PLAY_MOVIE(instance, handle);
  char line[120]; snprintf(line, sizeof line, "TEST: video handle %u, the engine was held up %.0f ms.", handle, timeMS(CLOCK_MONOTONIC) - start); pg_log(line);
}
#endif
void PG_FN_TV_SETUP_LESTER1(w2c_game*); // CTVPlaylistManager::SetupLester1CB
f32 PG_FN_TV_SCALE_TO_REAL_TIME(w2c_game*, f32); // CTVPlaylistManager::ScaleToRealTime
u32 PG_FN_TV_CURRENT_SHOW_HASH(w2c_game*); // CTVPlaylistManager::GetCurrentShowNameHash
void PG_FN_TV_SHOW_PLAY_TIME(w2c_game*, u64); // scrWrapped_GET_CURRENT_TV_SHOW_PLAY_TIME
void PG_FN_TV_SHOW_DURATION(w2c_game*, u64); // scrWrapped_GET_CURRENT_TV_SHOW_DURATION
// Friend Request (GTA-73): the Lifeinvader presentation (show 0x0cdfba8a, set up by SetupLester1CB) plays
// on Michael's TV for about 3 minutes with no picture (the game files have no TV videos), and the mission
// waits for the moment Jay Norris takes out the phone. Players gave up after a minute of a black TV, so the
// app shows how far it is (PGTVPresentation). Read on the game thread every 15 frames, like a script would.
static _Atomic int32_t pg_presentation_ms = -1, pg_presentation_duration_ms;
static void pg_tv_presentation_update(w2c_game *instance) {
  static int frames;
  if (++frames % 15) return;
  const int32_t channel = *(int32_t *)pg_pointer(&env, 28444788, 4);
  if (channel < 0 || PG_FN_TV_CURRENT_SHOW_HASH(instance) != 0x0cdfba8au) { atomic_store(&pg_presentation_ms, -1); return; }
  static uint64_t call; if (!call) call = PG_FN_OPERATOR_NEW(instance, 64);
  uint64_t *info = pg_pointer(&env, call, 64); int32_t answers[2];
  for (int k = 0; k < 2; k++) {
    memset(info, 0, 64); info[0] = call + 32; info[2] = call + 40;
    if (k == 0) PG_FN_TV_SHOW_PLAY_TIME(instance, call); else PG_FN_TV_SHOW_DURATION(instance, call);
    answers[k] = *(int32_t *)pg_pointer(&env, call + 32, 4);
  }
  atomic_store(&pg_presentation_duration_ms, answers[1]);
  atomic_store(&pg_presentation_ms, answers[1] > 0 ? answers[0] : -1);
}
bool PGTVPresentation(int32_t *playMs, int32_t *durationMs) {
  int32_t at = atomic_load(&pg_presentation_ms);
  if (at < 0) return false;
  *playMs = at; *durationMs = atomic_load(&pg_presentation_duration_ms);
  return true;
}
#if TARGET_OS_SIMULATOR
u32 PG_FN_BEGIN_TAKE_HIGH_QUALITY_PHOTO(w2c_game*); // graphics_commands::CommandBeginTakeHighQualityPhoto
u32 PG_FN_TAKE_HIGH_QUALITY_PHOTO_STATUS(w2c_game*); // graphics_commands::CommandGetStatusOfTakeHighQualityPhoto
u32 PG_FN_BEGIN_LOW_QUALITY_PHOTO_COPY(w2c_game*, u32); // graphics_commands::CommandBeginCreateLowQualityCopyOfPhoto
u32 PG_FN_LOW_QUALITY_PHOTO_COPY_STATUS(w2c_game*, u32); // graphics_commands::CommandGetStatusOfCreateLowQualityCopyOfPhoto
static uint64_t pg_test_enter_script(w2c_game *instance);
static void pg_test_leave_script(w2c_game *instance, uint64_t previous);
// Test (PG_TEST_LESTER1_TV=1): about 45 s in, puts the Lifeinvader presentation of the mission
// Friend Request (Lester1) on the TV the way the engine's own "Setup Lester1" debug button does
// (playlist PL_SP_INV on channel 0), then logs every 2 s what GET_CURRENT_TV_SHOW_PLAY_TIME and
// GET_CURRENT_TV_SHOW_DURATION would answer the mission script, and the state of the show's video.
static void pg_test_lester1_tv(w2c_game *instance) {
  static int frames;
  if (!getenv("PG_TEST_LESTER1_TV") || ++frames < 1350) return;
  if (frames == 1350) { pg_log("TEST: Lester1 presentation on the TV."); PG_FN_TV_SETUP_LESTER1(instance); return; }
  if ((frames - 1350) % 60) return;
  const int32_t channel = *(int32_t *)pg_pointer(&env, 28444788, 4);
  uint64_t cached = *(uint64_t *)pg_pointer(&env, 28445104, 8), show = cached ? *(uint64_t *)pg_pointer(&env, cached, 8) : 0;
  const float time = *(float *)pg_pointer(&env, 28444944, 4);
  const float duration = show ? *(float *)pg_pointer(&env, show + 28, 4) : 0;
  int32_t clock = 0, offset = 0;
  if (channel >= 0 && channel < 4) { clock = *(int32_t *)pg_pointer(&env, 28444800 + 24ull * channel + 8, 4); offset = *(int32_t *)pg_pointer(&env, 28444800 + 24ull * channel + 12, 4); }
  uint32_t handle = cached ? *(uint32_t *)pg_pointer(&env, cached + 8, 4) : 0, flags = 0; uint64_t bink = 0;
  uint64_t movies = *(uint64_t *)pg_pointer(&env, 28366640, 8); uint16_t count = *(uint16_t *)pg_pointer(&env, 28366648, 2);
  for (uint16_t i = 0; handle && i < count; i++) if (*(uint32_t *)pg_pointer(&env, movies + 160ull * i + 24, 4) == handle) {
    bink = *(uint64_t *)pg_pointer(&env, movies + 160ull * i, 8); flags = *(uint32_t *)pg_pointer(&env, movies + 160ull * i + 96, 4);
  }
  // What the mission script gets: the natives themselves, called like a script does (+0 result pointer).
  static uint64_t call; if (!call) call = PG_FN_OPERATOR_NEW(instance, 64);
  uint64_t *info = pg_pointer(&env, call, 64); int32_t answers[2];
  for (int k = 0; k < 2; k++) {
    memset(info, 0, 64); info[0] = call + 32; info[2] = call + 40;
    if (k == 0) PG_FN_TV_SHOW_PLAY_TIME(instance, call); else PG_FN_TV_SHOW_DURATION(instance, call);
    answers[k] = *(int32_t *)pg_pointer(&env, call + 32, 4);
  }
  char line[320]; snprintf(line, sizeof line, "TEST: TV channel %d show 0x%08x: GET_CURRENT_TV_SHOW_PLAY_TIME %d ms, GET_CURRENT_TV_SHOW_DURATION %d ms (cached show %s, %u of %u ms; channel clock %d + %d, raw show time %.1f), video handle %u flags 0x%x player %s",
    channel, PG_FN_TV_CURRENT_SHOW_HASH(instance), answers[0], answers[1], show ? "yes" : "no", show ? (uint32_t)(PG_FN_TV_SCALE_TO_REAL_TIME(instance, time) * 1000) : 0,
    show ? (uint32_t)(PG_FN_TV_SCALE_TO_REAL_TIME(instance, duration) * 1000) : 0, clock, offset, time, handle, flags, bink ? "yes" : "no");
  pg_log(line);
}
// Test (PG_TEST_PHOTO=1): about a minute in, takes a photo the way the phone camera script does
// (BEGIN_TAKE_HIGH_QUALITY_PHOTO, then BEGIN_CREATE_LOW_QUALITY_COPY_OF_PHOTO for the phone's
// screen) and logs each status change.
static void pg_test_photo(w2c_game *instance) {
  static int frames, stage, last = -1;
  if (stage > 2 || !getenv("PG_TEST_PHOTO") || ++frames < 1800) return;
  uint64_t previous = pg_test_enter_script(instance);
  int status = -1;
  if (stage == 0) { pg_log("TEST: taking a phone photo."); status = (int)PG_FN_BEGIN_TAKE_HIGH_QUALITY_PHOTO(instance); stage = 1; last = -1; }
  else if (stage == 1) status = (int)PG_FN_TAKE_HIGH_QUALITY_PHOTO_STATUS(instance);
  else status = (int)PG_FN_LOW_QUALITY_PHOTO_COPY_STATUS(instance, 0);
  pg_test_leave_script(instance, previous);
  if (status != last) { char line[96]; snprintf(line, sizeof line, "TEST: photo stage %d status %d (frame %d).", stage, status, frames); pg_log(line); last = status; }
  if (stage == 1 && status != 0 && frames > 1801) {
    const uint8_t *low = pg_pointer(&env, 0, 4); // a JPEG written to address 0 (the old memory file bug)
    char bytes[96]; snprintf(bytes, sizeof bytes, "TEST: memory at address 0: %02x %02x %02x %02x.", low[0], low[1], low[2], low[3]); pg_log(bytes);
    // PG_TEST_PHOTO=corrupt: the photo's JPEG then starts like the one in the player's log (GTA-21).
    uint64_t jpeg = atomic_load(&pgTestLastMemoryFile);
    if (!strcmp(getenv("PG_TEST_PHOTO"), "corrupt") && jpeg) {
      uint8_t *start = pg_pointer(&env, jpeg, 2); start[0] = 0x00; start[1] = 0x5f;
      pg_log("TEST: the photo's JPEG now starts with 00 5f.");
    }
    previous = pg_test_enter_script(instance);
    int started = (int)PG_FN_BEGIN_LOW_QUALITY_PHOTO_COPY(instance, 0);
    pg_test_leave_script(instance, previous);
    char line[96]; snprintf(line, sizeof line, "TEST: low quality copy requested (%d).", started); pg_log(line);
    stage = 2; last = -1;
  } else if (stage == 2 && status != 0) { pg_log("TEST: photo finished."); stage = 3; }
  if (frames > 1800 + 30 * 60 && stage < 3) { pg_log("TEST: photo still not finished after 60 s."); stage = 3; }
}
void PG_FN_REQUEST_MODEL(w2c_game*, u32); // streaming_commands::CommandRequestModel
u32 PG_FN_HAS_MODEL_LOADED(w2c_game*, u32); // streaming_commands::HasModelLoaded
u32 PG_FN_CREATE_VEHICLE(w2c_game*, u32, u64, f32, u32, u32, u32); // vehicle_commands::CommandCreateVehicle
void PG_FN_SET_PED_INTO_VEHICLE(w2c_game*, u32, u32, u32); // ped_commands::CommandSetPedIntoVehicle
// Script commands that create entities need a running script: lends them the "main" script's
// thread (the active thread is per engine thread, at g1 + 3088). Returns the previous one.
static uint64_t pg_test_enter_script(w2c_game *instance) {
  uint64_t *active = pg_pointer(&env, instance->w2c_g1 + 3088, 8), previous = *active;
  uint64_t threads = *(uint64_t *)pg_pointer(&env, 15409704, 8);
  uint16_t count = *(uint16_t *)pg_pointer(&env, 15409712, 2);
  for (uint16_t i = 0; i < count; i++) {
    uint64_t thread = *(uint64_t *)pg_pointer(&env, threads + 8ull * i, 8);
    if (thread && !strcmp(pg_string(&env, thread + 428), "main")) { *active = thread; break; }
  }
  return previous;
}
static void pg_test_leave_script(w2c_game *instance, uint64_t previous) {
  *(uint64_t *)pg_pointer(&env, instance->w2c_g1 + 3088, 8) = previous;
}
// Test (PG_TEST_CAR="x,y,z,heading"): from about 35 s in, puts the player in a car (a Sultan) there.
// GTA-76: whether the test truck still has its trailer (IS_VEHICLE_ATTACHED_TO_TRAILER), logged when it changes.
static uint32_t pg_test_trailer_truck;
static void pg_test_trailer_monitor(w2c_game *instance) {
  static int frames, last = -1;
  if (!pg_test_trailer_truck || ++frames % 15) return;
  uint64_t previous = pg_test_enter_script(instance);
  const uint64_t truck[1] = {pg_test_trailer_truck};
  int attached = (int)(pg_test_call(instance, 0xe7cf3c4f9f489f0cull, 1, truck) & 1);
  pg_test_leave_script(instance, previous);
  if (attached != last) { last = attached; char line[80]; snprintf(line, sizeof line, "TEST: trailer attached %d (frame %d).", attached, frames); pg_log(line); }
}
static void pg_test_car(w2c_game *instance) {
  static int frames, driving;
  // PG_TEST_DRIVE=<frames>: then holds the accelerator at half for that many frames.
  if (frames < 0 && driving > 0 && --driving >= 0) {
    PGUpdateVirtualPad((PGPadState){ .rightTrigger = driving ? 0.5f : 0 });
    if (!driving) pg_log("TEST: released the accelerator.");
    return;
  }
  const char *target = getenv("PG_TEST_CAR");
  float x, y, z, heading;
  const char *carAfter = getenv("PG_TEST_CAR_AFTER");   // seconds before the car (default about 35)
  if (frames < 0 || !target || ++frames < (carAfter ? atoi(carAfter) * 30 : 1050) || sscanf(target, "%f,%f,%f,%f", &x, &y, &z, &heading) != 4) return;
  // PG_TEST_CAR_MODEL=<name> picks the vehicle (joaat of the model name), "sultan" by default.
  uint32_t model = 970598228u; // joaat("sultan")
  const char *name = getenv("PG_TEST_CAR_MODEL");
  if (name && *name) { uint32_t h = 0; for (const char *c = name; *c; c++) { h += (uint8_t)(*c >= 'A' && *c <= 'Z' ? *c + 32 : *c); h += h << 10; h ^= h >> 6; } h += h << 3; h ^= h >> 11; h += h << 15; model = h; }
  uint64_t previous = pg_test_enter_script(instance);
  PG_FN_REQUEST_MODEL(instance, model);
  // PG_TEST_TRAILER=1 (GTA-76): a trailer ("trailers") is attached behind the vehicle (use a truck: phantom).
  const uint32_t trailerModel = 3417488910u; // joaat("trailers")
  bool trailer = getenv("PG_TEST_TRAILER") != NULL;
  if (trailer) PG_FN_REQUEST_MODEL(instance, trailerModel);
  if ((!PG_FN_HAS_MODEL_LOADED(instance, model) || (trailer && !PG_FN_HAS_MODEL_LOADED(instance, trailerModel))) && frames < (carAfter ? atoi(carAfter) * 30 : 1050) + 600) { pg_test_leave_script(instance, previous); return; }
  frames = -1;
  uint64_t vector = PG_FN_OPERATOR_NEW(instance, 32);
  float *v = pg_pointer(&env, vector, 24); v[0] = x; v[2] = y; v[4] = z;
  uint32_t vehicle = PG_FN_CREATE_VEHICLE(instance, model, vector, heading, 0, 0, 1);
  if (vehicle) PG_FN_SET_PED_INTO_VEHICLE(instance, PG_FN_PLAYER_PED_ID(instance), vehicle, (uint32_t)-1);
  if (trailer && vehicle) {
    float radians = heading * 3.14159265f / 180.0f;   // heading 0 faces north (+y); behind is minus forward
    v = pg_pointer(&env, vector, 24); v[0] = x + 11.0f * sinf(radians); v[2] = y - 11.0f * cosf(radians); v[4] = z;
    uint32_t towed = PG_FN_CREATE_VEHICLE(instance, trailerModel, vector, heading, 0, 0, 1);
    float radius = 15.0f; uint32_t radiusBits; memcpy(&radiusBits, &radius, 4);
    const uint64_t attach[3] = {vehicle, towed, radiusBits};
    pg_test_call(instance, 0x3c7d42d58f770b54ull, 3, attach);   // ATTACH_VEHICLE_TO_TRAILER
    pg_test_trailer_truck = vehicle;
    char line[96]; snprintf(line, sizeof line, "TEST: trailer %u attached behind vehicle %u.", towed, vehicle); pg_log(line);
  }
  pg_test_leave_script(instance, previous);
  if (getenv("PG_TEST_DRIVE")) driving = atoi(getenv("PG_TEST_DRIVE")) + 1;
  char line[96]; snprintf(line, sizeof line, "TEST: player put in car %u at %.1f, %.1f, %.1f.", vehicle, x, y, z); pg_log(line);
  pg_mod_test_recheck();
}
// Test (PG_TEST_REQUEST_MODELS="name,name"): from about 40 s in, requests those models the way a
// mission script does (REQUEST_MODEL) and logs when each has loaded, to load one model on demand.
static void pg_test_request_models(w2c_game *instance) {
  static int frames; static bool requested; static char done[8];
  const char *list = getenv("PG_TEST_REQUEST_MODELS");
  if (!list || frames < 0 || ++frames < 1200) return;
  char names[256]; snprintf(names, sizeof names, "%s", list);
  int index = 0, pending = 0;
  for (char *name = strtok(names, ","); name && index < 8; name = strtok(NULL, ","), index++) {
    uint32_t h = 0; for (const char *c = name; *c; c++) { h += (uint8_t)(*c >= 'A' && *c <= 'Z' ? *c + 32 : *c); h += h << 10; h ^= h >> 6; } h += h << 3; h ^= h >> 11; h += h << 15;
    uint64_t previous = pg_test_enter_script(instance);
    if (!requested) { PG_FN_REQUEST_MODEL(instance, h); char line[128]; snprintf(line, sizeof line, "TEST: requested model %s (0x%08x).", name, h); pg_log(line); }
    else if (!done[index]) {
      if (PG_FN_HAS_MODEL_LOADED(instance, h)) { done[index] = 1; char line[128]; snprintf(line, sizeof line, "TEST: model %s loaded.", name); pg_log(line); }
      else pending++;
    }
    pg_test_leave_script(instance, previous);
  }
  if (requested && !pending) { pg_log("TEST: all requested models loaded."); frames = -1; }
  requested = true;
  if (frames > 1200 + 30 * 120) { pg_log("TEST: requested models still not loaded after 120 s."); frames = -1; }
}
void PG_FN_LOAD_SCENE_START(w2c_game*, u64, u64, f32, u32, u32, u32); // CLoadScene::StartFromScript
u32 PG_FN_LOAD_SCENE_IS_LOADED(w2c_game*); // CLoadScene::IsLoaded
u64 PG_FN_HASH_STRING_TRY_GET(w2c_game*, u32, u32); // atHashStringNamespaceSupport::TryGetString
// Test (PG_TEST_LOADSCENE=start): about 50 s in, starts the frustum load scene Los Santos Customs
// (carmod_shop) asks for, NEW_LOAD_SCENE_START at (-326.94, -131.75, 38.85).
static void pg_test_loadscene(w2c_game *instance) {
  static int frames;
  const char *mode = getenv("PG_TEST_LOADSCENE");
  if (frames < 0 || !mode || strcmp(mode, "start") || ++frames < 1500) return;
  frames = -1;
  uint64_t vectors = PG_FN_OPERATOR_NEW(instance, 64);
  float *v = pg_pointer(&env, vectors, 32);
  v[0] = -326.94f; v[1] = -131.75f; v[2] = 38.85f; v[3] = 0;
  v[4] = -0.91f; v[5] = -0.40f; v[6] = 0; v[7] = 0;
  pg_log("TEST: starting the Los Santos Customs load scene.");
  PG_FN_LOAD_SCENE_START(instance, vectors, vectors + 16, 5.0f, 0, 1, 0);
}
// PG_TEST_LOADSCENE (any value): logs the load scene's state whenever it changes, and every 5 s.
static void pg_test_loadscene_monitor(w2c_game *instance) {
  static char last[200];
  static double lastTime;
  if (!getenv("PG_TEST_LOADSCENE")) return;
  const uint8_t *m = pg_pointer(&env, 0, 23418200);
  if (m[23389293] != 1) { last[0] = 0; return; }
  uint32_t state = *(const uint32_t *)(m + 23389296);
  uint64_t proxy = *(const uint64_t *)(m + 23389344);
  char name[48] = "-";
  int proxyState = -1, proxyRequested = -1, proxyFlags = -1;
  if (proxy) {
    const uint8_t *p = pg_pointer(&env, proxy, 208);
    proxyRequested = p[28]; proxyState = p[30]; proxyFlags = *(const uint16_t *)(p + 20);
    uint64_t text = PG_FN_HASH_STRING_TRY_GET(instance, 0, *(const uint32_t *)(p + 196));
    if (text) snprintf(name, sizeof name, "%s", pg_string(&env, text));
  }
  char line[200];
  snprintf(line, sizeof line, "LOADSCENE state %u proxy %s (%llx) state %d requested %d flags %x volume %x entities %u bounds %u loaded %u",
    state, name, (unsigned long long)proxy, proxyState, proxyRequested, proxyFlags, m[23417824],
    *(const uint16_t *)(m + 23417896), *(const uint16_t *)(m + 23417912), PG_FN_LOAD_SCENE_IS_LOADED(instance));
  double now = timeMS(CLOCK_MONOTONIC);
  if (!strcmp(line, last) && now - lastTime < 5000) return;
  snprintf(last, sizeof last, "%s", line); lastTime = now;
  pg_log(line);
}
#endif
// Sandbox on the GTA VI test map runs the GTA V map's scripts (NativeAssets.m), and they place
// the player on GTA V coordinates (a story character's sandbox spawn, hospitals after a death),
// which on the test map can be water or empty space. The first time the player exists, after any
// jump of more than 300 m (a respawn) and whenever the player falls below the map, this moves them
// to the test map's own start point (the one its test startup script uses). The player ped is
// found the same way as in PGGameStatus; an entity's position is at +144.
static void pg_keep_on_test_map(w2c_game *instance) {
  static int frames;
  static u64 vector;
  static bool placed;
  static float lastX, lastY;
  if (configuredStartMode != 3 || ++frames % 15) return;
  const uint8_t *m = (const uint8_t *)(void *)env.memory.data; uint64_t info, ped;
  if (!pg_context_u64(m, env.memory.size, 20159720, &info) || !info || !pg_context_u64(m, env.memory.size, info + 8, &ped) || !ped) return;
  const float *position = pg_pointer(&env, ped + 144, 12);
  const float x = position[0], y = position[1], z = position[2];
  const bool jumped = placed && (x - lastX) * (x - lastX) + (y - lastY) * (y - lastY) > 300.f * 300.f;
  lastX = x; lastY = y;
  if (placed && !jumped && !(z < -40.f)) return;
  if (!vector) vector = PG_FN_OPERATOR_NEW(instance, 32);
  float *v = pg_pointer(&env, vector, 24); v[0] = -234.f; v[2] = 838.f; v[4] = 38.f;
  PG_FN_SET_ENTITY_COORDS_NO_OFFSET(instance, PG_FN_PLAYER_PED_ID(instance), vector, 0, 0, 0);
  lastX = v[0]; lastY = v[2];
  char line[128]; snprintf(line, sizeof line, "GTA VI test map: moved the player from %.0f, %.0f, %.0f to the map's start point.", x, y, z); pg_log(line);
  placed = true;
}
// Aircraft weapons. INPUT_VEH_FLY_SELECT_NEXT_WEAPON shares D-pad left with the radio, whose tap
// changes the station, so the touch button asks for the next weapon the way a script does:
// GET_CURRENT_PED_VEHICLE_WEAPON (f63032), then SET_CURRENT_PED_VEHICLE_WEAPON (f63031) on the next
// known aircraft weapon until one is accepted (it refuses weapons the vehicle doesn't have).
void PG_FN_REDUCE_PED_MODEL_BUDGET(w2c_game*, u32);
void PG_FN_REDUCE_VEHICLE_MODEL_BUDGET(w2c_game*, u32);
void PG_FN_PED_DENSITY_THIS_FRAME(w2c_game*, f32);
void PG_FN_VEHICLE_DENSITY_THIS_FRAME(w2c_game*, f32);
void PG_FN_PARKED_DENSITY_THIS_FRAME(w2c_game*, f32);
void PG_FN_LOD_SCALE_THIS_FRAME(w2c_game*, f32);
// Lite build (PG_LITE): below the PC game's lowest settings, the way the consoles ran it. The game's
// own switches for heavy missions keep fewer ambient ped and vehicle models loaded; every frame fewer
// people and cars are placed and detail starts closer (measured: about 50 MB more headroom at a
// 2.3 GB limit, and no eviction churn). Scripts that set these themselves
// (missions, cutscenes) run later in the frame and win. PG_LITE_DENSITY and PG_LITE_LOD tune it.
static void pg_apply_lite(w2c_game *instance) {
  static int lite = -1; static float density = 0.45f, lod = 0.7f; static unsigned frames;
  if (lite < 0) {
    const char *flag = getenv("PG_LITE"), *d = getenv("PG_LITE_DENSITY"), *l = getenv("PG_LITE_LOD");
    lite = flag && strcmp(flag, "0") && !(getenv("PG_LITE_WORLD") && !strcmp(getenv("PG_LITE_WORLD"), "0"));
    if (d) density = fmaxf(0, fminf(1, (float)atof(d)));
    if (l) lod = fmaxf(0.3f, fminf(1, (float)atof(l)));
    if (lite) { char line[120]; snprintf(line, sizeof line, "Lite: fewer ambient models, density %.2f, detail distance %.2f.", density, lod); pg_log(line); }
  }
  if (!lite) return;
  if (frames++ % 60 == 0) { PG_FN_REDUCE_PED_MODEL_BUDGET(instance, 1); PG_FN_REDUCE_VEHICLE_MODEL_BUDGET(instance, 1); }
  PG_FN_PED_DENSITY_THIS_FRAME(instance, density);
  PG_FN_VEHICLE_DENSITY_THIS_FRAME(instance, density);
  PG_FN_PARKED_DENSITY_THIS_FRAME(instance, density);
  if (lod < 1) PG_FN_LOD_SCALE_THIS_FRAME(instance, lod);
}
u32 PG_FN_GET_ENTITY_MODEL(w2c_game*, u32); // entity_commands::CommandGetEntityModel
u32 PG_FN_STAT_SET_INT(w2c_game*, u32, u32, u32); // stats_commands::CommandStatSetInt
// The story scripts keep each character's balance in a script global (Global_68115[character]) and
// write the SPn_TOTAL_CASH stat from it after every purchase or payment. The globals' first block is
// at *(15408128); an array's size comes first (3), the balances follow. NULL if it isn't there, or
// with PG_CASH_GLOBAL=0 (comparisons).
static int64_t *pg_cash_balance(int character) {
  const char *setting = getenv("PG_CASH_GLOBAL");
  if ((setting && !strcmp(setting, "0")) || character < 0 || character > 2 || env.memory.size < 15408136) return NULL;
  const uint64_t globals = *(uint64_t *)pg_pointer(&env, 15408128, 8), balances = globals ? globals + 68115ull * 8 : 0;
  if (!balances || balances + 32 > env.memory.size || *(int32_t *)pg_pointer(&env, balances, 4) != 3) return NULL;
  return (int64_t *)pg_pointer(&env, balances + 8 * (1 + (uint64_t)character), 8);		// script values are 8 bytes
}
// Story cheat "Set money" (Settings): writes SPn_TOTAL_CASH of the character being played, the
// stat the game's money display and shops read. Michael is player_zero, Franklin player_one,
// Trevor player_two; any other model (Sandbox's) has no story cash.
static _Atomic int64_t cashRequest = -1;
void PGSetPlayerCash(int32_t amount) { atomic_store(&cashRequest, amount < 0 ? 0 : amount); }
static uint32_t pg_joaat(const char *text);
static void pg_apply_cash_request(w2c_game *instance) {
  const int64_t amount = atomic_exchange(&cashRequest, -1);
  if (amount < 0) return;
  const uint32_t model = PG_FN_GET_ENTITY_MODEL(instance, PG_FN_PLAYER_PED_ID(instance));
  int character = model == pg_joaat("player_zero") ? 0 : model == pg_joaat("player_one") ? 1 : model == pg_joaat("player_two") ? 2 : -1;
  char line[120];
  if (character < 0) {
    snprintf(line, sizeof line, "Set money: the player isn't Michael, Franklin or Trevor (model 0x%x); nothing changed.", model);
    pg_log(line); return;
  }
  char stat[16]; snprintf(stat, sizeof stat, "SP%d_TOTAL_CASH", character);
  // The stat alone would be overwritten from the scripts' balance (or a purchase above the old
  // balance refused) by the next transaction, so both are set.
  int64_t *balance = pg_cash_balance(character);
  if (balance) {
    snprintf(line, sizeof line, "Set money: the scripts' balance for character %d was %d.", character, (int32_t)*balance);
    pg_log(line);
    *balance = amount;
  } else pg_log("Set money: the scripts' balance wasn't found; only the stat changes.");
  PG_FN_STAT_SET_INT(instance, pg_joaat(stat), (u32)amount, 1);
  snprintf(line, sizeof line, "Set money: %s set to %lld.", stat, (long long)amount);
  pg_log(line);
}
void PG_FN_SET_CURRENT_PED_VEHICLE_WEAPON(w2c_game*, u64);
void PG_FN_GET_CURRENT_PED_VEHICLE_WEAPON(w2c_game*, u64);
u32 PG_FN_PLAYER_PED_ID(w2c_game*); // PLAYER_PED_ID
static _Atomic bool aircraftWeaponRequested;
void PGNextAircraftWeapon(void) { atomic_store(&aircraftWeaponRequested, true); }
static uint32_t pg_joaat(const char *text) {
  uint32_t h = 0;
  for (const char *c = text; *c; c++) { h += (uint8_t)(*c >= 'A' && *c <= 'Z' ? *c + 32 : *c); h += h << 10; h ^= h >> 6; }
  h += h << 3; h ^= h >> 11; h += h << 15; return h;
}
static void pg_next_aircraft_weapon(w2c_game *instance) {
  if (!atomic_exchange(&aircraftWeaponRequested, false)) return;
  static const char *names[] = {"VEHICLE_WEAPON_PLAYER_LAZER", "VEHICLE_WEAPON_SPACE_ROCKET", "VEHICLE_WEAPON_PLAYER_BUZZARD",
                                "VEHICLE_WEAPON_PLAYER_SAVAGE", "VEHICLE_WEAPON_PLAYER_BULLET", "VEHICLE_WEAPON_PLANE_ROCKET"};
  enum { COUNT = sizeof names / sizeof *names };
  static uint64_t call; // native call info: +0 result pointer, +16 arguments; then result and arguments
  if (!call) call = PG_FN_OPERATOR_NEW(instance, 64);
  uint64_t *info = pg_pointer(&env, call, 64);
  memset(info, 0, 64);
  info[0] = call + 24; info[2] = call + 32;
  const uint32_t ped = PG_FN_PLAYER_PED_ID(instance);
  info[4] = ped; info[5] = call + 48; // ped, pointer to the hash
  PG_FN_GET_CURRENT_PED_VEHICLE_WEAPON(instance, call);
  const uint32_t current = *(uint32_t *)pg_pointer(&env, call + 48, 4), found = *(uint32_t *)pg_pointer(&env, call + 24, 4);
  int at = -1;
  for (int i = 0; i < COUNT; i++) if (pg_joaat(names[i]) == current) at = i;
  char line[160];
  for (int step = 1; step <= COUNT; step++) {
    const int next = (at + step + COUNT) % COUNT;
    if (next == at) break;
    memset(info, 0, 64); info[0] = call + 24; info[2] = call + 32;
    info[4] = ped; info[5] = pg_joaat(names[next]);
    PG_FN_SET_CURRENT_PED_VEHICLE_WEAPON(instance, call);
    if (*(uint32_t *)pg_pointer(&env, call + 24, 4)) {
      snprintf(line, sizeof line, "Aircraft weapon: %s (was 0x%x%s).", names[next], current, found ? "" : ", none");
      pg_log(line); return;
    }
  }
  snprintf(line, sizeof line, "Aircraft weapon: no other weapon on this aircraft (current 0x%x%s).", current, found ? "" : ", none");
  pg_log(line);
}
// Add-on cars whose texture parent isn't in this game version (GTA-151; Scripts/prepare_txd_parent.py). A pack's
// vehicles.meta can name a parent texture set from a later PC update (cbr1000rrr: "vehicles_race_generic"); the game makes
// an empty slot for it, the car's textures depend on that slot, and the spawn waited 30 s and failed. The texture store
// asks here for a slot's parent whenever something requests it: a parent that by then has no file in the game's archives
// becomes vehshare, the shared vehicle textures, in the slot as well, so the textures link to it when they're placed.
u32 PG_FN_STREAM_IN_IMAGE(w2c_game*, u32);
u32 PG_FN_TXD_FIND_SLOT(w2c_game*, u64, u64);
u64 PG_FN_STREAM_OBJECT_NAME(w2c_game*, u32);
u32 pg_txd_parent(w2c_game *instance, u64 store, u64 def, u32 child, u32 parent) {
  if (parent == (u32)-1 || !def || def + 20 > env.memory.size) return parent;
  const u32 first = *(u32 *)pg_pointer(&env, store + 8, 4);		// the store's first streaming index
  if (PG_FN_STREAM_IN_IMAGE(instance, first + parent)) return parent;
  static int32_t vehshare = -2;
  if (vehshare == -2) {		// its slot, looked up by name once; the name goes on this thread's engine stack
    const u64 stack = instance->w2c_g0;
    instance->w2c_g0 -= 16;
    memcpy(pg_pointer(&env, instance->w2c_g0, 9), "vehshare", 9);
    vehshare = (int32_t)PG_FN_TXD_FIND_SLOT(instance, store, instance->w2c_g0);
    instance->w2c_g0 = stack;
  }
  if (vehshare < 0 || (u32)vehshare == child || (u32)vehshare == parent) return parent;
  static u32 logged[32]; static int count;
  bool seen = false;
  for (int i = 0; i < count; i++) seen |= logged[i] == parent;
  if (!seen && count < 32) {
    logged[count++] = parent;
    const u64 name = PG_FN_STREAM_OBJECT_NAME(instance, first + parent);		// "<<vehicles_race_generic>>" for an empty slot
    char line[220];
    snprintf(line, sizeof line, "Mods: the texture set %s isn't in this game version (it came with a later PC update); add-on cars that build on it use vehshare instead.",
             name ? pg_string(&env, name) : "?");
    pg_log(line);
  }
  *(u32 *)pg_pointer(&env, def + 16, 4) = (u32)vehshare;
  return (u32)vehshare;
}
// Trace (PG_TRACE_REQUEST_INDEX=N, GTA-151; Scripts/prepare_request_trace.py): which exit of RequestObject answers for
// streaming object N. It found the add-on car's texture dictionary refused at exit 6, a dependency that isn't in the
// game's archives (pg_txd_parent above).
void pg_trace_request_exit(u32 index, u32 exit, u32 result) {
  static long wanted = -2;
  if (wanted == -2) { const char *v = getenv("PG_TRACE_REQUEST_INDEX"); wanted = v ? atol(v) : -1; }
  if (wanted < 0 || index != (u32)wanted) return;
  char line[120]; snprintf(line, sizeof line, "RequestObject [trace]: object %u leaves by exit %u with %u.", index, exit, result); pg_log(line);
}
// Trace (PG_TRACE_STREAM_ALLOC, GTA-151; Scripts/prepare_stream_alloc_trace.py): the streaming allocator's answers
// for big blocks (big add-on cars need 32 MB pages): every refusal of 1 MB or more and every grant of 8 MB or more, the
// first 200.
void pg_trace_stream_alloc(u32 kind, u64 size, u64 align, u32 type, u64 result) {
  static int on = -1; static _Atomic int logged;
  if (on < 0) on = getenv("PG_TRACE_STREAM_ALLOC") != NULL;
  if (!on || size < (result ? 8u << 20 : 1u << 20) || atomic_fetch_add(&logged, 1) >= 200) return;
  char line[160];
  snprintf(line, sizeof line, "Streaming allocator [trace]: %s %llu KB (alignment %llu, kind %u): %s.", kind ? "try" : "allocate",
           (unsigned long long)(size >> 10), (unsigned long long)align, type, result ? "given" : "refused");
  pg_log(line);
}
// Trace (PG_TRACE_STREAM_LOADS, GTA-148): every ~10 s the objects the engine loaded most often, by name.
int PGStreamTopLoads(uint32_t *index, uint32_t *count, int max);
u64 PG_FN_STREAM_OBJECT_NAME(w2c_game*, u32);
static void pg_trace_stream_loads(w2c_game *instance) {
  static int on = -1; static unsigned frames;
  if (on < 0) on = getenv("PG_TRACE_STREAM_LOADS") != NULL;
  if (!on || ++frames % 300) return;
  uint32_t index[12], count[12]; const int n = PGStreamTopLoads(index, count, 12);
  for (int i = 0; i < n && count[i] > 2; i++) {
    const u64 name = PG_FN_STREAM_OBJECT_NAME(instance, index[i]);
    char line[200]; snprintf(line, sizeof line, "Streaming [trace]: loaded %u times: %s (index %u).", count[i], name ? pg_string(&env, name) : "?", index[i]);
    pg_log(line);
  }
}
uint32_t PGCurrentTouchContext(void);
static void pg_keep_weapon_loaded(w2c_game *instance) {
  static int frames; static uint32_t unarmed;
  if (++frames % 15 || PGGameStatus() & 16 || PGCurrentTouchContext() != 0) return;		// on foot, twice a second
  if (!unarmed) unarmed = pg_joaat("weapon_unarmed");
  const u32 ped = PG_FN_PLAYER_PED_ID(instance), weapon = PG_FN_SELECTED_WEAPON(instance, ped);
  if (!weapon || weapon == unarmed || PG_FN_WEAPON_ENTITY(instance, ped, 0)) return;
  if (timeMS(CLOCK_MONOTONIC) > atomic_load(&weaponGrantUntil)) {
    static _Atomic int logged;
    if (atomic_fetch_add(&logged, 1) < 3) { char line[96]; snprintf(line, sizeof line, "Memory guard: making room for the selected weapon (0x%x).", weapon); pg_log(line); }
  }
  atomic_store(&weaponGrantUntil, timeMS(CLOCK_MONOTONIC) + 2000);
}
// MARK: Script Hook V mods (.asi), GTA-69
// Mods made for Script Hook V on PC run in an x86-64 interpreter (Source/NativeASI.c). Here they get
// the engine's heap, its game commands by Script Hook V hash (Generated/asi-natives.inc, made by
// Scripts/prepare_asi_natives.py) and a turn on the main script thread every frame.
#include "NativeASI.h"
#include "asi-natives.inc"
void PG_FN_OPERATOR_DELETE(w2c_game *, u64);
static w2c_game *pg_asi_game;
static uint64_t pg_asi_alloc(uint64_t size) { return PG_FN_OPERATOR_NEW(pg_asi_game, size ? size : 16); }
static void pg_asi_free(uint64_t address) { if (address) PG_FN_OPERATOR_DELETE(pg_asi_game, address); }
static void pg_asi_log(const char *line) { pg_log(line); }
// Text boxes for mods: a mod asks for typed text (a car to spawn by name, a search) with the game's
// on-screen keyboard commands. Those are answered here: the app shows the iPhone keyboard with the mod's
// title and default text (PGAsiTextRequest), and the mod gets what was typed (PGAsiTextFinish).
static _Atomic int pg_asi_text_state = 3;   // UPDATE_ONSCREEN_KEYBOARD: 0 typing, 1 done, 2 cancelled, 3 none
static _Atomic bool pg_asi_text_requested;
static char pg_asi_text_title[160], pg_asi_text_value[1024]; static int pg_asi_text_max;
static pthread_mutex_t pg_asi_text_lock = PTHREAD_MUTEX_INITIALIZER;
bool PGAsiTextRequest(char *title, size_t titleSize, char *text, size_t textSize, int *maxLength) {
  if (!atomic_exchange(&pg_asi_text_requested, false)) return false;
  pthread_mutex_lock(&pg_asi_text_lock);
  snprintf(title, titleSize, "%s", pg_asi_text_title); snprintf(text, textSize, "%s", pg_asi_text_value); *maxLength = pg_asi_text_max;
  pthread_mutex_unlock(&pg_asi_text_lock);
  return true;
}
void PGAsiTextFinish(const char *text) {
  pthread_mutex_lock(&pg_asi_text_lock);
  if (text) snprintf(pg_asi_text_value, sizeof pg_asi_text_value, "%.*s", pg_asi_text_max > 0 && pg_asi_text_max < 1023 ? pg_asi_text_max : 1023, text);
  pthread_mutex_unlock(&pg_asi_text_lock);
  atomic_store(&pg_asi_text_state, text ? 1 : 2);
}
static bool pg_asi_native(uint64_t hash, uint64_t arguments, uint32_t count, uint64_t result);
static const char *pg_asi_guest_string(uint64_t address) { return address ? pg_string(&env, address) : ""; }
static bool pg_asi_text_command(uint64_t hash, uint64_t arguments, uint32_t count, uint64_t result) {
  const uint64_t *a = count ? pg_pointer(&env, arguments, 8ull * count) : 0;
  if (hash == 0x00dc833f2568dbf6ull || hash == 0xca78cfa0366592feull) {  // DISPLAY_ONSCREEN_KEYBOARD(_WITH_LONGER_INITIAL_STRING)
    if (count < 5) return true;
    // The title is a text label ("FMMC_KEY_TIP8"); its words come from the game's text (_GET_LABEL_TEXT).
    char title[160]; snprintf(title, sizeof title, "%s", pg_asi_guest_string(a[1]));
    if (title[0] && !strchr(title, ' ')) {
      static uint64_t buffer; if (!buffer) buffer = pg_asi_alloc(64);
      memcpy(pg_pointer(&env, buffer, 8), &a[1], 8); memset(pg_pointer(&env, buffer + 32, 8), 0, 8);
      if (pg_asi_native(0x7b5280eba9840c72ull, buffer, 1, buffer + 32)) {
        uint64_t text; memcpy(&text, pg_pointer(&env, buffer + 32, 8), 8);
        const char *words = pg_asi_guest_string(text);
        if (words[0] && strcmp(words, "NULL")) snprintf(title, sizeof title, "%s", words);
      }
    }
    pthread_mutex_lock(&pg_asi_text_lock);
    snprintf(pg_asi_text_title, sizeof pg_asi_text_title, "%s", title);
    pg_asi_text_value[0] = 0;
    for (uint32_t i = 3; i + 1 < count && i < 11; i++) {   // the default text, then its continuations
      size_t used = strlen(pg_asi_text_value);
      snprintf(pg_asi_text_value + used, sizeof pg_asi_text_value - used, "%s", pg_asi_guest_string(a[i]));
    }
    pg_asi_text_max = (int)(uint32_t)a[count - 1];
    pthread_mutex_unlock(&pg_asi_text_lock);
    atomic_store(&pg_asi_text_state, 0); atomic_store(&pg_asi_text_requested, true);
    char line[220]; snprintf(line, sizeof line, "Mods: a script asks for text (%s).", title); pg_log(line);
    return true;
  }
  if (hash == 0x0cf2b696bbf945aeull) {  // UPDATE_ONSCREEN_KEYBOARD
    uint64_t state = (uint32_t)atomic_load(&pg_asi_text_state); memcpy(pg_pointer(&env, result, 8), &state, 8); return true;
  }
  if (hash == 0x8362b09b91893647ull) {  // GET_ONSCREEN_KEYBOARD_RESULT
    static uint64_t text; if (!text) text = pg_asi_alloc(1024);
    pthread_mutex_lock(&pg_asi_text_lock);
    snprintf(pg_pointer(&env, text, 1024), 1024, "%s", atomic_load(&pg_asi_text_state) == 1 ? pg_asi_text_value : "");
    pthread_mutex_unlock(&pg_asi_text_lock);
    uint64_t pointer = atomic_load(&pg_asi_text_state) == 1 ? text : 0; memcpy(pg_pointer(&env, result, 8), &pointer, 8); return true;
  }
  if (hash == 0x58a39be597ce99cdull) { atomic_store(&pg_asi_text_state, 2); return true; }  // CANCEL_ONSCREEN_KEYBOARD
  return false;
}
static bool pg_asi_native(uint64_t hash, uint64_t arguments, uint32_t count, uint64_t result) {
  if (pg_asi_text_command(hash, arguments, count, result)) return true;
  size_t low = 0, high = sizeof pg_asi_natives / sizeof *pg_asi_natives;
  while (low < high) { size_t middle = (low + high) / 2; if (pg_asi_natives[middle].hash < hash) low = middle + 1; else high = middle; }
  if (low == sizeof pg_asi_natives / sizeof *pg_asi_natives || pg_asi_natives[low].hash != hash) {
    // Entity handles are also ped/vehicle/object handles: these only convert between them.
    if (hash == 0x04a2a40c73395041ull || hash == 0x4b53f92932adfac0ull || hash == 0xd7e3b9735c0f89d6ull) {
      if (count) memcpy(pg_pointer(&env, result, 8), pg_pointer(&env, arguments, 8), 8);
      return true;
    }
    return false;
  }
  // rage::scrThread::Info: result, argument count, arguments, then the Vector3 out-parameters the
  // command filled (count at +24, destinations at +32, values at +64), which the script VM copies back.
  static uint64_t context;
  if (!context) context = pg_asi_alloc(128);
  uint8_t *info = pg_pointer(&env, context, 128); memset(info, 0, 128);
  memcpy(info, &result, 8); memcpy(info + 8, &count, 4); memcpy(info + 16, &arguments, 8);
  pg_asi_natives[low].handler(pg_asi_game, context);
  uint32_t vectors; memcpy(&vectors, info + 24, 4);
  for (uint32_t i = 0; i < vectors && i < 4; i++) {
    uint64_t to; memcpy(&to, info + 32 + 8 * i, 8); if (!to) continue;
    uint8_t *out = pg_pointer(&env, to, 24); float value[3]; memcpy(value, info + 64 + 16 * i, 12);
    memset(out, 0, 24); memcpy(out, &value[0], 4); memcpy(out + 8, &value[1], 4); memcpy(out + 16, &value[2], 4);
  }
  return true;
}
// Tests: calls a game command by its hash through the script-mod table (Generated/asi-natives.inc), from
// the game thread inside a script (pg_test_enter_script). Returns its first result word, or -1 if unknown.
// Settings › Cheats uses it too, to look up the names the game shows for vehicles.
static uint64_t pg_test_buffer;   // pg_test_call's arguments, then its result words from +8 * 32
static uint64_t pg_test_call(w2c_game *instance, uint64_t hash, int count, const uint64_t *arguments) {
  if (!pg_asi_game) pg_asi_game = instance;
  if (!pg_test_buffer) pg_test_buffer = pg_asi_alloc(8 * 40);
  const uint64_t buffer = pg_test_buffer;
  if (count > 32) count = 32;
  if (count) memcpy(pg_pointer(&env, buffer, 8ull * count), arguments, 8ull * count);
  memset(pg_pointer(&env, buffer + 8 * 32, 64), 0, 64);
  if (!pg_asi_native(hash, buffer, (uint32_t)count, buffer + 8 * 32)) return (uint64_t)-1;
  uint64_t result; memcpy(&result, pg_pointer(&env, buffer + 8 * 32, 8), 8); return result;
}
// Game commands that create or own things need a running script: lends them the game's "main" script
// (the active script is per engine thread, at g1 + 3088). Returns the previous one for pg_asi_leave_script.
static uint64_t pg_asi_enter_script(w2c_game *instance) {
  uint64_t *active = pg_pointer(&env, instance->w2c_g1 + 3088, 8), previous = *active;
  uint64_t threads = *(uint64_t *)pg_pointer(&env, 15409704, 8);
  uint16_t count = *(uint16_t *)pg_pointer(&env, 15409712, 2);
  for (uint16_t i = 0; i < count; i++) {
    uint64_t thread = *(uint64_t *)pg_pointer(&env, threads + 8ull * i, 8);
    if (thread && !strcmp(pg_string(&env, thread + 428), "main")) { *active = thread; break; }
  }
  return previous;
}
static void pg_asi_leave_script(w2c_game *instance, uint64_t previous) {
  *(uint64_t *)pg_pointer(&env, instance->w2c_g1 + 3088, 8) = previous;
}
// Settings › Cheats: spawn vehicle, God mode, Never wanted, repair, time and weather. Run each frame by
// pg_cheats_menu_tick from pg_asi_script_tick below.
#include "NativeCheats.inc"
#include "NativeVehicleSpawn.inc"
// Keys for mods: the Mod keys pad (and a hardware keyboard) set them from the main thread; mods read
// them on the game thread, and keyboard handlers get each change there.
static _Atomic uint8_t pg_asi_keys[256];
static _Atomic uint32_t pg_asi_key_events[64]; static _Atomic uint32_t pg_asi_key_head, pg_asi_key_tail;
void PGAsiSetKey(int virtualKey, bool down) {
  if (virtualKey <= 0 || virtualKey > 255 || atomic_load(&pg_asi_keys[virtualKey]) == down) return;
  atomic_store(&pg_asi_keys[virtualKey], down);
  uint32_t at = atomic_fetch_add(&pg_asi_key_head, 1);
  atomic_store(&pg_asi_key_events[at % 64], (uint32_t)virtualKey | (down ? 0x100u : 0));
}
bool PGAsiModKeys(uint8_t keys[256]) { return pg_asi_polled_keys(keys); }
void PGAsiGetKeyInfo(PGAsiKeyInfo *info) { pg_asi_key_info(info); }
static bool pg_asi_key_down(int virtualKey) { return virtualKey > 0 && virtualKey < 256 && atomic_load(&pg_asi_keys[virtualKey]); }
#if TARGET_OS_SIMULATOR
// Test (PG_TEST_ASI_KEYS="seconds:key,..."): presses each Windows key for 0.3 s that many seconds after
// the script mods load, e.g. "20:114" is F3 (Simple Trainer's menu key).
static void pg_asi_test_keys(double seconds) {
  const char *list = getenv("PG_TEST_ASI_KEYS"); if (!list) return;
  char copy[256]; snprintf(copy, sizeof copy, "%s", list);
  for (char *item = strtok(copy, ","); item; item = strtok(0, ",")) {
    double at; int key; if (sscanf(item, "%lf:%i", &at, &key) != 2) continue;
    bool down = seconds >= at && seconds < at + 0.3;
    if (down != atomic_load(&pg_asi_keys[key & 255])) { PGAsiSetKey(key, down); char line[64]; snprintf(line, sizeof line, "TEST: mod key %d %s.", key, down ? "down" : "up"); pg_log(line); }
  }
}
#endif
#if TARGET_OS_SIMULATOR
// Test (PG_TEST_PLAYER_MODEL=name): from about 40 s in, the player becomes that model (default
// clothes) and the camera turns to face them, to look at skin mods. Calls game commands by their
// Script Hook V hashes, like a mod.
static uint64_t pg_test_native(uint64_t hash, const uint64_t *arguments, uint32_t count) {
  static uint64_t buffer;
  if (!buffer) buffer = pg_asi_alloc(8 * 40);
  memcpy(pg_pointer(&env, buffer, 8 * 32), arguments, 8 * count);
  memset(pg_pointer(&env, buffer + 8 * 32, 64), 0, 64);
  pg_asi_native(hash, buffer, count, buffer + 8 * 32);
  uint64_t value; memcpy(&value, pg_pointer(&env, buffer + 8 * 32, 8), 8); return value;
}
static void pg_test_player_model(w2c_game *instance) {
  static int frames, done;
  const char *name = getenv("PG_TEST_PLAYER_MODEL");
  if (!name || !*name || done > 1 || (PGGameStatus() & 16) || ++frames < 1200) return;
  pg_asi_game = instance;
  uint32_t model = 0; for (const char *c = name; *c; c++) { model += (uint8_t)(*c >= 'A' && *c <= 'Z' ? *c + 32 : *c); model += model << 10; model ^= model >> 6; }
  model += model << 3; model ^= model >> 11; model += model << 15;
  uint64_t previous = pg_asi_enter_script(instance);
  if (!done) {
    pg_test_native(0x963d27a58df860acull, (uint64_t[]){model}, 1);  // REQUEST_MODEL
    if (pg_test_native(0x98a4eb5d89a0c952ull, (uint64_t[]){model}, 1) & 1) {  // HAS_MODEL_LOADED
      uint64_t player = pg_test_native(0x4f8644af03d0e0d6ull, 0, 0) & 0xFFFFFFFF;  // PLAYER_ID
      pg_test_native(0x00a1cadd00108836ull, (uint64_t[]){player, model}, 2);  // SET_PLAYER_MODEL
      uint64_t ped = pg_test_native(0xd80958fc74e988a6ull, 0, 0) & 0xFFFFFFFF;  // PLAYER_PED_ID
      pg_test_native(0x45eee61580806d63ull, (uint64_t[]){ped}, 1);  // SET_PED_DEFAULT_COMPONENT_VARIATION
      // PG_TEST_PLAYER_CONTROL_OFF=1: player control off too, as the game reports it while playing as Chop (GTA-81).
      if (getenv("PG_TEST_PLAYER_CONTROL_OFF")) pg_test_native(0x8d32347d6d4c40a2ull, (uint64_t[]){player, 0, 0}, 3);  // SET_PLAYER_CONTROL
      done = 1; char line[96]; snprintf(line, sizeof line, "TEST: player model is now %s.", name); pg_log(line);
    } else if (frames > 2400) { done = 2; pg_log("TEST: player model did not load."); }
  }
  if (done == 1) {  // keep the camera in front of the player, looking slightly down
    float heading = 180, pitch = -5; uint32_t h, p; memcpy(&h, &heading, 4); memcpy(&p, &pitch, 4);
    pg_test_native(0xb4ec2312f4e5b1f1ull, (uint64_t[]){h}, 1);
    pg_test_native(0x6d0858b8edfd2b7dull, (uint64_t[]){p, 0x3f800000}, 2);
  }
  *(uint64_t *)pg_pointer(&env, instance->w2c_g1 + 3088, 8) = previous;
}
#endif
#if TARGET_OS_SIMULATOR
// Test (PG_TEST_TEXT=1): from about 40 s in, asks for text the way a trainer does (title label
// FMMC_KEY_TIP8, default "a80") and logs what comes back once the app's text box is answered.
static void pg_test_text(w2c_game *instance) {
  static int frames, stage;
  if (!getenv("PG_TEST_TEXT") || !*getenv("PG_TEST_TEXT") || stage > 1 || (PGGameStatus() & 16) || ++frames < 1200) return;
  pg_asi_game = instance;
  static uint64_t args; if (!args) args = pg_asi_alloc(8 * 16);
  uint64_t title = pg_asi_alloc(32), def = pg_asi_alloc(16), empty = pg_asi_alloc(8);
  if (!stage) {
    snprintf(pg_pointer(&env, title, 32), 32, "FMMC_KEY_TIP8"); snprintf(pg_pointer(&env, def, 16), 16, "a80"); *(char *)pg_pointer(&env, empty, 1) = 0;
    uint64_t a[8] = {0, title, empty, def, empty, empty, empty, 30};
    memcpy(pg_pointer(&env, args, 64), a, 64);
    pg_asi_text_command(0x00dc833f2568dbf6ull, args, 8, args + 64);
    stage = 1; return;
  }
  pg_asi_text_command(0x0cf2b696bbf945aeull, args, 0, args + 64);
  uint64_t state; memcpy(&state, pg_pointer(&env, args + 64, 8), 8);
  if (state == 1 || state == 2) {
    pg_asi_text_command(0x8362b09b91893647ull, args, 0, args + 64);
    uint64_t text; memcpy(&text, pg_pointer(&env, args + 64, 8), 8);
    char line[160]; snprintf(line, sizeof line, "TEST: text box answered (state %llu): \"%s\".", (unsigned long long)state, text ? pg_string(&env, text) : "(none)"); pg_log(line);
    stage = 2;
  }
}
#endif
#if TARGET_OS_SIMULATOR
// Test (PG_TEST_REQUEST_SCRIPT=<name>): about 40 s in, requests a script the way the phone does for its apps
// (REQUEST_SCRIPT), then logs every 2 s for 40 s whether it has loaded (HAS_SCRIPT_LOADED). The Trackify app's
// script (apptrackify) never finished loading for players, and the game froze waiting for it.
static void pg_test_request_script(w2c_game *instance) {
  static int frames, killFrames; static uint64_t name;
  const char *wanted = getenv("PG_TEST_REQUEST_SCRIPT");
  // PG_TEST_KILL_AT=<seconds>: the player dies then, while the script is still requested, as when the submarine
  // goes past crush depth; the respawn waits for every requested file.
  const char *killAt = getenv("PG_TEST_KILL_AT");
  if (wanted && killAt && killFrames >= 0 && !(PGGameStatus() & 16) && ++killFrames == atoi(killAt) * 30) {
    killFrames = -1; pg_asi_game = instance;
    const uint64_t previous = pg_asi_enter_script(instance);
    const uint64_t ped = pg_test_call(instance, 0xd80958fc74e988a6ull, 0, NULL) & 0xffffffff;   // PLAYER_PED_ID
    pg_test_call(instance, 0x6b76dc1f3ae6e6a3ull, 3, (uint64_t[]){ped, 0, 0});                  // SET_ENTITY_HEALTH
    pg_asi_leave_script(instance, previous);
    pg_log("TEST: player killed while the script is requested.");
  }
  if (!wanted || !*wanted || (PGGameStatus() & 16) || frames > 2400 || ++frames < 1200 || (frames - 1200) % 60) return;
  pg_asi_game = instance;
  if (!name) { name = pg_asi_alloc(64); snprintf(pg_pointer(&env, name, 64), 64, "%s", wanted); }
  // Script commands need a script to run in: "main" is lent, as for script mods.
  const uint64_t previous = pg_asi_enter_script(instance);
  if (frames == 1200) {
    pg_test_call(instance, 0x6eb5f71aa68f2e8eull, 1, (uint64_t[]){name});
    pg_asi_leave_script(instance, previous);
    char line[96]; snprintf(line, sizeof line, "TEST: requested script %s.", wanted); pg_log(line); return;
  }
  const uint64_t loaded = pg_test_call(instance, 0xe6cc9f3ba0fb9ef1ull, 1, (uint64_t[]){name}) & 0xff;
  pg_asi_leave_script(instance, previous);
  char line[96]; snprintf(line, sizeof line, "TEST: script %s loaded %llu after %d s.", wanted, (unsigned long long)loaded, (frames - 1200) / 30); pg_log(line);
  if (loaded && !killAt) frames = 9999;
}
// Test (PG_TEST_MISSING_TEXT=1): from about 40 s to 60 s, a help box with a label the game files don't have
// (AM_H_DRIVEBY, the drive-by help from a later update), shown every frame as a script does.
static void pg_test_missing_text(w2c_game *instance) {
  static int frames; static uint64_t label;
  if (!getenv("PG_TEST_MISSING_TEXT") || (PGGameStatus() & 16) || frames > 1800 || ++frames < 1200) return;
  pg_asi_game = instance;
  if (!label) { label = pg_asi_alloc(16); snprintf(pg_pointer(&env, label, 16), 16, "AM_H_DRIVEBY"); }
  if (frames == 1200) pg_log("TEST: help box with the missing label AM_H_DRIVEBY.");
  const uint64_t begin[1] = {label}, end[4] = {0, 0, 0, (uint64_t)-1};
  pg_test_call(instance, 0x8509b634fbe7da11ull, 1, begin);   // BEGIN_TEXT_COMMAND_DISPLAY_HELP
  pg_test_call(instance, 0x238ffe5c7b0498a6ull, 4, end);     // END_TEXT_COMMAND_DISPLAY_HELP
}
// Test (PG_TEST_TOOTH=1, GTA-94, GTA-82): mission prompts without the missions, each shown every frame as a script
// shows help (BEGIN/ADD/END_TEXT_COMMAND_DISPLAY_HELP). From about 40 s in, player control off and "Hold
// ~INPUT_SCRIPT_RT~ to grip a tooth." (By the Book, the prompt layout); from about 70 s, control on and RT named with
// the mission's rotate prompt, as the scene polls RT and the stick while pulling (the play layout); from about 100 s, control off and a stick
// with ~INPUT_CONTEXT~, as at a safehouse couch (GTA-82); from about 130 s, control off and Trevor's whiskey prompt
// (~INPUT_CONTEXT~ and ~INPUT_SCRIPT_RUP~, log 602); from about 160 s, control on and nothing.
static void pg_test_tooth(w2c_game *instance) {
  static int frames; static uint64_t label, texts[4];
  static const char *const prompts[4] = {"Hold ~INPUT_SCRIPT_RT~ to grip a tooth.",
    "Rotate ~PAD_RSTICK_ROTATE~ to pull it out.",   // the mission's own text (the harness in fbi3)
    "Use ~INPUT_SCRIPT_RIGHT_AXIS_X~ to change the channel. Press ~INPUT_CONTEXT~ to stand up.",
    "Press ~INPUT_CONTEXT~ to drink more whiskey.~n~Press ~INPUT_SCRIPT_RUP~ to stop drinking.~n~"};
  if (!getenv("PG_TEST_TOOTH") || (PGGameStatus() & 16) || frames > 4800 || ++frames < 1200) return;
  pg_asi_game = instance;
  if (!label) {
    label = pg_asi_alloc(16); snprintf(pg_pointer(&env, label, 16), 16, "STRING");
    for (int k = 0; k < 4; k++) { texts[k] = pg_asi_alloc(128); snprintf(pg_pointer(&env, texts[k], 128), 128, "%s", prompts[k]); }
  }
  const int phase = (frames - 1200) / 900;
  if ((frames - 1200) % 900 == 0) {
    const uint64_t control[3] = {pg_test_call(instance, 0x4f8644af03d0e0d6ull, 0, NULL), phase == 1 || phase == 4, 0};
    pg_test_call(instance, 0x8d32347d6d4c40a2ull, 3, control);   // SET_PLAYER_CONTROL(PLAYER_ID(), ...)
    char line[160]; snprintf(line, sizeof line, "TEST: prompt phase %d, control %s: %s", phase, control[1] ? "on" : "off", phase < 4 ? prompts[phase] : "(none)"); pg_log(line);
  }
  if (phase >= 4) return;
  // While RT is named with the right stick, what the game reads for INPUT_SCRIPT_RT (GET_CONTROL_NORMAL, frontend
  // control as the story scripts use it) every 2 s: 1 while the touch RT is latched.
  if (phase == 1 && (frames - 1200) % 60 == 0) {
    const uint64_t rt[2] = {2, 229}; const uint64_t read = pg_test_call(instance, 0xec3c9b8d5327b563ull, 2, rt);
    float value; uint32_t bits = (uint32_t)read; memcpy(&value, &bits, 4);
    char line[80]; snprintf(line, sizeof line, "TEST: the game reads INPUT_SCRIPT_RT as %.2f.", value); pg_log(line);
  }
  const uint64_t begin[1] = {label}, text[1] = {texts[phase]}, end[4] = {0, 0, 0, (uint64_t)-1};
  pg_test_call(instance, 0x8509b634fbe7da11ull, 1, begin);   // BEGIN_TEXT_COMMAND_DISPLAY_HELP
  pg_test_call(instance, 0x6c188be134e074aaull, 1, text);    // ADD_TEXT_COMPONENT_SUBSTRING_PLAYER_NAME
  pg_test_call(instance, 0x238ffe5c7b0498a6ull, 4, end);     // END_TEXT_COMMAND_DISPLAY_HELP
}
#endif
#if TARGET_OS_SIMULATOR
// Test (PG_TEST_PHONE=1, GTA-80): from about 40 s in, the game brings the phone out by itself for 15 s, as an
// incoming call does (CREATE_MOBILE_PHONE, then DESTROY_MOBILE_PHONE).
static void pg_test_phone(w2c_game *instance) {
  static int frames;
  if (!getenv("PG_TEST_PHONE") || (PGGameStatus() & 16) || frames > 1650 || ++frames < 1200) return;
  if (frames == 1200) { pg_test_call(instance, 0xa4e8e696c532fbc7ull, 1, (uint64_t[]){0}); pg_log("TEST: phone out by the game."); }
  if (frames == 1650) { pg_test_call(instance, 0x3bc861df703e5097ull, 0, NULL); pg_log("TEST: phone put away by the game."); }
}
#endif
#if TARGET_OS_SIMULATOR
// Test (PG_TEST_BLIPS=1): about 60 s in, every blip within 3 km of the player (sprite, colour, position), once.
static void pg_test_blips(w2c_game *instance) {
  static int frames;
  if (!getenv("PG_TEST_BLIPS") || (PGGameStatus() & 16) || frames < 0 || ++frames < 1800) return;
  frames = -1;
  uint64_t info, me; const uint8_t *m = (const uint8_t *)(void *)env.memory.data;
  if (!pg_context_u64(m, env.memory.size, 20159720, &info) || !info || !pg_context_u64(m, env.memory.size, info + 8, &me) || !me) return;
  const float *position = pg_pointer(&env, me + 144, 12); int found = 0;
  for (uint64_t sprite = 1; sprite < 830; sprite++) {
    for (uint64_t blip = pg_test_call(instance, 0x1bede233e6cd2a1full, 1, (uint64_t[]){sprite}) & 0xffffffff; blip;
         blip = pg_test_call(instance, 0x14f96aa50d6fbea7ull, 1, (uint64_t[]){sprite}) & 0xffffffff) {
      pg_test_call(instance, 0xfa7c7f0aadf25d09ull, 1, (uint64_t[]){blip});
      const uint8_t *r = pg_pointer(&env, pg_test_buffer + 8 * 32, 24); float c[3]; memcpy(&c[0], r, 4); memcpy(&c[1], r + 8, 4); memcpy(&c[2], r + 16, 4);
      if ((c[0] - position[0]) * (c[0] - position[0]) + (c[1] - position[1]) * (c[1] - position[1]) > 3000.f * 3000.f) continue;
      const uint32_t colour = (uint32_t)pg_test_call(instance, 0xdf729e8d20cf7327ull, 1, (uint64_t[]){blip});
      char line[120]; snprintf(line, sizeof line, "TEST: blip sprite %llu colour %u at %.1f, %.1f, %.1f.", (unsigned long long)sprite, colour, c[0], c[1], c[2]); pg_log(line);
      if (++found > 200) return;
    }
  }
}
// Test (PG_TEST_RACE=1): a race autopilot. Every 1.5 s while the player drives with control on, the vehicle is
// moved to the nearest yellow blip (a race checkpoint; colours other than yellow are skipped), so a street race
// finishes in a minute and its result screen can be checked. Every blip is logged once.
static void pg_test_race(w2c_game *instance) {
  static int frames; static bool listed; static float lastX, lastY;
  if (!getenv("PG_TEST_RACE") || (PGGameStatus() & (1 | 16)) || ++frames % 45) return;
  const uint64_t ped = pg_test_call(instance, 0xd80958fc74e988a6ull, 0, NULL) & 0xffffffff;   // PLAYER_PED_ID
  const uint64_t inVehicle[2] = {ped, 0};
  const uint64_t vehicle = pg_test_call(instance, 0x9a9112a0fe9a4713ull, 2, inVehicle) & 0xffffffff;   // GET_VEHICLE_PED_IS_IN
  if (!vehicle) return;
  const float *position = NULL; uint64_t info, me;
  const uint8_t *m = (const uint8_t *)(void *)env.memory.data;
  if (pg_context_u64(m, env.memory.size, 20159720, &info) && info && pg_context_u64(m, env.memory.size, info + 8, &me) && me) position = pg_pointer(&env, me + 144, 12);
  if (!position) return;
  float best = 1e9f, target[3] = {0};
  for (uint64_t blip = pg_test_call(instance, 0x1bede233e6cd2a1full, 1, (uint64_t[]){1}) & 0xffffffff; blip;   // GET_FIRST_BLIP_INFO_ID(1)
       blip = pg_test_call(instance, 0x14f96aa50d6fbea7ull, 1, (uint64_t[]){1}) & 0xffffffff) {            // GET_NEXT_BLIP_INFO_ID(1)
    const uint32_t colour = (uint32_t)pg_test_call(instance, 0xdf729e8d20cf7327ull, 1, (uint64_t[]){blip});      // GET_BLIP_COLOUR
    pg_test_call(instance, 0xfa7c7f0aadf25d09ull, 1, (uint64_t[]){blip});                                    // GET_BLIP_INFO_ID_COORD
    const uint8_t *r = pg_pointer(&env, pg_test_buffer + 8 * 32, 24); float c[3]; memcpy(&c[0], r, 4); memcpy(&c[1], r + 8, 4); memcpy(&c[2], r + 16, 4);
    if (!listed) { char line[120]; snprintf(line, sizeof line, "TEST: race blip %llu colour %u at %.1f, %.1f, %.1f.", (unsigned long long)blip, colour, c[0], c[1], c[2]); pg_log(line); }
    if (colour != 5 && colour != 66) continue;
    const float d = (c[0] - position[0]) * (c[0] - position[0]) + (c[1] - position[1]) * (c[1] - position[1]);
    if (d < best && d > 4.f && !(c[0] == lastX && c[1] == lastY)) { best = d; memcpy(target, c, sizeof target); }
  }
  listed = true;
  if (best > 1e8f) return;
  uint32_t fx, fy, fz; const float z = target[2] + 1.0f; memcpy(&fx, &target[0], 4); memcpy(&fy, &target[1], 4); memcpy(&fz, &z, 4);
  const uint64_t move[8] = {vehicle, fx, fy, fz, 0, 0, 0, 0};
  pg_test_call(instance, 0x06843da7060a026bull, 8, move);   // SET_ENTITY_COORDS
  lastX = target[0]; lastY = target[1];
  char line[96]; snprintf(line, sizeof line, "TEST: race autopilot to %.1f, %.1f, %.1f.", target[0], target[1], target[2]); pg_log(line);
}
#endif
#if TARGET_OS_SIMULATOR
// Test (PG_TEST_SPAWN="adder,buzzard2,..."): Settings › Cheats › Spawn vehicle without the screen. About
// 40 s in, logs how many vehicles the menu lists and how many have the game's own names, then spawns
// each model in turn through PGSpawnVehicle (the next once the last one finished), logging the name
// and class the menu shows for it and how the spawn ended. Three or more spawns exercise the menu's
// two-vehicle limit. PG_TEST_SPAWN_ENTER=1 puts the player in each one.
static void pg_test_spawn(void) {
  static int frames, index = -1; static bool waiting, counted;
  const char *list = getenv("PG_TEST_SPAWN");
  if (!list || !*list || index == -2 || (PGGameStatus() & 16) || ++frames < 1200) return;
  char line[200];
  if (!counted) {
    const int32_t count = PGVehicleCatalogCount(); int named = 0;
    if (count == -1 && frames < 1800) return;   // still reading the list
    PGVehicleEntry entry;
    for (int32_t i = 0; i < count; i++) if (PGVehicleCatalogEntryAt((uint32_t)i, &entry) && entry.label[0]) named++;
    snprintf(line, sizeof line, "TEST: the vehicle menu lists %d models, %d with the game's own names.", count, named); pg_log(line);
    counted = true;
  }
  if (waiting) {
    const PGVehicleSpawnStatus status = PGGetVehicleSpawnStatus();
    if (status == PGVehicleSpawnWaiting || status == PGVehicleSpawnLoading) return;
    snprintf(line, sizeof line, "TEST: spawn %d finished with status %d (3 spawned, 4 unavailable, 6 not ready, 9 vehicle limit).", index, status); pg_log(line);
    waiting = false;
  }
  char names[512], *name = NULL, *rest = NULL; snprintf(names, sizeof names, "%s", list);
  int at = 0;
  for (char *item = strtok_r(names, ",", &rest); item; item = strtok_r(NULL, ",", &rest), at++) if (at == index + 1) { name = item; break; }
  if (!name) { index = -2; pg_log("TEST: spawn list done."); return; }
  index++;
  uint32_t model = 0; for (const char *c = name; *c; c++) { model += (uint8_t)(*c >= 'A' && *c <= 'Z' ? *c + 32 : *c); model += model << 10; model ^= model >> 6; }
  model += model << 3; model ^= model >> 11; model += model << 15;
  PGVehicleEntry entry = {0}; bool listed = false;
  for (int32_t i = 0; i < PGVehicleCatalogCount() && !listed; i++) listed = PGVehicleCatalogEntryAt((uint32_t)i, &entry) && entry.model == model;
  const bool enter = getenv("PG_TEST_SPAWN_ENTER") && atoi(getenv("PG_TEST_SPAWN_ENTER"));
  waiting = PGSpawnVehicle(model, enter);
  if (listed) snprintf(line, sizeof line, "TEST: spawn %d: %s, listed as \"%s\" (class %u)%s.", index, name, entry.label, entry.vehicleClass, waiting ? "" : ", refused");
  else snprintf(line, sizeof line, "TEST: spawn %d: %s (0x%08x), not in the menu's list%s.", index, name, model, waiting ? "" : ", refused");
  pg_log(line);
}
// Test (PG_TEST_CHEAT="god,wanted,time:18,weather:5,natural,repair,clean"): Settings › Cheats without
// the screen. With "god" or "wanted", about 40 s in the player gets two wanted stars and the God mode /
// Never wanted switches go on; what the game itself then says (GET_PLAYER_INVINCIBLE,
// GET_PLAYER_WANTED_LEVEL, GET_MAX_WANTED_LEVEL) is logged at 45 s, the switches go off at 50 s and
// it's logged again at 55 s. The other names are one-off actions (an hour, a weather 0-6), queued one
// after another from 40 s, each logged as it finishes; repair and clean need PG_TEST_SPAWN_ENTER.
static void pg_test_cheat_report(w2c_game *instance, const char *when) {
  const uint64_t previous = pg_asi_enter_script(instance);
  const uint64_t player = pg_test_call(instance, 0x4f8644af03d0e0d6ull, 0, NULL) & 0xffffffff;   // PLAYER_ID
  const int invincible = (int)(pg_test_call(instance, 0xb721981b2b939e07ull, 1, (uint64_t[]){player}) & 1);   // GET_PLAYER_INVINCIBLE
  const int wanted = (int)(uint32_t)pg_test_call(instance, 0xe28e54788ce8f12dull, 1, (uint64_t[]){player});   // GET_PLAYER_WANTED_LEVEL
  const int limit = (int)(uint32_t)pg_test_call(instance, 0x462e0db9b137dc5full, 0, NULL);   // GET_MAX_WANTED_LEVEL
  pg_asi_leave_script(instance, previous);
  char line[160]; snprintf(line, sizeof line, "TEST: cheats %s: switches god %d wanted %d; the game says invincible %d, wanted level %d, wanted limit %d.",
                           when, PGCheatEnabled(PGCheatGodMode), PGCheatEnabled(PGCheatNeverWanted), invincible, wanted, limit);
  pg_log(line);
}
static void pg_test_cheat(w2c_game *instance) {
  static int frames, next; static bool waiting, done; static PGCheatCommand last;
  const char *list = getenv("PG_TEST_CHEAT");
  if (!list || !*list || (PGGameStatus() & 16) || ++frames < 1200) return;
  const bool god = strstr(list, "god") != NULL, wanted = strstr(list, "wanted") != NULL;
  if ((god || wanted) && frames == 1200) {
    if (wanted) {
      const uint64_t previous = pg_asi_enter_script(instance);
      const uint64_t player = pg_test_call(instance, 0x4f8644af03d0e0d6ull, 0, NULL) & 0xffffffff;   // PLAYER_ID
      pg_test_call(instance, 0x39ff19c64ef7da5bull, 3, (uint64_t[]){player, 2, 0});   // SET_PLAYER_WANTED_LEVEL
      pg_test_call(instance, 0xe0a7d1e497ffcd6full, 2, (uint64_t[]){player, 0});      // SET_PLAYER_WANTED_LEVEL_NOW
      pg_asi_leave_script(instance, previous);
    }
    pg_test_cheat_report(instance, "before");
    if (god) PGSetPersistentCheatEnabled(PGCheatGodMode, true);
    if (wanted) PGSetPersistentCheatEnabled(PGCheatNeverWanted, true);
  }
  if ((god || wanted) && frames == 1350) pg_test_cheat_report(instance, "on");
  if ((god || wanted) && frames == 1500) {
    if (god) PGSetPersistentCheatEnabled(PGCheatGodMode, false);
    if (wanted) PGSetPersistentCheatEnabled(PGCheatNeverWanted, false);
  }
  if ((god || wanted) && frames == 1650) pg_test_cheat_report(instance, "off again");
  if (done) return;
  char line[160];
  if (waiting) {
    const PGCheatStatus status = PGGetCheatStatus();
    if (status == PGCheatWaiting) return;
    snprintf(line, sizeof line, "TEST: cheat action %d finished with status %d (2 done, 3 no vehicle, 4 not ready).", next - 1, status); pg_log(line);
    if (last == PGCheatSetTime) {
      const uint64_t previous = pg_asi_enter_script(instance);
      snprintf(line, sizeof line, "TEST: the game's clock says %d o'clock.", (int)(uint32_t)pg_test_call(instance, 0x25223ca6b4d20b7full, 0, NULL)); pg_log(line);   // GET_CLOCK_HOURS
      pg_asi_leave_script(instance, previous);
    }
    waiting = false;
  }
  char names[256]; snprintf(names, sizeof names, "%s", list);
  char *name = NULL, *rest = NULL; int at = 0;
  for (char *item = strtok_r(names, ",", &rest); item; item = strtok_r(NULL, ",", &rest)) {
    if (!strcmp(item, "god") || !strcmp(item, "wanted")) continue;
    if (at++ == next) { name = item; break; }
  }
  if (!name) { done = true; return; }
  next++;
  PGCheatCommand command; int32_t value = 0;
  if (!strncmp(name, "time:", 5)) { command = PGCheatSetTime; value = atoi(name + 5); }
  else if (!strncmp(name, "weather:", 8)) { command = PGCheatSetWeather; value = atoi(name + 8); }
  else if (!strcmp(name, "natural")) command = PGCheatNaturalWeather;
  else if (!strcmp(name, "repair")) command = PGCheatRepairVehicle;
  else if (!strcmp(name, "clean")) command = PGCheatCleanVehicle;
  else { snprintf(line, sizeof line, "TEST: unknown cheat \"%s\".", name); pg_log(line); return; }
  waiting = PGQueueCheat(command, value); last = command;
  snprintf(line, sizeof line, "TEST: cheat action %d: %s%s.", next - 1, name, waiting ? " queued" : " refused"); pg_log(line);
}
#endif
// Loads every .asi in the Mods folder once the player exists, then runs their scripts each frame.
static void pg_asi_frame(w2c_game *instance) {
  static int state;  // 0 not loaded yet, 1 running, -1 no script mods
  if (state < 0 || (PGGameStatus() & 16)) return;
  pg_asi_game = instance;
  uint64_t previous = pg_asi_enter_script(instance);
  if (!state) {
    state = -1;
    const char *folder = pg_mods_folder_path();
    PGAsiHost host = { (uint8_t *)env.memory.data, env.memory.max_pages * env.memory.page_size, pg_asi_alloc, pg_asi_free, pg_asi_log, pg_asi_native, 0, pg_asi_key_down, 0, 2189, folder };
    // Scripts sit at the top of Mods, or at the top of a mod's own folder (Settings › Mods installs them
    // so; a folder ending in ".off" is switched off). Each script's folder holds its settings.
    char places[64][PATH_MAX]; int placeCount = 0;
    snprintf(places[placeCount++], PATH_MAX, "%s", folder);
    DIR *top = opendir(folder); struct dirent *entry; int loaded = 0;
    while (top && (entry = readdir(top)) && placeCount < 64) {
      size_t n = strlen(entry->d_name);
      if (entry->d_name[0] == '.' || (n > 4 && !strcasecmp(entry->d_name + n - 4, ".off"))) continue;
      char path[PATH_MAX]; snprintf(path, sizeof path, "%s/%s", folder, entry->d_name);
      struct stat info; if (stat(path, &info) || !S_ISDIR(info.st_mode)) continue;
      snprintf(places[placeCount++], PATH_MAX, "%s", path);
    }
    if (top) closedir(top);
    for (int place = 0; place < placeCount; place++) {
      DIR *dir = opendir(places[place]);
      while (dir && (entry = readdir(dir))) {
        size_t n = strlen(entry->d_name);
        if (n < 5 || strcasecmp(entry->d_name + n - 4, ".asi")) continue;
        // ScriptHookVDotNet's loader runs C# scripts on Windows .NET, and OpenIV's is for the PC: neither can run here.
        if (!strncasecmp(entry->d_name, "ScriptHookVDotNet", 17) || !strcasecmp(entry->d_name, "OpenIV.asi")) {
          char line[PATH_MAX + 96]; snprintf(line, sizeof line, "Script mods: %s needs Windows (ScriptHookVDotNet or OpenIV); not loaded.", entry->d_name); pg_log(line); continue;
        }
        if (!loaded && !pg_asi_init(&host)) { pg_log("Script mods: the interpreter could not start."); break; }
        char path[PATH_MAX]; snprintf(path, sizeof path, "%s/%s", places[place], entry->d_name);
        FILE *file = fopen(path, "rb"); if (!file) continue;
        fseek(file, 0, SEEK_END); long size = ftell(file); rewind(file);
        uint8_t *bytes = size > 0 && size < (256l << 20) ? malloc((size_t)size) : 0;
        if (bytes && fread(bytes, 1, (size_t)size, file) == (size_t)size && pg_asi_load(entry->d_name, places[place], bytes, (uint64_t)size)) { loaded++; pg_mod_path_used(path); }
        free(bytes); fclose(file);
      }
      if (dir) closedir(dir);
    }
    if (loaded) { state = 1; char line[96]; snprintf(line, sizeof line, "Script mods active: %d .asi file%s (Script Hook V layer).", loaded, loaded == 1 ? "" : "s"); pg_log(line); }
  }
  if (state > 0) {
    static double started; if (!started) started = timeMS(CLOCK_MONOTONIC);
#if TARGET_OS_SIMULATOR
    pg_asi_test_keys((timeMS(CLOCK_MONOTONIC) - started) / 1000.0);
#endif
    while (atomic_load(&pg_asi_key_tail) != atomic_load(&pg_asi_key_head)) {
      uint32_t event = atomic_load(&pg_asi_key_events[atomic_fetch_add(&pg_asi_key_tail, 1) % 64]);
      pg_asi_key((int)(event & 255), event & 0x100);
    }
    pg_asi_tick();
    static unsigned frames; static uint64_t micros, instructions;
    uint64_t us, count; pg_asi_stats(&us, &count); micros += us; instructions += count;
    if (++frames % 900 == 0) {
      char line[128]; snprintf(line, sizeof line, "Script mods: %.2f ms and %llu instructions per frame on average.", micros / 900.0 / 1000.0, (unsigned long long)(instructions / 900));
      pg_log(line); micros = instructions = 0;
    }
  }
  *(uint64_t *)pg_pointer(&env, instance->w2c_g1 + 3088, 8) = previous;
}
// The game runs each of its scripts once per frame on the main game thread (scrThread::Run, wrapped by
// Scripts/prepare_asi_script_tick.py); script mods get their turn just before the "main" script, and
// so does Settings › Cheats (vehicles must not be created from the controller thread, see
// NativeVehicleSpawn.inc). A paused (suspended) script isn't run, so neither are these.
// Trailers: unhitching one is holding the headlight input, which nobody guesses on touch, so the touch controls
// show a Detach trailer button while the player's vehicle pulls a trailer (GTA-76). Checked here on the game thread
// every 15 frames (IS_VEHICLE_ATTACHED_TO_TRAILER on the vehicle the player is in).
static uint64_t pg_f32_arg(float value);
static uint32_t pgSubmarine;
// Submersibles hold out to 200 m (GTA-134). The Merryweather Heist's device lies about 180 m down; the engine's
// default crush depths are -150/-170/-185 m, and a script's SET_SUBMARINE_CRUSH_DEPTHS lasts one frame only
// (CSubmarineHandling::ProcessCrushDepth clears it on the frame's last physics step), so it is set every frame while
// the player is in a submersible. In the simulator the sub imploded beside the device without it.
static void pg_submarine_depth_tick(w2c_game *instance) {
  if (!pgSubmarine || (PGGameStatus() & 16)) return;
  pg_asi_game = instance;
  const uint64_t previous = pg_asi_enter_script(instance);
  const uint64_t depth = pg_f32_arg(-200.0f);
  pg_test_call(instance, 0xc59872a5134879c7ull, 5, (uint64_t[]){pgSubmarine, 0, depth, depth, depth});   // SET_SUBMARINE_CRUSH_DEPTHS
  pg_asi_leave_script(instance, previous);
}
static void pg_trailer_tick(w2c_game *instance) {
  static unsigned frames;
  if (++frames % 15 || (PGGameStatus() & 16)) return;
  pg_asi_game = instance;
  const uint64_t previous = pg_asi_enter_script(instance);
  const uint64_t ped = pg_test_call(instance, 0xd80958fc74e988a6ull, 0, NULL) & 0xffffffff;                    // PLAYER_PED_ID
  const uint64_t vehicle = pg_test_call(instance, 0x9a9112a0fe9a4713ull, 2, (uint64_t[]){ped, 0}) & 0xffffffff;  // GET_VEHICLE_PED_IS_IN
  const uint64_t answer = vehicle && vehicle != 0xffffffff ? pg_test_call(instance, 0xe7cf3c4f9f489f0cull, 1, (uint64_t[]){vehicle}) : 0;  // IS_VEHICLE_ATTACHED_TO_TRAILER
  const bool attached = answer != (uint64_t)-1 && (answer & 1);
  // The submersible the player is in, if any, for pg_submarine_depth_tick (checked here twice a second).
  uint32_t sub = 0;
  if (vehicle && vehicle != 0xffffffff) {
    const uint32_t model = (uint32_t)pg_test_call(instance, 0x9f47b058362c84b5ull, 1, (uint64_t[]){vehicle});   // GET_ENTITY_MODEL
    if (model == 0x2dff622fu || model == 0xc07107eeu) sub = (uint32_t)vehicle;   // submersible, submersible2
  }
  pgSubmarine = sub;
  pg_asi_leave_script(instance, previous);
  atomic_store(&pg_trailer_attached, attached);
}
// Trackify (GTA-134). The players' game files have apptrackify.ysc only as a 5-byte stub (GTA-102), so the phone's
// Trackify app never ran and The Merryweather Heist (Offshore), Fresh Meat, scuba diving and the nuclear waste hunt had
// no way to find their targets. While the phone waits for Trackify (its app state is 7 and the selected app is
// appTrackify, which the request guard turns away), this does what the app script does: every 125 ms it gives the
// phone's own Trackify screen (view 23) the target's angle from where the player faces, its distance and its height,
// and pings (APP_FUNCTION 1) faster as the player gets closer. Script globals of the pinned build (the PC build's
// minus 683 for the phone, minus 666 for its flags): phone app state 20384, phone movie 20364, flags 8254/8255, the
// mission's Trackify target PG_TRACKIFY_TARGET.
#define PG_TRACKIFY_TARGET 22831   // the PC build's Global_23531 less 700 (harness: the Offshore heist's device, 180 m down)
static uint32_t pg_global_u32(uint64_t index) {
  const uint64_t at = pg_script_global(index); uint32_t value = 0;
  if (at) memcpy(&value, pg_pointer(&env, at, 4), 4);
  return value;
}
static float pg_global_f32(uint64_t index) { const uint32_t bits = pg_global_u32(index); float value; memcpy(&value, &bits, 4); return value; }
// Open from the phone's request for apptrackify (missions open it directly by its table index, 17, so the phone's
// "selected app" global doesn't say which app it is; the request comes once, then the phone waits) until the phone
// leaves its app state (7): Back, or the phone put away.
static bool pg_trackify_open(void) {
  static bool open;
  if (pg_global_u32(20384) != 7) open = false;
  else if (timeMS(CLOCK_MONOTONIC) - atomic_load(&pgTrackifyRequestedAt) < 1000) open = true;
  return open;
}
static uint64_t pg_wasm_text(uint64_t *slot, const char *text) {
  if (!*slot) { *slot = pg_asi_alloc(strlen(text) + 1); if (*slot) memcpy(pg_pointer(&env, *slot, strlen(text) + 1), text, strlen(text) + 1); }
  return *slot;
}
static uint64_t pg_f32_arg(float value) { uint32_t bits; memcpy(&bits, &value, 4); return bits; }
static void pg_trackify_tick(w2c_game *instance) {
  static double lastData, lastPing; static bool wasOpen;
  if (PGGameStatus() & 16) return;
  const bool open = pg_trackify_open();
  if (open != wasOpen) { wasOpen = open; pg_log(open ? "Trackify: opened (port-made app, GTA-134)." : "Trackify: closed."); }
  if (!open) return;
  const double now = timeMS(CLOCK_MONOTONIC);
  if (now - lastData < 125) return;
  lastData = now;
  pg_asi_game = instance;
  const float target[3] = {pg_global_f32(PG_TRACKIFY_TARGET), pg_global_f32(PG_TRACKIFY_TARGET + 1), pg_global_f32(PG_TRACKIFY_TARGET + 2)};
  const uint64_t movie = pg_global_u32(20364);
  if (!movie || (target[0] == 0 && target[1] == 0)) return;
  const uint64_t previous = pg_asi_enter_script(instance);
  const uint64_t ped = pg_test_call(instance, 0xd80958fc74e988a6ull, 0, NULL) & 0xffffffff;   // PLAYER_PED_ID
  pg_test_call(instance, 0x3fef770d40960d5aull, 2, (uint64_t[]){ped, 1});                     // GET_ENTITY_COORDS
  float player[3] = {0, 0, 0};
  for (int k = 0; k < 3; k++) memcpy(&player[k], pg_pointer(&env, pg_test_buffer + 8 * 32 + 8 * k, 4), 4);
  const uint64_t headingBits = pg_test_call(instance, 0xe83d4f9ba2a38914ull, 1, (uint64_t[]){ped});  // GET_ENTITY_HEADING
  float heading; uint32_t hb = (uint32_t)headingBits; memcpy(&heading, &hb, 4);
  const float dx = target[0] - player[0], dy = target[1] - player[1], dz = target[2] - player[2];
  // Angle on the screen: the bearing (clockwise from north) less the way the player faces (the game's heading turns
  // anticlockwise), 0-360.
  float angle = atan2f(dx, dy) * 180.0f / (float)M_PI + heading;
  angle = fmodf(fmodf(angle, 360.0f) + 360.0f, 360.0f);
  const float flat = sqrtf(dx * dx + dy * dy), full = sqrtf(dx * dx + dy * dy + dz * dz);
  static uint64_t setDataSlot, displayView, appFunction;
  const uint32_t flags = pg_global_u32(8254), flags2 = pg_global_u32(8255);   // the PC build's Global_8920 and 8921, less 666
  pg_test_call(instance, 0xf6e48914c7a8694eull, 2, (uint64_t[]){movie, pg_wasm_text(&setDataSlot, "SET_DATA_SLOT")});
  pg_test_call(instance, 0xc3d0841a0cc546a6ull, 1, (uint64_t[]){23});
  pg_test_call(instance, 0xc3d0841a0cc546a6ull, 1, (uint64_t[]){0});
  pg_test_call(instance, 0xc3d0841a0cc546a6ull, 1, (uint64_t[]){(uint32_t)(int32_t)floorf(angle)});
  pg_test_call(instance, 0xc3d0841a0cc546a6ull, 1, (uint64_t[]){(uint32_t)(int32_t)floorf(flat)});
  pg_test_call(instance, 0xc3d0841a0cc546a6ull, 1, (uint64_t[]){100});
  pg_test_call(instance, 0xc3d0841a0cc546a6ull, 1, (uint64_t[]){(flags >> 22) & 1});
  pg_test_call(instance, 0xc58424ba936eb458ull, 1, (uint64_t[]){(flags >> 29) & 1 ? 0 : 1});
  if ((flags2 >> 1) & 1) pg_test_call(instance, 0xd69736aae04db51aull, 1, (uint64_t[]){pg_f32_arg(dz)});
  pg_test_call(instance, 0xc6796a8ffa375e53ull, 0, NULL);
  pg_test_call(instance, 0xf6e48914c7a8694eull, 2, (uint64_t[]){movie, pg_wasm_text(&displayView, "DISPLAY_VIEW")});
  pg_test_call(instance, 0xc3d0841a0cc546a6ull, 1, (uint64_t[]){23});
  pg_test_call(instance, 0xc3d0841a0cc546a6ull, 1, (uint64_t[]){1});
  pg_test_call(instance, 0xc6796a8ffa375e53ull, 0, NULL);
  // The ping: more often the closer the target (30 ms a metre, at least 150 ms apart), at least every 2 s.
  const double gap = now - lastPing;
  if ((gap > floorf(full) * 30 && gap > 150) || gap > 2000) {
    lastPing = now;
    pg_test_call(instance, 0xf6e48914c7a8694eull, 2, (uint64_t[]){movie, pg_wasm_text(&appFunction, "APP_FUNCTION")});
    pg_test_call(instance, 0xc3d0841a0cc546a6ull, 1, (uint64_t[]){1});
    pg_test_call(instance, 0xc6796a8ffa375e53ull, 0, NULL);
  }
  pg_asi_leave_script(instance, previous);
}
#if TARGET_OS_SIMULATOR
// Harness: the debug channel's "audiodump <path> <seconds>" saves the next seconds of the game's sound (48 kHz,
// stereo float32, interleaved), so a test can check what played (Self Radio, GTA-5).
static FILE *pg_audio_dump; static _Atomic int64_t pg_audio_dump_frames;
#include "NativeDebugChannel.inc"
#endif
void pg_asi_script_tick(w2c_game *instance, u64 thread) {
#if TARGET_OS_SIMULATOR
  if (thread && strcmp(pg_string(&env, thread + 428), "main")) pg_debug_tick(instance, false);
#endif
  if (!thread || strcmp(pg_string(&env, thread + 428), "main")) return;
  pg_asi_frame(instance);
  pg_trailer_tick(instance);
  pg_submarine_depth_tick(instance);
  pg_cheats_menu_tick(instance);
  pg_trackify_tick(instance);
#if TARGET_OS_SIMULATOR
  pg_debug_tick(instance, true);
  pg_test_spawn();
  pg_test_cheat(instance);
  pg_test_text(instance);
  pg_test_player_model(instance);
  pg_test_tooth(instance);
  pg_test_missing_text(instance);
  pg_test_request_script(instance);
  pg_test_phone(instance);
  pg_test_race(instance);
  pg_test_blips(instance);
#endif
}
void pg_virtual_pad_apply(w2c_game *instance, uint64_t pad) {
  if (pad == 12840656) pg_next_aircraft_weapon(instance);
  if (pad == 12840656) pg_apply_cash_request(instance);
  if (pad == 12840656) pg_apply_lite(instance);
  if (pad == 12840656) pg_apply_targeting_mode(instance);
  if (pad == 12840656) pg_apply_self_radio_mode(instance);
  if (pad == 12840656) pg_tv_presentation_update(instance);
  if (pad == 12840656) pg_keep_on_test_map(instance);
  if (pad == 12840656) pg_keep_weapon_loaded(instance);
  if (pad == 12840656) pg_trace_stream_loads(instance);
#if TARGET_OS_SIMULATOR
  if (pad == 12840656) { pg_test_teleport(instance); pg_test_stale_job(instance); pg_test_speed(instance); pg_test_weapon(instance); pg_test_outfit(instance); pg_test_prompts(instance); pg_test_cash(instance); pg_test_tv(instance); pg_test_tv_flood(instance); pg_test_gfx_dirty(instance); pg_test_position(); pg_test_video(instance); pg_test_lester1_tv(instance); pg_test_photo(instance); pg_test_car(instance); pg_test_trailer_monitor(instance); pg_test_request_models(instance); pg_test_loadscene(instance); pg_test_loadscene_monitor(instance); }
#endif
  if (pad != 12840656 || !atomic_load(&virtualPadActive)) return;
  uint64_t packed = atomic_load(&virtualPad);
  // Use the last actual engine-sample interval (not display-link callbacks).
  static _Thread_local double lastSwipePollMS;
  const double nowMS = timeMS(CLOCK_MONOTONIC);
  const double elapsed = lastSwipePollMS > 0 ? fmax(1.0/240.0, fmin(0.0667, (nowMS - lastSwipePollMS) / 1000.0)) : 1.0/60.0;
  lastSwipePollMS = nowMS;
  const float dx = (float)atomic_exchange(&pendingCameraSwipeX, 0) / PG_CAMERA_SWIPE_SCALE;
  const float dy = (float)atomic_exchange(&pendingCameraSwipeY, 0) / PG_CAMERA_SWIPE_SCALE;
  // The selection wheels own the stick even when a look finger is down.
  const bool selectionWheel = (packed & ((1ull << 2) | (1ull << 14))) != 0;
  if (!selectionWheel && (dx != 0 || dy != 0)) {
    const float baseX = ((packed >> 32 & 255) - 127.5f) / 127.5f;
    const float baseY = (127.5f - (packed >> 40 & 255)) / 127.5f;
    const float lookX = fmaxf(-1, fminf(1, baseX + pg_camera_swipe_axis(dx, elapsed)));
    const float lookY = fmaxf(-1, fminf(1, baseY + pg_camera_swipe_axis(dy, elapsed)));
    packed = (packed & ~(0xffffull << 32)) |
      (uint64_t)pg_pad_axis(lookX, false) << 32 |
      (uint64_t)pg_pad_axis(lookY, true) << 40;
  }
  uint8_t *base = pg_pointer(&env, pad, 136);
  _Atomic uint32_t *buttons = (_Atomic uint32_t *)(base + 12);
  uint32_t bits = (uint32_t)(packed & 0xffff);
  if (atomic_load(&pauseFrames) > 0 && atomic_fetch_sub(&pauseFrames, 1) > 0) {
    bits |= 1u << 11;   // Start
    if (atomic_load(&pauseFrames) == 0) pg_log("Pause menu: Start pressed for the app going inactive.");
  }
  uint8_t l2 = packed >> 48, r2 = packed >> 56;
  // Analog triggers also count as pressed buttons past a small threshold.
  if (l2 > 30) bits |= 1; if (r2 > 30) bits |= 2;
  atomic_store(buttons, atomic_load(buttons) | bits);
  for (int i = 0; i < 4; i++) atomic_store((_Atomic uint8_t *)(base + 20 + i), (uint8_t)(packed >> (16 + 8 * i)));
  atomic_store((_Atomic uint8_t *)(base + 24), l2);
  atomic_store((_Atomic uint8_t *)(base + 25), r2);
}
// Videos on TVs and in some cutscenes: the engine waits for one to load with no time limit
// (Scripts/prepare_movie_wait.py). The game files have no .bik videos, and a load that never
// answered froze the game whenever a TV came on. After 2 s the video is marked as failed, as
// CMovie::LoadedAsyncCb does itself (bit 32 of the flags at +96), and later videos fail at once.
static _Atomic int videosUnavailable;
void pg_movie_wait(w2c_game *instance, uint64_t movie) {
  static _Thread_local uint64_t waitingFor;
  static _Thread_local double since, last;
  double now = timeMS(CLOCK_MONOTONIC);
  if (waitingFor != movie || now - last > 100) { waitingFor = movie; since = now; }
  last = now;
  bool limit = true;
#if TARGET_OS_SIMULATOR
  limit = !getenv("PG_TEST_VIDEO_NO_LIMIT"); // reproduces the old behaviour
#endif
  if (limit && (atomic_load(&videosUnavailable) || now - since > 2000)) {
    atomic_fetch_or((_Atomic uint32_t *)pg_pointer(&env, movie + 96, 4), 32);
    if (!atomic_exchange(&videosUnavailable, 1)) pg_log("A video (TV or cutscene) did not load within 2 s; videos are skipped from now on.");
    waitingFor = 0;
    return;
  }
  PG_FN_SYS_IPC_SLEEP(instance, 1);
}
// The show GET_CURRENT_TV_SHOW_PLAY_TIME, GET_CURRENT_TV_SHOW_DURATION and IS_TVSHOW_CURRENTLY_PLAYING
// answer about (Scripts/prepare_tv_without_video.py). The engine only counts a show whose video has
// loaded (the cached show), and no video ever loads here, so these answered 0 and a mission that
// waits for a moment in a show waited forever (Friend Request, GTA-22). Without a cached show they
// answer about the channel's current show from its playlist, as GET_CURRENT_TV_CLIP_NAMEHASH does:
// its play time moves on with the channel's clock. Both addresses hold a pointer to the show's info.
u64 pg_tv_current_show(w2c_game *instance, u64 cached, u64 current, u64 channel) {
  uint64_t show = *(uint64_t *)pg_pointer(&env, cached, 8);
#if TARGET_OS_SIMULATOR
  if (getenv("PG_TEST_TV_SHOW_OLD")) return show; // reproduces the old behaviour
#endif
  if (show || *(int32_t *)pg_pointer(&env, channel, 4) == -1) return show;
  return current;
}
// GET_INDEX_OF_CURRENT_LEVEL for scripts (Scripts/prepare_level_index.py). PG_LEVEL_INDEX_OVERRIDE
// answers a fixed index instead (test hook). Each new index the game reports is logged once.
u32 pg_script_level_index(u32 index) {
  static _Atomic int64_t lastLogged = -1;
  const char *override = getenv("PG_LEVEL_INDEX_OVERRIDE");
  u32 answer = override ? (u32)atoi(override) : index;
  if (atomic_exchange(&lastLogged, (int64_t)index) != (int64_t)index) {
    char line[96]; snprintf(line, sizeof line, "Scripts asked for the level index: %u (answered %u)", index, answer); pg_log(line);
  }
  return answer;
}

// HAS_STREAMED_TEXTURE_DICT_LOADED (Scripts/prepare_missing_txd.py): the scripts are newer than
// the game files and some wait for a texture dictionary no archive has (Los Santos Customs waits
// for "MPShopSale" before its menu). A name missing from the texture dictionary store can never
// load, so it reports loaded and the script carries on. The store's name map: bucket heads (u32)
// at 11097512, bucket count at 11097520, entries {hash, slot, next} (3 x u32) at 11097504.
u32 pg_streamed_txd_loaded(w2c_game *instance, u64 name, u32 hash, u32 loaded) {
  (void)instance;
  if (loaded) return loaded;
  uint32_t buckets = *(uint32_t *)pg_pointer(&env, 11097520, 4);
  if (!buckets) return 0; // the store isn't set up yet
  uint64_t heads = *(uint64_t *)pg_pointer(&env, 11097512, 8), entries = *(uint64_t *)pg_pointer(&env, 11097504, 8);
  uint32_t i = *(uint32_t *)pg_pointer(&env, heads + 4ull * (hash % buckets), 4);
  for (int steps = 0; i != UINT32_MAX && steps < 100000; steps++) {
    const uint32_t *entry = pg_pointer(&env, entries + 12ull * i, 12);
    if (entry[0] == hash) { if (entry[1] != UINT32_MAX) return 0; break; } // known: its real state
    i = entry[2];
  }
  static uint32_t logged[32]; static int loggedCount; // log each name once (script commands run on one thread)
  bool seen = false;
  for (int k = 0; k < loggedCount; k++) seen |= logged[k] == hash;
  if (!seen && loggedCount < 32) {
    logged[loggedCount++] = hash;
    char line[160]; snprintf(line, sizeof line, "Texture dictionary \"%.64s\" is not in the game files; scripts waiting for it carry on.", pg_string(&env, name));
    pg_log(line);
  }
  return 1;
}
// datResourceMap fixup miss (Scripts/prepare_fixup_guard.py). The map: chunk table pointer at +0,
// resource name at +16, entries {src, size | index << 56} (2 x u64) from +24, entry count (u8) at
// +4120; the chunk table holds {.., src, dest} (3 x u64) per index. The engine treats a pointer
// outside the map as fatal. Two Vinewood Hills fences (ch2_07_fence_03, ch2_07d_fencing_02, the end
// of Marriage Counseling) always contain such values, straight from their decompressed data
// (a simulator watchpoint saw only the streamer's decompressor write their chunks). An address
// inside one of the resource's own chunks is kept (delta 0); any other becomes a null pointer, so
// the model loads without that part instead of stopping the game.
static void pg_log_chunk_map(uint64_t map, uint64_t table, unsigned count) {
  char line[200];
  for (unsigned k = 0; k < count && k < 64; k++) {
    const uint64_t *e = pg_pointer(&env, map + 24 + 16ull * k, 16);
    snprintf(line, sizeof line, "  chunk %llu: file 0x%llx, %llu bytes, placed at 0x%llx", (unsigned long long)(e[1] >> 56),
             (unsigned long long)e[0], (unsigned long long)(e[1] & 0x00FFFFFFFFFFFFFFull),
             (unsigned long long)*(uint64_t *)pg_pointer(&env, table + 24 * (e[1] >> 56) + 24, 8));
    pg_log(line);
  }
}
#if TARGET_OS_SIMULATOR
// PG_FENCE_DUMP=<dir>: write each chunk of a flagged resource as it is at that moment (diagnostics).
static void pg_fence_dump(uint64_t map, const char *tag) {
  const char *dir = getenv("PG_FENCE_DUMP"); if (!dir) return;
  uint64_t table = *(uint64_t *)pg_pointer(&env, map, 8), name = *(uint64_t *)pg_pointer(&env, map + 16, 8);
  unsigned count = *(uint8_t *)pg_pointer(&env, map + 4120, 1);
  for (unsigned k = 0; k < count && k < 64; k++) {
    const uint64_t *e = pg_pointer(&env, map + 24 + 16ull * k, 16);
    uint64_t size = e[1] & 0x00FFFFFFFFFFFFFFull, dest = *(uint64_t *)pg_pointer(&env, table + 24 * (e[1] >> 56) + 24, 8);
    char path[512]; snprintf(path, sizeof path, "%s/%.64s_%s_%u_%llx_%llx.bin", dir, name ? pg_string(&env, name) : "x", tag, k,
                             (unsigned long long)e[0], (unsigned long long)dest);
    FILE *f = fopen(path, "wb"); if (f) { fwrite(pg_pointer(&env, dest, size), 1, size, f); fclose(f); }
  }
}
#endif
// Cash stats (Scripts/prepare_cash_stats.py, stats_commands::CommandStatSetInt). Loading a Story save,
// a script sets all three characters' SP?_TOTAL_CASH to 0 a few seconds after the save's data is read,
// so every load lost the money. Writes of 0 to those stats within a minute of a save being read (the
// engine logs "ReadScriptTreesFromLoadedPso" for each) are dropped; every cash write is logged.
// PG_CASH_GUARD=0 lets them through (comparisons).
// The scripts zeroed their balance global too (it is copied back from the stat only when signed in to
// Rockstar's network, which never happens here), so the next payment would have started from $0:
// the kept amount is copied into the balance as well.
u32 pg_stat_set_int(w2c_game *instance, u32 stat, u32 value) {
  static uint32_t cash[3];
  static uint64_t out;
  if (!cash[0]) { cash[0] = pg_joaat("SP0_TOTAL_CASH"); cash[1] = pg_joaat("SP1_TOTAL_CASH"); cash[2] = pg_joaat("SP2_TOTAL_CASH"); }
  for (int k = 0; k < 3; k++) if (stat == cash[k]) {
    const char *guard = getenv("PG_CASH_GUARD");
    bool drop = value == 0 && timeMS(CLOCK_MONOTONIC) - atomic_load(&saveLoadedAt) < 60000 && !(guard && !strcmp(guard, "0"));
    char line[160]; snprintf(line, sizeof line, "Stat SP%d_TOTAL_CASH set to %d%s.", k, (int32_t)value, drop ? ": kept the saved amount (still loading)" : "");
    pg_log(line);
    int64_t *balance = drop ? pg_cash_balance(k) : NULL;
    if (balance) {
      if (!out) out = PG_FN_OPERATOR_NEW(instance, 16);
      int32_t *kept = pg_pointer(&env, out, 4); *kept = 0;
      if (PG_FN_STAT_GET_INT(instance, stat, out, (u32)-1) && *kept > 0 && *balance != *kept) {
        snprintf(line, sizeof line, "Stat SP%d_TOTAL_CASH: the scripts' balance was %d, set to the kept %d.", k, (int32_t)*balance, *kept);
        pg_log(line);
        *balance = *kept;
      }
    }
    return drop;
  }
  return 0;
}
u32 pg_fixup_miss(w2c_game *instance, u64 map, u64 address, u64 *delta) {
  (void)instance;
  static _Atomic int logged;
  uint64_t table = *(uint64_t *)pg_pointer(&env, map, 8), name = *(uint64_t *)pg_pointer(&env, map + 16, 8);
  unsigned count = *(uint8_t *)pg_pointer(&env, map + 4120, 1);
  bool inside = false;
  for (unsigned k = 0; k < count && !inside; k++) {
    const uint64_t *entry = pg_pointer(&env, map + 24 + 16ull * k, 16);
    uint64_t size = entry[1] & 0x00FFFFFFFFFFFFFFull, index = entry[1] >> 56;
    uint64_t dest = *(uint64_t *)pg_pointer(&env, table + 24 * index + 24, 8);
    inside = address >= dest && address - dest < size;
  }
  *delta = inside ? 0 : (u64)0 - address; // the engine adds the delta: inside stays, outside becomes 0
  if (atomic_fetch_add(&logged, 1) < 16) {
    char line[200]; snprintf(line, sizeof line, "Resource \"%.64s\": pointer 0x%llx %s.", name ? pg_string(&env, name) : "?",
                             (unsigned long long)address, inside ? "was already fixed up; kept it" : "is in none of its chunks; set it to null");
    pg_log(line);
    if (atomic_load(&logged) <= 2) pg_log_chunk_map(map, table, count);
  }
#if TARGET_OS_SIMULATOR
  if (!inside) pg_fence_dump(map, "miss"); else pg_fence_dump(map, "kept");
#endif
  return 1;
}
// Page map space (Scripts/prepare_fixup_guard.py, f2080, f2082): the resource file reserved entries
// for its virtual (+8) and physical (+9) page counts. Read before pgBase overwrites them.
static void pg_page_map_forget(uint64_t map);
u32 pg_page_map_reserved(w2c_game *instance, u64 map) {
  (void)instance;
  if (!map) return 0;
  pg_page_map_forget(map);
  const uint8_t *counts = pg_pointer(&env, map + 8, 2);
  return (u32)counts[0] + counts[1];
}
// Entries past the reserved space, by page map address. pgBase writes a map once per placement
// (pg_page_map_reserved forgets the old extra entries of that address first).
#define PG_PAGE_MAPS 1024
static struct { uint64_t map; uint32_t reserved, count; uint64_t entry[8], saved[8]; } pageMaps[PG_PAGE_MAPS];
static pthread_mutex_t pageMapLock = PTHREAD_MUTEX_INITIALIZER;
static _Atomic uint64_t pageMapOverflows;
static int pg_page_map_slot(uint64_t map, bool create) {
  unsigned start = (unsigned)((map >> 4) * 2654435761u) % PG_PAGE_MAPS;
  int reuse = -1; // a slot whose map has no extra entries any more
  for (unsigned k = 0; k < PG_PAGE_MAPS; k++) {
    unsigned i = (start + k) % PG_PAGE_MAPS;
    if (pageMaps[i].map == map) return (int)i;
    if (reuse < 0 && pageMaps[i].map && !pageMaps[i].count) reuse = (int)i;
    if (!pageMaps[i].map) { if (reuse < 0) reuse = (int)i; break; }
  }
  if (!create || reuse < 0) return -1;
  pageMaps[reuse].map = map; pageMaps[reuse].count = 0;
  return reuse;
}
static void pg_page_map_forget(uint64_t map) {
  pthread_mutex_lock(&pageMapLock);
  int i = pg_page_map_slot(map, false);
  if (i >= 0) pageMaps[i].count = 0; // the slot stays (its address may come back), empty
  pthread_mutex_unlock(&pageMapLock);
}
u32 pg_page_map_entries(w2c_game *instance, u64 map, u32 pages, u32 reserved) {
  (void)instance;
  if (!map || !reserved || pages <= reserved) return pages;
  uint64_t n = atomic_fetch_add(&pageMapOverflows, 1) + 1;
  if (n <= 4 || (n & (n - 1)) == 0) {
    char line[200]; snprintf(line, sizeof line, "Page map at 0x%llx has room for %u pages but the resource has %u; the extra entries are kept aside (%llu so far).",
                             (unsigned long long)map, reserved, pages, (unsigned long long)n);
    pg_log(line);
  }
  return pages;
}
u32 pg_page_map_store(w2c_game *instance, u64 map, u64 index, u64 entry, u32 reserved) {
  (void)instance;
  if (!reserved || index < reserved) return 0;
  pthread_mutex_lock(&pageMapLock);
  int i = pg_page_map_slot(map, true);
  if (i >= 0 && index - reserved < 8) {
    pageMaps[i].reserved = reserved;
    pageMaps[i].entry[index - reserved] = entry;
    if (pageMaps[i].count < index - reserved + 1) pageMaps[i].count = (uint32_t)(index - reserved + 1);
  }
  pthread_mutex_unlock(&pageMapLock);
  return 1; // never written in place, even if the table is full
}
// pgBase::RegenerateMap(base): the extra entries go in place for the call and the bytes they cover
// come back afterwards.
void pg_page_map_swap(w2c_game *instance, u64 base, u32 in) {
  (void)instance;
  uint64_t map = *(uint64_t *)pg_pointer(&env, base + 8, 8);
  if (!map) return;
  pthread_mutex_lock(&pageMapLock);
  int i = pg_page_map_slot(map, false);
  if (i >= 0) {
    for (uint32_t k = 0; k < pageMaps[i].count; k++) {
      uint64_t *at = pg_pointer(&env, map + 16 + 8ull * (pageMaps[i].reserved + k), 8);
      if (in) { pageMaps[i].saved[k] = *at; *at = pageMaps[i].entry[k]; } else *at = pageMaps[i].saved[k];
    }
  }
  pthread_mutex_unlock(&pageMapLock);
}
// Texture dictionary placement (Scripts/prepare_fixup_guard.py, f5710): the array is {data, count
// (u16 at +8)}; entries before `index` already hold their placed addresses.
u32 pg_texture_already_placed(w2c_game *instance, u64 array, u64 index, u64 address) {
  uint64_t data = *(uint64_t *)pg_pointer(&env, array, 8);
#if TARGET_OS_SIMULATOR
  if (getenv("PG_TRACE_TEXTURE_PLACE")) {
    static _Atomic int traced;
    const uint8_t *t = pg_pointer(&env, address, 128);
    bool odd = false; for (int k = 0; k < 16; k++) { uint64_t v; memcpy(&v, t + 8 * k, 8); odd |= (v >> 48) == 0xffff; }
    if (odd && atomic_fetch_add(&traced, 1) < 6) {
      char line[512]; int n = snprintf(line, sizeof line, "TRACE texture entry %llu at 0x%llx (array 0x%llx, %u entries):", (unsigned long long)index,
                                       (unsigned long long)address, (unsigned long long)data, *(uint16_t *)pg_pointer(&env, array + 8, 2));
      for (int k = 0; k < 16 && n < (int)sizeof line - 20; k++) { uint64_t v; memcpy(&v, t + 8 * k, 8); n += snprintf(line + n, sizeof line - n, " %016llx", (unsigned long long)v); }
      pg_log(line);
    }
  }
#endif
  // A texture record never lives in the physical (GPU data) segment. The resource being placed is
  // *g19 (the datResource f5710 passes to GetFixup); its map's physical entries have file 0x6....
  bool physical = false;
  uint64_t map = *(uint64_t *)pg_pointer(&env, instance->w2c_g19, 8);
  if (map) {
    uint64_t table = *(uint64_t *)pg_pointer(&env, map, 8);
    unsigned count = *(uint8_t *)pg_pointer(&env, map + 4120, 1);
    for (unsigned k = 0; k < count && !physical; k++) {
      const uint64_t *e = pg_pointer(&env, map + 24 + 16ull * k, 16);
      uint64_t size = e[1] & 0x00FFFFFFFFFFFFFFull, dest = *(uint64_t *)pg_pointer(&env, table + 24 * (e[1] >> 56) + 24, 8);
      physical = (e[0] >> 28) == 6 && address >= dest && address - dest < size;
    }
  }
  uint64_t raw = *(uint64_t *)pg_pointer(&env, data + 8 * index, 8);
  if (physical) {
#if TARGET_OS_SIMULATOR
    pg_fence_dump(map, "tex");
#endif
    static _Atomic int skipped;
    if (atomic_fetch_add(&skipped, 1) < 8) {
      char line[160]; snprintf(line, sizeof line, "Texture dictionary entry %llu points at GPU data (0x%llx), not a texture; left it out.",
                               (unsigned long long)index, (unsigned long long)raw);
      pg_log(line);
    }
    return 2;
  }
  for (uint64_t k = 0; k < index; k++) {
    if (*(uint64_t *)pg_pointer(&env, data + 8 * k, 8) != address) continue;
    static _Atomic int logged;
    if (atomic_fetch_add(&logged, 1) < 8) {
      char line[128]; snprintf(line, sizeof line, "Texture dictionary lists one texture twice (entries %llu and %llu); placed it once.",
                               (unsigned long long)k, (unsigned long long)index);
      pg_log(line);
    }
    return 1;
  }
  return 0;
}
// The core of IS_PAUSE_MENU_ACTIVE (f52482 -> f36254): either frontend flag.
bool PGPauseMenuActive(void) {
  if (!atomic_load(&inputBlock) || env.memory.size < 19566112) return false;
  const uint8_t *memory = (const uint8_t *)(void *)env.memory.data;
  return ((atomic_load_explicit((const _Atomic uint8_t *)(memory + 19565906), memory_order_relaxed) |
           atomic_load_explicit((const _Atomic uint8_t *)(memory + 19566104), memory_order_relaxed)) & 1) != 0;
}
// PREF_TARGET_CONFIG: 0 traditional lock, 1 assisted, 2 assisted free, 3 free aim.
int32_t PGTargetingMode(void) {
  if (!atomic_load(&inputBlock) || env.memory.size < 19566128) return -1;
  return atomic_load_explicit((const _Atomic int32_t *)(void *)((const uint8_t *)(void *)env.memory.data + 19566124), memory_order_relaxed);
}
int32_t PGLastInputDevice(void) {
  if (!atomic_load(&inputBlock) || env.memory.size < 24627140) return -3;
  return atomic_load_explicit((const _Atomic int32_t *)(void *)((const uint8_t *)(void *)env.memory.data + 24627136), memory_order_relaxed);
}

void PGFillAudio(float *left, float *right, uint32_t count) {
  memset(left, 0, count * sizeof(float)); memset(right, 0, count * sizeof(float));
  uint64_t ring = atomic_load(&audioRing);
  if (!ring) return;
  uint32_t capacity = atomic_load(&audioCapacity);
  _Atomic uint32_t *header = pg_pointer(&env, ring, 64 + (u64)capacity * 8);
  float *data = (float *)((uint8_t *)(void *)header + 64);
  uint32_t read = atomic_load(header + 1), write = atomic_load(header);
  uint32_t available = write - read;
  uint32_t take = available < count ? available : count;
  if (take > capacity) take = capacity;
  for (uint32_t i = 0; i < take; i++) {
    uint32_t at = ((read + i) & (capacity - 1)) * 2;
    left[i] = data[at]; right[i] = data[at + 1];
  }
  atomic_store(header + 1, read + take);
  atomic_fetch_add(header + 3, 1);
#if TARGET_OS_SIMULATOR
  if (atomic_load(&pg_audio_dump_frames) > 0 && pg_audio_dump) {
    for (uint32_t i = 0; i < count; i++) { float frame[2] = {left[i], right[i]}; fwrite(frame, sizeof frame, 1, pg_audio_dump); }
    if (atomic_fetch_sub(&pg_audio_dump_frames, count) <= count) { fclose(pg_audio_dump); pg_audio_dump = NULL; pg_log("TEST: audio dump finished."); }
  }
#endif
}

static char *configuredQuality[32];static unsigned configuredQualityCount;
// The frame limiter reads the frame interval (in 60 Hz refreshes: 0 none, 1 = 60 FPS, 2 = 30 FPS)
// from 19447080 every frame (CSystem frame limit, set from -frameLimit), so it can change in play.
// A script fault ends that script instead of the game (Scripts/prepare_script_fault_abort.py, GTA-158). The
// interpreter has already logged "FAULT: ..." with the script's name and call stack.
static _Atomic int scriptFaults;
void pg_script_fault(w2c_game *instance) {
  (void)instance;
  int n = atomic_fetch_add(&scriptFaults, 1) + 1;
  char line[160]; snprintf(line, sizeof line, "Script fault %d: that script was stopped and the game goes on (a BankRelease build would stop the game here).", n);
  pg_log(line);
}
// The frame limiter's last stretch (Scripts/prepare_frame_limit_sleep.py, GTA-169): it used to spin reading the
// clock for the 1-2 ms its whole-millisecond sleeps couldn't cover; a precise sleep takes that time instead.
void pg_frame_limit_sleep(float seconds) {
  if (!(seconds > 0.00005f) || seconds > 0.05f) return;
  struct timespec wait = {0, (long)(seconds * 1e9f)};
  nanosleep(&wait, NULL);
}
void PGSetFrameLimit(int frameLimit){
  if(!atomic_load(&inputBlock)||frameLimit<0||frameLimit>4||env.memory.size<19447084)return;
  atomic_store_explicit((_Atomic int32_t *)(void *)((uint8_t *)(void *)env.memory.data+19447080),frameLimit,memory_order_relaxed);
  char line[96];snprintf(line,sizeof line,"Frame limit now %s.",frameLimit==0?"off":frameLimit==1?"60 FPS":frameLimit==2?"30 FPS":"lower");pg_log(line);
}
void PGConfigureEngine(const char *const *quality,unsigned count,int width,int height,int frameLimit){
  if(atomic_load(&started))return;
  for(unsigned i=0;i<configuredQualityCount;i++)free(configuredQuality[i]);
  configuredQualityCount=0;
  for(unsigned i=0;i<count&&i<32;i++)configuredQuality[configuredQualityCount++]=strdup(quality[i]);
  if(width>=320&&width<=3840&&height>=180&&height<=2160){configuredWidth=width&~1;configuredHeight=height&~1;}
  if(frameLimit>=0&&frameLimit<=4)configuredFrameLimit=frameLimit;
}
void PGSetStartMode(int32_t mode){
  if(atomic_load(&started))return;
  // 1 Story, 2 Sandbox on the GTA V map, 3 Sandbox on the game's test level (env_test).
  if(mode>=1&&mode<=3)configuredStartMode=mode;
}
void PGSetBackBufferSize(int width,int height){
  uint64_t block=atomic_load(&inputBlock);
  if(!block||width<320||height<180||width>3840||height>2160)return;
  uint8_t *base=pg_pointer(&env,block,444);
  atomic_store((_Atomic int32_t *)(base+432),width&~1);
  atomic_store((_Atomic int32_t *)(base+436),height&~1);
}
static void *boot(void *ignored) {
  pthread_setname_np("gta.engine.main");	// for the Threads line (NativeThreadCPU.c)
  // Real iOS must budget against its Jetsam allowance. Simulator runs opt in
  // with an explicit modeled ceiling so ordinary performance baselines match.
  const char *guard=getenv("PG_MEMORY_GUARD");nativeMemoryGuard=guard?atoi(guard)==1:!TARGET_OS_SIMULATOR;
#if TARGET_OS_SIMULATOR
  const char *limit=getenv("PG_STREAM_MEMORY_LIMIT_MB");
  if(limit){char *end;unsigned long mb=strtoul(limit,&end,10);if(end!=limit&&!*end&&mb>=2048&&mb<=8192)simulatedProcessLimit=(uint64_t)mb*1048576;}
#endif
  if(nativeMemoryGuard)pg_log("Native streaming memory guard enabled with 384 MB of reserve.");
  // Device A/B switches (GTA-117, GTA-128), named in the log so each run says which side it was.
  if(nativeMemoryGuard&&getenv("PG_GUARD_SPARE_MB"))pg_log("Memory guard A/B: fast nudges only with PG_GUARD_SPARE_MB to spare.");
  if(nativeMemoryGuard&&getenv("PG_GUARD_POOL_ROOM")&&atoi(getenv("PG_GUARD_POOL_ROOM"))==0)pg_log("Memory guard: the resource pool's free space doesn't count as room (PG_GUARD_POOL_ROOM=0).");
  pg_assets_prewarm();
  nativeEngineCores=pg_engine_core_configuration(getenv("PG_ENGINE_CORES"));
  char coresOption[32];snprintf(coresOption,sizeof coresOption,"-numCores=%u",nativeEngineCores);
  char coresLog[96];snprintf(coresLog,sizeof coresLog,"Native engine worker configuration: %u logical cores.",nativeEngineCores);pg_log(coresLog);
  wasm_rt_init();
  uint64_t engineMB=pg_engine_memory_mb();
  char reserveLog[128];snprintf(reserveLog,sizeof reserveLog,"Reserving %llu MB virtual engine memory, starting with a 3328 MB shared heap.",(unsigned long long)engineMB);pg_log(reserveLog);
#if defined(PG_HAS_ARM64_SHARED_VECTORS) && !defined(PG_SHARED_SIMD_BYTEWISE)
  pg_log("Shared vector memory uses native ARM64 instructions with bounds checks.");
#else
  pg_log("Shared vector memory uses bytewise atomic copies with bounds checks.");
#endif
  env.memory.pages = 3328ull*1024*1024/wasm2c_game_pagesize_env_memory;
  env.memory.max_pages = engineMB*1024*1024/wasm2c_game_pagesize_env_memory;
  env.memory.page_size = wasm2c_game_pagesize_env_memory;
  env.memory.size = env.memory.pages * env.memory.page_size;
  env.memory.is64 = true;
  uint64_t capacity=env.memory.max_pages*env.memory.page_size;
  // The full maximum is mapped up front, then an inaccessible guard region:
  // unchecked builds (PG_UNCHECKED_MEMORY) rely on it so that an access past
  // the end faults instead of touching unrelated memory.
  // Small enough for apps without the extended-address-space entitlement.
  const uint64_t guardBytes=64ull<<20;
  void *allocation=mmap(NULL,capacity+guardBytes,PROT_READ|PROT_WRITE,MAP_PRIVATE|MAP_ANON,-1,0);
  // Smaller reservations when iOS refuses: iPhones with 3 GB (iPhone 8, 8 Plus, X) on a free Apple ID
  // couldn't reserve 4095 MB and the game never started. 3392 MB is the 3328 MB starting heap plus a
  // little room to grow. Above 4095 MB, installs without the extended-address entitlement may be refused too.
  // PG_TEST_RESERVE_MAX_MB (simulator) refuses anything larger, to test the steps.
  static const uint64_t fallbackMB[]={6144,5120,4608,4095,3840,3584,3392};
#if TARGET_OS_SIMULATOR
  {const char *v=getenv("PG_TEST_RESERVE_MAX_MB");uint64_t most=v?(uint64_t)atol(v):0;
   if(most&&capacity/1048576>most&&allocation!=MAP_FAILED){munmap(allocation,capacity+guardBytes);allocation=MAP_FAILED;}
   for(size_t i=0;allocation==MAP_FAILED&&most&&i<sizeof fallbackMB/sizeof *fallbackMB;i++){
    if(fallbackMB[i]>=capacity/1048576)continue;
    char line[96];snprintf(line,sizeof line,"iOS could not reserve that much; trying %llu MB.",(unsigned long long)fallbackMB[i]);pg_log(line);
    env.memory.max_pages=fallbackMB[i]*1024*1024/wasm2c_game_pagesize_env_memory;capacity=env.memory.max_pages*env.memory.page_size;
    if(fallbackMB[i]<=most)allocation=mmap(NULL,capacity+guardBytes,PROT_READ|PROT_WRITE,MAP_PRIVATE|MAP_ANON,-1,0);
   }}
#endif
  for (size_t i=0;allocation==MAP_FAILED&&i<sizeof fallbackMB/sizeof *fallbackMB;i++) {
    if (fallbackMB[i]>=capacity/1048576) continue;
    char line[96];snprintf(line,sizeof line,"iOS could not reserve that much; trying %llu MB.",(unsigned long long)fallbackMB[i]);pg_log(line);
    env.memory.max_pages=fallbackMB[i]*1024*1024/wasm2c_game_pagesize_env_memory;capacity=env.memory.max_pages*env.memory.page_size;
    allocation=mmap(NULL,capacity+guardBytes,PROT_READ|PROT_WRITE,MAP_PRIVATE|MAP_ANON,-1,0);
  }
  if (allocation==MAP_FAILED) { pg_log("iOS could not reserve the engine memory."); return NULL; }
  if (mprotect((uint8_t *)allocation+capacity,guardBytes,PROT_NONE)) pg_log("Engine memory guard region could not be protected.");
  env.memory.data=(_Atomic volatile uint8_t *)allocation;
#if TARGET_OS_SIMULATOR
  {char line[96];snprintf(line,sizeof line,"Engine memory at %p (simulator, for debugger watchpoints).",allocation);pg_log(line);}
#endif
  env.memory.data_end = env.memory.data + capacity;
  pthread_mutex_init(&env.memory.mem_lock, NULL);
  wasm_rt_trap_t trap = wasm_rt_impl_try();
  if (trap) {
    char message[512];
    snprintf(message, sizeof(message), "Native boot stopped: %s%s%s", wasm_rt_strerror(trap),
             missingImport[0] ? " — " : "", missingImport);
    pg_log(message);
    return NULL;
  }
  pg_threads_main(&env);
  wasm2c_game_instantiate(&env.game, &env, &wasi);
  uint32_t actual = w2c_game_htons(&env.game, 0x1234);
  char message[128];
  snprintf(message, sizeof(message), "Real engine export executed as ARM64: htons(0x1234) = 0x%04x", actual);
  pg_log(message);
  if (actual != 0x3412) { pg_log("Native execution produced an incorrect result."); return NULL; }
  pg_log("Running the real engine's static constructors.");
  // Test hook: move the heap's top before the allocator starts, so the game's allocations land above 4 GB.
  const char *ballast=getenv("PG_TEST_HEAP_BALLAST_MB");
  if(ballast&&atoi(ballast)>0){extern u64 PG_FN_SBRK(w2c_game *,u64);u64 bytes=(u64)atoi(ballast)<<20;
    snprintf(message,sizeof message,"Test: heap ballast of %d MB, previous top 0x%llx.",atoi(ballast),(unsigned long long)PG_FN_SBRK(&env.game,bytes));pg_log(message);}
  w2c_game_0x5F_wasm_call_ctors(&env.game);
  pg_log("Constructors completed; calling the game entry point.");
  char widthOption[32],heightOption[32],frameOption[32];
  snprintf(widthOption,sizeof widthOption,"-width=%d",configuredWidth);
  snprintf(heightOption,sizeof heightOption,"-height=%d",configuredHeight);
  // PG_BENCHMARK_FRAME_LIMIT pins a benchmark's frame rate, so builds compare at equal work per second.
  const char *benchLimit=getenv("PG_BENCHMARK_FRAME_LIMIT");
  snprintf(frameOption,sizeof frameOption,"-frameLimit=%d",benchmarkEnabled()?(benchLimit?atoi(benchLimit):0):configuredFrameLimit);
  const char *base[]={"playgta5","-rootdir=/game/","-wgpu","-nodisplaycalibration","-noSocialClub","-pc:nosocialclub","-nonetwork","-output",widthOption,heightOption,"-forceResolution","-fastscriptcore","-Script_all=warning","-replay_all=warning",frameOption,coresOption};
  const char *defaultQuality[]={"-shaderQuality=1","-textureQuality=0","-pedVariety=0","-vehicleVariety=0","-shadowQuality=-1","-reflectionQuality=0","-particleQuality=0","-grassQuality=0","-cityDensity=0","-lodScale=0","-pedLodBias=0","-vehicleLodBias=0"};
  const char *options[64];unsigned optionCount=0;
  for(unsigned i=0;i<sizeof base/sizeof *base;i++)options[optionCount++]=base[i];
  // The text the release scripts use is in the release language archives (x64/data/lang/<language>_REL.rpf);
  // without the suffix the game loads the development ones and shows "<label> missing" (GTA-49).
  // PG_LANG_SUFFIX= (empty) loads the old ones, for comparisons.
  const char *langSuffix=getenv("PG_LANG_SUFFIX");static char langOption[48];
  snprintf(langOption,sizeof langOption,"-langfilesuffix=%s",langSuffix?langSuffix:"_REL");
  if(!langSuffix||*langSuffix)options[optionCount++]=langOption;
  // Benchmarks keep the measured low profile so results stay comparable.
  if(configuredQualityCount&&!benchmarkEnabled())for(unsigned i=0;i<configuredQualityCount;i++)options[optionCount++]=configuredQuality[i];
  else for(unsigned i=0;i<sizeof defaultQuality/sizeof *defaultQuality;i++)options[optionCount++]=defaultQuality[i];
  snprintf(message,sizeof message,"Graphics: %dx%d, frame limit %d, %u quality options.",configuredWidth,configuredHeight,benchmarkEnabled()?0:configuredFrameLimit,configuredQualityCount);pg_log(message);
  u64 stack=w2c_game_emscripten_stack_get_current(&env.game);
  u64 argv=(stack-4096)&~(u64)15;
  w2c_game_0x5Femscripten_stack_restore(&env.game,argv);
  u64 *arguments=pg_pointer(&env,argv,4096);u64 text=argv+512;
  unsigned argc=optionCount;
  for(unsigned i=0;i<argc;i++){size_t len=strlen(options[i])+1;arguments[i]=text;memcpy(pg_pointer(&env,text,len),options[i],len);text+=len;}
  if(benchmarkEnabled()) {
    const char *iterationText=getenv("PG_BENCHMARK_ITERATIONS");unsigned iterations=1;
    if(iterationText){char *end;unsigned long parsed=strtoul(iterationText,&end,10);if(end!=iterationText&&!*end&&parsed>=1&&parsed<=10)iterations=(unsigned)parsed;}
    char iterationOption[48];snprintf(iterationOption,sizeof iterationOption,"-benchmarkIterations=%u",iterations);
    const char *extra[]={"-benchmark",iterationOption,"-benchmarkFrameTimes"};
    for(unsigned i=0;i<sizeof(extra)/sizeof(*extra);i++){size_t len=strlen(extra[i])+1;arguments[argc++]=text;memcpy(pg_pointer(&env,text,len),extra[i],len);text+=len;}
    const char *pass=getenv("PG_BENCHMARK_PASS");if(pass&&*pass){char option[64];snprintf(option,sizeof option,"-benchmarkPass=%d",atoi(pass));size_t len=strlen(option)+1;arguments[argc++]=text;memcpy(pg_pointer(&env,text,len),option,len);text+=len;}
    pg_log("Starting the engine's built-in graphics benchmark.");
  }
  const char *streamerPercentage=getenv("PG_STREAMER_PERCENTAGE");
  if(streamerPercentage&&*streamerPercentage){
    char *end;double fraction=strtod(streamerPercentage,&end);
    if(end!=streamerPercentage&&!*end&&isfinite(fraction)&&fraction>=.1&&fraction<=.95){
      char option[80];snprintf(option,sizeof option,"-percentageForStreamer=%.3f",fraction);
      size_t len=strlen(option)+1;arguments[argc++]=text;memcpy(pg_pointer(&env,text,len),option,len);text+=len;
      snprintf(message,sizeof message,"Native streaming budget experiment: %.3f of engine video-memory budget.",fraction);pg_log(message);
    }
  }
  arguments[argc]=0;
  uint32_t result=w2c_game_0x5F_main_argc_argv(&env.game,argc,argv);
  snprintf(message, sizeof(message), "Game entry point returned %u", result);
  pg_log(message);
  return NULL;
}

void PGStartEngine(const char *path, const char *filesRoot, PGLogCallback callback, void *context) {
  if (atomic_exchange(&started, true)) return;
  manifestPath = strdup(path);
  pg_files_init(filesRoot);
  logCallback = callback; logContext = context;
  for (int i = 0; i < earlyCount; i++) logCallback(earlyLines[i], logContext);
  earlyCount = 0;
  pg_assets_configure(path, filesRoot);
  pthread_attr_t attributes;
  pthread_attr_init(&attributes);
  pthread_attr_setstacksize(&attributes, 16 * 1024 * 1024);
  extern void pg_engine_thread_attributes(pthread_attr_t *attrs);	// NativeThreads.c (GTA-92 A/B)
  pg_engine_thread_attributes(&attributes);
  pthread_t thread;
  int result = pthread_create(&thread, &attributes, boot, NULL);
  pthread_attr_destroy(&attributes);
  if (result) { pg_log("Could not create the native engine thread."); return; }
  pthread_detach(thread);
}

#include <execinfo.h>
#include <mach-o/dyld.h>
// The last indirect call that failed the fast check on this thread (Scripts/prepare_trap_context.py).
static _Thread_local const char *indirectFunction;
static _Thread_local uint32_t indirectIndex,indirectSize;
// Test (PG_TEST_CONTROLS=1, Scripts/prepare_control_trace.py): every 3 s, which controls scripts read
// and the strongest answer each got, e.g. "N2:31=1.00" (GET_CONTROL_NORMAL of input 31 reached 1).
// Kinds: P pressed, V value, N normal, DP disabled pressed, DN disabled normal.
static _Atomic float controlMax[5][400];
static _Atomic uint32_t controlReads[5][400];
// When scripts last asked for each input (any control, any kind): the touch controls show a button for
// an input a mission polls that has none on screen (GTA-51, PGInputPolledWithin).
static _Atomic double inputPolledAt[400];
int PGInputPolledWithin(int action, double ms) {
  if (action < 0 || action >= 400) return 0;
  double at = atomic_load_explicit(&inputPolledAt[action], memory_order_relaxed);
  return at > 0 && timeMS(CLOCK_MONOTONIC) - at < ms;
}
// When scripts last read each input in any way, including the script commands that read it without going through
// the commands above (IS_CONTROL_PRESSED, IS_CONTROL_JUST_PRESSED and others; pg_control_script_read). Only the
// "Prompt: scripts read inputs" log uses these so far: the touch layouts still follow PGInputPolledWithin (GTA-129).
static _Atomic double inputReadAt[400];
int PGInputReadWithin(int action, double ms) {
  if (action < 0 || action >= 400) return 0;
  double at = atomic_load_explicit(&inputReadAt[action], memory_order_relaxed);
  return at > 0 && timeMS(CLOCK_MONOTONIC) - at < ms;
}
static void pg_control_trace(u32 kind, u32 action, f32 value);
void pg_control_read(u32 kind, u32 control, u32 action, f32 value) {
  (void)control;
  if (action < 400) {
    double now = timeMS(CLOCK_MONOTONIC);
    atomic_store_explicit(&inputPolledAt[action], now, memory_order_relaxed);
    atomic_store_explicit(&inputReadAt[action], now, memory_order_relaxed);
  }
  pg_control_trace(kind, action, value);
}
void pg_control_script_read(u32 kind, u32 control, u32 action, f32 value) {
  (void)control;
  if (action < 400) atomic_store_explicit(&inputReadAt[action], timeMS(CLOCK_MONOTONIC), memory_order_relaxed);
  pg_control_trace(kind, action, value);
}
static void pg_control_trace(u32 kind, u32 action, f32 value) {
  static int on = -1;
  if (on < 0) on = getenv("PG_TEST_CONTROLS") != NULL;
  if (!on || kind > 4 || action >= 400) return;
  atomic_fetch_add(&controlReads[kind][action], 1);
  float magnitude = fabsf(kind == 1 ? (value - 127.f) / 127.f : value);
  if (magnitude > atomic_load(&controlMax[kind][action])) atomic_store(&controlMax[kind][action], magnitude);
  static _Atomic double next;
  double now = timeMS(CLOCK_MONOTONIC);
  if (now < atomic_load(&next)) return;
  atomic_store(&next, now + 3000);
  static const char *names[5] = {"P", "V", "N", "DP", "DN"};
  char line[1024]; int at = snprintf(line, sizeof line, "TEST: controls read:");
  for (int k = 0; k < 5; k++) for (int a = 0; a < 400; a++) {
    if (!atomic_exchange(&controlReads[k][a], 0)) continue;
    float m = atomic_exchange(&controlMax[k][a], 0);
    if (at < (int)sizeof line - 24) at += snprintf(line + at, sizeof line - at, " %s:%d=%.2f", names[k], a, m);
  }
  pg_log(line);
}
// The pause menu's input waits for its "ready" call (Scripts/prepare_pause_ready.py, GTA-22); after
// PG_PAUSE_READY_MS (default 2000, 0 = wait as the game does) it takes input anyway. Both are logged.
static _Atomic double pauseOpenedAt;
static _Atomic int pauseReadyLogged;
void pg_pause_opened(void) { atomic_store(&pauseOpenedAt, timeMS(CLOCK_MONOTONIC)); atomic_store(&pauseReadyLogged, 0); }
u32 pg_pause_input_ready(u32 ready) {
  static long limit = -1;
  if (limit < 0) { const char *v = getenv("PG_PAUSE_READY_MS"); limit = v ? atol(v) : 2000; }
  const double since = timeMS(CLOCK_MONOTONIC) - atomic_load(&pauseOpenedAt);
  if (ready == 1) {
    if (!atomic_exchange(&pauseReadyLogged, 1)) { char line[96]; snprintf(line, sizeof line, "Pause menu: ready %.0f ms after opening.", since); pg_log(line); }
    return ready;
  }
  if (!limit || since < limit) return ready;
  if (atomic_exchange(&pauseReadyLogged, 2) != 2) { char line[120]; snprintf(line, sizeof line, "Pause menu: still not ready after %.0f ms; taking input anyway.", since); pg_log(line); }
  return 1;
}
// Shader texture slots that outlive their texture (Scripts/prepare_stale_texture_slots.py, GTA-20/24).
// grcEffect_Technique_Pass::Bind fills six per-stage arrays of 42 texture pointers at 12629008; a
// freed texture or render target is cleared from them, and SetProgramResources skips a slot whose
// object no longer looks like a texture instead of trapping in its GetTextureView call.
static _Atomic uint64_t textureSlotsCleared, textureViewsSkipped;
void pg_texture_freed(w2c_game *instance, u64 texture) {
  (void)instance;
  if (!texture || env.memory.size < 12631024) return;
  _Atomic uint64_t *slot = (_Atomic uint64_t *)pg_pointer(&env, 12629008, 2016);
  for (int i = 0; i < 252; i++) {
    uint64_t held = texture;
    if (atomic_load_explicit(&slot[i], memory_order_relaxed) == texture &&
        atomic_compare_exchange_strong(&slot[i], &held, 0) && atomic_fetch_add(&textureSlotsCleared, 1) < 4) {
      char line[120]; snprintf(line, sizeof line, "Shader texture slot %d still held a freed texture (0x%llx); cleared it.", i, (unsigned long long)texture);
      pg_log(line);
    }
  }
}
u32 pg_texture_view_bad(w2c_game *instance, u64 texture) {
  (void)instance;
  const uint64_t size = env.memory.size;
  bool bad = !texture;		// 0: the caller found its GetTextureView entry isn't a function of that type
  if (texture) {
    bad = texture + 8 > size;
    if (!bad) { uint64_t vtable = *(uint64_t *)pg_pointer(&env, texture, 8); bad = vtable < 4096 || vtable + 200 > size; }
  }
  if (bad && atomic_fetch_add(&textureViewsSkipped, 1) < 8) {
    char line[120]; snprintf(line, sizeof line, "Shader texture slot held a freed or invalid texture (0x%llx); skipped it.", (unsigned long long)texture);
    pg_log(line);
  }
  return bad;
}
// Dependency jobs whose descriptor was already freed (Scripts/prepare_dependency_guard.py, GTA-144): the worker drops
// them instead of allocating a 0xDDDDDDDD-byte scratch buffer or calling a garbage job pointer. Counted, first 4 logged.
static _Atomic uint64_t dependencyJobsSkipped;
void pg_dependency_skipped(w2c_game *instance, u64 job, u64 function, u32 size) {
  (void)instance;
  if (atomic_fetch_add(&dependencyJobsSkipped, 1) < 4) {
    char line[160]; snprintf(line, sizeof line, "Dependency worker: dropped a stale job at 0x%llx (function 0x%llx, scratch %u bytes): its descriptor was freed (GTA-144).",
                             (unsigned long long)job, (unsigned long long)function, size);
    pg_log(line);
  }
}
// Engine heaps that reserve far more address space than they use (Scripts/prepare_heap_sizes.py, GTA-124). In 358
// player logs the Replay recorder heap (heap 0 here: 196 MB) never held more than 2 MB and heap 2 (220 MB) at most
// 58 MB, while the 4 GB address space is what runs out on 6-8 GB iPhones (GTA-70, GTA-145). PG_SMALL_ENGINE_HEAPS=1
// (Settings › Experimental, off by default, Kevin 2026-10-20) makes them 16 and 128 MB: about 270 MB more room.
// Replay recording never runs on the port (the engine skips its recording threads; START_REPLAY_RECORDING does
// nothing, simulator 2026-10-20), so the Replay heap is unused either way.
uint64_t pg_engine_heap_size(uint32_t heap, uint64_t size) {
  static int small = -1;
  if (small < 0) { const char *v = getenv("PG_SMALL_ENGINE_HEAPS"); small = v && atoi(v) == 1; }
  if (!small) return size;
  uint64_t wanted = heap == 0 ? 16ull << 20 : heap == 2 ? 128ull << 20 : size;
  if (wanted > size) wanted = size;
  static _Atomic bool logged[3];
  if (heap < 3 && !atomic_exchange(&logged[heap], true)) {
    char line[128]; snprintf(line, sizeof line, "Smaller engine heaps: %s heap %llu MB instead of %llu MB (GTA-124).", heap == 0 ? "Replay" : "debug",
                             (unsigned long long)(wanted >> 20), (unsigned long long)(size >> 20));
    pg_log(line);
  }
  return wanted;
}
// Render phases destroyed by a device restore that stay in the phase list (Scripts/prepare_destroyed_phases.py,
// GTA-89). A live resize (Settings resolution, a TV) restores the graphics device and CViewportManager::DeviceReset
// deletes the render phases; one stays in the list at 11547128 (an atArray: data at +0, u16 count at +8) with the
// bare rage::fwRenderPhase vtable (4219920) that ~fwRenderPhase leaves behind. CGameScan::KickVisibilityJobs then
// calls through it (slot +64 is past that vtable: table index 4227208) and the game stops; 12 player logs, v1.3.4 to
// v1.4.3, all that index. At the start of each KickVisibilityJobs (main thread, once a frame) such entries are dropped.
static _Atomic uint64_t destroyedPhasesDropped;
void pg_drop_destroyed_phases(w2c_game *instance) {
  (void)instance;
  uint64_t list;
  if (env.memory.size < 11547136) return;
  memcpy(&list, env.memory.data + 11547128, 8);
  if (!list || list + 16 > env.memory.size) return;
  uint64_t data; uint16_t count;
  memcpy(&data, env.memory.data + list, 8); memcpy(&count, env.memory.data + list + 8, 2);
  if (!data || data + 8ull * count > env.memory.size) return;
  uint64_t *phases = (uint64_t *)(env.memory.data + data);
  uint16_t kept = 0;
  for (uint16_t i = 0; i < count; i++) {
    uint64_t phase = phases[i], vtable = 0;
    if (phase && phase + 8 <= env.memory.size) memcpy(&vtable, env.memory.data + phase, 8);
    if (vtable == 4219920) {
      if (atomic_fetch_add(&destroyedPhasesDropped, 1) < 4) {
        char line[128]; snprintf(line, sizeof line, "Render phase %u of %u was destroyed by the device restore; dropped it from the phase list (GTA-89).", i, count);
        pg_log(line);
      }
      continue;
    }
    phases[kept++] = phase;
  }
  if (kept != count) memcpy(env.memory.data + list + 8, &kept, 2);
}
void pg_note_call_indirect(const char *function,uint32_t index,uint32_t size){indirectFunction=function;indirectIndex=index;indirectSize=size;}
void pg_record_trap(int code) {
  pg_invoke_top=NULL; // the trap leaves every invoke_* on this thread, so their jump points are gone
  void *frames[20];int count=backtrace(frames,20);char line[160];
  snprintf(line,sizeof line,"Native trap %d; app image base %p",code,_dyld_get_image_header(0));pg_log(line);
  // Names the engine function (w2c_game_fN) for an invalid indirect call, which native frames can't do.
  if(code==WASM_RT_TRAP_CALL_INDIRECT&&indirectFunction){snprintf(line,sizeof line,"  indirect call in %s, table index %u of %u",indirectFunction,indirectIndex,indirectSize);pg_log(line);}
  for(int i=0;i<count;i++){snprintf(line,sizeof line,"  native frame %d: %p",i,frames[i]);pg_log(line);}
}

#include "NativeGraphics.h"
uint32_t PGGraphicsNotify(uint64_t address){return pg_atomic_notify(&env.memory,address,UINT32_MAX);}
// The native Metal renderer sleeps on the ring head word like an engine thread (timeout in nanoseconds, -1: none).
uint32_t PGGraphicsWait(uint64_t address,uint32_t expected,int64_t timeoutNs){return pg_atomic_wait32(&env.memory,address,expected,(uint64_t)timeoutNs);}
void w2c_env_wgpu_start_worker(struct w2c_env *host,u64 ring,u64 size,u64 debug){
  pg_log("Connecting game graphics commands to native Metal.");
  PGStartGraphics((void *)env.memory.data,env.memory.max_pages*env.memory.page_size,ring,size,debug);
}

// REQUEST_SCALEFORM_MOVIE for a movie the game files don't have (Scripts/prepare_missing_scaleform.py):
// the barber asks for COLOUR_SWITCHER_01/02 and waited for them until it gave up without a menu (GTA-43).
// The request is made again for midsized_message, which every game version has and which draws nothing
// until a script asks it to show a message; the name string is rewritten so later requests go straight
// there. Script commands run on one thread.
u32 PG_FN_REQUEST_SCALEFORM_MOVIE(w2c_game*, u64, u32, u32); // graphics_commands::CommandRequestScaleformMovieCommon
static u32 scaleformFlags[2]; static bool scaleformStandIn;
void pg_scaleform_request_begin(w2c_game *instance, u64 name, u32 a, u32 b) {
  (void)instance; (void)name;
  if (!scaleformStandIn) { scaleformFlags[0] = a; scaleformFlags[1] = b; }
}
u32 pg_scaleform_missing(w2c_game *instance, u64 name) {
  static const char standIn[] = "midsized_message";
  if (scaleformStandIn) return 0; // the stand-in failed too
  size_t length = strnlen(pg_string(&env, name), 64);
  char line[200];
  if (length < sizeof standIn - 1) {
    snprintf(line, sizeof line, "Scaleform movie \"%.64s\" isn't in the game files.", pg_string(&env, name));
    pg_log(line);
    return 0;
  }
  snprintf(line, sizeof line, "Scaleform movie \"%.64s\" isn't in the game files; scripts get a blank one instead.", pg_string(&env, name));
  pg_log(line);
  memcpy(pg_pointer(&env, name, sizeof standIn), standIn, sizeof standIn);
  scaleformStandIn = true;
  u32 handle = PG_FN_REQUEST_SCALEFORM_MOVIE(instance, name, scaleformFlags[0], scaleformFlags[1]);
  scaleformStandIn = false;
  return handle;
}

// Mods inside archives (GTA-69, Scripts/prepare_mod_archives.py): called after rage::fiPackfile::Init.
// The packfile's RPF7 table of contents is decrypted in memory: entries (16 bytes each) at +32, names at
// +16 (entry name offset << byte at +184). Entry bits: 0-15 name offset, 16-39 stored size, 40-62 offset
// in 512-byte blocks (0x7FFFFF for a directory), 63 resource; second word: directory first child and
// count, file uncompressed size and encryption, or resource system and graphics flags.
static uint32_t pg_rpf_walk(uint64_t entries,uint64_t names,unsigned shift,uint32_t index,char *path,size_t length,int depth,const char *find,uint64_t *found){
 const uint64_t *e=pg_pointer(&env,entries+16ull*index,16);
 const char *name=pg_string(&env,names+((uint64_t)(e[0]&0xFFFF)<<shift));
 size_t n=length;
 if(index){n+=snprintf(path+length,length<480?512-length:0,"%s%s",length?"/":"",name);}
 if(((e[0]>>40)&0x7FFFFF)==0x7FFFFF){
  uint32_t first=(uint32_t)e[1],count=(uint32_t)(e[1]>>32),total=1;
  if(depth>32||count>200000)return total;
  for(uint32_t i=0;i<count;i++)total+=pg_rpf_walk(entries,names,shift,first+i,path,n,depth+1,find,found);
  path[length]=0;return total;
 }
 if(find&&!strcasecmp(path,find)&&!*found)*found=entries+16ull*index;
 path[length]=0;return 1;
}
// Mods inside archives (GTA-69): NativeAssets serves each mod file in a slot past the archive's real end;
// here the archive's entry for that file is pointed at the slot. Resources keep their version and flags
// from the mod's RSC7 header; other files become plain (unencrypted, uncompressed) data.
// The game file index for the mod installer (App/ModInstaller.swift): as the engine opens each archive,
// every file in it is written once per game version, "x64/levels/gta5/vehicles.rpf/oracle.yft"; files in
// archives inside other archives start with "@" (the mod loader can't change those yet).
static void pg_index_walk(FILE *out,const char *archive,uint64_t entries,uint64_t names,unsigned shift,uint32_t index,char *path,size_t length,int depth){
 const uint64_t *e=pg_pointer(&env,entries+16ull*index,16);
 const char *name=pg_string(&env,names+((uint64_t)(e[0]&0xFFFF)<<shift));
 size_t n=length;
 if(index)n+=snprintf(path+length,length<480?512-length:0,"%s%s",length?"/":"",name);
 if(((e[0]>>40)&0x7FFFFF)==0x7FFFFF){
  uint32_t first=(uint32_t)e[1],count=(uint32_t)(e[1]>>32);
  if(depth<32&&count<200000)for(uint32_t i=0;i<count;i++)pg_index_walk(out,archive,entries,names,shift,first+i,path,n,depth+1);
 }else fprintf(out,"%s/%s\n",archive,path);
 path[length]=0;
}
static void pg_game_index(const char *label,uint64_t packfile){
 static int state;static FILE *out;static uint64_t seen[4096];static int archives;static char temp[PATH_MAX];
 if(state<0)return;
 const char *final=pg_game_index_path();
 if(!state){
  char header[160];snprintf(header,sizeof header,"# game file index v1 %s\n",pg_game_files_version());
  FILE *old=fopen(final,"r");char line[160]={0};
  if(old){if(!fgets(line,sizeof line,old))line[0]=0;fclose(old);}
  if(!strcmp(line,header)){state=-1;return;}          // already written for these game files
  snprintf(temp,sizeof temp,"%s.part",final);
  if(!(out=fopen(temp,"w"))){state=-1;return;}
  fputs(header,out);state=1;
 }
 uint64_t hash=1469598103934665603ull;for(const char *c=label;*c;c++)hash=(hash^(uint8_t)*c)*1099511628211ull;
 for(uint64_t i=hash%4096,k=0;k<4096;i=(i+1)%4096,k++){if(seen[i]==hash)return;if(!seen[i]){seen[i]=hash;break;}}
 uint64_t entries=*(uint64_t *)pg_pointer(&env,packfile+32,8),names=*(uint64_t *)pg_pointer(&env,packfile+16,8);
 unsigned shift=*(uint8_t *)pg_pointer(&env,packfile+184,1);
 if(!entries||!names)return;
 char archive[600],path[512]={0};
 if(!pg_mods_archive_path(label,archive+1,sizeof archive-1))archive[0]='@';else memmove(archive,archive+1,strlen(archive+1)+1);
 pg_index_walk(out,archive,entries,names,shift,0,path,0,0);
 // The game opens about 1300 archives while starting; after that the index is complete enough to use.
 if(++archives==1000){fflush(out);rename(temp,final);pg_log("Mods: the game's file index is ready for the mod installer.");}
 else if(archives>1000&&archives%50==0)fflush(out);
}
// Audio in PC add-on packs (GTA-88): the game's own packs keep each audio data file three ways (X.dat151,
// X.dat151.nametable, X.dat151.rel) and this engine reads the plain X.dat151; PC mods only ship the release
// copy X.dat151.rel, so a car with its own sounds stopped the game after "Failed to find ...dat151". The
// .rel file holds the same data: in an archive that has no plain copy, its entry is renamed to the plain
// name (the names table is in memory; dropping a trailing ".rel" keeps the directory's sort order).
static int pg_audio_rel_walk(uint64_t entries,uint64_t names,unsigned shift,uint32_t index,int depth){
 const uint64_t *e=pg_pointer(&env,entries+16ull*index,16);
 if(((e[0]>>40)&0x7FFFFF)!=0x7FFFFF)return 0;
 uint32_t first=(uint32_t)e[1],count=(uint32_t)(e[1]>>32);int renamed=0;
 if(depth>16||count>20000)return 0;
 for(uint32_t i=0;i<count;i++){
  const uint64_t *child=pg_pointer(&env,entries+16ull*(first+i),16);
  if(((child[0]>>40)&0x7FFFFF)==0x7FFFFF){renamed+=pg_audio_rel_walk(entries,names,shift,first+i,depth+1);continue;}
  char *name=(char *)pg_string(&env,names+((uint64_t)(child[0]&0xFFFF)<<shift));
  size_t length=strlen(name);
  if(length<9||strcasecmp(name+length-4,".rel")||!strcasestr(name,".dat"))continue;
  bool plain=false;
  for(uint32_t k=0;k<count&&!plain;k++){
   const uint64_t *other=pg_pointer(&env,entries+16ull*(first+k),16);
   const char *otherName=pg_string(&env,names+((uint64_t)(other[0]&0xFFFF)<<shift));
   plain=k!=i&&strlen(otherName)==length-4&&!strncasecmp(otherName,name,length-4);
  }
  if(plain)continue;
  name[length-4]=0;renamed++;
 }
 return renamed;
}
void pg_packfile_mounted(w2c_game *instance,u64 packfile,u64 name,u32 result){
 (void)instance;
 if(!result)return;
 const char *label=pg_string(&env,name);
 pg_game_index(label,packfile);
 size_t labelLength=strlen(label);
 if(labelLength>8&&!strcasecmp(label+labelLength-7,"dlc.rpf")&&(label[labelLength-8]=='/'||label[labelLength-8]=='\\')){   // "platform:\dlcPacks\<pack>\dlc.rpf"
  uint64_t entries=*(uint64_t *)pg_pointer(&env,packfile+32,8),names=*(uint64_t *)pg_pointer(&env,packfile+16,8);
  unsigned shift=*(uint8_t *)pg_pointer(&env,packfile+184,1);
  int renamed=entries&&names?pg_audio_rel_walk(entries,names,shift,0,0):0;
  if(getenv("PG_TEST_MODS")){char test[400];snprintf(test,sizeof test,"TEST: dlc pack %.300s mounted, %d audio .rel renamed (entries %s).",label,renamed,entries&&names?"ok":"missing");pg_log(test);}
  static _Atomic int told;
  if(renamed&&atomic_fetch_add(&told,1)<16){char line[400];snprintf(line,sizeof line,"Mods: %.300s has PC audio data (.rel only); %d file%s read as the game's own.",label,renamed,renamed==1?"":"s");pg_log(line);}
 }
 const PGModPiece *pieces=NULL;int count=pg_mods_for_archive(label,&pieces);
 if(getenv("PG_TEST_MODS")&&strstr(label,"vehicles.rpf")){char test[400];snprintf(test,sizeof test,"TEST: mounted %.300s, %d mod files.",label,count);pg_log(test);}
 if(!count)return;
 uint64_t entries=*(uint64_t *)pg_pointer(&env,packfile+32,8),names=*(uint64_t *)pg_pointer(&env,packfile+16,8);
 unsigned shift=*(uint8_t *)pg_pointer(&env,packfile+184,1);
 if(!entries||!names)return;
 char line[700];int applied=0;
 for(int i=0;i<count;i++){
  char path[512]={0};uint64_t found=0;
  pg_rpf_walk(entries,names,shift,0,path,0,0,pieces[i].inner,&found);
  uint64_t block=pieces[i].offset/512;
  if(!found){if(atomic_fetch_add(&pg_mods_reported_missing,1)>=24)continue;snprintf(line,sizeof line,"Mods: %.200s has no %.200s to replace; new files inside game archives aren't supported, ignored.",label,pieces[i].inner);pg_log(line);continue;}
  if(block>=0x7FFFFF){snprintf(line,sizeof line,"Mods: %.200s is too large to hold %.200s; ignored.",label,pieces[i].inner);pg_log(line);continue;}
  uint64_t *e=pg_pointer(&env,found,16);
  uint64_t nameOffset=e[0]&0xFFFF;
  if(getenv("PG_TEST_MODS")){snprintf(line,sizeof line,"TEST: %s entry was %016llx %016llx (offset %llu).",pieces[i].inner,(unsigned long long)e[0],(unsigned long long)e[1],(unsigned long long)((e[0]>>40)&0x7FFFFF)*512);pg_log(line);}
  if(pieces[i].resource){
   e[0]=nameOffset|((pieces[i].length&0xFFFFFF)<<16)|(block<<40)|(1ull<<63);
   e[1]=(uint64_t)pieces[i].low|((uint64_t)pieces[i].high<<32);
  } else {
   e[0]=nameOffset|(block<<40);   // stored size 0: stored as is
   e[1]=(uint64_t)(uint32_t)pieces[i].length;
  }
  applied++;
  if(getenv("PG_TEST_MODS")){snprintf(line,sizeof line,"TEST: %s entry now %016llx %016llx (slot at %llu, %llu bytes).",pieces[i].inner,(unsigned long long)e[0],(unsigned long long)e[1],(unsigned long long)pieces[i].offset,(unsigned long long)pieces[i].length);pg_log(line);
   if(i==0){pg_mod_test_entry=found;pg_mod_test_value=e[0];}}
 }
 // The streaming system reloads archive tables often (ReInit); the first openings are enough in the log.
 static _Atomic int reported;
 if(atomic_fetch_add(&reported,1)<24){snprintf(line,sizeof line,"Mods: %.300s opened with %d of %d mod file%s.",label,applied,count,count==1?"":"s");pg_log(line);}
}
static void pg_mod_test_recheck(void){
 if(!pg_mod_test_entry)return;
 const uint64_t *e=pg_pointer(&env,pg_mod_test_entry,16);char line[200];
 snprintf(line,sizeof line,"TEST: first patched entry is %016llx now (%s).",(unsigned long long)e[0],e[0]==pg_mod_test_value?"unchanged":"CHANGED since the patch");pg_log(line);
}
