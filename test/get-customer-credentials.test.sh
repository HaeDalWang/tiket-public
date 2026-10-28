#!/usr/bin/env bash
# Phase 18 -- get-customer-credentials.sh (thin Bearer HTTP credential_process) tests
#
# Requirements covered (18-VALIDATION anchor invariants):
#   CLI-01: emits exactly the 5-key credential_process contract
#           {Version:1,AccessKeyId,SecretAccessKey,SessionToken,Expiration}
#           (BrokerVersion projected out) from the broker HTTP response.
#   CLI-01: NO local `aws sts assume-role` is ever invoked (stub aws asserts this).
#   CLI-02: customer-creds cache key is <account-id>.json (no role segment).
#   CLI-01: cache HIT short-circuits before any curl call.
#   CLI-01/03 (invariant 5): missing/empty Bearer -> non-zero exit in <2s,
#           no browser/OAuth, stderr points at get-sts-token.
#   RES-02: broker error body {"error":...} -> non-zero exit surfacing the message.
#
# Stubbing model (mirrors cleanup.test.sh):
#   - HOME override per case isolates filesystem state (conf + sts-token + cache).
#   - Stub `curl` on PATH records invocations and emits a canned broker body
#     (never touches the network).
#   - Stub `aws` on PATH records a marker if ever called with `assume-role`,
#     proving the no-local-assume invariant.
#   - Seeded sts-token.json is IDENTITY-ONLY (SlackAccessToken + SlackUserId),
#     never an AWS session.
#
# Exit 0 only when all cases pass. This test is RED until the script is rewritten.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${REPO_ROOT}/skills/aws-customer-account-ops/get-customer-credentials.sh"

if [[ ! -f "$SCRIPT" ]]; then
    echo "FAIL: ${SCRIPT} missing" >&2
    exit 1
fi

for tool in bash jq mktemp; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "SKIP: missing prerequisite: ${tool}" >&2
        exit 0
    fi
done

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

failures=0

# -- Cross-platform future/past ISO-8601 timestamp -----------------------------
future_ts() {
    date -u -d "1 hour" +"%Y-%m-%dT%H:%M:%S.000Z" 2>/dev/null \
        || date -u -v+1H +"%Y-%m-%dT%H:%M:%S.000Z" 2>/dev/null
}

past_ts() {
    date -u -d "-2 hours" +"%Y-%m-%dT%H:%M:%S.000Z" 2>/dev/null \
        || date -u -v-2H +"%Y-%m-%dT%H:%M:%S.000Z" 2>/dev/null
}

# -- Stub PATH: fake curl + fake aws -------------------------------------------
# The stubs read $HOME at runtime, so per-case HOME redirection scopes their
# marker/response files. STUB_DIR is prepended to PATH; real jq/date/mktemp/sed
# still resolve from the rest of PATH.
STUB_DIR="${WORK_DIR}/stubs"
mkdir -p "$STUB_DIR"

cat > "${STUB_DIR}/curl" <<'CURLSTUB'
#!/usr/bin/env bash
# Test stub for curl: honor `-o <file>` and `-w '%{http_code}'` (the new client
# captures the status via -w and writes the body via -o), record the invocation,
# and emit the SEEDED HTTP status code on stdout — mirroring the real curl.
# Never touches the network.
mkdir -p "${HOME}/.stub"
printf 'called\n' >> "${HOME}/.stub/curl_calls"
# ADDITIVE (#50): optional per-call latency, so parallel callers genuinely overlap
# the in-flight POST. Absent file => no sleep => every earlier case is unchanged.
[[ -f "${HOME}/.stub/delay" ]] && sleep "$(cat "${HOME}/.stub/delay")"

# ADDITIVE argv/stdin recorders (WR-01). Two NEW files, `curl_argv` and
# `curl_stdin`; `curl_calls` is untouched because its LINE COUNT is the 1-based
# call index both curl_call_count and the status_seq branch below depend on.
# One line per invocation, built by walking "$@" rather than "$*" so the record
# never depends on IFS.
printf '%s ' "$@" >> "${HOME}/.stub/curl_argv"
printf '\n'      >> "${HOME}/.stub/curl_argv"

out_file=""
want_code=0
want_stdin=0
prev=""
for arg in "$@"; do
    case "$prev" in
        -o) out_file="$arg" ;;
        -w) [[ "$arg" == *'%{http_code}'* ]] && want_code=1 ;;
        -d) printf '%s' "$arg" > "${HOME}/.stub/last_body.json" ;;  # capture the POST body ({accountId,agent})
        -K) [[ "$arg" == "-" ]] && want_stdin=1 ;;  # the client feeds a config stanza on stdin
    esac
    prev="$arg"
done

# Drain the config stanza BEFORE any status branch (including the 000 early
# exit), so the record exists on every path. GATED on the flag on purpose: an
# unconditional read blocks forever when the stub inherits a TTY from a caller
# that passed no config file (the ~120s suite hang the file header records).
if [[ "$want_stdin" == "1" ]]; then
    cat >> "${HOME}/.stub/curl_stdin"
fi

# Status code to emit (default 200). A per-case `.stub/status` seed overrides it.
# "000" simulates a transport failure: curl writes no body and exits non-zero,
# so the client's `|| HTTP_CODE=000` branch fires (retryable connect-fail class).
status="200"
if [[ -f "${HOME}/.stub/status" ]]; then
    status=$(cat "${HOME}/.stub/status")
fi

# ADDITIVE per-call status sequence (SCP-05 / D-01). Wholly gated on
# ${HOME}/.stub/status_seq, and NO case that predates it creates that file, so
# every pre-existing case sees a byte-identical stub. It exists because there is
# otherwise no way to express "the broker was down and then came back INSIDE ONE
# INVOCATION" -- and that is the only fixture that can tell "one window record
# per invocation" apart from "one window record per HTTP call". Those two
# readings of D-01 differ by 3x on exactly the failure pattern the brake exists
# to catch. The call index is 1-based because the `called` line above is appended
# BEFORE this point; past the end of the sequence the last code repeats.
if [[ -f "${HOME}/.stub/status_seq" ]]; then
    seq_idx=$(wc -l < "${HOME}/.stub/curl_calls" | tr -d ' ')
    seq_code=$(sed -n "${seq_idx}p" "${HOME}/.stub/status_seq")
    [[ -z "$seq_code" ]] && seq_code=$(tail -n 1 "${HOME}/.stub/status_seq")
    [[ -n "$seq_code" ]] && status="$seq_code"
fi

if [[ "$status" == "000" ]]; then
    # Real curl writes its transport diagnosis to stderr and exits non-zero. The
    # client redirects that stream to $CURL_ERR and prints its first line on the
    # final failure, so a stub that stays silent makes the printed tail render
    # EMPTY -- and a case asserting only "the marker is present" would then pass
    # against a client that had lost the diagnostic entirely. Only the transport
    # branch writes here, and no case that predates it seeds this status, so
    # every pre-existing case still sees a byte-identical stub.
    printf 'curl: (7) Failed to connect to broker.invalid port 443 after 0 ms: Could not connect to server\n' >&2
    exit 7
fi

# Write the response body to the -o target (real curl -o writes to the file, not stdout).
if [[ -n "$out_file" && -f "${HOME}/.stub/resp.json" ]]; then
    cat "${HOME}/.stub/resp.json" > "$out_file"
elif [[ -f "${HOME}/.stub/resp.json" ]]; then
    cat "${HOME}/.stub/resp.json"
fi

# Emit exactly what -w '%{http_code}' would print (the client reads this as HTTP_CODE).
[[ "$want_code" == "1" ]] && printf '%s' "$status"
exit 0
CURLSTUB
chmod +x "${STUB_DIR}/curl"

cat > "${STUB_DIR}/aws" <<'AWSSTUB'
#!/usr/bin/env bash
# Test stub for aws: FAIL LOUDLY if ever asked to assume-role (no-local-assume).
#
# `configure` is DELEGATED to the REAL CLI when one is available (its absolute
# path is frozen into `real-aws-path` beside this stub at harness-build time).
# Reason: the HOOK-B/STDOUT cases drive the auto-migration that now runs on the
# credential_process path, and migration is pure ~/.aws/config manipulation. A
# stub that exits 0 with empty output for every `configure` verb makes EVERY
# fixture look like a machine with zero profiles, so the ordering and
# stdout-purity assertions would pass while proving nothing -- the same
# reasoning test/fleet-migrate.test.sh:29-38 records for running against the
# real binary. Everything else (notably assume-role) stays stubbed, so the
# no-local-assume invariant is unchanged.
mkdir -p "${HOME}/.stub"
printf '%s\n' "$*" >> "${HOME}/.stub/aws_calls"
if printf '%s' "$*" | grep -q 'assume-role'; then
    printf 'ASSUME_CALLED: %s\n' "$*" >> "${HOME}/.stub/aws_assume"
    exit 99
fi
if [[ "${1:-}" == "configure" ]]; then
    _stub_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    _real_aws=""
    [[ -s "${_stub_dir}/real-aws-path" ]] && _real_aws="$(cat "${_stub_dir}/real-aws-path")"
    if [[ -n "$_real_aws" && -x "$_real_aws" ]]; then
        exec "$_real_aws" "$@"
    fi
fi
exit 0
AWSSTUB
chmod +x "${STUB_DIR}/aws"

# Absolute path of the real CLI, resolved BEFORE the stub dir is on PATH so this
# never resolves back to the stub itself. Empty when the CLI is absent, in which
# case the stub keeps its historic exit-0 behaviour and the migration cases SKIP.
REAL_AWS="$(command -v aws 2>/dev/null || printf '')"
printf '%s' "$REAL_AWS" > "${STUB_DIR}/real-aws-path"

# HOME isolation is only airtight while no AWS_* override redirects the CLI:
# AWS_CONFIG_FILE / AWS_SHARED_CREDENTIALS_FILE would make the delegated
# `aws configure set` write into the DEVELOPER'S REAL config despite the HOME
# override (same guard as test/fleet-migrate.test.sh).
unset AWS_CONFIG_FILE AWS_SHARED_CREDENTIALS_FILE AWS_PROFILE AWS_DEFAULT_PROFILE

# require_real_aws <label> -- SKIP guard for the cases that drive a real rename.
require_real_aws() {
    if [[ -z "$REAL_AWS" ]]; then
        echo "SKIP: $1 -- real 'aws' CLI not installed" >&2
        return 1
    fi
    return 0
}

# -- Per-case environment seeding ----------------------------------------------
# seed_env <home> <bearer>  (empty bearer => identity-only, no SlackAccessToken)
seed_env() {
    local home="$1"
    local bearer="$2"
    mkdir -p "${home}/.config/msp" "${home}/.cache/msp/customer-creds"
    cat > "${home}/.config/msp/credential-broker.conf" <<CONF
API_URL=https://example.execute-api.ap-northeast-2.amazonaws.com/Prod/v1/credentials
CLIENT_ID=test-client-id
CONF
    if [[ -n "$bearer" ]]; then
        cat > "${home}/.cache/msp/sts-token.json" <<TOK
{"Version":1,"Expiration":"$(future_ts)","BrokerVersion":"1.3.0","SlackAccessToken":"${bearer}","SlackUserId":"U0TESTUSER"}
TOK
    else
        # Identity-only WITHOUT a Bearer (login expired / never happened).
        cat > "${home}/.cache/msp/sts-token.json" <<TOK
{"Version":1,"Expiration":"$(future_ts)","BrokerVersion":"1.3.0","SlackUserId":"U0TESTUSER"}
TOK
    fi
    chmod 600 "${home}/.cache/msp/sts-token.json"
}

# seed_broker_ok <home>  -- 6-key success body (incl. BrokerVersion to be projected out)
seed_broker_ok() {
    local home="$1"
    mkdir -p "${home}/.stub"
    cat > "${home}/.stub/resp.json" <<RESP
{"Version":1,"AccessKeyId":"ASIAEXAMPLE","SecretAccessKey":"wJalrExampleKey","SessionToken":"FQoGExampleToken","Expiration":"$(future_ts)","BrokerVersion":"1.3.0"}
RESP
}

# seed_broker_err <home>  -- 403/400 structured error body
seed_broker_err() {
    local home="$1"
    mkdir -p "${home}/.stub"
    printf '%s\n' '{"error":"account 111111111111 is not authorized"}' > "${home}/.stub/resp.json"
}

# seed_status <home> <code>  -- HTTP status the curl stub emits (default 200 if unset).
# "000" simulates a transport/connect failure (curl exits non-zero, no body).
seed_status() {
    local home="$1"
    local code="$2"
    mkdir -p "${home}/.stub"
    printf '%s' "$code" > "${home}/.stub/status"
}

# seed_status_seq <home> <code>...  -- the HTTP status the curl stub emits on the
# 1st, 2nd, 3rd ... call of a SINGLE invocation; the last code repeats once the
# sequence is exhausted. `seed_status_seq "$d" 503 503 200` is the broker-came-
# back-mid-invocation fixture D-01's counting unit is measured against.
seed_status_seq() {
    local home="$1"
    shift
    local code
    mkdir -p "${home}/.stub"
    : > "${home}/.stub/status_seq"
    for code in "$@"; do
        printf '%s\n' "$code" >> "${home}/.stub/status_seq"
    done
}

curl_call_count() {
    local home="$1"
    [[ -f "${home}/.stub/curl_calls" ]] && wc -l < "${home}/.stub/curl_calls" | tr -d ' ' || printf '0'
}

# -- SCP-05 scope-brake fixtures (D-01/D-02/D-06/D-17) --------------------------
# The brake reads two append-only .jsonl files under
# ~/.cache/msp/customer-creds. Everything below seeds or counts those files;
# no case reaches into the client's internals.

# scope_acct <leading-digit> <n>  -- a deterministic 12-digit account id.
#   scope_acct 5 1  -> 500000000001
# Blocks: 5... = window/unapproved, 6... = accounts that get acked, 9... = the
# deliberately out-of-set account. No case hand-types a 12-digit literal: the
# client rejects a non-12-digit --account-id at its input gate long before the
# brake runs, so a miscounted digit would make a case assert nothing at all while
# still reporting PASS.
scope_acct() {
    printf '%s%011d' "$1" "$2"
}

# seed_scope_window <home> <age_seconds> <account_id>...
# Appends one {"ts":<now-age>,"accountId":"<id>"} line per id, i.e. exactly what
# scope_window_append writes. The age is RELATIVE so a case can straddle the
# 300-second cutoff without knowing the wall clock.
seed_scope_window() {
    local home="$1" age="$2"
    shift 2
    local now id
    mkdir -p "${home}/.cache/msp/customer-creds"
    now=$(date -u +%s)
    for id in "$@"; do
        printf '{"ts":%s,"accountId":"%s"}\n' "$((now - age))" "$id" \
            >> "${home}/.cache/msp/customer-creds/scope-window.jsonl"
    done
}

# seed_scope_ack <home> <ttl_offset_seconds> <account_id>...
# One {"ts":..,"expiresAt":..,"accountIds":[..],"count":N} line. A NEGATIVE
# offset is the expired-ack fixture. The array is built with printf and a loop,
# never with jq: this record has to be byte-shaped exactly like do_scope_ack's
# own output, and a `jq -c` array would look identical to a reader while being
# one more way for the fixture to drift from the producer it stands in for.
seed_scope_ack() {
    local home="$1" offset="$2"
    shift 2
    local now id ids_json="" n=0
    mkdir -p "${home}/.cache/msp/customer-creds"
    now=$(date -u +%s)
    for id in "$@"; do
        if [[ -z "$ids_json" ]]; then
            ids_json="\"${id}\""
        else
            ids_json="${ids_json},\"${id}\""
        fi
        n=$((n + 1))
    done
    printf '{"ts":%s,"expiresAt":%s,"accountIds":[%s],"count":%s}\n' \
        "$now" "$((now + offset))" "$ids_json" "$n" \
        >> "${home}/.cache/msp/customer-creds/scope-acks.jsonl"
}

# scope_window_lines <home>   -- window record count ("0" when the file is absent,
# which is the fresh-machine path). Same shape as curl_call_count above.
scope_window_lines() {
    local f="${1}/.cache/msp/customer-creds/scope-window.jsonl"
    [[ -f "$f" ]] && wc -l < "$f" | tr -d ' ' || printf '0'
}

# scope_window_distinct <home> -- distinct accountIds present in the window file.
# `wc -l` rather than `grep -c .`: grep -c exits 1 on zero matches, which would
# flip the `||` branch and print "00" on precisely the fresh-machine path.
scope_window_distinct() {
    local f="${1}/.cache/msp/customer-creds/scope-window.jsonl"
    local n
    [[ -f "$f" ]] || { printf '0'; return 0; }
    n=$(grep -oE '"accountId":"[0-9]{12}"' "$f" 2>/dev/null | sort -u | wc -l | tr -d ' ')
    printf '%s' "${n:-0}"
}

# scope_window_has <home> <account_id> -- 0 when the id appears in the window file.
scope_window_has() {
    grep -Fq "\"accountId\":\"${2}\"" \
        "${1}/.cache/msp/customer-creds/scope-window.jsonl" 2>/dev/null
}

