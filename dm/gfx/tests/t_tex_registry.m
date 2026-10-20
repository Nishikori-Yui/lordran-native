// Re-uploading while resolving a descriptor must invalidate its cache exactly once.
#include "../nvn/nvn_mtl.m"
#include <assert.h>

int prog_key(const prog_t *p, unsigned stage, uint8_t key[8]) { (void)p; (void)stage; memset(key, 0, 8); return 0; }
uint64_t nvn_new_serial(void) { static uint64_t serial = 80000; return ++serial; }
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t g_mod[MAX_MOD]; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }

static void test_feedback_pool(void) {
    __block __weak id probe;
    void *(*autorelease_raw)(void *) = dlsym(RTLD_DEFAULT, "objc_autorelease");
    assert(autorelease_raw);
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    dispatch_async(g_feedback_q, ^{
        id object = [NSObject new];
        probe = object;
        autorelease_raw((void *)CFBridgingRetain(object));
        // This next work item runs after the first item's pool has drained.
        dispatch_async(g_feedback_q, ^{ dispatch_semaphore_signal(done); });
    });
    assert(!dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC)));
    assert(!probe);
}

static void test_memory_text(void) {
    char text[32];
    memset(text, 0xff, sizeof text);
    assert(mtl_alloc_size_text(123, text, sizeof text) == text);
#if TARGET_OS_SIMULATOR
    assert(!strcmp(text, "unavailable"));
#else
    assert(!strcmp(text, "123"));
#endif
}

static void test_upload_versions(void) {
    tex_t t = {.magic = MAGIC('T', 'E', 'X', 0), .serial = 70002, .has_layout = 1};
    t.d = (nvn_texdesc){.width = 16, .height = 16, .depth = 1, .levels = 1,
        .target = NVN_TEXTURE_TARGET_2D, .format = NVN_FORMAT_RGBA8, .pkg_block_h = 1};
    nvn_tex_layout(&t.d, &t.L);
    t.mem = calloc(1, t.L.size); assert(t.mem);
    mtl_reg_tex(258, &t, NULL);
    id<MTLBuffer> readback = [g_dev newBufferWithLength:2048 options:MTLResourceStorageModeShared];
    assert(readback); res_add(readback);
    mtl_sub_begin();
    for (int version = 0; version < 2; version++) {
        memset(t.mem, version ? 0x22 : 0x11, t.L.size);
        rmu_lock(); g_ser_gen++;
        id<MTLTexture> texture = tex_by_id(258);
        assert(texture);
        enc_b_copy_texture_buffer(blit(), texture, 0, 0, MTLOriginMake(0, 0, 0),
            MTLSizeMake(16, 16, 1), readback, version * 1024, 64, 1024);
        rmu_unlock();
    }
    uint64_t fence = mtl_sub_commit();
    assert(mtl_wait(fence, 5000000000ull) && !mtl_last_commit_error());
    const uint8_t *pixels = readback.contents;
    for (int i = 0; i < 2048; i++) assert(pixels[i] == (i < 1024 ? 0x11 : 0x22));
    res_remove(readback);
    mtl_tex_release(&t);
    mtl_sub_begin(); fence = mtl_sub_commit();
    assert(mtl_wait(fence, 5000000000ull));
    free(t.mem);
    puts("texture upload: two versions in one submission preserve both GPU readbacks");
}

