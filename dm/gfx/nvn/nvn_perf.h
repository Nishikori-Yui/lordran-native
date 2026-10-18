// Low-cost, thread-safe telemetry for the on-screen performance HUD.
#pragma once
#include <stdint.h>

typedef struct {
    double display_fps, game_fps, frame_ms, gpu_ms;
    uint64_t presented_frames;
    uint32_t width, height;
} nvn_perf_snapshot;

void nvn_perf_frame(uint64_t ns, uint32_t width, uint32_t height, double gpu_ms);
void nvn_perf_present(uint64_t ns);
// All timestamps use the mach_absolute_time / CACurrentMediaTime clock.
// Unavailable timings are -1; a stalled stream reports 0 FPS after one second.
void nvn_perf_read(uint64_t now_ns, nvn_perf_snapshot *out);
