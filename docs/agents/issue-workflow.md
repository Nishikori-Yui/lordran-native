# Issues, branches, and task scope

## Player feedback requests

When a player asks to understand a log or prepare feedback, generate a local
draft using the current issue template. They do not need a GitHub login or a
build environment for this. Do not publish an issue or start implementation
unless requested. If they ask for submission, show the sanitized draft first
and use their explicit authorization. When available, check existing issues
and offer a supplemental comment draft for a matching report.

The [player support skill](../../skills/lordran-native-support/SKILL.md) routes
these requests to the existing documentation and helpers. If the player instead
authorizes a repository fix, use the maintainer workflow below.

## Report the bug first

1. Search existing issues and PRs before creating a duplicate. For every newly
   reported or discovered bug, create an issue using the closest existing
   [issue template](../../.github/ISSUE_TEMPLATE/), or update an existing issue
   that already covers that exact problem.
2. Read enough evidence to describe the symptom before filing. Include the
   actual build or commit, environment, reproduction steps, expected and actual
   behavior, frequency, and relevant sanitized log excerpts. Preserve useful
   timestamps, error codes, units, and measurements. Follow
   [diagnostics guidance](diagnostics.md).
3. Separate observations, suspected causes, and confirmed causes. Mark missing
   information and untested paths explicitly. A report can be filed before its
   root cause is known; do not delay issue creation until after implementing a
   fix.
4. Give the user the issue link, then ask whether to start fixing it now on a
   new branch. Wait for their answer before creating that fix branch or
   changing implementation code. Issue creation permits recording and
   investigation; it does not by itself authorize implementation.

If the user has already explicitly authorized the same fix and a new branch,
use that authorization without asking again. Otherwise ask even if the bug
appears small. Read-only inspection needed for a useful report can proceed
before the implementation decision.

## Start and maintain the approved fix

- Start a focused branch from current `main`, such as `fix/issue-11-touch-camera`,
  unless the user explicitly asks to continue another branch. Preserve
  unrelated local changes and artifacts.
- Link the branch and eventual PR to its issue. Keep the original reproduction
  and acceptance criteria visible while implementing and validating.
- If another bug is discovered, record it through the same issue-first process.
  A finding required to complete the already authorized fix can be addressed on
  that branch; record its relationship to the original issue. An independent
  bug needs its own issue and a separate implementation decision.
- Follow [validation guidance](validation.md) for the changed area. Once the fix
  is ready, continue through [PR creation and local review](review-and-merge.md).

## Additional requests during a fix

When the user mentions a requirement outside the active fix:

1. Acknowledge it and ask whether they want it recorded as a separate issue
   using the feature or other appropriate template.
2. Keep working on the approved fix while that optional recording decision is
   pending, where independent progress is possible.
3. Create the additional requirement issue after the user confirms, or directly
   if they already asked for it to be recorded. Keep it out of the current fix
   branch and PR.

Do not silently change the work focus or start the extra implementation.
If the user explicitly changes priority, stops the fix, or authorizes a scope
change, follow that instruction and state how the active work changes.

## Issue status

- Record reproduction, the fix commit, relevant validation, and the final PR
  link without publishing private procedures or full logs.
- Keep checklist status accurate. Distinguish a proven correction from a
  successful run that did not reproduce an older symptom.
- Use `Closes #<number>` in a PR only for an issue that its final change fully
  addresses. Use a reference for partial work; keep independent follow-ups open.
  The owner's approved merge is the normal point for closing a fixed issue.
