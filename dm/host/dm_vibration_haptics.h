#pragma once

#include "dm_vibration_bands.h"

typedef struct {
    float intensity;
    float sharpness;
} DmVibrationHapticsParameters;

static inline DmVibrationHapticsParameters dm_vibration_haptics_parameters_for_bands(
    DmVibrationBands bands) {
    float low = bands.low_amplitude;
    float high = bands.high_amplitude;
    float amplitude_sum = low + high;
    // Core Haptics sharpness is perceptual and the Switch encoder is
    // logarithmic, so combine active bands in log-frequency space rather than
    // letting a high-Hz band dominate a linear average.
    float frequency_log_sum = low * logf(bands.low_frequency) +
        high * logf(bands.high_frequency);
    float weighted_frequency = amplitude_sum > 0.f
        ? expf(frequency_log_sum / amplitude_sum) : 160.f;
    weighted_frequency = fmaxf(40.f, fminf(1252.f, weighted_frequency));
    return (DmVibrationHapticsParameters){
        .intensity = fminf(1.f, sqrtf(low * low + high * high)),
        .sharpness = log2f(weighted_frequency / 40.f) / log2f(1252.f / 40.f),
    };
}

static inline DmVibrationHapticsParameters dm_vibration_haptics_parameters(
    float low_amplitude, float low_frequency,
    float high_amplitude, float high_frequency) {
    DmVibrationFrame frame = {
        .low_amplitude = low_amplitude,
        .low_frequency = low_frequency,
        .high_amplitude = high_amplitude,
        .high_frequency = high_frequency,
    };
    return dm_vibration_haptics_parameters_for_bands(
        dm_vibration_bands_from_frame(&frame));
}
