#!/usr/bin/env bash
set -euo pipefail

project_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
test_dir=$(mktemp -d)
trap 'rm -rf -- "$test_dir"' EXIT

# shellcheck source=bin/pr-review-quorum
source "$project_dir/bin/pr-review-quorum"

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

# A pull request with many long reviews (here about 450 KB in 2 pages) must not exceed
# the 128 KiB limit for one command argument.
large_review_count=$(
    github_request() {
        local page="${2##*page=}" count=100
        [[ "$page" == 2 ]] && count=50
        jq -cn --argjson count "$count" --arg body "$(printf 'x%.0s' {1..3000})" \
            '[range($count) | {id: ., body: $body}]'
    }
    installation_token=test-token
    collect_pages '/repos/owner/repo/pulls/1/reviews' '.' | jq 'length'
)
[[ "$large_review_count" == 150 ]] ||
    fail "collect_pages lost reviews on a large review list: ${large_review_count:-error}"

bot_codex=270192887
bot_claude=104110997
bot_gemini=320627233
owner=166922787
bots="[$bot_codex,$bot_claude,$bot_gemini]"
head_sha='exact-head'
pull_file="$test_dir/pull.json"
reviews_file="$test_dir/reviews.json"

write_pull() {
    local author="$1" draft="${2:-false}" base="${3:-main}" state="${4:-open}"
    jq -cn --argjson author "$author" --argjson draft "$draft" --arg base "$base" \
        --arg state "$state" --arg head "$head_sha" \
        '{state:$state,draft:$draft,user:{id:$author},head:{sha:$head},base:{ref:$base}}' >"$pull_file"
}

write_reviews() {
    jq -cn "$1" >"$reviews_file"
}

conclusion() {
    evaluate_quorum "$pull_file" "$reviews_file" main "$bots" "$owner" | jq -r '.conclusion'
}

review() {
    local id="$1" login="$2" state="$3" commit="$4" sequence="$5"
    jq -cn --argjson id "$sequence" --argjson user_id "$id" --arg login "$login" \
        --arg state "$state" --arg commit "$commit" --arg submitted "2026-08-28T10:00:0${sequence}Z" \
        '{id:$id,user:{id:$user_id,login:$login},state:$state,commit_id:$commit,submitted_at:$submitted}'
}

assert_bot_pr_requires_other_two_bots_and_owner() {
    local author="$1" first_id="$2" first_login="$3" second_id="$4" second_login="$5"
    local first second owner_rev
    write_pull "$author"
    first=$(review "$first_id" "$first_login" APPROVED "$head_sha" 1)
    second=$(review "$second_id" "$second_login" APPROVED "$head_sha" 2)
    owner_rev=$(review "$owner" thelarklan APPROVED "$head_sha" 3)

    write_reviews "[$first,$second]"
    [[ "$(conclusion)" == failure ]] || fail "bot PR ($author) passed without owner approval"

    write_reviews "[$first,$owner_rev]"
    [[ "$(conclusion)" == failure ]] || fail "bot PR ($author) passed with only one other bot"

    write_reviews "[$first,$second,$owner_rev]"
    [[ "$(conclusion)" == success ]] || fail "bot PR ($author) failed with both other bots and owner"
}

assert_bot_pr_requires_other_two_bots_and_owner "$bot_codex" "$bot_claude" larkbot-claude "$bot_gemini" larkbot-gemini
assert_bot_pr_requires_other_two_bots_and_owner "$bot_claude" "$bot_codex" larkbot-codex "$bot_gemini" larkbot-gemini
assert_bot_pr_requires_other_two_bots_and_owner "$bot_gemini" "$bot_codex" larkbot-codex "$bot_claude" larkbot-claude

codex_review=$(review "$bot_codex" larkbot-codex APPROVED "$head_sha" 1)
claude_review=$(review "$bot_claude" larkbot-claude APPROVED "$head_sha" 2)
gemini_review=$(review "$bot_gemini" larkbot-gemini APPROVED "$head_sha" 3)
owner_review=$(review "$owner" thelarklan APPROVED "$head_sha" 4)

