#import <IOKit/hid/IOHIDManager.h>
#include <ctype.h>
#include <math.h>
#include <stdint.h>
#include <stdlib.h>
#include <stdatomic.h>
#include <string.h>
#include <mach/mach_time.h>
#include "dm_log.h"
#include "dm_switch_haptics_state.h"
#include "switch_haptics_mac.h"

enum {
    kSwitchVendorID = 0x057e,
    kSwitchProProductID = 0x2009,
    kSwitchJoyConLeftProductID = 0x2006,
    kSwitchJoyConRightProductID = 0x2007,
    kSwitchSubcommandReportID = 0x01,
    kSwitchRumbleReportID = 0x10,
    kSwitchEnableVibrationSubcommand = 0x48,
    kSwitchRumbleReportLength = 9,
    kSwitchEnableVibrationPayloadLength = 63,
};

static IOHIDManagerRef g_manager;
static IOHIDDeviceRef g_device;
static char g_transport[32];
static int g_report_length;
static int g_max_output_report_length;
static int g_logged_failure;
static int g_logged_success;
static int g_have_last_report;
static uint8_t g_last_rumble_report[8];
static uint8_t g_packet_counter;
static int g_controller_match;
static int g_input_callback_registered;
static DmSwitchHapticsRetry g_rumble_retry;
static DmSwitchHapticsPendingFrame g_pending_frame;
static uint8_t g_input_report[512];
static _Atomic int g_raw_supported;

static void send_rumble_frame(const DmVibrationFrame *frame);
static void select_device(void);
static void release_device(void);

static uint64_t switch_haptics_now_ns(void) {
    static mach_timebase_info_data_t timebase;
    if (!timebase.denom) mach_timebase_info(&timebase);
    return (uint64_t)((long double)mach_absolute_time() * timebase.numer /
                      timebase.denom);
}

static int input_report_acknowledges_rumble_enable(const uint8_t *report,
                                                   CFIndex report_length,
                                                   uint32_t report_id) {
    if (!report || report_id != 0x21) return 0;
    // IOHID callbacks receive the report ID separately on macOS. Accept the
    // full on-wire form as well so the parser remains protocol-testable.
    size_t ack_offset = report_length >= 15 && report[0] == 0x21 ? 13 : 12;
    size_t subcommand_offset = ack_offset + 1;
    if (report_length <= (CFIndex)subcommand_offset ||
        report[subcommand_offset] != kSwitchEnableVibrationSubcommand)
        return 0;
    return (report[ack_offset] & 0x80) ? 1 : -1;
}

static int io_result_indicates_disconnect(IOReturn result) {
    return result == kIOReturnNoDevice || result == kIOReturnNotOpen ||
        result == kIOReturnOffline || result == kIOReturnNotResponding;
}

static void handle_device_loss(IOHIDDeviceRef sender) {
    if (!sender || sender != g_device) return;
    DmSwitchHapticsRetry retry = g_rumble_retry;
    DmSwitchHapticsPendingFrame pending = g_pending_frame;
    dm_switch_haptics_mark_output_failed(&g_raw_supported, &retry, NULL, NULL,
                                         switch_haptics_now_ns());
    release_device();
    // release_device clears protocol state, but the newest frame and retry
    // deadline still belong to the active GameController selection.
    g_rumble_retry = retry;
    g_pending_frame = pending;
    select_device();
}

static void input_report_callback(void *context, IOReturn result, void *sender,
                                  IOHIDReportType type, uint32_t report_id,
                                  uint8_t *report, CFIndex report_length) {
    (void)context;
    if (result != kIOReturnSuccess) {
        if (io_result_indicates_disconnect(result))
            handle_device_loss((IOHIDDeviceRef)sender);
        return;
    }
    if (type != kIOHIDReportTypeInput) return;
    if (!dm_switch_haptics_ack_is_current(sender, g_device,
                                          g_rumble_retry.request_pending))
        return;
    int ack = input_report_acknowledges_rumble_enable(report, report_length, report_id);
    if (!ack) return;
    dm_switch_haptics_mark_enable_ack(&g_rumble_retry, ack > 0,
                                      switch_haptics_now_ns());
    if (ack < 0) {
        DM_LOG_WARN("controller", "Switch HID rumble-enable subcommand was rejected");
        return;
    }
    atomic_store(&g_raw_supported, 1);
    DM_LOG_INFO("controller", "Switch HID rumble-enable acknowledgement received");
    DmVibrationFrame pending;
    if (dm_switch_haptics_take_pending(&g_pending_frame, &pending))
        send_rumble_frame(&pending);
}

