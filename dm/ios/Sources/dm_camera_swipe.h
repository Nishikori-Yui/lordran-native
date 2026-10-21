// Collect relative screen motion independently of display and guest polling cadence.
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
    sensitivity = fmax(0.05, fmin(3, sensitivity)) * 3;
    x *= sensitivity * (invert_x ? -1 : 1); y *= sensitivity * (invert_y ? -1 : 1);
    double length = hypot(x, y);
    if (length > 1) { x /= length; y /= length; }
    *rx = (int32_t)lround(x * 32767); *ry = (int32_t)lround(y * 32767);
}
static inline void dm_camera_swipe_take(dm_camera_swipe *s, double *dx, double *dy) {
    *dx = s->active && s->dragging ? s->dx : 0;
    *dy = s->active && s->dragging ? s->dy : 0;
    s->dx = s->dy = 0;
}
static inline void dm_camera_swipe_end(dm_camera_swipe *s) { memset(s, 0, sizeof *s); }
