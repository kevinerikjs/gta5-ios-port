// The memory breakdown (GTA-217). iOS stops the app when its footprint (task_vm_info.phys_footprint) reaches the
// limit, so this says what the footprint is made of, in parts that add up to it:
//   - the engine block (the game's own memory, one mapping): what iOS holds of it, per engine pool, against what the
//     engine says it uses;
//   - the GPU: on iOS the footprint's graphics ledger (Metal textures and buffers, mapped or not), split by what the
//     renderer made (textures by kind and pixel format, mesh slabs, frame rings);
//   - malloc, with its zones and the biggest known users (the engine's function tables, BC block copies);
//   - IOSurface (the screen's drawables), Core Animation, stacks, the binary's data, other tagged memory;
//   - what's left over (unattributed), which should stay under 5% of the footprint.
// Each region's share of the footprint is its dirty pages less the reusable ones (memory handed back with
// MADV_FREE_REUSABLE is still dirty until iOS takes it, but no longer counts), plus its compressed or swapped pages.
// Logged every 30 s by the app (NativePortViewController) and on demand ("mem" on the debug channel).
#include "NativeMemoryBreakdown.h"
#include <mach/mach.h>
#include <mach/vm_statistics.h>
#include <malloc/malloc.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <dlfcn.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <TargetConditionals.h>

extern void pg_log(const char *line);
extern int PGMeshPageHandedBack(uint64_t offset);	// NativeMeshRelease.c

#define MB(x) ((unsigned long long)(((x) + (1ull << 19)) >> 20))	// rounded to the nearest MB

enum { GEngine, GGPU, GMalloc, GSurface, GAnimation, GStacks, GImages, GOther, GGroups };

// Address ranges of the loaded images' writable data segments (__DATA, __DATA_DIRTY, __DATA_CONST, __AUTH...).
static struct { uint64_t start, end; } imageData[512];
static int imageDataCount;
static void findImageData(void) {
	imageDataCount = 0;
	uint32_t images = _dyld_image_count();
	for (uint32_t i = 0; i < images && imageDataCount < 512; i++) {
		const struct mach_header_64 *h = (const struct mach_header_64 *)_dyld_get_image_header(i);
		if (!h || h->magic != MH_MAGIC_64) continue;
		intptr_t slide = _dyld_get_image_vmaddr_slide(i);
		const struct load_command *c = (const struct load_command *)(h + 1);
		for (uint32_t k = 0; k < h->ncmds && imageDataCount < 512; k++, c = (const struct load_command *)((const uint8_t *)c + c->cmdsize)) {
			if (c->cmd != LC_SEGMENT_64) continue;
			const struct segment_command_64 *seg = (const struct segment_command_64 *)c;
			if (!(seg->initprot & VM_PROT_WRITE)) continue;
			imageData[imageDataCount].start = seg->vmaddr + slide; imageData[imageDataCount].end = seg->vmaddr + slide + seg->vmsize; imageDataCount++;
		}
	}
}
static int inImageData(uint64_t start, uint64_t end) {
	for (int i = 0; i < imageDataCount; i++) if (start < imageData[i].end && end > imageData[i].start) return 1;
	return 0;
}

// Per-page dispositions (resident, dirty, reusable, paged out) of the engine block, to split it by pool. The call
// exists on iOS but isn't in its SDK headers, so it's looked up at run time.
typedef kern_return_t (*PageRangeQuery)(vm_map_t, mach_vm_address_t, mach_vm_size_t, mach_vm_address_t, mach_vm_size_t *);
static uint64_t engineHeld(PageRangeQuery query, uint64_t base, uint64_t start, uint64_t bytes, uint64_t *reusableOut) {
	enum { CHUNK = 4096 };
	static int dispositions[CHUNK];
	const uint64_t page = vm_page_size;
	uint64_t held = 0, reusable = 0;
	start &= ~(page - 1);
	for (uint64_t at = start; at < start + bytes; at += (uint64_t)CHUNK * page) {
		mach_vm_size_t count = CHUNK;
		uint64_t span = start + bytes - at; if (span > (uint64_t)CHUNK * page) span = (uint64_t)CHUNK * page;
		if (query(mach_task_self(), at, span, (mach_vm_address_t)(uintptr_t)dispositions, &count) != KERN_SUCCESS) break;
		for (mach_vm_size_t i = 0; i < count; i++) {
			int d = dispositions[i];
			if (PGMeshPageHandedBack(at + i * page - base)) continue;		// see the mesh release note in PGLogMemoryBreakdown
			if (d & VM_PAGE_QUERY_PAGE_PAGED_OUT) held += page;
			else if ((d & VM_PAGE_QUERY_PAGE_PRESENT) && (d & VM_PAGE_QUERY_PAGE_REUSABLE)) reusable += page;
			else if ((d & VM_PAGE_QUERY_PAGE_PRESENT) && (d & VM_PAGE_QUERY_PAGE_DIRTY)) held += page;
		}
	}
	if (reusableOut) *reusableOut += reusable;
	return held;
}

