#include "../dm_log_timestamp.h"
#include <assert.h>
#include <pthread.h>
#include <signal.h>
#include <stdatomic.h>
#include <sys/wait.h>

void crash_install(void);
static atomic_int locked;

static void *hold_stderr(void *arg) {
    (void)arg;
    flockfile(stderr);
    atomic_store(&locked, 1);
    for (;;) pause();
    return NULL;
}

static void check_dump(int stream_locked) {
    FILE *log = tmpfile();
    assert(log);
    pid_t child = fork();
    assert(child >= 0);
    if (!child) {
        unsetenv("DM_WATCH");
        unsetenv("DM_WATCH_STALL");
        assert(dup2(fileno(log), STDERR_FILENO) == STDERR_FILENO);
        dm_log_timestamp_stderr();
        crash_install();
        if (stream_locked) {
            pthread_t holder;
            assert(!pthread_create(&holder, NULL, hold_stderr, NULL));
            while (!atomic_load(&locked)) usleep(1000);
        }
        raise(SIGTRAP);
        _exit(1);
    }
    int status = 0;
    assert(waitpid(child, &status, 0) == child);
    assert(WIFEXITED(status) && WEXITSTATUS(status) == 128 + SIGTRAP);
    rewind(log);
    char dump[32768];
    size_t bytes = fread(dump, 1, sizeof dump - 1, log);
    dump[bytes] = 0;
    assert(strstr(dump, "[FATAL] [crash] [thread="));
    assert(strstr(dump, "Signal=") && strstr(dump, "pc=") && strstr(dump, "lr="));
    if (stream_locked) {
        assert(!strncmp(dump, "[unix=", 6));
        assert(strstr(dump, "stderr locked for 1 s; full dump unavailable"));
    } else {
        assert(dump[0] == '[' && dump[5] == '-' && dump[11] == 'T');
        assert(strstr(dump, "Registers: x0="));
    }
    fclose(log);
}

int main(void) {
    alarm(10);
    check_dump(0);
    check_dump(1);
    alarm(0);
    puts("crash logs: timestamped signal dump and locked-stream emergency fallback passed");
    return 0;
}
