#!/usr/bin/env bash
# Create the bot-review-quorum GitHub App from github/app-manifest.json and write its private config.
#
# Steps (run on the services host):
#   1. create-app.sh form --org ORG
#      Open the HTML file it writes and press the button. GitHub creates the App,
#      then opens the redirect page with "?code=..." in the address bar.
#   2. create-app.sh exchange --code CODE
#      Saves the private key (mode 600) and prints the App ID and slug.
#   3. Install the App on ORG with "All repositories" at https://github.com/apps/<slug>/installations/new
#   4. create-app.sh installation --org ORG --app-id ID --key FILE
#      Prints the installation ID.
#   5. create-app.sh config --org ORG --app-id ID --installation-id ID --key FILE --repository-owner-ids IDS
#      Writes ~/.config/pr-review/ORG.env (mode 600) for bin/pr-review-quorum.
set -euo pipefail

repo_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
config_dir="${PR_REVIEW_CONFIG_DIR:-$HOME/.config/pr-review}"
app_curl="${CREATE_APP_CURL_BIN:-curl}"
app_api_url="${CREATE_APP_API_URL:-https://api.github.com}"

# Cohort defaults: thelarklan is the human approver; the three bots review.
default_owner_id=166922787
default_bot_ids=270192887,104110997,320627233

usage() {
    sed -n '2,15p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
    printf '\nusage: %s form|exchange|installation|config [options]\n' "$0" >&2
}

fail() {
    printf 'create-app.sh: %s\n' "$*" >&2
    exit 1
}

require_value() {
    local name="$1" value="$2" pattern="$3"
    [[ -n "$value" ]] || fail "$name is required"
    [[ "$value" =~ $pattern ]] || fail "$name has an unsafe value: $value"
}

cmd_form() {
    local org="" manifest="$repo_dir/github/app-manifest.json" out=""
    while (($# > 0)); do
        case "$1" in
            --org) org="$2"; shift 2 ;;
            --manifest) manifest="$2"; shift 2 ;;
            --out) out="$2"; shift 2 ;;
            *) usage; exit 2 ;;
        esac
    done
    require_value --org "$org" '^[A-Za-z0-9-]+$'
    [[ -f "$manifest" ]] || fail "manifest not found: $manifest"
    jq -e '.name and .default_permissions' "$manifest" >/dev/null || fail "manifest is not valid"
    out="${out:-$PWD/create-$org-app.html}"

    # Escape the JSON for an HTML attribute value.
    local manifest_attr
    manifest_attr=$(jq -c . "$manifest" | sed -e 's/&/\&amp;/g' -e 's/"/\&quot;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g')
    cat >"$out" <<EOF
<!doctype html>
<meta charset="utf-8">
<title>Create GitHub App for $org</title>
<p>This form sends <code>github/app-manifest.json</code> to GitHub to create the App in <b>$org</b>.</p>
<form action="https://github.com/organizations/$org/settings/apps/new" method="post">
  <input type="hidden" name="manifest" value="$manifest_attr">
  <button type="submit">Create GitHub App in $org</button>
</form>
<p>After GitHub creates the App, copy the <code>code</code> value from the address bar.
Then run <code>scripts/create-app.sh exchange --code CODE</code> within one hour.</p>
EOF
    printf 'Wrote %s\n' "$out"
}

cmd_exchange() {
    local code="" response app_id slug key_file
    while (($# > 0)); do
        case "$1" in
            --code) code="$2"; shift 2 ;;
            *) usage; exit 2 ;;
        esac
    done
    require_value --code "$code" '^[A-Za-z0-9_-]+$'

    install -d -m 700 "$config_dir"
    umask 077
    response=$("$app_curl" -fsS -X POST \
        -H 'Accept: application/vnd.github+json' \
        -H 'X-GitHub-Api-Version: 2022-11-28' \
        "$app_api_url/app-manifests/$code/conversions") || fail "GitHub rejected the manifest code"

    app_id=$(jq -er '.id' <<<"$response") || fail "response has no App ID"
    slug=$(jq -er '.slug' <<<"$response") || fail "response has no App slug"
    [[ "$app_id" =~ ^[0-9]+$ && "$slug" =~ ^[A-Za-z0-9-]+$ ]] || fail "response has unsafe App ID or slug"

    key_file="$config_dir/$slug.pem"
    jq -er '.pem' <<<"$response" >"$key_file.next" || fail "response has no private key"
    chmod 600 "$key_file.next"
    mv -f -- "$key_file.next" "$key_file"
    # The response also holds a client secret and a webhook secret. This App uses neither, so they are not stored.
    response=""

    printf 'App ID: %s\nApp slug: %s\nPrivate key: %s\n' "$app_id" "$slug" "$key_file"
    printf 'Next: install the App at https://github.com/apps/%s/installations/new\n' "$slug"
}

