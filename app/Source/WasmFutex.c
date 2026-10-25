#include "WasmFutex.h"
#include <pthread.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdlib.h>
#include <errno.h>
#include <time.h>
#include <os/clock.h>
#include <os/os_sync_wait_on_address.h>

// The engine's memory.atomic.wait/notify (emscripten futexes: every lock, semaphore and condition of the game's
// threads ends here). GTA-173: it used to be one queue under one mutex for every address in the game, with a
// condition variable per waiter, so all threads' waits and wakes took the same lock (6% of the render thread in
// mutex drops on an iPhone 13 Pro Max) and every wake went through a condition variable (10-12% in cvsignal).
// Now waiters sit in buckets by address, each with its own lock and a count of sleepers, so a notify with nobody
// waiting is one atomic read and threads on different addresses don't meet. A waiter sleeps on its own word with
// the kernel's address wait (iOS 17.4, macOS 14.4); older systems sleep on its condition variable as before.
// PG_FUTEX_OLD=1 keeps the single queue, for A/B runs.

static void *checkedAddress(wasm_rt_shared_memory_t *memory, uint64_t offset,
                            uint32_t width) {
  if (offset % width) wasm_rt_trap(WASM_RT_TRAP_UNALIGNED);
  if (offset > memory->size || memory->size - offset < width)
    wasm_rt_trap(WASM_RT_TRAP_OOB);
  return (uint8_t *)(void *)memory->data + offset;
}

static uint64_t loadValue(void *address, uint32_t width) {
  return width == 4 ? atomic_load((_Atomic uint32_t *)address)
                    : atomic_load((_Atomic uint64_t *)address);
}

// The deadline for a timeout in nanoseconds (negative: none).
static struct timespec deadlineAfter(int64_t timeout) {
  struct timespec deadline;
  clock_gettime(CLOCK_MONOTONIC, &deadline);
  deadline.tv_sec += timeout / 1000000000;
  deadline.tv_nsec += timeout % 1000000000;
  if (deadline.tv_nsec >= 1000000000) { deadline.tv_sec++; deadline.tv_nsec -= 1000000000; }
  return deadline;
}

// Nanoseconds left until the deadline, 0 once it has passed.
static uint64_t nanosecondsLeft(struct timespec deadline) {
  struct timespec now;
  clock_gettime(CLOCK_MONOTONIC, &now);
  int64_t left = (int64_t)(deadline.tv_sec - now.tv_sec) * 1000000000 + (deadline.tv_nsec - now.tv_nsec);
  return left > 0 ? (uint64_t)left : 0;
}

// MARK: The single queue (up to v1.4.7; PG_FUTEX_OLD=1)

typedef struct OldWaiter {
  const void *address;
  bool notified;
  pthread_cond_t condition;
  struct OldWaiter *next;
} OldWaiter;

static pthread_mutex_t queueLock = PTHREAD_MUTEX_INITIALIZER;
static OldWaiter *oldWaiters;

static uint32_t oldWaitFor(void *address, uint64_t expected, int64_t timeout, uint32_t width) {
  pthread_mutex_lock(&queueLock);
  if (loadValue(address, width) != expected) { pthread_mutex_unlock(&queueLock); return 1; }
  if (!timeout) { pthread_mutex_unlock(&queueLock); return 2; }
  OldWaiter waiter = {.address = address, .notified = false, .next = oldWaiters};
  pthread_cond_init(&waiter.condition, NULL);
  oldWaiters = &waiter;
  struct timespec deadline = timeout > 0 ? deadlineAfter(timeout) : (struct timespec){0};
  int result = 0;
  while (!waiter.notified && !result) {
    if (timeout < 0) {
      result = pthread_cond_wait(&waiter.condition, &queueLock);
    } else {
      // Apple's relative wait uses monotonic time, so wall-clock changes cannot
      // extend or shorten an engine sleep. Recalculate after a spurious wakeup.
      uint64_t left = nanosecondsLeft(deadline);
      struct timespec remaining = {(time_t)(left / 1000000000), (long)(left % 1000000000)};
      result = left ? pthread_cond_timedwait_relative_np(&waiter.condition, &queueLock, &remaining) : ETIMEDOUT;
    }
  }
  OldWaiter **link = &oldWaiters;
  while (*link != &waiter) link = &(*link)->next;
  *link = waiter.next;
  bool notified = waiter.notified;
  pthread_mutex_unlock(&queueLock);
  pthread_cond_destroy(&waiter.condition);
  return notified ? 0 : 2;
}

