# Lordran Native development

The [README](../README.md) covers requirements, IPA packaging, controls and troubleshooting. This guide covers the Dark Souls: Remastered implementation (`01004AB00A260000`), packer options, manual Mac builds and regression checks. For extraction, bring-up failures and capture recipes, see the [porting and debugging guide](porting/README.md).

## How it works

| Part | Responsibility |
|---|---|
| Rewriter (`dm/tools/patch_nso.py`, `DM_RULESET=native`) | Rewrites kernel-dependent instructions in the registered module builds for the target title. No game-specific code cuts, observation gates or resolution patches are applied |
| Host (`dm/host`) | Provides Horizon kernel and system services: threads, synchronization, memory, transactional saves, HID, audio, movies, software keyboard, focus and lifecycle |
| Graphics (`dm/gfx`) | Implements NVN on Metal. `shader_split.py` extracts the target title's BNSH / GLSLC shader corpus for offline translation and compilation into the profile cache |
| Audio | AudioOut and the SDK audio renderer are hosted in-process. Output goes through Core Audio (default on iOS, `DM_AUDIO=1` on the Mac) |
| Input | iOS: the touch gamepad and physical controllers. Mac: scripted input (`DM_KEYS=<seconds>:<button>,…`, with `DM_KBD=<text>` answering the system keyboard) or `DM_WINDOW=1` for a window with keyboard input |
| iOS app | One unsigned IPA for iPhone and iPad. The rewritten code is embedded in the executable; the shader libraries, the RomFS and the game icon are inside the app |
| Known gaps | Conditional render is always drawn; sparse virtual-pool mappings; `DrawElementsIndirect`. TBDR optimizations are off by default. No online features. |

## The packing script in detail

`scripts/build_ipa_from_nsp.py` (`-h` lists every option):

```
# choose an output path inside the game's work folder
python3 scripts/build_ipa_from_nsp.py game/01004AB00A260000 -k game/01004AB00A260000/prod.keys -o game/01004AB00A260000/test.ipa

# pack the base game instead of 1.0.3 (the folder still needs both NSPs: the shader tables cover both versions)
python3 scripts/build_ipa_from_nsp.py game/01004AB00A260000 -k game/01004AB00A260000/prod.keys -p v0

# keep the extracted game files (to run the game on the Mac, or to skip extraction next time)
python3 scripts/build_ipa_from_nsp.py game/01004AB00A260000 -k game/01004AB00A260000/prod.keys --keep-extracted

# a diagnostic build with environment switches baked in (one KEY=VALUE per line)
python3 scripts/build_ipa_from_nsp.py game/01004AB00A260000 -k game/01004AB00A260000/prod.keys --env-file game/01004AB00A260000/diag_env.txt
```

In Spyder, open the script, fill in the settings at the top (`NSP_DIR`, `PROD_KEYS`, and optionally `PACKAGE`, `OUT_IPA`, `APP_NAME`, `BUNDLE_ID`), and press F5. Empty paths are asked for at run time.

What the script does:

