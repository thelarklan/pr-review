# Repository review policy

Human owner: `@thelarklan`

## Quorum and approvals

This repository requires full 3-of-3 exact-head approval across `{thelarklan, larkbot-codex, larkbot-claude, larkbot-gemini}`:

- Pull requests authored by `@thelarklan` require exact-head approvals from all three bot accounts.
- Pull requests authored by a bot account require exact-head approvals from both other bot accounts and `@thelarklan`.

## Ruleset enforcement

The default branch `main` enforces an active ruleset with no bypass actors:

- Pull requests required, `required_approving_review_count: 3`, squash merge only.
- Stale reviews dismissed on push, last-push approval required, conversation resolution required, and strict branch currency required.
- Required checks: `bot-review-quorum` (App ID `4752010`) and `verify` (`.github/workflows/ci.yml`).
- Native `require_code_owner_review` remains disabled because `@thelarklan` is the sole human owner; `bot-review-quorum` enforces human approval on every bot pull request.

## Verification

Run the complete local verification suite before pushing:

```bash
bash scripts/verify.sh
git diff --check
```

Manual checks follow [human-verification.md](human-verification.md).
Do not bypass repository rules or merge directly without passing checks.
