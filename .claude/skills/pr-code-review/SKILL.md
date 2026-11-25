---
name: pr-code-review
description: "Review a pull request and submit one GitHub review. Use for first-pass reviews, delta re-reviews, or follow-up reviews."
---

# Pull request code review

Review one pull request in a prepared checkout and submit one evidence-backed GitHub review at the exact head commit.

## Steps

1. Verify checkout and context.
   Change to the prepared worktree after the provider starts.
   Confirm `git rev-parse HEAD` matches the target head commit.
   Read repository instructions (`AGENTS.md`, `README.md`, or policy files) and prior pull request comments.
   Done when the head matches and you know the rules of the repository and every open thread.
2. Run the matching review branch.
   - For `first-pass` or `rebased-re-review`, follow [FIRST-PASS.md](FIRST-PASS.md).
   - For `delta-re-review` or `same-head-followup`, follow [DELTA-REVIEW.md](DELTA-REVIEW.md).
   Done when the branch procedure produces a complete list of evidence-backed findings.
3. Run proportionate verification.
   Run fast, relevant local tests or linters for the changed files when the environment supports them.
   Done when each relevant check finishes or you record why it could not run.
4. Classify each finding and choose one decisive verdict.
   Mark each finding as blocking or non-blocking with the [blocking bar](#blocking-bar).
   - Use `REQUEST_CHANGES` when at least one blocking finding remains.
   - Use `APPROVE` when the defect-seeking pass finds no blocking finding.
     Treat `APPROVE` as an earned conclusion, not as the default outcome.
     Put non-blocking findings in the approval body under the heading "Non-blocking notes".
   - Use `COMMENT` only when an environment blocker prevents a safe verdict, or when answering a question without changing a prior verdict.
   Done when every finding names exact files, lines, observable impact, and its class.
5. Re-read HEAD and submit one review.
   Query the pull request head commit with `gh` immediately before submission so no stale review is posted.
   Submit one review with `gh api` to the pull request reviews endpoint.
   Set `commit_id` to the target head SHA, `event` to the verdict, and `body` to the review text.
   Use `gh api --input` with a JSON file in the scratch directory.
   When a marker line is required, put it on the last line of the review body.
   Done when GitHub accepts the review on the current head commit.

## Blocking bar

Classify each finding in this order:

1. A finding is blocking if it has one of these impacts, however rare the trigger:
   - A security risk, for example a leaked secret, a permission bypass, or unsafe shell input.
   - Data that can be lost or corrupted.
   - A required build, test, or check that fails.
2. Otherwise, a finding is blocking if a user or a scheduled job meets it in normal use or with a likely configuration.
   This includes a documented behavior that fails in normal use.
3. All other findings are non-blocking. These are examples:
   - The failure needs a contrived setup, for example an unusual manual edit of a managed file, crontab, or config.
   - The failure needs a narrow race between independent processes.
   - No realistic input reaches an untested path.
   - The finding is about style, names, or a cleaner design.

For step 2, if you are not sure, ask: "Will the owner meet this failure in normal use of the tool?"
If the answer is no, the finding is non-blocking.

## Hard limits

- Do not merge, push commits, change branches, or mark drafts ready.
  Leave the checkout clean and report all findings in the GitHub review.
- Do not approve a self-authored pull request.
  Exit nonzero if the pull request author matches your GitHub identity.
- Do not manufacture nits to fill a quota.
  Report only concrete, evidence-backed defects.
- Do not guess when a safe review cannot finish.
  Exit nonzero and state the blocker in standard output.