# run_cred_watchdog <dir> <account_id> <max_deciseconds>
# The single invocation driver every scope case uses. Runs the client with
# stdout/stderr captured under <dir> and prints the recorded exit status, or
# "124" if the budget expired. Three properties, each load-bearing:
#
#  1. `</dev/null` is the NO-TTY ASSERTION (T-24-06), not a convenience. The
#     header of this file records a prior ~120-second agent hang caused by a
#     prompt on this path; every scope case runs with stdin closed so a `read`
#     reintroduced anywhere in the brake hangs the watchdog -- and fails the case
#     at the budget -- instead of silently blocking a human.
#  2. The poll watches for a MARKER FILE, never `kill -0 "$pid"`. A finished
#     background child stays visible to `kill -0` until it is reaped, so a
#     kill -0 loop reports "still running" for a process that has already exited:
#     a timing assertion that can only ever pass late.
#  3. `sleep 0.1` plus a decisecond budget, never timeout(1). GNU timeout is not
#     installed on a stock macOS and this repo's suites run on both platforms;
#     `sleep` accepts fractions on BSD and GNU alike.
run_cred_watchdog() {
    local dir="$1" acct="$2" budget="$3"
    local rc_file="${dir}/rc"
    local pid i rc
    mkdir -p "$dir"
    rm -f "$rc_file" "${rc_file}.tmp"
    (
        PATH="${STUB_DIR}:${PATH}" bash "$SCRIPT" --account-id "$acct" --agent claude-code \
            >"${dir}/stdout.json" 2>"${dir}/stderr.txt" </dev/null
        _wrc=$?
        printf '%s' "$_wrc" > "${rc_file}.tmp"
        mv -f "${rc_file}.tmp" "$rc_file"
    ) &
    pid=$!
    i=0
    while [[ $i -lt $budget ]]; do
        [[ -f "$rc_file" ]] && break
        sleep 0.1
        i=$((i + 1))
    done
    if [[ ! -f "$rc_file" ]]; then
        kill -9 "$pid" 2>/dev/null
        wait "$pid" 2>/dev/null
        printf '124'
        return 0
    fi
    wait "$pid" 2>/dev/null
    rc=$(cat "$rc_file" 2>/dev/null)
    printf '%s' "${rc:-124}"
}

# broker_agent <home> -- the `agent` value the client POSTed to the broker
# (extracted from the curl stub's captured request body). Empty if never sent.
broker_agent() {
    local home="$1"
    [[ -f "${home}/.stub/last_body.json" ]] \
        && jq -r '.agent // empty' "${home}/.stub/last_body.json" 2>/dev/null \
        || printf ''
}

# broker_client_version <home> -- the `clientVersion` value the client POSTed to
# the broker (ERR-10 spread-observation field), read out of the same captured
# request body as broker_agent. Empty if never sent.
broker_client_version() {
    local home="$1"
    [[ -f "${home}/.stub/last_body.json" ]] \
        && jq -r '.clientVersion // empty' "${home}/.stub/last_body.json" 2>/dev/null \
        || printf ''
}

# seed_run_assert_agent <dir> <label> <expected_agent> <script_path> [cli-args...]
# Shared driver for the agent-resolution priority cases (T-agent-*). The CALLER
# exports (or unsets) MSP_AGENT/AI_AGENT/CLAUDECODE in its subshell first;
# this seeds a valid Bearer + a 200 broker body, runs the script, and asserts the
# `agent` field the client POSTed to the broker (captured by the curl stub).
seed_run_assert_agent() {
    local d="$1" label="$2" expected="$3" script_path="$4"; shift 4
    seed_env "$d" "xoxp-test-bearer-value"
    seed_broker_ok "$d"

    PATH="${STUB_DIR}:${PATH}" bash "$script_path" --account-id 111111111111 "$@" \
        >/dev/null 2>"${d}/stderr.txt"
    local rc=$?
    if [[ $rc -ne 0 ]]; then
        echo "FAIL: ${label} -- exit ${rc}, expected 0; stderr: $(cat "${d}/stderr.txt")" >&2
        return 1
    fi

    local got; got=$(broker_agent "$d")
    if [[ "$got" != "$expected" ]]; then
        echo "FAIL: ${label} -- broker was sent agent='${got}', expected '${expected}'" >&2
        return 1
    fi
    echo "PASS: ${label}"
    return 0
}

# -- Migration (HOOK-B / STDOUT) fixtures ---------------------------------------
# Fixture builders are DUPLICATED per suite in this repo by convention -- do NOT
# source them from test/fleet-migrate.test.sh.
#
# The account ids are deliberately distinct from the invocation's own
# 111111111111 so PROF-06's exclude-own-cache rule never masks what these cases
# assert.

# seed_legacy_config <home>
#   [profile stale-cust] -- legacy CSG (222222222222). Paired with an EXPIRED
#                           cache below, so `sweep_expired_profiles` removes it.
#   [profile samplecorp]     -- legacy CSG (333333333333), NO cache file, therefore
#                           protected from the sweep and MUST be migrated to
#                           `csg-samplecorp`.
#   [default]            -- SKIP_PROFILES, inviolable.
seed_legacy_config() {
    local home="$1"
    mkdir -p "${home}/.aws"
    cat > "${home}/.aws/config" <<'AWSCONF'
[profile stale-cust]
credential_process = /path/to/get-customer-credentials.sh --account-id 222222222222 --agent claude-code
region = ap-northeast-2

[profile samplecorp]
credential_process = /path/to/get-customer-credentials.sh --account-id 333333333333 --agent claude-code
region = ap-northeast-2

[default]
region = ap-northeast-2
AWSCONF
}

# seed_collision_config <home> -- class H: `acme` and `csg-acme` both exist, so
# the rename target is already taken (D-07). migrate reports a reason token,
# keeps the old section and carries on with the rest.
#
# The two sections MUST carry DIFFERENT account ids: the collision is detected by
# register's `account-mismatch` abort, and a same-account `csg-acme` is instead a
# legitimate idempotent re-registration (the old section is then simply removed,
# which is correct behaviour and would make this fixture prove nothing).
seed_collision_config() {
    local home="$1"
    mkdir -p "${home}/.aws"
    cat > "${home}/.aws/config" <<'AWSCONF'
[profile acme]
credential_process = /path/to/get-customer-credentials.sh --account-id 444444444444 --agent claude-code
region = ap-northeast-2

[profile csg-acme]
credential_process = /path/to/get-customer-credentials.sh --account-id 777777777777 --agent claude-code
csg_managed = 1.7.0
region = ap-northeast-2

[profile other]
credential_process = /path/to/get-customer-credentials.sh --account-id 888888888888 --agent claude-code
region = ap-northeast-2

[default]
region = ap-northeast-2
AWSCONF
}

# seed_bom_config <home> -- Pitfall 7: a UTF-8 BOM makes the FIRST header
# unparseable to `aws configure`, so migrate must fail closed. Built with printf,
# not a heredoc (test/credentials-guard.test.sh:26-29).
seed_bom_config() {
    local home="$1"
    mkdir -p "${home}/.aws"
    printf '\xEF\xBB\xBF[profile samplecorp]\ncredential_process = /path/to/get-customer-credentials.sh --account-id 333333333333 --agent claude-code\nregion = ap-northeast-2\n\n[default]\nregion = ap-northeast-2\n' \
        > "${home}/.aws/config"
}

# seed_expired_cache <home> <account_id> -- a cache that expired two hours ago.
seed_expired_cache() {
    local home="$1" acct="$2"
    mkdir -p "${home}/.cache/msp/customer-creds"
    cat > "${home}/.cache/msp/customer-creds/${acct}.json" <<CACHE
{"Version":1,"AccessKeyId":"ASIAEXPIRED","SecretAccessKey":"expired","SessionToken":"expired","Expiration":"$(past_ts)"}
CACHE
}

# seed_migration_marker <home> -- pre-record the completion marker so the hook
# must short-circuit (HOOK-B-02).
seed_migration_marker() {
    local home="$1"
    mkdir -p "${home}/.cache/msp/customer-creds"
    printf '{"id":"v1.7-csg-namespace","completed_at":"2026-01-01T00:00:00Z","renamed":0,"repaired":0,"skipped":0}\n' \
        > "${home}/.cache/msp/customer-creds/migrations.jsonl"
}

migration_marker_path() { printf '%s' "${1}/.cache/msp/customer-creds/migrations.jsonl"; }

# config_has_profile <home> <name> -- exact section-header match (case-sensitive).
config_has_profile() {
    grep -Fxq "[profile ${2}]" "${1}/.aws/config" 2>/dev/null
}

bak_count() {
    ls "${1}/.aws/"config.bak.* 2>/dev/null | wc -l | tr -d ' '
}

# seed_incident_config <home>
# The composite "incident machine": every migration class at once, so a single
# credential_process call exercises the whole destructive path while the stdout
# contract is under assertion. `samplecorp` deliberately carries the SAME account id
# as the invocation (D-06: the currently-in-use profile is rewritten too), which
# is the highest-risk shape for stdout purity.
seed_incident_config() {
    local home="$1"
    mkdir -p "${home}/.aws"
    cat > "${home}/.aws/config" <<'AWSCONF'
[profile samplecorp]
credential_process = /path/to/get-customer-credentials.sh --account-id 111111111111 --agent claude-code
region = ap-northeast-2

[profile example-dev]
csg_managed = 1.6.2
credential_process = /path/to/get-customer-credentials.sh --account-id 222222222222 --agent claude-code
region = ap-northeast-2

[profile csg-already]
csg_managed = 1.7.0
credential_process = /path/to/get-customer-credentials.sh --account-id 333333333333 --agent claude-code
region = ap-northeast-2

[profile poisoned-a]
sso_start_url = https://acme.awsapps.com/start
sso_region = ap-northeast-2
sso_account_id = 444444444444
sso_role_name = ReadOnlyAccess
csg_managed = 1.6.2
credential_process = /path/to/get-customer-credentials.sh --account-id 444444444444 --agent claude-code
region = ap-northeast-2

[profile my-role-chain]
source_profile = default
role_arn = arn:aws:iam::999999999999:role/MyPersonalRole
region = us-east-1

[sso-session corp]
sso_start_url = https://corp.awsapps.com/start
sso_region = ap-northeast-2
sso_registration_scopes = sso:account:access

[default]
region = ap-northeast-2

[profile csg-login]
credential_process = /path/to/get-sts-token.sh --agent claude-code
region = ap-northeast-2
AWSCONF
}

# assert_stdout_is_only_json <file> <label>
# STRICTER than assert_pure_5key_stdout: stdout must be byte-equal to the
# compact re-serialization of its own JSON, which means NOTHING was written
# before or after it. The client emits `jq -ce` output through a bare
# `printf '%s'`, so a single leaked line from `migrate` or from the `register`
# CHILD would be immediately visible here -- and would break credential
# resolution for every AWS command on that machine (T-23-37).
assert_stdout_is_only_json() {
    local f="$1" label="$2"
    local first
    first=$(head -c 1 "$f" 2>/dev/null)
    if [[ "$first" != "{" ]]; then
        echo "FAIL: ${label} -- stdout does not start with '{': $(head -3 "$f")" >&2
        return 1
    fi
    local compact actual
    if ! compact=$(jq -c . "$f" 2>/dev/null); then
        echo "FAIL: ${label} -- stdout is not parseable as a single JSON value: $(cat "$f")" >&2
        return 1
    fi
    actual=$(cat "$f")
    if [[ "$actual" != "$compact" ]]; then
        echo "FAIL: ${label} -- stdout carries content beyond the JSON value." >&2
        echo "  got:      [${actual}]" >&2
        echo "  expected: [${compact}]" >&2
        return 1
    fi
    return 0
}

# assert_pure_5key_stdout <file> <label>
# The credential_process contract: stdout parses as JSON, carries EXACTLY the 5
# canonical keys, and nothing else precedes or follows it. The first-byte check
# is what catches a leaked `[migrate]`/`[register]` line -- `jq` alone would
# still accept trailing garbage on some builds, and a leading line would make
# the parse fail with a much less specific message.
assert_pure_5key_stdout() {
    local f="$1" label="$2"
    local first
    first=$(head -c 1 "$f" 2>/dev/null)
    if [[ "$first" != "{" ]]; then
        echo "FAIL: ${label} -- stdout does not start with '{' (leaked line?): $(head -3 "$f")" >&2
        return 1
    fi
    if ! jq -e 'keys | length == 5' "$f" >/dev/null 2>&1; then
        echo "FAIL: ${label} -- stdout is not a 5-key JSON object: $(cat "$f")" >&2
        return 1
    fi
    local keys
    keys=$(jq -rc '[keys_unsorted[]] | sort | join(",")' "$f" 2>/dev/null)
    if [[ "$keys" != "AccessKeyId,Expiration,SecretAccessKey,SessionToken,Version" ]]; then
        echo "FAIL: ${label} -- stdout keys were [${keys}], expected the 5-key contract" >&2
        return 1
    fi
    return 0
}

# -- Test Cases ---------------------------------------------------------------

run_case1() {
    local d="${WORK_DIR}/case1"; mkdir -p "$d"
    local label="CLI-01/02: success emits exact 5-key contract + <acct>.json cache + no assume"
    (
        export HOME="$d"
        seed_env "$d" "xoxp-test-bearer-value"
        seed_broker_ok "$d"

        local out_file="${d}/stdout.json"
        set +e
        PATH="${STUB_DIR}:${PATH}" bash "$SCRIPT" --account-id 111111111111 --agent claude-code >"$out_file" 2>"${d}/stderr.txt"
        local rc=$?
        set -e

        if [[ $rc -ne 0 ]]; then
            echo "FAIL: ${label} -- exit ${rc}, expected 0" >&2
            cat "${d}/stderr.txt" >&2
            exit 1
        fi

        # Exactly the 5 canonical keys (sorted), no BrokerVersion.
        local keys
        keys=$(jq -rc '[keys_unsorted[]] | sort | join(",")' "$out_file" 2>/dev/null) || {
            echo "FAIL: ${label} -- stdout is not valid JSON: $(cat "$out_file")" >&2
            exit 1
        }
        if [[ "$keys" != "AccessKeyId,Expiration,SecretAccessKey,SessionToken,Version" ]]; then
            echo "FAIL: ${label} -- stdout keys were [${keys}], expected the 5-key contract" >&2
            exit 1
        fi

        # Version must be integer 1.
        local ver
        ver=$(jq -rc '.Version' "$out_file")
        if [[ "$ver" != "1" ]]; then
            echo "FAIL: ${label} -- Version was '${ver}', expected 1" >&2
            exit 1
        fi

        # Cache written at customer-creds/<account-id>.json (NO role segment).
        if [[ ! -f "${d}/.cache/msp/customer-creds/111111111111.json" ]]; then
            echo "FAIL: ${label} -- cache file customer-creds/111111111111.json not written" >&2
            exit 1
        fi
        if ls "${d}/.cache/msp/customer-creds/"111111111111-*.json >/dev/null 2>&1; then
            echo "FAIL: ${label} -- a role-segmented cache file (<acct>-<role>.json) was written" >&2
            exit 1
        fi

        # No local assume-role ever happened.
        if [[ -f "${d}/.stub/aws_assume" ]]; then
            echo "FAIL: ${label} -- aws sts assume-role was invoked (no-local-assume violated)" >&2
            cat "${d}/.stub/aws_assume" >&2
            exit 1
        fi

        echo "PASS: ${label}"
    ) || return 1
    return 0
}

run_case2() {
    local d="${WORK_DIR}/case2"; mkdir -p "$d"
    local label="CLI-01: second invocation is a cache HIT (curl not called again)"
    (
        export HOME="$d"
        seed_env "$d" "xoxp-test-bearer-value"
        seed_broker_ok "$d"

        set +e
        PATH="${STUB_DIR}:${PATH}" bash "$SCRIPT" --account-id 111111111111 --agent claude-code >/dev/null 2>&1
        local rc1=$?
        PATH="${STUB_DIR}:${PATH}" bash "$SCRIPT" --account-id 111111111111 --agent claude-code >"${d}/stdout2.json" 2>/dev/null
        local rc2=$?
        set -e

        if [[ $rc1 -ne 0 || $rc2 -ne 0 ]]; then
            echo "FAIL: ${label} -- exit codes rc1=${rc1} rc2=${rc2}, expected 0/0" >&2
            exit 1
        fi

        local n
        n=$(curl_call_count "$d")
        if [[ "$n" != "1" ]]; then
            echo "FAIL: ${label} -- curl was called ${n} times across two runs, expected 1 (2nd = cache HIT)" >&2
            exit 1
        fi

        # Second run must still emit the 5-key contract from cache.
        local keys
        keys=$(jq -rc '[keys_unsorted[]] | sort | join(",")' "${d}/stdout2.json" 2>/dev/null) || {
            echo "FAIL: ${label} -- cache-hit stdout not valid JSON" >&2; exit 1;
        }
        if [[ "$keys" != "AccessKeyId,Expiration,SecretAccessKey,SessionToken,Version" ]]; then
            echo "FAIL: ${label} -- cache-hit stdout keys were [${keys}]" >&2
            exit 1
        fi

        echo "PASS: ${label}"
    ) || return 1
    return 0
}

