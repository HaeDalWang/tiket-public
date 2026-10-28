#!/usr/bin/env bash
# Behavioral tests for billing-api.sh
#
# Behaviors covered (DRC-BILLING-WRAPPER):
#   1. env precedence    -- BILLING_API_KEY env wins over conf value
#   2. conf fallback      -- env unset => key read from credential-broker.conf
#   3. fail-closed        -- neither env nor conf => non-zero exit, stderr mentions
#                            credential-broker.conf, and the key value never leaks
#   4. base-URL prepend   -- /api/foo resolves to https://billing.example.com/api/foo
#   5. URL passthrough    -- a full https URL is passed through unchanged
#   6. METHOD allowlist   -- an unknown verb (DELETE) is rejected before any curl call
#
# Stubbing model:
#   - HOME override per case isolates the conf-file location
#   - A fake `curl` on PATH writes its received args to a capture file and prints
#     a canned JSON body, so the wrapper runs fully offline (no real network).
#
# Exit 0 only when all cases pass.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${REPO_ROOT}/skills/aws-customer-account-ops/billing-api.sh"

if [[ ! -f "$SCRIPT" ]]; then
    echo "FAIL: ${SCRIPT} missing" >&2
    exit 1
fi

# Shell prerequisite checks
for tool in bash mktemp; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "SKIP: missing prerequisite: ${tool}" >&2
        exit 0
    fi
done

# -- Scratch directory --------------------------------------------------------
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

failures=0

# A unique sentinel that must NEVER appear in the wrapper's stdout/stderr.
# Used to prove the resolved key value is not echoed anywhere.
ENV_KEY="ENVKEY-do-not-leak-1111"
CONF_KEY="CONFKEY-do-not-leak-2222"

# -- Helpers ------------------------------------------------------------------

# make_fake_curl <bin_dir> <capture_file>
# Creates a fake `curl` executable that records its argv (one arg per line) to
# the capture file and prints a canned JSON body to stdout. Never touches the
# network. Returns the bin dir to prepend to PATH.
make_fake_curl() {
    local bin_dir="$1"
    local capture_file="$2"
    mkdir -p "$bin_dir"
    cat > "${bin_dir}/curl" <<CURL
#!/usr/bin/env bash
# Fake curl: record argv, print canned JSON, never hit the network.
: > "${capture_file}"
for a in "\$@"; do
    printf '%s\n' "\$a" >> "${capture_file}"
done
printf '%s\n' '{"header":{"code":200,"message":"success"},"body":[]}'
exit 0
CURL
    chmod +x "${bin_dir}/curl"
}

# write_conf <home_dir> <key_value>
# Writes a synthetic credential-broker.conf with a BILLING_API_KEY line plus a
# couple of unrelated lines (comment + other key) to exercise the parser.
write_conf() {
    local home_dir="$1"
    local key_value="$2"
    local conf_dir="${home_dir}/.config/msp"
    mkdir -p "$conf_dir"
    cat > "${conf_dir}/credential-broker.conf" <<CONF
# MSP Credential Broker config
API_URL=https://example.execute-api.ap-northeast-2.amazonaws.com/Prod/v1/credentials
CLIENT_ID=some-client-id
BILLING_API_KEY=${key_value}
CONF
    chmod 600 "${conf_dir}/credential-broker.conf"
}

# -- Test Cases ---------------------------------------------------------------

run_case1() {
    local case_dir="${WORK_DIR}/case1"
    mkdir -p "$case_dir"
    local label="env precedence: env key wins over conf key"

    (
        export HOME="$case_dir"
        local bin_dir="${case_dir}/bin"
        local capture="${case_dir}/curl.args"
        make_fake_curl "$bin_dir" "$capture"
        write_conf "$case_dir" "$CONF_KEY"
        export PATH="${bin_dir}:${PATH}"
        export BILLING_API_KEY="$ENV_KEY"

        local out
        out="$(bash "$SCRIPT" GET /api/admin/v1/companies 2>"${case_dir}/stderr.txt")"
        local rc=$?

        if [[ $rc -ne 0 ]]; then
            echo "FAIL: ${label} -- exit ${rc}, expected 0" >&2
            cat "${case_dir}/stderr.txt" >&2
            exit 1
        fi

        # The curl args must carry the ENV key in the Bearer header, not the conf key.
        if ! grep -q "Bearer ${ENV_KEY}" "$capture"; then
            echo "FAIL: ${label} -- env key not used in Authorization header" >&2
            exit 1
        fi
        if grep -q "$CONF_KEY" "$capture"; then
            echo "FAIL: ${label} -- conf key used despite env being set" >&2
            exit 1
        fi

        # The key value must never leak to stdout.
        if printf '%s' "$out" | grep -q "$ENV_KEY"; then
            echo "FAIL: ${label} -- key value leaked to stdout" >&2
            exit 1
        fi

        echo "PASS: ${label}"
    ) || return 1
    return 0
}

