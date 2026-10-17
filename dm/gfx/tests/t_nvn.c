// NVN null device unit tests: look up addresses from nvnBootstrapLoader the way the game does and go all the way to present; all expected values are hand-calculated, without calling the implementation under test.
// For build and run see dm/gfx/tests/Makefile (make -C dm/gfx/tests).
#include "../nvn/hle_nvn.c"
uint64_t g_t0_ns;   // process start time from host main.c (used by hle_nvn's per-frame @t_s); unit test stub
#include "../tex/nvn_deswizzle.h"
#include <time.h>
void *front_metal_layer(void) { return NULL; }   // no window in unit tests: present only counts
module_t *module_of(const void *p) { (void)p; return NULL; }   // no guest modules in unit tests
module_t g_mod[MAX_MOD]; int g_nmod;                            // host symbols that crash.c depends on
void svc_thread_dump(void) {}
int dm_guest_as_contains(uintptr_t a) { (void)a; return 0; }   // Unit tests call from a host stack.
void crash_install(void);
void nvn_present_config(int hz, int display_mode);
#include <fcntl.h>
#include <errno.h>
#include <unistd.h>
uint64_t now_ns(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return (uint64_t)t.tv_sec * 1000000000ull + t.tv_nsec; }

static int g_fail, g_n;
#define EXPECT(name, want, got) do { long long w_ = (long long)(want), g_ = (long long)(got); g_n++;                 \
    printf("%-44s 期望 %-12lld → 真结果 %-12lld %s\n", name, w_, g_, w_ == g_ ? "✓" : "✗"); if (w_ != g_) g_fail++; } while (0)

#define P(name) ((NVNT_##name)proc(#name))
static PFNNVNDEVICEGETPROCADDRESSPROC gpa; static NVNdevice dev;
static void *proc(const char *n) { void *p = (void *)gpa(&dev, n); if (!p) { printf("取址失败 %s\n", n); exit(1); } return p; }

// Command memory callback: hands out a new 256-byte memory segment each time (forces a multi-segment JUMP chain)
static uint8_t g_cmdmem[64 * 1024]; static size_t g_cmdoff; static int g_cb_calls; static NVNmemoryPool g_cmdpool;
static void mem_cb(NVNcommandBuffer *c, NVNcommandBufferMemoryEvent ev, size_t minsz, void *data) {
    (void)data; g_cb_calls++;
    if (ev != NVN_COMMAND_BUFFER_MEMORY_EVENT_OUT_OF_COMMAND_MEMORY) return;
    size_t n = minsz > 256 ? minsz : 256;
    P(nvnCommandBufferAddCommandMemory)(c, &g_cmdpool, (ptrdiff_t)g_cmdoff, n); g_cmdoff += n;
}

// Suspend unit test: do the submit on another thread
static _Atomic int g_sstarted, g_sdone; static pthread_mutex_t g_smu = PTHREAD_MUTEX_INITIALIZER; static pthread_cond_t g_scv = PTHREAD_COND_INITIALIZER;
static NVNqueue *g_sq; static NVNcommandHandle g_sh; static NVNT_nvnQueueSubmitCommands g_sub;
static void *susp_thr(void *a) { (void)a; pthread_mutex_lock(&g_smu); atomic_store(&g_sstarted, 1); pthread_cond_broadcast(&g_scv); pthread_mutex_unlock(&g_smu); g_sub(g_sq, 1, &g_sh); atomic_store(&g_sdone, 1); return NULL; }
static int wait_started(void) { struct timespec dl; clock_gettime(CLOCK_REALTIME, &dl); dl.tv_sec += 10; pthread_mutex_lock(&g_smu); while (!atomic_load(&g_sstarted) && pthread_cond_timedwait(&g_scv, &g_smu, &dl) == 0) {} int ok = atomic_load(&g_sstarted); pthread_mutex_unlock(&g_smu); return ok; }

static size_t tex_size(int fmt, int w, int h, int flags, size_t *align) {
    NVNtextureBuilder tb;
    P(nvnTextureBuilderSetDevice)(&tb, &dev); P(nvnTextureBuilderSetDefaults)(&tb);
    P(nvnTextureBuilderSetFlags)(&tb, flags); P(nvnTextureBuilderSetTarget)(&tb, NVN_TEXTURE_TARGET_2D);
    P(nvnTextureBuilderSetWidth)(&tb, w); P(nvnTextureBuilderSetHeight)(&tb, h); P(nvnTextureBuilderSetFormat)(&tb, fmt);
    if (align) *align = P(nvnTextureBuilderGetStorageAlignment)(&tb);
    return P(nvnTextureBuilderGetStorageSize)(&tb);
}

