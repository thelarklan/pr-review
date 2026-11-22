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
previous=""
for argument in "$@"; do
    if [[ "$previous" == --input ]]; then
        cp -- "$argument" "$GH_PAYLOAD"
    fi
    previous="$argument"
done
# GitHub Free may reject auto-merge on a private repository (HTTP 422).
if [[ "$FAKE_VISIBILITY" == private && "$*" == *"-X PATCH"* && "$*" == *allow_auto_merge* ]]; then
    printf 'HTTP 422: auto-merge is not available for this repository\n' >&2
    exit 1
fi
case "$*" in
    "api users/thelarklanlabs --jq .type")
        printf '%s\n' "${FAKE_OWNER_TYPE:-Organization}"
        ;;
    "api orgs/thelarklanlabs/installations --jq "*)
        # The real call filters by app_id with jq. Here App 999 is the installed one.
        if [[ "$*" == *"app_id == 999)"* ]]; then
            printf '%s\n' "${FAKE_SELECTION:-all}"
        fi
        ;;
    "api repos/thelarklanlabs/example --jq .visibility")
        printf '%s\n' "$FAKE_VISIBILITY"
        ;;
    "api repos/thelarklanlabs/example/rulesets --jq "*)
        if [[ -n "${FAKE_EXISTING_ID:-}" ]]; then
            printf '%s\n' "$FAKE_EXISTING_ID"
        fi
        ;;
    "api repos/thelarklanlabs/example/rulesets/55")
        # The live ruleset of pr-review: the old App and the verify CI job.
        printf '%s\n' '{"id":55,"name":"main protection","rules":[{"type":"deletion"},{"type":"required_status_checks","parameters":{"required_status_checks":[{"context":"bot-review-quorum","integration_id":4752010},{"context":"verify","integration_id":15368}]}}]}'
        ;;
    "api repos/thelarklanlabs/example/rulesets/57")
        # A live ruleset with protections that the template does not define.
        printf '%s\n' '{"id":57,"name":"main protection","rules":[{"type":"deletion"},{"type":"required_signatures"},{"type":"pull_request","parameters":{"required_approving_review_count":2,"require_extra_approval_for_unattributed_changes":true,"allowed_merge_methods":["squash","merge"]}},{"type":"required_status_checks","parameters":{"required_status_checks":[{"context":"bot-review-quorum","integration_id":4752010},{"context":"verify","integration_id":15368}]}}]}'
        ;;
    "api repos/thelarklanlabs/example/rulesets/56")
        # A check that accepts results from any source has no integration_id.
        printf '%s\n' '{"id":56,"name":"main protection","rules":[{"type":"required_status_checks","parameters":{"required_status_checks":[{"context":"bot-review-quorum","integration_id":4752010},{"context":"any-source"}]}}]}'
        ;;
esac
EOF
chmod +x "$test_dir/bin/gh"

run_enroll() {
    : >"$test_dir/calls"
    rm -f -- "$test_dir/payload.json"
    env PATH="$test_dir/bin:$PATH" \
        GH_CALL_LOG="$test_dir/calls" \
        GH_PAYLOAD="$test_dir/payload.json" \
        "$@"
}

enroll="$project_dir/scripts/enroll-repo.sh"

# Public repository without a ruleset: create it.
run_enroll FAKE_VISIBILITY=public "$enroll" thelarklanlabs/example \
    --app-id 999 --check verify --check custom:7 >"$test_dir/out"
grep -Fq 'api -X PATCH repos/thelarklanlabs/example -F allow_squash_merge=true -F allow_merge_commit=false' "$test_dir/calls" ||
    fail "merge settings were not applied"
for bot in larkbot-codex larkbot-claude larkbot-gemini; do
    grep -Fq "api -X PUT repos/thelarklanlabs/example/collaborators/$bot -f permission=push" "$test_dir/calls" ||
        fail "$bot was not given write access"
done
grep -Fq 'api -X POST repos/thelarklanlabs/example/rulesets --input' "$test_dir/calls" ||
    fail "new ruleset was not created"
checks=$(jq -c '[.rules[] | select(.type == "required_status_checks") | .parameters.required_status_checks[]]' "$test_dir/payload.json")
[[ "$checks" == '[{"context":"bot-review-quorum","integration_id":999},{"context":"verify","integration_id":15368},{"context":"custom","integration_id":7}]' ]] ||
    fail "required checks are wrong: $checks"
