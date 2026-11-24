#!/usr/bin/env bash
# Crontab text keeps $HOME literal, as install.sh writes it.
# shellcheck disable=SC2016
set -euo pipefail

project_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
test_dir=$(mktemp -d)
review_pid=""
cleanup() {
    if [[ -n "$review_pid" ]]; then
        pkill -P "$review_pid" 2>/dev/null || true
        kill "$review_pid" 2>/dev/null || true
    fi
    rm -rf -- "$test_dir"
}
trap cleanup EXIT

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

assert_contains() {
    local haystack="$1" needle="$2" message="$3"
    if [[ "$haystack" != *"$needle"* ]]; then
        printf '%s\n' "$haystack" >&2
        fail "$message"
    fi
}

assert_not_contains() {
    local haystack="$1" needle="$2" message="$3"
    if [[ "$haystack" == *"$needle"* ]]; then
        printf '%s\n' "$haystack" >&2
        fail "$message"
    fi
}

# Fail when the output has a check row with this name, such as "OK   runner    ...".
# Do not match the bare name: the header line has the user and host names, and CI runs as "runner".
assert_no_row() {
    local output="$1" name="$2" message="$3"
    if grep -qE "^(OK|WARN|FAIL) +$name " <<<"$output"; then
        printf '%s\n' "$output" >&2
        fail "$message"
    fi
}

# Print a log time stamp, as pr-review-cron writes it, for a time such as "5 minutes ago".
stamp() {
    date --iso-8601=seconds -d "$1"
}

home_dir="$test_dir/home"
state_dir="$home_dir/.local/state"
fake_bin="$test_dir/bin"
mkdir -p "$home_dir" "$fake_bin" \
    "$state_dir/pr-review" "$state_dir/pr-review-update" "$state_dir/pr-review-quorum"

# The fixture clone has an https origin, so install.sh accepts it.
# The health check reads main from a local bare repository instead.
upstream="$test_dir/upstream.git"
clone="$test_dir/clone"
git init -q --bare "$upstream"
git init -q -b main "$clone"
cp -R "$project_dir/install.sh" "$project_dir/hosts" "$project_dir/bin" "$clone/"
sed -i "s|^PR_REVIEW_PATH=.*|PR_REVIEW_PATH='$fake_bin:/usr/bin:/bin'|" "$clone/hosts/codex.env"
git -C "$clone" add -A
git -C "$clone" -c user.name=test -c user.email=test@example.invalid commit -q -m fixture
git -C "$clone" push -q "$upstream" main
git -C "$clone" remote add origin https://github.com/thelarklanlabs/pr-review.git

cat >"$fake_bin/crontab" <<'EOF'
#!/usr/bin/env bash
[[ "$1" == "-l" ]] || exit 1
cat "$FAKE_CRONTAB"
EOF
cat >"$fake_bin/gh" <<'EOF'
#!/usr/bin/env bash
# Read stdin, as some real programs do, to prove that the health check keeps its script away from children.
cat >/dev/null
case "$1 $2" in
    "api user")
        [[ -n "${FAKE_GH_LOGIN:-}" ]] || exit 1
        printf '%s\n' "$FAKE_GH_LOGIN"
        ;;
    "issue list")
        printf '%s' "${FAKE_GH_ISSUES:-}"
        ;;
    *) exit 1 ;;
