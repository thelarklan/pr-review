#!/usr/bin/env bash
# Crontab text keeps $HOME literal so the cron shell expands it at run time.
# shellcheck disable=SC2016
set -euo pipefail

project_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

assert_contains() {
    local haystack="$1" needle="$2" message="$3"
    if [[ "$haystack" != *"$needle"* ]]; then
        fail "$message"
    fi
}

# Run install.sh from a fixture clone with a fixed https origin.
# The result then does not depend on how the developer cloned this repository.
install_dir="$test_dir/install-fixture"
git init -q "$install_dir"
cp -R "$project_dir/install.sh" "$project_dir/hosts" "$install_dir/"
git -C "$install_dir" remote add origin https://github.com/thelarklan/pr-review.git

codex_cron=$("$install_dir/install.sh" --role codex --print-crontab)
assert_contains "$codex_cron" '* * * * * /usr/bin/flock -n "$HOME/.cache/pr-review/cron.lock"' "codex must run each minute"
assert_contains "$codex_cron" 'PR_REVIEW_CODEX_MODEL=gpt-6.2-sol' "codex model mismatch"
assert_contains "$codex_cron" 'PR_REVIEW_CODEX_EFFORT=high' "codex effort mismatch"
assert_contains "$codex_cron" "$install_dir/bin/pr-review-cron" "codex runner path mismatch"
assert_contains "$codex_cron" '19 * * * * ' "codex updater schedule missing"
assert_contains "$codex_cron" "$install_dir/bin/pr-review-update" "codex updater path mismatch"
assert_contains "$codex_cron" 'PR_REVIEW_OWNER=thelarklan,thelarklanlabs' "codex owner list missing"

claude_cron=$("$install_dir/install.sh" --role claude --print-crontab)
assert_contains "$claude_cron" '* * * * * /usr/bin/flock -n "$HOME/.cache/pr-review/cron.lock"' "claude must run each minute"
assert_contains "$claude_cron" 'PR_REVIEW_CLAUDE_MODEL=claude-opus-5-5' "claude model mismatch"
assert_contains "$claude_cron" 'PR_REVIEW_CLAUDE_EFFORT=high' "claude effort mismatch"
assert_contains "$claude_cron" 'PR_REVIEW_PATH="$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin"' "claude PATH missing"

gemini_cron=$("$install_dir/install.sh" --role gemini --print-crontab)
assert_contains "$gemini_cron" '* * * * * /usr/bin/flock -n "$HOME/.cache/pr-review/cron.lock"' "gemini must run each minute"
assert_contains "$gemini_cron" 'PR_REVIEW_GEMINI_DRIVER=agy' "gemini driver mismatch"
assert_contains "$gemini_cron" 'PR_REVIEW_ANTIGRAVITY_MODEL=gemini-4-neon-high' "gemini model mismatch"
assert_contains "$gemini_cron" 'PR_REVIEW_ANTIGRAVITY_EFFORT=""' "gemini effort should be empty"

