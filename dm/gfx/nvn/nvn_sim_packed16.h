// Expand the packed color formats absent from the Simulator GPU into RGBA8.
#pragma once
#include <stdint.h>
#include <stddef.h>
#include <string.h>

static inline int dm_sim_is_packed16(uint32_t format) { return format >= 40 && format <= 43; }
static inline uint8_t dm_sim_unorm8(unsigned value, unsigned maximum) {
    return (uint8_t)((value * 255 + maximum / 2) / maximum);
}
static inline void dm_sim_expand_packed16(uint32_t format, const void *source, size_t source_pitch,
                                         void *destination, size_t destination_pitch, size_t width, size_t height) {
    for (size_t y = 0; y < height; y++) for (size_t x = 0; x < width; x++) {
        uint16_t value; memcpy(&value, (const uint8_t *)source + y * source_pitch + 2 * x, 2);
        uint8_t *pixel = (uint8_t *)destination + y * destination_pitch + 4 * x;
        if (format == 40) {
            pixel[0] = dm_sim_unorm8(value >> 11, 31); pixel[1] = dm_sim_unorm8((value >> 5) & 63, 63);
            pixel[2] = dm_sim_unorm8(value & 31, 31); pixel[3] = 255;
        } else if (format == 41) {
            pixel[0] = dm_sim_unorm8(value >> 11, 31); pixel[1] = dm_sim_unorm8((value >> 6) & 31, 31);
            pixel[2] = dm_sim_unorm8((value >> 1) & 31, 31); pixel[3] = value & 1 ? 255 : 0;
        } else if (format == 42) {
            pixel[0] = (uint8_t)((value >> 12) * 17); pixel[1] = (uint8_t)(((value >> 8) & 15) * 17);
            pixel[2] = (uint8_t)(((value >> 4) & 15) * 17); pixel[3] = (uint8_t)((value & 15) * 17);
        } else {
            pixel[0] = dm_sim_unorm8((value >> 10) & 31, 31); pixel[1] = dm_sim_unorm8((value >> 5) & 31, 31);
            pixel[2] = dm_sim_unorm8(value & 31, 31); pixel[3] = value & 0x8000 ? 255 : 0;
        }
    }
}
