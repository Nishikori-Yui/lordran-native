#pragma once

#include "dm_input.h"

enum { DM_VIBRATION_MAX_INTERVAL_NS = 100000000ull };

typedef struct {
    uint64_t scheduled_ns;
    uint64_t last_timestamp_ns;
} DmVibrationTimeline;

static inline uint64_t dm_vibration_timeline_schedule(
    DmVibrationTimeline *timeline, const DmVibrationFrame *frame,
    uint64_t now_ns_value) {
    uint64_t target_ns = now_ns_value;
    if (timeline->scheduled_ns && frame->timestamp_ns > timeline->last_timestamp_ns) {
        uint64_t delta_ns = frame->timestamp_ns - timeline->last_timestamp_ns;
        if (delta_ns > DM_VIBRATION_MAX_INTERVAL_NS)
            delta_ns = DM_VIBRATION_MAX_INTERVAL_NS;
        uint64_t base_ns = timeline->scheduled_ns > now_ns_value
            ? timeline->scheduled_ns : now_ns_value;
        target_ns = UINT64_MAX - base_ns < delta_ns
            ? UINT64_MAX : base_ns + delta_ns;
    }
    timeline->last_timestamp_ns = frame->timestamp_ns;
    timeline->scheduled_ns = target_ns;
    return target_ns;
}
