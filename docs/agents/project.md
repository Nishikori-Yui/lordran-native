# Project scope and documentation

## Scope

- Work only on the native Apple port of Dark Souls: Remastered,
  title `01004AB00A260000`. Do not add support for another title.
- The game's own aarch64 code runs on Apple hardware. Rewrite only code that
  depends on Apple's kernel; this repository hosts Horizon services and NVN.
- Keep game-specific constants, build IDs, shader tables, prewarm data, and
  bring-up notes in `dm/games/01004AB00A260000/`. Tools use this profile by
  default; do not scatter its values through host code.
- Key per-build knowledge by the NSO build ID in the profile's `build` rows.
  Fixed module addresses must be guarded by the matching build ID. Accept only
  registered module builds for this title and apply no game-specific code cuts.
- Keep the user's NSP files, keys, extracted files, caches, logs, and binaries
  under the game's ignored work folder in `game/`. Never print key values or
  commit these artifacts. Read [diagnostics guidance](diagnostics.md) before
  handling private evidence or publishing excerpts.

## Documentation

- `README.md` is the player-facing English page; `README.zh-CN.md` is its
  Chinese counterpart. Keep their content aligned and link them to each other
  when changing player-facing instructions.
- Other repository documentation and code comments are in English. GitHub
  issues follow the existing Chinese templates; PR descriptions and review
  comments are in English.
- Use the game's name naturally, adding the title ID where it identifies a
  build or profile.
- Keep agent rules in these task-specific documents. Keep root `AGENTS.md`
  as a short index; do not duplicate the full rules there or create nested
  `AGENTS.md` files to preload this guidance.
