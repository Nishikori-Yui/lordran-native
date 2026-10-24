// Mac front end: with DM_WINDOW=1 open a window (CAMetalLayer, for the graphics backend to present frames) + keyboard → dm_input; the guest runs on a large-stack thread instead and the main thread belongs to AppKit.
// Without DM_WINDOW: the guest runs directly on the current thread, behaving the same as with no front end (windowless tests use this).
// Key map (Nintendo layout): WASD left stick, arrow keys D-pad, J=A K=B U=X I=Y, Q=L E=R, Z=ZL C=ZR, F=press left stick G=press right stick, Return=+ Tab=−.
#import <Cocoa/Cocoa.h>
#import <GameController/GameController.h>
#import <QuartzCore/CAMetalLayer.h>
#import <Metal/Metal.h>
#include "dm.h"
#include "dm_input.h"
#include "dm_padmap.h"
#include "../gfx/nvn/nvn_mtl.h"
#include "front.h"
#include "hle.h"
#import "perf_hud_mac.h"
#import "cheats_mac.h"
#import "metal_surface_mac.h"
#import "graphics_settings_mac.h"
#include <signal.h>

static CAMetalLayer *g_layer;
static uint64_t g_btn, g_key_btn, g_mouse_btn;
static int g_w, g_a, g_s, g_d;
static int g_walk, g_shift;
static int g_mouse_left, g_mouse_right, g_mouse_middle;
static int32_t g_mouse_rx, g_mouse_ry;
static uint64_t g_mouse_motion_seq;
static GCController *g_pad_controller;
static DmMacPerfHUD *g_perf_hud;
static DmMacCheats *g_cheats;
static DmMacGraphicsSettings *g_graphics_settings;

void *front_metal_layer(void) { return (__bridge void *)g_layer; }
static int ds_layout(void) { return !strcmp(DM_GAME_MAC_LAYOUT, "dark_souls_pc"); }
// The original game's 16:9 constants, behavior unchanged; DM_GAME_RES=<width>x<height>
// remains an explicit diagnostic override. The Mac Graphics menu scales these defaults.
uint64_t front_game_res(int docked) {
    unsigned w, h; const char *e = getenv("DM_GAME_RES");
    if (e && sscanf(e, "%ux%u", &w, &h) == 2) return docked ? (uint64_t)h << 32 | w : (uint64_t)(h * 4 / 5) << 32 | (w * 4 / 5 + 3) / 4 * 4;
    unsigned percent = dm_mac_graphics_resolution_percent();
    unsigned base_w = docked ? 1600 : 1280, base_h = docked ? 900 : 720;
    unsigned scaled_w = (base_w * percent / 100u + 3u) & ~3u;
    unsigned scaled_h = (base_h * percent / 100u + 3u) & ~3u;
    return (uint64_t)scaled_h << 32 | scaled_w;
}