1. It finds the game profile from the title ID (the `[title ID]` in the file names, or the NSP's ticket; the update by its `[vN]` tag).
2. It extracts the NSPs.
3. It rewrites the code modules, checking each build ID against the profile.
4. It splits out the shaders and checks them against the profile's tables.
5. It builds the iOS shader libraries.
6. It calls `build_ipa.sh`.

Everything it writes stays in the NSP folder: intermediate files and logs in `<id>_build/`, the IPA next to the NSPs. The extracted game files are deleted at the end unless you pass `--keep-extracted`. It exits with 0 when done and 1 on an error. The app's bundle ID is `org.nxnative.01004ab00a260000`; `--app-name` / `--bundle-id` (or `APP_NAME` / `BUNDLE_ID` in Spyder) override the name and ID.

Lordran Native retains the existing `org.nxnative` bundle identifiers so the
project rename preserves installed app identities and their data directories.
The clone examples use the existing GitHub repository URL with
`lordran-native` as the local directory name.

The packer uses `<NSP folder>/01004AB00A260000_build/`; the manual procedure below uses a separate `<NSP folder>/01004AB00A260000-work/` layout. Their extraction and cache paths differ. Do not use one layout's paths in the other without setting the appropriate overrides.

On the device, diagnostic environment switches go in `Documents/env.txt` (one `KEY=VALUE` per line), and game files are also accepted at `Documents/romfs`. Language, operation mode and the performance panel are owned by the in-game floating menu; language and operation mode changes restart the app.

## iOS performance panel

The iOS performance HUD is enabled by default and is controlled by the in-game floating menu.
Its main FPS and frame-time values use actual drawable presentation callbacks,
not the UI timer or display refresh rate. `Game` counts submitted game frames;
`GPU` is completed GPU work sampled eight game frames late. Both streams use
a rolling one-second window and report zero FPS after a one-second stall.
The panel refreshes twice per second and stops its timer while inactive.
Tap it to collapse the details; the choice persists across launches.
`RAM` is the process physical footprint and `Metal` is Metal's allocated
resource size, both in MiB; they overlap and must not be added together.
The resolution is the game's swapchain texture size. The thermal status is
the system's nominal/fair/serious/critical classification.

## Profile scope

This checkout is dedicated to Dark Souls: Remastered (`01004AB00A260000`). The only
profile is `dm/games/01004AB00A260000/`; its `game.tsv`, build IDs, shader
maps, chain header and prewarm data are the source of truth. The packing script
rejects other title IDs instead of generating surveys for unrelated games.

## Regression checks

The host and test Makefiles default to `01004AB00A260000` and reject another
profile. Run these from the repository root after a host change:

```sh
make -C dm/host dmhost
make -C dm/host/tests run
```

The host tests cover save transactions and failure recovery, case-sensitive
paths, notification ordering, audio output and pause/resume, software keyboard
input, controller layout, thread cleanup, condition variables, and service
clocks including New York calendar conversion. The audio-output test needs
access to Core Audio; a sandbox that denies AudioUnit creation cannot validate
that test. The tests do not require game files or the old D2R Python test
environment.

For a game regression, use a separate copy of the player's save directory
under the game's work folder. Keep its `.work` and `.new` transaction siblings
separate from the player's live save. A windowless run omits `DM_WINDOW`;
`DM_KEYS` can drive the title and continue menus, and `DM_NVN_SHOT` captures
rendered frames. Check the log for loading, successful save commits, missing
imports and fatal errors, then inspect captures from gameplay. Stop only the
test process, and do not start it while the player's game is running.

## Build by hand (Mac)

Run these commands from the repository root with the tools listed in the README. Use the prebuilt shader translator in `dm/gfx/tools/dmsh_xlate_bin`, which matches `dmsh_chain.lock`; a fresh `dotnet publish` produces different fingerprints.

The commands use three variables:

- `G`, the profile;
- `W`, the manual build directory: `<title ID>-work` inside the game's private NSP folder under `game/`;
- `VER`, a version folder named after the NSP version.

```sh
G=01004AB00A260000
W="$PWD/game/01004AB00A260000/$G-work"
VER=v196608
# 1. extract: the base game alone (update -), or an update layered over it (the last argument lets unchanged files become clones)
dotnet build dm/tools/nx_extract -c Release -o $W/build/nx_extract
$W/build/nx_extract/nx_extract <prod.keys> <base NSP> - $W/data/v0
$W/build/nx_extract/nx_extract <prod.keys> <base NSP> <update NSP> $W/data/$VER $W/data/v0/RomFS
# 2. rewrite the profile's code modules
for m in $(python3 dm/games/game.py $G modules); do DM_RULESET=native python3 dm/tools/patch_nso.py $W/data/$VER/ExeFS/$m $W/build/patched_$VER $m; done
# 3. shaders: extract from every version in the profile's shader_versions (comma-separated, base first), then translate into <cache>/b-<chain version>/
DM_GAME=$G python3 dm/gfx/tools/shader_split.py $W/data/v0/RomFS,$W/data/$VER/RomFS $W/data/v0/ExeFS/main,$W/data/$VER/ExeFS/main $W/shader/pkg dm/games/$G/shader_map.tsv dm/games/$G/shader_facts.tsv dm/games/$G/shader_pairs.tsv
DM_GAME=$G python3 dm/gfx/tools/dmsh_chain.py --header
DM_GAME=$G python3 dm/gfx/tools/dmsh_build.py $W/shader/pkg $W/build/cache/metal_shader_cache
python3 dm/gfx/tools/c1_guard.py $W/build/cache/metal_shader_cache/b-<chain version> dm/games/$G/c1_full.tsv
# 4. the host, and the button-icon font for the Nintendo-extension shared font
make -C dm/host GAME=$G dmhost
python3 dm/tools/make_ext_font.py $W/build/font/nintendo_ext.ttf
# 5. run on the Mac
DM_WINDOW=1 DM_ROOT=$W DM_ROMFS=$W/data/$VER/RomFS DM_SAVE=$W/run/save DM_TEMP=$W/run/temp DM_MSL_DIR=$W/build/cache/metal_shader_cache DM_FONT_DIR=$W/build/font dm/host/dmhost $W/build/patched_$VER
# 6. iOS shader libraries, then the IPA (default <NSP folder>/<the profile's ipa>)
IOSOUT=$W/build/ios/dmsh_b DM_GAME=$G python3 dm/gfx/tools/dmsh_build.py $W/shader/pkg $W/build/cache/metal_shader_cache
GAME=$G W=$W dm/ios/tools/build_ipa.sh [out.ipa]
```

Notes on these steps:

- The extraction commands contain placeholders for your key and NSP paths. The shader check needs the chain version generated in step 3.
- Step 5 opens a game window. Omit `DM_WINDOW` for a windowless test. Do not start another game process while the player's game is running.
- `build_ipa.sh` takes the rewritten modules from `$W/build/patched_<package>` and the RomFS from `$W/data/<package>/RomFS`; `PATCHED` and `ROMFS` override them.
- It also bundles a standard font (macOS's Arial Unicode, `STD_FONT=` overrides it) and the generated `nintendo_ext.ttf`.
- The icon is the `icon.jpg` that `nx_extract` saves next to `RomFS/`; `DM_ICON=` points at another image.
- `DM_ENV_FILE=` bakes environment switches into the app, and `DM_DISPLAY_NAME=` renames it.
- If Xcode's Locations setting puts products in a custom place, the script finds the app through the build log.
- `nx_extract` uses LibHac because some Switch update NCAs cannot be read by hactool.

## Prewarm lists

Metal compiles each combination of shaders and pipeline settings for the GPU the first time it is used. Each takes tens of milliseconds, so a burst of them on entering a level is a visible freeze. The host records what it had to compile and rebuilds those pipelines on a background queue at the next launch:

- `pso_user.tsv` sits next to the save directory: `Documents/pso_user.tsv` on iOS, the parent of `DM_SAVE` on the Mac (`DM_PSO_USER=path` overrides it). It is appended while playing, one line per item built on the spot: a shader (`S`), a render pipeline (`R`, the hex of `pso_skey` in `dm/gfx/nvn/nvn_pso_skey.h`) or a compute pipeline (`C`).
- `dm/games/<id>/pso_manifest.tsv` is the seed list bundled with the app, prewarmed before `pso_user.tsv`.

The lines name shaders by content key and hold no compiled code and nothing personal, so a list recorded on one device works on any other. To seed the bundled list:

1. Record on the Mac with prewarm off, so everything is built on demand: `DM_PSO_MANIFEST=off DM_PSO_RECORD=<file>`, then play the boot, title, save-load and first-area scenes.
2. Append the recorded lines below the header comments, in the recorded order. Duplicates are dropped at load.
3. Rebuild the IPA.

Record on the game version you ship. At launch the log names each list it read and its line count (`管线预热清单 … 行`), or says that `pso_user.tsv` does not exist yet.

## Target title notes

- The supported packages are the base game (`v0`, 1.0.0) and update
  `v196608` (1.0.3). The main and SDK build IDs are checked before rewriting.
- The Mac frontend uses the PC keyboard / mouse layout and maps physical
  controllers to the Nintendo button layout shown by the game.
- The renderer uses the target title's bindless texture tables and the profile's
  shader-chain cache. Keep generated shader libraries beside the game work
  folder, never in the repository.
- Validation evidence and unresolved issues are documented in the
  [bring-up notes](../dm/games/01004AB00A260000/bringup.md). Runtime logs stay
  under the game's work folder in `game/`.

## Tools (`dm/tools`)

| Tool | What it does |
|---|---|
| `nx_extract/` | NSP → ExeFS / RomFS / icon with LibHac, merging the update over the base game (C#, `dotnet build`) |
| `nso_fnmap.py` | Carries offsets from one build to another (function matching with addresses masked; globals via their references) |
| `nso2elf.py` | Converts NSO to ELF for Ghidra / REA |
| `insn_census.py` | Counts the instruction sites the rewriter must handle |
| `nso_syms.py` | Compares the SDK import surface of two games, or of one game (`-` for the reference) with the host hooks |
| `nvn_slots_got.py` | Builds the NVN fetch table and call sites (GOT-indirect loaders) |