# services schedules only the quorum configs that exist.
services_home="$test_dir/services-home"
mkdir -p "$services_home/.config/pr-review"
touch "$services_home/.config/pr-review/thelarklanlabs.env"
org_only_cron=$(HOME="$services_home" "$install_dir/install.sh" --role services --print-crontab 2>"$test_dir/org-only.err")
[[ "$(grep -c 'bin/pr-review-quorum"' <<<"$org_only_cron")" == 1 ]] ||
    fail "organization-only rebuild must schedule one quorum job"
assert_contains "$org_only_cron" 'PR_REVIEW_UPDATE_LOCK="$HOME/.cache/pr-review-quorum/thelarklanlabs.lock"' \
    "organization-only updater lock mismatch"
grep -Fq 'not scheduling $HOME/.config/pr-review/pr-review-quorum.env' "$test_dir/org-only.err" ||
    fail "skipped config was not reported"
empty_home="$test_dir/empty-home"
mkdir -p "$empty_home"
if HOME="$empty_home" "$install_dir/install.sh" --role services --print-crontab >/dev/null 2>&1; then
    fail "services schedule without any quorum config was accepted"
fi

touch "$services_home/.config/pr-review/pr-review-quorum.env"
services_cron=$(HOME="$services_home" "$install_dir/install.sh" --role services --print-crontab)
assert_contains "$services_cron" '* * * * * ' "services schedule missing"
assert_contains "$services_cron" '/pr-review-quorum.lock" /usr/bin/env QUORUM_CONFIG_FILE="$HOME/.config/pr-review/pr-review-quorum.env"' "services user-account config missing"
assert_contains "$services_cron" '/thelarklanlabs.lock" /usr/bin/env QUORUM_CONFIG_FILE="$HOME/.config/pr-review/thelarklanlabs.env"' "services organization config missing"
[[ "$(grep -c 'bin/pr-review-quorum"' <<<"$services_cron")" == 2 ]] || \
    fail "services must run one quorum pass per config"
assert_contains "$services_cron" "$install_dir/bin/pr-review-quorum" "services quorum path mismatch"
assert_contains "$services_cron" 'PR_REVIEW_UPDATE_LOCK="$HOME/.cache/pr-review-quorum/pr-review-quorum.lock:$HOME/.cache/pr-review-quorum/thelarklanlabs.lock"' "services updater must hold both evaluator locks"

# The updater URL comes from the origin remote of the clone.
remote_clone="$test_dir/remote-clone"
git init -q "$remote_clone"
cp -R "$project_dir/install.sh" "$project_dir/hosts" "$remote_clone/"
git -C "$remote_clone" remote add origin https://github.com/example-org/pr-review.git
remote_cron=$("$remote_clone/install.sh" --role codex --print-crontab)
assert_contains "$remote_cron" 'PR_REVIEW_UPDATE_UPSTREAM=https://github.com/example-org/pr-review.git ' \
    "updater URL did not follow the origin remote"
git -C "$remote_clone" remote set-url origin 'https://github.com/x/y.git;touch /tmp/pwned'
if "$remote_clone/install.sh" --role codex --print-crontab >/dev/null 2>&1; then
    fail "unsafe origin URL was written into the crontab"
fi

# Hosts pull without credentials, so an SSH origin is refused with a clear message.
# A developer clone with an SSH origin still passes verify.sh, because the checks above use the fixture.
git -C "$remote_clone" remote set-url origin git@github.com:thelarklan/pr-review.git
if "$remote_clone/install.sh" --role codex --print-crontab >/dev/null 2>"$test_dir/ssh.err"; then
    fail "SSH origin was written into the crontab"
fi
grep -Fq 'origin remote must be an https URL' "$test_dir/ssh.err" ||
    fail "SSH origin refusal was not explained"

for out in "$codex_cron" "$claude_cron" "$gemini_cron" "$services_cron"; do
    if [[ "$out" == *".local/bin/pr-review-"* ]]; then
        fail "rendered crontab still references ~/.local/bin/pr-review-*"
    fi
done

fake_home="$test_dir/home"
mkdir -p "$fake_home"
HOME="$fake_home" "$install_dir/install.sh" --role services --no-crontab >/dev/null
[[ -d "$fake_home/.cache/pr-review-quorum" ]] || fail "services cache directory missing"
[[ -d "$fake_home/.local/state/pr-review-quorum" ]] || fail "services state directory missing"
[[ -d "$fake_home/.local/state/pr-review-update" ]] || fail "updater state directory missing"

fake_bin="$test_dir/bin"
mkdir -p "$fake_bin"
cat >"$fake_bin/crontab" <<EOF
#!/usr/bin/env bash
set -euo pipefail
store="$test_dir/crontab.store"
if [[ "\${1:-}" == "-l" ]]; then
    if [[ -f "\$store" ]]; then
        cat "\$store"
        exit 0
    fi
    exit 1
fi
# Real crontab accepts a file argument or "-" for standard input.
source_file="\${1:--}"
cat -- "\$source_file" >"\$store.next"
mv -f -- "\$store.next" "\$store"
EOF
chmod +x "$fake_bin/crontab"

printf '0 3 * * * /usr/local/bin/unrelated-job\n' >"$test_dir/crontab.store"
PATH="$fake_bin:$PATH" HOME="$fake_home" "$install_dir/install.sh" --role codex >/dev/null
PATH="$fake_bin:$PATH" HOME="$fake_home" "$install_dir/install.sh" --role codex >/dev/null
installed_store=$(<"$test_dir/crontab.store")
assert_contains "$installed_store" '/usr/local/bin/unrelated-job' "unrelated cron job was lost"
[[ "$(grep -Fc '# BEGIN pr-review' <<<"$installed_store")" == 1 ]] || \
    fail "install.sh duplicated managed crontab block"

if "$install_dir/install.sh" --role unknown >/dev/null 2>&1; then
    fail "invalid role succeeded"
fi

printf 'install tests passed\n'
