// Standalone guest diagnostics. This app contains no game code or resources.
#import <UIKit/UIKit.h>
#import <Metal/Metal.h>

static NSMutableString *g_report;
static void report(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);
static void report(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *line = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    [g_report appendFormat:@"%@\n", line];
    fprintf(stderr, "%s\n", line.UTF8String);
    NSString *doc = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES)[0];
    [g_report writeToFile:[doc stringByAppendingPathComponent:@"metal-probe.txt"]
              atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

static void object_result(NSString *name, id object, NSError *error) {
    report(@"%@: %@ error=%@ code=%ld description=%@", name, object ? @"OK" : @"nil",
           error.domain ?: @"none", (long)error.code, error.localizedDescription ?: @"none");
}

static void probe(void) {
    g_report = [NSMutableString new];
    report(@"OS: %@", NSProcessInfo.processInfo.operatingSystemVersionString);
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    report(@"device: %@ class=%@", device.name, NSStringFromClass([device class]));
    if (!device) return;
    report(@"unified=%d argumentBuffersTier=%lu", device.hasUnifiedMemory,
           (unsigned long)device.argumentBuffersSupport);
    const MTLGPUFamily families[] = {MTLGPUFamilyApple7, MTLGPUFamilyApple8,
        MTLGPUFamilyApple9, MTLGPUFamilyApple10, MTLGPUFamilyMac2,
        MTLGPUFamilyMetal3, MTLGPUFamilyMetal4};
    for (unsigned i = 0; i < sizeof families / sizeof *families; i++)
        report(@"family %ld: %d", (long)families[i], [device supportsFamily:families[i]]);

    @try {
        id<MTLCommandQueue> queue = [device newCommandQueue];
        report(@"legacy queue: %@", queue ? @"OK" : @"nil");
        MTLTextureDescriptor *td = [MTLTextureDescriptor
            texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                         width:4 height:4 mipmapped:NO];
        td.storageMode = MTLStorageModeShared;
        td.usage = MTLTextureUsageRenderTarget;
        id<MTLTexture> texture = [device newTextureWithDescriptor:td];
        id<MTLCommandBuffer> cb = [queue commandBuffer];
        if (queue && texture && cb) {
            MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
            pass.colorAttachments[0].texture = texture;
            pass.colorAttachments[0].loadAction = MTLLoadActionClear;
            pass.colorAttachments[0].storeAction = MTLStoreActionStore;
            pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 1, 0, 1);
            id<MTLRenderCommandEncoder> encoder = [cb renderCommandEncoderWithDescriptor:pass];
            [encoder endEncoding];
            dispatch_semaphore_t done = dispatch_semaphore_create(0);
            [cb addCompletedHandler:^(id<MTLCommandBuffer> finished) {
                dispatch_semaphore_signal(done);
            }];
            [cb commit];
            long wait = dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC));
            uint8_t bytes[4 * 4 * 4] = {0};
            if (cb.status == MTLCommandBufferStatusCompleted)
                [texture getBytes:bytes bytesPerRow:16 fromRegion:MTLRegionMake2D(0, 0, 4, 4) mipmapLevel:0];
            report(@"legacy render: encoder=%d timeout=%ld status=%lu pixel=%u,%u,%u,%u error=%@",
                encoder != nil, wait, (unsigned long)cb.status, bytes[0], bytes[1],
                bytes[2], bytes[3], cb.error ?: @"none");
        }
    } @catch (NSException *e) {
        report(@"legacy exception: %@ %@", e.name, e.reason);
    }

    for (NSNumber *capacity in @[@0, @4096]) {
        @try {
            MTLResidencySetDescriptor *desc = [MTLResidencySetDescriptor new];
            desc.initialCapacity = capacity.unsignedIntegerValue;
            NSError *error = nil;
            id<MTLResidencySet> set = [device newResidencySetWithDescriptor:desc error:&error];
            object_result([NSString stringWithFormat:@"residency capacity=%@", capacity], set, error);
        } @catch (NSException *e) {
            report(@"residency exception: %@ %@", e.name, e.reason);
        }
    }
    @try {
        NSError *error = nil;
        id queue = [device newMTL4CommandQueueWithDescriptor:[MTL4CommandQueueDescriptor new] error:&error];
        object_result(@"Metal4 queue", queue, error);
    } @catch (NSException *e) {
        report(@"Metal4 queue exception: %@ %@", e.name, e.reason);
    }
    @try {
        NSError *error = nil;
        id allocator = [device newCommandAllocatorWithDescriptor:[MTL4CommandAllocatorDescriptor new] error:&error];
        object_result(@"Metal4 allocator", allocator, error);
    } @catch (NSException *e) {
        report(@"Metal4 allocator exception: %@ %@", e.name, e.reason);
    }
    @try {
        NSError *error = nil;
        MTL4ArgumentTableDescriptor *desc = [MTL4ArgumentTableDescriptor new];
        desc.maxBufferBindCount = 1;
        id table = [device newArgumentTableWithDescriptor:desc error:&error];
        object_result(@"Metal4 argument table", table, error);
    } @catch (NSException *e) {
        report(@"Metal4 argument table exception: %@ %@", e.name, e.reason);
    }
    @try {
        report(@"Metal4 command buffer: %@", [device newCommandBuffer] ? @"OK" : @"nil");
    } @catch (NSException *e) {
        report(@"Metal4 command buffer exception: %@ %@", e.name, e.reason);
    }
    report(@"probe complete");
}

@interface MetalProbeScene : UIResponder <UIWindowSceneDelegate>
@property(strong, nonatomic) UIWindow *window;
@end
@implementation MetalProbeScene
- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)options {
    self.window = [[UIWindow alloc] initWithWindowScene:(UIWindowScene *)scene];
    UIViewController *root = [UIViewController new];
    root.view.backgroundColor = UIColor.systemBackgroundColor;
    UITextView *text = [UITextView new];
    text.translatesAutoresizingMaskIntoConstraints = NO;
    text.editable = NO;
    text.font = [UIFont monospacedSystemFontOfSize:13 weight:UIFontWeightRegular];
    text.text = @"Running Metal capability checks...";
    [root.view addSubview:text];
    UILayoutGuide *safe = root.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [text.topAnchor constraintEqualToAnchor:safe.topAnchor],
        [text.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor],
        [text.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor],
        [text.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor],
    ]];
    self.window.rootViewController = root;
    [self.window makeKeyAndVisible];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        @autoreleasepool {
            probe();
            NSString *result = [g_report copy];
            dispatch_async(dispatch_get_main_queue(), ^{
                text.text = result;
                [text scrollRangeToVisible:NSMakeRange(0, 0)];
            });
        }
    });
}
@end

@interface MetalProbeApp : UIResponder <UIApplicationDelegate>
@end
@implementation MetalProbeApp
- (UISceneConfiguration *)application:(UIApplication *)app configurationForConnectingSceneSession:(UISceneSession *)session options:(UISceneConnectionOptions *)options {
    UISceneConfiguration *config = [[UISceneConfiguration alloc] initWithName:@"Probe" sessionRole:session.role];
    config.delegateClass = MetalProbeScene.class;
    return config;
}
@end

int main(int argc, char **argv) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass(MetalProbeApp.class));
    }
}
