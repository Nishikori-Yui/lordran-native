// iOS front end (the iOS implementation of front.h): a centered 16:9 Metal view (black bars on both sides) + a full-screen virtual gamepad layer (DmGamepad.m, controls drawn over the picture).
// The host runs on the big-stack thread started by main.m; front_run runs the guest directly on the calling thread.
#import <UIKit/UIKit.h>
#import <QuartzCore/CAMetalLayer.h>
#import <Metal/Metal.h>
#import <AVFAudio/AVFAudio.h>
#import "DmPerfHUD.h"
#import "DmDiagnostics.h"
#import "DmGamepad.h"
#import "DmControlOverlay.h"
#import "DmAppSettings.h"
#include <errno.h>
#include "front.h"
#include "hle.h"
#include "dm.h"

void front_ios_boot(void);
int front_ios_boot_ok(void);
int front_ios_recovery_needed(void);

static CAMetalLayer *g_layer;

void front_vibration(const DmVibrationFrame *frame) { if (frame) dm_gamepad_vibration(*frame); }
int front_vibration_supported(void) { return dm_gamepad_vibration_supported(); }
void front_vibration_set_enabled(int enabled) { dm_gamepad_vibration_enabled(enabled); }

@interface DmGameView : UIView
@end
@implementation DmGameView
+ (Class)layerClass { return CAMetalLayer.class; }
- (instancetype)initWithFrame:(CGRect)f {
    if ((self = [super initWithFrame:f])) {
        CAMetalLayer *l = (CAMetalLayer *)self.layer;
        l.device = MTLCreateSystemDefaultDevice(); l.pixelFormat = MTLPixelFormatBGRA8Unorm;
        l.contentsScale = UIScreen.mainScreen.nativeScale; l.framebufferOnly = NO; l.opaque = YES;
        self.backgroundColor = UIColor.blackColor;
    }
    return self;
}
- (void)layoutSubviews {
    [super layoutSubviews];
    CAMetalLayer *l = (CAMetalLayer *)self.layer;
    l.drawableSize = CGSizeMake(self.bounds.size.width * l.contentsScale, self.bounds.size.height * l.contentsScale);
}
@end