[[ "$(jq '[.rules[] | select(.type == "pull_request") | .parameters.required_approving_review_count][0]' "$test_dir/payload.json")" == 3 ]] ||
    fail "ruleset must require 3 approvals"
[[ "$(jq '.bypass_actors | length' "$test_dir/payload.json")" == 0 ]] ||
    fail "ruleset must have no bypass actors"

# Existing ruleset: update it in place.
run_enroll FAKE_VISIBILITY=public FAKE_EXISTING_ID=55 "$enroll" thelarklanlabs/example \
    --app-id 999 >"$test_dir/out"
grep -Fq 'api -X PUT repos/thelarklanlabs/example/rulesets/55 --input' "$test_dir/calls" ||
    fail "existing ruleset was not updated"
if grep -Fq 'api -X POST repos/thelarklanlabs/example/rulesets' "$test_dir/calls"; then
    fail "a second ruleset was created"
fi
# A new App ID alone must keep the existing CI check.
checks=$(jq -c '[.rules[] | select(.type == "required_status_checks") | .parameters.required_status_checks[]]' "$test_dir/payload.json")
[[ "$checks" == '[{"context":"bot-review-quorum","integration_id":999},{"context":"verify","integration_id":15368}]' ]] ||
    fail "App change dropped or kept the wrong checks: $checks"

# A --check value with the same name replaces the kept check, and new checks are added once.
run_enroll FAKE_VISIBILITY=public FAKE_EXISTING_ID=55 "$enroll" thelarklanlabs/example \
    --app-id 999 --check verify:42 --check lint --check lint >"$test_dir/out"
checks=$(jq -c '[.rules[] | select(.type == "required_status_checks") | .parameters.required_status_checks[]]' "$test_dir/payload.json")
[[ "$checks" == '[{"context":"bot-review-quorum","integration_id":999},{"context":"verify","integration_id":42},{"context":"lint","integration_id":15368}]' ]] ||
    fail "merged checks are wrong: $checks"

# An unpinned check stays unpinned: no integration_id key, never null.
run_enroll FAKE_VISIBILITY=public FAKE_EXISTING_ID=56 "$enroll" thelarklanlabs/example \
    --app-id 999 >"$test_dir/out"
grep -Fq 'api -X PUT repos/thelarklanlabs/example/rulesets/56 --input' "$test_dir/calls" ||
    fail "ruleset 56 was not updated"
checks=$(jq -c '[.rules[] | select(.type == "required_status_checks") | .parameters.required_status_checks[]]' "$test_dir/payload.json")
[[ "$checks" == '[{"context":"bot-review-quorum","integration_id":999},{"context":"any-source"}]' ]] ||
    fail "unpinned check was changed: $checks"

# --replace-checks drops the existing CI checks.
run_enroll FAKE_VISIBILITY=public FAKE_EXISTING_ID=55 "$enroll" thelarklanlabs/example \
    --app-id 999 --replace-checks >"$test_dir/out"
checks=$(jq -c '[.rules[] | select(.type == "required_status_checks") | .parameters.required_status_checks[].context]' "$test_dir/payload.json")
[[ "$checks" == '["bot-review-quorum"]' ]] || fail "--replace-checks kept old checks: $checks"

# An App change keeps protections that the template does not define.
run_enroll FAKE_VISIBILITY=public FAKE_EXISTING_ID=57 "$enroll" thelarklanlabs/example \
    --app-id 999 >"$test_dir/out"
grep -Fq 'api -X PUT repos/thelarklanlabs/example/rulesets/57 --input' "$test_dir/calls" ||
    fail "ruleset 57 was not updated"
rule_types=$(jq -c '[.rules[].type]' "$test_dir/payload.json")
[[ "$rule_types" == '["deletion","required_signatures","pull_request","required_status_checks","non_fast_forward"]' ]] ||
    fail "rules were dropped or reordered: $rule_types"
pull_request=$(jq -c '.rules[] | select(.type == "pull_request") | .parameters' "$test_dir/payload.json")
[[ "$(jq '.require_extra_approval_for_unattributed_changes' <<<"$pull_request")" == true ]] ||
    fail "extra pull_request parameter was dropped: $pull_request"
[[ "$(jq '.required_approving_review_count' <<<"$pull_request")" == 3 ]] ||
    fail "template approval count did not win: $pull_request"
[[ "$(jq -c '.allowed_merge_methods' <<<"$pull_request")" == '["squash"]' ]] ||
    fail "template merge methods did not win: $pull_request"
