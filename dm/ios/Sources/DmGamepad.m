// Editable touch controls and one explicitly selected GameController device.
#import "DmGamepad.h"
#import <GameController/GameController.h>
#import <CoreText/CoreText.h>
#import <QuartzCore/QuartzCore.h>
#import <CoreHaptics/CoreHaptics.h>
#import <TargetConditionals.h>
#import <mach/mach_time.h>
#import "DmAppSettings.h"
#include "../../host/dm_vibration_queue.h"
#include "../../host/dm_vibration_timing.h"
#include "../../host/dm_vibration_haptics.h"
#include <pthread.h>
#include "dm_input.h"
#include "../../host/dm_log.h"
#include "dm_padmap.h"
#include "game_profile.h"
#include "dm_camera_swipe.h"
#include "dm_pad_axis.h"
#include <stdatomic.h>
#include <pthread.h>

enum { B_A, B_B, B_X, B_Y, B_LS, B_RS, B_L, B_R, B_ZL, B_ZR, B_PLUS, B_MINUS, B_LEFT, B_UP, B_RIGHT, B_DOWN, B_N };
enum { C_BUTTON = 1, C_FACE, C_DPAD, C_STICK, C_SWIPE };
NSNotificationName const DmControllerChangedNotification = @"DmControllerChanged";
static __weak DmGamepad *g_view;
static _Atomic int g_gamepad_vibration_enabled = 1;
static _Atomic int g_gamepad_haptics_ready;
static _Atomic int g_gamepad_haptics_render_logged;
static pthread_mutex_t g_mu = PTHREAD_MUTEX_INITIALIZER;
static uint64_t g_touch_btn, g_pad_btn;
static int32_t g_touch_axis[4], g_pad_axis[4];
static UIColor *kIdle, *kPressed, *kText;
static pthread_mutex_t g_vibration_queue_mu = PTHREAD_MUTEX_INITIALIZER;
static DmVibrationQueue g_vibration_queue;
static DmVibrationTimeline g_vibration_timeline;
static _Atomic uint64_t g_vibration_generation = 1;

static uint64_t vibration_now_ns(void) {
    static mach_timebase_info_data_t timebase;
    if (!timebase.denom) mach_timebase_info(&timebase);
    return mach_absolute_time() * timebase.numer / timebase.denom;
}

static void vibration_cancel_pending(void) {
    atomic_fetch_add(&g_vibration_generation, 1);
    pthread_mutex_lock(&g_vibration_queue_mu);
    g_vibration_queue = (DmVibrationQueue){0};
    pthread_mutex_unlock(&g_vibration_queue_mu);
    g_vibration_timeline = (DmVibrationTimeline){0};
}

static void vibration_drain(void);
static void publish(void) {
    pthread_mutex_lock(&g_mu);
    int32_t a[4];
    for (int i = 0; i < 4; i += 2) {
        BOOL physical = g_pad_axis[i] || g_pad_axis[i + 1];
        if (physical) dm_input_swipe_cancel(i / 2);
        a[i] = physical ? g_pad_axis[i] : g_touch_axis[i];
        a[i + 1] = physical ? g_pad_axis[i + 1] : g_touch_axis[i + 1];
    }
    dm_input_set(g_touch_btn | g_pad_btn, a[0], a[1], a[2], a[3]);
    pthread_mutex_unlock(&g_mu);
}
static void clearPad(void) {
    pthread_mutex_lock(&g_mu); g_pad_btn = 0; memset(g_pad_axis, 0, sizeof g_pad_axis); pthread_mutex_unlock(&g_mu);
    publish();
}
static CAShapeLayer *shape(CALayer *parent) {
    CAShapeLayer *s = [CAShapeLayer layer];
    s.lineWidth = 1.5; s.strokeColor = [UIColor colorWithWhite:1 alpha:0.48].CGColor;
    s.fillColor = kIdle.CGColor;
    [parent addSublayer:s]; return s;
}
static CATextLayer *textLayer(CALayer *parent, NSString *text) {
    CATextLayer *t = [CATextLayer layer]; t.string = text; t.alignmentMode = kCAAlignmentCenter;
    t.contentsScale = UIScreen.mainScreen.scale; t.foregroundColor = kText.CGColor;
    [parent addSublayer:t]; return t;
}
static void path(CAShapeLayer *layer, CGPathRef p) { layer.path = p; CGPathRelease(p); }
static void labelAt(CATextLayer *t, CGPoint center, CGFloat size) {
    CTFontRef font = CTFontCreateUIFontForLanguage(kCTFontUIFontEmphasizedSystem, size, NULL);
    t.font = font; t.fontSize = size;
    CGFloat h = CTFontGetAscent(font) + CTFontGetDescent(font) + CTFontGetLeading(font);
    t.frame = CGRectMake(center.x - size * 2, center.y - h / 2, size * 4, h); CFRelease(font);
}
static BOOL shoulder(NSInteger c) { return c >= B_L && c <= B_ZR; }
static CGPathRef arm(CGFloat angle) {
    CGPoint points[] = {{-17, -48}, {17, -48}, {17, -28}, {0, -11}, {-17, -28}};
    CGMutablePathRef p = CGPathCreateMutable();
    CGPathMoveToPoint(p, NULL, points[0].x, points[0].y);
    for (int i = 1; i < 5; i++) CGPathAddLineToPoint(p, NULL, points[i].x, points[i].y);
    CGPathCloseSubpath(p);
    CGAffineTransform t = CGAffineTransformMakeRotation(angle);
    CGPathRef out = CGPathCreateCopyByTransformingPath(p, &t); CGPathRelease(p); return out;
}

