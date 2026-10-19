// Simulator-only implementation of the replay layer's Metal 4 command subset.
#pragma once
#import <Metal/Metal.h>
#include <TargetConditionals.h>

static inline NSUInteger dm_mtl_sample_count(id<MTLDevice> device, NSUInteger requested) {
    NSUInteger samples = requested ? requested : 1;
#if TARGET_OS_SIMULATOR
    // Simulator may expose only 4x MSAA. Keep multisample textures and pipelines consistent.
    if (samples == 2 && ![device supportsTextureSampleCount:2] &&
        [device supportsTextureSampleCount:4]) return 4;
#else
    (void)device;
#endif
    return samples;
}

#if TARGET_OS_SIMULATOR
@protocol DMSimArgumentTable;
@interface DMSimArgumentTableDescriptor : NSObject
@property NSUInteger maxBufferBindCount, maxTextureBindCount, maxSamplerStateBindCount;
@end
@protocol DMSimArgumentTable <NSObject>
- (void)setAddress:(MTLGPUAddress)address atIndex:(NSUInteger)index;
- (void)setTexture:(MTLResourceID)texture atIndex:(NSUInteger)index;
- (void)setSamplerState:(MTLResourceID)sampler atIndex:(NSUInteger)index;
@end
@interface DMSimAllocatorDescriptor : NSObject
@property(copy) NSString *label;
@end
@protocol DMSimAllocator <NSObject>
@property(readonly) uint64_t allocatedSize;
- (void)reset;
@end
@protocol DMSimCommandEncoder <NSObject>
- (void)endEncoding;
- (void)barrierAfterStages:(MTLStages)after beforeQueueStages:(MTLStages)before visibilityOptions:(NSUInteger)options;
- (void)barrierAfterQueueStages:(MTLStages)after beforeStages:(MTLStages)before visibilityOptions:(NSUInteger)options;
- (void)barrierAfterEncoderStages:(MTLStages)after beforeEncoderStages:(MTLStages)before visibilityOptions:(NSUInteger)options;
@end
@protocol DMSimRenderEncoder <MTLRenderCommandEncoder, DMSimCommandEncoder>
- (void)setArgumentTable:(id<DMSimArgumentTable>)table atStages:(MTLRenderStages)stages;
- (void)drawIndexedPrimitives:(MTLPrimitiveType)type indexCount:(NSUInteger)count indexType:(MTLIndexType)indexType
    indexBuffer:(MTLGPUAddress)address indexBufferLength:(NSUInteger)length instanceCount:(NSUInteger)instances
    baseVertex:(NSInteger)vertex baseInstance:(NSUInteger)instance;
@end
@protocol DMSimComputeEncoder <MTLComputeCommandEncoder, MTLBlitCommandEncoder, DMSimCommandEncoder>
- (void)setArgumentTable:(id<DMSimArgumentTable>)table;
@end
@protocol DMSimCommandBuffer <NSObject>
- (void)beginCommandBufferWithAllocator:(id<DMSimAllocator>)allocator;
- (void)endCommandBuffer;
- (id<DMSimRenderEncoder>)renderCommandEncoderWithDescriptor:(MTLRenderPassDescriptor *)descriptor;
- (id<DMSimComputeEncoder>)computeCommandEncoder;
@end
@protocol DMSimFeedback <NSObject>
@property(readonly) NSError *error;
@property(readonly) CFTimeInterval GPUStartTime, GPUEndTime;
@end
@interface DMSimCommitOptions : NSObject
- (void)addFeedbackHandler:(void (^)(id<DMSimFeedback>))handler;
@end
@interface DMSimQueueDescriptor : NSObject
@property(strong) dispatch_queue_t feedbackQueue;
@end
@protocol DMSimQueue <NSObject>
- (void)addResidencySet:(id<MTLResidencySet>)set;
- (void)commit:(id<DMSimCommandBuffer> const *)buffers count:(NSUInteger)count options:(DMSimCommitOptions *)options;
- (void)signalEvent:(id<MTLSharedEvent>)event value:(uint64_t)value;
@end

#define MTL4ArgumentTable DMSimArgumentTable
#define MTL4ArgumentTableDescriptor DMSimArgumentTableDescriptor
#define MTL4CommandAllocator DMSimAllocator
#define MTL4CommandAllocatorDescriptor DMSimAllocatorDescriptor
#define MTL4CommandEncoder DMSimCommandEncoder
#define MTL4RenderCommandEncoder DMSimRenderEncoder
#define MTL4ComputeCommandEncoder DMSimComputeEncoder
#define MTL4CommandBuffer DMSimCommandBuffer
#define MTL4CommitFeedback DMSimFeedback
#define MTL4CommitOptions DMSimCommitOptions
#define MTL4CommandQueueDescriptor DMSimQueueDescriptor
#define MTL4CommandQueue DMSimQueue
#define MTL4RenderPassDescriptor MTLRenderPassDescriptor
#define MTL4VisibilityOptionDevice 0

id<MTL4CommandQueue> dm_m4_queue(id<MTLDevice> device, MTL4CommandQueueDescriptor *descriptor, NSError **error);
id<MTL4CommandAllocator> dm_m4_allocator(id<MTLDevice> device, MTL4CommandAllocatorDescriptor *descriptor, NSError **error);
id<MTL4ArgumentTable> dm_m4_arguments(id<MTLDevice> device, MTL4ArgumentTableDescriptor *descriptor, NSError **error);
id<MTL4CommandBuffer> dm_m4_buffer(id<MTLDevice> device);
void dm_sim_track_resource(id<MTLResource> resource);
void dm_sim_untrack_resource(id<MTLResource> resource);
MTLResourceID dm_m4_resource_id(id resource);
void dm_sim_present(id<MTL4CommandBuffer> buffer, id<MTLDrawable> drawable);
#else
static inline id<MTL4CommandQueue> dm_m4_queue(id<MTLDevice> device, MTL4CommandQueueDescriptor *descriptor, NSError **error) {
    return [device newMTL4CommandQueueWithDescriptor:descriptor error:error];
}
static inline id<MTL4CommandAllocator> dm_m4_allocator(id<MTLDevice> device, MTL4CommandAllocatorDescriptor *descriptor, NSError **error) {
    return [device newCommandAllocatorWithDescriptor:descriptor error:error];
}
static inline id<MTL4ArgumentTable> dm_m4_arguments(id<MTLDevice> device, MTL4ArgumentTableDescriptor *descriptor, NSError **error) {
    return [device newArgumentTableWithDescriptor:descriptor error:error];
}
static inline id<MTL4CommandBuffer> dm_m4_buffer(id<MTLDevice> device) {
    return [device newCommandBuffer];
}
static inline MTLResourceID dm_m4_resource_id(id resource) { return [resource gpuResourceID]; }
#endif
