# Contributing to Lordran Native

## Issues

- Search existing issues and pull requests first.
- Use the closest issue template and include the requested environment and reproduction details.
- Never attach NSP files, keys, saves, shader caches, signed app bundles, or private diagnostic data.

## Branches and pull requests

- Work from a feature branch; `main` is protected and changes must arrive through a pull request.
- Keep a pull request focused. Separate unrelated features, cleanup, documentation, and generated artifacts.
- Use a short conventional-style title, for example `fix: prevent audio callback underruns`, `feat: add touch camera swipe`, or `docs: update build instructions`.
- Explain motivation, scope, tests, physical-device validation, risks, and known limitations.
- Keep generated outputs and local game-work files out of commits.

## Commit messages

Use an imperative, conventional-style subject:

```text
<type>: <short description>
```

Allowed types are `feat`, `fix`, `perf`, `test`, `refactor`, `build`, `docs`, and `chore`.

Keep the subject concise. Add a body when the reason, compatibility impact, migration, or testing needs explanation.

## Validation

At minimum, validate the area you changed. Host changes should build with:

```sh
make -C dm/host GAME=01004AB00A260000 dmhost
```

Run focused tests and `git diff --check`. For iOS or graphics changes, state clearly whether validation was performed on a physical device or only in a simulator/build environment.

## Game-specific scope

This repository is dedicated to Dark Souls: Remastered (`01004AB00A260000`). Keep game-specific constants, build IDs, shader data, and bring-up notes in the corresponding game profile.
