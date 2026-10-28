// Native Metal renderer: executes the game's D3D11 command ring directly on Metal.
//
// One renderer thread consumes the ring (wgpu_backend.h protocol of the web build; its JavaScript renderer wgpu_worker.js is the reference
// implementation this replaces). Differences from the WebGPU path, all made possible by talking to Metal directly:
//  - Shaders are precompiled into a metallib; D3D11 slots are Metal argument indices, so there are no bind groups.
//  - Constant buffers are versioned (copy-on-write into a per-frame ring) when they change, not packed per draw.
//  - Raster state, depth-stencil state, cull mode and depth bias are dynamic encoder state, not pipeline state.
//  - Clears become load actions of the next pass that renders to the target (tile memory, no extra pass).
//  - Occlusion queries return real sample counts; readbacks and fences complete from command-buffer handlers.
#include "MRInternal.h"
#include "MetalRenderer.h"
#include "MRFrameReports.h"
#include "BCTextureDecoder.h"
#include "BC1ToASTC.h"
#include "BCToETC.h"
#include "NativeGraphics.h"
#include "NativeFrameRate.h"
#include "NativeMemoryBreakdown.h"
#import <UIKit/UIKit.h>
#if __has_include(<MetalFX/MetalFX.h>) && !TARGET_OS_SIMULATOR		// iPhone SDK only
#import <MetalFX/MetalFX.h>
#define PG_METALFX 1
#endif
#include <TargetConditionals.h>
#include <pthread.h>
#include <mutex>
#include <unordered_map>
#include <unordered_set>
#include <array>
#include <sys/mman.h>
#include <functional>
#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstdarg>

namespace mr {

// Texture memory, for the periodic report: what the GPU holds, what the game thinks BC textures
// cost (their compressed size, which its streaming budget counts), and CPU copies of BC blocks.
static struct TextureStats {
	std::atomic<int64_t> gpuBytes{0}, bcGameBytes{0}, bcGpuBytes{0}, shadowBytes{0};
	std::atomic<int64_t> kindBytes[8][2];		// [BC kind][sRGB]: GPU bytes, to see where decoded memory goes
	std::atomic<uint64_t> createFailures{0}, decodeFailures{0}, bcReadbacks{0}, bcCopies{0};
	std::atomic<int64_t> halfSize{0};		// Lite: textures on the GPU without their largest level
	std::atomic<int64_t> quarterSize{0};		// of those, without their two largest (PG_LITE_BIG_MIP_SKIP)
	std::atomic<uint64_t> missingLevel{0};	// Lite: copies or readbacks that needed a dropped level
	std::atomic<uint64_t> convertMicros{0}, converts{0};	// BC to ASTC or pixels on the CPU (GTA-162: what converting ahead would save)
	std::atomic<uint64_t> etcMicros{0}, etcToASTC{0}, etcAlphaLost{0}, etcMismatch{0};	// BC as ETC2/EAC (GTA-217)
	std::atomic<int64_t> etcPendingBytes{0};		// BC1 levels waiting for the GPU's first use (malloc)
} gTextureStats;
// What the textures hold on the GPU (an estimate in the simulator). On an iPhone that memory counts
// against the app's limit; the simulator's GPU is the Mac's, so the simulated limit adds it (EngineHost.c).
extern "C" uint64_t PGGPUTextureBytes(void) { int64_t v = gTextureStats.gpuBytes.load(); return v > 0 ? (uint64_t)v : 0; }
// GPU time per frame for the Health line (GTA-116): FPS alone can't tell a busy GPU from a busy CPU.
static std::atomic<uint64_t> gGPUMicros{0}, gGPUFrames{0};
extern "C" double PGGPUFrameMilliseconds(void) {
	uint64_t frames = gGPUFrames.exchange(0), micros = gGPUMicros.exchange(0);
	return frames ? micros / 1000.0 / frames : 0;
}
// GPU buffers, for the report: how many, what they hold, and what iOS charges (whole 16 KB pages each).
static struct BufferStats { std::atomic<int64_t> count{0}, bytes{0}, pages{0}, meshCount{0}, meshBytes{0}, cbCount{0}, cbBytes{0}, cbWritten{0}, inSlab{0}; } gBufferStats;
// The memory breakdown (GTA-217): GPU bytes and counts by texture kind, and bytes by pixel format.
static std::atomic<int64_t> gTexKindBytes[PGTexKinds], gTexKindCount[PGTexKinds], gFormatBytes[1024];
static std::atomic<int64_t> gSlabTotal{0};
static std::atomic<uint64_t> gDrawablePixels{0};
static id<MTLDevice> gReportDevice;		// set once in setup()
static std::atomic<uint32_t> gPipelinesMade{0};
// For the app memory line (GTA-174): Metal buffer memory, slabs and own buffers, rounded to pages.
extern "C" uint64_t PGGPUBufferBytes(void) { int64_t v = gBufferStats.pages.load(); return v > 0 ? (uint64_t)v : 0; }
// The per-frame rings of shared memory (constant buffer versions, upload staging): chunks only grow (GTA-174).
static std::atomic<int64_t> gFrameRingBytes{0};
extern "C" uint64_t PGFrameRingBytes(void) { int64_t v = gFrameRingBytes.load(); return v > 0 ? (uint64_t)v : 0; }
// CPU copies of constant buffers (malloc), kept to rebuild each version.
extern "C" uint64_t PGConstantCopyBytes(void) { int64_t v = gBufferStats.cbBytes.load(); return v > 0 ? (uint64_t)v : 0; }
static uint64_t pageRound(uint64_t n) { return (n + 16383) & ~16383ull; }
// Small mesh buffers share 4 MB slabs (GTA-34). iOS charges every MTLBuffer whole 16 KB pages, and most of
// the game's ~8k vertex and index buffers hold a few KB: about 100 MB went to rounding at a 2.3 GB limit.
// A freed range is reused only once the GPU has finished every command buffer that could still read it.
// PG_BUFFER_SLABS=0 gives every buffer its own MTLBuffer again.
struct Slab { id<MTLBuffer> buf; std::map<uint32_t, uint32_t> free; };		// offset -> length
static std::vector<Slab> gSlabs;
struct SlabFree { uint64_t serial; int32_t slab; uint32_t off, len; };
static std::vector<SlabFree> gSlabPending;
static const uint32_t kSlabBytes = 4 << 20, kSlabAlign = 256;
// Meshes up to this size share 4 MB slabs; bigger ones get their own buffer, rounded up to whole 16 KB pages. 256 KB
// was worse than 64 KB on a 4 GB city drive (288 MB of pages for 172 MB of meshes, against 255 for 195): bigger pieces
// left more half-empty slabs (GTA-174). PG_SLAB_LARGEST_KB sets it for A/B runs.
static uint32_t slabLargest() {
	static uint32_t largest = 0;
	if (!largest) { const char *v = getenv("PG_SLAB_LARGEST_KB"); long kb = v ? atol(v) : 64; largest = (uint32_t)(kb >= 16 && kb <= 1024 ? kb : 64) << 10; }
	return largest;
}
static uint64_t currentSerial();
extern "C" {
uint32_t PGMeshRelease(uint32_t oid, const uint8_t *contents, uint32_t bytes, uint64_t *firstPage, uint32_t *pageCount, uint32_t *pageOffset);
void PGMeshForget(uint64_t firstPage, uint32_t pageCount, int gone);
void PGMeshReleaseStats(uint64_t *released, uint64_t *byFault, uint64_t *byForget, uint64_t *byTouch, uint64_t *mismatched, uint64_t *page,
                        uint64_t *orphanedPages, uint64_t *orphanWritten, uint64_t *orphanRead);
int PGMeshReleaseOn(void);
void PGMeshGone(uint32_t oid);
void PGMeshForgetMesh(uint32_t oid, uint64_t firstPage, uint32_t pageCount, int gone);
void PGMeshShareStats(uint64_t *pages, uint64_t *kept, uint64_t *held);
void PGMeshVerifyStats(uint64_t *checked, uint64_t *bad, uint64_t *badPage, uint64_t *badOffset);
uint64_t PGMeshRemapFallbacks(void);
const char *PGMeshVerifyDetail(void);
void PGMeshDeadStats(int64_t *bytes, uint64_t *freed, uint64_t *reusable);
void PGMeshFaultWaitStats(uint64_t *waits, uint64_t *maxUs, uint64_t *slow, uint64_t *late);
}
Buffer::~Buffer() {
	if (meshPages) PGMeshForgetMesh(oid, meshPage, meshPages, 1);
	if (bind & (1 | 2)) PGMeshGone(oid);
	if (bind & 4) { gBufferStats.cbCount--; gBufferStats.cbBytes -= (int64_t)shadow.size(); if (version) gBufferStats.cbWritten--; }		// BIND_CB
	if (slab >= 0) gSlabPending.push_back({currentSerial(), slab, (uint32_t)base, (bytes + kSlabAlign - 1) & ~(kSlabAlign - 1)});
	if (!counted) return;
	gBufferStats.count--; gBufferStats.bytes -= (int64_t)counted; if (slab < 0) gBufferStats.pages -= (int64_t)pageRound(counted); else gBufferStats.inSlab -= (int64_t)counted;
	if (bind & (1 | 2)) { gBufferStats.meshCount--; gBufferStats.meshBytes -= (int64_t)counted; }
}
Texture::~Texture() {
	gTextureStats.gpuBytes -= (int64_t)gpuBytes;
	if (skip) gTextureStats.halfSize--;
	if (skip > 1) gTextureStats.quarterSize--;
	if (bcKind) { gTextureStats.bcGameBytes -= (int64_t)bcGameBytes; gTextureStats.bcGpuBytes -= (int64_t)gpuBytes; gTextureStats.kindBytes[bcKind][bcSrgb] -= (int64_t)gpuBytes; }
	for (auto &it : compressedShadow) gTextureStats.shadowBytes -= (int64_t)it.second.size();
	for (auto &l : etcPending) gTextureStats.etcPendingBytes -= (int64_t)l.data.size();
	if (tex) { gTexKindBytes[memKind] -= (int64_t)gpuBytes; gTexKindCount[memKind]--; gFormatBytes[format & 1023] -= (int64_t)gpuBytes; }
	delete depthProxy;
}

static const uint32_t RING_DATA = 64;
enum Op : uint32_t {
	NOP = 0, WRAP = 1, INIT = 2, CREATE_TEXTURE = 3, DESTROY_OBJECT = 4, CLEAR_RT = 5, CLEAR_DS = 6, PRESENT = 7, FENCE = 8,
	SCREENSHOT = 9, LOG = 10, CREATE_BUFFER = 11, UPLOAD_BUFFER = 12, UPLOAD_TEXTURE = 13, CREATE_SHADER = 14, CREATE_LAYOUT = 15,
	CREATE_STATE = 16, CREATE_SRV = 17, SET_SHADER = 18, SET_INPUT_LAYOUT = 19, SET_TOPOLOGY = 20, SET_VERTEX_BUFFERS = 21,
	SET_INDEX_BUFFER = 22, SET_CBUFFERS = 23, SET_SRVS = 24, SET_SAMPLERS = 25, SET_RENDER_TARGETS = 26, SET_BLEND = 27,
	SET_DEPTH_STENCIL = 28, SET_RASTER = 29, SET_VIEWPORTS = 30, SET_SCISSORS = 31, DRAW = 32, CLEAR_STATE = 33,
	COPY_REGION = 34, COPY_RESOURCE = 35, RESOLVE = 36, CREATE_UAV = 37, SET_UAVS = 38, DISPATCH = 39, CLEAR_UAV = 40,
	GENERATE_MIPS = 41, READBACK = 42, COPY_COUNTER = 43, CREATE_QUERY = 44, BEGIN_QUERY = 45, END_QUERY = 46,
	UPLOAD_BUFFER_NO_OVERWRITE = 47,
};
static const uint32_t BIND_VB = 1, BIND_IB = 2, BIND_CB = 4, BIND_SRV = 8, BIND_RT = 0x20, BIND_DS = 0x40, BIND_UAV = 0x80;
static const int FRAME_SLOTS = 3;
static const uint32_t OCCLUSION_SLOTS = 16384;

static inline uint64_t fnv(uint64_t h, uint64_t v) { h ^= v; h *= 1099511628211ull; return h; }
static double nowMs() { return CACurrentMediaTime() * 1000.0; }

// ---- object table: ids come from one counter and are never reused; pages of pointers are freed when empty ------------
class ObjectTable {
	static const uint32_t PAGE = 16384;
	struct Page { Object *slot[PAGE] = {}; uint32_t live = 0; };
	std::vector<Page *> pages;
public:
	Object *get(uint32_t id) const {
		uint32_t pi = id / PAGE;
		if (pi >= pages.size() || !pages[pi]) return nullptr;
		return pages[pi]->slot[id % PAGE];
	}
	void set(uint32_t id, Object *o) {
		uint32_t pi = id / PAGE;
		if (pi >= pages.size()) pages.resize(pi + 1, nullptr);
		if (!pages[pi]) pages[pi] = new Page();
		Object *&s = pages[pi]->slot[id % PAGE];
		if (s) { delete s; pages[pi]->live--; }
		s = o;
		if (o) pages[pi]->live++;
	}
	void erase(uint32_t id) {
		uint32_t pi = id / PAGE;
		if (pi >= pages.size() || !pages[pi]) return;
		Object *&s = pages[pi]->slot[id % PAGE];
		if (!s) return;
		delete s; s = nullptr;
		if (--pages[pi]->live == 0 && pi + 1 < pages.size()) { delete pages[pi]; pages[pi] = nullptr; }
	}
	template <class T> T *as(uint32_t id, ObjKind k) const { Object *o = id ? get(id) : nullptr; return o && o->kind == k ? static_cast<T *>(o) : nullptr; }
};

// ---- per-frame ring of shared memory (constant buffer versions, staging for uploads) -------------------------------------
struct FrameRing {
	static const NSUInteger CHUNK = 8 << 20;
	std::vector<id<MTLBuffer>> chunks, big;
	size_t chunk = 0;
	NSUInteger off = 0;
	uint64_t lastSerial = 0;
	void reset() { chunk = 0; off = 0; big.clear(); }
};

struct Alloc { id<MTLBuffer> buf; NSUInteger off; uint8_t *ptr; };

struct Pipe {
	std::atomic<bool> ready{false};
	bool failed = false;
	id<MTLRenderPipelineState> state = nil;
	struct VbReq { uint32_t slot, stride, last; bool instance; };
	std::vector<VbReq> vbReq;
	bool zeroStream = false;
	std::string label;
};
struct ComputePipe { id<MTLComputePipelineState> state = nil; bool failed = false; };

struct PassInfo {
	MTLPixelFormat colors[8] = {};
	uint32_t colorCount = 0;
	MTLPixelFormat depth = MTLPixelFormatInvalid;
	uint32_t samples = 1, width = 1, height = 1;
	bool roDepth = false, roStencil = false;
	uint64_t key = 0;
	uint32_t packedMask = 0;		// colour targets in a packed float format (RG11B10, RGB9E5): GTA-77 statistics
};

struct PendingClear { uint32_t tex, mip, slice; bool depth; float color[4]; uint32_t flags; float z; uint32_t stencil; };

struct StageCache {
	__unsafe_unretained id<MTLBuffer> buffers[31];
	NSUInteger offsets[31];
	__unsafe_unretained id<MTLTexture> textures[96];
	__unsafe_unretained id<MTLSamplerState> samplers[16];
	void reset() { memset((void *)buffers, 0, sizeof buffers); memset(offsets, 0xff, sizeof offsets); memset((void *)textures, 0, sizeof textures); memset((void *)samplers, 0, sizeof samplers); }
};

struct PendingQuery { Query *q; uint32_t seq; std::vector<uint32_t> slots; uint32_t type; uint64_t addr; };

// Pictures presented since launch, for the Perf line's work per frame (NativePerfCounters.m, GTA-216).
static std::atomic<uint64_t> presentedFrames{0};

struct Renderer {
	uint8_t *mem = nullptr;
	uint64_t memSize = 0, ring = 0;
	uint32_t ringSize = 0;
	id<MTLDevice> device;
	id<MTLCommandQueue> queue;
	CAMetalLayer *layer;
	ObjectTable objs;
	bool float32Filtering = false, borderColors = false;

	// command buffers
	id<MTLCommandBuffer> cmd;
	uint64_t serial = 1;
	std::atomic<uint64_t> completed{0};
	dispatch_semaphore_t completion;
	std::vector<std::function<void()>> onComplete;
	id<MTLRenderCommandEncoder> pass;
	id<MTLComputeCommandEncoder> compute;
	id<MTLBlitCommandEncoder> blit;
	StageCache cache[3];
	uint32_t drawsInCmd = 0;

	// frames
	FrameRing frames[FRAME_SLOTS];
	uint64_t frame = 0;

	// D3D11 state
	uint32_t shader[3] = {0, 0, 0}, layout = 0, topo = 4;
	struct VB { uint32_t buf, stride, offset; } vb[16] = {};
	struct IB { uint32_t buf, fmt, offset; } ib = {};
	struct CB { uint32_t buf, first, num; } cb[3][16] = {};
	uint32_t srv[3][128] = {}, smp[3][16] = {}, uav[3][8] = {};
	struct RTB { uint32_t tex, mip, slice, fmt; } rt[8] = {};
	struct DSB { uint32_t tex, mip, slice, fmt, flags; } ds = {};
	uint32_t blendId = 0, blendMask = 0xffffffff, dssId = 0, dssRef = 0, rsId = 0;
	float blendFactor[4] = {1, 1, 1, 1};
	float viewport[6] = {};
	bool hasViewport = false, hasScissor = false;
	uint32_t scissor[4] = {};
	bool rtDirty = true, pipeDirty = true;

	// pass
	PassInfo passInfo;
	std::vector<PendingClear> clears;
	Pipe *lastPipe = nullptr;
	uint32_t appliedRs = UINT32_MAX, appliedRef = UINT32_MAX;
	__unsafe_unretained id<MTLDepthStencilState> appliedDss = nil;
	float appliedBlend[4] = {-1, -1, -1, -1};
	float appliedViewport[6] = {};
	bool viewportApplied = false;
	MTLScissorRect appliedScissor = {UINT32_MAX, 0, 0, 0};
	__unsafe_unretained id<MTLRenderPipelineState> appliedPipe = nil;

	// pipelines
	std::unordered_map<uint64_t, Pipe *> pipes;
	std::unordered_map<uint32_t, ComputePipe> computePipes;
	std::unordered_map<uint64_t, id<MTLDepthStencilState>> dssCache;
	std::atomic<uint32_t> pipesPending{0};
	uint32_t pipesMade = 0;
	std::mutex pipeLock;

	// queries
	id<MTLBuffer> visibility;
	uint32_t visNext = 0;
	Query *activeOcclusion = nullptr;
	int passSlot = -1;
	std::vector<PendingQuery> pendingQueries;

	// dummies and helpers
	id<MTLBuffer> zeroBuffer;
	std::unordered_map<uint32_t, id<MTLTexture>> dummyTextures;
	id<MTLSamplerState> dummySampler, dummyCompare;
	id<MTLRenderPipelineState> blitPipe, capturePipe;
	id<MTLDepthStencilState> noDepth;

	// game shader objects by program (the first object created for each), for program substitutions
	std::unordered_map<ShaderInfo *, uint32_t> shaderObjects;
	bool lastMaskSwap = false;

	// statistics
	uint64_t commitReasons[4] = {}, skipReasons[8] = {};
	uint64_t draws = 0, skipped = 0, pendingSkips = 0, clamped = 0, presents = 0, commits = 0;
	double pipeWaitMs = 0;		// time spent this frame waiting for pipelines to finish compiling
	double statT = 0, busyMs = 0, lastCommitMs = 0, lastPresentMs = 0;
	// stutter: presents more than 50 ms apart since the last report, and the longest gap
	double statPresentAt = 0, worstFrameMs = 0; uint64_t longFrames = 0;
	FrameWork work;
	uint64_t statDraws = 0, statPresents = 0, statSkips = 0, statPending = 0, statCommits = 0;
	PGFrameRateWindow fpsWindow;
	std::atomic<double> fps{0}, lastPresent{0};
	bool firstFrame = false, worldSent = false;
	double worldSince = 0, worldClean = 0;
	uint64_t drawsAtPresent = 0, pendingAtPresent = 0;
	std::mutex captureLock;
	std::string captureName;
	std::string burstName; int burstLeft = 0, burstIndex = 0;		// "burst": the next frames as PNGs (GTA-176 flicker test)
};

static Renderer *R;

// ---- debug trace (simulator only, env PG_MR_TRACE=<seconds after the world is shown>) ---------------------------------
// Writes every command of one frame (draws with their shaders, targets, states and textures; clears, copies) to
// Documents/mr-trace.txt and saves the render targets the frame drew into as PNGs (NativeFrames/trace-rt<id>).
#if TARGET_OS_SIMULATOR
#define MR_TRACE 1
static struct { int state = 0; double at = -1; FILE *f = nullptr; uint64_t n = 0; std::vector<uint32_t> rts; id<MTLRenderPipelineState> alphaPipe, dsPipe; int snaps = 0; } T;
static void tracef(const char *format, ...) __attribute__((format(printf, 1, 2)));
static void tracef(const char *format, ...) {
	if (T.state != 2 || !T.f) return;
	va_list a; va_start(a, format); vfprintf(T.f, format, a); va_end(a);
	fputc('\n', T.f);
}
#else
#define MR_TRACE 0
static inline void tracef(const char *, ...) {}
#endif

// ---- command buffers and encoders -----------------------------------------------------------------------------------
static id<MTLCommandBuffer> commandBuffer() {
	if (!R->cmd) {
		R->cmd = [R->queue commandBuffer];
		R->drawsInCmd = 0;
	}
	return R->cmd;
}
static void endEncoders() {
	if (R->pass) {
		if (R->passSlot >= 0) R->passSlot = -1;
		[R->pass endEncoding]; R->pass = nil; R->rtDirty = true;
	}
	if (R->compute) { [R->compute endEncoding]; R->compute = nil; }
	if (R->blit) { [R->blit endEncoding]; R->blit = nil; }
}
static id<MTLBlitCommandEncoder> blitEncoder() {
	if (R->blit) return R->blit;
	endEncoders();
	R->blit = [commandBuffer() blitCommandEncoder];
	return R->blit;
}
static void storeResult(uint64_t addr, uint64_t value, uint32_t seq);
// Occlusion answers (GTA-176: lights flicker at night): how many, how many said "hidden", and how often the same query
// changed between visible and hidden from one answer to the next. In a still scene, many flips mean unstable answers.
static std::atomic<uint64_t> gOcclusionResults{0}, gOcclusionZero{0}, gOcclusionFlips{0};
static uint64_t gQueriesEnded, gQueriesNoPass, gQueriesNoDraw, gQueryDraws;		// render thread only
extern "C" uint64_t PGOcclusionLate(void), PGOcclusionReads(void);	// EngineHost.c: the game's reads, and the late ones
static std::mutex gOcclusionLock;
static std::unordered_map<uint64_t, bool> gOcclusionLast;		// query address -> last answer was visible
static void noteOcclusion(uint64_t addr, uint64_t samples) {
	gOcclusionResults++; if (!samples) gOcclusionZero++;
	std::lock_guard<std::mutex> lock(gOcclusionLock);
	auto it = gOcclusionLast.find(addr);
	if (it == gOcclusionLast.end()) { if (gOcclusionLast.size() < 65536) gOcclusionLast.emplace(addr, samples != 0); }
	else { if (it->second != (samples != 0)) gOcclusionFlips++; it->second = samples != 0; }
}
enum CommitReason { CPresent, CFence, CReadback, CIdle, CReasons };
static const char *kCommitNames[CReasons] = {"present", "fence", "readback", "idle queries"};
// Settings › Graphics › Frame rate 40 (GTA-154): how long each picture stays up at least (0: no pacing here).
static std::atomic<double> gPresentInterval{0};
// Pictures that reached the screen (GTA-200), from the drawables' on-glass times: how many, how many never showed,
// and the gaps between them, which follow the screen's refresh rate (8.3 ms at 120 Hz, 12.5 ms at 80, 16.7 ms at 60).
static std::mutex gShownLock;
static std::vector<float> gShownGaps;		// milliseconds, since the last PGMetalRendererShownStats
static double gShownLast = 0, gShownSince = 0;
static uint32_t gShown = 0, gNotShown = 0;
[[maybe_unused]] static void noteShown(double at) {
	std::lock_guard<std::mutex> lock(gShownLock);
	if (at <= 0) { gNotShown++; return; }
	if (gShownSince <= 0) gShownSince = at;
	if (gShownLast > 0 && at > gShownLast && gShownGaps.size() < 8192) gShownGaps.push_back(float((at - gShownLast) * 1000));
	gShownLast = at; gShown++;
}
extern "C" void PGMetalRendererShownStats(double *perSecond, double *fastGapMs, double *medianGapMs, uint32_t *notShown) {
	std::vector<float> gaps;
	double since, last; uint32_t shown, dropped;
	{
		std::lock_guard<std::mutex> lock(gShownLock);
		gaps.swap(gShownGaps); since = gShownSince; last = gShownLast; shown = gShown; dropped = gNotShown;
		gShownSince = gShownLast; gShown = 0; gNotShown = 0;
	}
	*perSecond = last > since && shown > 1 ? (shown - 1) / (last - since) : 0;
	*fastGapMs = *medianGapMs = 0;
	if (!gaps.empty()) {
		std::sort(gaps.begin(), gaps.end());
		*fastGapMs = gaps[gaps.size() / 20];		// the fastest 5%: about one refresh of the screen when frames come quickly
		*medianGapMs = gaps[gaps.size() / 2];
	}
	*notShown = dropped;
}
static void commit(CommitReason reason, id<CAMetalDrawable> drawable = nil) {
	endEncoders();
	if (!R->pendingQueries.empty()) {
		std::vector<PendingQuery> list;
		list.swap(R->pendingQueries);
		id<MTLBuffer> vis = R->visibility;
		R->onComplete.push_back([list, vis]() {
			const uint64_t *v = (const uint64_t *)vis.contents;
			for (const PendingQuery &p : list) {
				uint64_t result;
				if (p.type == 1 || p.type == 5) {
					result = 0; for (uint32_t s : p.slots) result += v[s];
					static int visible = -1;		// PG_OQ_VISIBLE=1: every occlusion query says "visible" (GTA-176 test only)
					if (visible < 0) visible = getenv("PG_OQ_VISIBLE") && atoi(getenv("PG_OQ_VISIBLE"));
					if (visible) result = 1 << 20;
					noteOcclusion(p.addr, result);
				}
				else if (p.type == 2) result = (uint64_t)(CACurrentMediaTime() * 1e9);
				else result = 1;
				storeResult(p.addr, result, p.seq);
			}
		});
		if (R->visNext > OCCLUSION_SLOTS - 1024 && !R->activeOcclusion) R->visNext = 0;
	}
	id<MTLCommandBuffer> cb = commandBuffer();
	// 40 FPS (Settings › Graphics › Frame rate): each picture stays up 1/40 s, every third refresh of a 120 Hz screen.
	if (drawable) {
		double interval = gPresentInterval.load();
#if !TARGET_OS_SIMULATOR		// the simulator's Metal has no on-glass times
		[drawable addPresentedHandler:^(id<MTLDrawable> shown) { noteShown(shown.presentedTime); }];
#endif
		if (interval <= 0) [cb presentDrawable:drawable];
#if TARGET_OS_SIMULATOR
		// The simulator's Metal has no minimum-duration present: the same pacing from present times, for tests.
		else { static double next; double now = CACurrentMediaTime(); next = next > now && next - now < 1 ? next + interval : now + interval; [cb presentDrawable:drawable atTime:next - interval]; }
#else
		else [cb presentDrawable:drawable afterMinimumDuration:interval];
#endif
	}
	uint64_t serial = R->serial++;
	auto *callbacks = new std::vector<std::function<void()>>();
	callbacks->swap(R->onComplete);
	Renderer *r = R;
	[cb addCompletedHandler:^(id<MTLCommandBuffer> done) {
		if (done.status == MTLCommandBufferStatusError) logOnce("cmderr" + std::to_string(done.error.code), "Metal renderer: command buffer failed: %s", done.error.localizedDescription.UTF8String);
		double gpu = done.GPUEndTime - done.GPUStartTime;
		if (gpu > 0 && gpu < 1) { gGPUMicros += (uint64_t)(gpu * 1e6); gGPUFrames++; }
		for (auto &f : *callbacks) f();
		delete callbacks;
		uint64_t prev = r->completed.load();
		while (prev < serial && !r->completed.compare_exchange_weak(prev, serial)) {}
		dispatch_semaphore_signal(r->completion);
	}];
	double c0 = nowMs();
	[cb commit];
	R->work.submit += nowMs() - c0;
	R->cmd = nil;
	R->lastCommitMs = nowMs();
	R->commits++;
	R->commitReasons[reason]++;
}
static void waitSerial(uint64_t s) {
	while (R->completed.load() < s) dispatch_semaphore_wait(R->completion, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_MSEC));
}
static inline bool inFlight(uint64_t lastUse) { return lastUse > R->completed.load(std::memory_order_relaxed); }
static uint64_t currentSerial() { return R->serial; }
static void slabRelease(int32_t slab, uint32_t off, uint32_t len) {
	auto &free = gSlabs[slab].free;
	auto next = free.lower_bound(off);
	if (next != free.end() && off + len == next->first) { len += next->second; next = free.erase(next); }
	bool merged = false;
	if (next != free.begin()) {
		auto prev = std::prev(next);
		if (prev->first + prev->second == off) { prev->second += len; merged = true; }
	}
	if (!merged) free[off] = len;
	// A slab with nothing left in it goes back to iOS (GTA-174): slabs used to stay for good, so meshes that
	// streamed out left half-empty 4 MB slabs behind (a 4 GB city drive: 195 MB of meshes in 255 MB of pages).
	// Its slot stays, empty, for the next slab; every piece freed here is past the GPU already (slabReclaim).
	static int keep = -1;
	if (keep < 0) keep = getenv("PG_SLAB_KEEP") && atoi(getenv("PG_SLAB_KEEP"));		// 1: as before, for A/B runs
	if (!keep && free.size() == 1 && free.begin()->first == 0 && free.begin()->second == kSlabBytes) {
		gSlabs[slab].buf = nil; free.clear();
		gBufferStats.pages -= kSlabBytes; gSlabTotal -= kSlabBytes;
	}
}
static void slabReclaim() {
	if (gSlabPending.empty()) return;
	size_t keep = 0;
	for (auto &f : gSlabPending) { if (inFlight(f.serial)) gSlabPending[keep++] = f; else slabRelease(f.slab, f.off, f.len); }
	gSlabPending.resize(keep);
}
static bool slabAllocate(uint32_t bytes, int32_t &slab, uint32_t &off) {
	uint32_t len = (bytes + kSlabAlign - 1) & ~(kSlabAlign - 1);
	slabReclaim();
	for (size_t i = 0; i < gSlabs.size(); i++)
		for (auto it = gSlabs[i].free.begin(); gSlabs[i].buf && it != gSlabs[i].free.end(); ++it) if (it->second >= len) {
			off = it->first; uint32_t rest = it->second - len;
			gSlabs[i].free.erase(it);
			if (rest) gSlabs[i].free[off + len] = rest;
			slab = (int32_t)i; return true;
		}
	id<MTLBuffer> buf = [R->device newBufferWithLength:kSlabBytes options:MTLResourceStorageModeShared];
	if (!buf) return false;
	size_t empty = 0;
	while (empty < gSlabs.size() && gSlabs[empty].buf) empty++;		// a slot a released slab left
	if (empty == gSlabs.size()) gSlabs.push_back({});
	gSlabs[empty] = {buf, {{len, kSlabBytes - len}}};
	gBufferStats.pages += kSlabBytes; gSlabTotal += kSlabBytes;
	slab = (int32_t)empty; off = 0;
	return true;
}

// ---- frame ring ---------------------------------------------------------------------------------------------------------
static Alloc frameAlloc(NSUInteger size, NSUInteger align = 256) {
	FrameRing &f = R->frames[R->frame % FRAME_SLOTS];
	size = std::max<NSUInteger>(size, 4);
	if (size > FrameRing::CHUNK / 4) {
		id<MTLBuffer> b = [R->device newBufferWithLength:size options:MTLResourceStorageModeShared];
		f.big.push_back(b);
		return {b, 0, (uint8_t *)b.contents};
	}
	f.off = (f.off + align - 1) & ~(align - 1);
	if (f.chunk >= f.chunks.size() || f.off + size > FrameRing::CHUNK) {
		if (f.chunk < f.chunks.size()) { f.chunk++; f.off = 0; }
		if (f.chunk >= f.chunks.size()) { f.chunks.push_back([R->device newBufferWithLength:FrameRing::CHUNK options:MTLResourceStorageModeShared]); gFrameRingBytes += FrameRing::CHUNK; }
	}
	id<MTLBuffer> b = f.chunks[f.chunk];
	NSUInteger off = f.off;
	f.off += size;
	return {b, off, (uint8_t *)b.contents + off};
}

