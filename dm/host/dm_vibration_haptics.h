#pragma once

#include <math.h>

typedef struct {
    float intensity;
    float sharpness;
} DmVibrationHapticsParameters;

static inline float dm_vibration_haptics_amplitude(float amplitude) {
    return isfinite(amplitude) ? fminf(1.f, fmaxf(0.f, amplitude)) : 0.f;
}

static inline float dm_vibration_haptics_frequency(float frequency, float fallback) {
    return isfinite(frequency) && frequency > 0.f ? frequency : fallback;
}

static inline DmVibrationHapticsParameters dm_vibration_haptics_parameters(
    float low_amplitude, float low_frequency,
    float high_amplitude, float high_frequency) {
    float low = dm_vibration_haptics_amplitude(low_amplitude);
    float high = dm_vibration_haptics_amplitude(high_amplitude);
    float amplitude_sum = low + high;
    float low_hz = dm_vibration_haptics_frequency(low_frequency, 160.f);
    float high_hz = dm_vibration_haptics_frequency(high_frequency, 320.f);
    // Core Haptics sharpness is perceptual and the Switch encoder is
    // logarithmic, so combine active bands in log-frequency space rather than
    // letting a high-Hz band dominate a linear average.
    float frequency_log_sum = low * logf(low_hz) + high * logf(high_hz);
    float weighted_frequency = amplitude_sum > 0.f
        ? expf(frequency_log_sum / amplitude_sum) : 160.f;
    weighted_frequency = fmaxf(40.f, fminf(1252.f, weighted_frequency));
    return (DmVibrationHapticsParameters){
        .intensity = fminf(1.f, sqrtf(low * low + high * high)),
        .sharpness = log2f(weighted_frequency / 40.f) / log2f(1252.f / 40.f),
    };
}
