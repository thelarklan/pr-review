# pr-review

Automated pull-request reviewers (`codex`, `claude`, `gemini`) and the 3-of-3 `bot-review-quorum` GitHub App check evaluator.

## Quorum policy

The cohort contains four accounts: `thelarklan`, `larkbot-codex`, `larkbot-claude`, and `larkbot-gemini`.

- A pull request from `thelarklan` passes when all three bots approve the exact head commit.
- A pull request from a bot passes when both other bots and `thelarklan` approve the exact head commit.

## Repository layout

- `bin/pr-review-quorum`: Evaluates open pull requests, publishes `bot-review-quorum`, and optionally reconciles squash auto-merge.
- `bin/pr-watch`: Queries open pull requests awaiting review, readiness follow-ups, or conversation replies.
- `bin/pr-review-cron`: Invokes the configured AI reviewer CLI, verifies review posting, and manages health alert issues.
- `bin/pr-review-update`: Fast-forwards the repository clone from `origin/main` and runs verification.
- `hosts/`: Per-role environment configuration (`codex`, `claude`, `gemini`, `services`).
- `install.sh`: Prepares directories and installs the managed crontab block for a selected role.
- `github/`: The GitHub App manifest and the repository ruleset template.
- `scripts/create-app.sh`: Creates the GitHub App from the manifest and writes its private config.
- `scripts/enroll-repo.sh`: Applies merge settings, bot access, and the ruleset to one repository.
- `docs/recreate.md`: Rebuilds the whole system from this repository.

## Install a host role

Clone this repository into `~/projects/repos/pr-review`, run verification, and install the role schedule:

```bash
git clone https://github.com/thelarklanlabs/pr-review.git ~/projects/repos/pr-review
cd ~/projects/repos/pr-review
bash scripts/verify.sh
bash install.sh --role codex   # or claude, gemini, services
```

Cron jobs execute directly from the clone instead of copying binaries to `~/.local/bin`.
Each bot reviewer runs each minute. Its lock skips a run while the previous review is still going.
All roles run `bin/pr-review-update` hourly at minute `19` (`19 * * * *`).
The updater shares the review lock and waits up to 50 minutes for a running review to finish.
It verifies each new commit in a temporary export before it moves the live clone.
A failed verification leaves the live clone and crontab unchanged.

## Default reviewer models

| Role | Provider | Model | Reasoning or effort option |
| --- | --- | --- | --- |
| `codex` | `codex` | `gpt-6.2-sol` | `PR_REVIEW_CODEX_EFFORT=medium` |
| `claude` | `claude` | `claude-opus-5-5` | `PR_REVIEW_CLAUDE_EFFORT=medium` |
| `gemini` | `agy` | `gemini-4-neon-medium` | In the model name. `--effort` is omitted. |

Set `PR_REVIEW_ALERT_REPO=thelarklanlabs/pr-review` to open or update one health issue on escalations or auth failures.
Store optional unattended tokens (such as `CLAUDE_CODE_OAUTH_TOKEN`) in `~/.config/pr-review/provider.env` with mode `600`.

## Quorum deployment

See [docs/review-quorum.md](docs/review-quorum.md) for the `services` GitHub App runbook and [docs/review-policy.md](docs/review-policy.md) for ruleset guidance.
Keep live `pr-review-quorum.env`, `repo-policy.json`, and the `.pem` key under `~/.config/pr-review/` with mode `600`.

## Test

```bash
bash scripts/verify.sh
```