@implementation DmGamepad {
    DmControlProfile *_profile, *_savedProfile;
    CALayer *_control[DmControlCount];
    CAShapeLayer *_outline[DmControlCount], *_key[B_N], *_knob[2];
    CAShapeLayer *_editBox[DmControlCount], *_resizeHandle[DmControlCount];
    CGRect _editRect[DmControlCount];
    CATextLayer *_label[12], *_stickLabel[2];
    CGAffineTransform _transform[DmControlCount];
    NSMapTable<UITouch *, NSNumber *> *_owners;
    NSMapTable<UITouch *, NSNumber *> *_faceTouches;
    UITouch *_stickTouch[2], *_swipeTouch[2], *_editTouch;
    CGPoint _stickNow[2], _editOffset;
    CGPoint _resizeCenter, _resizeVector;
    CGFloat _resizeStartScale;
    BOOL _editResizing;
    dm_camera_swipe _swipe[2];
    NSArray<GCController *> *_controllers;
    GCController *_activeController;
    CHHapticEngine *_hapticsEngine;
    id<CHHapticAdvancedPatternPlayer> _hapticsPlayer;
    BOOL _hapticsPlaying;
    _Atomic int _hapticsSupported;
    BOOL _editingControls, _inputSuspended, _foreground;
    CGSize _lastSize;
    uint64_t _renderedButtons;
    CGPoint _renderedStick[2];
    BOOL _renderedHeld[2];
}
- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.multipleTouchEnabled = YES; self.opaque = NO; self.backgroundColor = UIColor.clearColor;
        static dispatch_once_t once;
        dispatch_once(&once, ^{
            kIdle = [UIColor colorWithWhite:1 alpha:0.14];
            kPressed = [UIColor colorWithWhite:1 alpha:0.5];
            kText = [UIColor colorWithWhite:1 alpha:0.8];
        });
        _renderedButtons = UINT64_MAX;
        _foreground = UIApplication.sharedApplication.applicationState == UIApplicationStateActive;
        _profile = [DmControlProfile loadWithDefaultFull:DM_GAME_PAD_FULL];
        _selectedControl = B_A;
        _owners = [NSMapTable strongToStrongObjectsMapTable]; _faceTouches = [NSMapTable strongToStrongObjectsMapTable];
        for (NSInteger c = 0; c < DmControlCount; c++) {
            _control[c] = [CALayer layer]; _control[c].anchorPoint = CGPointZero;
            [self.layer addSublayer:_control[c]];
            _outline[c] = shape(_control[c]);
            if (c < 12) { _key[c] = _outline[c]; _label[c] = textLayer(_control[c], DmControlName(c)); }
            else if (c == DmControlDpad) {
                _outline[c].fillColor = UIColor.clearColor.CGColor; _outline[c].strokeColor = nil;
                for (int b = B_LEFT; b < B_N; b++) _key[b] = shape(_control[c]);
            } else {
                int side = (int)c - DmControlLeftStick;
                _outline[c].fillColor = [UIColor colorWithWhite:1 alpha:0.06].CGColor;
                _knob[side] = shape(_control[c]); _stickLabel[side] = textLayer(_knob[side], side ? @"R" : @"L");
            }
        }
        for (NSInteger c = 0; c < DmControlCount; c++) {
            _editBox[c] = shape(self.layer); _editBox[c].fillColor = UIColor.clearColor.CGColor;
            _editBox[c].lineDashPattern = @[@4, @3]; _editBox[c].hidden = YES;
            _resizeHandle[c] = shape(self.layer); _resizeHandle[c].hidden = YES;
            CAShapeLayer *glyph = shape(_resizeHandle[c]); glyph.fillColor = nil; glyph.strokeColor = UIColor.whiteColor.CGColor;
            CGMutablePathRef arrows = CGPathCreateMutable();
            CGPathMoveToPoint(arrows, NULL, -4, -4); CGPathAddLineToPoint(arrows, NULL, 4, 4);
            CGPathMoveToPoint(arrows, NULL, -4, 1); CGPathAddLineToPoint(arrows, NULL, -4, -4); CGPathAddLineToPoint(arrows, NULL, 1, -4);
            CGPathMoveToPoint(arrows, NULL, -1, 4); CGPathAddLineToPoint(arrows, NULL, 4, 4); CGPathAddLineToPoint(arrows, NULL, 4, -1);
            path(glyph, arrows);
        }
        NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
        [nc addObserver:self selector:@selector(padsChanged) name:GCControllerDidConnectNotification object:nil];
        [nc addObserver:self selector:@selector(padsChanged) name:GCControllerDidDisconnectNotification object:nil];
        [nc addObserver:self selector:@selector(applicationWillTerminate:) name:UIApplicationWillTerminateNotification object:nil];
        [nc addObserver:self selector:@selector(resignActive) name:UIApplicationWillResignActiveNotification object:nil];
        [nc addObserver:self selector:@selector(becomeActive) name:UIApplicationDidBecomeActiveNotification object:nil];
        [self padsChanged];
    }
    return self;
}
- (DmControlProfile *)profile { return _profile; }
- (BOOL)isEditingControls { return _editingControls; }
- (CGRect)safe { return UIEdgeInsetsInsetRect(self.bounds, self.safeAreaInsets); }
- (CGFloat)unit { return MAX(0.4, MIN(self.bounds.size.height / 430.0, 1.3)); }
- (CGSize)baseHalf:(NSInteger)c {
    if (c < 4) return CGSizeMake(27, 27);
    if (c < 6) return CGSizeMake(17, 17);
    if (shoulder(c)) { CGFloat r = c == B_ZL || c == B_ZR ? 26 : 24; return CGSizeMake(r, r); }
    if (c < 12) return CGSizeMake(25, 14);
    if (c == DmControlDpad) return CGSizeMake(48, 48);
    return CGSizeMake(66, 66);
}
- (CGPoint)defaultCenter:(NSInteger)c {
    CGRect s = self.safe; CGFloat u = self.unit;
    CGFloat left = CGRectGetMinX(s), right = CGRectGetMaxX(s), top = CGRectGetMinY(s), bottom = CGRectGetMaxY(s);
    CGPoint face = CGPointMake(right - 81 * u, bottom - 82 * u);
    if (c < 4) {
        static const CGPoint offsets[] = {{50, 0}, {0, 50}, {0, -50}, {-50, 0}};
        return CGPointMake(face.x + offsets[c].x * u, face.y + offsets[c].y * u);
    }
    if (c < 6) return CGPointMake(c == B_RS ? right - 102 * u : left + 102 * u, top + 40 * u);
    if (shoulder(c)) return CGPointMake(c == B_R || c == B_ZR ? right - 44 * u : left + 44 * u,
                                        top + (c == B_ZL || c == B_ZR ? 40 : 108) * u);
    if (c < 12) return CGPointMake(CGRectGetMidX(s) + (c == B_PLUS ? 38 : -38) * u, top + 22 * u);
    if (c == DmControlDpad) return CGPointMake(left + 231 * u, bottom - 64 * u);
    if (c == DmControlLeftStick) return CGPointMake(left + 81 * u, bottom - 82 * u);
    return CGPointMake(right - 231 * u, bottom - 82 * u);
}
- (CGPoint)controlCenter:(NSInteger)c {
    if (c < 0 || c >= DmControlCount) return CGPointZero;
    DmControlStyle s = [_profile styleForControl:c]; CGSize r = [self baseHalf:c];
    CGFloat extra = s.shape == DmShapeDrop || (s.shape == DmShapeDefault && shoulder(c)) ? 1.45 : 1;
    r.width *= self.unit * extra; r.height *= self.unit * extra;
    return DmControlCenter(s, [self defaultCenter:c], self.safe, r);
}
- (CGPoint)controlResizeHandleCenter:(NSInteger)c {
    return c >= 0 && c < DmControlCount ? CGPointMake(CGRectGetMaxX(_editRect[c]), CGRectGetMaxY(_editRect[c])) : CGPointZero;
}
- (void)moveControl:(NSInteger)c toPoint:(CGPoint)p {
    if (c < 0 || c >= DmControlCount) return;
    CGRect safe = self.safe; if (safe.size.width <= 0 || safe.size.height <= 0) return;
    DmControlStyle s = [_profile styleForControl:c]; s.positioned = YES;
    s.x = (p.x - safe.origin.x) / safe.size.width; s.y = (p.y - safe.origin.y) / safe.size.height;
    [_profile setStyle:s forControl:c]; [self setNeedsLayout]; [self layoutIfNeeded];
    // Store the clamped visible position, so subsequent drags do not jump at an edge.
    CGPoint visible = [self controlCenter:c]; s.x = (visible.x - safe.origin.x) / safe.size.width; s.y = (visible.y - safe.origin.y) / safe.size.height;
    [_profile setStyle:s forControl:c];
}
- (BOOL)visibleControl:(NSInteger)c {
    if (_editingControls) return YES;
    if (!_profile.fullLayout && (c == B_LS || c == B_RS || c == DmControlDpad)) return NO;
    if (c == DmControlLeftStick) return _profile.leftMode == DmStickJoystick;
    if (c == DmControlRightStick) return _profile.rightMode == DmStickJoystick;
    return YES;
}
- (void)layoutSubviews {
    [super layoutSubviews];
    if (!CGSizeEqualToSize(_lastSize, self.bounds.size)) { _lastSize = self.bounds.size; [self resetTouches]; }
    [CATransaction begin]; [CATransaction setDisableActions:YES];
    for (NSInteger c = 0; c < DmControlCount; c++) {
        DmControlStyle s = [_profile styleForControl:c]; CGSize r = [self baseHalf:c];
        CGPoint center = [self controlCenter:c]; _transform[c] = DmControlTransform(s, center, self.unit);
        _control[c].position = center;
        CGAffineTransform local = _transform[c]; local.tx = local.ty = 0; _control[c].affineTransform = local;
        _control[c].opacity = (float)s.opacity; _control[c].hidden = ![self visibleControl:c];
        DmControlShape kind = s.shape;
        if (kind == DmShapeDefault) kind = shoulder(c) ? DmShapeDrop : c == B_PLUS || c == B_MINUS ? DmShapeRounded : DmShapeCircle;
        CGFloat angle = c == B_R || c == B_ZR ? -M_PI_4 : -3 * M_PI_4;
        path(_outline[c], DmControlCreatePath(kind, r, angle));
        _outline[c].strokeColor = (_editingControls && c == _selectedControl ? UIColor.systemOrangeColor : [UIColor colorWithWhite:1 alpha:0.48]).CGColor;
        _outline[c].lineWidth = _editingControls && c == _selectedControl ? 3 : 1.5;
        if (c < 12) labelAt(_label[c], CGPointZero, c < 4 ? 20 : c < 6 ? 13 : 16);
        else if (c == DmControlDpad) {
            _outline[c].strokeColor = _editingControls && c == _selectedControl ? UIColor.systemOrangeColor.CGColor : nil;
            static const int buttons[] = {B_UP, B_RIGHT, B_DOWN, B_LEFT};
            for (int i = 0; i < 4; i++) {
                if (s.shape == DmShapeDefault) path(_key[buttons[i]], arm(i * M_PI_2));
                else {
                    CGPathRef p = DmControlCreatePath(kind, CGSizeMake(15, 15), -M_PI_2);
                    CGAffineTransform t = CGAffineTransformMakeRotation(i * M_PI_2);
                    t = CGAffineTransformTranslate(t, 0, -30);
                    CGPathRef transformed = CGPathCreateCopyByTransformingPath(p, &t); CGPathRelease(p); path(_key[buttons[i]], transformed);
                }
            }
        } else {
            int side = (int)c - DmControlLeftStick;
            path(_knob[side], DmControlCreatePath(DmShapeCircle, CGSizeMake(27, 27), 0));
            labelAt(_stickLabel[side], CGPointZero, 16);
        }
        _editBox[c].hidden = _resizeHandle[c].hidden = !_editingControls;
        if (_editingControls) {
            CGPathRef screenPath = CGPathCreateCopyByTransformingPath(_outline[c].path, &_transform[c]);
            CGRect box = CGRectInset(CGPathGetPathBoundingBox(screenPath), -7, -7); CGPathRelease(screenPath);
            _editRect[c] = CGRectIntersection(CGRectInset(self.bounds, 3, 3), box);
            path(_editBox[c], CGPathCreateWithRoundedRect(_editRect[c], 5, 5, NULL));
            BOOL selected = c == _selectedControl;
            _editBox[c].strokeColor = (selected ? UIColor.systemOrangeColor : [UIColor colorWithWhite:1 alpha:0.65]).CGColor;
            _editBox[c].lineWidth = selected ? 2 : 1;
            _editBox[c].zPosition = selected ? 3 : 1;
            _resizeHandle[c].position = CGPointMake(CGRectGetMaxX(_editRect[c]), CGRectGetMaxY(_editRect[c]));
            path(_resizeHandle[c], DmControlCreatePath(DmShapeCircle, CGSizeMake(11, 11), 0));
            _resizeHandle[c].fillColor = (selected ? UIColor.systemOrangeColor : [UIColor colorWithWhite:0.18 alpha:0.85]).CGColor;
            _resizeHandle[c].zPosition = selected ? 4 : 2;
        }
    }
    [CATransaction commit]; [self refresh:0];
}
- (void)safeAreaInsetsDidChange { [super safeAreaInsetsDidChange]; [self resetTouches]; [self setNeedsLayout]; }
- (void)refresh:(uint64_t)buttons {
    [CATransaction begin]; [CATransaction setDisableActions:YES];
    uint64_t changed = _renderedButtons ^ buttons;
    for (int b = 0; b < B_N; b++) if ((changed >> b) & 1) {
        BOOL on = (buttons >> b) & 1;
        _key[b].fillColor = (on ? kPressed : kIdle).CGColor;
        if (b < 12) _label[b].foregroundColor = (on ? UIColor.blackColor : kText).CGColor;
    }
    _renderedButtons = buttons;
    for (int side = 0; side < 2; side++) {
        CGPoint offset = [self stickOffset:side]; BOOL held = _stickTouch[side] != nil;
        if (!CGPointEqualToPoint(offset, _renderedStick[side])) _knob[side].position = offset;
        if (held != _renderedHeld[side]) _knob[side].fillColor = (held ? kPressed : kIdle).CGColor;
        _renderedStick[side] = offset; _renderedHeld[side] = held;
    }
    [CATransaction commit];
}
- (BOOL)hit:(NSInteger)c point:(CGPoint)p padding:(CGFloat)padding {
    return [self visibleControl:c] && DmControlHit(_outline[c].path, _transform[c], p, padding);
}
- (NSInteger)controlAt:(CGPoint)p {
    static const int priority[] = {8, 6, 9, 7, 10, 11, 4, 5, 0, 1, 2, 3, 12, 13, 14};
    for (int i = 0; i < DmControlCount; i++) if ([self hit:priority[i] point:p padding:_editingControls ? 0 : 6 * self.unit]) return priority[i];
    return -1;
}
- (BOOL)hasVisibleControlAtPoint:(CGPoint)point {
    if (self.hidden || self.alpha <= 0.01 || !self.userInteractionEnabled || !CGRectContainsPoint(self.bounds, point)) return NO;
    [self layoutIfNeeded];
    if (_editingControls) {
        BOOL resizing = NO;
        return [self editControlAt:point resizing:&resizing] >= 0;
    }
    return [self controlAt:point] >= 0;
}
- (NSInteger)editControlAt:(CGPoint)p resizing:(BOOL *)resizing {
    // A selected control wins overlaps; every resize handle remains a separate target.
    *resizing = NO;
    for (NSInteger index = -1; index < DmControlCount; index++) {
        NSInteger c = index < 0 ? _selectedControl : index;
        CGPoint corner = CGPointMake(CGRectGetMaxX(_editRect[c]), CGRectGetMaxY(_editRect[c]));
        if (hypot(p.x - corner.x, p.y - corner.y) <= 19) { *resizing = YES; return c; }
    }
    if (CGRectContainsPoint(_editRect[_selectedControl], p)) return _selectedControl;
    NSInteger closest = -1; CGFloat best = CGFLOAT_MAX;
    for (NSInteger c = 0; c < DmControlCount; c++) if (CGRectContainsPoint(_editRect[c], p)) {
        CGPoint center = [self controlCenter:c]; CGFloat distance = hypot(p.x - center.x, p.y - center.y);
        if (distance < best) { closest = c; best = distance; }
    }
    return closest;
}
- (uint64_t)faceAt:(CGPoint)p {
    uint64_t bits = 0;
    for (int b = 0; b < 4; b++) if ([self hit:b point:p padding:5 * self.unit]) bits |= 1ull << b;
    return bits;
}
- (uint64_t)dpadAt:(CGPoint)p {
    CGPoint local = CGPointApplyAffineTransform(p, CGAffineTransformInvert(_transform[DmControlDpad]));
    if (hypot(local.x, local.y) < 12) return 0;
    double a = atan2(-local.y, local.x) * 180 / M_PI; uint64_t m = 0;
    if (a > -67.5 && a < 67.5) m |= 1ull << B_RIGHT;
    if (a > 22.5 && a < 157.5) m |= 1ull << B_UP;
    if (a > 112.5 || a < -112.5) m |= 1ull << B_LEFT;
    if (a < -22.5 && a > -157.5) m |= 1ull << B_DOWN;
    return m;
}
- (CGPoint)stickOffset:(int)side {
    if (!_stickTouch[side]) return CGPointZero;
    CGPoint p = CGPointApplyAffineTransform(_stickNow[side], CGAffineTransformInvert(_transform[DmControlLeftStick + side]));
    CGFloat length = hypot(p.x, p.y); if (length > 66) { p.x *= 66 / length; p.y *= 66 / length; } return p;
}
- (void)recompute {
    uint64_t buttons = 0;
    for (UITouch *t in _faceTouches) buttons |= [_faceTouches objectForKey:t].unsignedLongLongValue;
    for (UITouch *t in _owners) {
        unsigned v = [_owners objectForKey:t].unsignedIntValue;
        if ((v & 255) == C_BUTTON) buttons |= 1ull << (v >> 8);
        if ((v & 255) == C_DPAD) buttons |= [self dpadAt:[t locationInView:self]];
    }
    int32_t axes[4] = {0};
    for (int side = 0; side < 2; side++) {
        DmStickMode mode = side ? _profile.rightMode : _profile.leftMode;
        if (mode == DmStickJoystick) {
            // Rotation changes the visible shape, while stick movement follows screen directions.
            CGPoint c = [self controlCenter:DmControlLeftStick + side];
            double radius = 66 * self.unit * [_profile styleForControl:DmControlLeftStick + side].scale * 0.8;
            if (_stickTouch[side]) dm_pad_axis((_stickNow[side].x - c.x) / radius, (c.y - _stickNow[side].y) / radius, 0.1, &axes[side * 2], &axes[side * 2 + 1]);
            if (side) dm_camera_axis_tune(axes[2] / 32767.0, axes[3] / 32767.0, _profile.lookSensitivity,
                                         _profile.lookInvertX, _profile.lookInvertY, &axes[2], &axes[3]);
        }
    }
    pthread_mutex_lock(&g_mu); g_touch_btn = buttons; memcpy(g_touch_axis, axes, sizeof axes); pthread_mutex_unlock(&g_mu);
    publish(); [self refresh:buttons];
}
- (void)publishSwipe:(int)side {
    double dx, dy;
    dm_camera_swipe_take(&_swipe[side], &dx, &dy);
    double gain = side ? fmax(0.05, fmin(3, _profile.lookSensitivity)) : 1;
    double scale = side ? 200 : 600;
    double x = dx / scale * gain, y = -dy / scale * gain;
    if (side && _profile.lookInvertX) x = -x;
    if (side && _profile.lookInvertY) y = -y;
    dm_input_swipe_add(side, x, y);
}
- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (_editingControls) {
        if (_editTouch) return;
        UITouch *t = touches.anyObject; CGPoint p = [t locationInView:self];
        BOOL resizing = NO; NSInteger c = [self editControlAt:p resizing:&resizing];
        if (c >= 0) {
            self.selectedControl = c; _editTouch = t; CGPoint center = [self controlCenter:c];
            _editOffset = CGPointMake(p.x - center.x, p.y - center.y);
            _editResizing = resizing;
            _resizeStartScale = [_profile styleForControl:c].scale;
            _resizeCenter = center;
            _resizeVector = CGPointMake(p.x - center.x, p.y - center.y);
        } return;
    }
    if (_inputSuspended || !_foreground) return;
    for (UITouch *t in touches) {
        CGPoint p = [t locationInView:self]; NSInteger c = [self controlAt:p];
        if (c >= 0 && c < 4) { [_owners setObject:@(C_FACE) forKey:t]; [_faceTouches setObject:@([self faceAt:p]) forKey:t]; }
        else if (c >= 4 && c < 12) [_owners setObject:@(C_BUTTON | (c << 8)) forKey:t];
        else if (c == DmControlDpad) [_owners setObject:@(C_DPAD) forKey:t];
        else if (c >= DmControlLeftStick) {
            int side = (int)c - DmControlLeftStick;
            if (!_stickTouch[side]) { _stickTouch[side] = t; _stickNow[side] = p; [_owners setObject:@(C_STICK | (side << 8)) forKey:t]; }
        } else {
            int side = _profile.leftMode == DmStickSwipe && p.x < CGRectGetMidX(self.bounds) ? 0 : 1;
            DmStickMode mode = side ? _profile.rightMode : _profile.leftMode;
            if (mode == DmStickSwipe && !_swipeTouch[side]) {
                _swipeTouch[side] = t; dm_camera_swipe_begin(&_swipe[side], p.x, p.y);
                [_owners setObject:@(C_SWIPE | (side << 8)) forKey:t];
            }
        }
    }
    [self recompute];
}
- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    for (UITouch *t in touches) {
        CGPoint p = [t locationInView:self];
        if (_editingControls) {
            if (t == _editTouch) {
                if (_editResizing) {
                    CGFloat startLength = MAX(12, hypot(_resizeVector.x, _resizeVector.y));
                    CGFloat ratio = hypot(p.x - _resizeCenter.x, p.y - _resizeCenter.y) / startLength;
                    DmControlStyle s = [_profile styleForControl:_selectedControl]; s.scale = _resizeStartScale * ratio;
                    [_profile setStyle:s forControl:_selectedControl]; [self setNeedsLayout]; [self layoutIfNeeded];
                } else [self moveControl:_selectedControl toPoint:CGPointMake(p.x - _editOffset.x, p.y - _editOffset.y)];
                if (_selectionChanged) _selectionChanged();
            }
            continue;
        }
        unsigned v = [_owners objectForKey:t].unsignedIntValue; int side = v >> 8;
        if ((v & 255) == C_FACE) [_faceTouches setObject:@([self faceAt:p]) forKey:t];
        if ((v & 255) == C_STICK) _stickNow[side] = p;
        if ((v & 255) == C_SWIPE) {
            dm_camera_swipe_move(&_swipe[side], p.x, p.y); [self publishSwipe:side];
        }
    }
    if (!_editingControls) [self recompute];
}
- (void)endTouches:(NSSet<UITouch *> *)touches cancelled:(BOOL)cancelled {
    for (UITouch *t in touches) {
        if (t == _editTouch) { _editTouch = nil; _editResizing = NO; }
        [_owners removeObjectForKey:t]; [_faceTouches removeObjectForKey:t];
        for (int side = 0; side < 2; side++) {
            if (_stickTouch[side] == t) _stickTouch[side] = nil;
            if (_swipeTouch[side] == t) {
                if (cancelled) dm_input_swipe_cancel(side);
                else {
                    CGPoint p = [t locationInView:self];
                    dm_camera_swipe_move(&_swipe[side], p.x, p.y); [self publishSwipe:side];
                }
                _swipeTouch[side] = nil; dm_camera_swipe_end(&_swipe[side]);
            }
        }
    }
    if (!_editingControls) [self recompute];
}
- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event { [self endTouches:touches cancelled:NO]; }
- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event { [self endTouches:touches cancelled:YES]; }
- (void)resetTouches {
    [_owners removeAllObjects]; [_faceTouches removeAllObjects]; _editTouch = nil; _editResizing = NO;
    for (int i = 0; i < 2; i++) { _stickTouch[i] = _swipeTouch[i] = nil; dm_camera_swipe_end(&_swipe[i]); dm_input_swipe_cancel(i); }
    pthread_mutex_lock(&g_mu); g_touch_btn = 0; memset(g_touch_axis, 0, sizeof g_touch_axis); pthread_mutex_unlock(&g_mu);
    publish(); [self refresh:0];
}
- (void)updateVisibility {
#if TARGET_OS_SIMULATOR
    // Simulator may expose a virtual controller even when the player is using
    // mouse clicks; keep the on-screen controls visible so the game is usable.
    self.hidden = NO;
#else
    self.hidden = !_editingControls && _activeController && _profile.hideWithController;
#endif
}
- (void)setSelectedControl:(NSInteger)c {
    if (c < 0 || c >= DmControlCount) return;
    _selectedControl = c; [self setNeedsLayout]; if (_selectionChanged) _selectionChanged();
}
- (void)beginEditingControls {
    if (_editingControls) return;
    _savedProfile = [_profile copy]; _editingControls = YES;
    [self resetTouches]; clearPad(); [self updateVisibility]; [self setNeedsLayout];
}
- (void)finishEditingControlsSaving:(BOOL)save {
    if (!_editingControls) return;
    if (save) [_profile save]; else _profile = _savedProfile;
    _savedProfile = nil; _editingControls = NO; [self profileChanged];
}
- (void)profileChanged {
    [self resetTouches]; clearPad(); [self updateVisibility]; [self setNeedsLayout];
    if (!_editingControls) { [_profile save]; [self readController]; }
}
- (void)setInputSuspended:(BOOL)suspended {
    _inputSuspended = suspended; if (suspended) { vibration_cancel_pending(); [self stopVibration]; } [self resetTouches]; clearPad(); if (!suspended) [self readController];
}
- (void)resignActive { _foreground = NO; vibration_cancel_pending(); [self stopVibration]; [self resetTouches]; clearPad(); }
- (void)applicationWillTerminate:(NSNotification *)notification { (void)notification; vibration_cancel_pending(); [self stopVibration]; }
- (void)becomeActive { _foreground = YES; [self padsChanged]; }
- (void)didMoveToWindow { [super didMoveToWindow]; if (!self.window) { vibration_cancel_pending(); [self stopVibration]; [self resetTouches]; clearPad(); } }

