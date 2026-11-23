#!/usr/bin/env bash
set -euo pipefail

project_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

mkdir -p "$test_dir/bin"
cat >"$test_dir/bin/gh" <<'EOF'
#!/bin/bash
set -euo pipefail

printf '%s\n' "$*" >>"$GH_CALL_LOG"

if [[ "$*" == "auth status" ]]; then
    exit 0
fi
if [[ "$1" == "api" && "${2:-}" == "user" ]]; then
    printf '%s\n' "${GH_LOGIN:-larkbot-codex}"
    exit 0
fi
if [[ "$1" == "search" && "${2:-}" == "prs" ]]; then
    if [[ "$GH_SCENARIO" == "fail-search" ]]; then
        printf 'simulated search failure\n' >&2
        exit 9
    fi
    if [[ "$GH_SCENARIO" == "ceiling" ]]; then
        for number in $(seq 1 1000); do
            printf 'thelarklan/repo\t%s\tother-user\tfalse\n' "$number"
        done
        exit 0
    fi
    if [[ "$GH_SCENARIO" == "self-draft" ]]; then
        printf 'thelarklan/self\t1\tlarkbot-codex\tfalse\n'
        printf 'thelarklan/draft\t2\tother-user\ttrue\n'
        exit 0
    fi
    printf 'thelarklan/repo\t1\tother-user\tfalse\n'
    exit 0
fi

case " $* " in
    *" /repos/thelarklan/repo/pulls/1 "*)
        printf 'head-one\tfalse\tother-user\n'
        ;;
    *" /repos/thelarklan/repo/pulls/1/reviews?per_page=100 "*)
        if [[ "$GH_SCENARIO" != "new-head" ]]; then
            if [[ "$GH_SCENARIO" == "dismissed" ]]; then
                printf 'larkbot-codex\thead-one\t2026-08-26T10:00:00Z\tDISMISSED\n'
            else
                printf 'larkbot-codex\thead-one\t2026-08-26T10:00:00Z\tAPPROVED\n'
            fi
        fi
        ;;
    *" /repos/thelarklan/repo/issues/1/timeline?per_page=100 "*)
        if [[ "$GH_SCENARIO" == "ready" ]]; then
            printf '20\t2026-08-26T10:01:00Z\n'
        fi
        ;;
    *" api graphql "*)
        case "$GH_SCENARIO" in
            thread)
                printf 'false\tfalse\tlarkbot-codex\t30\t2026-08-26T10:02:00Z\tother-user\n'
                ;;
            resolved-thread)
                printf 'true\tfalse\tlarkbot-codex\t31\t2026-08-26T10:02:00Z\tother-user\n'
                ;;
            truncated-thread)
                printf 'false\ttrue\tlarkbot-codex\t32\t2026-08-26T10:02:00Z\tother-user\n'
                ;;
        esac
        ;;
    *" /repos/thelarklan/repo/issues/1/comments?per_page=100&since=2026-08-26T10:00:00Z "*)
        if [[ "$GH_SCENARIO" == "command" ]]; then
            printf '%s\t%s\n' "${GH_EVENT_ID:-40}" "${GH_EVENT_TIME:-2026-08-26T10:03:00Z}"
        fi
        ;;
    *)
        printf 'unexpected gh call: %s\n' "$*" >&2
        exit 10
        ;;
esac
EOF
chmod +x "$test_dir/bin/gh"

run_watch() {
    local scenario="$1" state_file="$2"
    shift 2
    : >"$test_dir/stdout"
    : >"$test_dir/stderr"
    : >"$test_dir/gh-calls"
    set +e
    env PATH="$test_dir/bin:$PATH" \
        GH_CALL_LOG="$test_dir/gh-calls" \
        GH_SCENARIO="$scenario" \
        GH_EVENT_ID="${GH_EVENT_ID:-}" \
        GH_EVENT_TIME="${GH_EVENT_TIME:-}" \
        PR_WATCH_STATE="$state_file" \
        "$@" "$project_dir/bin/pr-watch" \
        >"$test_dir/stdout" 2>"$test_dir/stderr"
    watch_status=$?
    set -e
}

