# DARK SOULS: REMASTERED bring-up

Status on 2026-10-18: experimental. An unsigned iOS IPA builds. User captures
show Mac character creation and asylum gameplay, with incorrect world textures,
opaque ground patches and unstable water. On-device iOS operation has not been
verified. Do not list this profile as playable.

## Inputs and shaders

- Base title: `01004AB00A260000`; update package: `v196608` (1.0.3).
- Tested main build: `df3766a2bb651a3e822828abf10b6f7b`.
- SDK 4.5 build: `d95547528dcd684e2813ec83d338a472`.
- NEX module: `73f98f5f7a34d4c520bda7c1a19cd9bd`.
- Shader chain: `0eefab8cf997`; 3,099 libraries built for Mac and iOS.
- Archives use BHD5/BDT, DCX-DFLT and BND3; the reader is
  `dm/gfx/tools/fromsoftware.py`.
- The measured shader corpus uses bindless handles in guest c13 and no c2
  reads. The unused driver tables retain the translator's default bases.

## Host compatibility

The older account, debug controller, layer-scaling and movie-constructor
interfaces need the same host handling as their newer counterparts. Movie
native-texture buffers predate `movie::Buffer::GetNvnSync`; that accessor is
optional because the host writes each output texture synchronously.

The SDK's blocked-user-list overloads open `friend:a` lazily, even after the
existing `friends::Initialize` offline hook. Dark Souls 1.0.3 calls the overload
without a UID at `main+0x92326c`. Both overloads now return the host's offline
failure with an output count of zero. An earlier `sm::Initialize` no-op left
the SDK's service-manager object null and crashed at `sdk+0xa0974`; that hook
was removed. Do not bypass service initialization without also handling the
actual service client.

## Validation

The game's work folder is `<NSP folder>/01004AB00A260000-work`.

- `run/boot13.log`: 60 seconds, no unexpected fatal signal after the friends
  fix.
- `run/boot14.log`: 90 seconds; `boot14-1400.png` shows the title prompt and
  `boot14-2200.png` shows the offline 1.0.3 main menu.
- `run/boot15.log` and `run/boot16.log`: menu input, first save-file access and
  brightness settings. B confirms and A goes back.
- `boot16` ran for 100 seconds. The logs end with watchdog SIGALRM (`sig=14`),
  which is the configured test timeout.
- Menu frames are paced at about 30 fps. In `boot16`, reported RSS ranges
  from 996 to 1,264 MB and Metal allocation from 1,053 to 1,102 MB.
- The four synthetic FromSoftware archive/GLSLC tests pass.
- Release iOS build succeeds with signing disabled. The IPA contains 19
  RomFS files and 3,099 metallibs, with minimum OS 26.0 and device families
  iPhone and iPad. ZIP CRC verification passes; `codesign -dv` confirms the
  built app is unsigned. No provisioning profile or dump keys are bundled.
- Artifact metadata and SHA-256 are saved in
  `build/ios/pkg/validation.json` under the work folder.
- The repaired 2026-10-18 artifact is
  `<NSP folder>/DarkSoulsRemastered-gfx-20261018.ipa` (4,183,998,448 bytes),
  with shader chain `0eefab8cf997`. ZIP CRCs, all 3,099 packaged reflection
  versions, the embedded host's chain, and unsigned status were checked.
  Its validation record is also saved in
  `analysis/gfx-20261018/ipa-validation.json`.

