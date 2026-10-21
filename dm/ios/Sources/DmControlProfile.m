#import "DmControlProfile.h"
#include <math.h>

static NSString *const kProfileKey = @"DmControlProfile.v1";
static CGFloat number(id value, CGFloat fallback, CGFloat low, CGFloat high) {
    if (![value isKindOfClass:NSNumber.class] || !isfinite([value doubleValue])) return fallback;
    return fmax(low, fmin(high, [value doubleValue]));
}
static DmControlStyle validated(DmControlStyle s) {
    s.x = isfinite(s.x) ? fmax(0, fmin(1, s.x)) : 0.5;
    s.y = isfinite(s.y) ? fmax(0, fmin(1, s.y)) : 0.5;
    s.scale = isfinite(s.scale) ? fmax(0.5, fmin(2, s.scale)) : 1;
    s.angle = isfinite(s.angle) ? fmax(-180, fmin(180, s.angle)) : 0;
    s.opacity = isfinite(s.opacity) ? fmax(0.1, fmin(1, s.opacity)) : 1;
    if (s.shape < DmShapeDefault || s.shape > DmShapeRounded) s.shape = DmShapeDefault;
    return s;
}
DmControlStyle DmControlStyleDefault(void) {
    return (DmControlStyle){.x = 0.5, .y = 0.5, .scale = 1, .opacity = 1};
}
NSString *DmControlName(NSInteger c) {
    static NSArray *names;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        names = @[@"A", @"B", @"X", @"Y", @"L3", @"R3", @"L", @"R", @"ZL", @"ZR",
                  @"+", @"−", @"D-pad / 十字键", @"Left stick / 左摇杆", @"Right stick / 右摇杆"];
    });
    return c >= 0 && c < DmControlCount ? names[c] : @"";
}
@implementation DmControlProfile {
    DmControlStyle _styles[DmControlCount];
}
- (instancetype)initWithDictionary:(NSDictionary *)dictionary defaultFull:(BOOL)full {
    if ((self = [super init])) {
        NSDictionary *d = [dictionary isKindOfClass:NSDictionary.class] ? dictionary : @{};
        _leftMode = (DmStickMode)number(d[@"left"], DmStickJoystick, 0, 1);
        _rightMode = (DmStickMode)number(d[@"right"], DmStickSwipe, 0, 1);
        _faceMapping = (DmFaceMapping)number(d[@"mapping"], DmFacePosition, 0, 2);
        _deadzone = number(d[@"deadzone"], 0.12, 0.05, 0.35);
        BOOL legacyLook = number(d[@"version"], 1, 1, 2) < 2 &&
                          [d[@"look_sensitivity"] isKindOfClass:NSNumber.class] &&
                          isfinite([d[@"look_sensitivity"] doubleValue]);
        _lookSensitivity = legacyLook ? number(d[@"look_sensitivity"], 1, 0.25, 3) / 3 :
                                       number(d[@"look_sensitivity"], 1, 0.05, 3);
        _lookInvertX = number(d[@"look_invert_x"], NO, 0, 1) != 0;
        _lookInvertY = number(d[@"look_invert_y"], NO, 0, 1) != 0;
        _hideWithController = number(d[@"hide"], YES, 0, 1) != 0;
        _fullLayout = number(d[@"full"], full, 0, 1) != 0;
        NSArray *styles = [d[@"styles"] isKindOfClass:NSArray.class] ? d[@"styles"] : @[];
        for (NSInteger c = 0; c < DmControlCount; c++) {
            DmControlStyle s = DmControlStyleDefault();
            NSDictionary *v = c < (NSInteger)styles.count && [styles[c] isKindOfClass:NSDictionary.class] ? styles[c] : @{};
            s.positioned = [v[@"x"] isKindOfClass:NSNumber.class] && isfinite([v[@"x"] doubleValue]) &&
                           [v[@"y"] isKindOfClass:NSNumber.class] && isfinite([v[@"y"] doubleValue]);
            s.x = number(v[@"x"], 0.5, 0, 1); s.y = number(v[@"y"], 0.5, 0, 1);
            s.scale = number(v[@"scale"], 1, 0.5, 2);
            s.angle = number(v[@"angle"], 0, -180, 180);
            s.opacity = number(v[@"opacity"], 1, 0.1, 1);
            s.shape = (DmControlShape)number(v[@"shape"], DmShapeDefault, 0, DmShapeRounded);
            _styles[c] = s;
        }
    }
    return self;
}
+ (instancetype)loadWithDefaultFull:(BOOL)full {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSNumber *legacy = [defaults objectForKey:@"DmPadLayout"];
    return [[self alloc] initWithDictionary:[defaults objectForKey:kProfileKey] defaultFull:legacy ? legacy.boolValue : full];
}
- (DmControlStyle)styleForControl:(NSInteger)c { return c >= 0 && c < DmControlCount ? _styles[c] : DmControlStyleDefault(); }
- (void)setStyle:(DmControlStyle)s forControl:(NSInteger)c { if (c >= 0 && c < DmControlCount) _styles[c] = validated(s); }
- (NSDictionary *)dictionary {
    NSMutableArray *styles = [NSMutableArray new];
    for (NSInteger c = 0; c < DmControlCount; c++) {
        DmControlStyle s = validated(_styles[c]);
        NSMutableDictionary *v = [@{@"scale": @(s.scale), @"angle": @(s.angle), @"opacity": @(s.opacity), @"shape": @(s.shape)} mutableCopy];
        if (s.positioned) { v[@"x"] = @(s.x); v[@"y"] = @(s.y); }
        [styles addObject:v];
    }
    return @{@"version": @2, @"styles": styles, @"left": @(_leftMode), @"right": @(_rightMode),
             @"look_sensitivity": @(number(@(_lookSensitivity), 1, 0.05, 3)),
             @"look_invert_x": @(_lookInvertX), @"look_invert_y": @(_lookInvertY),
             @"mapping": @(_faceMapping), @"deadzone": @(_deadzone), @"hide": @(_hideWithController), @"full": @(_fullLayout)};
}
- (id)copyWithZone:(NSZone *)zone { return [[[self class] allocWithZone:zone] initWithDictionary:self.dictionary defaultFull:_fullLayout]; }
- (void)save { [NSUserDefaults.standardUserDefaults setObject:self.dictionary forKey:kProfileKey]; }
- (void)resetStyles { for (NSInteger c = 0; c < DmControlCount; c++) _styles[c] = DmControlStyleDefault(); }
@end

