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
case "$*" in
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

# --replace-checks drops the existing CI checks.
run_enroll FAKE_VISIBILITY=public FAKE_EXISTING_ID=55 "$enroll" thelarklanlabs/example \
    --app-id 999 --replace-checks >"$test_dir/out"
checks=$(jq -c '[.rules[] | select(.type == "required_status_checks") | .parameters.required_status_checks[].context]' "$test_dir/payload.json")
[[ "$checks" == '["bot-review-quorum"]' ]] || fail "--replace-checks kept old checks: $checks"

# Private repository on GitHub Free: no ruleset.
run_enroll FAKE_VISIBILITY=private "$enroll" thelarklanlabs/example --app-id 999 >"$test_dir/out"
if grep -Fq '/rulesets' "$test_dir/calls"; then
    fail "private repository got a ruleset call"
fi
grep -Fq 'advisory' "$test_dir/out" || fail "private repository result was not explained"

# Dry run: read only.
run_enroll FAKE_VISIBILITY=public "$enroll" thelarklanlabs/example --app-id 999 --dry-run >"$test_dir/out"
if grep -Eq -- '-X (PATCH|PUT|POST)' "$test_dir/calls"; then
    fail "dry run changed GitHub"
fi
grep -Fq 'would run: gh api -X POST repos/thelarklanlabs/example/rulesets' "$test_dir/out" ||
    fail "dry run did not show the planned ruleset call"

# Invalid input.
if run_enroll FAKE_VISIBILITY=public "$enroll" thelarklanlabs/example --app-id abc >/dev/null 2>&1; then
    fail "non-numeric App ID was accepted"
fi
if run_enroll FAKE_VISIBILITY=public "$enroll" 'bad repo' --app-id 1 >/dev/null 2>&1; then
    fail "invalid repository name was accepted"
fi

printf 'enroll-repo tests passed\n'
