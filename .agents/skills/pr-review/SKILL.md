---
name: pr-review
description: "Enroll a repository in bot review, create the bot-review-quorum GitHub App, or install a review host role for thelarklanlabs/pr-review. Use when setting up automated PR review, rulesets, or quorum checks."
---

# Pull request review setup

This skill configures repositories and host roles that `pr-review` manages.
For a full rebuild, follow `docs/recreate.md`.

## Quorum rule

The `bot-review-quorum` check requires full 3-of-3 exact-head approval across `{thelarklan, larkbot-codex, larkbot-claude, larkbot-gemini}`:

- Pull requests from `thelarklan` need exact-head approvals from all three bots.
- Pull requests from a bot need exact-head approvals from both other bots and `thelarklan`.

## Enroll a repository

1. Use the App of the repository owner. See "Which App serves which owner" in `docs/recreate.md`.
   - `thelarklanlabs`: App ID `5877283`.
   - `thelarklan`: App ID `4752010`. Add `--skip-install-check` after you confirm the installation.
   - A repository that is moving to `thelarklanlabs`: transfer it first, then enroll it. See section 4 of `docs/recreate.md`.
2. Preview the changes:

   ```bash
   scripts/enroll-repo.sh OWNER/REPO --app-id APP_ID --check CI_CHECK --dry-run
   ```

3. Run the same command without `--dry-run`.
   The script sets squash merge only, gives the three bots write access, and writes the "main protection" ruleset.
4. If a bot is not an organization member, accept its repository invitation on its WSL distribution.
5. Keep `OWNER/REPO` out of `~/.config/pr-review/repo-policy.json` on `services` unless auto-merge is wanted.

GitHub Free enforces rulesets only on public repositories.
On a private repository, `bot-review-quorum` is advisory.

## Create or replace the GitHub App

Follow section 1 of `docs/recreate.md`.
`scripts/create-app.sh` creates the App from `github/app-manifest.json` and writes the private config.
After you replace the App, run `scripts/enroll-repo.sh` again for each repository with the new App ID.

## Install or update a host role

1. Clone `https://github.com/thelarklanlabs/pr-review.git` to `~/projects/repos/pr-review`.
2. Run `bash ~/projects/repos/pr-review/scripts/verify.sh`.
3. Run `bash ~/projects/repos/pr-review/install.sh --role ROLE`.
   Valid roles are `codex`, `claude`, `gemini`, and `services`.
4. On `services`, keep each App config, `repo-policy.json`, and each `.pem` key in `~/.config/pr-review/` with mode `600`.