static void test_movie_stream(void) {
    assert(g_nvn_deswz_gpu);
    tex_t t = {.magic = MAGIC('T', 'E', 'X', 0), .serial = 70003, .has_layout = 1};
    t.d = (nvn_texdesc){.width = 1920, .height = 1080, .depth = 1, .levels = 1,
        .target = NVN_TEXTURE_TARGET_2D, .format = NVN_FORMAT_RGBA8, .pkg_block_h = 1};
    nvn_tex_layout(&t.d, &t.L);
    size_t size = (t.L.size + getpagesize() - 1) & ~((size_t)getpagesize() - 1);
    assert(!posix_memalign((void **)&t.mem, getpagesize(), size));
    memset(t.mem, 0x55, size);
    mtl_pool_add(t.mem, size);
    mtl_reg_tex(259, &t, NULL);
    NSHashTable *versions = [NSHashTable weakObjectsHashTable];
    uint64_t settled_bytes = 0;
    for (int i = 0; i < 512; i++) { @autoreleasepool {
        mtl_sub_begin();
        rmu_lock(); g_ser_gen++;
        id<MTLTexture> texture = tex_by_id(259); assert(texture);
        [versions addObject:texture];
        rmu_unlock();
        uint64_t fence = mtl_sub_commit();
        assert(mtl_wait(fence, 5000000000ull) && !mtl_last_commit_error());
        dispatch_sync(g_feedback_q, ^{});
        assert(versions.allObjects.count <= 2);
        uint64_t allocated = g_dev.currentAllocatedSize;
        if (i == 127) settled_bytes = allocated;
        if (i >= 128) assert(allocated <= settled_bytes + (128ull << 20));
    } }
    mtl_tex_release(&t); mtl_pool_del(t.mem);
    mtl_sub_begin(); uint64_t fence = mtl_sub_commit();
    assert(mtl_wait(fence, 5000000000ull));
    dispatch_sync(g_feedback_q, ^{});
    assert(!serial_get(t.serial));
    assert(!g_treg[259].view && !g_treg[259].alt);
    // Completion objects may outlive a fence, but retired storage must not
    // stay resident or accumulate with the number of uploaded frames.
    assert(versions.allObjects.count <= 2);
    for (id texture in versions.allObjects) assert(![g_res_objects containsObject:texture]);
    free(t.mem);
    puts("movie stream: 512 full-HD GPU uploads, bounded allocations and residency retirement passed");
}

int main(int argc, char **argv) { @autoreleasepool {
    alarm(30);
    mtl_init();
    test_memory_text();
    test_feedback_pool();
    if (argc == 2 && !strcmp(argv[1], "--pools-only")) {
        puts("GPU feedback: autoreleased objects are released between work items");
        return 0;
    }
    if (argc == 2 && !strcmp(argv[1], "--movie-stream")) {
        test_movie_stream();
        return 0;
    }
    g_nvn_deswz_gpu = 0;
    test_upload_versions();
    tex_t t = {.magic = MAGIC('T', 'E', 'X', 0), .serial = 70001, .has_layout = 1};
    t.d = (nvn_texdesc){.width = 16, .height = 16, .depth = 1, .levels = 1,
        .target = NVN_TEXTURE_TARGET_2D, .format = NVN_FORMAT_RGBA8, .pkg_block_h = 1};
    nvn_tex_layout(&t.d, &t.L);
    t.mem = calloc(1, t.L.size);
    assert(t.mem);
    view_t view = {.set_levels = 1, .nlevels = 1};
    mtl_reg_tex(256, &t, &view);
    mtl_reg_tex(257, &t, &view);
    uint64_t reuploads = g_pkg_reuploads;
    for (int i = 0; i < 64; i++) { @autoreleasepool {
        mtl_sub_begin();
        rmu_lock();
        // Untracked storage is conservatively re-uploaded on a slow lookup.
        // Force one even when both global generations would otherwise match.
        g_ser_gen++;
        int tid = 256 + ((i / 4) & 1);
        id<MTLTexture> resolved = tex_by_id(tid);
        assert(resolved && g_treg[tid].view == (__bridge void *)resolved);
        NvPkg *pkg = serial_get(t.serial);
        assert(resolved == pkg->tex || resolved.parentTexture == pkg->tex);
        assert(!g_treg[tid ^ 1].view && !g_treg[tid ^ 1].alt);
        uint64_t rid = 0;
        assert(tex_fit(tid, resolved, MTLTextureType2DArray, &rid) && rid);
        rmu_unlock();
        uint64_t fence = mtl_sub_commit();
        assert(mtl_wait(fence, 5000000000ull));
        assert(!mtl_last_commit_error());
    } }
    assert(g_pkg_reuploads - reuploads == 63);
    mtl_tex_release(&t);
    assert(!g_treg[256].view && !g_treg[257].view);
    assert(!g_treg[256].alt && !g_treg[257].alt);
    mtl_sub_begin();
    uint64_t fence = mtl_sub_commit();
    assert(mtl_wait(fence, 5000000000ull));
    free(t.mem);
    puts("texture registry: 64 uploads, alias invalidation and finalization passed");
    return 0;
} }
