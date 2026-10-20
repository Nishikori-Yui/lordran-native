# Contributing to Lordran Native

## Issues

- Search existing issues and pull requests first.
- Report a bug through the closest issue template before implementing its fix, or update an existing issue that covers the same problem. Review findings corrected within the current PR are tracked in review comments; create an issue only for independent, deferred, or out-of-scope review work.
- Include the actual build, environment, reproduction details, expected and actual behavior, and short sanitized log excerpts. Separate observed facts from suspected causes and identify missing information.
- Never attach NSP files, keys, saves, shader caches, signed app bundles, or private diagnostic data.

## Agent-assisted work

- After filing or updating the bug issue, give the requester its link and ask whether to start fixing it now on a new branch. Wait for confirmation unless the same fix and new branch have already been explicitly authorized.
- Keep the approved fix as the active task. When an unrelated requirement comes up, ask whether to record it as a separate issue; do not silently add it to the implementation or change priority.
- Open a PR when the fix is ready, then perform a local review yourself. Report findings in PR comments before correcting them, use a separate commit for each correction, and reply with the commit and validation result.
- Use review comments to track corrections completed within that PR. Only independent, deferred, or out-of-scope findings require a separate issue.
- After review and corrections, ask the repository owner whether to merge. Merge only with explicit approval, using an ordinary merge commit that preserves the functional commits.

The task-specific agent instructions are indexed in [AGENTS.md](../AGENTS.md).
See the [issue workflow](../docs/agents/issue-workflow.md) and
[review and merge workflow](../docs/agents/review-and-merge.md) for details.

## Branches and pull requests

- Work from a feature branch; `main` is protected and changes must arrive through a pull request.
- Keep a pull request focused. Separate unrelated features, cleanup, documentation, and generated artifacts.
- Use a short conventional-style title, for example `fix: prevent audio callback underruns`, `feat: add touch camera swipe`, or `docs: update build instructions`.
- Use the PR template, link the issue when required, and explain motivation, scope, tests, physical-device validation, risks, and known limitations. Use a closing keyword only when the issue is fully addressed.
- Keep issue templates in Chinese; write PR descriptions and review comments in English.
- Keep findings, fix commits, and validation feedback in the PR discussion. Resolve a review thread only after verifying its correction.
- The owner decides when to merge. Use an ordinary merge commit; preserve outstanding work in open issues.
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
