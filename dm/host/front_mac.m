// Mac front end: with DM_WINDOW=1 open a window (CAMetalLayer, for the graphics backend to present frames) + keyboard → dm_input; the guest runs on a large-stack thread instead and the main thread belongs to AppKit.
// Without DM_WINDOW: the guest runs directly on the current thread, behaving the same as with no front end (windowless tests use this).
// Key map (Nintendo layout): WASD left stick, arrow keys D-pad, J=A K=B U=X I=Y, Q=L E=R, Z=ZL C=ZR, F=press left stick G=press right stick, Return=+ Tab=−.
#import <Cocoa/Cocoa.h>
#import <Foundation/Foundation.h>
#import <GameController/GameController.h>
#import <QuartzCore/CAMetalLayer.h>
#import <Metal/Metal.h>
#import <CoreHaptics/CoreHaptics.h>
#include "dm.h"
#include "dm_vibration_queue.h"
#include "dm_vibration_timing.h"
#include "dm_vibration_haptics.h"
#include "dm_log.h"
#include "dm_input.h"
#include "dm_padmap.h"
#include "../gfx/nvn/nvn_mtl.h"
#include "front.h"
#include "hle.h"
#import "perf_hud_mac.h"
#import "cheats_mac.h"
#import "switch_haptics_mac.h"
#include <signal.h>
#include <pthread.h>
#include <stdatomic.h>

#define HAPTICS_CHANNEL_COUNT 2

static pthread_mutex_t g_vibration_queue_mu = PTHREAD_MUTEX_INITIALIZER;
static DmVibrationQueue g_vibration_queue;
static DmVibrationTimeline g_vibration_timeline;
static _Atomic uint64_t g_vibration_generation = 1;
static BOOL g_vibration_app_active = YES;
static BOOL g_vibration_window_active = YES;

static void pad_apply_vibration_frame(const DmVibrationFrame *frame);
static void pad_start_haptics(GCController *controller);
static void vibration_drain(void);

static void vibration_cancel_pending(void) {
    atomic_fetch_add(&g_vibration_generation, 1);
    pthread_mutex_lock(&g_vibration_queue_mu);
    g_vibration_queue = (DmVibrationQueue){0};
    pthread_mutex_unlock(&g_vibration_queue_mu);
    g_vibration_timeline = (DmVibrationTimeline){0};
}

static void vibration_drain(void) {
    while (1) {
        pthread_mutex_lock(&g_vibration_queue_mu);
        DmVibrationFrame frame = {0};
        int have_frame = dm_vibration_queue_pop(&g_vibration_queue, &frame);
        if (!have_frame) {
            g_vibration_queue.drain_scheduled = 0;
            g_vibration_timeline = (DmVibrationTimeline){0};
        }
        pthread_mutex_unlock(&g_vibration_queue_mu);
        if (!have_frame) return;
        uint64_t now_ns_value = now_ns();
        uint64_t target_ns = dm_vibration_timeline_schedule(
            &g_vibration_timeline, &frame, now_ns_value);
        if (target_ns > now_ns_value) {
            uint64_t generation = atomic_load(&g_vibration_generation);
            DmVibrationFrame scheduled = frame;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(target_ns - now_ns_value)),
                           dispatch_get_main_queue(), ^{
                if (atomic_load(&g_vibration_generation) != generation) return;
                pad_apply_vibration_frame(&scheduled);
                vibration_drain();
            });
            return;
        }
        pad_apply_vibration_frame(&frame);
    }
}

static void vibration_push(const DmVibrationFrame *frame) {
    if (!frame) return;
    int schedule_drain = 0;
    pthread_mutex_lock(&g_vibration_queue_mu);
    dm_vibration_queue_push(&g_vibration_queue, frame);
    if (!g_vibration_queue.drain_scheduled) {
        g_vibration_queue.drain_scheduled = 1;
        schedule_drain = 1;
    }
    pthread_mutex_unlock(&g_vibration_queue_mu);
    if (!schedule_drain) return;
    dispatch_async(dispatch_get_main_queue(), ^{ vibration_drain(); });
}