checks=$(jq -c '[.rules[] | select(.type == "required_status_checks") | .parameters.required_status_checks[].context]' "$test_dir/payload.json")
[[ "$checks" == '["bot-review-quorum","verify"]' ]] || fail "checks are wrong after App change: $checks"
[[ "$(jq '.bypass_actors | length' "$test_dir/payload.json")" == 0 ]] ||
    fail "ruleset must have no bypass actors"

# Private repository on GitHub Free: no auto-merge field, bots still get access, no ruleset.
run_enroll FAKE_VISIBILITY=private "$enroll" thelarklanlabs/example --app-id 999 >"$test_dir/out" ||
    fail "private enrollment failed"
grep -Fq 'api -X PATCH repos/thelarklanlabs/example -F allow_squash_merge=true' "$test_dir/calls" ||
    fail "private repository did not get merge settings"
if grep -Fq 'allow_auto_merge' "$test_dir/calls"; then
    fail "private repository got the auto-merge setting"
fi
for bot in larkbot-codex larkbot-claude larkbot-gemini; do
    grep -Fq "api -X PUT repos/thelarklanlabs/example/collaborators/$bot -f permission=push" "$test_dir/calls" ||
        fail "private repository did not give $bot write access"
done
if grep -Fq '/rulesets' "$test_dir/calls"; then
    fail "private repository got a ruleset call"
fi
grep -Fq 'advisory' "$test_dir/out" || fail "private repository result was not explained"
if grep -Fq 'auto-merge allowed' "$test_dir/out"; then
    fail "private repository summary claims auto-merge"
fi

# Public repository: auto-merge is allowed.
run_enroll FAKE_VISIBILITY=public "$enroll" thelarklanlabs/example --app-id 999 >"$test_dir/out"
grep -Fq -- '-F allow_auto_merge=true' "$test_dir/calls" || fail "public repository did not allow auto-merge"

# Dry run: read only.
run_enroll FAKE_VISIBILITY=public "$enroll" thelarklanlabs/example --app-id 999 --dry-run >"$test_dir/out"
if grep -Eq -- '-X (PATCH|PUT|POST)' "$test_dir/calls"; then
    fail "dry run changed GitHub"
fi
grep -Fq 'would run: gh api -X POST repos/thelarklanlabs/example/rulesets' "$test_dir/out" ||
    fail "dry run did not show the planned ruleset call"

# The App must be installed for the owner before the ruleset requires its check.
assert_refused_without_writes() {
    local message="$1"
    shift
    if run_enroll FAKE_VISIBILITY=public "$@" >"$test_dir/out" 2>"$test_dir/err"; then
        fail "$message"
    fi
    if grep -Eq -- '-X (PATCH|PUT|POST)' "$test_dir/calls"; then
        fail "$message: GitHub was changed before the refusal"
    fi
}
assert_refused_without_writes "App not installed on the owner was accepted" \
    "$enroll" thelarklanlabs/example --app-id 4752010
grep -Fq 'App 4752010 is not installed on thelarklanlabs' "$test_dir/err" || fail "missing installation was not explained"
assert_refused_without_writes "App with selected repositories was accepted without confirmation" \
    FAKE_SELECTION=selected "$enroll" thelarklanlabs/example --app-id 999
assert_refused_without_writes "user-owned repository was accepted without confirmation" \
    FAKE_OWNER_TYPE=User "$enroll" thelarklanlabs/example --app-id 999
grep -Fq -- '--skip-install-check' "$test_dir/err" || fail "user-owned refusal did not name the override"
run_enroll FAKE_VISIBILITY=public FAKE_OWNER_TYPE=User "$enroll" thelarklanlabs/example \
    --app-id 999 --skip-install-check >"$test_dir/out" || fail "--skip-install-check did not proceed"
if grep -Fq 'api users/' "$test_dir/calls"; then
    fail "--skip-install-check still checked the installation"
fi

# Invalid input.
if run_enroll FAKE_VISIBILITY=public "$enroll" thelarklanlabs/example --app-id abc >/dev/null 2>&1; then
    fail "non-numeric App ID was accepted"
fi
if run_enroll FAKE_VISIBILITY=public "$enroll" 'bad repo' --app-id 1 >/dev/null 2>&1; then
    fail "invalid repository name was accepted"
fi

printf 'enroll-repo tests passed\n'
