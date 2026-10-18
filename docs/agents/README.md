# Dark Souls: Remastered port guide

These pages document the Dark Souls: Remastered port with the native-execution
approach of this repository and [d2r-mobile](https://github.com/jhaizhou-ops/d2r-mobile): the game's own aarch64 code runs natively on Apple hardware, a rewriter patches only the instructions Apple's kernel cannot run, the host replaces Horizon system services, and NVN is reimplemented on Metal.

The supported title uses SDK 4.5.0, NVN API 53.313 and the `main`, `subsdk0`
and `sdk` modules. Values in the profile and bring-up notes are evidence for
this title; measure a value again before changing it.

| Page | Covers |
|---|---|
| [01-extract.md](01-extract.md) | Keys, NSP to NCA to ExeFS / RomFS, update NSPs and the external workspace |
| [03-bringup.md](03-bringup.md) | Booting the host, reading logs and diagnosing bring-up failures |
| [04-graphics.md](04-graphics.md) | NVN on Metal, shader containers and keys, bindings, textures, depth, swizzle, render targets and diagnostics |
| [05-debugging.md](05-debugging.md) | Crash reports, lldb, disassembly, memory growth, render-pass and texture dumps, device diagnostics and pipeline checks |

## Ground rules

- **Bring your own files.** Keys, NSPs and anything extracted from them stay
  in the game's work folder (`$W` = `<NSP folder>/01004AB00A260000-work`),
  never in the repository, a commit or command output.
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
  `【红】` prefix.

## Dark Souls checklist

1. Extract the base game and 1.0.3 update with [01](01-extract.md), keeping
   keys, NSPs and outputs in the external `game/` work folder.
2. Check module build IDs against `dm/games/01004AB00A260000/game.tsv` and run
   the native rewriter with `DM_RULESET=native`.
3. Rebuild and validate the shader chain, then boot the Mac host and work
   through [03](03-bringup.md) and [04](04-graphics.md).
4. Check memory, input, audio, focus/lifecycle and graphics after each change.
5. Build an unsigned IPA and let the user sideload it; inspect
   `Documents/log.txt` using [05](05-debugging.md).
