#!/usr/bin/env bash
# Phase 18 -- get-sts-token.sh (login-only) tests
#
# Requirements covered (18-VALIDATION anchor invariants #1, #4, #5):
#   CLI-03: after a successful Slack login, sts-token.json persists ONLY the
#           identity/cadence fields (Version, Expiration, BrokerVersion,
#           SlackAccessToken, SlackUserId) and NONE of the AWS-credential keys
#           (AccessKeyId / SecretAccessKey / SessionToken). ZERO privileged
#           residue ON DISK.
#   CLI-03 / ROADMAP SC3 ("distributes no AWS credential"): the fresh-login run
#           EMITS the SAME identity-only projection on STDOUT -- the final JSON
#           line carries SlackAccessToken + SlackUserId and NONE of the three
#           AWS-credential keys. ZERO privileged residue ON STDOUT.
#   CLI-03: the sts-token.json file is written chmod 600.
#   CLI-03: --check-only returns exit 0 on a fresh valid token, exit 2 on an
#           expired/absent token, and NEVER opens a browser.
#   CLI-03 (migration): a pre-existing sts-token.json holding a full AWS session
#           is overwritten by the login-only run so the residue is gone.
#
# Stubbing model:
#   - HOME override per case isolates filesystem state (conf + sts-token cache).
#   - A stub `curl` on PATH answers ONLY the POST /v1/credentials exchange with a
#     canned 9-key login body (AWS creds + SlackAccessToken + SlackUserId). The
#     self-update GET probes (/version, /download) get an empty reply, so the
#     self-update hook is a no-op and no real network is touched.
#   - The OAuth loopback is driven locally: the test runs the script in the
#     background with --no-browser, reads the printed auth URL to recover the
#     CSRF `state`, and delivers the callback to the loopback listener with the
#     REAL curl (never the stub). Slack itself is never contacted.
#
# Exit 0 only when all cases pass. RED until get-sts-token.sh is login-only.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${REPO_ROOT}/skills/aws-customer-account-ops/get-sts-token.sh"
PORT="9876"

if [[ ! -f "$SCRIPT" ]]; then
    echo "FAIL: ${SCRIPT} missing" >&2
    exit 1
fi

for tool in bash jq python3 curl mktemp; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "SKIP: missing prerequisite: ${tool}" >&2
        exit 0
    fi
done

# The REAL curl -- used by the harness to deliver the OAuth callback to the
# loopback listener. Captured BEFORE the stub is prepended to PATH.
REAL_CURL="$(command -v curl)"

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

failures=0

# -- Cross-platform future/past ISO-8601 timestamps ----------------------------
future_ts() {
    date -u -d "1 hour" +"%Y-%m-%dT%H:%M:%S.000Z" 2>/dev/null \
        || date -u -v+1H +"%Y-%m-%dT%H:%M:%S.000Z" 2>/dev/null
}
past_ts() {
    date -u -d "-1 hour" +"%Y-%m-%dT%H:%M:%S.000Z" 2>/dev/null \
        || date -u -v-1H +"%Y-%m-%dT%H:%M:%S.000Z" 2>/dev/null
}

# -- Stub PATH: fake curl ------------------------------------------------------
# Answers the login POST with the canned 9-key body; stays silent for the
# self-update GET probes (so the update hook no-ops). Reads $HOME at runtime, so
# per-case HOME redirection scopes the canned response.
STUB_DIR="${WORK_DIR}/stubs"
mkdir -p "$STUB_DIR"
cat > "${STUB_DIR}/curl" <<'CURLSTUB'
#!/usr/bin/env bash
args="$*"
mkdir -p "${HOME}/.stub"
printf '%s\n' "$args" >> "${HOME}/.stub/curl_calls"
# Only the /v1/credentials exchange is a POST; emit the canned login body there.
if printf '%s' "$args" | grep -q -- '-X POST'; then
    [[ -f "${HOME}/.stub/login.json" ]] && cat "${HOME}/.stub/login.json"