run_case3() {
    local d="${WORK_DIR}/case3"; mkdir -p "$d"
    local label="CLI-01/03: missing Bearer -> non-zero exit <2s, no browser, points to get-sts-token"
    (
        export HOME="$d"
        seed_env "$d" ""          # identity-only, NO SlackAccessToken
        seed_broker_ok "$d"       # broker would answer, but we must never reach it

        local start end elapsed rc
        start=$(date +%s)
        set +e
        PATH="${STUB_DIR}:${PATH}" bash "$SCRIPT" --account-id 111111111111 --agent claude-code >/dev/null 2>"${d}/stderr.txt"
        rc=$?
        set -e
        end=$(date +%s)
        elapsed=$(( end - start ))

        if [[ $rc -eq 0 ]]; then
            echo "FAIL: ${label} -- exit 0, expected non-zero on missing Bearer" >&2
            exit 1
        fi
        if [[ $elapsed -ge 2 ]]; then
            echo "FAIL: ${label} -- took ${elapsed}s (>=2s); credential_process must fail fast" >&2
            exit 1
        fi
        if ! grep -qi 'get-sts-token' "${d}/stderr.txt"; then
            echo "FAIL: ${label} -- stderr does not point the user to get-sts-token" >&2
            echo "  stderr: $(cat "${d}/stderr.txt")" >&2
            exit 1
        fi
        # No browser / no broker call on the fail-fast path.
        if [[ -f "${d}/.stub/curl_calls" ]]; then
            echo "FAIL: ${label} -- broker was called despite missing Bearer" >&2
            exit 1
        fi
        if [[ -f "${d}/.stub/aws_assume" ]]; then
            echo "FAIL: ${label} -- aws assume-role invoked on fail-fast path" >&2
            exit 1
        fi

        echo "PASS: ${label}"
    ) || return 1
    return 0
}

run_case4() {
    local d="${WORK_DIR}/case4"; mkdir -p "$d"
    local label="RES-02: broker {\"error\":...} body -> non-zero exit surfacing the server message"
    (
        export HOME="$d"
        seed_env "$d" "xoxp-test-bearer-value"
        seed_broker_err "$d"

        set +e
        PATH="${STUB_DIR}:${PATH}" bash "$SCRIPT" --account-id 111111111111 --agent claude-code >/dev/null 2>"${d}/stderr.txt"
        local rc=$?
        set -e

        if [[ $rc -eq 0 ]]; then
            echo "FAIL: ${label} -- exit 0, expected non-zero on broker error body" >&2
            exit 1
        fi
        if ! grep -q 'not authorized' "${d}/stderr.txt"; then
            echo "FAIL: ${label} -- server error message not surfaced on stderr" >&2
            echo "  stderr: $(cat "${d}/stderr.txt")" >&2
            exit 1
        fi
        # A broker error must NOT leave a cache file behind.
        if [[ -f "${d}/.cache/msp/customer-creds/111111111111.json" ]]; then
            echo "FAIL: ${label} -- cache written despite broker error" >&2
            exit 1
        fi

        echo "PASS: ${label}"
    ) || return 1
    return 0
}

# -- Phase 19 (RES-02): status->message map + bounded 5xx/503 retry ------------

# run_case5: HTTP 401 -> re-login message, NO retry (exactly 1 curl call), no cache.
run_case5() {
    local d="${WORK_DIR}/case5"; mkdir -p "$d"
    local label="RES-02: HTTP 401 -> re-login message, no retry, no cache"
    (
        export HOME="$d"
        seed_env "$d" "xoxp-test-bearer-value"
        seed_status "$d" "401"

        set +e
        PATH="${STUB_DIR}:${PATH}" bash "$SCRIPT" --account-id 111111111111 --agent claude-code >/dev/null 2>"${d}/stderr.txt"
        local rc=$?
        set -e

        if [[ $rc -eq 0 ]]; then
            echo "FAIL: ${label} -- exit 0, expected non-zero on 401" >&2; exit 1
        fi
        if ! grep -q 'get-sts-token' "${d}/stderr.txt"; then
            echo "FAIL: ${label} -- 401 message must name get-sts-token: $(cat "${d}/stderr.txt")" >&2; exit 1
        fi
        local n; n=$(curl_call_count "$d")
        if [[ "$n" != "1" ]]; then
            echo "FAIL: ${label} -- 401 retried (curl called ${n}x, expected exactly 1)" >&2; exit 1
        fi
        if [[ -f "${d}/.cache/msp/customer-creds/111111111111.json" ]]; then
            echo "FAIL: ${label} -- cache written despite 401" >&2; exit 1
        fi
        echo "PASS: ${label}"
    ) || return 1
    return 0
}

# run_case6: HTTP 403 -> uniform not-authorized message, NO retry, no cache.
run_case6() {
    local d="${WORK_DIR}/case6"; mkdir -p "$d"
    local label="RES-02: HTTP 403 -> uniform not-authorized message, no retry, no cache"
    (
        export HOME="$d"
        seed_env "$d" "xoxp-test-bearer-value"
        seed_status "$d" "403"

        set +e
        PATH="${STUB_DIR}:${PATH}" bash "$SCRIPT" --account-id 111111111111 --agent claude-code >/dev/null 2>"${d}/stderr.txt"
        local rc=$?
        set -e

        if [[ $rc -eq 0 ]]; then
            echo "FAIL: ${label} -- exit 0, expected non-zero on 403" >&2; exit 1
        fi
        if ! grep -q '접근 권한이 없습니다' "${d}/stderr.txt"; then
            echo "FAIL: ${label} -- 403 uniform message not surfaced: $(cat "${d}/stderr.txt")" >&2; exit 1
        fi
        local n; n=$(curl_call_count "$d")
        if [[ "$n" != "1" ]]; then
            echo "FAIL: ${label} -- 403 retried (curl called ${n}x, expected exactly 1)" >&2; exit 1
        fi
        if [[ -f "${d}/.cache/msp/customer-creds/111111111111.json" ]]; then
            echo "FAIL: ${label} -- cache written despite 403" >&2; exit 1
        fi
        echo "PASS: ${label}"
    ) || return 1
    return 0
}

# run_case7: HTTP 503 -> retried (bounded), then fails with the retryable message.
run_case7() {
    local d="${WORK_DIR}/case7"; mkdir -p "$d"
    local label="RES-02: HTTP 503 -> bounded retry then retryable failure"
    (
        export HOME="$d"
        seed_env "$d" "xoxp-test-bearer-value"
        seed_status "$d" "503"

        set +e
        PATH="${STUB_DIR}:${PATH}" bash "$SCRIPT" --account-id 111111111111 --agent claude-code >/dev/null 2>"${d}/stderr.txt"
        local rc=$?
        set -e

        if [[ $rc -eq 0 ]]; then
            echo "FAIL: ${label} -- exit 0, expected non-zero after exhausting retries" >&2; exit 1
        fi
        if ! grep -q '잠시 후 다시 시도' "${d}/stderr.txt"; then
            echo "FAIL: ${label} -- retryable message not surfaced: $(cat "${d}/stderr.txt")" >&2; exit 1
        fi
        local n; n=$(curl_call_count "$d")
        if [[ "$n" -le 1 || "$n" -gt 3 ]]; then
            echo "FAIL: ${label} -- expected bounded retry (>1 and <=3 curl calls), got ${n}" >&2; exit 1
        fi
        if [[ -f "${d}/.cache/msp/customer-creds/111111111111.json" ]]; then
            echo "FAIL: ${label} -- cache written despite 503" >&2; exit 1
        fi
        echo "PASS: ${label}"
    ) || return 1
    return 0
}

# run_case8: generic HTTP 500 -> retried (bounded), then fails.
run_case8() {
    local d="${WORK_DIR}/case8"; mkdir -p "$d"
    local label="RES-02: HTTP 500 -> bounded retry then generic retryable failure"
    (
        export HOME="$d"
        seed_env "$d" "xoxp-test-bearer-value"
        seed_status "$d" "500"

        set +e
        PATH="${STUB_DIR}:${PATH}" bash "$SCRIPT" --account-id 111111111111 --agent claude-code >/dev/null 2>"${d}/stderr.txt"
        local rc=$?
        set -e

        if [[ $rc -eq 0 ]]; then
            echo "FAIL: ${label} -- exit 0, expected non-zero after exhausting retries" >&2; exit 1
        fi
        if ! grep -q '잠시 후 다시 시도' "${d}/stderr.txt"; then
            echo "FAIL: ${label} -- retryable message not surfaced: $(cat "${d}/stderr.txt")" >&2; exit 1
        fi
        local n; n=$(curl_call_count "$d")
        if [[ "$n" -le 1 || "$n" -gt 3 ]]; then
            echo "FAIL: ${label} -- expected bounded retry (>1 and <=3 curl calls), got ${n}" >&2; exit 1
        fi
        echo "PASS: ${label}"
    ) || return 1
    return 0
}

# run_case9: the Bearer NEVER appears in stderr on ANY path (success or error/retry).
run_case9() {
    local d="${WORK_DIR}/case9"; mkdir -p "$d"
    local bearer="xoxp-super-secret-bearer-do-not-leak"
    local label="T-19-05-01: Bearer never leaks to stderr on any path"
    (
        export HOME="$d"
        seed_env "$d" "$bearer"

        # Exercise the success, 403-deny, and 500-retry paths; capture ALL stderr.
        : > "${d}/all_stderr.txt"

        seed_broker_ok "$d"
        seed_status "$d" "200"
        set +e
        PATH="${STUB_DIR}:${PATH}" bash "$SCRIPT" --account-id 111111111111 --agent claude-code >/dev/null 2>>"${d}/all_stderr.txt"
        # fresh account each sub-run so a warm cache does not short-circuit later paths
        seed_status "$d" "403"
        PATH="${STUB_DIR}:${PATH}" bash "$SCRIPT" --account-id 222222222222 --agent claude-code >/dev/null 2>>"${d}/all_stderr.txt"
        seed_status "$d" "500"
        PATH="${STUB_DIR}:${PATH}" bash "$SCRIPT" --account-id 333333333333 --agent claude-code >/dev/null 2>>"${d}/all_stderr.txt"
        set -e

        if grep -qF "$bearer" "${d}/all_stderr.txt"; then
            echo "FAIL: ${label} -- the Bearer token was found in captured stderr" >&2
            exit 1
        fi
        echo "PASS: ${label}"
    ) || return 1
    return 0
}

# -- Agent-resolution priority (runtime agent detection; agent-misattribution fix) --
# Proves detect_agent's 5-level priority (first hit wins): explicit --agent >
# $MSP_AGENT > $AI_AGENT (leading token, validated) > $CLAUDECODE > install
# path. Each case pins the OTHER, lower-priority signals too, so the assertion
# proves the winner beat them — not merely that it was the only signal present.

# run_case10: explicit --agent beats every runtime-env signal.
run_case10() {
    local d="${WORK_DIR}/case10"; mkdir -p "$d"
    local label="AGENT-PRIO(1): explicit --agent wins over MSP_AGENT/AI_AGENT/CLAUDECODE"
    (
        export HOME="$d"
        unset MSP_AGENT AI_AGENT CLAUDECODE
        export MSP_AGENT="env-override" AI_AGENT="kiro_9-9_agent" CLAUDECODE=1
        seed_run_assert_agent "$d" "$label" "foo" "$SCRIPT" --agent foo
    ) || return 1
    return 0
}

# run_case11: MSP_AGENT wins when --agent is absent (beats AI_AGENT + CLAUDECODE).
run_case11() {
    local d="${WORK_DIR}/case11"; mkdir -p "$d"
    local label="AGENT-PRIO(2): MSP_AGENT wins over AI_AGENT/CLAUDECODE (no --agent)"
    (
        export HOME="$d"
        unset MSP_AGENT AI_AGENT CLAUDECODE
        export MSP_AGENT="bar" AI_AGENT="kiro_9-9_agent" CLAUDECODE=1
        seed_run_assert_agent "$d" "$label" "bar" "$SCRIPT"
    ) || return 1
    return 0
}

# run_case12: AI_AGENT wins over CLAUDECODE; leading token before first '_', lowercased.
run_case12() {
    local d="${WORK_DIR}/case12"; mkdir -p "$d"
    local label="AGENT-PRIO(3): AI_AGENT=kiro_9-9_agent -> 'kiro' (beats CLAUDECODE)"
    (
        export HOME="$d"
        unset MSP_AGENT AI_AGENT CLAUDECODE
        export AI_AGENT="kiro_9-9_agent" CLAUDECODE=1
        seed_run_assert_agent "$d" "$label" "kiro" "$SCRIPT"
    ) || return 1
    return 0
}

# run_case13: CLAUDECODE set (no --agent/MSP_AGENT/AI_AGENT) -> claude-code.
run_case13() {
    local d="${WORK_DIR}/case13"; mkdir -p "$d"
    local label="AGENT-PRIO(4): CLAUDECODE=1 -> 'claude-code'"
    (
        export HOME="$d"
        unset MSP_AGENT AI_AGENT CLAUDECODE
        export CLAUDECODE=1
        seed_run_assert_agent "$d" "$label" "claude-code" "$SCRIPT"
    ) || return 1
    return 0
}

# run_case14: no runtime signal -> install-path mapping (UNCHANGED final fallback).
# Runs a copy installed under a .kiro/... path so detect_agent_from_path -> 'kiro'.
run_case14() {
    local d="${WORK_DIR}/case14"; mkdir -p "$d"
    local label="AGENT-PRIO(7): no env signals -> install-path fallback maps '.kiro/' to 'kiro'"
    (
        export HOME="$d"
        unset MSP_AGENT AI_AGENT CLAUDECODE TERM_PROGRAM __CFBundleIdentifier
        local kiro_script="${d}/.kiro/skills/aws-customer-account-ops/get-customer-credentials.sh"
        mkdir -p "$(dirname "$kiro_script")"
        cp "$SCRIPT" "$kiro_script"
        seed_run_assert_agent "$d" "$label" "kiro" "$kiro_script"
    ) || return 1
    return 0
}

# run_case15: a malformed AI_AGENT is ignored (used only if it matches the charset),
# so resolution falls through to CLAUDECODE. Guards the "validated signal" rule.
run_case15() {
    local d="${WORK_DIR}/case15"; mkdir -p "$d"
    local label="AGENT-PRIO(3b): malformed AI_AGENT ignored -> falls through to CLAUDECODE"
    (
        export HOME="$d"
        unset MSP_AGENT AI_AGENT CLAUDECODE
        export AI_AGENT="Not A Valid Agent Name!" CLAUDECODE=1
        seed_run_assert_agent "$d" "$label" "claude-code" "$SCRIPT"
    ) || return 1
    return 0
}

# -- VSCode-fork agent detection (TERM_PROGRAM / __CFBundleIdentifier, KNOWN-gated) --
# Kiro (and other VSCode forks) inject NO custom AI_AGENT/KIRO_* var; the only
# reliable runtime signals are TERM_PROGRAM=kiro and (macOS) __CFBundleIdentifier=
# dev.kiro.desktop. These layers sit AFTER CLAUDECODE and BEFORE the path fallback,
# and are gated by the 9-id KNOWN-AGENT set so a generic terminal never mis-maps.

# run_case16: TERM_PROGRAM=kiro (a KNOWN agent id) -> 'kiro' (no --agent/MSP/AI/CLAUDECODE).
run_case16() {
    local d="${WORK_DIR}/case16"; mkdir -p "$d"
    local label="AGENT-PRIO(5): TERM_PROGRAM=kiro -> 'kiro'"
    (
        export HOME="$d"
        unset MSP_AGENT AI_AGENT CLAUDECODE __CFBundleIdentifier
        export TERM_PROGRAM="kiro"
        seed_run_assert_agent "$d" "$label" "kiro" "$SCRIPT"
    ) || return 1
    return 0
}

# run_case17: TERM_PROGRAM=vscode (NOT a CSG agent) -> falls through to path detection.
# The copy is installed under a .cursor/ path, so the frozen path mapping yields
# 'cursor'; asserting 'cursor' proves TERM_PROGRAM's 'vscode' was NEVER used.
run_case17() {
    local d="${WORK_DIR}/case17"; mkdir -p "$d"
    local label="AGENT-PRIO(5b): TERM_PROGRAM=vscode ignored -> install-path fallback ('cursor', NOT 'vscode')"
    (
        export HOME="$d"
        unset MSP_AGENT AI_AGENT CLAUDECODE __CFBundleIdentifier
        export TERM_PROGRAM="vscode"
        local cursor_script="${d}/.cursor/skills/aws-customer-account-ops/get-customer-credentials.sh"
        mkdir -p "$(dirname "$cursor_script")"
        cp "$SCRIPT" "$cursor_script"
        seed_run_assert_agent "$d" "$label" "cursor" "$cursor_script"
    ) || return 1
    return 0
}

# run_case18: __CFBundleIdentifier=dev.kiro.desktop (TERM_PROGRAM unset) -> 'kiro' (macOS backup).
run_case18() {
    local d="${WORK_DIR}/case18"; mkdir -p "$d"
    local label="AGENT-PRIO(6): __CFBundleIdentifier=dev.kiro.desktop -> 'kiro' (TERM_PROGRAM unset)"
    (
        export HOME="$d"
        unset MSP_AGENT AI_AGENT CLAUDECODE TERM_PROGRAM
        export __CFBundleIdentifier="dev.kiro.desktop"
        seed_run_assert_agent "$d" "$label" "kiro" "$SCRIPT"
    ) || return 1
    return 0
}

