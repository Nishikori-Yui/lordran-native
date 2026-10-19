#import "../Sources/DmControlProfile.h"
#include <assert.h>
#include <math.h>
#include <stdio.h>

static BOOL near(CGFloat a, CGFloat b) { return fabs(a - b) < 0.0001; }
int main(void) {
    @autoreleasepool {
        DmControlProfile *p = [[DmControlProfile alloc] initWithDictionary:nil defaultFull:YES];
        assert(p.leftMode == DmStickJoystick && p.rightMode == DmStickSwipe && p.fullLayout);
        assert(p.faceMapping == DmFacePosition && p.hideWithController && near(p.deadzone, 0.12));
        assert(near(p.lookSensitivity, 1) && !p.lookInvertX && !p.lookInvertY);
        DmControlStyle s = [p styleForControl:0];
        assert(!s.positioned && near(s.scale, 1) && near(s.opacity, 1));
        NSDictionary *bad = @{@"left": @"swipe", @"right": @99, @"deadzone": @(NAN),
                              @"look_sensitivity": @(NAN), @"look_invert_x": @"yes", @"look_invert_y": @[],
                              @"styles": @[@{@"x": @(NAN), @"y": @0.2, @"scale": @99,
                                  @"opacity": @-2, @"angle": @-900, @"shape": @"square"}, @"bad"]};
        DmControlProfile *invalid = [[DmControlProfile alloc] initWithDictionary:bad defaultFull:NO];
        s = [invalid styleForControl:0];
        assert(!s.positioned && near(s.scale, 2) && near(s.opacity, 0.1) && near(s.angle, -180) && s.shape == DmShapeDefault);
        assert(near(invalid.deadzone, 0.12) && !invalid.fullLayout);
        assert(near(invalid.lookSensitivity, 1) && !invalid.lookInvertX && !invalid.lookInvertY);
        invalid = [[DmControlProfile alloc] initWithDictionary:@{@"look_sensitivity": @100} defaultFull:NO];
        assert(near(invalid.lookSensitivity, 3));
        invalid = [[DmControlProfile alloc] initWithDictionary:@{@"look_sensitivity": @-1} defaultFull:NO];
        assert(near(invalid.lookSensitivity, 0.25));
        invalid = [[DmControlProfile alloc] initWithDictionary:(id)@[] defaultFull:YES];
        assert(invalid.fullLayout);
        s = DmControlStyleDefault(); s.positioned = YES; s.x = 0.27; s.y = 0.68;
        s.scale = 1.4; s.angle = 43; s.opacity = 0.6; s.shape = DmShapeDrop;
        [p setStyle:s forControl:3]; p.leftMode = DmStickSwipe; p.rightMode = DmStickJoystick;
        p.faceMapping = DmFaceAutomatic; p.deadzone = 0.24; p.hideWithController = NO;
        p.lookSensitivity = 1.75; p.lookInvertX = p.lookInvertY = YES;
        NSData *data = [NSPropertyListSerialization dataWithPropertyList:p.dictionary format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil];
        assert(data);
        NSDictionary *roundtrip = [NSPropertyListSerialization propertyListWithData:data options:0 format:nil error:nil];
        DmControlProfile *restored = [[DmControlProfile alloc] initWithDictionary:roundtrip defaultFull:NO];
        DmControlStyle r = [restored styleForControl:3];
        assert(r.positioned && near(r.x, s.x) && near(r.y, s.y) && near(r.scale, s.scale));
        assert(near(r.angle, s.angle) && near(r.opacity, s.opacity) && r.shape == s.shape);
        assert(restored.leftMode == DmStickSwipe && restored.rightMode == DmStickJoystick);
        assert(!restored.hideWithController && restored.faceMapping == DmFaceAutomatic && near(restored.deadzone, 0.24));
        assert(near(restored.lookSensitivity, 1.75) && restored.lookInvertX && restored.lookInvertY);
        DmControlProfile *draft = [p copy];
        [draft resetStyles]; assert(![draft styleForControl:3].positioned);
        assert([p styleForControl:3].positioned);
        s = DmControlStyleDefault(); s.positioned = YES; s.x = 0; s.y = 1; s.scale = 2; s.angle = 90;
        CGPoint center = DmControlCenter(s, CGPointZero, CGRectMake(10, 20, 800, 300), CGSizeMake(30, 15));
        assert(near(center.x, 40) && near(center.y, 260));
        s = DmControlStyleDefault(); s.scale = 1.6; s.angle = 37;
        CGAffineTransform t = DmControlTransform(s, CGPointMake(210, 160), 0.9);
        for (NSInteger shape = DmShapeCircle; shape <= DmShapeRounded; shape++) {
            CGPathRef path = DmControlCreatePath(shape, CGSizeMake(25, 25), -M_PI_4);
            assert(DmControlHit(path, t, CGPointMake(210, 160), 0));
            CGPoint inside = CGPointApplyAffineTransform(CGPointMake(10, 0), t);
            CGPoint outside = CGPointApplyAffineTransform(CGPointMake(-40, 0), t);
            assert(DmControlHit(path, t, inside, 0));
            assert(!DmControlHit(path, t, outside, 4));
            CGPathRelease(path);
        }
        CGPathRef square = DmControlCreatePath(DmShapeSquare, CGSizeMake(25, 25), 0);
        CGPoint corner = CGPointApplyAffineTransform(CGPointMake(23, 23), t);
        assert(DmControlHit(square, t, corner, 0));
        CGPathRef circle = DmControlCreatePath(DmShapeCircle, CGSizeMake(25, 25), 0);
        assert(!DmControlHit(circle, t, corner, 0));
        CGPoint padded = CGPointApplyAffineTransform(CGPointMake(27, 0), t);
        assert(!DmControlHit(circle, t, padded, 0) && DmControlHit(circle, t, padded, 4));
        CGPathRef drop = DmControlCreatePath(DmShapeDrop, CGSizeMake(25, 25), 0);
        assert(DmControlHit(drop, CGAffineTransformIdentity, CGPointMake(33, 0), 0));
        assert(!DmControlHit(circle, CGAffineTransformIdentity, CGPointMake(33, 0), 0));
        CGPathRelease(drop); CGPathRelease(circle); CGPathRelease(square);
        puts("control profile: persistence, invalid settings, geometry and transformed hit tests passed");
    }
    return 0;
}
