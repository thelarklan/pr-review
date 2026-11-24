# Delta re-review

Use this branch for a `delta-re-review` after new commits or a `same-head-followup` after new comments.

## Steps

1. Inspect only the new changes or conversation.
   - For `delta-re-review`, run `git log --oneline <prior_sha>..HEAD` and `git diff <prior_sha>..HEAD`.
   - For `same-head-followup`, read every comment and review thread created after your prior review.
   Done when you read every new hunk or comment since your prior review.
2. Verify prior concerns and shared boundaries.
   Confirm whether the code resolves every open concern from your prior review and from other reviewers.
   Inspect untouched files only where the delta changes a shared contract, state format, or caller.
   Done when every open thread and affected boundary is verified.
3. Perform a focused defect-seeking pass on the delta.
   Work independently of the pull request description and existing CI results.
   Identify the highest-risk behavior added or changed since `<prior_sha>`.
   Trace its failure and boundary paths, and check whether tests could pass while documented behavior still fails.
   Done when no high-risk delta path remains unverified.
