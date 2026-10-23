#include "../dm_vibration_queue.h"
#include "../dm_vibration_timing.h"
#include <assert.h>
#include <stdio.h>

int main(void) {
    uint64_t elapsed_ns = 0;
    assert(dm_vibration_elapsed_ns(1000000000ull, 1002500000ull, &elapsed_ns));
    assert(elapsed_ns == 2500000ull);
    assert(!dm_vibration_elapsed_ns(0, 1000000ull, &elapsed_ns));
    assert(!dm_vibration_elapsed_ns(2000000ull, 1000000ull, &elapsed_ns));

    DmVibrationQueue queue = {0};
    DmVibrationFrame next;

    dm_vibration_queue_push(&queue, &(DmVibrationFrame){0});
    assert(dm_vibration_queue_pop(&queue, &next));
    assert(dm_vibration_frame_is_stop(&next));
    assert(!dm_vibration_queue_pop(&queue, &next));

    DmVibrationTimeline timeline = {0};
    DmVibrationFrame timed = {.timestamp_ns = 1000000000ull};
    assert(dm_vibration_timeline_schedule(&timeline, &timed, 1000000000ull) == 1000000000ull);
    timed.timestamp_ns += 20000000ull;
    assert(dm_vibration_timeline_schedule(&timeline, &timed, 1000000000ull) == 1020000000ull);
    timed.timestamp_ns += 20000000ull;
    assert(dm_vibration_timeline_schedule(&timeline, &timed, 1010000000ull) == 1040000000ull);
    timed.timestamp_ns = 900000000ull;
    assert(dm_vibration_timeline_schedule(&timeline, &timed, 1100000000ull) == 1100000000ull);
    timed.timestamp_ns = 1200000000ull;
    assert(dm_vibration_timeline_schedule(&timeline, &timed, 1100000000ull) == 1200000000ull);

    // Overflow drops the oldest nonzero frame but never a pending stop barrier.
    for (unsigned i = 0; i < DM_VIBRATION_QUEUE_CAPACITY; i++)
        dm_vibration_queue_push(&queue, &(DmVibrationFrame){0.1f, 80.f, 0.2f, 320.f, i, 0});
    dm_vibration_queue_push(&queue, &(DmVibrationFrame){0});
    dm_vibration_queue_push(&queue, &(DmVibrationFrame){0.3f, 80.f, 0.4f, 320.f, 999, 0});
    assert(queue.count == DM_VIBRATION_QUEUE_CAPACITY);

    assert(dm_vibration_queue_pop(&queue, &next));
    assert(next.sequence == 2); // Sequence zero was dropped, then sequence one on the next overflow.
    for (unsigned i = 3; i < DM_VIBRATION_QUEUE_CAPACITY; i++)
        assert(dm_vibration_queue_pop(&queue, &next) && next.sequence == i);
    assert(dm_vibration_queue_pop(&queue, &next));
    assert(dm_vibration_frame_is_stop(&next));
    assert(dm_vibration_queue_pop(&queue, &next));
    assert(next.sequence == 999);
    assert(!dm_vibration_queue_pop(&queue, &next));

    // If only stop frames remain, overflowing still preserves one explicitly ordered stop.
    queue = (DmVibrationQueue){0};
    for (unsigned i = 0; i <= DM_VIBRATION_QUEUE_CAPACITY; i++)
        dm_vibration_queue_push(&queue, &(DmVibrationFrame){0});
    assert(queue.count == DM_VIBRATION_QUEUE_CAPACITY);
    for (unsigned i = 0; i < DM_VIBRATION_QUEUE_CAPACITY; i++) {
        assert(dm_vibration_queue_pop(&queue, &next));
        assert(dm_vibration_frame_is_stop(&next));
    }

    puts("vibration queue: bounded order, stop barriers, and oldest-nonzero drop passed");
    return 0;
}