static int32_t clamp_axis(long v) {
    return v < -DM_STICK_MAX ? -DM_STICK_MAX : v > DM_STICK_MAX ? DM_STICK_MAX : (int32_t)v;
}
static int32_t pad_axis(float v) {
    return (int32_t)(fmaxf(-1.f, fminf(1.f, v)) * DM_STICK_MAX);
}
static void pad_clear(void) {
    dm_pad_set(0, 0, 0, 0, 0);
}
static void pad_read(GCExtendedGamepad *g) {
    uint64_t buttons = dm_padmap_face(DM_PADKIND_NINTENDO,
                                      g.buttonA.isPressed, g.buttonB.isPressed,
                                      g.buttonX.isPressed, g.buttonY.isPressed);
    if (g.leftShoulder.isPressed) buttons |= DM_BTN_L;
    if (g.rightShoulder.isPressed) buttons |= DM_BTN_R;
    if (g.leftTrigger.isPressed) buttons |= DM_BTN_ZL;
    if (g.rightTrigger.isPressed) buttons |= DM_BTN_ZR;
    if (g.buttonMenu.isPressed) buttons |= DM_BTN_PLUS;
    if (g.buttonOptions && g.buttonOptions.isPressed) buttons |= DM_BTN_MINUS;
    if (g.leftThumbstickButton && g.leftThumbstickButton.isPressed) buttons |= DM_BTN_LS;
    if (g.rightThumbstickButton && g.rightThumbstickButton.isPressed) buttons |= DM_BTN_RS;
    if (g.dpad.left.isPressed) buttons |= DM_BTN_LEFT;
    if (g.dpad.up.isPressed) buttons |= DM_BTN_UP;
    if (g.dpad.right.isPressed) buttons |= DM_BTN_RIGHT;
    if (g.dpad.down.isPressed) buttons |= DM_BTN_DOWN;
    dm_pad_set(buttons,
               pad_axis(g.leftThumbstick.xAxis.value),
               pad_axis(g.leftThumbstick.yAxis.value),
               pad_axis(g.rightThumbstick.xAxis.value),
               pad_axis(g.rightThumbstick.yAxis.value));
}
static void pad_refresh(void) {
    GCController *selected = nil;
    GCController *current = GCController.current;
    for (GCController *c in GCController.controllers) {
        if (!c.extendedGamepad) continue;
        if (!selected) selected = c;
        if (c == current) { selected = c; break; }
    }
    if (selected != g_pad_controller) {
        g_pad_controller.extendedGamepad.valueChangedHandler = nil;
        g_pad_controller = selected;
        if (selected) {
            selected.extendedGamepad.valueChangedHandler = ^(GCExtendedGamepad *g, GCControllerElement *element) {
                (void)element;
                if (g == g_pad_controller.extendedGamepad) pad_read(g);
            };
            const char *vendor = selected.vendorName.UTF8String ?: "unknown";
            const char *category = selected.productCategory.UTF8String ?: "unknown";
            LOG("Mac controller connected: %s / %s", category, vendor);
        } else {
            LOG("Mac controller disconnected");
        }
    }
    if (selected) pad_read(selected.extendedGamepad); else pad_clear();
}
static int game_key_event(NSEvent *e, NSWindow *win) {
    return e.window == win || (e.window == nil && NSApp.keyWindow == win);
}
static void push(void) {
    int32_t lx = (g_d - g_a) * DM_STICK_MAX, ly = (g_w - g_s) * DM_STICK_MAX;
    if (ds_layout()) {
        if (g_walk) g_key_btn |= DM_BTN_LS; else g_key_btn &= ~DM_BTN_LS;
        g_btn = g_key_btn | g_mouse_btn;
        dm_input_set(g_btn, lx, ly, g_mouse_rx, g_mouse_ry);
    } else {
        g_btn = g_key_btn;
        dm_input_set(g_btn, lx, ly, 0, 0);
    }
}
static int key_bit(unsigned short code) {
    if (ds_layout()) {
        switch (code) {
            case 49: return 1;  // Space = dash / roll / backstep / jump = B
            case 14: return 0;  // E = confirm / action = A
            case 3:  return 2;  // F = one- / two-hand toggle = X
            case 15: return 3;  // R = use item = Y
            case 5:  return 11; // G = gesture menu = Minus
            case 53: return 10; // Esc = menu = Plus
            case 12: return 1; // Q = menu cancel
            case 36: return 0;  // Return = confirm as a convenient PC keyboard equivalent
            case 123: return 12; case 126: return 13; case 124: return 14; case 125: return 15;
        }
        return -1;
    }
    switch (code) {
        case 38: return 0;  case 40: return 1;  case 32: return 2;  case 34: return 3;    // J K U I → A B X Y
        case 3: return 4;   case 5: return 5;                                            // F G → press stick
        case 12: return 6;  case 14: return 7;  case 6: return 8;   case 8: return 9;    // Q E Z C → L R ZL ZR
        case 36: return 10; case 48: return 11;                                          // Return Tab → + −
        case 123: return 12; case 126: return 13; case 124: return 14; case 125: return 15; // ← ↑ → ↓
    }
    return -1;
}
static void compose_mouse_buttons(void) {
    g_mouse_btn = 0;
    if (g_mouse_left) g_mouse_btn |= g_shift ? DM_BTN_ZR : DM_BTN_R;       // left mouse = right-hand light / strong attack
    if (g_mouse_right) g_mouse_btn |= g_shift ? DM_BTN_ZL : DM_BTN_L;      // right mouse = left-hand guard / parry
    if (g_mouse_middle) g_mouse_btn |= DM_BTN_RS;                          // middle mouse = camera reset / lock-on
}
static void sync_mouse_buttons(void) {
    compose_mouse_buttons();
    push();
}
static void mouse_motion(NSEvent *e) {
    long rx = (long)llround(e.deltaX * DM_GAME_MAC_MOUSE_SENSITIVITY);
    long ry = (long)llround(e.deltaY * DM_GAME_MAC_MOUSE_SENSITIVITY);
    g_mouse_rx = clamp_axis((long)g_mouse_rx + rx);
    g_mouse_ry = clamp_axis((long)g_mouse_ry + ry);
    uint64_t seq = ++g_mouse_motion_seq;
    push();
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 25 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        if (seq == g_mouse_motion_seq) {
            g_mouse_rx = g_mouse_ry = 0;
            push();
        }
    });
}
static void pulse(uint64_t button) {
    uint64_t old = g_mouse_btn;
    g_mouse_btn |= button;
    push();
    g_mouse_btn = old;
    push();
}
static void mouse_scroll(NSEvent *e) {
    CGFloat dy = e.scrollingDeltaY;
    int n = (int)llround(fabs(dy));
    if (!n) n = dy > 0.1 || dy < -0.1 ? 1 : 0;
    if (n > 4) n = 4;
    uint64_t button = 0;
    if (e.modifierFlags & NSEventModifierFlagShift) {
        button = dy > 0 ? DM_BTN_RIGHT : DM_BTN_LEFT; // Shift + wheel: right-/left-hand weapon
    } else {
        button = dy > 0 ? DM_BTN_UP : DM_BTN_DOWN;    // Wheel: magic / item
    }
    while (n-- > 0) pulse(button);
}
static void on_key(NSEvent *e, int down) {
    unsigned short c = e.keyCode;
    switch (c) { case 13: g_w = down; break; case 0: g_a = down; break; case 1: g_s = down; break; case 2: g_d = down; break; }
    if (c == 58 || c == 61) g_walk = down;                         // Option / Alt = walk
    if (c == 56 || c == 60) { g_shift = down; if (ds_layout()) sync_mouse_buttons(); }
    int b = key_bit(c);
    if (b >= 0) g_key_btn = down ? (g_key_btn | 1ull << b) : (g_key_btn & ~(1ull << b));
    push();
    if (down && (b >= 0 || c == 0 || c == 1 || c == 2 || c == 13)) {
        LOG("Mac keyboard event: key_code=%hu buttons=%#llx sticks=(%d,%d)", c,
            (unsigned long long)g_btn, (g_d - g_a) * DM_STICK_MAX, (g_w - g_s) * DM_STICK_MAX);
    }
}

