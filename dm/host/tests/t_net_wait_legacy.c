#include "../hle_offline.c"
#include <assert.h>

void hle_bind_system_event(void *event, int handle) { (void)event; (void)handle; }
static uint64_t clock_ns(void) {
    struct timespec now; assert(!clock_gettime(CLOCK_MONOTONIC, &now));
    return (uint64_t)now.tv_sec * 1000000000 + now.tv_nsec;
}
int main(void) {
    uint64_t start = clock_ns();
    assert(h_sk_Poll(NULL, 0, 5) == 0);
    assert(clock_ns() - start >= 5000000);
    dm_net_timeval timeout = {0, 5000};
    start = clock_ns();
    assert(h_sk_SelectLegacy(0, NULL, NULL, NULL, &timeout) == 0);
    assert(clock_ns() - start >= 5000000);
    assert(h_sk_Poll(NULL, 1, 0) == -1);
    timeout.usec = ((int64_t)1 << 32) + 1;
    assert(h_sk_SelectLegacy(0, NULL, NULL, NULL, &timeout) == -1);
    assert(h_sk_SelectLegacy(-1, NULL, NULL, NULL, &timeout) == -1);
    puts("offline SDK 4.5 socket aliases: waits and guest timeval validation passed");
}
