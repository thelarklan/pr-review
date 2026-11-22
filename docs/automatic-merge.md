# Hardened personal-repository automatic merge

GitHub performs an automatic squash merge only after native repository rules and `bot-review-quorum` both pass.
The GitHub App may arm or disarm auto-merge; it never calls a direct-merge endpoint and never checks out or executes pull-request code.

## Three-of-three cohort quorum

Configure the owner ID and three bot IDs in private deployment configuration on `services`.

- An owner-authored pull request requires exact-head `APPROVED` reviews from all three configured bots.
- A bot-authored pull request requires exact-head `APPROVED` reviews from both other configured bots and the owner.
- Author self-approvals, outside accounts, drafts, wrong base branches, stale commits, dismissals, change requests, and API errors fail the check.

## Trusted App boundary

The private `thelarklan-bot-review-quorum` App receives only:

- metadata read;
- pull requests read and write (solely to inspect reviews and enable or disable auto-merge); and
- checks read and write (solely to publish `bot-review-quorum`).

Keep account IDs, `repo-policy.json`, the `.pem` private key, and `pr-review-quorum.env` outside the repository with mode `600`.

## Auto-merge reconciliation

With `QUORUM_AUTO_MERGE=1` and the repository set to `"auto_merge": true` in `repo-policy.json`, a passing check arms GitHub squash auto-merge.
A failing check disarms an existing auto-merge request.
Repositories omitted from `repo-policy.json` or set to `false` receive `bot-review-quorum` checks without auto-merge mutations.
Immediately before publishing and before each GraphQL mutation, the evaluator re-reads the pull request head and state to prevent stale-head races.