static CAMetalLayer *g_layer;
static uint64_t g_btn, g_key_btn, g_mouse_btn;
static int g_w, g_a, g_s, g_d;
static int g_walk, g_shift;
static int g_mouse_left, g_mouse_right, g_mouse_middle;
static int32_t g_mouse_rx, g_mouse_ry;
static uint64_t g_mouse_motion_seq;
static GCController *g_pad_controller;
static NSArray<GCController *> *g_pad_controllers;
typedef struct {
    CHHapticEngine *engine;
    id<CHHapticPatternPlayer> player;
    BOOL playing;
} DmHapticsChannel;
static _Atomic int g_vibration_enabled = 1;
static _Atomic int g_pad_haptics_supported;
static _Atomic int g_haptics_request_logged;
static _Atomic int g_pad_input_logged;
static DmHapticsChannel g_pad_haptics_channels[HAPTICS_CHANNEL_COUNT];
static NSUInteger g_pad_haptics_channel_count;
static float g_haptics_low, g_haptics_high;
static float g_haptics_low_frequency, g_haptics_high_frequency;
static DmMacPerfHUD *g_perf_hud;
static DmMacCheats *g_cheats;

static GCDeviceHaptics *controller_haptics(GCController *controller) {
    if (@available(macOS 11.0, *)) return controller.haptics;
    return nil;
}
void *front_metal_layer(void) { return (__bridge void *)g_layer; }
static int ds_layout(void) { return !strcmp(DM_GAME_MAC_LAYOUT, "dark_souls_pc"); }
// The original game's 16:9 constants, behavior unchanged; DM_GAME_RES=<width>x<height> (docked mode; handheld scaled by 720/900) is only for side-by-side comparison with iOS widescreen
uint64_t front_game_res(int docked) {
    unsigned w, h; const char *e = getenv("DM_GAME_RES");
    if (e && sscanf(e, "%ux%u", &w, &h) == 2) return docked ? (uint64_t)h << 32 | w : (uint64_t)(h * 4 / 5) << 32 | (w * 4 / 5 + 3) / 4 * 4;
    return docked ? 900ull << 32 | 1600 : 720ull << 32 | 1280;
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
static void pad_stop_core_haptics(void) {
    for (NSUInteger i = 0; i < g_pad_haptics_channel_count; i++) {
        DmHapticsChannel *channel = &g_pad_haptics_channels[i];
        NSError *error = nil;
        if (channel->player && ![channel->player stopAtTime:CHHapticTimeImmediate error:&error])
            DM_LOG_WARN("controller", "Could not stop haptics channel %lu: %s",
                        (unsigned long)i, error.localizedDescription.UTF8String ?: "unknown error");
        channel->playing = NO;
    }
}
static void pad_stop_vibration(void) {
    g_haptics_low = g_haptics_high = 0.f;
    g_haptics_low_frequency = g_haptics_high_frequency = 0.f;
    pad_stop_core_haptics();
    switch_haptics_stop();
}
static void pad_discard_haptics(void) {
    atomic_store(&g_pad_haptics_supported, 0);
    pad_stop_vibration();
    for (NSUInteger i = 0; i < HAPTICS_CHANNEL_COUNT; i++) {
        DmHapticsChannel *channel = &g_pad_haptics_channels[i];
        [channel->engine stopWithCompletionHandler:nil];
        channel->player = nil;
        channel->engine = nil;
    }
    g_pad_haptics_channel_count = 0;
}

static BOOL pad_configure_haptics_channel(DmHapticsChannel *out,
                                          GCDeviceHaptics *haptics,
                                          GCHapticsLocality locality,
                                          NSString *name) {
    DmHapticsChannel channel = {0};
    NSError *error = nil;
    channel.engine = [haptics createEngineWithLocality:locality];
    if (!channel.engine) {
        const char *log_name = name.UTF8String ?: "unknown locality";
        DM_LOG_ERROR("controller", "Could not create haptics engine for %s", log_name);
        return NO;
    }
    channel.engine.playsHapticsOnly = YES;
    channel.engine.stoppedHandler = ^(CHHapticEngineStoppedReason reason) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (reason != CHHapticEngineStoppedReasonNotifyWhenFinished) {
                const char *log_name = name.UTF8String ?: "unknown locality";
                DM_LOG_WARN("controller", "Haptics engine stopped for %s: reason=%ld",
                            log_name, (long)reason);
            }
            for (NSUInteger i = 0; i < HAPTICS_CHANNEL_COUNT; i++) {
                if (g_pad_haptics_channels[i].engine != channel.engine) continue;
                g_pad_haptics_channels[i].playing = NO;
                g_pad_haptics_channels[i].player = nil;
                atomic_store(&g_pad_haptics_supported, 0);
            }
        });
    };
    channel.engine.resetHandler = ^{
        dispatch_async(dispatch_get_main_queue(), ^{
            GCController *controller = g_pad_controller;
            if (!controller) return;
            // Rebuild all channels together because a reset may invalidate either handle.
            pad_discard_haptics();
            if (controller == g_pad_controller) pad_start_haptics(controller);
        });
    };
    if (![channel.engine startAndReturnError:&error]) {
        const char *log_name = name.UTF8String ?: "unknown locality";
        DM_LOG_ERROR("controller", "Could not start haptics engine for %s: %s",
                     log_name, error.localizedDescription.UTF8String ?: "unknown error");
        return NO;
    }
    CHHapticEventParameter *intensity = [[CHHapticEventParameter alloc] initWithParameterID:CHHapticEventParameterIDHapticIntensity value:0.0];
    CHHapticEventParameter *sharpness = [[CHHapticEventParameter alloc] initWithParameterID:CHHapticEventParameterIDHapticSharpness value:0.5];
    CHHapticEventParameter *sustained = [[CHHapticEventParameter alloc] initWithParameterID:CHHapticEventParameterIDSustained value:1.0];
    // The basic player is used deliberately: on macOS the advanced-player
    // factory can fail to connect to gamecontrollerd even for simple patterns.
    // A long continuous event can still be stopped immediately when the game
    // sends a zero frame.
    CHHapticEvent *event = [[CHHapticEvent alloc] initWithEventType:CHHapticEventTypeHapticContinuous parameters:@[intensity, sharpness, sustained] relativeTime:0 duration:3600.0];
    CHHapticPattern *pattern = [[CHHapticPattern alloc] initWithEvents:@[event] parameters:@[] error:&error];
    channel.player = pattern ? [channel.engine createPlayerWithPattern:pattern error:&error] : nil;
    if (!channel.player) {
        const char *log_name = name.UTF8String ?: "unknown locality";
        DM_LOG_ERROR("controller", "Could not create haptics player for %s: %s",
                     log_name, error.localizedDescription.UTF8String ?: "unknown error");
        return NO;
    }
    *out = channel;
    return YES;
}

