#include "../switch_haptics_mac.m"
#include "../dm_switch_haptics_state.h"
#include <assert.h>
#include <math.h>
#include <string.h>

static void assert_name_selection(void) {
    // Direct calls avoid opening real HID devices while covering name filtering.
    assert(name_is_nintendo_switch("Pro Controller", "Switch Pro Controller"));
    assert(name_is_nintendo_switch("Pro Controller", "Gamepad"));
    assert(name_is_nintendo_switch("Nintendo Switch Pro Controller", NULL));
    assert(name_is_nintendo_switch("Nintendo", "Gamepad"));
    assert(!name_is_nintendo_switch("DualSense Wireless Controller", "DualSense"));
    // Do not invoke the device-opening path in tests; a real controller may be connected.
    switch_haptics_init_for_controller("DualSense Wireless Controller", NULL);
    switch_haptics_init_for_controller(NULL, NULL);
    assert(*switch_haptics_transport_for_test() == '\0');
    assert(switch_haptics_report_length_for_test() == 0);
}

int main(void) {
    assert_name_selection();
    assert(device_report_size_allows_report(-1, kSwitchRumbleReportLength));
    assert(!device_report_size_allows_report(8, kSwitchRumbleReportLength));
    assert(device_report_size_allows_report(9, kSwitchRumbleReportLength));
    assert(device_report_size_allows_report(10, kSwitchRumbleReportLength));
    assert(!device_report_size_allows_report(62, kSwitchEnableVibrationReportLength));
    assert(device_report_size_allows_report(63, kSwitchEnableVibrationReportLength));
    assert(device_report_size_allows_report(64, kSwitchEnableVibrationReportLength));
    DmSwitchHapticsRetry retry = {0};
    uint64_t next_scan_ns = 0;
    assert(dm_switch_haptics_scan_due(&next_scan_ns, 0));
    assert(next_scan_ns == DM_SWITCH_HAPTICS_RETRY_NS);
    assert(!dm_switch_haptics_scan_due(&next_scan_ns, DM_SWITCH_HAPTICS_RETRY_NS - 1));
    assert(dm_switch_haptics_scan_due(&next_scan_ns, DM_SWITCH_HAPTICS_RETRY_NS));
    assert(dm_switch_haptics_retry_ready(&retry, 0));
    dm_switch_haptics_mark_enable_sent(&retry, 10000000000ull);
    assert(!dm_switch_haptics_retry_ready(&retry, 10240000000ull));
    assert(dm_switch_haptics_retry_ready(&retry, 10250000000ull));
    dm_switch_haptics_mark_enable_ack(&retry, 0, 10250000000ull);
    assert(!dm_switch_haptics_retry_ready(&retry, 10490000000ull));
    assert(dm_switch_haptics_retry_ready(&retry, 10500000000ull));
    dm_switch_haptics_mark_enable_ack(&retry, 1, 10500000000ull);
    assert(dm_switch_haptics_retry_ready(&retry, 10500000000ull));

    DmSwitchHapticsPendingFrame pending = {0};
    DmVibrationFrame pending_frame = {.low_amplitude = 0.4f, .sequence = 3};
    dm_switch_haptics_store_latest(&pending, &pending_frame);
    DmVibrationFrame received = {0};
    assert(dm_switch_haptics_take_pending(&pending, &received));
    assert(received.sequence == 3 && !pending.valid);
    dm_switch_haptics_mark_output_failed(NULL, &retry, &pending,
                                         &pending_frame, 20000000000ull);
    assert(!retry.request_pending && retry.retry_after_ns == 20250000000ull);
    assert(pending.valid && pending.frame.sequence == 3);

    DmSwitchHapticsOutputState output = {0};
    DmVibrationFrame output_first = {.low_amplitude = 0.4f, .sequence = 10};
    DmVibrationFrame output_stop = {.sequence = 11};
    DmVibrationFrame output_latest = {.high_amplitude = 0.8f, .sequence = 12};
    assert(dm_switch_haptics_output_begin(&output));
    assert(!dm_switch_haptics_output_begin(&output));
    dm_switch_haptics_output_enqueue(&output, &output_first);
    dm_switch_haptics_output_enqueue(&output, &output_stop);
    dm_switch_haptics_output_enqueue(&output, &output_latest);
    DmVibrationFrame queued = {0};
    assert(dm_switch_haptics_output_complete(&output, &queued));
    assert(queued.sequence == 11 && !output.report_in_flight);
    assert(dm_switch_haptics_output_complete(&output, &queued));
    assert(queued.sequence == 12 && !output.report_in_flight);
    assert(!dm_switch_haptics_output_complete(&output, &queued));
    assert(!output.report_in_flight);
    assert(dm_switch_haptics_output_begin(&output));
    dm_switch_haptics_output_enqueue(&output, &output_first);
    dm_switch_haptics_output_enqueue(&output, &output_latest);
    DmSwitchHapticsPendingFrame failed_pending = {0};
    dm_switch_haptics_output_fail(&output, &output_stop, &failed_pending);
    assert(!output.report_in_flight && output.rumble_frames.count == 0);
    assert(failed_pending.valid && failed_pending.frame.sequence == 12);

    assert(dm_switch_haptics_ack_is_current((void *)0x1, (void *)0x1, 1));
    assert(!dm_switch_haptics_ack_is_current((void *)0x1, (void *)0x2, 1));
    assert(!dm_switch_haptics_ack_is_current((void *)0x1, (void *)0x1, 0));

    assert(io_result_indicates_disconnect(kIOReturnNoDevice));
    assert(io_result_indicates_disconnect(kIOReturnNotOpen));
    assert(io_result_indicates_disconnect(kIOReturnOffline));
    assert(io_result_indicates_disconnect(kIOReturnNotResponding));
    assert(!io_result_indicates_disconnect(kIOReturnError));

    DmVibrationFrame frame = {
        .low_amplitude = 0.8f, .low_frequency = 80.f,
        .high_amplitude = 0.6f, .high_frequency = 320.f,
        .sequence = 1, .timestamp_ns = 1000000000ull,
    };
    uint8_t report[8] = {0};
    switch_haptics_encode_report(&frame, report);
    assert(!memcmp(report, report + 4, 4));

    uint8_t expected_payload[8];
    memcpy(expected_payload, report, sizeof expected_payload);
    uint8_t output_report[kSwitchRumbleReportLength];
    for (uint8_t counter = 0; counter < 18; counter++) {
        assert(encode_output_report(&frame, counter, output_report) == kSwitchRumbleReportLength);
        assert(output_report[0] == kSwitchRumbleReportID);
        assert(output_report[1] == (counter & 0x0f));
        assert(!memcmp(output_report + 2, expected_payload, sizeof expected_payload));
    }

    assert(report[0] == 0 || report[1] > 0); // 320 Hz encodes in the high band.
    assert(report[3] > 0x40);

    uint8_t enable_report[kSwitchEnableVibrationReportLength] = {0};
    const uint8_t expected_enable_report[12] = {
        0x01, 0x0a, 0x00, 0x01, 0x40, 0x40, 0x00, 0x01, 0x40, 0x40, 0x48, 0x01,
    };
    assert(encode_enable_vibration_report(0x1a, enable_report) == sizeof enable_report);
    assert(!memcmp(enable_report, expected_enable_report, sizeof expected_enable_report));
    for (size_t i = sizeof expected_enable_report; i < sizeof enable_report; i++)
        assert(enable_report[i] == 0);

    uint8_t on_wire_ack[15] = {0};
    on_wire_ack[0] = 0x21; on_wire_ack[13] = 0x80; on_wire_ack[14] = 0x48;
    assert(input_report_acknowledges_rumble_enable(on_wire_ack, sizeof on_wire_ack, 0x21));
    assert(!input_report_acknowledges_rumble_enable(on_wire_ack, sizeof on_wire_ack, 0x30));
    uint8_t hid_payload_ack[14] = {0};
    hid_payload_ack[12] = 0x80; hid_payload_ack[13] = 0x48;
    assert(input_report_acknowledges_rumble_enable(hid_payload_ack,
                                                   sizeof hid_payload_ack, 0x21));
    hid_payload_ack[12] = 0x00;
    assert(input_report_acknowledges_rumble_enable(hid_payload_ack,
                                                    sizeof hid_payload_ack, 0x21) == -1);
    hid_payload_ack[13] = 0x47;
    assert(!input_report_acknowledges_rumble_enable(hid_payload_ack,
                                                    sizeof hid_payload_ack, 0x21));

    DmVibrationFrame low_frequency_limit = {
        .low_frequency = 2000.f, .high_frequency = 320.f,
    };
    DmVibrationFrame low_frequency_max = {
        .low_frequency = 626.286f, .high_frequency = 320.f,
    };
    uint8_t high_out_of_range[8], at_range_limit[8];
    switch_haptics_encode_report(&low_frequency_limit, high_out_of_range);
    switch_haptics_encode_report(&low_frequency_max, at_range_limit);
    assert(!memcmp(high_out_of_range, at_range_limit, sizeof at_range_limit));
    assert(high_out_of_range[2] == 0x7f);

    DmVibrationFrame stop = {.low_frequency = 80.f, .high_frequency = 320.f};
    uint8_t stop_report[8] = {0xff};
    switch_haptics_encode_report(&stop, stop_report);
    assert(stop_report[1] == 0x01); // Neutral 320 Hz high-band code.
    assert(stop_report[3] == 0x40);
    assert(encode_output_report(&stop, 15, output_report) == kSwitchRumbleReportLength);
    assert(output_report[0] == kSwitchRumbleReportID);
    assert(output_report[1] == 15);
    assert(!memcmp(output_report + 2, stop_report, sizeof stop_report));

    DmVibrationFrame clamped = frame;
    clamped.low_amplitude = NAN;
    clamped.high_amplitude = 2.f;
    clamped.low_frequency = INFINITY;
    clamped.high_frequency = -INFINITY;
    uint8_t clamped_report[8];
    switch_haptics_encode_report(&clamped, clamped_report);
    assert(clamped_report[0] <= 0xfc); // Invalid frequency is clamped, not preserved.
    assert(clamped_report[3] == 0x40); // Invalid low amplitude is neutral.

    puts("Switch rumble: encoding, enable ACK/NACK, retry throttling, disconnect results and clamps passed");
    return 0;
}