- (void)prepareHapticsForController:(GCController *)controller {
    if (@available(iOS 14.0, *)) {
        atomic_store(&_hapticsSupported, 0);
        atomic_store(&g_gamepad_haptics_ready, 0);
        atomic_store(&g_gamepad_haptics_render_logged, 0);
        NSError *error = nil;
        _hapticsEngine = [controller.haptics createEngineWithLocality:GCHapticsLocalityDefault];
        if (!_hapticsEngine) {
            DM_LOG_WARN("controller", "Could not create controller haptics engine");
            return;
        }
        __weak CHHapticEngine *weakEngine = _hapticsEngine;
        _hapticsEngine.playsHapticsOnly = YES;
        __weak DmGamepad *weakSelf = self;
        _hapticsEngine.stoppedHandler = ^(CHHapticEngineStoppedReason reason) {
            dispatch_async(dispatch_get_main_queue(), ^{
                DmGamepad *self = weakSelf;
                CHHapticEngine *engine = weakEngine;
                if (!self || !engine || self->_hapticsEngine != engine) return;
                self->_hapticsPlaying = NO;
                if (reason == CHHapticEngineStoppedReasonNotifyWhenFinished) return;
                self->_hapticsPlayer = nil;
                atomic_store(&self->_hapticsSupported, 0);
                atomic_store(&g_gamepad_haptics_ready, 0);
                DM_LOG_WARN("controller", "Controller haptics engine stopped: reason=%ld", (long)reason);
                if (self->_activeController == controller && self->_foreground &&
                    !self->_inputSuspended && self.window) {
                    self->_hapticsEngine = nil;
                    [self prepareHapticsForController:controller];
                }
            });
        };
        _hapticsEngine.resetHandler = ^{
            dispatch_async(dispatch_get_main_queue(), ^{
                DmGamepad *self = weakSelf;
                CHHapticEngine *engine = weakEngine;
                if (self && engine && self->_hapticsEngine == engine &&
                    self->_activeController == controller) {
                    [self discardHaptics];
                    [self prepareHapticsForController:controller];
                }
            });
        };
        if (![_hapticsEngine startAndReturnError:&error]) {
            DM_LOG_ERROR("controller", "Could not start controller haptics engine: %s", error.localizedDescription.UTF8String ?: "unknown error");
            _hapticsEngine = nil;
            atomic_store(&_hapticsSupported, 0);
            atomic_store(&g_gamepad_haptics_ready, 0);
            return;
        }
        // Dynamic intensity is multiplicative and sharpness is additive. Use
        // neutral event values so the live controls can represent the full range.
        CHHapticEventParameter *intensity = [[CHHapticEventParameter alloc] initWithParameterID:CHHapticEventParameterIDHapticIntensity value:1.0];
        CHHapticEventParameter *sharpness = [[CHHapticEventParameter alloc] initWithParameterID:CHHapticEventParameterIDHapticSharpness value:0.0];
        CHHapticEventParameter *sustained = [[CHHapticEventParameter alloc] initWithParameterID:CHHapticEventParameterIDSustained value:1.0];
        CHHapticEvent *event = [[CHHapticEvent alloc] initWithEventType:CHHapticEventTypeHapticContinuous parameters:@[intensity, sharpness, sustained] relativeTime:0 duration:GCHapticDurationInfinite];
        CHHapticPattern *pattern = [[CHHapticPattern alloc] initWithEvents:@[event] parameters:@[] error:&error];
        _hapticsPlayer = pattern ? [_hapticsEngine createAdvancedPlayerWithPattern:pattern error:&error] : nil;
        if (!_hapticsPlayer)
            DM_LOG_ERROR("controller", "Could not create controller haptics player: %s", error.localizedDescription.UTF8String ?: "unknown error");
        else {
            atomic_store(&_hapticsSupported, 1);
            atomic_store(&g_gamepad_haptics_ready, 1);
            DM_LOG_INFO("controller", "Controller haptics engine and player ready");
        }
    }
}
- (void)discardHaptics {
    [self stopVibration];
    [_hapticsEngine stopWithCompletionHandler:nil];
    _hapticsEngine = nil;
    _hapticsPlayer = nil;
    _hapticsPlaying = NO;
    atomic_store(&_hapticsSupported, 0);
    atomic_store(&g_gamepad_haptics_ready, 0);
    atomic_store(&g_gamepad_haptics_render_logged, 0);
}
- (BOOL)vibrationSupported {
    return atomic_load(&g_gamepad_vibration_enabled) && atomic_load(&_hapticsSupported) &&
        _hapticsEngine != nil && _hapticsPlayer != nil;
}
- (void)applyVibrationFrame:(DmVibrationFrame)frame {
    if (!atomic_load(&g_gamepad_vibration_enabled)) { [self stopVibration]; return; }
    if (!_foreground || _inputSuspended || !_activeController || !self.window) { [self stopVibration]; return; }
    DmVibrationHapticsParameters parameters = dm_vibration_haptics_parameters(
        frame.low_amplitude, frame.low_frequency,
        frame.high_amplitude, frame.high_frequency);
    if (!parameters.intensity) { [self stopVibration]; return; }
    if (!atomic_load(&_hapticsSupported) || !_hapticsEngine || !_hapticsPlayer)
        [self prepareHapticsForController:_activeController];
    if (!_hapticsEngine || !_hapticsPlayer) return;
    NSError *error = nil;
    if (![_hapticsEngine startAndReturnError:&error]) {
        DM_LOG_ERROR("controller", "Could not restart controller haptics engine: %s", error.localizedDescription.UTF8String ?: "unknown error");
        atomic_store(&_hapticsSupported, 0);
        atomic_store(&g_gamepad_haptics_ready, 0);
        return;
    }
    CHHapticDynamicParameter *parameter = [[CHHapticDynamicParameter alloc] initWithParameterID:CHHapticDynamicParameterIDHapticIntensityControl value:parameters.intensity relativeTime:0];
    CHHapticDynamicParameter *sharpness = [[CHHapticDynamicParameter alloc] initWithParameterID:CHHapticDynamicParameterIDHapticSharpnessControl value:parameters.sharpness relativeTime:0];
    if (!_hapticsPlaying) _hapticsPlaying = [_hapticsPlayer startAtTime:CHHapticTimeImmediate error:&error];
    if (!_hapticsPlaying) {
        DM_LOG_ERROR("controller", "Could not start controller haptics player: %s", error.localizedDescription.UTF8String ?: "unknown error");
        atomic_store(&_hapticsSupported, 0);
        atomic_store(&g_gamepad_haptics_ready, 0);
        return;
    }
    if (![_hapticsPlayer sendParameters:@[parameter, sharpness] atTime:CHHapticTimeImmediate error:&error])
        DM_LOG_ERROR("controller", "Could not update controller haptics: %s", error.localizedDescription.UTF8String ?: "unknown error");
    else if (!atomic_exchange(&g_gamepad_haptics_render_logged, 1))
        DM_LOG_INFO("controller", "Core Haptics parameters accepted: sequence=%llu timestamp_ns=%llu intensity=%.3f sharpness=%.3f",
                    (unsigned long long)frame.sequence,
                    (unsigned long long)frame.timestamp_ns,
                    parameters.intensity, parameters.sharpness);
}
- (void)stopVibration {
    NSError *error = nil;
    if (_hapticsPlayer && ![_hapticsPlayer stopAtTime:CHHapticTimeImmediate error:&error])
        DM_LOG_WARN("controller", "Could not stop controller haptics: %s", error.localizedDescription.UTF8String ?: "unknown error");
    _hapticsPlaying = NO;
}
- (void)setVibrationEnabled:(BOOL)enabled {
    atomic_store(&g_gamepad_vibration_enabled, enabled);
    if (!enabled) { vibration_cancel_pending(); [self stopVibration]; }
}

