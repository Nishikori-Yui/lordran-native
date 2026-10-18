#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

enum { DmControlDpad = 12, DmControlLeftStick, DmControlRightStick, DmControlCount };
typedef NS_ENUM(NSInteger, DmControlShape) {
    DmShapeDefault, DmShapeCircle, DmShapeSquare, DmShapeDrop, DmShapeRounded
};
typedef NS_ENUM(NSInteger, DmStickMode) { DmStickJoystick, DmStickSwipe };
typedef NS_ENUM(NSInteger, DmFaceMapping) { DmFacePosition, DmFaceAutomatic, DmFaceLetters };
typedef struct {
    BOOL positioned;
    CGFloat x, y, scale, angle, opacity;
    DmControlShape shape;
} DmControlStyle;

@interface DmControlProfile : NSObject <NSCopying>
@property (nonatomic) DmStickMode leftMode;
@property (nonatomic) DmStickMode rightMode;
@property (nonatomic) DmFaceMapping faceMapping;
@property (nonatomic) CGFloat deadzone;
@property (nonatomic) BOOL hideWithController;
@property (nonatomic) BOOL fullLayout;
- (instancetype)initWithDictionary:(NSDictionary *)dictionary defaultFull:(BOOL)full;
+ (instancetype)loadWithDefaultFull:(BOOL)full;
- (DmControlStyle)styleForControl:(NSInteger)control;
- (void)setStyle:(DmControlStyle)style forControl:(NSInteger)control;
- (NSDictionary *)dictionary;
- (void)save;
- (void)resetStyles;
@end

NSString *DmControlName(NSInteger control);
DmControlStyle DmControlStyleDefault(void);
CGPoint DmControlCenter(DmControlStyle style, CGPoint fallback, CGRect safe, CGSize halfSize);
CGAffineTransform DmControlTransform(DmControlStyle style, CGPoint center, CGFloat unit);
CGPathRef DmControlCreatePath(DmControlShape shape, CGSize halfSize, CGFloat dropAngle) CF_RETURNS_RETAINED;
BOOL DmControlHit(CGPathRef path, CGAffineTransform transform, CGPoint point, CGFloat padding);
