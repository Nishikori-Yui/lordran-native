// Exercise occlusion reports through NVN recording and production Metal replay.
#define nvn_game_fps nvn_game_fps_mtl_default
#include "../nvn/nvn_mtl.m"
#undef nvn_game_fps
#include "../nvn/hle_nvn.c"

uint64_t g_t0_ns;
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t g_mod[MAX_MOD]; int g_nmod;
void svc_thread_dump(void) {}
int dm_guest_as_contains(uintptr_t p) { (void)p; return 0; }
uint64_t now_ns(void) { return bp_now(); }

static int checks, failures;
#define CHECK(label, want, got) do { \
    uint64_t w = (want), v = (got); checks++; \
    if (w != v) { failures++; fprintf(stderr, "FAIL: %s: got %llu, expected %llu\n", \
        label, (unsigned long long)v, (unsigned long long)w); } \
} while (0)

static NVNcommandBuffer cmd;
static prog_t program = {.serial = 95000};
static tex_t target = {.magic = MAGIC('T', 'E', 'X', 0), .serial = 95001,
    .d = {.target = NVN_TEXTURE_TARGET_2D, .width = 8, .height = 8,
          .depth = 1, .levels = 1, .samples = 1, .format = NVN_FORMAT_RGBA8}};
static NVNcounterData reports[24];

static void reset(void) { h_nvnCommandBufferResetCounter(&cmd, NVN_COUNTER_TYPE_SAMPLES_PASSED); }
static void report(int slot) {
    h_nvnCommandBufferReportCounter(&cmd, NVN_COUNTER_TYPE_SAMPLES_PASSED, (uintptr_t)&reports[slot]);
}
static void pass(void) {
    const NVNtexture *textures[] = {(const NVNtexture *)&target};
    h_nvnCommandBufferSetRenderTargets(&cmd, 1, textures, NULL, NULL, NULL);
    h_nvnCommandBufferSetScissor(&cmd, 0, 0, 8, 8);
    float black[] = {0, 0, 0, 1};
    h_nvnCommandBufferClearColor(&cmd, 0, black, NVN_CLEAR_COLOR_MASK_RGBA);
}
static void triangle(void) { h_nvnCommandBufferDrawArrays(&cmd, NVN_DRAW_PRIMITIVE_TRIANGLES, 0, 3); }
static void begin(void) {
    h_nvnCommandBufferBeginRecording(&cmd);
    h_nvnCommandBufferBindProgram(&cmd, (const NVNprogram *)&program, 3);
}
static uint64_t submit_async(void) {
    NVNcommandHandle handle = h_nvnCommandBufferEndRecording(&cmd);
    mtl_sub_begin(); mtl_exec((const uint8_t *)handle);
    return mtl_sub_commit();
}
static void complete(uint64_t fence) {
    int done = mtl_wait(fence, 5000000000ull);
    CHECK("GPU completion", 1, done);
    if (!done) abort();
    CHECK("GPU error", 0, mtl_last_commit_error());
}
static void submit(void) { complete(submit_async()); }