static uint32_t oldNotify(void *address, uint32_t count) {
  uint32_t total = 0;
  pthread_mutex_lock(&queueLock);
  for (OldWaiter *w = oldWaiters; w && total < count; w = w->next) {
    if (w->address == address && !w->notified) {
      w->notified = true;
      pthread_cond_signal(&w->condition);
      total++;
    }
  }
  pthread_mutex_unlock(&queueLock);
  return total;
}

// MARK: Buckets

enum { BUCKETS = 256 };
typedef struct Waiter {
  const void *address;
  _Atomic uint32_t notified;   // the word a waiter sleeps on with the kernel's address wait
  pthread_cond_t condition;    // before iOS 17.4 / macOS 14.4 only
  struct Waiter *next;
} Waiter;
typedef struct {
  pthread_mutex_t lock;
  Waiter *head;
  _Atomic uint32_t sleepers;   // read without the lock by notify: 0 means nobody to wake here
} __attribute__((aligned(128))) Bucket;   // one per cache line pair, so buckets don't share lines
static Bucket buckets[BUCKETS];

static int useOld = -1;      // PG_FUTEX_OLD, read once
static int addressWait = -1; // the kernel's address wait is there (iOS 17.4, macOS 14.4)
static pthread_once_t setupOnce = PTHREAD_ONCE_INIT;
static void setup(void) {
  const char *old = getenv("PG_FUTEX_OLD");
  useOld = old && atoi(old) != 0;
  for (int i = 0; i < BUCKETS; i++) pthread_mutex_init(&buckets[i].lock, NULL);
  addressWait = 0;
  if (__builtin_available(iOS 17.4, macOS 14.4, *)) addressWait = 1;
}

static Bucket *bucketFor(const void *address) {
  uintptr_t a = (uintptr_t)address >> 2;
  return &buckets[(a ^ (a >> 8) ^ (a >> 16)) & (BUCKETS - 1)];
}

static void unlink_(Bucket *bucket, Waiter *waiter) {
  Waiter **link = &bucket->head;
  while (*link && *link != waiter) link = &(*link)->next;
  if (*link) { *link = waiter->next; atomic_fetch_sub_explicit(&bucket->sleepers, 1, memory_order_relaxed); }
}

static uint32_t waitFor(wasm_rt_shared_memory_t *memory, uint64_t offset,
                        uint64_t expected, uint64_t timeoutBits, uint32_t width) {
  pthread_once(&setupOnce, setup);
  void *address = checkedAddress(memory, offset, width);
  int64_t timeout = (int64_t)timeoutBits;
  if (useOld) return oldWaitFor(address, expected, timeout, width);
  Bucket *bucket = bucketFor(address);
  pthread_mutex_lock(&bucket->lock);
  // Counted before the value is read, so a notify that changed the value after this read sees a sleeper and
  // takes the lock (where it finds this waiter) instead of skipping.
  atomic_fetch_add_explicit(&bucket->sleepers, 1, memory_order_seq_cst);
  bool changed = loadValue(address, width) != expected;
  if (changed || !timeout) {
    atomic_fetch_sub_explicit(&bucket->sleepers, 1, memory_order_relaxed);
    pthread_mutex_unlock(&bucket->lock);
    return changed ? 1 : 2;
  }
  Waiter waiter = {.address = address, .notified = 0, .next = bucket->head};
  bucket->head = &waiter;
  struct timespec deadline = timeout > 0 ? deadlineAfter(timeout) : (struct timespec){0};
  if (addressWait) {
    pthread_mutex_unlock(&bucket->lock);
    // Sleep on our own word until a notify sets it (it unlinks us first) or the time is up.
    while (!atomic_load_explicit(&waiter.notified, memory_order_acquire)) {
      int result;
      if (timeout < 0) {
        result = os_sync_wait_on_address(&waiter.notified, 0, 4, OS_SYNC_WAIT_ON_ADDRESS_NONE);
      } else {
        uint64_t left = nanosecondsLeft(deadline);
        if (!left) break;
        result = os_sync_wait_on_address_with_timeout(&waiter.notified, 0, 4, OS_SYNC_WAIT_ON_ADDRESS_NONE,
                                                      OS_CLOCK_MACH_ABSOLUTE_TIME, left);
      }
      if (result < 0 && errno == ETIMEDOUT) break;
    }
    if (atomic_load_explicit(&waiter.notified, memory_order_acquire)) return 0;
    // Timed out; a notify may still be unlinking us: decide under the lock.
    pthread_mutex_lock(&bucket->lock);
    bool notified = atomic_load_explicit(&waiter.notified, memory_order_acquire);
    if (!notified) unlink_(bucket, &waiter);
    pthread_mutex_unlock(&bucket->lock);
    return notified ? 0 : 2;
  }
  pthread_cond_init(&waiter.condition, NULL);
  int result = 0;
  while (!atomic_load_explicit(&waiter.notified, memory_order_relaxed) && !result) {
    if (timeout < 0) {
      result = pthread_cond_wait(&waiter.condition, &bucket->lock);
    } else {
      uint64_t left = nanosecondsLeft(deadline);
      struct timespec remaining = {(time_t)(left / 1000000000), (long)(left % 1000000000)};
      result = left ? pthread_cond_timedwait_relative_np(&waiter.condition, &bucket->lock, &remaining) : ETIMEDOUT;
    }
  }
  bool notified = atomic_load_explicit(&waiter.notified, memory_order_relaxed);
  if (!notified) unlink_(bucket, &waiter);
  pthread_mutex_unlock(&bucket->lock);
  pthread_cond_destroy(&waiter.condition);
  return notified ? 0 : 2;
}

