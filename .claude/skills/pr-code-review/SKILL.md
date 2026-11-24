---
name: pr-code-review
description: "Review a pull request and submit one GitHub review. Use for first-pass reviews, delta re-reviews, or follow-up reviews."
---

# Pull request code review

Review one pull request in a prepared checkout and submit one evidence-backed GitHub review at the exact head commit.

## Steps

1. Verify checkout and context.
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
4. Choose one decisive verdict.
   - Use `REQUEST_CHANGES` when any concrete defect, regression, or missing required check remains.
   - Use `APPROVE` only after the defect-seeking pass finds no blocking issue.
     Treat `APPROVE` as an earned conclusion, not as the default outcome.
   - Use `COMMENT` only when an environment blocker prevents a safe verdict, or when answering a question without changing a prior verdict.
   Done when every finding names exact files, lines, and observable impact.
5. Re-read HEAD and submit one review.
   Query the pull request head commit with `gh` immediately before submission so no stale review is posted.
   Submit one review at that exact head with `gh pr review`.
   When a marker line is required, put it on the last line of the review body.
   Done when GitHub accepts the review on the current head commit.

## Hard limits

- Do not merge, push commits, change branches, or mark drafts ready.
  Leave the checkout clean and report all findings in the GitHub review.
- Do not approve a self-authored pull request.
  Exit nonzero if the pull request author matches your GitHub identity.
- Do not manufacture nits to fill a quota.
  Report only concrete, evidence-backed defects.
- Do not guess when a safe review cannot finish.
  Exit nonzero and state the blocker in standard output.
