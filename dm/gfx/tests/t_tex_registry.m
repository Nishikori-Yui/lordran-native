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

int main(void) { @autoreleasepool {
    alarm(30);
    mtl_init();
    g_nvn_deswz_gpu = 0;
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
