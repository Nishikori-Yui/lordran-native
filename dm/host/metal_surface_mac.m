#import "metal_surface_mac.h"

// Keep AppKit/HUD invalidation off the manually presented Metal surface.
@implementation DmMetalSurface
- (NSView *)hitTest:(NSPoint)point { (void)point; return nil; }
- (void)resizeDrawable {
    CAMetalLayer *metal = (CAMetalLayer *)self.layer;
    CGFloat scale = self.window.backingScaleFactor ?: 1;
    metal.contentsScale = scale;
    metal.drawableSize = CGSizeMake(self.bounds.size.width * scale, self.bounds.size.height * scale);
}
- (void)setFrameSize:(NSSize)size { [super setFrameSize:size]; [self resizeDrawable]; }
- (void)viewDidMoveToWindow { [super viewDidMoveToWindow]; [self resizeDrawable]; }
- (void)viewDidChangeBackingProperties { [super viewDidChangeBackingProperties]; [self resizeDrawable]; }
@end