static const char *kTextureKinds[PGTexKinds] = {"BC native", "BC as ASTC", "BC as ETC2/EAC", "BC decoded", "plain", "targets", "staging"};
static const char *formatName(uint32_t f) {
	static char other[16];
	switch (f) {
	case 70: return "RGBA8"; case 71: return "RGBA8 sRGB"; case 80: return "BGRA8"; case 81: return "BGRA8 sRGB";
	case 10: return "R8"; case 30: return "RG8"; case 20: return "R16"; case 25: return "R16F"; case 65: return "RG16F"; case 115: return "RGBA16F";
	case 55: return "R32F"; case 105: return "RG32F"; case 125: return "RGBA32F"; case 90: return "RGB10A2"; case 92: return "RG11B10F"; case 93: return "RGB9E5";
	case 41: return "A1BGR5"; case 252: return "D32F"; case 253: return "S8"; case 255: return "D24S8"; case 260: return "D32FS8"; case 250: return "D16";
	case 204: return "ASTC4x4"; case 186: return "ASTC4x4 sRGB"; case 180: return "ETC2 RGB"; case 181: return "ETC2 RGB sRGB";
	case 178: return "ETC2 RGBA"; case 179: return "ETC2 RGBA sRGB"; case 170: return "EAC R11"; case 174: return "EAC RG11";
	case 182: return "ETC2 RGB A1"; case 183: return "ETC2 RGB A1 sRGB";
	case 130: return "BC1"; case 131: return "BC1 sRGB"; case 134: return "BC3"; case 135: return "BC3 sRGB"; case 140: return "BC4"; case 142: return "BC5"; case 152: return "BC7"; case 153: return "BC7 sRGB";
	default: snprintf(other, sizeof other, "fmt %u", f); return other;
	}
}

