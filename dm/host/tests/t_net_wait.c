#include "../../host/hle_net_wait.h"
#include "../hle_net.c"
#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <time.h>

static uint64_t monotonic_ns(void) {
    struct timespec ts;
    assert(!clock_gettime(CLOCK_MONOTONIC, &ts));
    return (uint64_t)ts.tv_sec * 1000000000ull + (uint64_t)ts.tv_nsec;
}

static void check_wait(int timeout_ms) {
    uint64_t start = monotonic_ns();
    dm_net_wait_timeout_ms(timeout_ms);
    uint64_t elapsed = monotonic_ns() - start;
    assert(elapsed >= (uint64_t)timeout_ms * 800000ull);
}

int main(void) {
    check_wait(5);
    uint64_t start = monotonic_ns();
    assert(h_sk_Poll(NULL, 0, 5) == 0);
    assert(monotonic_ns() - start >= 4000000ull);
    struct timeval tv = {.tv_sec = 0, .tv_usec = 5000};
    start = monotonic_ns();
    assert(h_sk_Select(0, NULL, NULL, NULL, &tv) == 0);
    assert(monotonic_ns() - start >= 4000000ull);
    dm_net_wait_timeout_ms(0);
    dm_net_wait_timeout_ms(-1);
    puts("offline network waits: timeout behavior passed");
    return 0;
}
