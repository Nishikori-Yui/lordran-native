#include "../dm_log.h"
#include "../dm_log_timestamp.h"
#include <assert.h>

enum { WORKERS = 4, RECORDS = 64, PAYLOAD = 8192 };

static void *worker(void *arg) {
    int worker_id = (int)(intptr_t)arg;
    char payload[PAYLOAD + 1];
    memset(payload, 'A' + worker_id, PAYLOAD);
    payload[PAYLOAD] = 0;
    for (int i = 0; i < RECORDS; i++) {
        errno = ENOSPC;
        DM_LOG_DEBUG("metal.pass", "worker=%d record=%d payload=%s", worker_id, i, payload);
        assert(errno == ENOSPC);
    }
    return NULL;
}

int main(void) {
    FILE *raw = tmpfile();
    assert(raw);
    FILE *original_stderr = stderr;
    stderr = dm_log_timestamp_stream(fileno(raw));
    assert(stderr);
    DM_LOG_INFO("/source/hle_audio.c", "Audio initialized: rate_hz=%d", 48000);
    DM_LOG_WARN("boot", "Fallback enabled");
    DM_LOG_ERROR("boot", "Failed to open resource: errno=%d", ENOENT);
    DM_LOG_INFO("legacy", "ERROR Failed to open resource");
    DM_LOG_INFO("legacy", "WARN Fallback enabled");
    DM_LOG_FATAL("crash", "ERROR Fatal error");
    DM_LOG_ERROR("legacy", "WARN Error remains an error");
    DM_LOG_INFO("legacy", "【红】Legacy error");
    DM_LOG_INFO("legacy", "FATAL Fatal legacy error");
    pthread_t threads[WORKERS];
    for (int i = 0; i < WORKERS; i++)
        assert(!pthread_create(&threads[i], NULL, worker, (void *)(intptr_t)i));
    for (int i = 0; i < WORKERS; i++) assert(!pthread_join(threads[i], NULL));
    FILE *captured = stderr;
    stderr = original_stderr;
    assert(!fclose(captured));
    rewind(raw);
    const char *levels[] = {"INFO", "WARN", "ERROR", "ERROR", "WARN", "FATAL", "ERROR", "ERROR", "FATAL"};
    unsigned char seen[WORKERS][RECORDS] = {{0}};
    unsigned long long thread_ids[WORKERS] = {0};
    char *line = NULL;
    size_t capacity = 0;
    ssize_t length;
    int count = 0;
    while ((length = getline(&line, &capacity, raw)) >= 0) {
        int year, month, day, hour, minute, second, ms, offset = 0;
        char level[16], component[64];
        unsigned long long thread_id = 0;
        assert(sscanf(line, "[%4d-%2d-%2dT%2d:%2d:%2d.%3dZ] [%15[^]]] [%63[^]]] [thread=%llu] %n",
            &year, &month, &day, &hour, &minute, &second, &ms, level, component, &thread_id, &offset) == 10);
        assert(month >= 1 && month <= 12 && ms >= 0 && ms <= 999 && offset > 27);
        assert(thread_id && line[length - 1] == '\n');
        const char *message = line + offset;
        if (count < 9) {
            assert(!strcmp(level, levels[count]));
            assert(!strstr(message, "ERROR ") && !strstr(message, "WARN ") && !strstr(message, "FATAL "));
            if (!count) {
                assert(!strcmp(component, "hle_audio"));
                assert(!strcmp(message, "Audio initialized: rate_hz=48000\n"));
            }
        } else {
            assert(!strcmp(level, "DEBUG") && !strcmp(component, "metal.pass"));
            int id = -1, record = -1, payload_offset = 0;
            assert(sscanf(message, "worker=%d record=%d payload=%n", &id, &record, &payload_offset) == 2);
            assert(id >= 0 && id < WORKERS && record >= 0 && record < RECORDS && payload_offset);
            assert(!seen[id][record]++);
            if (!thread_ids[id]) thread_ids[id] = thread_id;
            assert(thread_ids[id] == thread_id);
            const char *payload = message + payload_offset;
            assert(strlen(payload) == PAYLOAD + 1);
            for (int i = 0; i < PAYLOAD; i++) assert(payload[i] == 'A' + id);
        }
        count++;
    }
    assert(count == 9 + WORKERS * RECORDS);
    for (int i = 0; i < WORKERS; i++)
        for (int j = i + 1; j < WORKERS; j++) assert(thread_ids[i] != thread_ids[j]);
    free(line);
    fclose(raw);
    puts("runtime logs: severity, component, thread ID, errno and concurrent 8 KiB records passed");
    return 0;
}