// Shader bytecode the engine still holds (GTA-217, the other port's "free the shader data after compiling"): every D3D
// shader blob ("DXBC", a 16-byte checksum, version 1, total size, chunk count) in the engine's resident memory, counted
// once per checksum. Only pages iOS holds are read, so the scan doesn't make anything resident. A few hundred ms.
static void scanEngineShaders(PageRangeQuery query, const PGEngineMemoryNumbers *e, char *out, size_t outSize) {
	out[0] = 0;
	if (!query || !e->base || !e->size) return;
	const uint64_t page = vm_page_size;
	enum { CHUNK = 4096 };
	static int dispositions[CHUNK];
	uint64_t blobs = 0, bytes = 0, copies = 0, copyBytes = 0, biggest = 0;
	enum { SEEN = 1 << 16 };
	uint64_t *seen = (uint64_t *)calloc(SEEN, sizeof *seen);		// checksum words, open addressing
	if (!seen) return;
	const uint8_t *mem = (const uint8_t *)(uintptr_t)e->base;
	for (uint64_t at = 0; at < e->size; at += (uint64_t)CHUNK * page) {
		mach_vm_size_t count = CHUNK; uint64_t span = e->size - at; if (span > (uint64_t)CHUNK * page) span = (uint64_t)CHUNK * page;
		if (query(mach_task_self(), e->base + at, span, (mach_vm_address_t)(uintptr_t)dispositions, &count) != KERN_SUCCESS) break;
		for (mach_vm_size_t i = 0; i < count; i++) {
			int d = dispositions[i];
			if (!((d & VM_PAGE_QUERY_PAGE_PRESENT) && !(d & VM_PAGE_QUERY_PAGE_REUSABLE)) && !(d & VM_PAGE_QUERY_PAGE_PAGED_OUT)) continue;
			if (PGMeshPageHandedBack(at + i * page)) continue;		// protected: reading it would put it back
			const uint8_t *p = mem + at + i * page;
			for (uint64_t o = 0; o + 32 <= page; o += 4) {
				if (p[o] != 'D' || memcmp(p + o, "DXBC", 4)) continue;
				uint32_t version, total, chunks; memcpy(&version, p + o + 20, 4); memcpy(&total, p + o + 24, 4); memcpy(&chunks, p + o + 28, 4);
				if (version != 1 || total < 32 || total > (4u << 20) || !chunks || chunks > 64) continue;
				uint64_t key; memcpy(&key, p + o + 4, 8); key |= 1;
				uint32_t slot = (uint32_t)(key * 0x9E3779B97F4A7C15ull >> 48) & (SEEN - 1);
				int dup = 0;
				for (int probe = 0; probe < 64; probe++, slot = (slot + 1) & (SEEN - 1)) {
					if (!seen[slot]) { seen[slot] = key; break; }
					if (seen[slot] == key) { dup = 1; break; }
				}
				if (dup) { copies++; copyBytes += total; } else { blobs++; bytes += total; if (total > biggest) biggest = total; }
			}
		}
	}
	free(seen);
	snprintf(out, outSize, " | shader bytecode in the engine: %llu blobs, %llu MB (biggest %llu KB), plus %llu copies, %llu MB",
	         (unsigned long long)blobs, MB(bytes), (unsigned long long)(biggest >> 10), (unsigned long long)copies, MB(copyBytes));
}

static pthread_mutex_t breakdownLock = PTHREAD_MUTEX_INITIALIZER;

void PGLogMemoryBreakdown(const char *reason) {
	pthread_mutex_lock(&breakdownLock);
	static PageRangeQuery query; static int looked;
	if (!looked) { looked = 1; query = (PageRangeQuery)dlsym(RTLD_DEFAULT, "mach_vm_page_range_query"); findImageData(); }

	task_vm_info_data_t vm = {0}; mach_msg_type_number_t vmCount = TASK_VM_INFO_COUNT;
	if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&vm, &vmCount) != KERN_SUCCESS) { pthread_mutex_unlock(&breakdownLock); return; }
	const int hasLedgers = vmCount >= TASK_VM_INFO_REV3_COUNT;
	PGEngineMemoryNumbers e; PGEngineMemoryReport(&e);
	PGRendererMemoryNumbers r; PGRendererMemoryReport(&r);

	// The region walk: each region's share of the footprint, by group and by tag.
	uint64_t group[GGroups] = {0}, gpuRegions = 0, surface = 0, ioKit = 0, tagBytes[256] = {0}, engineReusable = 0, untagged = 0;
	const uint64_t page = vm_page_size;
	const uint64_t engineLow = e.base, engineHigh = e.base + e.capacity + (64ull << 20);
	vm_address_t address = 0; natural_t depth = 0;
	for (int guard = 0; guard < 200000; guard++) {
		vm_size_t size = 0; vm_region_submap_info_data_64_t info; mach_msg_type_number_t count = VM_REGION_SUBMAP_INFO_COUNT_64;
		if (vm_region_recurse_64(mach_task_self(), &address, &size, &depth, (vm_region_recurse_info_t)&info, &count) != KERN_SUCCESS) break;
		if (info.is_submap) { depth++; continue; }
		uint64_t dirty = info.pages_dirtied > info.pages_reusable ? info.pages_dirtied - info.pages_reusable : 0;
		uint64_t bytes = (dirty + info.pages_swapped_out) * page;
		const unsigned tag = info.user_tag & 255;
		if (address >= engineLow && address < engineHigh) { group[GEngine] += bytes; engineReusable += (uint64_t)info.pages_reusable * page; }
		else if (bytes) {
			tagBytes[tag] += bytes;
			if (tag == VM_MEMORY_IOACCELERATOR) gpuRegions += bytes;
			else if (tag == VM_MEMORY_IOSURFACE) surface += bytes;
			else if (tag == VM_MEMORY_IOKIT) ioKit += bytes;
			else if ((tag >= VM_MEMORY_MALLOC && tag <= VM_MEMORY_MALLOC_PROB_GUARD) || tag == VM_MEMORY_DYLD_MALLOC) group[GMalloc] += bytes;
			else if (tag == VM_MEMORY_LAYERKIT) group[GAnimation] += bytes;
			else if (tag == VM_MEMORY_STACK) group[GStacks] += bytes;
			else if (inImageData(address, address + size)) group[GImages] += bytes;
			else { group[GOther] += bytes; if (!tag) untagged += bytes; }
		}
		address += size;
	}
	// The GPU: iOS counts Metal memory in the footprint's graphics ledger, whether or not it is mapped into the app
	// (private textures aren't). Where there is no such ledger (the simulator, whose GPU memory isn't in the
	// footprint), the mapped IOAccelerator, IOSurface and IOKit regions stand for it.
	const uint64_t graphics = hasLedgers ? (uint64_t)(vm.ledger_tag_graphics_footprint + vm.ledger_tag_graphics_footprint_compressed) : 0;
	const uint64_t mappedGPU = gpuRegions + surface + ioKit;
	if (graphics >= mappedGPU) { group[GGPU] = graphics; group[GSurface] = 0; }
	else { group[GGPU] = gpuRegions + ioKit; group[GSurface] = surface; }
