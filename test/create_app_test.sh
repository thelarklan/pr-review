#!/usr/bin/env bash
set -euo pipefail

project_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

create_app="$project_dir/scripts/create-app.sh"
config_dir="$test_dir/config"

# The fake curl serves the manifest conversion and the installation list.
cat >"$test_dir/curl" <<'EOF'
#!/bin/bash
set -euo pipefail
for argument in "$@"; do
    if [[ "$argument" == *'Bearer '* ]]; then
        printf 'token leaked into curl argv\n' >&2
        exit 1
    fi
done
url="${!#}"
case "$url" in
    */app-manifests/good-code/conversions)
        printf '%s\n' '{"id":12345,"slug":"thelarklanlabs-bot-review-quorum","pem":"-----BEGIN RSA PRIVATE KEY-----\nfake\n-----END RSA PRIVATE KEY-----\n","client_secret":"client-secret-value","webhook_secret":"webhook-secret-value"}'
        ;;
    */app/installations)
        grep -q '^Authorization: Bearer ' || exit 1
        printf '%s\n' '[{"id":111,"account":{"login":"someone-else"}},{"id":222,"account":{"login":"thelarklanlabs"}}]'
        ;;
    *)
        exit 22
        ;;
esac
EOF
chmod +x "$test_dir/curl"

run_app() {
    env PR_REVIEW_CONFIG_DIR="$config_dir" CREATE_APP_CURL_BIN="$test_dir/curl" "$create_app" "$@"
}

# form: an HTML page that posts the manifest to the organization.
run_app form --org thelarklanlabs --out "$test_dir/form.html" >/dev/null
grep -Fq 'action="https://github.com/organizations/thelarklanlabs/settings/apps/new"' "$test_dir/form.html" ||
    fail "form does not post to the organization"
grep -Fq '&quot;checks&quot;:&quot;write&quot;' "$test_dir/form.html" ||
    fail "manifest was not HTML-escaped into the form"
if run_app form --org 'bad org' --out "$test_dir/bad.html" >/dev/null 2>&1; then
    fail "unsafe organization name was accepted"
fi

# exchange: store only the key, with mode 600, and print no secrets.
run_app exchange --code good-code >"$test_dir/exchange.out"
key_file="$config_dir/thelarklanlabs-bot-review-quorum.pem"
[[ -f "$key_file" ]] || fail "private key was not saved"
[[ "$(stat -c %a "$key_file")" == 600 ]] || fail "private key mode is not 600"
grep -Fq 'BEGIN RSA PRIVATE KEY' "$key_file" || fail "private key content is wrong"
grep -Fq 'App ID: 12345' "$test_dir/exchange.out" || fail "App ID was not printed"
if grep -Eq 'BEGIN|client-secret-value|webhook-secret-value' "$test_dir/exchange.out"; then
    fail "exchange printed a secret"
fi
if run_app exchange --code bad-code >/dev/null 2>&1; then
    fail "rejected code was reported as success"
fi
if run_app exchange --code 'x;y' >/dev/null 2>&1; then
    fail "unsafe code was accepted"
fi

# installation: sign a JWT and select the installation for the organization.
real_key="$test_dir/app.pem"
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$real_key" 2>/dev/null
chmod 600 "$real_key"
installation_id=$(run_app installation --org thelarklanlabs --app-id 12345 --key "$real_key")
[[ "$installation_id" == 222 ]] || fail "wrong installation ID: $installation_id"
if run_app installation --org missing-org --app-id 12345 --key "$real_key" >/dev/null 2>&1; then
    fail "missing installation was reported as success"
fi

# config: a private env file for bin/pr-review-quorum.
printf '%s\n' '{"thelarklanlabs/example":{"auto_merge":false}}' >"$config_dir/repo-policy.json"
chmod 600 "$config_dir/repo-policy.json"
run_app config --org thelarklanlabs --app-id 12345 --installation-id 222 \
    --key "$real_key" --repository-owner-ids 323226749 >/dev/null
env_file="$config_dir/thelarklanlabs.env"
[[ "$(stat -c %a "$env_file")" == 600 ]] || fail "config mode is not 600"
for expected in QUORUM_APP_ID=12345 QUORUM_INSTALLATION_ID=222 QUORUM_OWNER_ID=166922787 \
    QUORUM_REPOSITORY_OWNER_IDS=323226749 QUORUM_BOT_IDS=270192887,104110997,320627233; do
    grep -Fxq "$expected" "$env_file" || fail "config is missing $expected"
done
if run_app config --org thelarklanlabs --app-id 12345 --installation-id 222 \
    --key "$real_key" >/dev/null 2>&1; then
    fail "config without repository owner IDs was accepted"
fi

printf 'create-app tests passed\n'
