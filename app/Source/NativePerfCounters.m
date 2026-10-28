// CPU work per frame, for comparing builds on a phone (GTA-216). The Health line's CPU time depends on how fast the
// chip runs, and a hot phone runs slower, so two runs of the same build differ by as much as most optimisations save.
// The kernel also counts the instructions and cycles each thread retired, and the energy the CPU cores used for them
// (an estimate from its power model). Instructions per frame barely move between runs of one build at a fixed frame
// rate, so they show a code change's effect; energy per frame is what heats the phone.
//
// Every PG_PERF_INTERVAL seconds (default 10; 1 to 600) the log gets one Perf line: the frames shown in the window and,
// per frame, instructions, cycles, CPU time and energy, plus the same split by thread group, and running totals
// since launch so a script can take the exact difference between two lines. Counters the OS doesn't give read as 0.
#import <Foundation/Foundation.h>
#include <errno.h>
#include <mach/mach.h>
#include <mach/mach_time.h>
#include <math.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <sys/sysctl.h>
#include <time.h>
#include <unistd.h>

extern void pg_log(const char *line);
extern uint64_t PGMetalPresentedFrames(void);

// libproc is in every iOS libSystem, but the iPhone SDK has no header for it. PROC_PIDTHREADCOUNTS (xnu
// bsd/sys/proc_info_private.h) gives one thread's counters for each kind of core (performance, efficiency).
#if __has_include(<libproc.h>)	// the macOS SDK (the Mac app) has it, and its Darwin module brings it in anyway
#include <libproc.h>
#else
int proc_pid_rusage(int pid, int flavor, void *buffer);
int proc_pidinfo(int pid, int flavor, uint64_t arg, void *buffer, int buffersize);
#endif
enum { PG_PROC_PIDTHREADCOUNTS = 34, PG_RUSAGE_INFO_V6 = 6 };
struct pg_threadcounts_data { uint64_t instructions, cycles, user_mach, system_mach, energy_nj; };
struct pg_threadcounts { uint16_t len, reserved0; uint32_t reserved1; struct pg_threadcounts_data counts[4]; };
// rusage_info_v6 as in the macOS SDK's sys/resource.h (the iPhone SDK declares it too, without proc_pid_rusage).
struct pg_rusage_v6 {
  uint8_t uuid[16];
  uint64_t user_time, system_time, pkg_idle_wkups, interrupt_wkups, pageins, wired_size, resident_size, phys_footprint,
    proc_start_abstime, proc_exit_abstime, child_user_time, child_system_time, child_pkg_idle_wkups, child_interrupt_wkups,
    child_pageins, child_elapsed_abstime, diskio_bytesread, diskio_byteswritten, cpu_time_qos_default,
    cpu_time_qos_maintenance, cpu_time_qos_background, cpu_time_qos_utility, cpu_time_qos_legacy,
    cpu_time_qos_user_initiated, cpu_time_qos_user_interactive, billed_system_time, serviced_system_time, logical_writes,
    lifetime_max_phys_footprint, instructions, cycles, billed_energy, serviced_energy, interval_max_phys_footprint,
    runnable_time, flags, user_ptime, system_ptime, pinstructions, pcycles, energy_nj, penergy_nj,
    secure_time_in_system, secure_ptime_in_system, neural_footprint, lifetime_max_neural_footprint,
    interval_max_neural_footprint, reserved[9];
};

typedef struct { uint64_t frames, instructions, cycles, cpuNs, energyNj, pInstructions, pEnergyNj; double wall; } Totals;
enum { MAX_THREADS = 512, MAX_GROUPS = 24, NAME = 48 };
typedef struct { uint64_t id, instructions, cycles, energyNj, ns, pInstructions; } ThreadSeen;
typedef struct { char name[NAME]; uint64_t instructions, cycles, energyNj, ns, pInstructions; } Group;
static ThreadSeen seen[MAX_THREADS], now[MAX_THREADS];
static unsigned seenCount;
static int perfLevels = 2, threadCountsWork = 1;
static mach_timebase_info_data_t timebase;

