# Recreate the review system

Use this runbook to rebuild the review system from nothing, or to move it to a new organization.
Each step uses a file or a script in this repository.

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

Run this step with a `gh` login that is an owner of the organization.

```bash
scripts/enroll-repo.sh thelarklanlabs/pr-review --app-id APP_ID --check verify
scripts/enroll-repo.sh thelarklanlabs/lol --app-id APP_ID
scripts/enroll-repo.sh thelarklanlabs/wsl-tools --app-id APP_ID \
  --check powershell --check shell --check windows-powershell
scripts/enroll-repo.sh thelarklanlabs/jenkins-controller --app-id APP_ID
scripts/enroll-repo.sh thelarklanlabs/podman-tools --app-id APP_ID
```

- Add `--dry-run` to see the ruleset and the planned calls first.
- The script sets squash merge only, gives the three bots write access, and writes the ruleset.
- It updates an existing "main protection" ruleset in place. Run it again after you change the App.
- GitHub Free enforces rulesets only on public repositories.
  On a private repository, `bot-review-quorum` is advisory.

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

## 4. Move the repository to a new owner

1. Transfer the repository on GitHub.
2. On each host, point the clone at the new URL and install the role again:

   ```bash
   cd ~/projects/repos/pr-review
   git remote set-url origin https://github.com/NEW_OWNER/pr-review.git
   bash install.sh --role ROLE
   ```

   `install.sh` reads the updater URL from the `origin` remote.
3. Update `PR_REVIEW_OWNER` and `PR_REVIEW_ALERT_REPO` in `hosts/*.env` with a pull request.

## 5. Export the live configuration

Compare the live rulesets with `github/rulesets/main.json`:

```bash
for repo in $(gh repo list thelarklanlabs --json nameWithOwner --jq '.[].nameWithOwner'); do
  gh api "repos/$repo/rulesets" --jq '.[] | "\(.id) \(.name)"' | sed "s|^|$repo |"
done
```

Use `scripts/enroll-repo.sh --dry-run` to see the ruleset that the script writes.
