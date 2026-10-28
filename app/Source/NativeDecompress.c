// The engine's zstd and zlib decompression, done by native code on the engine's buffers (GTA-216).
//
// Every resource the game streams is decompressed by rage::pgStreamerDeviceHandler::ProcessDecompression on the
// streamer threads: a zstd frame (magic 28 B5 2F FD) through ZSTD_decompressStream, anything else through zlib's
// inflate. Both ran as translated wasm. Another team's native port of the game found native decompression in the
// streamer as fast or faster than reading uncompressed data. Scripts/prepare_native_inflate.py puts a hook at the
// start of those engine functions:
//   ZSTD_decompressStream(dctx, output, input): a native ZSTD_DCtx is kept per engine dctx. A frame starts native when
//     the call begins one (both positions 0 and the zstd magic at the input); a frame the wasm decoder started stays
//     with the wasm decoder to its end. Error codes are the same numbers (zstd 1.5, ZSTD_error_maxCode 120).
//   inflate(strm, flush): a native z_stream is kept per engine z_stream, set up by the hooks on inflateInit2_ and
//     inflateReset (same window bits) and freed by inflateEnd. The engine's z_stream has the native layout (wasm64:
//     8-byte pointers and longs); positions, totals, adler and data_type are copied back after each call.
// The wasm functions still run their own init/reset/end, so the wasm decoder is ready whenever a stream stays with it.
// PG_NATIVE_INFLATE=0 keeps the wasm decoders; PG_NATIVE_INFLATE=verify decodes with wasm (its output is used) and
// feeds the same input to the native decoder, comparing a checksum of every frame's output, logged every 30 s.
// Statistics (frames, MB out, time) go to the log every 60 s either way.
#include "HostInternal.h"
#include "engine-functions.h"
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <zlib.h>
// zstd 1.5.6, decoder only (Vendor/zstd/zstddeclib.c, made by its build/single_file_libs/create_single_file_decoder.sh; BSD license).
#undef LIKELY
#undef UNLIKELY
#include "../Vendor/zstd/zstddeclib.c"

static int mode = -1;   // 0 wasm, 1 native, 2 verify
static _Thread_local int insideWasm;
static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
static double now(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return t.tv_sec + t.tv_nsec / 1e9; }
static struct { _Atomic uint64_t zFrames, zBytes, zWasmFrames, dCalls, dBytes, dWasmCalls, mismatches, verified, nativeNs, wasmNs; double lastLog; } stats;

static void setMode(void) {
  if (mode >= 0) return;
  const char *v = getenv("PG_NATIVE_INFLATE");
  mode = v && !strcmp(v, "0") ? 0 : v && !strcmp(v, "verify") ? 2 : 1;
  pg_log(mode == 0 ? "Decompression: wasm zstd and zlib (PG_NATIVE_INFLATE=0)." : mode == 2 ? "Decompression: wasm, verified against native zstd and zlib." :
         "Decompression: native zstd and zlib.");
}

static void maybeLog(void) {
  double t = now();
  if (t - stats.lastLog < (mode == 2 ? 30 : 60)) return;
  pthread_mutex_lock(&lock);
  if (t - stats.lastLog >= (mode == 2 ? 30 : 60)) {
    stats.lastLog = t;
    char line[320];
    snprintf(line, sizeof line, "Decompression: zstd %llu frames native (%.1f MB), %llu with wasm; zlib %llu calls native (%.1f MB), %llu with wasm; "
             "time native %.0f ms, wasm %.0f ms%s%llu checked, %llu different.",
             (unsigned long long)stats.zFrames, stats.zBytes / 1048576.0, (unsigned long long)stats.zWasmFrames,
             (unsigned long long)stats.dCalls, stats.dBytes / 1048576.0, (unsigned long long)stats.dWasmCalls,
             stats.nativeNs / 1e6, stats.wasmNs / 1e6, mode == 2 ? "; verify: " : "; ", (unsigned long long)stats.verified, (unsigned long long)stats.mismatches);
    pg_log(line);
  }
  pthread_mutex_unlock(&lock);
}

static uint64_t r64(const uint8_t *base, uint64_t address) { uint64_t v; memcpy(&v, base + address, 8); return v; }
static uint32_t r32(const uint8_t *base, uint64_t address) { uint32_t v; memcpy(&v, base + address, 4); return v; }
static void w64(uint8_t *base, uint64_t address, uint64_t v) { memcpy(base + address, &v, 8); }
static void w32(uint8_t *base, uint64_t address, uint32_t v) { memcpy(base + address, &v, 4); }
static int inRange(uint64_t size, uint64_t address, uint64_t length) { return address <= size && length <= size - address; }

