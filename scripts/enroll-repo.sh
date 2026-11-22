#!/usr/bin/env bash
# Enroll a repository in bot review: merge settings, bot access, and the "main protection" ruleset.
# The command is idempotent. Run it again after a transfer or when the App changes.
#
# usage: enroll-repo.sh OWNER/REPO --app-id ID [--check NAME[:INTEGRATION_ID]]... [--replace-checks]
#                       [--skip-install-check] [--dry-run]
#   --app-id              ID of the bot-review-quorum App installed for OWNER. The ruleset requires its check.
#   --check               Another required check. The default integration is GitHub Actions (15368).
#   --replace-checks      Drop the CI checks of the existing ruleset. By default the script keeps them.
#   --skip-install-check  Skip the check that the App is installed for OWNER. Use it only after you confirm that.
#   --dry-run             Print the ruleset and the planned API calls. Change nothing.
set -euo pipefail

repo_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
template="${ENROLL_RULESET_TEMPLATE:-$repo_dir/github/rulesets/main.json}"
bots=(larkbot-codex larkbot-claude larkbot-gemini)
actions_integration_id=15368

usage() {
    sed -n '2,12p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
}

fail() {
    printf 'enroll-repo.sh: %s\n' "$*" >&2
    exit 1
}

repo="${1:-}"
[[ "$repo" =~ ^[A-Za-z0-9-]+/[A-Za-z0-9._-]+$ ]] || { usage; exit 2; }
shift

app_id=""
dry_run=0
replace_checks=0
skip_install_check=0
checks_json='[]'
while (($# > 0)); do
    case "$1" in
        --app-id)
            app_id="${2:-}"
            shift 2
            ;;
        --check)
            spec="${2:-}"
            shift 2
            name="${spec%%:*}"
            integration="$actions_integration_id"
            if [[ "$spec" == *:* ]]; then
                integration="${spec##*:}"
            fi
            [[ "$name" =~ ^[A-Za-z0-9._\ -]+$ && "$integration" =~ ^[0-9]+$ ]] ||
                fail "invalid --check value: $spec"
            checks_json=$(jq -c --arg name "$name" --argjson id "$integration" \
                '. + [{context: $name, integration_id: $id}]' <<<"$checks_json")
            ;;
        --dry-run)
            dry_run=1
            shift
            ;;
        --replace-checks)
            replace_checks=1
            shift
            ;;
        --skip-install-check)
            skip_install_check=1
            shift
            ;;
        *)
            usage
            exit 2
            ;;
    esac
done
[[ "$app_id" =~ ^[0-9]+$ ]] || fail "--app-id must be the numeric App ID"
[[ -f "$template" ]] || fail "ruleset template not found: $template"

run() {
    if ((dry_run == 1)); then
        printf 'would run: gh %s\n' "$*"
    else
        gh "$@"
    fi
}

visibility=$(gh api "repos/$repo" --jq '.visibility') || fail "cannot read $repo"
printf '%s (%s)\n' "$repo" "$visibility"

# The ruleset will require a check from this App. If the App is not installed for the repository,
# that check can never pass and every pull request is blocked. Confirm it before any change.
owner="${repo%%/*}"
if ((skip_install_check == 0)); then
    owner_type=$(gh api "users/$owner" --jq '.type') || fail "cannot read account $owner"
    if [[ "$owner_type" != Organization ]]; then
        fail "cannot confirm App installations on user account $owner with a personal token. Confirm that App $app_id is installed for $repo, then run again with --skip-install-check."
    fi
    selection=$(gh api "orgs/$owner/installations" \
        --jq ".installations[] | select(.app_id == $app_id) | .repository_selection") ||
        fail "cannot list App installations on $owner"
    if [[ -z "$selection" ]]; then
        fail "App $app_id is not installed on $owner, so its check could never pass on $repo. Install the App or use the App of this owner."
    fi
    if [[ "$selection" != all ]]; then
        fail "App $app_id is installed on $owner for selected repositories only. Confirm that it includes $repo, then run again with --skip-install-check."
    fi
    printf 'App %s: installed on %s for all repositories\n' "$app_id" "$owner"
fi

