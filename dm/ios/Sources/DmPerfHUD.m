#import "DmPerfHUD.h"
#import <QuartzCore/QuartzCore.h>
#import <Metal/Metal.h>
#include <mach/mach.h>
#include "../../gfx/nvn/nvn_perf.h"

@implementation DmPerfHUD {
    UILabel *_headline, *_details;
    NSTimer *_timer;
    id<MTLDevice> _device;
    BOOL _collapsed;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
        self.backgroundColor = [UIColor.secondarySystemBackgroundColor colorWithAlphaComponent:0.85];
        self.layer.cornerRadius = 10;
        _device = MTLCreateSystemDefaultDevice();
        _collapsed = [NSUserDefaults.standardUserDefaults boolForKey:@"DmPerfHUDCollapsed"];
        _headline = [UILabel new]; _details = [UILabel new];
        _headline.font = [UIFontMetrics.defaultMetrics scaledFontForFont:[UIFont monospacedDigitSystemFontOfSize:15 weight:UIFontWeightSemibold] maximumPointSize:20];
        _details.font = [UIFontMetrics.defaultMetrics scaledFontForFont:[UIFont monospacedDigitSystemFontOfSize:11 weight:UIFontWeightRegular] maximumPointSize:15];
        _headline.textColor = UIColor.labelColor; _details.textColor = UIColor.secondaryLabelColor;
        _headline.adjustsFontForContentSizeCategory = _details.adjustsFontForContentSizeCategory = YES;
        _details.numberOfLines = 0;
        _details.hidden = _collapsed;
        UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[_headline, _details]];
        stack.axis = UILayoutConstraintAxisVertical; stack.spacing = 4; stack.userInteractionEnabled = NO;
        stack.translatesAutoresizingMaskIntoConstraints = NO;
        [self addSubview:stack];
        [NSLayoutConstraint activateConstraints:@[
            [stack.topAnchor constraintEqualToAnchor:self.topAnchor constant:12],
            [stack.bottomAnchor constraintEqualToAnchor:self.bottomAnchor constant:-12],
            [stack.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:12],
            [stack.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-12],
            [self.heightAnchor constraintGreaterThanOrEqualToConstant:44]
        ]];
        [self addTarget:self action:@selector(toggleDetails) forControlEvents:UIControlEventTouchUpInside];
        self.isAccessibilityElement = YES;
        self.accessibilityTraits = UIAccessibilityTraitButton;
        self.accessibilityLabel = @"Performance";
        NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
        [nc addObserver:self selector:@selector(startUpdates) name:UIApplicationDidBecomeActiveNotification object:nil];
        [nc addObserver:self selector:@selector(stopUpdates) name:UIApplicationWillResignActiveNotification object:nil];
        [self refresh];
    }
    return self;
}

- (void)toggleDetails {
    _collapsed = !_collapsed; _details.hidden = _collapsed;
    [NSUserDefaults.standardUserDefaults setBool:_collapsed forKey:@"DmPerfHUDCollapsed"];
    [self refresh];
}

- (void)refresh {
    nvn_perf_snapshot s; nvn_perf_read((uint64_t)(CACurrentMediaTime() * 1e9), &s);
    NSString *fps = s.presented_frames ? [NSString stringWithFormat:@"%.1f FPS", s.display_fps] : @"-- FPS";
    NSString *frame = s.frame_ms >= 0 ? [NSString stringWithFormat:@"%.1f ms", s.frame_ms] : @"-- ms";
    _headline.text = [NSString stringWithFormat:@"%@   %@", fps, frame];
    self.accessibilityHint = _collapsed ? @"Show performance details" : @"Hide performance details";
    if (_collapsed) { self.accessibilityValue = _headline.text; return; }
    NSString *gpu = s.gpu_ms >= 0 ? [NSString stringWithFormat:@"%.1f ms", s.gpu_ms] : @"-- ms";
    task_vm_info_data_t vi; mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    NSString *ram = task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&vi, &count) == KERN_SUCCESS
        ? [NSString stringWithFormat:@"%llu", (unsigned long long)(vi.phys_footprint >> 20)] : @"--";
    NSString *thermal;
    switch (NSProcessInfo.processInfo.thermalState) {
        case NSProcessInfoThermalStateNominal: thermal = @"Nominal"; break;
        case NSProcessInfoThermalStateFair: thermal = @"Fair"; break;
        case NSProcessInfoThermalStateSerious: thermal = @"Serious"; break;
        default: thermal = @"Critical"; break;
    }
    _details.text = [NSString stringWithFormat:@"Game %.1f FPS   GPU %@\nRAM %@   Metal %llu MiB\n%ux%u   Thermal %@",
        s.game_fps, gpu, ram, (unsigned long long)(_device.currentAllocatedSize >> 20), s.width, s.height, thermal];
    self.accessibilityValue = [NSString stringWithFormat:@"%@. %@", _headline.text, _details.text];
}

- (void)startUpdates {
    if (_timer || !self.window || UIApplication.sharedApplication.applicationState != UIApplicationStateActive) return;
    [self refresh];
    __weak DmPerfHUD *weakSelf = self;
    _timer = [NSTimer timerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *t) { [weakSelf refresh]; }];
    _timer.tolerance = 0.1;
    [NSRunLoop.mainRunLoop addTimer:_timer forMode:NSRunLoopCommonModes];
}
- (void)stopUpdates { [_timer invalidate]; _timer = nil; }
- (void)didMoveToWindow { [super didMoveToWindow]; if (self.window) [self startUpdates]; else [self stopUpdates]; }
- (void)dealloc { [_timer invalidate]; [NSNotificationCenter.defaultCenter removeObserver:self]; }
@end
