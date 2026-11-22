# Recreate the review system

Use this runbook to rebuild the review system from nothing, or to move it to a new organization.
Each step uses a file or a script in this repository.

Until the transfer to `thelarklanlabs`, the repository is at `https://github.com/thelarklan/pr-review`.
The `git clone` commands below use the target URL. Before the transfer, clone from `thelarklan/pr-review` instead.
Do not change any other command. In particular, do not enroll a repository before it belongs to the organization.

## Which App serves which owner

Each App is private, so it can publish checks only for the account that owns it.
A ruleset must require the check from the App of the repository owner.
Otherwise the check never arrives, and every pull request is blocked.

| Repository owner | App | App ID | Config on `services` |
| --- | --- | --- | --- |
| `thelarklanlabs` (organization) | `thelarklanlabs-bot-review-quorum` | `5877283` | `~/.config/pr-review/thelarklanlabs.env` |
| `thelarklan` (user account) | `thelarklan-bot-review-quorum` | `4752010` | `~/.config/pr-review/pr-review-quorum.env` |

`scripts/enroll-repo.sh` confirms that the App is installed for an organization before it changes anything.
It cannot confirm this for a user account. For a user account, confirm it yourself, then add `--skip-install-check`.

| Part | Source in this repository |
| --- | --- |
| GitHub App definition | `github/app-manifest.json` |
| GitHub App creation and private config | `scripts/create-app.sh` |
| Repository ruleset | `github/rulesets/main.json` |
| Repository enrollment | `scripts/enroll-repo.sh` |
| Host schedules | `hosts/*.env` and `install.sh` |

## Prerequisites

1. An organization (for example `thelarklanlabs`) where `thelarklan` is an owner.
2. The bot accounts `larkbot-codex`, `larkbot-claude`, and `larkbot-gemini` as organization members.
3. Five WSL distributions: `services` (account `thelarklan`) and one for each bot (`codex`, `claude`, `gemini`).
4. On each distribution: `git`, `jq`, `curl`, `openssl`, `flock`, `shellcheck`, and `python3`.
5. On each bot distribution: `gh` signed in as the bot, and the AI CLI signed in.

## 1. Create the GitHub App

Run these steps on `services`.
The private key goes only to `services`.

1. Clone the repository and verify it:

   ```bash
   git clone https://github.com/thelarklanlabs/pr-review.git ~/projects/repos/pr-review
   cd ~/projects/repos/pr-review
   bash scripts/verify.sh
   ```

2. Write the manifest form:

   ```bash
   scripts/create-app.sh form --org thelarklanlabs --out /mnt/c/Users/thela/Downloads/create-app.html
   ```

3. Open the HTML file in a browser that is signed in as `thelarklan`.
4. Press the button. GitHub creates the App.
5. Copy the `code` value from the address bar of the redirect page.
6. Exchange the code within one hour:

   ```bash
   scripts/create-app.sh exchange --code CODE
   ```

   The script saves `~/.config/pr-review/<slug>.pem` with mode `600`.
   It prints the App ID and the slug. It prints no secret.
7. Open `https://github.com/apps/<slug>/installations/new`.
8. Install the App on the organization with "All repositories".
9. Get the installation ID:

   ```bash
   scripts/create-app.sh installation --org thelarklanlabs --app-id APP_ID \
     --key ~/.config/pr-review/<slug>.pem
   ```

10. Create `~/.config/pr-review/repo-policy.json` from `repo-policy.example.json` with mode `600`.
11. Write the private config for the quorum check:

    ```bash
    scripts/create-app.sh config --org thelarklanlabs --app-id APP_ID \
      --installation-id INSTALLATION_ID --key ~/.config/pr-review/<slug>.pem \
      --repository-owner-ids "$(gh api orgs/thelarklanlabs --jq .id)"
    ```

12. Make sure that `QUORUM_CONFIG_FILES` in `hosts/services.env` names this file.
13. Run one foreground audit:

    ```bash
    QUORUM_CONFIG_FILE="$HOME/.config/pr-review/thelarklanlabs.env" QUORUM_LOG_UNCHANGED=1 \
      bin/pr-review-quorum
    ```

14. Install the schedule:

    ```bash
    bash install.sh --role services
    ```

## 2. Enroll each repository

Enroll only repositories that the organization owns.
For a repository on another account, do section 4 first.
Run this step with a `gh` login that is an owner of the organization.

Set `APP_ID` to the App ID that `create-app.sh exchange` printed in section 1.
For the App that runs now, the value is in the table above.

```bash
APP_ID=5877283   # replace with the ID from section 1 after a rebuild
scripts/enroll-repo.sh thelarklanlabs/pr-review --app-id "$APP_ID" --check verify --dry-run
scripts/enroll-repo.sh thelarklanlabs/pr-review --app-id "$APP_ID" --check verify
```

- The script stops before any change if the App is not installed on the organization for all repositories.
- It sets squash merge only, gives the three bots write access, and writes the "main protection" ruleset.
- It allows auto-merge only on public repositories, because GitHub Free allows it only there.
- On an existing ruleset, it keeps the CI checks and the rules and parameters that the template does not define.
  The template wins for approvals, merge methods, and bypass actors.
- GitHub Free enforces rulesets only on public repositories.
  On a private repository, the script skips the ruleset, and `bot-review-quorum` is advisory.

## 3. Install each bot host

Run these steps on `codex`, `claude`, and `gemini`.

1. Sign in to `gh` as the bot account.
2. Sign in to the AI CLI:
   - `codex`: run `codex login`.
   - `claude`: run `claude setup-token`.
     Put `CLAUDE_CODE_OAUTH_TOKEN=<token>` in `~/.config/pr-review/provider.env` with mode `600`.
   - `gemini`: sign in to `agy`.
3. Clone, verify, and install the role:

   ```bash
   git clone https://github.com/thelarklanlabs/pr-review.git ~/projects/repos/pr-review
   bash ~/projects/repos/pr-review/scripts/verify.sh
   bash ~/projects/repos/pr-review/install.sh --role ROLE
   ```

## 4. Move a repository into the organization

Do these steps without a pause.
After the transfer, the old ruleset still requires the check from the user-account App.
That App cannot publish in the organization, so pull requests stay blocked until step 3.

1. Make sure that `services` runs the organization App: `crontab -l` shows a line for `thelarklanlabs.env`.
2. Transfer the repository on GitHub.
3. Enroll it with the organization App (section 2). Use `--dry-run` first.
4. Confirm the check: on an open pull request, `bot-review-quorum` comes from `thelarklanlabs-bot-review-quorum`.

## 5. Move this repository to a new owner

Do section 4 for this repository first. Then:

1. On each host, point the clone at the new URL and install the role again:

   ```bash
   cd ~/projects/repos/pr-review
   git remote set-url origin https://github.com/NEW_OWNER/pr-review.git
   bash install.sh --role ROLE
   ```

   `install.sh` reads the updater URL from the `origin` remote.
2. Update `PR_REVIEW_OWNER` and `PR_REVIEW_ALERT_REPO` in `hosts/*.env` with a pull request.

## 6. Export the live configuration

Compare the live rulesets with `github/rulesets/main.json`:

```bash
for repo in $(gh repo list thelarklanlabs --json nameWithOwner --jq '.[].nameWithOwner'); do
  gh api "repos/$repo/rulesets" --jq '.[] | "\(.id) \(.name)"' | sed "s|^|$repo |"
done
```

Use `scripts/enroll-repo.sh --dry-run` to see the ruleset that the script writes.
