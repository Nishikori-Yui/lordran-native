#import <UIKit/UIKit.h>
#import "DmControlProfile.h"

FOUNDATION_EXPORT NSNotificationName const DmControllerChangedNotification;

@interface DmGamepad : UIView
@property (nonatomic, readonly) DmControlProfile *profile;
@property (nonatomic, readonly, getter=isEditingControls) BOOL editingControls;
@property (nonatomic) NSInteger selectedControl;
@property (nonatomic, copy) void (^selectionChanged)(void);
@property (nonatomic, readonly) NSString *controllerStatus;
@property (nonatomic, readonly) NSArray<NSString *> *controllerNames;
@property (nonatomic, readonly) NSInteger activeControllerIndex;
- (void)selectController:(NSInteger)index;
- (void)beginEditingControls;
- (void)finishEditingControlsSaving:(BOOL)save;
- (void)profileChanged;
- (CGPoint)controlCenter:(NSInteger)control;
- (BOOL)hasVisibleControlAtPoint:(CGPoint)point;
- (CGPoint)controlResizeHandleCenter:(NSInteger)control;
- (void)moveControl:(NSInteger)control toPoint:(CGPoint)point;
- (void)setInputSuspended:(BOOL)suspended;
@end

UIView *dm_gamepad_view(CGRect frame);
void dm_gamepad_reset(void);