// ---- GTA-77: triangle strips as indexed triangle lists, NaN/infinity clamp on packed float targets ---------------------
// Another D3D11-on-Metal port found two faults on an iPhone 13 Pro (A15 GPU) that drew garbage streaks: degenerate
// triangle strips with a vertex behind the camera (fixed by drawing those draws as indexed triangle lists, rewritten on
// the CPU), and NaN or infinity written into R11G11B10 and RGB9E5 targets (filtered and clamped). Players report gravel
// roads drawn as large rectangles (GTA-77, iPhone 14) and ground turning see-through (GTA-208); neither showed in the
// simulator or on a Mac. Both fixes are on by default; PG_STRIP_LISTS_OLD=1 draws strips as strips again and
// PG_NAN_CLAMP_OLD=1 writes what the shader computed. PG_NAN_CLAMP=all (test) cleans every float target.
static std::atomic<int> gStripLists{1};		// 1: triangle strips go to the GPU as indexed triangle lists
static std::atomic<int> gNanClamp{1};		// 0 off, 1 RG11B10/RGB9E5 targets, 2 every float target, 3 = 1 + float targets up to 256x256
static int gLaunchStripLists = 1, gLaunchNanClamp = 1;		// what the environment chose; test shots go back to it
static struct FixStats {
	uint64_t stripDraws = 0, stripIndexed = 0, stripInstanced = 0, stripIndirect = 0, asList = 0, keptStrips = 0;
	uint64_t stripTris = 0, listTris = 0, degenerate = 0, restarts = 0, converts = 0, dynamicConverts = 0, hits = 0;
	double convertMs = 0;
	uint64_t passes = 0, packedPasses = 0, packedDraws = 0, packedDispatches = 0, cleanedPasses = 0;
} gFix;
// PG_MR_DRAW_STATS=1 (test): strip draws and draws into packed float targets by program, every 10 s report.
struct LabelStat { uint64_t strips = 0, stripIndexed = 0, stripVerts = 0, stripInst = 0, packed = 0; };
static int gDrawStats = -1;
static int gUninitTrace = -1;		// PG_MR_UNINIT=1: log textures read before anything wrote them, and draws skipped for compiles
static int gPipeWaitSmall = -1;		// PG_PIPE_WAIT_SMALL=1: draws into float32 or small targets wait for their pipeline
static std::unordered_map<std::string, LabelStat> gLabelStats;
static std::unordered_map<std::string, uint64_t> gPackedTargets;		// "format WxH" of packed float targets drawn into

// The largest finite value a target format keeps, as float bits (0: the format isn't cleaned in this mode). 64512 is
// R11G11B10's blue maximum (red and green go to 65024, RGB9E5 to 65408): one bound for every channel.
static uint32_t nanClampBits(MTLPixelFormat f, int mode, uint64_t texels) {
	if (!mode) return 0;
	if (f == MTLPixelFormatRG11B10Float || f == MTLPixelFormatRGB9E5Float) return 0x477C0000u;
	if (mode == 1 || (mode == 3 && texels > 256 * 256)) return 0;		// 3: also float targets up to 256x256 (simulations, exposure)
	if (f == MTLPixelFormatRGBA16Float || f == MTLPixelFormatRG16Float || f == MTLPixelFormatR16Float) return 0x477FE000u;		// 65504
	if (f == MTLPixelFormatRGBA32Float || f == MTLPixelFormatRG32Float || f == MTLPixelFormatR32Float) return 0x7F7FFFFFu;		// FLT_MAX
	return 0;
}
static bool packedFloat(MTLPixelFormat f) { return f == MTLPixelFormatRG11B10Float || f == MTLPixelFormatRGB9E5Float; }

// Converted index lists, cached per index buffer range until the buffer is written again. An index buffer whose
// ranges keep changing (rewritten between draws) is converted at every draw into the frame ring instead.
struct StripList { id<MTLBuffer> buf = nil; NSUInteger off = 0; int32_t slab = -1; uint32_t bytes = 0, indices = 0, version = 0, rebuilds = 0; uint64_t lastFrame = 0; };
static std::unordered_map<uint64_t, StripList> gStripCache;
static std::unordered_map<uint32_t, std::vector<uint64_t>> gStripCacheKeys;		// index buffer -> its cache keys
static std::unordered_set<uint32_t> gStripDynamic;
static int64_t gStripCacheBytes = 0;
static id<MTLBuffer> gStripPattern[2];		// non-indexed strips: 16- and 32-bit lists 0,1,2, 1,3,2, 2,3,4, 3,5,4, ...
static uint32_t gStripPatternTris[2];
static void stripFree(StripList &e) {
	if (e.slab >= 0) gSlabPending.push_back({R->serial, e.slab, (uint32_t)e.off, (e.bytes + kSlabAlign - 1) & ~(kSlabAlign - 1)});
	else if (e.buf) gBufferStats.pages -= (int64_t)pageRound(e.bytes);
	gStripCacheBytes -= e.bytes;
	e.buf = nil; e.slab = -1; e.off = 0; e.bytes = 0;
}
static bool stripAlloc(StripList &e, uint32_t bytes) {
	int32_t slab; uint32_t off;
	if (bytes <= slabLargest() && slabAllocate(bytes, slab, off)) { e.buf = gSlabs[slab].buf; e.off = off; e.slab = slab; }
	else {
		e.buf = [R->device newBufferWithLength:bytes options:MTLResourceStorageModeShared]; e.off = 0; e.slab = -1;
		if (!e.buf) return false;
		gBufferStats.pages += (int64_t)pageRound(bytes);
	}
	e.bytes = bytes; gStripCacheBytes += bytes;
	return true;
}
static void stripForgetBuffer(uint32_t oid) {
	gStripDynamic.erase(oid);
	auto it = gStripCacheKeys.find(oid);
	if (it == gStripCacheKeys.end()) return;
	for (uint64_t key : it->second) { auto e = gStripCache.find(key); if (e != gStripCache.end()) { stripFree(e->second); gStripCache.erase(e); } }
	gStripCacheKeys.erase(it);
}
// Every few seconds: lists not drawn for 20 s go (an index buffer the engine fills ring-style leaves many behind).
static void stripEvict() {
	if (R->frame % 256 || gStripCache.empty()) return;
	for (auto it = gStripCache.begin(); it != gStripCache.end();) {
		if (R->frame - it->second.lastFrame > 600) { stripFree(it->second); it = gStripCache.erase(it); } else ++it;
	}
	for (auto it = gStripCacheKeys.begin(); it != gStripCacheKeys.end();) {
		auto &keys = it->second;
		keys.erase(std::remove_if(keys.begin(), keys.end(), [](uint64_t k) { return !gStripCache.count(k); }), keys.end());
		if (keys.empty()) it = gStripCacheKeys.erase(it); else ++it;
	}
}
// D3D11 strip order: triangle k is (v[k], v[k+1], v[k+2]) for even k and (v[k], v[k+2], v[k+1]) for odd k, so every
// triangle keeps its winding and its first (provoking) vertex. The cut index (all ones) ends a strip; the next vertex
// starts a new one with an even triangle. Triangles that repeat an index have no area and are left out.
template <class T> static uint32_t stripToList(const T *in, uint32_t count, T *out, uint64_t &degenerate, uint64_t &restarts) {
	const T cut = (T)~(T)0;
	uint32_t n = 0, run = 0;
	T a = 0, b = 0;
	for (uint32_t i = 0; i < count; i++) {
		const T c = in[i];
		if (c == cut) { if (run) restarts++; run = 0; continue; }
		if (run >= 2) {
			if (a == b || b == c || a == c) degenerate++;
			else if (!((run - 2) & 1)) { out[n++] = a; out[n++] = b; out[n++] = c; }
			else { out[n++] = a; out[n++] = c; out[n++] = b; }
		}
		a = b; b = c; run++;
	}
	return n;
}
static bool stripPattern(int wide, uint32_t tris) {
	if (gStripPatternTris[wide] >= tris) return true;
	if (tris > (16u << 20)) return false;
	uint32_t cap = std::max<uint32_t>(4096, std::max(tris, gStripPatternTris[wide] * 2));
	if (!wide) cap = std::min<uint32_t>(cap, 0xfffd);		// 16-bit: vertices 0..65534 (0xffff stays unused)
	if (cap < tris) return false;
	const uint32_t isz = wide ? 4 : 2;
	id<MTLBuffer> b = [R->device newBufferWithLength:(NSUInteger)cap * 3 * isz options:MTLResourceStorageModeShared];
	if (!b) return false;
	for (uint32_t k = 0; k < cap; k++) {
		const uint32_t v[3] = {k, k & 1 ? k + 2 : k + 1, k & 1 ? k + 1 : k + 2};
		for (int j = 0; j < 3; j++) { if (wide) ((uint32_t *)b.contents)[k * 3 + j] = v[j]; else ((uint16_t *)b.contents)[k * 3 + j] = (uint16_t)v[j]; }
	}
	if (gStripPattern[wide]) gBufferStats.pages -= (int64_t)pageRound(gStripPattern[wide].length);
	gBufferStats.pages += (int64_t)pageRound(b.length);
	gStripPattern[wide] = b; gStripPatternTris[wide] = cap;
	return true;
}

// ---- engine memory ------------------------------------------------------------------------------------------------------
static void storeResult(uint64_t addr, uint64_t value, uint32_t seq) {
	if (!addr || addr + 16 > R->memSize) return;
	auto *w = (std::atomic<uint32_t> *)(R->mem + addr);
	w[2].store((uint32_t)value); w[3].store((uint32_t)(value >> 32));
	w[0].store(seq);
	PGGraphicsNotify(addr);
}
static void storeWord(uint64_t addr, uint32_t value) {
	if (!addr || addr + 4 > R->memSize || (addr & 3)) return;
	((std::atomic<uint32_t> *)(R->mem + addr))->store(value);
	PGGraphicsNotify(addr);
}

// ---- dummies ------------------------------------------------------------------------------------------------------------
static id<MTLTexture> dummyTexture(ResKind kind, TexDim dim, SampleKind sample) {
	uint32_t key = (uint32_t)kind | ((uint32_t)dim << 8) | ((uint32_t)sample << 16);
	auto it = R->dummyTextures.find(key);
	if (it != R->dummyTextures.end()) return it->second;
	MTLTextureDescriptor *d = [MTLTextureDescriptor new];
	bool depth = kind == RDepth || kind == RDepthMS, ms = kind == RTextureMS || kind == RDepthMS;
	d.pixelFormat = depth ? MTLPixelFormatDepth32Float : sample == SUint ? MTLPixelFormatRGBA8Uint : sample == SSint ? MTLPixelFormatRGBA8Sint : MTLPixelFormatRGBA8Unorm;
	if (kind == RStorageTex) d.pixelFormat = MTLPixelFormatRGBA32Float;
	d.width = d.height = 1;
	d.usage = MTLTextureUsageShaderRead | (kind == RStorageTex ? MTLTextureUsageShaderWrite : 0) | (depth || ms ? MTLTextureUsageRenderTarget : 0);
	d.storageMode = MTLStorageModePrivate;
	switch (dim) {
	case D1: d.textureType = MTLTextureType1D; break;
	case D2Array: d.textureType = MTLTextureType2DArray; d.arrayLength = 1; break;
	case D3: d.textureType = MTLTextureType3D; break;
	case DCube: d.textureType = MTLTextureTypeCube; break;
	case DCubeArray: d.textureType = MTLTextureTypeCubeArray; d.arrayLength = 1; break;
	default: d.textureType = ms ? MTLTextureType2DMultisample : MTLTextureType2D; if (ms) d.sampleCount = 4;
	}
	id<MTLTexture> t = [R->device newTextureWithDescriptor:d];
	R->dummyTextures[key] = t;
	return t;
}

// ---- samplers -----------------------------------------------------------------------------------------------------------
static float wordFloat(uint32_t w) { float f; memcpy(&f, &w, 4); return f; }
static MTLSamplerAddressMode addressMode(uint32_t m, const float *border) {
	switch (m) {
	case 2: return MTLSamplerAddressModeMirrorRepeat;
	case 3: return MTLSamplerAddressModeClampToEdge;
	case 4: return R->borderColors ? MTLSamplerAddressModeClampToBorderColor : MTLSamplerAddressModeClampToEdge;
	case 5: return MTLSamplerAddressModeMirrorClampToEdge;
	default: return MTLSamplerAddressModeRepeat;
	}
}
static void makeSamplers(State *s) {
	const uint32_t *w = s->words.data();
	if (s->words.size() < 13) return;
	uint32_t filter = w[0];
	bool aniso = (filter & 0x7f) == 0x55;
	float border[4] = {wordFloat(w[7]), wordFloat(w[8]), wordFloat(w[9]), wordFloat(w[10])};
	MTLSamplerDescriptor *d = [MTLSamplerDescriptor new];
	d.sAddressMode = addressMode(w[1], border); d.tAddressMode = addressMode(w[2], border); d.rAddressMode = addressMode(w[3], border);
	if (border[3] == 0) d.borderColor = MTLSamplerBorderColorTransparentBlack;
	else if (border[0] >= 0.5f) d.borderColor = MTLSamplerBorderColorOpaqueWhite;
	else d.borderColor = MTLSamplerBorderColorOpaqueBlack;
	d.magFilter = (filter >> 2) & 1 ? MTLSamplerMinMagFilterLinear : MTLSamplerMinMagFilterNearest;
	d.minFilter = (filter >> 4) & 1 ? MTLSamplerMinMagFilterLinear : MTLSamplerMinMagFilterNearest;
	d.mipFilter = filter & 1 ? MTLSamplerMipFilterLinear : MTLSamplerMipFilterNearest;
	float minLod = std::max(0.0f, wordFloat(w[11])), maxLod = std::min(1000.0f, std::max(0.0f, wordFloat(w[12])));
	d.lodMinClamp = minLod; d.lodMaxClamp = std::max(minLod, maxLod);
	if (filter & 0x80) d.compareFunction = w[6] >= 1 && w[6] <= 8 ? (MTLCompareFunction)(w[6] - 1) : MTLCompareFunctionAlways;
	if (aniso) { d.magFilter = d.minFilter = MTLSamplerMinMagFilterLinear; d.mipFilter = MTLSamplerMipFilterLinear; d.maxAnisotropy = std::max(1u, std::min(16u, w[5])); }
	s->sampler = [R->device newSamplerStateWithDescriptor:d];
	d.magFilter = d.minFilter = MTLSamplerMinMagFilterNearest; d.maxAnisotropy = 1;
	s->samplerNearest = [R->device newSamplerStateWithDescriptor:d];
}

// ---- textures -----------------------------------------------------------------------------------------------------------
static Texture *texture(uint32_t id) { return R->objs.as<Texture>(id, OTexture); }
static Buffer *buffer(uint32_t id) { return R->objs.as<Buffer>(id, OBuffer); }
static View *view(uint32_t id, ObjKind k) { return R->objs.as<View>(id, k); }
static State *state(uint32_t id) { return R->objs.as<State>(id, OState); }

static uint32_t bcBlockBytes(int kind);
static void encodeClear(const PendingClear &c);
static uint64_t gLiteBigSkip = 0;
static uint64_t gZeroInitTargets = 0;		// GTA-77: render targets cleared to zeros when created		// PG_LITE_BIG_MIP_SKIP (texels), 0 = off
static void createTexture(const uint32_t *p) {
	uint32_t id = p[0], dim = p[1], w = std::max(1u, p[2]), h = std::max(1u, p[3]), d = std::max(1u, p[4]), mips = std::max(1u, p[5]);
	uint32_t arraySize = std::max(1u, p[6]), dxgi = p[7], bind = p[8], samples = std::max(1u, p[9]);
	FormatInfo m = mapFormat(dxgi, bind);
	auto *t = new Texture(id);
	t->format = m.format; t->dxgi = dxgi; t->bind = bind; t->dim = dim; t->width = w; t->height = dim == 1 ? 1 : h;
	t->depthOrLayers = dim == 3 ? d : arraySize; t->mips = mips; t->samples = samples;
	t->isDepth = isDepthFormat(m.format); t->hasStencil = hasStencil(m.format);
	t->bcKind = m.bc; t->bcSrgb = m.srgb; t->bcNative = m.bcNative; t->astc = m.astc; t->etc = m.etc;
	t->floatNoFilter = isFloat32(m.format) && !R->float32Filtering;
	// Lite: only plain sampled 2D textures the game loads (shader resource only, so no render targets,
	// staging or dynamic textures, which have one mip) with mips to spare. Small ones (lookup tables,
	// and the ones the game may read back, which keep CPU block copies) stay whole.
	const bool skippable = bind == BIND_SRV && dim == 2 && samples == 1 && mips >= 2 && !t->isDepth && !m.a8 && !isFloat32(m.format) &&
	    (w >> 1) >= 4 && (h >> 1) >= 4;
	if (skippable && ((gSkipTopMip && (uint64_t)w * h > 128 * 128) || (gSkipBigTopMip && (uint64_t)w * h >= gSkipBigTopMip)))
		t->skip = 1;
	// Lite: the biggest textures lose a second level too (PG_LITE_BIG_MIP_SKIP=N: at least N×N texels).
	if (t->skip && gSkipTopMip && gLiteBigSkip && (uint64_t)w * h >= gLiteBigSkip && mips >= 3 && (w >> 2) >= 4 && (h >> 2) >= 4) {
		t->skip = 2;
	}
	MTLTextureDescriptor *desc = [MTLTextureDescriptor new];
	desc.pixelFormat = m.format;
	desc.width = std::max(1u, w >> t->skip); desc.height = std::max(1u, t->height >> t->skip);
	desc.mipmapLevelCount = mips - t->skip;
	if (dim == 3) { desc.textureType = MTLTextureType3D; desc.depth = d; }
	else if (dim == 1) { desc.textureType = arraySize > 1 ? MTLTextureType1DArray : MTLTextureType1D; desc.arrayLength = arraySize; }
	else if (samples > 1) { desc.textureType = arraySize > 1 ? MTLTextureType2DMultisampleArray : MTLTextureType2DMultisample; desc.sampleCount = samples; desc.arrayLength = arraySize; desc.mipmapLevelCount = 1; }
	else { desc.textureType = arraySize > 1 ? MTLTextureType2DArray : MTLTextureType2D; desc.arrayLength = arraySize; }
	MTLTextureUsage usage = MTLTextureUsageShaderRead;
	if (bind & (BIND_RT | BIND_DS)) usage |= MTLTextureUsageRenderTarget;
	if (bind & BIND_UAV) usage |= MTLTextureUsageShaderWrite | MTLTextureUsageRenderTarget;
	if (m.alt != MTLPixelFormatInvalid || t->hasStencil) usage |= MTLTextureUsagePixelFormatView;
	desc.usage = usage;
	bool gpuWritten = (bind & (BIND_RT | BIND_DS | BIND_UAV)) || samples > 1 || t->isDepth;
	t->shared = !gpuWritten;
	desc.storageMode = t->shared ? MTLStorageModeShared : MTLStorageModePrivate;
	// A8 is stored as R8 and read as (0,0,0,R). Metal forbids swizzles on render targets, so those get
	// the swizzle on the views shaders sample instead.
	if (m.a8 && !(usage & (MTLTextureUsageRenderTarget | MTLTextureUsageShaderWrite)))
		desc.swizzle = MTLTextureSwizzleChannelsMake(MTLTextureSwizzleZero, MTLTextureSwizzleZero, MTLTextureSwizzleZero, MTLTextureSwizzleRed);
	else if (m.a8) { t->alphaView = true; desc.usage |= MTLTextureUsagePixelFormatView; }
	t->tex = [R->device newTextureWithDescriptor:desc];
	if (t->etc && t->bcKind == 1) t->etcDesc = desc;		// until its first upload says whether it has transparent texels
#if MR_TRACE
	if (m.a8 && (bind & (BIND_RT | BIND_UAV))) logOnce("a8rt" + std::to_string(w) + "x" + std::to_string(h), "Metal renderer [trace]: A8 render target %u %ux%u bind %#x", id, w, h, bind);
#endif
	if (!t->tex) { gTextureStats.createFailures++; logOnce("tex" + std::to_string(dxgi) + "x" + std::to_string(bind), "Metal renderer: texture %ux%u dxgi %u bind %#x could not be created", w, h, dxgi, bind); }
	else {
		t->gpuBytes = t->tex.allocatedSize;
		if (t->bcKind) {
			uint32_t bb = m.bc == 1 || m.bc == 4 ? 8 : 16;
			for (uint32_t mip = 0; mip < mips; mip++) {
				uint64_t mw = std::max(1u, w >> mip), mh = std::max(1u, t->height >> mip), md = dim == 3 ? std::max(1u, d >> mip) : arraySize;
				t->bcGameBytes += (mw + 3) / 4 * ((mh + 3) / 4) * bb * md;
			}
		}
		if (!t->gpuBytes) {		// the simulator reports no allocation sizes: estimate (the levels the GPU holds)
			uint64_t blocks = 0;
			if (t->bcKind) for (uint32_t mip = t->skip; mip < mips; mip++) {
				uint64_t mw = std::max(1u, w >> mip), mh = std::max(1u, t->height >> mip), md = dim == 3 ? std::max(1u, d >> mip) : arraySize;
				blocks += (mw + 3) / 4 * ((mh + 3) / 4) * bcBlockBytes(m.bc) * md;
			}
			if (t->bcNative || t->etc) t->gpuBytes = blocks;
			else if (t->astc) t->gpuBytes = t->bcKind == 1 ? blocks * 2 : blocks;		// 16-byte blocks for BC1's 8, BC3's 16
			else for (uint32_t mip = t->skip; mip < mips; mip++)
				t->gpuBytes += (uint64_t)std::max(1u, w >> mip) * std::max(1u, t->height >> mip) * (dim == 3 ? std::max(1u, d >> mip) : arraySize) * samples * bytesPerTexel(m.format);
		}
		gTextureStats.gpuBytes += (int64_t)t->gpuBytes;
		t->memKind = t->bcKind ? (t->bcNative ? PGTexBCNative : t->astc ? PGTexBCASTC : t->etc ? PGTexBCETC : PGTexBCDecoded) : gpuWritten ? PGTexTarget : !bind ? PGTexStaging : PGTexPlain;
		gTexKindBytes[t->memKind] += (int64_t)t->gpuBytes; gTexKindCount[t->memKind]++; gFormatBytes[t->format & 1023] += (int64_t)t->gpuBytes;
		// The game's big render targets, once per size and format (GTA-217: targets take 160 MB at 934x432).
		if (t->memKind == PGTexTarget && t->gpuBytes >= (2u << 20))
			logOnce("bigrt" + std::to_string(w) + "x" + std::to_string(h) + "-" + std::to_string(dxgi) + "-" + std::to_string(arraySize) + "-" + std::to_string(mips),
			        "Metal renderer: render target %ux%u x%u, %u levels, DXGI %u, bind %#x, %u samples: %.1f MB", w, h, dim == 3 ? d : arraySize, mips, dxgi, bind, samples, t->gpuBytes / 1048576.0);
		if (t->skip) gTextureStats.halfSize++;
		if (t->skip > 1) gTextureStats.quarterSize++;
		if (t->bcKind && getenv("PG_TRACE_BC_FORMATS")) logOnce("bcdxgi" + std::to_string(dxgi), "Metal renderer [trace]: BC texture format DXGI %u (first %ux%u)", dxgi, w, h);
		if (t->bcKind) { gTextureStats.bcGameBytes += (int64_t)t->bcGameBytes; gTextureStats.bcGpuBytes += (int64_t)t->gpuBytes; gTextureStats.kindBytes[t->bcKind][t->bcSrgb] += (int64_t)t->gpuBytes; }
	}
	R->objs.set(id, t);
#if MR_TRACE
	// Test (simulator, GTA-77): PG_TEST_RT_FILL=nan fills every new 32-bit float render target with NaN, as memory a
	// phone's GPU hands out unwritten may hold; the simulator's starts as zeros.
	static const char *rtFill = getenv("PG_TEST_RT_FILL");
	if (rtFill && t->tex && (bind & BIND_RT) && !t->isDepth && isFloat32(t->format) && t->samples == 1 && dim == 2) {
		for (uint32_t mip = 0; mip < t->tex.mipmapLevelCount; mip++) for (uint32_t s = 0; s < t->tex.arrayLength; s++) {
			PendingClear c{id, mip, s, false, {NAN, NAN, NAN, NAN}, 0, 0, 0};
			encodeClear(c);
		}
		logOnce("rtfill", "Metal renderer [test]: new 32-bit float render targets start as NaN (PG_TEST_RT_FILL)");
		t->written = false;
	}
#endif
	// GTA-77: a new render target or storage texture starts as zeros, as D3D11 drivers hand out new GPU memory. Metal
	// promises nothing: on a phone it can hold whatever the memory held before. The game's water simulation (256x256
	// R32F feedback maps) reads its last state before writing it; when its passes were skipped while their pipelines
	// compiled (the first launch after an install or update), it read that leftover memory, a NaN stayed in the
	// simulation for the whole session, and part of the water (by the Alamo Sea trailer park) was never drawn.
	// PG_RT_ZERO_INIT_OLD=1 leaves new targets as Metal gives them.
	static int zeroOld = -1;
	if (zeroOld < 0) zeroOld = getenv("PG_RT_ZERO_INIT_OLD") && strcmp(getenv("PG_RT_ZERO_INIT_OLD"), "0");
	if (!zeroOld && t->tex && (bind & (BIND_RT | BIND_DS | BIND_UAV)) && dim != 1) {
		if (!gZeroInitTargets) logf("Metal renderer: new render targets start as zeros, as on D3D11 (GTA-77; PG_RT_ZERO_INIT_OLD=1 leaves them as Metal gives them).");
		const bool cube = t->tex.textureType == MTLTextureTypeCube || t->tex.textureType == MTLTextureTypeCubeArray;
		for (uint32_t mip = 0; mip < t->tex.mipmapLevelCount; mip++) {
			const uint32_t slices = t->dim == 3 ? std::max<uint32_t>(1, (uint32_t)t->tex.depth >> mip) : (uint32_t)t->tex.arrayLength * (cube ? 6 : 1);
			for (uint32_t s = 0; s < slices; s++) {
				PendingClear c{id, mip, s, t->isDepth, {0, 0, 0, 0}, t->isDepth ? 3u : 0u, 0.0f, 0};
				encodeClear(c);
			}
		}
		gZeroInitTargets++;
	}
}

static void mipExtent(Texture *t, uint32_t mip, uint32_t &w, uint32_t &h, uint32_t &d) {
	w = std::max(1u, t->width >> mip); h = std::max(1u, t->height >> mip);
	d = t->dim == 3 ? std::max(1u, t->depthOrLayers >> mip) : 1;
}
static uint32_t bcBlockBytes(int kind) { return kind == 1 || kind == 4 ? 8 : 16; }

// The game reads a few BC textures back to the CPU, all small ones in testing (16x128, 64x64), and
// a CPU copy of every BC texture cost as much RAM as the game's whole BC budget. Only textures up
// to 128x128 kept their original blocks: still 60-80 MB of malloc in a city drive (GTA-217). The readbacks seen since
// are all BC1 of 4,096 texels or fewer (128x32, 64x32, 4x4 in the benchmark; 16x128 and 64x64 before), so only those
// could keep a copy. PG_BC_COPY_TEXELS sets the limit; a readback that finds no copy says so once. v1.5.2 keeps the old
// 16,384 (128x128) by default: 4,096 saves about 50 MB but wasn't cleared by the lab's teleport stress in time (2026-10-27).
static uint64_t maxShadowTexels() {
	static uint64_t texels = 0;
	if (!texels) { const char *v = getenv("PG_BC_COPY_TEXELS"); long n = v ? atol(v) : 16384; texels = (uint64_t)(n >= 16 && n <= (1 << 24) ? n : 16384); }
	return texels;
}
static void storeCompressed(Texture *t, uint32_t mip, uint32_t slice, uint32_t x, uint32_t y, uint32_t z, uint32_t w, uint32_t h, uint32_t d,
                            uint32_t bpr, uint32_t rpi, const uint8_t *data, size_t size) {
	if ((uint64_t)t->width * t->height > maxShadowTexels()) return;
	uint32_t mw, mh, md; mipExtent(t, mip, mw, mh, md);
	uint32_t bb = bcBlockBytes(t->bcKind), pitch = (mw + 3) / 4 * bb, rows = (mh + 3) / 4, count = (w + 3) / 4 * bb, uploadRows = (h + 3) / 4;
	size_t sourceSlice = (size_t)bpr * (rpi ? rpi : uploadRows);
	bool three = t->dim == 3;
	for (uint32_t layer = 0; layer < d; layer++) {
		uint64_t key = ((uint64_t)mip << 32) | (three ? z + layer : slice + layer);
		auto &shadow = t->compressedShadow[key];
		if (shadow.empty()) { shadow.resize((size_t)pitch * rows); gTextureStats.shadowBytes += (int64_t)shadow.size(); }
		for (uint32_t row = 0; row < uploadRows; row++) {
			size_t from = layer * sourceSlice + (size_t)row * bpr, to = (size_t)(y / 4 + row) * pitch + (x / 4) * bb;
			if (from + count > size || to + count > shadow.size()) break;
			memcpy(shadow.data() + to, data + from, count);
		}
	}
}

// Block-compressed data to the GPU texture's level: bpr bytes per block row, imageBytes per 3D slice or array layer.
static void uploadBlocks(Texture *t, uint32_t level, uint32_t slice, uint32_t x, uint32_t y, uint32_t z, uint32_t w, uint32_t h, uint32_t d,
                         uint32_t bpr, uint32_t imageBytes, const uint8_t *data) {
	bool three = t->dim == 3;
	MTLRegion region = MTLRegionMake3D(x, y, three ? z : 0, w, h, three ? d : 1);
	if (t->shared && !inFlight(t->lastUse)) {
		if (three || d == 1) [t->tex replaceRegion:region mipmapLevel:level slice:three ? 0 : slice withBytes:data bytesPerRow:bpr bytesPerImage:three ? imageBytes : 0];
		else for (uint32_t l = 0; l < d; l++) [t->tex replaceRegion:MTLRegionMake2D(x, y, w, h) mipmapLevel:level slice:slice + l withBytes:data + (size_t)l * imageBytes bytesPerRow:bpr bytesPerImage:0];
	} else {
		Alloc a = frameAlloc((size_t)imageBytes * d, 16);
		memcpy(a.ptr, data, (size_t)imageBytes * d);
		id<MTLBlitCommandEncoder> b = blitEncoder();
		if (three) [b copyFromBuffer:a.buf sourceOffset:a.off sourceBytesPerRow:bpr sourceBytesPerImage:imageBytes sourceSize:MTLSizeMake(w, h, d) toTexture:t->tex destinationSlice:0 destinationLevel:level destinationOrigin:MTLOriginMake(x, y, z)];
		else for (uint32_t l = 0; l < d; l++) [b copyFromBuffer:a.buf sourceOffset:a.off + (NSUInteger)l * imageBytes sourceBytesPerRow:bpr sourceBytesPerImage:imageBytes sourceSize:MTLSizeMake(w, h, 1) toTexture:t->tex destinationSlice:slice + l destinationLevel:level destinationOrigin:MTLOriginMake(x, y, 0)];
		t->lastUse = R->serial;
	}
}