# run_case19: __CFBundleIdentifier=com.apple.Terminal -> ignored (not dev.<known>.desktop/.app),
# so resolution falls through to the install-path mapping ('cursor').
run_case19() {
    local d="${WORK_DIR}/case19"; mkdir -p "$d"
    local label="AGENT-PRIO(6b): __CFBundleIdentifier=com.apple.Terminal ignored -> install-path fallback ('cursor')"
    (
        export HOME="$d"
        unset MSP_AGENT AI_AGENT CLAUDECODE TERM_PROGRAM
        export __CFBundleIdentifier="com.apple.Terminal"
        local cursor_script="${d}/.cursor/skills/aws-customer-account-ops/get-customer-credentials.sh"
        mkdir -p "$(dirname "$cursor_script")"
        cp "$SCRIPT" "$cursor_script"
        seed_run_assert_agent "$d" "$label" "cursor" "$cursor_script"
    ) || return 1
    return 0
}

# run_case20: CLAUDECODE + TERM_PROGRAM=kiro both set -> 'claude-code' (layer 4 beats layer 5).
run_case20() {
    local d="${WORK_DIR}/case20"; mkdir -p "$d"
    local label="AGENT-PRIO(4>5): CLAUDECODE=1 + TERM_PROGRAM=kiro -> 'claude-code' (CLAUDECODE wins)"
    (
        export HOME="$d"
        unset MSP_AGENT AI_AGENT __CFBundleIdentifier
        export CLAUDECODE=1 TERM_PROGRAM="kiro"
        seed_run_assert_agent "$d" "$label" "claude-code" "$SCRIPT"
    ) || return 1
    return 0
}

# =============================================================================
# Phase 30 (ERR-02/03/04/05/10) -- 424 deny, 418 fail-closed, transport budget,
# and the clientVersion observation field on the wire
# =============================================================================

# run_case21: HTTP 424 -> customer-side deny sentence, NO retry, no cache (ERR-02).
# The call-count assertion is what makes "no retry" a property rather than a hope:
# a 424 that gets retried is exactly the waste ERR-02 exists to eliminate. The
# cache assertion is what makes "fail closed" mean something -- a stale credential
# left on disk after an error is strictly worse than a clean failure.
run_case21() {
    local d="${WORK_DIR}/case21"; mkdir -p "$d"
    local label="RES-02: HTTP 424 -> customer-side deny message, no retry, no cache"
    (
        export HOME="$d"
        seed_env "$d" "xoxp-test-bearer-value"
        seed_status "$d" "424"

        set +e
        PATH="${STUB_DIR}:${PATH}" bash "$SCRIPT" --account-id 111111111111 --agent claude-code >/dev/null 2>"${d}/stderr.txt"
        local rc=$?
        set -e

        if [[ $rc -eq 0 ]]; then
            echo "FAIL: ${label} -- exit 0, expected non-zero on 424" >&2; exit 1
        fi
        # Anchored on the metacharacter-free substring of the shipped sentence; the
        # full literal carries ( ) and / which grep would read as a pattern.
        if ! grep -q '세션을 발급할 수 없습니다' "${d}/stderr.txt"; then
            echo "FAIL: ${label} -- 424 deny message not surfaced: $(cat "${d}/stderr.txt")" >&2; exit 1
        fi
        local n; n=$(curl_call_count "$d")
        if [[ "$n" != "1" ]]; then
            echo "FAIL: ${label} -- 424 retried (curl called ${n}x, expected exactly 1); a customer-side deny never heals by waiting" >&2; exit 1
        fi
        if [[ -f "${d}/.cache/msp/customer-creds/111111111111.json" ]]; then
            echo "FAIL: ${label} -- cache written despite 424" >&2; exit 1
        fi
        echo "PASS: ${label}"
    ) || return 1
    return 0
}

# run_tiket_version: the client version IS the tiket release tag (0040, 2026-10-20).
# A copy of the skill inside a throwaway git repo tagged v9.8.7 must send exactly
# tiket-v9.8.7; the same copy outside any git repo must send tiket-unknown (the
# broker never refuses unknown). The tag is fixed here, not read the way the script
# reads it, so the case cannot pass by comparing the implementation with itself.
run_tiket_version() {
    local d="${WORK_DIR}/tiketver"; mkdir -p "$d"
    local label="tiket: clientVersion is tiket-<release tag>, tiket-unknown outside git"
    (
        local repo="${d}/repo" bare="${d}/bare"
        mkdir -p "${repo}/skills" "$bare"
        cp -R "$(dirname "$SCRIPT")" "${repo}/skills/"
        cp -R "$(dirname "$SCRIPT")" "${bare}/"
        git -C "$repo" init -q
        git -C "$repo" -c user.name=t -c user.email=t@example.invalid add -A
        git -C "$repo" -c user.name=t -c user.email=t@example.invalid commit -q -m init
        git -C "$repo" tag v9.8.7

        export HOME="$d"
        seed_env "$d" "xoxp-test-bearer-value"
        local script_name; script_name=$(basename "$SCRIPT")
        local skill_name; skill_name=$(basename "$(dirname "$SCRIPT")")

        seed_broker_ok "$d"
        set +e
        PATH="${STUB_DIR}:${PATH}" bash "${repo}/skills/${skill_name}/${script_name}" --account-id 111111111111 --agent claude-code >/dev/null 2>"${d}/stderr1.txt"
        local rc=$?
        set -e
        [[ $rc -eq 0 ]] || { echo "FAIL: ${label} -- tagged copy exit ${rc}: $(cat "${d}/stderr1.txt")" >&2; exit 1; }
        local v; v=$(broker_client_version "$d")
        [[ "$v" == "tiket-v9.8.7" ]] || { echo "FAIL: ${label} -- tagged copy sent '${v}', expected tiket-v9.8.7" >&2; exit 1; }

        rm -rf "${d}/.cache/msp/customer-creds" "${d}/.stub"
        seed_broker_ok "$d"
        set +e
        GIT_CEILING_DIRECTORIES="$d" PATH="${STUB_DIR}:${PATH}" bash "${bare}/${skill_name}/${script_name}" --account-id 111111111111 --agent claude-code >/dev/null 2>"${d}/stderr2.txt"
        rc=$?
        set -e
        [[ $rc -eq 0 ]] || { echo "FAIL: ${label} -- untracked copy exit ${rc}: $(cat "${d}/stderr2.txt")" >&2; exit 1; }
        v=$(broker_client_version "$d")
        [[ "$v" == "tiket-unknown" ]] || { echo "FAIL: ${label} -- untracked copy sent '${v}', expected tiket-unknown" >&2; exit 1; }
        echo "PASS: ${label}"
    ) || return 1
    return 0
}

# run_case426: the broker refuses an outdated tiket client with 426 (2026-10-20).
# Same contract as 424: a client-side sentence, no retry (waiting never upgrades the
# workspace), no cache.
run_case426() {
    local d="${WORK_DIR}/case426"; mkdir -p "$d"
    local label="tiket: HTTP 426 -> update-the-workspace message, no retry, no cache"
    (
        export HOME="$d"
        seed_env "$d" "xoxp-test-bearer-value"
        seed_status "$d" "426"

        set +e
        PATH="${STUB_DIR}:${PATH}" bash "$SCRIPT" --account-id 111111111111 --agent claude-code >/dev/null 2>"${d}/stderr.txt"
        local rc=$?
        set -e

        [[ $rc -ne 0 ]] || { echo "FAIL: ${label} -- exit 0, expected non-zero on 426" >&2; exit 1; }
        grep -q 'tiket 워크스페이스가 오래돼' "${d}/stderr.txt" \
            || { echo "FAIL: ${label} -- update message not surfaced: $(cat "${d}/stderr.txt")" >&2; exit 1; }
        local n; n=$(curl_call_count "$d")
        [[ "$n" == "1" ]] || { echo "FAIL: ${label} -- 426 retried (curl called ${n}x, expected exactly 1)" >&2; exit 1; }
        [[ ! -f "${d}/.cache/msp/customer-creds/111111111111.json" ]] || { echo "FAIL: ${label} -- cache written despite 426" >&2; exit 1; }
        echo "PASS: ${label}"
    ) || return 1
    return 0
}

# run_case22: HTTP 418 (unknown status) -> fail closed (ERR-05).
# 418 stands in for every status the map does not name. The point is not the
# wording but that an unmapped status is an ENFORCED stop rather than an accident
# of the fallback arm: no retry, no cache file, and nothing on stdout -- because a
# client that printed a partial credential JSON before dying would satisfy every
# other assertion here while still minting a usable credential.
run_case22() {
    local d="${WORK_DIR}/case22"; mkdir -p "$d"
    local label="RES-02: HTTP 418 (unmapped status) -> fail closed, no retry, no cache, no stdout"
    (
        export HOME="$d"
        seed_env "$d" "xoxp-test-bearer-value"
        seed_status "$d" "418"

        set +e
        PATH="${STUB_DIR}:${PATH}" bash "$SCRIPT" --account-id 111111111111 --agent claude-code >"${d}/stdout.txt" 2>"${d}/stderr.txt"
        local rc=$?
        set -e

        if [[ $rc -eq 0 ]]; then
            echo "FAIL: ${label} -- exit 0, expected non-zero on an unmapped status" >&2; exit 1
        fi
        if ! grep -q '브로커 호출 실패' "${d}/stderr.txt"; then
            echo "FAIL: ${label} -- unmapped-status message not surfaced: $(cat "${d}/stderr.txt")" >&2; exit 1
        fi
        local n; n=$(curl_call_count "$d")
        if [[ "$n" != "1" ]]; then
            echo "FAIL: ${label} -- 418 retried (curl called ${n}x, expected exactly 1)" >&2; exit 1
        fi
        if [[ -f "${d}/.cache/msp/customer-creds/111111111111.json" ]]; then
            echo "FAIL: ${label} -- cache written despite an unmapped status" >&2; exit 1
        fi
        if [[ -s "${d}/stdout.txt" ]]; then
            echo "FAIL: ${label} -- an unmapped status emitted bytes on stdout: $(cat "${d}/stdout.txt")" >&2; exit 1
        fi
        echo "PASS: ${label}"
    ) || return 1
    return 0
}

# run_case23: transport failure -> EXACTLY max_attempts requests + a non-empty
# sanitized diagnostic (ERR-03, ERR-04, D-01).
# run_case7/run_case8 assert ">1 and <=3" because they predate the concern that
# splitting the transport arm off 5xx might give it its own counter. That looser
# bound would still pass against a client carrying exactly that defect on a
# different arm, so this case pins the exact number instead.
run_case23() {
    local d="${WORK_DIR}/case23"; mkdir -p "$d"
    local label="RES-02: transport failure -> exactly 3 requests + non-empty diagnostic"
    (
        export HOME="$d"
        seed_env "$d" "xoxp-test-bearer-value"
        seed_status "$d" "000"

        set +e
        PATH="${STUB_DIR}:${PATH}" bash "$SCRIPT" --account-id 111111111111 --agent claude-code >/dev/null 2>"${d}/stderr.txt"
        local rc=$?
        set -e

        if [[ $rc -eq 0 ]]; then
            echo "FAIL: ${label} -- exit 0, expected non-zero after exhausting retries" >&2; exit 1
        fi
        if ! grep -q '브로커에 연결할 수 없습니다' "${d}/stderr.txt"; then
            echo "FAIL: ${label} -- transport-failure message not surfaced: $(cat "${d}/stderr.txt")" >&2; exit 1
        fi
        local n; n=$(curl_call_count "$d")
        if ! [[ "$n" == "3" ]]; then
            echo "FAIL: ${label} -- expected EXACTLY 3 requests (the single shared retry budget), got ${n}; 6 means the arm split introduced a second counter" >&2; exit 1
        fi
        # Marker present AND at least one character inside the quoted tail: a tail
        # that renders empty means the captured stderr was read wrong or the
        # sanitizer swallowed it, and "the marker is there" alone would hide that.
        if ! grep -qE "진단: '[^']" "${d}/stderr.txt"; then
            echo "FAIL: ${label} -- transport diagnostic missing or empty: $(cat "${d}/stderr.txt")" >&2; exit 1
        fi
        echo "PASS: ${label}"
    ) || return 1
    return 0
}

# run_case24: the POST body carries a semver-shaped clientVersion (ERR-10).
# The value itself is NOT pinned -- install.sh stamps it at pack/install time and
# the repo literal drifts by design. `agent` is re-asserted from the same captured
# body so a broken body capture cannot make this case pass vacuously: an empty
# capture would fail both reads, not silently satisfy one.
run_case24() {
    local d="${WORK_DIR}/case24"; mkdir -p "$d"
    local label="ERR-10: the broker POST body carries a semver-shaped clientVersion alongside agent"
    (
        export HOME="$d"
        unset MSP_AGENT AI_AGENT CLAUDECODE
        seed_env "$d" "xoxp-test-bearer-value"
        seed_broker_ok "$d"

        set +e
        PATH="${STUB_DIR}:${PATH}" bash "$SCRIPT" --account-id 111111111111 --agent claude-code >/dev/null 2>"${d}/stderr.txt"
        local rc=$?
        set -e

        if [[ $rc -ne 0 ]]; then
            echo "FAIL: ${label} -- exit ${rc}, expected 0: $(cat "${d}/stderr.txt")" >&2; exit 1
        fi
        local v; v=$(broker_client_version "$d")
        if [[ -z "$v" ]]; then
            echo "FAIL: ${label} -- no clientVersion in the POSTed body: $(cat "${d}/.stub/last_body.json" 2>/dev/null)" >&2; exit 1
        fi
        # tiket 으로 옮긴 뒤 (0040, 2026-10-20): 값은 tiket 릴리스 태그다. 이 체크아웃에 태그가 있으면
        # tiket-vX.Y.Z, 얕은 클론이면 tiket-unknown — 정확한 값은 run_tiket_version 이 고정한다.
        if ! printf '%s' "$v" | grep -qE '^tiket-(v[0-9]+\.[0-9]+\.[0-9]+|unknown)$'; then
            echo "FAIL: ${label} -- clientVersion='${v}' is not tiket-vX.Y.Z or tiket-unknown" >&2; exit 1
        fi
        local a; a=$(broker_agent "$d")
        if [[ "$a" != "claude-code" ]]; then
            echo "FAIL: ${label} -- agent='${a}', expected 'claude-code'; the new field must be ADDED, not swapped in" >&2; exit 1
        fi
        echo "PASS: ${label}"
    ) || return 1
    return 0
}

# =============================================================================
# CR-01 / WR-01 -- the two credential-exposure paths found by the phase-30 review
# =============================================================================
# Both predate phase 30 and both falsify a claim the client makes about itself,
# which is why they are pinned by BEHAVIOUR here rather than by a lexical mirror
# in the parity suite: "the stream carries no credential bytes" and "the process
# argv carries no Bearer" are properties of a RUN, and the parity suite can only
# read text. Neither property is expressible there.

# run_case25 (CR-01): a 2xx body that satisfies the .error guard but fails the
# 5-key projection must not be echoed back at the engineer.
#
# The fixture is the exact gap the two upstream guards leave open: the body is
# HTTP 200 (so no status arm fires), it has no .error/.message (so the structured
# -error surfacing does not fire), and it carries a live AccessKeyId /
# SecretAccessKey / SessionToken with a null Expiration (so the projection fails
# closed). That is a broker regression or a partial STS response, and the failure
# path is read by three audiences at once -- the engineer's terminal, the AI
# agent transcript, and any CI log capturing the run.
#
# The canary lives ONLY in the three secret VALUES, never in a field name. That
# separation is the point: it lets the case demand a diagnostic that names the
# absent field while still forbidding every byte of credential material, so the
# fix cannot degrade into "print nothing and say nothing".
run_case25() {
    local d="${WORK_DIR}/case25"; mkdir -p "$d"
    local label="CR-01: a 2xx body missing Expiration leaks no credential material and writes no cache"
    (
        export HOME="$d"
        seed_env "$d" "xoxp-test-bearer-value"
        seed_status "$d" "200"

        mkdir -p "${d}/.stub"
        cat > "${d}/.stub/resp.json" <<RESP
{"Version":1,"AccessKeyId":"ASIALEAKCANARY000000","SecretAccessKey":"wJalrLEAKCANARYsecretkey","SessionToken":"FQoGLEAKCANARYsessiontoken","Expiration":null,"BrokerVersion":"1.3.0"}
RESP

        set +e
        PATH="${STUB_DIR}:${PATH}" bash "$SCRIPT" --account-id 111111111111 --agent claude-code \
            >"${d}/stdout.txt" 2>"${d}/stderr.txt"
        local rc=$?
        set -e

        if [[ $rc -eq 0 ]]; then
            echo "FAIL: ${label} -- exit 0 on a body with no usable Expiration; the projection must fail closed" >&2
            exit 1
        fi
        if grep -qF 'LEAKCANARY' "${d}/stdout.txt"; then
            echo "FAIL: ${label} -- credential material reached stdout (see ${d}/stdout.txt)" >&2
            exit 1
        fi
        if grep -qF 'LEAKCANARY' "${d}/stderr.txt"; then
            echo "FAIL: ${label} -- credential material reached stderr (see ${d}/stderr.txt)" >&2
            exit 1
        fi
        local cache_dir="${d}/.cache/msp/customer-creds"
        if [[ -e "${cache_dir}/111111111111.json" ]]; then
            echo "FAIL: ${label} -- a cache entry was written for a body the client rejected" >&2
            exit 1
        fi
        local staged
        staged=$(find "$cache_dir" -maxdepth 1 -name '111111111111.json.*' 2>/dev/null | head -1)
        if [[ -n "$staged" ]]; then
            echo "FAIL: ${label} -- a staging cache file survived the failure: ${staged}" >&2
            exit 1
        fi
        if ! grep -qF 'Expiration' "${d}/stderr.txt"; then
            echo "FAIL: ${label} -- the message does not name the contract field that was absent" >&2
            echo "  stderr: $(cat "${d}/stderr.txt")" >&2
            exit 1
        fi
        echo "PASS: ${label}"
    ) || return 1
    return 0
}