static double wallSeconds(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return t.tv_sec + t.tv_nsec / 1e9; }
static uint64_t machToNs(uint64_t t) { return timebase.denom ? t * timebase.numer / timebase.denom : t; }

static int processTotals(Totals *t) {
  memset(t, 0, sizeof *t);
  t->wall = wallSeconds();
  t->frames = PGMetalPresentedFrames();
  struct pg_rusage_v6 ru; memset(&ru, 0, sizeof ru);
  if (proc_pid_rusage(getpid(), PG_RUSAGE_INFO_V6, (void *)&ru) != 0) return 0;
  t->instructions = ru.instructions; t->cycles = ru.cycles;
  t->cpuNs = machToNs(ru.user_time + ru.system_time);
  t->energyNj = ru.energy_nj; t->pInstructions = ru.pinstructions; t->pEnergyNj = ru.penergy_nj;
  if (!t->energyNj) {	// older systems: the task's energy from TASK_POWER_INFO_V2 (nanojoules on ARM)
    task_power_info_v2_data_t power; mach_msg_type_number_t count = TASK_POWER_INFO_V2_COUNT;
#if defined(__arm64__)
    if (task_info(mach_task_self(), TASK_POWER_INFO_V2, (task_info_t)&power, &count) == KERN_SUCCESS) t->energyNj = power.task_energy;
#endif
  }
  return 1;
}

static void threadGroupName(thread_t port, char *out) {
  out[0] = 0;
  pthread_t thread = pthread_from_mach_thread_np(port);
  if (thread) pthread_getname_np(thread, out, NAME);
  size_t n = strlen(out);
  while (n && ((out[n - 1] >= '0' && out[n - 1] <= '9') || strchr(" ._-#:", out[n - 1]))) out[--n] = 0;
  if (!n) strcpy(out, "unnamed");
}

// Each thread's counters since the last window, summed by thread group. Returns the number of groups.
static unsigned threadGroups(Group *groups) {
  unsigned groupCount = 0, nowCount = 0;
  thread_act_array_t list; mach_msg_type_number_t count;
  if (!threadCountsWork || task_threads(mach_task_self(), &list, &count) != KERN_SUCCESS) return 0;
  int size = (int)(8 + perfLevels * sizeof(struct pg_threadcounts_data));
  for (mach_msg_type_number_t i = 0; i < count; i++) {
    thread_identifier_info_data_t ident; mach_msg_type_number_t identCount = THREAD_IDENTIFIER_INFO_COUNT;
    struct pg_threadcounts tc;
    if (nowCount < MAX_THREADS && thread_info(list[i], THREAD_IDENTIFIER_INFO, (thread_info_t)&ident, &identCount) == KERN_SUCCESS) {
      memset(&tc, 0, sizeof tc);
      if (proc_pidinfo(getpid(), PG_PROC_PIDTHREADCOUNTS, ident.thread_id, &tc, size) <= 0) {
        if (errno == EPERM || errno == ENOTSUP || errno == EINVAL) threadCountsWork = 0;	// not on this OS: stop asking
      } else {
        ThreadSeen t = {ident.thread_id, 0, 0, 0, 0, tc.counts[0].instructions};	// level 0: the performance cores
        for (int l = 0; l < perfLevels && l < 4; l++) {
          t.instructions += tc.counts[l].instructions; t.cycles += tc.counts[l].cycles; t.energyNj += tc.counts[l].energy_nj;
          t.ns += machToNs(tc.counts[l].user_mach + tc.counts[l].system_mach);
        }
        now[nowCount++] = t;
        ThreadSeen before = {0, 0, 0, 0, 0, 0};	// a thread new since the last window counts everything it did
        for (unsigned j = 0; j < seenCount; j++) if (seen[j].id == t.id) { before = seen[j]; break; }
        char name[NAME]; threadGroupName(list[i], name);
        unsigned g = 0;
        while (g < groupCount && strcmp(groups[g].name, name)) g++;
        if (g == groupCount && groupCount < MAX_GROUPS) { memset(&groups[g], 0, sizeof groups[g]); strcpy(groups[g].name, name); groupCount++; }
        if (g < groupCount) {
          groups[g].instructions += t.instructions >= before.instructions ? t.instructions - before.instructions : 0;
          groups[g].cycles += t.cycles >= before.cycles ? t.cycles - before.cycles : 0;
          groups[g].energyNj += t.energyNj >= before.energyNj ? t.energyNj - before.energyNj : 0;
          groups[g].ns += t.ns >= before.ns ? t.ns - before.ns : 0;
          groups[g].pInstructions += t.pInstructions >= before.pInstructions ? t.pInstructions - before.pInstructions : 0;
        }
      }
    }
    mach_port_deallocate(mach_task_self(), list[i]);
  }
  vm_deallocate(mach_task_self(), (vm_address_t)list, count * sizeof(thread_t));
  memcpy(seen, now, nowCount * sizeof(ThreadSeen)); seenCount = nowCount;
  return groupCount;
}

