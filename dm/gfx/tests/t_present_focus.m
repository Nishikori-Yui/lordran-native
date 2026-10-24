// Exercise the real presentation worker without displaying flashing frames.
#define nvn_game_fps nvn_game_fps_mtl_default
#include "../nvn/nvn_mtl.m"
#undef nvn_game_fps
#include "../nvn/hle_nvn.c"
#include <assert.h>

uint64_t g_t0_ns;
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t g_mod[MAX_MOD]; int g_nmod;
void svc_thread_dump(void) {}
int dm_guest_as_contains(uintptr_t p) { (void)p; return 0; }
uint64_t now_ns(void) { return bp_now(); }
void test_focus_set(int value);

static void worker_hold(int on) {
    pthread_mutex_lock(&g_pq_mu);
    g_link_owns_layer = on;
    pthread_cond_broadcast(&g_pq_cv);
    pthread_mutex_unlock(&g_pq_mu);
}

static void wait_ticket(uint64_t ticket) {
    struct timespec deadline; clock_gettime(CLOCK_REALTIME, &deadline);
    deadline.tv_sec += 5;
    pthread_mutex_lock(&g_pq_mu);
    while (g_pq_done < ticket)
        assert(pthread_cond_timedwait(&g_pq_cv, &g_pq_mu, &deadline) == 0);
    pthread_mutex_unlock(&g_pq_mu);
}

static _Atomic int retire_started, retire_done;
static void *retire_test(void *arg) {
    atomic_store(&retire_started, 1);
    present_retire_skipped(*(uint64_t *)arg);
    atomic_store(&retire_done, 1);
    return NULL;
}

int main(void) { @autoreleasepool {
    alarm(30);
    mtl_init();
    tex_t textures[3] = {0};
    for (int i = 0; i < 3; ++i) {
        textures[i].magic = MAGIC('T', 'E', 'X', 0);
        textures[i].serial = nvn_new_serial();
        textures[i].d.width = textures[i].d.height = 8;
        textures[i].d.depth = textures[i].d.levels = 1;
        textures[i].d.format = NVN_FORMAT_RGBA8;
        textures[i].d.target = NVN_TEXTURE_TARGET_2D;
        (void)tex_mtl(&textures[i]);
    }
    uint64_t ticket = mtl_present(&textures[0], 0, NULL);
    wait_ticket(ticket);
    uint64_t count = g_present_n;
    assert(count == 1);

    test_focus_set(2);
    for (int i = 0; i < 30; ++i) {
        ticket = mtl_present(&textures[i % 3], 0, NULL);
        wait_ticket(ticket);
        assert(g_present_n == count);
        assert(mtl_presented_time(ticket) == -1);
    }
    // A queued inactive frame remains suppressed even if consumed after recovery.
    worker_hold(1);
    ticket = mtl_present(&textures[1], 0, NULL);
    test_focus_set(1);
    worker_hold(0); wait_ticket(ticket);
    assert(g_present_n == count);

    // A frame queued while focused is also suppressed if focus is lost first.
    worker_hold(1);
    ticket = mtl_present(&textures[2], 0, NULL);
    test_focus_set(2);
    worker_hold(0); wait_ticket(ticket);
    assert(g_present_n == count);

    test_focus_set(1);
    ticket = mtl_present(&textures[0], 0, NULL); wait_ticket(ticket);
    assert(g_present_n == count + 1);
    mtl_present_flush();

    // Skipping a later ticket must not release an earlier GPU reader.
    pthread_mutex_lock(&g_pq_mu);
    uint64_t old_done = g_pq_done, skipped = old_done + 1;
    g_pq_inflight = 1;
    pthread_mutex_unlock(&g_pq_mu);
    pthread_t thread; assert(!pthread_create(&thread, NULL, retire_test, &skipped));
    while (!atomic_load(&retire_started)) usleep(1000);
    usleep(20000);
    pthread_mutex_lock(&g_pq_mu);
    assert(!atomic_load(&retire_done) && g_pq_done == old_done);
    g_pq_inflight = 0;
    pthread_cond_broadcast(&g_pq_cv);
    pthread_mutex_unlock(&g_pq_mu);
    pthread_join(thread, NULL);
    assert(atomic_load(&retire_done) && g_pq_done == skipped);
    puts("Presentation focus: 30 inactive rotations, both queue races, recovery and GPU retirement passed");
    return 0;
} }
