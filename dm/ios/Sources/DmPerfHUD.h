#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@class DmGamepad;

@interface DmPerfHUD : UIControl
@property (nonatomic, weak, nullable) DmGamepad *gamepad;
- (void)attachToView:(UIView *)view belowSubview:(UIView *)sibling;
@end

NS_ASSUME_NONNULL_END
