#!/usr/bin/env bash
set -euo pipefail

project_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT

unset PR_REVIEW_PROVIDER PR_REVIEW_OWNER PR_REVIEW_REVIEWER PR_REVIEW_COHORT \
    PR_REVIEW_LABEL PR_REVIEW_MAX_FOLLOWUPS PR_REVIEW_MAX_FAILURES PR_REVIEW_TIMEOUT \
    PR_REVIEW_WORK_ROOT PR_REVIEW_PATH PR_REVIEW_GEMINI_DRIVER \
    PR_REVIEW_CODEX_MODEL PR_REVIEW_CODEX_EFFORT PR_REVIEW_CLAUDE_MODEL \
    PR_REVIEW_CLAUDE_EFFORT PR_REVIEW_ANTIGRAVITY_MODEL \
    PR_REVIEW_ANTIGRAVITY_EFFORT PR_REVIEW_CODEX_BIN PR_REVIEW_CLAUDE_BIN \
    PR_REVIEW_GEMINI_BIN PR_REVIEW_WATCH_BIN PR_REVIEW_PROVIDER_ENV_FILE \
    PR_REVIEW_ALERT_REPO PR_REVIEW_GIT_BASE_URL PR_REVIEW_SKILL_DIR \
    PR_REVIEW_CLEANUP_INTERVAL_SECONDS PR_WATCH_OWNER PR_WATCH_REVIEWER \
    PR_WATCH_COHORT PR_WATCH_LABEL PR_WATCH_MAX_FOLLOWUPS PR_WATCH_VERBOSE \
    PR_WATCH_STATE DEV_TOOLS_PR_WATCH_STATE XDG_STATE_HOME XDG_CACHE_HOME

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

# Create a local bare Git remote with main and PR head refs for offline worktree tests.
remotes_root="$test_dir/remotes"
seed_work="$test_dir/seed"
mkdir -p "$remotes_root/owner" "$seed_work"

create_remote_repo() {
    local repo_name="$1" pr_number="$2"
    local bare="$remotes_root/owner/${repo_name}.git"
    local work="$seed_work/${repo_name}"
    git init -q --bare "$bare"
    git init -q -b main "$work"
    git -C "$work" config user.email "test@example.com"
    git -C "$work" config user.name "Test User"
    printf 'base\n' >"$work/app.txt"
    git -C "$work" add app.txt
    git -C "$work" commit -q -m "base commit"
    git -C "$work" remote add origin "$bare"
    git -C "$work" push -q origin main
    git -C "$work" checkout -q -b "pr-$pr_number"
    printf 'first change in %s\n' "$repo_name" >>"$work/app.txt"
    git -C "$work" add app.txt
    git -C "$work" commit -q -m "first pr commit"
    git -C "$work" push -q origin "HEAD:refs/pull/$pr_number/head"
}

create_remote_repo repository 7
repo_base_sha=$(git -C "$remotes_root/owner/repository.git" rev-parse refs/heads/main)
repo_commit_a=$(git -C "$remotes_root/owner/repository.git" rev-parse refs/pull/7/head)

# Add a follow-up commit and an unrelated force-pushed commit on repository#7.
printf 'second change\n' >>"$seed_work/repository/app.txt"
git -C "$seed_work/repository" add app.txt
git -C "$seed_work/repository" commit -q -m "second pr commit"
repo_commit_b=$(git -C "$seed_work/repository" rev-parse HEAD)
git -C "$seed_work/repository" push -q origin "HEAD:refs/heads/pr-7-next"

git -C "$seed_work/repository" checkout -q -b pr-7-rebased main
printf 'rebased change\n' >>"$seed_work/repository/app.txt"
git -C "$seed_work/repository" add app.txt
git -C "$seed_work/repository" commit -q -m "rebased pr commit"
repo_commit_c=$(git -C "$seed_work/repository" rev-parse HEAD)
git -C "$seed_work/repository" push -q origin "HEAD:refs/heads/pr-7-rebased"

create_remote_repo claude 8
claude_base_sha=$(git -C "$remotes_root/owner/claude.git" rev-parse refs/heads/main)
claude_head=$(git -C "$remotes_root/owner/claude.git" rev-parse refs/pull/8/head)

create_remote_repo gemini 9
gemini_base_sha=$(git -C "$remotes_root/owner/gemini.git" rev-parse refs/heads/main)
gemini_head=$(git -C "$remotes_root/owner/gemini.git" rev-parse refs/pull/9/head)

create_remote_repo first 10
first_base_sha=$(git -C "$remotes_root/owner/first.git" rev-parse refs/heads/main)
first_head=$(git -C "$remotes_root/owner/first.git" rev-parse refs/pull/10/head)

create_remote_repo third 12
third_base_sha=$(git -C "$remotes_root/owner/third.git" rev-parse refs/heads/main)
third_head=$(git -C "$remotes_root/owner/third.git" rev-parse refs/pull/12/head)

create_remote_repo confirmation 10
confirm_base_sha=$(git -C "$remotes_root/owner/confirmation.git" rev-parse refs/heads/main)
confirm_head=$(git -C "$remotes_root/owner/confirmation.git" rev-parse refs/pull/10/head)

create_remote_repo another 8
another_base_sha=$(git -C "$remotes_root/owner/another.git" rev-parse refs/heads/main)
another_head=$(git -C "$remotes_root/owner/another.git" rev-parse refs/pull/8/head)

home_dir="$test_dir/home"
fake_bin="$home_dir/.local/bin"
mkdir -p "$fake_bin"

