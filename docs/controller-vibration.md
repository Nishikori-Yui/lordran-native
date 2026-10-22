# Controller vibration implementation

This is a living design and validation document for issue #26. Update it as
the implementation changes. It separates the Switch-side signal model from
the capabilities of each Apple output backend so that later projects can reuse
the reasoning without treating one device's approximation as a universal
mapping.

## Goal

Forward the game's `nn::hid` vibration requests to a connected controller on
macOS and iOS, with these properties:

- preserve both Switch vibration bands whenever the target backend allows it;
- keep request timing ordered and bounded under high update rates;
- stop output on zero values, disable, focus loss, backgrounding, disconnect,
  controller replacement and process exit;
- report support only after the selected output backend is actually usable;
- distinguish protocol-level receipt from physical-device validation;
- retain a fallback path for devices that do not expose Apple's
  `GCDeviceHaptics`.

The project targets `01004AB00A260000`. This document describes the host and
front-end implementation for that title; it does not change the game's
original vibration data.

## Signal model

The Switch value is treated as four floating-point fields:

```text
low-frequency amplitude
low-frequency frequency
high-frequency amplitude
high-frequency frequency
```

The low and high fields are frequency bands of one logical vibration request.
They are not left/right spatial channels. A renderer should therefore combine
the two bands for each physical actuator by default. Mapping the low band to
the left handle and the high band to the right handle is a deliberate
spatialized effect, not a faithful Switch translation.

The HLE boundary preserves all four fields in `DmVibrationFrame`. Each frame
also carries a monotonic sequence number and the host's `now_ns()` timestamp,
so tests and renderers can distinguish dropped, reordered and coalesced
updates.

## Target architecture

```text
guest nn::hid call
        |
        v
dm/host/hle_hid.c
  validate handle and device
  copy four vibration fields
  assign monotonic timestamp and sequence
        |
        v
bounded vibration queue
        |
        +--> Core Haptics renderer
        |      DualSense / supported Apple haptics
        |
        +--> Switch raw HID renderer
        |      Switch Pro / Joy-Con protocol output
        |
        +--> optional diagnostic renderer
               capture decoded frames and write outcomes
```

The queue is the important boundary. The guest thread must not wait for
AppKit, UIKit, Core Haptics or IOKit. Both Mac and iOS use a fixed 64-entry
ring and schedule one main-queue drain at a time. Oldest frames are dropped
when the ring is full, preventing an unbounded `dispatch_async` chain where
old vibration updates arrive after the game has already sent a stop.

The initial queue implementation should use a fixed-size ring with a
last-value-wins policy for updates that have not yet reached the output
backend. A zero frame is a barrier: it must be delivered ahead of later
nonzero frames and should clear pending nonzero work when the output backend
accepts it.

## Backend A: Core Haptics

Apple exposes controller haptics through `GCDeviceHaptics`, from which an
application can create a `CHHapticEngine` for a supported locality. The
implementation must discover supported localities and create the engine and
player before advertising vibration support.

The intended DualSense path is:

1. select the active controller;
2. inspect its supported haptic localities;
3. create independent left-handle and right-handle engines where available;
4. create a pattern player for each engine;
5. feed both players the same combined vibration frame by default;
6. use intensity, sharpness and parameter curves to approximate the decoded
   low/high spectrum;
7. stop both players immediately on a zero frame or lifecycle transition;
8. recreate players after `resetHandler` and clear state after
   `stoppedHandler`.

Core Haptics is a perceptual renderer. Its public interface exposes haptic
events, parameters, curves and localities; it is not a generic API for
sending arbitrary motor waveforms at exact Switch frequencies. Exact
frequency preservation therefore belongs to the raw HID backend. Core
Haptics should report successful output only when the engine and player are
usable, and the diagnostic log should retain any start, reset, stop or
parameter error.

