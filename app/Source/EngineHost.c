#include "HostInternal.h"
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
void pg_log(const char *message) {
  if (!strncmp(message, "[wasm] region 0x", 16)) pg_note_region(message);
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
 available=os_proc_available_memory();
 available=available>capReserveBytes?available-capReserveBytes:0;
#endif
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
 if(t-since<(loading?0.25:1.5))return result;
 atomic_store(&holdingSince,t);atomic_fetch_add(&memoryBudgetNudges,1);
 return loading?-(slice>(96ll<<20)?slice:(96ll<<20)):-slice;
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
// The engine heap's reservation. 4095 MB unless the process may use clearly more: the game's
// heap hit that ceiling on 8 GB-limit phones while about 1 GB of the limit was still free.
// About 3 GB of the limit stays for textures, Metal and the app.
void PGSetMemoryCap(int mb) { if (!atomic_load(&started)) memoryCapMB = mb > 0 ? (uint64_t)mb : 0; }
static uint64_t pg_engine_memory_mb(void){
 const char *configured=getenv("PG_ENGINE_MEMORY_MB");
 if(configured){long mb=atol(configured);if(mb>=1024&&mb<=8192)return (uint64_t)mb;}
#if !TARGET_OS_SIMULATOR
 task_vm_info_data_t info={};mach_msg_type_number_t count=TASK_VM_INFO_COUNT;
 if(task_info(mach_task_self(),TASK_VM_INFO,(task_info_t)&info,&count)==KERN_SUCCESS){
  uint64_t limitMB=(os_proc_available_memory()+info.phys_footprint)>>20;
  if(memoryCapMB&&memoryCapMB<limitMB){
   capReserveBytes=(limitMB-memoryCapMB)<<20; // headroom the guard leaves unused
   char line[96];snprintf(line,sizeof line,"Memory cap: %llu MB of the %llu MB limit.",(unsigned long long)memoryCapMB,(unsigned long long)limitMB);pg_log(line);
   limitMB=memoryCapMB;
  }
  processLimitMB=limitMB;
  if(limitMB>=4095+3072+512)return limitMB-3072<6144?limitMB-3072:6144;
 }
#endif
 return 4095;
}
// The adapter's video memory as the engine reads it (Scripts/prepare_video_memory.py). The
// browser build reports about 4 GB on every device, so the engine streams textures as if a phone
// had 4 GB of video memory to spare. On GPUs that decode BC textures they also take about 4 times
// what the engine counts. Memory then fills within minutes and the streaming guard throttles the
// game for the rest of the session (the slowdown players report). The budget is what the limit
// leaves after about 1.8 GB for the rest of the game and the guard's reserve, halved where BC
// textures are decoded (in simulator soaks the GPU held about twice what the engine counted).
int PGGPUReadsBC(void);
u64 pg_video_memory(u64 reported){
 uint64_t mb=0;
 const char *configured=getenv("PG_VIDEO_MEMORY_MB");
 if(configured)mb=(uint64_t)atol(configured);
 else if(processLimitMB){
  uint64_t textures=processLimitMB>1800+640?processLimitMB-1800:640;
  mb=PGGPUReadsBC()?textures:textures/2;
  if(mb<640)mb=640;
 }
 if(!mb||(mb<<20)>=reported)return reported;
 char line[160];snprintf(line,sizeof line,"Video memory for the engine: %llu MB (memory limit %llu MB, %s).",(unsigned long long)mb,(unsigned long long)processLimitMB,PGGPUReadsBC()?"GPU reads BC textures":"BC textures decoded");pg_log(line);
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
// (IS_WARNING_MESSAGE_ACTIVE: 19577926 or 19577929 bit 0), 16 no local player yet.
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
 // Help messages (CMessages, 3 slots of 600 bytes; "is help showing" is the first byte).
 uint8_t first=0;
 if(pg_context_u8(m,size,25477136,&first)&&first&&size>25477136+1800){
  hints.helpShown=true;
  const char *text=(const char *)(m+25477136);
  static const char *const tokens[]={"INPUT_CONTEXT","INPUT_TALK"};
  for(int t=0;t<2&&!hints.helpContext;t++)if(memmem(text,1800,tokens[t],strlen(tokens[t])))hints.helpContext=true;
  // Logged once per new message, so the prompts' button tokens can be checked in logs.
  static char last[96];char now[96];size_t n=strnlen(text,95);memcpy(now,text,n);now[n]=0;
  if(strcmp(now,last)){memcpy(last,now,sizeof last);char line[160];snprintf(line,sizeof line,"Help message: %s",now);pg_log(line);}
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
 if(hints.passenger){
  uint64_t threads;uint16_t count=0;
  if(pg_context_u64(m,size,15409704,&threads)&&threads&&pg_context_u16(m,size,15409712,&count)){
   for(uint16_t i=0;i<count&&i<512;i++){
    uint64_t thread;
    if(!pg_context_u64(m,size,threads+8ull*i,&thread)||!thread||thread+440>size)continue;
    if(!strncasecmp((const char *)(m+thread+428),"taxiservice",12)){hints.taxiMenu=true;break;}
   }
  }
 }
 return hints;
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
u64 PG_FN_OPERATOR_NEW(w2c_game*, u64); // operator new
// Used outside the simulator tests below too (the weapon streaming guard, the saved-cash restore).
u32 PG_FN_STAT_GET_INT(w2c_game*, u32, u64, u32); // stats_commands::CommandStatGetInt
u32 PG_FN_WEAPON_ENTITY(w2c_game*, u32, u32); // weapon_commands::CommandGetCurrentPedWeaponEntityIndex
u32 PG_FN_SELECTED_WEAPON(w2c_game*, u32); // weapon_commands::CommandGetSelectedPedWeapon
u32 PG_FN_PLAYER_PED_ID(w2c_game*); // player_commands::CommandPlayerPedId
void PG_FN_SET_ENTITY_COORDS_NO_OFFSET(w2c_game*, u32, u64, u32, u32, u32); // entity_commands::CommandSetEntityCoordsNoOffset
// Script commands that create entities need a running script: lends them the "main" script's
// thread (the active thread is per engine thread, at g1 + 3088). Returns the previous one.
static uint64_t pg_enter_main_script(w2c_game *instance) {
  uint64_t *active = pg_pointer(&env, instance->w2c_g1 + 3088, 8), previous = *active;
  *active = 0; // Never attach a menu-spawned entity to an unrelated mission script.
  uint64_t threads = *(uint64_t *)pg_pointer(&env, 15409704, 8);
  uint16_t count = *(uint16_t *)pg_pointer(&env, 15409712, 2);
  for (uint16_t i = 0; i < count; i++) {
    uint64_t thread = *(uint64_t *)pg_pointer(&env, threads + 8ull * i, 8);
    if (thread && !strcmp(pg_string(&env, thread + 428), "main")) { *active = thread; break; }
  }
  return previous;
}
static void pg_leave_main_script(w2c_game *instance, uint64_t previous) {
  *(uint64_t *)pg_pointer(&env, instance->w2c_g1 + 3088, 8) = previous;
}
#include "NativeCheats.inc"
#include "NativeVehicleSpawn.inc"
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
  if (++frames < first || (frames - first) % (period ? period : 1)) return;
  if (!period) frames = -1;
  const float *t = p[jumps++ & 1];
  uint64_t vector = PG_FN_OPERATOR_NEW(instance, 32);
  float *v = pg_pointer(&env, vector, 24); v[0] = t[0]; v[2] = t[1]; v[4] = t[2];
  PG_FN_SET_ENTITY_COORDS_NO_OFFSET(instance, PG_FN_PLAYER_PED_ID(instance), vector, 0, 0, 0);
  char line[96]; snprintf(line, sizeof line, "TEST: player moved to %.1f, %.1f, %.1f (jump %d).", t[0], t[1], t[2], jumps); pg_log(line);
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
void PG_FN_TV_SETUP_LESTER1(w2c_game*); // CTVPlaylistManager::SetupLester1CB
f32 PG_FN_TV_SCALE_TO_REAL_TIME(w2c_game*, f32); // CTVPlaylistManager::ScaleToRealTime
u32 PG_FN_TV_CURRENT_SHOW_HASH(w2c_game*); // CTVPlaylistManager::GetCurrentShowNameHash
void PG_FN_TV_SHOW_PLAY_TIME(w2c_game*, u64); // scrWrapped_GET_CURRENT_TV_SHOW_PLAY_TIME
void PG_FN_TV_SHOW_DURATION(w2c_game*, u64); // scrWrapped_GET_CURRENT_TV_SHOW_DURATION
u32 PG_FN_BEGIN_TAKE_HIGH_QUALITY_PHOTO(w2c_game*); // graphics_commands::CommandBeginTakeHighQualityPhoto
u32 PG_FN_TAKE_HIGH_QUALITY_PHOTO_STATUS(w2c_game*); // graphics_commands::CommandGetStatusOfTakeHighQualityPhoto
u32 PG_FN_BEGIN_LOW_QUALITY_PHOTO_COPY(w2c_game*, u32); // graphics_commands::CommandBeginCreateLowQualityCopyOfPhoto
u32 PG_FN_LOW_QUALITY_PHOTO_COPY_STATUS(w2c_game*, u32); // graphics_commands::CommandGetStatusOfCreateLowQualityCopyOfPhoto
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
  uint64_t previous = pg_enter_main_script(instance);
  int status = -1;
  if (stage == 0) { pg_log("TEST: taking a phone photo."); status = (int)PG_FN_BEGIN_TAKE_HIGH_QUALITY_PHOTO(instance); stage = 1; last = -1; }
  else if (stage == 1) status = (int)PG_FN_TAKE_HIGH_QUALITY_PHOTO_STATUS(instance);
  else status = (int)PG_FN_LOW_QUALITY_PHOTO_COPY_STATUS(instance, 0);
  pg_leave_main_script(instance, previous);
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
    previous = pg_enter_main_script(instance);
    int started = (int)PG_FN_BEGIN_LOW_QUALITY_PHOTO_COPY(instance, 0);
    pg_leave_main_script(instance, previous);
    char line[96]; snprintf(line, sizeof line, "TEST: low quality copy requested (%d).", started); pg_log(line);
    stage = 2; last = -1;
  } else if (stage == 2 && status != 0) { pg_log("TEST: photo finished."); stage = 3; }
  if (frames > 1800 + 30 * 60 && stage < 3) { pg_log("TEST: photo still not finished after 60 s."); stage = 3; }
}
void PG_FN_REQUEST_MODEL(w2c_game*, u32); // streaming_commands::CommandRequestModel
u32 PG_FN_HAS_MODEL_LOADED(w2c_game*, u32); // streaming_commands::HasModelLoaded
u32 PG_FN_CREATE_VEHICLE(w2c_game*, u32, u64, f32, u32, u32, u32); // vehicle_commands::CommandCreateVehicle
void PG_FN_SET_PED_INTO_VEHICLE(w2c_game*, u32, u32, u32); // ped_commands::CommandSetPedIntoVehicle
// Test (PG_TEST_CAR="x,y,z,heading"): from about 35 s in, puts the player in a car (a Sultan) there.
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
  if (frames < 0 || !target || ++frames < 1050 || sscanf(target, "%f,%f,%f,%f", &x, &y, &z, &heading) != 4) return;
  // PG_TEST_CAR_MODEL=<name> picks the vehicle (joaat of the model name), "sultan" by default.
  uint32_t model = 970598228u; // joaat("sultan")
  const char *name = getenv("PG_TEST_CAR_MODEL");
  if (name && *name) { uint32_t h = 0; for (const char *c = name; *c; c++) { h += (uint8_t)(*c >= 'A' && *c <= 'Z' ? *c + 32 : *c); h += h << 10; h ^= h >> 6; } h += h << 3; h ^= h >> 11; h += h << 15; model = h; }
  uint64_t previous = pg_enter_main_script(instance);
  PG_FN_REQUEST_MODEL(instance, model);
  if (!PG_FN_HAS_MODEL_LOADED(instance, model) && frames < 1650) { pg_leave_main_script(instance, previous); return; }
  frames = -1;
  uint64_t vector = PG_FN_OPERATOR_NEW(instance, 32);
  float *v = pg_pointer(&env, vector, 24); v[0] = x; v[2] = y; v[4] = z;
  uint32_t vehicle = PG_FN_CREATE_VEHICLE(instance, model, vector, heading, 0, 0, 1);
  if (vehicle) PG_FN_SET_PED_INTO_VEHICLE(instance, PG_FN_PLAYER_PED_ID(instance), vehicle, (uint32_t)-1);
  pg_leave_main_script(instance, previous);
  if (getenv("PG_TEST_DRIVE")) driving = atoi(getenv("PG_TEST_DRIVE")) + 1;
  char line[96]; snprintf(line, sizeof line, "TEST: player put in car %u at %.1f, %.1f, %.1f.", vehicle, x, y, z); pg_log(line);
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
    uint64_t previous = pg_enter_main_script(instance);
    if (!requested) { PG_FN_REQUEST_MODEL(instance, h); char line[128]; snprintf(line, sizeof line, "TEST: requested model %s (0x%08x).", name, h); pg_log(line); }
    else if (!done[index]) {
      if (PG_FN_HAS_MODEL_LOADED(instance, h)) { done[index] = 1; char line[128]; snprintf(line, sizeof line, "TEST: model %s loaded.", name); pg_log(line); }
      else pending++;
    }
    pg_leave_main_script(instance, previous);
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
void pg_virtual_pad_apply(w2c_game *instance, uint64_t pad) {
  if (pad == 12840656) pg_next_aircraft_weapon(instance);
  if (pad == 12840656) pg_apply_cash_request(instance);
  if (pad == 12840656) pg_apply_lite(instance);
  if (pad == 12840656) pg_apply_targeting_mode(instance);
  if (pad == 12840656) pg_keep_on_test_map(instance);
  if (pad == 12840656) pg_keep_weapon_loaded(instance);
#if TARGET_OS_SIMULATOR
  if (pad == 12840656) { pg_test_teleport(instance); pg_test_speed(instance); pg_test_weapon(instance); pg_test_outfit(instance); pg_test_prompts(instance); pg_test_cash(instance); pg_test_tv(instance); pg_test_video(instance); pg_test_lester1_tv(instance); pg_test_photo(instance); pg_test_car(instance); pg_test_request_models(instance); pg_test_loadscene(instance); pg_test_loadscene_monitor(instance); }
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
}

static char *configuredQuality[32];static unsigned configuredQualityCount;
// The frame limiter reads the frame interval (in 60 Hz refreshes: 0 none, 1 = 60 FPS, 2 = 30 FPS)
// from 19447080 every frame (CSystem frame limit, set from -frameLimit), so it can change in play.
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
  // Real iOS must budget against its Jetsam allowance. Simulator runs opt in
  // with an explicit modeled ceiling so ordinary performance baselines match.
  const char *guard=getenv("PG_MEMORY_GUARD");nativeMemoryGuard=guard?atoi(guard)==1:!TARGET_OS_SIMULATOR;
#if TARGET_OS_SIMULATOR
  const char *limit=getenv("PG_STREAM_MEMORY_LIMIT_MB");
  if(limit){char *end;unsigned long mb=strtoul(limit,&end,10);if(end!=limit&&!*end&&mb>=2048&&mb<=8192)simulatedProcessLimit=(uint64_t)mb*1048576;}
#endif
  if(nativeMemoryGuard)pg_log("Native streaming memory guard enabled with 384 MB of reserve.");
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
  if (allocation==MAP_FAILED&&engineMB>4095) {
    pg_log("iOS could not reserve that much; using 4095 MB.");
    env.memory.max_pages=4095ull*1024*1024/wasm2c_game_pagesize_env_memory;capacity=env.memory.max_pages*env.memory.page_size;
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
void pg_control_read(u32 kind, u32 control, u32 action, f32 value) {
  if (action < 400) atomic_store_explicit(&inputPolledAt[action], timeMS(CLOCK_MONOTONIC), memory_order_relaxed);
  static int on = -1;
  if (on < 0) on = getenv("PG_TEST_CONTROLS") != NULL;
  if (!on || kind > 4 || action >= 400) return;
  (void)control;
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
