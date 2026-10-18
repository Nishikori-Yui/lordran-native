// Runtime log schema: UTC timestamp (stream), severity, component, thread, message.
#pragma once
#include <errno.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#define DM_LOG_SCHEMA_VERSION 2

static inline void dm_log_emit(const char *level, const char *source, const char *format, ...)
    __attribute__((format(printf, 3, 4)));
static inline void dm_log_emit(const char *level, const char *source, const char *format, ...) {
    int saved_errno = errno;
    const char *component = strrchr(source, '/');
    component = component ? component + 1 : source;
    size_t component_length = strlen(component);
    const char *extension = strrchr(component, '.');
    if (extension && (!strcmp(extension, ".c") || !strcmp(extension, ".m") ||
                      !strcmp(extension, ".h") || !strcmp(extension, ".mm")))
        component_length = (size_t)(extension - component);
    // Legacy severity prefixes can escalate a record, but cannot downgrade FATAL.
    const char *prefix_level = NULL;
    if (!strncmp(format, "【红】", strlen("【红】"))) { prefix_level = "ERROR"; format += strlen("【红】"); }
    if (!strncmp(format, "FATAL ", 6)) { prefix_level = "FATAL"; format += 6; }
    else if (!strncmp(format, "ERROR ", 6)) { prefix_level = "ERROR"; format += 6; }
    else if (!strncmp(format, "WARN ", 5)) { prefix_level = "WARN"; format += 5; }
    if (prefix_level && strcmp(level, "FATAL") &&
        (strcmp(level, "ERROR") || !strcmp(prefix_level, "FATAL"))) level = prefix_level;
    static _Thread_local uint64_t thread_id;
    if (!thread_id) pthread_threadid_np(NULL, &thread_id);
    va_list args; va_start(args, format);
    // Lock once for the entire record, including its newline and stream timestamp.
    flockfile(stderr);
    fprintf(stderr, "[%s] [%.*s] [thread=%llu] ", level, (int)component_length, component, (unsigned long long)thread_id);
    vfprintf(stderr, format, args);
    fputc('\n', stderr);
    funlockfile(stderr);
    va_end(args);
    errno = saved_errno;
}

#define DM_LOG_INFO(component, ...) dm_log_emit("INFO", component, __VA_ARGS__)
#define DM_LOG_WARN(component, ...) dm_log_emit("WARN", component, __VA_ARGS__)
#define DM_LOG_ERROR(component, ...) dm_log_emit("ERROR", component, __VA_ARGS__)
#define DM_LOG_DEBUG(component, ...) dm_log_emit("DEBUG", component, __VA_ARGS__)
#define DM_LOG_FATAL(component, ...) dm_log_emit("FATAL", component, __VA_ARGS__)
