#pragma once

#include <errno.h>
#include <time.h>

// An offline wait still needs to consume the caller's timeout. Without this,
// polling network threads can turn an unavailable service into a busy loop.
static inline void dm_net_wait_timeout_ms(int timeout_ms) {
    if (timeout_ms <= 0) return;
    struct timespec rem = {
        .tv_sec = timeout_ms / 1000,
        .tv_nsec = (long)(timeout_ms % 1000) * 1000000L,
    };
    while (nanosleep(&rem, &rem) && errno == EINTR) {}
}