CGPoint DmControlCenter(DmControlStyle s, CGPoint fallback, CGRect safe, CGSize halfSize) {
    CGPoint p = s.positioned ? CGPointMake(safe.origin.x + s.x * safe.size.width, safe.origin.y + s.y * safe.size.height) : fallback;
    // The rotated bounding box, including a drop's tip, must remain reachable.
    CGFloat a = s.angle * M_PI / 180, cs = fabs(cos(a)), sn = fabs(sin(a));
    CGFloat w = fmin(safe.size.width / 2, s.scale * (cs * halfSize.width + sn * halfSize.height));
    CGFloat h = fmin(safe.size.height / 2, s.scale * (sn * halfSize.width + cs * halfSize.height));
    p.x = fmax(CGRectGetMinX(safe) + w, fmin(CGRectGetMaxX(safe) - w, p.x));
    p.y = fmax(CGRectGetMinY(safe) + h, fmin(CGRectGetMaxY(safe) - h, p.y));
    return p;
}
CGAffineTransform DmControlTransform(DmControlStyle s, CGPoint center, CGFloat unit) {
    CGAffineTransform t = CGAffineTransformMakeTranslation(center.x, center.y);
    t = CGAffineTransformRotate(t, s.angle * M_PI / 180);
    return CGAffineTransformScale(t, unit * s.scale, unit * s.scale);
}
CGPathRef DmControlCreatePath(DmControlShape shape, CGSize r, CGFloat angle) {
    CGRect rect = CGRectMake(-r.width, -r.height, 2 * r.width, 2 * r.height);
    if (shape == DmShapeSquare) return CGPathCreateWithRect(rect, NULL);
    if (shape == DmShapeRounded) return CGPathCreateWithRoundedRect(rect, MIN(r.width, r.height) * 0.4, MIN(r.width, r.height) * 0.4, NULL);
    if (shape != DmShapeDrop) return CGPathCreateWithEllipseInRect(rect, NULL);
    CGFloat radius = MIN(r.width, r.height), d = radius * 1.45, th = acos(radius / d);
    CGPoint tip = CGPointMake(d * cos(angle), d * sin(angle));
    CGPoint p1 = CGPointMake(radius * cos(angle + th), radius * sin(angle + th));
    CGPoint p2 = CGPointMake(radius * cos(angle - th), radius * sin(angle - th));
    CGMutablePathRef p = CGPathCreateMutable();
    CGPathMoveToPoint(p, NULL, p2.x, p2.y);
    CGPathAddArcToPoint(p, NULL, tip.x, tip.y, p1.x, p1.y, 4);
    CGPathAddArc(p, NULL, 0, 0, radius, angle + th, angle - th + 2 * M_PI, false);
    CGPathCloseSubpath(p);
    return p;
}
BOOL DmControlHit(CGPathRef path, CGAffineTransform t, CGPoint point, CGFloat padding) {
    if (!path) return NO;
    CGPoint local = CGPointApplyAffineTransform(point, CGAffineTransformInvert(t));
    if (CGPathContainsPoint(path, NULL, local, false)) return YES;
    CGFloat scale = hypot(t.a, t.b);
    if (padding <= 0 || scale <= 0) return NO;
    CGPathRef stroke = CGPathCreateCopyByStrokingPath(path, NULL, 2 * padding / scale, kCGLineCapRound, kCGLineJoinRound, 2);
    BOOL hit = CGPathContainsPoint(stroke, NULL, local, false);
    CGPathRelease(stroke);
    return hit;
}