int main(void) { @autoreleasepool {
    setenv("DM_NVN_TBDR", "0", 1);
    mtl_init();
    if (!g_dev) return 2;
    NSError *error = nil;
    id<MTLLibrary> lib = [g_dev newLibraryWithSource:
        @"#include <metal_stdlib>\nusing namespace metal;\n"
         "vertex float4 v(uint n [[vertex_id]]) {"
         " float2 p[3] = {float2(-1,-1), float2(3,-1), float2(-1,3)};"
         " return float4(p[n], .5, 1); }\n"
         "fragment float4 f() { return float4(1); }\n"
        options:nil error:&error];
    if (!lib) { fprintf(stderr, "%s\n", error.localizedDescription.UTF8String); return 2; }
    NvProg *p = [NvProg new];
    p->sh[0] = [NvShader new]; p->sh[0]->fn = [lib newFunctionWithName:@"v"];
    p->sh[1] = [NvShader new]; p->sh[1]->fn = [lib newFunctionWithName:@"f"]; p->sh[1]->stage = 1;
    serial_put(program.serial, p);
    void *memory = NULL;
    if (posix_memalign(&memory, 16384, 65536)) return 2;
    pool_t pool = {.mem = memory, .size = 65536};
    mtl_pool_add(memory, pool.size);
    h_nvnCommandBufferInitialize(&cmd, NULL);
    h_nvnCommandBufferAddCommandMemory(&cmd, (const NVNmemoryPool *)&pool, 0, pool.size);

    begin(); reset(); pass(); triangle(); report(0);
    pass(); triangle(); report(1);
    pass(); triangle(); report(2);
    submit();
    CHECK("first report survives later render passes", 64, reports[0].counter);
    CHECK("second report accumulates two passes", 128, reports[1].counter);
    CHECK("third report accumulates three passes", 192, reports[2].counter);

    begin(); reset(); pass(); triangle(); report(3);
    triangle(); report(4);
    reset(); report(5);
    triangle(); report(6);
    submit();
    CHECK("report snapshots earlier draws in the same pass", 64, reports[3].counter);
    CHECK("two same-pass draws accumulate", 128, reports[4].counter);
    CHECK("reset without a draw returns zero", 0, reports[5].counter);
    CHECK("reset inside a pass starts another query", 64, reports[6].counter);

    begin(); reset(); pass(); triangle(); report(7); submit();
    begin(); pass(); h_nvnCommandBufferSetScissor(&cmd, 0, 0, 8, 4);
    triangle(); report(8); submit();
    CHECK("report before a submission boundary", 64, reports[7].counter);
    CHECK("counter survives a submission boundary", 96, reports[8].counter);

    begin(); pass(); h_nvnCommandBufferSetScissor(&cmd, 0, 0, 2, 4);
    triangle(); report(9); submit();
    CHECK("third submission retains both earlier counts", 104, reports[9].counter);
    begin(); pass(); h_nvnCommandBufferSetScissor(&cmd, 0, 0, 0, 0);
    triangle(); report(10); submit();
    CHECK("an occluded draw preserves earlier samples", 104, reports[10].counter);
    begin(); reset(); report(11); submit();
    CHECK("reset clears folded samples too", 0, reports[11].counter);
    begin(); reset(); pass(); triangle(); report(12); submit();
    CHECK("reused visibility buffer does not retain old counts", 64, reports[12].counter);

    // Hold four submissions in flight so every visibility-ring buffer is used.
    id<MTLSharedEvent> gate = [g_dev newSharedEvent];
    [g_q4 waitForEvent:gate value:1];
    uint64_t fence = 0;
    for (int i = 0; i < 4; i++) {
        reports[13 + i].counter = UINT64_MAX;
        begin(); if (!i) reset(); pass();
        h_nvnCommandBufferSetScissor(&cmd, 0, 0, 8, i + 1);
        triangle(); report(13 + i); fence = submit_async();
    }
    CHECK("all visibility-ring buffers exercised", 4, g_vis_ring_n);
    CHECK("reports wait for GPU completion", UINT64_MAX, reports[13].counter);
    gate.signaledValue = 1;
    complete(fence);
    uint64_t expected = 0;
    for (int i = 0; i < 4; i++) {
        expected += 8 * (i + 1);
        CHECK("in-flight report retains its snapshot", expected, reports[13 + i].counter);
    }
    for (int i = 4; i < 8; i++) {
        begin(); pass(); h_nvnCommandBufferSetScissor(&cmd, 0, 0, 8, i + 1);
        triangle(); report(13 + i); submit();
        expected += 8 * (i + 1);
        CHECK("ring reuse preserves every earlier submission", expected, reports[13 + i].counter);
    }
    h_nvnCommandBufferFinalize(&cmd);
    mtl_pool_del(memory); free(memory);
    printf("Visibility: %d checks, %d failures\n", checks, failures);
    return failures != 0;
} }