run_watch new-head "$test_dir/new-head.state"
[[ "$watch_status" -eq 0 ]] || fail "new-head watch failed"
[[ "$(cat "$test_dir/stdout")" == "thelarklan/repo#1" ]] || fail "new head was not reported"
grep -Fq 'search prs --owner thelarklan --state open' "$test_dir/gh-calls" || \
    fail "default owner was not searched"

run_watch new-head "$test_dir/two-owners.state" PR_WATCH_OWNER=thelarklan,thelarklanlabs
[[ "$watch_status" -eq 0 ]] || fail "two-owner watch failed"
grep -Fq 'search prs --owner thelarklan --owner thelarklanlabs --state open' "$test_dir/gh-calls" || \
    fail "both owners were not searched in one call"

run_watch new-head "$test_dir/bad-owner.state" 'PR_WATCH_OWNER=thelarklan;other'
[[ "$watch_status" -eq 2 ]] || fail "invalid owner list was accepted"

# Opt-in: with a label, the search returns only pull requests that carry it.
if grep -Fq -- '--label' "$test_dir/gh-calls"; then
    fail "search without PR_WATCH_LABEL used a label filter"
fi
run_watch new-head "$test_dir/label.state" PR_WATCH_LABEL=bot-review
[[ "$watch_status" -eq 0 ]] || fail "labeled watch failed"
grep -Fq 'search prs --owner thelarklan --label bot-review --state open' "$test_dir/gh-calls" ||
    fail "opt-in label was not passed to the search"
run_watch new-head "$test_dir/bad-label.state" 'PR_WATCH_LABEL=bot review'
[[ "$watch_status" -eq 2 ]] || fail "invalid label was accepted"

touch "$test_dir/persistent-lock.state.lock"
run_watch new-head "$test_dir/persistent-lock.state"
[[ "$watch_status" -eq 0 ]] || fail "an unlocked lock file wedged the watcher"

held_state="$test_dir/held-lock.state"
exec {held_lock_fd}>"${held_state}.lock"
flock -n "$held_lock_fd" || fail "could not hold the watcher test lock"
run_watch new-head "$held_state"
[[ "$watch_status" -ne 0 ]] || fail "a concurrent watcher was accepted"
grep -Fq 'another watcher is using' "$test_dir/stderr" || \
    fail "concurrent watcher failure was not explained"
exec {held_lock_fd}>&-

# pr-watch is a standalone script, so it needs bash and core tools on PATH.
# Link those tools into a separate directory and leave out flock.
no_flock_bin="$test_dir/no-flock-bin"
mkdir -p "$no_flock_bin"
for tool in bash env cat cut date dirname grep jq mkdir mktemp mv rm sed sort touch tr; do
    if tool_path=$(type -P "$tool"); then
        ln -sf "$tool_path" "$no_flock_bin/$tool"
    fi
done
run_watch quiet "$test_dir/missing-flock.state" PATH="$test_dir/bin:$no_flock_bin"
[[ "$watch_status" -ne 0 ]] || fail "watcher without flock succeeded"
grep -Fq 'flock is not installed' "$test_dir/stderr" || \
    fail "missing flock was reported as a lock collision"

run_watch dismissed "$test_dir/dismissed.state"
[[ "$watch_status" -eq 0 ]] || fail "dismissed-review watch failed"
[[ "$(cat "$test_dir/stdout")" == "thelarklan/repo#1" ]] || fail "dismissed review suppressed work"

run_watch self-draft "$test_dir/self-draft.state"
[[ "$watch_status" -eq 0 ]] || fail "self/draft watch failed"
[[ ! -s "$test_dir/stdout" ]] || fail "self-authored or draft PR was reported"
if grep -q '/pulls/' "$test_dir/gh-calls"; then
    fail "self-authored or draft PR triggered detail calls"
fi