# run_case26 (WR-01): the Bearer must not be visible in the credential-fetch
# child process's arguments. On Linux /proc/<pid>/cmdline is world-readable for
# the lifetime of that process, and a stolen Bearer mints customer sessions
# ATTRIBUTED TO THE VICTIM ENGINEER -- the broker's audit log is the
# authoritative record, so the wrong name lands in exactly the artifact this
# project exists to keep honest.
#
# Both halves are asserted. The negative half alone ("not on argv") is satisfied
# by a client that stopped sending the header at all, which would make every
# request a 401 and produce NO audit record whatsoever; the positive half (the
# header is really there, just carried on stdin) plus the rc-0 assertion is what
# forbids that degenerate reading.
run_case26() {
    local d="${WORK_DIR}/case26"; mkdir -p "$d"
    local bearer="xoxp-argv-canary-bearer-do-not-leak"
    local label="WR-01: the Bearer reaches curl on stdin, never on argv"
    (
        export HOME="$d"
        seed_env "$d" "$bearer"
        seed_broker_ok "$d"
        seed_status "$d" "200"

        set +e
        PATH="${STUB_DIR}:${PATH}" bash "$SCRIPT" --account-id 111111111111 --agent claude-code \
            >/dev/null 2>"${d}/stderr.txt"
        local rc=$?
        set -e

        if [[ $rc -ne 0 ]]; then
            echo "FAIL: ${label} -- exit ${rc}, expected 0: $(cat "${d}/stderr.txt")" >&2
            exit 1
        fi
        # Guard against a vacuous pass: if the recorder itself broke, the
        # negative assertion below would go green against a client that still
        # puts the Bearer on argv.
        if [[ ! -s "${d}/.stub/curl_argv" ]]; then
            echo "FAIL: ${label} -- the stub recorded no argv at all; the negative assertion would be vacuous" >&2
            exit 1
        fi
        if grep -qF "$bearer" "${d}/.stub/curl_argv"; then
            echo "FAIL: ${label} -- the Bearer is on the curl process argv (world-readable via /proc/<pid>/cmdline)" >&2
            exit 1
        fi
        if [[ ! -s "${d}/.stub/curl_stdin" ]]; then
            echo "FAIL: ${label} -- nothing was fed to curl on stdin; the header was removed rather than moved" >&2
            exit 1
        fi
        if ! grep -qF "$bearer" "${d}/.stub/curl_stdin"; then
            echo "FAIL: ${label} -- the Bearer never reached curl on stdin either; requests would be unauthenticated" >&2
            exit 1
        fi
        if ! grep -qF 'Authorization' "${d}/.stub/curl_stdin"; then
            echo "FAIL: ${label} -- the stdin stanza does not set an Authorization header" >&2
            exit 1
        fi
        echo "PASS: ${label}"
    ) || return 1
    return 0
}

# =============================================================================
# HOOK-B -- the credential_process main flow fires the fleet migration (PROF-12)
# =============================================================================
# `self-update` replaces skill FILES and never re-runs install.sh, so a migration
# hosted only in the installer reaches ~0 already-deployed machines. These cases
# pin the client-side hook that is the actual delivery mechanism, and the ORDER
# it runs in relative to the sweep.

# run_hook_b1: no marker -> one ordinary credential_process call migrates the
# machine and leaves the completion marker behind.
run_hook_b1() {
    local d="${WORK_DIR}/hookb1"; mkdir -p "$d"
    local label="HOOK-B-01: an ordinary credential_process call fires the migration and records the marker"
    require_real_aws "$label" || return 0
    (
        export HOME="$d"
        seed_env "$d" "xoxp-test-bearer-value"
        seed_broker_ok "$d"
        seed_legacy_config "$d"

        PATH="${STUB_DIR}:${PATH}" bash "$SCRIPT" --account-id 111111111111 --agent claude-code \
            >"${d}/stdout.json" 2>"${d}/stderr.txt"
        local rc=$?
        if [[ $rc -ne 0 ]]; then
            echo "FAIL: ${label} -- exit ${rc}, expected 0; stderr: $(cat "${d}/stderr.txt")" >&2
            exit 1
        fi

        if [[ ! -f "$(migration_marker_path "$d")" ]]; then
            echo "FAIL: ${label} -- no migrations.jsonl written (the hook never fired)" >&2
            exit 1
        fi
        if ! grep -Fq '"id":"v1.7-csg-namespace"' "$(migration_marker_path "$d")"; then
            echo "FAIL: ${label} -- marker file lacks the v1.7-csg-namespace id" >&2
            exit 1
        fi
        if ! config_has_profile "$d" "csg-samplecorp"; then
            echo "FAIL: ${label} -- [profile csg-samplecorp] was not created; config: $(cat "${d}/.aws/config")" >&2
            exit 1
        fi
        assert_pure_5key_stdout "${d}/stdout.json" "$label" || exit 1

        echo "PASS: ${label}"
    ) || return 1
    return 0
}

# run_hook_b2: marker present -> the hook short-circuits before ~/.aws/config is
# opened. Proven by the config being byte-identical and no new .bak appearing.
run_hook_b2() {
    local d="${WORK_DIR}/hookb2"; mkdir -p "$d"
    local label="HOOK-B-02: an already-migrated machine short-circuits -- config byte-identical, no new .bak"
    require_real_aws "$label" || return 0
    (
        export HOME="$d"
        seed_env "$d" "xoxp-test-bearer-value"
        seed_broker_ok "$d"
        seed_legacy_config "$d"
        seed_migration_marker "$d"
        cp "${d}/.aws/config" "${d}/config.before"
        local baks_before; baks_before=$(bak_count "$d")

        PATH="${STUB_DIR}:${PATH}" bash "$SCRIPT" --account-id 111111111111 --agent claude-code \
            >"${d}/stdout.json" 2>"${d}/stderr.txt"
        local rc=$?
        if [[ $rc -ne 0 ]]; then
            echo "FAIL: ${label} -- exit ${rc}, expected 0" >&2
            exit 1
        fi

        if ! cmp -s "${d}/config.before" "${d}/.aws/config"; then
            echo "FAIL: ${label} -- ~/.aws/config was rewritten despite the completion marker" >&2
            diff "${d}/config.before" "${d}/.aws/config" >&2
            exit 1
        fi
        local baks_after; baks_after=$(bak_count "$d")
        if [[ "$baks_after" != "$baks_before" ]]; then
            echo "FAIL: ${label} -- .bak count went ${baks_before} -> ${baks_after}, expected no change" >&2
            exit 1
        fi
        if config_has_profile "$d" "csg-samplecorp"; then
            echo "FAIL: ${label} -- migration ran anyway (csg-samplecorp appeared)" >&2
            exit 1
        fi
        assert_pure_5key_stdout "${d}/stdout.json" "$label" || exit 1

        echo "PASS: ${label}"
    ) || return 1
    return 0
}

# run_hook_b3: THE ORDERING CONTRACT.
# `extract_cache_path` keys the cache on the ACCOUNT ID, not the profile name
# (Phase 18 collapse), so a freshly renamed `csg-X` inherits old `X`'s
# <account-id>.json -- normally an expired 1-hour session. Running migrate
# BEFORE the sweep therefore hands the sweep a brand-new `csg-X` that it
# immediately classifies as expired-with-cache and deletes: the mapping table
# claims N renames while the fleet ends up empty.
#
# The discriminating assertion is not "some csg- profile exists" (true under
# both orders) but "every rename the mapping table CLAIMS is still present in
# the config afterwards".
run_hook_b3() {
    local d="${WORK_DIR}/hookb3"; mkdir -p "$d"
    local label="HOOK-B-03: sweep runs BEFORE migrate -- every claimed rename survives, the stale legacy profile is swept, never renamed"
    require_real_aws "$label" || return 0
    (
        export HOME="$d"
        seed_env "$d" "xoxp-test-bearer-value"
        seed_broker_ok "$d"
        seed_legacy_config "$d"
        seed_expired_cache "$d" 222222222222   # -> stale-cust is sweep bait

        PATH="${STUB_DIR}:${PATH}" bash "$SCRIPT" --account-id 111111111111 --agent claude-code \
            >"${d}/stdout.json" 2>"${d}/stderr.txt"
        local rc=$?
        if [[ $rc -ne 0 ]]; then
            echo "FAIL: ${label} -- exit ${rc}, expected 0; stderr: $(cat "${d}/stderr.txt")" >&2
            exit 1
        fi

        # The sweep must have gone first and taken the expired legacy profile.
        if ! grep -Fq '[sweep] removed' "${d}/stderr.txt"; then
            echo "FAIL: ${label} -- the sweep never reported a removal; stderr: $(cat "${d}/stderr.txt")" >&2
            exit 1
        fi
        if config_has_profile "$d" "stale-cust"; then
            echo "FAIL: ${label} -- expired legacy profile 'stale-cust' survived the sweep" >&2
            exit 1
        fi
        # migrate-first would have renamed it to csg-stale-cust and the sweep
        # would then have deleted the fresh section.
        if config_has_profile "$d" "csg-stale-cust"; then
            echo "FAIL: ${label} -- csg-stale-cust exists, so migrate saw a profile the sweep should have removed first" >&2
            exit 1
        fi

        # Every mapping line's target must exist -- no rename may be claimed and lost.
        local claimed=0 new_name
        while IFS= read -r new_name; do
            [[ -n "$new_name" ]] || continue
            claimed=$((claimed + 1))
            if ! config_has_profile "$d" "$new_name"; then
                echo "FAIL: ${label} -- stderr claims '${new_name}' but no such section exists (migrate ran before the sweep?)" >&2
                exit 1
            fi
        done < <(sed -n 's/^\[migrate\] .* → \(csg-[A-Za-z0-9_.:@+-]*\)$/\1/p' "${d}/stderr.txt")

        if [[ $claimed -eq 0 ]]; then
            echo "FAIL: ${label} -- no rename was claimed at all; stderr: $(cat "${d}/stderr.txt")" >&2
            exit 1
        fi
        if ! config_has_profile "$d" "csg-samplecorp"; then
            echo "FAIL: ${label} -- the never-cached legacy profile was not migrated to csg-samplecorp" >&2
            exit 1
        fi
        assert_pure_5key_stdout "${d}/stdout.json" "$label" || exit 1

        echo "PASS: ${label}"
    ) || return 1
    return 0
}

# run_hook_b4: a failing migration must never break credential resolution -- the
# hook is `|| true` and the fail-closed abort (Pitfall 7) leaves no marker.
run_hook_b4() {
    local d="${WORK_DIR}/hookb4"; mkdir -p "$d"
    local label="HOOK-B-04: a fail-closed migration does not break credential resolution"
    require_real_aws "$label" || return 0
    (
        export HOME="$d"
        seed_env "$d" "xoxp-test-bearer-value"
        seed_broker_ok "$d"
        seed_bom_config "$d"      # unparseable to `aws configure`

        PATH="${STUB_DIR}:${PATH}" bash "$SCRIPT" --account-id 111111111111 --agent claude-code \
            >"${d}/stdout.json" 2>"${d}/stderr.txt"
        local rc=$?
        if [[ $rc -ne 0 ]]; then
            echo "FAIL: ${label} -- exit ${rc}, expected 0 (a migration failure must not be fatal)" >&2
            cat "${d}/stderr.txt" >&2
            exit 1
        fi
        assert_pure_5key_stdout "${d}/stdout.json" "$label" || exit 1

        if ! grep -Fq '[migrate] reason=config-unparseable' "${d}/stderr.txt"; then
            echo "FAIL: ${label} -- the migration did not fail closed; stderr: $(cat "${d}/stderr.txt")" >&2
            exit 1
        fi
        if [[ -f "$(migration_marker_path "$d")" ]]; then
            echo "FAIL: ${label} -- a completion marker was written on the fail-closed path (Pitfall 7)" >&2
            exit 1
        fi

        echo "PASS: ${label}"
    ) || return 1
    return 0
}

# =============================================================================
# STDOUT-0* -- the 5-key contract survives a hook-fired run (T-23-37)
# =============================================================================
# 23-RESEARCH flags this as the highest-value case class: `migrate` can be
# perfect when driven as a SUBCOMMAND (test/fleet-migrate.test.sh proves that)
# while the auto-hook still corrupts credential resolution, because the hook
# runs on a path whose stdout is a machine-readable contract. These cases drive
# the REAL main flow through the stub harness, not the `migrate` subcommand.

# run_stdout1: the incident machine, marker absent -> a real credential_process
# call migrates everything AND emits nothing but the 5-key JSON.
run_stdout1() {
    local d="${WORK_DIR}/stdout1"; mkdir -p "$d"
    local label="STDOUT-01: a hook-fired credential_process call on the incident machine emits ONLY the 5-key JSON"
    require_real_aws "$label" || return 0
    (
        export HOME="$d"
        seed_env "$d" "xoxp-test-bearer-value"
        seed_broker_ok "$d"
        seed_incident_config "$d"

        PATH="${STUB_DIR}:${PATH}" bash "$SCRIPT" --account-id 111111111111 --agent claude-code \
            >"${d}/stdout.json" 2>"${d}/stderr.txt"
        local rc=$?
        if [[ $rc -ne 0 ]]; then
            echo "FAIL: ${label} -- exit ${rc}, expected 0; stderr: $(cat "${d}/stderr.txt")" >&2
            exit 1
        fi

        # The hook must actually have fired, or this proves nothing.
        if [[ ! -f "$(migration_marker_path "$d")" ]]; then
            echo "FAIL: ${label} -- the migration never ran, so stdout purity was not exercised" >&2
            exit 1
        fi
        assert_stdout_is_only_json "${d}/stdout.json" "$label" || exit 1
        assert_pure_5key_stdout "${d}/stdout.json" "$label" || exit 1

        echo "PASS: ${label}"
    ) || return 1
    return 0
}

# run_stdout2: the summary is stderr-only (D-02) -- the mapping table must be
# visible THERE and nowhere near stdout.
run_stdout2() {
    local d="${WORK_DIR}/stdout2"; mkdir -p "$d"
    local label="STDOUT-02: the same run's [migrate] mapping table is on stderr, never on stdout"
    require_real_aws "$label" || return 0
    (
        export HOME="$d"
        seed_env "$d" "xoxp-test-bearer-value"
        seed_broker_ok "$d"
        seed_incident_config "$d"

        PATH="${STUB_DIR}:${PATH}" bash "$SCRIPT" --account-id 111111111111 --agent claude-code \
            >"${d}/stdout.json" 2>"${d}/stderr.txt"
        local rc=$?
        if [[ $rc -ne 0 ]]; then
            echo "FAIL: ${label} -- exit ${rc}, expected 0" >&2
            exit 1
        fi

        if ! grep -qE '^\[migrate\] .+ → csg-' "${d}/stderr.txt"; then
            echo "FAIL: ${label} -- no mapping table on stderr: $(cat "${d}/stderr.txt")" >&2
            exit 1
        fi
        if grep -q '\[migrate\]' "${d}/stdout.json"; then
            echo "FAIL: ${label} -- a [migrate] line reached stdout: $(cat "${d}/stdout.json")" >&2
            exit 1
        fi
        assert_stdout_is_only_json "${d}/stdout.json" "$label" || exit 1

        echo "PASS: ${label}"
    ) || return 1
    return 0
}

# run_stdout3: the `register` CHILD prints the new profile name on ITS stdout on
# success. That descriptor is inherited unless the parent captures it, so this
# case requires a fixture whose rename actually succeeds.
run_stdout3() {
    local d="${WORK_DIR}/stdout3"; mkdir -p "$d"
    local label="STDOUT-03: the register child's success line does not leak into the parent's stdout"
    require_real_aws "$label" || return 0
    (
        export HOME="$d"
        seed_env "$d" "xoxp-test-bearer-value"
        seed_broker_ok "$d"
        seed_legacy_config "$d"     # `samplecorp` has no cache -> its rename WILL succeed

        PATH="${STUB_DIR}:${PATH}" bash "$SCRIPT" --account-id 111111111111 --agent claude-code \
            >"${d}/stdout.json" 2>"${d}/stderr.txt"
        local rc=$?
        if [[ $rc -ne 0 ]]; then
            echo "FAIL: ${label} -- exit ${rc}, expected 0; stderr: $(cat "${d}/stderr.txt")" >&2
            exit 1
        fi

        # A rename must genuinely have happened, or the child never printed.
        if ! config_has_profile "$d" "csg-samplecorp"; then
            echo "FAIL: ${label} -- no rename occurred, so the child produced no success line to leak" >&2
            exit 1
        fi
        if grep -q 'csg-samplecorp' "${d}/stdout.json"; then
            echo "FAIL: ${label} -- the child's profile-name line leaked to stdout: $(cat "${d}/stdout.json")" >&2
            exit 1
        fi
        assert_stdout_is_only_json "${d}/stdout.json" "$label" || exit 1

        echo "PASS: ${label}"
    ) || return 1
    return 0
}