The current implementation in `dm/host/front_mac.m` and
`dm/ios/Sources/DmGamepad.m` has lifecycle recovery, output error handling
and four-field frame forwarding in place. Both platforms now use the frame
timestamps to preserve the interval between queued updates, with a 100 ms
per-interval ceiling; a reset, disable, controller change or lifecycle stop
invalidates delayed callbacks and drops stale queued frames. This is bounded
timing preservation, not interpolation or waveform reconstruction. On Mac it
creates independent
left/right channels when both localities are supported; otherwise it creates
one channel for combined handles or the default locality. The Mac renderer
uses a basic pattern player because the advanced-player factory failed to
connect to `gamecontrollerd` in earlier tests. It maps the two amplitudes to
one overall intensity and an amplitude-weighted frequency to sharpness. The
iOS path uses one advanced player and maps the larger amplitude to intensity;
it currently ignores both frequency fields. Neither path synthesizes a
waveform or reconstructs the Switch actuator signal. The next fidelity step is
timestamp-aware parameter updates and device-specific calibration.

References:

- [Apple GCDeviceHaptics](https://developer.apple.com/documentation/gamecontroller/gcdevicehaptics)
- [Apple CHHapticEngine](https://developer.apple.com/documentation/corehaptics/chhapticengine)
- [Apple CHHapticPatternPlayer](https://developer.apple.com/documentation/corehaptics/chhapticpatternplayer)
- [godot-dualsense haptics backend](https://github.com/Sineaggi/godot-dualsense/blob/main/src/haptics_gc.mm)

## Backend B: Switch raw HID

Switch Pro and Joy-Con devices may not expose usable `GCDeviceHaptics`.
macOS then needs a raw `IOHIDDeviceSetReport` path.

The raw backend must:

1. identify the selected Nintendo controller rather than any unrelated
   controller currently connected;
2. retain the HID device while the controller remains active;
3. encode both frequency bands and amplitudes using the Switch rumble
   algorithm;
4. send the correct output report for the connection type;
5. serialize report writes and preserve the protocol packet counter when the
   report requires one;
6. send a safe neutral report on stop and release;
7. reopen or discard the device after disconnect;
8. log the report result without logging private device identifiers.

The raw backend is in `dm/host/switch_haptics_mac.m`. It is opened only after
the active `GCController` reports a Nintendo Switch controller name, then
matches Nintendo HID devices. Before advertising raw vibration support it sends
output report `0x01` with subcommand `0x48` and value `0x01`, which enables
controller rumble, and requires macOS to accept that report. The 64-byte
protocol report is sent as a 63-byte payload because IOKit receives the report
ID separately. The input callback waits for a matching `0x21` ACK before
advertising raw vibration support; OS acceptance alone is not treated as proof
that the controller applied the setting. The newest vibration frame is held
until the ACK arrives, then sent through the raw path. A matching NACK leaves
raw output disabled, allowing the Mac Core Haptics fallback when available.
Controller selection briefly pumps the main run loop (up to 250 ms) so the
normal startup path can receive the ACK before the guest enumerates vibration
devices; later frames still replace the pending frame and retry after timeout.

Rumble frames use output report `0x10` and encode both guest frequencies and
amplitudes with the Switch logarithmic tables. The rumble-only report consists
of a four-bit packet counter followed by eight rumble bytes; the report ID is
passed separately to `IOHIDDeviceSetReport`. The counter advances for every
accepted report and wraps at four bits. The eight rumble bytes are duplicated
across both actuators because the Switch low/high pair represents frequency
bands, not spatial sides. The low-band frequency is clamped to its protocol
range. Repeated neutral or non-neutral payloads are coalesced because the
controller retains its last rumble state. The descriptor maximum is checked
when macOS exposes a size smaller than the expected payload.

The device is acquired once when the first matching controller is selected and
is retained for the process lifetime because the public controller and IOKit
identities cannot be correlated safely later. Selecting another controller
stops output but deliberately does not attempt to rebind this raw device. The
implementation sends the rumble-enable subcommand and asynchronously consumes
the matching `0x21` ACK/NACK; whether the controller physically vibrates must
still be verified on hardware.
The protocol sources describe the packet layout, but do not establish macOS
IOKit behavior or physical actuator output.

The identity filter accepts a Nintendo manufacturer name or a Switch product
category, then restricts raw IOKit access to the known Switch Pro/Joy-Con
vendor/product IDs. Apple's public GameController API does not expose a stable
identifier equal to an IOKit HID property, so a perfect selected-device
correlation is impossible without private API. If more than one matching
Switch controller is connected, the first HID match is used. USB/Bluetooth
report length, packet counters, and physical output remain unverified.

The protocol references are:

- [Switch rumble data table](https://github.com/dekuNukem/Nintendo_Switch_Reverse_Engineering/blob/master/rumble_data_table.md)
- [Switch Bluetooth HID output reports](https://github.com/dekuNukem/Nintendo_Switch_Reverse_Engineering/blob/master/bluetooth_hid_notes.md)
- [Linux Nintendo HID driver](https://github.com/torvalds/linux/blob/master/drivers/hid/hid-nintendo.c)
- [libnx HID service implementation](https://github.com/switchbrew/libnx/blob/master/nx/source/services/hid.c)
- [PS5 Mac Companion HID architecture](https://github.com/cestercian/ps5-mac-companion)

The raw path must be tested separately over USB and Bluetooth. A successful
`IOHIDDeviceSetReport` call proves that macOS accepted the write; it does not
prove that the controller actuator moved.

## Optional Core Audio experiment

Generating a waveform with Core Audio is useful for studying the decoded
signal, but normal Core Audio output is a speaker path. It must not be called
a controller haptics implementation unless the selected device and system
provide an explicit audio-to-haptics route.

If an audio-backed experiment is added, keep it behind a separate renderer
interface and record:

- the generated sample rate and buffer size;
- the oscillator or noise synthesis model;
- the route and output device;
- whether the signal reached a speaker, a haptic actuator, or neither;
- latency from the captured Switch frame to the output callback.

Core Audio must never be the only backend for issue #26.

## Timing and synthesis

The synthesis stage should operate on timestamped frames, not on UI callback
frequency. HLE assigns a sequence and monotonic timestamp to each captured
value, and the bounded queue preserves order. Mac and iOS schedule updates
using the interval between frames, capped at 100 ms per step, rather than
draining a burst at UI speed. They do not interpolate, reconstruct durations
from the next frame, or synthesize a sample waveform. For each frame in a
future higher-fidelity renderer:

1. clamp non-finite amplitudes to zero;
2. clamp frequencies to the supported Switch range;
3. compute the frame duration from the next frame or the backend tick;
4. preserve zero frames as explicit stop events;
5. coalesce repeated values only after sequence ordering is known;
6. expose the original and rendered values to diagnostics.

The current output model is intentionally conservative:

- use the Switch frequency encoder for raw HID output;
- use combined amplitude and weighted frequency for Mac Core Haptics;
- use maximum amplitude for iOS Core Haptics; frequency mapping is not yet
  implemented there;
- keep both output handles synchronized;
- avoid artificial pulses when the game sends a continuous update;
- stop immediately when both amplitudes reach zero.

Later calibration can replace the Core Haptics mapping with device-specific
curves. Those curves belong in a profile keyed by controller category and
connection type, not in the HLE layer.

## Lifecycle rules

Every backend follows the same state transitions:

```text
unavailable
    -> discovered
    -> prepared
    -> playing
    -> stopped
    -> unavailable
```

The backend must stop output and clear its pending frame on:

- vibration setting disabled;
- game window losing focus or being miniaturized;
- iOS scene resigning active or entering background;
- controller disconnect;
- active controller selection change;
- haptics engine stop or reset;
- app/window termination.

`IsVibrationPermitted` and vibration device enumeration must reflect the
prepared state, not merely device discovery. A controller with a non-null
`haptics` property but a failed engine or player is not ready for output.

## Diagnostics

Public logs should distinguish these events:

```text
vibration capability discovered
vibration backend prepared
vibration frame received
vibration frame rendered
vibration stop received
vibration backend reset/stopped
vibration output failed
```

The first nonzero frame may include sanitized amplitudes and frequencies.
Repeated frames should be rate-limited. Logs must not contain HID serial
numbers, private paths or complete diagnostic dumps.

The diagnostic record should make it possible to answer:

1. Did the game call the HID vibration entry point?
2. Did the host validate the handle?
3. Did a renderer receive the complete four-field frame?
4. Did the OS API accept the output?
5. Did the physical controller produce feedback?

The fifth question requires physical-device testing and cannot be inferred
from the first four.

## Validation matrix

| Area | Current status | Required evidence |
|---|---|---|
| HID single and batch values | Four-field forwarding, handle filtering, sequence, and timestamp are implemented; focused tests pass (2026-10-23) | In-game single/batch dispatch and physical stop behavior |
| Mac host build | Latest source builds (2026-10-23); existing Metal/compiler warnings remain | Launch this exact build and validate gameplay |
| iOS controller UI build | Simulator UI harness compiles; app-settings and controller mapping tests pass (2026-10-23) | Physical controller test |
| DualSense Core Haptics | Independent handle channels plus combined/default-locality fallback are implemented | Start, update, stop, and actual feedback on USB and Bluetooth |
| Switch Pro raw HID | Four-field encoder, dual actuator payload, packet counter, low-band range clamp, rumble-enable report, and ACK/NACK parser tests pass | Physical USB/Bluetooth rumble and acknowledgement delivery timing |
| NS Pro JoyDual input | JoyDual state maps the selected controller; stick regression test passes | Confirm both sticks and buttons in the running game |
| Low/high frequency preservation | Preserved through HLE and encoded natively by Switch raw HID; Core Haptics is an approximation | Compare decoded and rendered frame records on hardware |
| Timing and waveform synthesis | Sequence/timestamp capture and bounded ordered delivery are implemented; timestamps schedule inter-frame updates with a 100 ms step cap; no sample waveform is reconstructed | Measure queue latency and fidelity, then decide whether interpolation or waveform reconstruction is needed |
| Background and disconnect | Lifecycle stop code is implemented | Device and scene transition test |
| Long-running session | Current host ran for about 17 minutes / 7,200 rendered frames without a host crash; no controller was enumerated and repeated physical effects were not tested | At least 30 minutes with repeated effects on a connected controller |
| Core Audio experiment | Not implemented | Only add after raw/Core Haptics paths are measured |

## Change log

### 2026-10-23

- Ran the current-build host with an isolated save for about 17 minutes and
  7,200 rendered frames without a host crash. This validates renderer/session
  stability only; it does not validate vibration because macOS enumerated no
  connected NS Pro or DualSense HID device during the run.
- Rechecked the macOS USB/HID and Bluetooth inventories; the available
  DualSense entries were disconnected and no Switch Pro device was present.
- Added Switch rumble-enable subcommand `0x48` before marking the raw path
  available. The input callback now validates the matching `0x21` ACK before
  enabling the raw backend. Tightened low-band frequency clamping to the
  protocol's representable range and added packet-layout/ACK parser tests
  without touching connected hardware.
- Added timestamp-paced Mac and iOS delivery, plus cancellation tokens so
  delayed frames cannot restart vibration after focus loss, backgrounding,
  controller replacement or disable. Extended the queue test with timeline
  ordering, timestamp regression and interval-cap cases.
- Made Core Haptics capability state follow engine stop/reset and player
  teardown. A stopped backend is no longer advertised as ready, and the next
  frame can rebuild it instead of silently dropping output.
- Kept the HLE capability query on atomic backend state only; Core Haptics
  channel objects remain main-thread-owned while the guest may query support
  concurrently.
- Rebuilt the latest Mac host, including the Core Haptics combined-locality
  fallback, into a temporary validation location.
- Re-ran the HID forwarding, Switch rumble encoding, and bounded vibration
  queue tests; all passed. Re-ran the iOS diagnostics, camera, control-profile,
  controller-axis, and app-settings tests; all passed, and the Simulator UI
  harness compiled.
- No current-build gameplay or physical-controller result is available yet.
  The previous runtime logs predate the combined-locality fallback and cannot
  establish successful output from the reviewed source.

### 2026-10-22

- Added the living design document for issue #26.
- Recorded the distinction between Switch frequency bands and spatial
  left/right output localities.
- Recorded the Core Haptics approximation boundary and raw HID fidelity path.
- Recorded the first Mac raw Switch HID transport and its remaining limits.
- HLE captures all four Switch vibration fields with sequence and timestamp.
  Mac and iOS drain a bounded 64-entry queue on the main thread.
- The raw Switch encoder uses the guest's low/high frequencies rather than
  fixed defaults.
- Corrected rumble-only report construction to include the four-bit counter
  before the eight-byte payload. Protocol layout is unit-tested; no physical
  controller result is claimed.
- The Mac Core Haptics backend now creates independent left/right handle
  engines when supported, with handles and default-locality fallbacks. The
  same combined spectral frame drives both output channels.
- The rumble-only raw-HID report now places a four-bit packet counter before
  the eight-byte payload for both USB and Bluetooth, and advances it for each
  accepted report. The raw device is acquired on the first matching Switch
  controller and retained for the process lifetime.
