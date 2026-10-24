#import "perf_hud_mac.h"
#import <QuartzCore/QuartzCore.h>
#include <mach/mach.h>
#include "../gfx/nvn/nvn_perf.h"
#import "graphics_settings_mac.h"

@interface DmPerfTextView : NSView
@end
@implementation DmPerfTextView
- (NSView *)hitTest:(NSPoint)point { (void)point; return nil; }
@end

@implementation DmMacPerfHUD {
    __weak NSWindow *_gameWindow;
    id<MTLDevice> _device;
    NSTextField *_headline, *_details;
    NSMenuItem *_modeItem;
    NSTimer *_timer;
}

- (instancetype)initWithWindow:(NSWindow *)window device:(id<MTLDevice>)device {
    if (!(self = [super init])) return nil;
    _gameWindow = window;
    _device = device;
    NSInteger saved = [NSUserDefaults.standardUserDefaults integerForKey:@"DmMacPerfMode"];
    _mode = saved >= 0 && saved <= 2 ? saved : 0;
    _view = [DmPerfTextView new];
    _view.translatesAutoresizingMaskIntoConstraints = NO;
    _view.accessibilityRole = NSAccessibilityGroupRole;
    _view.accessibilityLabel = @"Performance";
    _headline = [NSTextField labelWithString:@"-- FPS   -- ms"];
    _headline.accessibilityLabel = @"Frame rate and frame time";
    _details = [NSTextField wrappingLabelWithString:@""];
    _details.maximumNumberOfLines = 4;
    for (NSTextField *field in @[_headline, _details]) {
        field.translatesAutoresizingMaskIntoConstraints = NO;
        field.alignment = NSTextAlignmentRight;
        field.drawsBackground = NO;
        field.selectable = NO;
        [_view addSubview:field];
    }
    [window.contentView addSubview:_view];
    [NSLayoutConstraint activateConstraints:@[
        [_view.trailingAnchor constraintEqualToAnchor:window.contentView.trailingAnchor constant:-14],
        [_view.topAnchor constraintEqualToAnchor:window.contentView.topAnchor constant:14],
        [_view.widthAnchor constraintEqualToConstant:320],
        [_view.heightAnchor constraintEqualToConstant:118],
        [_headline.leadingAnchor constraintEqualToAnchor:_view.leadingAnchor],
        [_headline.trailingAnchor constraintEqualToAnchor:_view.trailingAnchor],
        [_headline.topAnchor constraintEqualToAnchor:_view.topAnchor],
        [_details.leadingAnchor constraintEqualToAnchor:_view.leadingAnchor],
        [_details.trailingAnchor constraintEqualToAnchor:_view.trailingAnchor],
        [_details.topAnchor constraintEqualToAnchor:_headline.bottomAnchor constant:5]
    ]];
    [self installMenu];
    NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
    for (NSNotificationName name in @[NSApplicationDidBecomeActiveNotification, NSApplicationWillResignActiveNotification])
        [nc addObserver:self selector:@selector(visibilityChanged:) name:name object:NSApp];
    for (NSNotificationName name in @[NSWindowDidMiniaturizeNotification, NSWindowDidDeminiaturizeNotification,
                                     NSWindowDidChangeOcclusionStateNotification])
        [nc addObserver:self selector:@selector(visibilityChanged:) name:name object:window];
    [nc addObserver:self selector:@selector(parentClosed:) name:NSWindowWillCloseNotification object:window];
    [self updateVisibility];
    return self;
}

- (void)installMenu {
    if (!NSApp.mainMenu) {
        NSMenu *main = [NSMenu new];
        NSMenuItem *appItem = [NSMenuItem new];
        appItem.submenu = [NSMenu new];
        [appItem.submenu addItemWithTitle:@"Quit" action:@selector(terminate:) keyEquivalent:@"q"];
        [main addItem:appItem];
        NSApp.mainMenu = main;
    }
    NSMenuItem *viewItem = [NSApp.mainMenu itemWithTitle:@"View"];
    if (!viewItem) {
        viewItem = [[NSMenuItem alloc] initWithTitle:@"View" action:nil keyEquivalent:@""];
        viewItem.submenu = [[NSMenu alloc] initWithTitle:@"View"];
        [NSApp.mainMenu addItem:viewItem];
    }
    _modeItem = [[NSMenuItem alloc] initWithTitle:@"Performance: Simple" action:@selector(cycleMode:)
                                  keyEquivalent:[NSString stringWithFormat:@"%C", (unichar)NSF5FunctionKey]];
    _modeItem.keyEquivalentModifierMask = 0;
    _modeItem.target = self;
    [viewItem.submenu addItem:_modeItem];
}