write_pull "$bot_codex"
write_reviews "[$codex_review,$claude_review,$owner_review]"
[[ "$(conclusion)" == failure ]] || fail 'bot author self-approval substituted for missing bot'

write_pull "$owner"
write_reviews "[$codex_review,$claude_review]"
[[ "$(conclusion)" == failure ]] || fail 'owner-authored PR passed with only two bot approvals'
write_reviews "[$codex_review,$claude_review,$owner_review]"
[[ "$(conclusion)" == failure ]] || fail 'owner self-approval substituted for third bot approval'
write_reviews "[$codex_review,$claude_review,$gemini_review]"
[[ "$(conclusion)" == success ]] || fail 'owner-authored PR failed with all three bot approvals'

write_pull "$bot_codex"
stale_review=$(review "$bot_gemini" larkbot-gemini APPROVED old-head 2)
write_reviews "[$claude_review,$stale_review,$owner_review]"
[[ "$(conclusion)" == failure ]] || fail 'stale bot approval counted'

stale_owner=$(review "$owner" thelarklan APPROVED old-head 4)
write_reviews "[$claude_review,$gemini_review,$stale_owner]"
[[ "$(conclusion)" == failure ]] || fail 'stale owner approval counted'

dismissed_review=$(review "$bot_gemini" larkbot-gemini DISMISSED "$head_sha" 5)
write_reviews "[$claude_review,$gemini_review,$dismissed_review,$owner_review]"
[[ "$(conclusion)" == failure ]] || fail 'dismissed approval counted'

gemini_change=$(review "$bot_gemini" larkbot-gemini CHANGES_REQUESTED "$head_sha" 5)
write_reviews "[$claude_review,$gemini_review,$gemini_change,$owner_review]"
[[ "$(conclusion)" == failure ]] || fail 'latest change request did not override approval'

owner_change=$(review "$owner" thelarklan CHANGES_REQUESTED "$head_sha" 5)
write_reviews "[$claude_review,$gemini_review,$owner_review,$owner_change]"
[[ "$(conclusion)" == failure ]] || fail 'latest owner change request did not override approval'

write_pull 999999999
write_reviews "[$codex_review,$claude_review,$gemini_review,$owner_review]"
[[ "$(conclusion)" == failure ]] || fail 'outside author passed the cohort gate'

write_pull "$bot_codex" true
write_reviews "[$claude_review,$gemini_review,$owner_review]"
[[ "$(conclusion)" == failure ]] || fail 'draft pull request passed'

write_pull "$bot_codex" false release
write_reviews "[$claude_review,$gemini_review,$owner_review]"
[[ "$(conclusion)" == failure ]] || fail 'pull request to another base passed'

write_pull "$bot_codex"
jq 'del(.head.sha)' "$pull_file" >"$test_dir/missing-head.json"
mv "$test_dir/missing-head.json" "$pull_file"
empty_claude_review=$(review "$bot_claude" larkbot-claude APPROVED '' 1)
empty_gemini_review=$(review "$bot_gemini" larkbot-gemini APPROVED '' 2)
empty_owner_review=$(review "$owner" thelarklan APPROVED '' 3)
write_reviews "[$empty_claude_review,$empty_gemini_review,$empty_owner_review]"
missing_head_evaluation=$(evaluate_quorum "$pull_file" "$reviews_file" main "$bots" "$owner")
[[ "$(jq -r '.conclusion' <<<"$missing_head_evaluation")" == failure ]] || \
    fail 'missing head and empty review commit IDs passed the quorum gate'
[[ "$(jq -r '[.observed[].exact_head] | any' <<<"$missing_head_evaluation")" == false ]] || \
    fail 'empty review commit ID was marked as an exact-head approval'

repo_policy='{"thelarklan/example":{"auto_merge":true}}'
[[ "$(repository_auto_merge_enabled thelarklan/example "$repo_policy")" == true ]] || \
    fail 'repository auto-merge policy was not read'
[[ "$(repository_auto_merge_enabled thelarklan/missing "$repo_policy")" == false ]] || \
    fail 'unlisted repository did not default to auto_merge=false'

