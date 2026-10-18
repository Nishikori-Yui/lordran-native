# vphone executable remap compatibility

This directory contains the optional compatibility path for testing the iOS
host in a vphone guest. The loader calls it after a successful `vm_remap`;
it has no dependency on game modules, fixed addresses, or shader translation.

Every destination region is checked before the loader enters guest code.
`DM_VM_MAP_DIAG=1` also logs source regions and the protections reported by
`vm_remap`. A protection mismatch fails startup by default.

For an authorized vphone test, put `DM_VPHONE_CODE_COPY=1` in the installed
app's `Documents/env.txt`. The copy path requires page-aligned, nonoverlapping
ranges, a shared executable remap that reported RX, an actual RX source,
and an actual read-only destination. It allocates private RW pages at the
reserved destination, copies the bytes, invalidates the instruction cache,
sets RX, and checks every destination region again. Writable/executable
permissions are never requested together. Normal executable remaps retain
their signed pages.

Keep this switch out of ordinary IPA builds and physical-device tests.
The compatibility path addresses a virtual guest mapping failure; it does
not establish the cause of any physical-device black screen.

Run the native Mach VM checks with:

```sh
make -C dm/ios/vphone/tests run
```

These checks exercise permission rejection, range boundaries, preservation
of adjacent pages, opt-in behavior, and actual execution after the RW-to-RX
copy. An installed iOS guest run is still required to validate that guest's
signing and execution policy.

## Standalone Metal capability probe

Build a small, unsigned probe without rebuilding or bundling the game:

```sh
bash dm/ios/vphone/build_metal_probe.sh game/01004AB00A260000-work/build/vphone-metal-probe
```

The probe has bundle ID `org.nxnative.vphone-metal-probe`. Install it only into
an authorized virtual test guest. Its UI and `Documents/metal-probe.txt` report
the device class and GPU families, argument-buffer tier, a completed basic
render with pixel readback, residency-set creation at two capacities, and
creation of the Metal 4 queue, allocator, argument table and command buffer.
The basic render waits at most ten seconds for completion.

The current host requires Metal 4. A working basic render is not sufficient
when these Metal 4 objects are unavailable. The probe does not substitute a
renderer or bypass missing driver capabilities.