static void uploadTextureInner(const uint32_t *p);
static void uploadTexture(const uint32_t *p) {
	double t0 = nowMs();
	uploadTextureInner(p);
	R->work.uploads += nowMs() - t0;
	R->work.uploadBytes += p[11];
}
// Trace (PG_TRACE_HELD, GTA-148): does the engine keep its own copy of what it uploaded? Every texture level and
// vertex or index buffer upload of at least 16 KB is remembered by its first and last 64 bytes, and twice in a run
// the engine's resident memory is searched for them (8-byte steps; the renderer stops for some seconds). Found
// means the same bytes sit in engine memory as well as on the GPU: memory the game holds twice.
extern "C" const uint8_t *pg_engine_memory(uint64_t *size);
struct Held { uint64_t head[8], tail[8]; uint32_t size; bool texture, found; };
static int gTraceHeld = -1;
static std::unordered_map<uint32_t, std::vector<Held>> gHeld;		// by object; renderer thread only
static void rememberHeld(uint32_t oid, const uint8_t *data, uint32_t size, bool texture) {
	if (gTraceHeld < 0) gTraceHeld = getenv("PG_TRACE_HELD") != NULL;
	if (!gTraceHeld || size < 16384) return;
	Held h; memcpy(h.head, data, 64); memcpy(h.tail, data + size - 64, 64); h.size = size; h.texture = texture; h.found = false;
	gHeld[oid].push_back(h);
}
static void scanHeld() {
	uint64_t memSize = 0; const uint8_t *mem = pg_engine_memory(&memSize);
	if (!mem || !memSize) return;
	const double t0 = nowMs(), MB = 1048576.0;
	// First nonzero head word of each upload, in a bitmap (quick reject) and a multimap (index of that word).
	std::vector<uint64_t> bits(1 << 18);
	std::unordered_multimap<uint64_t, std::pair<Held *, int>> words;
	uint64_t texBytes = 0, meshBytes = 0, texCount = 0, meshCount = 0;
	for (auto &kv : gHeld) for (auto &h : kv.second) {
		h.found = false;
		(h.texture ? texBytes : meshBytes) += h.size; (h.texture ? texCount : meshCount)++;
		for (int k = 0; k < 8; k++) if (h.head[k]) {
			uint64_t b = (h.head[k] * 0x9E3779B97F4A7C15ull) >> 40;
			bits[b >> 6] |= 1ull << (b & 63); words.emplace(h.head[k], std::make_pair(&h, k)); break;
		}
	}
	// Only pages the engine has used are read (in memory or compressed); never-touched ones would become resident.
	const size_t page = (size_t)getpagesize(), pages = (size_t)((memSize + page - 1) / page);
	std::vector<char> resident(pages);
	if (mincore((caddr_t)mem, (size_t)memSize, resident.data()) != 0) { logf("[metal] held twice [trace]: mincore failed"); return; }
	uint64_t foundTex = 0, foundMesh = 0, nTex = 0, nMesh = 0, scanned = 0, compressed = 0;
	for (size_t pg = 0; pg < pages; pg++) {
		if (!(resident[pg] & (MINCORE_INCORE | MINCORE_PAGED_OUT))) continue;		// in memory or compressed: never-touched pages are skipped
		const uint64_t start = pg * page, end = std::min<uint64_t>(memSize, start + page);
		scanned += end - start;
		if (!(resident[pg] & MINCORE_INCORE)) compressed += end - start;
		for (uint64_t off = start; off + 8 <= end; off += 8) {
			uint64_t w; memcpy(&w, mem + off, 8);
			if (!w) continue;
			uint64_t b = (w * 0x9E3779B97F4A7C15ull) >> 40;
			if (!(bits[b >> 6] >> (b & 63) & 1)) continue;
			auto range = words.equal_range(w);
			for (auto it = range.first; it != range.second; ++it) {
				Held &h = *it->second.first;
				if (h.found || off < (uint64_t)it->second.second * 8) continue;
				const uint64_t at = off - (uint64_t)it->second.second * 8;
				if (at + h.size > memSize || memcmp(mem + at, h.head, 64) || memcmp(mem + at + h.size - 64, h.tail, 64)) continue;
				h.found = true;
				if (h.texture) { foundTex += h.size; nTex++; } else { foundMesh += h.size; nMesh++; }
			}
		}
	}
	logf("[metal] held twice [trace]: textures %.0f of %.0f MB uploaded are still in engine memory (%llu of %llu), meshes %.0f of %.0f MB (%llu of %llu); searched %.0f MB used (%.0f MB of it compressed) of %.0f MB in %.0f ms",
	     foundTex / MB, texBytes / MB, (unsigned long long)nTex, (unsigned long long)texCount, foundMesh / MB, meshBytes / MB, (unsigned long long)nMesh, (unsigned long long)meshCount,
	     scanned / MB, compressed / MB, memSize / MB, nowMs() - t0);
}
// A BC1 texture made ETC2 (GTA-217) whose first upload has transparent texels: ETC2 RGB has no alpha, so it is made
// ASTC 4x4 instead (exact, as before), while nothing has used it yet.
static void etcBC1ToASTC(Texture *t) {
	MTLTextureDescriptor *desc = t->etcDesc;
	t->etcDesc = nil; t->etcDecided = true;
	if (!desc) { logOnce("etcastcdesc", "Metal renderer: a BC1 texture with transparent texels stays ETC2 (no descriptor)"); return; }
	desc.pixelFormat = t->bcSrgb ? MTLPixelFormatASTC_4x4_sRGB : MTLPixelFormatASTC_4x4_LDR;
	id<MTLTexture> tex = [R->device newTextureWithDescriptor:desc];
	if (!tex) return;
	gTextureStats.gpuBytes -= (int64_t)t->gpuBytes; gTextureStats.bcGpuBytes -= (int64_t)t->gpuBytes; gTextureStats.kindBytes[t->bcKind][t->bcSrgb] -= (int64_t)t->gpuBytes;
	gTexKindBytes[t->memKind] -= (int64_t)t->gpuBytes; gTexKindCount[t->memKind]--; gFormatBytes[t->format & 1023] -= (int64_t)t->gpuBytes;
	t->tex = tex; t->format = desc.pixelFormat; t->etc = false; t->astc = true; t->views.clear();
	t->gpuBytes = tex.allocatedSize ? tex.allocatedSize : t->gpuBytes * 2;		// the simulator reports no sizes: ASTC is twice ETC2 here
	t->memKind = PGTexBCASTC;
	gTextureStats.gpuBytes += (int64_t)t->gpuBytes; gTextureStats.bcGpuBytes += (int64_t)t->gpuBytes; gTextureStats.kindBytes[t->bcKind][t->bcSrgb] += (int64_t)t->gpuBytes;
	gTexKindBytes[t->memKind] += (int64_t)t->gpuBytes; gTexKindCount[t->memKind]++; gFormatBytes[t->format & 1023] += (int64_t)t->gpuBytes;
	gTextureStats.etcToASTC++;
}
// BC blocks re-encoded as ETC2/EAC or ASTC (whichever the texture is now) and uploaded. False: the texture is neither.
static bool uploadConverted(Texture *t, uint32_t level, uint32_t slice, uint32_t x, uint32_t y, uint32_t z, uint32_t w, uint32_t h, uint32_t d,
                            uint32_t bpr, uint32_t rpi, const uint8_t *data, size_t size) {
	if (!t->etc && !t->astc) return false;
	size_t outSize = 0; uint32_t outBpr = 0, outRpi = 0;
	double c0 = nowMs();
	void *blocks = t->etc ? PGTranscodeBCToETC(t->bcKind, w, h, d, bpr, rpi, data, size, &outSize, &outBpr, &outRpi)
	                      : PGTranscodeBCToASTC(t->bcKind, w, h, d, bpr, rpi, data, size, &outSize, &outBpr, &outRpi);
	const uint64_t micros = (uint64_t)((nowMs() - c0) * 1000);
	gTextureStats.convertMicros += micros; gTextureStats.converts++; if (t->etc) gTextureStats.etcMicros += micros;
	if (!blocks) { gTextureStats.decodeFailures++; logOnce("convfail" + std::to_string(t->bcKind), "Metal renderer: BC%u upload smaller than its region", t->bcKind); return true; }
	uploadBlocks(t, level, slice, x, y, z, w, h, d, outBpr, outBpr * outRpi, (const uint8_t *)blocks);
	free(blocks);
	t->proxyDirty = true; t->written = true;		// written (GTA-77): no longer a never-written texture
	return true;
}
// The GPU is about to use a BC1 texture still waiting as ETC2: decide (ASTC if any waiting level has a transparent
// texel), encode and upload what waited.
static void etcSettle(Texture *t) {
	if (!t || !t->etc || t->etcDecided) return;
	t->etcDecided = true;
	if (t->etcAlpha) etcBC1ToASTC(t);
	t->etcDesc = nil;
	for (auto &l : t->etcPending) {
		gTextureStats.etcPendingBytes -= (int64_t)l.data.size();
		uploadConverted(t, l.level, l.slice, l.x, l.y, l.z, l.w, l.h, l.d, l.bpr, l.rpi, l.data.data(), l.data.size());
	}
	std::vector<Texture::EtcPending>().swap(t->etcPending);
}
static void uploadTextureInner(const uint32_t *p) {
	Texture *t = texture(p[0]);
	if (!t || !t->tex) return;
	uint32_t mip = p[1], slice = p[2], x = p[3], y = p[4], z = p[5], w = p[6], h = p[7], d = std::max(1u, p[8]);
	uint32_t bpr = p[9], rpi = p[10], size = p[11];
	const uint8_t *data = (const uint8_t *)(p + 12);
	if (!x && !y && !z) rememberHeld(p[0], data, size, true);
	if (mip >= t->mips) return;
	if (mip < t->skip) return;		// Lite: the dropped level
	const uint32_t level = mip - t->skip;		// the GPU texture's level for this mip
	void *decoded = nullptr;
	if (t->bcNative) {		// blocks go to the GPU as they are; rows and images count block rows
		uint32_t mw, mh, md; mipExtent(t, mip, mw, mh, md);
		w = std::min(w, mw - std::min(mw, x)); h = std::min(h, mh - std::min(mh, y));
		if (!w || !h) return;
		uint32_t blockRows = (h + 3) / 4, imageBytes = bpr * (rpi ? rpi : blockRows);
		if (getenv("PG_TRACE_BC_FORMATS") && (x || y || w < mw || h < mh || bpr != (w + 3) / 4 * bcBlockBytes(t->bcKind)))
			logOnce("bcpart" + std::to_string(t->dxgi) + "-" + std::to_string(mw) + "-" + std::to_string(w) + "-" + std::to_string(bpr), "Metal renderer [trace]: partial BC upload tex %u dxgi %u mip %u (%ux%u) region %u,%u %ux%u bpr %u rpi %u d %u size %u",
			        p[0], t->dxgi, mip, mw, mh, x, y, w, h, bpr, rpi, d, size);
		bool three = t->dim == 3;
		size_t total = (size_t)imageBytes * (d - 1) + (size_t)bpr * blockRows;
		if (total > size) { logOnce("bcnshort", "Metal renderer: compressed upload smaller than its region"); return; }
		MTLRegion region = MTLRegionMake3D(x, y, three ? z : 0, w, h, three ? d : 1);
		if (t->shared && !inFlight(t->lastUse)) {
			if (three || d == 1) [t->tex replaceRegion:region mipmapLevel:level slice:three ? 0 : slice withBytes:data bytesPerRow:bpr bytesPerImage:three ? imageBytes : 0];
			else for (uint32_t l = 0; l < d; l++) [t->tex replaceRegion:MTLRegionMake2D(x, y, w, h) mipmapLevel:level slice:slice + l withBytes:data + (size_t)l * imageBytes bytesPerRow:bpr bytesPerImage:0];
		} else {
			Alloc a = frameAlloc((size_t)imageBytes * d, 16);
			memcpy(a.ptr, data, std::min<size_t>((size_t)imageBytes * d, size));
			id<MTLBlitCommandEncoder> b = blitEncoder();
			if (three) [b copyFromBuffer:a.buf sourceOffset:a.off sourceBytesPerRow:bpr sourceBytesPerImage:imageBytes sourceSize:MTLSizeMake(w, h, d) toTexture:t->tex destinationSlice:0 destinationLevel:level destinationOrigin:MTLOriginMake(x, y, z)];
			else for (uint32_t l = 0; l < d; l++) [b copyFromBuffer:a.buf sourceOffset:a.off + (NSUInteger)l * imageBytes sourceBytesPerRow:bpr sourceBytesPerImage:imageBytes sourceSize:MTLSizeMake(w, h, 1) toTexture:t->tex destinationSlice:slice + l destinationLevel:level destinationOrigin:MTLOriginMake(x, y, 0)];
			t->lastUse = R->serial;
		}
		t->proxyDirty = true; t->written = true;
		return;
	}
	if (t->bcKind) {
		uint32_t mw, mh, md; mipExtent(t, mip, mw, mh, md);
		w = std::min(w, mw - std::min(mw, x)); h = std::min(h, mh - std::min(mh, y));
		if (!w || !h) return;
		storeCompressed(t, mip, slice, x, y, z, w, h, d, bpr, rpi, data, size);
#if TARGET_OS_SIMULATOR
		// PG_DUMP_BC=3 (simulator): the game's BC3 blocks as uploaded, appended to Documents/bc3-blocks.bin (up to
		// 64 MB), for measuring BC3-to-ASTC quality offline on real textures (GTA-118).
		static int dumpKind = getenv("PG_DUMP_BC") ? atoi(getenv("PG_DUMP_BC")) : 0;
		static size_t dumped;
		if (dumpKind && dumpKind == (int)t->bcKind && dumped < (64u << 20) && d == 1) {
			static FILE *dump = fopen([[NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject
			                           stringByAppendingPathComponent:@"bc3-blocks.bin"] fileSystemRepresentation], "wb");
			const uint32_t rowBytes = (w + 3) / 4 * bcBlockBytes(t->bcKind);
			if (dump && rowBytes <= bpr) for (uint32_t row = 0; row < (h + 3) / 4 && (size_t)row * bpr + rowBytes <= size; row++) {
				fwrite(data + (size_t)row * bpr, 1, rowBytes, dump); dumped += rowBytes;
			}
			if (dump) fflush(dump);
		}
#endif
		size_t outSize = 0;
		if (t->etc && t->bcKind == 1) {
			const bool transparent = PGBC1HasTransparency(w, h, d, bpr, rpi, data, size);
			if (!t->etcDecided) {		// waits for the GPU's first use (etcSettle)
				t->etcAlpha |= transparent;
				t->etcPending.push_back({level, slice, x, y, z, w, h, d, bpr, rpi, std::vector<uint8_t>(data, data + size)});
				gTextureStats.etcPendingBytes += (int64_t)size;
				return;
			}
			if (transparent) { gTextureStats.etcAlphaLost++; logOnce("etcalpha", "Metal renderer: a BC1 texture already used as ETC2 got transparent texels in a later upload (%ux%u, level %u); they show opaque", t->width, t->height, mip); }
		}
		// Re-encoded block by block as ETC2/EAC (GTA-217) or ASTC, then uploaded as blocks (rows count block rows)
		if (uploadConverted(t, level, slice, x, y, z, w, h, d, bpr, rpi, data, size)) return;
		double c0 = nowMs();
		decoded = PGDecodeBC(t->bcKind, w, h, d, bpr, rpi, data, size, &outSize);
		gTextureStats.convertMicros += (uint64_t)((nowMs() - c0) * 1000); gTextureStats.converts++;
		if (!decoded) { gTextureStats.decodeFailures++; logOnce("bcfail", "Metal renderer: BC decode failed"); return; }
		if (t->format == MTLPixelFormatA1BGR5Unorm) {		// RGBA8 to A1BGR5 in place: Metal names components from the lowest bit (A bit 0, B 1-5, G 6-10, R 11-15)
			const uint8_t *in = (const uint8_t *)decoded; uint16_t *out = (uint16_t *)decoded;
			for (size_t i = 0, n = outSize / 4; i < n; i++, in += 4)
				out[i] = (uint16_t)((in[0] >> 3) << 11 | (in[1] >> 3) << 6 | (in[2] >> 3) << 1 | (in[3] >= 128));
			outSize /= 2;
		}
		data = (const uint8_t *)decoded; bpr = w * bytesPerTexel(t->format); rpi = h; size = (uint32_t)outSize;
	}
	uint32_t imageBytes = bpr * (rpi ? rpi : h);
	bool three = t->dim == 3;
	MTLRegion region = MTLRegionMake3D(x, y, three ? z : 0, w, h, three ? d : 1);
	if (t->shared && !inFlight(t->lastUse)) {
		if (three || d == 1) [t->tex replaceRegion:region mipmapLevel:level slice:three ? 0 : slice withBytes:data bytesPerRow:bpr bytesPerImage:three ? imageBytes : 0];
		else for (uint32_t l = 0; l < d; l++) [t->tex replaceRegion:MTLRegionMake2D(x, y, w, h) mipmapLevel:level slice:slice + l withBytes:data + (size_t)l * imageBytes bytesPerRow:bpr bytesPerImage:0];
	} else {
		size_t total = (size_t)imageBytes * d;
		Alloc a = frameAlloc(total, 16);
		memcpy(a.ptr, data, std::min<size_t>(total, size));
		id<MTLBlitCommandEncoder> b = blitEncoder();
		if (three) [b copyFromBuffer:a.buf sourceOffset:a.off sourceBytesPerRow:bpr sourceBytesPerImage:imageBytes sourceSize:MTLSizeMake(w, h, d) toTexture:t->tex destinationSlice:0 destinationLevel:level destinationOrigin:MTLOriginMake(x, y, z)];
		else for (uint32_t l = 0; l < d; l++) [b copyFromBuffer:a.buf sourceOffset:a.off + (NSUInteger)l * imageBytes sourceBytesPerRow:bpr sourceBytesPerImage:imageBytes sourceSize:MTLSizeMake(w, h, 1) toTexture:t->tex destinationSlice:slice + l destinationLevel:level destinationOrigin:MTLOriginMake(x, y, 0)];
		t->lastUse = R->serial;
	}
	if (decoded) free(decoded);
	t->proxyDirty = true; t->written = true;
}

// ---- buffers ------------------------------------------------------------------------------------------------------------
static void createBuffer(const uint32_t *p) {
	auto *b = new Buffer(p[0]);
	b->size = p[1]; b->bind = p[2]; b->misc = p[3]; b->stride = p[4];
	// A constant buffer's CPU copy is made on its first write (GTA-174): in a city drive 3,118 of 3,220 were never
	// written, and an unwritten one binds the zero buffer, which holds what it would (zeros, at most 64 KB).
	if (b->bind & BIND_CB) gBufferStats.cbCount++;
	if ((b->bind & (BIND_VB | BIND_IB | BIND_SRV | BIND_UAV)) || (b->misc & 0x10)) {
		b->bytes = std::max(4u, (b->size + 3) & ~3u);
		static int slabs = -1;
		if (slabs < 0) slabs = !(getenv("PG_BUFFER_SLABS") && !strcmp(getenv("PG_BUFFER_SLABS"), "0"));
		int32_t slab; uint32_t off;
		// Only plain vertex/index buffers: no shader or compute access, no special flags.
		bool mesh = (b->bind & (BIND_VB | BIND_IB)) && !(b->bind & ~(BIND_VB | BIND_IB)) && !b->misc;
		if (slabs && mesh && b->bytes <= slabLargest() && slabAllocate(b->bytes, slab, off)) { b->buf = gSlabs[slab].buf; b->base = off; b->slab = slab; }
		else b->buf = [R->device newBufferWithLength:b->bytes options:MTLResourceStorageModeShared];
		if (b->buf) {
			b->counted = b->bytes;
			gBufferStats.count++; gBufferStats.bytes += b->bytes; if (b->slab < 0) gBufferStats.pages += (int64_t)pageRound(b->bytes); else gBufferStats.inSlab += b->bytes;
			if (b->bind & (BIND_VB | BIND_IB)) { gBufferStats.meshCount++; gBufferStats.meshBytes += b->bytes; }
		}
		if (b->buf) memset((uint8_t *)b->buf.contents + b->base, 0, b->bytes);
	}
	R->objs.set(p[0], b);
}

// Times each vertex or index buffer was written (the ped spike check below runs again after a rewrite).
static std::unordered_map<uint32_t, uint32_t> gMeshWrites;
static void uploadBuffer(const uint32_t *p, bool noOverwrite) {
	Buffer *b = buffer(p[0]);
	if (!b) return;
	if (b->bind & (BIND_VB | BIND_IB)) gMeshWrites[p[0]]++;
	uint32_t offset = p[1], size = p[2];
	const uint8_t *data = (const uint8_t *)(p + 3);
	if (b->meshPages) { PGMeshForgetMesh(b->oid, b->meshPage, b->meshPages, 0); b->meshPages = 0; }		// rewritten: the engine's bytes go back first
	if ((b->bind & BIND_CB) && offset < b->size) {
		if (b->shadow.empty()) { b->shadow.assign(b->size, 0); gBufferStats.cbBytes += b->size; }
		memcpy(b->shadow.data() + offset, data, std::min<size_t>(size, b->shadow.size() - offset));
		b->cbFrame = UINT64_MAX; if (!b->version++) gBufferStats.cbWritten++;
	}
	if (!offset && b->shadow.empty() && (b->bind & (BIND_VB | BIND_IB))) rememberHeld(p[0], data, size, false);
	if (!b->buf || offset >= b->bytes) return;
	size = std::min(size, b->bytes - offset);
	if (!noOverwrite && inFlight(b->lastUse)) {
		if (b->bind & BIND_UAV) {		// the GPU may write it: the new bytes go in order through the command buffer
			Alloc a = frameAlloc(size, 16);
			memcpy(a.ptr, data, size);
			[blitEncoder() copyFromBuffer:a.buf sourceOffset:a.off toBuffer:b->buf destinationOffset:b->base + offset size:size & ~3u];
			b->lastUse = R->serial;
			return;
		}
		// renamed: draws already recorded keep reading the old storage (D3D's discard semantics)
		id<MTLBuffer> fresh = [R->device newBufferWithLength:b->bytes options:MTLResourceStorageModeShared];
		if (offset || size < b->bytes) memcpy(fresh.contents, (const uint8_t *)b->buf.contents + b->base, b->bytes);
		if (b->slab >= 0) {		// a slab buffer rewritten while in use moves to its own storage
			gSlabPending.push_back({R->serial, b->slab, (uint32_t)b->base, (b->bytes + kSlabAlign - 1) & ~(kSlabAlign - 1)});
			gBufferStats.pages += (int64_t)pageRound(b->bytes); gBufferStats.inSlab -= (int64_t)b->counted;
			b->slab = -1; b->base = 0;
		}
		b->buf = fresh;
		b->lastUse = 0;
	}
	memcpy((uint8_t *)b->buf.contents + b->base + offset, data, size);
	// Mesh release (GTA-152): the whole mesh is in buf now, so the engine's copy of it can go.
	if (offset + size >= b->size && (b->bind & (BIND_VB | BIND_IB)) && !(b->bind & ~(BIND_VB | BIND_IB)) && !b->misc && PGMeshReleaseOn()) {
		uint64_t first; uint32_t count, at;
		if (PGMeshRelease(p[0], (const uint8_t *)b->buf.contents + b->base, b->size, &first, &count, &at)) { b->meshPage = first; b->meshPages = count; }
	}
}

// A constant buffer's current contents at a GPU address valid for this frame, with at least `need` bytes readable.
static Alloc constantBuffer(Buffer *b, uint32_t need) {
	if (b->cbFrame != R->frame || b->cbCap < need) {
		uint32_t cap = std::max<uint32_t>((uint32_t)b->shadow.size(), std::max(need, b->cbPad));
		cap = (cap + 15) & ~15u;
		b->cbPad = std::max(b->cbPad, need);
		Alloc a = frameAlloc(cap);
		memcpy(a.ptr, b->shadow.data(), b->shadow.size());
		if (cap > b->shadow.size()) memset(a.ptr + b->shadow.size(), 0, cap - b->shadow.size());
		b->cbBuf = a.buf; b->cbOff = a.off; b->cbCap = cap; b->cbFrame = R->frame;
	}
	return {b->cbBuf, b->cbOff, nullptr};
}

// ---- views --------------------------------------------------------------------------------------------------------------
static MTLTextureType viewType(TexDim dim, bool ms) {
	switch (dim) {
	case D1: return MTLTextureType1D;
	case D2Array: return MTLTextureType2DArray;
	case D3: return MTLTextureType3D;
	case DCube: return MTLTextureTypeCube;
	case DCubeArray: return MTLTextureTypeCubeArray;
	default: return ms ? MTLTextureType2DMultisample : MTLTextureType2D;
	}
}
static id<MTLTexture> srvTexture(View *v, Texture *t, const ResBinding &b) {
	if (!t->tex) return nil;
	etcSettle(t);
	bool ms = b.kind == RTextureMS || b.kind == RDepthMS;
	MTLTextureType type = viewType(b.dim, ms);
	MTLPixelFormat fmt = t->format;
	if (t->isDepth && b.sample == SUint) fmt = MTLPixelFormatX32_Stencil8;
	else if (!t->isDepth) fmt = viewFormat(v->fmt, t->format);
	if (t->bcKind && v->fmt && v->fmt != t->dxgi && getenv("PG_TRACE_BC_FORMATS")) logOnce("bcview" + std::to_string(t->dxgi) + "-" + std::to_string(v->fmt), "Metal renderer [trace]: BC texture DXGI %u viewed as DXGI %u", t->dxgi, v->fmt);
	uint32_t mips = t->samples > 1 ? 1 : t->mips;
	uint32_t base = std::min(v->a, mips - 1);
	uint32_t count = (v->b == 0xffffffff || v->b == 0) ? mips - base : std::min(v->b, mips - base);
	if (t->skip) {		// Lite: the game's mip range in the GPU texture's levels (a view of the dropped level gets the next)
		uint32_t end = base + count;
		base = base > t->skip ? base - t->skip : 0;
		end = end > t->skip ? end - t->skip : 1;
		count = std::max(1u, end - std::min(end, base));
		mips -= t->skip;
	}
	uint32_t layers = t->dim == 3 ? 1 : t->depthOrLayers;
	uint32_t first = std::min(v->c, layers - 1), slices;
	if (b.dim == DCube) slices = 6;
	else if (b.dim == DCubeArray) slices = v->d ? v->d * 6 : (layers - first) / 6 * 6;
	else if (b.dim == D2Array) slices = v->d ? std::min(v->d, layers - first) : layers - first;
	else slices = 1;
	if (t->dim == 3) { first = 0; slices = 1; }
	if ((b.dim == DCube || b.dim == DCubeArray) && (slices == 0 || first + slices > layers)) {
		logOnce("cube" + std::to_string(t->oid), "Metal renderer: cube SRV over a texture with %u layer(s)", layers);
		return nil;
	}
	if (b.dim == D3 && t->dim != 3) return nil;
	if (b.dim != D3 && t->dim == 3) return nil;
	if (!t->alphaView && type == t->tex.textureType && fmt == t->format && base == 0 && count == mips && first == 0 && slices == (t->dim == 3 ? 1 : layers)) return t->tex;
	uint64_t key = fnv(fnv(fnv(fnv(fnv(1469598103934665603ull, type), fmt), base | ((uint64_t)count << 16)), first), slices);
	auto it = v->views.find(key);
	if (it != v->views.end()) return it->second;
	id<MTLTexture> out = t->alphaView
		? [t->tex newTextureViewWithPixelFormat:fmt textureType:type levels:NSMakeRange(base, count) slices:NSMakeRange(first, slices)
		                                swizzle:MTLTextureSwizzleChannelsMake(MTLTextureSwizzleZero, MTLTextureSwizzleZero, MTLTextureSwizzleZero, MTLTextureSwizzleRed)]
		: [t->tex newTextureViewWithPixelFormat:fmt textureType:type levels:NSMakeRange(base, count) slices:NSMakeRange(first, slices)];
	if (!out) logOnce("view" + std::to_string(t->oid), "Metal renderer: SRV view failed (texture %u)", t->oid);
	v->views[key] = out;
	return out;
}
static id<MTLTexture> uavTexture(View *u, Texture *t, const ResBinding &b) {
	if (!t->tex) return nil;
	MTLTextureType type = viewType(b.dim, false);
	uint32_t mip = std::min(u->a, t->mips - 1);
	uint32_t layers = t->dim == 3 ? 1 : t->depthOrLayers;
	uint32_t first = 0, slices = layers;
	if (b.dim == D2Array) { first = u->vdim == 5 ? u->b : 0; slices = u->vdim == 5 ? u->c : layers; }
	else if (b.dim == D2) { first = u->vdim == 5 ? u->b : 0; slices = 1; }
	if (t->dim == 3) { first = 0; slices = 1; }
	if (type == t->tex.textureType && mip == 0 && t->mips == 1 && first == 0 && slices == layers) return t->tex;
	uint64_t key = fnv(fnv(fnv(1469598103934665603ull, type), mip), first | ((uint64_t)slices << 32));
	auto it = u->views.find(key);
	if (it != u->views.end()) return it->second;
	id<MTLTexture> out = [t->tex newTextureViewWithPixelFormat:t->format textureType:type levels:NSMakeRange(mip, 1) slices:NSMakeRange(first, std::max(1u, slices))];
	u->views[key] = out;
	return out;
}
static id<MTLTexture> attachmentTexture(Texture *t, uint32_t dxgi) {
	MTLPixelFormat fmt = viewFormat(dxgi, t->format);
	if (fmt == t->format) return t->tex;
	uint64_t key = fnv(0xa77ac4ull, fmt);
	auto it = t->views.find(key);
	if (it != t->views.end()) return it->second;
	id<MTLTexture> v = [t->tex newTextureViewWithPixelFormat:fmt];
	t->views[key] = v;
	return v;
}

// ---- clears and passes ----------------------------------------------------------------------------------------------------
static void beginOcclusionInPass();
static void encodeClear(const PendingClear &c) {
	Texture *t = texture(c.tex);
	if (!t || !t->tex) return;
	endEncoders();
	MTLRenderPassDescriptor *d = [MTLRenderPassDescriptor renderPassDescriptor];
	if (c.depth) {
		d.depthAttachment.texture = t->tex; d.depthAttachment.level = c.mip; d.depthAttachment.slice = c.slice;
		d.depthAttachment.loadAction = (c.flags & 1) ? MTLLoadActionClear : MTLLoadActionLoad; d.depthAttachment.storeAction = MTLStoreActionStore;
		d.depthAttachment.clearDepth = c.z;
		if (t->hasStencil) {
			d.stencilAttachment.texture = t->tex; d.stencilAttachment.level = c.mip; d.stencilAttachment.slice = c.slice;
			d.stencilAttachment.loadAction = (c.flags & 2) ? MTLLoadActionClear : MTLLoadActionLoad; d.stencilAttachment.storeAction = MTLStoreActionStore;
			d.stencilAttachment.clearStencil = c.stencil;
		}
	} else {
		d.colorAttachments[0].texture = t->tex; d.colorAttachments[0].level = c.mip;
		if (t->dim == 3) d.colorAttachments[0].depthPlane = c.slice; else d.colorAttachments[0].slice = c.slice;
		d.colorAttachments[0].loadAction = MTLLoadActionClear; d.colorAttachments[0].storeAction = MTLStoreActionStore;
		d.colorAttachments[0].clearColor = MTLClearColorMake(c.color[0], c.color[1], c.color[2], c.color[3]);
	}
	id<MTLRenderCommandEncoder> e = [commandBuffer() renderCommandEncoderWithDescriptor:d];
	[e endEncoding];
	t->lastUse = R->serial; t->proxyDirty = true; t->written = true;
}
static void flushClears() {
	if (R->clears.empty()) return;
	std::vector<PendingClear> list;
	list.swap(R->clears);
	for (auto &c : list) encodeClear(c);
}
static void addClear(const PendingClear &c) {
	if (R->pass) { [R->pass endEncoding]; R->pass = nil; }
	R->rtDirty = true;
	for (auto &e : R->clears) if (e.tex == c.tex && e.mip == c.mip && e.slice == c.slice && e.depth == c.depth) {
		if (c.depth) {		// merge: a later clear of the other plane adds to the earlier one
			if (c.flags & 1) e.z = c.z;
			if (c.flags & 2) e.stencil = c.stencil;
			e.flags |= c.flags;
		} else e = c;
		return;
	}
	R->clears.push_back(c);
}

static bool ensurePass() {
	if (R->pass && !R->rtDirty) return true;
	if (R->pass) { [R->pass endEncoding]; R->pass = nil; }
	if (R->compute) { [R->compute endEncoding]; R->compute = nil; }
	if (R->blit) { [R->blit endEncoding]; R->blit = nil; }
	MTLRenderPassDescriptor *d = [MTLRenderPassDescriptor renderPassDescriptor];
	PassInfo info;
	bool any = false;
	std::vector<bool> consumed(R->clears.size(), false);
	auto clearFor = [&](uint32_t tex, uint32_t mip, uint32_t slice, bool depth) -> PendingClear * {
		for (size_t i = 0; i < R->clears.size(); i++) {
			PendingClear &c = R->clears[i];
			if (c.tex == tex && c.mip == mip && c.slice == slice && c.depth == depth) { consumed[i] = true; return &c; }
		}
		return nullptr;
	};
	uint64_t key = 1469598103934665603ull;
	for (uint32_t i = 0; i < 8; i++) {
		Texture *t = texture(R->rt[i].tex);
		if (!t || !t->tex) continue;
		auto *a = d.colorAttachments[i];
		a.texture = attachmentTexture(t, R->rt[i].fmt);
		a.level = std::min(R->rt[i].mip, t->mips - 1);
		if (t->dim == 3) a.depthPlane = R->rt[i].slice; else a.slice = R->rt[i].slice;
		PendingClear *c = clearFor(R->rt[i].tex, R->rt[i].mip, R->rt[i].slice, false);
		if (c) { a.loadAction = MTLLoadActionClear; a.clearColor = MTLClearColorMake(c->color[0], c->color[1], c->color[2], c->color[3]); }
		else a.loadAction = MTLLoadActionLoad;
		a.storeAction = MTLStoreActionStore;
		info.colors[i] = a.texture.pixelFormat; info.colorCount = i + 1;
		info.samples = t->samples; info.width = std::max(1u, t->width >> a.level); info.height = std::max(1u, t->height >> a.level);
		t->lastUse = R->serial; t->proxyDirty = true; t->written = true;
		any = true;
	}
	Texture *dt = texture(R->ds.tex);
	if (dt && dt->tex && dt->isDepth) {
		uint32_t mip = std::min(R->ds.mip, dt->mips - 1);
		info.roDepth = (R->ds.flags & 1) != 0; info.roStencil = (R->ds.flags & 2) != 0;
		PendingClear *c = clearFor(R->ds.tex, R->ds.mip, R->ds.slice, true);
		d.depthAttachment.texture = dt->tex; d.depthAttachment.level = mip; d.depthAttachment.slice = R->ds.slice;
		d.depthAttachment.loadAction = c && (c->flags & 1) ? MTLLoadActionClear : MTLLoadActionLoad;
		d.depthAttachment.clearDepth = c ? c->z : 1.0;
		d.depthAttachment.storeAction = MTLStoreActionStore;
		if (dt->hasStencil) {
			d.stencilAttachment.texture = dt->tex; d.stencilAttachment.level = mip; d.stencilAttachment.slice = R->ds.slice;
			d.stencilAttachment.loadAction = c && (c->flags & 2) ? MTLLoadActionClear : MTLLoadActionLoad;
			d.stencilAttachment.clearStencil = c ? c->stencil : 0;
			d.stencilAttachment.storeAction = MTLStoreActionStore;
		}
		info.depth = dt->format;
		if (!any) { info.width = std::max(1u, dt->width >> mip); info.height = std::max(1u, dt->height >> mip); info.samples = dt->samples; }
		dt->lastUse = R->serial; dt->proxyDirty = true; dt->written = true;
		any = true;
	}
	if (!any) return false;
	// clears of other targets happen before this pass, in their own (rare) passes
	std::vector<PendingClear> rest;
	for (size_t i = 0; i < R->clears.size(); i++) if (!consumed[i]) rest.push_back(R->clears[i]);
	R->clears.clear();
	for (auto &c : rest) encodeClear(c);
	d.visibilityResultBuffer = R->visibility;
	for (uint32_t i = 0; i < info.colorCount; i++) key = fnv(key, info.colors[i]);
	key = fnv(fnv(fnv(key, info.depth), info.samples), (info.roDepth ? 1 : 0) | (info.roStencil ? 2 : 0) | (info.colorCount << 4));
	info.key = key;
	R->passInfo = info;
	R->pass = [commandBuffer() renderCommandEncoderWithDescriptor:d];
	R->rtDirty = false;
	R->cache[0].reset(); R->cache[1].reset();
	// GTA-77: the colour outputs the pixel shaders clean of NaN and infinity in this pass (pg_nanc: mask, a zero the
	// compiler can't see, then each target's largest finite value as float bits). Bound in every pass: every game pixel
	// shader built with the clean reads it.
	{
		struct { uint32_t mask, salt, pad[2], maxBits[8]; } c = {};
		const int mode = gNanClamp.load(std::memory_order_relaxed);
		for (uint32_t i = 0; i < info.colorCount; i++) {
			if (packedFloat(info.colors[i])) R->passInfo.packedMask |= 1u << i;
			if (uint32_t bits = nanClampBits(info.colors[i], mode, (uint64_t)info.width * info.height)) { c.mask |= 1u << i; c.maxBits[i] = bits; }
		}
		[R->pass setFragmentBytes:&c length:sizeof c atIndex:kNanClampBuffer];
		gFix.passes++;
		if (R->passInfo.packedMask) gFix.packedPasses++;
		if (c.mask) gFix.cleanedPasses++;
		if (R->passInfo.packedMask && gDrawStats > 0) {
			for (uint32_t i = 0; i < info.colorCount; i++) if (packedFloat(info.colors[i])) {
				char k[64]; snprintf(k, sizeof k, "%s %ux%u", info.colors[i] == MTLPixelFormatRG11B10Float ? "RG11B10" : "RGB9E5", info.width, info.height);
				gPackedTargets[k]++;
			}
		}
	}
	R->appliedRs = UINT32_MAX; R->appliedRef = UINT32_MAX; R->appliedDss = nil; R->appliedPipe = nil;
	R->appliedBlend[0] = -1; R->viewportApplied = false; R->appliedScissor.x = UINT32_MAX;
	R->pipeDirty = true;
	beginOcclusionInPass();
	return true;
}

