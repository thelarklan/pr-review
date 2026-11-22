# AGENTS.md

This public repository owns the automated pull-request review bots and the `bot-review-quorum` check evaluator.

## Rules

1. Run `bash scripts/verify.sh` inside Linux or WSL before you commit.
2. Do not commit `.env` files, `.pem` keys, tokens, or `repo-policy.json`.
3. Keep all files with LF line endings.
4. Keep the three copies of `SKILL.md` under `.claude/skills/pr-review/`, `.agents/skills/pr-review/`, and `.gemini/skills/pr-review/` identical.
5. Do not add `dev-tools` dependencies or install binaries into `~/.local/bin`.

## Key files

- `bin/pr-review-quorum`: Publishes the `bot-review-quorum` check using a 3-of-3 cohort rule.
- `bin/pr-watch`: Finds open pull requests that need review or follow-up by the authenticated account.
- `bin/pr-review-cron`: Runs `bin/pr-watch`, invokes Codex, Claude, or Antigravity, confirms review submission, and emits health alerts.
- `bin/pr-review-update`: Verifies `origin/main` in a temporary export, then fast-forwards the role clone and updates the role crontab.
- `hosts/*.env` and `install.sh`: Configure non-colliding schedules per host role (`codex`, `claude`, `gemini`, `services`).
- `docs/review-quorum.md`: Runbook for the GitHub App deployment on `services`.
