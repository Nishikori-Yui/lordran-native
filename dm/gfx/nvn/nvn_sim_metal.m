#import "nvn_sim_metal.h"
#if TARGET_OS_SIMULATOR
#include <os/lock.h>
#include <objc/runtime.h>

static os_unfair_lock registry_lock = OS_UNFAIR_LOCK_INIT;
static NSHashTable *resources;
static NSMapTable<NSNumber *, id> *buffers, *textures, *samplers;
static NSArray<NSNumber *> *buffer_addresses;
static uint64_t resource_generation;

static void registry_init(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        resources = [NSHashTable weakObjectsHashTable];
        buffers = [NSMapTable strongToWeakObjectsMapTable];
        textures = [NSMapTable strongToWeakObjectsMapTable];
        samplers = [NSMapTable strongToWeakObjectsMapTable];
    });
}
void dm_sim_track_resource(id<MTLResource> resource) {
    if (!resource) return;
    registry_init(); os_unfair_lock_lock(&registry_lock);
    if (![resources containsObject:resource]) {
        [resources addObject:resource]; resource_generation++;
        if ([resource conformsToProtocol:@protocol(MTLBuffer)]) {
            [buffers setObject:resource forKey:@([(id<MTLBuffer>)resource gpuAddress])];
            buffer_addresses = nil;
        }
    }
    os_unfair_lock_unlock(&registry_lock);
}
void dm_sim_untrack_resource(id<MTLResource> resource) {
    registry_init(); os_unfair_lock_lock(&registry_lock);
    [resources removeObject:resource]; resource_generation++;
    if ([resource conformsToProtocol:@protocol(MTLBuffer)]) {
        NSNumber *key = @([(id<MTLBuffer>)resource gpuAddress]);
        if ([buffers objectForKey:key] == resource) [buffers removeObjectForKey:key];
        buffer_addresses = nil;
    }
    os_unfair_lock_unlock(&registry_lock);
}
MTLResourceID dm_m4_resource_id(id resource) {
    MTLResourceID key = [resource gpuResourceID];
    registry_init(); os_unfair_lock_lock(&registry_lock);
    NSMapTable *table = [resource conformsToProtocol:@protocol(MTLSamplerState)] ? samplers : textures;
    [table setObject:resource forKey:@(key._impl)];
    os_unfair_lock_unlock(&registry_lock);
    if ([resource conformsToProtocol:@protocol(MTLResource)]) dm_sim_track_resource(resource);
    return key;
}
static id<MTLBuffer> resolve_address(MTLGPUAddress address, NSUInteger *offset) {
    registry_init(); os_unfair_lock_lock(&registry_lock);
    if (!buffer_addresses) buffer_addresses = [[buffers keyEnumerator].allObjects sortedArrayUsingSelector:@selector(compare:)];
    NSUInteger lo = 0, hi = buffer_addresses.count;
    while (lo < hi) {
        NSUInteger mid = lo + (hi - lo) / 2;
        if (buffer_addresses[mid].unsignedLongLongValue <= address) lo = mid + 1; else hi = mid;
    }
    id<MTLBuffer> buffer = lo ? [buffers objectForKey:buffer_addresses[lo - 1]] : nil;
    uint64_t delta = buffer ? address - buffer.gpuAddress : 0;
    if (!buffer || delta >= buffer.length) buffer = nil;
    else *offset = (NSUInteger)delta;
    os_unfair_lock_unlock(&registry_lock);
    if (address && !buffer) [NSException raise:NSInvalidArgumentException format:@"Unregistered Simulator GPU address: %#llx", address];
    return buffer;
}
static void declare_resources(id encoder, uint64_t *generation, MTLRenderStages stages) {
    registry_init(); os_unfair_lock_lock(&registry_lock);
    if (*generation == resource_generation + 1) { os_unfair_lock_unlock(&registry_lock); return; }
    NSArray *snapshot = resources.allObjects;
    *generation = resource_generation + 1;
    os_unfair_lock_unlock(&registry_lock);
    for (id<MTLResource> resource in snapshot) {
        if (stages) [(id<MTLRenderCommandEncoder>)encoder useResource:resource usage:MTLResourceUsageRead | MTLResourceUsageWrite stages:stages];
        else [(id<MTLComputeCommandEncoder>)encoder useResource:resource usage:MTLResourceUsageRead | MTLResourceUsageWrite];
    }
}

