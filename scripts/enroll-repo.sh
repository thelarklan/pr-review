#!/usr/bin/env bash
# Enroll a repository in bot review: merge settings, bot access, and the "main protection" ruleset.
# The command is idempotent. Run it again after a transfer or when the App changes.
#
# usage: enroll-repo.sh OWNER/REPO --app-id ID [--check NAME[:INTEGRATION_ID]]... [--replace-checks] [--dry-run]
#   --app-id          ID of the bot-review-quorum GitHub App. The ruleset requires its check.
#   --check           Another required check. The default integration is GitHub Actions (15368).
#   --replace-checks  Drop the CI checks of the existing ruleset. By default the script keeps them.
#   --dry-run         Print the ruleset and the planned API calls. Change nothing.
set -euo pipefail

repo_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
template="${ENROLL_RULESET_TEMPLATE:-$repo_dir/github/rulesets/main.json}"
bots=(larkbot-codex larkbot-claude larkbot-gemini)
actions_integration_id=15368

usage() {
    sed -n '2,10p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
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

run api -X PATCH "repos/$repo" \
    -F allow_squash_merge=true \
    -F allow_merge_commit=false \
    -F allow_rebase_merge=false \
    -F allow_auto_merge=true \
    -F delete_branch_on_merge=true \
    --silent
printf 'merge settings: squash only, auto-merge allowed, delete merged branches\n'

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

# Keep the CI checks of an existing ruleset, so a new App ID cannot drop them.
# --replace-checks uses only the --check values.
kept_json='[]'
if [[ -n "$existing_id" && "$replace_checks" == 0 ]]; then
    existing=$(gh api "repos/$repo/rulesets/$existing_id") || fail "cannot read ruleset $existing_id"
    kept_json=$(jq -c '[.rules[]? | select(.type == "required_status_checks")
        | .parameters.required_status_checks[]
        | select(.context != "bot-review-quorum")
        | {context} + (if .integration_id == null then {} else {integration_id} end)]' <<<"$existing")
fi

# The quorum check comes first. A --check value replaces a kept check with the same name.
ruleset=$(jq -c --argjson app_id "$app_id" --argjson kept "$kept_json" --argjson extra "$checks_json" '
    ($kept + $extra
        | reduce .[] as $check ([];
            if any(.[]; .context == $check.context)
            then map(if .context == $check.context then $check else . end)
            else . + [$check] end)) as $ci
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