fake_bin="$test_dir/fake-bin"
mkdir -p "$fake_bin"
cat >"$fake_bin/curl" <<EOF
#!/usr/bin/env bash
set -euo pipefail
method=''
previous=''
data=''
authorization=\$(cat)
[[ "\$authorization" == "Authorization: Bearer "* ]] || {
    printf 'fake curl did not receive authorization on stdin\n' >&2
    exit 1
}
for argument in "\$@"; do
    if [[ "\$argument" == *'Authorization: Bearer '* || "\$argument" == installation-token ]]; then
        printf 'authorization token leaked into fake curl argv\n' >&2
        exit 1
    fi
    if [[ "\$previous" == -X ]]; then
        method="\$argument"
    elif [[ "\$previous" == --data-binary ]]; then
        data="\$argument"
    fi
    previous="\$argument"
done
url="\${!#}"
case "\$method \$url" in
    *'/app/installations/157289427/access_tokens')
        printf '%s\n' '{"token":"installation-token"}'
        ;;
    *'/installation/repositories?per_page=100&page=1')
        printf '{"repositories":[{"full_name":"thelarklan/example","owner":{"id":%s},"default_branch":"main"}]}\n' "\${FAKE_REPO_OWNER_ID:-166922787}"
        ;;
    *'/repos/thelarklan/example/pulls?state=open&per_page=100&page=1')
        printf '%s\n' '[{"number":7}]'
        ;;
    *'/repos/thelarklan/example/pulls/7/reviews?per_page=100&page=1')
        if [[ "\${FAKE_REVIEWS_ERROR:-0}" == 1 ]]; then
            exit 22
        fi
        review_head=exact-head
        if [[ "\${FAKE_HEAD_CHANGE:-0}" == 1 ]]; then
            review_head=head-A
        fi
        if [[ "\${FAKE_AUTHOR:-bot}" == owner ]]; then
            if [[ "\${FAKE_APPROVALS:-complete}" == complete ]]; then
                printf '[{"id":1,"user":{"id":270192887,"login":"larkbot-codex"},"state":"APPROVED","commit_id":"%s","submitted_at":"2026-08-28T10:00:01Z"},{"id":2,"user":{"id":104110997,"login":"larkbot-claude"},"state":"APPROVED","commit_id":"%s","submitted_at":"2026-08-28T10:00:02Z"},{"id":3,"user":{"id":320627233,"login":"larkbot-gemini"},"state":"APPROVED","commit_id":"%s","submitted_at":"2026-08-28T10:00:03Z"}]\n' "\$review_head" "\$review_head" "\$review_head"
            else
                printf '[{"id":1,"user":{"id":104110997,"login":"larkbot-claude"},"state":"APPROVED","commit_id":"%s","submitted_at":"2026-08-28T10:00:01Z"},{"id":2,"user":{"id":320627233,"login":"larkbot-gemini"},"state":"APPROVED","commit_id":"%s","submitted_at":"2026-08-28T10:00:02Z"}]\n' "\$review_head" "\$review_head"
            fi
        elif [[ "\${FAKE_APPROVALS:-complete}" == complete ]]; then
            printf '[{"id":1,"user":{"id":104110997,"login":"larkbot-claude"},"state":"APPROVED","commit_id":"%s","submitted_at":"2026-08-28T10:00:01Z"},{"id":2,"user":{"id":320627233,"login":"larkbot-gemini"},"state":"APPROVED","commit_id":"%s","submitted_at":"2026-08-28T10:00:02Z"},{"id":3,"user":{"id":166922787,"login":"thelarklan"},"state":"APPROVED","commit_id":"%s","submitted_at":"2026-08-28T10:00:03Z"}]\n' "\$review_head" "\$review_head" "\$review_head"
        elif [[ "\${FAKE_APPROVALS:-complete}" == bots-only ]]; then
            printf '[{"id":1,"user":{"id":104110997,"login":"larkbot-claude"},"state":"APPROVED","commit_id":"%s","submitted_at":"2026-08-28T10:00:01Z"},{"id":2,"user":{"id":320627233,"login":"larkbot-gemini"},"state":"APPROVED","commit_id":"%s","submitted_at":"2026-08-28T10:00:02Z"}]\n' "\$review_head" "\$review_head"
        else
            printf '[{"id":1,"user":{"id":104110997,"login":"larkbot-claude"},"state":"APPROVED","commit_id":"%s","submitted_at":"2026-08-28T10:00:01Z"}]\n' "\$review_head"
        fi
        ;;
    *'/repos/thelarklan/example/pulls/7')
        pull_head=exact-head
        if [[ "\${FAKE_HEAD_CHANGE:-0}" == 1 ]]; then
            pull_calls=0
            [[ ! -f "\$FAKE_PULL_COUNTER" ]] || read -r pull_calls <"\$FAKE_PULL_COUNTER"
            pull_calls=\$((pull_calls + 1))
            printf '%s\n' "\$pull_calls" >"\$FAKE_PULL_COUNTER"
            if ((pull_calls == 1)); then
                pull_head=head-A
            else
                pull_head=head-B
            fi
        fi
        author_id=270192887
        if [[ "\${FAKE_AUTHOR:-bot}" == owner ]]; then
            author_id=166922787
        fi
        auto_merge_json='null'
        if [[ "\${FAKE_AUTO_MERGE_STATE:-}" == enabled ]]; then
            auto_merge_json='{"enabled_by":{"login":"app"}}'
        elif [[ "\${FAKE_AUTO_MERGE_STATE:-}" == disabled ]]; then
            auto_merge_json='null'
        elif [[ "\${FAKE_APPROVALS:-complete}" != complete ]]; then
            auto_merge_json='{"enabled_by":{"login":"app"}}'
        fi
        printf '{"node_id":"PR_test","auto_merge":%s,"state":"open","draft":false,"html_url":"https://github.com/thelarklan/example/pull/7","user":{"id":%s},"head":{"sha":"%s"},"base":{"ref":"main"}}\n' "\$auto_merge_json" "\$author_id" "\$pull_head"
        ;;
    *'/repos/thelarklan/example/commits/'*'/check-runs?check_name=bot-review-quorum&filter=latest')
        if [[ -n "\${FAKE_EXISTING_CHECK_JSON:-}" ]]; then
            printf '%s\n' "\$FAKE_EXISTING_CHECK_JSON"
        else
            printf '%s\n' '{"check_runs":[]}'
        fi
        ;;
    'POST '*'/repos/thelarklan/example/check-runs')
        if [[ -n "\${CHECK_POST_LOG:-}" ]]; then
            printf '%s\n' "\$data" >>"\$CHECK_POST_LOG"
        fi
        printf '%s\n' '{"id":9001}'
        ;;
    'POST '*'/graphql')
        printf '%s\n' "\$data" >>"\$GRAPHQL_LOG"
        if [[ "\${FAKE_GRAPHQL_ERROR:-0}" == 1 ]]; then
            printf '%s\n' '{"errors":[{"message":"simulated mutation rejection"}]}'
        elif [[ "\$data" == *enablePullRequestAutoMerge* ]]; then
            printf '%s\n' '{"data":{"enablePullRequestAutoMerge":{"pullRequest":{"autoMergeRequest":{"enabledAt":"2026-08-28T10:00:03Z","mergeMethod":"SQUASH"}}}}}'
        else
            printf '%s\n' '{"data":{"disablePullRequestAutoMerge":{"pullRequest":{"autoMergeRequest":null}}}}'
        fi
        ;;
    *)
        printf 'unexpected fake curl request: %s %s\n' "\$method" "\$url" >&2
        exit 1
        ;;
