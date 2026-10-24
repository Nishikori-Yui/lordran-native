#pragma once

#import <Cocoa/Cocoa.h>
#import <Metal/Metal.h>

@interface DmMacGraphicsSettings : NSObject
- (instancetype)initWithWindow:(NSWindow *)window device:(id<MTLDevice>)device;
@end

// Apply saved settings before the guest creates its resolution-dependent resources.
void dm_mac_graphics_apply(void);
unsigned dm_mac_graphics_resolution_percent(void);
unsigned dm_mac_graphics_msaa(void);
unsigned dm_mac_graphics_anisotropy(void);
