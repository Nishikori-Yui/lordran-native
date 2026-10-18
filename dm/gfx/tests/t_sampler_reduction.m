// NVN sampler state -> descriptor-pool snapshot -> production Metal sampler.
// Expected pixels use a small, independent CPU filter over two known mip levels.
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
static const float base[4][4] = {
    {.125f, .875f, .375f, 1}, {.5f, .5f, 1, 1},
    {.875f, .25f, .625f, 1}, {.375f, .75f, .125f, 1}
};
static const float mip[4] = {1, .125f, .875f, 1};
static const float lods[5] = {-.5f, 0, .25f, .75f, 1};

static float spatial(int channel, int linear, int reduction) {
    if (!linear) return base[3][channel];
    float value = reduction ? base[0][channel] : 0;
    for (int i = 0; i < 4; i++) {
        float x = base[i][channel];
        value = reduction == 1 ? fminf(value, x) : reduction == 2 ? fmaxf(value, x) : value + x * .25f;
    }
    return value;
}
static float expected(int channel, int min_filter, int mag_filter, int reduction, float lod) {
    const int linear_min[6] = {0, 1, 0, 1, 0, 1};
    const int mip_mode[6] = {0, 0, 1, 1, 2, 2};
    float low = spatial(channel, lod <= 0 ? mag_filter : linear_min[min_filter], reduction);
    if (!mip_mode[min_filter] || lod <= 0) return low;
    float high = mip[channel];
    if (lod >= 1) return high;
    if (mip_mode[min_filter] == 1) return lod < .5f ? low : high;
    return reduction == 1 ? fminf(low, high) : reduction == 2 ? fmaxf(low, high) : low * (1 - lod) + high * lod;
}

