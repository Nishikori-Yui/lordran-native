// Exercise the actual HID fill path; the clock is deterministic, no game data is needed.
#include "../hle_hid.c"
#include <assert.h>

static uint64_t test_time = 1000000000ull;
uint64_t now_ns(void) { return test_time; }
uint64_t dm_guest_frame(void) { return 0; }
int dm_opmode(void) { return 1; }
void hle_bind_system_event(void *g, int autoclear) { (void)g; (void)autoclear; }
void hle_signal_system_event(void *g) { (void)g; }

int main(void) {
    NpadState s;
    fill(&s, NPAD_NO1, STYLE_FULLKEY); assert(s.attributes && !s.rx && !s.ry);
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
    puts("HID motion: real fill path, idle publications, button latch, wrong id, batch reads, controller priority and cancellation passed");
}