@interface DmRootVC : UIViewController
@property (nonatomic, strong) DmGameView *game;
@property (nonatomic, strong) DmGamepad *pad;
@property (nonatomic, strong) UIView *recovery;
@property (nonatomic, strong) DmControlOverlay *controls;
@property (nonatomic, strong) DmPerfHUD *performance;
@end
@implementation DmRootVC
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.blackColor;
    self.controls = [[DmControlOverlay alloc] initWithFrame:self.view.bounds];
    self.controls.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.controls.presenter = self;
    self.controls.showsFPS = DmAppPerformanceVisible();
    __weak DmRootVC *weakSelf = self;
    self.controls.fpsChanged = ^(BOOL visible) { [weakSelf updatePerformance]; };
    [self.view addSubview:self.controls];
    if (front_ios_recovery_needed()) {
        UILabel *message = [UILabel new];
        message.text = @"The previous session did not finish normally.\nExport diagnostics before trying again.\n\n上次运行未正常结束，可先导出诊断，再尝试启动。";
        message.numberOfLines = 0; message.textColor = UIColor.whiteColor; message.textAlignment = NSTextAlignmentCenter;
        message.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
        message.adjustsFontForContentSizeCategory = YES;
        UIButton *start = [UIButton buttonWithType:UIButtonTypeSystem];
        start.configuration = UIButtonConfiguration.filledButtonConfiguration;
        [start setTitle:@"Start game / 启动游戏" forState:UIControlStateNormal];
        [start addTarget:self action:@selector(resumeFromRecovery) forControlEvents:UIControlEventTouchUpInside];
        UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[message, start]];
        stack.axis = UILayoutConstraintAxisVertical; stack.spacing = 24; stack.translatesAutoresizingMaskIntoConstraints = NO;
        [self.view addSubview:stack]; self.recovery = stack;
        [NSLayoutConstraint activateConstraints:@[
            [stack.centerXAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.centerXAnchor],
            [stack.centerYAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.centerYAnchor],
            [stack.leadingAnchor constraintGreaterThanOrEqualToAnchor:self.view.safeAreaLayoutGuide.leadingAnchor constant:24],
            [stack.trailingAnchor constraintLessThanOrEqualToAnchor:self.view.safeAreaLayoutGuide.trailingAnchor constant:-24]
        ]];
        [self.view bringSubviewToFront:self.controls];
    } else [self loadGameViews];
}
- (void)updatePerformance {
    if (self.controls.showsFPS && self.game) {
        if (self.performance) return;
        self.performance = [DmPerfHUD new];
        self.performance.gamepad = self.pad;
        [self.performance attachToView:self.view belowSubview:self.controls];
    } else {
        [self.performance removeFromSuperview]; self.performance = nil;
    }
}
- (void)resumeFromRecovery {
    [self.recovery removeFromSuperview]; self.recovery = nil;
    [self loadGameViews]; [self.view setNeedsLayout]; [self.view layoutIfNeeded];
    front_ios_boot();
}
- (void)loadGameViews {
    if (!front_ios_boot_ok()) {   // No game files: show a hint and do not start the host
        UILabel *lb = [[UILabel alloc] initWithFrame:CGRectInset(self.view.bounds, 40, 40)];
        lb.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        lb.numberOfLines = 0; lb.textAlignment = NSTextAlignmentCenter; lb.textColor = UIColor.whiteColor;
        lb.text = @"Game files not found.\nPut the RomFS folder into this App's Documents as \"romfs\" (Files app), then restart.\n\n没找到游戏文件：把 RomFS 文件夹以 romfs 为名放进本 App 的「文稿」后重开。";
        [self.view insertSubview:lb belowSubview:self.controls]; return;
    }
    self.game = [[DmGameView alloc] initWithFrame:self.view.bounds];
    [self.view insertSubview:self.game belowSubview:self.controls];
    g_layer = (CAMetalLayer *)self.game.layer;
    self.pad = (DmGamepad *)dm_gamepad_view(self.view.bounds);
    self.pad.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view insertSubview:self.pad belowSubview:self.controls];
    self.controls.gamepad = self.pad;
    [self updatePerformance];
}
- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGRect b = self.view.bounds; if (!self.game) return;
    CGFloat w = b.size.width, h = b.size.height;   // Fit 16:9 into the whole screen
    if (w / h > 16.0 / 9.0) w = h * 16.0 / 9.0; else h = w * 9.0 / 16.0;
    self.game.frame = CGRectMake(floor((b.size.width - w) / 2), floor((b.size.height - h) / 2), w, h);
}
- (void)viewDidAppear:(BOOL)a { [super viewDidAppear:a]; if (!self.recovery) front_ios_boot(); }
- (BOOL)prefersHomeIndicatorAutoHidden { return YES; }
- (UIRectEdge)preferredScreenEdgesDeferringSystemGestures { return UIRectEdgeAll; }   // Edge gestures need two swipes, to avoid accidental exits
- (BOOL)prefersStatusBarHidden { return YES; }
- (UIInterfaceOrientationMask)supportedInterfaceOrientations { return UIInterfaceOrientationMaskLandscape; }
@end
UIViewController *front_ios_root(void) { return [DmRootVC new]; }

void *front_metal_layer(void) { return (__bridge void *)g_layer; }
uint64_t front_game_res(int docked) { return docked ? 900ull << 32 | 1600 : 720ull << 32 | 1280; }   // Same as Mac: the original 16:9 constants
void front_run(void (*guest)(void)) { guest(); }   // Already on main.m's big-stack thread

// Software keyboard: show a UIAlertController on the main thread, the calling thread waits for the result
int front_text_input(const char *title, const char *sub, const char *guide, const char *initial, int max_chars, char *out, int out_cap) {
    (void)max_chars;
    if (!g_layer) return -1;
    __block int r = 0; __block NSString *text = nil;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    NSString *t = title && *title ? @(title) : @"", *m = [NSString stringWithFormat:@"%s%s%s", sub ? sub : "", sub && *sub && guide && *guide ? "\n" : "", guide ? guide : ""];
    NSString *init = initial ? @(initial) : @"", *ph = guide ? @(guide) : @"";
    dispatch_async(dispatch_get_main_queue(), ^{
        UIAlertController *ac = [UIAlertController alertControllerWithTitle:t message:m preferredStyle:UIAlertControllerStyleAlert];
        [ac addTextFieldWithConfigurationHandler:^(UITextField *f) { f.text = init; f.placeholder = ph; }];
        [ac addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) { (void)x; r = 1; text = ac.textFields.firstObject.text; dispatch_semaphore_signal(done); }]];
        [ac addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:^(UIAlertAction *x) { (void)x; dispatch_semaphore_signal(done); }]];
        UIViewController *vc = nil;
        for (UIScene *s in UIApplication.sharedApplication.connectedScenes) if ([s isKindOfClass:UIWindowScene.class]) for (UIWindow *w in ((UIWindowScene *)s).windows) if (w.isKeyWindow) vc = w.rootViewController;
        if (!vc) { dispatch_semaphore_signal(done); return; }
        [vc presentViewController:ac animated:YES completion:nil];
    });
    guest_clock_freeze_for(2, 1);
    dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER);
    guest_clock_freeze_for(2, 0);
    if (!r) return 0;
    snprintf(out, out_cap, "%s", text.UTF8String ? text.UTF8String : "");
    return 1;
}