esac
EOF
cat >"$fake_bin/npm" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$FAKE_NPM_LATEST"
EOF
cat >"$fake_bin/codex" <<'EOF'
#!/usr/bin/env bash
printf 'codex-cli 0.171.0\n'
EOF
chmod +x "$fake_bin"/*

export HOME="$home_dir"
export XDG_STATE_HOME="$state_dir"
export PATH="$fake_bin:/usr/bin:/bin"
export PR_REVIEW_HEALTH_REPO="$clone"
export PR_REVIEW_HEALTH_UPSTREAM="$upstream"
export FAKE_CRONTAB="$test_dir/crontab.txt"
export FAKE_GH_LOGIN=larkbot-codex
export FAKE_NPM_LATEST=0.171.0

{
    printf 'SHELL=/bin/bash\n'
    bash "$clone/install.sh" --role codex --print-crontab
} >"$FAKE_CRONTAB"

updater_log="$state_dir/pr-review-update/cron.log"
runner_log="$state_dir/pr-review/cron.log"
failure_file="$state_dir/pr-review/provider-failures"
printf '\n[2026-11-23T19:19:01-07:00] updater started\n[2026-11-23T19:19:03-07:00] already at verified commit abc\n' >"$updater_log"
write_clean_run() {
    printf '\n[2026-11-23T19:40:05-07:00] codex watcher started\npr-watch: checked 1 open PR(s)\n[2026-11-23T19:40:09-07:00] codex watcher finished: 0 confirmed, 0 failed, 0 paused\n' >"$runner_log"
}
write_clean_run
: >"$failure_file"

run_health() {
    local status=0
    output=$(bash "$clone/bin/pr-review-health" "$@" 2>&1) || status=$?
    return "$status"
}

# 1. A healthy codex host passes, and the role comes from the crontab.
run_health || fail "healthy host must pass: $output"
assert_contains "$output" 'pr-review-health: codex as' "role was not read from the crontab"
assert_contains "$output" 'OK   clone     at' "clone at main must pass"
assert_contains "$output" 'same as main' "clone must match main"
assert_contains "$output" 'OK   crontab   pr-review block matches' "crontab block must match"
assert_contains "$output" 'OK   updater' "updater must pass"
assert_contains "$output" 'OK   runner    codex watcher finished: 0 confirmed' "runner must pass"
assert_contains "$output" 'OK   failures  no failed review attempts' "failures must pass"
assert_contains "$output" 'OK   github    signed in as larkbot-codex' "github login must pass"
assert_contains "$output" 'OK   cli       codex 0.171.0 (latest)' "cli version must pass"
assert_not_contains "$output" 'WARN' "healthy host has a warning"

# 2. The script works when it arrives on stdin, as scripts/check-hosts.sh sends it.
status=0
output=$(bash -s -- --role codex <"$clone/bin/pr-review-health" 2>&1) || status=$?
((status == 0)) || fail "piped health check must pass: $output"
assert_contains "$output" 'OK   cli       codex 0.171.0 (latest)' "a child read the piped script"
assert_contains "$output" 'codex: 0 failure(s), 0 warning(s)' "piped summary mismatch"

# 3. An older CLI is a warning, not a failure.
FAKE_NPM_LATEST=0.172.0 run_health || fail "an old CLI must not fail the host"
assert_contains "$output" 'WARN cli       codex 0.171.0, latest is 0.172.0' "old CLI was not reported"
FAKE_NPM_LATEST=0.170.9 run_health || fail "a newer CLI must pass"
assert_contains "$output" 'OK   cli       codex 0.171.0 (latest)' "a newer CLI than the release is current"
FAKE_NPM_LATEST=0.172.0 run_health --no-latest || fail "--no-latest must pass"
assert_contains "$output" 'OK   cli       codex 0.171.0' "--no-latest must skip the release check"

# pr-review-cron puts ~/.local/bin before PR_REVIEW_PATH, so the health check must find that copy first.
mkdir -p "$home_dir/.local/bin"
cat >"$home_dir/.local/bin/codex" <<'EOF'
#!/usr/bin/env bash
printf 'codex-cli 0.172.0\n'
EOF
chmod +x "$home_dir/.local/bin/codex"
run_health --no-latest || fail "a CLI in ~/.local/bin must pass: $output"
assert_contains "$output" 'OK   cli       codex 0.172.0' "the CLI in ~/.local/bin was not used"
rm -f "$home_dir/.local/bin/codex"

# 4. A runner that has not written for a long time fails.
touch -d '30 minutes ago' "$runner_log"
if run_health; then
    fail "an idle runner must fail"
fi
assert_contains "$output" 'FAIL runner    no run for 30 minutes' "idle runner was not reported"
write_clean_run

# 5. A fatal error stops the run before "watcher finished" and fails.
printf '\n[2026-11-23T19:41:01-07:00] codex watcher started\npr-review-cron: authenticated as someone, expected larkbot-codex\n' >>"$runner_log"
if run_health; then
    fail "a runner error must fail"
fi
assert_contains "$output" 'FAIL runner    pr-review-cron: authenticated as someone' "runner error was not reported"

# A failed review attempt writes a "pr-review-cron:" line, but the run finishes, so it only warns.
{
    printf '\n[2026-11-23T19:42:01-07:00] codex watcher started\n'
    printf '[2026-11-23T19:42:05-07:00] reviewing thelarklanlabs/example#7 at 64cf1701234 (mode=full, worktree=/w)\n'
    printf 'pr-review-cron: thelarklanlabs/example#7 was not confirmed (provider=1, before=none, after=none, head=64cf1701234)\n'
    printf '[2026-11-23T19:42:09-07:00] codex watcher finished: 0 confirmed, 1 failed, 0 paused\n'
} >>"$runner_log"
run_health || fail "a failed review attempt must only warn: $output"
assert_contains "$output" 'WARN runner    codex watcher finished: 0 confirmed, 1 failed, 0 paused; first error: pr-review-cron: thelarklanlabs/example#7 was not confirmed' \
    "failed review was not reported"
write_clean_run

# 6. An active run. A process whose command line names bin/pr-review-cron stands in for the run.
# The ": done" keeps bash from replacing itself with sleep.
start_fake_runner() {
    bash -c 'sleep 300; : done' "$clone/bin/pr-review-cron" &
    review_pid=$!
}
# The sleep child can exit first, and then its bash parent exits too. Accept a process that is gone.
stop_fake_runner() {
    pkill -P "$review_pid" 2>/dev/null || true
    kill "$review_pid" 2>/dev/null || true
    wait "$review_pid" 2>/dev/null || true
    review_pid=""
}
start_fake_runner

# A review in progress passes, even when the log is old. The time comes from the "reviewing" line.
{
    printf '\n[%s] codex watcher started\n' "$(stamp '6 minutes ago')"
    printf '[%s] reviewing thelarklanlabs/example#7 at 64cf1701234 (mode=full, worktree=/w)\n' "$(stamp '5 minutes ago')"
} >>"$runner_log"
touch -d '20 minutes ago' "$runner_log"
run_health || fail "a review in progress must pass: $output"
assert_contains "$output" 'OK   runner    review in progress for 5 minutes: reviewing thelarklanlabs/example#7 at 64cf170' \
    "review in progress was not reported"

# One run reviews each queued pull request in turn. Time only the current review, not the run.
{
    printf '\n[%s] codex watcher started\n' "$(stamp '61 minutes ago')"
    printf '[%s] reviewing o/r#1 at aaaaaaa1111 (mode=full, worktree=/w)\n' "$(stamp '60 minutes ago')"
    printf '[%s] confirmed review 11 for o/r#1 at aaaaaaa1111\n' "$(stamp '15 minutes ago')"
    printf '[%s] reviewing o/r#2 at bbbbbbb2222 (mode=full, worktree=/w)\n' "$(stamp '15 minutes ago')"
} >>"$runner_log"
touch -d '15 minutes ago' "$runner_log"
run_health || fail "the second review of a long run must pass: $output"
assert_contains "$output" 'OK   runner    review in progress for 15 minutes: reviewing o/r#2 at bbbbbbb' \
    "the second review was not timed from its own start"

# A review that runs longer than its timeout fails.
printf '\n[%s] codex watcher started\n[%s] reviewing o/r#3 at ccccccc3333 (mode=full, worktree=/w)\n' \
    "$(stamp '56 minutes ago')" "$(stamp '55 minutes ago')" >>"$runner_log"
touch -d '55 minutes ago' "$runner_log"
if run_health; then
    fail "a hung review must fail"
fi
assert_contains "$output" 'FAIL runner    review has run for 55 minutes, longer than the timeout: reviewing o/r#3 at ccccccc' \
    "hung review was not reported"

# A poll that writes its log passes. A poll that stops writing its log fails.
printf '\n[%s] codex watcher started\n' "$(stamp 'now')" >>"$runner_log"
run_health || fail "a poll in progress must pass: $output"
assert_contains "$output" 'OK   runner    run in progress, last log write 0 minutes ago' "poll in progress was not reported"
touch -d '65 minutes ago' "$runner_log"
if run_health; then
    fail "a stalled poll must fail"
fi
assert_contains "$output" 'FAIL runner    run in progress has not written its log for 65 minutes' "stalled poll was not reported"

stop_fake_runner
write_clean_run

# 7. Paused and retrying pull requests are warnings.
printf 'thelarklanlabs/example#7 64cf1701234 3\nthelarklanlabs/example#8 aaaaaaa1111 1\n' >"$failure_file"
run_health || fail "failure records must only warn"
assert_contains "$output" 'WARN failures  paused after 3 failed attempts: thelarklanlabs/example#7@64cf170' "paused review missing"
assert_contains "$output" 'WARN failures  1 pull request(s) with failed attempts that will retry' "retry count missing"
: >"$failure_file"

# 8. A wrong or missing GitHub login fails.
if FAKE_GH_LOGIN=someone run_health; then
    fail "a wrong login must fail"
fi
assert_contains "$output" 'FAIL github    signed in as someone, expected larkbot-codex' "wrong login was not reported"
if FAKE_GH_LOGIN="" run_health; then
    fail "a missing login must fail"
fi
assert_contains "$output" 'FAIL github    gh cannot read the signed-in account' "missing login was not reported"

# 9. Crontab problems.
cp "$FAKE_CRONTAB" "$test_dir/crontab.good"
sed -i 's/PR_REVIEW_CODEX_EFFORT=medium/PR_REVIEW_CODEX_EFFORT=high/' "$FAKE_CRONTAB"
printf '* * * * * $HOME/.local/bin/pr-review-cron\n' >>"$FAKE_CRONTAB"
run_health --role codex || fail "crontab drift must only warn"
assert_contains "$output" 'WARN crontab   pr-review block differs from install.sh output' "drift was not reported"
assert_contains "$output" 'WARN crontab   old review entry outside the pr-review block' "old entry was not reported"
printf 'SHELL=/bin/bash\n' >"$FAKE_CRONTAB"
if run_health --role codex; then
    fail "a missing cron block must fail"
fi
assert_contains "$output" 'FAIL crontab   no pr-review block; run install.sh --role codex' "missing block was not reported"
if run_health; then
    fail "a missing role must fail"
fi
assert_contains "$output" 'cannot find the role; pass --role' "missing role was not reported"
cp "$test_dir/crontab.good" "$FAKE_CRONTAB"

# 10. A clone behind main and a stopped updater.
git -C "$clone" -c user.name=test -c user.email=test@example.invalid commit -q --allow-empty -m newer
git -C "$clone" push -q "$upstream" main
git -C "$clone" reset -q --hard HEAD~1
run_health || fail "a clone behind main must only warn"
assert_contains "$output" 'main is ' "clone behind main was not reported"
assert_contains "$output" 'WARN clone' "clone behind main must warn"
printf 'leftover\n' >"$clone/extra.txt"
if run_health; then
    fail "local changes must fail"
fi
assert_contains "$output" 'FAIL clone     has local changes' "local changes were not reported"
rm -f "$clone/extra.txt"
printf 'pr-review-update: verification failed for abc; source stays at def\n' >>"$updater_log"
if run_health; then
    fail "an updater error must fail"
fi
assert_contains "$output" 'FAIL updater   pr-review-update: verification failed' "updater error was not reported"
touch -d '3 hours ago' "$updater_log"
if run_health; then
    fail "an old updater log must fail"
fi
assert_contains "$output" 'FAIL updater   no run for 180 minutes' "stopped updater was not reported"
printf '\n[2026-11-23T20:19:01-07:00] updater started\n[2026-11-23T20:19:03-07:00] already at verified commit abc\n' >"$updater_log"

# 11. The services role checks the config mode and the last poll of each App installation.
config_dir="$home_dir/.config/pr-review"
mkdir -p "$config_dir"
touch "$config_dir/pr-review-quorum.env" "$config_dir/thelarklanlabs.env"
chmod 600 "$config_dir/pr-review-quorum.env"
chmod 644 "$config_dir/thelarklanlabs.env"
# Each installation has its own log and status file, named after its config file.
# pr-review-quorum writes "TIME STATUS" to the status file when a poll ends.
quorum_log="$state_dir/pr-review-quorum/thelarklanlabs.log"
quorum_status="$state_dir/pr-review-quorum/thelarklanlabs.status"
user_quorum_log="$state_dir/pr-review-quorum/pr-review-quorum.log"
user_quorum_status="$state_dir/pr-review-quorum/pr-review-quorum.status"
write_poll_status() {
    printf '%s %s\n' "$(stamp now)" "$2" >"$1"
}
printf 'pr-review-quorum: could not list open pull requests for a/b\n{"repository":"a/b","pull":1}\n' >"$quorum_log"
write_poll_status "$quorum_status" 0
printf '{"repository":"thelarklan/x","pull":1}\n' >"$user_quorum_log"
write_poll_status "$user_quorum_status" 0
run_health --role services --no-latest || true
assert_contains "$output" 'OK   config    pr-review-quorum.env exists with mode 600' "good config mode missing"
assert_contains "$output" 'thelarklanlabs.env has mode 644; run chmod 600 on it' "bad config mode missing"
assert_contains "$output" 'OK   quorum    thelarklanlabs: the last poll at' "a successful poll must pass"
assert_contains "$output" 'OK   quorum    pr-review-quorum: the last poll at' "the user-account poll was not checked"
assert_no_row "$output" runner "services must not check a review runner"
chmod 600 "$config_dir/thelarklanlabs.env"
run_health --role services || fail "successful polls must pass: $output"

# A poll can log errors, publish a failure result, and exit 1. The exit status decides.
printf 'pr-review-quorum: could not re-read reviews for a/b#1; publishing failure\n{"repository":"a/b","pull":1,"conclusion":"failure"}\n' \
    >>"$quorum_log"
write_poll_status "$quorum_status" 1
if run_health --role services; then
    fail "a failed poll with a result line must fail"
fi
assert_contains "$output" 'FAIL quorum    thelarklanlabs: the last poll at' "failed poll was not reported"
assert_contains "$output" 'exited with status 1: pr-review-quorum: could not re-read reviews for a/b#1' \
    "failed poll status or error mismatch"
assert_contains "$output" 'OK   quorum    pr-review-quorum: the last poll at' \
    "a failed poll of one installation must not change the other"

# A poll that stops running fails, even when its last result was good.
write_poll_status "$quorum_status" 0
touch -d '1 hour ago' "$quorum_status"
if run_health --role services; then
    fail "a stopped quorum poll must fail"
fi
assert_contains "$output" 'FAIL quorum    thelarklanlabs: no finished poll for 60 minutes' "stopped poll was not reported"
write_poll_status "$quorum_status" 0

# A host that has not installed the status file yet only warns.
rm -f "$quorum_status"
run_health --role services || fail "a missing status file must only warn: $output"
assert_contains "$output" 'WARN quorum    thelarklanlabs: no poll status at' "missing status file was not reported"
write_poll_status "$quorum_status" 0

# One missing config only warns. When no configured config exists, the check fails.
mv "$config_dir/pr-review-quorum.env" "$test_dir/pr-review-quorum.env.saved"
run_health --role services || fail "one missing config must only warn: $output"
assert_contains "$output" 'WARN config    '"$config_dir"'/pr-review-quorum.env does not exist' "missing config was not reported"
mv "$config_dir/thelarklanlabs.env" "$test_dir/thelarklanlabs.env.saved"
if run_health --role services; then
    fail "services without any quorum config must fail"
fi
assert_contains "$output" 'FAIL config    no quorum config exists' "no config was not reported"
mv "$test_dir/pr-review-quorum.env.saved" "$config_dir/pr-review-quorum.env"
mv "$test_dir/thelarklanlabs.env.saved" "$config_dir/thelarklanlabs.env"

# 12. scripts/check-hosts.sh runs the check through wsl.exe and lists health issues.
# Each call gets /dev/null as stdin, because the fake gh reads stdin.
touch "$runner_log"
cat >"$fake_bin/wsl.exe" <<'EOF'
#!/usr/bin/env bash
# Drop "-d DISTRO --cd / --" and run the rest here.
[[ "$1" == "-d" && "$3" == "--cd" && "$5" == "--" ]] || exit 9
printf 'distro=%s\n' "$2"
shift 5
exec "$@"
EOF
chmod +x "$fake_bin/wsl.exe"
status=0
output=$(PR_REVIEW_WSL_BIN="$fake_bin/wsl.exe" bash "$project_dir/scripts/check-hosts.sh" codex=other 2>&1 </dev/null) || status=$?
((status == 0)) || fail "check-hosts.sh must pass for a healthy host: $output"
assert_contains "$output" '== codex (WSL distribution other)' "target heading mismatch"
assert_contains "$output" 'distro=other' "the distribution name was not passed to wsl.exe"
assert_contains "$output" 'OK   github    signed in as larkbot-codex' "the host check did not run"
assert_contains "$output" 'check-hosts.sh: all hosts are healthy' "healthy summary missing"
status=0
output=$(FAKE_GH_ISSUES='#12 [bot-health] codex (larkbot-codex) review alert' PR_REVIEW_WSL_BIN="$fake_bin/wsl.exe" \
    bash "$project_dir/scripts/check-hosts.sh" codex=other 2>&1 </dev/null) || status=$?
((status == 1)) || fail "an open health issue must fail check-hosts.sh"
assert_contains "$output" 'FAIL #12 [bot-health] codex (larkbot-codex) review alert' "health issue was not listed"
if bash "$project_dir/scripts/check-hosts.sh" nobody >/dev/null 2>&1; then
    fail "an unknown role must fail"
fi

printf 'pr_review_health_test.sh: all tests passed\n'
