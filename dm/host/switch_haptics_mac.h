#pragma once

#include "dm_input.h"

// Raw macOS HID fallback for Nintendo Switch controllers. Values are normalized
// amplitudes; the protocol encoder supplies safe default actuator frequencies.
void switch_haptics_init_for_controller(const char *controller_name,
                                        const char *controller_category);
// Test-only introspection for transport/report sizing decisions.
const char *switch_haptics_transport_for_test(void);
int switch_haptics_report_length_for_test(void);
// Retry device discovery and rumble-enable handshake from the host poll loop.
void switch_haptics_poll(void);
int switch_haptics_supported(void);
void switch_haptics_set(const DmVibrationFrame *frame);
void switch_haptics_stop(void);
// Exposed for focused protocol tests; returns eight rumble payload bytes.
void switch_haptics_encode_report(const DmVibrationFrame *frame, uint8_t out[8]);
