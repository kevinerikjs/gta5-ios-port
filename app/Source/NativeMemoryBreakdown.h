// The memory breakdown (GTA-217): what the app's footprint (what iOS counts against its limit) is made of, in one
// log line every 30 s and on demand (debug channel "mem"). NativeMemoryBreakdown.c walks the app's memory; the engine
// and the renderer fill in what only they know.
#pragma once
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif

// EngineHost.c: the engine's memory as the engine itself sees it.
typedef struct {
	uint64_t base, size, capacity;			// the engine block: address, current size, reservation
	int regionCount;
	uint64_t regionBase[64], regionBytes[64];	// the engine's pools ("[wasm] region" lines), engine addresses
	double arenaMB, inUseMB;				// its malloc ("[wasm] mem" line, about every 10 s)
	double gameVirtualUsedMB, gameVirtualMB, resourceVirtualUsedMB, resourceVirtualMB;
	double gamePhysicalUsedMB, gamePhysicalMB, resourcePhysicalUsedMB, resourcePhysicalMB;
	uint64_t returnedBytes, returnedFrees;		// freed blocks handed back to iOS (GTA-34)
	uint64_t failedBytes, failedFrees;		// freed blocks iOS refused to take (GTA-241: a page mesh release protects in the range)
	uint64_t reuseFailedBytes;				// blocks handed out again that iOS refused to mark in use (GTA-241)
	uint64_t d3dCopyBytes, d3dCopies;			// the D3D layer's CPU copies (GTA-174)
	uint64_t videoBudgetMB, limitMB;			// the engine's texture budget and the app's limit at boot
} PGEngineMemoryNumbers;
void PGEngineMemoryReport(PGEngineMemoryNumbers *out);

// MRRenderer.mm: what the renderer holds. Texture kinds: see PGTextureKindNames.
enum { PGTexBCNative, PGTexBCASTC, PGTexBCETC, PGTexBCDecoded, PGTexPlain, PGTexTarget, PGTexStaging, PGTexKinds };
typedef struct {
	uint64_t deviceAllocated;					// MTLDevice.currentAllocatedSize
	uint64_t textureBytes[PGTexKinds], textureCount[PGTexKinds];
	uint64_t bcGameBytes;					// what the game counts for its BC textures
	uint32_t topFormat[8]; uint64_t topFormatBytes[8];	// the biggest pixel formats (MTLPixelFormat)
	uint64_t slabBytes, slabUsedBytes, ownMeshBytes, otherBufferBytes, meshBytes, meshCount;
	uint64_t frameRingBytes, constantCopyBytes, blockCopyBytes;	// blockCopy: BC blocks kept on the CPU for readbacks (malloc)
	uint64_t meshReleasedBytes;				// engine pages of meshes handed back (GTA-152)
	uint64_t drawableBytes;					// the layer's drawables (IOSurface)
	uint64_t pipelines;
} PGRendererMemoryNumbers;
void PGRendererMemoryReport(PGRendererMemoryNumbers *out);

// NativeThreads.c: the engine's function tables, one per engine thread (malloc).
uint64_t PGFunctionTableBytes(uint64_t *count);

// Writes the breakdown lines to the log. `reason`: "30 s", "debug" and so on. Thread-safe; takes a few ms.
void PGLogMemoryBreakdown(const char *reason);

#ifdef __cplusplus
}
#endif
