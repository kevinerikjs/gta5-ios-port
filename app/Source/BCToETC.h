#pragma once
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
// BC textures as ETC2/EAC for GPUs that can't sample BC (A15 and older iPhones; GTA-217). ETC2 RGB and EAC R11 take
// 8 bytes per 4x4 block like BC1 and BC4, EAC RG11 16 bytes like BC5, so the texture keeps the size the game budgets
// (BC1 as ASTC 4x4 takes twice that). Each block is decoded and encoded again with etcpak (BSD 3-clause,
// Source/etcpak/LICENSE.txt), so it is close to the original, not identical; BC1 textures with transparent texels
// stay ASTC (exact), see MRRenderer.mm.
//
// kind 1 (BC1) to ETC2 RGB8, kind 4 (BC4) to EAC R11, kind 5 (BC5) to EAC RG11. A region of blocks (bpr bytes per
// block row, rpi block rows per image, d images), tightly packed; free() the result. NULL if the region doesn't fit.
void *PGTranscodeBCToETC(int kind, uint32_t w, uint32_t h, uint32_t d, uint32_t bpr, uint32_t rpi, const void *data, size_t size,
                         size_t *outSize, uint32_t *outBpr, uint32_t *outRpi);
// Whether any BC1 block of the region has a transparent texel (three-colour mode with index 3).
bool PGBC1HasTransparency(uint32_t w, uint32_t h, uint32_t d, uint32_t bpr, uint32_t rpi, const void *data, size_t size);
#ifdef __cplusplus
}
#endif
