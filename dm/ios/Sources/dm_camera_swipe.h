// Convert relative screen motion into a right-stick velocity for one display tick.
#pragma once
#include <math.h>
#include <stdint.h>
#include <string.h>

typedef struct {
    double start_x, start_y, last_x, last_y, dx, dy;
    int active, dragging;
} dm_camera_swipe;

static inline void dm_camera_swipe_begin(dm_camera_swipe *s, double x, double y) {
    *s = (dm_camera_swipe){.start_x = x, .start_y = y, .last_x = x, .last_y = y, .active = 1};
}
static inline void dm_camera_swipe_move(dm_camera_swipe *s, double x, double y) {
    if (!s->active || !isfinite(x) || !isfinite(y)) return;
    if (!s->dragging) {
        if (hypot(x - s->start_x, y - s->start_y) < 2) return;
        s->dragging = 1;
    }
    s->dx += x - s->last_x; s->dy += y - s->last_y;
    s->last_x = x; s->last_y = y;
}
static inline void dm_camera_axis_tune(double x, double y, double sensitivity, int invert_x, int invert_y,
                                     int32_t *rx, int32_t *ry) {
    if (!isfinite(sensitivity)) sensitivity = 1;
    sensitivity = fmax(0.25, fmin(3, sensitivity));
    x *= sensitivity * (invert_x ? -1 : 1); y *= sensitivity * (invert_y ? -1 : 1);
    double length = hypot(x, y);
    if (length > 1) { x /= length; y /= length; }
    *rx = (int32_t)lround(x * 32767); *ry = (int32_t)lround(y * 32767);
}
static inline void dm_camera_swipe_sample_tuned(dm_camera_swipe *s, double dt, double sensitivity,
                                              int invert_x, int invert_y, int32_t *rx, int32_t *ry) {
    *rx = *ry = 0;
    if (s->active && s->dragging) {
        if (!isfinite(dt) || dt <= 0) dt = 1.0 / 60;
        dt = fmax(1.0 / 240, fmin(1.0 / 15, dt));
        // 600 points per second reaches full tilt; normalize diagonal swipes
        // together so horizontal and vertical sensitivity remain identical.
        double x = s->dx / (600 * dt), y = -s->dy / (600 * dt);
        dm_camera_axis_tune(x, y, sensitivity, invert_x, invert_y, rx, ry);
    }
    s->dx = s->dy = 0;
}
static inline void dm_camera_swipe_sample(dm_camera_swipe *s, double dt, int32_t *rx, int32_t *ry) {
    dm_camera_swipe_sample_tuned(s, dt, 1, 0, 0, rx, ry);
}
static inline void dm_camera_swipe_end(dm_camera_swipe *s) { memset(s, 0, sizeof *s); }
