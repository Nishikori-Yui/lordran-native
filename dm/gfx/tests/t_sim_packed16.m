#import <Metal/Metal.h>
#include "../nvn/nvn_sim_packed16.h"
#include <math.h>
#include <stdio.h>
#include <stdlib.h>

int main(void) { @autoreleasepool {
    id<MTLDevice> device = MTLCreateSystemDefaultDevice(); if (!device) return 2;
    NSError *error = nil;
    id<MTLLibrary> library = [device newLibraryWithSource:@"#include <metal_stdlib>\nusing namespace metal;\n"
        "kernel void read_colors(texture2d<float, access::read> image [[texture(0)]], device float4 *out [[buffer(0)]], uint2 p [[thread_position_in_grid]]) { out[p.y*256+p.x] = image.read(p); }"
        options:nil error:&error];
    id<MTLComputePipelineState> pipeline = [device newComputePipelineStateWithFunction:[library newFunctionWithName:@"read_colors"] error:&error];
    if (!pipeline) { fprintf(stderr, "%s\n", error.localizedDescription.UTF8String); return 1; }
    id<MTLCommandQueue> queue = [device newCommandQueue];
    uint16_t *packed = malloc(65536 * sizeof *packed);
    uint8_t *expanded = malloc(65536 * 4);
    for (unsigned i = 0; i < 65536; i++) packed[i] = (uint16_t)i;
    int failures = 0;
    for (uint32_t format = 40; format <= 43; format++) {
        dm_sim_expand_packed16(format, packed, 256 * 2, expanded, 256 * 4, 256, 256);
        MTLTextureDescriptor *descriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:format width:256 height:256 mipmapped:NO];
        descriptor.storageMode = MTLStorageModeShared; descriptor.usage = MTLTextureUsageShaderRead;
        id<MTLTexture> texture = [device newTextureWithDescriptor:descriptor];
        [texture replaceRegion:MTLRegionMake2D(0, 0, 256, 256) mipmapLevel:0 withBytes:packed bytesPerRow:256 * 2];
        id<MTLBuffer> result = [device newBufferWithLength:65536 * 4 * sizeof(float) options:MTLResourceStorageModeShared];
        id<MTLCommandBuffer> buffer = [queue commandBuffer];
        id<MTLComputeCommandEncoder> encoder = [buffer computeCommandEncoder];
        [encoder setComputePipelineState:pipeline]; [encoder setTexture:texture atIndex:0]; [encoder setBuffer:result offset:0 atIndex:0];
        [encoder dispatchThreadgroups:MTLSizeMake(32, 32, 1) threadsPerThreadgroup:MTLSizeMake(8, 8, 1)];
        [encoder endEncoding]; [buffer commit]; [buffer waitUntilCompleted];
        const float *reference = result.contents; double maximum = 0;
        for (unsigned i = 0; i < 65536 * 4; i++) maximum = fmax(maximum, fabs(reference[i] - expanded[i] / 255.0));
        int bad = buffer.status == MTLCommandBufferStatusError || maximum > 0.5 / 255 + 0.00001;
        printf("Packed format %u: pixels=65536 max_error=%.7f %s\n", format, maximum, bad ? "FAIL" : "PASS"); failures += bad;
    }
    free(expanded); free(packed);
    return failures != 0;
} }
