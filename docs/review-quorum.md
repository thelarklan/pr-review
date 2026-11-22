# Bot review quorum

`pr-review-quorum` is a polling evaluator for the private `thelarklan-bot-review-quorum` GitHub App.
It never checks out pull-request code, pushes, approves, directly merges, or changes repository settings.
Its installation permissions cover metadata read, pull requests read and write, and checks read and write.
Pull-request write exists only to enable or disable GitHub auto-merge.

For each open pull request in a repository owned by `thelarklan`, the evaluator publishes `bot-review-quorum` on the exact head.
The trusted cohort has four accounts: `thelarklan`, `larkbot-codex`, `larkbot-claude`, and `larkbot-gemini`.

- For a pull request authored by `thelarklan`, all three bot accounts must have a latest decisive `APPROVED` review on that exact head.
- For a pull request authored by one of the three bot accounts, both other bot accounts and `thelarklan` must have a latest decisive `APPROVED` review on that exact head.

Approvals by the author or any account outside the cohort never count.
Outside authors, drafts, other base branches, stale approvals, dismissals, change requests, API errors, and mid-poll head changes fail.
With reconciliation enabled, success arms squash auto-merge and failure disarms an existing request.

## Trusted deployment configuration

Download a private key from the GitHub App settings and store it outside every repository.
On the `services` WSL distribution:

```bash
install -d -m 700 "$HOME/.config/pr-review"
install -m 600 /mnt/c/Users/CHANGE_ME/Downloads/thelarklan-bot-review-quorum.pem \
  "$HOME/.config/pr-review/thelarklan-bot-review-quorum.pem"
```

Copy `pr-review-quorum.env.example` to `~/.config/pr-review/pr-review-quorum.env` with mode `600`:

```bash
QUORUM_APP_ID=4752010
QUORUM_INSTALLATION_ID=157289427
QUORUM_OWNER_ID=166922787
QUORUM_BOT_IDS=270192887,104110997,320627233
QUORUM_PRIVATE_KEY_FILE="$HOME/.config/pr-review/thelarklan-bot-review-quorum.pem"
QUORUM_REPO_POLICY_FILE="$HOME/.config/pr-review/repo-policy.json"
QUORUM_AUTO_MERGE=0
QUORUM_LOG_UNCHANGED=0
```

Create `~/.config/pr-review/repo-policy.json` with mode `600` using `repo-policy.example.json` as a template.
Keep the live `repo-policy.json` outside Git so private repository names stay local to `services`.
Repositories omitted from `repo-policy.json` default to `auto_merge: false`.

Enforce mode `600` on all local configuration and key files:

```bash
chmod 600 "$HOME/.config/pr-review/pr-review-quorum.env" \
  "$HOME/.config/pr-review/repo-policy.json" \
  "$HOME/.config/pr-review/thelarklan-bot-review-quorum.pem"
```

The immutable account-ID mapping is:

| Account | GitHub ID |
| --- | ---: |
| `thelarklan` | `166922787` |
| `larkbot-codex` | `270192887` |
| `larkbot-claude` | `104110997` |
| `larkbot-gemini` | `320627233` |

Run `bin/pr-review-quorum` directly from `~/projects/repos/pr-review`; never copy it to `~/.local/bin`.
Run one foreground audit before installing the schedule:

```bash
QUORUM_CONFIG_FILE="$HOME/.config/pr-review/pr-review-quorum.env" \
  QUORUM_LOG_UNCHANGED=1 \
  "$HOME/projects/repos/pr-review/bin/pr-review-quorum"
```

By default (`QUORUM_LOG_UNCHANGED=0`), the evaluator prints a JSON line only when a check run or auto-merge state changes.
After verifying behavior, run `bash ~/projects/repos/pr-review/install.sh --role services` to schedule minute polls and hourly updates.

## Repository ruleset

For each public repository where rulesets are available, configure an active default-branch ruleset with no bypass actors that:

- requires pull requests and three approvals;
- keeps `require_code_owner_review` disabled when `@thelarklan` is the sole human owner (so `@thelarklan` pull requests are not blocked);
- dismisses stale approvals and requires approval of the latest reviewable push;
- requires all conversations to be resolved and the branch to be current before merging;
- requires `bot-review-quorum` from `thelarklan-bot-review-quorum` (`integration_id` `4752010`) and CI checks; and
- permits squash merge only.

On private repositories under GitHub Free, rulesets are unavailable.
Keep `auto_merge: false` for private repositories and treat `bot-review-quorum` as an advisory manual merge gate.
