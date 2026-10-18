#include "../Sources/dm_camera_swipe.h"
#include <assert.h>
#include <stdio.h>

int main(void) {
    dm_camera_swipe s = {0};
    int32_t rx, ry;
    dm_camera_swipe_begin(&s, 400, 200);
    dm_camera_swipe_sample(&s, 1.0 / 60, &rx, &ry);
    assert(rx == 0 && ry == 0);
    dm_camera_swipe_move(&s, 400.5, 200.5);
    dm_camera_swipe_sample(&s, 1.0 / 60, &rx, &ry);
    assert(rx == 0 && ry == 0);   // A tap or small jitter does not rotate.

    dm_camera_swipe_move(&s, 405, 200);
    dm_camera_swipe_sample(&s, 1.0 / 60, &rx, &ry);
    assert(rx == 16384 && ry == 0);
    dm_camera_swipe_sample(&s, 1.0 / 60, &rx, &ry);
    assert(rx == 0 && ry == 0);   // A stationary finger stops the camera.
    dm_camera_swipe_move(&s, 400, 195);
    dm_camera_swipe_sample(&s, 1.0 / 60, &rx, &ry);
    assert(rx == -16384 && ry == 16384);

    dm_camera_swipe_move(&s, 500, 95);
    dm_camera_swipe_sample(&s, 1.0 / 60, &rx, &ry);
    assert(rx > 0 && ry > 0 && hypot(rx, ry) <= 32768);
    dm_camera_swipe_end(&s);
    dm_camera_swipe_move(&s, 900, 100);
    dm_camera_swipe_sample(&s, 1.0 / 60, &rx, &ry);
    assert(rx == 0 && ry == 0);   // Release/cancel discards pending motion.
    dm_camera_swipe_begin(&s, 50, 50);
    dm_camera_swipe_sample(&s, 1.0 / 60, &rx, &ry);
    assert(rx == 0 && ry == 0);   // Re-touch does not reuse the previous origin.

    dm_camera_swipe_move(&s, 55, 50);
    dm_camera_swipe_sample(&s, 1.0 / 120, &rx, &ry);
    assert(rx == 32767 && ry == 0);
    dm_camera_swipe_move(&s, 65, 50);
    dm_camera_swipe_sample(&s, 1.0 / 60, &rx, &ry);
    assert(rx == 32767 && ry == 0);   // Equal swipe speed at 60/120 Hz.
    dm_camera_swipe_move(&s, NAN, 0);
    dm_camera_swipe_sample(&s, NAN, &rx, &ry);
    assert(rx == 0 && ry == 0);
    puts("camera swipe: motion, idle, reversal, clamping, cancellation and cadence passed");
    return 0;
}