static int string_contains(const char *haystack, const char *needle) {
    if (!haystack || !needle || !*needle) return 0;
    size_t length = strlen(needle);
    for (; *haystack; haystack++) {
        size_t i = 0;
        while (i < length && haystack[i] &&
               tolower((unsigned char)haystack[i]) == tolower((unsigned char)needle[i]))
            i++;
        if (i == length) return 1;
    }
    return 0;
}

static int name_is_nintendo_switch(const char *name, const char *category) {
    // GameController may expose only "Pro Controller" / "Joy-Con" and the
    // generic category ("Gamepad"). The HID vendor/product allowlist below
    // remains the authoritative model filter before any raw report is sent.
    return string_contains(name, "nintendo") || string_contains(category, "switch") ||
        string_contains(name, "pro controller") || string_contains(name, "joy-con") ||
        string_contains(category, "joy-con");
}

static int property_int(IOHIDDeviceRef device, CFStringRef key) {
    CFTypeRef value = IOHIDDeviceGetProperty(device, key);
    return value && CFGetTypeID(value) == CFNumberGetTypeID()
        ? ({ int result = 0; CFNumberGetValue((CFNumberRef)value, kCFNumberIntType, &result); result; })
        : -1;
}

static char *property_string(IOHIDDeviceRef device, CFStringRef key) {
    CFTypeRef value = IOHIDDeviceGetProperty(device, key);
    if (!value || CFGetTypeID(value) != CFStringGetTypeID()) return NULL;
    CFIndex length = CFStringGetMaximumSizeForEncoding(CFStringGetLength(value),
                                                       kCFStringEncodingUTF8) + 1;
    char *result = malloc((size_t)length);
    if (!result) return NULL;
    if (!CFStringGetCString(value, result, length, kCFStringEncodingUTF8)) {
        free(result);
        return NULL;
    }
    return result;
}

static int device_transport(IOHIDDeviceRef device, char *out, size_t out_size) {
    char *value = property_string(device, CFSTR(kIOHIDTransportKey));
    if (!value) return 0;
    int copied = snprintf(out, out_size, "%s", value) < (int)out_size;
    free(value);
    return copied;
}

static int device_report_length(IOHIDDeviceRef device) {
    CFTypeRef value = IOHIDDeviceGetProperty(device, CFSTR(kIOHIDMaxOutputReportSizeKey));
    if (!value || CFGetTypeID(value) != CFNumberGetTypeID()) return -1;
    int result = -1;
    return CFNumberGetValue(value, kCFNumberIntType, &result) ? result : -1;
}