static void pad_start_haptics(GCController *controller) {
    if (@available(macOS 11.0, *)) {
        GCDeviceHaptics *haptics = controller.haptics;
        atomic_store(&g_pad_haptics_supported, 0);
        if (!haptics) return;
        NSSet<GCHapticsLocality> *supported = haptics.supportedLocalities;
        BOOL split_handles = [supported containsObject:GCHapticsLocalityLeftHandle] &&
            [supported containsObject:GCHapticsLocalityRightHandle];
        BOOL ready = NO;
        if (split_handles) {
            // Some macOS/GameController versions advertise per-handle
            // localities but reject their player connection. Try the precise
            // path first, then fall back to the combined locality instead of
            // disabling vibration for the controller altogether.
            pad_discard_haptics();
            NSArray<GCHapticsLocality> *localities =
                @[GCHapticsLocalityLeftHandle, GCHapticsLocalityRightHandle];
            NSArray<NSString *> *names = @[@"left handle", @"right handle"];
            g_pad_haptics_channel_count = localities.count;
            ready = YES;
            for (NSUInteger i = 0; i < g_pad_haptics_channel_count; i++) {
                if (!pad_configure_haptics_channel(&g_pad_haptics_channels[i], haptics,
                                                   localities[i], names[i])) {
                    ready = NO;
                    break;
                }
            }
        }
        if (!ready) {
            pad_discard_haptics();
            GCHapticsLocality locality = [supported containsObject:GCHapticsLocalityHandles]
                ? GCHapticsLocalityHandles : GCHapticsLocalityDefault;
            g_pad_haptics_channel_count = 1;
            ready = pad_configure_haptics_channel(&g_pad_haptics_channels[0], haptics,
                                                  locality, @"combined handles");
        }
        if (ready) {
            atomic_store(&g_pad_haptics_supported, 1);
            DM_LOG_INFO("controller", "Controller haptics engines and players ready");
        } else {
            pad_discard_haptics();
        }
    }
}
static void pad_apply_haptics(void) {
    DmVibrationHapticsParameters parameters = dm_vibration_haptics_parameters(
        g_haptics_low, g_haptics_low_frequency,
        g_haptics_high, g_haptics_high_frequency);
    if (parameters.intensity <= 0.f) { pad_stop_vibration(); return; }
    for (NSUInteger i = 0; i < g_pad_haptics_channel_count; i++) {
        DmHapticsChannel *channel = &g_pad_haptics_channels[i];
        if (!channel->engine || !channel->player) continue;
        NSError *error = nil;
        if (![channel->engine startAndReturnError:&error]) {
            DM_LOG_ERROR("controller", "Could not start haptics engine for channel %lu: %s",
                         (unsigned long)i, error.localizedDescription.UTF8String ?: "unknown error");
            continue;
        }
        CHHapticDynamicParameter *intensity = [[CHHapticDynamicParameter alloc] initWithParameterID:CHHapticDynamicParameterIDHapticIntensityControl value:parameters.intensity relativeTime:0];
        CHHapticDynamicParameter *sharpness_parameter = [[CHHapticDynamicParameter alloc] initWithParameterID:CHHapticDynamicParameterIDHapticSharpnessControl value:parameters.sharpness relativeTime:0];
        if (!channel->playing) {
            if (![channel->player startAtTime:CHHapticTimeImmediate error:&error]) {
                DM_LOG_ERROR("controller", "Could not start haptics player for channel %lu: %s",
                             (unsigned long)i, error.localizedDescription.UTF8String ?: "unknown error");
                continue;
            }
            channel->playing = YES;
        }
        if (![channel->player sendParameters:@[intensity, sharpness_parameter] atTime:CHHapticTimeImmediate error:&error])
            DM_LOG_ERROR("controller", "Could not update haptics for channel %lu: %s",
                         (unsigned long)i, error.localizedDescription.UTF8String ?: "unknown error");
    }
}
static BOOL pad_haptics_ready(void) {
    if (!g_pad_haptics_channel_count) return NO;
    for (NSUInteger i = 0; i < g_pad_haptics_channel_count; i++)
        if (!g_pad_haptics_channels[i].engine || !g_pad_haptics_channels[i].player) return NO;
    return YES;
}
static void pad_apply_vibration_frame(const DmVibrationFrame *frame) {
    if (!frame) return;
    float low = isfinite(frame->low_amplitude) ? fminf(1.f, fmaxf(0.f, frame->low_amplitude)) : 0.f;
    float high = isfinite(frame->high_amplitude) ? fminf(1.f, fmaxf(0.f, frame->high_amplitude)) : 0.f;
    float low_frequency = isfinite(frame->low_frequency) && frame->low_frequency > 0.f
        ? frame->low_frequency : 160.f;
    float high_frequency = isfinite(frame->high_frequency) && frame->high_frequency > 0.f
        ? frame->high_frequency : 320.f;
    if (!atomic_load(&g_vibration_enabled) || !g_pad_controller ||
        !g_vibration_app_active || !g_vibration_window_active) {
        g_haptics_low = g_haptics_high = 0.f;
        g_haptics_low_frequency = g_haptics_high_frequency = 0.f;
        pad_stop_vibration();
        return;
    }
    if ((low > 0.f || high > 0.f) && !atomic_exchange(&g_haptics_request_logged, 1))
        DM_LOG_INFO("controller", "First nonzero game vibration received: low_amp=%.3f low_hz=%.3f high_amp=%.3f high_hz=%.3f",
                    low, low_frequency, high, high_frequency);
    g_haptics_low = low;
    g_haptics_high = high;
    g_haptics_low_frequency = low_frequency;
    g_haptics_high_frequency = high_frequency;
    // Let the raw Switch backend retain the latest frame while its enable
    // acknowledgement is still in flight. It is a no-op for other devices.
    switch_haptics_set(frame);
    // Preserve Switch HD Rumble by sending its native two-band values to the
    // Nintendo HID device. Core Haptics is the fallback for devices such as
    // DualSense that do not expose this Switch protocol.
    if (switch_haptics_supported()) {
        if (atomic_load(&g_pad_haptics_supported)) pad_stop_core_haptics();
        return;
    }
    if (low > 0.f || high > 0.f) {
        if (!atomic_load(&g_pad_haptics_supported) || !pad_haptics_ready())
            pad_start_haptics(g_pad_controller);
        if (!atomic_load(&g_pad_haptics_supported)) {
            switch_haptics_set(frame);
            return;
        }
        pad_apply_haptics();
    } else pad_stop_vibration();
}
void front_vibration(const DmVibrationFrame *frame) {
    if (!frame || !atomic_load(&g_vibration_enabled)) return;
    vibration_push(frame);
}
int front_vibration_supported(void) {
    return atomic_load(&g_vibration_enabled) &&
        (atomic_load(&g_pad_haptics_supported) || switch_haptics_supported());
}
void front_vibration_set_enabled(int enabled) {
    dispatch_async(dispatch_get_main_queue(), ^{
        atomic_store(&g_vibration_enabled, enabled != 0);
        [NSUserDefaults.standardUserDefaults setBool:enabled != 0 forKey:@"DmVibrationEnabled"];
        if (!enabled) { vibration_cancel_pending(); pad_stop_vibration(); }
    });
}
static void pad_read(GCExtendedGamepad *g) {
    if (!g) return;
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
    int32_t lx = pad_axis(g.leftThumbstick.xAxis.value);
    int32_t ly = pad_axis(g.leftThumbstick.yAxis.value);
    int32_t rx = pad_axis(g.rightThumbstick.xAxis.value);
    int32_t ry = pad_axis(g.rightThumbstick.yAxis.value);
    dm_pad_set(buttons, lx, ly, rx, ry);
    if ((buttons || lx || ly || rx || ry) && !atomic_exchange(&g_pad_input_logged, 1))
        DM_LOG_INFO("controller", "First nonzero controller input received: buttons=%#llx left=(%d,%d) right=(%d,%d)",
                    (unsigned long long)buttons, lx, ly, rx, ry);
}
static void pad_select_controller(GCController *selected) {
    if (selected != g_pad_controller) {
        vibration_cancel_pending();
        pad_discard_haptics();
        g_pad_controller = selected;
        atomic_store(&g_pad_haptics_supported, 0);
        if (selected) {
            switch_haptics_init_for_controller(selected.vendorName.UTF8String,
                                               selected.productCategory.UTF8String);
            pad_start_haptics(selected);
            const char *vendor = selected.vendorName.UTF8String ?: "unknown";
            const char *category = selected.productCategory.UTF8String ?: "unknown";
            DM_LOG_INFO("controller", "Mac controller connected: category=%s vendor=%s haptics=%d",
                        category, vendor, controller_haptics(selected) != nil);
        } else {
            switch_haptics_init_for_controller(NULL, NULL);
            LOG("Mac controller disconnected");
        }
    }
    if (selected) pad_read(selected.extendedGamepad); else pad_clear();
    atomic_store(&g_pad_haptics_supported,
                 g_pad_haptics_channel_count > 0 && pad_haptics_ready());
}
static void pad_refresh(void) {
    NSMutableArray<GCController *> *controllers = [NSMutableArray array];
    for (GCController *controller in GCController.controllers)
        if (controller.extendedGamepad) [controllers addObject:controller];
    if (![controllers isEqualToArray:g_pad_controllers]) {
        for (GCController *controller in g_pad_controllers)
            controller.extendedGamepad.valueChangedHandler = nil;
        g_pad_controllers = [controllers copy];
        for (GCController *controller in g_pad_controllers) {
            __weak GCController *weakController = controller;
            controller.extendedGamepad.valueChangedHandler = ^(GCExtendedGamepad *gamepad, GCControllerElement *element) {
                (void)element;
                GCController *source = weakController;
                if (!source) return;
                void (^publishInput)(void) = ^{
                    if (![g_pad_controllers containsObject:source]) return;
                    pad_select_controller(source);
                    if (gamepad == source.extendedGamepad) pad_read(gamepad);
                };
                if (NSThread.isMainThread) publishInput();
                else dispatch_async(dispatch_get_main_queue(), publishInput);
            };
        }
    }
    GCController *current = GCController.current;
    if (current && current.extendedGamepad && [g_pad_controllers containsObject:current])
        pad_select_controller(current);
    else if (!g_pad_controller || ![g_pad_controllers containsObject:g_pad_controller])
        pad_select_controller(g_pad_controllers.firstObject);
}
static void pad_poll(void) {
    if (g_pad_controller && [g_pad_controllers containsObject:g_pad_controller])
        pad_read(g_pad_controller.extendedGamepad);
    else
        pad_clear();
}
static NSMenuItem *g_vibration_menu_item;
@interface DmVibrationMenuTarget : NSObject
- (void)toggleVibration:(NSMenuItem *)item;
@end
@implementation DmVibrationMenuTarget
- (void)toggleVibration:(NSMenuItem *)item {
    item.state = item.state == NSControlStateValueOn ? NSControlStateValueOff : NSControlStateValueOn;
    front_vibration_set_enabled(item.state == NSControlStateValueOn);
}
@end
static DmVibrationMenuTarget *g_vibration_menu_target;
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
        v.layer = g_layer;
        win.acceptsMouseMovedEvents = YES;
        [win center];
        [NSApp activateIgnoringOtherApps:YES];
        [win makeKeyAndOrderFront:nil];
        g_vibration_app_active = NSApp.isActive;
        g_vibration_window_active = win.isKeyWindow;
        win.initialFirstResponder = v;
        [win makeFirstResponder:v];
        atomic_store(&g_vibration_enabled, [NSUserDefaults.standardUserDefaults objectForKey:@"DmVibrationEnabled"]
            ? [NSUserDefaults.standardUserDefaults boolForKey:@"DmVibrationEnabled"] : YES);
        g_perf_hud = [[DmMacPerfHUD alloc] initWithWindow:win device:g_layer.device];
        g_cheats = [[DmMacCheats alloc] initWithWindow:win];
        NSMenu *applicationMenu = NSApp.mainMenu.itemArray.firstObject.submenu;
        if (applicationMenu) {
            g_vibration_menu_item = [[NSMenuItem alloc] initWithTitle:@"Controller Vibration" action:@selector(toggleVibration:) keyEquivalent:@""];
            g_vibration_menu_target = [DmVibrationMenuTarget new];
            g_vibration_menu_item.target = g_vibration_menu_target;
            g_vibration_menu_item.state = atomic_load(&g_vibration_enabled) ? NSControlStateValueOn : NSControlStateValueOff;
            [applicationMenu addItem:g_vibration_menu_item];
        }
        NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
        [nc addObserverForName:NSApplicationWillResignActiveNotification object:NSApp queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) {
            (void)n; g_vibration_app_active = NO; vibration_cancel_pending(); pad_stop_vibration();
        }];
        [nc addObserverForName:NSApplicationDidBecomeActiveNotification object:NSApp queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) {
            (void)n; g_vibration_app_active = YES; g_vibration_window_active = win.isKeyWindow;
        }];
        [nc addObserverForName:GCControllerDidConnectNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) {
            (void)n; pad_refresh();
        }];
        [nc addObserverForName:GCControllerDidDisconnectNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) {
            (void)n; pad_refresh();
        }];
        [nc addObserverForName:GCControllerDidBecomeCurrentNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) {
            (void)n; pad_refresh();
        }];
        [nc addObserverForName:GCControllerDidStopBeingCurrentNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) {
            (void)n; pad_refresh();
        }];
        pad_refresh();
        [NSTimer scheduledTimerWithTimeInterval:1.0 / 60.0 repeats:YES block:^(NSTimer *timer) {
            (void)timer;
            pad_poll();
        }];
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
                                                      usingBlock:^(NSNotification *n) { (void)n; vibration_cancel_pending(); pad_stop_vibration(); exit(0); }];
        // Lifecycle (hle.h / dm.h): focus lost → 2, focus regained → 1; minimized → 3 + audio paused + GPU suspended, restored → resume (followed by focus regained → 1)
        [nc addObserverForName:NSWindowDidResignKeyNotification object:win queue:nil usingBlock:^(NSNotification *n) {
            (void)n;
            g_vibration_window_active = NO;
            vibration_cancel_pending();
            pad_stop_vibration();
            // A native text dialog can consume the key-up that opened it.
            g_btn = g_key_btn = g_mouse_btn = 0;
            g_w = g_a = g_s = g_d = g_walk = g_shift = 0;
            g_mouse_left = g_mouse_right = g_mouse_middle = 0;
            g_mouse_rx = g_mouse_ry = 0; ++g_mouse_motion_seq;
            push(); pad_clear(); dm_touch_set(NULL, 0);
            LOG("Game window lost keyboard focus");
            if (!win.miniaturized) dm_focus_set(2);
        }];
        [nc addObserverForName:NSWindowDidBecomeKeyNotification object:win queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) {
            (void)n; g_vibration_window_active = YES;
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
        [nc addObserverForName:NSWindowDidMiniaturizeNotification object:win queue:nil usingBlock:^(NSNotification *n) { (void)n; g_vibration_window_active = NO; vibration_cancel_pending(); pad_stop_vibration(); dm_focus_set(3); dm_audio_suspend(1); dm_gfx_suspend(1); }];
        [nc addObserverForName:NSWindowDidDeminiaturizeNotification object:win queue:nil usingBlock:^(NSNotification *n) { (void)n; g_vibration_window_active = win.isKeyWindow; dm_gfx_suspend(0); dm_audio_suspend(0); dm_focus_set(2); }];
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
