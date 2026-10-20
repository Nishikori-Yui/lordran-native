# Validation and artifacts

## Checks for the change

- Validate the target title after independent changes. Choose checks for the
  changed behavior, and report commands, results, skips, and untested paths.
- Run `python3 -m py_compile` for changed Python sources. For host changes, run:

  ```sh
  make -C dm/host GAME=01004AB00A260000 dmhost
  ```

- Run focused tests when their targets build. Do not replace a regression
  check with a build-only result or claim a test passed if it was skipped.
- Run `git diff --check`. For documentation-only changes, check links and
  consistency with the existing templates and guidance; runtime builds are
  unnecessary unless runtime behavior or build inputs also changed.
- Match performance comparisons by scene, settings, and run conditions.
  Separate CPU, GPU, shader compilation, and presentation evidence where
  available. Distinguish Simulator results from physical-device results.

## Shader translation changes

After changing `dm/gfx/tools/dmsh_*`, `dmsh_xlate/`,
`dm/ios/tools/ios_metal.py`, or the target title's shader tables:

1. Regenerate `dmsh_chain.h`.
2. Rebuild Mac and iOS shader libraries as applicable.
3. Regenerate `c1_full.tsv`.
4. Rebuild the host.

The host accepts only libraries matching its own shader chain. Keep generated
libraries and private caches under the game's work folder, and do not package
mixed chains.

## Test sessions and packaging

- Do not sign IPA builds. Installing unsigned Simulator `.app` builds for
  validation is allowed.
- During a test step, close, replace, or relaunch a running game instance when
  needed. Avoid doing so outside a test step.
- Use a separate copy of a player's save for regression testing. Keep
  transaction siblings separate from live saves.
- Delete one-off helper scripts after use and do not commit them.
- Keep NSPs, keys, saves, logs, generated bundles, and binaries out of commits,
  as described in [diagnostics guidance](diagnostics.md).

## CI

- Keep build and basic-validation workflows manual or tag triggered. Ordinary
  branch pushes and PR updates must not start them automatically.
- Use GitHub-hosted runners for public validation. Do not attach a private
  Windows machine as a runner or expose it to hosted workflows.
- A public tooling CI pass does not establish gameplay, device compatibility,
  stability, or performance acceptance. Record those tests separately.