// ---- queries ------------------------------------------------------------------------------------------------------------
static void beginOcclusionInPass() {
	Query *q = R->activeOcclusion;
	if (!q || !R->pass || R->passSlot >= 0) return;
	if (R->visNext >= OCCLUSION_SLOTS) { logOnce("qfull", "Metal renderer: occlusion slots exhausted"); return; }
	R->passSlot = (int)R->visNext++;
	q->slots.push_back(R->passSlot);
	((uint64_t *)R->visibility.contents)[R->passSlot] = 0;
	[R->pass setVisibilityResultMode:MTLVisibilityResultModeCounting offset:R->passSlot * 8];
}
static void endOcclusionInPass() {
	if (R->pass && R->passSlot >= 0) { [R->pass setVisibilityResultMode:MTLVisibilityResultModeDisabled offset:0]; }
	R->passSlot = -1;
}

// ---- pipelines ----------------------------------------------------------------------------------------------------------
static const MTLBlendFactor BLEND_FACTOR[] = {
	MTLBlendFactorOne, MTLBlendFactorZero, MTLBlendFactorOne, MTLBlendFactorSourceColor, MTLBlendFactorOneMinusSourceColor,
	MTLBlendFactorSourceAlpha, MTLBlendFactorOneMinusSourceAlpha, MTLBlendFactorDestinationAlpha, MTLBlendFactorOneMinusDestinationAlpha,
	MTLBlendFactorDestinationColor, MTLBlendFactorOneMinusDestinationColor, MTLBlendFactorSourceAlphaSaturated, MTLBlendFactorOne, MTLBlendFactorOne,
	MTLBlendFactorBlendColor, MTLBlendFactorOneMinusBlendColor, MTLBlendFactorSource1Color, MTLBlendFactorOneMinusSource1Color,
	MTLBlendFactorSource1Alpha, MTLBlendFactorOneMinusSource1Alpha,
};
static MTLBlendFactor blendFactor(uint32_t v, MTLBlendFactor fallback) { return v >= 1 && v <= 19 ? BLEND_FACTOR[v] : fallback; }
static MTLBlendOperation blendOp(uint32_t v) {
	switch (v) { case 2: return MTLBlendOperationSubtract; case 3: return MTLBlendOperationReverseSubtract; case 4: return MTLBlendOperationMin; case 5: return MTLBlendOperationMax; default: return MTLBlendOperationAdd; }
}
static bool integerFormat(MTLPixelFormat f) {
	switch (f) {
	case MTLPixelFormatR8Uint: case MTLPixelFormatR16Uint: case MTLPixelFormatR32Uint: case MTLPixelFormatR32Sint: case MTLPixelFormatRGBA8Uint:
	case MTLPixelFormatRGBA8Sint: case MTLPixelFormatRGBA32Uint: case MTLPixelFormatRG32Uint: return true;
	default: return false;
	}
}
static MTLPrimitiveTopologyClass topologyClass(uint32_t topo) {
	return topo == 1 ? MTLPrimitiveTopologyClassPoint : topo == 2 || topo == 3 ? MTLPrimitiveTopologyClassLine : MTLPrimitiveTopologyClassTriangle;
}
static MTLPrimitiveType primitiveType(uint32_t topo) {
	switch (topo) { case 1: return MTLPrimitiveTypePoint; case 2: return MTLPrimitiveTypeLine; case 3: return MTLPrimitiveTypeLineStrip; case 5: return MTLPrimitiveTypeTriangleStrip; default: return MTLPrimitiveTypeTriangle; }
}

static Pipe *getPipeline(Shader *vs, Shader *ps, Layout *lay) {
	State *blend = state(R->blendId);
	const PassInfo &pi = R->passInfo;
	uint64_t key = fnv(fnv(fnv(1469598103934665603ull, vs->info->uid), ps && ps->info ? ps->info->uid : 0), pi.key);
	key = fnv(key, lay->oid);
	for (auto &s : lay->slots) { Buffer *b = buffer(R->vb[s.first].buf); key = fnv(key, b && b->buf ? R->vb[s.first].stride : 0xffffffffu); }
	key = fnv(fnv(key, topologyClass(R->topo)), blend ? blend->hash : 0);
	auto it = R->pipes.find(key);
	if (it != R->pipes.end()) return it->second;

	auto *pipe = new Pipe();
	R->pipes[key] = pipe;
	ShaderInfo *vsi = vs->info, *psi = ps ? ps->info : nullptr;
	pipe->label = vsi->label + " + " + (psi ? psi->label : "-");
	id<MTLFunction> vfn = shaderFunction(vsi), pfn = psi ? shaderFunction(psi) : nil;
	if (!vfn || (psi && !pfn)) { pipe->failed = true; return pipe; }
	if (psi) for (uint32_t loc : psi->inputs) if (std::find(vsi->outputs.begin(), vsi->outputs.end(), loc) == vsi->outputs.end()) {
		logOnce("varying" + pipe->label, "Metal renderer: %s reads varying %u that the vertex shader does not write", pipe->label.c_str(), loc);
		break;
	}
	MTLRenderPipelineDescriptor *d = [MTLRenderPipelineDescriptor new];
	d.vertexFunction = vfn; d.fragmentFunction = pfn;
	MTLVertexDescriptor *vd = [MTLVertexDescriptor vertexDescriptor];
	uint64_t seenLocations = 0;
	struct SlotInfo { uint32_t last = 0; bool used = false, instance = false; };
	SlotInfo slots[16];
	for (const LayoutEl &e : lay->els) {
		const Shader::Sig *sig = nullptr;
		for (auto &s : vs->sig) if (s.sem == e.sem && s.idx == e.idx) { sig = &s; break; }
		if (!sig || e.slot >= 16) continue;
		if (std::find(vsi->inputs.begin(), vsi->inputs.end(), sig->reg) == vsi->inputs.end()) continue;
		uint32_t bytes = 0;
		MTLVertexFormat f = vertexFormat(e.fmt, &bytes);
		if (f == MTLVertexFormatInvalid) { logOnce("vf" + std::to_string(e.fmt), "Metal renderer: unsupported vertex format DXGI %u", e.fmt); continue; }
		if (seenLocations & (1ull << sig->reg)) continue;
		seenLocations |= 1ull << sig->reg;
		vd.attributes[sig->reg].format = f; vd.attributes[sig->reg].offset = e.offset; vd.attributes[sig->reg].bufferIndex = kVertexBufferTop - e.slot;
		SlotInfo &si = slots[e.slot];
		si.used = true; si.instance = e.cls == 1; si.last = std::max(si.last, e.offset + bytes);
		auto *l = vd.layouts[kVertexBufferTop - e.slot];
		Buffer *vbuf = buffer(R->vb[e.slot].buf);
		uint32_t stride = vbuf && vbuf->buf ? R->vb[e.slot].stride : 0;
		if (stride == 0) { l.stepFunction = MTLVertexStepFunctionConstant; l.stepRate = 0; l.stride = std::max(4u, (si.last + 3) & ~3u); }
		else { l.stride = stride; l.stepFunction = si.instance ? MTLVertexStepFunctionPerInstance : MTLVertexStepFunctionPerVertex; l.stepRate = si.instance ? std::max(1u, e.rate) : 1; }
	}
	for (uint32_t loc : vsi->inputs) {
		if (seenLocations & (1ull << loc)) continue;
		vd.attributes[loc].format = MTLVertexFormatFloat4; vd.attributes[loc].offset = 0; vd.attributes[loc].bufferIndex = kZeroVertexBuffer;
		vd.layouts[kZeroVertexBuffer].stepFunction = MTLVertexStepFunctionConstant; vd.layouts[kZeroVertexBuffer].stepRate = 0; vd.layouts[kZeroVertexBuffer].stride = 16;
		pipe->zeroStream = true;
	}
	d.vertexDescriptor = vd;
	for (uint32_t s = 0; s < 16; s++) if (slots[s].used) {
		Buffer *vbuf = buffer(R->vb[s].buf);
		uint32_t stride = vbuf && vbuf->buf ? R->vb[s].stride : 0;
		pipe->vbReq.push_back({s, stride, slots[s].last, slots[s].instance});
	}
	const uint32_t *bw = blend && blend->words.size() >= 66 ? blend->words.data() : nullptr;
	for (uint32_t i = 0; i < pi.colorCount; i++) {
		if (!pi.colors[i]) continue;
		auto *c = d.colorAttachments[i];
		c.pixelFormat = pi.colors[i];
		bool writes = psi && std::find(psi->outputs.begin(), psi->outputs.end(), i) != psi->outputs.end();
		if (!writes) { c.writeMask = MTLColorWriteMaskNone; continue; }
		if (!bw) { c.writeMask = MTLColorWriteMaskAll; continue; }
		const uint32_t *q = bw + 2 + (bw[1] ? i : 0) * 8;
		uint32_t mask = q[7] & 0xf;
		c.writeMask = (mask & 1 ? MTLColorWriteMaskRed : 0) | (mask & 2 ? MTLColorWriteMaskGreen : 0) | (mask & 4 ? MTLColorWriteMaskBlue : 0) | (mask & 8 ? MTLColorWriteMaskAlpha : 0);
		if (q[0] && !integerFormat(pi.colors[i])) {
			c.blendingEnabled = YES;
			c.sourceRGBBlendFactor = blendFactor(q[1], MTLBlendFactorOne); c.destinationRGBBlendFactor = blendFactor(q[2], MTLBlendFactorZero); c.rgbBlendOperation = blendOp(q[3]);
			c.sourceAlphaBlendFactor = blendFactor(q[4], MTLBlendFactorOne); c.destinationAlphaBlendFactor = blendFactor(q[5], MTLBlendFactorZero); c.alphaBlendOperation = blendOp(q[6]);
		}
	}
	if (pi.depth) {
		d.depthAttachmentPixelFormat = pi.depth;
		if (hasStencil(pi.depth)) d.stencilAttachmentPixelFormat = pi.depth;
	}
	d.rasterSampleCount = pi.samples;
	// D3D11 alpha-to-coverage also works on single-sample targets (an alpha test at 0.5); Metal accepts it there too.
	d.alphaToCoverageEnabled = bw && bw[0] && psi && std::find(psi->outputs.begin(), psi->outputs.end(), 0u) != psi->outputs.end();
	d.inputPrimitiveTopology = topologyClass(R->topo);
	if (R->topo == 1) logOnce("points", "Metal renderer: point-list draws (%s): shaders do not write a point size", pipe->label.c_str());
	R->pipesPending++; R->pipesMade++; gPipelinesMade++;
	Renderer *r = R;
	std::string label = pipe->label;
	[R->device newRenderPipelineStateWithDescriptor:d completionHandler:^(id<MTLRenderPipelineState> s, NSError *error) {
		std::lock_guard<std::mutex> guard(r->pipeLock);
		if (!s) { pipe->failed = true; logOnce("pipe" + label, "Metal renderer: pipeline failed (%s): %s", label.c_str(), error.localizedDescription.UTF8String); }
		pipe->state = s;
		pipe->ready.store(true, std::memory_order_release);
		r->pipesPending--;
	}];
	return pipe;
}

static id<MTLDepthStencilState> depthStencilState() {
	const PassInfo &pi = R->passInfo;
	if (!pi.depth) return R->noDepth;
	State *s = state(R->dssId);
	bool stencil = hasStencil(pi.depth);
	uint64_t key = fnv(fnv(fnv(1469598103934665603ull, s ? s->hash : 0), stencil), (pi.roDepth ? 1 : 0) | (pi.roStencil ? 2 : 0));
	auto it = R->dssCache.find(key);
	if (it != R->dssCache.end()) return it->second;
	MTLDepthStencilDescriptor *d = [MTLDepthStencilDescriptor new];
	d.depthCompareFunction = MTLCompareFunctionAlways; d.depthWriteEnabled = NO;
	if (s && s->words.size() >= 13) {
		const uint32_t *w = s->words.data();
		if (w[0]) { d.depthWriteEnabled = w[1] == 1 && !pi.roDepth; d.depthCompareFunction = w[2] >= 1 && w[2] <= 8 ? (MTLCompareFunction)(w[2] - 1) : MTLCompareFunctionLess; }
		if (stencil && w[3]) {
			auto face = [&](const uint32_t *q) {
				MTLStencilDescriptor *f = [MTLStencilDescriptor new];
				f.stencilFailureOperation = q[0] >= 1 && q[0] <= 8 ? (MTLStencilOperation)(q[0] - 1) : MTLStencilOperationKeep;
				f.depthFailureOperation = q[1] >= 1 && q[1] <= 8 ? (MTLStencilOperation)(q[1] - 1) : MTLStencilOperationKeep;
				f.depthStencilPassOperation = q[2] >= 1 && q[2] <= 8 ? (MTLStencilOperation)(q[2] - 1) : MTLStencilOperationKeep;
				f.stencilCompareFunction = q[3] >= 1 && q[3] <= 8 ? (MTLCompareFunction)(q[3] - 1) : MTLCompareFunctionAlways;
				f.readMask = w[4] & 0xff; f.writeMask = pi.roStencil ? 0 : (w[4] >> 8) & 0xff;
				return f;
			};
			d.frontFaceStencil = face(w + 5); d.backFaceStencil = face(w + 9);
		}
	}
	id<MTLDepthStencilState> st = [R->device newDepthStencilStateWithDescriptor:d];
	R->dssCache[key] = st;
	return st;
}

