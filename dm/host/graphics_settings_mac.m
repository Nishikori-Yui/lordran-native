#import "graphics_settings_mac.h"
#include "../gfx/nvn/nvn_mtl.h"
#include <stdlib.h>
#include <strings.h>

static NSString *const kResolution = @"DmMacGraphicsResolutionPercent";
static NSString *const kMSAA = @"DmMacGraphicsMSAA";
static NSString *const kAnisotropy = @"DmMacGraphicsAnisotropy";
static NSString *const kBloom = @"DmMacGraphicsBloom";

static void register_defaults(void) {
    [NSUserDefaults.standardUserDefaults registerDefaults:@{
        kResolution: @100,
        kMSAA: @0,
        kAnisotropy: @0,
        kBloom: @-1,
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

static unsigned saved_anisotropy(void) {
    register_defaults();
    NSInteger value = [NSUserDefaults.standardUserDefaults integerForKey:kAnisotropy];
    return value == 2 || value == 4 || value == 8 || value == 16 ? (unsigned)value : 0;
}

static int saved_bloom(void) {
    register_defaults();
    NSInteger value = [NSUserDefaults.standardUserDefaults integerForKey:kBloom];
    return value == 0 || value == 1 ? (int)value : -1;
}

void dm_mac_graphics_apply(void) {
    mtl_set_graphics_overrides(saved_msaa(), saved_anisotropy(), saved_bloom());
}

@interface DmMacGraphicsSettings ()
@end

@implementation DmMacGraphicsSettings {
    id<MTLDevice> _device;
    NSArray<NSNumber *> *_msaaValues;
    NSMenuItem *_resolutionItem;
    NSMenuItem *_msaaItem;
    NSMenuItem *_anisotropyItem;
    NSMenuItem *_bloomItem;
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

- (NSString *)bloomName:(int)value {
    if (value == 0) return text(@"Off", @"关闭");
    if (value == 1) return text(@"On", @"开启");
    return text(@"Game default", @"游戏默认");
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
    _bloomItem = [[NSMenuItem alloc] initWithTitle:@"" action:@selector(cycleBloom:) keyEquivalent:@""];
    _bloomItem.target = self;
    [menu addItem:_resolutionItem];
    [menu addItem:_msaaItem];
    [menu addItem:_anisotropyItem];
    [menu addItem:_bloomItem];
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
    int bloom = saved_bloom();
    _resolutionItem.title = [NSString stringWithFormat:@"%@: %@", text(@"Resolution", @"分辨率"), [self resolutionName:resolution]];
    _msaaItem.title = [NSString stringWithFormat:@"%@: %@", text(@"MSAA", @"MSAA"), [self msaaName:msaa]];
    _anisotropyItem.title = [NSString stringWithFormat:@"%@: %@", text(@"Texture filtering", @"纹理过滤"), [self anisotropyName:anisotropy]];
    _bloomItem.title = [NSString stringWithFormat:@"%@: %@", text(@"Bloom", @"Bloom"), [self bloomName:bloom]];
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

- (void)cycleBloom:(id)sender {
    (void)sender;
    NSArray<NSNumber *> *values = @[@-1, @0, @1];
    int current = saved_bloom();
    NSUInteger index = [values indexOfObject:@(current)];
    if (index == NSNotFound) index = 0;
    [NSUserDefaults.standardUserDefaults setInteger:values[(index + 1) % values.count].integerValue forKey:kBloom];
    [self changed];
}

- (void)resetSettings:(id)sender {
    (void)sender;
    [NSUserDefaults.standardUserDefaults setInteger:100 forKey:kResolution];
    [NSUserDefaults.standardUserDefaults setInteger:0 forKey:kMSAA];
    [NSUserDefaults.standardUserDefaults setInteger:0 forKey:kAnisotropy];
    [NSUserDefaults.standardUserDefaults setInteger:-1 forKey:kBloom];
    [self changed];
}

@end
