# Delta re-review

Use this branch for a `delta-re-review` after new commits or a `same-head-followup` after new comments.

## Steps

1. Inspect only the new changes or conversation.
   - For `delta-re-review`, run `git log --oneline <prior_sha>..HEAD` and `git diff <prior_sha>..HEAD`.
   - For `same-head-followup`, read every comment and review thread created after your prior review.
   Done when you read every new hunk or comment since your prior review.
2. Verify prior concerns and shared boundaries.
   Confirm whether the code resolves every open concern from your prior review and from other reviewers.
   A concern is resolved when the fix handles the reported case.
   A rare variant of the reported case is a new finding. Classify it with the blocking bar in `SKILL.md`.
   Inspect untouched files only where the delta changes a shared contract, state format, or caller.
   Done when every open thread and affected boundary is verified.
3. Check the delta for new blocking defects.
   Work independently of the pull request description and existing CI results.
   Identify the highest-risk behavior added or changed since `<prior_sha>`.
   Check whether that behavior fails in normal use, or whether tests could pass while documented behavior still fails.
   Report rare or contrived cases in the fix as non-blocking notes.
   Done when each changed behavior that normal use reaches is verified.
