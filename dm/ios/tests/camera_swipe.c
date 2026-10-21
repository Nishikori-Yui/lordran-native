#include "../Sources/dm_camera_swipe.h"
#include "../../host/dm_input_motion.h"
#include <assert.h>
#include <stdio.h>

static void cadence(int producer, int consumer) {
    dm_camera_swipe swipe = {0};
    dm_input_motion motion = {0};
    int32_t x, y;
    const uint64_t start = 1000000000ull;
    dm_input_motion_read(&motion, start, &x, &y);
    dm_camera_swipe_begin(&swipe, 0, 0);
    double sum = 0;
    // 240 Hz scheduler gives exact interleavings for every requested cadence.
    for (int tick = 1; tick <= 240; tick++) {
        uint64_t now = start + (uint64_t)llround(tick * 1e9 / 240);
        if (tick % (240 / producer) == 0) {
            double dx, dy;
            dm_camera_swipe_move(&swipe, tick * 40.0 / 240, 0);
            dm_camera_swipe_take(&swipe, &dx, &dy);
            dm_input_motion_add(&motion, dx / 200, -dy / 200, now);
        }
        if (tick % (240 / consumer) == 0) {
            dm_input_motion_read(&motion, now, &x, &y);
            sum += x / 32767.0 / consumer;
            assert(y == 0);
            int32_t repeated_x, repeated_y;
            dm_input_motion_read(&motion, now + 1000, &repeated_x, &repeated_y);
            assert(repeated_x == x && repeated_y == y);
        }
    }
    assert(fabs(sum - 0.2) < 0.0001);
    dm_input_motion_read(&motion, start + 1100000000ull, &x, &y);
    assert(x == 0 && y == 0);
}
int main(void) {
    for (int producer = 60; producer <= 120; producer *= 2)
        for (int consumer = 15; consumer <= 60; consumer *= 2) cadence(producer, consumer);
    dm_camera_swipe s = {0};
    double dx, dy;
    dm_camera_swipe_begin(&s, 0, 0);
    dm_camera_swipe_move(&s, 0.5, 0.5);
    dm_camera_swipe_take(&s, &dx, &dy); assert(dx == 0 && dy == 0);
    dm_camera_swipe_move(&s, 5, -2);
    dm_camera_swipe_take(&s, &dx, &dy); assert(dx == 5 && dy == -2);
    dm_camera_swipe_take(&s, &dx, &dy); assert(dx == 0 && dy == 0);
    dm_camera_swipe_move(&s, NAN, 0);
    dm_camera_swipe_take(&s, &dx, &dy); assert(dx == 0 && dy == 0);
    dm_camera_swipe_end(&s); dm_camera_swipe_move(&s, 90, 90);
    dm_camera_swipe_take(&s, &dx, &dy); assert(dx == 0 && dy == 0);

    dm_input_motion m = {0}; int32_t x, y;
    uint64_t now = 1000000000ull;
    dm_input_motion_read(&m, now, &x, &y);
    dm_input_motion_add(&m, 0.0025, 0, now + 1000000); // Short swipe survives empty UI ticks.
    dm_input_motion_read(&m, now + 33333333, &x, &y); assert(x == 2458 && y == 0);
    dm_input_motion_read(&m, now + 66666666, &x, &y); assert(x == 0 && y == 0);
    dm_input_motion_add(&m, 0.01, 0, now + 70000000);
    dm_input_motion_add(&m, -0.015, 0, now + 71000000);
    dm_input_motion_read(&m, now + 99999999, &x, &y); assert(x == -4915 && y == 0);
    dm_input_motion_add(&m, 20, 20, now + 100000000);
    dm_input_motion_read(&m, now + 133333332, &x, &y); assert(x > 0 && y > 0 && hypot(x, y) <= 32768);
    dm_input_motion_read(&m, now + 166666665, &x, &y); assert(x == 0 && y == 0);
    dm_input_motion_add(&m, 0.01, 0, now + 170000000);
    dm_input_motion_cancel(&m); // Cancel, background, settings and controller takeover.
    dm_input_motion_read(&m, now + 199999998, &x, &y); assert(x == 0 && y == 0);
    dm_input_motion_add(&m, 0.01, 0, now + 200000000);
    dm_input_motion_read(&m, now + 400000000, &x, &y); assert(x == 0 && y == 0); // No post-stall tail.
    dm_input_motion_add(&m, NAN, INFINITY, now + 410000000);
    dm_input_motion_read(&m, now + 433333333, &x, &y); assert(x == 0 && y == 0);
    dm_input_motion_add(&m, 0.01, 0, now + 440000000);
    dm_input_motion_read(&m, now, &x, &y); assert(x == 0 && y == 0); // Backwards clock clears travel.

    // New 1x is exactly the previous 3x axis response (before radial saturation).
    dm_camera_axis_tune(0.1, 0.05, 1, 0, 0, &x, &y); assert(x == 9830 && y == 4915);
    dm_camera_axis_tune(0.1, 0.05, 1.0 / 3, 1, 0, &x, &y); assert(x == -3277 && y == 1638);
    dm_camera_axis_tune(1, 1, 3, 1, 1, &x, &y); assert(x < 0 && y < 0 && hypot(x, y) <= 32768);
    dm_camera_axis_tune(0.1, 0, NAN, 0, 0, &x, &y); assert(x == 9830 && y == 0);
    puts("camera: 60/120 Hz producers, 15/30/60 Hz consumers, short/reversed/cancelled/expired motion and new scale passed");
}