// ---- depth copies: D3D11 compares against any float texture; Metal only against depth textures ---------------------
static id<MTLRenderPipelineState> depthCopyPipe;
static void refreshDepthProxy(Texture *t) {
	if (t->skip) { logOnce("liteproxy", "Metal renderer: Lite: depth proxy of a reduced texture not supported"); return; }
	if (!t->depthProxy) {
		auto *px = new Texture(0);
		px->format = MTLPixelFormatDepth32Float; px->isDepth = true; px->dim = 2; px->width = t->width; px->height = t->height;
		px->depthOrLayers = t->dim == 3 ? 1 : t->depthOrLayers; px->mips = t->mips; px->samples = 1;
		MTLTextureDescriptor *d = [MTLTextureDescriptor new];
		d.pixelFormat = MTLPixelFormatDepth32Float; d.width = t->width; d.height = t->height; d.mipmapLevelCount = t->mips;
		d.textureType = px->depthOrLayers > 1 ? MTLTextureType2DArray : MTLTextureType2D; d.arrayLength = px->depthOrLayers;
		d.usage = MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget; d.storageMode = MTLStorageModePrivate;
		px->tex = [R->device newTextureWithDescriptor:d];
		t->depthProxy = px;
		t->proxyDirty = true;
	}
	if (!t->proxyDirty || !t->depthProxy->tex) return;
	endEncoders();
	Texture *px = t->depthProxy;
	for (uint32_t mip = 0; mip < px->mips; mip++) for (uint32_t layer = 0; layer < px->depthOrLayers; layer++) {
		uint64_t key = ((uint64_t)mip << 32) | layer;
		auto it = t->views.find(key ^ 0xd3d3000000000000ull);
		id<MTLTexture> src;
		if (it != t->views.end()) src = it->second;
		else { src = [t->tex newTextureViewWithPixelFormat:t->format textureType:MTLTextureType2D levels:NSMakeRange(mip, 1) slices:NSMakeRange(layer, 1)]; t->views[key ^ 0xd3d3000000000000ull] = src; }
		MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
		rp.depthAttachment.texture = px->tex; rp.depthAttachment.level = mip; rp.depthAttachment.slice = layer;
		rp.depthAttachment.loadAction = MTLLoadActionDontCare; rp.depthAttachment.storeAction = MTLStoreActionStore;
		id<MTLRenderCommandEncoder> e = [commandBuffer() renderCommandEncoderWithDescriptor:rp];
		[e setRenderPipelineState:depthCopyPipe];
		[e setDepthStencilState:R->dssCache[0xdeb7ull]];
		[e setFragmentTexture:src atIndex:0];
		[e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
		[e endEncoding];
	}
	t->proxyDirty = false;
	t->lastUse = R->serial;
}
static void prepareProxies(ShaderInfo *info, int stage) {
	for (const ResBinding &b : info->res) {
		if (b.kind != RDepth) continue;
		View *v = view(R->srv[stage][(b.binding - 32) & 127], OSrv);
		Texture *t = v && !v->isBuf ? texture(v->res) : nullptr;
		if (t && t->tex && !t->isDepth && t->samples == 1 && t->dim != 3) refreshDepthProxy(t);
	}
}

// ---- bindings -------------------------------------------------------------------------------------------------------------
static inline void setBuffer(int stage, id<MTLBuffer> b, NSUInteger off, uint32_t index) {
	StageCache &c = R->cache[stage];
	if (c.buffers[index] == b) {
		if (c.offsets[index] == off) return;
		if (stage == 0) [R->pass setVertexBufferOffset:off atIndex:index];
		else if (stage == 1) [R->pass setFragmentBufferOffset:off atIndex:index];
		else [R->compute setBufferOffset:off atIndex:index];
	} else {
		if (stage == 0) [R->pass setVertexBuffer:b offset:off atIndex:index];
		else if (stage == 1) [R->pass setFragmentBuffer:b offset:off atIndex:index];
		else [R->compute setBuffer:b offset:off atIndex:index];
		c.buffers[index] = b;
	}
	c.offsets[index] = off;
}
static inline void setTexture(int stage, id<MTLTexture> t, uint32_t index) {
	StageCache &c = R->cache[stage];
	if (c.textures[index] == t) return;
	if (stage == 0) [R->pass setVertexTexture:t atIndex:index];
	else if (stage == 1) [R->pass setFragmentTexture:t atIndex:index];
	else [R->compute setTexture:t atIndex:index];
	c.textures[index] = t;
}
static inline void setSampler(int stage, id<MTLSamplerState> s, uint32_t index) {
	StageCache &c = R->cache[stage];
	if (c.samplers[index] == s) return;
	if (stage == 0) [R->pass setVertexSamplerState:s atIndex:index];
	else if (stage == 1) [R->pass setFragmentSamplerState:s atIndex:index];
	else [R->compute setSamplerState:s atIndex:index];
	c.samplers[index] = s;
}

static Buffer *storageBuffer(int stage, const ResBinding &b, uint32_t &offset) {
	offset = 0;
	View *v = nullptr;
	if (b.binding >= 160) v = view(R->uav[stage][(b.binding - (b.binding >= 176 ? 176 : 160)) & 7], OUav);
	else v = view(R->srv[stage][(b.binding - 32) & 127], OSrv);
	if (!v || !v->isBuf) return nullptr;
	Buffer *buf = buffer(v->res);
	if (!buf || !buf->buf) return nullptr;
	if (b.binding < 176) { uint32_t stride = buf->stride ? buf->stride : 4; uint64_t off = (uint64_t)v->a * stride; if (off < buf->bytes) offset = (uint32_t)(off & ~3ull); }
	offset += (uint32_t)buf->base;
	return buf;
}

// Binds every resource the shader declares; false if the draw must be skipped.
static bool bindStage(int stage, ShaderInfo *info) {
	uint32_t sizes[32] = {};
	uint32_t texFloatNoFilterSamplers = 0;
	for (const ResBinding &b : info->res) {
		switch (b.kind) {
		case RUbo: {
			if (b.binding == 15) {
				if (info->constBuffer) setBuffer(stage, info->constBuffer, info->constOffset, kConstTableBuffer);
				else setBuffer(stage, R->zeroBuffer, 0, kConstTableBuffer);
				break;
			}
			const auto &c = R->cb[stage][b.binding & 15];
			Buffer *buf = buffer(c.buf);
			if (!buf || buf->shadow.empty()) { setBuffer(stage, R->zeroBuffer, 0, b.index); break; }
			Alloc a = constantBuffer(buf, c.first * 16 + b.size);
			setBuffer(stage, a.buf, a.off + c.first * 16, b.index);
			break;
		}
		case RStorageRO: case RStorageRW: {
			uint32_t offset = 0;
			Buffer *buf = storageBuffer(stage, b, offset);
			uint32_t size = 65536;
			if (b.binding >= 176) {
				if (buf && !buf->counter) { buf->counter = [R->device newBufferWithLength:16 options:MTLResourceStorageModeShared]; memset(buf->counter.contents, 0, 16); }
				if (buf) { setBuffer(stage, buf->counter, 0, b.index); size = 16; buf->lastUse = R->serial; }
				else setBuffer(stage, R->zeroBuffer, 0, b.index);
			} else if (buf) { setBuffer(stage, buf->buf, offset, b.index); size = buf->bytes - offset; buf->lastUse = R->serial; }
			else setBuffer(stage, R->zeroBuffer, 0, b.index);
			for (auto &al : info->arrayLengths) if (al.first == b.index && al.second < 32) sizes[al.second] = size;
			break;
		}
		case RSampler: break;		// after the textures (32-bit float fallback)
		case RStorageTex: {
			View *u = view(R->uav[stage][(b.binding - 160) & 7], OUav);
			Texture *t = u && !u->isBuf ? texture(u->res) : nullptr;
			id<MTLTexture> v = t ? uavTexture(u, t, b) : nil;
			if (!v) { logOnce("nouav" + info->label, "Metal renderer: %s: storage texture u%u unbound", info->label.c_str(), b.binding - 160); v = dummyTexture(RStorageTex, b.dim, b.sample); }
			else { t->lastUse = R->serial; t->proxyDirty = true; t->written = true; }
			setTexture(stage, v, b.index);
			break;
		}
		default: {		// sampled, multisampled and depth textures
			View *v = view(R->srv[stage][(b.binding - 32) & 127], OSrv);
			Texture *t = v && !v->isBuf ? texture(v->res) : nullptr;
			id<MTLTexture> tex = nil;
			if (t) {
				if (b.kind == RDepth && !t->isDepth) {
					if (t->depthProxy && t->depthProxy->tex) tex = srvTexture(v, t->depthProxy, b);
				} else tex = srvTexture(v, t, b);
				if (tex) { t->lastUse = R->serial; if (t->floatNoFilter && b.pairedSampler >= 0) texFloatNoFilterSamplers |= 1u << b.pairedSampler; }
				if (tex && !t->written && gUninitTrace > 0)		// GTA-77 (PG_MR_UNINIT=1): a texture read before anything wrote it
					logOnce("uninit" + std::to_string(t->oid), "Metal renderer [uninit]: texture %u (%ux%u, DXGI %u, bind %#x) read by %s before anything wrote it",
					        t->oid, t->width, t->height, t->dxgi, t->bind, info->label.c_str());
			}
			setTexture(stage, tex ?: dummyTexture(b.kind, b.dim, b.sample), b.index);
		}
		}
	}
	for (const ResBinding &b : info->res) {
		if (b.kind != RSampler) continue;
		uint32_t slot = (b.binding - 16) & 15;
		State *s = state(R->smp[stage][slot]);
		id<MTLSamplerState> st = nil;
		if (s && s->sampler && (((s->words[0] & 0x80) != 0) == b.compare)) st = (texFloatNoFilterSamplers >> slot) & 1 ? s->samplerNearest : s->sampler;
		setSampler(stage, st ?: (b.compare ? R->dummyCompare : R->dummySampler), b.index);
	}
	if (info->immediate) {
		uint32_t block[4 + 32] = {};
		uint32_t n = 0;
		for (auto &al : info->arrayLengths) n = std::max(n, al.second + 1);
		for (uint32_t i = 0; i < n && i < 32; i++) block[4 + i] = sizes[i];
		NSUInteger bytes = (16 + n * 4 + 15) & ~15u;
		if (stage == 0) [R->pass setVertexBytes:block length:bytes atIndex:kImmediateBuffer];
		else if (stage == 1) [R->pass setFragmentBytes:block length:bytes atIndex:kImmediateBuffer];
		else [R->compute setBytes:block length:bytes atIndex:kImmediateBuffer];
		R->cache[stage].buffers[kImmediateBuffer] = nil;
	}
	return true;
}

// ---- draw ---------------------------------------------------------------------------------------------------------------
static void applyDynamicState() {
	const PassInfo &pi = R->passInfo;
	if (R->rsId != R->appliedRs) {
		State *rs = state(R->rsId);
		if (rs && rs->words.size() >= 8) {
			const uint32_t *w = rs->words.data();
			[R->pass setCullMode:w[1] == 2 ? MTLCullModeFront : w[1] == 3 ? MTLCullModeBack : MTLCullModeNone];
			[R->pass setFrontFacingWinding:w[2] ? MTLWindingCounterClockwise : MTLWindingClockwise];
			[R->pass setDepthBias:(float)(int32_t)w[3] slopeScale:wordFloat(w[5]) clamp:wordFloat(w[4])];
			[R->pass setDepthClipMode:w[6] ? MTLDepthClipModeClip : MTLDepthClipModeClamp];
			[R->pass setTriangleFillMode:w[0] == 2 ? MTLTriangleFillModeLines : MTLTriangleFillModeFill];
		} else {
			[R->pass setCullMode:MTLCullModeBack]; [R->pass setFrontFacingWinding:MTLWindingClockwise];
			[R->pass setDepthBias:0 slopeScale:0 clamp:0]; [R->pass setDepthClipMode:MTLDepthClipModeClip]; [R->pass setTriangleFillMode:MTLTriangleFillModeFill];
		}
		R->appliedRs = R->rsId;
		R->appliedScissor.x = UINT32_MAX;
	}
	id<MTLDepthStencilState> dss = depthStencilState();
	if (dss != R->appliedDss) { [R->pass setDepthStencilState:dss]; R->appliedDss = dss; }
	if (R->dssRef != R->appliedRef) { [R->pass setStencilReferenceValue:R->dssRef]; R->appliedRef = R->dssRef; }
	if (memcmp(R->blendFactor, R->appliedBlend, sizeof R->blendFactor)) {
		[R->pass setBlendColorRed:R->blendFactor[0] green:R->blendFactor[1] blue:R->blendFactor[2] alpha:R->blendFactor[3]];
		memcpy(R->appliedBlend, R->blendFactor, sizeof R->blendFactor);
	}
	if (R->hasViewport && (!R->viewportApplied || memcmp(R->viewport, R->appliedViewport, sizeof R->viewport))) {
		MTLViewport v = {R->viewport[0], R->viewport[1], std::max(1.0f, R->viewport[2]), std::max(1.0f, R->viewport[3]), R->viewport[4], R->viewport[5]};
		[R->pass setViewport:v];
		memcpy(R->appliedViewport, R->viewport, sizeof R->viewport);
		R->viewportApplied = true;
	} else if (!R->hasViewport && !R->viewportApplied) {
		[R->pass setViewport:(MTLViewport){0, 0, (double)pi.width, (double)pi.height, 0, 1}];
		R->viewportApplied = true;
		memset(R->appliedViewport, 0, sizeof R->appliedViewport);
	}
	State *rs = state(R->rsId);
	MTLScissorRect sc = {0, 0, pi.width, pi.height};
	if (rs && rs->words.size() >= 8 && rs->words[7] && R->hasScissor) {
		uint32_t x0 = std::min(pi.width, R->scissor[0]), y0 = std::min(pi.height, R->scissor[1]);
		uint32_t x1 = std::min(pi.width, std::max(x0, R->scissor[2])), y1 = std::min(pi.height, std::max(y0, R->scissor[3]));
		sc = {x0, y0, x1 - x0, y1 - y0};
	}
	if (sc.x != R->appliedScissor.x || sc.y != R->appliedScissor.y || sc.width != R->appliedScissor.width || sc.height != R->appliedScissor.height) {
		[R->pass setScissorRect:sc];
		R->appliedScissor = sc;
	}
}

#if MR_TRACE
static std::string traceTex(uint32_t id) {
	Texture *t = texture(id);
	if (!t) return std::to_string(id) + "(none)";
	char b[160];
	snprintf(b, sizeof b, "%u[dxgi%u fmt%lu %ux%ux%u mips%u s%u bind%#x%s%s]", id, t->dxgi, (unsigned long)t->format, t->width, t->height, t->depthOrLayers, t->mips, t->samples, t->bind,
	         t->alphaView ? " alphaView" : "", t->bcKind ? " bc" : "");
	return b;
}
static std::string traceWords(uint32_t id) {
	State *s = state(id);
	if (!s) return "-";
	std::string o = std::to_string(id) + "{";
	for (size_t i = 0; i < s->words.size() && i < 20; i++) o += (i ? "," : "") + std::to_string(s->words[i]);
	return o + "}";
}
static void traceDraw(const uint32_t *p, Shader *vs, Shader *ps, Layout *lay, const char *outcome) {
	if (T.state != 2) return;
	T.n++;
	std::string rts;
	for (int i = 0; i < 8; i++) if (R->rt[i].tex) {
		rts += " rt" + std::to_string(i) + "=" + traceTex(R->rt[i].tex) + "/v" + std::to_string(R->rt[i].fmt) + "m" + std::to_string(R->rt[i].mip);
		if (std::find(T.rts.begin(), T.rts.end(), R->rt[i].tex) == T.rts.end()) T.rts.push_back(R->rt[i].tex);
	}
	if (R->ds.tex) rts += " ds=" + traceTex(R->ds.tex) + "/f" + std::to_string(R->ds.flags);
	std::string tex;
	for (int st = 0; st < 2; st++) {
		Shader *sh = st ? ps : vs;
		if (!sh || !sh->info) continue;
		for (const ResBinding &b : sh->info->res) {
			if (b.kind == RUbo || b.kind == RSampler || b.kind == RStorageRO || b.kind == RStorageRW) continue;
			View *v = view(R->srv[st][(b.binding - 32) & 127], OSrv);
			tex += std::string(st ? " ps" : " vs") + "t" + std::to_string(b.binding - 32) + "=" + (v ? (v->isBuf ? "buf" : traceTex(v->res) + "/v" + std::to_string(v->fmt)) : "null");
		}
		for (const ResBinding &b : sh->info->res) if (b.kind == RSampler) tex += std::string(st ? " ps" : " vs") + "s" + std::to_string(b.binding - 16) + "=" + traceWords(R->smp[st][(b.binding - 16) & 15]);
	}
	std::string vbs;
	if (lay) {
		for (auto &e : lay->els) vbs += " el(" + std::to_string(e.sem) + ":" + std::to_string(e.idx) + " f" + std::to_string(e.fmt) + " s" + std::to_string(e.slot) + " o" + std::to_string(e.offset) + ")";
		for (auto &s : lay->slots) vbs += " vb" + std::to_string(s.first) + "=" + std::to_string(R->vb[s.first].buf) + "/" + std::to_string(R->vb[s.first].stride);
	}
	if (vs) for (auto &s : vs->sig) vbs += " sig(" + std::to_string(s.sem) + ":" + std::to_string(s.idx) + "->" + std::to_string(s.reg) + ")";
	// small non-indexed draws (blits, UI quads): the vertices and the pixel shader's constant buffers
	if (p[0] == 0 && p[1] <= 6 && lay && !lay->slots.empty()) {
		auto &v = R->vb[lay->slots[0].first];
		Buffer *b = buffer(v.buf);
		if (b && b->buf && v.stride && v.stride <= 64) {
			char t[64];
			for (uint32_t i = 0; i < p[1]; i++) {
				uint64_t off = v.offset + (uint64_t)(p[3] + i) * v.stride;
				if (off + v.stride > b->bytes) break;
				const float *f = (const float *)((const uint8_t *)b->buf.contents + b->base + off);
				vbs += " v" + std::to_string(i) + "(";
				for (uint32_t k = 0; k < v.stride / 4; k++) { snprintf(t, sizeof t, "%s%.3g", k ? "," : "", f[k]); vbs += t; }
				vbs += ")";
			}
		}
		{		// the vertex stage's b1 (RAGE's transform block, rows 8..11 = world-view-projection), bound or not
			const auto &c = R->cb[0][1];
			Buffer *cb = buffer(c.buf);
			char t[64];
			if (cb && !cb->shadow.empty()) {
				vbs += " vscb1[";
				for (uint32_t k = 32; k < 48 && c.first * 16 + k * 4 + 4 <= cb->shadow.size(); k++) { float fv; memcpy(&fv, cb->shadow.data() + c.first * 16 + k * 4, 4); snprintf(t, sizeof t, "%s%.3g", k > 32 ? "," : "", fv); vbs += t; }
				vbs += "]";
			}
			snprintf(t, sizeof t, " vs%u ps%u", R->shader[0], R->shader[1]);
			vbs += t;
		}
		if (ps && ps->info) for (const ResBinding &rb : ps->info->res) if (rb.kind == RUbo && rb.binding != 15) {
			const auto &c = R->cb[1][rb.binding & 15];
			Buffer *cb = buffer(c.buf);
			if (!cb || cb->shadow.empty()) continue;
			char t[64];
			vbs += " cb" + std::to_string(rb.binding) + "[";
			for (uint32_t k = 0; k < rb.size / 4 && c.first * 16 + k * 4 + 4 <= cb->shadow.size() && k < 64; k++) { float fv; memcpy(&fv, cb->shadow.data() + c.first * 16 + k * 4, 4); snprintf(t, sizeof t, "%s%.3g", k ? "," : "", fv); vbs += t; }
			vbs += "]";
		}
	}
	tracef("D%llu %s | %s + %s | k%u c%u i%u st%u bv%d topo%u |%s | blend=%s bf=%.2f,%.2f,%.2f,%.2f mask=%#x | dss=%s ref%u | rs=%s | vp=%.0f,%.0f,%.0f,%.0f sc%d=%u,%u,%u,%u |%s |%s",
	       (unsigned long long)T.n, outcome, vs && vs->info ? vs->info->label.c_str() : (vs ? vs->hash.c_str() : "-"), ps && ps->info ? ps->info->label.c_str() : (ps ? ps->hash.c_str() : "-"),
	       p[0], p[1], p[2], p[3], (int32_t)p[4], R->topo, rts.c_str(), traceWords(R->blendId).c_str(), R->blendFactor[0], R->blendFactor[1], R->blendFactor[2], R->blendFactor[3], R->blendMask,
	       traceWords(R->dssId).c_str(), R->dssRef, traceWords(R->rsId).c_str(), R->viewport[0], R->viewport[1], R->viewport[2], R->viewport[3], R->hasScissor,
	       R->scissor[0], R->scissor[1], R->scissor[2], R->scissor[3], tex.c_str(), vbs.c_str());
}
#else
static inline void traceDraw(const uint32_t *, Shader *, Shader *, Layout *, const char *) {}
#endif

static void capture(Texture *t, const std::string &name, id<MTLRenderPipelineState> pipe = nil, id<MTLTexture> second = nil);
static void drawInner(const uint32_t *p);
static const char *drawOutcome;
// GTA-77 test shots: what each pictured frame drew, by program (Documents/NativeFrames/<folder>/<name>.txt next to the
// picture): draws, vertices (count x instances) and skipped draws with their reason. Kept only while shots are queued.
struct CensusRow { uint64_t draws = 0, verts = 0, skipped = 0; std::string reasons; };
static std::atomic<bool> gCensusOn{false};
static std::map<std::string, CensusRow> gCensus;
static Pipe *gDrawPipe;
static void draw(const uint32_t *p) {
	drawOutcome = "ok";
	gDrawPipe = nullptr;
	drawInner(p);
	if (gCensusOn.load(std::memory_order_relaxed)) {
		std::string key = gDrawPipe ? gDrawPipe->label : std::string("(") + drawOutcome + ")";
		key += R->topo == 5 ? " [strip]" : R->topo == 4 ? "" : " [topo " + std::to_string(R->topo) + "]";
		CensusRow &c = gCensus[key];
		if (!strncmp(drawOutcome, "ok", 2)) { c.draws++; c.verts += p[0] >= 4 ? 0 : (uint64_t)p[1] * std::max(1u, p[2]); }
		else { c.skipped++; if (c.reasons.find(drawOutcome) == std::string::npos) c.reasons += std::string(c.reasons.empty() ? "" : ",") + drawOutcome; }
	}
#if MR_TRACE
	if (T.state == 2) {
		traceDraw(p, R->objs.as<Shader>(R->shader[0], OShader), R->objs.as<Shader>(R->shader[1], OShader), R->objs.as<Layout>(R->layout, OLayout), drawOutcome);
		// targets around alpha-only writes (masks): the colour target's alpha and the depth/stencil buffer
		State *bs = state(R->blendId);
		if (bs && bs->words.size() >= 10 && (bs->words[9] & 0xf) == 8 && T.snaps < 8 && T.alphaPipe) {
			T.snaps++;
			endEncoders();
			std::string tag = "trace-D" + std::to_string(T.n);
			capture(texture(R->rt[0].tex), tag + "-alpha-rt" + std::to_string(R->rt[0].tex), T.alphaPipe);
			for (int slot = 0; slot < 16; slot++) {		// the textures the pixel shader reads (colour and alpha)
				View *v = view(R->srv[1][slot], OSrv);
				Texture *st = v && !v->isBuf ? texture(v->res) : nullptr;
				if (!st || !st->tex || st->isDepth || st->samples > 1 || st->tex.textureType != MTLTextureType2D) continue;
				capture(st, tag + "-t" + std::to_string(slot) + "-tex" + std::to_string(v->res));
				capture(st, tag + "-t" + std::to_string(slot) + "-tex" + std::to_string(v->res) + "-alpha", T.alphaPipe);
			}
			Texture *dt = texture(R->ds.tex);
			if (dt && dt->tex && dt->hasStencil && dt->samples == 1) {
				id<MTLTexture> st = [dt->tex newTextureViewWithPixelFormat:MTLPixelFormatX32_Stencil8];
				capture(dt, tag + "-ds" + std::to_string(R->ds.tex), T.dsPipe, st);
			}
		}
	}
#endif
}
// ---- game-side workaround: the minimap (radar) alpha mask ------------------------------------------------------------
// The minimap is drawn into a screen-sized target of its own and then blended over the frame with that target's alpha
// (im::PS_Blit, SRC_ALPHA / INV_SRC_ALPHA). The alpha comes from a mask pass: the target's alpha is cleared to 0, then the
// radar mask texture (a soft-edged rounded rectangle, bound at t2) is blitted into the alpha over the minimap rectangle.
// The game issues that mask draw with the programs of the *next* pass of im.fxc's gtadrawblit technique (pass 15:
// VS_Blit + PS_BlitDepthToAlpha) while its data is for pass 14 (VS_GTABlit + PS_BlitToAlpha): the vertices are in 0..1
// screen space for the ortho transform in the vertex stage's b1, the b5 constants are BlitToAlpha's (the mask's texel size,
// a channel selector, an output range) and BlitDepthToAlpha's depth texture (t5) is never bound. Executed as issued (the
// web build's WebGPU renderer does the same), the quad lands in the top half of the screen and samples whatever t5 held,
// the minimap's alpha stays 0 and only the blips show. The draw is run with the programs its data was made for:
// im::VS_TransformUnlit_IM (the b1-transforming blit vertex shader, same code as VS_GTABlit) + im::PS_BlitToAlpha.
// Only when nothing depth-like is bound at t5, so a real depth-to-alpha blit (if the game ever issues one) is untouched.
struct MaskPrograms { ShaderInfo *blitVs, *depthToAlpha, *transformVs, *toAlpha; bool looked; };
static MaskPrograms maskPrograms = {};
static Shader *gameShaderFor(ShaderInfo *info) {
	auto it = info ? R->shaderObjects.find(info) : R->shaderObjects.end();
	if (it == R->shaderObjects.end()) return nullptr;
	Shader *s = R->objs.as<Shader>(it->second, OShader);
	if (!s || s->info != info) { R->shaderObjects.erase(it); return nullptr; }
	return s;
}
static bool minimapMaskSwap(Shader *&vs, Shader *&ps) {
	MaskPrograms &m = maskPrograms;
	if (!m.looked) {
		m.looked = true;
		m.blitVs = findShader("4e1d5d361e0ed0bc");		// im::VS_Blit
		m.depthToAlpha = findShader("7f531ca66548aefe");	// im::PS_BlitDepthToAlpha
		m.transformVs = findShader("028921879df627f5");	// im::VS_TransformUnlit_IM
		m.toAlpha = findShader("bc10d4d035fb7863");		// im::PS_BlitToAlpha
		if (!m.blitVs || !m.depthToAlpha || !m.transformVs || !m.toAlpha) logf("Metal renderer: minimap mask programs not in the shader library (the minimap may stay blank)");
#if MR_TRACE
		if (getenv("PG_MR_NO_MASK_FIX")) { m.depthToAlpha = nullptr; logf("Metal renderer [trace]: minimap mask fix disabled"); }		// before/after comparisons
#endif
	}
	if (!ps || ps->info != m.depthToAlpha || vs->info != m.blitVs || !m.depthToAlpha) return false;
	View *v = view(R->srv[1][5], OSrv);
	Texture *t = v && !v->isBuf ? texture(v->res) : nullptr;
	if (t && t->isDepth) return false;
	Shader *tvs = gameShaderFor(m.transformVs), *tps = gameShaderFor(m.toAlpha);
	if (!tvs || !tps) { logOnce("maskswap", "Metal renderer: minimap mask programs were not created by the game"); return false; }
	vs = tvs; ps = tps;
	return true;
}

// ---- game-data workaround: stray vertices in ped models (GTA-78) ------------------------------------------------------
// Some of the game's ped clothing models have a vertex far from where it belongs: g_m_y_famca_01's letterman jacket
// (torso drawable 0) has vertex 449 0.85 m below its neighbours, which share its bones and weights. Drawn as is, it pulls
// its triangles into a long spike out of the jacket, standing or lying dead. On the PC the HD ped models ("+hi") replace
// these near the camera; the game files here have none ("Ped HD assets for 'G_M_Y_FamCA_01+hi' not found"), so the
// standard model is drawn up close too. The engine's own copy of the model holds the same vertex, so it is the data, not
// the skinning or the shader translation: CPU skinning of the draw lands it at the spike's pixels.
// The first time a ped model's index range is drawn with a bone-skinned ped shader (b4: 255 bones), each vertex is
// compared with the vertices it shares a triangle with. A vertex is moved to the middle of its neighbours when all of
// them are more than 0.5 m away from it, they lie within 0.4 times that distance of each other, and one of them has
// the same main bone. No real part of a ped's mesh looks like that (a strap or hair card has a near neighbour along
// its length); across 54 ped models in two outfits each, only that jacket vertex matched. Only the GPU copy changes.
// PG_PED_SPIKE_FIX=0 draws the models as they are.
static void fixPedSpikes(Shader *vs, Layout *lay, const uint32_t *p) {
	static int on = -1;
	if (on < 0) on = !(getenv("PG_PED_SPIKE_FIX") && !strcmp(getenv("PG_PED_SPIKE_FIX"), "0"));
	if (!on || !vs || !vs->info || !lay || p[0] >= 4 || !(p[0] & 1) || R->topo != 4) return;		// indexed triangle lists only
	if (vs->info->label.find("Ped") == std::string::npos) return;
	bool bones = false, cloth = false;
	for (auto &b : vs->info->res) if (b.kind == RUbo) { bones |= b.binding == 4 && b.size == 12240; cloth |= b.binding == 11 && b.size == 4128; }
	if (!bones || cloth) return;		// cloth models place their simulated vertices from b11, not from these positions
	const LayoutEl *pe = nullptr, *ie = nullptr, *we = nullptr;
	for (auto &e : lay->els) {
		if (e.idx) continue;
		if (e.sem == 2013849738u) pe = &e;		// POSITION (FNV-1a of the semantic name)
		else if (e.sem == 307084293u) ie = &e;		// BLENDINDICES
		else if (e.sem == 3650812920u) we = &e;		// BLENDWEIGHT
	}
	if (!pe || !ie || !we || pe->fmt != 6 || pe->slot != ie->slot || pe->slot != we->slot) return;
	const auto &v = R->vb[pe->slot];
	Buffer *vb = buffer(v.buf), *ib = buffer(R->ib.buf);
	if (!vb || !vb->buf || !ib || !ib->buf || !v.stride) return;
	const uint32_t count = p[1], start = p[3];
	const int32_t baseVertex = (int32_t)p[4];
	static std::unordered_set<uint64_t> checked;
	uint64_t key = fnv(fnv(fnv(fnv(fnv(fnv(1469598103934665603ull, v.buf), gMeshWrites[v.buf]), R->ib.buf), gMeshWrites[R->ib.buf]), R->ib.offset + (uint64_t)start * (R->ib.fmt == 57 ? 2 : 4)), count);
	key = fnv(fnv(key, (uint32_t)baseVertex), v.offset);
	if (checked.size() > 200000) checked.clear();
	if (!checked.insert(key).second) return;
	const uint32_t isz = R->ib.fmt == 57 ? 2 : 4;
	if (R->ib.offset + ((uint64_t)start + count) * isz > ib->bytes) return;
	const uint8_t *indices = (const uint8_t *)ib->buf.contents + ib->base + R->ib.offset + (size_t)start * isz;
	uint8_t *verts = (uint8_t *)vb->buf.contents + vb->base + v.offset;
	const uint64_t avail = vb->bytes > v.offset ? vb->bytes - v.offset : 0;
	auto vertexAt = [&](uint32_t i) -> int64_t {
		int64_t x = (int64_t)(isz == 2 ? ((const uint16_t *)indices)[i] : ((const uint32_t *)indices)[i]) + baseVertex;
		return x >= 0 && (uint64_t)x * v.stride + pe->offset + 12 <= avail && (uint64_t)x * v.stride + std::max(ie->offset, we->offset) + 4 <= avail ? x : -1;
	};
	auto pos = [&](uint32_t x) { return (float *)(verts + (size_t)x * v.stride + pe->offset); };
	auto mainBone = [&](uint32_t x) {
		const uint8_t *w = verts + (size_t)x * v.stride + we->offset, *b = verts + (size_t)x * v.stride + ie->offset;
		int best = 0;
		for (int k = 1; k < 4; k++) if (w[k] > w[best]) best = k;
		return b[best];		// UNORM8 x4 or BGRA: the same byte holds a weight and its bone
	};
	if ((ie->fmt != 28 && ie->fmt != 87) || we->fmt != ie->fmt) return;
	std::unordered_map<uint32_t, std::vector<uint32_t>> nbrs;
	for (uint32_t t = 0; t + 2 < count; t += 3) {
		int64_t a = vertexAt(t), b = vertexAt(t + 1), c = vertexAt(t + 2);
		if (a < 0 || b < 0 || c < 0) return;
		uint32_t tri[3] = {(uint32_t)a, (uint32_t)b, (uint32_t)c};
		for (int k = 0; k < 3; k++) for (int j = 1; j < 3; j++) {
			auto &n = nbrs[tri[k]];
			uint32_t o = tri[(k + j) % 3];
			if (o != tri[k] && std::find(n.begin(), n.end(), o) == n.end()) n.push_back(o);
		}
	}
	auto dist = [](const float *a, const float *b) { float x = a[0] - b[0], y = a[1] - b[1], z = a[2] - b[2]; return std::sqrt(x * x + y * y + z * z); };
	std::vector<std::pair<uint32_t, std::array<float, 3>>> moves;
	for (auto &kv : nbrs) {
		const std::vector<uint32_t> &n = kv.second;
		if (n.size() < 2) continue;
		const float *me = pos(kv.first);
		float nearest = 1e30f, spread = 0;
		bool sameBone = false;
		const uint8_t bone = mainBone(kv.first);
		for (size_t i = 0; i < n.size(); i++) {
			nearest = std::min(nearest, dist(me, pos(n[i])));
			sameBone |= mainBone(n[i]) == bone;
			for (size_t j = i + 1; j < n.size(); j++) spread = std::max(spread, dist(pos(n[i]), pos(n[j])));
		}
		if (!(nearest > 0.5f) || !(spread < 0.4f * nearest) || !sameBone || !(nearest < 100.0f)) continue;
		std::array<float, 3> mid = {0, 0, 0};
		for (uint32_t o : n) for (int k = 0; k < 3; k++) mid[k] += pos(o)[k] / n.size();
		moves.push_back({kv.first, mid});
	}
	for (auto &m : moves) {
		float *q = pos(m.first);
		logf("Metal renderer: ped model (%s, vertex buffer %u): vertex %u was %.2f m from the vertices it shares triangles with, which all lie close together; moved to them (GTA-78)",
		     vs->info->label.c_str(), v.buf, m.first, dist(q, m.second.data()));
		memcpy(q, m.second.data(), 12);
	}
}

// A non-indexed strip whose vertices repeat a position (strips joined by repeated vertices): its list without the
// triangles that have no area, in the frame ring. 0 when no triangle repeats a position (or the positions can't be
// read: no per-vertex POSITION, or a strip too long to check), so the shared pattern draws it.
static uint32_t stripPositions(Layout *lay, uint32_t start, uint32_t count, Alloc &out) {
	if (!lay || count > 4096) return 0;
	const LayoutEl *pe = nullptr;
	for (auto &e : lay->els) if (e.sem == 2013849738u && !e.idx && e.cls == 0) { pe = &e; break; }		// POSITION (FNV-1a of the name)
	uint32_t bytes = 0;
	if (!pe || pe->slot >= 16 || vertexFormat(pe->fmt, &bytes) == MTLVertexFormatInvalid) return 0;
	const auto &v = R->vb[pe->slot];
	Buffer *vb = buffer(v.buf);
	if (!vb || !vb->buf || !v.stride || (vb->bind & BIND_UAV)) return 0;
	if ((uint64_t)v.offset + ((uint64_t)start + count - 1) * v.stride + pe->offset + bytes > vb->bytes) return 0;
	const uint8_t *p = (const uint8_t *)vb->buf.contents + vb->base + v.offset + (size_t)start * v.stride + pe->offset;
	auto same = [&](uint32_t a, uint32_t b) { return !memcmp(p + (size_t)a * v.stride, p + (size_t)b * v.stride, bytes); };
	uint32_t first = UINT32_MAX;
	for (uint32_t k = 0; k + 2 < count && first == UINT32_MAX; k++) if (same(k, k + 1) || same(k + 1, k + 2) || same(k, k + 2)) first = k;
	if (first == UINT32_MAX) return 0;
	const bool wide = count - 1 >= 0xffff;
	out = frameAlloc((size_t)(count - 2) * 3 * (wide ? 4 : 2), 16);
	uint32_t n = 0;
	for (uint32_t k = 0; k + 2 < count; k++) {
		if (k >= first && (same(k, k + 1) || same(k + 1, k + 2) || same(k, k + 2))) { gFix.degenerate++; continue; }
		const uint32_t t[3] = {k, k & 1 ? k + 2 : k + 1, k & 1 ? k + 1 : k + 2};
		for (int j = 0; j < 3; j++) { if (wide) ((uint32_t *)out.ptr)[n++] = t[j]; else ((uint16_t *)out.ptr)[n++] = (uint16_t)t[j]; }
	}
	return n ? n : UINT32_MAX;		// UINT32_MAX: every triangle repeats a position
}

// GTA-77: a triangle strip draw as an indexed triangle list. False: draw it as a strip (no memory for the list).
static bool drawStripAsList(bool indexed, Buffer *ib, uint32_t isz, uint32_t start, uint64_t count, uint64_t inst, int32_t baseVertex,
                            bool foldV, uint32_t vFirst, uint32_t iFirst, Layout *lay) {
	if (!indexed) {		// vertices 0..count-1 from the draw's first vertex: one shared list, or this strip's own without repeats
		if (count < 3) return true;		// no triangle
		const int wide = count - 1 >= 0xffff;
		const uint32_t tris = (uint32_t)(count - 2);
		Alloc own{};
		const double t0 = nowMs();
		const uint32_t n = stripPositions(lay, start, (uint32_t)count, own);
		gFix.convertMs += nowMs() - t0;
		gFix.stripTris += tris;
		if (n == UINT32_MAX) return true;		// nothing with an area
		if (n) {
			gFix.listTris += n / 3; gFix.converts++; gFix.dynamicConverts++;
			[R->pass drawIndexedPrimitives:MTLPrimitiveTypeTriangle indexCount:n indexType:wide ? MTLIndexTypeUInt32 : MTLIndexTypeUInt16
			                  indexBuffer:own.buf indexBufferOffset:own.off instanceCount:inst baseVertex:vFirst baseInstance:iFirst];
			return true;
		}
		if (!stripPattern(wide, tris)) return false;
		[R->pass drawIndexedPrimitives:MTLPrimitiveTypeTriangle indexCount:(NSUInteger)tris * 3 indexType:wide ? MTLIndexTypeUInt32 : MTLIndexTypeUInt16
		                  indexBuffer:gStripPattern[wide] indexBufferOffset:0 instanceCount:inst baseVertex:vFirst baseInstance:iFirst];
		gFix.listTris += tris;
		return true;
	}
	if (ib->bind & BIND_UAV) return false;		// the GPU may write it: the CPU copy can't be trusted
	const uint32_t ibId = R->ib.buf, version = gMeshWrites[ibId];
	const uint64_t at = (uint64_t)R->ib.offset + (uint64_t)start * isz;
	const uint64_t key = fnv(fnv(fnv(fnv(1469598103934665603ull, ibId), at), count), isz);
	const bool dynamic = gStripDynamic.count(ibId) != 0;
	id<MTLBuffer> buf = nil; NSUInteger off = 0; uint32_t n = 0;
	StripList *e = nullptr;
	if (!dynamic) {
		auto it = gStripCache.find(key);
		if (it != gStripCache.end() && it->second.version == version) { e = &it->second; gFix.hits++; }
	}
	if (e) { buf = e->buf; off = e->off; n = e->indices; e->lastFrame = std::max<uint64_t>(1, R->frame); }
	else {
		const double t0 = nowMs();
		static std::vector<uint8_t> scratch;
		if (scratch.size() < count * 3 * isz) scratch.resize(count * 3 * isz);
		const uint8_t *src = (const uint8_t *)ib->buf.contents + ib->base + at;
		uint64_t degenerate = 0, restarts = 0;
		n = isz == 2 ? stripToList((const uint16_t *)src, (uint32_t)count, (uint16_t *)scratch.data(), degenerate, restarts)
		             : stripToList((const uint32_t *)src, (uint32_t)count, (uint32_t *)scratch.data(), degenerate, restarts);
		gFix.degenerate += degenerate; gFix.restarts += restarts; gFix.converts++;
		const uint32_t bytes = n * isz;
		bool perDraw = dynamic;
		if (!dynamic) {
			auto found = gStripCache.find(key);
			if (found == gStripCache.end()) { found = gStripCache.emplace(key, StripList()).first; gStripCacheKeys[ibId].push_back(key); }
			StripList &s = found->second;
			if (s.lastFrame) {		// converted before, and the buffer was written since
				stripFree(s);
				if (++s.rebuilds >= 3) { stripForgetBuffer(ibId); gStripDynamic.insert(ibId); perDraw = true; }		// again and again: per draw from now on
			}
			if (!perDraw) {
				s.version = version; s.indices = n; s.lastFrame = std::max<uint64_t>(1, R->frame);
				if (n) {
					if (!stripAlloc(s, bytes)) { gFix.convertMs += nowMs() - t0; return false; }
					memcpy((uint8_t *)s.buf.contents + s.off, scratch.data(), bytes);
					buf = s.buf; off = s.off;
				}
			}
		}
		if (perDraw) {
			if (n) { Alloc a = frameAlloc(bytes, 16); memcpy(a.ptr, scratch.data(), bytes); buf = a.buf; off = a.off; }
			gFix.dynamicConverts++;
		}
		gFix.convertMs += nowMs() - t0;
	}
	gFix.stripTris += count >= 3 ? count - 2 : 0; gFix.listTris += n / 3;
	if (!n) return true;		// every triangle repeats an index (or the strip is empty): nothing to draw, as before
	[R->pass drawIndexedPrimitives:MTLPrimitiveTypeTriangle indexCount:n indexType:isz == 2 ? MTLIndexTypeUInt16 : MTLIndexTypeUInt32 indexBuffer:buf
	              indexBufferOffset:off instanceCount:inst baseVertex:foldV ? 0 : baseVertex baseInstance:iFirst];
	return true;
}

static void drawInner(const uint32_t *p) {
	uint32_t kind = p[0], count = p[1], inst = p[2], start = p[3], startInstance = p[5];
	int32_t baseVertex = (int32_t)p[4];
	Shader *vs = R->objs.as<Shader>(R->shader[0], OShader);
	Shader *ps = R->objs.as<Shader>(R->shader[1], OShader);
	Layout *lay = R->objs.as<Layout>(R->layout, OLayout);
	if (!vs || !vs->info || !lay || (ps && !ps->info)) { drawOutcome = "SKIP-shader"; R->skipped++; R->skipReasons[(!vs || !lay) ? 0 : 1]++; return; }
	bool maskSwap = minimapMaskSwap(vs, ps);
	if (maskSwap != R->lastMaskSwap) { R->lastMaskSwap = maskSwap; R->pipeDirty = true; }
	if (maskSwap) drawOutcome = "ok-maskswap";
	prepareProxies(vs->info, 0);
	if (ps) prepareProxies(ps->info, 1);
	if (!ensurePass()) { drawOutcome = "SKIP-norT"; R->skipped++; R->skipReasons[2]++; return; }
	Pipe *pipe = R->lastPipe;
	if (R->pipeDirty || !pipe) {
		pipe = getPipeline(vs, ps, lay);
		R->lastPipe = pipe;
		R->pipeDirty = false;
	}
	gDrawPipe = pipe;
	// A pipeline still compiling: wait for it up to 8 ms per frame in all, so a prop isn't missing
	// for a few frames the first time it's seen; past the budget the draw is skipped as before.
	if (!pipe->ready.load(std::memory_order_acquire) && R->pipeWaitMs < 8) {
		double start = nowMs();
		while (!pipe->ready.load(std::memory_order_acquire) && R->pipeWaitMs + (nowMs() - start) < 8) usleep(250);
		R->pipeWaitMs += nowMs() - start;
	}
	// GTA-77 test switch PG_PIPE_WAIT_SMALL=1: a draw into a 32-bit float target or a small one (simulation and feedback
	// textures: the water simulation's 256x256 R32F maps, 1x1 exposure) waits for its pipeline instead of being skipped,
	// because a skipped step of a simulation stays wrong for the rest of the session.
	if (!pipe->ready.load(std::memory_order_acquire) && gPipeWaitSmall > 0 &&
	    ((R->passInfo.colorCount && isFloat32(R->passInfo.colors[0])) || (uint64_t)R->passInfo.width * R->passInfo.height <= 256 * 256)) {
		double start = nowMs();
		while (!pipe->ready.load(std::memory_order_acquire) && nowMs() - start < 3000) usleep(250);
		R->pipeWaitMs += nowMs() - start;
		logOnce("pwait" + pipe->label, "Metal renderer: waited %.0f ms for %s's pipeline (%ux%u target, PG_PIPE_WAIT_SMALL)", nowMs() - start, pipe->label.c_str(), R->passInfo.width, R->passInfo.height);
	}
	if (!pipe->ready.load(std::memory_order_acquire)) {
		drawOutcome = "SKIP-pending"; R->pendingSkips++; R->skipped++; R->pipeDirty = true;
		if (gUninitTrace > 0)		// GTA-77 (PG_MR_UNINIT=1): the first skip of each program while its pipeline compiles
			logOnce("pend" + pipe->label, "Metal renderer [startup]: %s skipped while its pipeline compiles (frame %llu, target %ux%u, format %lu)",
			        pipe->label.c_str(), (unsigned long long)R->frame, R->passInfo.width, R->passInfo.height, (unsigned long)(R->passInfo.colorCount ? R->passInfo.colors[0] : R->passInfo.depth));
		return;
	}
	if (!pipe->state) { drawOutcome = "SKIP-pipefail"; R->skipped++; R->skipReasons[3]++; return; }
	if (R->activeOcclusion) {
		R->activeOcclusion->draws++;
		// PG_OQ_TRACE=1 (GTA-176): the first 40 draws inside occlusion queries, to see why almost all count no sample.
		static int trace = -1, traced = 0;
		if (trace < 0) trace = getenv("PG_OQ_TRACE") && atoi(getenv("PG_OQ_TRACE"));
		if (trace && traced < 40) {
			traced++;
			State *ds = state(R->dssId); const uint32_t *w = ds && ds->words.size() >= 13 ? ds->words.data() : nullptr;
			logf("[metal] occlusion draw %d: query type %u slot %d, pass depth %u (read-only %d) %ux%u x%u samples, colors %u; depth test %u write %u func %u; stencil %u func %u ref %u mask %x",
			     traced, R->activeOcclusion->type, R->passSlot, (unsigned)R->passInfo.depth, R->passInfo.roDepth ? 1 : 0, R->passInfo.width, R->passInfo.height,
			     R->passInfo.samples, R->passInfo.colorCount, w ? w[0] : 0, w ? w[1] : 0, w ? w[2] : 0, w ? w[3] : 0, w ? w[5 + 3] : 0, R->dssRef, w ? w[4] : 0);
		}
	}
	// Test (GTA-77, every platform): PG_TEST_SKIP_PROGRAM=<part of a program name>:<frames> skips those draws until that
	// frame, as a pipeline still compiling on a cold shader cache does (e.g. waterTex::PS_WaterUpdate:1500).
	{
		static std::string skipName; static uint64_t skipUntil = 0; static bool parsed = false;
		if (!parsed) { parsed = true; if (const char *v = getenv("PG_TEST_SKIP_PROGRAM")) { std::string s = v; size_t c = s.rfind(':'); if (c != std::string::npos) { skipName = s.substr(0, c); skipUntil = strtoull(s.c_str() + c + 1, nullptr, 10); } } }
		if (!skipName.empty() && R->frame < skipUntil && pipe->label.find(skipName) != std::string::npos) {
			logOnce("testskip", "Metal renderer [test]: %s skipped until frame %llu (PG_TEST_SKIP_PROGRAM)", pipe->label.c_str(), (unsigned long long)skipUntil);
			drawOutcome = "SKIP-test"; R->skipped++; return;
		}
	}
#if MR_TRACE
	// Test (simulator, GTA-77): PG_TEST_WATER_NAN=x0,y0,w,h fills that region of the water height map the near water's
	// vertex shader reads (water::VS_WaterTess, vertex texture 0, R32F 256x256) with NaN before its first draw each
	// frame, to see what a broken water simulation looks like.
	static const char *waterNan = getenv("PG_TEST_WATER_NAN");
	static uint64_t waterNanFrame = UINT64_MAX;
	if (waterNan && waterNanFrame != R->frame && pipe->label.find("VS_WaterTess") != std::string::npos) {
		View *v = view(R->srv[0][0], OSrv);
		Texture *ht = v && !v->isBuf ? texture(v->res) : nullptr;
		unsigned x0 = 0, y0 = 0, w = 64, h = 64;
		sscanf(waterNan, "%u,%u,%u,%u", &x0, &y0, &w, &h);
		if (ht && ht->tex && ht->format == MTLPixelFormatR32Float && x0 + w <= ht->width && y0 + h <= ht->height) {
			waterNanFrame = R->frame;
			Alloc a = frameAlloc((size_t)w * h * 4, 16);
			for (size_t i = 0; i < (size_t)w * h; i++) ((uint32_t *)a.ptr)[i] = 0x7fc00000u;
			[blitEncoder() copyFromBuffer:a.buf sourceOffset:a.off sourceBytesPerRow:w * 4 sourceBytesPerImage:w * h * 4 sourceSize:MTLSizeMake(w, h, 1)
			                    toTexture:ht->tex destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(x0, y0, 0)];
			logOnce("waternan", "Metal renderer [test]: water height map %u (%ux%u) gets NaN at %u,%u %ux%u every frame", ht->oid, ht->width, ht->height, x0, y0, w, h);
			if (!ensurePass()) return;
			R->appliedPipe = nil; R->pipeDirty = true;
		}
	}
#endif
	if (pipe->state != R->appliedPipe) { [R->pass setRenderPipelineState:pipe->state]; R->appliedPipe = pipe->state; }
	applyDynamicState();
	fixPedSpikes(vs, lay, p);
	bindStage(0, vs->info);
	if (ps) bindStage(1, ps->info);
	if (pipe->zeroStream) setBuffer(0, R->zeroBuffer, 0, kZeroVertexBuffer);

	bool indexed = kind == 4 || (kind < 4 && (kind & 1));
	bool foldV = vs->info->vid, foldI = vs->info->iid;
	uint32_t vFirst = indexed || foldV ? 0 : start, iFirst = foldI ? 0 : startInstance;
	uint64_t avail[16] = {};
	for (auto &s : lay->slots) {
		uint32_t slot = s.first;
		const auto &v = R->vb[slot];
		Buffer *b = buffer(v.buf);
		if (!b || !b->buf) { setBuffer(0, R->zeroBuffer, 0, kVertexBufferTop - slot); avail[slot] = R->zeroBuffer.length; continue; }
		int64_t shift = s.second == 1 ? (foldI ? (int64_t)startInstance * v.stride : 0) : (foldV ? (int64_t)(indexed ? baseVertex : (int32_t)start) * v.stride : 0);
		int64_t off = (int64_t)v.offset + shift;
		if (off < 0) off = 0;
		if (off > b->bytes) off = b->bytes;
		setBuffer(0, b->buf, b->base + (NSUInteger)off, kVertexBufferTop - slot);
		avail[slot] = b->bytes - off;
		b->lastUse = R->serial;
	}
	MTLPrimitiveType type = primitiveType(R->topo);
	// GTA-77 statistics: strip draws, and draws into packed float targets (RG11B10, RGB9E5)
	const bool strip = R->topo == 5;
	if (strip) { gFix.stripDraws++; if (kind >= 4) gFix.stripIndirect++; else { if (indexed) gFix.stripIndexed++; if (inst > 1) gFix.stripInstanced++; } }
	if (R->passInfo.packedMask && ps) gFix.packedDraws++;
	if (gDrawStats > 0 && (strip || (R->passInfo.packedMask && ps))) {
		LabelStat &ls = gLabelStats[pipe->label];
		if (strip) { ls.strips++; if (indexed) ls.stripIndexed++; ls.stripVerts += kind >= 4 ? 0 : count; if (inst > 1) ls.stripInst++; }
		if (R->passInfo.packedMask && ps) ls.packed++;
	}
	if (kind >= 4) {
		Buffer *args = buffer(p[1]);
		if (!args || !args->buf) { R->skipped++; return; }
		args->lastUse = R->serial;
		if (strip) gFix.keptStrips++;		// indirect: the GPU holds the counts, so it stays a strip
		if (kind == 4) {
			Buffer *ib = buffer(R->ib.buf);
			if (!ib || !ib->buf) { R->skipped++; return; }
			ib->lastUse = R->serial;
			[R->pass drawIndexedPrimitives:type indexType:R->ib.fmt == 57 ? MTLIndexTypeUInt16 : MTLIndexTypeUInt32 indexBuffer:ib->buf indexBufferOffset:ib->base + R->ib.offset indirectBuffer:args->buf indirectBufferOffset:args->base + p[2]];
		} else [R->pass drawPrimitives:type indirectBuffer:args->buf indirectBufferOffset:args->base + p[2]];
		R->draws++;
		return;
	}
	// D3D11 reads zeros past the end of a vertex/index buffer; Metal would read out of bounds. The counts are clamped to
	// what the bound buffers hold (the elements dropped are the ones D3D would have fed zeros).
	uint64_t dCount = count, dInst = inst;
	for (auto &r : pipe->vbReq) {
		uint64_t a = avail[r.slot];
		uint64_t n = a < r.last ? 0 : (r.stride ? (a - r.last) / r.stride + 1 : UINT64_MAX);
		if (r.instance) { if (dInst + iFirst > n) dInst = n > iFirst ? n - iFirst : 0; }
		else if (!indexed && dCount + vFirst > n) dCount = n > vFirst ? n - vFirst : 0;
	}
	Buffer *ib = nullptr;
	uint32_t isz = R->ib.fmt == 57 ? 2 : 4;
	if (indexed) {
		ib = buffer(R->ib.buf);
		if (!ib || !ib->buf) { R->skipped++; return; }
		uint64_t ibMax = ib->bytes > R->ib.offset ? (ib->bytes - R->ib.offset) / isz : 0;
		ibMax = ibMax > start ? ibMax - start : 0;
		if (dCount > ibMax) dCount = ibMax;
		ib->lastUse = R->serial;
	}
	if (dCount != count || dInst != inst) {
		R->clamped++;
		if (!dCount || !dInst) { drawOutcome = "SKIP-clamp"; R->skipped++; R->skipReasons[4]++; return; }
	}
	if (!dCount || !dInst) return;
	if (strip && gStripLists.load(std::memory_order_relaxed)) {
		if (drawStripAsList(indexed, ib, isz, start, dCount, dInst, baseVertex, foldV, vFirst, iFirst, lay)) {
			gFix.asList++; drawOutcome = "ok-list";
			R->draws++; R->drawsInCmd++;
			return;
		}
		gFix.keptStrips++;
	} else if (strip) gFix.keptStrips++;
	if (indexed)
		[R->pass drawIndexedPrimitives:type indexCount:dCount indexType:isz == 2 ? MTLIndexTypeUInt16 : MTLIndexTypeUInt32 indexBuffer:ib->buf
		          indexBufferOffset:ib->base + R->ib.offset + (NSUInteger)start * isz instanceCount:dInst baseVertex:foldV ? 0 : baseVertex baseInstance:iFirst];
	else [R->pass drawPrimitives:type vertexStart:vFirst vertexCount:dCount instanceCount:dInst baseInstance:iFirst];
	R->draws++;
	R->drawsInCmd++;
}

// ---- compute ------------------------------------------------------------------------------------------------------------
static void dispatch(uint32_t x, uint32_t y, uint32_t z) {
	Shader *cs = R->objs.as<Shader>(R->shader[2], OShader);
	if (!cs || !cs->info) { R->skipped++; logOnce("nocs", "Metal renderer: dispatch without a compute shader"); return; }
	ShaderInfo *info = cs->info;
	ComputePipe &cp = R->computePipes[info->uid];
	if (!cp.state && !cp.failed) {
		id<MTLFunction> fn = shaderFunction(info);
		NSError *error = nil;
		cp.state = fn ? [R->device newComputePipelineStateWithFunction:fn error:&error] : nil;
		if (!cp.state) { cp.failed = true; logf("Metal renderer: compute pipeline failed (%s): %s", info->label.c_str(), error.localizedDescription.UTF8String ?: "no function"); }
	}
	if (!cp.state) { R->skipped++; return; }
	flushClears();
	prepareProxies(info, 2);
	if (!R->compute) {
		endEncoders();
		R->compute = [commandBuffer() computeCommandEncoder];
		R->cache[2].reset();
	}
	[R->compute setComputePipelineState:cp.state];
	for (size_t i = 0; i < info->wgMem.size(); i++) [R->compute setThreadgroupMemoryLength:(info->wgMem[i] + 15) & ~15u atIndex:i];
	bindStage(2, info);
	for (const ResBinding &b : info->res) if (b.kind == RStorageTex) {		// GTA-77 statistics: compute writes into packed float textures
		View *u = view(R->uav[2][(b.binding - 160) & 7], OUav);
		Texture *t = u && !u->isBuf ? texture(u->res) : nullptr;
		if (t && t->tex && packedFloat(t->format)) {
			gFix.packedDispatches++;
			if (gDrawStats > 0) gLabelStats["compute " + info->label].packed++;
			break;
		}
	}
	[R->compute dispatchThreadgroups:MTLSizeMake(x, y, z) threadsPerThreadgroup:MTLSizeMake(info->wg[0], info->wg[1], info->wg[2])];
}

// ---- copies -------------------------------------------------------------------------------------------------------------
// Blocks the GPU wrote into an uncompressed texture, copied into a compressed one (D3D allows it when a
// texel has a block's size: an RGBA16 texel is a BC1 block). The game compresses the pause menu's
// player headshot this way. Metal can't copy between those formats, so the texels go to a buffer,
// and once the GPU is done they are uploaded like any BC upload (native, ASTC or decoded) from the
// render thread at the next present.
struct BlockUpload { uint32_t tex, width, height; std::vector<uint32_t> packet; };
static std::mutex gBlockUploadsLock;
static std::vector<BlockUpload> gBlockUploads;
static void uploadTextureInner(const uint32_t *p);
static void flushBlockUploads() {
	std::vector<BlockUpload> list;
	{ std::lock_guard<std::mutex> g(gBlockUploadsLock); list.swap(gBlockUploads); }
	for (BlockUpload &u : list) {
		Texture *t = texture(u.tex);
		if (t && t->tex && t->width == u.width && t->height == u.height) uploadTextureInner(u.packet.data());		// still the same texture
	}
}
static bool copyTexelsAsBlocks(Texture *s, Texture *d, uint32_t dstId, uint32_t sLevel, uint32_t sLayer, uint32_t sx, uint32_t sy,
                               uint32_t dMip, uint32_t dLayer, uint32_t dx, uint32_t dy, uint32_t w, uint32_t h) {
	const uint32_t block = bcBlockBytes(d->bcKind);
	if (!d->bcKind || s->bcKind || s->isDepth || s->samples > 1 || s->dim == 3 || d->dim == 3 || bytesPerTexel(s->format) != block) return false;
	uint32_t dw, dh, dd; mipExtent(d, dMip, dw, dh, dd);
	w = std::min(w, (dw + 3) / 4 - std::min((dw + 3) / 4, dx / 4)); h = std::min(h, (dh + 3) / 4 - std::min((dh + 3) / 4, dy / 4));
	if (!w || !h) return true;
	const uint32_t bpr = w * block, bytes = bpr * h;
	id<MTLBuffer> buffer = [R->device newBufferWithLength:bytes options:MTLResourceStorageModeShared];
	if (!buffer) return true;
	[blitEncoder() copyFromTexture:s->tex sourceSlice:sLayer sourceLevel:sLevel sourceOrigin:MTLOriginMake(sx, sy, 0) sourceSize:MTLSizeMake(w, h, 1)
	                      toBuffer:buffer destinationOffset:0 destinationBytesPerRow:bpr destinationBytesPerImage:bytes];
	s->lastUse = R->serial;
	const uint32_t px = std::min(w * 4, dw - std::min(dw, dx)), py = std::min(h * 4, dh - std::min(dh, dy)), width = d->width, height = d->height;
	R->onComplete.push_back([=]() {
		BlockUpload u{dstId, width, height, std::vector<uint32_t>(12 + (bytes + 3) / 4)};
		uint32_t header[12] = {dstId, dMip, dLayer, dx, dy, 0, px, py, 1, bpr, 0, bytes};
		memcpy(u.packet.data(), header, sizeof header);
		memcpy(u.packet.data() + 12, buffer.contents, bytes);
		std::lock_guard<std::mutex> g(gBlockUploadsLock);
		gBlockUploads.push_back(std::move(u));
	});
	gTextureStats.bcCopies++;
	return true;
}
static void copyRegion(const uint32_t *p) {
	uint32_t dstId = p[0], dstSub = p[1], dx = p[2], dy = p[3], dz = p[4], srcId = p[5], srcSub = p[6], hasBox = p[7];
	uint32_t l = p[8], t = p[9], f = p[10], r = p[11], b = p[12], bk = p[13];
	Object *so = R->objs.get(srcId), *dobj = R->objs.get(dstId);
	if (!so || !dobj) return;
	if (so->kind == OBuffer && dobj->kind == OBuffer) {
		Buffer *s = (Buffer *)so, *d = (Buffer *)dobj;
		if (!s->buf || !d->buf) return;
		uint32_t sOff = hasBox ? l : 0, size = hasBox ? r - l : std::min(s->size, d->size);
		size = std::min(size, std::min(s->bytes - std::min(s->bytes, sOff), d->bytes - std::min(d->bytes, dx))) & ~3u;
		if (!size) return;
		// The GPU is about to change a mesh's Metal bytes: engine pages handed back with them go back first, with the bytes
		// they had (GTA-217: otherwise a later put-back would give the engine the copied bytes; seen once in a
		// simulator benchmark with PG_MESH_VERIFY=1, 1 page in 58,822).
		if (d->meshPages) {
			static uint64_t gpuCopies; gpuCopies++;
			if (!(gpuCopies & (gpuCopies - 1))) logf("Metal renderer: a GPU copy into a mesh with engine pages handed back (%llu so far); they go back first", (unsigned long long)gpuCopies);
			PGMeshForgetMesh(d->oid, d->meshPage, d->meshPages, 0); d->meshPages = 0;
		}
		[blitEncoder() copyFromBuffer:s->buf sourceOffset:s->base + sOff toBuffer:d->buf destinationOffset:d->base + dx size:size];
		s->lastUse = d->lastUse = R->serial;
		return;
	}
	if (so->kind != OTexture || dobj->kind != OTexture) return;
	Texture *s = (Texture *)so, *d = (Texture *)dobj;
	if (!s->tex || !d->tex) return;
	etcSettle(s); etcSettle(d);
	if (s->bcKind && d->bcKind && s->format != d->format && (s->etc || d->etc)) gTextureStats.etcMismatch++;
	uint32_t sMip = srcSub % s->mips, sLayer = srcSub / s->mips, dMip = dstSub % d->mips, dLayer = dstSub / d->mips;
	uint32_t mw, mh, md; mipExtent(s, sMip, mw, mh, md);
	uint32_t w = hasBox ? r - l : mw, h = hasBox ? b - t : mh, dep = hasBox ? bk - f : md;
	uint32_t sx = hasBox ? l : 0, sy = hasBox ? t : 0, sz = hasBox ? f : 0;
	if (s->bcKind && d->bcKind && !s->compressedShadow.empty()) {
		gTextureStats.bcCopies++;
		logOnce("bccopyinfo" + std::to_string(s->width) + "x" + std::to_string(s->height) + "-" + std::to_string(s->dxgi) + "-" + std::to_string(d->bind), "Metal renderer: BC copy region from a %ux%u texture (DXGI %u, bind %#x, %u levels) to bind %#x %ux%u",
		        s->width, s->height, s->dxgi, s->bind, s->mips, d->bind, d->width, d->height);
		uint32_t dw, dh, dd; mipExtent(d, dMip, dw, dh, dd);
		uint32_t bb = bcBlockBytes(s->bcKind), sp = (mw + 3) / 4 * bb, dp = (dw + 3) / 4 * bb, rows = (h + 3) / 4, bytes = (w + 3) / 4 * bb;
		for (uint32_t zz = 0; zz < (s->dim == 3 ? dep : 1); zz++) {
			auto src = s->compressedShadow.find(((uint64_t)sMip << 32) | (s->dim == 3 ? sz + zz : sLayer));
			if (src == s->compressedShadow.end()) continue;
			auto &dst = d->compressedShadow[((uint64_t)dMip << 32) | (d->dim == 3 ? dz + zz : dLayer)];
			if (dst.empty()) { dst.resize((size_t)dp * ((dh + 3) / 4)); gTextureStats.shadowBytes += (int64_t)dst.size(); }
			for (uint32_t row = 0; row < rows; row++) {
				size_t from = (size_t)(sy / 4 + row) * sp + (sx / 4) * bb, to = (size_t)(dy / 4 + row) * dp + (dx / 4) * bb;
				if (from + bytes > src->second.size() || to + bytes > dst.size()) break;
				memcpy(dst.data() + to, src->second.data() + from, bytes);
			}
		}
	}
	uint32_t dw, dh, dd; mipExtent(d, dMip, dw, dh, dd);
	if (sMip < s->skip || dMip < d->skip) {		// Lite: a level the GPU doesn't hold
		gTextureStats.missingLevel++;
		logOnce("litecopy", "Metal renderer: Lite: a copy touched a texture's dropped largest level (skipped)");
		return;
	}
	const uint32_t sLevel = sMip - s->skip, dLevel = dMip - d->skip;
	w = std::min(w, std::min(mw - std::min(mw, sx), dw - std::min(dw, dx)));
	h = std::min(h, std::min(mh - std::min(mh, sy), dh - std::min(dh, dy)));
	if (!w || !h) return;
	bool three = s->dim == 3;
	if (s->bcNative && getenv("PG_TRACE_BC_FORMATS")) logOnce("bccopy" + std::to_string(w) + "x" + std::to_string(h), "Metal renderer [trace]: BC copy %ux%u from mip %u (%ux%u) at %u,%u to %u,%u", w, h, sMip, mw, mh, sx, sy, dx, dy);
	if (s->format == d->format) {
		[blitEncoder() copyFromTexture:s->tex sourceSlice:three ? 0 : sLayer sourceLevel:sLevel sourceOrigin:MTLOriginMake(sx, sy, three ? sz : 0)
		                    sourceSize:MTLSizeMake(w, h, three ? std::max(1u, dep) : 1) toTexture:d->tex destinationSlice:d->dim == 3 ? 0 : dLayer
		              destinationLevel:dLevel destinationOrigin:MTLOriginMake(dx, dy, d->dim == 3 ? dz : 0)];
	} else if (s->bcNative && d->bcNative && bcBlockBytes(s->bcKind) == bcBlockBytes(d->bcKind)) {
		if (getenv("PG_TRACE_BC_FORMATS")) logOnce("bctwin", "Metal renderer [trace]: BC copy between twin formats");
		// sRGB and linear twins of one BC format: copy through a view of the destination in the source's format.
		id<MTLTexture> target = [d->tex newTextureViewWithPixelFormat:s->format];
		if (!target) { logOnce("copybcview", "Metal renderer: copy between BC formats %lu and %lu not supported", (unsigned long)s->format, (unsigned long)d->format); return; }
		[blitEncoder() copyFromTexture:s->tex sourceSlice:three ? 0 : sLayer sourceLevel:sLevel sourceOrigin:MTLOriginMake(sx, sy, three ? sz : 0)
		                    sourceSize:MTLSizeMake(w, h, three ? std::max(1u, dep) : 1) toTexture:target destinationSlice:d->dim == 3 ? 0 : dLayer
		              destinationLevel:dLevel destinationOrigin:MTLOriginMake(dx, dy, d->dim == 3 ? dz : 0)];
	} else if ((s->astc && d->astc) || (s->etc && d->etc)) {		// sRGB and linear ASTC (or ETC2) twins: through a view, as for BC above
		id<MTLTexture> target = [d->tex newTextureViewWithPixelFormat:s->format];
		if (!target) { logOnce("copyastcview", "Metal renderer: copy between ASTC formats not supported"); return; }
		[blitEncoder() copyFromTexture:s->tex sourceSlice:three ? 0 : sLayer sourceLevel:sLevel sourceOrigin:MTLOriginMake(sx, sy, three ? sz : 0)
		                    sourceSize:MTLSizeMake(w, h, three ? std::max(1u, dep) : 1) toTexture:target destinationSlice:d->dim == 3 ? 0 : dLayer
		              destinationLevel:dLevel destinationOrigin:MTLOriginMake(dx, dy, d->dim == 3 ? dz : 0)];
	} else if (!s->bcNative && !d->bcNative && !s->astc && !d->astc && !s->etc && !d->etc && bytesPerTexel(s->format) == bytesPerTexel(d->format) && !s->isDepth && !d->isDepth && s->samples == 1 && d->samples == 1) {
		uint32_t bpp = bytesPerTexel(s->format), bpr = w * bpp;
		// Different formats of one size are copied as raw bytes; if their channel layouts differ
		// the colours come out wrong (suspected for short-lived magenta terrain patches).
		logOnce("copyraw" + std::to_string(s->format) + "-" + std::to_string(d->format), "Metal renderer: raw copy between formats %lu and %lu (%ux%u, mip %u to %u)",
		        (unsigned long)s->format, (unsigned long)d->format, w, h, sMip, dMip);
		Alloc a = frameAlloc((size_t)bpr * h, 16);
		id<MTLBlitCommandEncoder> e = blitEncoder();
		[e copyFromTexture:s->tex sourceSlice:three ? 0 : sLayer sourceLevel:sLevel sourceOrigin:MTLOriginMake(sx, sy, three ? sz : 0) sourceSize:MTLSizeMake(w, h, 1)
		          toBuffer:a.buf destinationOffset:a.off destinationBytesPerRow:bpr destinationBytesPerImage:bpr * h];
		[e copyFromBuffer:a.buf sourceOffset:a.off sourceBytesPerRow:bpr sourceBytesPerImage:bpr * h sourceSize:MTLSizeMake(w, h, 1)
		        toTexture:d->tex destinationSlice:d->dim == 3 ? 0 : dLayer destinationLevel:dLevel destinationOrigin:MTLOriginMake(dx, dy, d->dim == 3 ? dz : 0)];
	} else if (copyTexelsAsBlocks(s, d, dstId, sLevel, sLayer, sx, sy, dMip, dLayer, dx, dy, w, h)) {
		logOnce("copyblocks" + std::to_string(s->format), "Metal renderer: texels of format %lu copied as compressed blocks (GPU compression, e.g. the pause menu headshot)", (unsigned long)s->format);
	} else {
		logOnce("copyfmt" + std::to_string(s->format) + "-" + std::to_string(d->format), "Metal renderer: copy between formats %lu and %lu not supported", (unsigned long)s->format, (unsigned long)d->format);
		return;
	}
	s->lastUse = d->lastUse = R->serial;
	d->proxyDirty = true; d->written = true;
}
static void copyResource(uint32_t dstId, uint32_t srcId) {
	Object *so = R->objs.get(srcId), *dobj = R->objs.get(dstId);
	if (!so || !dobj) return;
	if (so->kind == OBuffer) { uint32_t q[14] = {dstId, 0, 0, 0, 0, srcId, 0, 0}; copyRegion(q); return; }
	if (so->kind != OTexture || dobj->kind != OTexture) return;
	Texture *s = (Texture *)so, *d = (Texture *)dobj;
	if (!s->tex || !d->tex) return;
	etcSettle(s); etcSettle(d);
	if (s->bcKind && d->bcKind && s->format != d->format && (s->etc || d->etc)) gTextureStats.etcMismatch++;
	if (s->bcKind && d->bcKind && !s->compressedShadow.empty()) {
		gTextureStats.bcCopies++;
		logOnce("bccopyresinfo" + std::to_string(s->width) + "x" + std::to_string(s->height) + "-" + std::to_string(s->dxgi) + "-" + std::to_string(d->bind), "Metal renderer: BC copy from a %ux%u texture (DXGI %u, bind %#x, %u levels) to bind %#x",
		        s->width, s->height, s->dxgi, s->bind, s->mips, d->bind);
		for (auto &it : d->compressedShadow) gTextureStats.shadowBytes -= (int64_t)it.second.size();
		d->compressedShadow = s->compressedShadow;
		for (auto &it : d->compressedShadow) gTextureStats.shadowBytes += (int64_t)it.second.size();
	}
	if (s->format != d->format || s->samples != d->samples) { logOnce("copyres", "Metal renderer: CopyResource between different formats"); return; }
	uint32_t mips = std::min(s->mips, d->mips);
	uint32_t slices = s->dim == 3 ? 1 : std::min(s->depthOrLayers, d->depthOrLayers);
	id<MTLBlitCommandEncoder> e = blitEncoder();
	if (s->skip != d->skip) { gTextureStats.missingLevel++; logOnce("litecopyres", "Metal renderer: Lite: CopyResource between a whole and a reduced texture (largest level skipped)"); }
	for (uint32_t m = std::max(s->skip, d->skip); m < mips; m++) for (uint32_t sl = 0; sl < slices; sl++) {
		uint32_t w, h, dd; mipExtent(s, m, w, h, dd);
		[e copyFromTexture:s->tex sourceSlice:sl sourceLevel:m - s->skip sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(w, h, dd)
		         toTexture:d->tex destinationSlice:sl destinationLevel:m - d->skip destinationOrigin:MTLOriginMake(0, 0, 0)];
	}
	s->lastUse = d->lastUse = R->serial;
	d->proxyDirty = true; d->written = true;
}
static void resolve(const uint32_t *p) {
	Texture *d = texture(p[0]), *s = texture(p[2]);
	if (!s || !d || !s->tex || !d->tex || s->samples <= 1) return;
	endEncoders();
	MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
	rp.colorAttachments[0].texture = s->tex; rp.colorAttachments[0].slice = p[3] / std::max(1u, s->mips);
	rp.colorAttachments[0].resolveTexture = d->tex; rp.colorAttachments[0].resolveLevel = p[1] % d->mips; rp.colorAttachments[0].resolveSlice = p[1] / d->mips;
	rp.colorAttachments[0].loadAction = MTLLoadActionLoad; rp.colorAttachments[0].storeAction = MTLStoreActionMultisampleResolve;
	[[commandBuffer() renderCommandEncoderWithDescriptor:rp] endEncoding];
	s->lastUse = d->lastUse = R->serial;
	d->proxyDirty = true; d->written = true;
}
static void generateMips(uint32_t srvId) {
	View *v = view(srvId, OSrv);
	Texture *t = v ? texture(v->res) : nullptr;
	if (!t || !t->tex || t->mips < 2 || t->isDepth || t->samples > 1) return;
	[blitEncoder() generateMipmapsForTexture:t->tex];
	t->written = true;
	t->lastUse = R->serial;
}

// ---- UAV counters and clears ------------------------------------------------------------------------------------------
static id<MTLBuffer> counterOf(Buffer *b) {
	if (!b->counter) { b->counter = [R->device newBufferWithLength:16 options:MTLResourceStorageModeShared]; memset(b->counter.contents, 0, 16); }
	return b->counter;
}
static void setUavCounter(uint32_t uavId, uint32_t value) {
	View *u = view(uavId, OUav);
	Buffer *b = u && u->isBuf ? buffer(u->res) : nullptr;
	if (!b) return;
	Alloc a = frameAlloc(4, 16);
	memcpy(a.ptr, &value, 4);
	[blitEncoder() copyFromBuffer:a.buf sourceOffset:a.off toBuffer:counterOf(b) destinationOffset:0 size:4];
}
static void copyCounter(uint32_t dstId, uint32_t offset, uint32_t uavId) {
	Buffer *d = buffer(dstId);
	View *u = view(uavId, OUav);
	Buffer *s = u && u->isBuf ? buffer(u->res) : nullptr;
	if (!d || !d->buf || !s || offset + 4 > d->bytes) return;
	[blitEncoder() copyFromBuffer:counterOf(s) sourceOffset:0 toBuffer:d->buf destinationOffset:d->base + offset size:4];
	d->lastUse = R->serial;
}
static void clearUav(const uint32_t *p) {
	View *u = view(p[0], OUav);
	if (!u) return;
	bool isFloat = p[1] != 0;
	uint32_t values[4] = {p[2], p[3], p[4], p[5]};
	bool zero = !(values[0] | values[1] | values[2] | values[3]);
	if (u->isBuf) {
		Buffer *b = buffer(u->res);
		if (!b || !b->buf) return;
		if (zero) [blitEncoder() fillBuffer:b->buf range:NSMakeRange(b->base, b->bytes) value:0];
		else {
			Alloc a = frameAlloc(b->bytes, 16);
			uint32_t *w = (uint32_t *)a.ptr;
			for (uint32_t i = 0; i < b->bytes / 4; i++) w[i] = values[i & 3];
			[blitEncoder() copyFromBuffer:a.buf sourceOffset:a.off toBuffer:b->buf destinationOffset:b->base size:b->bytes & ~3u];
		}
		b->lastUse = R->serial;
		return;
	}
	Texture *t = texture(u->res);
	if (!t || !t->tex) return;
	endEncoders();
	uint32_t mip = std::min(u->a, t->mips - 1), layers = t->dim == 3 ? std::max(1u, t->depthOrLayers >> mip) : t->depthOrLayers;
	for (uint32_t l = 0; l < layers; l++) {
		MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
		rp.colorAttachments[0].texture = t->tex; rp.colorAttachments[0].level = mip;
		if (t->dim == 3) rp.colorAttachments[0].depthPlane = l; else rp.colorAttachments[0].slice = l;
		rp.colorAttachments[0].loadAction = MTLLoadActionClear; rp.colorAttachments[0].storeAction = MTLStoreActionStore;
		double c[4];
		for (int i = 0; i < 4; i++) c[i] = isFloat ? wordFloat(values[i]) : (double)values[i];
		rp.colorAttachments[0].clearColor = MTLClearColorMake(c[0], c[1], c[2], c[3]);
		[[commandBuffer() renderCommandEncoderWithDescriptor:rp] endEncoding];
	}
	t->lastUse = R->serial;
	t->proxyDirty = true; t->written = true;
}

// ---- readbacks --------------------------------------------------------------------------------------------------------
static void readback(const uint32_t *p) {
	Object *o = R->objs.get(p[0]);
	uint32_t sub = p[1], hasBox = p[2], l = p[3], t = p[4], f = p[5], r = p[6], b = p[7], bk = p[8];
	uint64_t addr = p[9] + ((uint64_t)p[10] << 32);
	uint32_t rowPitch = p[11], slicePitch = p[12], isBuf = p[13], size = p[14];
	uint64_t flag = p[15] + ((uint64_t)p[16] << 32);
	auto done = [flag]() { if (flag) storeWord(flag, 0); };
	if (!o || addr >= R->memSize) { done(); return; }
	if (isBuf && o->kind == OBuffer) {
		Buffer *s = (Buffer *)o;
		if (!s->buf) { done(); return; }
		uint32_t from = hasBox ? l : 0, n = hasBox ? r - l : std::min(size, s->size);
		n = std::min<uint64_t>(std::min(n, s->bytes - std::min(s->bytes, from)), R->memSize - addr);
		Alloc a = frameAlloc((n + 3) & ~3u, 16);
		[blitEncoder() copyFromBuffer:s->buf sourceOffset:s->base + from toBuffer:a.buf destinationOffset:a.off size:(n + 3) & ~3u];
		uint8_t *dst = R->mem + addr, *src = a.ptr;
		R->onComplete.push_back([dst, src, n, done]() { memcpy(dst, src, n); done(); });
		commit(CReadback);
		return;
	}
	if (o->kind != OTexture) { done(); return; }
	Texture *s = (Texture *)o;
	etcSettle(s);
	uint32_t mip = sub % s->mips, layer = sub / s->mips;
	if (mip < s->skip && !(s->bcKind && !s->bcNative)) {		// Lite: the GPU doesn't hold that level
		gTextureStats.missingLevel++;
		logOnce("literb", "Metal renderer: Lite: readback of a texture's dropped largest level (skipped)");
		done(); return;
	}
	const uint32_t level = mip - std::min(mip, s->skip);
	uint32_t mw, mh, md; mipExtent(s, mip, mw, mh, md);
	uint32_t w = hasBox ? r - l : mw, h = hasBox ? b - t : mh, d = hasBox ? bk - f : md;
	uint32_t x0 = hasBox ? l : 0, y0 = hasBox ? t : 0, z0 = hasBox ? f : 0;
	bool three = s->dim == 3;
	if (s->bcNative && s->tex) {		// copy the blocks out of the GPU texture
		w = std::min(w, mw - std::min(mw, x0)); h = std::min(h, mh - std::min(mh, y0));
		uint32_t bb = bcBlockBytes(s->bcKind), rows = (h + 3) / 4, rowBytes = (w + 3) / 4 * bb, bpr = (rowBytes + 15) & ~15u;
		if (!w || !h || rowBytes > rowPitch) { done(); return; }
		uint32_t layers = three ? d : 1;
		Alloc a = frameAlloc((size_t)bpr * rows * layers, 16);
		[blitEncoder() copyFromTexture:s->tex sourceSlice:three ? 0 : layer sourceLevel:level sourceOrigin:MTLOriginMake(x0, y0, three ? z0 : 0) sourceSize:MTLSizeMake(w, h, layers)
		                      toBuffer:a.buf destinationOffset:a.off destinationBytesPerRow:bpr destinationBytesPerImage:bpr * rows];
		uint8_t *src = a.ptr, *mem = R->mem;
		uint64_t memSize = R->memSize;
		R->onComplete.push_back([=]() {
			for (uint32_t z = 0; z < layers; z++) for (uint32_t row = 0; row < rows; row++) {
				uint64_t to = addr + (uint64_t)z * slicePitch + (uint64_t)row * rowPitch;
				if (to + rowBytes > memSize) break;
				memcpy(mem + to, src + ((size_t)z * rows + row) * bpr, rowBytes);
			}
			done();
		});
		commit(CReadback);
		return;
	}
	if (s->bcKind) {		// the original blocks (the GPU holds a decoded copy)
		gTextureStats.bcReadbacks++;
		// Which BC textures the game reads back (GTA-217: the CPU block copies cost 60-70 MB for a handful of readbacks).
		logOnce("rbinfo" + std::to_string(s->width) + "x" + std::to_string(s->height) + "-" + std::to_string(s->dxgi), "Metal renderer: BC readback of a %ux%u texture (DXGI %u, bind %#x, %u levels, mip %u, %s)",
		        s->width, s->height, s->dxgi, s->bind, s->mips, mip, s->compressedShadow.empty() ? "no CPU copy" : "from its CPU copy");
		uint32_t bb = bcBlockBytes(s->bcKind), rows = (h + 3) / 4, pitch = (mw + 3) / 4 * bb, rowBytes = (w + 3) / 4 * bb;
		for (uint32_t z = 0; z < (three ? d : 1); z++) {
			auto it = s->compressedShadow.find(((uint64_t)mip << 32) | (three ? z0 + z : layer));
			if (it == s->compressedShadow.end()) { logOnce("rbbc" + std::to_string(s->width) + "x" + std::to_string(s->height), "Metal renderer: compressed readback of a %ux%u texture without its original blocks", s->width, s->height); break; }
			for (uint32_t row = 0; row < rows; row++) {
				size_t from = (size_t)(y0 / 4 + row) * pitch + (x0 / 4) * bb;
				uint64_t to = addr + (uint64_t)z * slicePitch + (uint64_t)row * rowPitch;
				if (from + rowBytes > it->second.size() || to + rowBytes > R->memSize || rowBytes > rowPitch) break;
				memcpy(R->mem + to, it->second.data() + from, rowBytes);
			}
		}
		done();
		return;
	}
	if (!s->tex || s->samples > 1 || s->isDepth) { logOnce("rbfmt" + std::to_string(s->format), "Metal renderer: readback of format %lu not supported", (unsigned long)s->format); done(); return; }
	uint32_t bpp = bytesPerTexel(s->format), rowBytes = w * bpp, bpr = (rowBytes + 15) & ~15u;
	if (rowBytes > rowPitch) { logOnce("rbpitch", "Metal renderer: readback row pitch too small"); done(); return; }
	uint32_t layers = three ? d : 1;
	Alloc a = frameAlloc((size_t)bpr * h * layers, 16);
	[blitEncoder() copyFromTexture:s->tex sourceSlice:three ? 0 : layer sourceLevel:level sourceOrigin:MTLOriginMake(x0, y0, three ? z0 : 0) sourceSize:MTLSizeMake(w, h, layers)
	                      toBuffer:a.buf destinationOffset:a.off destinationBytesPerRow:bpr destinationBytesPerImage:bpr * h];
	uint8_t *src = a.ptr;
	uint64_t memSize = R->memSize;
	uint8_t *mem = R->mem;
	// GTA-77 (PG_MR_UNINIT=1): NaN or infinity in what the game reads back from a 32-bit float target (the water
	// simulation's height and velocity maps are read back every frame), logged at most every 10 s per texture.
	const bool scan = gUninitTrace > 0 && isFloat32(s->format);
	const uint32_t oid = s->oid, tw = s->width, th = s->height;
	R->onComplete.push_back([=]() {
		for (uint32_t z = 0; z < layers; z++) for (uint32_t row = 0; row < h; row++) {
			uint64_t to = addr + (uint64_t)z * slicePitch + (uint64_t)row * rowPitch;
			if (to + rowBytes > memSize) break;
			memcpy(mem + to, src + ((size_t)z * h + row) * bpr, rowBytes);
		}
		if (scan) {
			uint64_t nan = 0, inf = 0, n = 0;
			for (uint32_t z = 0; z < layers; z++) for (uint32_t row = 0; row < h; row++) {
				const uint32_t *wv = (const uint32_t *)(src + ((size_t)z * h + row) * bpr);
				for (uint32_t i = 0; i < rowBytes / 4; i++, n++) { uint32_t m = wv[i] & 0x7fffffffu; if (m > 0x7f800000u) nan++; else if (m == 0x7f800000u) inf++; }
			}
			static std::mutex lock; static std::unordered_map<uint32_t, double> last;
			if (nan || inf) {
				std::lock_guard<std::mutex> g(lock);
				double now = CACurrentMediaTime();
				if (now - last[oid] > 10) { last[oid] = now; logf("Metal renderer [nan]: readback of texture %u (%ux%u, 32-bit float) holds %llu NaN and %llu infinite values of %llu", oid, tw, th,
				                                                  (unsigned long long)nan, (unsigned long long)inf, (unsigned long long)n); }
			}
		}
		done();
	});
	commit(CReadback);
}

// ---- present ------------------------------------------------------------------------------------------------------------
static void savePNG(id<MTLBuffer> buf, uint32_t w, uint32_t h, uint32_t bpr, std::string name) {
	CGColorSpaceRef color = CGColorSpaceCreateDeviceRGB();
	CGContextRef bitmap = CGBitmapContextCreate(buf.contents, w, h, 8, bpr, color, kCGBitmapByteOrder32Little | kCGImageAlphaNoneSkipFirst);
	CGImageRef image = CGBitmapContextCreateImage(bitmap);
	NSData *png = UIImagePNGRepresentation([UIImage imageWithCGImage:image]);
	NSString *folder = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject stringByAppendingPathComponent:@"NativeFrames"];
	NSString *full = [NSString stringWithUTF8String:name.c_str()];
	// "folder/name": one subfolder of NativeFrames (GTA-77 test shots keep each session's pictures together)
	NSString *sub = full.stringByDeletingLastPathComponent.lastPathComponent;
	if (sub.length && ![sub isEqualToString:@".."] && ![sub isEqualToString:@"."]) folder = [folder stringByAppendingPathComponent:sub];
	[NSFileManager.defaultManager createDirectoryAtPath:folder withIntermediateDirectories:YES attributes:nil error:nil];
	NSString *file = [[folder stringByAppendingPathComponent:full.lastPathComponent] stringByAppendingPathExtension:@"png"];
	[png writeToFile:file atomically:YES];
	CGImageRelease(image); CGContextRelease(bitmap); CGColorSpaceRelease(color);
	logf("Native rendered frame saved: %s", name.c_str());
}