cmd_installation() {
    local org="" app_id="" key="" jwt installations
    while (($# > 0)); do
        case "$1" in
            --org) org="$2"; shift 2 ;;
            --app-id) app_id="$2"; shift 2 ;;
            --key) key="$2"; shift 2 ;;
            *) usage; exit 2 ;;
        esac
    done
    require_value --org "$org" '^[A-Za-z0-9-]+$'
    require_value --app-id "$app_id" '^[0-9]+$'
    [[ -f "$key" ]] || fail "--key must name the App private key"

    # Reuse the JWT signer of bin/pr-review-quorum.
    # shellcheck source=bin/pr-review-quorum
    QUORUM_CONFIG_FILE="" source "$repo_dir/bin/pr-review-quorum"
    QUORUM_APP_ID="$app_id" QUORUM_PRIVATE_KEY_FILE="$key" jwt=$(make_app_jwt)
    installations=$(printf 'Authorization: Bearer %s\n' "$jwt" | "$app_curl" -fsS \
        -H 'Accept: application/vnd.github+json' \
        -H 'X-GitHub-Api-Version: 2022-11-28' \
        -H @- \
        "$app_api_url/app/installations") || fail "could not list App installations"
    jq -er --arg org "$org" \
        '.[] | select(.account.login == $org) | .id' <<<"$installations" ||
        fail "the App is not installed on $org"
}

cmd_config() {
    local org="" app_id="" installation_id="" key="" owner_id="$default_owner_id"
    local bot_ids="$default_bot_ids" repository_owner_ids="" policy_file="" out
    while (($# > 0)); do
        case "$1" in
            --org) org="$2"; shift 2 ;;
            --app-id) app_id="$2"; shift 2 ;;
            --installation-id) installation_id="$2"; shift 2 ;;
            --key) key="$2"; shift 2 ;;
            --owner-id) owner_id="$2"; shift 2 ;;
            --bot-ids) bot_ids="$2"; shift 2 ;;
            --repository-owner-ids) repository_owner_ids="$2"; shift 2 ;;
            --policy) policy_file="$2"; shift 2 ;;
            *) usage; exit 2 ;;
        esac
    done
    require_value --org "$org" '^[A-Za-z0-9-]+$'
    require_value --app-id "$app_id" '^[0-9]+$'
    require_value --installation-id "$installation_id" '^[0-9]+$'
    require_value --owner-id "$owner_id" '^[0-9]+$'
    require_value --bot-ids "$bot_ids" '^[0-9]+,[0-9]+,[0-9]+$'
    require_value --repository-owner-ids "$repository_owner_ids" '^[0-9]+(,[0-9]+)*$'
    [[ -f "$key" ]] || fail "--key must name the App private key"
    policy_file="${policy_file:-$config_dir/repo-policy.json}"
    [[ -f "$policy_file" ]] || fail "repository policy not found: $policy_file"

    install -d -m 700 "$config_dir"
    umask 077
    out="$config_dir/$org.env"
    cat >"$out.next" <<EOF
# bot-review-quorum App on $org. Written by scripts/create-app.sh.
QUORUM_APP_ID=$app_id
QUORUM_INSTALLATION_ID=$installation_id
QUORUM_OWNER_ID=$owner_id
QUORUM_REPOSITORY_OWNER_IDS=$repository_owner_ids
QUORUM_BOT_IDS=$bot_ids
QUORUM_PRIVATE_KEY_FILE="$key"
QUORUM_REPO_POLICY_FILE="$policy_file"
QUORUM_AUTO_MERGE=0
EOF
    chmod 600 "$out.next"
    mv -f -- "$out.next" "$out"
    printf 'Wrote %s\n' "$out"
}

command_name="${1:-}"
shift || true
case "$command_name" in
    form) cmd_form "$@" ;;
    exchange) cmd_exchange "$@" ;;
    installation) cmd_installation "$@" ;;
    config) cmd_config "$@" ;;
    -h | --help) usage ;;
    *) usage; exit 2 ;;
esac
