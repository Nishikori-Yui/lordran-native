#import "DmDiagnostics.h"
#import "DmDiagnosticReport.h"
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#include <mach/mach.h>
#include <sys/sysctl.h>
#include "game_profile.h"
#include "dmsh_chain.h"
#include "../../gfx/nvn/nvn_perf.h"

static NSDictionary *diagnosticMetadata(void) {
    char model[128] = {0}; size_t size = sizeof model;
    sysctlbyname("hw.machine", model, &size, NULL, 0);
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    NSBundle *bundle = NSBundle.mainBundle;
    nvn_perf_snapshot perf;
    nvn_perf_read((uint64_t)(CACurrentMediaTime() * 1e9), &perf);
    task_vm_info_data_t vm = {0}; mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&vm, &count);
    return @{
        @"exported_at": [NSISO8601DateFormatter.new stringFromDate:NSDate.date],
        @"game": @DM_GAME_ID,
        @"app_version": [bundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"unknown",
        @"app_build": [bundle objectForInfoDictionaryKey:@"CFBundleVersion"] ?: @"unknown",
        @"bundle_id": bundle.bundleIdentifier ?: @"unknown",
        @"device_model": @(model), @"os": NSProcessInfo.processInfo.operatingSystemVersionString,
        @"shader_chain": @DMSH_CHAIN,
        @"gpu": device.name ?: @"unavailable",
        @"metal4": @([device supportsFamily:MTLGPUFamilyMetal4]),
        @"argument_buffer_tier": @(device.argumentBuffersSupport),
        @"physical_memory_bytes": @(NSProcessInfo.processInfo.physicalMemory),
        @"app_memory_bytes": @(vm.phys_footprint),
        @"metal_memory_bytes": @(device.currentAllocatedSize),
        @"thermal_state": @(NSProcessInfo.processInfo.thermalState),
        @"performance": @{@"display_fps": @(perf.display_fps), @"game_fps": @(perf.game_fps),
            @"frame_ms": @(perf.frame_ms), @"gpu_ms": @(perf.gpu_ms),
            @"presented_frames": @(perf.presented_frames), @"width": @(perf.width), @"height": @(perf.height)},
        @"notes": @"Each log is limited to its last 8 MiB. This report contains app logs, not system crash reports."
    };
}

void DmDiagnosticsShare(UIViewController *presenter, UIButton *button) {
    if (!button.enabled || presenter.presentedViewController) return;
    button.enabled = NO;
    NSDictionary *metadata = diagnosticMetadata();
    NSURL *documents = [NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject;
    // No runtime dumps or stderr locks: export must still work if a game thread stalls.
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        @autoreleasepool {
            NSError *error = nil;
            NSURL *report = DmDiagnosticReportCreate(documents, metadata, &error);
            dispatch_async(dispatch_get_main_queue(), ^{
                button.enabled = YES;
                if (!presenter.view.window || presenter.presentedViewController) return;
                if (!report) {
                    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Export failed / 导出失败"
                        message:error.localizedDescription preferredStyle:UIAlertControllerStyleAlert];
                    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
                    [presenter presentViewController:alert animated:YES completion:nil];
                    return;
                }
                UIActivityViewController *share = [[UIActivityViewController alloc] initWithActivityItems:@[report] applicationActivities:nil];
                share.popoverPresentationController.sourceView = button;
                share.popoverPresentationController.sourceRect = button.bounds;
                [presenter presentViewController:share animated:YES completion:nil];
            });
        }
    });
}