int main(void) { @autoreleasepool {
    mtl_init();
    if (!g_dev) return 2;
    NSError *error = nil;
    id<MTLLibrary> lib = [g_dev newLibraryWithSource:
        @"#include <metal_stdlib>\nusing namespace metal;\n"
         "kernel void sample0(texture2d<float> t [[texture(0)]], sampler s [[sampler(0)]],"
         " device float4 *out [[buffer(0)]], uint i [[thread_position_in_grid]]) {"
         " float lod[5] = {-.5, 0, .25, .75, 1};"
         " out[i] = t.sample(s, float2(.5), level(lod[i])); }"
        options:nil error:&error];
    id<MTLComputePipelineState> ps = lib ? [g_dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"sample0"] error:&error] : nil;
    if (!ps) { fprintf(stderr, "%s\n", error.localizedDescription.UTF8String); return 1; }
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA32Float width:2 height:2 mipmapped:YES];
    td.storageMode = MTLStorageModeShared;
    id<MTLTexture> texture = [g_dev newTextureWithDescriptor:td];
    [texture replaceRegion:MTLRegionMake2D(0, 0, 2, 2) mipmapLevel:0 withBytes:base bytesPerRow:32];
    [texture replaceRegion:MTLRegionMake2D(0, 0, 1, 1) mipmapLevel:1 withBytes:mip bytesPerRow:16];

    void *storage = NULL;
    if (posix_memalign(&storage, 16384, 16384)) return 1;
    NVNmemoryPoolBuilder pool_builder = {0}; NVNmemoryPool memory_pool = {0};
    h_nvnMemoryPoolBuilderSetDefaults(&pool_builder);
    h_nvnMemoryPoolBuilderSetStorage(&pool_builder, storage, 16384);
    h_nvnMemoryPoolBuilderSetFlags(&pool_builder, 0x24);
    CHECK("memory pool initializes", h_nvnMemoryPoolInitialize(&memory_pool, &pool_builder));
    NVNsamplerPool pool = {0};
    CHECK("sampler pool initializes", h_nvnSamplerPoolInitialize(&pool, &memory_pool, 0, 257));
    NVNcommandBuffer cmd = {0};
    h_nvnCommandBufferInitialize(&cmd, NULL);
    h_nvnCommandBufferAddCommandMemory(&cmd, &memory_pool, 12288, 4096);
    h_nvnCommandBufferBeginRecording(&cmd);
    h_nvnCommandBufferSetSamplerPool(&cmd, &pool);
    mtl_exec((const uint8_t *)h_nvnCommandBufferEndRecording(&cmd));

    NVNsamplerBuilder builder = {0}; NVNsampler original, average;
    h_nvnSamplerBuilderSetDefaults(&builder);
    h_nvnSamplerInitialize(&original, &builder);
    CHECK("default reduction is average", h_nvnSamplerGetReductionFilter(&original) == NVN_SAMPLER_REDUCTION_AVERAGE);
    h_nvnSamplerBuilderSetReductionFilter(&builder, NVN_SAMPLER_REDUCTION_MAX);
    h_nvnSamplerBuilderSetDefaults(&builder);
    h_nvnSamplerInitialize(&original, &builder);
    CHECK("SetDefaults resets reduction", h_nvnSamplerGetReductionFilter(&original) == NVN_SAMPLER_REDUCTION_AVERAGE);

    for (int min_filter = 0; min_filter < 6; min_filter++) for (int mag_filter = 0; mag_filter < 2; mag_filter++) for (int reduction = 0; reduction < 3; reduction++) {
        h_nvnSamplerBuilderSetDefaults(&builder);
        h_nvnSamplerBuilderSetMinMagFilter(&builder, min_filter, mag_filter);
        h_nvnSamplerBuilderSetReductionFilter(&builder, reduction);
        h_nvnSamplerInitialize(&original, &builder);
        CHECK("object preserves reduction", h_nvnSamplerGetReductionFilter(&original) == reduction);
        h_nvnSamplerBuilderSetReductionFilter(&builder, NVN_SAMPLER_REDUCTION_AVERAGE);
        h_nvnSamplerInitialize(&average, &builder);
        CHECK("sampler comparison includes reduction", h_nvnSamplerCompare(&original, &average) == (reduction == 0));

        h_nvnSamplerPoolRegisterSampler(&pool, 256, &original);
        h_nvnSamplerFinalize(&original);
        h_nvnSamplerInitialize(&original, &builder);   // Reuse the object; the registered descriptor must retain its snapshot.
        id<MTLSamplerState> sampler = samp_by_id(256);
        CHECK("registered sampler cache reuses the matching state", sampler && sampler == samp_by_id(256));
        if (!sampler) return 1;

        id<MTLBuffer> output = [g_dev newBufferWithLength:sizeof(float) * 20 options:MTLResourceStorageModeShared];
        id<MTLCommandBuffer> cb = [g_q commandBuffer];
        id<MTLComputeCommandEncoder> enc = [cb computeCommandEncoder];
        [enc setComputePipelineState:ps]; [enc setTexture:texture atIndex:0];
        [enc setSamplerState:sampler atIndex:0]; [enc setBuffer:output offset:0 atIndex:0];
        [enc dispatchThreads:MTLSizeMake(5, 1, 1) threadsPerThreadgroup:MTLSizeMake(5, 1, 1)];
        [enc endEncoding]; [cb commit]; [cb waitUntilCompleted];
        if (cb.status != MTLCommandBufferStatusCompleted) return 1;
        float *actual = output.contents;
        for (int l = 0; l < 5; l++) {
            int bad = 0;
            for (int c = 0; c < 4; c++) {
                float value = actual[4 * l + c];
                bad |= !isfinite(value) || fabsf(value - expected(c, min_filter, mag_filter, reduction, lods[l])) > 1e-6f;
            }
            CHECK("GPU pixel matches independent reduction/filter result", !bad);
            if (bad) fprintf(stderr, "min=%d mag=%d reduction=%d lod=%g got=%g,%g,%g,%g\n",
                             min_filter, mag_filter, reduction, lods[l], actual[4*l], actual[4*l+1], actual[4*l+2], actual[4*l+3]);
        }
    }
    h_nvnSamplerPoolFinalize(&pool);
    h_nvnMemoryPoolFinalize(&memory_pool);
    free(storage);
    printf("Sampler reduction: 36 configurations, 180 RGBA samples, %d checks, %d failures\n", checks, failures);
    return failures != 0;
} }
