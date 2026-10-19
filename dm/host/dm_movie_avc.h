#pragma once
#include <CoreVideo/CoreVideo.h>
#include <stddef.h>
#include <stdint.h>

typedef struct dm_avc dm_avc;

dm_avc *dm_avc_create(void);
void dm_avc_destroy(dm_avc *decoder);
// Accept an AVCDecoderConfigurationRecord, Annex B parameter sets, or one SPS/PPS.
int dm_avc_configure(dm_avc *decoder, const uint8_t *data, size_t size);
// Input is one access unit in Annex B or the configured length-prefixed format.
int dm_avc_submit(dm_avc *decoder, const uint8_t *data, size_t size, int64_t pts_us);
int dm_avc_end(dm_avc *decoder);
int dm_avc_ready(const dm_avc *decoder);
// Returns a retained image in presentation order. The caller releases it.
CVPixelBufferRef dm_avc_pop(dm_avc *decoder, int64_t *pts_us);
int dm_avc_copy(CVPixelBufferRef image, uint8_t *dst, int width, int height, int rgba);
