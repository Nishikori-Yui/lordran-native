#include "nvn_perf.h"
#include <pthread.h>
#include <math.h>

enum { CAP = 256 };
static const uint64_t WINDOW = 1000000000ull;
typedef struct { uint64_t time[CAP], total; unsigned next, count; } stream;
static pthread_mutex_t g_lock = PTHREAD_MUTEX_INITIALIZER;
static stream g_game, g_display;
static uint32_t g_width, g_height;
static double g_gpu_ms = -1;

static void record(stream *s, uint64_t ns) {
    if (!ns) return;
    if (s->count) {
        uint64_t last = s->time[(s->next + CAP - 1) % CAP];
        if (ns <= last) return;   // A late or discarded drawable is not a new visible frame.
        if (ns - last > WINDOW) s->count = 0;
    }
    s->time[s->next] = ns;
    s->next = (s->next + 1) % CAP;
    if (s->count < CAP) s->count++;
    s->total++;
}

static double rate(const stream *s, uint64_t now, double *frame_ms) {
    *frame_ms = -1;
    if (s->count < 2) return 0;
    uint64_t last = s->time[(s->next + CAP - 1) % CAP];
    if (now < last || now - last >= WINDOW) return 0;
    uint64_t first = last;
    unsigned n = 1;
    for (unsigned i = 1; i < s->count; i++) {
        uint64_t t = s->time[(s->next + CAP - 1 - i) % CAP];
        first = t; n++;
        if (now - t >= WINDOW) break;
    }
    *frame_ms = (last - first) / 1e6 / (n - 1);
    // Normal scan-out idle time is not a missed frame. Once the next frame
    // is overdue, include the excess delay so a hung renderer's FPS decays.
    uint64_t interval = (last - first) / (n - 1), idle = now - last;
    uint64_t span = last - first + (idle > interval ? idle - interval : 0);
    return (n - 1) * 1e9 / span;
}

void nvn_perf_frame(uint64_t ns, uint32_t width, uint32_t height, double gpu_ms) {
    pthread_mutex_lock(&g_lock);
    record(&g_game, ns);
    g_width = width; g_height = height;
    g_gpu_ms = isfinite(gpu_ms) && gpu_ms >= 0 ? gpu_ms : -1;
    pthread_mutex_unlock(&g_lock);
}

void nvn_perf_present(uint64_t ns) {
    pthread_mutex_lock(&g_lock);
    record(&g_display, ns);
    pthread_mutex_unlock(&g_lock);
}

void nvn_perf_read(uint64_t now_ns, nvn_perf_snapshot *out) {
    pthread_mutex_lock(&g_lock);
    double unused;
    out->display_fps = rate(&g_display, now_ns, &out->frame_ms);
    out->game_fps = rate(&g_game, now_ns, &unused);
    out->gpu_ms = out->game_fps > 0 ? g_gpu_ms : -1;
    out->presented_frames = g_display.total;
    out->width = g_width; out->height = g_height;
    pthread_mutex_unlock(&g_lock);
}
