#import "../metal_surface_mac.h"
#include <assert.h>
#include <math.h>

int main(void) { @autoreleasepool {
    [NSApplication sharedApplication];
    NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 640, 360)
        styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskResizable
        backing:NSBackingStoreBuffered defer:NO];
    window.releasedWhenClosed = NO;
    NSView *root = window.contentView;
    root.wantsLayer = YES;
    CAMetalLayer *metal = [CAMetalLayer layer];
    DmMetalSurface *surface = [[DmMetalSurface alloc] initWithFrame:root.bounds];
    surface.layer = metal;
    surface.wantsLayer = YES;
    surface.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [root addSubview:surface];
    NSTextField *overlay = [NSTextField labelWithString:@"30 FPS"];
    overlay.frame = NSMakeRect(400, 300, 200, 30);
    [root addSubview:overlay];
    assert(root.layer != metal && surface.layer == metal);
    assert(overlay.superview == surface.superview && surface.subviews.count == 0);
    assert([surface hitTest:NSMakePoint(10, 10)] == nil);
    assert(metal.delegate != (id)root && metal.delegate != (id)surface);

    for (int i = 0; i < 12; ++i) {
        NSSize size = i & 1 ? NSMakeSize(1280, 720) : NSMakeSize(640, 360);
        [window setContentSize:size];
        [root layoutSubtreeIfNeeded];
        [surface viewDidChangeBackingProperties];
        overlay.stringValue = [NSString stringWithFormat:@"%d FPS", 30 + i];
        [root setNeedsDisplay:YES];
        [root displayIfNeeded];
        CGFloat scale = window.backingScaleFactor;
        assert(surface.layer == metal && root.layer != metal);
        assert(fabs(surface.bounds.size.width - size.width) < 1);
        assert(fabs(surface.bounds.size.height - size.height) < 1);
        assert(fabs(metal.drawableSize.width - size.width * scale) < 1);
        assert(fabs(metal.drawableSize.height - size.height * scale) < 1);
        assert(fabs(metal.contentsScale - scale) < .01);
        assert(metal.delegate != (id)root && metal.delegate != (id)surface);
    }
    [window close];
    puts("Metal surface: native overlay isolation, hit testing, resize and backing scale passed");
    return 0;
} }
