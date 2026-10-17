# DARK SOULS: REMASTERED bring-up

Status on 2026-10-17: experimental. An unsigned iOS IPA builds, and the Mac
host reaches the offline title menu and brightness settings. Character creation,
gameplay and on-device iOS operation have not been verified. Do not list this
profile as playable.

## Inputs and shaders

- Base title: `01004AB00A260000`; update package: `v196608` (1.0.3).
- Tested main build: `df3766a2bb651a3e822828abf10b6f7b`.
- SDK 4.5 build: `d95547528dcd684e2813ec83d338a472`.
- NEX module: `73f98f5f7a34d4c520bda7c1a19cd9bd`.
- Shader chain: `924286814443`; 3,099 libraries built for Mac and iOS.
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
- `nvnCommandBufferFenceSync` and `nvnCommandBufferSetAlphaRef` are still
  unimplemented and logged during menu rendering.
- Dirty-page tracking reaches its 4,096-range limit at startup. Excess pools
  are untracked, which may cause unnecessary texture uploads.
- Continue past the initial settings into character creation and gameplay,
  then verify graphics, audio, saves and memory over a longer run.
- Have the user sideload the unsigned IPA and return `Documents/log.txt`.
  Mac results alone do not establish iPhone compatibility.