run_case2() {
    local case_dir="${WORK_DIR}/case2"
    mkdir -p "$case_dir"
    local label="conf fallback: env unset => key read from conf"

    (
        export HOME="$case_dir"
        local bin_dir="${case_dir}/bin"
        local capture="${case_dir}/curl.args"
        make_fake_curl "$bin_dir" "$capture"
        write_conf "$case_dir" "$CONF_KEY"
        export PATH="${bin_dir}:${PATH}"
        unset BILLING_API_KEY

        local out
        out="$(bash "$SCRIPT" GET /api/admin/v1/companies 2>"${case_dir}/stderr.txt")"
        local rc=$?

        if [[ $rc -ne 0 ]]; then
            echo "FAIL: ${label} -- exit ${rc}, expected 0" >&2
            cat "${case_dir}/stderr.txt" >&2
            exit 1
        fi

        if ! grep -q "Bearer ${CONF_KEY}" "$capture"; then
            echo "FAIL: ${label} -- conf key not used in Authorization header" >&2
            exit 1
        fi

        if printf '%s' "$out" | grep -q "$CONF_KEY"; then
            echo "FAIL: ${label} -- key value leaked to stdout" >&2
            exit 1
        fi

        echo "PASS: ${label}"
    ) || return 1
    return 0
}

run_case3() {
    local case_dir="${WORK_DIR}/case3"
    mkdir -p "$case_dir"
    local label="fail-closed: no env, no conf => non-zero exit + remediation, no leak"

    (
        export HOME="$case_dir"
        local bin_dir="${case_dir}/bin"
        local capture="${case_dir}/curl.args"
        make_fake_curl "$bin_dir" "$capture"
        # No conf file written at all.
        export PATH="${bin_dir}:${PATH}"
        unset BILLING_API_KEY

        local stderr_file="${case_dir}/stderr.txt"
        local stdout_file="${case_dir}/stdout.txt"
        set +e
        bash "$SCRIPT" GET /api/admin/v1/companies >"$stdout_file" 2>"$stderr_file"
        local rc=$?
        set -e

        if [[ $rc -eq 0 ]]; then
            echo "FAIL: ${label} -- expected non-zero exit, got 0" >&2
            exit 1
        fi

        if ! grep -q 'credential-broker.conf' "$stderr_file"; then
            echo "FAIL: ${label} -- stderr does not mention credential-broker.conf" >&2
            echo "  stderr was: $(cat "$stderr_file")" >&2
            exit 1
        fi

        # curl must never have run in the fail-closed path.
        if [[ -s "$capture" ]]; then
            echo "FAIL: ${label} -- curl was invoked despite fail-closed" >&2
            exit 1
        fi

        echo "PASS: ${label}"
    ) || return 1
    return 0
}

run_case4() {
    local case_dir="${WORK_DIR}/case4"
    mkdir -p "$case_dir"
    local label="base-URL prepend: /api/foo => https://billing.example.com/api/foo"

    (
        export HOME="$case_dir"
        local bin_dir="${case_dir}/bin"
        local capture="${case_dir}/curl.args"
        make_fake_curl "$bin_dir" "$capture"
        write_conf "$case_dir" "$CONF_KEY"
        export PATH="${bin_dir}:${PATH}"
        unset BILLING_API_KEY

        bash "$SCRIPT" GET /api/foo >/dev/null 2>"${case_dir}/stderr.txt" || {
            echo "FAIL: ${label} -- non-zero exit" >&2
            cat "${case_dir}/stderr.txt" >&2
            exit 1
        }

        if ! grep -qx 'https://billing.example.com/api/foo' "$capture"; then
            echo "FAIL: ${label} -- resolved URL not found in curl args" >&2
            echo "  capture was:" >&2
            cat "$capture" >&2
            exit 1
        fi

        echo "PASS: ${label}"
    ) || return 1
    return 0
}