static void capture(Texture *t, const std::string &name, id<MTLRenderPipelineState> pipe, id<MTLTexture> second) {
	if (!t || !t->tex) return;
	if (!pipe) pipe = R->capturePipe;
	MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:t->width height:t->height mipmapped:NO];
	d.usage = MTLTextureUsageRenderTarget; d.storageMode = MTLStorageModePrivate;
	id<MTLTexture> target = [R->device newTextureWithDescriptor:d];
	MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
	rp.colorAttachments[0].texture = target; rp.colorAttachments[0].loadAction = MTLLoadActionDontCare; rp.colorAttachments[0].storeAction = MTLStoreActionStore;
	id<MTLRenderCommandEncoder> e = [commandBuffer() renderCommandEncoderWithDescriptor:rp];
	[e setRenderPipelineState:pipe]; [e setFragmentTexture:t->tex atIndex:0];
	if (second) [e setFragmentTexture:second atIndex:1];
	[e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
	[e endEncoding];
	uint32_t bpr = t->width * 4;
	id<MTLBuffer> out = [R->device newBufferWithLength:(NSUInteger)bpr * t->height options:MTLResourceStorageModeShared];
	id<MTLBlitCommandEncoder> b = [commandBuffer() blitCommandEncoder];
	[b copyFromTexture:target sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(t->width, t->height, 1) toBuffer:out destinationOffset:0 destinationBytesPerRow:bpr destinationBytesPerImage:bpr * t->height];
	[b endEncoding];
	uint32_t w = t->width, h = t->height;
	R->onComplete.push_back([out, w, h, bpr, name]() { dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{ @autoreleasepool { savePNG(out, w, h, bpr, name); } }); });
}