# run_stdout4: a class-H collision makes migrate report a reason token and keep
# going. stdout must be unaffected.
run_stdout4() {
    local d="${WORK_DIR}/stdout4"; mkdir -p "$d"
    local label="STDOUT-04: a name-collision run still emits ONLY the 5-key JSON"
    require_real_aws "$label" || return 0
    (
        export HOME="$d"
        seed_env "$d" "xoxp-test-bearer-value"
        seed_broker_ok "$d"
        seed_collision_config "$d"

        PATH="${STUB_DIR}:${PATH}" bash "$SCRIPT" --account-id 111111111111 --agent claude-code \
            >"${d}/stdout.json" 2>"${d}/stderr.txt"
        local rc=$?
        if [[ $rc -ne 0 ]]; then
            echo "FAIL: ${label} -- exit ${rc}, expected 0; stderr: $(cat "${d}/stderr.txt")" >&2
            exit 1
        fi

        if ! grep -qF -- '[migrate] reason=name-collision' "${d}/stderr.txt"; then
            echo "FAIL: ${label} -- the collision was not reported; stderr: $(cat "${d}/stderr.txt")" >&2
            exit 1
        fi
        # D-07: the old section survives a collision -- losing it would lose data.
        if ! config_has_profile "$d" "acme"; then
            echo "FAIL: ${label} -- the colliding legacy profile 'acme' was deleted" >&2
            exit 1
        fi
        # ...and a collision must not abort the run: the unrelated profile still migrates.
        if ! config_has_profile "$d" "csg-other"; then
            echo "FAIL: ${label} -- the unrelated profile was not migrated; a collision aborted the run" >&2
            exit 1
        fi
        assert_stdout_is_only_json "${d}/stdout.json" "$label" || exit 1
        assert_pure_5key_stdout "${d}/stdout.json" "$label" || exit 1

        echo "PASS: ${label}"
    ) || return 1
    return 0
}

# -- SCP-05 fan-out brake cases -------------------------------------------------
# What these cases prove: 결정론적 거부와 기록 -- a deterministic refusal plus a
# durable local record. They deliberately do NOT assert that a fan-out is
# impossible. An agent owns the shell and can call `scope-ack` itself (T-24-02,
# accepted); the backstop that does not depend on the agent's cooperation is
# server-side (Phase 25 DET-01).

# run_scope1: the 12-in-54s incident, reproduced from BOTH sides of the boundary.
#
# MUTATION CHECK (verified): commenting out the `# --- SCP-05 fan-out brake`
# block in get-customer-credentials.sh makes the refusal half fail (exit 0 where
# 1 is required); changing `(( scope_count > SCOPE_MAX_ACCOUNTS ))` to `>=` makes
# the boundary half fail (the FIFTH account is refused one account early).
run_scope1() {
    local d="${WORK_DIR}/scope1"; mkdir -p "$d"
    local label="SCP-05: the 6th distinct unapproved account in the window is refused (12-in-54s shape)"
    (
        export HOME="$d"
        seed_env "$d" "xoxp-test-bearer-value"
        seed_broker_ok "$d"
        # HOOK-B short-circuit: without the marker this fixture drives the whole
        # auto-migration and the case would be measuring the migration, not the brake.
        seed_migration_marker "$d"

        local a1 a2 a3 a4 a5 a6 a99
        a1=$(scope_acct 5 1); a2=$(scope_acct 5 2); a3=$(scope_acct 5 3)
        a4=$(scope_acct 5 4); a5=$(scope_acct 5 5); a6=$(scope_acct 5 6)
        a99=$(scope_acct 5 99)

        # The incident's own cadence: four distinct accounts inside a minute.
        seed_scope_window "$d" 54 "$a1"
        seed_scope_window "$d" 44 "$a2"
        seed_scope_window "$d" 34 "$a3"
        seed_scope_window "$d" 24 "$a4"
        # ... plus one record 400 seconds old, i.e. OUTSIDE the 300s window.
        seed_scope_window "$d" 400 "$a99"

        # --- the N=5 boundary, asserted from the PASSING side -----------------
        # This is the off-by-one guard, not a warm-up. D-02 is "6번째 distinct
        # 계정의 신규 발급부터 거부", so the fifth must still pass. Without this
        # half, a `>=` where the code needs `>` (or a cutoff that counted the
        # 400-second-old record) refuses one account early and every remaining
        # assertion below still goes green -- they only ever check that SOMETHING
        # was refused.
        local rc5
        rc5=$(run_cred_watchdog "${d}/five" "$a5" 20)
        if [[ "$rc5" != "0" ]]; then
            echo "FAIL: ${label} -- 5th distinct account exited ${rc5}, expected 0 (N=5 boundary)" >&2
            cat "${d}/five/stderr.txt" >&2
            exit 1
        fi
        assert_pure_5key_stdout "${d}/five/stdout.json" "$label" || exit 1
        local n5; n5=$(curl_call_count "$d")
        if [[ "$n5" != "1" ]]; then
            echo "FAIL: ${label} -- 5th account made ${n5} curl calls, expected 1" >&2
            exit 1
        fi
        # append-then-count: this invocation's OWN record is on disk, and the
        # 400-second-old one has been pruned away by the same invocation.
        if ! scope_window_has "$d" "$a5"; then
            echo "FAIL: ${label} -- the 5th account's own window record was not written" >&2
            exit 1
        fi
        if scope_window_has "$d" "$a99"; then
            echo "FAIL: ${label} -- the 400s-old record survived the prune" >&2
            exit 1
        fi
        local wl5; wl5=$(scope_window_lines "$d")
        if [[ "$wl5" != "5" ]]; then
            echo "FAIL: ${label} -- window holds ${wl5} records after the 5th run, expected 5" >&2
            exit 1
        fi

        # --- the refusal ------------------------------------------------------
        local before_curl; before_curl=$(curl_call_count "$d")
        local rc6
        rc6=$(run_cred_watchdog "${d}/six" "$a6" 20)
        # rc EXACTLY 1, not merely non-zero: die and scope_refuse must not be
        # conflated, and if a later change turns the refusal into rc 2 this case
        # should say so.
        if [[ "$rc6" != "1" ]]; then
            echo "FAIL: ${label} -- 6th distinct account exited ${rc6}, expected 1" >&2
            cat "${d}/six/stderr.txt" >&2
            exit 1
        fi
        if [[ -s "${d}/six/stdout.json" ]]; then
            echo "FAIL: ${label} -- refusal wrote to stdout: $(head -3 "${d}/six/stdout.json")" >&2
            exit 1
        fi
        local tok; tok=$(grep -c '^\[scope\] reason=fan-out-threshold' "${d}/six/stderr.txt")
        if [[ "$tok" != "1" ]]; then
            echo "FAIL: ${label} -- reason token appeared ${tok}x, expected exactly 1" >&2
            cat "${d}/six/stderr.txt" >&2
            exit 1
        fi

        # Pitfall 4: the copy-pasteable retry is the LAST thing the agent reads.
        # A [sweep]/[migrate] line written later in the same invocation must not
        # be able to bury it.
        local last retry_re='scope-ack --account-ids [0-9][0-9,]*$'
        last=$(grep -v '^[[:space:]]*$' "${d}/six/stderr.txt" | tail -n 1)
        if ! [[ "$last" =~ $retry_re ]]; then
            echo "FAIL: ${label} -- last stderr line is not the retry command: [${last}]" >&2
            exit 1
        fi
        # All SIX ids, including the one just refused. append-then-count puts the
        # refused invocation's own record in the window before the count is read,
        # so a retry command that omitted it would refuse again on the
        # copy-paste -- a silently useless instruction.
        local want
        for want in "$a1" "$a2" "$a3" "$a4" "$a5" "$a6"; do
            case "$last" in
                *"$want"*) ;;
                *) echo "FAIL: ${label} -- retry line omits ${want}: [${last}]" >&2; exit 1 ;;
            esac
        done
        # ... and NOT the 400-second-old id: the sliding window applies to the
        # message as well as to the count.
        case "$last" in
            *"$a99"*) echo "FAIL: ${label} -- retry line carries the out-of-window id ${a99}" >&2; exit 1 ;;
        esac

        # The brake sits before the broker POST, so a refusal costs no call.
        local after_curl; after_curl=$(curl_call_count "$d")
        if [[ "$after_curl" != "$before_curl" ]]; then
            echo "FAIL: ${label} -- refusal made $((after_curl - before_curl)) curl call(s), expected 0" >&2
            exit 1
        fi
        if [[ -f "${d}/.cache/msp/customer-creds/${a6}.json" ]]; then
            echo "FAIL: ${label} -- a cache file was written for the refused account" >&2
            exit 1
        fi

        echo "PASS: ${label}"
    ) || return 1
    return 0
}

# run_scope2: D-06 is TWO rules, and both are asserted here.
#
# MUTATION CHECK (verified): deleting the `case ",${scope_acks},"` membership
# test in the brake block makes the first half fail -- the acked account would be
# refused for its neighbours' behaviour.
run_scope2() {
    local d="${WORK_DIR}/scope2"; mkdir -p "$d"
    local label="SCP-05/D-06: an acked account passes with 6 unapproved neighbours; an out-of-set account is still counted and refused"
    (
        export HOME="$d"
        seed_env "$d" "xoxp-test-bearer-value"
        seed_broker_ok "$d"
        seed_migration_marker "$d"

        local ack1 ack2 out
        ack1=$(scope_acct 6 1); ack2=$(scope_acct 6 2); out=$(scope_acct 9 99)

        # Six distinct unapproved accounts -- already over the allowance of 5.
        seed_scope_window "$d" 50 "$(scope_acct 5 1)"
        seed_scope_window "$d" 40 "$(scope_acct 5 2)"
        seed_scope_window "$d" 30 "$(scope_acct 5 3)"
        seed_scope_window "$d" 20 "$(scope_acct 5 4)"
        seed_scope_window "$d" 10 "$(scope_acct 5 5)"
        seed_scope_window "$d"  5 "$(scope_acct 5 6)"

        set +e
        PATH="${STUB_DIR}:${PATH}" bash "$SCRIPT" scope-ack --account-ids "${ack1},${ack2}" \
            >"${d}/ack.out" 2>"${d}/ack.err" </dev/null
        local ack_rc=$?
        set -e
        if [[ $ack_rc -ne 0 ]]; then
            echo "FAIL: ${label} -- scope-ack exited ${ack_rc}, expected 0: $(cat "${d}/ack.err")" >&2
            exit 1
        fi
        local acks; acks=$(wc -l < "${d}/.cache/msp/customer-creds/scope-acks.jsonl" | tr -d ' ')
        if [[ "$acks" != "1" ]]; then
            echo "FAIL: ${label} -- scope-acks.jsonl holds ${acks} lines after one ack, expected 1" >&2
            exit 1
        fi

        # Half one: the acked account PASSES even though six unapproved accounts
        # sit in the window. This is the half a naive implementation gets wrong.
        local rc_ok
        rc_ok=$(run_cred_watchdog "${d}/acked" "$ack1" 20)
        if [[ "$rc_ok" != "0" ]]; then
            echo "FAIL: ${label} -- acked account exited ${rc_ok}, expected 0" >&2
            cat "${d}/acked/stderr.txt" >&2
            exit 1
        fi
        assert_pure_5key_stdout "${d}/acked/stdout.json" "$label" || exit 1
        local nc; nc=$(curl_call_count "$d")
        if [[ "$nc" != "1" ]]; then
            echo "FAIL: ${label} -- acked account made ${nc} curl calls, expected 1" >&2
            exit 1
        fi

        # Half two: an account OUTSIDE the set is still counted and still refused.
        local rc_no
        rc_no=$(run_cred_watchdog "${d}/unacked" "$out" 20)
        if [[ "$rc_no" != "1" ]]; then
            echo "FAIL: ${label} -- out-of-set account exited ${rc_no}, expected 1" >&2
            exit 1
        fi
        if [[ -s "${d}/unacked/stdout.json" ]]; then
            echo "FAIL: ${label} -- refusal wrote to stdout: $(head -3 "${d}/unacked/stdout.json")" >&2
            exit 1
        fi
        if ! grep -q '^\[scope\] reason=fan-out-threshold' "${d}/unacked/stderr.txt"; then
            echo "FAIL: ${label} -- refusal token missing: $(cat "${d}/unacked/stderr.txt")" >&2
            exit 1
        fi
        # RESEARCH A3: acked ids are excluded from the count AND from the message,
        # so a legitimately approved 12-account batch cannot block an unrelated
        # 13th by inflating the list.
        local last
        last=$(grep -v '^[[:space:]]*$' "${d}/unacked/stderr.txt" | tail -n 1)
        case "$last" in
            *"$ack1"*|*"$ack2"*)
                echo "FAIL: ${label} -- an acked id leaked into the retry line: [${last}]" >&2
                exit 1 ;;
        esac

        echo "PASS: ${label}"
    ) || return 1
    return 0
}

# run_scope3: ack TTL and union semantics, observed entirely from the outside --
# this case never reads SCOPE_ACK_TTL_SECONDS, it seeds an expiresAt the reader
# has to reject.
#
# MUTATION CHECK (verified): changing scope_ack_set's `expiresAt > now` filter to
# unconditional makes phase 1 fail (the expired record would exempt the account).
run_scope3() {
    local d="${WORK_DIR}/scope3"; mkdir -p "$d"
    local label="SCP-05/D-06: an expired ack exempts nothing; a re-ack restores; two acks UNION rather than replace"
    (
        export HOME="$d"
        seed_env "$d" "xoxp-test-bearer-value"
        seed_broker_ok "$d"
        seed_migration_marker "$d"

        local b1 b2 b3 b4 out
        b1=$(scope_acct 6 1); b2=$(scope_acct 6 2)
        b3=$(scope_acct 6 3); b4=$(scope_acct 6 4)
        out=$(scope_acct 9 99)

        seed_scope_window "$d" 50 "$(scope_acct 5 1)"
        seed_scope_window "$d" 40 "$(scope_acct 5 2)"
        seed_scope_window "$d" 30 "$(scope_acct 5 3)"
        seed_scope_window "$d" 20 "$(scope_acct 5 4)"
        seed_scope_window "$d" 10 "$(scope_acct 5 5)"
        seed_scope_window "$d"  5 "$(scope_acct 5 6)"

        # -- phase 1: an ack whose expiresAt is 60 seconds in the PAST ---------
        seed_scope_ack "$d" -60 "$b1" "$b2"
        local rc1
        rc1=$(run_cred_watchdog "${d}/expired" "$b1" 20)
        if [[ "$rc1" != "1" ]]; then
            echo "FAIL: ${label} -- expired ack still exempted the account (exit ${rc1}, expected 1)" >&2
            exit 1
        fi
        if ! grep -q '^\[scope\] reason=fan-out-threshold' "${d}/expired/stderr.txt"; then
            echo "FAIL: ${label} -- expired-ack refusal carries no reason token" >&2
            exit 1
        fi

        # -- phase 2: a fresh scope-ack restores the pass ----------------------
        # The expired record is still in the file (append-only, no tombstone) and
        # the fresh one wins.
        set +e
        PATH="${STUB_DIR}:${PATH}" bash "$SCRIPT" scope-ack --account-ids "${b1},${b2}" \
            >/dev/null 2>"${d}/ack1.err" </dev/null
        local ar1=$?
        set -e
        if [[ $ar1 -ne 0 ]]; then
            echo "FAIL: ${label} -- first scope-ack exited ${ar1}: $(cat "${d}/ack1.err")" >&2
            exit 1
        fi
        local rc2
        rc2=$(run_cred_watchdog "${d}/reacked" "$b1" 20)
        if [[ "$rc2" != "0" ]]; then
            echo "FAIL: ${label} -- re-acked account exited ${rc2}, expected 0" >&2
            cat "${d}/reacked/stderr.txt" >&2
            exit 1
        fi
        assert_pure_5key_stdout "${d}/reacked/stdout.json" "$label" || exit 1

        # -- phase 3: a SECOND scope-ack must UNION, not replace ---------------
        set +e
        PATH="${STUB_DIR}:${PATH}" bash "$SCRIPT" scope-ack --account-ids "${b3},${b4}" \
            >/dev/null 2>"${d}/ack2.err" </dev/null
        local ar2=$?
        set -e
        if [[ $ar2 -ne 0 ]]; then
            echo "FAIL: ${label} -- second scope-ack exited ${ar2}: $(cat "${d}/ack2.err")" >&2
            exit 1
        fi
        local acks; acks=$(wc -l < "${d}/.cache/msp/customer-creds/scope-acks.jsonl" | tr -d ' ')
        if [[ "$acks" != "3" ]]; then
            echo "FAIL: ${label} -- scope-acks.jsonl holds ${acks} lines, expected 3 (expired + two acks)" >&2
            exit 1
        fi
        local rc3
        rc3=$(run_cred_watchdog "${d}/second-pair" "$b3" 20)
        if [[ "$rc3" != "0" ]]; then
            echo "FAIL: ${label} -- the second ack's account exited ${rc3}, expected 0" >&2
            exit 1
        fi
        # The union assertion: if the second scope-ack had REPLACED the set, this
        # account would now be refused and D-16's resume-without-re-ack would be
        # broken.
        local rc4
        rc4=$(run_cred_watchdog "${d}/first-pair" "$b2" 20)
        if [[ "$rc4" != "0" ]]; then
            echo "FAIL: ${label} -- the first ack's account exited ${rc4} after a second ack (replace, not union)" >&2
            exit 1
        fi
        # Control: a never-acked account is still refused, which is what proves
        # the passes above came from the ack set and not from a window that had
        # drifted below the allowance.
        local rc5
        rc5=$(run_cred_watchdog "${d}/control" "$out" 20)
        if [[ "$rc5" != "1" ]]; then
            echo "FAIL: ${label} -- control (never acked) exited ${rc5}, expected 1" >&2
            exit 1
        fi

        echo "PASS: ${label}"
    ) || return 1
    return 0
}