run_case5() {
    local case_dir="${WORK_DIR}/case5"
    mkdir -p "$case_dir"
    local label="URL passthrough: full https URL passed through unchanged"

    (
        export HOME="$case_dir"
        local bin_dir="${case_dir}/bin"
        local capture="${case_dir}/curl.args"
        make_fake_curl "$bin_dir" "$capture"
        write_conf "$case_dir" "$CONF_KEY"
        export PATH="${bin_dir}:${PATH}"
        unset BILLING_API_KEY

        bash "$SCRIPT" GET "https://billing.example.com/x" >/dev/null 2>"${case_dir}/stderr.txt" || {
            echo "FAIL: ${label} -- non-zero exit" >&2
            cat "${case_dir}/stderr.txt" >&2
            exit 1
        }

        if ! grep -qx 'https://billing.example.com/x' "$capture"; then
            echo "FAIL: ${label} -- full URL not passed through unchanged" >&2
            echo "  capture was:" >&2
            cat "$capture" >&2
            exit 1
        fi
        # The base URL must NOT have been prepended.
        if grep -q 'billing.example.com/https' "$capture"; then
            echo "FAIL: ${label} -- base URL wrongly prepended to full URL" >&2
            exit 1
        fi

        echo "PASS: ${label}"
    ) || return 1
    return 0
}

run_case6() {
    local case_dir="${WORK_DIR}/case6"
    mkdir -p "$case_dir"
    local label="METHOD allowlist: DELETE rejected before any curl call"

    (
        export HOME="$case_dir"
        local bin_dir="${case_dir}/bin"
        local capture="${case_dir}/curl.args"
        make_fake_curl "$bin_dir" "$capture"
        write_conf "$case_dir" "$CONF_KEY"
        export PATH="${bin_dir}:${PATH}"
        export BILLING_API_KEY="$ENV_KEY"

        set +e
        bash "$SCRIPT" DELETE /api/foo >/dev/null 2>"${case_dir}/stderr.txt"
        local rc=$?
        set -e

        if [[ $rc -eq 0 ]]; then
            echo "FAIL: ${label} -- DELETE accepted (expected non-zero exit)" >&2
            exit 1
        fi

        # curl must not have run for a rejected method.
        if [[ -s "$capture" ]]; then
            echo "FAIL: ${label} -- curl invoked despite rejected METHOD" >&2
            exit 1
        fi

        echo "PASS: ${label}"
    ) || return 1
    return 0
}

# -- Runner -------------------------------------------------------------------

echo "=== billing-api.sh behavioral tests (DRC-BILLING-WRAPPER) ==="
echo ""

run_case1 || failures=$((failures + 1))
run_case2 || failures=$((failures + 1))
run_case3 || failures=$((failures + 1))
run_case4 || failures=$((failures + 1))
run_case5 || failures=$((failures + 1))
run_case6 || failures=$((failures + 1))

rejected_targets=(
    'http://billing.example.com/api/foo'
    'https://other.example/x'
    'https://billing.example.com.evil.example/x'
    'https://billing.example.com@evil.example/x'
    'https://user@billing.example.com/x'
    'https://billing.example.com:444/x'
    '//evil.example/x'
    'https://billing.example.com\@evil.example/x'
    $'https://billing.example.com\n.evil.example/x'
)
case_number=6
for target in "${rejected_targets[@]}"; do
    case_number=$((case_number + 1))
    case_dir="${WORK_DIR}/case${case_number}"
    mkdir -p "$case_dir"
    make_fake_curl "${case_dir}/bin" "${case_dir}/curl.args"
    if PATH="${case_dir}/bin:${PATH}" BILLING_API_KEY="$ENV_KEY" \
        bash "$SCRIPT" GET "$target" >"${case_dir}/stdout" 2>"${case_dir}/stderr"; then
        echo "FAIL: destination guard case ${case_number} accepted unsafe target"
        failures=$((failures + 1))
    elif [[ -s "${case_dir}/curl.args" ]] || grep -q "$ENV_KEY" "${case_dir}/stdout" "${case_dir}/stderr"; then
        echo "FAIL: destination guard case ${case_number} sent or exposed the key"
        failures=$((failures + 1))
    else
        echo "PASS: destination guard case ${case_number} rejects before transport"
    fi
done

echo ""
if [[ $failures -gt 0 ]]; then
    echo "RESULT: ${failures} case(s) FAILED (out of ${case_number})"
    exit 1
fi
echo "RESULT: all ${case_number} cases PASS"
exit 0
