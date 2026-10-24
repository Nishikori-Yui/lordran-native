#import "graphics_settings_mac.h"
#import "dm_log.h"
#include "../gfx/nvn/nvn_mtl.h"
#ifdef MAC_GRAPHICS_TEST_STUB
void mtl_set_graphics_overrides(unsigned msaa, unsigned anisotropy) { (void)msaa; (void)anisotropy; }
void mtl_set_spatial_upscaling(int on) { (void)on; }
int mtl_spatial_upscaling_supported(void) { return 0; }
int mtl_spatial_upscaling_supported_on_device(id<MTLDevice> device) { (void)device; return 0; }
#endif
#include <stdlib.h>
#include <strings.h>

static NSString *const kResolution = @"DmMacGraphicsResolutionPercent";
static NSString *const kMSAA = @"DmMacGraphicsMSAA";
static NSString *const kAnisotropy = @"DmMacGraphicsAnisotropy";
static NSString *const kUpscaling = @"DmMacGraphicsUpscaling";

static void register_defaults(void) {
    [NSUserDefaults.standardUserDefaults registerDefaults:@{
        kResolution: @100,
        kMSAA: @0,
        kAnisotropy: @0,
        kUpscaling: @0,
    }];
}

static BOOL uses_chinese(void) {
    const char *language = getenv("DM_LANG");
    return language && !strncasecmp(language, "zh", 2);
}

static NSString *text(NSString *english, NSString *chinese) {
    return uses_chinese() ? chinese : english;
}

unsigned dm_mac_graphics_resolution_percent(void) {
    register_defaults();
    NSInteger value = [NSUserDefaults.standardUserDefaults integerForKey:kResolution];
    return value == 50 || value == 75 || value == 125 ? (unsigned)value : 100;
}

static unsigned saved_msaa(void) {
    register_defaults();
    NSInteger value = [NSUserDefaults.standardUserDefaults integerForKey:kMSAA];
    return value == 2 || value == 4 || value == 8 ? (unsigned)value : 0;
}

unsigned dm_mac_graphics_msaa(void) {
    return saved_msaa();
}

static unsigned saved_anisotropy(void) {
    register_defaults();
    NSInteger value = [NSUserDefaults.standardUserDefaults integerForKey:kAnisotropy];
    return value == 2 || value == 4 || value == 8 || value == 16 ? (unsigned)value : 0;
}

unsigned dm_mac_graphics_anisotropy(void) {
    return saved_anisotropy();
}

unsigned dm_mac_graphics_upscaling(void) {
    register_defaults();
    return [NSUserDefaults.standardUserDefaults integerForKey:kUpscaling] ? 1 : 0;
}

void dm_mac_graphics_apply(void) {
    mtl_set_graphics_overrides(saved_msaa(), saved_anisotropy());
    mtl_set_spatial_upscaling(dm_mac_graphics_upscaling());
}

@interface DmMacGraphicsSettings ()
@end

@implementation DmMacGraphicsSettings {
    id<MTLDevice> _device;
    NSArray<NSNumber *> *_msaaValues;
    NSMenuItem *_resolutionItem;
    NSMenuItem *_msaaItem;
    NSMenuItem *_anisotropyItem;
    NSMenuItem *_upscalingItem;
    BOOL _upscalingSupported;
}

- (instancetype)initWithWindow:(NSWindow *)window device:(id<MTLDevice>)device {
    if (!(self = [super init])) return nil;
    (void)window;
    _device = device;
    register_defaults();

    NSMutableArray<NSNumber *> *msaa = [NSMutableArray arrayWithObject:@0];
    for (NSNumber *number in @[@2, @4, @8]) {
        NSUInteger value = number.unsignedIntegerValue;
        if ([_device supportsTextureSampleCount:value]) [msaa addObject:@(value)];
    }
    _msaaValues = msaa;
    _upscalingSupported = mtl_spatial_upscaling_supported_on_device(_device);
    if (!_upscalingSupported) DM_LOG_INFO("metal", "MetalFX spatial upscaling unavailable on this device");
    [self installMenu];
    [self updateTitles];
    return self;
}

- (NSString *)resolutionName:(unsigned)value {
    if (value == 50) return text(@"50%", @"50%");
    if (value == 75) return text(@"75%", @"75%");
    if (value == 125) return text(@"125%", @"125%");
    return text(@"Native", @"原生");
}

- (NSString *)msaaName:(unsigned)value {
    return value ? [NSString stringWithFormat:@"%ux", value] : text(@"Game default", @"游戏默认");
}

- (NSString *)anisotropyName:(unsigned)value {
    return value ? [NSString stringWithFormat:@"%ux", value] : text(@"Game default", @"游戏默认");
}

- (NSString *)upscalingName:(unsigned)value {
    return value ? text(@"MetalFX", @"MetalFX") : text(@"Bilinear", @"双线性");
}