// Save write failed (most likely the phone's storage is full): show a notice on the main thread without blocking the game (as d2r-mobile does). hle_fs.c calls this when a save transaction is refused or a mount has to fall back to read-only;
// the iOS front end used not to implement it, so there was only a log line and the player never learned that progress was not being saved
void front_save_failed(int err) {
    LOG("Save write failed: errno=%d; notifying player", err);
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *vc = nil;
        for (UIScene *s in UIApplication.sharedApplication.connectedScenes) if ([s isKindOfClass:UIWindowScene.class]) for (UIWindow *w in ((UIWindowScene *)s).windows) if (w.isKeyWindow) vc = w.rootViewController;
        while (vc.presentedViewController) vc = vc.presentedViewController;
        if (!vc) { LOG_ERROR("Cannot show save-failure notification: no window; errno=%d", err); return; }
        NSString *m = err == ENOSPC ? @"存储空间不足，进度没有存上。请清理空间后再存档。\nStorage is full, so progress was not saved. Free up space and save again."
                                    : [NSString stringWithFormat:@"存档写入失败（errno %d），进度没有存上。\nSaving failed (errno %d); progress was not saved.", err, err];
        UIAlertController *a = [UIAlertController alertControllerWithTitle:@"存档失败 / Save failed" message:m preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [vc presentViewController:a animated:YES completion:nil];
    });
}

// Audio session: the frames RemoteIO asks for in each callback follow the I/O buffer duration, about 21 ms by default on iOS (1024 frames at 48 kHz). The game keeps only 4 blocks × 5 ms = 20 ms in flight,
// so every callback came up 1.3 ms short and was zero-filled, about 47 gaps per second (crackling; reproducible on the Mac by forcing 1024-frame callbacks: 1999 underruns in 2000 callbacks). Ask for 5 ms and the system picks the nearest it supports;
// Playback keeps game audio audible when the hardware silent switch is on. Set once at boot and again on return to the foreground (the system may reset it after an interruption)
void front_ios_audio_session(void) {
    AVAudioSession *s = AVAudioSession.sharedInstance; NSError *e = nil;
    if (![s setCategory:AVAudioSessionCategoryPlayback error:&e]) LOG_ERROR("Failed to set audio session category: %s", e.localizedDescription.UTF8String);
    [s setPreferredSampleRate:48000 error:nil];
    if (![s setPreferredIOBufferDuration:0.005 error:&e]) LOG_ERROR("Failed to set audio session I/O buffer duration: %s", e.localizedDescription.UTF8String);
    if (![s setActive:YES error:&e]) LOG_ERROR("Failed to activate audio session: %s", e.localizedDescription.UTF8String);
    LOG("Audio session configured: sample_rate_hz=%.0f io_buffer_ms=%.2f requested_io_buffer_ms=5", s.sampleRate, s.IOBufferDuration * 1000);
}

// Scene lifecycle (called by SceneDelegate in main.m): 0 resign active, 1 enter background, 2 return to foreground, 3 become active. On entering background, freeze the guest clock and suspend after in-flight GPU work completes (submitting GPU work in background gets the process killed)
void front_ios_focus_event(int ev) {
    if (!g_layer) return;
    switch (ev) {
        case 0: dm_gamepad_reset(); dm_focus_set(2); break;
        case 1: dm_focus_set(3); dm_audio_suspend(1); guest_clock_freeze_for(1, 1); dm_gfx_suspend(1); break;
        case 2: dm_gfx_suspend(0); guest_clock_freeze_for(1, 0); front_ios_audio_session(); dm_audio_suspend(0); dm_focus_set(2); break;
        case 3: dm_focus_set(1); break;
    }
}
