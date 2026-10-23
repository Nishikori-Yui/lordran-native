#pragma once

#include <math.h>
#include "dm_input.h"

// Canonical Switch dual-band parameters after the guest's VibrationValue has
// crossed the HLE boundary. Output backends may apply device-specific limits,
// but they all start from this same finite, normalized representation.
typedef struct {
    float low_amplitude;
    float low_frequency;
    float high_amplitude;
    float high_frequency;
} DmVibrationBands;

static inline float dm_vibration_band_amplitude(float amplitude) {
    return isfinite(amplitude) ? fminf(1.f, fmaxf(0.f, amplitude)) : 0.f;
}

static inline float dm_vibration_band_frequency(float frequency, float fallback) {
    return isfinite(frequency) && frequency > 0.f ? frequency : fallback;
}

static inline DmVibrationBands dm_vibration_bands_from_frame(
    const DmVibrationFrame *frame) {
    if (!frame) return (DmVibrationBands){0};
    return (DmVibrationBands){
        .low_amplitude = dm_vibration_band_amplitude(frame->low_amplitude),
        .low_frequency = dm_vibration_band_frequency(frame->low_frequency, 160.f),
        .high_amplitude = dm_vibration_band_amplitude(frame->high_amplitude),
        .high_frequency = dm_vibration_band_frequency(frame->high_frequency, 320.f),
    };
}
