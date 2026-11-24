#!/usr/bin/env bash
# Crontab text keeps $HOME literal so the cron shell expands it at run time.
# shellcheck disable=SC2016
set -euo pipefail

repo_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
default_upstream=https://github.com/thelarklanlabs/pr-review.git

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
PR_REVIEW_COHORT=""
PR_REVIEW_CODEX_MODEL=""
PR_REVIEW_CODEX_EFFORT=""
PR_REVIEW_CLAUDE_MODEL=""
PR_REVIEW_CLAUDE_EFFORT=""
PR_REVIEW_GEMINI_DRIVER=""
PR_REVIEW_ANTIGRAVITY_MODEL=""
PR_REVIEW_ANTIGRAVITY_EFFORT=""
PR_REVIEW_PATH=""
PR_REVIEW_ALERT_REPO=""
PR_REVIEW_OWNER=""
PR_REVIEW_LABEL=""
QUORUM_CONFIG_FILE=""
QUORUM_CONFIG_FILES=""
PR_REVIEW_UPDATE_LOCK=""

# shellcheck source=/dev/null
source "$host_env"

render_cron_block() {
    local update_lock="${PR_REVIEW_UPDATE_LOCK:-\$HOME/.cache/pr-review/cron.lock}"
    local runner_cmd=""

    if [[ "$role" == "services" ]]; then
        # One quorum pass per GitHub App installation, each with its own lock, log, and status file.
        # bin/pr-review-health reads the status file of each installation to judge its last poll.
        local config_files="${QUORUM_CONFIG_FILES:-$QUORUM_CONFIG_FILE}"
        local config_file config_name line
        local -a config_list=()
        read -r -a config_list <<<"$config_files"
        if ((${#config_list[@]} == 0)); then
            printf 'install.sh: services role needs QUORUM_CONFIG_FILES\n' >&2
            return 1
        fi
        # The updater holds every quorum lock, so it never replaces the checkout during a quorum pass.
        # The lock list uses ":" as separator, so a path with a space stays one path.
        # Schedule only the configs that exist, so an organization-only rebuild has no failing job.
        update_lock=""
        for config_file in "${config_list[@]}"; do
            config_name=$(basename -- "$config_file" .env)
            if [[ ! "$config_name" =~ ^[A-Za-z0-9._-]+$ ]]; then
                printf 'install.sh: unsafe quorum config name: %s\n' "$config_file" >&2
                return 1
            fi
            if [[ ! -f "${config_file/\$HOME/$HOME}" ]]; then
                printf 'install.sh: not scheduling %s: the file does not exist\n' "$config_file" >&2
                continue
            fi
            line=$(printf '%s /usr/bin/flock -n "$HOME/.cache/pr-review-quorum/%s.lock" /usr/bin/env QUORUM_CONFIG_FILE="%s" QUORUM_STATUS_FILE="$HOME/.local/state/pr-review-quorum/%s.status" "%s/bin/pr-review-quorum" >>"$HOME/.local/state/pr-review-quorum/%s.log" 2>&1' \
                "$PR_REVIEW_CRON_SCHEDULE" "$config_name" "$config_file" "$config_name" "$repo_dir" "$config_name")
            runner_cmd+="${runner_cmd:+$'\n'}$line"
            update_lock+="${update_lock:+:}\$HOME/.cache/pr-review-quorum/$config_name.lock"
        done
        if [[ -z "$runner_cmd" ]]; then
            printf 'install.sh: no quorum config in QUORUM_CONFIG_FILES exists. Create one first (docs/recreate.md, section 1).\n' >&2
            return 1
        fi
    else
        local -a env_parts=(
            "PR_REVIEW_PROVIDER=$PR_REVIEW_PROVIDER"
            "PR_REVIEW_REVIEWER=$PR_REVIEW_REVIEWER"
        )
        if [[ -n "$PR_REVIEW_COHORT" ]]; then
            env_parts+=("PR_REVIEW_COHORT=$PR_REVIEW_COHORT")
        fi
        if [[ -n "$PR_REVIEW_LABEL" ]]; then
            env_parts+=("PR_REVIEW_LABEL=$PR_REVIEW_LABEL")
        fi
        if [[ -n "$PR_REVIEW_OWNER" ]]; then
            env_parts+=("PR_REVIEW_OWNER=$PR_REVIEW_OWNER")
        fi
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

    # The updater pulls from the same URL as the origin remote of this clone.
    # To move the repository, run "git remote set-url origin <url>" and then run install.sh again.
    local upstream
    upstream=$(git -C "$repo_dir" remote get-url origin 2>/dev/null || true)
    upstream="${upstream:-$default_upstream}"
    if [[ ! "$upstream" =~ ^https://[A-Za-z0-9._/-]+$ ]]; then
        printf 'install.sh: origin remote must be an https URL: %s\n' "$upstream" >&2
        return 1
    fi

    local update_cmd
    update_cmd=$(printf '19 * * * * /usr/bin/env PR_REVIEW_ROLE=%s PR_REVIEW_UPDATE_SOURCE="%s" PR_REVIEW_UPDATE_UPSTREAM=%s PR_REVIEW_UPDATE_LOCK="%s" "%s/bin/pr-review-update"' \
        "$role" "$repo_dir" "$upstream" "$update_lock" "$repo_dir")

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
    mkdir -p "$HOME/.cache/pr-review" "$HOME/.local/state/pr-review" \
        "$HOME/.local/share/pr-review/work/repos" "$HOME/.local/share/pr-review/work/prs"
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

# Record when each quorum poll was first scheduled.
# bin/pr-review-health gives a new poll this much time to write its first status file.
if [[ "$role" == "services" ]]; then
    while IFS= read -r status_path; do
        scheduled_file="${status_path/\$HOME/$HOME}"
        scheduled_file="${scheduled_file%.status}.scheduled"
        [[ -e "$scheduled_file" ]] || : >"$scheduled_file"
    done < <(grep -oE 'QUORUM_STATUS_FILE="[^"]+"' "$tmp_crontab" | cut -d'"' -f2)
fi
printf 'Installed pr-review %s schedule from %s\n' "$role" "$repo_dir"