// Sharper upscaling (GTA-10): instead of the screen stretching the picture, MetalFX's spatial scaler
// brings it to the screen's own resolution (up to 3 times the render size) with edge-aware sharpening.
static std::atomic<bool> gUpscale{false};
extern "C" void PGMetalRendererSetUpscaling(int on) { gUpscale.store(on != 0); }
extern "C" void PGMetalRendererSetPresentInterval(double seconds) { gPresentInterval.store(seconds > 0 && seconds < 1 ? seconds : 0); }
#if PG_METALFX
static struct { id<MTLFXSpatialScaler> scaler; id<MTLTexture> out; uint32_t inW, inH, outW, outH; MTLPixelFormat format; bool unsupported; } FX;
static id<MTLTexture> upscaled(Texture *t) {
	if (!gUpscale.load() || FX.unsupported || !R->layer) return nil;
	if (![MTLFXSpatialScalerDescriptor supportsDevice:R->device]) { FX.unsupported = true; pg_log("Sharper upscaling: MetalFX isn't available on this device."); return nil; }
	CGSize screen = R->layer.bounds.size; CGFloat scale = R->layer.contentsScale;
	uint32_t outW = (uint32_t)std::min<double>(screen.width * scale, t->width * 3.0), outH = (uint32_t)std::min<double>(screen.height * scale, t->height * 3.0);
	if (outW < t->width * 1.05 || outH < t->height * 1.05) return nil;		// the picture is already about screen size
	if (!FX.scaler || FX.inW != t->width || FX.inH != t->height || FX.outW != outW || FX.outH != outH || FX.format != t->tex.pixelFormat) {
		MTLFXSpatialScalerDescriptor *d = [MTLFXSpatialScalerDescriptor new];
		d.inputWidth = t->width; d.inputHeight = t->height; d.outputWidth = outW; d.outputHeight = outH;
		d.colorTextureFormat = t->tex.pixelFormat; d.outputTextureFormat = t->tex.pixelFormat;
		d.colorProcessingMode = MTLFXSpatialScalerColorProcessingModePerceptual;
		FX.scaler = [d newSpatialScalerWithDevice:R->device];
		MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:t->tex.pixelFormat width:outW height:outH mipmapped:NO];
		td.storageMode = MTLStorageModePrivate;
		td.usage = (FX.scaler ? FX.scaler.outputTextureUsage : 0) | MTLTextureUsageShaderRead;
		FX.out = FX.scaler ? [R->device newTextureWithDescriptor:td] : nil;
		FX.inW = t->width; FX.inH = t->height; FX.outW = outW; FX.outH = outH; FX.format = t->tex.pixelFormat;
		if (!FX.scaler || !FX.out) { FX.unsupported = true; FX.scaler = nil; FX.out = nil; logf("Sharper upscaling: MetalFX couldn't scale format %lu; off.", (unsigned long)t->tex.pixelFormat); return nil; }
		logf("Sharper upscaling: MetalFX %ux%u to %ux%u.", t->width, t->height, outW, outH);
	}
	FX.scaler.colorTexture = t->tex; FX.scaler.outputTexture = FX.out;
	FX.scaler.inputContentWidth = t->width; FX.scaler.inputContentHeight = t->height;
	[FX.scaler encodeToCommandBuffer:commandBuffer()];
	return FX.out;
}
#else
static id<MTLTexture> upscaled(Texture *) {
	static bool told;
	if (gUpscale.load() && !told) { told = true; pg_log("Sharper upscaling: MetalFX isn't available on this device."); }
	return nil;
}
#endif

// GTA-77 test shots (PG_TEST_SHOTS in EngineHost.c): pictures, each with its own switch settings. The settings change
// right after a frame is presented; the picture is the third frame after that, drawn wholly with them. When the queue
// is empty the settings go back to the launch's.
struct TestShot { std::string name; int strips, nan; };
static std::mutex gShotLock;
static std::vector<TestShot> gShots;
static int gShotFrames = -1;		// -1: the first shot's settings are not applied yet
static void writeCensus(const std::string &name) {
	NSString *folder = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject stringByAppendingPathComponent:@"NativeFrames"];
	NSString *full = [NSString stringWithUTF8String:name.c_str()];
	NSString *sub = full.stringByDeletingLastPathComponent.lastPathComponent;
	if (sub.length && ![sub isEqualToString:@".."] && ![sub isEqualToString:@"."]) folder = [folder stringByAppendingPathComponent:sub];
	[NSFileManager.defaultManager createDirectoryAtPath:folder withIntermediateDirectories:YES attributes:nil error:nil];
	FILE *f = fopen([[[folder stringByAppendingPathComponent:full.lastPathComponent] stringByAppendingPathExtension:@"txt"] fileSystemRepresentation], "w");
	if (!f) return;
	uint64_t draws = 0, skipped = 0;
	for (auto &kv : gCensus) { draws += kv.second.draws; skipped += kv.second.skipped; }
	fprintf(f, "frame %llu: %llu draws, %llu skipped; pipelines %u made, %u compiling\n", (unsigned long long)R->frame, (unsigned long long)draws,
	        (unsigned long long)skipped, R->pipesMade, R->pipesPending.load());
	for (auto &kv : gCensus) fprintf(f, "%6llu draws %9llu vertices %4llu skipped %-14s %s\n", (unsigned long long)kv.second.draws, (unsigned long long)kv.second.verts,
	                                 (unsigned long long)kv.second.skipped, kv.second.reasons.c_str(), kv.first.c_str());
	fclose(f);
}
static std::string testShotAtPresent() {
	std::lock_guard<std::mutex> g(gShotLock);
	gCensusOn.store(!gShots.empty(), std::memory_order_relaxed);
	if (gShots.empty()) { gCensus.clear(); return ""; }
	TestShot &s = gShots.front();
	if (gShotFrames < 0) { gStripLists.store(s.strips); gNanClamp.store(s.nan); gShotFrames = 3; gCensus.clear(); return ""; }
	if (--gShotFrames > 0) { gCensus.clear(); return ""; }
	std::string name = s.name;
	writeCensus(name);
	gCensus.clear();
	logf("Metal renderer: test shot %s (strips as lists %d, NaN clamp %d)", name.c_str(), s.strips, s.nan);
	gShots.erase(gShots.begin()); gShotFrames = -1;
	if (gShots.empty()) { gStripLists.store(gLaunchStripLists); gNanClamp.store(gLaunchNanClamp); }
	return name;
}

static void present(uint32_t texId) {
	flushBlockUploads();
	flushClears();
	endEncoders();
	stripEvict();
	Texture *t = texture(texId);
	id<CAMetalDrawable> drawable = nil;
	const std::string shot = testShotAtPresent();
	if (t && t->tex && !shot.empty()) capture(t, shot);
	if (t && t->tex && R->layer) {
		std::string name;
		{ std::lock_guard<std::mutex> g(R->captureLock); name.swap(R->captureName); }
		if (!name.empty()) capture(t, name);
		{
			std::string burst;
			{ std::lock_guard<std::mutex> g(R->captureLock); if (R->burstLeft > 0) { R->burstLeft--; char n[160]; snprintf(n, sizeof n, "%s-%03d", R->burstName.c_str(), R->burstIndex++); burst = n; } }
			if (!burst.empty()) capture(t, burst);
		}
		id<MTLTexture> picture = upscaled(t) ?: t->tex;
		CGSize size = CGSizeMake(picture.width, picture.height);
		if (!CGSizeEqualToSize(R->layer.drawableSize, size)) { R->layer.drawableSize = size; gDrawablePixels = (uint64_t)picture.width * picture.height; }
		drawable = [R->layer nextDrawable];
		if (drawable) {
			MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
			rp.colorAttachments[0].texture = drawable.texture; rp.colorAttachments[0].loadAction = MTLLoadActionDontCare; rp.colorAttachments[0].storeAction = MTLStoreActionStore;
			id<MTLRenderCommandEncoder> e = [commandBuffer() renderCommandEncoderWithDescriptor:rp];
			[e setRenderPipelineState:R->blitPipe]; [e setFragmentTexture:picture atIndex:0];
			[e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
			[e endEncoding];
			t->lastUse = R->serial;
		}
	}
#if MR_TRACE
	if (T.state == 2) {		// the traced frame is complete: save the targets it drew into
		tracef("PRESENT %s", traceTex(texId).c_str());
		capture(t, "trace-present");
		for (uint32_t id : T.rts) {
			Texture *rt = texture(id);
			if (rt && rt->tex && !rt->isDepth && rt->samples == 1 && rt->tex.textureType == MTLTextureType2D && id != texId) capture(rt, "trace-rt" + std::to_string(id));
		}
		fclose(T.f); T.f = nullptr; T.state = 3;
		logf("Metal renderer: traced frame written (%llu draws, %zu targets)", (unsigned long long)T.n, T.rts.size());
	} else if (T.state == 1 && CACurrentMediaTime() >= T.at) {
		NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
		T.f = fopen([docs stringByAppendingPathComponent:@"mr-trace.txt"].UTF8String, "w");
		T.state = T.f ? 2 : 3;
	} else if (T.state == 0 && R->worldSent) {
		const char *env = getenv("PG_MR_TRACE");
		if (env && *env) { T.at = CACurrentMediaTime() + atof(env); T.state = 1; } else T.state = 3;
	}
#endif
	FrameRing &f = R->frames[R->frame % FRAME_SLOTS];
	commit(CPresent, drawable);
	f.lastSerial = R->serial - 1;
	R->presents++;
	presentedFrames.fetch_add(1, std::memory_order_relaxed);
	double now = CACurrentMediaTime();
	if (R->statPresentAt) { double gap = (now - R->statPresentAt) * 1000; if (gap > 50) R->longFrames++; if (gap > R->worstFrameMs) R->worstFrameMs = gap; }
	R->statPresentAt = now;
	R->lastPresent.store(now);
	if (R->fpsWindow.record(now)) R->fps.store(R->fpsWindow.rate);
	// loading progress for the app: first frame, then the world once 1.5 s went by without draws waiting for pipelines
	if (!R->firstFrame) { R->firstFrame = true; pg_log("{\"pct\":76,\"label\":\"First frame\"}"); }
	uint64_t d = R->draws - R->drawsAtPresent;
	R->drawsAtPresent = R->draws;
	double ms = now * 1000;
	if (!R->worldSent && (R->worldSince || d > 300)) {
		if (!R->worldSince) R->worldSince = ms;
		if (R->pendingSkips != R->pendingAtPresent) R->worldClean = 0; else if (!R->worldClean) R->worldClean = ms;
		if ((R->worldClean && ms - R->worldClean >= 1500) || ms - R->worldSince >= 60000) {
			R->worldSent = true;
			logf("Metal renderer: world shown after %.1f s of pipeline compiles (%u pipelines made)", (ms - R->worldSince) / 1000, R->pipesMade);
			pg_log("{\"pct\":100,\"label\":\"Ready\",\"world\":true}");
			pg_log("WORLD_READY");
		}
	}
	R->pendingAtPresent = R->pendingSkips;
	R->pipeWaitMs = 0;
	// the next frame's ring slot must be idle on the GPU
	R->frame++;
	FrameRing &next = R->frames[R->frame % FRAME_SLOTS];
	double w0 = nowMs();
	if (next.lastSerial) waitSerial(next.lastSerial);
	R->work.gpuWait += nowMs() - w0;
	next.reset();
	double tn = nowMs();
	if (R->lastPresentMs) frameReportsRecord(tn, tn - R->lastPresentMs, d, R->worldSent, R->work);
	R->lastPresentMs = tn;
	R->work = FrameWork();
}

// ---- object creation ----------------------------------------------------------------------------------------------------
static void createShader(const uint32_t *p) {
	auto *s = new Shader(p[0]);
	s->stage = p[1];
	char hash[17];
	snprintf(hash, sizeof hash, "%08x%08x", p[3], p[2]);
	s->hash = hash;
	uint32_t nin = p[4];
	for (uint32_t i = 0; i < nin && i < 64; i++) s->sig.push_back({p[5 + i * 4], p[6 + i * 4], p[7 + i * 4], p[8 + i * 4]});
	s->info = findShader(s->hash);
	if (s->info) R->shaderObjects.emplace(s->info, p[0]);
#if MR_TRACE
	static FILE *shaderList = nullptr;
	static bool shaderListChecked = false;
	if (!shaderListChecked) {
		shaderListChecked = true;
		const char *env = getenv("PG_MR_TRACE");
		NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
		if (env && *env) shaderList = fopen([docs stringByAppendingPathComponent:@"mr-shaders.txt"].UTF8String, "w");
	}
	if (shaderList) { fprintf(shaderList, "%u %u %s %s\n", p[0], p[1], hash, s->info ? s->info->label.c_str() : "-"); fflush(shaderList); }
#endif
	if (!s->info && s->stage <= 2) logOnce("noshader" + s->hash, "Metal renderer: no precompiled shader %s (stage %u)", hash, s->stage);
	R->objs.set(p[0], s);
}
static void createLayout(const uint32_t *p) {
	auto *l = new Layout(p[0]);
	uint32_t n = p[1];
	uint32_t seen = 0;
	for (uint32_t i = 0; i < n && i < 32; i++) {
		const uint32_t *q = p + 2 + i * 7;
		LayoutEl e{q[0], q[1], q[2], q[3], q[4], q[5], q[6]};
		l->els.push_back(e);
		if (e.slot < 16 && !((seen >> e.slot) & 1)) { seen |= 1u << e.slot; l->slots.push_back({e.slot, e.cls}); }
	}
	R->objs.set(p[0], l);
}
static void createState(const uint32_t *p, uint32_t n) {
	auto *s = new State(p[0]);
	s->skind = p[1];
	s->words.assign(p + 2, p + std::max(2u, n));
	uint64_t h = fnv(1469598103934665603ull, s->skind);
	for (uint32_t w : s->words) h = fnv(h, w);
	s->hash = h;
	if (s->skind == 3) makeSamplers(s);
	R->objs.set(p[0], s);
}
static void createView(const uint32_t *p, ObjKind kind) {
	auto *v = new View(kind, p[0]);
	v->isBuf = p[1] == 1; v->res = p[2]; v->fmt = p[3]; v->vdim = p[4]; v->a = p[5]; v->b = p[6]; v->c = p[7];
	if (kind == OSrv) v->d = p[8]; else v->flags = p[8];
	R->objs.set(p[0], v);
}
static void createQuery(const uint32_t *p) {
	auto *q = new Query(p[0]);
	q->type = p[1];
	q->addr = p[2] + ((uint64_t)p[3] << 32);
	R->objs.set(p[0], q);
}
static void destroyObject(uint32_t oid) {
	Object *o = R->objs.get(oid);
	if (!o) return;
	if (o->kind == OTexture) {
		R->clears.erase(std::remove_if(R->clears.begin(), R->clears.end(), [oid](const PendingClear &c) { return c.tex == oid; }), R->clears.end());
		for (auto &r : R->rt) if (r.tex == oid) R->rtDirty = true;
		if (R->ds.tex == oid) R->rtDirty = true;
	}
	if (o->kind == OQuery && R->activeOcclusion == o) { endOcclusionInPass(); R->activeOcclusion = nullptr; }
	if (o->kind == OQuery) for (auto &pq : R->pendingQueries) if (pq.q == o) pq.q = nullptr;
	if (o->kind == OShader) { Shader *s = (Shader *)o; auto it = s->info ? R->shaderObjects.find(s->info) : R->shaderObjects.end(); if (it != R->shaderObjects.end() && it->second == oid) R->shaderObjects.erase(it); }
	if (o->kind == OBuffer || o->kind == OLayout || o->kind == OState || o->kind == OShader) R->pipeDirty = true;
	if (o->kind == OBuffer) { gMeshWrites.erase(oid); if (!gStripCacheKeys.empty() || !gStripDynamic.empty()) stripForgetBuffer(oid); }
	if (gTraceHeld > 0) gHeld.erase(oid);
	R->objs.erase(oid);
}
static void resetState() {
	memset(R->shader, 0, sizeof R->shader); R->layout = 0; R->topo = 4;
	memset(R->vb, 0, sizeof R->vb); memset(&R->ib, 0, sizeof R->ib); memset(R->cb, 0, sizeof R->cb);
	memset(R->srv, 0, sizeof R->srv); memset(R->smp, 0, sizeof R->smp); memset(R->uav, 0, sizeof R->uav);
	memset(R->rt, 0, sizeof R->rt); memset(&R->ds, 0, sizeof R->ds);
	R->blendId = 0; R->blendFactor[0] = R->blendFactor[1] = R->blendFactor[2] = R->blendFactor[3] = 1; R->blendMask = 0xffffffff;
	R->dssId = 0; R->dssRef = 0; R->rsId = 0; R->hasViewport = R->hasScissor = false;
	R->rtDirty = true; R->pipeDirty = true;
}

// ---- command loop -------------------------------------------------------------------------------------------------------
static bool isStateOp(uint32_t op) {
	switch (op) {
	case NOP: case INIT: case CREATE_TEXTURE: case CREATE_BUFFER: case CREATE_SHADER: case CREATE_LAYOUT: case CREATE_STATE: case CREATE_SRV:
	case CREATE_UAV: case CREATE_QUERY: case SET_SHADER: case SET_INPUT_LAYOUT: case SET_TOPOLOGY: case SET_VERTEX_BUFFERS: case SET_INDEX_BUFFER:
	case SET_CBUFFERS: case SET_SRVS: case SET_SAMPLERS: case SET_RENDER_TARGETS: case SET_BLEND: case SET_DEPTH_STENCIL: case SET_RASTER:
	case SET_VIEWPORTS: case SET_SCISSORS: case DRAW: case CLEAR_STATE: case CLEAR_RT: case CLEAR_DS: case UPLOAD_BUFFER: case UPLOAD_BUFFER_NO_OVERWRITE:
	case DESTROY_OBJECT: case LOG: case BEGIN_QUERY: case END_QUERY: case SET_UAVS: case WRAP:
		return true;
	default: return false;
	}
}

static void execute(uint32_t op, const uint32_t *p, uint32_t n) {
	const float *pf = (const float *)p;
#if MR_TRACE
	if (T.state == 2) switch (op) {
	case CLEAR_RT: tracef("CLEAR_RT %s mip%u slice%u %.3f,%.3f,%.3f,%.3f", traceTex(p[0]).c_str(), p[1], p[2], pf[3], pf[4], pf[5], pf[6]); break;
	case CLEAR_DS: tracef("CLEAR_DS %s flags%u z%.3f s%u", traceTex(p[0]).c_str(), p[3], pf[4], p[5]); break;
	case COPY_REGION: tracef("COPY_REGION dst %u sub%u at %u,%u <- src %u sub%u box%u %u,%u-%u,%u", p[0], p[1], p[2], p[3], p[5], p[6], p[7], p[8], p[9], p[11], p[12]); break;
	case COPY_RESOURCE: tracef("COPY_RESOURCE %u <- %u", p[0], p[1]); break;
	case RESOLVE: tracef("RESOLVE %s <- %s", traceTex(p[0]).c_str(), traceTex(p[2]).c_str()); break;
	case GENERATE_MIPS: tracef("GENERATE_MIPS srv%u", p[0]); break;
	case DISPATCH: tracef("DISPATCH %s", R->objs.as<Shader>(R->shader[2], OShader) && R->objs.as<Shader>(R->shader[2], OShader)->info ? R->objs.as<Shader>(R->shader[2], OShader)->info->label.c_str() : "?"); break;
	case UPLOAD_TEXTURE: tracef("UPLOAD_TEXTURE %s mip%u slice%u %u,%u %ux%u", traceTex(p[0]).c_str(), p[1], p[2], p[3], p[4], p[6], p[7]); break;
	case CREATE_TEXTURE: tracef("CREATE_TEXTURE %u dim%u %ux%u dxgi%u bind%#x", p[0], p[1], p[2], p[3], p[7], p[8]); break;
	case CREATE_SRV: tracef("CREATE_SRV %u res%u fmt%u", p[0], p[2], p[3]); break;
	case READBACK: tracef("READBACK %u", p[0]); break;
	case SET_SRVS: { std::string o; for (uint32_t i = 0; i < p[2]; i++) { View *v = view(p[3 + i], OSrv); o += " t" + std::to_string(p[1] + i) + "=" + std::to_string(p[3 + i]) + (v ? (v->isBuf ? "(buf)" : "(" + std::to_string(v->res) + " f" + std::to_string(v->fmt) + ")") : "(null)"); } tracef("SET_SRVS st%u%s", p[0], o.c_str()); break; }
	case SET_RENDER_TARGETS: tracef("SET_RENDER_TARGETS rt0=%u ds=%u", p[0], p[32]); break;
	case DESTROY_OBJECT: tracef("DESTROY %u", p[0]); break;
	case CLEAR_STATE: tracef("CLEAR_STATE"); break;
	default: break;
	}
#endif
	if (!isStateOp(op)) flushClears();
	switch (op) {
	case NOP: case INIT: break;
	case CREATE_TEXTURE: createTexture(p); break;
	case DESTROY_OBJECT: destroyObject(p[0]); break;
	case CLEAR_RT: { PendingClear c{p[0], p[1], p[2], false, {pf[3], pf[4], pf[5], pf[6]}, 0, 0, 0}; if (texture(p[0])) addClear(c); break; }
	case CLEAR_DS: { PendingClear c{p[0], p[1], p[2], true, {}, p[3], pf[4], p[5]}; if (texture(p[0])) addClear(c); break; }
	case PRESENT: present(p[0]); break;
	case FENCE: {
		uint64_t addr = p[0] + ((uint64_t)p[1] << 32);
		uint32_t value = p[2];
		R->onComplete.push_back([addr, value]() { storeWord(addr, value); });
		commit(CFence);
		break;
	}
	case SCREENSHOT: {
		std::string name((const char *)(p + 2), std::min<uint32_t>(p[1], 256));
		size_t slash = name.find_last_of("/\\");
		if (slash != std::string::npos) name = name.substr(slash + 1);
		if (name.size() > 4 && name.substr(name.size() - 4) == ".png") name.resize(name.size() - 4);
		capture(texture(p[0]), name);
		break;
	}
	case LOG: { std::string text((const char *)(p + 1), std::min<uint32_t>(p[0], (n - 1) * 4)); logf("[game] %s", text.c_str()); break; }
	case CREATE_BUFFER: createBuffer(p); break;
	case UPLOAD_BUFFER: uploadBuffer(p, false); break;
	case UPLOAD_BUFFER_NO_OVERWRITE: uploadBuffer(p, true); break;
	case UPLOAD_TEXTURE: uploadTexture(p); break;
	case CREATE_SHADER: createShader(p); break;
	case CREATE_LAYOUT: createLayout(p); break;
	case CREATE_STATE: createState(p, n); break;
	case CREATE_SRV: createView(p, OSrv); break;
	case CREATE_UAV: createView(p, OUav); break;
	case SET_SHADER: if (p[0] < 3 && R->shader[p[0]] != p[1]) { R->shader[p[0]] = p[1]; if (p[0] < 2) R->pipeDirty = true; } break;
	case SET_INPUT_LAYOUT: if (R->layout != p[0]) { R->layout = p[0]; R->pipeDirty = true; } break;
	case SET_TOPOLOGY: if (R->topo != p[0]) { if (topologyClass(R->topo) != topologyClass(p[0])) R->pipeDirty = true; R->topo = p[0]; } break;
	case SET_VERTEX_BUFFERS: {
		uint32_t s = p[0], c = p[1];
		for (uint32_t i = 0; i < c && s + i < 16; i++) {
			auto &v = R->vb[s + i];
			uint32_t nb = p[2 + i * 3], ns = p[3 + i * 3];
			if (v.stride != ns || !v.buf != !nb) R->pipeDirty = true;
			else if (v.buf != nb) { Buffer *ob = buffer(v.buf), *nbo = buffer(nb); if (!ob != !nbo || (ob && nbo && !ob->buf != !nbo->buf)) R->pipeDirty = true; }
			v.buf = nb; v.stride = ns; v.offset = p[4 + i * 3];
		}
		break;
	}
	case SET_INDEX_BUFFER: R->ib.buf = p[0]; R->ib.fmt = p[1]; R->ib.offset = p[2]; break;
	case SET_CBUFFERS: { uint32_t st = p[0], s = p[1], c = p[2]; if (st > 2) break; for (uint32_t i = 0; i < c && s + i < 16; i++) R->cb[st][s + i] = {p[3 + i * 3], p[4 + i * 3], p[5 + i * 3]}; break; }
	case SET_SRVS: { uint32_t st = p[0], s = p[1], c = p[2]; if (st > 2) break; for (uint32_t i = 0; i < c && s + i < 128; i++) R->srv[st][s + i] = p[3 + i]; break; }
	case SET_SAMPLERS: { uint32_t st = p[0], s = p[1], c = p[2]; if (st > 2) break; for (uint32_t i = 0; i < c && s + i < 16; i++) R->smp[st][s + i] = p[3 + i]; break; }
	case SET_UAVS: {
		uint32_t st = p[0], s0 = p[1], c = p[2];
		if (st > 2) break;
		for (uint32_t i = 0; i < c && s0 + i < 8; i++) {
			R->uav[st][s0 + i] = p[3 + i];
			if (p[3 + c + i] != 0xffffffff) setUavCounter(p[3 + i], p[3 + c + i]);
		}
		break;
	}
	case SET_RENDER_TARGETS: {
		for (int i = 0; i < 8; i++) R->rt[i] = {p[i * 4], p[1 + i * 4], p[2 + i * 4], p[3 + i * 4]};
		const uint32_t *q = p + 32;
		R->ds = {q[0], q[1], q[2], q[3], q[4]};
		R->rtDirty = true; R->pipeDirty = true;
		break;
	}
	case SET_BLEND: if (R->blendId != p[0]) R->pipeDirty = true; R->blendId = p[0]; R->blendFactor[0] = pf[1]; R->blendFactor[1] = pf[2]; R->blendFactor[2] = pf[3]; R->blendFactor[3] = pf[4]; R->blendMask = p[5]; break;
	case SET_DEPTH_STENCIL: R->dssId = p[0]; R->dssRef = p[1]; break;
	case SET_RASTER: R->rsId = p[0]; break;
	case SET_VIEWPORTS: R->hasViewport = p[0] > 0; if (p[0]) memcpy(R->viewport, pf + 1, sizeof R->viewport); break;
	case SET_SCISSORS: R->hasScissor = p[0] > 0; if (p[0]) memcpy(R->scissor, p + 1, sizeof R->scissor); break;
	case DRAW: draw(p); break;
	case CLEAR_STATE: resetState(); break;
	case COPY_REGION: copyRegion(p); break;
	case COPY_RESOURCE: copyResource(p[0], p[1]); break;
	case RESOLVE: resolve(p); break;
	case DISPATCH: dispatch(p[0], p[1], p[2]); break;
	case CLEAR_UAV: clearUav(p); break;
	case GENERATE_MIPS: generateMips(p[0]); break;
	case READBACK: readback(p); break;
	case COPY_COUNTER: copyCounter(p[0], p[1], p[2]); break;
	case CREATE_QUERY: createQuery(p); break;
	case BEGIN_QUERY: {
		Query *q = R->objs.as<Query>(p[0], OQuery);
		if (!q || !(q->type == 1 || q->type == 5)) break;
		q->slots.clear(); q->draws = 0;
		R->activeOcclusion = q;
		beginOcclusionInPass();
		break;
	}
	case END_QUERY: {
		Query *q = R->objs.as<Query>(p[0], OQuery);
		if (!q) break;
		q->seq = p[1];
		if (q->type == 1 || q->type == 5) {
			if (R->activeOcclusion == q) { endOcclusionInPass(); R->activeOcclusion = nullptr; }
			gQueriesEnded++; if (q->slots.empty()) gQueriesNoPass++; if (!q->draws) gQueriesNoDraw++; gQueryDraws += q->draws;
		}
		R->pendingQueries.push_back({q, p[1], q->slots, q->type, q->addr});
		q->slots.clear();
		break;
	}
	default: logOnce("op" + std::to_string(op), "Metal renderer: unknown opcode %u", op); break;
	}
}

// What the renderer holds, for the memory breakdown (GTA-217, NativeMemoryBreakdown.c). Any thread: atomics only.
extern "C" void PGRendererMemoryReport(PGRendererMemoryNumbers *out) {
	memset(out, 0, sizeof *out);
	auto pos = [](int64_t v) { return v > 0 ? (uint64_t)v : 0; };
	out->deviceAllocated = gReportDevice ? (uint64_t)gReportDevice.currentAllocatedSize : 0;
	for (int k = 0; k < PGTexKinds; k++) { out->textureBytes[k] = pos(gTexKindBytes[k].load()); out->textureCount[k] = pos(gTexKindCount[k].load()); }
	out->bcGameBytes = pos(gTextureStats.bcGameBytes.load());
	for (uint32_t f = 0; f < 1024; f++) {
		uint64_t v = pos(gFormatBytes[f].load());
		for (int i = 0; i < 8; i++) if (v > out->topFormatBytes[i]) {
			for (int j = 7; j > i; j--) { out->topFormat[j] = out->topFormat[j - 1]; out->topFormatBytes[j] = out->topFormatBytes[j - 1]; }
			out->topFormat[i] = f; out->topFormatBytes[i] = v; break;
		}
	}
	out->slabBytes = pos(gSlabTotal.load()); out->slabUsedBytes = pos(gBufferStats.inSlab.load());
	out->meshBytes = pos(gBufferStats.meshBytes.load()); out->meshCount = pos(gBufferStats.meshCount.load());
	out->ownMeshBytes = out->meshBytes > out->slabUsedBytes ? out->meshBytes - out->slabUsedBytes : 0;
	uint64_t all = pos(gBufferStats.bytes.load()); out->otherBufferBytes = all > out->meshBytes ? all - out->meshBytes : 0;
	out->frameRingBytes = pos(gFrameRingBytes.load()); out->constantCopyBytes = pos(gBufferStats.cbBytes.load()); out->blockCopyBytes = pos(gTextureStats.shadowBytes.load());
	if (PGMeshReleaseOn()) {
		uint64_t released, byFault, byForget, byTouch, mismatched, page, orphanedPages, orphanWritten, orphanRead;
		PGMeshReleaseStats(&released, &byFault, &byForget, &byTouch, &mismatched, &page, &orphanedPages, &orphanWritten, &orphanRead);
		uint64_t back = byFault + byForget + byTouch + orphanWritten + orphanRead;
		out->meshReleasedBytes = released > back ? (released - back) * page : 0;
	}
	out->drawableBytes = gDrawablePixels.load() * 4 * 3;		// BGRA8, maximumDrawableCount 3
	out->pipelines = gPipelinesMade.load();
}

static void report() {
	double now = nowMs();
	if (!R->statT) { R->statT = now; R->statDraws = R->draws; R->statPresents = R->presents; R->statSkips = R->skipped; R->statPending = R->pendingSkips; R->statCommits = R->commits; return; }
	if (now - R->statT < 10000) return;
	static int reports; reports++;
	if (gTraceHeld > 0 && (reports == 20 || reports == 30)) scanHeld();
	if (PGMeshReleaseOn()) {
		uint64_t released, byFault, byForget, byTouch, mismatched, page, orphanedPages, orphanWritten, orphanRead;
		PGMeshReleaseStats(&released, &byFault, &byForget, &byTouch, &mismatched, &page, &orphanedPages, &orphanWritten, &orphanRead);
		logf("[metal] mesh release: %.0f MB of engine memory handed back now; pages released %llu, put back when the game read them %llu, before a file read %llu, when their buffer went away %llu; kept because they changed %llu; left empty with their buffer %llu (written again %llu, read again %llu)",
		     (double)(released - byFault - byForget - byTouch - orphanWritten - orphanRead) * page / 1048576.0, (unsigned long long)released, (unsigned long long)byFault, (unsigned long long)byTouch,
		     (unsigned long long)byForget, (unsigned long long)mismatched, (unsigned long long)orphanedPages, (unsigned long long)orphanWritten, (unsigned long long)orphanRead);
		uint64_t shared = 0, kept = 0, held = 0; PGMeshShareStats(&shared, &kept, &held);
		if (shared) logf("[metal] mesh release, pages shared by several meshes (GTA-217): %llu released, %.1f MB of other bytes kept with them; %llu not handed back again (put back moments before); %llu put back without the remap", (unsigned long long)shared, kept / 1048576.0, (unsigned long long)held, (unsigned long long)PGMeshRemapFallbacks());
		{ uint64_t waits = 0, waitMaxUs = 0, slow = 0, late = 0; PGMeshFaultWaitStats(&waits, &waitMaxUs, &slow, &late);
		  if (shared || waits || slow) logf("[metal] mesh release, writes while a page is made writable again (GTA-245): %llu waited, longest %.1f ms; %llu kept faulting past 1,000 tries; %llu pages made writable again right after the read-only step", (unsigned long long)waits, waitMaxUs / 1000.0, (unsigned long long)slow, (unsigned long long)late); }
		{ int64_t dead = 0; uint64_t freedPieces = 0, reusable = 0; PGMeshDeadStats(&dead, &freedPieces, &reusable);
		  if (shared) logf("[metal] mesh release, destroyed meshes: %.1f MB of their bytes kept in page records (malloc), %llu pieces dropped once the engine freed them; %llu freed (reusable) pages left alone", dead / 1048576.0, (unsigned long long)freedPieces, (unsigned long long)reusable); }
		uint64_t checked = 0, bad = 0, badPage = 0, badOffset = 0; PGMeshVerifyStats(&checked, &bad, &badPage, &badOffset);
		if (checked) logf("[metal] mesh release check: %llu pages put back compared with their copy, %llu different%s", (unsigned long long)checked, (unsigned long long)bad,
		                  bad ? [NSString stringWithFormat:@" (first: engine page %llu, byte %llu; %s)", (unsigned long long)badPage, (unsigned long long)badOffset, PGMeshVerifyDetail()].UTF8String : "");
	}
	double frames = (double)(R->presents - R->statPresents);
	logf("[metal] fps: %.1f (%.0f frames, %.0f draws/frame, %.1f command buffers/frame), skipped +%llu (waiting for pipelines +%llu), clamped %llu, pipelines %u (%u compiling), renderer busy %.1f ms/frame",
	     frames * 1000 / (now - R->statT), frames, (R->draws - R->statDraws) / std::max(1.0, frames), (R->commits - R->statCommits) / std::max(1.0, frames),
	     (unsigned long long)(R->skipped - R->statSkips), (unsigned long long)(R->pendingSkips - R->statPending), (unsigned long long)R->clamped, R->pipesMade, R->pipesPending.load(),
	     R->busyMs / std::max(1.0, frames));
	std::string reasons;
	for (int i = 0; i < CReasons; i++) if (R->commitReasons[i]) { char b[64]; snprintf(b, sizeof b, "%s%s %.1f", reasons.empty() ? "" : ", ", kCommitNames[i], R->commitReasons[i] / std::max(1.0, frames)); reasons += b; }
	static const char *skipNames[] = {"no shader/layout", "untranslated shader", "no render target", "pipeline failed", "empty after clamp"};
	std::string skips;
	for (int i = 0; i < 5; i++) if (R->skipReasons[i]) { char b[64]; snprintf(b, sizeof b, "%s%s %llu", skips.empty() ? "" : ", ", skipNames[i], (unsigned long long)R->skipReasons[i]); skips += b; }
	logf("[metal] command buffers per frame: %s; skipped draws: %s", reasons.c_str(), skips.empty() ? "none" : skips.c_str());
	logf("[metal] stutter: %llu frames over 50 ms, longest %.0f ms", (unsigned long long)R->longFrames, R->worstFrameMs);
	{		// GTA-77: strip draws and their lists, and draws into packed float targets
		const double fr = std::max(1.0, frames);
		logf("[metal] strips (GTA-77): %.1f draws/frame (%.1f indexed, %.1f instanced, %.1f indirect), %.1f/frame as lists, %.1f/frame as strips; "
		     "%llu triangles became %llu (%llu repeating an index left out, %llu strip restarts); converted %llu (%llu per draw) in %.2f ms (%.3f ms/frame), "
		     "%llu from the cache, %zu lists cached in %.0f KB, %zu index buffers per draw",
		     gFix.stripDraws / fr, gFix.stripIndexed / fr, gFix.stripInstanced / fr, gFix.stripIndirect / fr, gFix.asList / fr, gFix.keptStrips / fr,
		     (unsigned long long)gFix.stripTris, (unsigned long long)gFix.listTris, (unsigned long long)gFix.degenerate, (unsigned long long)gFix.restarts,
		     (unsigned long long)gFix.converts, (unsigned long long)gFix.dynamicConverts, gFix.convertMs, gFix.convertMs / fr, (unsigned long long)gFix.hits,
		     gStripCache.size(), gStripCacheBytes / 1024.0, gStripDynamic.size());
		logf("[metal] packed float targets (GTA-77): %.1f of %.1f passes/frame draw into RG11B10/RGB9E5 (%.1f draws/frame, %.1f compute writes/frame); "
		     "NaN/infinity clamp %s, %.1f passes/frame cleaned; strips as lists %s",
		     gFix.packedPasses / fr, gFix.passes / fr, gFix.packedDraws / fr, gFix.packedDispatches / fr,
		     gNanClamp.load() == 2 ? "on (every float target)" : gNanClamp.load() == 3 ? "on (with small float targets)" : gNanClamp.load() ? "on" : "off", gFix.cleanedPasses / fr, gStripLists.load() ? "on" : "off");
		gFix = FixStats();
		if (gDrawStats > 0) {
			std::vector<std::pair<std::string, LabelStat>> list(gLabelStats.begin(), gLabelStats.end());
			std::sort(list.begin(), list.end(), [](auto &a, auto &b) { return a.second.strips + a.second.packed > b.second.strips + b.second.packed; });
			for (size_t i = 0; i < list.size() && i < 40; i++) {
				const LabelStat &s = list[i].second;
				logf("[metal] draw stats (GTA-77): %s: strips %llu (indexed %llu, instanced %llu, %.0f vertices each), packed float target draws %llu",
				     list[i].first.c_str(), (unsigned long long)s.strips, (unsigned long long)s.stripIndexed, (unsigned long long)s.stripInst,
				     s.strips ? (double)s.stripVerts / s.strips : 0.0, (unsigned long long)s.packed);
			}
			for (auto &kv : gPackedTargets) logf("[metal] draw stats (GTA-77): packed float target %s: %llu passes", kv.first.c_str(), (unsigned long long)kv.second);
			gLabelStats.clear(); gPackedTargets.clear();
		}
	}
	R->longFrames = 0; R->worstFrameMs = 0;
	const double MB = 1048576.0;
	logf("[metal] textures: GPU %.0f MB (BC: game counts %.0f MB, GPU holds %.0f MB), CPU block copies %.0f MB; BC readbacks %llu, BC copies %llu; create failures %llu, decode failures %llu",
	     gTextureStats.gpuBytes / MB, gTextureStats.bcGameBytes / MB, gTextureStats.bcGpuBytes / MB, gTextureStats.shadowBytes / MB,
	     (unsigned long long)gTextureStats.bcReadbacks.load(), (unsigned long long)gTextureStats.bcCopies.load(),
	     (unsigned long long)gTextureStats.createFailures.load(), (unsigned long long)gTextureStats.decodeFailures.load());
	PGNoteTextureRatio(gTextureStats.bcGpuBytes.load(), gTextureStats.bcGameBytes.load());		// the next boot's texture budget (GTA-123)
	std::string kinds;
	for (int k = 1; k < 8; k++) for (int srgb = 0; srgb < 2; srgb++) if (int64_t v = gTextureStats.kindBytes[k][srgb]) {
		char b[48]; snprintf(b, sizeof b, "%sBC%d%s %.0f MB", kinds.empty() ? "" : ", ", k, srgb ? " sRGB" : "", v / MB); kinds += b;
	}
	if (!kinds.empty()) logf("[metal] BC textures on the GPU by kind: %s", kinds.c_str());
	static double lastConvertReport;
	double convertNow = nowMs(), convertSpan = lastConvertReport ? convertNow - lastConvertReport : 0;
	lastConvertReport = convertNow;
	uint64_t convertMicros = gTextureStats.convertMicros.exchange(0), converts = gTextureStats.converts.exchange(0);
	if (converts && convertSpan > 0) logf("[metal] texture conversion on the CPU: %.0f ms for %llu uploads in the last %.0f s (%.3f cores)",
	                                    convertMicros / 1000.0, (unsigned long long)converts, convertSpan / 1000, convertMicros / 1000.0 / convertSpan);
	if (gETCBC) logf("[metal] BC as ETC2/EAC: %.0f ms of the conversion in the last %.0f s; BC1 with transparent texels made ASTC %llu, transparent texels shown opaque %llu, copies between ETC2 and ASTC %llu; %.1f MB of BC1 waiting for first use",
	                 gTextureStats.etcMicros.exchange(0) / 1000.0, convertSpan / 1000, (unsigned long long)gTextureStats.etcToASTC.load(), (unsigned long long)gTextureStats.etcAlphaLost.load(), (unsigned long long)gTextureStats.etcMismatch.load(),
	                 gTextureStats.etcPendingBytes.load() / 1048576.0);
	uint64_t ring = 0, ringBig = 0;
	for (auto &f : R->frames) { ring += f.chunks.size() * FrameRing::CHUNK; for (id<MTLBuffer> b : f.big) ringBig += b.length; }
	{
		static uint64_t lastResults, lastZero, lastFlips;
		uint64_t results = gOcclusionResults.load(), zero = gOcclusionZero.load(), flips = gOcclusionFlips.load();
		static uint64_t lastLate, lastReads;
		uint64_t late = PGOcclusionLate(), reads = PGOcclusionReads();
		if (results > lastResults) logf("[metal] occlusion: %llu answers, %.0f%% hidden, %llu flips between visible and hidden; the game read %llu, %llu not answered yet (GTA-176)",
		                                (unsigned long long)(results - lastResults), 100.0 * (zero - lastZero) / (results - lastResults), (unsigned long long)(flips - lastFlips),
		                                (unsigned long long)(reads - lastReads), (unsigned long long)(late - lastLate));
		lastResults = results; lastZero = zero; lastFlips = flips; lastLate = late; lastReads = reads;
		if (gQueriesEnded) logf("[metal] occlusion queries: %llu ended, %llu without a pass, %llu with no draw, %llu draws in them",
		                        (unsigned long long)gQueriesEnded, (unsigned long long)gQueriesNoPass, (unsigned long long)gQueriesNoDraw, (unsigned long long)gQueryDraws);
		gQueriesEnded = gQueriesNoPass = gQueriesNoDraw = gQueryDraws = 0;
	}
	logf("[metal] constant buffers: %lld (%.0f MB on the CPU), %lld ever written", (long long)gBufferStats.cbCount.load(), gBufferStats.cbBytes / MB, (long long)gBufferStats.cbWritten.load());
	logf("[metal] buffers: %lld (%.0f MB, %.0f MB in whole pages), meshes %lld (%.0f MB), %zu slabs; frame ring %.0f MB + %.0f MB large",
	     (long long)gBufferStats.count.load(), gBufferStats.bytes / MB, gBufferStats.pages / MB, (long long)gBufferStats.meshCount.load(),
	     gBufferStats.meshBytes / MB, (size_t)std::count_if(gSlabs.begin(), gSlabs.end(), [](const Slab &x) { return x.buf != nil; }), ring / MB, ringBig / MB);
	if (gSkipTopMip || gSkipBigTopMip) logf("[metal] %s: %lld textures without their largest level (%lld without two); %llu copies or readbacks needed one", gSkipTopMip ? "Lite" : "Big textures", (long long)gTextureStats.halfSize.load(), (long long)gTextureStats.quarterSize.load(), (unsigned long long)gTextureStats.missingLevel.load());
	memset(R->commitReasons, 0, sizeof R->commitReasons); memset(R->skipReasons, 0, sizeof R->skipReasons);
	R->statT = now; R->statDraws = R->draws; R->statPresents = R->presents; R->statSkips = R->skipped; R->statPending = R->pendingSkips; R->statCommits = R->commits; R->busyMs = 0;
}

// A packet that doesn't fit the ring (or runs past what the engine published) means the ring is corrupt:
// executing it would read engine memory as commands. Say so once and stop rendering.
[[noreturn]] static void ringFault(uint32_t op, uint32_t words, uint32_t tail, uint32_t head) {
	char line[160];
	snprintf(line, sizeof line, "Metal renderer: bad ring packet (op %u, %u words, tail %u, head %u, ring %u bytes); rendering stopped", op, words, tail, head, R->ringSize);
	pg_log(line);
	for (;;) sleep(60);
}

static void loop() {
	auto *hdr = (std::atomic<uint32_t> *)(R->mem + R->ring);
	uint32_t tail = RING_DATA;
	hdr[1].store(tail);
	hdr[2].store(1);
	uint32_t executed = 0, sinceYield = 0;
	for (;;) {
		@autoreleasepool {
			uint32_t head = hdr[0].load(std::memory_order_acquire);
			if (head == tail) {
				// nobody is producing: queries the engine may be polling must reach the GPU
				// (at most every 2 ms: the engine issues dozens of occlusion queries per frame between short ring gaps)
				// PG_QUERY_COMMIT_MS=0 sends them at once (GTA-92 A/B: idle-query buffers separate 60-FPS from 35-FPS windows).
				static double queryCommitMs = getenv("PG_QUERY_COMMIT_MS") ? atof(getenv("PG_QUERY_COMMIT_MS")) : 0;	// 0 since v1.4.3; 2 was the old wait
				bool waiting = !R->pendingQueries.empty();
				if (waiting && nowMs() - R->lastCommitMs >= queryCommitMs) { commit(CIdle); waiting = false; }
				hdr[5].store(1);
				double i0 = nowMs();
				if (hdr[0].load() == tail) PGGraphicsWait(R->ring, tail, (waiting ? 2 : 100) * 1000000ll);
				R->work.idle += nowMs() - i0;
				hdr[5].store(0);
				report();
				continue;
			}
			double t0 = nowMs();
			while (tail != head) {
				if (tail > R->ringSize - 8 || (tail < head && head - tail < 8)) ringFault(0, 0, tail, head);
				const uint32_t *base = (const uint32_t *)(R->mem + R->ring + tail);
				uint32_t op = base[0], n = base[1];
				if (op == WRAP) { tail = RING_DATA; continue; }
				if (n > (R->ringSize - tail - 8) / 4 || (tail < head && tail + 8 + n * 4 > head)) ringFault(op, n, tail, head);
				execute(op, base + 2, n);
				tail += n * 4 + 8;
				executed++;
				if (++sinceYield >= 512) {
					sinceYield = 0;
					hdr[3].fetch_add(executed); executed = 0;
					hdr[1].store(tail, std::memory_order_release);
					PGGraphicsNotify(R->ring + 4);
				}
			}
			R->busyMs += nowMs() - t0;
			if (executed) { hdr[3].fetch_add(executed); executed = 0; }
			hdr[1].store(tail, std::memory_order_release);
			PGGraphicsNotify(R->ring + 4);
		}
	}
}

// ---- startup ------------------------------------------------------------------------------------------------------------
static const char *kHelperShaders = R"(
#include <metal_stdlib>
using namespace metal;
struct V { float4 p [[position]]; };
vertex V pg_fullscreen(uint i [[vertex_id]]) { float2 q[3] = {float2(-1, -1), float2(3, -1), float2(-1, 3)}; V v; v.p = float4(q[i], 0, 1); return v; }
fragment float4 pg_blit(V in [[stage_in]], texture2d<float> t [[texture(0)]]) { return t.read(uint2(in.p.xy)); }
fragment float4 pg_alpha(V in [[stage_in]], texture2d<float> t [[texture(0)]]) { float a = t.read(uint2(in.p.xy)).a; return float4(a, a, a, 1); }
fragment float4 pg_ds(V in [[stage_in]], depth2d<float> d [[texture(0)]], texture2d<uint> s [[texture(1)]]) { float z = d.read(uint2(in.p.xy)); uint st = s.read(uint2(in.p.xy)).r; return float4(z != 0 ? 1.0 : 0.0, saturate(z * 20.0), st != 0 ? 1.0 : 0.0, 1); }
struct D { float depth [[depth(any)]]; };
fragment D pg_depth_copy(V in [[stage_in]], texture2d<float> t [[texture(0)]]) { D d; d.depth = t.read(uint2(in.p.xy)).x; return d; }
)";