// ---------- zstd ----------
enum { SLOTS = 32 };
typedef struct { uint64_t dctx; ZSTD_DCtx *native; int owned; uint32_t sum, nativeSum; uint64_t produced, nativeOut; } ZSlot;   // owned: this frame is ours
static ZSlot zslots[SLOTS];

static ZSlot *zslotFor(uint64_t dctx, int create) {
  ZSlot *free = NULL;
  pthread_mutex_lock(&lock);
  for (int i = 0; i < SLOTS; i++) {
    if (zslots[i].dctx == dctx) { pthread_mutex_unlock(&lock); return &zslots[i]; }
    if (!zslots[i].dctx && !free) free = &zslots[i];
  }
  if (create && free) { free->dctx = dctx; free->owned = 0; free->native = ZSTD_createDCtx(); if (!free->native) free->dctx = 0, free = NULL; }
  pthread_mutex_unlock(&lock);
  return create ? free : NULL;
}

static int frameStart(const uint8_t *base, uint64_t size, uint64_t out, uint64_t in) {
  uint64_t src = r64(base, in), srcSize = r64(base, in + 8), inPos = r64(base, in + 16), outPos = r64(base, out + 16);
  return inPos == 0 && outPos == 0 && srcSize >= 4 && inRange(size, src, 4) && r32(base, src) == 0xFD2FB528u;
}

u64 PG_FN_ZSTD_DECOMPRESS_STREAM(w2c_game *, u64, u64, u64);
u32 PG_FN_INFLATE(w2c_game *, u64, u32);

// Answers 1 with *result set when the call was decoded natively, 0 to let the wasm body run.
u32 pg_zstd_stream(w2c_game *instance, u64 dctx, u64 out, u64 in, u64 *result) {
  setMode();
  if (mode == 0 || insideWasm) return 0;
  uint8_t *base = (uint8_t *)(void *)instance->w2c_env_memory->data; uint64_t size = instance->w2c_env_memory->size;
  if (!inRange(size, out, 24) || !inRange(size, in, 24)) return 0;
  uint64_t dst = r64(base, out), dstSize = r64(base, out + 8), dstPos = r64(base, out + 16);
  uint64_t src = r64(base, in), srcSize = r64(base, in + 8), srcPos = r64(base, in + 16);
  if (dstPos > dstSize || srcPos > srcSize || !inRange(size, dst, dstSize) || !inRange(size, src, srcSize)) return 0;
  int start = frameStart(base, size, out, in);
  ZSlot *slot = zslotFor(dctx, start);
  if (start && slot) { ZSTD_DCtx_reset(slot->native, ZSTD_reset_session_only); slot->owned = 1; slot->sum = slot->nativeSum = 0; slot->produced = slot->nativeOut = 0; }
  if (start && !slot) atomic_fetch_add(&stats.zWasmFrames, 1);
  if (!slot || !slot->owned) return 0;
  if (mode == 1) {
    ZSTD_outBuffer o = {base + dst, dstSize, dstPos}; ZSTD_inBuffer i = {base + src, srcSize, srcPos};
    double t0 = now();
    size_t r = ZSTD_decompressStream(slot->native, &o, &i);
    atomic_fetch_add(&stats.nativeNs, (uint64_t)((now() - t0) * 1e9));
    w64(base, out + 16, o.pos); w64(base, in + 16, i.pos);
    atomic_fetch_add(&stats.zBytes, o.pos - dstPos);
    if (r == 0 || ZSTD_isError(r)) { slot->owned = 0; if (!r) atomic_fetch_add(&stats.zFrames, 1); }
    *result = r;
    maybeLog();
    return 1;
  }
  // Verify: the wasm decoder's output is what the game gets; the native one sees the same input and is compared.
  double t0 = now();
  insideWasm = 1;
  uint64_t r = PG_FN_ZSTD_DECOMPRESS_STREAM(instance, dctx, out, in);
  insideWasm = 0;
  atomic_fetch_add(&stats.wasmNs, (uint64_t)((now() - t0) * 1e9));
  base = (uint8_t *)(void *)instance->w2c_env_memory->data;
  uint64_t produced = r64(base, out + 16) - dstPos, consumed = r64(base, in + 16) - srcPos;
  slot->sum = (uint32_t)crc32(slot->sum, base + dst + dstPos, (uInt)produced);
  // The native decoder gets the same input bytes; its output goes to a scratch buffer and into its own checksum.
  static _Thread_local uint8_t *scratch; static _Thread_local size_t scratchSize;
  ZSTD_inBuffer i = {base + src + srcPos, consumed, 0};
  double t1 = now();
  while (i.pos < i.size) {
    if (scratchSize < (1u << 20)) { free(scratch); scratchSize = 1u << 20; scratch = malloc(scratchSize); if (!scratch) { scratchSize = 0; break; } }
    ZSTD_outBuffer o = {scratch, scratchSize, 0};
    size_t nr = ZSTD_decompressStream(slot->native, &o, &i);
    slot->nativeSum = (uint32_t)crc32(slot->nativeSum, scratch, (uInt)o.pos); slot->nativeOut += o.pos;
    if (ZSTD_isError(nr) || (!o.pos && i.pos < i.size && nr == 0)) break;
  }
  atomic_fetch_add(&stats.nativeNs, (uint64_t)((now() - t1) * 1e9));
  slot->produced += produced;
  if (r == 0 || ((r > (uint64_t)-121))) {   // the wasm frame ended (or failed): compare
    atomic_fetch_add(&stats.verified, 1);
    if (r == 0 && (slot->nativeSum != slot->sum || slot->nativeOut != slot->produced)) {
      atomic_fetch_add(&stats.mismatches, 1);
      char line[200]; snprintf(line, sizeof line, "Decompression verify: zstd frame differs (wasm %llu bytes crc %08x, native %llu bytes crc %08x).",
                               (unsigned long long)slot->produced, slot->sum, (unsigned long long)slot->nativeOut, slot->nativeSum);
      pg_log(line);
    }
    atomic_fetch_add(&stats.zFrames, 1); atomic_fetch_add(&stats.zBytes, slot->produced);
    slot->owned = 0;
  }
  *result = r;
  maybeLog();
  return 1;
}

