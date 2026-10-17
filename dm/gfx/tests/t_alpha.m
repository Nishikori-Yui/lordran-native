#include "../nvn/nvn_mtl.m"
int prog_key(const prog_t *p, unsigned s, uint8_t k[8]) { (void)p; (void)s; memset(k, 0, 8); return 0; }
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t g_mod[MAX_MOD]; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
uint64_t nvn_new_serial(void) { static uint64_t s; return ++s; }

static int run(NvShader *vs, NvShader *fs, unsigned op, float ref, float alpha, int want) {
    state_reset(); S.color.alpha_func = op;
    p_bind_state a = {.kind = 6}; memcpy(a.bytes, &ref, sizeof ref); state_op(OP_BIND_STATE, &a);
    uint32_t formats[8] = {MTLPixelFormatRGBA8Unorm, MTLPixelFormatRGBA8Unorm};
    pso_key k; pso_key_fill(&k, vs, fs, formats, MTLPixelFormatDepth32Float, 0, 1, 0);
    MTLRenderPipelineDescriptor *d = pso_desc(&k, vs, fs, nil, 0);
    NSError *e = nil;
    id<MTLRenderPipelineState> ps = [g_dev newRenderPipelineStateWithDescriptor:d error:&e];
    if (!ps) { fprintf(stderr, "pipeline: %s\n", e.localizedDescription.UTF8String); return 1; }
    id<MTLTexture> targets[3];
    MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
    for (int i = 0; i < 3; i++) {
        MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:i < 2 ? MTLPixelFormatRGBA8Unorm : MTLPixelFormatDepth32Float width:1 height:1 mipmapped:NO];
        td.usage = MTLTextureUsageRenderTarget; td.storageMode = MTLStorageModeShared;
        targets[i] = [g_dev newTextureWithDescriptor:td];
        if (i < 2) {
            rp.colorAttachments[i].texture = targets[i]; rp.colorAttachments[i].loadAction = MTLLoadActionClear;
            rp.colorAttachments[i].storeAction = MTLStoreActionStore; rp.colorAttachments[i].clearColor = MTLClearColorMake(0, 0, 1, 1);
        } else {
            rp.depthAttachment.texture = targets[i]; rp.depthAttachment.loadAction = MTLLoadActionClear;
            rp.depthAttachment.storeAction = MTLStoreActionStore; rp.depthAttachment.clearDepth = 1;
        }
    }
    MTLDepthStencilDescriptor *ds = [MTLDepthStencilDescriptor new];
    ds.depthCompareFunction = MTLCompareFunctionAlways; ds.depthWriteEnabled = YES;
    id<MTLCommandQueue> queue = [g_dev newCommandQueue];
    id<MTLCommandBuffer> cb = [queue commandBuffer];
    id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:rp];
    [enc setRenderPipelineState:ps]; [enc setDepthStencilState:[g_dev newDepthStencilStateWithDescriptor:ds]];
    [enc setFragmentBytes:&alpha length:sizeof alpha atIndex:1];
    [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [enc endEncoding]; [cb commit]; [cb waitUntilCompleted];
    uint8_t px[2][4]; float depth = 0;
    for (int i = 0; i < 2; i++) [targets[i] getBytes:px[i] bytesPerRow:4 fromRegion:MTLRegionMake2D(0, 0, 1, 1) mipmapLevel:0];
    [targets[2] getBytes:&depth bytesPerRow:4 fromRegion:MTLRegionMake2D(0, 0, 1, 1) mipmapLevel:0];
    int actual = px[0][0] == 255 && px[1][1] == 255 && depth == 0.25f;
    int untouched = px[0][2] == 255 && px[1][2] == 255 && depth == 1.0f;
    int bad = cb.status == MTLCommandBufferStatusError || (want ? !actual : !untouched);
    printf("op %u ref %.2f alpha %.2f: color/depth %s\n", op, ref, alpha, bad ? "FAIL" : "PASS");
    return bad;
}
int main(int argc, char **argv) { @autoreleasepool {
    if (argc != 3) return 2;
    g_dev = MTLCreateSystemDefaultDevice(); if (!g_dev) return 2;
    NSError *e = nil;
    NSString *source = [NSString stringWithContentsOfFile:@(argv[1]) encoding:NSUTF8StringEncoding error:&e];
    id<MTLLibrary> lib = [g_dev newLibraryWithSource:source options:nil error:&e];
    if (!lib) { fprintf(stderr, "%s\n", e.localizedDescription.UTF8String); return 1; }
    NvShader *vs = [NvShader new], *fs = [NvShader new];
    vs->fn = [lib newFunctionWithName:@"vertex0"]; fs->fn = [lib newFunctionWithName:@"main0"]; fs->alib = lib;
    // Rows are NVN comparisons NEVER, LESS, EQUAL, LEQUAL, GREATER, NOTEQUAL,
    // GEQUAL, ALWAYS; columns are alpha 0, 0.5 and 1 with reference 0.5.
    const int expected[8][3] = {{0,0,0},{1,0,0},{0,1,0},{1,1,0},{0,0,1},{1,0,1},{0,1,1},{1,1,1}};
    int bad = 0, has_alpha = atoi(argv[2]);
    for (unsigned op = 1; op <= 8; op++) for (int i = 0; i < 3; i++)
        bad |= run(vs, fs, op, 0.5f, i * 0.5f, has_alpha ? expected[op - 1][i] : op != 1);
    bad |= run(vs, fs, NVN_ALPHA_FUNC_GREATER, 0.75f, 0.5f, !has_alpha);
    bad |= run(vs, fs, NVN_ALPHA_FUNC_GREATER, 0.25f, 0.5f, 1);
    bad |= run(vs, fs, NVN_ALPHA_FUNC_GREATER, 0.75f, 0.5f, !has_alpha);
    return bad;
} }
