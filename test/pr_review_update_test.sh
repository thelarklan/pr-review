#!/usr/bin/env bash
set -euo pipefail

project_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT

unset PR_REVIEW_UPDATE_UPSTREAM PR_REVIEW_UPDATE_REMOTE PR_REVIEW_UPDATE_BRANCH \
    PR_REVIEW_UPDATE_SOURCE PR_REVIEW_ROLE PR_REVIEW_UPDATE_LOCK \
    PR_REVIEW_UPDATE_LOG PR_REVIEW_UPDATE_DEPLOYED_STATE PR_REVIEW_UPDATE_LOCK_WAIT \
    XDG_STATE_HOME XDG_CACHE_HOME UPDATE_TRACE UPDATE_VERIFY_FAIL

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

home_dir="$test_dir/home"
state_dir="$test_dir/state"
cache_dir="$test_dir/cache"
source_dir="$test_dir/source"
upstream_work="$test_dir/upstream-work"
upstream_repo="$test_dir/upstream.git"
trace_file="$test_dir/trace"
verify_fail="$test_dir/verify-fail"
mkdir -p "$home_dir" "$upstream_work/scripts" "$upstream_work/bin"

cp "$project_dir/bin/pr-review-update" "$upstream_work/bin/pr-review-update"
cat >"$upstream_work/scripts/verify.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ ! -e "$UPDATE_VERIFY_FAIL" ]] || exit 42
printf 'verify\n' >>"$UPDATE_TRACE"
EOF
cat >"$upstream_work/install.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'install:%s\n' "$*" >>"$UPDATE_TRACE"
EOF
chmod 0755 "$upstream_work/scripts/verify.sh" "$upstream_work/install.sh" \
    "$upstream_work/bin/pr-review-update"

git -C "$upstream_work" init --initial-branch=main >/dev/null
git -C "$upstream_work" config user.name updater-test
git -C "$upstream_work" config user.email updater-test@example.com
git -C "$upstream_work" add .
git -C "$upstream_work" commit -m initial >/dev/null
initial_commit=$(git -C "$upstream_work" rev-parse HEAD)
git clone --bare "$upstream_work" "$upstream_repo" >/dev/null
git -C "$upstream_work" remote add publish "$upstream_repo"

lock_wait_seconds=10

run_update() {
    PR_REVIEW_UPDATE_LOCK_WAIT="$lock_wait_seconds" \
    HOME="$home_dir" \
    XDG_STATE_HOME="$state_dir" \
    XDG_CACHE_HOME="$cache_dir" \
    PR_REVIEW_ROLE=codex \
    PR_REVIEW_UPDATE_SOURCE="$source_dir" \
    PR_REVIEW_UPDATE_UPSTREAM="$upstream_repo" \
    PR_REVIEW_UPDATE_BRANCH=main \
    UPDATE_TRACE="$trace_file" \
    UPDATE_VERIFY_FAIL="$verify_fail" \
        "$project_dir/bin/pr-review-update"
}

run_update
[[ "$(git -C "$source_dir" rev-parse HEAD)" == "$initial_commit" ]] || \
    fail "initial clone did not select canonical main"
[[ "$(cat "$state_dir/pr-review-update/deployed")" == "$initial_commit" ]] || \
    fail "deployed state did not record the verified commit"
[[ "$(grep -Fc verify "$trace_file")" == 1 ]] || fail "verification did not run"
[[ "$(grep -Fc 'install:--role codex' "$trace_file")" == 1 ]] || fail "role installer did not run"

run_update
[[ "$(grep -Fc verify "$trace_file")" == 1 ]] || fail "already-deployed commit ran redundant verification"
grep -Fq "already at verified commit $initial_commit" "$state_dir/pr-review-update/cron.log" || \
    fail "already-deployed skip was not logged"

lock_file="$cache_dir/pr-review/cron.lock"
exec 9>"$lock_file"
flock -n 9 || fail "test could not acquire the shared lock"
lock_wait_seconds=0
run_update
lock_wait_seconds=10
flock -u 9
exec 9>&-
[[ "$(grep -Fc verify "$trace_file")" == 1 ]] || fail "busy updater ran verification"

# A review that holds the lock for a short time must delay the update, not skip it.
(
    exec 9>"$lock_file"
    flock -n 9 || exit 1
    sleep 2
) &
holder_pid=$!
sleep 0.5
already_count=$(grep -Fc "already at verified commit" "$state_dir/pr-review-update/cron.log")
run_update
wait "$holder_pid" || fail "test lock holder could not acquire the shared lock"
[[ "$(grep -Fc "already at verified commit" "$state_dir/pr-review-update/cron.log")" == $((already_count + 1)) ]] || \
    fail "updater skipped instead of waiting for the shared lock"

printf 'dirty\n' >"$source_dir/local-change"
if run_update; then
    fail "dirty source checkout was accepted"
fi
rm -- "$source_dir/local-change"

git -C "$source_dir" remote set-url origin "$test_dir/wrong.git"
if run_update; then
    fail "wrong origin remote was accepted"
fi
git -C "$source_dir" remote set-url origin "$upstream_repo"

printf 'next\n' >"$upstream_work/release.txt"
git -C "$upstream_work" add release.txt
git -C "$upstream_work" commit -m next >/dev/null
next_commit=$(git -C "$upstream_work" rev-parse HEAD)
git -C "$upstream_work" push publish main >/dev/null

touch "$verify_fail"
if run_update; then
    fail "failed verification was accepted"
fi
rm -- "$verify_fail"
[[ "$(git -C "$source_dir" rev-parse HEAD)" == "$initial_commit" ]] || \
    fail "failed verification moved the live source checkout"
[[ "$(grep -Fc 'install:--role codex' "$trace_file")" == 1 ]] || \
    fail "installation ran after failed verification"
[[ "$(cat "$state_dir/pr-review-update/deployed")" == "$initial_commit" ]] || \
    fail "failed verification changed deployed state"

run_update
[[ "$(git -C "$source_dir" rev-parse HEAD)" == "$next_commit" ]] || \
    fail "source checkout did not fast-forward"
[[ "$(cat "$state_dir/pr-review-update/deployed")" == "$next_commit" ]] || \
    fail "fast-forwarded commit was not recorded"
[[ "$(grep -Fc 'install:--role codex' "$trace_file")" == 2 ]] || \
    fail "verified fast-forward did not run role install"

empty_tree=$(git -C "$upstream_work" mktree </dev/null)
rewritten_commit=$(printf 'rewritten history\n' | git -C "$upstream_work" commit-tree "$empty_tree")
git -C "$upstream_work" push --force publish \
    "$rewritten_commit:refs/heads/main" >/dev/null
if run_update; then
    fail "non-fast-forward canonical history was accepted"
fi
[[ "$(git -C "$source_dir" rev-parse HEAD)" == "$next_commit" ]] || \
    fail "non-fast-forward attempt changed the source checkout"
[[ "$(grep -Fc 'install:--role codex' "$trace_file")" == 2 ]] || \
    fail "non-fast-forward attempt ran installation"

grep -Fq 'shared lock is busy after 0s; update skipped' \
    "$state_dir/pr-review-update/cron.log" || fail "busy update was not logged"
grep -Fq 'source checkout has local changes' \
    "$state_dir/pr-review-update/cron.log" || fail "dirty checkout refusal was not logged"
grep -Fq 'is not a fast-forward' \
    "$state_dir/pr-review-update/cron.log" || fail "history rewrite refusal was not logged"

printf 'pr-review-update tests passed\n'
