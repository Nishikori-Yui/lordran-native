# Dark Souls: Remastered port guide

These pages cover extraction, host bring-up and debugging for Dark Souls:
Remastered (`01004AB00A260000`). Start with the [development guide](../development.md) for build
commands and architecture, or the [README](../../README.md) for IPA packaging
and player instructions.

Lordran Native is based on
[seedds/nxnative](https://github.com/seedds/nxnative), is now maintained
independently, and follows its
native-execution approach: the game's ARM64 code
runs on Apple hardware, a rewriter adapts kernel-dependent instructions, the
host provides Horizon services, and the graphics layer implements NVN on Metal.

The supported title uses SDK 4.5.0, NVN API 53.313 and the `main`, `subsdk0`
and `sdk` modules. Values in the profile and bring-up notes are evidence for
this title; measure a value again before changing it.

| Page | Covers |
|---|---|
| [01-extract.md](01-extract.md) | Keys, NSP to NCA to ExeFS / RomFS, update NSPs and the external workspace |
| [02-bringup.md](02-bringup.md) | Booting the host, reading logs and diagnosing bring-up failures |
| [03-graphics.md](03-graphics.md) | NVN on Metal, shader containers and keys, bindings, textures, depth, swizzle, render targets and diagnostics |
| [04-debugging.md](04-debugging.md) | Crash reports, lldb, disassembly, memory growth, render-pass and texture dumps, device diagnostics and pipeline checks |

## Ground rules

- **Bring your own files.** Keys, NSPs and anything extracted from them stay
  in the game's private folder under the Git-ignored `game/` directory.
  Manual builds use `$W` = `<NSP folder>/01004AB00A260000-work`; the IPA
  packer uses `<NSP folder>/01004AB00A260000_build`. Never commit private
  artifacts or print key values.
- **Measure, then change.** Base changes on a log, disassembly, shader census,
  memory profile or other reproducible observation. Put the evidence beside a
  non-obvious fix in an English code comment.
- **Keep the profile authoritative.** Identity, supported builds, module list,
  memory partition, NVN tables and shader data live in
  `dm/games/01004AB00A260000/`. Fixed-address behaviour must check the matching
  build ID.
- **Test where it runs.** The Mac host is the development loop; the iOS app
  reuses the same host and graphics code. Do not claim an iOS fix without an
  iOS test.
- **Logging.** Keep existing log messages unchanged. Red log lines use the
  `【红】` prefix. Generated host and app log lines carry UTC timestamps with
  millisecond precision; diagnostic export filenames include an export timestamp.

## Target title checklist

1. Extract the base game and 1.0.3 update with [01](01-extract.md), keeping
   keys, NSPs and outputs in the game's private folder under `game/`.
2. Check module build IDs against `dm/games/01004AB00A260000/game.tsv` and run
   the native rewriter with `DM_RULESET=native`.
3. Rebuild and validate the shader chain, then boot the Mac host and work
   through [02](02-bringup.md) and [03](03-graphics.md).
4. Check memory, input, audio, focus/lifecycle and graphics after each change.
5. Build an unsigned IPA and let the user sideload it; inspect
   `Documents/log.txt` using [04](04-debugging.md).
