// Native Metal renderer: shared declarations.
//
// The game's D3D11 backend (wgpu_backend.cpp in the wasm build) writes a command ring into the shared engine memory. The
// web build executes it with a JavaScript WebGPU renderer (wgpu_worker.js); this renderer executes the same ring directly on Metal:
// D3D11 register slots map onto Metal argument-table indices (see ShaderTool/pgmsl.cc), shaders come precompiled from
// shaders-<sdk>.metallib, and constant buffers are versioned into a per-frame ring instead of being packed per draw.
#pragma once
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#include <stdint.h>
#include <string>
#include <vector>
#include <unordered_map>
#include <memory>
#include <atomic>
#include <map>

extern "C" void pg_log(const char *);
extern "C" uint32_t PGGraphicsNotify(uint64_t);
extern "C" uint32_t PGGraphicsWait(uint64_t address, uint32_t expected, int64_t timeoutNs);

namespace mr {

void logf(const char *format, ...) __attribute__((format(printf, 1, 2)));
void logOnce(const std::string &key, const char *format, ...) __attribute__((format(printf, 2, 3)));

// ---- Metal argument-table layout (keep in sync with ShaderTool/pgmsl.cc) --------------------------------------------------
enum : uint32_t {
	kConstTableBuffer = 14,		// binding 15: the shader's constant table
	kImmediateBuffer = 15,		// zero word + storage buffer sizes (Tint immediates)
	kFirstStorageBuffer = 16,
	kVertexBufferTop = 30,		// vertex buffer slot s -> buffer 30 - s
	kZeroVertexBuffer = 15,		// zero stream for shader inputs the input layout does not provide
	kUavTextureBase = 64,
	kNanClampBuffer = 30,		// pixel shaders: which colour outputs to clean of NaN/infinity (GTA-77, Scripts/build_metal_shaders.py)
};

// ---- shader reflection (GeneratedResources/shader-reflection.jsonl) -----------------------------------------------------
enum ResKind : uint8_t { RUbo, RStorageRO, RStorageRW, RSampler, RTexture, RTextureMS, RDepth, RDepthMS, RStorageTex };
enum TexDim : uint8_t { D1, D2, D2Array, D3, DCube, DCubeArray, DNone };
enum SampleKind : uint8_t { SFloat, SUint, SSint };
struct ResBinding {
	ResKind kind;
	uint16_t binding;		// WGSL binding (D3D register: b 0..15, s 16+, t 32+, u 160+, counter 176+)
	uint8_t index;			// Metal argument index
	TexDim dim;
	SampleKind sample;
	bool compare;
	uint32_t size;			// uniform struct size
	int8_t pairedSampler = -1;	// texture: a sampler binding index it is sampled with (32-bit float filtering fallback)
};
struct ShaderInfo {
	std::string hash, label;
	uint8_t stage = 0;		// 0 vs, 1 ps, 2 cs
	std::vector<ResBinding> res;
	std::vector<uint32_t> inputs, outputs;
	uint32_t wg[3] = {1, 1, 1};
	std::vector<uint32_t> wgMem;
	bool vid = false, iid = false, immediate = false;
	std::vector<std::pair<uint32_t, uint32_t>> arrayLengths;		// (Metal buffer index, size index)
	std::vector<uint32_t> consts;
	id<MTLBuffer> constBuffer = nil;
	NSUInteger constOffset = 0;
	id<MTLFunction> function = nil;
	bool functionFailed = false;
	uint32_t uid = 0;
	uint32_t textureFloatSamplers = 0;		// bit per sampler index that is paired with some texture
	bool nanClamp = false;		// pixel shader that reads pg_nanc (buffer kNanClampBuffer) and cleans its colour outputs (GTA-77)
};

// ---- objects ----------------------------------------------------------------------------------------------------------
enum ObjKind : uint8_t { OTexture, OBuffer, OShader, OLayout, OState, OSrv, OUav, OQuery };
struct Object { ObjKind kind; uint32_t oid; explicit Object(ObjKind k, uint32_t i) : kind(k), oid(i) {} virtual ~Object() {} };

struct Texture : Object {
	Texture(uint32_t i) : Object(OTexture, i) {}
	id<MTLTexture> tex = nil;
	MTLPixelFormat format = MTLPixelFormatInvalid;
	uint32_t dxgi = 0, bind = 0, dim = 2, width = 1, height = 1, depthOrLayers = 1, mips = 1, samples = 1;
	bool isDepth = false, hasStencil = false, shared = false, floatNoFilter = false;
	bool alphaView = false;		// A8 render target: stored as R8, sampled through a (0,0,0,R) swizzled view
	int bcKind = 0;			// 1..7: block-compressed source (decoded on the CPU unless bcNative)
	bool bcNative = false;		// stored as a Metal BC format: uploads, copies and readbacks use the blocks as they are
	bool astc = false;		// BC1 (or BC3, gASTCBC3) rewritten as ASTC 4x4 on upload (gASTCBC1); readbacks use the original blocks
	bool etc = false;		// BC1, BC4 or BC5 as ETC2 RGB / EAC R11 / EAC RG11 (gETCBC, GTA-217): the BC size, re-encoded
	bool etcDecided = false;	// BC1 as ETC2: its first upload had no transparent texel, or the GPU used it already (no more switching to ASTC)
	MTLTextureDescriptor *etcDesc = nil;	// BC1 as ETC2 until decided: the descriptor, to make it ASTC instead
	// BC1 as ETC2 until the GPU first uses it: the uploaded levels wait here, so that a transparent texel in any level
	// (often only the small ones) makes the texture ASTC before anything is encoded.
	struct EtcPending { uint32_t level, slice, x, y, z, w, h, d, bpr, rpi; std::vector<uint8_t> data; };
	std::vector<EtcPending> etcPending;
	bool etcAlpha = false;
	bool bcSrgb = false;
	// Lite build (gSkipTopMip): GPU levels dropped from the top. The GPU texture is that many times half
	// the size and has that many fewer levels; width/height/mips stay the game's, so GPU level = mip - skip.
	uint32_t skip = 0;
	uint64_t lastUse = 0;		// command buffer serial that last referenced it
	std::unordered_map<uint64_t, id<MTLTexture>> views;
	uint64_t gpuBytes = 0, bcGameBytes = 0;		// GPU allocation, and the compressed size the game budgets (for the report)
	uint8_t memKind = 0;		// the memory breakdown's texture kind (NativeMemoryBreakdown.h, GTA-217)
	std::unordered_map<uint64_t, std::vector<uint8_t>> compressedShadow;		// "mip:layer" -> original blocks, for CPU readbacks
	Texture *depthProxy = nullptr;		// r32float copy of a depth texture, for shaders that read it as float (if needed)
	bool proxyDirty = true;
	bool written = false;		// something wrote it (upload, clear, render, copy): GTA-77 read-before-write check
	~Texture() override;
};

struct Buffer : Object {
	Buffer(uint32_t i) : Object(OBuffer, i) {}
	id<MTLBuffer> buf = nil;		// GPU storage (vertex/index/storage/indirect)
	uint32_t size = 0, bind = 0, misc = 0, stride = 0, bytes = 0;
	uint64_t lastUse = 0;
	// constant buffer: CPU shadow, materialised into the frame ring on first bind after a change
	std::vector<uint8_t> shadow;
	uint64_t cbFrame = UINT64_MAX;
	id<MTLBuffer> cbBuf = nil;
	NSUInteger cbOff = 0;
	uint32_t cbCap = 0, cbPad = 0;
	uint32_t version = 0;
	id<MTLBuffer> counter = nil;		// UAV append/consume counter
	uint64_t counted = 0;		// bytes added to the buffer statistics (report)
	// A small mesh buffer lives in a shared slab (GTA-34): its bytes start at `base` in `buf`. Every use of
	// buf adds base. slab is the slab's index, or -1 for a buffer of its own.
	NSUInteger base = 0;
	int32_t slab = -1;
	// Engine pages of this mesh's source handed back to iOS (GTA-152, NativeMeshRelease.c); their bytes are read
	// back from buf, so they're put back before buf changes or goes away.
	uint64_t meshPage = 0;
	uint32_t meshPages = 0;
	~Buffer() override;
};

struct Shader : Object {
	Shader(uint32_t i) : Object(OShader, i) {}
	ShaderInfo *info = nullptr;
	uint32_t stage = 0;
	std::string hash;
	struct Sig { uint32_t sem, idx, reg, mask; };
	std::vector<Sig> sig;
};

struct LayoutEl { uint32_t sem, idx, fmt, slot, offset, cls, rate; };
struct Layout : Object {
	Layout(uint32_t i) : Object(OLayout, i) {}
	std::vector<LayoutEl> els;
	std::vector<std::pair<uint32_t, uint32_t>> slots;		// (slot, class) once per slot
};

struct State : Object {
	State(uint32_t i) : Object(OState, i) {}
	uint32_t skind = 0;		// 0 blend, 1 depth-stencil, 2 raster, 3 sampler
	std::vector<uint32_t> words;
	id<MTLSamplerState> sampler = nil, samplerNearest = nil;
	id<MTLDepthStencilState> dss[4] = {nil, nil, nil, nil};
	uint64_t hash = 0;
};

struct View : Object {
	View(ObjKind k, uint32_t i) : Object(k, i) {}
	uint32_t res = 0;
	bool isBuf = false;
	uint32_t fmt = 0, vdim = 0, a = 0, b = 0, c = 0, d = 0, flags = 0;
	std::unordered_map<uint64_t, id<MTLTexture>> views;
};

struct Query : Object {
	Query(uint32_t i) : Object(OQuery, i) {}
	uint32_t type = 0;
	uint64_t addr = 0;
	std::vector<uint32_t> slots;
	uint32_t seq = 0;
	uint32_t draws = 0;		// draws while it was active (GTA-176)
};

// ---- formats ----------------------------------------------------------------------------------------------------------
struct FormatInfo {
	MTLPixelFormat format = MTLPixelFormatRGBA8Unorm;
	MTLPixelFormat alt = MTLPixelFormatInvalid;		// sRGB/linear twin (views)
	int bc = 0;			// BC1..7 source
	bool srgb = false, a8 = false;
	bool bcNative = false;		// kept compressed on the GPU (gNativeBC), not decoded on the CPU
	bool astc = false;		// BC1 (or BC3, gASTCBC3) stored as ASTC 4x4 (gASTCBC1)
	bool etc = false;		// BC1/BC4/BC5 stored as ETC2 RGB / EAC R11 / EAC RG11 (gETCBC)
};
// The GPU samples BC1-7 itself (Apple silicon iPads and Macs; not iPhones): BC textures stay
// compressed, 2 to 8 times smaller than decoded. Set once by the renderer before any texture.
extern bool gNativeBC;
// Decoded BC1 (non-sRGB) stored as 16-bit A1BGR5 instead of RGBA8: BC1 has only 1-bit alpha and
// 5:6:5 colours, so this halves the largest share of decoded texture memory on iPhones.
extern bool gPackedBC1;
// BC1 rewritten block by block as ASTC 4x4 (Source/BC1ToASTC.c): 8 bits per texel, half of A1BGR5 and a
// quarter of RGBA8, for sRGB BC1 too. Every Apple GPU reads ASTC; takes precedence over gPackedBC1.
extern bool gASTCBC1;
extern bool gASTCBC3;
// BC1 as ETC2 RGB (half of ASTC 4x4: BC1's own 4 bits per texel), BC4 as EAC R11 and BC5 as EAC RG11 (GTA-217), where the
// GPU can't sample BC. Re-encoded by etcpak (Source/BCToETC.cpp), so close to the original but not exact. A BC1
// texture whose first upload has transparent texels stays ASTC. PG_ETC_BC=0 turns it off.
extern bool gETCBC;		// BC3 as ASTC too (on; PG_ASTC_BC3=0 or Settings › Experimental turns it off; lossy alpha, GTA-118)
// Lite build: the game's loaded textures go to the GPU without their largest mip level (a quarter
// of the memory; at phone render resolutions that level is rarely sampled), as consoles shipped them.
extern bool gSkipTopMip;
// The same for big textures only (GTA-122): at least this many texels (512×512 by default; PG_BIG_MIP_SKIP=N, 0 = off),
// on GPUs that decode BC, where those textures take the most memory. 0 = off.
extern uint64_t gSkipBigTopMip;
FormatInfo mapFormat(uint32_t dxgi, uint32_t bind);
MTLPixelFormat viewFormat(uint32_t dxgi, MTLPixelFormat textureFormat);
bool isDepthFormat(MTLPixelFormat f);
bool hasStencil(MTLPixelFormat f);
uint32_t bytesPerTexel(MTLPixelFormat f);
bool isFloat32(MTLPixelFormat f);
MTLVertexFormat vertexFormat(uint32_t dxgi, uint32_t *bytes);

// ---- shader library ---------------------------------------------------------------------------------------------------
bool loadShaderLibrary(id<MTLDevice> device);
extern uint32_t gNanClampShaders;		// pixel shaders in the library that carry the NaN/infinity clean (GTA-77)
ShaderInfo *findShader(const std::string &hash);
id<MTLFunction> shaderFunction(ShaderInfo *info);

}  // namespace mr
