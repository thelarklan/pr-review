# First-pass review

Use this branch for a `first-pass` review or a `rebased-re-review` after a force-push.

## Steps

1. Inspect the complete diff.
   Run `git diff origin/<base>...HEAD` and read surrounding code for each changed file.
   Done when you inspect every changed hunk and each direct caller.
2. Perform a separate defect-seeking pass.
   Work independently of the pull request description and existing CI results.
   Identify the highest-risk changed behavior.
   Trace its failure paths, boundary inputs, concurrency races, and permission checks.
   Done when you verify each high-risk path against the code.
3. Audit test gaps.
   Check whether tests could pass while documented behavior still fails.
   Look for untested error branches, overly permissive mocks, or stale documentation.
   Done when every high-risk change maps to a verified check or a concrete finding.
