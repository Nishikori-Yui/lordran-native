// Standalone simulator harness: no host, game files, signing, or IPA installation.
#import "../Sources/DmGamepad.h"
#import "../Sources/DmControlOverlay.h"
#import <GameController/GameController.h>
#import <QuartzCore/QuartzCore.h>
#include "../../host/dm_input.h"
#include <assert.h>
#include <stdio.h>

#undef assert
#define assert(condition) do { if (!(condition)) @throw [NSException exceptionWithName:@"TestFailure" reason:[NSString stringWithFormat:@"%s:%d: %s", __FILE__, __LINE__, #condition] userInfo:nil]; } while (0)

@interface DmGamepad (TestCalls)
- (void)becomeActive;
- (void)resignActive;
- (void)readController;
- (void)swipeTick:(id)tick;
@end
@interface DmControlOverlay (TestCalls)
- (void)toggleMenu;
- (void)closeMenu;
- (void)editControls;
- (void)saveEdits;
- (void)cancelEdits;
- (void)inputSettings;
- (void)sliderChanged:(UISlider *)slider;
- (void)panBall:(UIPanGestureRecognizer *)pan;
- (void)exportLog;
- (void)fpsToggled:(UISwitch *)toggle;
@end
static uint64_t buttons;
static int32_t axes[4];
static UIButton *exportAnchor;
void dm_input_set(uint64_t b, int32_t lx, int32_t ly, int32_t rx, int32_t ry) {
    buttons = b; axes[0] = lx; axes[1] = ly; axes[2] = rx; axes[3] = ry;
}
void DmDiagnosticsShare(UIViewController *presenter, UIButton *button) { assert(presenter); exportAnchor = button; }

