#pragma once
#import <Cocoa/Cocoa.h>
#import <QuartzCore/CAMetalLayer.h>

// A layer-hosting leaf; put native overlays in its parent, not this view.
@interface DmMetalSurface : NSView
@end