esac
EOF
chmod +x "$fake_bin/curl"

private_key="$test_dir/app.pem"
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$private_key" 2>/dev/null
chmod 600 "$private_key"
repo_policy_file="$test_dir/repo-policy.json"
printf '%s\n' '{"thelarklan/example":{"auto_merge":true}}' >"$repo_policy_file"
chmod 600 "$repo_policy_file"
config_file="$test_dir/quorum.env"
cat >"$config_file" <<EOF
QUORUM_APP_ID=4752010
QUORUM_INSTALLATION_ID=157289427
QUORUM_OWNER_ID=166922787
QUORUM_BOT_IDS=270192887,104110997,320627233
QUORUM_PRIVATE_KEY_FILE=$private_key
QUORUM_CURL_BIN=$fake_bin/curl
QUORUM_AUTO_MERGE=1
QUORUM_REPO_POLICY_FILE=$repo_policy_file
EOF
chmod 600 "$config_file"

graphql_log="$test_dir/graphql.log"
integration_output=$(GRAPHQL_LOG="$graphql_log" QUORUM_CONFIG_FILE="$config_file" \
    "$project_dir/bin/pr-review-quorum")
[[ "$(jq -r '.conclusion' <<<"$integration_output")" == success ]] || \
    fail 'bot PR with both other bots and owner did not publish success'
