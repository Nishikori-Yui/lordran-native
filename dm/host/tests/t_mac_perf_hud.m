#import "../perf_hud_mac.h"
#import <QuartzCore/QuartzCore.h>
#include "../../gfx/nvn/nvn_perf.h"
#include <assert.h>
#include <stdio.h>
#include <unistd.h>

@interface HUDTestApplication : NSApplication
@property BOOL testActive;
@end
@implementation HUDTestApplication
- (BOOL)isActive { return self.testActive; }
@end
@interface HUDTestWindow : NSWindow
@property BOOL testMiniaturized;
@end
@implementation HUDTestWindow
- (BOOL)isMiniaturized { return self.testMiniaturized; }
@end

static NSTextField *headline(NSView *view) {
    for (NSView *child in view.subviews) {
        if ([child isKindOfClass:NSTextField.class] &&
            [child.accessibilityLabel isEqualToString:@"Frame rate and frame time"]) return (NSTextField *)child;
    }
    return nil;
}

static NSTextField *details(NSView *view) {
    for (NSView *child in view.subviews) {
        if (![child isKindOfClass:NSTextField.class]) continue;
        NSTextField *field = (NSTextField *)child;
        if (field.maximumNumberOfLines == 4) return field;
    }
    return nil;
}

static NSEvent *key_event(NSEventType type, unsigned short code, NSEventModifierFlags modifiers, BOOL repeat) {
    return [NSEvent keyEventWithType:type location:NSZeroPoint modifierFlags:modifiers timestamp:0
                       windowNumber:0 context:nil characters:@"" charactersIgnoringModifiers:@"" isARepeat:repeat keyCode:code];
}

int main(void) {
    @autoreleasepool {
        HUDTestApplication *app = [HUDTestApplication sharedApplication];
        app.testActive = YES;
        NSString *key = @"DmMacPerfMode";
        id saved = [NSUserDefaults.standardUserDefaults objectForKey:key];
        [NSUserDefaults.standardUserDefaults removeObjectForKey:key];
        HUDTestWindow *window = [[HUDTestWindow alloc] initWithContentRect:NSMakeRect(120, 120, 1000, 650)
                                                               styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskResizable
                                                                 backing:NSBackingStoreBuffered defer:NO];
        [window orderFront:nil];
        DmMacPerfHUD *hud = [[DmMacPerfHUD alloc] initWithWindow:window device:MTLCreateSystemDefaultDevice()];
        assert(hud.mode == 0 && hud.updating);
        assert(hud.view.superview == window.contentView);
        assert([hud.view hitTest:NSMakePoint(10, 10)] == nil);
        NSTextField *label = headline(hud.view);
        NSTextField *detailLabel = details(hud.view);
        assert(label && [label.stringValue containsString:@"-- FPS"]);
        assert(detailLabel && detailLabel.maximumNumberOfLines == 4);
        assert([hud handleKeyEvent:key_event(NSEventTypeKeyDown, 96, 0, NO)] && hud.mode == 1);
        assert([hud handleKeyEvent:key_event(NSEventTypeKeyDown, 96, 0, YES)] && hud.mode == 1);
        assert([hud handleKeyEvent:key_event(NSEventTypeKeyUp, 96, 0, NO)] && hud.mode == 1);
        assert(![hud handleKeyEvent:key_event(NSEventTypeKeyDown, 96, NSEventModifierFlagCommand, NO)]);
        assert(![hud handleKeyEvent:key_event(NSEventTypeKeyDown, 14, 0, NO)]);
        hud.mode = 0;

        uint64_t now = (uint64_t)(CACurrentMediaTime() * 1e9);
        for (int i = 0; i <= 60; i++) {
            uint64_t t = now - 1000000000ull + i * 1000000000ull / 60;
            nvn_perf_frame(t, 1600, 900, 5.5);
            if (i % 2 == 0) nvn_perf_present(t);
        }
        [hud cycleMode:nil];
        assert(hud.mode == 1 && !hud.view.hidden);
        assert(label.stringValue.doubleValue > 28 && label.stringValue.doubleValue <= 30.1);
        assert(detailLabel && [detailLabel.stringValue containsString:@"Graphics Native · MSAA Default · AF Default"]);
        NSColor *color = [label.attributedStringValue attribute:NSForegroundColorAttributeName atIndex:0 effectiveRange:NULL];
        assert(color.greenComponent > 0.99 && color.redComponent < 0.6);
        assert([label.attributedStringValue attribute:NSShadowAttributeName atIndex:0 effectiveRange:NULL]);
        NSMenu *menu = [NSApp.mainMenu itemWithTitle:@"View"].submenu;
        NSMenuItem *modeItem = [menu itemWithTitle:@"Performance: Detailed"];
        assert(modeItem.target == hud && modeItem.keyEquivalentModifierMask == 0);
        [hud cycleMode:modeItem];
        assert(hud.mode == 2 && !hud.updating && hud.view.hidden);
        [hud cycleMode:modeItem];
        assert(hud.mode == 0 && hud.updating && !hud.view.hidden);
        assert([modeItem.title isEqualToString:@"Performance: Simple"]);
        [window setContentSize:NSMakeSize(500, 300)];
        [window.contentView layoutSubtreeIfNeeded];
        assert(NSContainsRect(window.contentView.bounds, hud.view.frame));
        app.testActive = NO;
        [NSNotificationCenter.defaultCenter postNotificationName:NSApplicationWillResignActiveNotification object:app];
        assert(!hud.updating);
        app.testActive = YES;
        [NSNotificationCenter.defaultCenter postNotificationName:NSApplicationDidBecomeActiveNotification object:app];
        assert(hud.updating);
        window.testMiniaturized = YES;
        [NSNotificationCenter.defaultCenter postNotificationName:NSWindowDidMiniaturizeNotification object:window];
        assert(!hud.updating);
        window.testMiniaturized = NO;
        [NSNotificationCenter.defaultCenter postNotificationName:NSWindowDidDeminiaturizeNotification object:window];
        assert(hud.updating);
        [NSNotificationCenter.defaultCenter postNotificationName:NSWindowWillCloseNotification object:window];
        assert(!hud.updating && !hud.view.superview);
        [window orderOut:nil];
        if (saved) [NSUserDefaults.standardUserDefaults setObject:saved forKey:key];
        else [NSUserDefaults.standardUserDefaults removeObjectForKey:key];
        puts("PASS: text-only Mac HUD metrics, modes, hit testing, color, layout and lifecycle");
    }
}
