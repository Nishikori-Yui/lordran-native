## Summary

<!-- What does this PR change, and why? Keep the summary focused. -->

## Change type

- [ ] Bug fix
- [ ] Feature
- [ ] Performance or compatibility
- [ ] Refactor
- [ ] Tests
- [ ] Documentation
- [ ] Build or tooling

## Scope

### Changed

-

### Not changed

-

## Testing

<!-- List exact commands and their results. -->

```text
make -C dm/host GAME=01004AB00A260000 dmhost
<other commands>
```

## Device validation

- [ ] Not applicable
- [ ] Mac tested
- [ ] Physical iOS device tested
- [ ] Physical controller tested
- [ ] Background/foreground transition tested
- [ ] Long-running session tested

Details:

## Diagnostics and artifacts

- Diagnostic report or log location:
- IPA / build artifact:
- Screenshots or recordings:

Do not commit NSP files, keys, saves, shader caches, private logs, or signed/provisioned app artifacts.

## Risk and rollback

- Main risks:
- Compatibility concerns:
- Rollback plan:

## Checklist

- [ ] The change is limited to the stated scope.
- [ ] I added or updated focused tests where behavior changed.
- [ ] I ran the relevant build and test commands.
- [ ] I checked `git diff --check`.
- [ ] I updated user-facing documentation when needed.
- [ ] I did not commit private game data, keys, or generated build artifacts.
- [ ] I called out known limitations and untested paths.
