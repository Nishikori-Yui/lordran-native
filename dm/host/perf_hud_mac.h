#import <Cocoa/Cocoa.h>
#import <Metal/Metal.h>

@interface DmMacPerfHUD : NSObject
- (instancetype)initWithWindow:(NSWindow *)window device:(id<MTLDevice>)device;
// 0 = compact, 1 = detailed, 2 = off.
@property(nonatomic) NSInteger mode;
@property(nonatomic, readonly) NSView *view;
@property(nonatomic, readonly) BOOL updating;
- (void)cycleMode:(id)sender;
- (BOOL)handleKeyEvent:(NSEvent *)event;
@end