// Controller handlers run on the main queue, so selection and settings never race callbacks.
- (void)readController {
    GCExtendedGamepad *g = _activeController.extendedGamepad;
    if (!g || !_foreground || _inputSuspended || _editingControls || !self.window) { clearPad(); return; }
    int kind = DM_PADKIND_NINTENDO;
    if (_profile.faceMapping == DmFaceLetters) kind = DM_PADKIND_XBOX;
    if (_profile.faceMapping == DmFaceAutomatic) kind = dm_padmap_kind(_activeController.productCategory.UTF8String, _activeController.vendorName.UTF8String);
    uint64_t buttons = dm_padmap_face(kind, g.buttonA.isPressed, g.buttonB.isPressed, g.buttonX.isPressed, g.buttonY.isPressed);
    #define K(button, bit) if ((button).isPressed) buttons |= 1ull << (bit)
    K(g.leftShoulder, B_L); K(g.rightShoulder, B_R); K(g.leftTrigger, B_ZL); K(g.rightTrigger, B_ZR);
    K(g.buttonMenu, B_PLUS); K(g.buttonOptions, B_MINUS);
    K(g.leftThumbstickButton, B_LS); K(g.rightThumbstickButton, B_RS);
    K(g.dpad.left, B_LEFT); K(g.dpad.up, B_UP); K(g.dpad.right, B_RIGHT); K(g.dpad.down, B_DOWN);
    #undef K
    int32_t axes[4];
    dm_pad_axis(g.leftThumbstick.xAxis.value, g.leftThumbstick.yAxis.value, _profile.deadzone, &axes[0], &axes[1]);
    dm_pad_axis(g.rightThumbstick.xAxis.value, g.rightThumbstick.yAxis.value, _profile.deadzone, &axes[2], &axes[3]);
    pthread_mutex_lock(&g_mu); g_pad_btn = buttons; memcpy(g_pad_axis, axes, sizeof axes); pthread_mutex_unlock(&g_mu); publish();
}
- (NSArray<NSString *> *)controllerNames {
    NSMutableArray *names = [NSMutableArray new];
    for (GCController *c in _controllers) [names addObject:c.vendorName ?: c.productCategory ?: @"Controller / 手柄"];
    return names;
}
- (NSInteger)activeControllerIndex { return _activeController ? [_controllers indexOfObjectIdenticalTo:_activeController] : NSNotFound; }
- (NSString *)controllerStatus {
    if (!_activeController) return @"No controller connected / 未连接手柄";
    return [NSString stringWithFormat:@"%@ (%ld) / 已连接", _activeController.vendorName ?: _activeController.productCategory, (long)_controllers.count];
}
- (void)selectController:(NSInteger)index {
    if (index < 0 || index >= (NSInteger)_controllers.count) return;
    vibration_cancel_pending();
    [self discardHaptics];
    [self resetTouches]; clearPad(); _activeController = _controllers[index];
    if (_activeController.haptics) [self prepareHapticsForController:_activeController];
    [self updateVisibility]; [self readController];
    [NSNotificationCenter.defaultCenter postNotificationName:DmControllerChangedNotification object:self];
}
- (void)padsChanged {
    if (!NSThread.isMainThread) { dispatch_async(dispatch_get_main_queue(), ^{ [self padsChanged]; }); return; }
    for (GCController *c in _controllers) c.extendedGamepad.valueChangedHandler = nil;
    NSMutableArray *controllers = [NSMutableArray new];
    for (GCController *c in GCController.controllers) if (c.extendedGamepad) [controllers addObject:c];
    _controllers = controllers;
    if (![_controllers containsObject:_activeController]) _activeController = _controllers.firstObject;
    vibration_cancel_pending(); [self discardHaptics];
    if (_activeController.haptics) [self prepareHapticsForController:_activeController];
    __weak DmGamepad *weakSelf = self;
    for (GCController *c in _controllers) {
        c.handlerQueue = dispatch_get_main_queue();
        __weak GCController *weakController = c;
        c.extendedGamepad.valueChangedHandler = ^(GCExtendedGamepad *g, GCControllerElement *element) {
            DmGamepad *view = weakSelf; if (view && weakController == view->_activeController) [view readController];
        };
    }
    [self resetTouches]; clearPad(); [self updateVisibility]; [self readController];
    [NSNotificationCenter.defaultCenter postNotificationName:DmControllerChangedNotification object:self];
}
- (void)dealloc {
    vibration_cancel_pending();
    [self discardHaptics];
    dm_input_swipe_cancel(0); dm_input_swipe_cancel(1);
    [NSNotificationCenter.defaultCenter removeObserver:self];
    for (GCController *c in _controllers) c.extendedGamepad.valueChangedHandler = nil;
}
@end
UIView *dm_gamepad_view(CGRect frame) {
    DmGamepad *v = [[DmGamepad alloc] initWithFrame:frame];
    g_view = v;
    atomic_store(&g_gamepad_vibration_enabled, DmAppVibrationEnabled());
    return v;
}
void dm_gamepad_reset(void) {
    dispatch_async(dispatch_get_main_queue(), ^{ [g_view resignActive]; });
    clearPad();
}
void dm_gamepad_vibration(DmVibrationFrame frame) {
    pthread_mutex_lock(&g_vibration_queue_mu);
    dm_vibration_queue_push(&g_vibration_queue, &frame);
    int schedule = !g_vibration_queue.drain_scheduled;
    if (schedule) g_vibration_queue.drain_scheduled = 1;
    pthread_mutex_unlock(&g_vibration_queue_mu);
    if (!schedule) return;
    dispatch_async(dispatch_get_main_queue(), ^{ vibration_drain(); });
}
static void vibration_drain(void) {
    while (1) {
        pthread_mutex_lock(&g_vibration_queue_mu);
        DmVibrationFrame frame = {0};
        int have = dm_vibration_queue_pop(&g_vibration_queue, &frame);
        if (!have) {
            g_vibration_queue.drain_scheduled = 0;
            g_vibration_timeline = (DmVibrationTimeline){0};
        }
        pthread_mutex_unlock(&g_vibration_queue_mu);
        if (!have) return;
        uint64_t now = vibration_now_ns();
        uint64_t target = dm_vibration_timeline_schedule(&g_vibration_timeline, &frame, now);
        if (target > now) {
            uint64_t generation = atomic_load(&g_vibration_generation);
            DmVibrationFrame scheduled = frame;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(target - now)),
                           dispatch_get_main_queue(), ^{
                if (atomic_load(&g_vibration_generation) != generation) return;
                [g_view applyVibrationFrame:scheduled];
                vibration_drain();
            });
            return;
        }
        [g_view applyVibrationFrame:frame];
    }
}
int dm_gamepad_vibration_supported(void) {
    return atomic_load(&g_gamepad_vibration_enabled) &&
        atomic_load(&g_gamepad_haptics_ready);
}
void dm_gamepad_vibration_enabled(int enabled) {
    atomic_store(&g_gamepad_vibration_enabled, enabled != 0);
    dispatch_async(dispatch_get_main_queue(), ^{
        [g_view setVibrationEnabled:enabled != 0];
    });
}
