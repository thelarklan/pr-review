---
name: pr-review
description: "Enroll a repository, configure rulesets, and install bot review or quorum roles for thelarklan/pr-review. Use when configuring automated PR review or quorum checks."
---

# Pull request review setup

This skill configures repositories and host roles managed by `thelarklan/pr-review`.

## Quorum rule

The `bot-review-quorum` check enforces full 3-of-3 exact-head approval across `{thelarklan, larkbot-codex, larkbot-claude, larkbot-gemini}`:

- Pull requests from `thelarklan` require exact-head approvals from all three bots.
- Pull requests from a bot require exact-head approvals from both other bots and `thelarklan`.

## Enroll a repository

1. Invite all three bot accounts as collaborators with write permission.

   ```bash
   for bot in larkbot-codex larkbot-claude larkbot-gemini; do
     gh api -X PUT "repos/OWNER/REPO/collaborators/$bot"
   done
   ```

2. Accept each pending repository invitation from the matching bot WSL distribution (`codex`, `claude`, `gemini`).
3. Confirm GitHub App installation `157289427` lists `OWNER/REPO`.

   ```bash
   gh api /user/installations/157289427/repositories --paginate --jq '.repositories[].full_name'
   ```

4. Keep `OWNER/REPO` unlisted in `~/.config/pr-review/repo-policy.json` on `services` unless auto-merge is wanted.
   To enable squash auto-merge on a public repository, set `"auto_merge": true` in `~/.config/pr-review/repo-policy.json`.

## Configure a public repository ruleset

GitHub Free restricts rulesets to public repositories.
On private repositories under GitHub Free, treat `bot-review-quorum` as an advisory manual merge gate.

1. Configure repository settings to permit squash merges only.
2. Create an active default-branch ruleset with no bypass actors.
3. Set `required_approving_review_count` to `3`.
4. Enable `dismiss_stale_reviews_on_push`, `require_last_push_approval`, and `required_review_thread_resolution`.
5. Keep `require_code_owner_review` set to `false` when `@thelarklan` is the sole human owner.
   Because `@thelarklan` cannot approve self-authored pull requests, native code-owner checks would block owner pull requests.
6. Require status check `bot-review-quorum` with `integration_id` `4752010` plus repository CI checks.
7. Enable `strict_required_status_checks_policy` so branches stay current before merge.

## Install or update a host role

1. Clone `https://github.com/thelarklan/pr-review.git` to `~/projects/repos/pr-review`.
2. Run `bash ~/projects/repos/pr-review/scripts/verify.sh`.
3. Run `bash ~/projects/repos/pr-review/install.sh --role ROLE`.
   Valid roles are `codex`, `claude`, `gemini`, and `services`.
4. On `services`, place `pr-review-quorum.env`, `repo-policy.json`, and the `.pem` key in `~/.config/pr-review/` with mode `600`.
