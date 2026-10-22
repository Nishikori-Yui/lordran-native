#include "../switch_haptics_mac.m"
#include <assert.h>
#include <math.h>
#include <string.h>

static void assert_name_selection(void) {
    // Direct calls avoid opening real HID devices while covering name filtering.
    assert(name_is_nintendo_switch("Pro Controller", "Switch Pro Controller"));
    assert(name_is_nintendo_switch("Nintendo Switch Pro Controller", NULL));
    assert(name_is_nintendo_switch("Nintendo", "Gamepad"));
    assert(!name_is_nintendo_switch("Pro Controller", "Gamepad"));
    assert(!name_is_nintendo_switch("DualSense Wireless Controller", "DualSense"));
    // Do not invoke the device-opening path in tests; a real controller may be connected.
    switch_haptics_init_for_controller("DualSense Wireless Controller", NULL);
    switch_haptics_init_for_controller(NULL, NULL);
    assert(*switch_haptics_transport_for_test() == '\0');
    assert(switch_haptics_report_length_for_test() == 0);
}

int main(void) {
    assert_name_selection();
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
    uint8_t output_report[9];
    for (uint8_t counter = 0; counter < 18; counter++) {
        assert(encode_output_report(&frame, counter, output_report) == 9);
        assert(output_report[0] == (counter & 0x0f));
        assert(!memcmp(output_report + 1, expected_payload, sizeof expected_payload));
    }

    assert(report[0] == 0 || report[1] > 0); // 320 Hz encodes in the high band.
    assert(report[3] > 0x40);

    uint8_t enable_report[kSwitchEnableVibrationPayloadLength] = {0};
    const uint8_t expected_enable_report[11] = {
        0x0a, 0x00, 0x01, 0x40, 0x40, 0x00, 0x01, 0x40, 0x40, 0x48, 0x01,
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
    assert(encode_output_report(&stop, 15, output_report) == 9);
    assert(output_report[0] == 15);
    assert(!memcmp(output_report + 1, stop_report, sizeof stop_report));

    DmVibrationFrame clamped = frame;
    clamped.low_amplitude = NAN;
    clamped.high_amplitude = 2.f;
    clamped.low_frequency = INFINITY;
    clamped.high_frequency = -INFINITY;
    uint8_t clamped_report[8];
    switch_haptics_encode_report(&clamped, clamped_report);
    assert(clamped_report[0] <= 0xfc); // Invalid frequency is clamped, not preserved.
    assert(clamped_report[3] == 0x40); // Invalid low amplitude is neutral.

    puts("Switch rumble: dual-band encoding, enable subcommand, packet rollover, stop and clamps passed");
    return 0;
}
