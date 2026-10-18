#include "../dm_log_timestamp.h"
#include <assert.h>
#include <pthread.h>

static void *worker(void *arg) {
    FILE *stream = arg;
    for (int i = 0; i < 64; i++) fprintf(stream, "worker %d\n", i);
    return NULL;
}

int main(void) {
    FILE *raw = tmpfile();
    assert(raw);
    FILE *stream = dm_log_timestamp_stream(fileno(raw));
    assert(stream);
    fputs("[dm] fragmented", stream); fflush(stream);
    fputs(" message\nregisters\n", stream);
    pthread_t threads[4];
    for (int i = 0; i < 4; i++) assert(!pthread_create(&threads[i], NULL, worker, stream));
    for (int i = 0; i < 4; i++) assert(!pthread_join(threads[i], NULL));
    assert(!fclose(stream));
    rewind(raw);
    char line[256]; int count = 0;
    while (fgets(line, sizeof line, raw)) {
        int y, mo, d, h, mi, s, ms, n = 0;
        assert(sscanf(line, "[%4d-%2d-%2dT%2d:%2d:%2d.%3dZ] %n", &y, &mo, &d, &h, &mi, &s, &ms, &n) == 7);
        assert(n == 27 && mo >= 1 && mo <= 12 && ms >= 0 && ms <= 999);
        if (count == 0) assert(!strcmp(line + n, "[dm] fragmented message\n"));
        else if (count == 1) assert(!strcmp(line + n, "registers\n"));
        else assert(!strncmp(line + n, "worker ", 7));
        count++;
    }
    assert(count == 258);
    // The stream wrapper must not close the emergency crash-report descriptor.
    assert(write(fileno(raw), "fallback\n", 9) == 9);
    fclose(raw);
    puts("timestamp stream: fragmented lines, concurrent writers and fd ownership passed");
    return 0;
}
