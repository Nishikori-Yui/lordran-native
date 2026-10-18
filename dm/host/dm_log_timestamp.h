// Prefix stderr lines at the stream boundary so fragmented crash dumps and
// ordinary host messages share the same UTC millisecond timestamps.
#pragma once
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

typedef struct { int fd, line_start; } dm_log_sink;

static inline int dm_log_write_all(int fd, const char *p, size_t n) {
    while (n) {
        ssize_t written = write(fd, p, n);
        if (written < 0 && errno == EINTR) continue;
        if (written <= 0) return -1;
        p += written; n -= (size_t)written;
    }
    return 0;
}

static inline int dm_log_write(void *cookie, const char *bytes, int length) {
    dm_log_sink *sink = cookie;
    const char *p = bytes;
    size_t left = (size_t)length;
    while (left) {
        if (sink->line_start) {
            struct timespec now; struct tm utc;
            if (clock_gettime(CLOCK_REALTIME, &now) || !gmtime_r(&now.tv_sec, &utc)) return -1;
            char date[32], prefix[48];
            if (!strftime(date, sizeof date, "%Y-%m-%dT%H:%M:%S", &utc)) return -1;
            int n = snprintf(prefix, sizeof prefix, "[%s.%03ldZ] ", date, now.tv_nsec / 1000000);
            if (dm_log_write_all(sink->fd, prefix, (size_t)n)) return -1;
            sink->line_start = 0;
        }
        const char *newline = memchr(p, '\n', left);
        size_t n = newline ? (size_t)(newline - p) + 1 : left;
        if (dm_log_write_all(sink->fd, p, n)) return -1;
        sink->line_start = newline != NULL;
        p += n; left -= n;
    }
    return length;
}

// The descriptor remains owned by the original stream. In particular fd 2
// stays open for the signal handler's emergency write() fallback.
static inline int dm_log_close(void *cookie) { free(cookie); return 0; }
static inline FILE *dm_log_timestamp_stream(int fd) {
    dm_log_sink *sink = calloc(1, sizeof *sink);
    if (!sink) return NULL;
    sink->fd = fd; sink->line_start = 1;
    FILE *stream = funopen(sink, NULL, dm_log_write, NULL, dm_log_close);
    if (!stream) { free(sink); return NULL; }
    setvbuf(stream, NULL, _IOLBF, 0);
    return stream;
}
static inline void dm_log_timestamp_stderr(void) {
    fflush(stderr);
    FILE *stream = dm_log_timestamp_stream(fileno(stderr));
    if (stream) stderr = stream;
}