- (BOOL)updating { return _timer != nil; }
- (void)setMode:(NSInteger)mode {
    _mode = mode >= 0 && mode <= 2 ? mode : 0;
    [NSUserDefaults.standardUserDefaults setInteger:_mode forKey:@"DmMacPerfMode"];
    [self updateVisibility];
}
- (void)cycleMode:(id)sender { (void)sender; self.mode = (_mode + 1) % 3; }
- (BOOL)handleKeyEvent:(NSEvent *)event {
    NSEventModifierFlags shortcuts = NSEventModifierFlagCommand | NSEventModifierFlagControl |
                                     NSEventModifierFlagOption | NSEventModifierFlagShift;
    if (event.keyCode != 96 || (event.modifierFlags & shortcuts)) return NO;
    if (event.type == NSEventTypeKeyDown && !event.isARepeat) [self cycleMode:nil];
    return YES;
}
- (void)parentClosed:(NSNotification *)notification {
    (void)notification;
    [_timer invalidate]; _timer = nil;
    [_view removeFromSuperview];
    _gameWindow = nil;
}
- (void)visibilityChanged:(NSNotification *)notification {
    if ([notification.name isEqualToString:NSApplicationWillResignActiveNotification]) {
        [_timer invalidate]; _timer = nil;
        return;
    }
    [self updateVisibility];
}
- (void)updateVisibility {
    _modeItem.title = @[@"Performance: Simple", @"Performance: Detailed", @"Performance: Off"][_mode];
    _view.hidden = _mode == 2;
    _details.hidden = _mode != 1;
    NSWindow *window = _gameWindow;
    if (_mode == 2 || !window.visible || window.miniaturized || !NSApp.active) {
        [_timer invalidate]; _timer = nil;
        return;
    }
    [self refresh];
    if (!_timer) {
        __weak DmMacPerfHUD *weakSelf = self;
        _timer = [NSTimer timerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *timer) { (void)timer; [weakSelf refresh]; }];
        _timer.tolerance = 0.1;
        [NSRunLoop.mainRunLoop addTimer:_timer forMode:NSRunLoopCommonModes];
    }
}

- (void)setText:(NSString *)text field:(NSTextField *)field size:(CGFloat)size {
    NSShadow *shadow = [NSShadow new];
    shadow.shadowColor = [NSColor.blackColor colorWithAlphaComponent:0.95];
    shadow.shadowBlurRadius = 2;
    shadow.shadowOffset = NSMakeSize(0, -1);
    NSMutableParagraphStyle *paragraph = [NSMutableParagraphStyle new];
    paragraph.alignment = NSTextAlignmentRight;
    NSColor *green = field == _headline
        ? [NSColor colorWithSRGBRed:0.45 green:1 blue:0.12 alpha:1]
        : [NSColor colorWithSRGBRed:0.70 green:1 blue:0.48 alpha:1];
    field.attributedStringValue = [[NSAttributedString alloc] initWithString:text attributes:@{
        NSFontAttributeName: [NSFont monospacedDigitSystemFontOfSize:size weight:NSFontWeightSemibold],
        NSForegroundColorAttributeName: green,
        NSShadowAttributeName: shadow,
        NSParagraphStyleAttributeName: paragraph
    }];
}
- (void)refresh {
    nvn_perf_snapshot s; nvn_perf_read((uint64_t)(CACurrentMediaTime() * 1e9), &s);
    double fps = s.presented_frames ? s.display_fps : s.game_fps;
    double ms = s.frame_ms >= 0 ? s.frame_ms : (fps > 0 ? 1000.0 / fps : -1);
    NSString *rate = s.presented_frames || fps > 0
        ? [NSString stringWithFormat:@"%.1f %@FPS", fps, s.presented_frames ? @"" : @"Game "] : @"-- FPS";
    NSString *frame = ms >= 0 ? [NSString stringWithFormat:@"%.1f ms", ms] : @"-- ms";
    [self setText:[NSString stringWithFormat:@"%@   %@", rate, frame] field:_headline size:18];
    if (_mode != 1) return;
    NSString *gpu = s.gpu_ms >= 0 ? [NSString stringWithFormat:@"%.1f ms", s.gpu_ms] : @"-- ms";
    task_vm_info_data_t info; mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    NSString *ram = task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&info, &count) == KERN_SUCCESS
        ? [NSString stringWithFormat:@"%llu", (unsigned long long)(info.phys_footprint >> 20)] : @"--";
    NSUInteger state = (NSUInteger)NSProcessInfo.processInfo.thermalState;
    NSString *thermal = @[@"Nominal", @"Fair", @"Serious", @"Critical"][MIN(state, 3)];
    NSString *resolution = s.width && s.height ? [NSString stringWithFormat:@"%ux%u", s.width, s.height] : @"--x--";
    unsigned runResolutionPercent = dm_mac_graphics_resolution_percent();
    const char *runResolutionOverride = getenv("DM_GAME_RES");
    unsigned graphicsMSAA = dm_mac_graphics_msaa();
    unsigned graphicsAnisotropy = dm_mac_graphics_anisotropy();
    NSString *graphicsResolutionName = runResolutionOverride
        ? @"Override" : runResolutionPercent == 100 ? @"Native" : [NSString stringWithFormat:@"%u%%", runResolutionPercent];
    NSString *graphicsMSAAName = graphicsMSAA ? [NSString stringWithFormat:@"%ux", graphicsMSAA] : @"Default";
    NSString *graphicsAnisotropyName = graphicsAnisotropy ? [NSString stringWithFormat:@"%ux", graphicsAnisotropy] : @"Default";
    NSString *upscaling = dm_mac_graphics_upscaling() ? @" · MFX" : @"";
    [self setText:[NSString stringWithFormat:@"Game %.1f FPS   GPU %@\nRAM %@ MiB   Metal %llu MiB\n%@   Thermal %@\nGraphics %@%@ · MSAA %@ · AF %@",
        s.game_fps, gpu, ram, (unsigned long long)(_device.currentAllocatedSize >> 20), resolution, thermal,
        graphicsResolutionName, upscaling, graphicsMSAAName, graphicsAnisotropyName]
            field:_details size:12];
}
- (void)dealloc {
    [_timer invalidate];
    [NSNotificationCenter.defaultCenter removeObserver:self];
    [_view removeFromSuperview];
}
@end
