// Exercise the actual HID fill path; the clock is deterministic, no game data is needed.
#include "../hle_hid.c"
#include <assert.h>

static uint64_t test_time = 1000000000ull;
static int vibration_supported = 1;
static DmVibrationFrame vibration_frame;
static uint64_t vibration_sequence;
uint64_t now_ns(void) { return test_time; }
uint64_t dm_guest_frame(void) { return 0; }
int dm_opmode(void) { return 1; }
int front_vibration_supported(void) { return vibration_supported; }
void front_vibration(const DmVibrationFrame *frame) {
    assert(frame);
    assert(frame->sequence == vibration_sequence + 1);
    vibration_sequence = frame->sequence;
    vibration_frame = *frame;
}
void front_vibration_set_enabled(int enabled) { (void)enabled; }
void hle_bind_system_event(void *g, int autoclear) { (void)g; (void)autoclear; }
void hle_signal_system_event(void *g) { (void)g; }

int main(void) {
    NpadState s;
    uint32_t handle = NPAD_NO1;
    float value[4] = {0.3f, 80.f, 0.7f, 160.f};
    uint32_t devices[2] = {NPAD_NO1, NPAD_HANDHELD};
    float values[8] = {0.2f, 1.f, 0.4f, 2.f, 0.8f, 3.f, 0.6f, 4.f};
    assert(h_hid_VibPermit());
    assert(h_hid_VibHandles(&handle, 1, &handle, 0) == 1);
    h_hid_SendVib(&handle, value);
    assert(vibration_frame.low_amplitude == 0.3f && vibration_frame.low_frequency == 80.f);
    assert(vibration_frame.high_amplitude == 0.7f && vibration_frame.high_frequency == 160.f);
    assert(vibration_frame.sequence == 1 && vibration_frame.timestamp_ns == test_time);
    assert(h_hid_SendVibs(devices, values, 2) == 0);
    assert(vibration_frame.low_amplitude == 0.2f && vibration_frame.low_frequency == 1.f);
    assert(vibration_frame.high_amplitude == 0.4f && vibration_frame.high_frequency == 2.f);
    assert(vibration_frame.sequence == 2); // Ignore non-current controller IDs.
    vibration_supported = 0; assert(!h_hid_VibPermit());
    assert(h_hid_VibHandles(&handle, 1, &handle, 0) == 0);
    vibration_supported = 1;
    fill(&s, NPAD_NO1, STYLE_FULLKEY); assert(s.attributes && !s.rx && !s.ry);
    dm_pad_set(0, 0, 0, 2345, -3456);
    fill(&s, NPAD_NO1, STYLE_JOYDUAL);
    assert(s.attributes && s.rx == 2345 && s.ry == -3456);
    dm_pad_set(0, -4567, 5678, 2345, -3456);
    fill(&s, NPAD_NO1, STYLE_FULLKEY);
    assert(s.attributes && s.lx == -4567 && s.ly == 5678 &&
           s.rx == 2345 && s.ry == -3456);
    fill(&s, NPAD_NO1, STYLE_JOYDUAL);
    assert(s.attributes && s.lx == -4567 && s.ly == 5678 &&
           s.rx == 2345 && s.ry == -3456);
    dm_pad_set(0, 0, 0, 0, 0);
    test_time += 1000000;
    dm_input_swipe_cancel(1); // Cancellation must preserve the established poll interval.
    dm_input_swipe_add(1, 0.0025, 0);
    dm_input_set(DM_BTN_A, 0, 0, 0, 0);
    dm_input_set(0, 0, 0, 0, 0); // Idle UI publications must not overwrite travel or a short button press.
    test_time += 32333333;
    fill(&s, NPAD_HANDHELD, STYLE_HANDHELD); assert(!s.attributes); // Wrong id cannot consume.
    fill(&s, NPAD_NO1, STYLE_FULLKEY); assert(s.rx == 2458 && !s.ry && (s.buttons & DM_BTN_A));
    fill(&s, NPAD_NO1, STYLE_FULLKEY); assert(s.rx == 2458 && !(s.buttons & DM_BTN_A));
    test_time += 33333333;
    fill(&s, NPAD_NO1, STYLE_FULLKEY); assert(!s.rx && !s.ry);

    dm_input_swipe_add(1, 0.01, -0.005);
    dm_pad_set(DM_BTN_B, 0, 0, 1234, 0);
    test_time += 33333333;
    fill(&s, NPAD_NO1, STYLE_FULLKEY); assert(s.rx == 1234 && !s.ry && (s.buttons & DM_BTN_B));
    dm_pad_set(0, 0, 0, 0, 0);
    test_time += 1000;
    fill(&s, NPAD_NO1, STYLE_FULLKEY); assert(!s.rx && !s.ry); // Same-batch release cannot expose cached travel.
    test_time += 33333333;
    fill(&s, NPAD_NO1, STYLE_FULLKEY); assert(!s.rx && !s.ry); // No hidden swipe debt after controller use.

    dm_input_swipe_add(0, -0.01, 0.005);
    dm_input_swipe_add(1, 0.005, -0.01);
    test_time += 33333333;
    fill(&s, NPAD_NO1, STYLE_FULLKEY);
    assert(s.lx < 0 && s.ly > 0 && s.rx > 0 && s.ry < 0);
    assert(abs(s.lx + 9830) <= 1 && abs(s.ly - 4915) <= 1 && abs(s.rx - 4915) <= 1 && abs(s.ry + 9830) <= 1);
    dm_input_swipe_cancel(0); dm_input_swipe_cancel(1);
    fill(&s, NPAD_NO1, STYLE_FULLKEY); assert(!s.rx && !s.ry && !s.lx && !s.ly);
    dm_input_swipe_add(-1, 1, 1); dm_input_swipe_cancel(3);
    puts("HID input: motion, button latch, controller priority, vibration device filtering and single/batch forwarding passed");
}
