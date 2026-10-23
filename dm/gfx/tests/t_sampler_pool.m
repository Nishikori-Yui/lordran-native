// Descriptor-pool switching must change GPU sampling even with the same handle.
#define nvn_game_fps nvn_game_fps_mtl_default
#include "../nvn/nvn_mtl.m"
#undef nvn_game_fps
#include "../nvn/hle_nvn.c"
#include <math.h>

uint64_t g_t0_ns;
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t g_mod[MAX_MOD]; int g_nmod;
void svc_thread_dump(void) {}
int dm_guest_as_contains(uintptr_t p) { (void)p; return 0; }
uint64_t now_ns(void) { return bp_now(); }

static int checks, failures;
#define CHECK(label, condition) do { checks++; if (!(condition)) { failures++; fprintf(stderr, "FAIL: %s\n", label); } } while (0)

static NVNcommandHandle selection(NVNcommandBuffer *cmd, const NVNsamplerPool *pool) {
    h_nvnCommandBufferBeginRecording(cmd);
    h_nvnCommandBufferSetSamplerPool(cmd, pool);
    return h_nvnCommandBufferEndRecording(cmd);
}
static NVNcommandHandle selection_tex(NVNcommandBuffer *cmd, const NVNtexturePool *pool) {
    h_nvnCommandBufferBeginRecording(cmd);
    h_nvnCommandBufferSetTexturePool(cmd, pool);
    return h_nvnCommandBufferEndRecording(cmd);
}
static void select_pool(NVNcommandHandle handle) { mtl_exec((const uint8_t *)handle); }
static void register_sampler(NVNsamplerPool *pool, int sid, int linear) {
    NVNsamplerBuilder builder = {0}; NVNsampler sampler = {0};
    h_nvnSamplerBuilderSetDefaults(&builder);
    h_nvnSamplerBuilderSetMinMagFilter(&builder, linear, linear);
    h_nvnSamplerInitialize(&sampler, &builder);
    h_nvnSamplerPoolRegisterSampler(pool, sid, &sampler);
    h_nvnSamplerFinalize(&sampler);
}
static void check_encoded_sample(NvShader *shader, id<MTLComputePipelineState> pipeline,
                                 id<MTLTexture> texture, float expected, const char *label) {
    id<MTLBuffer> output = [g_dev newBufferWithLength:16 options:MTLResourceStorageModeShared];
    id<MTLCommandBuffer> cb = [g_q commandBuffer];
    id<MTLComputeCommandEncoder> enc = [cb computeCommandEncoder];
    [enc setComputePipelineState:pipeline];
    [enc setBuffer:shader->ab_buf offset:shader->ab_off atIndex:0];
    [enc setBuffer:output offset:0 atIndex:1];
    [enc useResource:texture usage:MTLResourceUsageRead];
    [enc dispatchThreads:MTLSizeMake(1, 1, 1) threadsPerThreadgroup:MTLSizeMake(1, 1, 1)];
    [enc endEncoding]; [cb commit]; [cb waitUntilCompleted];
    CHECK("GPU sampling completes", cb.status == MTLCommandBufferStatusCompleted);
    float *value = output.contents;
    CHECK(label, isfinite(value[0]) && fabsf(value[0] - expected) < 1e-6f);
    if (fabsf(value[0] - expected) >= 1e-6f) fprintf(stderr, "%s: got %g, expected %g\n", label, value[0], expected);
}
static void check_sample(NvShader *shader, id<MTLComputePipelineState> pipeline,
                         id<MTLTexture> texture, float expected, const char *label) { @autoreleasepool {
    CHECK("argument encoding succeeds", encode_args(nil, shader, 1, 0));
    check_encoded_sample(shader, pipeline, texture, expected, label);
} }

