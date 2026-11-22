#!/usr/bin/env bash
set -euo pipefail

project_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT

unset PR_REVIEW_PROVIDER PR_REVIEW_OWNER PR_REVIEW_REVIEWER \
    PR_REVIEW_MAX_FOLLOWUPS PR_REVIEW_MAX_FAILURES PR_REVIEW_TIMEOUT \
    PR_REVIEW_WORK_ROOT PR_REVIEW_PATH PR_REVIEW_GEMINI_DRIVER \
    PR_REVIEW_CODEX_MODEL PR_REVIEW_CODEX_EFFORT PR_REVIEW_CLAUDE_MODEL \
    PR_REVIEW_CLAUDE_EFFORT PR_REVIEW_ANTIGRAVITY_MODEL \
    PR_REVIEW_ANTIGRAVITY_EFFORT PR_REVIEW_CODEX_BIN PR_REVIEW_CLAUDE_BIN \
    PR_REVIEW_GEMINI_BIN PR_REVIEW_WATCH_BIN PR_REVIEW_PROVIDER_ENV_FILE \
    PR_REVIEW_ALERT_REPO PR_WATCH_OWNER PR_WATCH_REVIEWER \
    PR_WATCH_MAX_FOLLOWUPS PR_WATCH_VERBOSE PR_WATCH_STATE \
    DEV_TOOLS_PR_WATCH_STATE XDG_STATE_HOME XDG_CACHE_HOME

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

assert_arg_pair() {
    local args_file="$1" flag="$2" value="$3" message="$4"
    awk -v flag="$flag" -v value="$value" '
        previous == flag && $0 == value { found = 1 }
        { previous = $0 }
        END { exit !found }
    ' "$args_file" || fail "$message"
}

assert_no_arg() {
    local args_file="$1" flag="$2" message="$3"
    if grep -Fqx -- "$flag" "$args_file"; then
        fail "$message"
    fi
}

home_dir="$test_dir/home"
fake_bin="$home_dir/.local/bin"
mkdir -p "$fake_bin"

cat >"$fake_bin/pr-watch" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
state_target="${PR_WATCH_STATE:-$DEV_TOOLS_PR_WATCH_STATE}"
if [[ "${PR_WATCH_RECORD_STATE:-1}" == "1" ]]; then
    printf '%s conversation head thread 42\n' "$PR_WATCH_ITEM" >>"$state_target"
fi
if [[ -n "${PR_WATCH_ITEM:-}" ]]; then
    printf '%s\n' "$PR_WATCH_ITEM"
fi
EOF
chmod +x "$fake_bin/pr-watch"

cat >"$fake_bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$1" == "api" && "$2" == "user" ]]; then
    printf 'review-bot\n'
elif [[ "$1" == "api" && "$*" == */reviews* && "$*" == *'| .id' ]]; then
    # Review-round query: one review ID per earlier review by this reviewer.
    for ((index = 1; index <= ${FAKE_PRIOR_REVIEWS:-0}; index++)); do
        printf '%s\n' "$((80 + index))"
    done
elif [[ "$1" == "api" && ( "$2" == */reviews* || "${3:-}" == */reviews* ) ]]; then
    if [[ -e "$REVIEW_SUBMITTED" ]]; then
        printf '102\thead-sha\n'
    else
        printf '101\thead-sha\n'
    fi
elif [[ "$1" == "pr" && "$2" == "view" ]]; then
    if [[ -n "${PRE_PROVIDER_FAIL_NUMBER:-}" && "${3:-}" == "$PRE_PROVIDER_FAIL_NUMBER" ]]; then
        printf 'simulated pre-provider head failure\n' >&2
        exit 8
    fi
    if [[ -n "${HEAD_CALLS:-}" ]]; then
        head_calls=0
        [[ ! -e "$HEAD_CALLS" ]] || read -r head_calls <"$HEAD_CALLS"
        head_calls=$((head_calls + 1))
        printf '%s\n' "$head_calls" >"$HEAD_CALLS"
        if [[ "${POST_CONFIRM_FAIL:-0}" == "1" && "$head_calls" -gt 1 ]]; then
            printf 'simulated post-provider head failure\n' >&2
            exit 9
        fi
    fi
    printf 'head-sha\n'