static void select_device(void) {
    if (!g_controller_match) return;
    if (g_device) return;
    if (!g_manager) g_manager = IOHIDManagerCreate(kCFAllocatorDefault, kIOHIDOptionsTypeNone);
    if (!g_manager) return;
    IOHIDManagerOpen(g_manager, kIOHIDOptionsTypeNone);
    CFSetRef devices = IOHIDManagerCopyDevices(g_manager);
    if (!devices) return;
    CFIndex count = CFSetGetCount(devices);
    IOHIDDeviceRef *list = calloc((size_t)count, sizeof(*list));
    if (list) {
        CFSetGetValues(devices, (const void **)list);
        for (CFIndex i = 0; i < count; i++) {
            int vendor = property_int(list[i], CFSTR(kIOHIDVendorIDKey));
            int product = property_int(list[i], CFSTR(kIOHIDProductIDKey));
            if (vendor != kSwitchVendorID ||
                (product != kSwitchProProductID &&
                 product != kSwitchJoyConLeftProductID &&
                 product != kSwitchJoyConRightProductID))
                continue;
            if (IOHIDDeviceOpen(list[i], kIOHIDOptionsTypeNone) != kIOReturnSuccess) continue;
            g_device = (IOHIDDeviceRef)CFRetain(list[i]);
            g_transport[0] = '\0';
            device_transport(g_device, g_transport, sizeof g_transport);
            g_max_output_report_length = device_report_length(g_device);
            // Report ID is passed separately to IOHIDDeviceSetReport. The
            // rumble-only report carries a packet counter and 8 rumble bytes.
            g_report_length = kSwitchRumbleReportLength;
            if (g_max_output_report_length >= 0 &&
                g_max_output_report_length < kSwitchRumbleReportLength) {
                DM_LOG_WARN("controller",
                            "Switch HID output report descriptor smaller than expected: size=%d",
                            g_max_output_report_length);
                g_report_length = g_max_output_report_length;
            }
            IOHIDDeviceScheduleWithRunLoop(g_device, CFRunLoopGetCurrent(),
                                           kCFRunLoopDefaultMode);
            IOHIDDeviceRegisterInputReportCallback(g_device, g_input_report,
                                                   sizeof g_input_report,
                                                   input_report_callback, NULL);
            g_input_callback_registered = 1;
            DM_LOG_INFO("controller",
                        "Raw Switch HID output ready: vendor=%#x product=%#x transport=%s output_report_size=%d",
                        vendor, product, g_transport[0] ? g_transport : "unknown", g_report_length);
            break;
        }
        free(list);
    }
    CFRelease(devices);
}

static void release_device(void) {
    atomic_store(&g_raw_supported, 0);
    if (g_device) {
        if (g_input_callback_registered) {
            IOHIDDeviceRegisterInputReportCallback(g_device, g_input_report,
                                                   sizeof g_input_report, NULL, NULL);
            IOHIDDeviceUnscheduleFromRunLoop(g_device, CFRunLoopGetCurrent(),
                                             kCFRunLoopDefaultMode);
            g_input_callback_registered = 0;
        }
        IOHIDDeviceClose(g_device, kIOHIDOptionsTypeNone);
        CFRelease(g_device);
        g_device = NULL;
    }
    g_transport[0] = '\0';
    g_report_length = 0;
    g_max_output_report_length = 0;
    g_logged_failure = 0;
    g_logged_success = 0;
    g_have_last_report = 0;
    memset(g_last_rumble_report, 0, sizeof g_last_rumble_report);
    g_packet_counter = 0;
    g_rumble_retry = (DmSwitchHapticsRetry){0};
    g_pending_frame = (DmSwitchHapticsPendingFrame){0};
}

const char *switch_haptics_transport_for_test(void) { return g_transport; }
int switch_haptics_report_length_for_test(void) { return g_report_length; }

static uint8_t encode_frequency(float frequency) {
    if (!(frequency > 0.f)) frequency = 160.f;
    if (frequency > 1252.f) frequency = 1252.f;
    int value = (int)lrintf(log2f(frequency / 10.f) * 32.f);
    return (uint8_t)(value < 0 ? 0 : value > 255 ? 255 : value);
}

static uint8_t encode_low_frequency(float frequency) {
    // The low-band field tops out at 0x7f, corresponding to about 626 Hz.
    if (!(frequency > 0.f)) frequency = 160.f;
    if (frequency > 626.286f) frequency = 626.286f;
    uint8_t encoded = encode_frequency(frequency);
    return encoded > 0x40 ? (uint8_t)(encoded - 0x40) : 1;
}

static float normalized_frequency(float frequency, float fallback) {
    return isfinite(frequency) && frequency > 0.f ? frequency : fallback;
}

static uint8_t encode_amplitude(float amplitude) {
    if (!(amplitude > 0.f)) return 0;
    if (amplitude > 1.f) amplitude = 1.f;
    int value;
    if (amplitude > 0.23f)
        value = (int)lrintf(log2f(8.7f * amplitude) * 32.f);
    else if (amplitude > 0.12f)
        value = (int)lrintf(log2f(17.f * amplitude) * 16.f);
    else
        value = 2;
    return (uint8_t)(value < 2 ? 2 : value > 0x7f ? 0x7f : value);
}

