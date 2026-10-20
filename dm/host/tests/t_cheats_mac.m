#import "../cheats_mac.h"
#import <QuartzCore/QuartzCore.h>
#include "../cheats.h"
#include "game_profile.h"
#include <assert.h>
#include <stdio.h>
#include <unistd.h>

@interface DmMacCheats (TestRows) <NSTableViewDataSource, NSTableViewDelegate>
- (NSView *)tableView:(NSTableView *)tableView viewForTableColumn:(NSTableColumn *)column row:(NSInteger)row;
@end

static NSTextField *labelWithText(NSArray<NSView *> *views, NSString *text) {
    for (NSView *view in views)
        if ([view isKindOfClass:NSTextField.class] && [((NSTextField *)view).stringValue isEqualToString:text]) return (NSTextField *)view;
    return nil;
}

@interface CheatTestApplication : NSApplication
@end
@implementation CheatTestApplication
- (BOOL)isActive { return YES; }
@end
static NSEvent *key(NSEventType type, unsigned short code, NSEventModifierFlags modifiers, BOOL repeat) {
    return [NSEvent keyEventWithType:type location:NSZeroPoint modifierFlags:modifiers timestamp:0
                       windowNumber:0 context:nil characters:@"" charactersIgnoringModifiers:@"" isARepeat:repeat keyCode:code];
}
int main(void) {
    @autoreleasepool {
        [CheatTestApplication sharedApplication];
        const struct { const char *id, *version; } builds[] = {DM_GAME_DISPLAY_VERSIONS};
        char path[] = "/tmp/dm-cheats-ui-XXXXXX"; int fd = mkstemp(path); assert(fd >= 0); close(fd);
        FILE *f = fopen(path, "w"); assert(f);
        fprintf(f, "# BUILD_ID\t%s\n0\t0\t示例//Example\n1\t0\t第二//Second\n", builds[0].id); fclose(f);
        uint32_t flags[2] = {0};
        setenv("DM_LANG", "en-US", 1);
        assert(dm_cheats_load(flags, 2, builds[0].id, path));
        assert(!strcmp(dm_cheat_name(0), "Example"));
        setenv("DM_LANG", "zh-Hans", 1);
        assert(!strcmp(dm_cheat_name(0), "示例"));
        setenv("DM_LANG", "en-US", 1);
        unlink(path);
        NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(100, 100, 1000, 650)
                                                     styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
        [window orderFront:nil];
        DmMacCheats *menu = [[DmMacCheats alloc] initWithWindow:window];
        assert(!menu.visible && !menu.panel.canBecomeKeyWindow && !menu.panel.canBecomeMainWindow);
        assert(menu.panel.hasShadow == NO && menu.panel.opaque == NO);
        assert(CGColorGetAlpha(menu.panel.contentView.layer.backgroundColor) == 0);
        assert(menu.panel.contentView.subviews.count > 0);
        assert(![menu handleKeyEvent:key(NSEventTypeKeyDown, 14, 0, NO)]);
        assert(![menu handleKeyEvent:key(NSEventTypeKeyDown, 101, 0, NO)]);
        assert(![menu handleKeyEvent:key(NSEventTypeKeyDown, 97, NSEventModifierFlagCommand, NO)]);
        assert([menu handleKeyEvent:key(NSEventTypeKeyDown, 97, 0, NO)]);
        assert(menu.visible && menu.selectedIndex == 0);
        assert(fabs(menu.panel.frame.size.width - 460) < 1);
        NSRect content = [window convertRectToScreen:window.contentView.bounds];
        assert(NSMaxY(menu.panel.frame) <= NSMaxY(content) - 124);
        NSScrollView *scroll = nil;
        for (NSView *view in menu.panel.contentView.subviews)
            if ([view isKindOfClass:NSScrollView.class]) scroll = (NSScrollView *)view;
        assert(scroll);
        NSTableView *table = (NSTableView *)scroll.documentView;
        assert(table.numberOfColumns == 1);
        assert(NSWidth(table.bounds) >= NSWidth(scroll.contentView.bounds) - 0.5);
        NSView *row = [menu tableView:table viewForTableColumn:table.tableColumns[0] row:0];
        [row setFrame:NSMakeRect(0, 0, NSWidth(table.bounds), table.rowHeight)];
        [row layoutSubtreeIfNeeded];
        NSTextField *englishName = row.subviews.firstObject;
        NSTextField *status = row.subviews.lastObject;
        assert([englishName isKindOfClass:NSTextField.class] && [englishName.stringValue isEqualToString:@"Example"]);
        assert([status isKindOfClass:NSTextField.class] && NSMaxX(status.frame) <= NSWidth(row.bounds) + 0.5);
        setenv("DM_LANG", "zh-Hans", 1);
        row = [menu tableView:table viewForTableColumn:table.tableColumns[0] row:0];
        assert([((NSTextField *)row.subviews.firstObject).stringValue isEqualToString:@"示例"]);
        setenv("DM_LANG", "en-US", 1);
        NSBitmapImageRep *image = [menu.panel.contentView bitmapImageRepForCachingDisplayInRect:menu.panel.contentView.bounds];
        [menu.panel.contentView cacheDisplayInRect:menu.panel.contentView.bounds toBitmapImageRep:image];
        NSData *png = [image representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
        assert([png writeToFile:@"/tmp/dm-cheats-panel.png" atomically:YES]);
        assert([menu handleKeyEvent:key(NSEventTypeKeyUp, 97, 0, NO)] && menu.visible);
        assert([menu handleKeyEvent:key(NSEventTypeKeyDown, 97, 0, YES)] && menu.visible);
        assert([menu handleKeyEvent:key(NSEventTypeKeyDown, 100, 0, NO)] && menu.selectedIndex == 1);
        assert([menu handleKeyEvent:key(NSEventTypeKeyDown, 101, 0, NO)] && flags[1] == 1);
        assert([menu handleKeyEvent:key(NSEventTypeKeyDown, 101, 0, YES)] && flags[1] == 1);
        assert([menu handleKeyEvent:key(NSEventTypeKeyUp, 101, 0, NO)] && flags[1] == 1);
        assert([menu handleKeyEvent:key(NSEventTypeKeyDown, 98, 0, NO)] && menu.selectedIndex == 0);
        assert([menu handleKeyEvent:key(NSEventTypeKeyDown, 101, 0, NO)] && flags[0] == 1);
        assert([menu handleKeyEvent:key(NSEventTypeKeyDown, 101, 0, NO)] && flags[0] == 0);
        assert([menu handleKeyEvent:key(NSEventTypeKeyDown, 97, 0, NO)] && !menu.visible);
        assert(![menu handleKeyEvent:key(NSEventTypeKeyDown, 100, 0, NO)]);
        [NSNotificationCenter.defaultCenter postNotificationName:NSWindowWillCloseNotification object:window];
        assert(!menu.visible && !menu.panel.parentWindow);
        [window orderOut:nil];

        setenv("DM_LANG", "zh-Hans", 1);
        NSWindow *chineseWindow = [[NSWindow alloc] initWithContentRect:NSMakeRect(120, 120, 1000, 650)
                                                               styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
        [chineseWindow orderFront:nil];
        DmMacCheats *chineseMenu = [[DmMacCheats alloc] initWithWindow:chineseWindow];
        [chineseMenu toggleMenu:nil];
        NSArray<NSView *> *labels = chineseMenu.panel.contentView.subviews;
        assert([labelWithText(labels, @"金手指") isKindOfClass:NSTextField.class]);
        assert([labelWithText(labels, @"F7 上一个   F8 下一个   F9 开关   F6 关闭") isKindOfClass:NSTextField.class]);
        assert([labelWithText(labels, @"进入游戏前请保持关闭，进入游戏后再开启。") isKindOfClass:NSTextField.class]);
        NSScrollView *chineseScroll = nil;
        for (NSView *view in labels) if ([view isKindOfClass:NSScrollView.class]) chineseScroll = (NSScrollView *)view;
        NSTableView *chineseTable = (NSTableView *)chineseScroll.documentView;
        NSView *chineseRow = [chineseMenu tableView:chineseTable viewForTableColumn:chineseTable.tableColumns[0] row:0];
        assert([((NSTextField *)chineseRow.subviews.firstObject).stringValue isEqualToString:@"示例"]);
        [NSNotificationCenter.defaultCenter postNotificationName:NSWindowWillCloseNotification object:chineseWindow];
        [chineseWindow orderOut:nil];
        puts("PASS: Mac cheat function keys, selection, live flags and focus isolation");
    }
}