# run_scope4: the SC5 stream contract, with stdin closed and a real time budget.
#
# MUTATION CHECK (verified): adding any printf to fd 1 inside scope_refuse makes
# the refuse half fail on the zero-byte assertion.
run_scope4() {
    local d="${WORK_DIR}/scope4"; mkdir -p "$d"
    local label="SCP-05/SC5: pass path emits ONLY the 5-key JSON; refuse path emits zero bytes; both run with no TTY and refuse in <2s"
    (
        # -- pass ---------------------------------------------------------------
        (
            local p="${d}/pass"; mkdir -p "$p"
            export HOME="$p"
            seed_env "$p" "xoxp-test-bearer-value"
            seed_broker_ok "$p"
            seed_migration_marker "$p"

            # 50 deciseconds, deliberately LOOSER than the refusal's budget: this
            # path may still spawn the real `aws` binary for the migration hook,
            # and SC5's <2s budget is about the REFUSAL. Do not tighten this into
            # a flake.
            local rc
            rc=$(run_cred_watchdog "${p}/run" "$(scope_acct 5 1)" 50)
            if [[ "$rc" != "0" ]]; then
                echo "FAIL: ${label} -- pass path exited ${rc}, expected 0" >&2
                cat "${p}/run/stderr.txt" >&2
                exit 1
            fi
            # Both assertions: the first proves nothing was written before or
            # after the JSON, the second proves the key set.
            assert_stdout_is_only_json "${p}/run/stdout.json" "$label" || exit 1
            assert_pure_5key_stdout "${p}/run/stdout.json" "$label" || exit 1
            local wl; wl=$(scope_window_lines "$p")
            if [[ "$wl" != "1" ]]; then
                echo "FAIL: ${label} -- pass path wrote ${wl} window records, expected 1" >&2
                exit 1
            fi
        ) || exit 1

        # -- refuse -------------------------------------------------------------
        (
            local r="${d}/refuse"; mkdir -p "$r"
            export HOME="$r"
            seed_env "$r" "xoxp-test-bearer-value"
            seed_broker_ok "$r"
            seed_migration_marker "$r"
            seed_scope_window "$r" 54 "$(scope_acct 5 1)"
            seed_scope_window "$r" 44 "$(scope_acct 5 2)"
            seed_scope_window "$r" 34 "$(scope_acct 5 3)"
            seed_scope_window "$r" 24 "$(scope_acct 5 4)"
            seed_scope_window "$r" 14 "$(scope_acct 5 5)"

            local rc
            rc=$(run_cred_watchdog "${r}/run" "$(scope_acct 5 6)" 20)
            if [[ "$rc" == "124" ]]; then
                echo "FAIL: ${label} -- refusal did not complete within 2s (SC5: no prompt, no TTY dependence, fail fast)" >&2
                exit 1
            fi
            if [[ "$rc" != "1" ]]; then
                echo "FAIL: ${label} -- refusal exited ${rc}, expected 1" >&2
                exit 1
            fi
            if [[ -s "${r}/run/stdout.json" ]]; then
                echo "FAIL: ${label} -- refusal wrote to stdout: $(head -3 "${r}/run/stdout.json")" >&2
                exit 1
            fi

            # Optional TTY hardening. setsid is absent on a stock macOS, so
            # `</dev/null` above is the portable primary mechanism and the static
            # "no read, no prompt" gates in 24-01/24-02 cover the rest. A case
            # that hard-required setsid would simply not run on half the fleet.
            if command -v setsid >/dev/null 2>&1; then
                set +e
                PATH="${STUB_DIR}:${PATH}" setsid bash "$SCRIPT" --account-id "$(scope_acct 5 7)" --agent claude-code \
                    >"${r}/setsid.out" 2>"${r}/setsid.err" </dev/null
                local src=$?
                set -e
                if [[ $src -ne 1 ]]; then
                    echo "FAIL: ${label} -- refusal under setsid exited ${src}, expected 1" >&2
                    exit 1
                fi
                if [[ -s "${r}/setsid.out" ]]; then
                    echo "FAIL: ${label} -- refusal under setsid wrote to stdout" >&2
                    exit 1
                fi
            fi
        ) || exit 1

        echo "PASS: ${label}"
    ) || return 1
    return 0
}

# run_scope5: D-01's counting unit is the NEW-ISSUANCE ATTEMPT -- not the cache
# read above it, and not the HTTP call below it.
#
# MUTATION CHECK (verified): hoisting `scope_window_append` above
# `if emit_from_cache; then exit 0; fi` makes a cache HIT consume window budget
# (records go 2 -> 2 instead of 1 -> 1); moving the same call INSIDE the retry
# loop makes it fire once per HTTP call instead of once per invocation. Both turn
# this case red.
run_scope5() {
    local d="${WORK_DIR}/scope5"; mkdir -p "$d"
    local label="SCP-05/D-01: a cache HIT writes no window record; a 503->503->200 retry writes exactly one"
    (
        # -- cache HIT ----------------------------------------------------------
        (
            local h="${d}/hit"; mkdir -p "$h"
            export HOME="$h"
            seed_env "$h" "xoxp-test-bearer-value"
            seed_broker_ok "$h"
            seed_migration_marker "$h"

            local acct; acct=$(scope_acct 5 1)
            local rc1 rc2
            rc1=$(run_cred_watchdog "${h}/first" "$acct" 50)
            if [[ "$rc1" != "0" ]]; then
                echo "FAIL: ${label} -- first run exited ${rc1}, expected 0" >&2
                cat "${h}/first/stderr.txt" >&2
                exit 1
            fi
            local c1 w1; c1=$(curl_call_count "$h"); w1=$(scope_window_lines "$h")
            rc2=$(run_cred_watchdog "${h}/second" "$acct" 50)
            if [[ "$rc2" != "0" ]]; then
                echo "FAIL: ${label} -- warm run exited ${rc2}, expected 0" >&2
                exit 1
            fi
            local c2 w2; c2=$(curl_call_count "$h"); w2=$(scope_window_lines "$h")
            if [[ "$c1" != "1" || "$c2" != "1" ]]; then
                echo "FAIL: ${label} -- curl calls went ${c1} -> ${c2}, expected 1 -> 1 (2nd is a cache HIT)" >&2
                exit 1
            fi
            # The counting unit is the NEW issuance; a cache HIT is a reuse of an
            # existing session. If a HIT consumed window budget, five customers'
            # worth of routine re-reads inside five minutes would refuse the
            # sixth -- "정상 3계정 비교도 걸려 override 일상화", which is exactly
            # the failure mode D-02 rejected N=3/60s to avoid. The guarantee is
            # POSITIONAL (the brake sits below `if emit_from_cache; then exit 0;
            # fi`), so this case is what notices if the block ever moves.
            if [[ "$w1" != "1" || "$w2" != "1" ]]; then
                echo "FAIL: ${label} -- window records went ${w1} -> ${w2}, expected 1 -> 1" >&2
                exit 1
            fi
        ) || exit 1

        # -- 503 -> 503 -> 200 inside ONE invocation ----------------------------
        (
            local r="${d}/retry"; mkdir -p "$r"
            export HOME="$r"
            local acct; acct=$(scope_acct 5 2)
            seed_env "$r" "xoxp-test-bearer-value"
            seed_broker_ok "$r"
            seed_migration_marker "$r"
            # A stale cache forces the broker call the sequence is about.
            seed_expired_cache "$r" "$acct"
            seed_status_seq "$r" 503 503 200

            # 100 deciseconds, deliberately generous: the client sleeps 1s then 2s
            # between attempts. SC5's <2s budget is a property of the REFUSAL, not
            # of a legitimate bounded retry -- a timing assertion here would be
            # asserting Phase 19's backoff contract, not this phase's.
            local rc
            rc=$(run_cred_watchdog "${r}/run" "$acct" 100)
            if [[ "$rc" != "0" ]]; then
                echo "FAIL: ${label} -- 503->503->200 exited ${rc}, expected 0" >&2
                cat "${r}/run/stderr.txt" >&2
                exit 1
            fi
            assert_pure_5key_stdout "${r}/run/stdout.json" "$label" || exit 1
            local n; n=$(curl_call_count "$r")
            if [[ "$n" != "3" ]]; then
                echo "FAIL: ${label} -- the status sequence produced ${n} curl calls, expected 3" >&2
                exit 1
            fi
            # Pitfall 9: a brake check placed inside the retry loop would write
            # three records here and could refuse on the second retry of a
            # legitimate 5xx recovery -- turning a broker hiccup into a fan-out
            # accusation.
            local w; w=$(scope_window_lines "$r")
            if [[ "$w" != "1" ]]; then
                echo "FAIL: ${label} -- one invocation over 3 HTTP calls wrote ${w} window records, expected 1" >&2
                exit 1
            fi
        ) || exit 1

        echo "PASS: ${label}"
    ) || return 1
    return 0
}

# run_scope6: scope-ack validates EVERY element before dedupe, before the >=2
# arity check and before any file write (T-24-08, V5).
#
# MUTATION CHECK (verified): moving the `(( n < 2 ))` arity check ahead of the
# per-element regex flips the `1,2` row's token from invalid-account-id to
# invalid-arguments and this case fails on it.
run_scope6() {
    local d="${WORK_DIR}/scope6"; mkdir -p "$d"
    local label="SCP-05/T-24-08: scope-ack validates every id before any write; injection inputs create no record"
    (
        local a1 a2
        a1=$(scope_acct 5 1); a2=$(scope_acct 5 2)

        # -- abort rows ---------------------------------------------------------
        (
            local ab="${d}/abort"; mkdir -p "$ab"
            export HOME="$ab"

            # <expected-token>|<input>. Split on the FIRST '|' only; no input
            # below contains one. The last row carries a real newline.
            local rows=(
                "invalid-account-id|1,2"
                "invalid-arguments|${a1}"
                "invalid-arguments|${a1},${a1}"
                "invalid-arguments|"
                "invalid-account-id|${a1}\",\"x\":\"y"
                "invalid-account-id|${a1},{\"a\":1}"
            )
            rows+=("invalid-account-id|${a1},${a2}"$'\n''{"ts":0,"accountId":"999999999999"}')

            local i=0 row token input rc first
            for row in "${rows[@]}"; do
                i=$((i + 1))
                token="${row%%|*}"
                input="${row#*|}"
                set +e
                PATH="${STUB_DIR}:${PATH}" bash "$SCRIPT" scope-ack --account-ids "$input" \
                    >"${ab}/o.${i}" 2>"${ab}/e.${i}" </dev/null
                rc=$?
                set -e
                if [[ $rc -ne 1 ]]; then
                    echo "FAIL: ${label} -- row ${i} exited ${rc}, expected 1" >&2
                    exit 1
                fi
                if [[ -s "${ab}/o.${i}" ]]; then
                    echo "FAIL: ${label} -- row ${i} wrote to stdout: $(head -3 "${ab}/o.${i}")" >&2
                    exit 1
                fi
                # -Fqx, never a substring match: a substring test would pass on a
                # token that merely CONTAINS the expected one.
                first=$(head -n 1 "${ab}/e.${i}")
                if ! grep -Fqx -- "[scope-ack] reason=${token}" <<< "$first"; then
                    echo "FAIL: ${label} -- row ${i} first stderr line was [${first}], expected [[scope-ack] reason=${token}]" >&2
                    exit 1
                fi
                # Log injection: the newline row's payload must not be able to
                # produce an unprefixed line a log reader would attribute to the
                # tool. scope-ack routes before the main parser and before
                # sweep/migrate, so no other prefix can legitimately appear on
                # this path -- which is what makes the assertion exact rather
                # than heuristic.
                local unprefixed
                unprefixed=$(grep -v '^[[:space:]]*$' "${ab}/e.${i}" | grep -cv '^\[scope-ack\] ')
                if [[ "$unprefixed" != "0" ]]; then
                    echo "FAIL: ${label} -- row ${i} emitted ${unprefixed} stderr line(s) without the [scope-ack] prefix" >&2
                    cat "${ab}/e.${i}" >&2
                    exit 1
                fi
            done

            # `1,2` is rejected before the >=2 check and every injection row is
            # rejected before any write, so nothing may exist here at all. That
            # ordering is what makes the token honest: a user who typed a short
            # id is told the id is wrong, not that they need more accounts.
            if [[ -e "${ab}/.cache/msp/customer-creds/scope-acks.jsonl" ]]; then
                echo "FAIL: ${label} -- an aborted scope-ack created scope-acks.jsonl" >&2
                cat "${ab}/.cache/msp/customer-creds/scope-acks.jsonl" >&2
                exit 1
            fi
        ) || exit 1

        # -- the success row ----------------------------------------------------
        (
            local ok="${d}/ok"; mkdir -p "$ok"
            export HOME="$ok"
            set +e
            PATH="${STUB_DIR}:${PATH}" bash "$SCRIPT" scope-ack --account-ids "${a1},${a2},${a1}" \
                >"${ok}/out" 2>"${ok}/err" </dev/null
            local rc=$?
            set -e
            if [[ $rc -ne 0 ]]; then
                echo "FAIL: ${label} -- success row exited ${rc}: $(cat "${ok}/err")" >&2
                exit 1
            fi
            local lines; lines=$(wc -l < "${ok}/out" | tr -d ' ')
            if [[ "$lines" != "1" ]]; then
                echo "FAIL: ${label} -- success stdout is ${lines} lines, expected exactly 1" >&2
                exit 1
            fi
            if ! grep -Fq 'scope-ack: 2 accounts approved until ' "${ok}/out"; then
                echo "FAIL: ${label} -- success stdout was [$(cat "${ok}/out")]" >&2
                exit 1
            fi
            # The no-brace rule is structural: this line must be impossible to
            # confuse with the 5-key JSON contract even if a reader captures the
            # wrong stream (T-24-05).
            if grep -q '[{}]' "${ok}/out"; then
                echo "FAIL: ${label} -- success stdout carries a brace: [$(cat "${ok}/out")]" >&2
                exit 1
            fi
            local errlines; errlines=$(grep -c '^\[scope-ack\] ' "${ok}/err")
            if [[ "$errlines" != "1" ]]; then
                echo "FAIL: ${label} -- success stderr carries ${errlines} [scope-ack] lines, expected 1" >&2
                exit 1
            fi
            local rec="${ok}/.cache/msp/customer-creds/scope-acks.jsonl"
            local reclines; reclines=$(wc -l < "$rec" | tr -d ' ')
            if [[ "$reclines" != "1" ]]; then
                echo "FAIL: ${label} -- scope-acks.jsonl holds ${reclines} lines, expected 1" >&2
                exit 1
            fi
            # Deduped, first-seen order, no third element.
            if ! grep -Eq "^\{\"ts\":[0-9]+,\"expiresAt\":[0-9]+,\"accountIds\":\[\"${a1}\",\"${a2}\"\],\"count\":2\}$" "$rec"; then
                echo "FAIL: ${label} -- ack record was [$(cat "$rec")]" >&2
                exit 1
            fi
        ) || exit 1

        echo "PASS: ${label}"
    ) || return 1
    return 0
}