uint32_t pg_atomic_wait32(wasm_rt_shared_memory_t *m, uint64_t a, uint32_t v,
                           uint64_t timeout) { return waitFor(m, a, v, timeout, 4); }
uint32_t pg_atomic_wait64(wasm_rt_shared_memory_t *m, uint64_t a, uint64_t v,
                           uint64_t timeout) { return waitFor(m, a, v, timeout, 8); }

uint32_t pg_atomic_notify(wasm_rt_shared_memory_t *m, uint64_t offset,
                           uint32_t count) {
  pthread_once(&setupOnce, setup);
  void *address = checkedAddress(m, offset, 4);
  if (useOld) return oldNotify(address, count);
  Bucket *bucket = bucketFor(address);
  // The value the notifier changed must be visible before the sleepers are read (the waiter counts itself, then
  // reads the value): the fence also covers a plain store, which ARM may otherwise reorder after this load.
  atomic_thread_fence(memory_order_seq_cst);
  if (!atomic_load_explicit(&bucket->sleepers, memory_order_relaxed)) return 0;
  Waiter *wake[64];
  uint32_t total = 0, woken = 0;
  pthread_mutex_lock(&bucket->lock);
  for (Waiter **link = &bucket->head; *link && total < count;) {
    Waiter *w = *link;
    if (w->address != address) { link = &w->next; continue; }
    *link = w->next;   // unlinked here, so a waiter that times out at the same moment sees it was notified
    atomic_fetch_sub_explicit(&bucket->sleepers, 1, memory_order_relaxed);
    total++;
    if (addressWait) {
      atomic_store_explicit(&w->notified, 1, memory_order_release);
      // Woken after the lock is released, so the woken thread doesn't block on it; past 64 at once, now.
      if (woken < 64) wake[woken++] = w;
      else if (__builtin_available(iOS 17.4, macOS 14.4, *)) os_sync_wake_by_address_any(&w->notified, 4, OS_SYNC_WAKE_BY_ADDRESS_NONE);
    } else {
      atomic_store_explicit(&w->notified, 1, memory_order_relaxed);
      pthread_cond_signal(&w->condition);
    }
  }
  pthread_mutex_unlock(&bucket->lock);
  // A woken waiter can return and reuse its stack as soon as it sees notified = 1; a wake on that stale word
  // reaches nobody, or a later wait of the same thread on the same slot, which re-checks its own word.
  if (__builtin_available(iOS 17.4, macOS 14.4, *))
    for (uint32_t i = 0; i < woken; i++) os_sync_wake_by_address_any(&wake[i]->notified, 4, OS_SYNC_WAKE_BY_ADDRESS_NONE);
  return total;
}
