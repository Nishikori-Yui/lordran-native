#pragma once

#include <errno.h>
#include <stdint.h>
#include <string.h>
#include <time.h>

// Horizon's timeval has two signed 64-bit fields, unlike Darwin's timeval.
typedef struct { int64_t sec, usec; } dm_net_timeval;

static inline void dm_net_wait_timeout_ms(int timeout_ms) {
    if (timeout_ms <= 0) return;
    struct timespec rem = {timeout_ms / 1000, (long)(timeout_ms % 1000) * 1000000L};
    while (nanosleep(&rem, &rem) && errno == EINTR) {}
}

static inline int dm_net_empty_select(int count, const void *timeout) {
    if (count != 0 || !timeout) return -1;
    dm_net_timeval tv;
    memcpy(&tv, timeout, sizeof tv);
    if (tv.sec < 0 || tv.usec < 0 || tv.usec >= 1000000) return -1;
    struct timespec rem = {.tv_sec = (time_t)tv.sec, .tv_nsec = (long)tv.usec * 1000L};
    while (nanosleep(&rem, &rem)) if (errno != EINTR) return -1;
    return 0;
}