elif [[ "$1" == "issue" && "$2" == "list" ]]; then
    if [[ -n "${ALERT_LOG:-}" ]]; then
        printf 'list:%s\n' "$*" >>"$ALERT_LOG"
    fi
    if [[ -f "${OPEN_ALERT_ISSUE_FILE:-}" ]]; then
        cat "${OPEN_ALERT_ISSUE_FILE}"
    else
        printf '[]\n'
    fi
elif [[ "$1" == "issue" && "$2" == "create" ]]; then
    if [[ -n "${ALERT_LOG:-}" ]]; then
        printf 'create:%s\n' "$*" >>"$ALERT_LOG"
    fi
    if [[ -n "${OPEN_ALERT_ISSUE_FILE:-}" ]]; then
        shift 2
        title=""
        while (($# > 0)); do
            if [[ "$1" == "--title" ]]; then
                title="$2"
                shift 2
            else
                shift
            fi
        done
        jq -cn --arg title "$title" '[{number:77,title:$title}]' >"$OPEN_ALERT_ISSUE_FILE"
    fi
    printf 'https://github.com/owner/pr-review/issues/77\n'
elif [[ "$1" == "issue" && "$2" == "comment" ]]; then
    if [[ -n "${ALERT_LOG:-}" ]]; then
        printf 'comment:%s\n' "$*" >>"$ALERT_LOG"
    fi
elif [[ "$1" == "issue" && "$2" == "close" ]]; then
    if [[ -n "${ALERT_LOG:-}" ]]; then
        printf 'close:%s\n' "$*" >>"$ALERT_LOG"
    fi
    if [[ -n "${OPEN_ALERT_ISSUE_FILE:-}" ]]; then
        printf '[]\n' >"$OPEN_ALERT_ISSUE_FILE"
    fi
else
    printf 'unexpected gh call: %s\n' "$*" >&2
    exit 1
fi
EOF
chmod +x "$fake_bin/gh"

toolchain_bin="$test_dir/toolchain/bin"
mkdir -p "$toolchain_bin"
cat >"$toolchain_bin/test-shell" <<'EOF'
#!/usr/bin/env bash
exec /usr/bin/bash "$@"
EOF
chmod +x "$toolchain_bin/test-shell"

cat >"$fake_bin/codex" <<'EOF'
#!/usr/bin/env test-shell
set -euo pipefail
if [[ -n "${PROVIDER_CALLS:-}" ]]; then
    call_count=0
    [[ ! -e "$PROVIDER_CALLS" ]] || read -r call_count <"$PROVIDER_CALLS"
    printf '%s\n' "$((call_count + 1))" >"$PROVIDER_CALLS"
fi
printf '%s\n' "$@" >"$PROVIDER_ARGS"
touch "$REVIEW_SUBMITTED"
printf 'submitted test review\n'
EOF
chmod +x "$fake_bin/codex"

review_marker="$test_dir/review-submitted"
provider_args="$test_dir/provider-args"
HOME="$home_dir" \
PATH="$fake_bin:/usr/local/bin:/usr/bin:/bin" \
PR_REVIEW_PROVIDER=codex \
PR_REVIEW_PATH="$fake_bin:$toolchain_bin:/usr/local/bin:/usr/bin:/bin" \
PR_REVIEW_WATCH_BIN="$fake_bin/pr-watch" \
PR_REVIEW_CODEX_BIN="$fake_bin/codex" \
PR_REVIEW_TIMEOUT=5s \
PR_WATCH_ITEM=owner/repository#7 \
REVIEW_SUBMITTED="$review_marker" \
PROVIDER_ARGS="$provider_args" \
    "$project_dir/bin/pr-review-cron"

[[ -e "$review_marker" ]] || fail "provider was not invoked"
grep -Fqx 'owner/repository#7 conversation head thread 42' \
    "$home_dir/.local/state/pr-review/pr-watch.seen" || fail "confirmed watcher state was not committed"
grep -Fq 'confirmed review 102 for owner/repository#7 at head-sha' \
    "$home_dir/.local/state/pr-review/cron.log" || fail "review was not confirmed in the log"
assert_arg_pair "$provider_args" --model gpt-6.2-sol "Codex model was not pinned to gpt-6.2-sol"
assert_arg_pair "$provider_args" --config 'model_reasoning_effort="high"' \
    "Codex reasoning effort was not pinned"
grep -Fq 'perform a separate defect-seeking pass' "$provider_args" || \
    fail "review prompt does not require a defect-seeking pass"
grep -Fq 'tests could pass while documented behavior still fails' "$provider_args" || \
    fail "review prompt does not require test-gap analysis"
grep -Fq 'do not manufacture nits' "$provider_args" || \
    fail "review prompt does not reject quota-driven findings"
grep -Fq 'not as the default outcome' "$provider_args" || \
    fail "review prompt does not set the approval threshold"
grep -Fq 'This is your review round 1 on this pull request.' "$provider_args" || \
    fail "first review did not state round 1"
if grep -Fq 'only for a blocking defect' "$provider_args"; then
    fail "first review already used the blocking-defect bar"
fi

# From the third review on, the reviewer requests changes only for blocking defects.
run_round_review() {
    local prior="$1" round_home="$test_dir/round-home-$1"
    mkdir -p "$round_home"
    HOME="$round_home" \
    PATH="$fake_bin:/usr/local/bin:/usr/bin:/bin" \
    PR_REVIEW_PROVIDER=codex \
    PR_REVIEW_PATH="$fake_bin:$toolchain_bin:/usr/local/bin:/usr/bin:/bin" \
    PR_REVIEW_WATCH_BIN="$fake_bin/pr-watch" \
    PR_REVIEW_CODEX_BIN="$fake_bin/codex" \
    PR_REVIEW_TIMEOUT=5s \
    PR_WATCH_ITEM=owner/repository#7 \
    FAKE_PRIOR_REVIEWS="$prior" \
    REVIEW_SUBMITTED="$test_dir/review-submitted-round-$prior" \
    PROVIDER_ARGS="$provider_args" \
        "$project_dir/bin/pr-review-cron"
}
run_round_review 1
grep -Fq 'This is your review round 2 on this pull request.' "$provider_args" || \
    fail "second review did not state round 2"
if grep -Fq 'only for a blocking defect' "$provider_args"; then
    fail "second review already used the blocking-defect bar"
fi
run_round_review 2
grep -Fq 'This is your review round 3 on this pull request.' "$provider_args" || \
    fail "third review did not state round 3"
grep -Fq 'use REQUEST_CHANGES only for a blocking defect' "$provider_args" || \
    fail "third review did not raise the bar to blocking defects"
grep -Fq 'submit APPROVE when no blocking defect remains' "$provider_args" || \
    fail "third review did not say when to approve"

cat >"$fake_bin/claude" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$@" >"$PROVIDER_ARGS"
if [[ -n "${TOKEN_CAPTURE:-}" ]]; then
    printf '%s\n' "${CLAUDE_CODE_OAUTH_TOKEN:-}" >"$TOKEN_CAPTURE"
fi
touch "$REVIEW_SUBMITTED"
printf 'submitted test review\n'
EOF
chmod +x "$fake_bin/claude"

broad_env="$test_dir/broad.env"
printf 'CLAUDE_CODE_OAUTH_TOKEN=test-secret\n' >"$broad_env"
chmod 644 "$broad_env"
if HOME="$home_dir" \
    PR_REVIEW_PROVIDER=claude \
    PR_REVIEW_PROVIDER_ENV_FILE="$broad_env" \
    "$project_dir/bin/pr-review-cron" 2>"$test_dir/broad-env-error"; then
    fail "broad provider env permissions were accepted"
fi
grep -Fq 'provider env permissions are too broad' "$test_dir/broad-env-error" || \
    fail "broad provider env permissions were not diagnosed"

secret_env="$test_dir/provider.env"
printf 'CLAUDE_CODE_OAUTH_TOKEN=secret-oauth-value\n' >"$secret_env"
chmod 600 "$secret_env"
token_capture="$test_dir/token-capture"

rm -- "$review_marker"
HOME="$home_dir" \
PATH="$fake_bin:/usr/local/bin:/usr/bin:/bin" \
PR_REVIEW_PROVIDER=claude \
PR_REVIEW_WATCH_BIN="$fake_bin/pr-watch" \
PR_REVIEW_PROVIDER_ENV_FILE="$secret_env" \
PR_REVIEW_CLAUDE_BIN="$fake_bin/claude" \
PR_REVIEW_TIMEOUT=5s \
PR_WATCH_ITEM=owner/claude#8 \
REVIEW_SUBMITTED="$review_marker" \
PROVIDER_ARGS="$provider_args" \
TOKEN_CAPTURE="$token_capture" \
    "$project_dir/bin/pr-review-cron"
assert_arg_pair "$provider_args" --model claude-opus-5-5 "Claude model was not pinned to claude-opus-5-5"
assert_arg_pair "$provider_args" --effort high "Claude effort was not pinned"
[[ "$(cat "$token_capture")" == "secret-oauth-value" ]] || \
    fail "provider env file did not supply CLAUDE_CODE_OAUTH_TOKEN"
if grep -Fq 'secret-oauth-value' "$home_dir/.local/state/pr-review/cron.log"; then
    fail "provider env secret leaked into cron.log"
fi

cat >"$fake_bin/agy" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$@" >"$PROVIDER_ARGS"
touch "$REVIEW_SUBMITTED"
printf 'submitted test review\n'
EOF
chmod +x "$fake_bin/agy"

rm -- "$review_marker"
HOME="$home_dir" \
PATH="$fake_bin:/usr/local/bin:/usr/bin:/bin" \
PR_REVIEW_PROVIDER=gemini \
PR_REVIEW_WATCH_BIN="$fake_bin/pr-watch" \
PR_REVIEW_GEMINI_BIN="$fake_bin/agy" \
PR_REVIEW_TIMEOUT=5s \
PR_WATCH_ITEM=owner/gemini#9 \
REVIEW_SUBMITTED="$review_marker" \
PROVIDER_ARGS="$provider_args" \
    "$project_dir/bin/pr-review-cron"
assert_arg_pair "$provider_args" --model gemini-4-neon-high \
    "Antigravity model did not default to gemini-4-neon-high"
assert_no_arg "$provider_args" --effort \
    "Antigravity passed --effort when PR_REVIEW_ANTIGRAVITY_EFFORT was empty"

rm -- "$review_marker"
HOME="$home_dir" \
PATH="$fake_bin:/usr/local/bin:/usr/bin:/bin" \
PR_REVIEW_PROVIDER=gemini \
PR_REVIEW_GEMINI_DRIVER=agy \
PR_REVIEW_ANTIGRAVITY_EFFORT=high \
PR_REVIEW_WATCH_BIN="$fake_bin/pr-watch" \
PR_REVIEW_GEMINI_BIN="$fake_bin/agy" \
PR_REVIEW_TIMEOUT=5s \
PR_WATCH_ITEM=owner/gemini#9 \
REVIEW_SUBMITTED="$review_marker" \
PROVIDER_ARGS="$provider_args" \
    "$project_dir/bin/pr-review-cron"
assert_arg_pair "$provider_args" --effort high \
    "Antigravity did not pass explicit PR_REVIEW_ANTIGRAVITY_EFFORT"

rm -- "$review_marker"
batch_calls="$test_dir/batch-provider-calls"
batch_items=$'owner/first#10\nowner/fail#11\nowner/third#12'
if HOME="$home_dir" \
    PATH="$fake_bin:$toolchain_bin:/usr/local/bin:/usr/bin:/bin" \
    PR_REVIEW_PROVIDER=codex \
    PR_REVIEW_WATCH_BIN="$fake_bin/pr-watch" \
    PR_REVIEW_CODEX_BIN="$fake_bin/codex" \
    PR_REVIEW_TIMEOUT=5s \
    PR_WATCH_ITEM="$batch_items" \
    PR_WATCH_RECORD_STATE=0 \
    PRE_PROVIDER_FAIL_NUMBER=11 \
    REVIEW_SUBMITTED="$review_marker" \
    PROVIDER_ARGS="$provider_args" \
    PROVIDER_CALLS="$batch_calls" \
        "$project_dir/bin/pr-review-cron"; then
    fail "batch with a failed preparation query succeeded"
fi
[[ "$(cat "$batch_calls")" == "2" ]] || \
    fail "a preparation query failure truncated the remaining work batch"
grep -Fq 'preparation query failed for owner/fail#11' \
    "$home_dir/.local/state/pr-review/cron.log" || \
    fail "pre-provider query failure did not name the skipped item"
grep -Fq 'reviewing owner/third#12' "$home_dir/.local/state/pr-review/cron.log" || \
    fail "work after a preparation query failure was not attempted"

rm -- "$review_marker"
head_calls="$test_dir/head-calls"
if HOME="$home_dir" \
    PATH="$fake_bin:$toolchain_bin:/usr/local/bin:/usr/bin:/bin" \
    PR_REVIEW_PROVIDER=codex \
    PR_REVIEW_WATCH_BIN="$fake_bin/pr-watch" \
    PR_REVIEW_CODEX_BIN="$fake_bin/codex" \
    PR_REVIEW_TIMEOUT=5s \
    PR_WATCH_ITEM=owner/confirmation#10 \
    REVIEW_SUBMITTED="$review_marker" \
    PROVIDER_ARGS="$provider_args" \
    HEAD_CALLS="$head_calls" \
    POST_CONFIRM_FAIL=1 \
        "$project_dir/bin/pr-review-cron"; then
    fail "post-provider confirmation failure succeeded"
fi
grep -Fq 'confirmation query failed for owner/confirmation#10' \
    "$home_dir/.local/state/pr-review/cron.log" || \
    fail "post-provider confirmation failure aborted without a diagnostic"

rm -- "$review_marker"
failure_calls="$test_dir/failure-calls"
alert_log="$test_dir/alert.log"
open_alert_file="$test_dir/open-alert.json"
: >"$alert_log"
printf '[]\n' >"$open_alert_file"

cat >"$fake_bin/codex" <<'EOF'
#!/usr/bin/env bash
count=0
[[ ! -e "$PROVIDER_CALLS" ]] || read -r count <"$PROVIDER_CALLS"
printf '%s\n' "$((count + 1))" >"$PROVIDER_CALLS"
printf 'ERROR: Your access token could not be refreshed. Please log out and sign in again.\n'
exit 1
EOF
chmod +x "$fake_bin/codex"

for attempt in 1 2; do
    if HOME="$home_dir" \
        PATH="$fake_bin:/usr/local/bin:/usr/bin:/bin" \
        PR_REVIEW_PROVIDER=codex \
        PR_REVIEW_WATCH_BIN="$fake_bin/pr-watch" \
        PR_REVIEW_CODEX_BIN="$fake_bin/codex" \
        PR_REVIEW_MAX_FAILURES=2 \
        PR_REVIEW_ALERT_REPO=owner/pr-review \
        ALERT_LOG="$alert_log" \
        OPEN_ALERT_ISSUE_FILE="$open_alert_file" \
        PR_REVIEW_TIMEOUT=5s \
        PR_WATCH_ITEM=owner/another#8 \
        PR_WATCH_RECORD_STATE=0 \
        REVIEW_SUBMITTED="$review_marker" \
        PROVIDER_CALLS="$failure_calls" \
            "$project_dir/bin/pr-review-cron"; then
        fail "unconfirmed provider run $attempt succeeded"
    fi
done
[[ "$(grep -Fc 'create:' "$alert_log")" == 1 ]] || \
    fail "auth failure did not create exactly one health alert issue"
[[ "$(grep -Fc 'comment:' "$alert_log")" == 1 ]] || \
    fail "escalation change did not update the existing health alert issue"

HOME="$home_dir" \
PATH="$fake_bin:/usr/local/bin:/usr/bin:/bin" \
PR_REVIEW_PROVIDER=codex \
PR_REVIEW_WATCH_BIN="$fake_bin/pr-watch" \
PR_REVIEW_CODEX_BIN="$fake_bin/codex" \
PR_REVIEW_MAX_FAILURES=2 \
PR_REVIEW_ALERT_REPO=owner/pr-review \
ALERT_LOG="$alert_log" \
OPEN_ALERT_ISSUE_FILE="$open_alert_file" \
PR_REVIEW_TIMEOUT=5s \
PR_WATCH_ITEM=owner/another#8 \
PR_WATCH_RECORD_STATE=0 \
REVIEW_SUBMITTED="$review_marker" \
PROVIDER_CALLS="$failure_calls" \
    "$project_dir/bin/pr-review-cron"
[[ "$(cat "$failure_calls")" == "2" ]] || fail "provider retries were not bounded"
[[ "$(grep -Fc 'close:' "$alert_log")" == 0 ]] || \
    fail "health alert issue closed while paused PRs remained"
grep -Fq 'ESCALATE: owner/another#8 failed 2 consecutive attempt(s)' \
    "$home_dir/.local/state/pr-review/cron.log" || fail "provider failures did not escalate"
grep -Fq 'owner/another#8 at head-sha remains paused after 2 unconfirmed attempt(s)' \
    "$home_dir/.local/state/pr-review/cron.log" || fail "paused item was not named in the log"
if grep -Fq 'owner/another#8 ' "$home_dir/.local/state/pr-review/pr-watch.seen"; then
    fail "failed primary provider state was committed"
fi
if grep -Eq 'owner/(confirmation#10|third#12) ' \
    "$home_dir/.local/state/pr-review/provider-failures"; then
    fail "inactive provider failure state was not pruned"
fi

HOME="$home_dir" \
PATH="$fake_bin:/usr/local/bin:/usr/bin:/bin" \
PR_REVIEW_PROVIDER=codex \
PR_REVIEW_WATCH_BIN="$fake_bin/pr-watch" \
PR_REVIEW_CODEX_BIN="$fake_bin/codex" \
PR_REVIEW_ALERT_REPO=owner/pr-review \
ALERT_LOG="$alert_log" \
OPEN_ALERT_ISSUE_FILE="$open_alert_file" \
PR_REVIEW_TIMEOUT=5s \
PR_WATCH_ITEM='' \
PR_WATCH_RECORD_STATE=0 \
REVIEW_SUBMITTED="$review_marker" \
    "$project_dir/bin/pr-review-cron"
[[ "$(grep -Fc 'close:' "$alert_log")" == 1 ]] || \
    fail "clean recovery run did not close the open health alert issue"
[[ ! -e "$home_dir/.local/state/pr-review/last-alert-key" ]] || \
    fail "last-alert-key remained after closing the health alert issue"

if HOME="$home_dir" PR_REVIEW_PROVIDER=codex PR_REVIEW_PATH=CHANGE_ME \
    "$project_dir/bin/pr-review-cron" 2>/dev/null; then
    fail "provider PATH placeholder was accepted"
fi

if HOME="$home_dir" PR_REVIEW_PROVIDER=unknown "$project_dir/bin/pr-review-cron" 2>/dev/null; then
    fail "unknown provider succeeded"
fi

printf 'pull request review cron tests passed\n'
