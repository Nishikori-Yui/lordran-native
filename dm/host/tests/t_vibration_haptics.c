#include "../dm_vibration_haptics.h"
#include <assert.h>
#include <math.h>
#include <stdio.h>

static int near(float a, float b) { return fabsf(a - b) < 0.0001f; }

int main(void) {
    DmVibrationHapticsParameters parameters =
        dm_vibration_haptics_parameters(0.5f, 80.f, 0.5f, 320.f);
    float expected_sharpness = log2f(200.f / 40.f) / log2f(1252.f / 40.f);
    assert(near(parameters.intensity, sqrtf(0.5f)));
    assert(near(parameters.sharpness, expected_sharpness));

    parameters = dm_vibration_haptics_parameters(2.f, NAN, NAN, INFINITY);
    assert(near(parameters.intensity, 1.f));
    assert(near(parameters.sharpness,
                 log2f(160.f / 40.f) / log2f(1252.f / 40.f)));

    parameters = dm_vibration_haptics_parameters(0.f, 80.f, 0.f, 320.f);
    assert(parameters.intensity == 0.f);
    assert(parameters.sharpness >= 0.f && parameters.sharpness <= 1.f);
    puts("Core Haptics mapping: combined intensity, weighted dual-band frequency and clamps passed");
    return 0;
}