int main(void) {
    crash_install();   // the same SIGSEGV / SIGBUS handling as production (the page-fault hook is dispatched from within it)
    // 1. Bootstrap address lookup: bootstrap gets GetProcAddress, then uses it to get all the names
    PFNNVNBOOTSTRAPLOADERPROC boot = (PFNNVNBOOTSTRAPLOADERPROC)h_nvnBootstrapLoader;
    gpa = (PFNNVNDEVICEGETPROCADDRESSPROC)boot("nvnDeviceGetProcAddress");
    EXPECT("bootstrap 取 GetProcAddress 非空", 1, gpa != NULL);
    int nonnull = 0; for (unsigned i = 0; i < NVN_NFUNC; i++) nonnull += gpa(NULL, nvn_names[i]) != NULL;
    EXPECT("名字表里每个名字都取到地址（NVN_NFUNC 个）", NVN_NFUNC, nonnull);   // used to be hard-coded 523 and kept failing once the name table grew to 536
    EXPECT("未知名字取址返回空", 0, gpa(NULL, "nvnNoSuchFunction") != NULL);

    // 2. Device
    NVNdeviceBuilder db; P(nvnDeviceBuilderSetDefaults)(&db); P(nvnDeviceBuilderSetFlags)(&db, 0);
    EXPECT("DeviceInitialize 成功", 1, P(nvnDeviceInitialize)(&dev, &db));
    int v; P(nvnDeviceGetInteger)(&dev, NVN_DEVICE_INFO_UNIFORM_BUFFER_ALIGNMENT, &v);
    EXPECT("uniform 缓冲对齐（X1 实测 256）", 256, v);
    P(nvnDeviceGetInteger)(&dev, NVN_DEVICE_INFO_TEXTURE_DESCRIPTOR_SIZE, &v); EXPECT("贴图描述符大小（32）", 32, v);
    P(nvnDeviceGetInteger)(&dev, NVN_DEVICE_INFO_QUEUE_COMMAND_MEMORY_MIN_SIZE, &v); EXPECT("队列命令内存下限（65536）", 65536, v);

    // 3. Memory pool: GPU address = the storage address given by the game
    static uint8_t poolmem[1 << 20] __attribute__((aligned(4096)));
    NVNmemoryPoolBuilder pb; NVNmemoryPool pool;
    P(nvnMemoryPoolBuilderSetDevice)(&pb, &dev); P(nvnMemoryPoolBuilderSetDefaults)(&pb);
    P(nvnMemoryPoolBuilderSetStorage)(&pb, poolmem, sizeof poolmem); P(nvnMemoryPoolBuilderSetFlags)(&pb, 0x24);
    EXPECT("MemoryPoolInitialize 成功", 1, P(nvnMemoryPoolInitialize)(&pool, &pb));
    EXPECT("池 GPU 地址 = 存储地址", (long long)(uintptr_t)poolmem, P(nvnMemoryPoolGetBufferAddress)(&pool));

    // 4. Texture storage size (block-linear: GOB = 64 B × 8 rows; block height from the GOB count of "height × 1.5": ≥16→16, ≥8→8 ...)
    //    256×256 RGBA8: 1024 B per row = 16 GOBs; height 256 rows = 32 GOB rows, block height 16 GOBs → 2 blocks; 16×2×(512×16) = 262144
    size_t al; EXPECT("256x256 RGBA8 尺寸", 262144, tex_size(NVN_FORMAT_RGBA8, 256, 256, 0, &al));
    EXPECT("块线性对齐", 512, al);
    //    100×100 RGBA8: 400 B → 7 GOBs wide; height 100 → 13 GOB rows, ×1.5 = 150 rows = 19 GOBs → block height 16 → 1 block; 7×1×8192 = 57344
    EXPECT("100x100 RGBA8 尺寸", 57344, tex_size(NVN_FORMAT_RGBA8, 100, 100, 0, NULL));
    //    128×128 DXT1: 32×32 blocks, 8 B/block → 256 B = 4 GOBs wide; 32 rows → ×1.5 = 48 rows = 6 GOBs → block height 4 → 4 GOB rows = 1 block; 4×1×2048 = 8192
    EXPECT("128x128 DXT1 尺寸", 8192, tex_size(NVN_FORMAT_RGBA_DXT1, 128, 128, 0, NULL));
    //    LINEAR 100×100 RGBA8: row pitch 400 aligned to 32 = 416; 416×100 = 41600, aligned to 32
    EXPECT("线性 100x100 RGBA8 尺寸", 41600, tex_size(NVN_FORMAT_RGBA8, 100, 100, NVN_TEXTURE_FLAGS_LINEAR, &al));
    EXPECT("线性对齐", 32, al);

    // 5. Command buffer: record uniform updates / events / counters / buffer copies / nested calls, with memory in 256 B segments to force multi-segment linking
    NVNcommandBuffer cb; P(nvnCommandBufferInitialize)(&cb, &dev);
    NVNmemoryPoolBuilder cpb; P(nvnMemoryPoolBuilderSetDefaults)(&cpb); P(nvnMemoryPoolBuilderSetStorage)(&cpb, g_cmdmem, sizeof g_cmdmem);
    P(nvnMemoryPoolInitialize)(&g_cmdpool, &cpb);
    P(nvnCommandBufferSetMemoryCallback)(&cb, mem_cb); P(nvnCommandBufferSetMemoryCallbackData)(&cb, NULL);
    NVNeventBuilder eb; NVNevent ev; P(nvnEventBuilderSetDefaults)(&eb); P(nvnEventBuilderSetStorage)(&eb, &pool, 0x1000);
    P(nvnEventInitialize)(&ev, &eb);
    uint8_t *ub = poolmem + 0x2000, *cnt = poolmem + 0x3000, *src = poolmem + 0x4000, *dst = poolmem + 0x5000;
    for (int i = 0; i < 64; i++) src[i] = (uint8_t)(i * 3 + 1);
    uint32_t data[16];

    P(nvnCommandBufferBeginRecording)(&cb);
    EXPECT("录制中", 1, P(nvnCommandBufferIsRecording)(&cb));
    for (int k = 0; k < 20; k++) {                        // 20 updates to different offsets of the same buffer, 64 B of data each
        for (int i = 0; i < 16; i++) data[i] = k * 100 + i;
        P(nvnCommandBufferUpdateUniformBuffer)(&cb, (NVNbufferAddress)ub, 4096, k * 64, 64, data);
        memset(data, 0xEE, sizeof data);                  // modify the original data after recording: the submit must use the values copied in at record time
    }
    P(nvnCommandBufferSignalEvent)(&cb, &ev, NVN_EVENT_SIGNAL_MODE_WRITE, NVN_EVENT_SIGNAL_LOCATION_BOTTOM, 0, 7);
    P(nvnCommandBufferSignalEvent)(&cb, &ev, NVN_EVENT_SIGNAL_MODE_ADD, NVN_EVENT_SIGNAL_LOCATION_BOTTOM, 0, 5);
    P(nvnCommandBufferReportCounter)(&cb, NVN_COUNTER_TYPE_TIMESTAMP, (NVNbufferAddress)cnt);
    NVNcommandHandle h1 = P(nvnCommandBufferEndRecording)(&cb);
    EXPECT("录完不在录制", 0, P(nvnCommandBufferIsRecording)(&cb));
    P(nvnCommandBufferBeginRecording)(&cb);
    P(nvnCommandBufferCopyBufferToBuffer)(&cb, (NVNbufferAddress)src, (NVNbufferAddress)dst, 64, 0);
    P(nvnCommandBufferCopyCommands)(&cb, 1, &h1);         // nested: execute h1 once more (event 7 → +5 → write 7 again → +5)
    NVNcommandHandle h2 = P(nvnCommandBufferEndRecording)(&cb);
    printf("（命令内存回调 %d 次，用掉 %zu B）\n", g_cb_calls, g_cmdoff);
    EXPECT("命令内存回调至少 2 次（多段）", 1, g_cb_calls >= 2);
    EXPECT("提交前事件值仍为 0", 0, P(nvnEventGetValue)(&ev));

    NVNqueueBuilder qb; NVNqueue q; static uint8_t qmem[1 << 19];
    P(nvnQueueBuilderSetDevice)(&qb, &dev); P(nvnQueueBuilderSetDefaults)(&qb);
    size_t qsz = P(nvnQueueBuilderGetQueueMemorySize)(&qb);
    EXPECT("队列内存 = 64K+256K+16K 取整 4K", 65536 + 262144 + 16384, qsz);
    P(nvnQueueBuilderSetQueueMemory)(&qb, qmem, qsz);
    EXPECT("QueueInitialize 成功", 1, P(nvnQueueInitialize)(&q, &qb));
    NVNcommandHandle hs[2] = {h1, h2};
    P(nvnQueueSubmitCommands)(&q, 2, hs);
    NVNsync sf; P(nvnSyncInitialize)(&sf, &dev); P(nvnQueueFenceSync)(&q, &sf, NVN_SYNC_CONDITION_ALL_GPU_COMMANDS_COMPLETE, 0);
    int wr = P(nvnSyncWait)(&sf, 5000000000ull);
    EXPECT("提交后围栏等待成功（0 或 1）", 1, wr == 0 || wr == 1);
    int ub_ok = 1;
    for (int k = 0; k < 20; k++) for (int i = 0; i < 16; i++) { uint32_t w; memcpy(&w, ub + k * 64 + i * 4, 4); ub_ok &= w == (uint32_t)(k * 100 + i); }
    EXPECT("uniform 缓冲 20×16 个字全等录制值", 1, ub_ok);
    EXPECT("事件值：h1(7,+5) h2 拷贝后再跑 h1(7,+5) = 12", 12, P(nvnEventGetValue)(&ev));
    EXPECT("缓冲拷贝 64 B 全等", 0, memcmp(src, dst, 64));
    uint64_t ts[2]; memcpy(ts, cnt, 16);
    EXPECT("计数器时间戳已写（非 0）", 1, ts[0] != 0 && ts[0] == ts[1]);

    // 5b. Sync must hold the CPU back: first queue 24 copies of 64 MiB to keep the GPU busy, with the last one copying src to dst;
    //     the CPU rewrites src only after the fence wait returns. If the wait is released early, that last copy reads the rewritten src.
    {
        size_t big = 64u << 20, pgsz = 16384;
        uint8_t *heap; posix_memalign((void **)&heap, pgsz, 4 * big);
        uint8_t *busy_a = heap, *busy_b = heap + big, *bsrc = heap + 2 * big, *bdst = heap + 3 * big;
        memset(heap, 0, 4 * big); memset(bsrc, 0x5A, big);
        NVNmemoryPoolBuilder hb; NVNmemoryPool hp; P(nvnMemoryPoolBuilderSetDefaults)(&hb); P(nvnMemoryPoolBuilderSetStorage)(&hb, heap, 4 * big);
        P(nvnMemoryPoolInitialize)(&hp, &hb);
        NVNsync sb; P(nvnSyncInitialize)(&sb, &dev);
        P(nvnCommandBufferBeginRecording)(&cb);
        for (int i = 0; i < 24; i++) P(nvnCommandBufferCopyBufferToBuffer)(&cb, (NVNbufferAddress)busy_a, (NVNbufferAddress)busy_b, big, 0);
        P(nvnCommandBufferCopyBufferToBuffer)(&cb, (NVNbufferAddress)bsrc, (NVNbufferAddress)bdst, big, 0);
        P(nvnCommandBufferFenceSync)(&cb, &sb, NVN_SYNC_CONDITION_ALL_GPU_COMMANDS_COMPLETE, 0);
        NVNcommandHandle hb2 = P(nvnCommandBufferEndRecording)(&cb);
        EXPECT("recording a command fence does not signal it", NVN_SYNC_WAIT_RESULT_TIMEOUT_EXPIRED, P(nvnSyncWait)(&sb, 0));
        uint64_t t0 = now_ns();
        P(nvnQueueSubmitCommands)(&q, 1, &hb2);
        int w0 = P(nvnSyncWait)(&sb, 0);
        int w1 = P(nvnSyncWait)(&sb, 10000000000ull);
        double ms = (now_ns() - t0) / 1e6;
        memset(bsrc, 0xC3, big);                                       // rewrite only after the wait is released
        size_t bad = 0; for (size_t i = 0; i < big; i += 4096) bad += bdst[i] != 0x5A;
        printf("（GPU 占用约 %.1f ms）\n", ms);
        EXPECT("刚提交时零超时等待 = 超时(2)", 2, w0);
        EXPECT("长等待 = 满足(1)", 1, w1);
        EXPECT("dst 全为改写前的值（抽 16384 处）", 0, bad);
        // The same recorded command must fence a later submission too.
        memset(bsrc, 0x5A, big);
        uint64_t first_fence = ((sync_t *)&sb)->fence;
        P(nvnQueueSubmitCommands)(&q, 1, &hb2);
        EXPECT("replayed command fence advances", 1, ((sync_t *)&sb)->fence > first_fence);
        w1 = P(nvnSyncWait)(&sb, 10000000000ull);
        EXPECT("replayed command fence completes", 1, w1 == NVN_SYNC_WAIT_RESULT_ALREADY_SIGNALED || w1 == NVN_SYNC_WAIT_RESULT_CONDITION_SATISFIED);
        EXPECT("replayed copy completed before CPU reuse", 0, memcmp(bsrc, bdst, big));
        P(nvnMemoryPoolFinalize)(&hp); free(heap);
    }

    // 6. Sync / window / present
    NVNsync s1, s2; P(nvnSyncInitialize)(&s1, &dev); P(nvnSyncInitialize)(&s2, &dev);
    EXPECT("未围栏的同步等待 = 超时(2)", 2, P(nvnSyncWait)(&s1, 0));
    P(nvnQueueFenceSync)(&q, &s1, NVN_SYNC_CONDITION_ALL_GPU_COMMANDS_COMPLETE, 0);
    EXPECT("围栏后等待 = 已就绪(0)", 0, P(nvnSyncWait)(&s1, 0));
    NVNtexture sc[2]; NVNtextureBuilder tb; P(nvnTextureBuilderSetDevice)(&tb, &dev); P(nvnTextureBuilderSetDefaults)(&tb);
    P(nvnTextureBuilderSetWidth)(&tb, 1280); P(nvnTextureBuilderSetHeight)(&tb, 720); P(nvnTextureBuilderSetFormat)(&tb, NVN_FORMAT_RGBA8);
    P(nvnTextureBuilderSetStorage)(&tb, &pool, 0); P(nvnTextureInitialize)(&sc[0], &tb); P(nvnTextureInitialize)(&sc[1], &tb);
    EXPECT("贴图宽", 1280, P(nvnTextureGetWidth)(&sc[0]));
    NVNtexture *scp[2] = {&sc[0], &sc[1]};
    NVNwindowBuilder wb; NVNwindow win; P(nvnWindowBuilderSetDevice)(&wb, &dev); P(nvnWindowBuilderSetDefaults)(&wb);
    P(nvnWindowBuilderSetTextures)(&wb, 2, scp); EXPECT("WindowInitialize 成功", 1, P(nvnWindowInitialize)(&win, &wb));
    int idx[4];
    for (int f = 0; f < 4; f++) {
        P(nvnWindowAcquireTexture)(&win, &s2, &idx[f]);
        for (int b = 0; b < 5; b++) P(nvnCommandBufferBarrier)(&cb, 0);
        P(nvnQueuePresentTexture)(&q, &win, idx[f]);
    }
    EXPECT("交换链轮转 0,1,0,1", 0x0101, idx[0] << 12 | idx[1] << 8 | idx[2] << 4 | idx[3]);
    EXPECT("取图后同步已就绪(0)", 0, P(nvnSyncWait)(&s2, 0));
    unsigned bi = 0; while (strcmp(nvn_names[bi], "nvnCommandBufferBarrier")) bi++;
    EXPECT("Barrier 计数 = 4 帧 × 5", 20, nvn_slot[bi].cnt);

    // 6b. Readback: pixel (x,y) = {x*16+y, y*16+x, 0x55, 0xAA} (expected values computed directly from the formula)
    {
        #define PX(x, y, c) ((uint8_t)((c) == 0 ? (x) * 16 + (y) : (c) == 1 ? (y) * 16 + (x) : (c) == 2 ? 0x55 : 0xAA))
        static uint8_t rb[256 << 10] __attribute__((aligned(16384)));
        NVNmemoryPoolBuilder rpb; NVNmemoryPool rp; P(nvnMemoryPoolBuilderSetDefaults)(&rpb); P(nvnMemoryPoolBuilderSetStorage)(&rpb, rb, sizeof rb);
        P(nvnMemoryPoolInitialize)(&rp, &rpb);
        uint8_t *stage = rb + 0x8000, *outb = rb + 0xC000;
        for (int y = 0; y < 4; y++) for (int x = 0; x < 8; x++) for (int c = 0; c < 4; c++) stage[(y * 8 + x) * 4 + c] = PX(x, y, c);
        NVNtextureBuilder b; NVNtexture ta; P(nvnTextureBuilderSetDevice)(&b, &dev); P(nvnTextureBuilderSetDefaults)(&b);
        P(nvnTextureBuilderSetWidth)(&b, 8); P(nvnTextureBuilderSetHeight)(&b, 4); P(nvnTextureBuilderSetFormat)(&b, NVN_FORMAT_RGBA8);
        P(nvnTextureBuilderSetStorage)(&b, &rp, 0); P(nvnTextureInitialize)(&ta, &b);
        NVNcopyRegion all = {0, 0, 0, 8, 4, 1}, sub = {2, 1, 0, 5, 3, 1}, cp = {1, 0, 0, 4, 2, 1};
        P(nvnCommandBufferBeginRecording)(&cb);
        P(nvnCommandBufferSetCopyRowStride)(&cb, 0);
        P(nvnCommandBufferCopyBufferToTexture)(&cb, (NVNbufferAddress)stage, &ta, NULL, &all, 0);
        P(nvnCommandBufferSetCopyRowStride)(&cb, 64);
        P(nvnCommandBufferCopyTextureToBuffer)(&cb, &ta, NULL, &cp, (NVNbufferAddress)outb, 0);
        NVNcommandHandle hr = P(nvnCommandBufferEndRecording)(&cb);
        memset(outb, 0xEE, 256);
        P(nvnQueueSubmitCommands)(&q, 1, &hr); P(nvnQueueFinish)(&q);
        uint8_t got[5 * 3 * 4]; P(nvnTextureReadTexels)(&ta, NULL, &sub, got);
        int bad = 0; for (int y = 0; y < 3; y++) for (int x = 0; x < 5; x++) for (int c = 0; c < 4; c++) bad += got[(y * 5 + x) * 4 + c] != PX(x + 2, y + 1, c);
        EXPECT("ReadTexels 子区域 5x3 逐字节（GPU 写入的贴图）", 0, bad);
        uint8_t gs[4 * 40]; memset(gs, 0xEE, sizeof gs); P(nvnTextureReadTexelsStrided)(&ta, NULL, &all, gs, 40, 0);
        bad = 0; for (int y = 0; y < 4; y++) { for (int x = 0; x < 8; x++) for (int c = 0; c < 4; c++) bad += gs[y * 40 + x * 4 + c] != PX(x, y, c); for (int k = 32; k < 40; k++) bad += gs[y * 40 + k] != 0xEE; }
        EXPECT("ReadTexelsStrided 行距 40（行尾填充不动）", 0, bad);
        bad = 0; for (int y = 0; y < 2; y++) { for (int x = 0; x < 4; x++) for (int c = 0; c < 4; c++) bad += outb[y * 64 + x * 4 + c] != PX(x + 1, y, c); for (int k = 16; k < 64; k++) bad += outb[y * 64 + k] != 0xEE; }
        EXPECT("CopyTextureToBuffer 行距 64（GPU 拷回）", 0, bad);
        // Packaged texture: the pool memory is the ground truth (block-linear); ReadTexels deswizzles and reads it directly
        uint8_t lin[16 * 8 * 4]; for (int y = 0; y < 8; y++) for (int x = 0; x < 16; x++) for (int c = 0; c < 4; c++) lin[(y * 16 + x) * 4 + c] = PX(x, y, c);
        NVNtexture tb; NVNpackagedTextureLayout lay = {{1, 0, 0, 0, 7, 0, 1, 0}};
        P(nvnTextureBuilderSetDefaults)(&b); P(nvnTextureBuilderSetWidth)(&b, 16); P(nvnTextureBuilderSetHeight)(&b, 8); P(nvnTextureBuilderSetFormat)(&b, NVN_FORMAT_RGBA8);
        P(nvnTextureBuilderSetPackagedTextureLayout)(&b, &lay); P(nvnTextureBuilderSetStorage)(&b, &rp, 0x10000); P(nvnTextureInitialize)(&tb, &b);
        nvn_texdesc dd = ((tex_t *)&tb)->d;
        if (nvn_swizzle(&dd, 0, 0, lin, 64, rb + 0x10000)) { printf("nvn_swizzle 失败\n"); g_fail++; }
        NVNcopyRegion s2 = {3, 2, 0, 9, 5, 1}; uint8_t g2[9 * 5 * 4];
        P(nvnTextureReadTexels)(&tb, NULL, &s2, g2);
        bad = 0; for (int y = 0; y < 5; y++) for (int x = 0; x < 9; x++) for (int c = 0; c < 4; c++) bad += g2[(y * 9 + x) * 4 + c] != PX(x + 3, y + 2, c);
        EXPECT("ReadTexels 预排布贴图 9x5（池内存块线性直读）", 0, bad);
        P(nvnMemoryPoolFinalize)(&rp);
    }

    // 6c. Write-protected dirty pages: after a packaged texture is uploaded its pool pages are read-only; game write → page fault → mark dirty → re-upload on next use; a direct host read() write needs prepare first
    {
        static uint8_t wb_[256 << 10] __attribute__((aligned(16384)));
        NVNmemoryPoolBuilder wpb; NVNmemoryPool wp; P(nvnMemoryPoolBuilderSetDefaults)(&wpb); P(nvnMemoryPoolBuilderSetStorage)(&wpb, wb_, sizeof wb_);
        P(nvnMemoryPoolInitialize)(&wp, &wpb);
        NVNtextureBuilder b; NVNtexture tw; NVNpackagedTextureLayout lay = {{1, 0, 0, 0, 7, 0, 1, 0}};
        P(nvnTextureBuilderSetDevice)(&b, &dev); P(nvnTextureBuilderSetDefaults)(&b); P(nvnTextureBuilderSetWidth)(&b, 16); P(nvnTextureBuilderSetHeight)(&b, 8);
        P(nvnTextureBuilderSetFormat)(&b, NVN_FORMAT_RGBA8); P(nvnTextureBuilderSetPackagedTextureLayout)(&b, &lay);
        P(nvnTextureBuilderSetStorage)(&b, &wp, 0x10000); P(nvnTextureInitialize)(&tw, &b);
        nvn_texdesc dd = ((tex_t *)&tw)->d;
        uint8_t lin[16 * 8 * 4], *store = wb_ + 0x10000, *outb = wb_ + 0x20000;
        #define FILLPAT(k) for (int y = 0; y < 8; y++) for (int x = 0; x < 16; x++) for (int c = 0; c < 4; c++) lin[(y * 16 + x) * 4 + c] = (uint8_t)(x * 16 + y + (k) * 3 + c * 41)
        FILLPAT(0); nvn_swizzle(&dd, 0, 0, lin, 64, store);
        NVNcopyRegion all = {0, 0, 0, 16, 8, 1};
        // Check the actual GPU-side contents with a GPU copy-back (CopyTextureToBuffer reading the MTLTexture): expected = pattern version k
        #define GPU_READ_EQ(k, name) do { P(nvnCommandBufferBeginRecording)(&cb); P(nvnCommandBufferSetCopyRowStride)(&cb, 0); \
            P(nvnCommandBufferCopyTextureToBuffer)(&cb, &tw, NULL, &all, (NVNbufferAddress)outb, 0); NVNcommandHandle hh = P(nvnCommandBufferEndRecording)(&cb); \
            P(nvnQueueSubmitCommands)(&q, 1, &hh); P(nvnQueueFinish)(&q); FILLPAT(k); EXPECT(name, 0, memcmp(outb, lin, sizeof lin)); } while (0)
        uint64_t up0, re0, fa0, pr0, up, re, fa, pr; mtl_pkg_stats(&up0, &re0); nvn_dirty_stats(&fa0, &pr0);
        GPU_READ_EQ(0, "首传：GPU 侧内容 = 第 0 版");
        mtl_pkg_stats(&up, &re); EXPECT("首传次数 +1", 1, up - up0);
        FILLPAT(1); nvn_swizzle(&dd, 0, 0, lin, 64, store);          // game-style CPU write: protected page → page fault → hook marks it dirty
        nvn_dirty_stats(&fa, &pr); EXPECT("游戏写触发缺页 ≥ 1 次（已被钩子接住、未崩）", 1, fa - fa0 >= 1);
        GPU_READ_EQ(1, "重传后 GPU 侧内容 = 第 1 版");
        mtl_pkg_stats(&up, &re); EXPECT("池内容变化重传 +1", 1, re - re0);
        uint64_t fa1 = fa; GPU_READ_EQ(1, "内容不变再用：仍为第 1 版");
        nvn_dirty_stats(&fa, &pr); mtl_pkg_stats(&up, &re); EXPECT("内容不变：缺页 +0", 0, fa - fa1); EXPECT("内容不变：重传仍为 1", 1, re - re0);
        // Pitfall 1: host read() writing directly into protected pages. Without prepare the kernel returns EFAULT (no page fault); after prepare the read succeeds, the pages are marked dirty and re-uploaded next time
        char path[1024]; snprintf(path, sizeof path, "%s/t_nvn_rd_XXXXXX", getenv("TMPDIR") ? getenv("TMPDIR") : "."); int fd = mkstemp(path);   // per-user temp directory, do not write to /tmp
        FILLPAT(2); uint8_t tmpst[sizeof lin * 4]; memset(tmpst, 0, sizeof tmpst);
        static uint8_t full[0x10000]; memcpy(full, store, sizeof full);   // existing storage contents (block-linear); write version 2 into a copy and then save it to a file
        nvn_swizzle(&dd, 0, 0, lin, 64, full); if (write(fd, full, ((tex_t *)&tw)->L.size) < 0) g_fail++;
        ssize_t r0 = pread(fd, store, ((tex_t *)&tw)->L.size, 0); int e0 = errno;
        EXPECT("不 prepare：read() 进受保护页返回 -1 且 EFAULT", 1, r0 == -1 && e0 == EFAULT);
        dm_guest_write_prepare(store, ((tex_t *)&tw)->L.size);
        ssize_t r1 = pread(fd, store, ((tex_t *)&tw)->L.size, 0);
        EXPECT("prepare 后 read() 成功", (long long)((tex_t *)&tw)->L.size, r1);
        close(fd); unlink(path);
        GPU_READ_EQ(2, "宿主写后重传：GPU 侧内容 = 第 2 版");
        mtl_pkg_stats(&up, &re); EXPECT("宿主写触发重传，累计 2", 2, re - re0);
        P(nvnMemoryPoolFinalize)(&wp);
    }

    // 6c2. WriteTexels region writes: the result must be byte-identical to "decode the whole level → patch the region → re-encode" (Metroid Dread's minimap writes one texel at a time, which used to cost a whole-level round trip each).
    //      RGBA8 100×37 (width not a whole number of GOBs), BC1 64×64 (4×4 blocks, 8 bytes per block), RGBA16F 33×17 two-layer array; several regions each, including 1×1, a whole row, GOB-crossing and the whole level
    {
        static uint8_t wtmem[1 << 18] __attribute__((aligned(16384)));
        NVNmemoryPoolBuilder wb2; NVNmemoryPool wtp; P(nvnMemoryPoolBuilderSetDevice)(&wb2, &dev); P(nvnMemoryPoolBuilderSetDefaults)(&wb2);
        P(nvnMemoryPoolBuilderSetStorage)(&wb2, wtmem, sizeof wtmem); P(nvnMemoryPoolBuilderSetFlags)(&wb2, 0x24); P(nvnMemoryPoolInitialize)(&wtp, &wb2);
        struct { int fmt, w, h, layers; int rg[5][4]; } cs[] = {
            {NVN_FORMAT_RGBA8, 100, 37, 1, {{0, 0, 1, 1}, {99, 36, 1, 1}, {13, 5, 40, 9}, {0, 20, 100, 1}, {0, 0, 100, 37}}},
            {NVN_FORMAT_RGBA_DXT1, 64, 64, 1, {{0, 0, 4, 4}, {60, 60, 4, 4}, {16, 8, 32, 20}, {0, 32, 64, 4}, {0, 0, 64, 64}}},
            {NVN_FORMAT_RGBA16F, 33, 17, 2, {{32, 16, 1, 1}, {1, 2, 30, 13}, {0, 0, 33, 1}, {5, 9, 17, 8}, {0, 0, 33, 17}}},
        };
        int bad = 0, n = 0; uint32_t seed = 12345;
        for (unsigned c = 0; c < sizeof cs / sizeof cs[0]; c++) {
            NVNtextureBuilder b; NVNtexture t; P(nvnTextureBuilderSetDevice)(&b, &dev); P(nvnTextureBuilderSetDefaults)(&b);
            P(nvnTextureBuilderSetTarget)(&b, cs[c].layers > 1 ? NVN_TEXTURE_TARGET_2D_ARRAY : NVN_TEXTURE_TARGET_2D);
            P(nvnTextureBuilderSetSize3D)(&b, cs[c].w, cs[c].h, cs[c].layers); P(nvnTextureBuilderSetFormat)(&b, cs[c].fmt);
            P(nvnTextureBuilderSetStorage)(&b, &wtp, 0); P(nvnTextureInitialize)(&t, &b);
            const tex_t *tt = (const tex_t *)&t; int bw, bh, bpb = nvn_fmt_bpb(cs[c].fmt, &bw, &bh);
            size_t lp = (size_t)((cs[c].w + bw - 1) / bw) * bpb, lr = (size_t)(cs[c].h + bh - 1) / bh;
            for (int k = 0; k < 5; k++) {
                for (size_t i = 0; i < tt->L.size; i++) wtmem[i] = (uint8_t)(seed = seed * 1103515245u + 12345u) >> 3;   // random old content
                static uint8_t want[1 << 18], lin[1 << 16], src[1 << 16];
                int x = cs[c].rg[k][0], y = cs[c].rg[k][1], w = cs[c].rg[k][2], h = cs[c].rg[k][3], z = cs[c].layers - 1;
                size_t wbb = (size_t)((w + bw - 1) / bw) * bpb, hbb = (size_t)(h + bh - 1) / bh;
                for (size_t i = 0; i < wbb * hbb; i++) src[i] = (uint8_t)(seed = seed * 1103515245u + 12345u) >> 5;
                memcpy(want, wtmem, tt->L.size);   // expected: decode the whole level, patch, re-encode (only the last layer)
                nvn_deswizzle(&tt->d, 0, (unsigned)z, want, lin, lp);
                for (size_t r = 0; r < hbb; r++) memcpy(lin + ((size_t)y / bh + r) * lp + (size_t)(x / bw) * bpb, src + r * wbb, wbb);
                nvn_swizzle(&tt->d, 0, (unsigned)z, lin, lp, want); (void)lr;
                NVNtextureView vw; P(nvnTextureViewSetDefaults)(&vw); P(nvnTextureViewSetLayers)(&vw, z, 1);
                NVNcopyRegion rg = {x, y, 0, w, h, 1};
                write_texels(tt, cs[c].layers > 1 ? (const view_t *)&vw : NULL, &rg, src, 0, 0);
                n++; if (memcmp(want, wtmem, tt->L.size)) bad++;
            }
            P(nvnTextureFinalize)(&t);
        }
        EXPECT("WriteTexels 区域直写与整级来回逐字节相同（15 例）", 0, bad); EXPECT("WriteTexels 区域例数", 15, n);
        P(nvnMemoryPoolFinalize)(&wtp);
    }

    // 6d. Lifecycle: in-flight GPU work is 0 when suspend returns; submits are blocked during suspend and let through after resume
    {
        size_t big = 64u << 20; uint8_t *heap; posix_memalign((void **)&heap, 16384, 2 * big); memset(heap, 0, 2 * big);
        NVNmemoryPoolBuilder hb; NVNmemoryPool hp; P(nvnMemoryPoolBuilderSetDefaults)(&hb); P(nvnMemoryPoolBuilderSetStorage)(&hb, heap, 2 * big);
        P(nvnMemoryPoolInitialize)(&hp, &hb);
        P(nvnCommandBufferBeginRecording)(&cb);
        for (int i = 0; i < 24; i++) P(nvnCommandBufferCopyBufferToBuffer)(&cb, (NVNbufferAddress)heap, (NVNbufferAddress)(heap + big), big, 0);
        NVNcommandHandle hbusy = P(nvnCommandBufferEndRecording)(&cb);
        P(nvnQueueSubmitCommands)(&q, 1, &hbusy);
        uint64_t f = mtl_last_fence();
        int busy_before = !mtl_wait(f, 0);
        dm_gfx_suspend(1);
        EXPECT("挂起前 GPU 确实在忙（零超时等待未完成）", 1, busy_before);
        EXPECT("挂起返回时在途工作已完成", 1, mtl_wait(f, 0));
        P(nvnCommandBufferBeginRecording)(&cb); P(nvnCommandBufferBarrier)(&cb, 0); NVNcommandHandle hsmall = P(nvnCommandBufferEndRecording)(&cb);
        g_sq = &q; g_sh = hsmall; g_sub = P(nvnQueueSubmitCommands); atomic_store(&g_sstarted, 0); atomic_store(&g_sdone, 0);
        pthread_t th; pthread_create(&th, NULL, susp_thr, NULL);
        int started = wait_started();
        EXPECT("挂起期间另一线程已进入提交且尚未返回", 1, started && !atomic_load(&g_sdone));
        dm_gfx_suspend(0);
        pthread_join(th, NULL);
        EXPECT("恢复后该提交放行返回", 1, atomic_load(&g_sdone));
        P(nvnQueueFinish)(&q); P(nvnMemoryPoolFinalize)(&hp); free(heap);
    }

    // 6e. Present pacing (real-device semantics): present returns immediately; blocking happens at acquire - swapchain of 3, interval 1, 60 Hz, the 4th acquire waits until texture 0 has been displayed for a full period
    {
        nvn_present_config(60, 0);
        NVNwindowBuilder wb2; NVNwindow w2; P(nvnWindowBuilderSetDevice)(&wb2, &dev); P(nvnWindowBuilderSetDefaults)(&wb2);
        NVNtexture *sc3[3] = {&sc[0], &sc[1], &sc[0]};
        P(nvnWindowBuilderSetTextures)(&wb2, 3, sc3); P(nvnWindowInitialize)(&w2, &wb2); P(nvnWindowSetPresentInterval)(&w2, 1);
        int ix;
        for (int k = 0; k < 3; k++) {
            P(nvnWindowAcquireTexture)(&w2, NULL, &ix);
            P(nvnQueuePresentTexture)(&q, &w2, ix);
        }
        P(nvnWindowAcquireTexture)(&w2, NULL, &ix);
        EXPECT("第 4 次取到的是第 0 张", 0, ix);
        P(nvnQueuePresentTexture)(&q, &w2, ix);
        P(nvnWindowAcquireTexture)(&w2, NULL, &ix);
        EXPECT("第 5 次取到的是第 1 张", 1, ix);
        nvn_present_config(0, 0);
    }

    // 6f. Present thread: when the drawable stays unavailable for a long time (the present thread stalls 200 ms each time), the present call still returns immediately;
    //     after the swapchain has gone a full round, re-acquiring texture 0 has to wait until its present has been processed (first enqueue + 200 ms)
    {
        nvn_present_config(0, 0);   // do not wait on the display link; only check that the present thread hands it back
        const double S = 200;
        mtl_present_test_stall((uint64_t)(S * 1e6));
        NVNwindowBuilder wb3; NVNwindow w3; P(nvnWindowBuilderSetDevice)(&wb3, &dev); P(nvnWindowBuilderSetDefaults)(&wb3);
        NVNtexture *sc3[3] = {&sc[0], &sc[1], &sc[0]};
        P(nvnWindowBuilderSetTextures)(&wb3, 3, sc3); P(nvnWindowInitialize)(&w3, &wb3);
        int ix;
        for (int k = 0; k < 3; k++) {
            P(nvnWindowAcquireTexture)(&w3, NULL, &ix);
            P(nvnQueuePresentTexture)(&q, &w3, ix);
        }
        P(nvnWindowAcquireTexture)(&w3, NULL, &ix);
        EXPECT("取到的是第 0 张", 0, ix);
        mtl_present_test_stall(0); mtl_present_flush();
    }

    // 7. Unimplemented functions: return 0, report a failure, report only once
    // Use a function that is still unimplemented (nvnBufferBuilderSetDefaults, used before, was implemented later and crashes on NULL)
    unsigned ui = 0; while (strcmp(nvn_names[ui], "nvnBufferBuilderGetDevice")) ui++;
    ((void (*)(void *))proc("nvnBufferBuilderGetDevice"))(NULL); ((void (*)(void *))proc("nvnBufferBuilderGetDevice"))(NULL);
    EXPECT("未实现函数被调用后记为已报红", 1, g_unimpl_seen[ui] > 0);
    EXPECT("未实现函数计数 2", 2, nvn_slot[ui].cnt);

    printf("== %d 项，失败 %d ==\n", g_n, g_fail);
    return g_fail != 0;
}