cat >"$fake_bin/pr-watch" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
state_target="${PR_WATCH_STATE:-$DEV_TOOLS_PR_WATCH_STATE}"
if [[ -n "${WATCH_ENV_CAPTURE:-}" ]]; then
    printf 'COHORT=%s\n' "${PR_WATCH_COHORT:-}" >"$WATCH_ENV_CAPTURE"
fi
if [[ "${PR_WATCH_RECORD_STATE:-1}" == "1" ]]; then
    printf '%s conversation head thread 42\n' "$PR_WATCH_ITEM" >>"$state_target"
fi
if [[ -n "${PR_WATCH_ITEM:-}" ]]; then
    printf '%s\n' "$PR_WATCH_ITEM"
fi
EOF
chmod +x "$fake_bin/pr-watch"

pr_meta_file="$test_dir/pr-meta.tsv"
cat >"$pr_meta_file" <<EOF
owner/repository#7	$repo_commit_a	main	$repo_base_sha	OPEN
owner/claude#8	$claude_head	main	$claude_base_sha	OPEN
owner/gemini#9	$gemini_head	main	$gemini_base_sha	OPEN
owner/first#10	$first_head	main	$first_base_sha	OPEN
owner/third#12	$third_head	main	$third_base_sha	OPEN
owner/confirmation#10	$confirm_head	main	$confirm_base_sha	OPEN
owner/another#8	$another_head	main	$another_base_sha	OPEN
EOF

cat >"$fake_bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$1" == "api" && "$2" == "user" ]]; then
    printf 'review-bot\n'
elif [[ "$1" == "api" && "$2" =~ ^/repos/([^/]+/[^/]+)/pulls/([0-9]+)$ ]]; then
    repo="${BASH_REMATCH[1]}"
    number="${BASH_REMATCH[2]}"
    if [[ "${PRE_PROVIDER_FAIL_NUMBER:-}" == "$number" ]]; then exit 8; fi
    row=$(awk -F'\t' -v key="$repo#$number" '$1 == key { print; exit }' "$PR_META_FILE")
    [[ -n "$row" ]] || exit 1
    IFS=$'\t' read -r _key head base_ref base_sha pr_state <<<"$row"
    printf '%s\n%s\n%s\nhttps://github.com/%s/pull/%s\n' "$head" "$base_ref" "$base_sha" "$repo" "$number"
elif [[ "$1" == "api" && "$*" == */reviews* ]]; then
    if [[ -n "${BEFORE_REVIEWS_TSV:-}" && ! -e "${REVIEW_SUBMITTED:-/nonexistent}" ]]; then
        printf '%s\n' "$BEFORE_REVIEWS_TSV"
    elif [[ -e "${REVIEW_SUBMITTED:-/nonexistent}" ]]; then
        if [[ -n "${BEFORE_REVIEWS_TSV:-}" ]]; then
            printf '%s\n' "$BEFORE_REVIEWS_TSV"
        fi
        confirm_sha="${CONFIRM_HEAD_SHA:-${ACTIVE_HEAD_SHA:-}}"
        if [[ -s "${REVIEW_SUBMITTED:-}" ]]; then
            confirm_sha=$(<"$REVIEW_SUBMITTED")
        fi
        printf '102\t%s\t2026-08-26T12:00:00Z\tAPPROVED\n' "$confirm_sha"
    fi
elif [[ "$1" == "api" && "$*" == */timeline* ]]; then
    if [[ -n "${TIMELINE_DISMISSED_TSV:-}" ]]; then
        printf '%s\n' "$TIMELINE_DISMISSED_TSV"
    fi
elif [[ "$1" == "pr" && "$2" == "view" ]]; then
    number="$3"
    repo=""
    json_fields=""
    shift 3
    while (($# > 0)); do
        case "$1" in
            --repo) repo="$2"; shift 2 ;;
            --json) json_fields="$2"; shift 2 ;;
            *) shift ;;
        esac
    done
    if [[ -n "${PRE_PROVIDER_FAIL_NUMBER:-}" && "$number" == "$PRE_PROVIDER_FAIL_NUMBER" ]]; then
        printf 'simulated pre-provider head failure\n' >&2
        exit 8
    fi
    if [[ -n "${HEAD_CALLS:-}" && "$json_fields" == "headRefOid" ]]; then
        head_calls=0
        [[ ! -e "$HEAD_CALLS" ]] || read -r head_calls <"$HEAD_CALLS"
        head_calls=$((head_calls + 1))
        printf '%s\n' "$head_calls" >"$HEAD_CALLS"
        if [[ "${POST_CONFIRM_FAIL:-0}" == "1" ]]; then
            printf 'simulated post-provider head failure\n' >&2
            exit 9
        fi
    fi
    row=$(awk -F'\t' -v key="$repo#$number" '$1 == key { print; exit }' "$PR_META_FILE")
    if [[ -z "$row" ]]; then
        printf 'unknown PR %s#%s\n' "$repo" "$number" >&2
        exit 1
    fi
    IFS=$'\t' read -r _key head base_ref base_sha pr_state <<<"$row"
    case "$json_fields" in
        headRefOid,baseRefName,baseRefOid,url)
            printf '%s\n%s\n%s\nhttps://github.com/%s/pull/%s\n' "$head" "$base_ref" "$base_sha" "$repo" "$number"
            ;;
        headRefOid)
            printf '%s\n' "$head"
            ;;
        state)
            printf '%s\n' "$pr_state"
            ;;
        *)
            printf 'unexpected pr view fields: %s\n' "$json_fields" >&2
            exit 1
            ;;
    esac
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
if [[ -n "${PROVIDER_CWD:-}" ]]; then
    pwd >"$PROVIDER_CWD"
