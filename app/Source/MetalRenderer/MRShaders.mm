// Shader library, reflection table and D3D11 format tables of the native Metal renderer.
#include "MRInternal.h"
#include <TargetConditionals.h>
#include <stdarg.h>
#include <mutex>
#include <set>

namespace mr {

void logf(const char *format, ...) {
	char line[1024];
	va_list args;
	va_start(args, format);
	vsnprintf(line, sizeof line, format, args);
	va_end(args);
	pg_log(line);
}

void logOnce(const std::string &key, const char *format, ...) {
	static std::mutex lock;
	static std::set<std::string> seen;
	{
		std::lock_guard<std::mutex> guard(lock);
		if (seen.size() > 4000 || !seen.insert(key).second) return;
	}
	char line[1024];
	va_list args;
	va_start(args, format);
	vsnprintf(line, sizeof line, format, args);
	va_end(args);
	pg_log(line);
}

// ---- shader library ---------------------------------------------------------------------------------------------------
static id<MTLLibrary> library;
uint32_t gNanClampShaders = 0;
static std::unordered_map<std::string, std::unique_ptr<ShaderInfo>> shaders;

static ResKind resKind(NSString *k) {
	if ([k isEqualToString:@"ubo"]) return RUbo;
	if ([k isEqualToString:@"ro"]) return RStorageRO;
	if ([k isEqualToString:@"rw"]) return RStorageRW;
	if ([k isEqualToString:@"smp"]) return RSampler;
	if ([k isEqualToString:@"texms"]) return RTextureMS;
	if ([k isEqualToString:@"depth"]) return RDepth;
	if ([k isEqualToString:@"depthms"]) return RDepthMS;
	if ([k hasPrefix:@"st"]) return RStorageTex;
	return RTexture;
}
static TexDim texDim(NSString *d) {
	if ([d isEqualToString:@"1d"]) return D1;
	if ([d isEqualToString:@"2d"]) return D2;
	if ([d isEqualToString:@"2d-array"]) return D2Array;
	if ([d isEqualToString:@"3d"]) return D3;
	if ([d isEqualToString:@"cube"]) return DCube;
	if ([d isEqualToString:@"cube-array"]) return DCubeArray;
	return DNone;
}

bool loadShaderLibrary(id<MTLDevice> device) {
#if TARGET_OS_SIMULATOR
	NSString *name = @"shaders-iphonesimulator";
#elif TARGET_OS_MACCATALYST
	NSString *name = @"shaders-maccatalyst";
#else
	NSString *name = @"shaders-iphoneos";
#endif
	NSURL *url = [NSBundle.mainBundle URLForResource:name withExtension:@"metallib"];
	NSError *error = nil;
	library = url ? [device newLibraryWithURL:url error:&error] : nil;
	if (!library) { logf("Metal renderer: shader library %s missing (%s)", name.UTF8String, error.localizedDescription.UTF8String ?: "not bundled"); return false; }
	NSString *path = [NSBundle.mainBundle pathForResource:@"shader-reflection" ofType:@"jsonl"];
	NSData *data = path ? [NSData dataWithContentsOfFile:path] : nil;
	if (!data) { logf("Metal renderer: shader reflection missing"); return false; }
	const char *bytes = (const char *)data.bytes, *end = bytes + data.length;
	std::vector<ShaderInfo *> withConsts;
	size_t constBytes = 0;
	uint32_t uid = 1;
	while (bytes < end) {
		const char *nl = (const char *)memchr(bytes, '\n', end - bytes);
		if (!nl) nl = end;
		NSData *line = [NSData dataWithBytesNoCopy:(void *)bytes length:nl - bytes freeWhenDone:NO];
		bytes = nl + 1;
		if (!line.length) continue;
		NSDictionary *o = [NSJSONSerialization JSONObjectWithData:line options:0 error:nil];
		if (!o) continue;
		auto info = std::make_unique<ShaderInfo>();
		info->hash = [o[@"h"] UTF8String];
		info->label = [o[@"label"] UTF8String] ?: "";
		NSString *st = o[@"st"];
		info->stage = [st isEqualToString:@"vs"] ? 0 : [st isEqualToString:@"ps"] ? 1 : 2;
		for (NSArray *r in o[@"res"]) {
			ResBinding b{};
			b.kind = resKind(r[0]);
			b.binding = [r[1] unsignedShortValue];
			b.index = [r[2] unsignedCharValue];
			b.dim = texDim(r[3]);
			b.sample = [r[4] isEqualToString:@"uint"] ? SUint : [r[4] isEqualToString:@"sint"] ? SSint : SFloat;
			b.compare = [r[5] boolValue];
			b.size = [r[6] unsignedIntValue];
			info->res.push_back(b);
		}
		for (NSArray *p in o[@"pairs"]) {		// [sampler binding, texture binding]
			uint32_t s = [p[0] unsignedIntValue], t = [p[1] unsignedIntValue];
			for (auto &b : info->res) if (b.binding == t && (b.kind == RTexture)) b.pairedSampler = (int8_t)(s - 16);
			info->textureFloatSamplers |= 1u << ((s - 16) & 31);
		}
		for (NSNumber *n in o[@"in"]) info->inputs.push_back(n.unsignedIntValue);
		for (NSNumber *n in o[@"out"]) info->outputs.push_back(n.unsignedIntValue);
		NSArray *wg = o[@"wg"];
		for (NSUInteger i = 0; i < wg.count && i < 3; i++) info->wg[i] = [wg[i] unsignedIntValue];
		for (NSNumber *n in o[@"wgm"]) info->wgMem.push_back(n.unsignedIntValue);
		info->vid = [o[@"vid"] boolValue];
		info->iid = [o[@"iid"] boolValue];
		info->immediate = [o[@"imm"] boolValue];
		info->nanClamp = [o[@"nc"] boolValue];
		if (info->nanClamp) gNanClampShaders++;
		for (NSArray *a in o[@"alen"]) info->arrayLengths.push_back({[a[0] unsignedIntValue], [a[1] unsignedIntValue]});
		for (NSNumber *n in o[@"k"]) info->consts.push_back((uint32_t)n.unsignedLongLongValue);
		info->uid = uid++;
		if (!info->consts.empty()) { withConsts.push_back(info.get()); constBytes += (info->consts.size() * 16 + 255) & ~255ull; }
		shaders[info->hash] = std::move(info);
	}
	// every constant table in one buffer: element i of the table is row i (x component), as the WGSL declares array<vec4<u32>>
	if (constBytes) {
		id<MTLBuffer> table = [device newBufferWithLength:constBytes options:MTLResourceStorageModeShared];
		uint8_t *base = (uint8_t *)table.contents;
		NSUInteger at = 0;
		for (ShaderInfo *info : withConsts) {
			uint32_t *rows = (uint32_t *)(base + at);
			for (size_t i = 0; i < info->consts.size(); i++) rows[i * 4] = info->consts[i];
			info->constBuffer = table;
			info->constOffset = at;
			at += (info->consts.size() * 16 + 255) & ~255ull;
		}
	}
	logf("Metal renderer: %zu precompiled shaders (%zu with constant tables).", shaders.size(), withConsts.size());
	return true;
}

ShaderInfo *findShader(const std::string &hash) {
	auto it = shaders.find(hash);
	return it == shaders.end() ? nullptr : it->second.get();
}

id<MTLFunction> shaderFunction(ShaderInfo *info) {
	if (info->function || info->functionFailed) return info->function;
	info->function = [library newFunctionWithName:[NSString stringWithFormat:@"s_%s", info->hash.c_str()]];
	if (!info->function) { info->functionFailed = true; logf("Metal renderer: function s_%s missing from the library", info->hash.c_str()); }
	return info->function;
}

// ---- formats ----------------------------------------------------------------------------------------------------------
static const uint32_t BIND_DS = 0x40;

bool gNativeBC = false;
bool gPackedBC1 = false;
bool gASTCBC1 = false;
bool gASTCBC3 = false;
bool gETCBC = false;
bool gSkipTopMip = false;
uint64_t gSkipBigTopMip = 0;

FormatInfo mapFormat(uint32_t f, uint32_t bind) {
	bool ds = (bind & BIND_DS) != 0;
	FormatInfo m;
	switch (f) {
	case 2: m.format = MTLPixelFormatRGBA32Float; break;
	case 9: case 10: m.format = MTLPixelFormatRGBA16Float; break;
	case 11: m.format = MTLPixelFormatRGBA16Unorm; break;
	case 16: m.format = MTLPixelFormatRG32Float; break;
	case 19: case 20: m.format = MTLPixelFormatDepth32Float_Stencil8; break;
	case 23: case 24: m.format = MTLPixelFormatRGB10A2Unorm; break;
	case 26: m.format = MTLPixelFormatRG11B10Float; break;
	case 27: case 28: m.format = MTLPixelFormatRGBA8Unorm; m.alt = MTLPixelFormatRGBA8Unorm_sRGB; break;
	case 29: m.format = MTLPixelFormatRGBA8Unorm_sRGB; m.alt = MTLPixelFormatRGBA8Unorm; m.srgb = true; break;
	case 87: case 88: case 90: m.format = MTLPixelFormatBGRA8Unorm; m.alt = MTLPixelFormatBGRA8Unorm_sRGB; break;
	case 91: m.format = MTLPixelFormatBGRA8Unorm_sRGB; m.alt = MTLPixelFormatBGRA8Unorm; m.srgb = true; break;
	case 33: case 34: m.format = MTLPixelFormatRG16Float; break;
	case 35: m.format = MTLPixelFormatRG16Unorm; break;
	case 39: m.format = ds ? MTLPixelFormatDepth32Float : MTLPixelFormatR32Float; break;
	case 40: m.format = MTLPixelFormatDepth32Float; break;
	case 41: m.format = MTLPixelFormatR32Float; break;
	case 42: m.format = MTLPixelFormatR32Uint; break;
	case 43: m.format = MTLPixelFormatR32Sint; break;
	case 44: case 45: case 21: case 22: case 46: case 47: m.format = MTLPixelFormatDepth32Float_Stencil8; break;
	case 48: case 49: m.format = MTLPixelFormatRG8Unorm; break;
	case 53: m.format = ds ? MTLPixelFormatDepth16Unorm : MTLPixelFormatR16Float; break;
	case 54: m.format = MTLPixelFormatR16Float; break;
	case 55: case 56: m.format = MTLPixelFormatDepth16Unorm; break;
	case 57: m.format = MTLPixelFormatR16Uint; break;
	case 58: m.format = MTLPixelFormatR16Unorm; break;
	case 60: case 61: m.format = MTLPixelFormatR8Unorm; break;
	case 62: m.format = MTLPixelFormatR8Uint; break;
	case 63: m.format = MTLPixelFormatR8Snorm; break;
	case 51: m.format = MTLPixelFormatRG8Snorm; break;
	case 31: m.format = MTLPixelFormatRGBA8Snorm; break;
	case 30: m.format = MTLPixelFormatRGBA8Uint; break;
	case 3: m.format = MTLPixelFormatRGBA32Uint; break;
	case 1: m.format = MTLPixelFormatRGBA32Float; break;
	case 67: m.format = MTLPixelFormatRGB9E5Float; break;
	case 65: m.format = MTLPixelFormatR8Unorm; m.a8 = true; break;
	case 70: case 71: m.bc = 1; break;
	case 72: m.bc = 1; m.srgb = true; break;
	case 73: case 74: m.bc = 2; break;
	case 75: m.bc = 2; m.srgb = true; break;
	case 76: case 77: m.bc = 3; break;
	case 78: m.bc = 3; m.srgb = true; break;
	case 79: case 80: m.bc = 4; break;
	case 82: case 83: m.bc = 5; break;
	case 94: case 95: m.bc = 6; break;
	case 97: case 98: m.bc = 7; break;
	case 99: m.bc = 7; m.srgb = true; break;
	default:
		logOnce("fmt" + std::to_string(f), "Metal renderer: no format for DXGI %u (using RGBA8)", f);
		m.format = MTLPixelFormatRGBA8Unorm;
	}
	if (m.bc && gNativeBC) {		// the GPU samples the blocks directly
		m.bcNative = true;
		if (@available(iOS 16.4, *)) switch (m.bc) {		// gNativeBC is only set on 16.4+
		case 1: m.format = m.srgb ? MTLPixelFormatBC1_RGBA_sRGB : MTLPixelFormatBC1_RGBA; m.alt = m.srgb ? MTLPixelFormatBC1_RGBA : MTLPixelFormatBC1_RGBA_sRGB; break;
		case 2: m.format = m.srgb ? MTLPixelFormatBC2_RGBA_sRGB : MTLPixelFormatBC2_RGBA; m.alt = m.srgb ? MTLPixelFormatBC2_RGBA : MTLPixelFormatBC2_RGBA_sRGB; break;
		case 3: m.format = m.srgb ? MTLPixelFormatBC3_RGBA_sRGB : MTLPixelFormatBC3_RGBA; m.alt = m.srgb ? MTLPixelFormatBC3_RGBA : MTLPixelFormatBC3_RGBA_sRGB; break;
		case 4: m.format = MTLPixelFormatBC4_RUnorm; break;
		case 5: m.format = MTLPixelFormatBC5_RGUnorm; break;
		case 6: m.format = MTLPixelFormatBC6H_RGBUfloat; break;
		default: m.format = m.srgb ? MTLPixelFormatBC7_RGBAUnorm_sRGB : MTLPixelFormatBC7_RGBAUnorm; m.alt = m.srgb ? MTLPixelFormatBC7_RGBAUnorm : MTLPixelFormatBC7_RGBAUnorm_sRGB;
		}
	} else if (m.bc) {		// decoded on the CPU to an uncompressed format
		if (gETCBC && (m.bc == 1 || m.bc == 4 || m.bc == 5)) {		// re-encoded as ETC2/EAC at the BC size (GTA-217)
			m.etc = true;
			if (m.bc == 1) { m.format = m.srgb ? MTLPixelFormatETC2_RGB8_sRGB : MTLPixelFormatETC2_RGB8; m.alt = m.srgb ? MTLPixelFormatETC2_RGB8 : MTLPixelFormatETC2_RGB8_sRGB; }
			else m.format = m.bc == 4 ? MTLPixelFormatEAC_R11Unorm : MTLPixelFormatEAC_RG11Unorm;
			return m;
		}
		if ((m.bc == 1 || (m.bc == 3 && gASTCBC3)) && gASTCBC1) {
			m.astc = true;
			m.format = m.srgb ? MTLPixelFormatASTC_4x4_sRGB : MTLPixelFormatASTC_4x4_LDR;
			m.alt = m.srgb ? MTLPixelFormatASTC_4x4_LDR : MTLPixelFormatASTC_4x4_sRGB;
			return m;
		}
		if (m.bc == 1 && f == 71 && gPackedBC1) { m.format = MTLPixelFormatA1BGR5Unorm; return m; }
		switch (m.bc) {
		case 4: m.format = MTLPixelFormatR8Unorm; break;
		case 5: m.format = MTLPixelFormatRG8Unorm; break;
		case 6: m.format = MTLPixelFormatRGBA16Float; break;
		default:
			m.format = m.srgb ? MTLPixelFormatRGBA8Unorm_sRGB : MTLPixelFormatRGBA8Unorm;
			m.alt = m.srgb ? MTLPixelFormatRGBA8Unorm : MTLPixelFormatRGBA8Unorm_sRGB;
		}
	}
	return m;
}

// The format a view (SRV/RTV with an explicit DXGI format) reinterprets the texture as: only the sRGB twin differs.
MTLPixelFormat viewFormat(uint32_t dxgi, MTLPixelFormat tf) {
	if (!dxgi) return tf;
	FormatInfo m = mapFormat(dxgi, 0);
	if (m.format == tf) return tf;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wunguarded-availability-new"	// a BC texture only exists on 16.4+ (gNativeBC)
	switch (tf) {
	case MTLPixelFormatRGBA8Unorm: return m.srgb ? MTLPixelFormatRGBA8Unorm_sRGB : tf;
	case MTLPixelFormatRGBA8Unorm_sRGB: return m.srgb ? tf : MTLPixelFormatRGBA8Unorm;
	case MTLPixelFormatBGRA8Unorm: return m.srgb ? MTLPixelFormatBGRA8Unorm_sRGB : tf;
	case MTLPixelFormatBGRA8Unorm_sRGB: return m.srgb ? tf : MTLPixelFormatBGRA8Unorm;
	case MTLPixelFormatBC1_RGBA: return m.srgb ? MTLPixelFormatBC1_RGBA_sRGB : tf;
	case MTLPixelFormatBC1_RGBA_sRGB: return m.srgb ? tf : MTLPixelFormatBC1_RGBA;
	case MTLPixelFormatBC2_RGBA: return m.srgb ? MTLPixelFormatBC2_RGBA_sRGB : tf;
	case MTLPixelFormatBC2_RGBA_sRGB: return m.srgb ? tf : MTLPixelFormatBC2_RGBA;
	case MTLPixelFormatBC3_RGBA: return m.srgb ? MTLPixelFormatBC3_RGBA_sRGB : tf;
	case MTLPixelFormatBC3_RGBA_sRGB: return m.srgb ? tf : MTLPixelFormatBC3_RGBA;
	case MTLPixelFormatBC7_RGBAUnorm: return m.srgb ? MTLPixelFormatBC7_RGBAUnorm_sRGB : tf;
	case MTLPixelFormatBC7_RGBAUnorm_sRGB: return m.srgb ? tf : MTLPixelFormatBC7_RGBAUnorm;
	default: return tf;
	}
#pragma clang diagnostic pop
}

bool isDepthFormat(MTLPixelFormat f) {
	return f == MTLPixelFormatDepth32Float || f == MTLPixelFormatDepth16Unorm || f == MTLPixelFormatDepth32Float_Stencil8 || f == MTLPixelFormatStencil8;
}
bool hasStencil(MTLPixelFormat f) { return f == MTLPixelFormatDepth32Float_Stencil8 || f == MTLPixelFormatStencil8; }
bool isFloat32(MTLPixelFormat f) { return f == MTLPixelFormatR32Float || f == MTLPixelFormatRG32Float || f == MTLPixelFormatRGBA32Float; }

uint32_t bytesPerTexel(MTLPixelFormat f) {
	switch (f) {
	case MTLPixelFormatR8Unorm: case MTLPixelFormatR8Snorm: case MTLPixelFormatR8Uint: case MTLPixelFormatStencil8: return 1;
	case MTLPixelFormatA1BGR5Unorm:
	case MTLPixelFormatRG8Unorm: case MTLPixelFormatRG8Snorm: case MTLPixelFormatR16Float: case MTLPixelFormatR16Unorm:
	case MTLPixelFormatR16Uint: case MTLPixelFormatDepth16Unorm: return 2;
	case MTLPixelFormatRGBA16Float: case MTLPixelFormatRGBA16Unorm: case MTLPixelFormatRG32Float: case MTLPixelFormatDepth32Float_Stencil8: return 8;
	case MTLPixelFormatRGBA32Float: case MTLPixelFormatRGBA32Uint: return 16;
	default: return 4;
	}
}

MTLVertexFormat vertexFormat(uint32_t f, uint32_t *bytes) {
	struct E { uint32_t dxgi; MTLVertexFormat format; uint32_t bytes; };
	static const E table[] = {
		{2, MTLVertexFormatFloat4, 16}, {6, MTLVertexFormatFloat3, 12}, {16, MTLVertexFormatFloat2, 8}, {41, MTLVertexFormatFloat, 4},
		{3, MTLVertexFormatUInt4, 16}, {7, MTLVertexFormatUInt3, 12}, {17, MTLVertexFormatUInt2, 8}, {42, MTLVertexFormatUInt, 4},
		{4, MTLVertexFormatInt4, 16}, {8, MTLVertexFormatInt3, 12}, {18, MTLVertexFormatInt2, 8}, {43, MTLVertexFormatInt, 4},
		{10, MTLVertexFormatHalf4, 8}, {34, MTLVertexFormatHalf2, 4}, {54, MTLVertexFormatHalf, 2},
		{11, MTLVertexFormatUShort4Normalized, 8}, {35, MTLVertexFormatUShort2Normalized, 4},
		{12, MTLVertexFormatUShort4, 8}, {36, MTLVertexFormatUShort2, 4},
		{13, MTLVertexFormatShort4Normalized, 8}, {37, MTLVertexFormatShort2Normalized, 4},
		{14, MTLVertexFormatShort4, 8}, {38, MTLVertexFormatShort2, 4},
		{28, MTLVertexFormatUChar4Normalized, 4}, {30, MTLVertexFormatUChar4, 4}, {31, MTLVertexFormatChar4Normalized, 4}, {32, MTLVertexFormatChar4, 4},
		{49, MTLVertexFormatUChar2Normalized, 2}, {50, MTLVertexFormatUChar2, 2}, {51, MTLVertexFormatChar2Normalized, 2}, {52, MTLVertexFormatChar2, 2},
		{87, MTLVertexFormatUChar4Normalized_BGRA, 4}, {24, MTLVertexFormatUInt1010102Normalized, 4},
	};
	for (const E &e : table) if (e.dxgi == f) { if (bytes) *bytes = e.bytes; return e.format; }
	return MTLVertexFormatInvalid;
}

}  // namespace mr
