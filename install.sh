#!/usr/bin/env bash
# Crontab text keeps $HOME literal so the cron shell expands it at run time.
# shellcheck disable=SC2016
set -euo pipefail

repo_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

usage() {
    printf 'usage: %s --role codex|claude|gemini|services [--print-crontab] [--no-crontab]\n' "$0" >&2
}

role=""
print_crontab=0
no_crontab=0

while (($# > 0)); do
    case "$1" in
        --role)
            (($# >= 2)) || {
                usage
                exit 2
            }
            role="$2"
            shift 2
            ;;
        --print-crontab)
            print_crontab=1
            shift
            ;;
        --no-crontab)
            no_crontab=1
            shift
            ;;
        -h | --help)
            usage
            exit 0
            ;;
        *)
            usage
            exit 2
            ;;
    esac
done

case "$role" in
    codex | claude | gemini | services) ;;
    *)
        usage
        exit 2
        ;;
esac

host_env="$repo_dir/hosts/${role}.env"
[[ -f "$host_env" ]] || {
    printf 'install.sh: missing host config: %s\n' "$host_env" >&2
    exit 1
}

PR_REVIEW_CRON_SCHEDULE=""
PR_REVIEW_PROVIDER=""
PR_REVIEW_REVIEWER=""
PR_REVIEW_CODEX_MODEL=""
PR_REVIEW_CODEX_EFFORT=""
PR_REVIEW_CLAUDE_MODEL=""
PR_REVIEW_CLAUDE_EFFORT=""
PR_REVIEW_GEMINI_DRIVER=""
PR_REVIEW_ANTIGRAVITY_MODEL=""
PR_REVIEW_ANTIGRAVITY_EFFORT=""
PR_REVIEW_PATH=""
PR_REVIEW_ALERT_REPO=""
QUORUM_CONFIG_FILE=""
PR_REVIEW_UPDATE_LOCK=""

# shellcheck source=/dev/null
source "$host_env"

render_cron_block() {
    local update_lock="${PR_REVIEW_UPDATE_LOCK:-\$HOME/.cache/pr-review/cron.lock}"
    local runner_cmd=""

    if [[ "$role" == "services" ]]; then
        runner_cmd=$(printf '%s /usr/bin/flock -n "$HOME/.cache/pr-review-quorum/cron.lock" /usr/bin/env QUORUM_CONFIG_FILE="%s" "%s/bin/pr-review-quorum" >>"$HOME/.local/state/pr-review-quorum/cron.log" 2>&1' \
            "$PR_REVIEW_CRON_SCHEDULE" "$QUORUM_CONFIG_FILE" "$repo_dir")
    else
        local -a env_parts=(
            "PR_REVIEW_PROVIDER=$PR_REVIEW_PROVIDER"
            "PR_REVIEW_REVIEWER=$PR_REVIEW_REVIEWER"
        )
        case "$PR_REVIEW_PROVIDER" in
            codex)
                env_parts+=(
                    "PR_REVIEW_CODEX_MODEL=$PR_REVIEW_CODEX_MODEL"
                    "PR_REVIEW_CODEX_EFFORT=$PR_REVIEW_CODEX_EFFORT"
                )
                ;;
            claude)
                env_parts+=(
                    "PR_REVIEW_CLAUDE_MODEL=$PR_REVIEW_CLAUDE_MODEL"
                    "PR_REVIEW_CLAUDE_EFFORT=$PR_REVIEW_CLAUDE_EFFORT"
                )
                ;;
            gemini)
                env_parts+=(
                    "PR_REVIEW_GEMINI_DRIVER=$PR_REVIEW_GEMINI_DRIVER"
                    "PR_REVIEW_ANTIGRAVITY_MODEL=$PR_REVIEW_ANTIGRAVITY_MODEL"
                    "PR_REVIEW_ANTIGRAVITY_EFFORT=\"${PR_REVIEW_ANTIGRAVITY_EFFORT:-}\""
                )
                ;;
        esac
        env_parts+=(
            "PR_REVIEW_PATH=\"$PR_REVIEW_PATH\""
            "PR_REVIEW_ALERT_REPO=$PR_REVIEW_ALERT_REPO"
        )
        runner_cmd=$(printf '%s /usr/bin/flock -n "$HOME/.cache/pr-review/cron.lock" /usr/bin/env %s "%s/bin/pr-review-cron"' \
            "$PR_REVIEW_CRON_SCHEDULE" "${env_parts[*]}" "$repo_dir")
    fi

    local update_cmd
    update_cmd=$(printf '19 * * * * /usr/bin/env PR_REVIEW_ROLE=%s PR_REVIEW_UPDATE_SOURCE="%s" PR_REVIEW_UPDATE_UPSTREAM=https://github.com/thelarklan/pr-review.git PR_REVIEW_UPDATE_LOCK="%s" "%s/bin/pr-review-update"' \
        "$role" "$repo_dir" "$update_lock" "$repo_dir")

    printf '# BEGIN pr-review\n%s\n%s\n# END pr-review\n' "$runner_cmd" "$update_cmd"
}

if ((print_crontab == 1)); then
    render_cron_block
    exit 0
fi

mkdir -p "$HOME/.local/state/pr-review-update"
if [[ "$role" == "services" ]]; then
    mkdir -p "$HOME/.cache/pr-review-quorum" "$HOME/.local/state/pr-review-quorum"
else
    mkdir -p "$HOME/.cache/pr-review" "$HOME/.local/state/pr-review" "$HOME/.local/share/pr-review/work"
fi

if ((no_crontab == 1)); then
    printf 'Prepared %s directories without modifying crontab.\n' "$role"
    exit 0
fi

existing_crontab=$(crontab -l 2>/dev/null || true)
cleaned_crontab=$(awk '
    /^# BEGIN pr-review$/ { skip = 1; next }
    /^# END pr-review$/ { skip = 0; next }
    !skip { print }
' <<<"$existing_crontab")

header_lines=""
if ! grep -Eq '^SHELL=' <<<"$cleaned_crontab"; then
    header_lines+=$'SHELL=/bin/bash\n'
fi
if ! grep -Eq '^PATH=' <<<"$cleaned_crontab"; then
    header_lines+=$'PATH=/usr/local/bin:/usr/bin:/bin\n'
fi

tmp_crontab=$(mktemp)
trap 'rm -f -- "$tmp_crontab"' EXIT

{
    if [[ -n "$header_lines" ]]; then
        printf '%s' "$header_lines"
    fi
    if [[ -n "$cleaned_crontab" ]]; then
        printf '%s\n' "$cleaned_crontab"
    fi
    render_cron_block
} >"$tmp_crontab"

crontab "$tmp_crontab"
printf 'Installed pr-review %s schedule from %s\n' "$role" "$repo_dir"