# GitHub Free allows auto-merge only on public repositories, so send the field only for them.
merge_settings=(
    -F allow_squash_merge=true
    -F allow_merge_commit=false
    -F allow_rebase_merge=false
    -F delete_branch_on_merge=true
)
auto_merge_summary="auto-merge unchanged (GitHub Free allows it only on public repositories)"
if [[ "$visibility" == public ]]; then
    merge_settings+=(-F allow_auto_merge=true)
    auto_merge_summary="auto-merge allowed"
fi
run api -X PATCH "repos/$repo" "${merge_settings[@]}" --silent
printf 'merge settings: squash only, %s, delete merged branches\n' "$auto_merge_summary"

for bot in "${bots[@]}"; do
    run api -X PUT "repos/$repo/collaborators/$bot" -f permission=push --silent
done
printf 'bot access: %s (write)\n' "${bots[*]}"

if [[ "$visibility" != public ]]; then
    printf 'ruleset: skipped. GitHub Free enforces rulesets only on public repositories.\n'
    printf 'bot-review-quorum is advisory on %s.\n' "$repo"
    exit 0
fi

existing_id=$(gh api "repos/$repo/rulesets" \
    --jq '.[] | select(.source_type == "Repository" and .name == "main protection") | .id' | head -n 1)

# An update keeps what the template does not define:
# - rules of other types (for example required_signatures) stay as they are;
# - parameters that the template does not set stay as they are;
# - CI checks stay, unless --replace-checks is given.
# The template wins for the settings it defines (approvals, no bypass, squash only).
existing='null'
kept_json='[]'
if [[ -n "$existing_id" ]]; then
    existing=$(gh api "repos/$repo/rulesets/$existing_id") || fail "cannot read ruleset $existing_id"
    if [[ "$replace_checks" == 0 ]]; then
        kept_json=$(jq -c '[.rules[]? | select(.type == "required_status_checks")
            | .parameters.required_status_checks[]
            | select(.context != "bot-review-quorum")
            | {context} + (if .integration_id == null then {} else {integration_id} end)]' <<<"$existing")
    fi
fi

# The quorum check comes first. A --check value replaces a kept check with the same name.
ruleset=$(jq -c --argjson app_id "$app_id" --argjson kept "$kept_json" --argjson extra "$checks_json" \
    --argjson existing "$existing" '
    ($kept + $extra
        | reduce .[] as $check ([];
            if any(.[]; .context == $check.context)
            then map(if .context == $check.context then $check else . end)
            else . + [$check] end)) as $ci
    | . as $template
    | (if $existing == null then $template.rules
       else
           ($existing.rules | map(
               . as $live
               | ([$template.rules[] | select(.type == $live.type)] | first) as $wanted
               | if $wanted == null then $live
                 else {type: $live.type}
                      + (if ($live.parameters // $wanted.parameters) == null then {}
                         else {parameters: (($live.parameters // {}) + ($wanted.parameters // {}))} end)
                 end))
           + [$template.rules[] | select(.type as $type | all($existing.rules[]; .type != $type))]
       end) as $rules
    | $template + {rules: $rules}
    | .rules |= map(
        if .type == "required_status_checks" then
            .parameters.required_status_checks =
                ([{context: "bot-review-quorum", integration_id: $app_id}] + $ci)
        else . end)
' "$template")

ruleset_file=$(mktemp)
trap 'rm -f -- "$ruleset_file"' EXIT
printf '%s\n' "$ruleset" >"$ruleset_file"
if ((dry_run == 1)); then
    jq . "$ruleset_file"
fi

if [[ -n "$existing_id" ]]; then
    run api -X PUT "repos/$repo/rulesets/$existing_id" --input "$ruleset_file" --silent
    printf 'ruleset: updated "main protection" (%s)\n' "$existing_id"
else
    run api -X POST "repos/$repo/rulesets" --input "$ruleset_file" --silent
    printf 'ruleset: created "main protection"\n'
fi
printf 'required checks: %s\n' "$(jq -r '[.rules[] | select(.type == "required_status_checks") | .parameters.required_status_checks[].context] | join(", ")' "$ruleset_file")"
