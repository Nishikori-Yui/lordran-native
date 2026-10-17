#include "../nvn/nvn_mtl.m"
int prog_key(const prog_t *p, unsigned s, uint8_t k[8]) { (void)p; (void)s; memset(k, 0, 8); return 0; }
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t g_mod[MAX_MOD]; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
uint64_t nvn_new_serial(void) { static uint64_t s; return ++s; }

static int check(NvShader *vs, NvShader *fs, int fmt, const void *bytes, size_t size, const uint32_t want[4]) {
    pso_key k = {0};
    k.cfmt[0] = MTLPixelFormatRGBA32Uint; k.chmask = 15;
    k.attr[4].fmt = fmt;
    NSError *error = nil;
    MTLRenderPipelineDescriptor *d = pso_desc(&k, vs, fs, nil, 0);
    id<MTLRenderPipelineState> ps = [g_dev newRenderPipelineStateWithDescriptor:d error:&error];
    if (!ps) { fprintf(stderr, "pipeline: %s\n", error.localizedDescription.UTF8String); return 1; }
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA32Uint width:1 height:1 mipmapped:NO];
    td.usage = MTLTextureUsageRenderTarget; td.storageMode = MTLStorageModeShared;
    id<MTLTexture> target = [g_dev newTextureWithDescriptor:td];
    id<MTLBuffer> vb = [g_dev newBufferWithBytes:bytes length:size options:MTLResourceStorageModeShared];
    MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
    rp.colorAttachments[0].texture = target;
    rp.colorAttachments[0].loadAction = MTLLoadActionClear; rp.colorAttachments[0].storeAction = MTLStoreActionStore;
    id<MTLCommandQueue> q = [g_dev newCommandQueue];
    id<MTLCommandBuffer> cb = [q commandBuffer];
    id<MTLRenderCommandEncoder> en = [cb renderCommandEncoderWithDescriptor:rp];
    [en setRenderPipelineState:ps]; [en setVertexBuffer:vb offset:0 atIndex:VB_SLOT(0)];
    [en drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [en endEncoding]; [cb commit]; [cb waitUntilCompleted];
    uint32_t got[4] = {0};
    [target getBytes:got bytesPerRow:16 fromRegion:MTLRegionMake2D(0, 0, 1, 1) mipmapLevel:0];
    int bad = cb.status == MTLCommandBufferStatusError || memcmp(got, want, 16);
    printf("format %#x: %08x %08x %08x %08x %s\n", fmt, got[0], got[1], got[2], got[3], bad ? "FAIL" : "PASS");
    return bad;
}
int main(int argc, char **argv) { @autoreleasepool {
    if (argc != 3) return 2;
    g_dev = MTLCreateSystemDefaultDevice();
    if (!g_dev) return 2;
    NSError *e = nil;
    NSString *source = [NSString stringWithContentsOfFile:@(argv[1]) encoding:NSUTF8StringEncoding error:&e];
    id<MTLLibrary> lib = [g_dev newLibraryWithSource:source options:nil error:&e];
    if (!lib) { fprintf(stderr, "%s\n", e.localizedDescription.UTF8String); return 1; }
    NvShader *vs = [NvShader new], *fs = [NvShader new];
    vs->vlib = lib; vs->fn = [lib newFunctionWithName:@"main0"];
    vs->rf.nv = 1; vs->rf.v[0].loc = vs->rf.v[0].nvn = 4;
    vs->rf.v[0].ct = !strcmp(argv[2], "uint4") ? NVN_CT_UINT : !strcmp(argv[2], "int4") ? NVN_CT_INT : NVN_CT_FLOAT;
    fs->fn = [lib newFunctionWithName:@"pixel"];
    int16_t uv[] = {-1024, 2048};
    uint32_t signed_want[] = {0xfffffc00u, 2048, 0, 1};
    uint8_t normalized[] = {0, 255, 0, 255};
    uint32_t normalized_want[] = {0, 0x3f800000, 0, 0x3f800000};
    uint8_t unsigned_values[] = {0, 128, 254, 255};
    uint32_t unsigned_want[] = {0, 128, 254, 255};
    float floats[] = {-1.0f, 2.0f, 0.5f, 1.0f};
    uint32_t float_want[4]; memcpy(float_want, floats, 16);
    int bad = check(vs, fs, NVN_FORMAT_RG16I, uv, sizeof uv, signed_want);
    bad |= check(vs, fs, NVN_FORMAT_RGBA8, normalized, sizeof normalized, normalized_want);
    bad |= check(vs, fs, NVN_FORMAT_RGBA8UI, unsigned_values, sizeof unsigned_values, unsigned_want);
    bad |= check(vs, fs, NVN_FORMAT_RGBA32F, floats, sizeof floats, float_want);
    // Switch back to the original layout to exercise the specialized-function cache.
    bad |= check(vs, fs, NVN_FORMAT_RG16I, uv, sizeof uv, signed_want);
    return bad;
} }