[[ "$(jq -r '.required_approval_count' <<<"$integration_output")" == 3 ]] || \
    fail 'required_approval_count was not 3'
[[ "$(jq -r '.check_run_id' <<<"$integration_output")" == 9001 ]] || \
    fail 'end-to-end polling fixture did not record the published check run'
[[ "$(jq -r '.auto_merge_action' <<<"$integration_output")" == armed ]] || \
    fail 'successful exact-head quorum did not arm auto-merge'
grep -Fq 'enablePullRequestAutoMerge' "$graphql_log" || \
    fail 'successful exact-head quorum did not use the enable mutation'

integration_output=$(FAKE_AUTHOR=owner GRAPHQL_LOG="$graphql_log" \
    QUORUM_CONFIG_FILE="$config_file" "$project_dir/bin/pr-review-quorum")
[[ "$(jq -r '.conclusion' <<<"$integration_output")" == success ]] || \
    fail 'owner PR with all three bots did not publish success'
[[ "$(jq -r '.auto_merge_action' <<<"$integration_output")" == armed ]] || \
    fail 'owner PR with all three bots did not arm auto-merge'

# An organization-owned repository is skipped unless its owner ID is listed.
org_id=323226749
unlisted_output=$(FAKE_REPO_OWNER_ID="$org_id" GRAPHQL_LOG="$graphql_log" \
    QUORUM_CONFIG_FILE="$config_file" "$project_dir/bin/pr-review-quorum")
[[ -z "$unlisted_output" ]] || \
    fail 'repository of an unlisted owner was evaluated'

org_output=$(FAKE_REPO_OWNER_ID="$org_id" FAKE_AUTHOR=owner GRAPHQL_LOG="$graphql_log" \
    QUORUM_REPOSITORY_OWNER_IDS="166922787,$org_id" \
    QUORUM_CONFIG_FILE="$config_file" "$project_dir/bin/pr-review-quorum")
[[ "$(jq -r '.conclusion' <<<"$org_output")" == success ]] || \
    fail 'organization repository with a listed owner ID was not evaluated'
[[ "$(jq -r '.author_id' <<<"$org_output")" == 166922787 ]] || \
    fail 'human approver must stay separate from the repository owner'

if QUORUM_REPOSITORY_OWNER_IDS="166922787,org" QUORUM_CONFIG_FILE="$config_file" \
    "$project_dir/bin/pr-review-quorum" >/dev/null 2>&1; then
    fail 'non-numeric QUORUM_REPOSITORY_OWNER_IDS was accepted'
fi

head_change_pull_counter="$test_dir/head-change-pulls"
before_mutations=$(wc -l <"$graphql_log")
integration_output=$(FAKE_HEAD_CHANGE=1 \
    FAKE_PULL_COUNTER="$head_change_pull_counter" \
    GRAPHQL_LOG="$graphql_log" QUORUM_CONFIG_FILE="$config_file" \
    "$project_dir/bin/pr-review-quorum")
[[ "$(jq -r '.head' <<<"$integration_output")" == head-B ]] || \
    fail 'head-change fixture did not publish against the fresh head'
[[ "$(jq -r '.conclusion' <<<"$integration_output")" == failure ]] || \
    fail 'head-change evaluation passed with approvals from head-A'
[[ "$(wc -l <"$graphql_log")" == "$before_mutations" ]] || \
    fail 'head-change evaluation armed auto-merge on the unapproved fresh head'