Rebuild the same IPA from the prepared work folder:

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
export GAME=01004AB00A260000
export W="<NSP folder>/01004AB00A260000-work"
export MSL_IOS="$W/shader/ios"
# FONT_PY must name a Python interpreter with fontTools installed.
dm/ios/tools/build_ipa.sh "<NSP folder>/DarkSoulsRemastered.ipa"
```

## Remaining work

- AVC/VP8 movie decoding currently produces black frames. The player advances
  through the title movie; this does not verify playback of the story movies.
- Dirty-page tracking reaches its 4,096-range limit at startup. Excess pools
  are untracked, which may cause unnecessary texture uploads.
- Revisit character creation and asylum gameplay on the repaired build,
  including the opaque ground patches and unstable water. User captures
  establish these defects on the preceding build; the GPU tests below do
  not establish that every visible defect has been repaired.
- Have the user sideload the unsigned IPA and return `Documents/log.txt`.
  Mac results alone do not establish iPhone compatibility.

## Vertex fetch investigation (2026-10-18)

`run/current-gpu.log` reports an `RG16I` (0x15) attribute bound to a float
input of `vs_engine.bin#204` (`FRPG_Phn_PIN_D_Non.vpo`). Its shader bitcasts
the input to signed int, converts that int numerically to float, then scales
the UV by 1/1024. Numeric conversion by Metal vertex fetch before this bitcast
corrupts the UV. For example, a stored short of -1024 must reach the register
as `0xfffffc00`, rather than the float representation `0xc4800000`.

The same shader has also been seen with normalized UChar4 in
`run/live-vertex-diagnostic.log`. A single static float/uint declaration cannot
serve both layouts. Reinterpreting signed shorts as unsigned shorts also loses
sign extension. There are 258 vertex shaders in this corpus containing signed
integer conversion and the 1/1024 UV scale.

The offline compiler now generates conditional float/int/uint stage inputs.
The host specializes them using the actual NVN attribute formats already in
the pipeline cache key. The adapter preserves register bits before the
translated shader interprets them. Specialization uses compiled metallibs,
including on iOS; it does not translate game shaders at runtime.

Validation:

- The GPU test `tests/test_vertex_fetch.py` uses the production pipeline
  descriptor and checks signed Short2, normalized UChar4, unsigned UChar4,
  float4 and returning to a cached layout. All 15 pixel comparisons pass
  under Metal API validation, for float, uint and int shader declarations.
- All 3,099 Mac and 3,099 iOS shaders build; 390 vertex shaders have
  format-specialized fetch, and one procedural vertex shader has no inputs.
  Bindings, original input types, raster facts and c1 constants match the
  preceding chain for every shader.
- `c1_full.tsv` has been regenerated and the Mac host rebuilt.

This establishes the vertex-fetch defect and the adapter's behavior, not a
visual pass for the new gameplay build. The existing game process was left
running on its previous build. The latest live log has only 18 draws/frame;
absence of pipeline failures there is not evidence about the faulty gameplay
scene. The pass diagnostic log also lacks the per-draw vertex/alpha state
needed to attribute each visible ground patch or water draw.

## Command fences (2026-10-18)

`nvnCommandBufferFenceSync` previously went through an unimplemented thunk.
It now records the sync pointer and publishes the enclosing submission's
completion fence during replay. This is conservative: a fence in the middle
of a command list waits for the entire submission, including its split
segments, rather than signaling before later commands finish. Recording does
not change the sync object, and CPU waits still depend on actual GPU completion.

The NVN integration test passes all 67 checks, including a busy GPU copy,
waiting before CPU reuse of its source buffer, and replaying the same command
fence in a later submission. This repairs a missing synchronization mechanism;
it does not by itself prove the cause of the reported water instability.

## Metal copy barriers (2026-10-18)

Running the integration test with `MTL_DEBUG_LAYER=1` exposed an invalid
intra-encoder barrier: `MTLStageAll` includes render stages, which a Metal 4
compute/copy encoder does not support. The validation layer aborts at the first
overlapping copy/update. The copy barrier now uses `MTLStageBlit` for both
sides, matching the commands it orders. Queue-wide producer/consumer barriers
continue to cover all stages; the SDK explicitly permits that combination.

After the fix, all 67 integration checks pass with Metal API validation
enabled, including uniform updates, copies, command fences and readback.

## Alpha testing (2026-10-18)

