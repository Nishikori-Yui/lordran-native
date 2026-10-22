#pragma once

#include "dm_input.h"
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

static inline int dm_switch_haptics_ack_is_current(
    const void *sender, const void *current_device, int request_pending) {
    return sender && sender == current_device && request_pending;
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
