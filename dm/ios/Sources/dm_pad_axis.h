// Radial deadzone and continuous full-scale response for mobile controllers.
#pragma once
#include <math.h>
#include <stdint.h>
static inline void dm_pad_axis(double x, double y, double deadzone, int32_t *outX, int32_t *outY) {
    *outX = *outY = 0;
    if (!isfinite(x) || !isfinite(y)) return;
    deadzone = isfinite(deadzone) ? fmax(0.05, fmin(0.35, deadzone)) : 0.12;
    double length = hypot(x, y);
    if (length <= deadzone) return;
    double amount = (fmin(1, length) - deadzone) / (1 - deadzone) / length;
    *outX = (int32_t)lround(x * amount * 32767);
    *outY = (int32_t)lround(y * amount * 32767);
}