@implementation DMSimArgumentTableDescriptor @end
@implementation DMSimAllocatorDescriptor @end
@implementation DMSimQueueDescriptor @end
@interface DMSimAllocatorObject : NSObject<DMSimAllocator> @end
@implementation DMSimAllocatorObject
- (uint64_t)allocatedSize { return 0; }
- (void)reset {}
@end
@interface DMSimArguments : NSObject<DMSimArgumentTable> {
@public MTLGPUAddress addresses[31]; MTLResourceID texture_ids[128], sampler_ids[128];
    NSUInteger buffer_count, texture_count, sampler_count;
}
@end
@implementation DMSimArguments
- (void)setAddress:(MTLGPUAddress)address atIndex:(NSUInteger)index { NSParameterAssert(index < buffer_count); addresses[index] = address; }
- (void)setTexture:(MTLResourceID)texture atIndex:(NSUInteger)index { NSParameterAssert(index < texture_count); texture_ids[index] = texture; }
- (void)setSamplerState:(MTLResourceID)sampler atIndex:(NSUInteger)index { NSParameterAssert(index < sampler_count); sampler_ids[index] = sampler; }
@end
static void apply_arguments(DMSimArguments *table, id encoder, MTLRenderStages stage) {
    if (!table) return;
    for (NSUInteger i = 0; i < table->buffer_count; i++) {
        NSUInteger offset = 0; id<MTLBuffer> buffer = resolve_address(table->addresses[i], &offset);
        if (stage == MTLRenderStageVertex) [encoder setVertexBuffer:buffer offset:offset atIndex:i];
        else if (stage == MTLRenderStageFragment) [encoder setFragmentBuffer:buffer offset:offset atIndex:i];
        else [encoder setBuffer:buffer offset:offset atIndex:i];
    }
    for (NSUInteger i = 0; i < table->texture_count; i++) {
        os_unfair_lock_lock(&registry_lock); id texture = [textures objectForKey:@(table->texture_ids[i]._impl)]; os_unfair_lock_unlock(&registry_lock);
        if (stage == MTLRenderStageVertex) [encoder setVertexTexture:texture atIndex:i];
        else if (stage == MTLRenderStageFragment) [encoder setFragmentTexture:texture atIndex:i];
        else [(id<MTLComputeCommandEncoder>)encoder setTexture:texture atIndex:i];
    }
    for (NSUInteger i = 0; i < table->sampler_count; i++) {
        os_unfair_lock_lock(&registry_lock); id sampler = [samplers objectForKey:@(table->sampler_ids[i]._impl)]; os_unfair_lock_unlock(&registry_lock);
        if (stage == MTLRenderStageVertex) [encoder setVertexSamplerState:sampler atIndex:i];
        else if (stage == MTLRenderStageFragment) [encoder setFragmentSamplerState:sampler atIndex:i];
        else [(id<MTLComputeCommandEncoder>)encoder setSamplerState:sampler atIndex:i];
    }
}