typedef struct { void (*fn)(void); } guest_arg;
static void *guest_tramp(void *p) {
    static char alt[65536];                       // The signal alternate stack is per thread; crash printing must also work on the guest thread
    stack_t ss = {.ss_sp = alt, .ss_size = sizeof alt}; sigaltstack(&ss, 0);
    ((guest_arg *)p)->fn(); LOG("Guest thread exited"); exit(0);
}

void front_run(void (*guest)(void)) {
    if (!getenv("DM_WINDOW")) { guest(); return; }
    @autoreleasepool {
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
        NSRect r = NSMakeRect(0, 0, 1280, 720);
        NSWindow *win = [[NSWindow alloc] initWithContentRect:r
                                                    styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable
                                                      backing:NSBackingStoreBuffered defer:NO];
        win.title = @DM_GAME_NAME;   // the game profile's name (game name label)
        NSView *v = win.contentView;
        v.wantsLayer = YES;
        g_layer = [CAMetalLayer layer];
        g_layer.device = MTLCreateSystemDefaultDevice();
        g_layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
        g_layer.contentsScale = win.backingScaleFactor;
        g_layer.opaque = YES;
        DmMetalSurface *surface = [[DmMetalSurface alloc] initWithFrame:v.bounds];
        // Setting the layer before wantsLayer creates a layer-hosting view;
        // AppKit must not replace its contents while redrawing native controls.
        surface.layer = g_layer;
        surface.wantsLayer = YES;
        surface.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        [v addSubview:surface];
        win.acceptsMouseMovedEvents = YES;
        [win center];
        [NSApp activateIgnoringOtherApps:YES];
        [win makeKeyAndOrderFront:nil];
        win.initialFirstResponder = v;
        [win makeFirstResponder:v];
        g_perf_hud = [[DmMacPerfHUD alloc] initWithWindow:win device:g_layer.device];
        g_cheats = [[DmMacCheats alloc] initWithWindow:win];
        dm_mac_graphics_apply();
        g_graphics_settings = [[DmMacGraphicsSettings alloc] initWithWindow:win device:g_layer.device];
        NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
        [nc addObserverForName:GCControllerDidConnectNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) {
            (void)n; pad_refresh();
        }];
        [nc addObserverForName:GCControllerDidDisconnectNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) {
            (void)n; pad_refresh();
        }];
        pad_refresh();
        if (!GCController.controllers.count) [GCController startWirelessControllerDiscoveryWithCompletionHandler:nil];
        [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown | NSEventMaskKeyUp handler:^NSEvent *(NSEvent *e) {
            if (!game_key_event(e, win)) return e;   // Keep native text dialogs and other application windows independent
            if ([g_perf_hud handleKeyEvent:e]) return nil;
            if ([g_cheats handleKeyEvent:e]) return nil;
            if (e.modifierFlags & NSEventModifierFlagCommand) {
                if (e.type == NSEventTypeKeyUp) on_key(e, 0);
                return e;
            }
            if (!e.isARepeat) on_key(e, e.type == NSEventTypeKeyDown);
            return nil;   // Swallow it to avoid the system beep
        }];
        if (ds_layout()) {
            // Dark Souls' Mac layout follows the PC manual: relative mouse camera,
            // mouse attacks, Shift for strong attacks, and wheel for D-pad actions.
            [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskMouseMoved | NSEventMaskLeftMouseDown | NSEventMaskLeftMouseDragged | NSEventMaskLeftMouseUp |
             NSEventMaskRightMouseDown | NSEventMaskRightMouseDragged | NSEventMaskRightMouseUp | NSEventMaskOtherMouseDown | NSEventMaskOtherMouseDragged |
             NSEventMaskOtherMouseUp | NSEventMaskScrollWheel handler:^NSEvent *(NSEvent *e) {
                if (e.window != win) return e;
                switch (e.type) {
                    case NSEventTypeMouseMoved: case NSEventTypeLeftMouseDragged: case NSEventTypeRightMouseDragged: case NSEventTypeOtherMouseDragged:
                        mouse_motion(e); return nil;
                    case NSEventTypeScrollWheel: mouse_scroll(e); return nil;
                    case NSEventTypeLeftMouseDown: g_mouse_left = 1; sync_mouse_buttons(); return nil;
                    case NSEventTypeLeftMouseUp: g_mouse_left = 0; sync_mouse_buttons(); return nil;
                    case NSEventTypeRightMouseDown: g_mouse_right = 1; sync_mouse_buttons(); return nil;
                    case NSEventTypeRightMouseUp: g_mouse_right = 0; sync_mouse_buttons(); return nil;
                    case NSEventTypeOtherMouseDown: if (e.buttonNumber == 2) { g_mouse_middle = 1; sync_mouse_buttons(); return nil; } break;
                    case NSEventTypeOtherMouseUp: if (e.buttonNumber == 2) { g_mouse_middle = 0; sync_mouse_buttons(); return nil; } break;
                    default: break;
                }
                return e;
            }];
        } else {
            // Mouse as a single-point touchscreen (for testing touch on the local machine, front.h dm_touch_set): left button down / drag = finger 0 at the normalized coordinates, release = lifted
            [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskLeftMouseDown | NSEventMaskLeftMouseDragged | NSEventMaskLeftMouseUp handler:^NSEvent *(NSEvent *e) {
                if (e.window != win) return e;
                if (e.type == NSEventTypeLeftMouseUp) { dm_touch_set(NULL, 0); return nil; }
                NSPoint p = [v convertPoint:e.locationInWindow fromView:nil]; NSSize sz = v.bounds.size;
                if (sz.width <= 0 || sz.height <= 0) return e;
                dm_touch t = {0, (float)(p.x / sz.width), (float)(1.0 - p.y / sz.height)};   // The AppKit view origin is at bottom left, the touchscreen origin is at top left
                dm_touch_set(&t, 1); return nil;
            }];
        }
        [[NSNotificationCenter defaultCenter] addObserverForName:NSWindowWillCloseNotification object:win queue:nil
                                                      usingBlock:^(NSNotification *n) { (void)n; exit(0); }];
        // Lifecycle (hle.h / dm.h): focus lost → 2, focus regained → 1; minimized → 3 + audio paused + GPU suspended, restored → resume (followed by focus regained → 1)
        [nc addObserverForName:NSWindowDidResignKeyNotification object:win queue:nil usingBlock:^(NSNotification *n) {
            (void)n;
            // A native text dialog can consume the key-up that opened it.
            g_btn = g_key_btn = g_mouse_btn = 0;
            g_w = g_a = g_s = g_d = g_walk = g_shift = 0;
            g_mouse_left = g_mouse_right = g_mouse_middle = 0;
            g_mouse_rx = g_mouse_ry = 0; ++g_mouse_motion_seq;
            push(); pad_clear(); dm_touch_set(NULL, 0);
            LOG("Game window lost keyboard focus");
            if (!win.miniaturized) dm_focus_set(2);
        }];
        [nc addObserverForName:NSWindowDidBecomeKeyNotification object:win queue:nil usingBlock:^(NSNotification *n) {
            (void)n;
            [win makeFirstResponder:v];
            push();
            pad_refresh();
            LOG("Game window gained keyboard focus");
            mtl_link_resume();
            dm_focus_set(1);
        }];
        [nc addObserverForName:NSWindowDidMiniaturizeNotification object:win queue:nil usingBlock:^(NSNotification *n) { (void)n; dm_focus_set(3); dm_audio_suspend(1); dm_gfx_suspend(1); }];
        [nc addObserverForName:NSWindowDidDeminiaturizeNotification object:win queue:nil usingBlock:^(NSNotification *n) { (void)n; dm_gfx_suspend(0); dm_audio_suspend(0); dm_focus_set(2); }];
        // Guest thread: 64 MiB stack (the Switch main thread stack is specified by npdm; the host gives plenty)
        static guest_arg ga; ga.fn = guest;
        pthread_attr_t a; pthread_attr_init(&a); pthread_attr_setstacksize(&a, 64u << 20);
        pthread_t th; if (pthread_create(&th, &a, guest_tramp, &ga)) die("pthread_create guest");
        [NSApp run];
    }
}