static bool setup() {
	R->device = R->layer.device ?: MTLCreateSystemDefaultDevice();
	if (!R->device) return false;
	R->layer.device = R->device;
	R->layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
	R->layer.framebufferOnly = YES;
	R->layer.maximumDrawableCount = 3;
	R->queue = [R->device newCommandQueueWithMaxCommandBufferCount:64];
	R->completion = dispatch_semaphore_create(0);
	R->float32Filtering = (R->device.supports32BitFloatFiltering && !getenv("PG_NO_FLOAT32_FILTER")) || getenv("PG_FORCE_FLOAT32_FILTER");		// tests (GTA-77 striping)
	// PG_FORCE_BC_DECODE=1 keeps the CPU decode path on BC-capable GPUs (simulator checks of the iPhone path).
	gNativeBC = false;
	if (@available(iOS 16.4, *)) gNativeBC = R->device.supportsBCTextureCompression && !getenv("PG_FORCE_BC_DECODE"); // iOS 16.0-16.3: decoded
	// Packed 16-bit formats exist on every Apple GPU, but not on the simulator's (which aborts on them).
#if !TARGET_OS_SIMULATOR
	gPackedBC1 = !gNativeBC && !getenv("PG_NO_PACKED_BC1") && [R->device supportsFamily:MTLGPUFamilyApple3];
#endif
	// PG_NO_ASTC_BC1=1 keeps the decoded BC1 path (A1BGR5 or RGBA8), for comparisons.
	gASTCBC1 = !gNativeBC && !getenv("PG_NO_ASTC_BC1") && [R->device supportsFamily:MTLGPUFamilyApple2];
	gASTCBC3 = gASTCBC1 && !(getenv("PG_ASTC_BC3") && atoi(getenv("PG_ASTC_BC3")) == 0);		// on since v1.4.4 (Kevin); PG_ASTC_BC3=0 turns it off
	// BC1/BC4/BC5 as ETC2/EAC (GTA-217): every Apple GPU samples ETC2 and EAC. Off unless PG_ETC_BC=1: re-encoded BC1
	// shows on close-ups (texture_closeup.py, 2026-10-25: the stop sign's red gets blocky colour noise at Quality 900p
	// and at Ultra Performance 432p; 34 dB from the BC1 picture over 8.4 million game BC1 blocks). It would save half of
	// BC1's GPU memory: about 95 MB in the 6 GB city drive, 26 MB at Ultra Performance.
	{ const char *v = getenv("PG_ETC_BC");
	  gETCBC = !gNativeBC && v && atoi(v) != 0 && [R->device supportsFamily:MTLGPUFamilyApple2]; }
	// Lite build (the app sets PG_LITE from its Info.plist); PG_LITE_TEXTURES=0 keeps textures whole there.
	gSkipTopMip = getenv("PG_LITE") && strcmp(getenv("PG_LITE"), "0") && !(getenv("PG_LITE_TEXTURES") && !strcmp(getenv("PG_LITE_TEXTURES"), "0"));
	// Textures of at least 512×512 texels lose their largest level where BC is decoded, a quarter of their
	// memory (GTA-122; simulator: GPU textures −16%).
	// On by default since v1.4.3 at 512×512 (Kevin, 2026-10-20); PG_BIG_MIP_SKIP=0 turns it off, another size changes it.
	// Fixed-camera close-ups (Harness/scenarios/texture_closeup.py, Quality at 900p, 2026-10-24): GPU textures 1,304 MB
	// off, 1,122 at 1024, 941 at 512, 765 at 256. Road, sign and car look the same down to 512; a face at 1 m is a little
	// softer at 512 zoomed in; 256 visibly softens the pavement, so 512 stays.
	{ const char *v = getenv("PG_BIG_MIP_SKIP"); long side = v ? atol(v) : 512; if (side >= 256 && side <= 8192 && !gNativeBC) gSkipBigTopMip = (uint64_t)side * side; }
	// Lite: textures of at least N×N texels (the game's size) lose their second level too, where BC is decoded
	// (PG_LITE_BIG_MIP_SKIP=N, GTA-148; the app sets 512 below a 2,600 MB limit, GraphicsOptions.swift).
	{ const char *v = getenv("PG_LITE_BIG_MIP_SKIP"); long side = v ? atol(v) : 0; if (gSkipTopMip && side >= 256 && side <= 8192 && !gNativeBC) gLiteBigSkip = (uint64_t)side * side; }
	R->borderColors = [R->device supportsFamily:MTLGPUFamilyApple7];
	if (!loadShaderLibrary(R->device)) return false;
	// GTA-77: strips as indexed lists and the NaN/infinity clamp, on unless PG_STRIP_LISTS_OLD=1 / PG_NAN_CLAMP_OLD=1.
	{
		auto set = [](const char *name) { const char *v = getenv(name); return v && *v && strcmp(v, "0") != 0; };
		gLaunchStripLists = !set("PG_STRIP_LISTS_OLD");
		const char *all = getenv("PG_NAN_CLAMP");
		gLaunchNanClamp = set("PG_NAN_CLAMP_OLD") ? 0 : all && !strcmp(all, "all") ? 2 : all && !strcmp(all, "sim") ? 3 : 1;
		gStripLists.store(gLaunchStripLists); gNanClamp.store(gLaunchNanClamp);
		gDrawStats = set("PG_MR_DRAW_STATS");
		gUninitTrace = set("PG_MR_UNINIT");
		gPipeWaitSmall = set("PG_PIPE_WAIT_SMALL");
		if (const char *cold = getenv("PG_TEST_COLD_SHADERS_RESULT")) logf("TEST: the system's shader cache for this app: %s (PG_TEST_COLD_SHADERS).", cold);
		logf("Metal renderer: triangle strips drawn as %s; NaN/infinity clamp %s, in %u pixel shaders (GTA-77).",
		     gLaunchStripLists ? "indexed triangle lists" : "strips (PG_STRIP_LISTS_OLD)",
		     !gLaunchNanClamp ? "off (PG_NAN_CLAMP_OLD)" : gLaunchNanClamp == 2 ? "on every float target (PG_NAN_CLAMP=all)" :
		     gLaunchNanClamp == 3 ? "on RG11B10/RGB9E5 targets and float targets up to 256x256 (PG_NAN_CLAMP=sim)" : "on RG11B10/RGB9E5 targets", gNanClampShaders);
	}
	R->zeroBuffer = [R->device newBufferWithLength:65536 options:MTLResourceStorageModeShared];
	memset(R->zeroBuffer.contents, 0, 65536);
	R->visibility = [R->device newBufferWithLength:OCCLUSION_SLOTS * 8 options:MTLResourceStorageModeShared];
	MTLSamplerDescriptor *sd = [MTLSamplerDescriptor new];
	R->dummySampler = [R->device newSamplerStateWithDescriptor:sd];
	sd.compareFunction = MTLCompareFunctionAlways;
	R->dummyCompare = [R->device newSamplerStateWithDescriptor:sd];
	MTLDepthStencilDescriptor *dd = [MTLDepthStencilDescriptor new];
	R->noDepth = [R->device newDepthStencilStateWithDescriptor:dd];
	NSError *error = nil;
	id<MTLLibrary> helpers = [R->device newLibraryWithSource:[NSString stringWithUTF8String:kHelperShaders] options:nil error:&error];
	if (!helpers) { logf("Metal renderer: helper shaders failed: %s", error.localizedDescription.UTF8String); return false; }
	MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
	pd.vertexFunction = [helpers newFunctionWithName:@"pg_fullscreen"];
	pd.fragmentFunction = [helpers newFunctionWithName:@"pg_blit"];
	pd.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
	R->blitPipe = [R->device newRenderPipelineStateWithDescriptor:pd error:&error];
	R->capturePipe = R->blitPipe;
#if MR_TRACE
	pd.fragmentFunction = [helpers newFunctionWithName:@"pg_alpha"];
	T.alphaPipe = [R->device newRenderPipelineStateWithDescriptor:pd error:&error];
	pd.fragmentFunction = [helpers newFunctionWithName:@"pg_ds"];
	T.dsPipe = [R->device newRenderPipelineStateWithDescriptor:pd error:&error];
	if (!T.alphaPipe || !T.dsPipe) logf("Metal renderer: trace pipelines failed: %s", error.localizedDescription.UTF8String);
#endif
	MTLRenderPipelineDescriptor *dp = [MTLRenderPipelineDescriptor new];
	dp.vertexFunction = pd.vertexFunction;
	dp.fragmentFunction = [helpers newFunctionWithName:@"pg_depth_copy"];
	dp.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float;
	depthCopyPipe = [R->device newRenderPipelineStateWithDescriptor:dp error:&error];
	MTLDepthStencilDescriptor *always = [MTLDepthStencilDescriptor new];
	always.depthCompareFunction = MTLCompareFunctionAlways; always.depthWriteEnabled = YES;
	R->dssCache[0xdeb7ull] = [R->device newDepthStencilStateWithDescriptor:always];
	if (!R->blitPipe) { logf("Metal renderer: present pipeline failed: %s", error.localizedDescription.UTF8String); return false; }
	frameReportsInstall(R->device);
	gReportDevice = R->device;
	// GTA-217: which Metal device object the app got. A plain one is the GPU driver's (AGX...); a capture or validation layer
	// wraps it (CaptureMTLDevice, MTLDebugDevice, MTLToolsDevice...), which records every resource and costs memory.
	{
		BOOL captureTools = NO;
		if (@available(iOS 13.0, *)) captureTools = [MTLCaptureManager.sharedCaptureManager supportsDestination:MTLCaptureDestinationDeveloperTools];
		const char *ta = getenv("MTL_CAPTURE_ENABLED"), *dw = getenv("METAL_DEVICE_WRAPPER_TYPE"), *dl = getenv("MTL_DEBUG_LAYER"), *di = getenv("DYLD_INSERT_LIBRARIES");
		logf("Metal renderer: device object %s; capture to developer tools %s; MTL_CAPTURE_ENABLED=%s, METAL_DEVICE_WRAPPER_TYPE=%s, MTL_DEBUG_LAYER=%s, DYLD_INSERT_LIBRARIES=%s.",
		     NSStringFromClass([R->device class]).UTF8String, captureTools ? "possible" : "not possible", ta ?: "-", dw ?: "-", dl ?: "-", di ?: "-");
	}
	logf("Metal renderer: %s, 32-bit float filtering %s, border colours %s, BC textures %s.", R->device.name.UTF8String, R->float32Filtering ? "yes" : "no (nearest fallback)",
	     R->borderColors ? "yes" : "no", gNativeBC ? "native" : gETCBC && gASTCBC3 ? "decoded on the CPU (BC1, BC4, BC5 as ETC2/EAC, BC3 as ASTC)" : gASTCBC3 ? "decoded on the CPU (BC1 and BC3 as ASTC)" : gASTCBC1 ? "decoded on the CPU (BC1 as ASTC)" : gPackedBC1 ? "decoded on the CPU (BC1 as 16-bit)" : "decoded on the CPU");
	if (gSkipTopMip) logf("Metal renderer: Lite: the game's textures go to the GPU without their largest level.");
	else if (gSkipBigTopMip) logf("Metal renderer: textures of %llu texels or more go to the GPU without their largest level (PG_BIG_MIP_SKIP).", (unsigned long long)gSkipBigTopMip);
	if (gLiteBigSkip) logf("Metal renderer: Lite: textures of %llu texels or more go to the GPU without their two largest levels (PG_LITE_BIG_MIP_SKIP).", (unsigned long long)gLiteBigSkip);
	return true;
}

static void *threadMain(void *) {
	pthread_setname_np("gta5port.metal");
	@autoreleasepool {
		if (!setup()) {
			pg_log("Metal renderer could not start.");
			auto *hdr = (std::atomic<uint32_t> *)(R->mem + R->ring);
			hdr[2].store(2);
			for (;;) { hdr[1].store(hdr[0].load()); PGGraphicsNotify(R->ring + 4); usleep(5000); }
		}
	}
	loop();
	return nullptr;
}

}  // namespace mr

using namespace mr;

static CAMetalLayer *pendingLayer;

extern "C" void PGMetalRendererAttachLayer(void *layer) { pendingLayer = (__bridge CAMetalLayer *)layer; }

extern "C" bool PGMetalRendererAvailable(void) {
#if TARGET_OS_SIMULATOR
	NSString *name = @"shaders-iphonesimulator";
#elif TARGET_OS_MACCATALYST
	NSString *name = @"shaders-maccatalyst";
#else
	NSString *name = @"shaders-iphoneos";
#endif
	return [NSBundle.mainBundle URLForResource:name withExtension:@"metallib"] != nil;
}

static void startPeriodicShots(void);
extern "C" void PGStartMetalRenderer(void *memory, uint64_t memorySize, uint64_t ring, uint64_t ringSize) {
	R = new Renderer();
	R->mem = (uint8_t *)memory; R->memSize = memorySize; R->ring = ring; R->ringSize = (uint32_t)ringSize;
	R->layer = pendingLayer;
	pg_log("Connecting game graphics commands to the native Metal renderer.");
	pthread_attr_t attr;
	pthread_attr_init(&attr);
	pthread_attr_set_qos_class_np(&attr, QOS_CLASS_USER_INTERACTIVE, 0);
	pthread_attr_setstacksize(&attr, 8 << 20);
	pthread_t thread;
	pthread_create(&thread, &attr, threadMain, nullptr);
	pthread_attr_destroy(&attr);
	startPeriodicShots();
}

extern "C" uint64_t PGMetalPresentedFrames(void) { return presentedFrames.load(std::memory_order_relaxed); }

extern "C" double PGMetalRendererFPS(void) {
	if (!R) return 0;
	double last = R->lastPresent.load();
	return last && CACurrentMediaTime() - last < 1.5 ? R->fps.load() : 0;
}

// The next `frames` presented pictures as NativeFrames/<name>-000.png and on (debug channel "burst", GTA-176).
extern "C" void PGMetalRendererBurst(const char *name, int frames) {
	if (!R) return;
	std::lock_guard<std::mutex> g(R->captureLock);
	R->burstName = name; R->burstIndex = 0; R->burstLeft = frames < 0 ? 0 : frames > 300 ? 300 : frames;
}
extern "C" void PGMetalRendererCapture(const char *name) {
	if (!R) return;
	std::lock_guard<std::mutex> g(R->captureLock);
	R->captureName = name;
}
// Test (PG_TEST_FRAME_EVERY=<seconds>, GTA-241): the presented picture every that many seconds after the renderer starts,
// as NativeFrames/periodic/<PG_TEST_FRAME_PREFIX>t<seconds>.png, to see on a phone whether the ground has loaded mid-run.
static void startPeriodicShots(void) {
	const char *v = getenv("PG_TEST_FRAME_EVERY"); int every = v ? atoi(v) : 0;
	if (every < 2) return;
	const char *p = getenv("PG_TEST_FRAME_PREFIX"); std::string prefix = p ? p : "";
	dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
		for (int t = every; t <= 3600; t += every) {
			sleep(every);
			char name[96]; snprintf(name, sizeof name, "periodic/%st%04d", prefix.c_str(), t);
			PGMetalRendererCapture(name);
		}
	});
}
// GTA-77 tests: a picture (Documents/NativeFrames/<name>.png) drawn with these switch settings (strips as lists 0/1,
// NaN clamp 0/1/2); how many are still waiting; and the launch's settings.
extern "C" void PGMetalRendererQueueShot(const char *name, int stripLists, int nanClamp) {
	std::lock_guard<std::mutex> g(gShotLock);
	gShots.push_back({name, stripLists ? 1 : 0, nanClamp < 0 ? 0 : nanClamp > 3 ? 3 : nanClamp});
}
extern "C" int PGMetalRendererShotsPending(void) {
	std::lock_guard<std::mutex> g(gShotLock);
	return (int)gShots.size();
}
extern "C" void PGMetalRendererFixes(int *stripLists, int *nanClamp) {
	if (stripLists) *stripLists = gLaunchStripLists;
	if (nanClamp) *nanClamp = gLaunchNanClamp;
}
