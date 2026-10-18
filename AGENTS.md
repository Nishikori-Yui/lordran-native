# Notes for agents

- This repository is dedicated to the native Apple port of Dark Souls: Remastered (`01004AB00A260000`). The game's own aarch64 code runs on Apple hardware; only code that depends on Apple's kernel is rewritten, while Horizon services and NVN are hosted by this repository. Do not add support for another title here.
- Game-specific constants, build IDs, shader tables, prewarm data and bring-up notes live in `dm/games/01004AB00A260000/`. The tools use this profile by default. Keep game-specific values in the profile rather than scattering them through host code.
- Per-build knowledge is keyed by the NSO build ID: rewriter cuts in `dm/tools/patch_nso.py`, the profile's `build` rows, and host code that uses fixed module addresses. Any fixed-address behaviour must check the matching build ID before it runs.
- The user's NSP files, keys, extracted files, caches, logs and binaries stay under the game's work folder in `game/`; never print key values or commit any of these artifacts.
- `README.md` is the player-facing page in English followed by Chinese. Other documentation and code comments are in English. Keep log messages unchanged; red log lines start with `【红】`.
- After changing anything in the shader translation chain (`dm/gfx/tools/dmsh_*`, `dmsh_xlate/`, `dm/ios/tools/ios_metal.py`, or the Dark Souls shader tables), regenerate `dmsh_chain.h`, rebuild the Mac/iOS shader libraries as applicable, regenerate `c1_full.tsv`, and rebuild the host. The host only accepts libraries with its own chain version.
- Validate Dark Souls after independent changes. At minimum use `python3 -m py_compile` for changed Python and `make -C dm/host GAME=01004AB00A260000 dmhost` for host changes; run focused tests when their targets build.
- Commit each independent change when the user has asked for ongoing commits, using the owner's identity and New York timezone:
  `TZ=America/New_York git -c user.name=Nishikori-Yui -c user.email=165007678+Nishikori-Yui@users.noreply.github.com commit`
- Do not sign or install IPA builds. Do not close or duplicate a running game window. Delete one-off helper scripts after use and do not commit them.