# run_scope7: the fail-open / fail-closed ASYMMETRY, stated as three fixtures.
#
# Fail OPEN on the window: a lost record under-counts, which is the safe
# direction, and breaking a legitimate single-account read is strictly worse than
# missing one fan-out (CLAUDE.md Core Value). Fail CLOSED-ish on the ack: an
# unreadable approval is not an approval, and granting an unrequested override is
# worse than both.
#
# 24-01's scope_ack_set already returns the empty set on garbage (it keeps only
# length-12 digit elements), so fixture 3 passes by construction today. The case
# exists so that a later "improvement" into a permissive ack parser is caught.
#
# MUTATION CHECK (verified): making the brake die on an unparseable window line
# instead of ignoring it turns fixture 1 red; making an unreadable ack file
# set scope_acked=true -- the permissive-parser shape -- turns fixture 3 red.
run_scope7() {
    local d="${WORK_DIR}/scope7"; mkdir -p "$d"
    local label="SCP-05: a corrupt or garbage brake state file passes (fail-open), it never breaks a single-account issuance"
    (
        # -- 1. garbage, random bytes and an unterminated final line ------------
        (
            local g="${d}/garbage"; mkdir -p "$g"
            export HOME="$g"
            seed_env "$g" "xoxp-test-bearer-value"
            seed_broker_ok "$g"
            seed_migration_marker "$g"
            local f="${g}/.cache/msp/customer-creds/scope-window.jsonl"
            mkdir -p "$(dirname "$f")"
            printf 'garbage not json\n' > "$f"
            printf '{"ts":"abc","accountId":"zz"}\n' >> "$f"
            head -c 512 /dev/urandom >> "$f"
            printf '\n{"ts":1,"accountId":"nope"' >> "$f"

            local rc
            rc=$(run_cred_watchdog "${g}/run" "$(scope_acct 5 1)" 50)
            if [[ "$rc" != "0" ]]; then
                echo "FAIL: ${label} -- a garbage window file broke a single-account issuance (exit ${rc})" >&2
                cat "${g}/run/stderr.txt" >&2
                exit 1
            fi
            assert_pure_5key_stdout "${g}/run/stdout.json" "$label" || exit 1
        ) || exit 1

        # -- 2. a zero-byte window file (the shape a killed writer leaves) ------
        (
            local z="${d}/empty"; mkdir -p "$z"
            export HOME="$z"
            seed_env "$z" "xoxp-test-bearer-value"
            seed_broker_ok "$z"
            seed_migration_marker "$z"
            mkdir -p "${z}/.cache/msp/customer-creds"
            : > "${z}/.cache/msp/customer-creds/scope-window.jsonl"

            local rc
            rc=$(run_cred_watchdog "${z}/run" "$(scope_acct 5 1)" 50)
            if [[ "$rc" != "0" ]]; then
                echo "FAIL: ${label} -- a zero-byte window file broke a single-account issuance (exit ${rc})" >&2
                cat "${z}/run/stderr.txt" >&2
                exit 1
            fi
            assert_pure_5key_stdout "${z}/run/stdout.json" "$label" || exit 1
        ) || exit 1

        # -- 3. a garbage ACK file over an over-threshold window: still REFUSE --
        (
            local a="${d}/badack"; mkdir -p "$a"
            export HOME="$a"
            seed_env "$a" "xoxp-test-bearer-value"
            seed_broker_ok "$a"
            seed_migration_marker "$a"
            seed_scope_window "$a" 50 "$(scope_acct 5 1)"
            seed_scope_window "$a" 40 "$(scope_acct 5 2)"
            seed_scope_window "$a" 30 "$(scope_acct 5 3)"
            seed_scope_window "$a" 20 "$(scope_acct 5 4)"
            seed_scope_window "$a" 10 "$(scope_acct 5 5)"
            seed_scope_window "$a"  5 "$(scope_acct 5 6)"
            local f="${a}/.cache/msp/customer-creds/scope-acks.jsonl"
            printf 'garbage not json\n' > "$f"
            printf '{"ts":"abc","expiresAt":"zz","accountIds":[oops]}\n' >> "$f"
            head -c 512 /dev/urandom >> "$f"
            printf '\n{"ts":1,"expiresAt":9999999999,"accountIds":["' >> "$f"

            local rc
            rc=$(run_cred_watchdog "${a}/run" "$(scope_acct 5 7)" 20)
            if [[ "$rc" != "1" ]]; then
                echo "FAIL: ${label} -- an unreadable ack file became a blanket override (exit ${rc}, expected 1)" >&2
                exit 1
            fi
            if ! grep -q '^\[scope\] reason=fan-out-threshold' "${a}/run/stderr.txt"; then
                echo "FAIL: ${label} -- garbage-ack refusal carries no reason token" >&2
                exit 1
            fi
        ) || exit 1

        echo "PASS: ${label}"
    ) || return 1
    return 0
}

# run_scope8: twelve parallel invocations of twelve distinct accounts.
#
# OQ5 DIVERGENCE, stated because this file's convention is exact counts (FM-10
# asserts `delta -ne 1`). Here the assertion is BOUNDS, deliberately: the append
# is unlocked and happens before any count is read, so the number that pass is
# "about 5", not "exactly 5". An exact assertion would flake by construction.
#
# `passes <= 5` is nevertheless a HARD guarantee, not a soft bound: every
# invocation appends its own record before reading, so the k-th appender observes
# at least k distinct ids, and therefore no more than five invocations can ever
# observe a count inside the allowance.
#
# `records >= 12` holds despite the prune because nothing in this fixture is
# older than the cutoff: scope_prune_window's no-op guard sees a stale count of
# zero and skips the rewrite entirely, so no sibling's append can be lost to a
# pre-`mv` inode.
#
# THIS ASSERTION HAS ALREADY CAUGHT A REAL DEFECT -- do not relax it. The guard
# used to compare `wc -l` of the temp file against a SECOND `wc -l` of the live
# record, i.e. a snapshot against a re-count taken a fork later. One sibling
# appending in that gap defeated the guard, the `mv` fired, and it took every
# record appended since awk's EOF with it: this case saw 4-7 survivors out of 12
# on Linux. macOS passed only because its slower fork/exec narrows the overlap
# (at 48-way parallelism it fails there too), which is exactly the kind of
# platform-flavoured under-count that makes the brake silently weaker rather
# than noisily broken.
#
# MUTATION CHECK (verified): moving scope_window_append after the count read
# makes passes climb above 5.
run_scope8() {
    local d="${WORK_DIR}/scope8"; mkdir -p "$d"
    local label="SCP-05/D-17: 12 parallel invocations -- passes <= 5, refusals >= 1, window records >= 12 (bounds, not an exact split)"
    (
        export HOME="$d"
        # Seeded ONCE, before any child starts.
        seed_env "$d" "xoxp-test-bearer-value"
        seed_broker_ok "$d"
        seed_migration_marker "$d"

        local i pids="" p
        for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
            (
                PATH="${STUB_DIR}:${PATH}" bash "$SCRIPT" --account-id "$(scope_acct 5 "$i")" --agent claude-code \
                    >"${d}/stdout.${i}" 2>"${d}/stderr.${i}" </dev/null
                printf '%s' "$?" > "${d}/rc.${i}"
            ) &
            pids="${pids} $!"
        done
        for p in $pids; do
            wait "$p"
        done

        local passes=0 refusals=0 rc
        for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
            rc=$(cat "${d}/rc.${i}" 2>/dev/null)
            if [[ "$rc" == "0" ]]; then
                passes=$((passes + 1))
                # stdout purity under concurrency, in the passing direction.
                assert_pure_5key_stdout "${d}/stdout.${i}" "$label" || exit 1
            elif [[ "$rc" == "1" ]] && grep -q '^\[scope\] reason=fan-out-threshold' "${d}/stderr.${i}"; then
                refusals=$((refusals + 1))
                # ... and in the refusing direction.
                if [[ -s "${d}/stdout.${i}" ]]; then
                    echo "FAIL: ${label} -- refused run ${i} wrote to stdout: $(head -3 "${d}/stdout.${i}")" >&2
                    exit 1
                fi
            fi
        done

        if [[ "$passes" -gt 5 ]]; then
            echo "FAIL: ${label} -- ${passes} runs passed, the allowance is 5" >&2
            exit 1
        fi
        if [[ "$refusals" -lt 1 ]]; then
            echo "FAIL: ${label} -- no run was refused across 12 distinct accounts" >&2
            exit 1
        fi
        # No third outcome. Without this, a fixture where eleven runs crashed on
        # an unrelated error would satisfy both bounds and prove nothing.
        if [[ $((passes + refusals)) -ne 12 ]]; then
            echo "FAIL: ${label} -- ${passes} passed + ${refusals} refused != 12 (an unrelated failure mode is present)" >&2
            for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
                printf 'run %s rc=%s: %s\n' "$i" "$(cat "${d}/rc.${i}" 2>/dev/null)" "$(tail -n 1 "${d}/stderr.${i}" 2>/dev/null)" >&2
            done
            exit 1
        fi
        local w; w=$(scope_window_lines "$d")
        if [[ "$w" -lt 12 ]]; then
            echo "FAIL: ${label} -- window holds ${w} records, expected at least 12" >&2
            exit 1
        fi

        echo "PASS: ${label}"
    ) || return 1
    return 0
}

# run_singleflight: credential-broker #50. N parallel callers on one account
# with an empty cache must produce ONE broker POST; everyone gets the 5-key JSON.
# MUTATION CHECK: removing the acquire_acct_lock block makes the POST count N.
run_singleflight() {
    local d="${WORK_DIR}/singleflight"; mkdir -p "$d"
    local label="#50: 6 parallel calls on one account with an empty cache -> exactly 1 broker POST"
    (
        export HOME="$d"
        seed_env "$d" "xoxp-test-bearer-value"
        seed_broker_ok "$d"
        seed_migration_marker "$d"
        printf '1' > "${d}/.stub/delay"

        local acct; acct=$(scope_acct 5 1)
        local i pids="" p rc
        for i in 1 2 3 4 5 6; do
            (
                PATH="${STUB_DIR}:${PATH}" bash "$SCRIPT" --account-id "$acct" --agent claude-code \
                    >"${d}/stdout.${i}" 2>"${d}/stderr.${i}" </dev/null
                printf '%s' "$?" > "${d}/rc.${i}"
            ) &
            pids="${pids} $!"
        done
        for p in $pids; do wait "$p"; done

        for i in 1 2 3 4 5 6; do
            rc=$(cat "${d}/rc.${i}" 2>/dev/null)
            if [[ "$rc" != "0" ]]; then
                echo "FAIL: ${label} -- run ${i} exited ${rc}: $(tail -n 2 "${d}/stderr.${i}")" >&2
                exit 1
            fi
            assert_pure_5key_stdout "${d}/stdout.${i}" "$label" || exit 1
        done
        local n; n=$(curl_call_count "$d")
        if [[ "$n" != "1" ]]; then
            echo "FAIL: ${label} -- ${n} broker POSTs, expected 1" >&2
            exit 1
        fi
        if [[ -e "${d}/.cache/msp/customer-creds/.${acct}.lock.d" ]]; then
            echo "FAIL: ${label} -- lock dir left behind" >&2
            exit 1
        fi
        echo "PASS: ${label}"
    ) || return 1
    return 0
}

# run_stale_lock: a lock dir older than 60s (crashed holder) is reclaimed, not waited on.
run_stale_lock() {
    local d="${WORK_DIR}/stalelock"; mkdir -p "$d"
    local label="#50: a lock older than 60s is reclaimed and issuance proceeds"
    (
        export HOME="$d"
        seed_env "$d" "xoxp-test-bearer-value"
        seed_broker_ok "$d"
        seed_migration_marker "$d"
        local acct; acct=$(scope_acct 5 2)
        local lock="${d}/.cache/msp/customer-creds/.${acct}.lock.d"
        mkdir -p "$lock"
        touch -t 200001010000 "$lock"

        local rc
        rc=$(run_cred_watchdog "${d}/run" "$acct" 100)
        if [[ "$rc" != "0" ]]; then
            echo "FAIL: ${label} -- exited ${rc}: $(tail -n 2 "${d}/run/stderr.txt")" >&2
            exit 1
        fi
        [[ "$(curl_call_count "$d")" == "1" ]] || { echo "FAIL: ${label} -- expected 1 POST" >&2; exit 1; }
        echo "PASS: ${label}"
    ) || return 1
    return 0
}

# run_throttle429: credential-broker #49. 429 is retried (shared attempt budget);
# 424 stays a no-retry deny (run_case21 covers 424 too -- repeated here next to the 429
# case so the contrast is one read).
run_throttle429() {
    local d="${WORK_DIR}/throttle429"; mkdir -p "$d"
    local label="#49: 429 -> 200 retries and succeeds; persistent 429 stops at 3 POSTs; 424 never retries"
    (
        # -- 429 then 200 -------------------------------------------------------
        (
            local a="${d}/recover"; mkdir -p "$a"
            export HOME="$a"
            seed_env "$a" "xoxp-test-bearer-value"
            seed_broker_ok "$a"
            seed_migration_marker "$a"
            seed_status_seq "$a" 429 200
            local rc; rc=$(run_cred_watchdog "${a}/run" "$(scope_acct 5 3)" 100)
            if [[ "$rc" != "0" ]]; then
                echo "FAIL: ${label} -- 429->200 exited ${rc}: $(tail -n 2 "${a}/run/stderr.txt")" >&2
                exit 1
            fi
            assert_pure_5key_stdout "${a}/run/stdout.json" "$label" || exit 1
            [[ "$(curl_call_count "$a")" == "2" ]] \
                || { echo "FAIL: ${label} -- 429->200 made $(curl_call_count "$a") POSTs, expected 2" >&2; exit 1; }
        ) || exit 1

        # -- persistent 429 -----------------------------------------------------
        (
            local b="${d}/persist"; mkdir -p "$b"
            export HOME="$b"
            seed_env "$b" "xoxp-test-bearer-value"
            seed_status "$b" 429
            seed_migration_marker "$b"
            local rc; rc=$(run_cred_watchdog "${b}/run" "$(scope_acct 5 4)" 100)
            if [[ "$rc" != "1" ]] || ! grep -q '429' "${b}/run/stderr.txt"; then
                echo "FAIL: ${label} -- persistent 429 exit ${rc}, stderr: $(tail -n 2 "${b}/run/stderr.txt")" >&2
                exit 1
            fi
            [[ "$(curl_call_count "$b")" == "3" ]] \
                || { echo "FAIL: ${label} -- persistent 429 made $(curl_call_count "$b") POSTs, expected 3" >&2; exit 1; }
        ) || exit 1

        # -- 424 stays no-retry -------------------------------------------------
        (
            local c="${d}/deny"; mkdir -p "$c"
            export HOME="$c"
            seed_env "$c" "xoxp-test-bearer-value"
            seed_status "$c" 424
            seed_migration_marker "$c"
            local rc; rc=$(run_cred_watchdog "${c}/run" "$(scope_acct 5 5)" 100)
            if [[ "$rc" != "1" ]]; then
                echo "FAIL: ${label} -- 424 exit ${rc}, expected 1" >&2
                exit 1
            fi
            [[ "$(curl_call_count "$c")" == "1" ]] \
                || { echo "FAIL: ${label} -- 424 made $(curl_call_count "$c") POSTs, expected 1 (no retry)" >&2; exit 1; }
        ) || exit 1

        echo "PASS: ${label}"
    ) || return 1
    return 0
}

# -- Runner -------------------------------------------------------------------

echo "=== Phase 18/19: get-customer-credentials.sh (thin Bearer HTTP + status map + retry + agent detection) ==="
echo ""

run_case1 || failures=$((failures + 1))
run_case2 || failures=$((failures + 1))
run_case3 || failures=$((failures + 1))
run_case4 || failures=$((failures + 1))
run_case5 || failures=$((failures + 1))
run_case6 || failures=$((failures + 1))
run_case7 || failures=$((failures + 1))
run_case8 || failures=$((failures + 1))
run_case9 || failures=$((failures + 1))
run_case10 || failures=$((failures + 1))
run_case11 || failures=$((failures + 1))
run_case12 || failures=$((failures + 1))
run_case13 || failures=$((failures + 1))
run_case14 || failures=$((failures + 1))
run_case15 || failures=$((failures + 1))
run_case16 || failures=$((failures + 1))
run_case17 || failures=$((failures + 1))
run_case18 || failures=$((failures + 1))
run_case19 || failures=$((failures + 1))
run_case20 || failures=$((failures + 1))
run_case21 || failures=$((failures + 1))
run_case22 || failures=$((failures + 1))
run_case23 || failures=$((failures + 1))
run_case24 || failures=$((failures + 1))
run_tiket_version || failures=$((failures + 1))
run_case426 || failures=$((failures + 1))
run_case25 || failures=$((failures + 1))
run_case26 || failures=$((failures + 1))
run_hook_b1 || failures=$((failures + 1))
run_hook_b2 || failures=$((failures + 1))
run_hook_b3 || failures=$((failures + 1))
run_hook_b4 || failures=$((failures + 1))
run_stdout1 || failures=$((failures + 1))
run_stdout2 || failures=$((failures + 1))
run_stdout3 || failures=$((failures + 1))
run_stdout4 || failures=$((failures + 1))
run_scope1 || failures=$((failures + 1))
run_scope2 || failures=$((failures + 1))
run_scope3 || failures=$((failures + 1))
run_scope4 || failures=$((failures + 1))
run_scope5 || failures=$((failures + 1))
run_scope6 || failures=$((failures + 1))
run_scope7 || failures=$((failures + 1))
run_scope8 || failures=$((failures + 1))
run_singleflight || failures=$((failures + 1))
run_stale_lock || failures=$((failures + 1))
run_throttle429 || failures=$((failures + 1))

TOTAL_CASES=47

echo ""
if [[ $failures -gt 0 ]]; then
    echo "RESULT: ${failures} case(s) FAILED (out of ${TOTAL_CASES})"
    exit 1
fi
echo "RESULT: all ${TOTAL_CASES} cases PASS"
exit 0
