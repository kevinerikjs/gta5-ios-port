// The app's graphics entry points (NativeGraphics.h), served by the native Metal renderer.
#include "NativeGraphics.h"
#include "MetalRenderer/MetalRenderer.h"
#import <Metal/Metal.h>
#include <stdlib.h>

extern "C" void pg_log(const char *);

void PGAttachMetalLayer(void *layer) { PGMetalRendererAttachLayer(layer); }
double PGRenderedFramesPerSecond(void) { return PGMetalRendererFPS(); }
void PGCaptureNativeFrame(const char *name) { PGMetalRendererCapture(name); }
void PGQueueTestShot(const char *name, int stripLists, int nanClamp) { PGMetalRendererQueueShot(name, stripLists, nanClamp); }
int PGTestShotsPending(void) { return PGMetalRendererShotsPending(); }
void PGRenderFixes(int *stripLists, int *nanClamp) { PGMetalRendererFixes(stripLists, nanClamp); }
void PGSetSharperUpscaling(int on) { PGMetalRendererSetUpscaling(on); }
void PGSetPresentInterval(double seconds) { PGMetalRendererSetPresentInterval(seconds); }
void PGShownFrameStats(double *perSecond, double *fastGapMs, double *medianGapMs, uint32_t *notShown) { PGMetalRendererShownStats(perSecond, fastGapMs, medianGapMs, notShown); }
void PGStartGraphics(void *memory, uint64_t memorySize, uint64_t ring, uint64_t ringSize, uint64_t) {
	if (!PGMetalRendererAvailable()) { pg_log("The Metal shader library is missing from the app: rebuild with the game's shaders."); return; }
	PGStartMetalRenderer(memory, memorySize, ring, ringSize);
}

int PGGPUReadsBC(void) {
	static int answer = -1;
	if (answer < 0) { id<MTLDevice> device = MTLCreateSystemDefaultDevice(); answer = 0; if (@available(iOS 16.4, *)) answer = device && device.supportsBCTextureCompression && !getenv("PG_FORCE_BC_DECODE"); }
	return answer;
}

// What BC textures take on the GPU per byte the engine budgets, in percent (GTA-123). The engine sizes texture
// streaming once at boot, so this is the ratio the renderer measured on this iPhone in earlier sessions, kept per
// texture path (BC3 as ASTC or decoded): a texture saving then turns into more sharp textures kept loaded. Before a
// first measurement: 140 with BC3 as ASTC, 200 with BC3 decoded (simulator soaks: 1.33 and 2.15).
static NSString *textureRatioKey(void) {
	bool astc3 = !(getenv("PG_ASTC_BC3") && atoi(getenv("PG_ASTC_BC3")) == 0);
	return astc3 ? @"pgTextureRatioASTC3" : @"pgTextureRatioDecoded";
}
int PGTextureRatioPercent(void) {
	if (PGGPUReadsBC()) return 100;
	NSInteger stored = [[NSUserDefaults standardUserDefaults] integerForKey:textureRatioKey()];
	if (stored >= 100 && stored <= 400) return (int)stored;
	return [textureRatioKey() isEqualToString:@"pgTextureRatioASTC3"] ? 140 : 200;
}
void PGNoteTextureRatio(int64_t gpuBytes, int64_t gameBytes) {
	if (PGGPUReadsBC() || gameBytes < (128ll << 20) || gpuBytes <= 0) return;		// too little loaded to say
	NSInteger ratio = (NSInteger)(gpuBytes * 100 / gameBytes);
	ratio = ratio < 100 ? 100 : ratio > 400 ? 400 : ratio;
	NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
	NSInteger old = [defaults integerForKey:textureRatioKey()];
	[defaults setInteger:old >= 100 && old <= 400 ? (old * 3 + ratio) / 4 : ratio forKey:textureRatioKey()];
}
