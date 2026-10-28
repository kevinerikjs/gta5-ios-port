#pragma once
#include <stdint.h>
#include <stdbool.h>
#ifdef __cplusplus
extern "C" {
#endif
// Native Metal renderer (Source/MetalRenderer): executes the game's graphics command ring directly on Metal.
bool PGMetalRendererAvailable(void);
void PGMetalRendererAttachLayer(void *layer);
void PGStartMetalRenderer(void *memory, uint64_t memorySize, uint64_t ring, uint64_t ringSize);
double PGMetalRendererFPS(void);
void PGMetalRendererCapture(const char *name);
void PGMetalRendererSetUpscaling(int on);
// Each picture stays on screen at least this long (0: as the frame limiter allows). 1/40 s gives an even 40 FPS on a 120 Hz screen.
void PGMetalRendererSetPresentInterval(double seconds);
// Pictures shown on screen since the last call (GTA-200): per second, the fastest 5% and the median gap between two, and
// how many never showed.
void PGMetalRendererShownStats(double *perSecond, double *fastGapMs, double *medianGapMs, uint32_t *notShown);
// GTA-77 tests: queue a picture drawn with these settings (strips as lists 0/1, NaN clamp 0 off / 1 packed targets /
// 2 every float target), how many are waiting, and what the launch chose (PG_STRIP_LISTS_OLD, PG_NAN_CLAMP_OLD).
void PGMetalRendererQueueShot(const char *name, int stripLists, int nanClamp);
int PGMetalRendererShotsPending(void);
void PGMetalRendererFixes(int *stripLists, int *nanClamp);
#ifdef __cplusplus
}
#endif