fi
if [[ -n "${PROVIDER_HEAD_FILE:-}" ]]; then
    args=("$@")
    while (($#)); do
        if [[ "$1" == "--add-dir" ]]; then git -C "$2" rev-parse HEAD >"$PROVIDER_HEAD_FILE"; break; fi
        shift
    done
    set -- "${args[@]}"
fi
printf '%s\n' "$@" >"$PROVIDER_ARGS"
touch "$REVIEW_SUBMITTED"
printf 'submitted test review\n'
EOF
chmod +x "$fake_bin/codex"

# 1. First-pass review on Codex: prepares bare repo cache + detached worktree and inlines pr-code-review skill.
review_marker="$test_dir/review-submitted"
provider_args="$test_dir/provider-args"
provider_cwd="$test_dir/provider-cwd"
provider_head="$test_dir/provider-head"
watch_env="$test_dir/watch-env"

HOME="$home_dir" \
PATH="$fake_bin:/usr/local/bin:/usr/bin:/bin" \
PR_REVIEW_PROVIDER=codex \
PR_REVIEW_COHORT=larkbot-codex,larkbot-claude,larkbot-gemini \
PR_REVIEW_PATH="$fake_bin:$toolchain_bin:/usr/local/bin:/usr/bin:/bin" \
PR_REVIEW_WATCH_BIN="$fake_bin/pr-watch" \
PR_REVIEW_CODEX_BIN="$fake_bin/codex" \
PR_REVIEW_GIT_BASE_URL="file://$remotes_root" \
PR_REVIEW_CLEANUP_INTERVAL_SECONDS=3600 \
PR_REVIEW_TIMEOUT=5s \
PR_WATCH_ITEM=owner/repository#7 \
PR_META_FILE="$pr_meta_file" \
ACTIVE_HEAD_SHA="$repo_commit_a" \
WATCH_ENV_CAPTURE="$watch_env" \
REVIEW_SUBMITTED="$review_marker" \
PROVIDER_ARGS="$provider_args" \
PROVIDER_CWD="$provider_cwd" \
PROVIDER_HEAD_FILE="$provider_head" \
    "$project_dir/bin/pr-review-cron"

[[ -e "$review_marker" ]] || fail "provider was not invoked"
grep -Fqx 'COHORT=larkbot-codex,larkbot-claude,larkbot-gemini' "$watch_env" ||
    fail "PR_REVIEW_COHORT was not passed to pr-watch"
grep -Fqx 'owner/repository#7 conversation head thread 42' \
    "$home_dir/.local/state/pr-review/pr-watch.seen" || fail "confirmed watcher state was not committed"
grep -Fq "confirmed review 102 for owner/repository#7 at $repo_commit_a" \
    "$home_dir/.local/state/pr-review/cron.log" || fail "review was not confirmed in the log"

expected_worktree="$home_dir/.local/share/pr-review/work/prs/owner__repository__pr-7/repo"
expected_scratch="$home_dir/.local/share/pr-review/work/prs/owner__repository__pr-7/scratch"
[[ "$(cat "$provider_cwd")" == "$expected_scratch" ]] ||
    fail "provider did not run outside the PR worktree"
[[ "$(cat "$provider_head")" == "$repo_commit_a" ]] ||
    fail "worktree was not checked out at exact PR head"
assert_arg_pair "$provider_args" --add-dir "$expected_worktree" "Codex --add-dir did not include PR worktree"
assert_arg_pair "$provider_args" "$expected_worktree" -- "Codex prompt separator missing"
assert_arg_pair "$provider_args" --model gpt-6.2-sol "Codex model was not pinned to gpt-6.2-sol"
assert_arg_pair "$provider_args" --config 'model_reasoning_effort="high"' \
    "Codex reasoning effort was not pinned"
grep -Fq 'Review mode: first-pass' "$provider_args" || fail "first-pass mode missing"
grep -Fq '# Pull request code review' "$provider_args" || fail "pr-code-review SKILL.md was not inlined"
grep -Fq '# First-pass review' "$provider_args" || fail "FIRST-PASS.md branch was not inlined"
grep -Fq 'Perform a separate defect-seeking pass' "$provider_args" ||
    fail "review prompt does not require a defect-seeking pass"
grep -Fq 'tests could pass while documented behavior still fails' "$provider_args" ||
    fail "review prompt does not require test-gap analysis"
grep -Fq 'Do not manufacture nits' "$provider_args" ||
    fail "review prompt does not reject quota-driven findings"
grep -Fq 'not as the default outcome' "$provider_args" ||
    fail "review prompt does not set the approval threshold"
grep -Fq '## Blocking bar' "$provider_args" ||
    fail "review prompt does not define the blocking bar"
grep -Fq 'Non-blocking notes' "$provider_args" ||
    fail "review prompt does not put non-blocking findings in the approval"
grep -Fq 'however rare the trigger' "$provider_args" ||
    fail "review prompt lets rarity override security, data-loss, or required-check impact"
if grep -Fq '## Review rounds' "$provider_args"; then
    fail "first-pass prompt includes the delta-only review-round scope limit"
fi
if grep -Fqx 'name: pr-code-review' "$provider_args"; then
    fail "YAML frontmatter leaked into inlined review prompt"
fi

sed -i 's/^102/101/' "$(dirname "$expected_worktree")/review-baseline"

# 2. Delta re-review after push-dismissed APPROVED: cleans dirty worktree, advances to commit_b, passes delta range.
git -C "$remotes_root/owner/repository.git" update-ref refs/pull/7/head "$repo_commit_b"
sed -i "s|$repo_commit_a|$repo_commit_b|" "$pr_meta_file"
printf 'stale untracked file\n' >"$expected_worktree/leftover.tmp"
rm -- "$review_marker"

HOME="$home_dir" \
PATH="$fake_bin:/usr/local/bin:/usr/bin:/bin" \
PR_REVIEW_PROVIDER=codex \
PR_REVIEW_PATH="$fake_bin:$toolchain_bin:/usr/local/bin:/usr/bin:/bin" \
PR_REVIEW_WATCH_BIN="$fake_bin/pr-watch" \
PR_REVIEW_CODEX_BIN="$fake_bin/codex" \
PR_REVIEW_GIT_BASE_URL="file://$remotes_root" \
PR_REVIEW_TIMEOUT=5s \
PR_WATCH_ITEM=owner/repository#7 \
PR_WATCH_RECORD_STATE=0 \
PR_META_FILE="$pr_meta_file" \
ACTIVE_HEAD_SHA="$repo_commit_b" \
BEFORE_REVIEWS_TSV="$(printf '101\t%s\t2026-08-26T10:00:00Z\tDISMISSED' "$repo_commit_a")" \
TIMELINE_DISMISSED_TSV="$(printf 'approved\t%s' "$repo_commit_b")" \
REVIEW_SUBMITTED="$review_marker" \
PROVIDER_ARGS="$provider_args" \
PROVIDER_HEAD_FILE="$provider_head" \
    "$project_dir/bin/pr-review-cron"

[[ ! -e "$expected_worktree/leftover.tmp" ]] || fail "worktree was not cleaned before re-review"
[[ "$(cat "$provider_head")" == "$repo_commit_b" ]] || fail "worktree did not advance to commit_b"
grep -Fq 'Review mode: delta-re-review' "$provider_args" || fail "matching baseline did not enter delta review"
grep -Fq '# Delta re-review' "$provider_args" || fail "DELTA-REVIEW.md branch was not inlined"
grep -Fq "Primary diff range: $repo_commit_a..$repo_commit_b" "$provider_args" ||
    fail "delta diff range was not passed"
grep -Fq 'state=APPROVED (dismissed on push)' "$provider_args" ||
    fail "prior push-dismissed approval context was missing"
grep -Fq 'Earlier change requests by review-bot on this pull request: 0' "$provider_args" ||
    fail "change-request count was not zero without earlier change requests"
grep -Fq 'A concern is resolved when the fix handles the reported case' "$provider_args" ||
    fail "delta review does not limit prior concerns to the reported case"
grep -Fq 'Report rare or contrived cases in the fix as non-blocking notes, unless they have a security' "$provider_args" ||
    fail "delta review does not make contrived cases non-blocking"
grep -Fq '## Review rounds' "$provider_args" ||
    fail "delta review does not include the review-round scope limit"

# The prompt counts distinct head commits where this reviewer requested changes.
rm -- "$review_marker"
change_request_rows=$(printf '%s\n' \
    "$(printf '98\t%s\t2026-08-26T08:00:00Z\tCHANGES_REQUESTED' "$repo_commit_c")" \
    "$(printf '99\t%s\t2026-08-26T09:00:00Z\tCHANGES_REQUESTED' "$repo_commit_a")" \
    "$(printf '100\t%s\t2026-08-26T09:30:00Z\tCHANGES_REQUESTED' "$repo_commit_a")" \
    "$(printf '101\t%s\t2026-08-26T10:00:00Z\tCOMMENTED' "$repo_commit_a")")
HOME="$home_dir" \
PATH="$fake_bin:/usr/local/bin:/usr/bin:/bin" \
PR_REVIEW_PROVIDER=codex \
PR_REVIEW_PATH="$fake_bin:$toolchain_bin:/usr/local/bin:/usr/bin:/bin" \
PR_REVIEW_WATCH_BIN="$fake_bin/pr-watch" \
PR_REVIEW_CODEX_BIN="$fake_bin/codex" \
PR_REVIEW_GIT_BASE_URL="file://$remotes_root" \
PR_REVIEW_TIMEOUT=5s \
PR_WATCH_ITEM=owner/repository#7 \
PR_WATCH_RECORD_STATE=0 \
PR_META_FILE="$pr_meta_file" \
ACTIVE_HEAD_SHA="$repo_commit_b" \
BEFORE_REVIEWS_TSV="$change_request_rows" \
REVIEW_SUBMITTED="$review_marker" \
PROVIDER_ARGS="$provider_args" \
PROVIDER_HEAD_FILE="$provider_head" \
    "$project_dir/bin/pr-review-cron"
grep -Fq 'Earlier change requests by review-bot on this pull request: 2' "$provider_args" ||
    fail "change-request count did not count distinct head commits"

# A comment is not evidence of a completed review.
rm -- "$review_marker"
HOME="$home_dir" \
PATH="$fake_bin:/usr/local/bin:/usr/bin:/bin" \
PR_REVIEW_PROVIDER=codex \
PR_REVIEW_PATH="$fake_bin:$toolchain_bin:/usr/local/bin:/usr/bin:/bin" \
PR_REVIEW_WATCH_BIN="$fake_bin/pr-watch" \
PR_REVIEW_CODEX_BIN="$fake_bin/codex" \
PR_REVIEW_GIT_BASE_URL="file://$remotes_root" \
PR_REVIEW_TIMEOUT=5s \
PR_WATCH_ITEM=owner/repository#7 \
PR_WATCH_RECORD_STATE=0 \
PR_META_FILE="$pr_meta_file" \
ACTIVE_HEAD_SHA="$repo_commit_b" \
BEFORE_REVIEWS_TSV="$(printf '101\t%s\t2026-08-26T10:00:00Z\tCOMMENTED' "$repo_commit_a")" \
TIMELINE_DISMISSED_TSV="$(printf 'approved\t%s' "$repo_commit_b")" \
REVIEW_SUBMITTED="$review_marker" \
PROVIDER_ARGS="$provider_args" \
PROVIDER_HEAD_FILE="$provider_head" \
    "$project_dir/bin/pr-review-cron"
grep -Fq 'Review mode: first-pass' "$provider_args" || fail "comment-only baseline entered delta mode"

# A changed base invalidates the recorded review baseline.
printf '101\tother-base\t%s\n' "$(git -C "$expected_worktree" merge-base refs/pr-review/bases/7 "$repo_commit_b")" >"$(dirname "$expected_worktree")/review-baseline"
rm -- "$review_marker"
HOME="$home_dir" \
PATH="$fake_bin:/usr/local/bin:/usr/bin:/bin" \
PR_REVIEW_PROVIDER=codex \
PR_REVIEW_PATH="$fake_bin:$toolchain_bin:/usr/local/bin:/usr/bin:/bin" \
PR_REVIEW_WATCH_BIN="$fake_bin/pr-watch" \
PR_REVIEW_CODEX_BIN="$fake_bin/codex" \
PR_REVIEW_GIT_BASE_URL="file://$remotes_root" \
PR_REVIEW_TIMEOUT=5s \
PR_WATCH_ITEM=owner/repository#7 \
PR_WATCH_RECORD_STATE=0 \
PR_META_FILE="$pr_meta_file" \
ACTIVE_HEAD_SHA="$repo_commit_b" \
BEFORE_REVIEWS_TSV="$(printf '101\t%s\t2026-08-26T10:00:00Z\tAPPROVED' "$repo_commit_a")" \
TIMELINE_DISMISSED_TSV="$(printf 'approved\t%s' "$repo_commit_b")" \
REVIEW_SUBMITTED="$review_marker" \
PROVIDER_ARGS="$provider_args" \
PROVIDER_HEAD_FILE="$provider_head" \
    "$project_dir/bin/pr-review-cron"
grep -Fq 'Review mode: first-pass' "$provider_args" || fail "changed base entered delta mode"

sed -i 's/^102/101/' "$(dirname "$expected_worktree")/review-baseline"

# 3. Rebased (force-pushed) PR falls back to rebased-re-review + FIRST-PASS.md.
git -C "$remotes_root/owner/repository.git" update-ref refs/pull/7/head "$repo_commit_c"
sed -i "s|$repo_commit_b|$repo_commit_c|" "$pr_meta_file"
rm -- "$review_marker"

HOME="$home_dir" \
PATH="$fake_bin:/usr/local/bin:/usr/bin:/bin" \
PR_REVIEW_PROVIDER=codex \
PR_REVIEW_PATH="$fake_bin:$toolchain_bin:/usr/local/bin:/usr/bin:/bin" \
PR_REVIEW_WATCH_BIN="$fake_bin/pr-watch" \
PR_REVIEW_CODEX_BIN="$fake_bin/codex" \
PR_REVIEW_GIT_BASE_URL="file://$remotes_root" \
PR_REVIEW_TIMEOUT=5s \
PR_WATCH_ITEM=owner/repository#7 \
PR_WATCH_RECORD_STATE=0 \
PR_META_FILE="$pr_meta_file" \
ACTIVE_HEAD_SHA="$repo_commit_c" \
BEFORE_REVIEWS_TSV="$(printf '101\t%s\t2026-08-26T11:00:00Z\tAPPROVED' "$repo_commit_b")" \
REVIEW_SUBMITTED="$review_marker" \
PROVIDER_ARGS="$provider_args" \
    "$project_dir/bin/pr-review-cron"

grep -Fq 'Review mode: rebased-re-review' "$provider_args" || fail "force-pushed PR did not fall back to rebased-re-review"
grep -Fq '# First-pass review' "$provider_args" || fail "rebased-re-review did not inline FIRST-PASS.md"

# 3b. A base branch renamed to a nested name still prepares the worktree.
# Simulate a stale ref from an older cache that blocks refs/remotes/origin/main/v2.
bare_cache="$home_dir/.local/share/pr-review/work/repos/owner/repository.git"
git -C "$bare_cache" update-ref refs/remotes/origin/main "$repo_base_sha"
git -C "$remotes_root/owner/repository.git" update-ref -d refs/heads/main
git -C "$remotes_root/owner/repository.git" update-ref refs/heads/main/v2 "$repo_base_sha"
sed -i 's|^\(owner/repository#7\t[^\t]*\t\)main\t|\1main/v2\t|' "$pr_meta_file"
rm -- "$review_marker"

HOME="$home_dir" \
PATH="$fake_bin:/usr/local/bin:/usr/bin:/bin" \
PR_REVIEW_PROVIDER=codex \
PR_REVIEW_PATH="$fake_bin:$toolchain_bin:/usr/local/bin:/usr/bin:/bin" \
PR_REVIEW_WATCH_BIN="$fake_bin/pr-watch" \
PR_REVIEW_CODEX_BIN="$fake_bin/codex" \
PR_REVIEW_GIT_BASE_URL="file://$remotes_root" \
PR_REVIEW_TIMEOUT=5s \
PR_WATCH_ITEM=owner/repository#7 \
PR_WATCH_RECORD_STATE=0 \
PR_META_FILE="$pr_meta_file" \
ACTIVE_HEAD_SHA="$repo_commit_c" \
BEFORE_REVIEWS_TSV="$(printf '101\t%s\t2026-08-26T11:00:00Z\tAPPROVED' "$repo_commit_b")" \
REVIEW_SUBMITTED="$review_marker" \
PROVIDER_ARGS="$provider_args" \
    "$project_dir/bin/pr-review-cron"

[[ -e "$review_marker" ]] || fail "renamed nested base branch blocked the review"
[[ "$(git -C "$bare_cache" rev-parse refs/pr-review/bases/7)" == "$repo_base_sha" ]] ||
    fail "base was not fetched into the per-PR base ref"

git -C "$remotes_root/owner/repository.git" update-ref -d refs/heads/main/v2
git -C "$remotes_root/owner/repository.git" update-ref refs/heads/main "$repo_base_sha"
sed -i 's|^\(owner/repository#7\t[^\t]*\t\)main/v2\t|\1main\t|' "$pr_meta_file"

# 4. Head moved during fetch aborts before starting provider.
git -C "$remotes_root/owner/repository.git" update-ref refs/pull/7/head "$repo_commit_a"
rm -- "$review_marker"
moved_calls="$test_dir/moved-calls"
if HOME="$home_dir" \
    PATH="$fake_bin:/usr/local/bin:/usr/bin:/bin" \
    PR_REVIEW_PROVIDER=codex \
    PR_REVIEW_PATH="$fake_bin:$toolchain_bin:/usr/local/bin:/usr/bin:/bin" \
    PR_REVIEW_WATCH_BIN="$fake_bin/pr-watch" \
    PR_REVIEW_CODEX_BIN="$fake_bin/codex" \
    PR_REVIEW_GIT_BASE_URL="file://$remotes_root" \
    PR_REVIEW_TIMEOUT=5s \
    PR_WATCH_ITEM=owner/repository#7 \
    PR_WATCH_RECORD_STATE=0 \
    PR_META_FILE="$pr_meta_file" \
    ACTIVE_HEAD_SHA="$repo_commit_c" \
    REVIEW_SUBMITTED="$review_marker" \
    PROVIDER_ARGS="$provider_args" \
    PROVIDER_CALLS="$moved_calls" \
        "$project_dir/bin/pr-review-cron"; then
    fail "head-moved-during-fetch run succeeded"
fi
[[ ! -e "$moved_calls" ]] || fail "provider ran despite head moving during fetch"
grep -Fq 'head moved during fetch' "$home_dir/.local/state/pr-review/cron.log" ||
    fail "head-moved mismatch was not logged"

# Restore PR#7 ref to commit_c for cleanup test later.
git -C "$remotes_root/owner/repository.git" update-ref refs/pull/7/head "$repo_commit_c"

# 5. Claude provider + secret provider.env + --add-dir.
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
grep -Fq 'provider env permissions are too broad' "$test_dir/broad-env-error" ||
    fail "broad provider env permissions were not diagnosed"

secret_env="$test_dir/provider.env"
printf 'CLAUDE_CODE_OAUTH_TOKEN=secret-oauth-value\n' >"$secret_env"
chmod 600 "$secret_env"
token_capture="$test_dir/token-capture"

HOME="$home_dir" \
PATH="$fake_bin:/usr/local/bin:/usr/bin:/bin" \
PR_REVIEW_PROVIDER=claude \
PR_REVIEW_WATCH_BIN="$fake_bin/pr-watch" \
PR_REVIEW_PROVIDER_ENV_FILE="$secret_env" \
PR_REVIEW_CLAUDE_BIN="$fake_bin/claude" \
PR_REVIEW_GIT_BASE_URL="file://$remotes_root" \
PR_REVIEW_TIMEOUT=5s \
PR_WATCH_ITEM=owner/claude#8 \
PR_META_FILE="$pr_meta_file" \
ACTIVE_HEAD_SHA="$claude_head" \
REVIEW_SUBMITTED="$review_marker" \
PROVIDER_ARGS="$provider_args" \
TOKEN_CAPTURE="$token_capture" \
    "$project_dir/bin/pr-review-cron"
assert_arg_pair "$provider_args" --model claude-opus-5-5 "Claude model was not pinned to claude-opus-5-5"
assert_arg_pair "$provider_args" --effort high "Claude effort was not pinned"
assert_arg_pair "$provider_args" --add-dir \
    "$home_dir/.local/share/pr-review/work/prs/owner__claude__pr-8/repo" \
    "Claude --add-dir did not include PR worktree"
assert_arg_pair "$provider_args" "$home_dir/.local/share/pr-review/work/prs/owner__claude__pr-8/repo" -- "Claude prompt separator missing"
[[ "$(cat "$token_capture")" == "secret-oauth-value" ]] ||
    fail "provider env file did not supply CLAUDE_CODE_OAUTH_TOKEN"
if grep -Fq 'secret-oauth-value' "$home_dir/.local/state/pr-review/cron.log"; then
    fail "provider env secret leaked into cron.log"
fi

# 6. Antigravity (agy) provider default and explicit effort + --add-dir.
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
PR_REVIEW_GIT_BASE_URL="file://$remotes_root" \
PR_REVIEW_TIMEOUT=5s \
PR_WATCH_ITEM=owner/gemini#9 \
PR_META_FILE="$pr_meta_file" \
ACTIVE_HEAD_SHA="$gemini_head" \
REVIEW_SUBMITTED="$review_marker" \
PROVIDER_ARGS="$provider_args" \
    "$project_dir/bin/pr-review-cron"
assert_arg_pair "$provider_args" --model gemini-4-neon-high \
    "Antigravity model did not default to gemini-4-neon-high"
assert_no_arg "$provider_args" --effort \
    "Antigravity passed --effort when PR_REVIEW_ANTIGRAVITY_EFFORT was empty"
assert_no_arg "$provider_args" --add-dir \
    "Antigravity must not load PR workspace customizations"

rm -- "$review_marker"
HOME="$home_dir" \
PATH="$fake_bin:/usr/local/bin:/usr/bin:/bin" \
PR_REVIEW_PROVIDER=gemini \
PR_REVIEW_GEMINI_DRIVER=agy \
PR_REVIEW_ANTIGRAVITY_EFFORT=high \
PR_REVIEW_WATCH_BIN="$fake_bin/pr-watch" \
PR_REVIEW_GEMINI_BIN="$fake_bin/agy" \
PR_REVIEW_GIT_BASE_URL="file://$remotes_root" \
PR_REVIEW_TIMEOUT=5s \
PR_WATCH_ITEM=owner/gemini#9 \
PR_META_FILE="$pr_meta_file" \
ACTIVE_HEAD_SHA="$gemini_head" \
REVIEW_SUBMITTED="$review_marker" \
PROVIDER_ARGS="$provider_args" \
    "$project_dir/bin/pr-review-cron"
assert_arg_pair "$provider_args" --effort high \
    "Antigravity did not pass explicit PR_REVIEW_ANTIGRAVITY_EFFORT"

# 7. Cleanup removes MERGED/CLOSED PR workspaces while keeping OPEN workspaces and bare repos.
sed -i 's|^owner/repository#7\(.*\)OPEN$|owner/repository#7\1MERGED|' "$pr_meta_file"
sed -i 's|^owner/claude#8\(.*\)OPEN$|owner/claude#8\1CLOSED|' "$pr_meta_file"
HOME="$home_dir" \
PATH="$fake_bin:/usr/local/bin:/usr/bin:/bin" \
PR_REVIEW_PROVIDER=codex \
PR_REVIEW_WATCH_BIN="$fake_bin/pr-watch" \
PR_REVIEW_CODEX_BIN="$fake_bin/codex" \
PR_REVIEW_GIT_BASE_URL="file://$remotes_root" \
PR_REVIEW_CLEANUP_INTERVAL_SECONDS=0 \
PR_WATCH_ITEM='' \
PR_WATCH_RECORD_STATE=0 \
PR_META_FILE="$pr_meta_file" \
    "$project_dir/bin/pr-review-cron"

[[ ! -e "$home_dir/.local/share/pr-review/work/prs/owner__repository__pr-7" ]] ||
    fail "MERGED PR workspace was not cleaned up"
[[ ! -e "$home_dir/.local/share/pr-review/work/prs/owner__claude__pr-8" ]] ||
    fail "CLOSED PR workspace was not cleaned up"
[[ -d "$home_dir/.local/share/pr-review/work/prs/owner__gemini__pr-9/repo" ]] ||
    fail "OPEN PR workspace was wrongly removed"
[[ -d "$home_dir/.local/share/pr-review/work/repos/owner/repository.git" ]] ||
    fail "bare repo cache was wrongly removed during PR cleanup"
grep -Fq 'cleaned up MERGED PR workspace owner/repository#7' \
    "$home_dir/.local/state/pr-review/cron.log" || fail "cleanup action was not logged"
! git -C "$home_dir/.local/share/pr-review/work/repos/owner/repository.git" \
    rev-parse -q --verify refs/pr-review/bases/7 >/dev/null ||
    fail "cleanup did not remove the per-PR base ref"

# 8. Batch continues past preparation query failure.
rm -- "$review_marker"
batch_calls="$test_dir/batch-provider-calls"
batch_items=$'owner/first#10\nowner/fail#11\nowner/third#12'
# Confirmation head varies per item; confirm using git rev-parse inside the fake codex via a shared file.
cat >"$fake_bin/codex" <<'EOF'
#!/usr/bin/env test-shell
set -euo pipefail
if [[ -n "${PROVIDER_CALLS:-}" ]]; then
    call_count=0
    [[ ! -e "$PROVIDER_CALLS" ]] || read -r call_count <"$PROVIDER_CALLS"
    printf '%s\n' "$((call_count + 1))" >"$PROVIDER_CALLS"
fi
printf '%s\n' "$@" >"$PROVIDER_ARGS"
while (($#)); do
    if [[ "$1" == "--add-dir" ]]; then git -C "$2" rev-parse HEAD >"$REVIEW_SUBMITTED"; break; fi
    shift
done
printf 'submitted test review\n'
EOF
chmod +x "$fake_bin/codex"

if HOME="$home_dir" \
    PATH="$fake_bin:$toolchain_bin:/usr/local/bin:/usr/bin:/bin" \
    PR_REVIEW_PROVIDER=codex \
    PR_REVIEW_WATCH_BIN="$fake_bin/pr-watch" \
    PR_REVIEW_CODEX_BIN="$fake_bin/codex" \
    PR_REVIEW_GIT_BASE_URL="file://$remotes_root" \
    PR_REVIEW_TIMEOUT=5s \
    PR_WATCH_ITEM="$batch_items" \
    PR_WATCH_RECORD_STATE=0 \
    PRE_PROVIDER_FAIL_NUMBER=11 \
    PR_META_FILE="$pr_meta_file" \
    REVIEW_SUBMITTED="$review_marker" \
    PROVIDER_ARGS="$provider_args" \
    PROVIDER_CALLS="$batch_calls" \
        "$project_dir/bin/pr-review-cron"; then
    fail "batch with a failed preparation query succeeded"
fi
[[ "$(cat "$batch_calls")" == "2" ]] ||
    fail "a preparation query failure truncated the remaining work batch"
grep -Fq 'preparation query failed for owner/fail#11' \
    "$home_dir/.local/state/pr-review/cron.log" ||
    fail "pre-provider query failure did not name the skipped item"
grep -Fq 'reviewing owner/third#12' "$home_dir/.local/state/pr-review/cron.log" ||
    fail "work after a preparation query failure was not attempted"

# 9. Post-provider confirmation failure is diagnosed.
rm -- "$review_marker"
head_calls="$test_dir/head-calls"
if HOME="$home_dir" \
    PATH="$fake_bin:$toolchain_bin:/usr/local/bin:/usr/bin:/bin" \
    PR_REVIEW_PROVIDER=codex \
    PR_REVIEW_WATCH_BIN="$fake_bin/pr-watch" \
    PR_REVIEW_CODEX_BIN="$fake_bin/codex" \
    PR_REVIEW_GIT_BASE_URL="file://$remotes_root" \
    PR_REVIEW_TIMEOUT=5s \
    PR_WATCH_ITEM=owner/confirmation#10 \
    PR_META_FILE="$pr_meta_file" \
    REVIEW_SUBMITTED="$review_marker" \
    PROVIDER_ARGS="$provider_args" \
    HEAD_CALLS="$head_calls" \
    POST_CONFIRM_FAIL=1 \
        "$project_dir/bin/pr-review-cron"; then
    fail "post-provider confirmation failure succeeded"
fi
grep -Fq 'confirmation query failed for owner/confirmation#10' \
    "$home_dir/.local/state/pr-review/cron.log" ||
    fail "post-provider confirmation failure aborted without a diagnostic"

# 10. Auth failure + bounded retries + escalation + clean recovery health alert lifecycle.
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
        PR_REVIEW_GIT_BASE_URL="file://$remotes_root" \
        PR_REVIEW_MAX_FAILURES=2 \
        PR_REVIEW_ALERT_REPO=owner/pr-review \
        ALERT_LOG="$alert_log" \
        OPEN_ALERT_ISSUE_FILE="$open_alert_file" \
        PR_REVIEW_TIMEOUT=5s \
        PR_WATCH_ITEM=owner/another#8 \
        PR_WATCH_RECORD_STATE=0 \
        PR_META_FILE="$pr_meta_file" \
        REVIEW_SUBMITTED="$review_marker" \
        PROVIDER_CALLS="$failure_calls" \
            "$project_dir/bin/pr-review-cron"; then
        fail "unconfirmed provider run $attempt succeeded"
    fi
done
[[ "$(grep -Fc 'create:' "$alert_log")" == 1 ]] ||
    fail "auth failure did not create exactly one health alert issue"
[[ "$(grep -Fc 'comment:' "$alert_log")" == 1 ]] ||
    fail "escalation change did not update the existing health alert issue"

HOME="$home_dir" \
PATH="$fake_bin:/usr/local/bin:/usr/bin:/bin" \
PR_REVIEW_PROVIDER=codex \
PR_REVIEW_WATCH_BIN="$fake_bin/pr-watch" \
PR_REVIEW_CODEX_BIN="$fake_bin/codex" \
PR_REVIEW_GIT_BASE_URL="file://$remotes_root" \
PR_REVIEW_MAX_FAILURES=2 \
PR_REVIEW_ALERT_REPO=owner/pr-review \
ALERT_LOG="$alert_log" \
OPEN_ALERT_ISSUE_FILE="$open_alert_file" \
PR_REVIEW_TIMEOUT=5s \
PR_WATCH_ITEM=owner/another#8 \
PR_WATCH_RECORD_STATE=0 \
PR_META_FILE="$pr_meta_file" \
REVIEW_SUBMITTED="$review_marker" \
PROVIDER_CALLS="$failure_calls" \
    "$project_dir/bin/pr-review-cron"
[[ "$(cat "$failure_calls")" == "2" ]] || fail "provider retries were not bounded"
[[ "$(grep -Fc 'close:' "$alert_log")" == 0 ]] ||
    fail "health alert issue closed while paused PRs remained"
grep -Fq 'ESCALATE: owner/another#8 failed 2 consecutive attempt(s)' \
    "$home_dir/.local/state/pr-review/cron.log" || fail "provider failures did not escalate"
grep -Fq "owner/another#8 at $another_head remains paused after 2 unconfirmed attempt(s)" \
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
PR_REVIEW_GIT_BASE_URL="file://$remotes_root" \
PR_REVIEW_ALERT_REPO=owner/pr-review \
ALERT_LOG="$alert_log" \
OPEN_ALERT_ISSUE_FILE="$open_alert_file" \
PR_REVIEW_TIMEOUT=5s \
PR_WATCH_ITEM='' \
PR_WATCH_RECORD_STATE=0 \
PR_META_FILE="$pr_meta_file" \
REVIEW_SUBMITTED="$review_marker" \
    "$project_dir/bin/pr-review-cron"
[[ "$(grep -Fc 'close:' "$alert_log")" == 1 ]] ||
    fail "clean recovery run did not close the open health alert issue"
[[ ! -e "$home_dir/.local/state/pr-review/last-alert-key" ]] ||
    fail "last-alert-key remained after closing the health alert issue"

# 11. Config and missing-skill validation fail closed.
if HOME="$home_dir" PR_REVIEW_PROVIDER=codex PR_REVIEW_SKILL_DIR="$test_dir/missing-skill" \
    PR_REVIEW_WATCH_BIN="$fake_bin/pr-watch" "$project_dir/bin/pr-review-cron" 2>/dev/null; then
    fail "missing review skill directory was accepted"
fi

if HOME="$home_dir" PR_REVIEW_PROVIDER=codex PR_REVIEW_PATH=CHANGE_ME \
    "$project_dir/bin/pr-review-cron" 2>/dev/null; then
    fail "provider PATH placeholder was accepted"
fi

if HOME="$home_dir" PR_REVIEW_PROVIDER=unknown "$project_dir/bin/pr-review-cron" 2>/dev/null; then
    fail "unknown provider succeeded"
fi

printf 'pull request review cron tests passed\n'