static const char *thermalName(void) {
  NSProcessInfoThermalState s = [NSProcessInfo processInfo].thermalState;
  return s == NSProcessInfoThermalStateNominal ? "nominal" : s == NSProcessInfoThermalStateFair ? "fair" : s == NSProcessInfoThermalStateSerious ? "serious" : "critical";
}

static void *perfThread(void *unused) {
  (void)unused;
  pthread_setname_np("gta.perf");
  const char *value = getenv("PG_PERF_INTERVAL");
  double every = value && *value ? atof(value) : 10; if (!(every >= 1 && every <= 600)) every = 10;
  mach_timebase_info(&timebase);
  size_t len = sizeof perfLevels; if (sysctlbyname("hw.nperflevels", &perfLevels, &len, NULL, 0) != 0 || perfLevels < 1 || perfLevels > 4) perfLevels = 2;
  Totals start, last, cur;
  if (!processTotals(&start)) { pg_log("Perf: the kernel gives no counters here (proc_pid_rusage failed)."); return NULL; }
  last = start;
  static Group groups[MAX_GROUPS];
  threadGroups(groups);	// the starting point per thread
  char line[2400];
  snprintf(line, sizeof line, "Perf: counting instructions, cycles and energy per frame every %.0f s (GTA-216); %d core kinds, per-thread counters %s.",
           every, perfLevels, threadCountsWork ? "on" : "off");
  pg_log(line);
  for (;;) {
    struct timespec wait = {(time_t)every, (long)((every - floor(every)) * 1e9)};
    nanosleep(&wait, NULL);
    @autoreleasepool {
    if (!processTotals(&cur)) continue;
    unsigned groupCount = threadGroups(groups);
    double seconds = cur.wall - last.wall;
    uint64_t frames = cur.frames - last.frames;
    double f = frames ? (double)frames : 1;
    double instr = (double)(cur.instructions - last.instructions), cycles = (double)(cur.cycles - last.cycles);
    double cpuMs = (cur.cpuNs - last.cpuNs) / 1e6, energyMj = (cur.energyNj - last.energyNj) / 1e6;
    double pShare = instr > 0 ? (cur.pInstructions - last.pInstructions) / instr : 0;
    int used = snprintf(line, sizeof line,
      "Perf: %llu frames in %.2f s (%.1f FPS) · per frame %.2f M instructions, %.2f M cycles (IPC %.2f), CPU %.2f ms, energy %.2f mJ"
      " · %.2f W · P cores %.0f%% of instructions · thermal %s · totals %llu frames, %llu instructions, %llu cycles, %llu us CPU, %llu uJ, %.1f s",
      (unsigned long long)frames, seconds, seconds > 0 ? frames / seconds : 0, instr / f / 1e6, cycles / f / 1e6, cycles > 0 ? instr / cycles : 0,
      cpuMs / f, energyMj / f, seconds > 0 ? energyMj / 1e3 / seconds : 0, pShare * 100, thermalName(),
      (unsigned long long)(cur.frames - start.frames), (unsigned long long)(cur.instructions - start.instructions),
      (unsigned long long)(cur.cycles - start.cycles), (unsigned long long)((cur.cpuNs - start.cpuNs) / 1000),
      (unsigned long long)((cur.energyNj - start.energyNj) / 1000), cur.wall - start.wall);
    // Thread groups by instructions, heaviest first: M instructions / mJ / CPU ms per frame. Under 1% goes into "other".
    for (unsigned a = 0; a < groupCount; a++)
      for (unsigned b = a + 1; b < groupCount; b++)
        if (groups[b].instructions > groups[a].instructions) { Group t = groups[a]; groups[a] = groups[b]; groups[b] = t; }
    if (groupCount && used > 0 && used < (int)sizeof line) used += snprintf(line + used, sizeof line - used, " · threads (M instr/mJ/ms per frame, %% of instr on P cores):");
    Group other = {"other", 0, 0, 0, 0, 0};
    for (unsigned g = 0; g < groupCount; g++) {
      if (instr > 0 && groups[g].instructions < instr / 100) { other.instructions += groups[g].instructions; other.energyNj += groups[g].energyNj; other.ns += groups[g].ns; continue; }
      if (used > 0 && used < (int)sizeof line - 1)
        used += snprintf(line + used, sizeof line - used, " %s %.2f/%.2f/%.2f/%.0f;", groups[g].name, groups[g].instructions / f / 1e6, groups[g].energyNj / f / 1e6, groups[g].ns / f / 1e6,
                         groups[g].instructions ? groups[g].pInstructions * 100.0 / groups[g].instructions : 0);
    }
    if (other.instructions && used > 0 && used < (int)sizeof line - 1)
      snprintf(line + used, sizeof line - used, " other %.2f/%.2f/%.2f;", other.instructions / f / 1e6, other.energyNj / f / 1e6, other.ns / f / 1e6);
    pg_log(line);
    last = cur;
    }
  }
  return NULL;
}

