#include "HostInternal.h"
#include "wasm-rt-impl.h"
#include <pthread.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <time.h>
#include <unistd.h>
#include <TargetConditionals.h>

static struct w2c_env *mainHost;
// The engine's threads run without a QoS class; under a steady multi-core load iOS may then put them on
// efficiency cores or lower clocks (GTA-92: FPS halves after a minute while CPU time per frame grows
// 2.4-2.9x at the same scene load). Since v1.4.3 every engine thread is user-initiated (Kevin, 2026-10-20);
// PG_ENGINE_QOS=interactive raises them further, PG_ENGINE_QOS=off leaves them without a class as before.
void pg_engine_thread_attributes(pthread_attr_t *attrs) {
  static int qos = -1;
  if (qos < 0) {
    const char *v = getenv("PG_ENGINE_QOS");
    qos = v && !strcmp(v, "off") ? 0 : v && !strcmp(v, "interactive") ? QOS_CLASS_USER_INTERACTIVE : QOS_CLASS_USER_INITIATED;
    char line[96]; snprintf(line, sizeof line, "Engine threads run at QoS %s.", qos == QOS_CLASS_USER_INTERACTIVE ? "user-interactive" : qos ? "user-initiated" : "default"); pg_log(line);
  }
  if (qos) pthread_attr_set_qos_class_np(attrs, (qos_class_t)qos, 0);
}
struct EngineThread {struct w2c_env host;struct w2c_wasi__snapshot__preview1 wasi;u64 pthread,start,arg;wasm_rt_funcref_t *table;};
static _Thread_local struct EngineThread *currentThread;
// Function tables (GTA-192). Each engine thread is its own module instance with its own copy of the indirect function
// table (89368 entries, 2.9 MB), which wasm2c_game_instantiate used to calloc on the new thread without a check. When
// the save list thread ([RAGE] EnumerationThread) started for the autosave after Casing the Jewel Store, that calloc
// returned NULL on a player's iPad (iPad13,4, increased memory limit not granted) and filling the table wrote to address
// 0x20: the app was gone right after the mission (log 2438, crash at wasm2c_game_instantiate+0x1cc, the table fill).
// Now a table that a thread is done with is kept for the next one, one spare is made with the main instance's table at
// startup (while memory is plentiful), and a thread gets its table in pthread_create, before it exists: if there is none
// at all, pthread_create answers EAGAIN instead of the app crashing. Scripts/prepare_thread_tables.py routes the table
// allocation of wasm2c_game_instantiate and the release of wasm2c_game_free here.
enum {SPARE_TABLES=1, KEPT_TABLES=3};
static pthread_mutex_t tablesLock=PTHREAD_MUTEX_INITIALIZER;
static wasm_rt_funcref_t *keptTables[KEPT_TABLES];
static int keptCount;
static uint32_t tableElements;	// the game's table size, from the main instance
static _Atomic bool startupSpareMade;
#if TARGET_OS_SIMULATOR
static double tablesStartedAt;
static double nowMS(void){struct timespec t;clock_gettime(CLOCK_MONOTONIC,&t);return t.tv_sec*1000.0+t.tv_nsec/1e6;}
#endif
// Test (simulator, PG_TEST_TABLE_ALLOC_FAIL=<seconds>): from that long after startup, every new table fails to allocate,
// as on the player's iPad at the autosave; later engine threads must still start.
static bool testTablesFail(void){
  #if TARGET_OS_SIMULATOR
  static double failAfter=-2;
  if(failAfter==-2){const char *v=getenv("PG_TEST_TABLE_ALLOC_FAIL");failAfter=v?atof(v):-1;}
  if(failAfter>=0&&tablesStartedAt&&nowMS()-tablesStartedAt>failAfter*1000){
    static _Atomic bool logged;if(!atomic_exchange(&logged,true))pg_log("TEST: new engine function tables fail to allocate from now on.");
    return true;
  }
  #endif
  return false;
}
static wasm_rt_funcref_t *newTable(uint32_t elements){
  if(testTablesFail())return NULL;
  return calloc(elements,sizeof(wasm_rt_funcref_t));
}
static wasm_rt_funcref_t *takeTable(uint32_t elements){
  wasm_rt_funcref_t *data=NULL;
  pthread_mutex_lock(&tablesLock);
  if(keptCount&&elements==tableElements)data=keptTables[--keptCount];
  pthread_mutex_unlock(&tablesLock);
  if(data){memset(data,0,(size_t)elements*sizeof *data);return data;}	// as calloc'd
  return newTable(elements);
}
static void keepTable(wasm_rt_funcref_t *data,uint32_t elements){
  if(!data)return;
  pthread_mutex_lock(&tablesLock);
  if(keptCount<KEPT_TABLES&&elements==tableElements){keptTables[keptCount++]=data;data=NULL;}
  pthread_mutex_unlock(&tablesLock);
  free(data);
}
// Tops the kept tables up to SPARE_TABLES after a thread took one (it doesn't matter if this fails).
static void makeSpareTables(void){
  for(int made=0;made<SPARE_TABLES;made++){
    pthread_mutex_lock(&tablesLock);int count=keptCount;pthread_mutex_unlock(&tablesLock);
    if(count>=SPARE_TABLES||!tableElements)return;
    wasm_rt_funcref_t *spare=newTable(tableElements);
    if(!spare){char line[120];snprintf(line,sizeof line,"Engine function table: no spare made now (%d kept).",count);pg_log(line);return;}
    keepTable(spare,tableElements);
  }
}
void pg_allocate_funcref_table(wasm_rt_funcref_table_t *table,uint32_t elements,uint32_t maxElements){
  if(!tableElements)tableElements=elements;
  #if TARGET_OS_SIMULATOR
  if(!tablesStartedAt)tablesStartedAt=nowMS();
  #endif
  wasm_rt_funcref_t *data=NULL;
  struct EngineThread *thread=currentThread;
  if(thread&&thread->table&&elements==tableElements){data=thread->table;thread->table=NULL;}	// zeroed in pthread_create
  if(!data)data=takeTable(elements);
  for(int tries=0;!data&&tries<50;tries++){
    if(!tries){char line[160];snprintf(line,sizeof line,"Engine function table: no memory for %u entries; waiting up to 5 s.",elements);pg_log(line);}
    usleep(100000);data=takeTable(elements);
  }
  if(!data){pg_log("Engine function table: still no memory after 5 s; this engine thread stops.");wasm_rt_trap(WASM_RT_TRAP_OOB);}
  table->data=data;table->size=elements;table->max_size=maxElements;
  if(!atomic_load(&startupSpareMade)){
    wasm_rt_funcref_t *spare=calloc(elements,sizeof *spare);		// with the main instance, while memory is plentiful
    if(spare)keepTable(spare,elements);
    atomic_store(&startupSpareMade,true);
  }
}
void pg_free_funcref_table(wasm_rt_funcref_table_t *table){
  keepTable(table->data,table->size);table->data=NULL;table->size=0;
}
static void disposeThread(void *pointer) {
  struct EngineThread *thread=pointer;
  wasm2c_game_free(&thread->host.game);keepTable(thread->table,tableElements);wasm_rt_free_thread();free(thread);currentThread=NULL;
}
// Native names for the engine's threads, for the Threads line in the log (GTA-162, NativeThreadCPU.c). The game names
// every thread it starts: rage::sysIpcCreateThread (f128) mallocs a 56-byte block, copies the name into it at offset
// 24 (31 characters at most) and starts rage::sysIpcThreadWrapper (table index 15) with it. Other threads are
// "gta.engine.start<N>", after their start function's table index.
static void nameEngineThread(struct EngineThread *thread) {
  wasm_rt_shared_memory_t *m=&thread->host.memory;const uint8_t *base=(const uint8_t *)(void *)m->data;
  char name[64]="";u64 arg=thread->arg;
  if(thread->start==15&&arg&&arg<m->size&&m->size-arg>=56){
    size_t n=0;while(n<31&&base[arg+24+n]>=0x20&&base[arg+24+n]<0x7f)n++;
    if(n>=2&&!base[arg+24+n]){memcpy(name,base+arg+24,n);name[n]=0;}
  }
  if(!name[0])snprintf(name,sizeof name,"gta.engine.start%llu",(unsigned long long)thread->start);
  pthread_setname_np(name);
  char line[96];snprintf(line,sizeof line,"Engine thread: %s.",name);pg_log(line);
}
static void *runThread(void *pointer) {
  struct EngineThread *thread=pointer;currentThread=thread;wasm_rt_init_thread();
  pthread_cleanup_push(disposeThread,thread);
  wasm_rt_trap_t trap=wasm_rt_impl_try();
  if(trap) {char line[200];snprintf(line,sizeof line,"Native game thread stopped: %s",wasm_rt_strerror(trap));pg_log(line);}
  else {
    wasm2c_game_instantiate(&thread->host.game,&thread->host,&thread->wasi);
    u64 high=*(u64 *)pg_pointer(&thread->host,thread->pthread+80,8);
    u64 size=*(u64 *)pg_pointer(&thread->host,thread->pthread+88,8);
    if(size>high)wasm_rt_trap(WASM_RT_TRAP_OOB);
    w2c_game_emscripten_stack_set_limits(&thread->host.game,high,high-size);
    w2c_game_0x5Femscripten_stack_restore(&thread->host.game,high);
    w2c_game_0x5Femscripten_thread_init(&thread->host.game,thread->pthread,0,0,1,1048576,0);
    w2c_game_0x5Femscripten_tls_init(&thread->host.game);
    wasm_rt_funcref_table_t *table=w2c_game_0x5F_indirect_function_table(&thread->host.game);
    nameEngineThread(thread);
    if(thread->start>=table->size)wasm_rt_trap(WASM_RT_TRAP_CALL_INDIRECT);
    wasm_rt_funcref_t entry=table->data[thread->start];
    wasm_rt_func_type_t expected=wasm2c_game_get_func_type(1,1,WASM_RT_I64,WASM_RT_I64);
    if(!entry.func||!entry.func_type||memcmp(entry.func_type,expected,32))wasm_rt_trap(WASM_RT_TRAP_CALL_INDIRECT);
    u64 result=((u64 (*)(void *,u64))entry.func)(entry.module_instance,thread->arg);
    w2c_game_0x5Femscripten_thread_exit(&thread->host.game,result);
  }
  pthread_cleanup_pop(1);return NULL;
}
u32 w2c_env_0x5F_pthread_create_js(struct w2c_env *host,u64 pthread,u64 attr,u64 routine,u64 argument) {
  struct EngineThread *thread=calloc(1,sizeof *thread);if(!thread)return 6;
  thread->host.memory=*w2c_env_memory(host);thread->wasi.env=&thread->host;
  thread->pthread=pthread;thread->start=routine;thread->arg=argument;
  // Its function table first (GTA-192): a kept one, or a new one; without one the engine gets EAGAIN, not a crash.
  testTablesFail();
  if(tableElements){
    thread->table=takeTable(tableElements);
    if(!thread->table){
      char line[160];snprintf(line,sizeof line,"Engine thread not started: no memory for its function table (%u entries); pthread_create answers EAGAIN.",tableElements);pg_log(line);
      free(thread);return 6;
    }
    makeSpareTables();
  }
  pthread_attr_t attrs;pthread_attr_init(&attrs);pthread_attr_setstacksize(&attrs,16*1024*1024);pg_engine_thread_attributes(&attrs);
  pthread_t native;int e=pthread_create(&native,&attrs,runThread,thread);pthread_attr_destroy(&attrs);
  if(e){keepTable(thread->table,tableElements);free(thread);return 6;}pthread_detach(native);return 0;
}
void pg_threads_main(struct w2c_env *host){mainHost=host;}
void w2c_env_0x5Femscripten_thread_cleanup(struct w2c_env *host,u64 thread) {
  // Emscripten pthread state is released after the engine exit protocol finishes.
  // Keeping the record alive also permits a later pthread_join to read its result.
}
void w2c_env_0x5Femscripten_notify_mailbox_postmessage(struct w2c_env *host,u64 target,u64 current) {
  // Native blocking workers process mailbox messages at their engine futex points.
  // A direct proxy below handles synchronous host operations without a JS event loop.
}
// When the heap last refused to grow (CLOCK_MONOTONIC seconds as bits), for the streaming guard.
_Atomic uint64_t pgHeapRefusedAt;
u32 w2c_env_emscripten_resize_heap(struct w2c_env *host,u64 desired){
  wasm_rt_shared_memory_t *memory=w2c_env_memory(host);u32 success=0;
  static uint64_t refused;static double lastRefusedLog;
  pthread_mutex_lock(&memory->mem_lock);
  uint64_t capacity=memory->max_pages*memory->page_size;
  if(desired<=memory->size)success=1;
  else if(desired<=capacity){
    uint64_t previous=memory->size,pages=(desired+memory->page_size-1)/memory->page_size;
    // The imported module instances share this memory descriptor. Its backing
    // mapping and the renderer's external ArrayBuffer remain at the same address.
    memory->pages=pages;memory->size=pages*memory->page_size;success=1;
    char line[160];snprintf(line,sizeof line,"Native heap grew from %llu to %llu MB within the shared reservation.",previous/1048576,memory->size/1048576);pg_log(line);
  }else{
    uint64_t count=++refused;
    {struct timespec now;clock_gettime(CLOCK_MONOTONIC,&now);double at=now.tv_sec+now.tv_nsec/1e9;uint64_t bits;memcpy(&bits,&at,8);atomic_store(&pgHeapRefusedAt,bits);}
    if(count==1||(count&4095)==0){struct timespec now;clock_gettime(CLOCK_MONOTONIC,&now);double seconds=now.tv_sec+now.tv_nsec/1e9;
      if(count==1||seconds-lastRefusedLog>=5){char line[180];snprintf(line,sizeof line,"Native heap capacity exceeded: requested %llu MB, capacity %llu MB (%llu attempts)",desired/1048576,capacity/1048576,count);pg_log(line);lastRefusedLog=seconds;}
    }
  }
  pthread_mutex_unlock(&memory->mem_lock);return success;
}
u64 w2c_env_emscripten_stack_snapshot(struct w2c_env *host){return 0;}
u32 w2c_env_emscripten_stack_unwind_buffer(struct w2c_env *host,u64 pc,u64 output,u32 count){return 0;}
u32 w2c_env_0x5Femscripten_system(struct w2c_env *host,u64 command){return command?(u32)-52:0;}
void w2c_env_emscripten_exit_with_live_runtime(struct w2c_env *host){pthread_exit(NULL);}
void w2c_env_exit(struct w2c_env *host,u32 status){char line[80];snprintf(line,sizeof line,"Game thread exited with status %u",status);pg_log(line);pthread_exit(NULL);}
void w2c_wasi__snapshot__preview1_proc_exit(struct w2c_wasi__snapshot__preview1 *host,u32 status){w2c_env_exit(host->env,status);}
void w2c_env_0x5Fabort_js(struct w2c_env *host){pg_log("Engine requested abort.");wasm_rt_trap(WASM_RT_TRAP_UNREACHABLE);}
