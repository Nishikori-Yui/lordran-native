#import <Cocoa/Cocoa.h>

@interface DmMacCheats : NSObject
- (instancetype)initWithWindow:(NSWindow *)window;
- (BOOL)handleKeyEvent:(NSEvent *)event;
- (void)toggleMenu:(id)sender;
@property(nonatomic, readonly) BOOL visible;
@property(nonatomic, readonly) NSInteger selectedIndex;
@property(nonatomic, readonly) NSPanel *panel;
@end
