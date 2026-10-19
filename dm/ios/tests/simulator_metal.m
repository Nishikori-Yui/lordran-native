// Exercise the Simulator command adapter on a real Simulator Metal device.
#import "../../gfx/nvn/nvn_sim_metal.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>

static int failures;
static void check(BOOL value, const char *label) {
    printf("%s: %s\n", value ? "PASS" : "FAIL", label);
    if (!value) failures++;
}
static void submit(id<MTL4CommandQueue> queue, id<MTL4CommandBuffer> buffer) {
    [buffer endCommandBuffer];
    dispatch_semaphore_t finished = dispatch_semaphore_create(0);
    MTL4CommitOptions *options = [MTL4CommitOptions new];
    [options addFeedbackHandler:^(id<MTL4CommitFeedback> feedback) {
        check(feedback.error == nil, "GPU command execution");
        dispatch_semaphore_signal(finished);
    }];
    id<MTL4CommandBuffer> buffers[] = {buffer};
    [queue commit:buffers count:1 options:options];
    check(dispatch_semaphore_wait(finished, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC)) == 0, "completion callback");
}
int main(void) { @autoreleasepool {
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    if (!device) { check(NO, "Metal device"); return 1; }
    void *memory = mmap(NULL, 0x4000, PROT_READ | PROT_WRITE, MAP_ANON | MAP_SHARED, -1, 0);
    check(memory != MAP_FAILED, "shared pool allocation");
    id<MTLBuffer> alias = [device newBufferWithBytesNoCopy:memory length:0x4000 options:MTLResourceStorageModeShared deallocator:nil];
    check(alias && alias.contents == memory, "zero-copy pool aliases caller memory");
    if (!alias || alias.contents != memory) return 1;
    NSError *error = nil;
    MTL4CommandQueueDescriptor *qd = [MTL4CommandQueueDescriptor new];
    qd.feedbackQueue = dispatch_queue_create("simulator-metal-test", DISPATCH_QUEUE_SERIAL);
    id<MTL4CommandQueue> queue = dm_m4_queue(device, qd, &error);
    id<MTL4CommandAllocator> allocator = dm_m4_allocator(device, [MTL4CommandAllocatorDescriptor new], &error);
    NSString *source = @"#include <metal_stdlib>\nusing namespace metal;\n"
        "kernel void compute(device const uint *src [[buffer(0)]], device uint *dst [[buffer(1)]], uint i [[thread_position_in_grid]]) { dst[i] = src[i] * 3 + 7; }\n"
        "struct Args { device const uint *src [[id(0)]]; device uint *dst [[id(1)]]; };\n"
        "kernel void argument_compute(constant Args &a [[buffer(0)]], uint i [[thread_position_in_grid]]) { a.dst[i] = a.src[i] * 3 + 7; }\n"
        "vertex float4 vertex_main(uint i [[vertex_id]]) { float2 p[3] = {float2(-1,-1), float2(3,-1), float2(-1,3)}; return float4(p[i],0,1); }\n"
        "fragment float4 fragment_main(constant float4 &color [[buffer(0)]], texture2d<float> image [[texture(0)]], sampler s [[sampler(0)]]) { return color * image.sample(s,float2(0.5)); }\n"
        "struct Colors { constant float4 *color [[id(0)]]; texture2d<float> image [[id(1)]]; sampler s [[id(2)]]; };\n"
        "fragment float4 argument_fragment(constant Colors &a [[buffer(0)]]) { return *a.color * a.image.sample(a.s,float2(0.5)); }\n";
    id<MTLLibrary> library = [device newLibraryWithSource:source options:nil error:&error];
    check(library != nil, "test shader compilation"); if (!library) return 1;
    id<MTLComputePipelineState> compute = [device newComputePipelineStateWithFunction:[library newFunctionWithName:@"compute"] error:&error];
    uint32_t input[] = {1, 2, 3, 4}, zero[4] = {0}, expected[] = {10, 13, 16, 19};
    id<MTLBuffer> src = [device newBufferWithBytes:input length:sizeof input options:MTLResourceStorageModeShared];
    id<MTLBuffer> dst = [device newBufferWithBytes:zero length:sizeof zero options:MTLResourceStorageModeShared];
    id<MTLBuffer> copy = [device newBufferWithBytes:zero length:sizeof zero options:MTLResourceStorageModeShared];
    dm_sim_track_resource(src); dm_sim_track_resource(dst); dm_sim_track_resource(copy);
    MTL4ArgumentTableDescriptor *ad = [MTL4ArgumentTableDescriptor new]; ad.maxBufferBindCount = 2;
    id<MTL4ArgumentTable> arguments = dm_m4_arguments(device, ad, &error);
    [arguments setAddress:src.gpuAddress atIndex:0]; [arguments setAddress:dst.gpuAddress atIndex:1];
    id<MTL4CommandBuffer> buffer = dm_m4_buffer(device);
    [buffer beginCommandBufferWithAllocator:allocator];
    id<MTL4ComputeCommandEncoder> encoder = [buffer computeCommandEncoder];
    [encoder setArgumentTable:arguments]; [encoder setComputePipelineState:compute];
    [encoder dispatchThreadgroups:MTLSizeMake(1,1,1) threadsPerThreadgroup:MTLSizeMake(4,1,1)];
    [encoder copyFromBuffer:dst sourceOffset:0 toBuffer:copy destinationOffset:0 size:sizeof input];
    [encoder endEncoding]; submit(queue, buffer);
    check(!memcmp(copy.contents, expected, sizeof expected), "compute followed by blit preserves ordering");
    check(!memcmp(dst.contents, expected, sizeof expected), "GPU address argument binding");
    memcpy(memory, input, sizeof input); memset(dst.contents, 0, sizeof zero);
    dm_sim_track_resource(alias);
    uint64_t slots[] = {alias.gpuAddress, dst.gpuAddress};
    id<MTLBuffer> argumentBuffer = [device newBufferWithBytes:slots length:sizeof slots options:MTLResourceStorageModeShared];
    dm_sim_track_resource(argumentBuffer);
    [arguments setAddress:argumentBuffer.gpuAddress atIndex:0]; [arguments setAddress:0 atIndex:1];
    id<MTLFunction> argumentFunction = [library newFunctionWithName:@"argument_compute"];
    id<MTLArgumentEncoder> argumentEncoder = [argumentFunction newArgumentEncoderWithBufferIndex:0];
    check(argumentEncoder.encodedLength == sizeof slots, "raw argument buffer ABI");
    compute = [device newComputePipelineStateWithFunction:argumentFunction error:&error];
    [buffer beginCommandBufferWithAllocator:allocator]; encoder = [buffer computeCommandEncoder];
    [encoder setArgumentTable:arguments]; [encoder setComputePipelineState:compute];
    [encoder dispatchThreadgroups:MTLSizeMake(1,1,1) threadsPerThreadgroup:MTLSizeMake(4,1,1)];
    [encoder endEncoding]; submit(queue, buffer);
    check(!memcmp(dst.contents, expected, sizeof expected), "raw argument pointers access the shared guest pool");

    float color[] = {0, 1, 0, 1}; uint16_t indices[] = {0, 1, 2};
    id<MTLBuffer> uniform = [device newBufferWithBytes:color length:sizeof color options:MTLResourceStorageModeShared];
    id<MTLBuffer> index = [device newBufferWithBytes:indices length:sizeof indices options:MTLResourceStorageModeShared];
    dm_sim_track_resource(uniform); dm_sim_track_resource(index);
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:1 height:1 mipmapped:NO];
    td.storageMode = MTLStorageModeShared; td.usage = MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget;
    id<MTLTexture> image = [device newTextureWithDescriptor:td], target = [device newTextureWithDescriptor:td];
    uint32_t white = 0xffffffff;
    [image replaceRegion:MTLRegionMake2D(0,0,1,1) mipmapLevel:0 withBytes:&white bytesPerRow:4];
    MTLSamplerDescriptor *samplerDescriptor = [MTLSamplerDescriptor new];
    samplerDescriptor.supportArgumentBuffers = YES;
    id<MTLSamplerState> sampler = [device newSamplerStateWithDescriptor:samplerDescriptor];
    MTL4ArgumentTableDescriptor *rd = [MTL4ArgumentTableDescriptor new]; rd.maxBufferBindCount = 1; rd.maxTextureBindCount = 1; rd.maxSamplerStateBindCount = 1;
    id<MTL4ArgumentTable> fragment = dm_m4_arguments(device, rd, &error);
    [fragment setTexture:dm_m4_resource_id(image) atIndex:0]; [fragment setSamplerState:dm_m4_resource_id(sampler) atIndex:0];
    MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
    pd.vertexFunction = [library newFunctionWithName:@"vertex_main"]; pd.fragmentFunction = [library newFunctionWithName:@"fragment_main"];
    pd.colorAttachments[0].pixelFormat = td.pixelFormat;
    id<MTLRenderPipelineState> pipeline = [device newRenderPipelineStateWithDescriptor:pd error:&error];
    check(pipeline != nil, "render pipeline");
    MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture = target; pass.colorAttachments[0].loadAction = MTLLoadActionClear; pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    [buffer beginCommandBufferWithAllocator:allocator];
    id<MTL4RenderCommandEncoder> render = [buffer renderCommandEncoderWithDescriptor:pass];
    [render setRenderPipelineState:pipeline]; [render setArgumentTable:fragment atStages:MTLRenderStageFragment];
    // The replay changes table addresses after attaching the table to an encoder.
    [fragment setAddress:uniform.gpuAddress atIndex:0];
    [render drawIndexedPrimitives:MTLPrimitiveTypeTriangle indexCount:3 indexType:MTLIndexTypeUInt16 indexBuffer:index.gpuAddress indexBufferLength:index.length instanceCount:1 baseVertex:0 baseInstance:0];
    [render endEncoding]; submit(queue, buffer);
    uint8_t pixel[4] = {0};
    [target getBytes:pixel bytesPerRow:4 fromRegion:MTLRegionMake2D(0,0,1,1) mipmapLevel:0];
    check(pixel[0] == 0 && pixel[1] == 255 && pixel[2] == 0 && pixel[3] == 255, "indexed draw, live table, texture and sampler produce a green pixel");
    argumentFunction = [library newFunctionWithName:@"argument_fragment"];
    argumentEncoder = [argumentFunction newArgumentEncoderWithBufferIndex:0];
    argumentBuffer = [device newBufferWithLength:argumentEncoder.encodedLength options:MTLResourceStorageModeShared];
    [argumentEncoder setArgumentBuffer:argumentBuffer offset:0];
    [argumentEncoder setBuffer:uniform offset:0 atIndex:0];
    [argumentEncoder setTexture:image atIndex:1];
    [argumentEncoder setSamplerState:sampler atIndex:2];
    dm_sim_track_resource(argumentBuffer);
    [fragment setAddress:argumentBuffer.gpuAddress atIndex:0];
    pd.fragmentFunction = argumentFunction;
    pipeline = [device newRenderPipelineStateWithDescriptor:pd error:&error];
    [buffer beginCommandBufferWithAllocator:allocator];
    render = [buffer renderCommandEncoderWithDescriptor:pass];
    [render setRenderPipelineState:pipeline]; [render setArgumentTable:fragment atStages:MTLRenderStageFragment];
    [render drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [render endEncoding]; submit(queue, buffer);
    [target getBytes:pixel bytesPerRow:4 fromRegion:MTLRegionMake2D(0,0,1,1) mipmapLevel:0];
    check(pixel[0] == 0 && pixel[1] == 255 && pixel[2] == 0 && pixel[3] == 255, "encoded buffer, texture and sampler arguments produce a green pixel");
    check(dm_mtl_sample_count(device, 0) == 1 && dm_mtl_sample_count(device, 1) == 1,
        "single-sample pipelines retain their sample count");
    for (NSUInteger requested = 2; requested <= 4; requested *= 2) {
        NSUInteger actual = dm_mtl_sample_count(device, requested);
        printf("MSAA requested=%lu actual=%lu\n", (unsigned long)requested, (unsigned long)actual);
        check([device supportsTextureSampleCount:actual], "MSAA mapping selects a supported sample count");
        if ([device supportsTextureSampleCount:requested])
            check(actual == requested, "supported MSAA sample count is preserved");
        MTLTextureDescriptor *ms = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:td.pixelFormat width:1 height:1 mipmapped:NO];
        ms.textureType = MTLTextureType2DMultisample; ms.sampleCount = actual;
        ms.storageMode = MTLStorageModePrivate; ms.usage = MTLTextureUsageRenderTarget;
        id<MTLTexture> msColor = [device newTextureWithDescriptor:ms];
        ms.pixelFormat = MTLPixelFormatDepth32Float;
        id<MTLTexture> msDepth = [device newTextureWithDescriptor:ms];
        check(msColor && msDepth, "MSAA color and depth textures are created");
        pd.fragmentFunction = [library newFunctionWithName:@"fragment_main"];
        pd.rasterSampleCount = dm_mtl_sample_count(device, requested);
        pd.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float;
        pipeline = [device newRenderPipelineStateWithDescriptor:pd error:&error];
        check(pipeline != nil, "MSAA pipeline matches attachment sample counts");
        if (!msColor || !msDepth || !pipeline) continue;
        MTLRenderPassDescriptor *msPass = [MTLRenderPassDescriptor renderPassDescriptor];
        msPass.colorAttachments[0].texture = msColor;
        msPass.colorAttachments[0].resolveTexture = target;
        msPass.colorAttachments[0].loadAction = MTLLoadActionClear;
        msPass.colorAttachments[0].clearColor = MTLClearColorMake(1,0,0,1);
        msPass.colorAttachments[0].storeAction = MTLStoreActionMultisampleResolve;
        msPass.depthAttachment.texture = msDepth;
        msPass.depthAttachment.loadAction = MTLLoadActionClear;
        msPass.depthAttachment.clearDepth = 1;
        msPass.depthAttachment.storeAction = MTLStoreActionDontCare;
        [fragment setAddress:uniform.gpuAddress atIndex:0];
        [buffer beginCommandBufferWithAllocator:allocator];
        render = [buffer renderCommandEncoderWithDescriptor:msPass];
        [render setRenderPipelineState:pipeline];
        [render setArgumentTable:fragment atStages:MTLRenderStageFragment];
        [render drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
        [render endEncoding]; submit(queue, buffer);
        [target getBytes:pixel bytesPerRow:4 fromRegion:MTLRegionMake2D(0,0,1,1) mipmapLevel:0];
        check(pixel[0] == 0 && pixel[1] == 255 && pixel[2] == 0 && pixel[3] == 255,
            "MSAA color and depth draw resolves to a green single-sample pixel");
    }
    id<MTLSharedEvent> event = [device newSharedEvent];
    [queue signalEvent:event value:3];
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:5];
    while (event.signaledValue < 3 && deadline.timeIntervalSinceNow > 0) [NSThread sleepForTimeInterval:0.001];
    check(event.signaledValue >= 3, "queue fence signaling");
    alias = nil; munmap(memory, 0x4000);
    printf("Simulator Metal failures=%d\n", failures);
    return failures != 0;
} }
