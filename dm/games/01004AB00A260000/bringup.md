# Title 01004AB00A260000 bring-up

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
existing `friends::Initialize` offline hook. Version 1.0.3 calls the overload
without a UID at `main+0x92326c`. Both overloads now return the host's offline
failure with an output count of zero. An earlier `sm::Initialize` no-op left
the SDK's service-manager object null and crashed at `sdk+0xa0974`; that hook
was removed. Do not bypass service initialization without also handling the
actual service client.

Offline socket waits preserve timeout behavior. Empty `Poll` and `Select`
requests consume their requested timeout and return zero, while requests that
contain descriptors still take the unavailable-network failure path. This
prevents the game's offline networking threads from retrying in a tight loop.

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
- The repaired 2026-10-18 IPA uses shader chain `0eefab8cf997`. ZIP CRCs,
  all 3,099 packaged reflection versions, the embedded host's chain, and
  unsigned status were checked. Its validation record is saved in
  `analysis/gfx-20261018/ipa-validation.json`.

Rebuild the same IPA from the prepared work folder:

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
export GAME=01004AB00A260000
export W="<NSP folder>/01004AB00A260000-work"
export MSL_IOS="$W/shader/ios"
# FONT_PY must name a Python interpreter with fontTools installed.
dm/ios/tools/build_ipa.sh "<NSP folder>/LordranNative.ipa"
```

## Remaining work

- VP8 movie decoding remains unsupported and produces black frames. AVC movie
  decoding uses VideoToolbox. Simulator validation reached the story movie and
  Northern Undead Asylum; performance and longer gameplay still need validation.
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

New builds log the first incompatible texture for each shader binding,
including the shader key, stage, argument ID, bound slot or uniform offset,
raw handle, texture ID and dimensions, expected/actual type, frame, pass,
draw and alpha state. This runs without PASSDUMP and preserves the original
binding behavior, so the next gameplay log can identify a specific shader
for `DM_NVN_KEYDUMP` without recording every draw indefinitely.

## iOS build compatibility (2026-10-18)

The existing window-focus recovery added two unguarded
`CAMetalLayer.displaySyncEnabled` assignments to `mtl_link_resume`. Xcode
rejects both on iOS, where that property is unavailable. Both assignments
now have the same `TARGET_OS_OSX` guard as the present path. The Mac
display-link recreation remains intact. The Mac host and unsigned iOS
Release build both succeed; this does not verify focus recovery on a device.

## Sampler reduction (2026-10-18)

`run/live-vertex-diagnostic.log:4020` records a request for MAX reduction
being replaced with average sampling. The setter discarded the mode, the
getter always returned average, and sampler comparison merged states that
differed only in reduction. The Metal sampler consequently used its default
weighted-average mode.

The state now retains the reduction byte in previously unused alignment
space; `samp_par` remains 40 bytes. Pool registration snapshots the mode with
the other parameters, comparison includes it, and the production Metal
descriptor selects the matching Metal 26 reduction mode. Original min/mag
and mip filters remain intact. PASSDUMP sampler records include the mode.
This changes host state only; the shader chain remains `0eefab8cf997`.

`tests/t_sampler_reduction.m` exercises the actual NVN setters, defaults,
getter, comparison, pool registration, object reuse, sampler cache and Metal
sampling path. An independent CPU oracle checks all six minification
filters, both magnification filters, all three reduction modes, and five
explicit LODs against known two-level float texture data. All 180 RGBA
samples and 292 checks pass with Metal API validation on the M5 Max.
The NVN integration test also passes all 67 checks under validation.
Logs are in `analysis/gfx-20261018/reduction-*-test.log`.

This establishes an ignored rendering state and its repair. The historical
log does not identify the draw using MAX reduction, so the connection to
water, ground patches or any particular material remains unverified.

## Water dependency audit (2026-10-18)

The translated corpus contains 73 shaders whose source names include Water:
18 vertex and 55 fragment shaders. All have current-chain reflection files.
The historical `run/pso_user.tsv` references 13 of them, including the
height-map, mask, wave and reflection passes. This records historical
pipeline use; it does not identify the draws in the user's capture.

The wave vertex shader (index 306) and height-map vertex shader (313) both
perform integer reinterpretation followed by a 1/1024 UV scale. They
therefore depend on the vertex-register preservation repair, in addition
to the opaque scenery materials identified earlier. The main water vertex
shader (312) also has a uint input at location 1; all four historically
referenced water vertex shaders use format-specialized fetch.

The height-map fragment shader (2561) samples a 2D texture through the
handle at uniform slot 10, byte offset 48. The six historically referenced
reflection variants (2564-2567, 2572-2573) each use four 2D texture bindings
through that slot at offsets 48, 88, 40 and 32, plus uniform slot 0 and
the shader's packaged c1 constants. Their vertex stages use uniform slot 0
and do not sample a height texture. A height texture assigned to the wrong
frame, an incorrect handle, or a damaged UV can therefore affect the
fragment results without requiring a missing vertex texture operation.
No one of these possibilities is established by the existing log.

None of those 13 recorded shaders declares a cube texture. The complete
water corpus does contain 24 cube bindings in other variants, so the
historical cube/2D mismatch cannot be ruled out as water-related solely
from names. The new contextual texture diagnostic is needed to identify it.

For a focused next run, use `DM_NVN_KEYDUMP=<height-map fragment key>:12:1`
to capture twelve matching draws across different frames, or use the
reflection key for the affected material. Resolve the key from
`shader_map.tsv`; do not infer a handle offset from the source name.

The local launcher must set `DM_WINDOW=1`. Without it, the host deliberately
runs windowless, and the log reports `无窗口，固定 60 Hz` even though the
game and Metal renderer continue running. The generated launcher under the
game work folder now sets this variable explicitly.
Compare slot 0 uniforms and slot 10 handles, texture serials, view ranges,
sampler reduction and alpha state together. The current capture has neither
these per-draw records nor repaired-build images, so it cannot distinguish
a time/UV error from a render-target dependency error.

PASSDUMP's texture and sampler binding lines now include the argument ID,
binding kind, uniform byte offset and raw handle. The previous lines only
identified the uniform slot, making those four slot-10 bindings ambiguous
without consulting reflection and relying on line order. This diagnostic
appends fields to preserve the existing log prefix. The Mac host builds,
and all five budget-export parser regression checks pass. This does not
alter the bindings or shader chain.

## Occlusion counter lifetime (2026-10-18)

The visibility buffer ring reused slots from a completed submission while
an unreset NVN samples-passed query still referenced them. Retaining the
Metal buffer did not preserve its contents. A GPU regression reproduces
the error: 64 samples in one submission followed by 32 in another reported
64 instead of 96, because both query entries read the reused 32-sample slot.

Before a completed ring buffer is reused, its outstanding query samples
are now folded into a CPU subtotal. Reports snapshot that subtotal with
the remaining GPU slots, and ResetCounter clears both. The existing fence
waits still determine when buffer contents may be read; this adds no new
GPU wait.

`tests/t_visibility.m` passes 49 checks with Metal API validation enabled:
multiple passes and reports, a reset within a pass, unequal sample counts
across submissions, an empty scissor, ring reuse, and four deliberately
blocked in-flight submissions with independent report snapshots. NVN
integration passes 67 checks, sampler pools pass 58 checks, and the Mac host
builds. Logs are `analysis/gfx-20261018/visibility-*.log`.

This repairs an incorrect visibility result that can affect game-side
culling; it does not establish that every reported scene or water flicker
has the same cause. The twelve reflection captures in
`water-reflection-113827` keep the same four texture handles and serials.
Their changing uniforms alone do not prove a timing defect.
Conditional render commands still use the always-draw fallback, and the
cube/2D mismatch remains a separate unresolved issue.

## Launch regression and timestamped diagnostics (2026-10-19)

The supplied launch diagnostic report records a startup `SIGTRAP`, with `x0=0`,
`lr=CFRelease+0x14c` and `tex_by_id+0x184` on the host backtrace. This is a
different failure from the earlier unexplained exits under memory pressure.
The previous cache cleanup patch cleared `rp->view` inside `tex_mtl` during
package re-upload, then the caller attempted `CFRelease(rp->view)` using its
pre-resolution cache snapshot. Resolve the base first, inspect the current
cache afterwards, and share an idempotent cleanup for base/alternate/alpha
views. Old GPU references continue to retire through the existing fence.

`t_tex_registry` reproduces the pre-fix trap on real Metal hardware and
passes 64 consecutive uploads/resolutions plus alias cleanup and
finalization after the fix, including with Metal validation enabled.
The NVN integration tests pass 67 checks both normally and with
`DM_TEST_NO_BC=1`; sampler pools pass 58 checks. These Mac checks exercise
the fallback paths but do not establish physical iPhone 13 compatibility.
Its supplied screenshots show developer-verification errors before the app
runs, not an application crash backtrace.

Host and iOS stderr streams now prefix lines with UTC millisecond timestamps,
including multi-line and fragmented diagnostics. Export filenames include
the UTC export time and a unique suffix; older retained logs remain intact.
Tests cover fragmented writes, concurrent writers, keeping the emergency
crash descriptor open, timestamped export names and independent exports.
Validation logs remain under `run/launchfix-*.log` in the game's work folder.

## Runtime hardening (2026-10-23)

- GLSLC extraction uses explicit control-relative code offsets rather than
  searching linkage data. Synthetic coverage includes truncated headers,
  offset overflow, inconsistent lengths and decoy magic. Both registered
  versions retain the same 3,099 unique stage/control/code tuples and keys;
  the shader tables and chain are unchanged.
- The offline profanity filter installs all seven SDK virtual slots and keeps
  the guest RTTI prefix. Direct UTF-8, UTF-16 and char16_t aliases share the
  same no-match behavior; caller text and work buffers are not modified.
  Constructor overloads, initialization and finalization avoid the system
  word-list heap. Deleting destruction uses the guest operator delete, not
  the host allocator. Concurrent construction and virtual calls are tested.
- Texture and sampler pool commands capture storage base and capacity when
  recorded, so reusing a wrapper cannot redirect an existing command. UBO
  bindless handles are reread before argument reuse and invalid offsets or
  overflowing addresses resolve as empty bindings.
- Empty SDK 4.5 and newer socket Poll/Select entry points, plus nnsocketPoll,
  honor finite timeouts. Select reads two signed 64-bit guest timeval fields;
  invalid values and negative descriptor counts fail. Infinite offline waits
  remain unsupported (negative Poll timeouts return immediately; null Select
  timeouts fail). Nonempty waits remain unavailable.
- `--experimental-60fps` is opt-in for the registered 1.0.3 build only. It
  verifies the original rate argument and following call instructions, then
  changes just the 30 Hz argument to 60 Hz. The limiter function is not cut.
  Imported/runtime patches cannot be combined with this option. This is a
  rewrite-level check, not a gameplay, performance or device acceptance result.

Validation covers synthetic host tests, Metal descriptor/UBO tests and the
local registered inputs. No gameplay session or physical iOS device test was
performed for these changes; the existing save and running game are untouched.
