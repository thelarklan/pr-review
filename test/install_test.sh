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

codex_cron=$("$project_dir/install.sh" --role codex --print-crontab)
assert_contains "$codex_cron" '*/5 * * * * ' "codex schedule missing"
assert_contains "$codex_cron" 'PR_REVIEW_CODEX_MODEL=gpt-6.2-sol' "codex model mismatch"
assert_contains "$codex_cron" 'PR_REVIEW_CODEX_EFFORT=high' "codex effort mismatch"
assert_contains "$codex_cron" "$project_dir/bin/pr-review-cron" "codex runner path mismatch"
assert_contains "$codex_cron" '19 * * * * ' "codex updater schedule missing"
assert_contains "$codex_cron" "$project_dir/bin/pr-review-update" "codex updater path mismatch"

claude_cron=$("$project_dir/install.sh" --role claude --print-crontab)
assert_contains "$claude_cron" '1-56/5 * * * * ' "claude schedule missing"
assert_contains "$claude_cron" 'PR_REVIEW_CLAUDE_MODEL=claude-opus-5-5' "claude model mismatch"
assert_contains "$claude_cron" 'PR_REVIEW_CLAUDE_EFFORT=high' "claude effort mismatch"
assert_contains "$claude_cron" 'PR_REVIEW_PATH="$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin"' "claude PATH missing"

gemini_cron=$("$project_dir/install.sh" --role gemini --print-crontab)
assert_contains "$gemini_cron" '2-57/5 * * * * ' "gemini schedule missing"
assert_contains "$gemini_cron" 'PR_REVIEW_GEMINI_DRIVER=agy' "gemini driver mismatch"
assert_contains "$gemini_cron" 'PR_REVIEW_ANTIGRAVITY_MODEL=gemini-4-neon-high' "gemini model mismatch"
assert_contains "$gemini_cron" 'PR_REVIEW_ANTIGRAVITY_EFFORT=""' "gemini effort should be empty"

services_cron=$("$project_dir/install.sh" --role services --print-crontab)
assert_contains "$services_cron" '* * * * * ' "services schedule missing"
assert_contains "$services_cron" 'QUORUM_CONFIG_FILE="$HOME/.config/pr-review/pr-review-quorum.env"' "services config missing"
assert_contains "$services_cron" "$project_dir/bin/pr-review-quorum" "services quorum path mismatch"
assert_contains "$services_cron" 'PR_REVIEW_UPDATE_LOCK="$HOME/.cache/pr-review-quorum/cron.lock"' "services lock mismatch"

for out in "$codex_cron" "$claude_cron" "$gemini_cron" "$services_cron"; do
    if [[ "$out" == *".local/bin/pr-review-"* ]]; then
        fail "rendered crontab still references ~/.local/bin/pr-review-*"
    fi
done

fake_home="$test_dir/home"
mkdir -p "$fake_home"
HOME="$fake_home" "$project_dir/install.sh" --role services --no-crontab >/dev/null
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
PATH="$fake_bin:$PATH" HOME="$fake_home" "$project_dir/install.sh" --role codex >/dev/null
PATH="$fake_bin:$PATH" HOME="$fake_home" "$project_dir/install.sh" --role codex >/dev/null
installed_store=$(<"$test_dir/crontab.store")
assert_contains "$installed_store" '/usr/local/bin/unrelated-job' "unrelated cron job was lost"
[[ "$(grep -Fc '# BEGIN pr-review' <<<"$installed_store")" == 1 ]] || \
    fail "install.sh duplicated managed crontab block"

if "$project_dir/install.sh" --role unknown >/dev/null 2>&1; then
    fail "invalid role succeeded"
fi

printf 'install tests passed\n'
