// Exercise actual frame streams, stalls and drawable callback ordering.
#include "../nvn/nvn_perf.h"
#include <math.h>
#include <stdio.h>

static int checks, fails;
#define CHECK(c, msg) do { checks++; if (!(c)) { fails++; fprintf(stderr, "FAIL: %s\n", msg); } } while (0)
static int near(double a, double b) { return fabs(a - b) < 0.01; }

int main(void) {
    nvn_perf_snapshot s;
    nvn_perf_read(1000000000ull, &s);
    CHECK(!s.presented_frames && !s.display_fps && s.frame_ms < 0 && s.gpu_ms < 0, "startup has no invented samples");
    const uint64_t start = 2000000000ull;
    for (uint64_t i = 0; i <= 120; i++) {
        uint64_t t = start + i * 1000000000ull / 60;
        nvn_perf_frame(t, 1600, 900, 6.5);
        if (!(i % 2)) nvn_perf_present(t);
    }
    nvn_perf_read(start + 2000000000ull, &s);
    CHECK(near(s.game_fps, 60), "game submits 60 frames per second");
    CHECK(near(s.display_fps, 30), "display shows only 30 distinct frames per second");
    CHECK(near(s.frame_ms, 1000.0 / 30), "frame time measures display intervals");
    CHECK(near(s.gpu_ms, 6.5) && s.width == 1600 && s.height == 900, "GPU timing and render size");
    CHECK(s.presented_frames == 61, "present count");
    nvn_perf_read(start + 2008000000ull, &s);
    CHECK(near(s.display_fps, 30) && near(s.game_fps, 60), "sampling between refreshes does not under-report FPS");
    nvn_perf_present(0);
    nvn_perf_present(start + 2000000000ull);
    nvn_perf_present(start + 1000000000ull);
    nvn_perf_read(start + 2000000000ull, &s);
    CHECK(s.presented_frames == 61 && near(s.display_fps, 30), "discarded, duplicate and late callbacks are ignored");
    nvn_perf_read(start + 2500000000ull, &s);
    CHECK(s.display_fps < 25 && s.game_fps < 50, "stalled streams decay before the timeout");
    nvn_perf_read(start + 3000000000ull, &s);
    CHECK(!s.display_fps && !s.game_fps && s.frame_ms < 0 && s.gpu_ms < 0, "stalled streams reach zero and clear timings");
    nvn_perf_frame(start + 4000000000ull, 1280, 720, NAN);
    nvn_perf_present(start + 4000000000ull);
    nvn_perf_read(start + 4000000000ull, &s);
    CHECK(!s.display_fps && !s.game_fps && s.gpu_ms < 0, "resume starts a fresh measurement window");
    for (uint64_t i = 1; i <= 360; i++) {
        uint64_t t = start + 4000000000ull + i * 1000000000ull / 120;
        nvn_perf_frame(t, 1280, 720, -1);
        nvn_perf_present(t);
    }
    nvn_perf_read(start + 7000000000ull, &s);
    CHECK(near(s.display_fps, 120) && near(s.game_fps, 120), "ring wraps correctly at 120 Hz");
    CHECK(near(s.frame_ms, 1000.0 / 120) && s.gpu_ms < 0, "unavailable GPU timing stays unavailable");
    nvn_perf_read(start + 6000000000ull, &s);
    CHECK(!s.display_fps && !s.game_fps, "an earlier snapshot time cannot underflow");
    printf("Performance telemetry: %d checks, %d failures\n", checks, fails);
    return fails != 0;
}