integration_output=$(FAKE_APPROVALS=bots-only GRAPHQL_LOG="$graphql_log" \
    QUORUM_CONFIG_FILE="$config_file" "$project_dir/bin/pr-review-quorum")
[[ "$(jq -r '.conclusion' <<<"$integration_output")" == failure ]] || \
    fail 'bot PR missing owner approval did not publish failure'
[[ "$(jq -r '.auto_merge_action' <<<"$integration_output")" == disarmed ]] || \
    fail 'bot PR missing owner approval did not disarm auto-merge'
grep -Fq 'disablePullRequestAutoMerge' "$graphql_log" || \
    fail 'lost quorum did not use the disable mutation'

integration_output=$(FAKE_AUTHOR=owner FAKE_APPROVALS=missing GRAPHQL_LOG="$graphql_log" \
    QUORUM_CONFIG_FILE="$config_file" "$project_dir/bin/pr-review-quorum")
[[ "$(jq -r '.conclusion' <<<"$integration_output")" == failure ]] || \
    fail 'owner PR missing third bot approval did not publish failure'
[[ "$(jq -r '.auto_merge_action' <<<"$integration_output")" == disarmed ]] || \
    fail 'owner PR missing third bot approval did not disarm auto-merge'

if FAKE_GRAPHQL_ERROR=1 GRAPHQL_LOG="$graphql_log" \
    QUORUM_CONFIG_FILE="$config_file" "$project_dir/bin/pr-review-quorum" \
    >"$test_dir/graphql-error-output" 2>"$test_dir/graphql-error"; then
    fail 'GraphQL mutation error did not fail the poll'
fi
grep -Fq 'GitHub rejected the auto-merge armed mutation' \
    "$test_dir/graphql-error" || fail 'GraphQL mutation failure was not diagnosed'

set +e
integration_output=$(FAKE_REVIEWS_ERROR=1 GRAPHQL_LOG="$graphql_log" \
    QUORUM_CONFIG_FILE="$config_file" "$project_dir/bin/pr-review-quorum" \
    2>"$test_dir/reviews-error")
integration_status=$?
set -e
((integration_status != 0)) || fail 'review-read API failure did not fail the poll'
[[ "$(jq -r '.conclusion' <<<"$integration_output")" == failure ]] || \
    fail 'review-read API failure did not publish failure'
grep -Fq 'could not read reviews for thelarklan/example#7' "$test_dir/reviews-error" || \
    fail 'review-read API failure was not diagnosed'

jq '.["thelarklan/example"].auto_merge = false' "$repo_policy_file" \
    >"$test_dir/repo-policy.next"
mv "$test_dir/repo-policy.next" "$repo_policy_file"
chmod 600 "$repo_policy_file"
before_mutations=$(wc -l <"$graphql_log")
integration_output=$(GRAPHQL_LOG="$graphql_log" QUORUM_CONFIG_FILE="$config_file" \
    "$project_dir/bin/pr-review-quorum")
[[ "$(jq -r '.auto_merge_action' <<<"$integration_output")" == disabled-for-repository ]] || \
    fail 'repository rollout switch did not suppress auto-merge'
[[ "$(wc -l <"$graphql_log")" == "$before_mutations" ]] || \
    fail 'disabled repository still received an auto-merge mutation'
[[ "$(jq -r 'has("check_changed")' <<<"$integration_output")" == false ]] || \
    fail 'internal check_changed field leaked into stdout JSON'

check_post_log="$test_dir/check-posts.log"
: >"$check_post_log"
matching_check_json='{"check_runs":[{"id":9001,"app":{"id":4752010},"conclusion":"success","output":{"title":"Exact-head review quorum satisfied","summary":"Both non-author bot accounts and the repository owner approved head exact-head."}}]}'
integration_output=$(FAKE_EXISTING_CHECK_JSON="$matching_check_json" \
    CHECK_POST_LOG="$check_post_log" GRAPHQL_LOG="$graphql_log" \
    QUORUM_CONFIG_FILE="$config_file" "$project_dir/bin/pr-review-quorum")
[[ -z "$integration_output" ]] || \
    fail 'unchanged check result still wrote a stdout log line'
