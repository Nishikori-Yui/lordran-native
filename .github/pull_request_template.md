## Summary

<!-- What does this PR change, and why? Keep the summary focused. -->

## Related issue

- Issue:

<!-- Bug fixes must have an issue before implementation. Use Closes #<number> only for a fully addressed issue; otherwise reference it without closing it. For a task without an issue, explain why it is not applicable. -->

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

## Local review

- Reviewed head commit:
- Findings and correction comments:
- Remaining open issues or validation limits:

<!-- After opening this PR, perform a local review yourself. Comment on findings before fixing them; use a separate commit per correction and reply with its commit and validation. Update this section after the review rather than claiming it in advance. -->

## Risk and rollback

- Main risks:
- Compatibility concerns:
- Rollback plan:

## Checklist

- [ ] The change is limited to the stated scope.
- [ ] Bug fixes reference an issue filed before implementation; unrelated requirements remain separate.
- [ ] I added or updated focused tests where behavior changed.
- [ ] I ran the relevant build and test commands.
- [ ] I checked `git diff --check`.
- [ ] I performed a local review after opening the PR and recorded its outcome and any corrections.
- [ ] I updated user-facing documentation when needed.
- [ ] I did not commit private game data, keys, or generated build artifacts.
- [ ] I called out known limitations and untested paths.

<!-- Merge is a separate owner decision after review and corrections. Obtain explicit approval and use an ordinary merge commit that preserves the separate commits. -->
