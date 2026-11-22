# Human verification checklist

Use this checklist for changes that alter host scheduling, GitHub App permissions, or provider CLI invocations.
Record results in the pull-request description so evidence stays attached to the verified head commit.

## Contributor record

- State the behavior changed by the pull request.
- Record the exact base commit, head commit, and test environment.
- List each automated command run and its observed result.
- Document numbered manual steps with expected and observed results.
- Confirm that no credentials, private keys, or live `repo-policy.json` contents were added.

## Maintainer review

- Confirm the pull request stays focused and its head has not changed since verification.
- Repeat hands-on checks from a clean checkout or test environment when touching install or cron scripts.
- Verify failure paths leave state files, locks, and crontabs recoverable.
- Submit an exact-head approval after verification passes.
