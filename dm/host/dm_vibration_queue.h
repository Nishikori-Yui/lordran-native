#pragma once

#include "dm_input.h"

enum { DM_VIBRATION_QUEUE_CAPACITY = 64 };

typedef struct {
    DmVibrationFrame frames[DM_VIBRATION_QUEUE_CAPACITY];
    unsigned head, tail, count;
    int drain_scheduled;
} DmVibrationQueue;

static inline int dm_vibration_frame_is_stop(const DmVibrationFrame *frame) {
    return !(frame->low_amplitude > 0.f) && !(frame->high_amplitude > 0.f);
}

static inline void dm_vibration_queue_remove_oldest_nonzero(DmVibrationQueue *queue) {
    for (unsigned i = 0; i < queue->count; i++) {
        unsigned index = (queue->head + i) % DM_VIBRATION_QUEUE_CAPACITY;
        if (dm_vibration_frame_is_stop(&queue->frames[index])) continue;

        // Shift frames after the victim one slot toward the head, then free
        // the last slot for the incoming frame.
        for (unsigned j = i; j + 1 < queue->count; j++) {
            unsigned current = (queue->head + j) % DM_VIBRATION_QUEUE_CAPACITY;
            unsigned next = (queue->head + j + 1) % DM_VIBRATION_QUEUE_CAPACITY;
            queue->frames[current] = queue->frames[next];
        }
        queue->tail = (queue->tail + DM_VIBRATION_QUEUE_CAPACITY - 1) %
            DM_VIBRATION_QUEUE_CAPACITY;
        queue->count--;
        return;
    }
    // Every frame is a stop; preserve the oldest explicitly ordered stop.
    for (unsigned j = 0; j + 1 < queue->count; j++) {
        unsigned current = (queue->head + j) % DM_VIBRATION_QUEUE_CAPACITY;
        unsigned next = (queue->head + j + 1) % DM_VIBRATION_QUEUE_CAPACITY;
        queue->frames[current] = queue->frames[next];
    }
    queue->tail = (queue->tail + DM_VIBRATION_QUEUE_CAPACITY - 1) %
        DM_VIBRATION_QUEUE_CAPACITY;
    queue->count--;
}

static inline void dm_vibration_queue_push(DmVibrationQueue *queue,
                                           const DmVibrationFrame *frame) {
    if (queue->count == DM_VIBRATION_QUEUE_CAPACITY)
        dm_vibration_queue_remove_oldest_nonzero(queue);
    queue->frames[queue->tail] = *frame;
    queue->tail = (queue->tail + 1) % DM_VIBRATION_QUEUE_CAPACITY;
    queue->count++;
}

static inline int dm_vibration_queue_pop(DmVibrationQueue *queue,
                                         DmVibrationFrame *out) {
    if (queue->count == 0) return 0;
    if (out) *out = queue->frames[queue->head];
    queue->head = (queue->head + 1) % DM_VIBRATION_QUEUE_CAPACITY;
    queue->count--;
    return 1;
}