[[ "$(wc -l <"$check_post_log")" == 0 ]] || \
    fail 'unchanged check result still posted a duplicate check run'

integration_output=$(FAKE_EXISTING_CHECK_JSON="$matching_check_json" \
    QUORUM_LOG_UNCHANGED=1 CHECK_POST_LOG="$check_post_log" GRAPHQL_LOG="$graphql_log" \
    QUORUM_CONFIG_FILE="$config_file" "$project_dir/bin/pr-review-quorum")
[[ "$(jq -r '.check_run_id' <<<"$integration_output")" == 9001 ]] || \
    fail 'QUORUM_LOG_UNCHANGED=1 did not emit the unchanged check run'
[[ "$(wc -l <"$check_post_log")" == 0 ]] || \
    fail 'QUORUM_LOG_UNCHANGED=1 posted a duplicate check run'

jq '.["thelarklan/example"].auto_merge = true' "$repo_policy_file" \
    >"$test_dir/repo-policy.next"
mv "$test_dir/repo-policy.next" "$repo_policy_file"
chmod 600 "$repo_policy_file"

integration_output=$(FAKE_EXISTING_CHECK_JSON="$matching_check_json" \
    FAKE_AUTO_MERGE_STATE=enabled CHECK_POST_LOG="$check_post_log" \
    GRAPHQL_LOG="$graphql_log" QUORUM_CONFIG_FILE="$config_file" \
    "$project_dir/bin/pr-review-quorum")
[[ -z "$integration_output" ]] || \
    fail 'unchanged check with already-enabled auto-merge wrote a stdout log line'

integration_output=$(FAKE_EXISTING_CHECK_JSON="$matching_check_json" \
    FAKE_AUTO_MERGE_STATE=disabled CHECK_POST_LOG="$check_post_log" \
    GRAPHQL_LOG="$graphql_log" QUORUM_CONFIG_FILE="$config_file" \
    "$project_dir/bin/pr-review-quorum")
[[ "$(jq -r '.auto_merge_action' <<<"$integration_output")" == armed ]] || \
    fail 'auto-merge arming with unchanged check did not write a stdout log line'
[[ "$(wc -l <"$check_post_log")" == 0 ]] || \
    fail 'auto-merge arming with unchanged check posted a duplicate check run'

different_title_check_json='{"check_runs":[{"id":9001,"app":{"id":4752010},"conclusion":"success","output":{"title":"Outdated title","summary":"Both non-author bot accounts and the repository owner approved head exact-head."}}]}'
integration_output=$(FAKE_EXISTING_CHECK_JSON="$different_title_check_json" \
    FAKE_AUTO_MERGE_STATE=enabled CHECK_POST_LOG="$check_post_log" \
    GRAPHQL_LOG="$graphql_log" QUORUM_CONFIG_FILE="$config_file" \
    "$project_dir/bin/pr-review-quorum")
[[ "$(jq -r '.conclusion' <<<"$integration_output")" == success ]] || \
    fail 'title change did not emit an updated log line'
[[ "$(wc -l <"$check_post_log")" == 1 ]] || \
    fail 'title change did not publish an updated check run'

if QUORUM_LOG_UNCHANGED=yes QUORUM_CONFIG_FILE="$config_file" \
    "$project_dir/bin/pr-review-quorum" >/dev/null 2>"$test_dir/log-unchanged-error"; then
    fail 'invalid QUORUM_LOG_UNCHANGED did not fail validation'
fi
grep -Fq 'QUORUM_LOG_UNCHANGED must be 0 or 1' "$test_dir/log-unchanged-error" || \
    fail 'invalid QUORUM_LOG_UNCHANGED was not diagnosed'

example_policy_json=$(jq -ce '.' "$project_dir/repo-policy.example.json") || \
    fail 'repo-policy.example.json is not valid JSON'
[[ "$(repository_auto_merge_enabled thelarklan/example-repo "$example_policy_json")" == false ]] || \
    fail 'example-repo auto_merge policy was not false'
[[ "$(repository_auto_merge_enabled thelarklan/unlisted "$example_policy_json")" == false ]] || \
    fail 'unlisted repository policy did not default to false'

printf 'pull request quorum tests passed\n'