#if TARGET_OS_SIMULATOR
	// The simulator's Metal memory is plain untagged memory of the app (in its footprint, not tagged as GPU).
	group[GGPU] += untagged; group[GOther] -= untagged;
#endif
	// Mesh release (GTA-152/217) protects a page and then marks it reusable. iOS takes it out of the footprint, but the
	// call answers "not permitted" on a protected page and the region still reports it dirty, not reusable (checked on
	// the lab Mac: footprint 257 -> 129 MB for 128 MB handed back, region dirty unchanged). So those pages come off here.
	group[GEngine] = group[GEngine] > r.meshReleasedBytes ? group[GEngine] - r.meshReleasedBytes : 0;
	uint64_t accounted = 0; for (int g = 0; g < GGroups; g++) accounted += group[g];
	const int64_t residual = (int64_t)vm.phys_footprint - (int64_t)accounted;

	// The engine block, by pool (engine addresses), against what the engine says it uses.
	uint64_t pools = 0, poolBytes = 0, perRegion[64] = {0};
	if (query && e.base) {
		for (int i = 0; i < e.regionCount; i++) { perRegion[i] = engineHeld(query, e.base, e.base + e.regionBase[i], e.regionBytes[i], NULL); pools += perRegion[i]; poolBytes += e.regionBytes[i]; }
	}
	const double poolUsedMB = e.gameVirtualUsedMB + e.resourceVirtualUsedMB + e.gamePhysicalUsedMB + e.resourcePhysicalUsedMB;
	const uint64_t poolUsed = (uint64_t)(poolUsedMB * 1048576.0);
	const uint64_t rest = group[GEngine] > pools ? group[GEngine] - pools : 0;

	// malloc zones: bytes handed out against what each zone holds.
	vm_address_t *zones = NULL; unsigned zoneCount = 0; char zoneText[400] = ""; int zt = 0;
	uint64_t mallocInUse = 0;
	if (malloc_get_all_zones(mach_task_self(), NULL, &zones, &zoneCount) == KERN_SUCCESS) {
		for (unsigned z = 0; z < zoneCount && z < 16; z++) {
			malloc_zone_t *zone = (malloc_zone_t *)zones[z]; if (!zone) continue;
			malloc_statistics_t st = {0}; malloc_zone_statistics(zone, &st);
			mallocInUse += st.size_in_use;
			if (st.size_allocated >= (1u << 20) && zt < (int)sizeof zoneText - 64)
				zt += snprintf(zoneText + zt, sizeof zoneText - zt, "%s%s %llu/%llu", zt ? ", " : "", zone->zone_name ? zone->zone_name : "?", MB(st.size_in_use), MB(st.size_allocated));
		}
	}
	uint64_t tables = 0, tableBytes = PGFunctionTableBytes(&tables);

	uint64_t textures = 0; for (int k = 0; k < PGTexKinds; k++) textures += r.textureBytes[k];
	const uint64_t buffers = r.slabBytes + r.ownMeshBytes + r.otherBufferBytes + r.frameRingBytes;

	char line[3200]; int at = 0;
