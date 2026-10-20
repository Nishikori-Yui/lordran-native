# Review and merge workflow

## Commit and open the PR

1. Finish the approved change and relevant
   [validation](validation.md). Group commits by function; keep unrelated
   changes and private artifacts out.
2. Push the focused branch and open a PR using the
   [existing PR template](../../.github/pull_request_template.md). Write the
   description in English and link its issue. Explain the problem, resulting
   behavior, scope, actual checks, remaining limits, and risks.
3. Keep the PR's title and description aligned with the final change.
   Reference remaining work through open issues rather than claiming it is
   completed by the PR.

## Perform local review after opening the PR

- Review the PR locally yourself after it exists. Inspect the full diff against
  its base and the surrounding implementation, prioritizing bugs, regressions,
  correctness, privacy, and meaningful gaps in validation.
- Passing tests or an external automated review do not replace this local
  review. Record the reviewed head commit and distinguish existing test results
  from checks actually repeated during review.
- If there are no actionable findings, report that result with relevant
  validation limits. Do not claim exhaustive correctness.

## Findings and corrections

For each actionable finding:

1. Follow the [issue workflow](issue-workflow.md) to create or update its bug
   record. Findings within the already approved fix scope stay on that branch;
   independent work needs a separate issue and implementation decision.
2. Before correcting it, post an English PR review comment describing severity,
   the affected code, a concrete trigger, impact, and the proposed correction.
   Include short sanitized evidence where useful.
3. Fix an in-scope finding in its own commit, run the relevant checks, and push
   the commit. Do not combine unrelated review findings in one correction
   commit.
4. Reply in the finding's thread, or link a follow-up PR comment to the original
   finding. Include the fix commit, changed behavior, validation results, and
   any remaining limitation.
5. Review the correction and its effect on the final diff. Resolve the review
   thread only after verifying the finding is addressed. Repeat for newly
   introduced findings.

Update the linked issue and PR description as needed. Keep a concise public
record of findings and corrections; full logs and private procedures remain
in the ignored work folder.

## Ask before merging

- Once local review and corrections are complete, give the user the PR link,
  the final status, checks, and remaining open issues. Ask whether to merge.
- Wait for explicit user approval of this PR and its reviewed change. Approval
  to create an issue, start a fix, push commits, or open a PR does not itself
  authorize merging. Honor any approval already explicitly given for this PR
  rather than asking for the same permission again.
- If subsequent changes materially alter what the user approved, explain them
  and obtain approval for the revised change.
- Merge with an ordinary merge commit, preserving the separate commits.
  Match the reviewed head when merging; do not silently substitute squash,
  rebase, or a direct push to `main`.
- If repository protection prevents the approved ordinary merge, explain the
  actual conflict to the user. Do not weaken protection or bypass checks
  without authorization.
- After merging, record the merge commit and close only issues actually fixed.
  Keep uncompleted requirements and independent findings open.