run_watch quiet "$test_dir/quiet.state" PR_WATCH_VERBOSE=1
[[ "$watch_status" -eq 0 ]] || fail "quiet watch failed"
[[ ! -s "$test_dir/stdout" ]] || fail "quiet watch printed actionable work"
grep -Fq 'pr-watch: checked 1 open PR(s)' "$test_dir/stderr" || fail "verbose count is missing"
grep -Fq 'api --paginate /repos/thelarklan/repo/pulls/1/reviews?per_page=100' "$test_dir/gh-calls" ||
    fail "reviews were not fully paginated"

ready_state="$test_dir/ready.state"
run_watch ready "$ready_state"
[[ "$(cat "$test_dir/stdout")" == "thelarklan/repo#1" ]] || fail "ready event was not reported"
run_watch ready "$ready_state"
[[ ! -s "$test_dir/stdout" ]] || fail "ready event was reported twice"

thread_state="$test_dir/thread.state"
run_watch thread "$thread_state"
[[ "$(cat "$test_dir/stdout")" == "thelarklan/repo#1" ]] || fail "unresolved direct reply was not reported"
run_watch thread "$thread_state"
[[ ! -s "$test_dir/stdout" ]] || fail "direct reply was reported twice"

run_watch resolved-thread "$test_dir/resolved.state"
[[ "$watch_status" -eq 0 && ! -s "$test_dir/stdout" ]] || fail "resolved thread was reported"

run_watch truncated-thread "$test_dir/truncated.state"
[[ "$watch_status" -ne 0 ]] || fail "truncated thread did not fail closed"
grep -Fq 'review thread exceeds 100 comments' "$test_dir/stderr" || fail "truncation failure was not explained"

command_state="$test_dir/command.state"
run_watch command "$command_state"
[[ "$(cat "$test_dir/stdout")" == "thelarklan/repo#1" ]] || fail "explicit review command was not reported"
run_watch command "$command_state"
[[ ! -s "$test_dir/stdout" ]] || fail "explicit review command was reported twice"

cap_state="$test_dir/cap.state"
GH_EVENT_ID=50 GH_EVENT_TIME=2026-08-26T10:03:00Z run_watch command "$cap_state"
GH_EVENT_ID=51 GH_EVENT_TIME=2026-08-26T10:04:00Z run_watch command "$cap_state"
GH_EVENT_ID=52 GH_EVENT_TIME=2026-08-26T10:05:00Z run_watch command "$cap_state"
[[ "$watch_status" -eq 0 ]] || fail "follow-up escalation failed"
[[ "$(cat "$test_dir/stdout")" == "thelarklan/repo#1" ]] || fail "escalation did not surface the PR"
grep -Fq 'pr-watch: ESCALATE:' "$test_dir/stderr" || fail "follow-up cap did not request escalation"
GH_EVENT_ID=52 GH_EVENT_TIME=2026-08-26T10:05:00Z run_watch command "$cap_state"
[[ ! -s "$test_dir/stdout" ]] || fail "escalation event was reported twice"

run_watch quiet "$test_dir/mismatch.state" PR_WATCH_REVIEWER=larkbot-gemini
[[ "$watch_status" -ne 0 ]] || fail "identity mismatch was accepted"
grep -Fq 'authenticated as larkbot-codex, expected larkbot-gemini' "$test_dir/stderr" ||
    fail "identity mismatch was not explained"

run_watch fail-search "$test_dir/failure.state"
[[ "$watch_status" -ne 0 ]] || fail "API failure returned success"
[[ ! -s "$test_dir/stdout" ]] || fail "API failure printed actionable work"
grep -Fq 'GitHub pull-request search failed' "$test_dir/stderr" || fail "API failure was silent"

run_watch ceiling "$test_dir/ceiling.state"
[[ "$watch_status" -ne 0 ]] || fail "search ceiling returned success"
grep -Fq "1000-result ceiling" "$test_dir/stderr" || fail "search truncation was silent"

printf 'pr-watch tests passed\n'