// Software keyboard input box (front.h): the main thread shows an NSAlert + text field and the guest thread waits synchronously for the result. Not shown in windowless mode (returns -1, the caller treats it as cancel)
int front_text_input(const char *title, const char *sub, const char *guide, const char *initial, int max_chars, char *out, int out_cap) {
    if (!g_layer) return -1;
    __block int r = 0;
    __block NSString *text = nil;
    dispatch_sync(dispatch_get_main_queue(), ^{
        NSAlert *a = [NSAlert new];
        a.messageText = title && *title ? @(title) : @"输入";
        NSString *info = [NSString stringWithFormat:@"%s%s%s", sub ? sub : "", sub && *sub && guide && *guide ? "\n" : "", guide ? guide : ""];
        a.informativeText = info;
        [a addButtonWithTitle:@"确定"]; [a addButtonWithTitle:@"取消"];
        NSTextField *f = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 300, 24)];
        f.stringValue = initial ? @(initial) : @"";
        if (guide && *guide) f.placeholderString = @(guide);
        a.accessoryView = f; a.window.initialFirstResponder = f;
        r = [a runModal] == NSAlertFirstButtonReturn;
        text = f.stringValue;
    });
    if (!r) return 0;
    (void)max_chars;                              // Truncation is done uniformly in hle_swkbd.c in UTF-16 units
    snprintf(out, out_cap, "%s", text.UTF8String);
    return 1;
}