// ---------- zlib ----------
typedef struct { uint64_t strm; z_stream z; int windowBits, ready, owned; uint32_t sum, nativeSum; uint64_t produced, nativeOut; } DSlot;
enum { DSLOTS = 64 };
static DSlot dslots[DSLOTS];

static DSlot *dslotFor(uint64_t strm, int create) {
  DSlot *free = NULL;
  pthread_mutex_lock(&lock);
  for (int i = 0; i < DSLOTS; i++) {
    if (dslots[i].strm == strm) { pthread_mutex_unlock(&lock); return &dslots[i]; }
    if (!dslots[i].strm && !free) free = &dslots[i];
  }
  if (create && free) { memset(free, 0, sizeof *free); free->strm = strm; }
  pthread_mutex_unlock(&lock);
  return create ? free : NULL;
}

// inflateInit2_ (kind 0, with its window bits), inflateReset (1) and inflateEnd (2), before the wasm body runs.
void pg_inflate_lifecycle(w2c_game *instance, u64 strm, u32 kind, u32 windowBits) {
  (void)instance;
  setMode();
  if (mode == 0) return;
  if (kind == 2) {
    DSlot *slot = dslotFor(strm, 0);
    if (slot) { if (slot->ready) inflateEnd(&slot->z); pthread_mutex_lock(&lock); slot->strm = 0; slot->ready = 0; pthread_mutex_unlock(&lock); }
    return;
  }
  DSlot *slot = dslotFor(strm, 1);
  if (!slot) return;   // no room: this stream stays with the wasm decoder
  if (kind == 0) { if (slot->ready) inflateEnd(&slot->z); slot->ready = 0; slot->windowBits = (int32_t)windowBits; }
  if (!slot->ready) { memset(&slot->z, 0, sizeof slot->z); slot->ready = inflateInit2(&slot->z, slot->windowBits) == Z_OK; }
  else inflateReset(&slot->z);
  slot->owned = slot->ready; slot->sum = slot->nativeSum = 0; slot->produced = slot->nativeOut = 0;
}

enum { Z_NEXT_IN = 0, Z_AVAIL_IN = 8, Z_TOTAL_IN = 16, Z_NEXT_OUT = 24, Z_AVAIL_OUT = 32, Z_TOTAL_OUT = 40, Z_MSG = 48, Z_DATA_TYPE = 88, Z_ADLER = 96 };