@interface DMSimEncoder : NSProxy<DMSimCommandEncoder>
@property(strong) id target;
@end
@implementation DMSimEncoder
- (NSMethodSignature *)methodSignatureForSelector:(SEL)selector { return [self.target methodSignatureForSelector:selector]; }
- (void)forwardInvocation:(NSInvocation *)invocation { [invocation invokeWithTarget:self.target]; }
- (void)endEncoding { [self.target endEncoding]; }
// Metal 3 tracks hazards between encoders. Copies below use a separate blit encoder.
- (void)barrierAfterStages:(MTLStages)a beforeQueueStages:(MTLStages)b visibilityOptions:(NSUInteger)o { (void)a; (void)b; (void)o; }
- (void)barrierAfterQueueStages:(MTLStages)a beforeStages:(MTLStages)b visibilityOptions:(NSUInteger)o { (void)a; (void)b; (void)o; }
- (void)barrierAfterEncoderStages:(MTLStages)a beforeEncoderStages:(MTLStages)b visibilityOptions:(NSUInteger)o { (void)a; (void)b; (void)o; }
@end
@interface DMSimRender : DMSimEncoder<DMSimRenderEncoder>
@property(strong) DMSimArguments *vertexTable, *fragmentTable;
@property uint64_t generation;
@end
@implementation DMSimRender
- (void)setArgumentTable:(id<DMSimArgumentTable>)table atStages:(MTLRenderStages)stages {
    if (stages & MTLRenderStageVertex) self.vertexTable = (DMSimArguments *)table;
    if (stages & MTLRenderStageFragment) self.fragmentTable = (DMSimArguments *)table;
}
- (void)prepareDraw {
    apply_arguments(self.vertexTable, self.target, MTLRenderStageVertex);
    apply_arguments(self.fragmentTable, self.target, MTLRenderStageFragment);
    uint64_t generation = self.generation;
    declare_resources(self.target, &generation, MTLRenderStageVertex | MTLRenderStageFragment); self.generation = generation;
}
- (void)drawPrimitives:(MTLPrimitiveType)type vertexStart:(NSUInteger)start vertexCount:(NSUInteger)count {
    [self prepareDraw]; [self.target drawPrimitives:type vertexStart:start vertexCount:count];
}
- (void)drawPrimitives:(MTLPrimitiveType)type vertexStart:(NSUInteger)start vertexCount:(NSUInteger)count instanceCount:(NSUInteger)instances baseInstance:(NSUInteger)base {
    [self prepareDraw]; [self.target drawPrimitives:type vertexStart:start vertexCount:count instanceCount:instances baseInstance:base];
}
- (void)drawIndexedPrimitives:(MTLPrimitiveType)type indexCount:(NSUInteger)count indexType:(MTLIndexType)indexType indexBuffer:(MTLGPUAddress)address indexBufferLength:(NSUInteger)length instanceCount:(NSUInteger)instances baseVertex:(NSInteger)vertex baseInstance:(NSUInteger)instance {
    NSUInteger offset = 0; id<MTLBuffer> buffer = resolve_address(address, &offset);
    NSParameterAssert(buffer && length <= buffer.length - offset);
    [self prepareDraw]; [self.target drawIndexedPrimitives:type indexCount:count indexType:indexType indexBuffer:buffer indexBufferOffset:offset instanceCount:instances baseVertex:vertex baseInstance:instance];
}
@end
@interface DMSimCompute : DMSimEncoder<DMSimComputeEncoder>
@property(strong) id<MTLCommandBuffer> buffer;
@property(strong) DMSimArguments *table;
@property(strong) id<MTLComputePipelineState> pipeline;
@property BOOL blit;
@property uint64_t generation;
@end
@implementation DMSimCompute
- (void)selectBlit:(BOOL)blit {
    if (self.target && self.blit == blit) return;
    [self.target endEncoding]; self.target = nil; self.blit = blit; self.generation = 0;
    self.target = blit ? (id)[self.buffer blitCommandEncoder] : (id)[self.buffer computeCommandEncoder];
}
- (NSMethodSignature *)methodSignatureForSelector:(SEL)selector {
    NSString *name = NSStringFromSelector(selector);
    [self selectBlit:[name hasPrefix:@"copyFrom"] || [name hasPrefix:@"fillBuffer:"]];
    return [self.target methodSignatureForSelector:selector];
}
- (void)setArgumentTable:(id<DMSimArgumentTable>)table { self.table = (DMSimArguments *)table; }
- (void)setComputePipelineState:(id<MTLComputePipelineState>)pipeline { self.pipeline = pipeline; }
- (void)dispatchThreadgroups:(MTLSize)groups threadsPerThreadgroup:(MTLSize)threads {
    [self selectBlit:NO]; [self.target setComputePipelineState:self.pipeline];
    apply_arguments(self.table, self.target, 0);
    uint64_t generation = self.generation; declare_resources(self.target, &generation, 0); self.generation = generation;
    [self.target dispatchThreadgroups:groups threadsPerThreadgroup:threads];
}
- (void)endEncoding { [self.target endEncoding]; self.target = nil; }
- (void)barrierAfterEncoderStages:(MTLStages)a beforeEncoderStages:(MTLStages)b visibilityOptions:(NSUInteger)o {
    (void)a; (void)b; (void)o; [self endEncoding]; self.generation = 0;
}
@end

