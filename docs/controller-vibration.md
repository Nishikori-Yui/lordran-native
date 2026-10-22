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
               capture source frames and write outcomes
```

The queue is the important boundary. The guest thread must not wait for
AppKit, UIKit, Core Haptics or IOKit. Both Mac and iOS use a fixed 64-entry
ring and schedule one main-queue drain at a time. Oldest frames are dropped
when the ring is full, preventing an unbounded `dispatch_async` chain where
old vibration updates arrive after the game has already sent a stop.

The current queue uses a fixed-size ring and drops the oldest nonzero frame on
overflow before dropping a stop frame. If the ring contains only stops, it
drops the oldest stop to stay bounded. It does not coalesce repeated values.
Any future coalescing policy must preserve order around stop frames and be
justified by measured backend latency rather than applied at the HLE boundary.

## Reusable integration checklist

For another game or emulator port, adapt the boundaries rather than copying a
controller-specific frequency curve:

1. Capture the source API's native parameters, handle identity, sequence and
   monotonic timestamp before invoking platform APIs. Do not prematurely map
   frequency bands to left/right actuators.
2. Keep capture independent of output. Feed a bounded queue so guest or render
   threads never wait on UI frameworks, device discovery or HID reports.
3. Choose an output backend from discovered capabilities. Use a native device
   protocol when exact parameter control is available; otherwise document the
   perceptual approximation and its calibration assumptions.
4. Model `unavailable`, `discovered`, `prepared`, `playing` and `stopped`
   separately. Advertise support only after the selected backend can accept
   output, and revoke it on engine failure or device loss.
5. Treat zero as an ordered stop event. Cancel queued work on disable, focus or
   scene loss, controller replacement, disconnect and process teardown.
6. Record evidence in layers: source request captured, renderer invoked, OS
   accepted the report, protocol acknowledged it, and physical actuator
   feedback observed. Never infer a later layer from an earlier one.
7. Validate each transport and controller model independently, then add
   device-specific calibration only from repeatable measurements.

This repository's `VibrationValue` arrives as four floats already; the project
does not decode a captured raw HD Rumble byte stream. The raw HID backend
encodes those floats into a Switch controller report. This distinction matters
when reusing the design for a title or emulator that exposes a different
source representation.

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
6. use intensity, sharpness and parameter curves to approximate the captured
   low/high parameters;
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
`dm/ios/Sources/DmGamepad.m` has lifecycle cancellation, output error handling
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
iOS path uses one advanced player and now shares the same bounded combined-
amplitude and log-frequency mapping. Sharpness is only a perceptual proxy, not
an output-frequency control. iOS retries engine preparation after an unexpected
engine stop while the active game view is foregrounded. Neither path synthesizes
a waveform or reconstructs the Switch actuator signal. The next fidelity step
is device-specific calibration and a measured choice between parameter curves
and a sample-level waveform renderer.

Continuous-event base parameters must be neutral when live controls carry the
frame: Core Haptics multiplies event intensity by `hapticIntensityControl` and
adds `hapticSharpnessControl` to event sharpness. Both platforms therefore use
base intensity `1.0` and base sharpness `0.0`; a zero base intensity would mute
every update regardless of the submitted intensity, while a nonzero base
sharpness would bias and potentially saturate the mapped range. Parameter
submission logs still prove only that Core Haptics accepted an update, not that
a controller's physical actuators moved.

References:

- [Apple GCDeviceHaptics](https://developer.apple.com/documentation/gamecontroller/gcdevicehaptics)
- [Apple CHHapticEngine](https://developer.apple.com/documentation/corehaptics/chhapticengine)
- [Apple CHHapticPatternPlayer](https://developer.apple.com/documentation/corehaptics/chhapticpatternplayer)
- [godot-dualsense haptics backend](https://github.com/Sineaggi/godot-dualsense/blob/main/src/haptics_gc.mm)

The inspected Godot backend creates Core Haptics engines and players per
locality and drives patterns with intensity and sharpness. It is a useful
reference for controller discovery, locality separation and player lifetime;
it does not expose arbitrary motor-frequency output, so it supports the
perceptual-renderer boundary described here rather than raw waveform fidelity.

## Backend B: Switch raw HID

Switch Pro and Joy-Con devices may not expose usable `GCDeviceHaptics`.
macOS then needs a raw IOKit HID output path.

The raw backend must:

1. identify the selected Nintendo controller rather than any unrelated
   controller currently connected;
2. retain the HID device while the controller remains active;
3. encode both frequency bands and amplitudes using the Switch rumble
   algorithm;
4. send the correct output report for the connection type;
5. submit reports asynchronously, serialize in-flight writes, and preserve the
   protocol packet counter when the report requires one;
6. send a safe neutral report on stop and release;
7. reopen or discard the device after disconnect;
8. log the report result without logging private device identifiers.

The raw backend is in `dm/host/switch_haptics_mac.m`. It is opened only after
the active `GCController` reports a Nintendo Switch controller name, then
matches Nintendo HID devices. Before advertising raw vibration support it sends
output report `0x01` with subcommand `0x48` and value `0x01`, which enables
controller rumble, and requires macOS to accept that report. The 64-byte
protocol report includes the `0x01` report ID in its first byte, as required by
IOKit for a device with multiple reports. The input callback
waits for a matching `0x21` ACK before advertising raw vibration support; OS
acceptance alone is not treated as proof
that the controller applied the setting. The newest vibration frame is held
until the ACK arrives, then sent through the raw path. A matching NACK leaves
raw output disabled, allowing the Mac Core Haptics fallback when available;
NACKs, timed-out ACKs and failed writes are retried no more than once per
250 ms. Both the enable handshake and rumble frames use
`IOHIDDeviceSetReportWithCallback`; controller selection never waits for an ACK
or pumps the main run loop. Each asynchronous request owns its report buffer
and retains its HID device until completion. A single in-flight report and a
fixed-capacity ordered frame queue serialize output. A new stop removes older
queued rumble frames before it is enqueued, so obsolete effects cannot be
replayed after a stop; on output failure, the queue is reduced to its newest
frame for retry. A per-device generation makes late completions harmless after
disconnect or replacement. The regular host poll retries the enable handshake
and rate-limits raw-device rescans to 250 ms, so recovery does not depend on a
later guest vibration frame.

Rumble frames use output report `0x10` and encode both guest frequencies and
amplitudes with the Switch logarithmic tables. The on-wire rumble report is
`0x10`, a four-bit packet counter, and eight rumble bytes; the report ID is
present both in the first byte and in the `IOHIDDeviceSetReport` argument. The
counter advances when IOKit accepts each asynchronous report request and wraps at four bits. The eight
rumble bytes are duplicated across both actuators because the Switch low/high
pair represents frequency bands, not spatial sides. The low-band frequency is clamped to its protocol
range. Repeated neutral or non-neutral payloads are coalesced because the
controller retains its last rumble state. When macOS exposes a maximum output
report size, the preflight check accepts either interpretation of whether the
descriptor-derived size includes the report-ID byte, since Apple's property
documentation does not specify that detail; `IOHIDDeviceSetReportWithCallback` remains the
final size check.
The raw-HID success witness is emitted only from a successful completion
callback; an immediate success return from the asynchronous submission API is
recorded only as a queued request, not as completed OS output.

The device is acquired when the first matching controller is selected and is
retained while usable because the public controller and IOKit identities
cannot be correlated safely later. Selecting another controller stops output
but deliberately does not attempt to bind to an unverified HID identity. A
disconnected-device IOKit result now clears raw capability, releases the stale
device, and re-enumerates a matching HID device; the current frame remains
pending for a fresh rumble-enable ACK. Other output failures also clear
capability so Core Haptics may take over when available. Whether the controller
physically vibrates must still be verified on hardware.
The protocol sources describe the packet layout, but do not establish macOS
IOKit behavior or physical actuator output.

The identity filter accepts a Nintendo manufacturer name, a Switch product
category, or the generic `Pro Controller`/`Joy-Con` names emitted by some
GameController versions, then restricts raw IOKit access to the known Switch
Pro/Joy-Con vendor/product IDs. Apple's public GameController API does not expose a stable
identifier equal to an IOKit HID property, so a perfect selected-device
correlation is impossible without private API. If more than one matching
Switch controller is connected, the first HID match is used. The Mac front end
keeps the last-input controller stable, and an explicit menu selection locks
input to that controller until it disconnects. This prevents another connected
controller from stealing NS Pro stick input during testing. USB/Bluetooth
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

Generating a waveform with Core Audio is useful for studying the captured
parameters, but normal Core Audio output is a speaker path. It must not be
called a controller haptics implementation unless the selected device and
system provide an explicit audio-to-haptics route.

If an audio-backed experiment is added, keep it behind a separate renderer
interface and record:

- the generated sample rate and buffer size;
- the oscillator or noise synthesis model;
- the route and output device;
- whether the signal reached a speaker, a haptic actuator, or neither;
- latency from the captured Switch frame to the output callback.

Core Audio must never be the only backend for issue #26.

## Manual output smoke test

macOS has an explicit, development-only output smoke test for a connected
controller. Start the host with `DM_HAPTICS_TEST=1` and `DM_WINDOW=1`; after a
selected controller is prepared it sends a short sequence through the same
bounded queue and timestamp scheduler as guest frames. The sequence contains
an isolated low-band pulse, an isolated high-band pulse, a combined dual-band
pulse, and dot-dot-dash pulses with explicit stop gaps. The renderer logs a
high-bit synthetic sequence range so this output cannot be confused with a
game-captured `VibrationValue`.

This test is useful for separating controller discovery, raw HID/Core Haptics
submission and physical feedback from game behavior. It does not prove that
the game called `nn::hid`, and an OS-accepted report still does not prove that
an actuator moved. The variable is intentionally opt-in and has no effect
when unset.

## Timing and synthesis

The synthesis stage should operate on timestamped frames, not on UI callback
frequency. HLE assigns a sequence and monotonic timestamp to each captured
value, and the bounded queue preserves order. Mac and iOS schedule updates
using the interval between frames, capped at 100 ms per step, rather than
draining a burst at UI speed. They do not interpolate, reconstruct durations
from the next frame, or synthesize a sample waveform. A future higher-fidelity
renderer should:

1. clamp non-finite amplitudes to zero;
2. clamp frequencies to the supported Switch range;
3. compute the frame duration from the next frame or the backend tick;
4. preserve zero frames as explicit stop events;
5. coalesce repeated values only after sequence ordering is known;
6. expose the original and rendered values to diagnostics.

The current output model is intentionally conservative:

- use the Switch frequency encoder for raw HID output;
- use combined amplitude and weighted frequency for Mac Core Haptics;
- use the same combined amplitude and weighted-frequency mapping for iOS Core
  Haptics; sharpness remains a perceptual proxy, not an exact motor frequency;
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
Npad state returned for physical controller input
Core Haptics parameters accepted
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

The HLE now emits a rate-limited source witness for the first nonzero guest
frame and for an ordered stop, including the source path (`single` or
`batch`), sequence, timestamp and four guest values. This is intentionally
separate from the front-end's renderer log and the raw HID ACK/write logs.
The HLE also rechecks backend capability on every send and invalidates stale
vibration handles after a backend failure, so a previous successful
enumeration cannot be mistaken for current output readiness. Renderer
acceptance witnesses include the originating frame sequence and timestamp, so
an in-game log can correlate guest capture with the exact Core Haptics or raw
HID update that the OS accepted.

## Validation matrix

| Area | Current status | Required evidence |
|---|---|---|
| HID single and batch values | Four-field forwarding, handle filtering, sequence, and timestamp are implemented; focused tests pass (2026-10-23) | In-game single/batch dispatch and physical stop behavior |
| Runtime vibration evidence | Rate-limited HLE source witnesses distinguish guest capture from renderer/HID evidence; Npad receipt and Core Haptics/raw HID parameter-submission witnesses include frame sequence and timestamp; stale handles are rejected after capability loss. API acceptance is not physical actuator evidence. | Capture one in-game log containing source capture, renderer acceptance, and the physical test result |
| Mac host build | Isolated full host build passes with the reviewed source (2026-10-23); an earlier isolated smoke run reached normal rendering and shut down cleanly; existing Metal/compiler warnings remain | Launch this exact build with a connected controller and validate gameplay |
| iOS controller UI build | Simulator UI harness compiles; app-settings and controller mapping tests pass (2026-10-23) | Physical controller test |
| DualSense Core Haptics | Independent handle channels plus combined/default-locality fallback are implemented; iOS recreates its player after unexpected engine stops | Start, update, stop, recovery, and actual feedback on USB and Bluetooth |
| Switch Pro raw HID | Four-field encoder, report-ID-inclusive 10-byte rumble frame, 64-byte rumble-enable report, asynchronous serialized writes, owned callback buffers, stop-priority/latest-frame queueing, per-device completion generations, dual actuator payload, packet counter, low-band range clamp, ACK/NACK parsing, retry throttling, descriptor-size boundary handling, and disconnected-result classification are unit-tested | Physical USB/Bluetooth rumble, callback timing, ACK behavior, and unplug/reconnect recovery |
| NS Pro JoyDual input | Selected host axes are published through both FullKey and JoyDual layouts; Mac offers explicit controller selection and locks to that choice until disconnect; HLE axis forwarding tests pass | Confirm both sticks and buttons in the running game |
| Low/high frequency preservation | Preserved through HLE and encoded natively by Switch raw HID; both Core Haptics paths map amplitude-weighted frequency to perceptual sharpness | Compare captured source parameters with rendered results on hardware; calibrate per device |
| Timing and waveform synthesis | Sequence/timestamp capture and bounded ordered delivery are implemented; timestamps schedule inter-frame updates with a 100 ms step cap; no sample waveform is reconstructed | Measure queue latency and fidelity, then decide whether interpolation or waveform reconstruction is needed |
| Background and disconnect | Lifecycle stop code is implemented | Device and scene transition test |
| Long-running session | Current host ran for about 17 minutes / 7,200 rendered frames without a host crash; no controller was enumerated and repeated physical effects were not tested | At least 30 minutes with repeated effects on a connected controller |
| Core Audio experiment | Not implemented | Only add after raw/Core Haptics paths are measured |

## Change log

### 2026-10-23

- Self-review found that synchronous `IOHIDDeviceSetReport` could block the
  main thread during either the rumble-enable handshake or a game vibration
  update. Replaced both writes with `IOHIDDeviceSetReportWithCallback`, heap-
  owned report buffers and retained device references, one in-flight output,
  bounded serialized rumble queueing with stop priority, latest-frame recovery,
  and per-device generations that ignore late completions. Removed startup's
  run-loop wait. Added output state regression cases; the Switch protocol and
  output-state test, HLE input/vibration test, pad-map test, queue test,
  Core Haptics mapping test, and isolated macOS host build pass. Physical
  USB/Bluetooth callback timing and actuator validation remain pending.
- Moved the raw rumble acceptance witness to the asynchronous completion
  callback so an accepted enqueue cannot be mistaken for completed OS output.
- Self-review found a macOS HID framing defect: the Switch output buffers omitted
  the report ID even though `IOHIDDeviceSetReport` requires it in the first byte
  for multi-report devices. Corrected the rumble frame to 10 bytes and the
  rumble-enable frame to 64 bytes, and updated the protocol vectors. Added a
  Mac controller menu (created even without a preexisting AppKit menu) with an
  explicit selection lock so a different pad cannot steal NS Pro input while
  testing. The descriptor-size guard tolerates
  either report-ID accounting convention; physical USB, Bluetooth, gameplay
  input and actuator feedback remain unverified.
- Added an independent macOS raw-HID recovery poll: device discovery is
  rate-limited to 250 ms and rumble-enable ACK timeouts retry even when the
  game has not enumerated vibration handles or sent another vibration frame.
  Added deterministic scan-throttle regression coverage. Physical ACK timing
  and late device discovery still require a connected-controller run.
- Ran the current host against an isolated copy of the existing game save for
  a short windowed smoke session. The corrected shader-cache root reached
  normal rendering and shut down cleanly after a controlled SIGTERM; no
  controller was enumerated and no vibration frame was generated, so this is
  a host/gameplay-startup check only, not vibration or input acceptance.
- Corrected the Core Haptics continuous-event baselines on macOS and iOS after
  reviewing Apple's control semantics: intensity control multiplies event
  intensity, while sharpness control adds to event sharpness. The previous
  zero-intensity base could mute all runtime updates; the previous 0.5
  sharpness base could saturate the mapped control. New neutral bases are 1.0
  intensity and 0.0 sharpness. Runtime and physical controller verification
  remains pending.
- Clarified the macOS Core Haptics witness to report how many locality channels
  accepted the parameter update instead of implying every configured channel
  succeeded. Rebuilt the Mac host to a temporary path, rebuilt the iOS
  controller UI harness, ran the iOS diagnostics/controller tests, and reran
  the focused host pad mapping, HID forwarding, Switch rumble, queue and
  Core Haptics mapping tests; all passed. These checks do not establish
  physical rumble or haptics output.
- Added renderer-side acceptance witnesses for both macOS and iOS Core
  Haptics. The log records the first successful parameter submission after
  a controller is prepared, including the originating frame sequence and
  timestamp, but still deliberately does not claim physical actuator feedback.
- Added frame sequence and timestamp fields to macOS raw-HID and Core Haptics
  acceptance witnesses. This makes the source-to-renderer correlation
  inspectable without treating OS acceptance as proof of actuator motion.
- Added an opt-in macOS `DM_HAPTICS_TEST=1` smoke sequence for controller-only
  testing. It reuses the normal queue/timestamp path and covers low-band,
  high-band, dual-band and dot-dot-dash pulse shapes while marking its frame
  sequences as synthetic. This remains a diagnostic aid, not gameplay or
  physical-actuator acceptance.
- Added a rate-limited Npad receipt witness for the first nonzero physical
  controller state returned to the guest, including layout, buttons and both
  axes. This separates a GameController event from proof that the running
  game actually sampled the NS Pro state.
- Added the first source-side runtime evidence layer: HLE logs a rate-limited
  witness for nonzero guest frames and ordered stops, including source path,
  sequence, timestamp and all four values. Every send now rechecks backend
  readiness so stale vibration handles cannot continue to masquerade as a
  usable device after a renderer failure. Added a regression assertion for
  this stale-capability case.
- Re-ran the latest raw-HID state-helper refactor and added input-report
  disconnect handling: a device-gone callback now clears stale capability,
  preserves the newest pending frame and re-enumerates the selected device.
  The Switch name filter also accepts the generic `Pro Controller` and
  `Joy-Con` labels used by some macOS GameController versions, while the HID
  vendor/product allowlist remains mandatory before any raw report is sent.
  Extended the HID regression test to cover both sticks through FullKey and
  JoyDual layouts.
- Rebuilt the current macOS host to a temporary output after the disconnect
  handling change. Re-ran the four focused host tests, the iOS diagnostics and
  controller-axis tests, and the Simulator UI harness build; all passed.
- Added a reusable integration checklist and clarified the source/output
  boundary: this title's `VibrationValue` is already four floats, so the host
  encodes it for Switch HID rather than decoding a raw HD Rumble byte stream.
  Corrected the queue, iOS Core Haptics and frame-diagnostic descriptions to
  match the current implementation. Rechecked the Godot DualSense reference;
  its per-locality intensity/sharpness pattern path corroborates the Core
  Haptics design but not exact motor-frequency reproduction.
- Re-reviewed the implementation against issue #26's acceptance criteria. The
  host has the full four-field capture/sequence/timestamp and output path, but
  waveform reconstruction, exact Core Haptics frequency fidelity, device
  calibration, and physical controller validation remain incomplete. This is
  not yet ready to mark the issue complete.
- Unified Mac/iOS Core Haptics parameter synthesis: both now combine band
  amplitudes and map the amplitude-weighted logarithmic frequency to
  perceptual sharpness. Added focused tests for dual-band weighting, amplitude
  bounds and invalid-frequency fallbacks; this improves consistency but does
  not reproduce either Switch motor waveform.
- Hardened the raw Switch HID failure path: NACKs, timed-out enable requests
  and failed writes are rate-limited to 250 ms; device-gone IOKit results clear
  the advertised capability, discard the stale handle, re-enumerate and keep
  the newest frame pending for the next enable ACK. Added retry-timing and
  device-gone classification tests. Physical unplug/reconnect remains to be
  verified with a controller attached.
- Fixed an iOS capability-query thread-safety gap: the guest thread now reads
  only atomic vibration-enabled/backend-ready flags instead of asking a UIKit
  view for state. The iOS stopped-handler now ignores stale engine callbacks
  and retries preparation after an unexpected stop when the active game view
  is foregrounded; a naturally finished pattern does not discard its player.
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