@interface TestPad : DmGamepad
@end
@implementation TestPad
- (UIEdgeInsets)safeAreaInsets { return UIEdgeInsetsMake(0, 44, 21, 44); }
@end
@interface TestOverlay : DmControlOverlay
@end
@implementation TestOverlay
- (UIEdgeInsets)safeAreaInsets { return UIEdgeInsetsMake(0, 44, 21, 44); }
@end
@interface TestTouch : NSObject
@property CGPoint point;
@end
@implementation TestTouch
- (CGPoint)locationInView:(UIView *)view { return self.point; }
@end
@interface TestTick : NSObject
@end
@implementation TestTick
- (CFTimeInterval)timestamp { return 1; }
- (CFTimeInterval)targetTimestamp { return 1 + 1.0 / 60; }
@end
@interface TestPan : UIPanGestureRecognizer
@property CGPoint movement;
@property UIGestureRecognizerState testState;
@end
@implementation TestPan
- (CGPoint)translationInView:(UIView *)view { return self.movement; }
- (UIGestureRecognizerState)state { return self.testState; }
@end
static NSSet *touchSet(TestTouch *t) { return [NSSet setWithObject:t]; }
static TestTouch *begin(DmGamepad *pad, CGPoint p) {
    TestTouch *t = [TestTouch new]; t.point = p; [pad touchesBegan:touchSet(t) withEvent:nil]; return t;
}
static void move(DmGamepad *pad, TestTouch *t, CGPoint p) { t.point = p; [pad touchesMoved:touchSet(t) withEvent:nil]; }
static void end(DmGamepad *pad, TestTouch *t) { [pad touchesEnded:touchSet(t) withEvent:nil]; }
static void released(void) { assert(buttons == 0 && axes[0] == 0 && axes[1] == 0 && axes[2] == 0 && axes[3] == 0); }
static void snapshot(UIView *view, NSString *name) {
    [view layoutIfNeeded];
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithBounds:view.bounds];
    UIImage *image = [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) { [view drawViewHierarchyInRect:view.bounds afterScreenUpdates:YES]; }];
    NSURL *dir = [NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject;
    assert([UIImagePNGRepresentation(image) writeToURL:[dir URLByAppendingPathComponent:name] atomically:YES]);
}
static void panelFits(DmControlOverlay *overlay) {
    UIView *panel = [overlay valueForKey:@"panel"];
    assert(panel && panel.bounds.size.width > 200 && panel.bounds.size.height > 100);
    CGRect safe = UIEdgeInsetsInsetRect(overlay.bounds, overlay.safeAreaInsets);
    assert(CGRectContainsRect(safe, panel.frame));
    UIScrollView *scroll = [overlay valueForKey:@"scroll"];
    [panel layoutIfNeeded];
    assert(scroll.contentSize.height > 100 && scroll.contentSize.width >= panel.bounds.size.width - 1);
    assert(!panel.hasAmbiguousLayout);
    assert(CGColorGetAlpha(panel.backgroundColor.CGColor) > 0 && CGColorGetAlpha(panel.backgroundColor.CGColor) < 1);
}
static void runTests(UIViewController *presenter) {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    [defaults removeObjectForKey:@"DmControlProfile.v1"];
    [defaults removeObjectForKey:@"DmControlDock.v1"];
    [defaults removeObjectForKey:@"DmPadLayout"];
    UIView *canvas = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 844, 390)];
    CAGradientLayer *gradient = [CAGradientLayer layer]; gradient.frame = canvas.bounds;
    gradient.colors = @[(id)[UIColor colorWithRed:0.32 green:0.22 blue:0.1 alpha:1].CGColor,
                        (id)[UIColor colorWithRed:0.05 green:0.12 blue:0.17 alpha:1].CGColor];
    [canvas.layer addSublayer:gradient]; [presenter.view addSubview:canvas];
    TestPad *pad = [[TestPad alloc] initWithFrame:canvas.bounds]; [canvas addSubview:pad]; [pad becomeActive];
    TestOverlay *overlay = [[TestOverlay alloc] initWithFrame:canvas.bounds];
    overlay.gamepad = pad; overlay.presenter = presenter; [canvas addSubview:overlay];
    [canvas layoutIfNeeded];
    assert([overlay hitTest:CGPointMake(420, 150) withEvent:nil] == nil);
    UIButton *ball = [overlay valueForKey:@"ball"];
    assert(ball.bounds.size.width == 48 && CGRectGetMaxX(ball.frame) <= 800);
    [overlay toggleMenu]; panelFits(overlay);
    assert(ball.hidden);
    assert([overlay hitTest:CGPointMake(100, 160) withEvent:nil] == overlay);
    __block BOOL showsFPS = NO;
    overlay.fpsChanged = ^(BOOL visible) { showsFPS = visible; };
    UISwitch *fps = [UISwitch new]; fps.on = YES; [overlay fpsToggled:fps];
    assert(showsFPS && overlay.showsFPS && [defaults boolForKey:@"DmShowFPS"]);
    fps.on = NO; [overlay fpsToggled:fps]; assert(!showsFPS && !overlay.showsFPS);
    UIButton *exportButton = [overlay valueForKey:@"export"];
    assert(exportButton && !exportButton.hidden);
    [overlay exportLog]; assert(exportAnchor == exportButton && exportButton.window);
    snapshot(canvas, @"controls-menu.png"); [overlay closeMenu];

    // Opening the editor releases both held buttons and pending camera motion.
    TestTouch *key = begin(pad, [pad controlCenter:0]); assert(buttons & DM_BTN_A);
    TestTouch *camera = begin(pad, CGPointMake(500, 150)); move(pad, camera, CGPointMake(510, 145));
    [pad swipeTick:(id)[TestTick new]]; assert(axes[2] > 0 && axes[3] > 0);
    [overlay toggleMenu]; released(); [overlay editControls]; assert(pad.editingControls);
    assert(ball.hidden && [overlay valueForKey:@"panel"] == nil);
    UIButton *confirm = [overlay valueForKey:@"confirm"];
    assert(confirm && fabs(confirm.center.x - CGRectGetMidX(canvas.bounds)) < 1 && fabs(confirm.center.y - CGRectGetMidY(canvas.bounds)) < 1);
    assert([overlay hitTest:CGPointMake(420, 150) withEvent:nil] == nil);
    CGPoint original = [pad controlCenter:0]; pad.selectedControl = 0; [pad layoutIfNeeded];
    TestTouch *drag = begin(pad, original); move(pad, drag, CGPointMake(420, 190)); end(pad, drag);
    CGPoint moved = [pad controlCenter:0]; assert(hypot(moved.x - 420, moved.y - 190) < 1);
    CGPoint handle = [pad controlResizeHandleCenter:0];
    TestTouch *resize = begin(pad, handle); move(pad, resize, CGPointMake(handle.x + 28, handle.y + 28)); end(pad, resize);
    assert([pad.profile styleForControl:0].scale > 1);
    released(); snapshot(canvas, @"controls-editor.png");
    [overlay cancelEdits]; assert(!pad.editingControls && hypot([pad controlCenter:0].x - original.x, [pad controlCenter:0].y - original.y) < 1);
    [overlay editControls]; [pad moveControl:0 toPoint:CGPointMake(420, 190)];
    DmControlStyle style = [pad.profile styleForControl:0]; style.scale = 1.4; style.angle = 45; style.shape = DmShapeSquare; style.opacity = 0.6;
    [pad.profile setStyle:style forControl:0]; [pad setNeedsLayout]; [pad layoutIfNeeded];
    [overlay saveEdits]; [overlay closeMenu]; [pad layoutIfNeeded];
    key = begin(pad, [pad controlCenter:0]); assert(buttons == DM_BTN_A); end(pad, key); released();
    key = begin(pad, original); assert(!(buttons & DM_BTN_A)); end(pad, key); released();
    DmControlProfile *loaded = [DmControlProfile loadWithDefaultFull:YES];
    style = [loaded styleForControl:0]; assert(style.positioned && style.shape == DmShapeSquare && fabs(style.opacity - 0.6) < 0.001);
    [pad.profile resetStyles]; [pad profileChanged]; [pad layoutIfNeeded];

    // Every left/right mode pair must release cleanly, including idle swipes.
    for (int left = 0; left <= 1; left++) for (int right = 0; right <= 1; right++) {
        pad.profile.leftMode = left; pad.profile.rightMode = right; [pad profileChanged]; [pad layoutIfNeeded];
        CGPoint l = left ? CGPointMake(340, 150) : [pad controlCenter:DmControlLeftStick];
        CGPoint r = right ? CGPointMake(510, 150) : [pad controlCenter:DmControlRightStick];
        TestTouch *lt = begin(pad, l), *rt = begin(pad, r);
        move(pad, lt, CGPointMake(l.x + 10, l.y - 5)); move(pad, rt, CGPointMake(r.x + 10, r.y - 5));
        [pad swipeTick:(id)[TestTick new]];
        assert(axes[0] > 0 && axes[1] > 0 && axes[2] > 0 && axes[3] > 0);
        [pad swipeTick:(id)[TestTick new]];
        if (left) assert(axes[0] == 0 && axes[1] == 0);
        if (right) assert(axes[2] == 0 && axes[3] == 0);
        end(pad, lt); end(pad, rt); released();
    }
    pad.profile.leftMode = DmStickJoystick; pad.profile.rightMode = DmStickSwipe; [pad profileChanged];
    [overlay toggleMenu]; [overlay inputSettings]; panelFits(overlay); snapshot(canvas, @"controls-input.png"); [overlay closeMenu];

    // Snapshot controllers exercise mapping and selection without external hardware.
    GCController *first = [GCController controllerWithExtendedGamepad], *second = [GCController controllerWithExtendedGamepad];
    [pad setValue:@[first, second] forKey:@"controllers"]; [pad selectController:0];
    assert(pad.hidden); [first.extendedGamepad.buttonA setValue:1]; [first.extendedGamepad.leftThumbstick.xAxis setValue:0.08];
    [pad readController]; assert(buttons == DM_BTN_B && axes[0] == 0);
    pad.profile.faceMapping = DmFaceLetters; [pad profileChanged]; [pad readController]; assert(buttons == DM_BTN_A);
    [first.extendedGamepad.buttonMenu setValue:1]; [first.extendedGamepad.leftTrigger setValue:1];
    [first.extendedGamepad.rightThumbstickButton setValue:1]; [first.extendedGamepad.leftThumbstick.xAxis setValue:0.8];
    [pad readController]; assert(buttons & DM_BTN_PLUS); assert(buttons & DM_BTN_ZL); assert(buttons & DM_BTN_RS); assert(axes[0] > 0);
    [pad selectController:1]; released();
    [pad setInputSuspended:YES]; [second.extendedGamepad.buttonB setValue:1]; [pad readController]; released();
    [pad setInputSuspended:NO]; assert(buttons != 0);
    [pad resignActive]; [pad readController]; released(); [pad becomeActive]; released(); assert(!pad.hidden);
    [overlay toggleMenu]; assert(ball.hidden); [overlay closeMenu]; assert(!ball.hidden);

    // Docking and a narrow landscape viewport keep both menu and editor on screen.
    CGPoint destinations[] = {{68, 150}, {776, 150}, {420, 24}, {420, 345}};
    for (int edge = 0; edge < 4; edge++) {
        TestPan *pan = [TestPan new]; pan.testState = UIGestureRecognizerStateBegan; [overlay panBall:pan];
        pan.testState = UIGestureRecognizerStateEnded;
        pan.movement = CGPointMake(destinations[edge].x - ball.center.x, destinations[edge].y - ball.center.y); [overlay panBall:pan];
        assert([[overlay valueForKey:@"edge"] integerValue] == edge);
        assert(hypot(ball.center.x - destinations[edge].x, ball.center.y - destinations[edge].y) < 1);
    }
    TestOverlay *restoredDock = [[TestOverlay alloc] initWithFrame:canvas.bounds];
    [restoredDock setNeedsLayout]; [restoredDock layoutIfNeeded];
    UIButton *restoredBall = [restoredDock valueForKey:@"ball"];
    assert(hypot(restoredBall.center.x - ball.center.x, restoredBall.center.y - ball.center.y) < 1);
    pad.frame = overlay.frame = CGRectMake(0, 0, 667, 375);
    [pad setNeedsLayout]; [overlay setNeedsLayout]; [pad layoutIfNeeded]; [overlay layoutIfNeeded];
    [overlay toggleMenu]; panelFits(overlay); assert(ball.hidden); [overlay editControls];
    assert(ball.hidden && [overlay valueForKey:@"panel"] == nil);
    snapshot(canvas, @"controls-editor-narrow.png"); [overlay cancelEdits]; [overlay closeMenu];
    released();
    puts("controls UI: menu, transparency, docking, export anchor, editor save/cancel, transformed touch, four input modes, controller selection and lifecycle passed");
    fflush(stdout);
}
@interface TestVC : UIViewController
@end
@implementation TestVC
- (UIInterfaceOrientationMask)supportedInterfaceOrientations { return UIInterfaceOrientationMaskLandscape; }
- (BOOL)prefersStatusBarHidden { return YES; }
- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        NSURL *dir = [NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject;
        NSURL *result = [dir URLByAppendingPathComponent:@"controls-ui-result.txt"];
        @try { runTests(self); [@"PASS\n" writeToURL:result atomically:YES encoding:NSUTF8StringEncoding error:nil]; exit(0); }
        @catch (NSException *e) {
            [e.description writeToURL:result atomically:YES encoding:NSUTF8StringEncoding error:nil];
            fprintf(stderr, "controls UI exception: %s\n", e.description.UTF8String); exit(1);
        }
    });
}
@end
@interface TestScene : UIResponder <UIWindowSceneDelegate>
@property (strong, nonatomic) UIWindow *window;
@end
@implementation TestScene
- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)options {
    self.window = [[UIWindow alloc] initWithWindowScene:(UIWindowScene *)scene];
    self.window.rootViewController = [TestVC new]; [self.window makeKeyAndVisible];
}
@end
@interface TestApp : UIResponder <UIApplicationDelegate>
@end
@implementation TestApp
@end
int main(int argc, char **argv) {
    @autoreleasepool { return UIApplicationMain(argc, argv, nil, NSStringFromClass(TestApp.class)); }
}