@interface DMSimBuffer : NSObject<DMSimCommandBuffer>
@property(strong) id<MTLCommandQueue> queue;
@property(strong) id<MTLCommandBuffer> native;
@end
@implementation DMSimBuffer
- (void)beginCommandBufferWithAllocator:(id<DMSimAllocator>)allocator { (void)allocator; self.native = [self.queue commandBuffer]; }
- (void)endCommandBuffer {}
- (id<DMSimRenderEncoder>)renderCommandEncoderWithDescriptor:(MTLRenderPassDescriptor *)descriptor {
    DMSimRender *encoder = [DMSimRender alloc]; encoder.target = [self.native renderCommandEncoderWithDescriptor:descriptor]; return encoder;
}
- (id<DMSimComputeEncoder>)computeCommandEncoder {
    DMSimCompute *encoder = [DMSimCompute alloc]; encoder.buffer = self.native; return encoder;
}
@end
void dm_sim_present(id<MTL4CommandBuffer> buffer, id<MTLDrawable> drawable) {
    [((DMSimBuffer *)buffer).native presentDrawable:drawable];
}
@interface DMSimFeedbackObject : NSObject<DMSimFeedback>
@property(strong) NSError *error;
@property CFTimeInterval GPUStartTime, GPUEndTime;
@end
@implementation DMSimFeedbackObject @end
@interface DMSimCommitOptions ()
@property(strong) NSMutableArray *handlers;
@end
@implementation DMSimCommitOptions
- (void)addFeedbackHandler:(void (^)(id<DMSimFeedback>))handler {
    if (!self.handlers) self.handlers = [NSMutableArray array];
    [self.handlers addObject:[handler copy]];
}
@end
@interface DMSimQueueObject : NSObject<DMSimQueue>
@property(strong) id<MTLCommandQueue> native;
@property(strong) dispatch_queue_t feedbackQueue;
@end
@implementation DMSimQueueObject
- (void)addResidencySet:(id<MTLResidencySet>)set { (void)set; }
- (void)commit:(id<DMSimCommandBuffer> const *)buffers count:(NSUInteger)count options:(DMSimCommitOptions *)options {
    for (NSUInteger i = 0; i < count; i++) {
        id<MTLCommandBuffer> native = ((DMSimBuffer *)buffers[i]).native;
        if (i == count - 1 && options.handlers.count) {
            NSArray *handlers = [options.handlers copy]; dispatch_queue_t queue = self.feedbackQueue;
            [native addCompletedHandler:^(id<MTLCommandBuffer> completed) {
                DMSimFeedbackObject *feedback = [DMSimFeedbackObject new];
                feedback.error = completed.error; feedback.GPUStartTime = completed.GPUStartTime; feedback.GPUEndTime = completed.GPUEndTime;
                dispatch_async(queue, ^{ for (void (^handler)(id<DMSimFeedback>) in handlers) handler(feedback); });
            }];
        }
        [native commit];
    }
}
- (void)signalEvent:(id<MTLSharedEvent>)event value:(uint64_t)value {
    id<MTLCommandBuffer> buffer = [self.native commandBuffer]; [buffer encodeSignalEvent:event value:value]; [buffer commit];
}
@end
static DMSimQueueObject *replay_queue;
id<MTL4CommandQueue> dm_m4_queue(id<MTLDevice> device, MTL4CommandQueueDescriptor *descriptor, NSError **error) {
    (void)error;
    replay_queue = [DMSimQueueObject new]; replay_queue.native = [device newCommandQueue];
    replay_queue.feedbackQueue = descriptor.feedbackQueue ?: dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0);
    return replay_queue;
}
id<MTL4CommandAllocator> dm_m4_allocator(id<MTLDevice> device, MTL4CommandAllocatorDescriptor *descriptor, NSError **error) {
    (void)device; (void)descriptor; (void)error; return [DMSimAllocatorObject new];
}
id<MTL4ArgumentTable> dm_m4_arguments(id<MTLDevice> device, MTL4ArgumentTableDescriptor *descriptor, NSError **error) {
    (void)device; (void)error;
    NSCParameterAssert(descriptor.maxBufferBindCount <= 31 && descriptor.maxTextureBindCount <= 128 && descriptor.maxSamplerStateBindCount <= 128);
    DMSimArguments *table = [DMSimArguments new];
    table->buffer_count = descriptor.maxBufferBindCount; table->texture_count = descriptor.maxTextureBindCount; table->sampler_count = descriptor.maxSamplerStateBindCount;
    return table;
}
id<MTL4CommandBuffer> dm_m4_buffer(id<MTLDevice> device) {
    (void)device; DMSimBuffer *buffer = [DMSimBuffer new]; buffer.queue = replay_queue.native; return buffer;
}
#endif