void PGPerfCountersStart(void) {
  static int started;
  if (started) return;
  started = 1;
  const char *value = getenv("PG_PERF_INTERVAL");
  if (value && !strcmp(value, "0")) return;	// PG_PERF_INTERVAL=0: off
  pthread_t thread;
  if (pthread_create(&thread, NULL, perfThread, NULL) == 0) pthread_detach(thread);
}

// The FPS counter's heat and power figures (Settings › Show FPS counter › FPS and heat, or PG_PERF_OVERLAY=1): CPU power
// in watts (the kernel's energy estimate for this app's threads), CPU cores busy, and the share of instructions that ran
// on the performance cores, since the last call. Returns 0 until there are two samples a quarter second apart or more.
int PGPerfOverlaySample(double *watts, double *cores, double *pShare) {
  static Totals last; static int have;
  static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
  pthread_mutex_lock(&lock);
  if (!timebase.denom) mach_timebase_info(&timebase);
  Totals cur; int ok = processTotals(&cur), result = 0;
  if (ok && have && cur.wall - last.wall >= 0.25) {
    double seconds = cur.wall - last.wall;
    *watts = (cur.energyNj - last.energyNj) / 1e9 / seconds;
    *cores = (cur.cpuNs - last.cpuNs) / 1e9 / seconds;
    uint64_t instr = cur.instructions - last.instructions;
    *pShare = instr ? (double)(cur.pInstructions - last.pInstructions) / instr : 0;
    result = 1;
  }
  if (ok && (!have || result)) { last = cur; have = 1; }
  pthread_mutex_unlock(&lock);
  return result;
}
