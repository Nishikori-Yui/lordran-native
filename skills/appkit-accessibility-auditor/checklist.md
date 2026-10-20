# Mac performance text accessibility verification

Scope: `dm/host/mac_perf_hud.m` and the key monitor in `front_mac.m`.

## Findings and implemented fixes

- P0/P1: No outstanding finding identified in the new overlay's code.
- P2: A display-only overlay must not intercept game input. `DmPerfTextView`
  returns nil from hit testing and exposes no pointer-only actions.
- P2: The three display modes need a discoverable keyboard action. F5 cycles
  Simple, Detailed and Off; the native View menu offers the same action and
  names the current mode. Mode is conveyed in text rather than color alone.
- P2: The headline exposes the label Frame rate and frame time. Standard text
  fields expose their values inside a Performance accessibility group. Values
  refresh without live announcements that would repeatedly interrupt speech.

These fixes are implemented in `hitTest:`, `installMenu`, and the key monitor;
no separate patch application is required.

## Manual checks

- With the game focused, press F5 three times (Fn-F5 if needed). Expect Detailed,
  Off, then Simple. No game action should occur. Relaunch and verify persistence.
- Invoke the same action through the View menu using keyboard navigation.
  Expect the title to identify the current mode and no focus trap.
- Enable VoiceOver and inspect the View menu and Performance group. Expect the
  mode action, labeled headline and metric values to be readable without
  repeated speech interruptions during refresh.
- With Voice Control or Switch Control, activate the performance action in the
  View menu. Expect the same cycle without pointer-only controls.
- Move and click through the text area. Expect normal game mouse input.
  Resize and test fullscreen; text should remain in the upper-right corner.
- Inspect bright and dark scenes with Increase Contrast/Reduce Transparency.
  Green text and its black shadow should remain readable without a background.
- Switch applications, minimize/restore and close. Expect refresh to stop and
  recover appropriately, with no timer after close or Off.

## Validation limits and regression risk

Automated AppKit checks cover synthetic metrics, all modes, pass-through hit
testing, green color/shadow, resizing and lifecycle timer state. They do not
establish spoken VoiceOver or Voice/Switch Control acceptance. F5 is reserved
for display modes; the existing game key map is retained.