static void encode_rumble(uint8_t *out, float low_amplitude, float low_frequency,
                          float high_amplitude, float high_frequency) {
    uint8_t encoded_high_frequency = encode_frequency(high_frequency);
    uint8_t encoded_high_amplitude = encode_amplitude(high_amplitude);
    uint8_t encoded_low_amplitude = encode_amplitude(low_amplitude);
    uint16_t high_frequency_code = encoded_high_frequency >= 0x60
        ? (uint16_t)(encoded_high_frequency - 0x60) * 4 : 0;
    uint8_t low_frequency_code = encode_low_frequency(low_frequency);
    uint16_t high_amplitude_code = (uint16_t)encoded_high_amplitude * 2;
    uint16_t low_amplitude_code = (uint16_t)(encoded_low_amplitude / 2 + 0x40);
    out[0] = (uint8_t)high_frequency_code;
    out[1] = (uint8_t)(high_amplitude_code + (high_frequency_code >> 8));
    out[2] = (uint8_t)(low_frequency_code + (low_amplitude_code >> 8));
    out[3] = (uint8_t)low_amplitude_code;
}

static int encode_enable_vibration_report(uint8_t packet_counter,
                                          uint8_t out[kSwitchEnableVibrationPayloadLength]) {
    if (!out) return 0;
    DmVibrationFrame neutral = {.low_frequency = 160.f, .high_frequency = 320.f};
    // Report 0x01 is 64 bytes on the wire; IOHIDDeviceSetReport receives the
    // report ID separately, so this buffer contains its 63-byte payload.
    memset(out, 0, kSwitchEnableVibrationPayloadLength);
    out[0] = packet_counter & 0x0f;
    switch_haptics_encode_report(&neutral, out + 1);
    out[9] = kSwitchEnableVibrationSubcommand;
    out[10] = 0x01;
    return kSwitchEnableVibrationPayloadLength;
}

static int enable_rumble(void) {
    if (!g_device || (g_max_output_report_length >= 0 &&
                      g_max_output_report_length < kSwitchEnableVibrationPayloadLength))
        return 0;
    uint64_t now_ns = switch_haptics_now_ns();
    if (g_rumble_retry.request_pending &&
        now_ns - g_rumble_retry.sent_at_ns < DM_SWITCH_HAPTICS_RETRY_NS)
        return 1;
    if (!dm_switch_haptics_retry_ready(&g_rumble_retry, now_ns))
        return 0;
    uint8_t report[kSwitchEnableVibrationPayloadLength] = {0};
    if (encode_enable_vibration_report(g_packet_counter, report) != sizeof report)
        return 0;
    IOReturn result = IOHIDDeviceSetReport(g_device, kIOHIDReportTypeOutput,
                                           kSwitchSubcommandReportID, report,
                                           sizeof report);
    if (result != kIOReturnSuccess) {
        if (!g_logged_failure) {
            g_logged_failure = 1;
            DM_LOG_WARN("controller", "Switch HID rumble-enable write failed: kr=%d", result);
        }
        dm_switch_haptics_mark_output_failed(&g_raw_supported, &g_rumble_retry,
                                             NULL, NULL, now_ns);
        if (io_result_indicates_disconnect(result)) {
            handle_device_loss(g_device);
        }
        return 0;
    }
    g_packet_counter = (uint8_t)((g_packet_counter + 1) & 0x0f);
    dm_switch_haptics_mark_enable_sent(&g_rumble_retry, now_ns);
    DM_LOG_INFO("controller", "Switch HID rumble-enable subcommand sent; waiting for acknowledgement");
    return 1;
}

static void wait_for_rumble_enable(void) {
    CFAbsoluteTime deadline = CFAbsoluteTimeGetCurrent() + 0.25;
    while (!atomic_load(&g_raw_supported) && CFAbsoluteTimeGetCurrent() < deadline)
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.01, false);
}