int main(void) { @autoreleasepool {
    mtl_init();
    if (!g_dev) return 2;
    NSError *error = nil;
    id<MTLLibrary> library = [g_dev newLibraryWithSource:
        @"#include <metal_stdlib>\nusing namespace metal;\n"
         "struct Args { texture2d<float> t [[id(0)]]; sampler s [[id(1)]]; };\n"
         "kernel void sample0(constant Args &a [[buffer(0)]], device float4 *out [[buffer(1)]]) {"
         " out[0] = a.t.sample(a.s, float2(.5), level(0)); }"
        options:nil error:&error];
    id<MTLFunction> function = [library newFunctionWithName:@"sample0"];
    id<MTLComputePipelineState> pipeline = function ? [g_dev newComputePipelineStateWithFunction:function error:&error] : nil;
    if (!pipeline) { fprintf(stderr, "%s\n", error.localizedDescription.UTF8String); return 1; }
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA32Float width:2 height:2 mipmapped:NO];
    td.storageMode = MTLStorageModeShared;
    id<MTLTexture> texture = [g_dev newTextureWithDescriptor:td];
    const float pixels[4][4] = {{0, 0, 0, 1}, {.25, 0, 0, 1}, {.75, 0, 0, 1}, {1, 0, 0, 1}};
    [texture replaceRegion:MTLRegionMake2D(0, 0, 2, 2) mipmapLevel:0 withBytes:pixels bytesPerRow:32];
    id<MTLTexture> texture2 = [g_dev newTextureWithDescriptor:td];
    const float pixels2[4][4] = {{.125, 0, 0, 1}, {.125, 0, 0, 1}, {.125, 0, 0, 1}, {.125, 0, 0, 1}};
    [texture2 replaceRegion:MTLRegionMake2D(0, 0, 2, 2) mipmapLevel:0 withBytes:pixels2 bytesPerRow:32];
    tex_t tex = {.magic = MAGIC('T', 'E', 'X', 0), .serial = 10001};
    tex.d.width = tex.d.height = 2; tex.d.depth = tex.d.levels = 1;
    tex.d.target = NVN_TEXTURE_TARGET_2D; tex.d.format = NVN_FORMAT_RGBA32F;
    serial_put(tex.serial, texture);
    mtl_reg_tex(256, &tex, NULL);
    tex_t tex2 = tex; tex2.serial = 10002;
    serial_put(tex2.serial, texture2);

    void *storage = NULL;
    if (posix_memalign(&storage, 16384, 65536)) return 1;
    memset(storage, 0, 65536);
    NVNmemoryPoolBuilder builder = {0}; NVNmemoryPool memory = {0};
    h_nvnMemoryPoolBuilderSetDefaults(&builder);
    h_nvnMemoryPoolBuilderSetStorage(&builder, storage, 65536);
    h_nvnMemoryPoolBuilderSetFlags(&builder, 0x24);
    CHECK("memory pool initializes", h_nvnMemoryPoolInitialize(&memory, &builder));
    NVNtexturePool tex_first = {0}, tex_second = {0};
    NVNsamplerPool first = {0}, second = {0}, alias = {0}, shifted = {0};
    NVNmemoryPool memory_alias = memory;
    CHECK("first texture pool initializes", h_nvnTexturePoolInitialize(&tex_first, &memory, 32768, 257));
    CHECK("second texture pool initializes", h_nvnTexturePoolInitialize(&tex_second, &memory, 40960, 257));
    CHECK("first pool initializes", h_nvnSamplerPoolInitialize(&first, &memory, 0, 257));
    CHECK("second pool initializes", h_nvnSamplerPoolInitialize(&second, &memory, 16384, 257));
    CHECK("alias pool initializes", h_nvnSamplerPoolInitialize(&alias, &memory_alias, 0, 257));
    CHECK("overlapping pool initializes", h_nvnSamplerPoolInitialize(&shifted, &memory, 32, 256));
    NVNcommandBuffer cmd = {0};
    h_nvnCommandBufferInitialize(&cmd, NULL);
    h_nvnCommandBufferAddCommandMemory(&cmd, &memory, 49152, 16384);
    NVNcommandHandle tex_a = selection_tex(&cmd, &tex_first), tex_b = selection_tex(&cmd, &tex_second);
    NVNcommandHandle a = selection(&cmd, &first), b = selection(&cmd, &second);
    NVNcommandHandle c = selection(&cmd, &alias), d = selection(&cmd, &shifted);

    register_sampler(&first, 256, 0);
    register_sampler(&second, 256, 1);
    h_nvnTexturePoolRegisterTexture(&tex_first, 256, (const NVNtexture *)&tex, NULL);
    h_nvnTexturePoolRegisterTexture(&tex_second, 256, (const NVNtexture *)&tex2, NULL);
    select_pool(tex_a);
    select_pool(a);
    S.tex[1][0] = 256 | (256ull << 20);
    NvShader *shader = [NvShader new];
    shader->ae = [function newArgumentEncoderWithBufferIndex:0];
    shader->arg_len = shader->ae.encodedLength;
    shader->rf.abi = 0; shader->rf.nb = 2;
    shader->rf.b[0] = (nvn_rbind){.kind = NVN_RB_TEX, .reg = 0, .aid = 0, .dtt = MTLTextureType2D};
    shader->rf.b[1] = (nvn_rbind){.kind = NVN_RB_SAMPT, .reg = 0, .aid = 1};
    arena_begin();
    check_sample(shader, pipeline, texture, 1, "first pool retains nearest sampling");
    select_pool(tex_b);
    check_sample(shader, pipeline, texture2, .125, "switching texture pools changes the texture for the same handle");
    select_pool(tex_a);
    check_sample(shader, pipeline, texture, 1, "switching texture pools back restores the original texture");
    uint64_t encoded = g_stat_args_enc, reused = g_stat_args_reuse;
    check_sample(shader, pipeline, texture, 1, "unchanged pool reuses correct arguments");
    CHECK("unchanged bindings reuse their argument block", g_stat_args_enc == encoded && g_stat_args_reuse == reused + 1);

    select_pool(b);
    check_sample(shader, pipeline, texture, .5, "switching pools changes sampling without rebinding the handle");
    CHECK("pool switch rebuilds cached arguments", g_stat_args_enc == encoded + 1);
    select_pool(a);
    check_sample(shader, pipeline, texture, 1, "switching back restores the first descriptor");
    register_sampler(&second, 256, 1);
    check_sample(shader, pipeline, texture, 1, "registration in an inactive pool leaves the active pool intact");

    select_pool(c);
    check_sample(shader, pipeline, texture, 1, "a second wrapper reads the same descriptor storage");
    register_sampler(&alias, 256, 1);
    select_pool(a);
    check_sample(shader, pipeline, texture, .5, "registration through an alias updates shared storage");
    register_sampler(&shifted, 255, 0);
    check_sample(shader, pipeline, texture, 1, "overlapping pools resolve the same physical descriptor");
    select_pool(d);
    S.tex[1][0] = 256 | (255ull << 20); args_dirty_all();
    check_sample(shader, pipeline, texture, 1, "descriptor offset and sampler ID are combined");
    h_nvnSamplerPoolFinalize(&alias);
    select_pool(a);
    S.tex[1][0] = 256 | (256ull << 20); args_dirty_all();
    check_sample(shader, pipeline, texture, 1, "finalizing an alias leaves shared descriptor storage intact");

    __weak id<MTLSamplerState> old;
    @autoreleasepool { old = samp_by_id(256); }
    @autoreleasepool { register_sampler(&first, 256, 1); }
    CHECK("replaced sampler remains alive for encoded GPU arguments", old != nil);
    check_encoded_sample(shader, pipeline, texture, 1, "already encoded arguments retain the old sampler after re-registration");
    check_sample(shader, pipeline, texture, .5, "re-registration refreshes the selected descriptor");
    h_nvnSamplerPoolFinalize(&first);
    CHECK("reinitializing a wrapper at another offset succeeds", h_nvnSamplerPoolInitialize(&first, &memory, 16384, 257));
    select_pool(a);
    check_sample(shader, pipeline, texture, .5, "reinitialized wrapper resolves its current storage");
    // The game's water/material shaders read combined handles from a uniform.
    shader->rf.b[0].kind = NVN_RB_TEXU; shader->rf.b[0].reg = 10; shader->rf.b[0].off = 48;
    shader->rf.b[1].kind = NVN_RB_SAMPU; shader->rf.b[1].reg = 10; shader->rf.b[1].off = 48;
    shader->rf.bindless = 1;
    uint32_t handle = 256 | (256u << 20);
    memcpy((uint8_t *)storage + 40000 + 48, &handle, sizeof handle);
    S.ubo[1][10] = (p_bind_buf){.stage = 1, .index = 10, .addr = (uintptr_t)storage + 40000, .size = 64};
    args_dirty_all();
    check_sample(shader, pipeline, texture, .5, "bindless uniform handles use the selected pool");
    NVNsamplerPool original_storage = {0};
    CHECK("another wrapper over original storage initializes", h_nvnSamplerPoolInitialize(&original_storage, &memory, 0, 257));
    register_sampler(&original_storage, 256, 0);
    NVNcommandHandle e = selection(&cmd, &original_storage);
    select_pool(e);
    check_sample(shader, pipeline, texture, 1, "pool switching refreshes bindless cached arguments");
    select_pool(b);
    check_sample(shader, pipeline, texture, .5, "bindless handles remain unchanged when switching back");
    h_nvnMemoryPoolFinalize(&memory);
    CHECK("finalizing storage removes its sampler descriptors", samp_by_id(256) == nil);
    free(storage);
    printf("Sampler pools: %d checks, %d failures\n", checks, failures);
    return failures != 0;
} }
