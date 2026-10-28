// BC textures as ETC2/EAC (GTA-217); see BCToETC.h.
#include "BCToETC.h"
#include "etcpak/ProcessRGB.hpp"
#include <stdlib.h>
#include <dispatch/dispatch.h>
#include <string.h>
#define BCDEC_STATIC
#define BCDEC_IMPLEMENTATION
#include "../Tools/bcdec/bcdec.h"

// etcpak's encoders read pixels as 0xAARRGGBB words (BGRA in memory); bcdec writes RGBA bytes.
static inline uint32_t bgra(const uint8_t *rgba) { return (uint32_t)rgba[2] | (uint32_t)rgba[1] << 8 | (uint32_t)rgba[0] << 16 | (uint32_t)rgba[3] << 24; }

extern "C" bool PGBC1HasTransparency(uint32_t w, uint32_t h, uint32_t d, uint32_t bpr, uint32_t rpi, const void *data, size_t size) {
	const uint32_t bw = (w + 3) / 4, bh = (h + 3) / 4, imageRows = rpi ? rpi : bh;
	if ((size_t)bw * 8 > bpr || (size_t)bpr * imageRows * (d - 1) + (size_t)bpr * bh > size) return false;
	for (uint32_t z = 0; z < d; z++) for (uint32_t y = 0; y < bh; y++) {
		const uint8_t *row = (const uint8_t *)data + (size_t)z * bpr * imageRows + (size_t)y * bpr;
		for (uint32_t x = 0; x < bw; x++) {
			const uint8_t *b = row + 8 * x;
			uint16_t c0 = (uint16_t)(b[0] | b[1] << 8), c1 = (uint16_t)(b[2] | b[3] << 8);
			if (c0 > c1) continue;
			uint32_t idx = (uint32_t)b[4] | (uint32_t)b[5] << 8 | (uint32_t)b[6] << 16 | (uint32_t)b[7] << 24;
			// index 3 in any of the 16 two-bit fields: both bits set
			if (idx & (idx >> 1) & 0x55555555u) return true;
		}
	}
	return false;
}

// One row of blocks: decoded into a strip of texels (4 rows), then encoded.
static void transcodeRow(int kind, const uint8_t *row, uint32_t bw, uint32_t *strip, uint64_t *to) {
	const size_t stripWidth = (size_t)bw * 4;
	for (uint32_t x = 0; x < bw; x++) {
		uint32_t *px = strip + 4 * x;
		if (kind == 1) {
			uint8_t rgba[64];
			bcdec_bc1(row + 8 * x, rgba, 16);
			for (int r = 0; r < 4; r++) for (int c = 0; c < 4; c++) px[r * stripWidth + c] = bgra(rgba + r * 16 + c * 4);
		} else if (kind == 4) {
			uint8_t v[16];
			bcdec_bc4(row + 8 * x, v, 4);
			for (int r = 0; r < 4; r++) for (int c = 0; c < 4; c++) px[r * stripWidth + c] = (uint32_t)v[r * 4 + c] << 16;
		} else {
			uint8_t v[32];
			bcdec_bc5(row + 16 * x, v, 8);
			for (int r = 0; r < 4; r++) for (int c = 0; c < 4; c++) px[r * stripWidth + c] = (uint32_t)v[r * 8 + c * 2] << 16 | (uint32_t)v[r * 8 + c * 2 + 1] << 8;
		}
	}
	if (kind == 1) CompressEtc2Rgb(strip, to, bw, stripWidth, true);
	else if (kind == 4) CompressEacR(strip, to, bw, stripWidth);
	else CompressEacRg(strip, to, bw, stripWidth);
}

extern "C" void *PGTranscodeBCToETC(int kind, uint32_t w, uint32_t h, uint32_t d, uint32_t bpr, uint32_t rpi, const void *data, size_t size,
                                   size_t *outSize, uint32_t *outBpr, uint32_t *outRpi) {
	if (kind != 1 && kind != 4 && kind != 5) return NULL;
	const size_t inBlock = kind == 5 ? 16 : 8, outBlock = kind == 5 ? 16 : 8;
	const uint32_t bw = (w + 3) / 4, bh = (h + 3) / 4, imageRows = rpi ? rpi : bh;
	if ((size_t)bw * inBlock > bpr || (size_t)bpr * imageRows * (d - 1) + (size_t)bpr * bh > size) return NULL;
	const size_t pitch = (size_t)bw * outBlock, image = pitch * bh, stripBytes = (size_t)bw * 16 * 4;
	uint8_t *out = (uint8_t *)malloc(image * d);
	if (!out) return NULL;
	const uint8_t *in = (const uint8_t *)data;
	const size_t rows = (size_t)bh * d;
	// Big uploads are encoded on several cores (the renderer thread waits less: GTA-39); small ones right here.
	if ((size_t)bw * rows >= 4096) {
		enum { BAND = 8 };		// rows of blocks per task
		__block bool failed = false;
		dispatch_apply((rows + BAND - 1) / BAND, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^(size_t band) {
			uint32_t *strip = (uint32_t *)malloc(stripBytes);
			if (!strip) { failed = true; return; }
			for (size_t r = band * BAND; r < rows && r < (band + 1) * BAND; r++) {
				const size_t z = r / bh, y = r % bh;
				transcodeRow(kind, in + z * bpr * imageRows + y * bpr, bw, strip, (uint64_t *)(out + z * image + y * pitch));
			}
			free(strip);
		});
		if (failed) { free(out); return NULL; }
	} else {
		uint32_t *strip = (uint32_t *)malloc(stripBytes);
		if (!strip) { free(out); return NULL; }
		for (size_t r = 0; r < rows; r++) {
			const size_t z = r / bh, y = r % bh;
			transcodeRow(kind, in + z * bpr * imageRows + y * bpr, bw, strip, (uint64_t *)(out + z * image + y * pitch));
		}
		free(strip);
	}
	*outSize = image * d; *outBpr = (uint32_t)pitch; *outRpi = bh;
	return out;
}
