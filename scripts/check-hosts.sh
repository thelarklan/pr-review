#!/usr/bin/env bash
# Run bin/pr-review-health on each WSL host role, then list open [bot-health] issues.
# Run it from Windows (Git Bash) or from a WSL distribution with Windows interop.
# Each host runs the copy of bin/pr-review-health from this clone, so a host with an old clone still gets the current checks.
set -uo pipefail

repo_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
health_script="$repo_dir/bin/pr-review-health"
wsl_bin="${PR_REVIEW_WSL_BIN:-wsl.exe}"
alert_repo="${PR_REVIEW_ALERT_REPO:-thelarklanlabs/pr-review}"

usage() {
    printf 'usage: %s [--no-latest] [ROLE[=DISTRO] ...]\n' "$0" >&2
    printf 'The default targets are services, codex, claude, and gemini. Each distribution has the name of its role.\n' >&2
}

health_args=()
targets=()
while (($# > 0)); do
    case "$1" in
        --no-latest)
            health_args+=(--no-latest)
            shift
            ;;
        -h | --help)
            usage
            exit 0
            ;;
        -*)
            usage
            exit 2
            ;;
        *)
            targets+=("$1")
            shift
            ;;
    esac
done
if ((${#targets[@]} == 0)); then
    targets=(services codex claude gemini)
fi

problems=0
for target in "${targets[@]}"; do
    role="${target%%=*}"
    distro="${target#*=}"
    case "$role" in
        codex | claude | gemini | services) ;;
        *)
            printf 'check-hosts.sh: unknown role: %s\n' "$role" >&2
            exit 2
            ;;
    esac

    printf '\n== %s (WSL distribution %s)\n' "$role" "$distro"
    # "--cd /" stops a warning when the current folder has no path in the target distribution.
    if ! "$wsl_bin" -d "$distro" --cd / -- bash -s -- --role "$role" "${health_args[@]}" <"$health_script"; then
        problems=$((problems + 1))
    fi
done

printf '\n== open [bot-health] issues in %s\n' "$alert_repo"
# A skipped issue lookup is an incomplete check, so it counts as a problem.
if ! command -v gh >/dev/null 2>&1; then
    printf 'FAIL gh is not installed here; cannot list the issues, so the check is incomplete\n'
    problems=$((problems + 1))
elif ! issues=$(gh issue list --repo "$alert_repo" --state open --search '"[bot-health]" in:title' \
    --json number,title --jq '.[] | "#\(.number) \(.title)"' 2>/dev/null); then
    printf 'FAIL cannot list issues in %s, so the check is incomplete\n' "$alert_repo"
    problems=$((problems + 1))
elif [[ -z "$issues" ]]; then
    printf 'OK   none\n'
else
    while IFS= read -r issue; do
        printf 'FAIL %s\n' "$issue"
    done <<<"$issues"
    problems=$((problems + 1))
fi

printf '\n'
if ((problems > 0)); then
    printf 'check-hosts.sh: %s problem area(s); read the FAIL lines above\n' "$problems"
    exit 1
fi
printf 'check-hosts.sh: all hosts are healthy\n'