#define PUT(...) do { if (at < (int)sizeof line - 1) at += snprintf(line + at, sizeof line - at, __VA_ARGS__); } while (0)
	PUT("Memory breakdown (%s): footprint %llu MB = engine %llu + GPU %llu + malloc %llu + IOSurface %llu + Core Animation %llu + stacks %llu + binary data %llu + other %llu; unattributed %lld MB (%.1f%%)",
	    reason, MB(vm.phys_footprint), MB(group[GEngine]), MB(group[GGPU]), MB(group[GMalloc]), MB(group[GSurface]), MB(group[GAnimation]), MB(group[GStacks]), MB(group[GImages]), MB(group[GOther]),
	    (long long)(residual / 1048576), vm.phys_footprint ? 100.0 * (double)residual / (double)vm.phys_footprint : 0);
	PUT(" | engine: pools %llu MB held of %llu MB (the engine uses %.0f), outside pools %llu MB (malloc arena %.0f MB, %.0f in use), handed back %llu MB not yet taken by iOS, returned %llu MB in %llu frees (refused %llu MB in %llu, in-use marks refused %llu MB), D3D CPU copies %llu MB, mesh pages handed back %llu MB",
	    MB(pools), MB(poolBytes), poolUsedMB, MB(rest), e.arenaMB, e.inUseMB, MB(engineReusable), MB(e.returnedBytes), (unsigned long long)e.returnedFrees, MB(e.failedBytes), (unsigned long long)e.failedFrees, MB(e.reuseFailedBytes), MB(e.d3dCopyBytes), MB(r.meshReleasedBytes));
	PUT(" | GPU: Metal %llu MB allocated; textures %llu MB (", MB(r.deviceAllocated), MB(textures));
	for (int k = 0; k < PGTexKinds; k++) PUT("%s%s %llu MB/%llu", k ? ", " : "", kTextureKinds[k], MB(r.textureBytes[k]), (unsigned long long)r.textureCount[k]);
	PUT("; the game counts %llu MB of BC), buffers %llu MB (mesh slabs %llu MB holding %llu, own meshes %llu, other %llu, frame rings %llu), meshes %llu MB in %llu, drawables %llu MB, pipelines %llu",
	    MB(r.bcGameBytes), MB(buffers), MB(r.slabBytes), MB(r.slabUsedBytes), MB(r.ownMeshBytes), MB(r.otherBufferBytes), MB(r.frameRingBytes), MB(r.meshBytes), (unsigned long long)r.meshCount, MB(r.drawableBytes), (unsigned long long)r.pipelines);
	PUT(" | malloc: %llu MB in use; engine function tables %llu MB (%llu), BC block copies %llu MB, constant buffer copies %llu MB; zones %s",
	    MB(mallocInUse), MB(tableBytes), (unsigned long long)tables, MB(r.blockCopyBytes), MB(r.constantCopyBytes), zoneText);
	pg_log(line);

	// The raw numbers, for checking the sum: task_vm_info, the formats, the pools, the budgets, the biggest tags.
	at = 0;
	PUT("Memory detail: internal %llu, compressed %llu, reusable %llu, purgeable volatile %llu, peak footprint %llu",
	    MB(vm.internal), MB(vm.compressed), MB(vm.reusable), MB(vm.purgeable_volatile_pmap), hasLedgers ? MB((uint64_t)vm.ledger_phys_footprint_peak) : 0);
	if (hasLedgers) PUT(", graphics %llu (+%llu compressed, not counted %llu), media %llu, neural %llu, purgeable nonvolatile %llu",
	    MB((uint64_t)vm.ledger_tag_graphics_footprint), MB((uint64_t)vm.ledger_tag_graphics_footprint_compressed), MB((uint64_t)vm.ledger_tag_graphics_nofootprint),
	    MB((uint64_t)vm.ledger_tag_media_footprint), MB((uint64_t)vm.ledger_tag_neural_footprint), MB((uint64_t)vm.ledger_purgeable_nonvolatile));
	PUT(", limit left %llu MB | mapped GPU regions: IOAccelerator %llu, IOSurface %llu, IOKit %llu | formats:", vmCount >= TASK_VM_INFO_REV4_COUNT ? MB(vm.limit_bytes_remaining) : 0, MB(gpuRegions), MB(surface), MB(ioKit));
	for (int i = 0; i < 8 && r.topFormatBytes[i] >= (1u << 20); i++) PUT(" %s %llu", formatName(r.topFormat[i]), MB(r.topFormatBytes[i]));
	PUT(" | pools:");
	for (int i = 0; i < e.regionCount; i++) PUT(" %lluMB@%llx=%llu", (unsigned long long)(e.regionBytes[i] >> 20), (unsigned long long)e.regionBase[i], MB(perRegion[i]));
	PUT(" (engine says game %.0f/%.0f, resource %.0f/%.0f, physical %.0f/%.0f + %.0f/%.0f MB; free but held at least %llu MB)",
	    e.gameVirtualUsedMB, e.gameVirtualMB, e.resourceVirtualUsedMB, e.resourceVirtualMB, e.gamePhysicalUsedMB, e.gamePhysicalMB, e.resourcePhysicalUsedMB, e.resourcePhysicalMB,
	    MB(pools > poolUsed ? pools - poolUsed : 0));
	PUT(" | budgets: engine textures %llu MB, limit %llu MB | biggest tags:", (unsigned long long)e.videoBudgetMB, (unsigned long long)e.limitMB);
	for (int n = 0; n < 6; n++) {
		int best = -1; for (int t = 0; t < 256; t++) if (tagBytes[t] >= (1u << 20) && (best < 0 || tagBytes[t] > tagBytes[best])) best = t;
		if (best < 0) break;
		PUT(" %d=%llu", best, MB(tagBytes[best])); tagBytes[best] = 0;
	}
	PUT(" (untagged other %llu)", MB(untagged));
	// "mem shaders" on the debug channel, or PG_MEM_SCAN=1 every time: the engine's shader bytecode.
	if (strstr(reason, "shaders") || (getenv("PG_MEM_SCAN") && atoi(getenv("PG_MEM_SCAN")))) { char scan[200]; scanEngineShaders(query, &e, scan, sizeof scan); PUT("%s", scan); }
	{ extern void PGMeshCoverage(char *out, size_t outSize); char cov[400]; PGMeshCoverage(cov, sizeof cov); PUT("%s", cov); }

	// Apple's GPU capture or validation layers cost hundreds of MB when something loads them (an Info.plist key, a
	// MTL_* variable, a debugger): name any loaded one.
	{
		int found = 0;
		for (uint32_t i = 0, n = _dyld_image_count(); i < n; i++) {
			const char *name = _dyld_get_image_name(i);
			if (name && (strstr(name, "MTLCapture") || strstr(name, "GPUTools") || strstr(name, "MTLDebug") || strstr(name, "MTLValidation") || strstr(name, "MetalTools"))) {
				const char *slash = strrchr(name, '/'); PUT("%s%s", found++ ? ", " : " | Metal debug layers loaded: ", slash ? slash + 1 : name);
			}
		}
		const char *vars[] = {"MTL_CAPTURE_ENABLED", "METAL_DEVICE_WRAPPER_TYPE", "MTL_DEBUG_LAYER", "MTL_SHADER_VALIDATION", "METAL_CAPTURE_ENABLED"};
		for (size_t i = 0; i < sizeof vars / sizeof *vars; i++) if (getenv(vars[i])) PUT("%s%s=%s", found++ ? ", " : " | Metal debug layers: ", vars[i], getenv(vars[i]));
		if (!found) PUT(" | Metal debug layers: none");
	}
#undef PUT
	pg_log(line);
	pthread_mutex_unlock(&breakdownLock);
}
