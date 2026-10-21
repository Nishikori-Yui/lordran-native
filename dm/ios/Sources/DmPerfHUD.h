#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface DmPerfHUD : UIControl
- (void)attachToView:(UIView *)view belowSubview:(UIView *)sibling;
@end

NS_ASSUME_NONNULL_END
