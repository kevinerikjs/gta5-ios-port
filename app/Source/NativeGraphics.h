#pragma once
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
void PGCaptureNativeFrame(const char *name);
double PGRenderedFramesPerSecond(void);
void PGAttachMetalLayer(void *layer);
void PGStartGraphics(void *memory,uint64_t memorySize,uint64_t ring,uint64_t ringSize,uint64_t debug);
// The GPU samples BC textures as they are (otherwise they are decoded, about 4 times larger).
int PGGPUReadsBC(void);
// GPU bytes per budgeted byte of BC textures, in percent, from earlier sessions on this device (GTA-123), and the
// renderer's live numbers that keep it current.
int PGTextureRatioPercent(void);
void PGNoteTextureRatio(int64_t gpuBytes, int64_t gameBytes);
// Settings › Sharper upscaling: MetalFX scales the picture to the screen's resolution (changes live).
void PGSetSharperUpscaling(int on);
// Frame rate 40 (ProMotion screens): each picture stays up at least this long; 0 for the other frame rates.
void PGSetPresentInterval(double seconds);
// Pictures that reached the screen since the last call (GTA-200): per second, the fastest 5% and the median gap between
// two in milliseconds (they follow the screen's refresh rate), and how many never showed.
void PGShownFrameStats(double *perSecond, double *fastGapMs, double *medianGapMs, uint32_t *notShown);
#ifdef __cplusplus
}
#endif