- (void)installMenu {
    if (!NSApp.mainMenu) {
        NSMenu *main = [NSMenu new];
        NSMenuItem *app = [NSMenuItem new];
        app.submenu = [NSMenu new];
        [app.submenu addItemWithTitle:@"Quit" action:@selector(terminate:) keyEquivalent:@"q"];
        [main addItem:app];
        NSApp.mainMenu = main;
    }
    NSString *title = text(@"Graphics", @"画质");
    NSMenuItem *root = [[NSMenuItem alloc] initWithTitle:title action:nil keyEquivalent:@""];
    NSMenu *menu = [[NSMenu alloc] initWithTitle:title];
    root.submenu = menu;
    [NSApp.mainMenu addItem:root];

    _resolutionItem = [[NSMenuItem alloc] initWithTitle:@"" action:@selector(cycleResolution:) keyEquivalent:@""];
    _resolutionItem.target = self;
    _msaaItem = [[NSMenuItem alloc] initWithTitle:@"" action:@selector(cycleMSAA:) keyEquivalent:@""];
    _msaaItem.target = self;
    _anisotropyItem = [[NSMenuItem alloc] initWithTitle:@"" action:@selector(cycleAnisotropy:) keyEquivalent:@""];
    _anisotropyItem.target = self;
    _upscalingItem = [[NSMenuItem alloc] initWithTitle:@"" action:@selector(cycleUpscaling:) keyEquivalent:@""];
    _upscalingItem.target = self;
    _upscalingItem.hidden = !_upscalingSupported;
    [menu addItem:_resolutionItem];
    [menu addItem:_msaaItem];
    [menu addItem:_anisotropyItem];
    [menu addItem:_upscalingItem];
    [menu addItem:NSMenuItem.separatorItem];
    NSMenuItem *reset = [[NSMenuItem alloc] initWithTitle:text(@"Reset graphics settings", @"恢复画质默认设置")
                                                    action:@selector(resetSettings:) keyEquivalent:@""];
    reset.target = self;
    [menu addItem:reset];
}

- (void)updateTitles {
    unsigned resolution = dm_mac_graphics_resolution_percent();
    unsigned msaa = saved_msaa();
    unsigned anisotropy = saved_anisotropy();
    _resolutionItem.title = [NSString stringWithFormat:@"%@: %@", text(@"Resolution", @"分辨率"), [self resolutionName:resolution]];
    _msaaItem.title = [NSString stringWithFormat:@"%@: %@", text(@"MSAA", @"MSAA"), [self msaaName:msaa]];
    _anisotropyItem.title = [NSString stringWithFormat:@"%@: %@", text(@"Texture filtering", @"纹理过滤"), [self anisotropyName:anisotropy]];
    if (!_upscalingSupported) return;
    _upscalingItem.title = [NSString stringWithFormat:@"%@: %@", text(@"Upscaling", @"超分辨率"), [self upscalingName:dm_mac_graphics_upscaling()]];
}

- (void)changed {
    [self updateTitles];
    [self showRestartNotice];
}

- (void)showRestartNotice {
    NSAlert *alert = [NSAlert new];
    alert.messageText = text(@"Graphics setting saved", @"画质设置已保存");
    alert.informativeText = text(@"Restart the game for this setting to take effect.", @"请重启游戏使设置生效。");
    [alert addButtonWithTitle:text(@"OK", @"确定")];
    [alert runModal];
}

- (void)cycleResolution:(id)sender {
    (void)sender;
    NSArray<NSNumber *> *values = @[@50, @75, @100, @125];
    unsigned current = dm_mac_graphics_resolution_percent();
    NSUInteger index = [values indexOfObject:@(current)];
    if (index == NSNotFound) index = 2;
    [NSUserDefaults.standardUserDefaults setInteger:values[(index + 1) % values.count].integerValue forKey:kResolution];
    [self changed];
}

- (void)cycleMSAA:(id)sender {
    (void)sender;
    unsigned current = saved_msaa();
    NSUInteger index = [_msaaValues indexOfObject:@(current)];
    if (index == NSNotFound) index = 0;
    [NSUserDefaults.standardUserDefaults setInteger:_msaaValues[(index + 1) % _msaaValues.count].integerValue forKey:kMSAA];
    [self changed];
}

- (void)cycleAnisotropy:(id)sender {
    (void)sender;
    NSArray<NSNumber *> *values = @[@0, @2, @4, @8, @16];
    unsigned current = saved_anisotropy();
    NSUInteger index = [values indexOfObject:@(current)];
    if (index == NSNotFound) index = 0;
    [NSUserDefaults.standardUserDefaults setInteger:values[(index + 1) % values.count].integerValue forKey:kAnisotropy];
    [self changed];
}

- (void)cycleUpscaling:(id)sender {
    (void)sender;
    if (!_upscalingSupported) return;
    [NSUserDefaults.standardUserDefaults setInteger:dm_mac_graphics_upscaling() ? 0 : 1 forKey:kUpscaling];
    [self changed];
}

- (void)resetSettings:(id)sender {
    (void)sender;
    [NSUserDefaults.standardUserDefaults setInteger:100 forKey:kResolution];
    [NSUserDefaults.standardUserDefaults setInteger:0 forKey:kMSAA];
    [NSUserDefaults.standardUserDefaults setInteger:0 forKey:kAnisotropy];
    [NSUserDefaults.standardUserDefaults setInteger:0 forKey:kUpscaling];
    [self changed];
}

@end