void switch_haptics_init_for_controller(const char *controller_name,
                                        const char *controller_category) {
    if (!name_is_nintendo_switch(controller_name, controller_category)) {
        g_controller_match = 0;
        release_device();
        return;
    }
    // GameController does not expose an HID device identifier. Filtering on the
    // selected controller's localized name is more restrictive than accepting any
    // Nintendo HID device, while still avoiding private API use.
    g_controller_match = 1;
    select_device();
    if (g_device && !atomic_load(&g_raw_supported)) {
        enable_rumble();
        wait_for_rumble_enable();
    }
}

int switch_haptics_supported(void) {
    return atomic_load(&g_raw_supported);
}

void switch_haptics_encode_report(const DmVibrationFrame *frame, uint8_t out[8]) {
    if (!frame || !out) return;
    // Each actuator receives the same low/high-band pair: the Switch value is
    // spectral, not a left/right spatial pair.
    encode_rumble(out + 0, frame->low_amplitude, frame->low_frequency,
                  frame->high_amplitude, frame->high_frequency);
    memcpy(out + 4, out, 4);
}

static int encode_output_report(const DmVibrationFrame *frame,
                                uint8_t packet_counter, uint8_t out[9]) {
    if (!frame || !out) return 0;
    memset(out, 0, 9);
    out[0] = packet_counter & 0x0f;
    switch_haptics_encode_report(frame, out + 1);
    return 9;
}

static void send_rumble_frame(const DmVibrationFrame *frame) {
    if (!g_device || !frame || !atomic_load(&g_raw_supported)) return;
    uint8_t report[9] = {0};
    DmVibrationFrame normalized = *frame;
    normalized.low_frequency = normalized_frequency(frame->low_frequency, 160.f);
    normalized.high_frequency = normalized_frequency(frame->high_frequency, 320.f);
    int expected_length = encode_output_report(&normalized, g_packet_counter, report);
    int report_length = g_report_length > 0 ? g_report_length : kSwitchRumbleReportLength;
    if (report_length != expected_length) {
        if (!g_logged_failure) {
            g_logged_failure = 1;
            DM_LOG_WARN("controller", "Raw Switch HID report size unsupported: %d", report_length);
        }
        return;
    }
    size_t rumble_offset = 1;
    if (g_have_last_report && !memcmp(g_last_rumble_report,
                                     report + rumble_offset,
                                     sizeof g_last_rumble_report))
        return; // The controller retains the current actuator state until the next report.
    IOReturn result = IOHIDDeviceSetReport(g_device, kIOHIDReportTypeOutput,
                                           kSwitchRumbleReportID, report, report_length);
    if (result != kIOReturnSuccess) {
        if (!g_logged_failure) {
            g_logged_failure = 1;
            DM_LOG_WARN("controller", "Raw Switch HID rumble write failed: kr=%d", result);
        }
        g_have_last_report = 0;
        dm_switch_haptics_mark_output_failed(&g_raw_supported, &g_rumble_retry,
                                             &g_pending_frame, frame,
                                             switch_haptics_now_ns());
        if (io_result_indicates_disconnect(result)) {
            handle_device_loss(g_device);
        }
    } else {
        g_logged_failure = 0;
        if (!g_logged_success) {
            g_logged_success = 1;
            DM_LOG_INFO("controller", "Raw Switch HID rumble report accepted by macOS: transport=%s",
                        g_transport[0] ? g_transport : "unknown");
        }
        memcpy(g_last_rumble_report, report + rumble_offset, sizeof g_last_rumble_report);
        g_have_last_report = 1;
        g_packet_counter = (uint8_t)((g_packet_counter + 1) & 0x0f);
    }
}

void switch_haptics_set(const DmVibrationFrame *frame) {
    if (!g_controller_match || !frame) return;
    select_device();
    if (!g_device) return;
    if (!atomic_load(&g_raw_supported)) {
        dm_switch_haptics_store_latest(&g_pending_frame, frame);
        enable_rumble();
        return;
    }
    send_rumble_frame(frame);
}

void switch_haptics_stop(void) {
    if (!g_device) return;
    DmVibrationFrame frame = {.low_frequency = 160.f, .high_frequency = 320.f};
    switch_haptics_set(&frame);
}
