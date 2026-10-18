#import <UIKit/UIKit.h>
@class DmGamepad;

@interface DmControlOverlay : UIView
@property (nonatomic, weak) UIViewController *presenter;
@property (nonatomic, strong) DmGamepad *gamepad;
@property (nonatomic) BOOL showsFPS;
@property (nonatomic, copy) void (^fpsChanged)(BOOL visible);
@end
