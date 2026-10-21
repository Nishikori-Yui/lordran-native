#import "DmPerfHUD.h"
#import "DmGamepad.h"
#import <QuartzCore/QuartzCore.h>
#import <Metal/Metal.h>
#include <mach/mach.h>
#include <TargetConditionals.h>
#include "../../gfx/nvn/nvn_perf.h"

@implementation DmPerfHUD {
    UILabel *_headline, *_details;
    UIStackView *_stack;
    NSTimer *_timer;
    id<MTLDevice> _device;
    BOOL _collapsed;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
        self.backgroundColor = UIColor.clearColor;
        _device = MTLCreateSystemDefaultDevice();
        _collapsed = [NSUserDefaults.standardUserDefaults boolForKey:@"DmPerfHUDCollapsed"];
        _headline = [UILabel new]; _details = [UILabel new];
        _headline.textAlignment = _details.textAlignment = NSTextAlignmentRight;
        _headline.numberOfLines = 1;
        _headline.adjustsFontSizeToFitWidth = YES;
        _headline.minimumScaleFactor = 0.75;
        _headline.adjustsFontForContentSizeCategory = _details.adjustsFontForContentSizeCategory = YES;
        _details.numberOfLines = 0;
        _stack = [[UIStackView alloc] initWithArrangedSubviews:@[_headline, _details]];
        _stack.axis = UILayoutConstraintAxisVertical; _stack.spacing = 4; _stack.userInteractionEnabled = NO;
        _stack.translatesAutoresizingMaskIntoConstraints = NO;
        [self addSubview:_stack];
        [NSLayoutConstraint activateConstraints:@[
            [_stack.topAnchor constraintEqualToAnchor:self.topAnchor],
            [_stack.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
            [_stack.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
            [_stack.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
            [self.heightAnchor constraintGreaterThanOrEqualToConstant:44]
        ]];
        _details.hidden = _collapsed;
        [self addTarget:self action:@selector(toggleDetails) forControlEvents:UIControlEventTouchUpInside];
        self.isAccessibilityElement = YES;
        self.accessibilityTraits = UIAccessibilityTraitButton;
        self.accessibilityLabel = @"Performance";
        [self refresh];
        NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
        [nc addObserver:self selector:@selector(startUpdates) name:UIApplicationDidBecomeActiveNotification object:nil];
        [nc addObserver:self selector:@selector(stopUpdates) name:UIApplicationWillResignActiveNotification object:nil];
    }
    return self;
}

- (void)attachToView:(UIView *)view belowSubview:(UIView *)sibling {
    NSParameterAssert(view && sibling.superview == view);
    [self removeFromSuperview];
    self.translatesAutoresizingMaskIntoConstraints = NO;
    [view insertSubview:self belowSubview:sibling];
    UILayoutGuide *safe = view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [self.topAnchor constraintEqualToAnchor:safe.topAnchor constant:14],
        [self.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-14],
        [self.leadingAnchor constraintGreaterThanOrEqualToAnchor:safe.leadingAnchor constant:14],
        [self.widthAnchor constraintLessThanOrEqualToConstant:320],
        [self.widthAnchor constraintLessThanOrEqualToAnchor:safe.widthAnchor constant:-28]
    ]];
}

- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    if (![super pointInside:point withEvent:event]) return NO;
    DmGamepad *gamepad = self.gamepad;
    // Keep the gamepad's transformed buttons and editor handles reachable beneath the HUD.
    return !(gamepad && gamepad.window == self.window &&
        [gamepad hasVisibleControlAtPoint:[self convertPoint:point toView:gamepad]]);
}

- (BOOL)accessibilityActivate {
    [self toggleDetails];
    return YES;
}

- (void)applyText:(NSString *)text toLabel:(UILabel *)label baseSize:(CGFloat)size weight:(UIFontWeight)weight color:(UIColor *)color {
    UIFont *base = [UIFont monospacedDigitSystemFontOfSize:size weight:weight];
    UIFont *font = [UIFontMetrics.defaultMetrics scaledFontForFont:base maximumPointSize:size * 1.5 compatibleWithTraitCollection:self.traitCollection];
    NSShadow *shadow = [NSShadow new];
    shadow.shadowColor = [UIColor.blackColor colorWithAlphaComponent:0.95];
    shadow.shadowBlurRadius = 2;
    shadow.shadowOffset = CGSizeMake(0, -1);
    label.attributedText = [[NSAttributedString alloc] initWithString:text attributes:@{
        NSFontAttributeName: font,
        NSForegroundColorAttributeName: color,
        NSShadowAttributeName: shadow
    }];
}

- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    if (_headline && ![self.traitCollection.preferredContentSizeCategory isEqualToString:previousTraitCollection.preferredContentSizeCategory])
        [self refresh];
}

- (void)toggleDetails {
    _collapsed = !_collapsed; _details.hidden = _collapsed;
    [NSUserDefaults.standardUserDefaults setBool:_collapsed forKey:@"DmPerfHUDCollapsed"];
    [self refresh];
}

- (void)refresh {
    nvn_perf_snapshot s; nvn_perf_read((uint64_t)(CACurrentMediaTime() * 1e9), &s);
    double headline_fps = s.presented_frames ? s.display_fps : s.game_fps;
    double headline_ms = s.frame_ms >= 0 ? s.frame_ms : (headline_fps > 0 ? 1000.0 / headline_fps : -1);
    NSString *fps = (s.presented_frames || s.game_fps > 0)
        ? [NSString stringWithFormat:@"%.1f %@FPS", headline_fps, s.presented_frames ? @"" : @"Game "] : @"-- FPS";
    NSString *frame = headline_ms >= 0 ? [NSString stringWithFormat:@"%.1f ms", headline_ms] : @"-- ms";
    NSString *headline = [NSString stringWithFormat:@"%@   %@", fps, frame];
    UIColor *brightGreen = [UIColor colorWithRed:0.45 green:1 blue:0.12 alpha:1];
    UIColor *softGreen = [UIColor colorWithRed:0.70 green:1 blue:0.48 alpha:1];
    [self applyText:headline toLabel:_headline baseSize:18 weight:UIFontWeightSemibold color:brightGreen];
    self.accessibilityHint = _collapsed ? @"Show performance details" : @"Hide performance details";
    if (_collapsed) { self.accessibilityValue = headline; return; }
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
#if TARGET_OS_SIMULATOR
    NSString *metal = @"N/A (Simulator)";
#else
    NSString *metal = [NSString stringWithFormat:@"%llu MiB", (unsigned long long)(_device.currentAllocatedSize >> 20)];
#endif
    NSString *details = [NSString stringWithFormat:@"Game %.1f FPS   GPU %@\nRAM %@   Metal %@\n%ux%u   Thermal %@",
        s.game_fps, gpu, ram, metal, s.width, s.height, thermal];
    [self applyText:details toLabel:_details baseSize:12 weight:UIFontWeightSemibold color:softGreen];
    self.accessibilityValue = [NSString stringWithFormat:@"%@. %@", headline, details];
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
