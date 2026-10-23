#pragma once

#include "dm_input.h"
#include "dm_vibration_queue.h"
#include <stdatomic.h>

enum { DM_SWITCH_HAPTICS_RETRY_NS = 250000000ull };

typedef struct {
    int request_pending;
    uint64_t sent_at_ns;
    uint64_t retry_after_ns;
} DmSwitchHapticsRetry;

typedef struct {
    DmVibrationFrame frame;
    int valid;
} DmSwitchHapticsPendingFrame;

typedef struct {
    DmVibrationQueue rumble_frames;
    int report_in_flight;
    int shutdown_requested;
    int shutdown_pending;
} DmSwitchHapticsOutputState;

static inline int dm_switch_haptics_output_begin(
    DmSwitchHapticsOutputState *state) {
    if (!state || state->report_in_flight) return 0;
    state->report_in_flight = 1;
    return 1;
}

static inline void dm_switch_haptics_output_enqueue(
    DmSwitchHapticsOutputState *state, const DmVibrationFrame *frame) {
    if (!state || !frame || state->shutdown_requested) return;
    if (dm_vibration_frame_is_stop(frame))
        state->rumble_frames = (DmVibrationQueue){0};
    dm_vibration_queue_push(&state->rumble_frames, frame);
}

static inline int dm_switch_haptics_output_begin_shutdown(
    DmSwitchHapticsOutputState *state) {
    if (!state || state->shutdown_requested) return 0;
    state->shutdown_requested = 1;
    state->shutdown_pending = 1;
    state->rumble_frames = (DmVibrationQueue){0};
    return 1;
}

static inline int dm_switch_haptics_output_take_shutdown(
    DmSwitchHapticsOutputState *state, DmVibrationFrame *stop_frame) {
    if (!state || !stop_frame || !state->shutdown_pending ||
        state->report_in_flight)
        return 0;
    state->shutdown_pending = 0;
    state->report_in_flight = 1;
    *stop_frame = (DmVibrationFrame){
        .low_frequency = 160.f,
        .high_frequency = 320.f,
    };
    return 1;
}

// Complete the in-flight report and take the next queued frame, if any.
static inline int dm_switch_haptics_output_complete(
    DmSwitchHapticsOutputState *state, DmVibrationFrame *next) {
    if (!state) return 0;
    state->report_in_flight = 0;
    return dm_vibration_queue_pop(&state->rumble_frames, next);
}

static inline int dm_switch_haptics_ack_is_current(
    const void *sender, const void *current_device, int request_pending) {
    return sender && sender == current_device && request_pending;
}

static inline int dm_switch_haptics_scan_due(
    uint64_t *next_scan_ns, uint64_t now_ns) {
    if (!next_scan_ns || now_ns < *next_scan_ns) return 0;
    *next_scan_ns = now_ns + DM_SWITCH_HAPTICS_RETRY_NS;
    return 1;
}

static inline int dm_switch_haptics_retry_ready(
    const DmSwitchHapticsRetry *retry, uint64_t now_ns) {
    if (!retry) return 0;
    if (retry->request_pending && now_ns - retry->sent_at_ns <
            DM_SWITCH_HAPTICS_RETRY_NS)
        return 0;
    return now_ns >= retry->retry_after_ns;
}

static inline void dm_switch_haptics_mark_enable_sent(
    DmSwitchHapticsRetry *retry, uint64_t now_ns) {
    if (!retry) return;
    retry->request_pending = 1;
    retry->sent_at_ns = now_ns;
    retry->retry_after_ns = now_ns + DM_SWITCH_HAPTICS_RETRY_NS;
}

static inline void dm_switch_haptics_mark_enable_ack(
    DmSwitchHapticsRetry *retry, int accepted, uint64_t now_ns) {
    if (!retry) return;
    retry->request_pending = 0;
    retry->sent_at_ns = 0;
    retry->retry_after_ns = accepted ? 0 : now_ns + DM_SWITCH_HAPTICS_RETRY_NS;
}

static inline void dm_switch_haptics_mark_output_failed(
    _Atomic int *supported, DmSwitchHapticsRetry *retry,
    DmSwitchHapticsPendingFrame *pending, const DmVibrationFrame *frame,
    uint64_t now_ns) {
    if (supported) atomic_store(supported, 0);
    if (retry) {
        retry->request_pending = 0;
        retry->sent_at_ns = 0;
        retry->retry_after_ns = now_ns + DM_SWITCH_HAPTICS_RETRY_NS;
    }
    if (pending && frame) {
        pending->frame = *frame;
        pending->valid = 1;
    }
}

static inline void dm_switch_haptics_store_latest(
    DmSwitchHapticsPendingFrame *pending, const DmVibrationFrame *frame) {
    if (!pending || !frame) return;
    pending->frame = *frame;
    pending->valid = 1;
}

static inline int dm_switch_haptics_take_pending(
    DmSwitchHapticsPendingFrame *pending, DmVibrationFrame *out) {
    if (!pending || !pending->valid) return 0;
    if (out) *out = pending->frame;
    pending->valid = 0;
    return 1;
}

static inline void dm_switch_haptics_output_fail(
    DmSwitchHapticsOutputState *state, const DmVibrationFrame *failed,
    DmSwitchHapticsPendingFrame *pending) {
    if (!state) return;
    state->report_in_flight = 0;
    if (pending && failed) dm_switch_haptics_store_latest(pending, failed);
    DmVibrationFrame queued;
    while (dm_vibration_queue_pop(&state->rumble_frames, &queued))
        dm_switch_haptics_store_latest(pending, &queued);
}
