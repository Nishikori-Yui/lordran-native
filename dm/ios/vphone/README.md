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