The historical `run/live-vertex-diagnostic.log` contains 6,911 unimplemented
`nvnCommandBufferSetAlphaRef` calls and 1,225 unimplemented
`nvnCommandBufferFenceSync` calls. The alpha gap was larger than the missing
entry point: color state retained the comparison function, but pipeline
construction ignored it and the offline translator fixed it to ALWAYS.
Consequently an alpha-tested surface could write its transparent texels to
both color and depth. This is a concrete missing rendering operation; the
old logs do not identify the exact ground-patch draws or prove their alpha
state.

The compiler now adds all eight NVN comparisons to the fragment epilogue.
The host records the reference value in command order and specializes the
compiled function using the comparison and reference bits in the pipeline
key. Readable-tile variants carry the same constants. Alpha testing also
disables the full-coverage load-elision proof. SPH `OmapTargets`, rather than
a padded MSL output, determines whether the original shader exports color
0 alpha. As in the bundled Ryujinx emitter, missing alpha bypasses comparisons
except NEVER.

Default vertex and fragment functions are specialized before their argument
encoders are created. An unspecialized Metal function with function constants
cannot be used to construct a pipeline.

Validation for chain `0eefab8cf997`:

- All 3,099 Mac and 3,099 iOS libraries compile, including 2,708 fragment
  shaders with alpha-test support. Of those, 2,703 originally export alpha;
  five do not. None forces early fragment tests.
- Bindings, original vertex input types, raster facts and c1 bytes are
  unchanged from chain `353d61b89bf3` and agree between Mac and iOS.
  `c1_full.tsv` has been regenerated; the Mac host builds.
- `tests/test_alpha.py` passes 54 GPU render cases under Metal API validation:
  every comparison at alpha 0, 0.5 and 1, changing references, cache reuse,
  and shaders without exported alpha. Each case checks two color targets
  and depth; discarded fragments must leave all three untouched.
- The vertex-fetch test passes all 15 cases again; the NVN integration test
  passes all 67 checks. The serialized pipeline-key round-trip test passes
  with the new alpha fields.
- An additional work-folder smoke test loads all 3,099 actual game libraries
  through production `shader_load`, creates 3,090 argument encoders,
  specializes all 390 vertex-input shaders for normalized attributes and
  all 2,708 fragment shaders for GREATER/0.5, and checks cache reuse.
  Metal API validation reports no failure.
- All 454 historical pipeline records from `run/pso_user.tsv` link on the
  new libraries, both with the original ALWAYS behavior and with GREATER/0.5:
  908 pipeline creations, zero failures and zero skipped records. The test
  appends default alpha fields to an in-memory copy of each old key; it does
  not rewrite the player's manifest. This checks recorded layouts and stage
  interfaces, not their rendered pixels or the runtime texture contents.

Logs and the real-library smoke-test source are under the game's
`analysis/gfx-20261018/`. The previous live game process was not closed or
replaced. Its loaded executable and shader functions predate these changes;
its continuing log cannot validate the new build. Water instability still
requires scene-level validation and, if it persists, per-draw vertex,
texture, alpha and synchronization captures on the repaired build.

`run/live-vertex-diagnostic.log` also has a texture-type mismatch: a shader
expects a cube (Metal type 5) but receives a 2D texture (type 2, texture ID
363). The log has no shader key or binding next to that warning, so its
relationship to water or the ground patches is unknown. The texture fitter
already supports compatible 2D/array views; a single 2D image supplies no
evidence for six cube faces. Do not manufacture faces or suppress the warning
without capturing the draw and its bindless handle.

## iOS build compatibility (2026-10-18)

The existing window-focus recovery added two unguarded
`CAMetalLayer.displaySyncEnabled` assignments to `mtl_link_resume`. Xcode
rejects both on iOS, where that property is unavailable. Both assignments
now have the same `TARGET_OS_OSX` guard as the present path. The Mac
display-link recreation remains intact. The Mac host and unsigned iOS
Release build both succeed; this does not verify focus recovery on a device.
