// Relative stick motion is stored as normalized stick-seconds, not display-tick axes.
#pragma once
#include <math.h>
#include <stdint.h>
#include <string.h>

#define DM_MOTION_BATCH_NS 4166667ull
#define DM_MOTION_EXPIRY_NS 100000000ull

typedef struct {
    double x, y;
    uint64_t event_ns, read_ns;
    int32_t cached_x, cached_y;
} dm_input_motion;

static inline void dm_input_motion_clear(dm_input_motion *s) { memset(s, 0, sizeof *s); }
// Cancelling travel does not restart the consumer's polling interval.
static inline void dm_input_motion_cancel(dm_input_motion *s) {
    uint64_t read_ns = s->read_ns;
    dm_input_motion_clear(s);
    s->read_ns = read_ns;
}

static inline void dm_input_motion_add(dm_input_motion *s, double x, double y, uint64_t now) {
    if (!isfinite(x) || !isfinite(y) || (!x && !y)) return;
    if (now < s->event_ns || now - s->event_ns > DM_MOTION_EXPIRY_NS) s->x = s->y = 0;
    // Bound saturation debt; excess travel is discarded at the next read, never replayed.
    s->x = fmax(-1, fmin(1, s->x + x));
    s->y = fmax(-1, fmin(1, s->y + y));
    s->event_ns = now;
}

static inline void dm_input_motion_read(dm_input_motion *s, uint64_t now, int32_t *x, int32_t *y) {
    if (now < s->event_ns || now - s->event_ns > DM_MOTION_EXPIRY_NS) {
        s->x = s->y = 0; s->cached_x = s->cached_y = 0;
    }
    // SDK callers can query several styles/state APIs in one polling batch.
    if (s->read_ns && now >= s->read_ns && now - s->read_ns < DM_MOTION_BATCH_NS) {
        *x = s->cached_x; *y = s->cached_y;
        return;
    }
    double dt = s->read_ns && now > s->read_ns ? (now - s->read_ns) / 1e9 : 1.0 / 60;
    dt = fmax(1.0 / 240, fmin(1.0 / 15, dt));
    double rx = s->x / dt, ry = s->y / dt, length = hypot(rx, ry);
    if (length > 1) { rx /= length; ry /= length; }
    *x = s->cached_x = (int32_t)lround(rx * 32767);
    *y = s->cached_y = (int32_t)lround(ry * 32767);
    s->x = s->y = 0;
    s->read_ns = now;
}
