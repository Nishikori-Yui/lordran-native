#include "../dm_vibration_bands.h"
#include <assert.h>
#include <math.h>
#include <stdio.h>

static int near(float a, float b) { return fabsf(a - b) < 0.0001f; }

int main(void) {
    DmVibrationFrame frame = {
        .low_amplitude = 0.25f, .low_frequency = 80.f,
        .high_amplitude = 0.75f, .high_frequency = 320.f,
    };
    DmVibrationBands bands = dm_vibration_bands_from_frame(&frame);
    assert(near(bands.low_amplitude, 0.25f));
    assert(near(bands.low_frequency, 80.f));
    assert(near(bands.high_amplitude, 0.75f));
    assert(near(bands.high_frequency, 320.f));

    frame.low_amplitude = -1.f;
    frame.low_frequency = 0.f;
    frame.high_amplitude = 2.f;
    frame.high_frequency = NAN;
    bands = dm_vibration_bands_from_frame(&frame);
    assert(bands.low_amplitude == 0.f);
    assert(bands.low_frequency == 160.f);
    assert(bands.high_amplitude == 1.f);
    assert(bands.high_frequency == 320.f);

    bands = dm_vibration_bands_from_frame(NULL);
    assert(bands.low_amplitude == 0.f && bands.high_amplitude == 0.f);
    puts("Vibration bands: shared finite amplitude/frequency normalization passed");
    return 0;
}