elif [[ "$args" == *'/version'* && -f "${HOME}/.stub/version.json" ]]; then
    cat "${HOME}/.stub/version.json"
elif [[ "$args" == *'/download'* && -f "${HOME}/.stub/version.json" ]]; then
    if [[ "$args" == *'Bearer xoxp-test-bearer-value'* && ! -f "${HOME}/.stub/update-fail" ]]; then
        cat "${HOME}/.stub/download.json"
    else
        printf '%s\n' '{"error":"Invalid Slack access token"}'
    fi
elif [[ "$args" == *'https://update.example/package.zip'* ]]; then
    while [[ $# -gt 0 ]]; do
        if [[ "$1" == '-o' ]]; then cp "${HOME}/.stub/update.zip" "$2"; break; fi
        shift
    done
fi
exit 0
CURLSTUB
chmod +x "${STUB_DIR}/curl"

# -- Per-case seeding ----------------------------------------------------------
seed_conf() {
    local home="$1"
    mkdir -p "${home}/.config/msp" "${home}/.cache/msp"
    cat > "${home}/.config/msp/credential-broker.conf" <<CONF
API_URL=https://example.execute-api.ap-northeast-2.amazonaws.com/Prod/v1/credentials
CLIENT_ID=test-client-id
CONF
}

# The canned /v1/credentials 200 body: the full 9-key privileged login response.
seed_login_body() {
    local home="$1"
    mkdir -p "${home}/.stub"
    cat > "${home}/.stub/login.json" <<RESP
{"Version":1,"AccessKeyId":"ASIAEXAMPLE","SecretAccessKey":"wJalrExampleSecretKey","SessionToken":"FQoGExampleSessionToken","Expiration":"$(future_ts)","BrokerVersion":"1.3.0","SlackAccessToken":"xoxp-test-bearer-value","SlackUserId":"U0TESTUSER","BrokerMetadata":{"SlackUserId":"U0TESTUSER"}}
RESP
}

# Write an identity-only cached token (valid or expired) to sts-token.json.
seed_cached_token() {
    local home="$1"; local exp="$2"
    mkdir -p "${home}/.cache/msp"
    cat > "${home}/.cache/msp/sts-token.json" <<TOK
{"Version":1,"Expiration":"${exp}","BrokerVersion":"1.3.0","SlackAccessToken":"xoxp-test-bearer-value","SlackUserId":"U0TESTUSER"}
TOK
    chmod 600 "${home}/.cache/msp/sts-token.json"
}

# Write a STALE full-AWS-session sts-token.json (pre-migration residue).
seed_stale_aws_session() {
    local home="$1"; local exp="$2"
    mkdir -p "${home}/.cache/msp"
    cat > "${home}/.cache/msp/sts-token.json" <<TOK
{"Version":1,"AccessKeyId":"ASIASTALE","SecretAccessKey":"staleSecret","SessionToken":"staleToken","Expiration":"${exp}","BrokerVersion":"1.3.0","SlackAccessToken":"xoxp-old","SlackUserId":"U0TESTUSER"}
TOK
    chmod 600 "${home}/.cache/msp/sts-token.json"
}

# -- Drive a full login through the real loopback ------------------------------
# drive_login <home> <stdout_file> [extra args...] -> echoes the script exit code
drive_login() {
    local home="$1"; local out="$2"; shift 2
    : > "$out"
    HOME="$home" MSP_DISABLE_UPDATE=1 PATH="${STUB_DIR}:${PATH}" \
        bash "$SCRIPT" --no-browser "$@" > "$out" 2> "${home}/stderr.txt" &
    local pid=$!

    local state="" i=0
    while (( i < 200 )); do              # up to ~50s for the listener + URL
        if grep -qE 'state=[A-Za-z0-9._~%-]+' "$out" 2>/dev/null; then
            state=$(grep -oE 'state=[A-Za-z0-9._~%-]+' "$out" | head -1 | cut -d= -f2-)
            [[ -n "$state" ]] && break
        fi
        kill -0 "$pid" 2>/dev/null || break
        sleep 0.25; i=$((i + 1))
    done

    if [[ -z "$state" ]]; then
        kill "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
        echo "127"   # harness-level failure sentinel
        return
    fi

    # Deliver the OAuth callback with the REAL curl (never the stub).
    "$REAL_CURL" -s "http://localhost:${PORT}/callback?code=test-auth-code&state=${state}" >/dev/null 2>&1 || true

    wait "$pid"
    echo "$?"
}

# Extract the final emitted JSON line (starts with '{') from a captured stdout.
final_json_line() {
    grep -E '^\{' "$1" 2>/dev/null | tail -1
}

# -- HOOK-A fixtures ------------------------------------------------------------
# HOOK-A shells out to the SIBLING get-customer-credentials.sh, so the cases run
# a COPY of the script under test from a synthetic skills dir where that sibling
# is a recorder we control.
#
# setup_skill_dir <home> <mode> [child_rc]
#   mode=record  -- install a recorder sibling that logs its argv, writes a line
#                   to STDOUT (which the hook must swallow) and a mapping table
#                   to STDERR (which the hook must let through)
#   mode=absent  -- no sibling at all
#   mode=noexec  -- sibling present but not executable
# Echoes the path of the copied get-sts-token.sh.
setup_skill_dir() {
    local home="$1" mode="$2" child_rc="${3:-0}"
    local sd="${home}/skills"
    mkdir -p "$sd" "${home}/.stub"
    cp "$SCRIPT" "${sd}/get-sts-token.sh"
    chmod +x "${sd}/get-sts-token.sh"

    if [[ "$mode" != "absent" ]]; then
        cat > "${sd}/get-customer-credentials.sh" <<RECORDER
#!/usr/bin/env bash
# Recorder stand-in for the real client. Logs argv, then deliberately writes to
# BOTH streams so the hook's redirection can be observed from the outside.
mkdir -p "\${HOME}/.stub"
printf '%s\n' "\$*" >> "\${HOME}/.stub/gcc_calls"
printf 'STDOUT-LEAK-FROM-MIGRATE\n'
printf '[migrate] samplecorp → csg-samplecorp\n' >&2
printf '[migrate] rewritten=1\n' >&2
exit ${child_rc}
RECORDER
        if [[ "$mode" == "noexec" ]]; then
            chmod 000 "${sd}/get-customer-credentials.sh"
        else
            chmod +x "${sd}/get-customer-credentials.sh"
        fi
    fi

    printf '%s' "${sd}/get-sts-token.sh"
}

# run_check_only <home> <script_path> -> echoes the exit code, captures streams
run_check_only() {
    local home="$1" script_path="$2"
    set +e
    HOME="$home" MSP_DISABLE_UPDATE=1 PATH="${STUB_DIR}:${PATH}" \
        bash "$script_path" --check-only >"${home}/stdout.txt" 2>"${home}/stderr.txt"
    local rc=$?
    set -e
    printf '%s' "$rc"
}

# -- Test Cases ----------------------------------------------------------------

run_case1() {
    local d="${WORK_DIR}/case1"; mkdir -p "$d"
    local label="CLI-03: fresh login persists identity-only ON DISK and emits identity-only ON STDOUT (no AWS creds)"
    export HOME="$d"
    seed_conf "$d"; seed_login_body "$d"

    local out="${d}/stdout.txt"
    local rc; rc="$(drive_login "$d" "$out")"

    if [[ "$rc" == "127" ]]; then
        echo "FAIL: ${label} -- harness could not drive the login (no state captured)" >&2
        cat "${d}/stderr.txt" >&2
        return 1
    fi
    if [[ "$rc" != "0" ]]; then
        echo "FAIL: ${label} -- login exited ${rc}, expected 0" >&2
        cat "${d}/stderr.txt" >&2
        return 1
    fi

    local tok="${d}/.cache/msp/sts-token.json"
    if [[ ! -f "$tok" ]]; then
        echo "FAIL: ${label} -- sts-token.json was not written" >&2
        return 1
    fi

    # ON DISK: identity present, AWS creds absent.
    if ! jq -e 'has("SlackAccessToken") and has("SlackUserId")' "$tok" >/dev/null 2>&1; then
        echo "FAIL: ${label} -- sts-token.json missing SlackAccessToken/SlackUserId" >&2
        return 1
    fi
    if jq -e 'has("AccessKeyId") or has("SecretAccessKey") or has("SessionToken")' "$tok" >/dev/null 2>&1; then
        echo "FAIL: ${label} -- sts-token.json still carries an AWS credential (residue ON DISK)" >&2
        cat "$tok" >&2
        return 1
    fi

    # Permissions must be 600. Separate substitutions (GNU first, then BSD) so a
    # failed first attempt can't leak `stat -f` filesystem output into $perm on
    # Linux (where BSD `-f '%Lp'` prints an fs block to stdout and exits 1).
    local perm
    perm=$(stat -c '%a' "$tok" 2>/dev/null) || perm=$(stat -f '%Lp' "$tok" 2>/dev/null)
    if [[ "$perm" != "600" ]]; then
        echo "FAIL: ${label} -- sts-token.json perms were ${perm}, expected 600" >&2
        return 1
    fi

    # ON STDOUT: the fresh-login emission carries identity only, no AWS creds.
    local emitted; emitted="$(final_json_line "$out")"
    if [[ -z "$emitted" ]]; then
        echo "FAIL: ${label} -- no JSON emitted on stdout" >&2
        cat "$out" >&2
        return 1
    fi
    if ! printf '%s' "$emitted" | jq -e 'has("SlackAccessToken") and has("SlackUserId")' >/dev/null 2>&1; then
        echo "FAIL: ${label} -- stdout emission missing SlackAccessToken/SlackUserId" >&2
        echo "  emitted: ${emitted}" >&2
        return 1
    fi
    if printf '%s' "$emitted" | jq -e 'has("AccessKeyId") or has("SecretAccessKey") or has("SessionToken")' >/dev/null 2>&1; then
        echo "FAIL: ${label} -- stdout DISTRIBUTES an AWS credential (residue ON STDOUT)" >&2
        echo "  emitted: ${emitted}" >&2
        return 1
    fi

    echo "PASS: ${label}"
    return 0
}

run_case2() {
    local d="${WORK_DIR}/case2"; mkdir -p "$d"
    local label="CLI-03: --check-only with a fresh valid token exits 0 and opens no browser"
    (
        export HOME="$d"
        seed_conf "$d"; seed_login_body "$d"
        seed_cached_token "$d" "$(future_ts)"

        set +e
        MSP_DISABLE_UPDATE=1 PATH="${STUB_DIR}:${PATH}" \
            bash "$SCRIPT" --check-only >"${d}/stdout.txt" 2>"${d}/stderr.txt"
        local rc=$?
        set -e

        if [[ $rc -ne 0 ]]; then
            echo "FAIL: ${label} -- exit ${rc}, expected 0" >&2
            cat "${d}/stderr.txt" >&2
            exit 1
        fi
        # No OAuth URL must have been printed (no browser flow entered).
        if grep -q 'state=' "${d}/stdout.txt" "${d}/stderr.txt" 2>/dev/null; then
            echo "FAIL: ${label} -- an OAuth URL was produced under --check-only" >&2
            exit 1
        fi
        echo "PASS: ${label}"
    ) || return 1
    return 0
}

run_case3() {
    local d="${WORK_DIR}/case3"; mkdir -p "$d"
    local label="CLI-03: --check-only with an absent token exits 2 and opens no browser"
    (
        export HOME="$d"
        seed_conf "$d"; seed_login_body "$d"      # no cached token seeded

        local start end elapsed rc
        start=$(date +%s)
        set +e
        MSP_DISABLE_UPDATE=1 PATH="${STUB_DIR}:${PATH}" \
            bash "$SCRIPT" --check-only >"${d}/stdout.txt" 2>"${d}/stderr.txt"
        rc=$?
        set -e
        end=$(date +%s)
        elapsed=$(( end - start ))

        if [[ $rc -ne 2 ]]; then
            echo "FAIL: ${label} -- exit ${rc}, expected 2" >&2
            cat "${d}/stderr.txt" >&2
            exit 1
        fi
        if [[ $elapsed -ge 10 ]]; then
            echo "FAIL: ${label} -- took ${elapsed}s; --check-only must not block on OAuth" >&2
            exit 1
        fi
        if grep -q 'state=' "${d}/stdout.txt" "${d}/stderr.txt" 2>/dev/null; then
            echo "FAIL: ${label} -- an OAuth URL was produced under --check-only" >&2
            exit 1
        fi
        echo "PASS: ${label}"
    ) || return 1
    return 0
}

run_case4() {
    local d="${WORK_DIR}/case4"; mkdir -p "$d"
    local label="CLI-03 (migration): a stale full-AWS-session sts-token.json is overwritten with identity-only"
    export HOME="$d"
    seed_conf "$d"; seed_login_body "$d"
    seed_stale_aws_session "$d" "$(past_ts)"   # expired -> login-only rewrite triggers

    local tok="${d}/.cache/msp/sts-token.json"
    # Precondition: the seeded residue really is present before the run.
    if ! jq -e 'has("SecretAccessKey") or has("SessionToken")' "$tok" >/dev/null 2>&1; then
        echo "FAIL: ${label} -- test seed did not contain a stale AWS session" >&2
        return 1
    fi

    local out="${d}/stdout.txt"
    local rc; rc="$(drive_login "$d" "$out")"
    if [[ "$rc" == "127" ]]; then
        echo "FAIL: ${label} -- harness could not drive the login (no state captured)" >&2
        cat "${d}/stderr.txt" >&2
        return 1
    fi
    if [[ "$rc" != "0" ]]; then
        echo "FAIL: ${label} -- login exited ${rc}, expected 0" >&2
        cat "${d}/stderr.txt" >&2
        return 1
    fi

    # Post-migration: the residue is gone from disk.
    if jq -e 'has("AccessKeyId") or has("SecretAccessKey") or has("SessionToken")' "$tok" >/dev/null 2>&1; then
        echo "FAIL: ${label} -- stale AWS session still present after login-only run" >&2
        cat "$tok" >&2
        return 1
    fi
    if ! jq -e 'has("SlackAccessToken") and has("SlackUserId")' "$tok" >/dev/null 2>&1; then
        echo "FAIL: ${label} -- identity fields missing after overwrite" >&2
        return 1
    fi

    echo "PASS: ${label}"
    return 0
}

# ==============================================================================
# HOOK-A -- the login path fires the fleet migration (PROF-12)
# ==============================================================================
# `try_self_update` replaces skill FILES and never re-runs install.sh, so the
# migration has to be triggered by the clients themselves. This is the ONE hook
# with a real TTY, which is why its stderr stays attached: the mapping table is
# the only human-facing artifact of the whole migration.

# run_hook_a1: the sibling client is invoked with the `migrate` subcommand.
run_hook_a1() {
    local d="${WORK_DIR}/hooka1"; mkdir -p "$d"
    local label="HOOK-A-01: get-sts-token shells out to get-customer-credentials.sh migrate"
    (
        seed_conf "$d"; seed_login_body "$d"
        seed_cached_token "$d" "$(future_ts)"
        local copied; copied="$(setup_skill_dir "$d" record)"

        local rc; rc="$(run_check_only "$d" "$copied")"
        if [[ "$rc" != "0" ]]; then
            echo "FAIL: ${label} -- exit ${rc}, expected 0; stderr: $(cat "${d}/stderr.txt")" >&2
            exit 1
        fi
        if [[ ! -f "${d}/.stub/gcc_calls" ]]; then
            echo "FAIL: ${label} -- the sibling client was never invoked" >&2
            exit 1
        fi
        if ! grep -qx 'migrate' "${d}/.stub/gcc_calls"; then
            echo "FAIL: ${label} -- invoked with argv '$(cat "${d}/.stub/gcc_calls")', expected exactly 'migrate'" >&2
            exit 1
        fi
        echo "PASS: ${label}"
    ) || return 1
    return 0
}

# run_hook_a2: STATIC proof. The workspace skill has no self-update any more
# (2026-10-21: a stale copy forced an update that could never finish, so login
# never completed). No remnant of it may come back. Also asserts SCRIPT_DIR is
# defined once and reused, and that stdout (not stderr) is the stream discarded.
run_hook_a2() {
    local label="HOOK-A-02: no self-update remnant, the hook reuses SCRIPT_DIR, and discards stdout only"
    local hook_line
    hook_line=$(grep -n 'get-customer-credentials.sh" migrate' "$SCRIPT" | head -1 | cut -d: -f1)

    if [[ -z "$hook_line" ]]; then
        echo "FAIL: ${label} -- no 'get-customer-credentials.sh\" migrate' call found in ${SCRIPT}" >&2
        return 1
    fi
    if grep -nE 'self-update|try_self_update|UPDATE_REQUIRED|NO_UPDATE|cache_slack_token|deferred_update' "$SCRIPT" >&2; then
        echo "FAIL: ${label} -- self-update remnants above are still in ${SCRIPT}" >&2
        return 1
    fi

    local script_dir_defs
    script_dir_defs=$(grep -c 'SCRIPT_DIR=' "$SCRIPT")
    if [[ "$script_dir_defs" != "1" ]]; then
        echo "FAIL: ${label} -- SCRIPT_DIR is assigned ${script_dir_defs} times, expected exactly 1 (the hook must reuse it)" >&2
        return 1
    fi

    # stderr must NOT be redirected with the stdout: `2>&1` on the hook line
    # would swallow the mapping table, which is the whole point of HOOK-A.
    if grep -q 'migrate >/dev/null 2>&1' "$SCRIPT"; then
        echo "FAIL: ${label} -- the hook discards stderr too; the mapping table would be invisible" >&2
        return 1
    fi

    echo "PASS: ${label}"
    return 0
}

# run_hook_a3: a missing or unexecutable sibling must not break login.
run_hook_a3() {
    local label="HOOK-A-03: an absent or unexecutable sibling client does not break get-sts-token"
    local sub_rc=0

    local d="${WORK_DIR}/hooka3a"; mkdir -p "$d"
    (
        seed_conf "$d"; seed_login_body "$d"
        seed_cached_token "$d" "$(future_ts)"
        local copied; copied="$(setup_skill_dir "$d" absent)"
        local rc; rc="$(run_check_only "$d" "$copied")"
        if [[ "$rc" != "0" ]]; then
            echo "FAIL: ${label} [absent] -- exit ${rc}, expected 0; stderr: $(cat "${d}/stderr.txt")" >&2
            exit 1
        fi
    ) || sub_rc=1

    local e="${WORK_DIR}/hooka3b"; mkdir -p "$e"
    (
        seed_conf "$e"; seed_login_body "$e"
        seed_cached_token "$e" "$(future_ts)"
        local copied; copied="$(setup_skill_dir "$e" noexec)"
        local rc; rc="$(run_check_only "$e" "$copied")"
        if [[ "$rc" != "0" ]]; then
            echo "FAIL: ${label} [noexec] -- exit ${rc}, expected 0; stderr: $(cat "${e}/stderr.txt")" >&2
            exit 1
        fi
    ) || sub_rc=1

    [[ $sub_rc -eq 0 ]] || return 1
    echo "PASS: ${label}"
    return 0
}

# run_hook_a4: a FAILING migration must not change get-sts-token's exit code.
run_hook_a4() {
    local d="${WORK_DIR}/hooka4"; mkdir -p "$d"
    local label="HOOK-A-04: a failing migration does not affect get-sts-token's exit code"
    (
        seed_conf "$d"; seed_login_body "$d"
        seed_cached_token "$d" "$(future_ts)"
        local copied; copied="$(setup_skill_dir "$d" record 1)"   # child exits 1

        local rc; rc="$(run_check_only "$d" "$copied")"
        if [[ "$rc" != "0" ]]; then
            echo "FAIL: ${label} -- exit ${rc}, expected 0 despite the child failing; stderr: $(cat "${d}/stderr.txt")" >&2
            exit 1
        fi
        if [[ ! -f "${d}/.stub/gcc_calls" ]]; then
            echo "FAIL: ${label} -- the failing child was never invoked, so nothing was proven" >&2
            exit 1
        fi
        echo "PASS: ${label}"
    ) || return 1
    return 0
}

# run_hook_a5: the mapping table reaches the engineer (stderr kept) while the
# child's stdout is swallowed (this process' stdout is not a free-form channel).
run_hook_a5() {
    local d="${WORK_DIR}/hooka5"; mkdir -p "$d"
    local label="HOOK-A-05: the [migrate] mapping table reaches stderr while the child's stdout is swallowed"
    (
        seed_conf "$d"; seed_login_body "$d"
        seed_cached_token "$d" "$(future_ts)"
        local copied; copied="$(setup_skill_dir "$d" record)"

        local rc; rc="$(run_check_only "$d" "$copied")"
        if [[ "$rc" != "0" ]]; then
            echo "FAIL: ${label} -- exit ${rc}, expected 0" >&2
            exit 1
        fi
        if ! grep -qF -- '[migrate] samplecorp → csg-samplecorp' "${d}/stderr.txt"; then
            echo "FAIL: ${label} -- the mapping table did not reach stderr: $(cat "${d}/stderr.txt")" >&2
            exit 1
        fi
        if grep -qF 'STDOUT-LEAK-FROM-MIGRATE' "${d}/stdout.txt"; then
            echo "FAIL: ${label} -- the child's stdout leaked into get-sts-token's stdout: $(cat "${d}/stdout.txt")" >&2
            exit 1
        fi
        echo "PASS: ${label}"
    ) || return 1
    return 0
}

# -- Runner --------------------------------------------------------------------

# HOOK-A-06 (WR-04): on an already-migrated machine the hook must not fork the
# client AT ALL. get-sts-token.sh is csg-login's registered credential_process,
# so without a completion-marker pre-check every AWS call resolved through that
# profile spawned a whole `bash` subprocess and printed
# "[migrate] status=already-migrated" onto the engineer's terminal, forever.
# The assertion is on the RECORDER LOG, not on stderr: "no output" could also be
# produced by a child that ran and stayed quiet; an empty log proves no fork.
#
# MUTATION CHECK (verified): removing the marker pre-check from HOOK-A makes
# gcc_calls non-empty and this case red.
run_hook_a6() {
    local d="${WORK_DIR}/hooka6"; mkdir -p "$d"
    local label="HOOK-A-06 WR-04: 완료 마커가 있으면 클라이언트를 아예 실행하지 않는다"
    (
        seed_conf "$d"; seed_login_body "$d"
        seed_cached_token "$d" "$(future_ts)"
        local copied; copied="$(setup_skill_dir "$d" record)"

        mkdir -p "${d}/.cache/msp/customer-creds"
        printf '{"id":"v1.7-csg-namespace","completed_at":"2026-01-01T00:00:00Z","renamed":0,"repaired":0,"skipped":0}\n' \
            > "${d}/.cache/msp/customer-creds/migrations.jsonl"

        local rc; rc="$(run_check_only "$d" "$copied")"
        if [[ "$rc" != "0" ]]; then
            echo "FAIL: ${label} -- exit ${rc}, expected 0" >&2
            exit 1
        fi
        if [[ -s "${d}/.stub/gcc_calls" ]]; then
            echo "FAIL: ${label} -- 마커가 있는데도 클라이언트를 실행했습니다: $(cat "${d}/.stub/gcc_calls")" >&2
            exit 1
        fi
        if grep -qF '[migrate]' "${d}/stderr.txt"; then
            echo "FAIL: ${label} -- 수렴한 머신의 stderr 에 [migrate] 줄이 있습니다: $(cat "${d}/stderr.txt")" >&2
            exit 1
        fi
        echo "PASS: ${label}"
    ) || return 1
    return 0
}

# HOOK-A-07 (WR-05): sweep BEFORE migrate, the ordering the credential_process
# hook documents as load-bearing. The cache is keyed on the ACCOUNT ID (Phase 18
# collapse), so a freshly renamed csg-X inherits old X's <account-id>.json, which
# is a 1-hour session and therefore almost always expired. Migrating first hands
# the next sweep a brand-new csg-X it deletes on the spot -- so the mapping table
# printed on THIS path, the one human-facing artifact of the whole migration,
# lists names that no longer exist. HOOK-A ran migrate with no sweep at all.
#
# MUTATION CHECK (verified): dropping the `cleanup` call leaves a one-line log
# and this case goes red on the argv-order assertion.
run_hook_a7() {
    local d="${WORK_DIR}/hooka7"; mkdir -p "$d"
    local label="HOOK-A-07 WR-05: 마이그레이션 전에 sweep(cleanup)을 먼저 실행한다"
    (
        seed_conf "$d"; seed_login_body "$d"
        seed_cached_token "$d" "$(future_ts)"
        local copied; copied="$(setup_skill_dir "$d" record)"

        local rc; rc="$(run_check_only "$d" "$copied")"
        if [[ "$rc" != "0" ]]; then
            echo "FAIL: ${label} -- exit ${rc}, expected 0" >&2
            exit 1
        fi

        local calls="${d}/.stub/gcc_calls"
        if [[ ! -s "$calls" ]]; then
            echo "FAIL: ${label} -- 클라이언트가 한 번도 실행되지 않았습니다" >&2
            exit 1
        fi
        local first second
        first="$(sed -n '1p' "$calls")"
        second="$(sed -n '2p' "$calls")"
        if [[ "$first" != "cleanup" ]]; then
            echo "FAIL: ${label} -- 첫 호출이 'cleanup' 이 아니라 '${first}' 입니다 (sweep→migrate 순서 위반)" >&2
            sed 's/^/       calls| /' "$calls" >&2
            exit 1
        fi
        if [[ "$second" != "migrate" ]]; then
            echo "FAIL: ${label} -- 두 번째 호출이 'migrate' 가 아니라 '${second}' 입니다" >&2
            sed 's/^/       calls| /' "$calls" >&2
            exit 1
        fi
        echo "PASS: ${label}"
    ) || return 1
    return 0
}

echo "=== Phase 18: get-sts-token.sh (login-only) ==="
echo ""

run_case1 || failures=$((failures + 1))
run_case2 || failures=$((failures + 1))
run_case3 || failures=$((failures + 1))
run_case4 || failures=$((failures + 1))
run_hook_a1 || failures=$((failures + 1))
run_hook_a2 || failures=$((failures + 1))
run_hook_a3 || failures=$((failures + 1))
run_hook_a4 || failures=$((failures + 1))
run_hook_a5 || failures=$((failures + 1))
run_hook_a6 || failures=$((failures + 1))
run_hook_a7 || failures=$((failures + 1))

TOTAL_CASES=11

echo ""
if [[ $failures -gt 0 ]]; then
    echo "RESULT: ${failures} case(s) FAILED (out of ${TOTAL_CASES})"
    exit 1
fi
echo "RESULT: all ${TOTAL_CASES} cases PASS"
exit 0