u32 pg_inflate(w2c_game *instance, u64 strm, u32 flush, u32 *result) {
  setMode();
  if (mode == 0 || insideWasm) return 0;
  uint8_t *base = (uint8_t *)(void *)instance->w2c_env_memory->data; uint64_t size = instance->w2c_env_memory->size;
  if (!inRange(size, strm, 112)) return 0;
  DSlot *slot = dslotFor(strm, 0);
  if (!slot || !slot->owned) { atomic_fetch_add(&stats.dWasmCalls, 1); return 0; }
  uint64_t nextIn = r64(base, strm + Z_NEXT_IN), nextOut = r64(base, strm + Z_NEXT_OUT);
  uint32_t availIn = r32(base, strm + Z_AVAIL_IN), availOut = r32(base, strm + Z_AVAIL_OUT);
  if (!inRange(size, nextIn, availIn) || !inRange(size, nextOut, availOut)) { slot->owned = 0; return 0; }
  if (mode == 1) {
    z_stream *z = &slot->z;
    z->next_in = base + nextIn; z->avail_in = availIn; z->next_out = base + nextOut; z->avail_out = availOut;
    double t0 = now();
    int r = inflate(z, (int)flush);
    atomic_fetch_add(&stats.nativeNs, (uint64_t)((now() - t0) * 1e9));
    uint64_t consumed = availIn - z->avail_in, produced = availOut - z->avail_out;
    w64(base, strm + Z_NEXT_IN, nextIn + consumed); w32(base, strm + Z_AVAIL_IN, z->avail_in);
    w64(base, strm + Z_TOTAL_IN, r64(base, strm + Z_TOTAL_IN) + consumed);
    w64(base, strm + Z_NEXT_OUT, nextOut + produced); w32(base, strm + Z_AVAIL_OUT, z->avail_out);
    w64(base, strm + Z_TOTAL_OUT, r64(base, strm + Z_TOTAL_OUT) + produced);
    w64(base, strm + Z_ADLER, z->adler); w32(base, strm + Z_DATA_TYPE, (uint32_t)z->data_type);
    if (r < 0 && r != Z_BUF_ERROR) w64(base, strm + Z_MSG, 0);
    atomic_fetch_add(&stats.dCalls, 1); atomic_fetch_add(&stats.dBytes, produced);
    *result = (u32)r;
    maybeLog();
    return 1;
  }
  // Verify: wasm decodes for the game; the native stream gets the same input bytes into a scratch buffer.
  double t0 = now();
  insideWasm = 1;
  u32 r = PG_FN_INFLATE(instance, strm, flush);
  insideWasm = 0;
  atomic_fetch_add(&stats.wasmNs, (uint64_t)((now() - t0) * 1e9));
  base = (uint8_t *)(void *)instance->w2c_env_memory->data;
  uint64_t consumed = availIn - r32(base, strm + Z_AVAIL_IN), produced = availOut - r32(base, strm + Z_AVAIL_OUT);
  slot->sum = (uint32_t)crc32(slot->sum, base + nextOut, (uInt)produced); slot->produced += produced;
  static _Thread_local uint8_t *scratch; if (!scratch && !(scratch = malloc(1 << 16))) { *result = r; return 1; }
  slot->z.next_in = base + nextIn; slot->z.avail_in = (uInt)consumed;
  double t1 = now();
  int nr = Z_OK;
  while (slot->z.avail_in > 0 || nr == Z_OK) {
    slot->z.next_out = scratch; slot->z.avail_out = 1 << 16;
    nr = inflate(&slot->z, Z_SYNC_FLUSH);
    uInt n = (uInt)((1 << 16) - slot->z.avail_out);
    slot->nativeSum = (uint32_t)crc32(slot->nativeSum, scratch, n); slot->nativeOut += n;
    if (nr != Z_OK || (!n && slot->z.avail_in == 0)) break;
  }
  atomic_fetch_add(&stats.nativeNs, (uint64_t)((now() - t1) * 1e9));
  atomic_fetch_add(&stats.dCalls, 1); atomic_fetch_add(&stats.dBytes, produced);
  if ((int32_t)r == Z_STREAM_END || (int32_t)r < 0) {
    atomic_fetch_add(&stats.verified, 1);
    if ((int32_t)r == Z_STREAM_END && (slot->nativeSum != slot->sum || slot->nativeOut != slot->produced)) {
      atomic_fetch_add(&stats.mismatches, 1);
      char line[200]; snprintf(line, sizeof line, "Decompression verify: zlib stream differs (wasm %llu bytes crc %08x, native %llu bytes crc %08x).",
                               (unsigned long long)slot->produced, slot->sum, (unsigned long long)slot->nativeOut, slot->nativeSum);
      pg_log(line);
    }
    slot->owned = 0;
  }
  *result = r;
  maybeLog();
  return 1;
}
