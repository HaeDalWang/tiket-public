#!/usr/bin/env bash
# Phase 21 -- sweep guard foreign-key immunity tests
#
# Requirements covered:
#   PROF-07 (criterion 1): sweep/cleanup skip any section carrying a foreign
#            credential key (case-folded prefix-family match)
#   PROF-07 (criterion 2): the literal incident-reproduction scenario --
#            a poisoned hybrid section (SSO keys + injected credential_process
#            co-existing in one section) + an expired cache survives
#            `cleanup --all`
#   PROF-07 (criterion 4): the INI parser resets state on EVERY bracketed
#            header (not only [profile ...]/[default]), so CRLF, BOM,
#            quoted-name, double-space-header, and [sso-session ...]-adjacent
#            config fixtures neither crash the script nor leak a foreign key
#            into an adjacent profile's eligibility
#   PROF-08: the ownership verdict is the SUPERSET (csg_managed marker OR the
#            legacy credential_process signature) with the Phase 21 foreign-key
#            veto still top-level, and the marker is consumed presence-only --
#            a section stamped with an unknown/future version string is still
#            sweep-eligible, and `csg_managed` is not a foreign key
#   PROF-14 (criterion 3): a run that deletes a section prints the .bak
#            recovery path + a copy-paste-able `cp` command on stderr; a run
#            that deletes nothing stays silent about .bak (D-08/D-09); the
#            guard's skip line is printed once per section and deduped across
#            invocations via the local guard-skips.jsonl record (D-06)
#
# Stubbing model:
#   - HOME override per case isolates filesystem state (identical to
#     test/cleanup.test.sh)
#   - Synthetic ~/.aws/config fixtures cover: a poisoned hybrid section (SSO
#     keys + injected credential_process in ONE section), a CRLF header line
#     (built via printf, not a heredoc -- heredocs do not reliably preserve
#     embedded \r), a UTF-8 BOM prepended to an otherwise-normal config, a
#     single-quoted profile name, a double-space "[profile  X]" header, and a
#     [sso-session ...] block placed immediately before a clean CSG profile
#   - Subprocess invocation for behavioral cases (auto-sweep, cleanup,
#     cleanup --all)
#   - Function extraction via awk (same marker-comment-bounded region as
#     test/cleanup.test.sh:381) for unit-level predicate tests
#     (is_csg_profile / is_contaminated_hybrid)
#
# Exit 0 only when all cases pass.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${REPO_ROOT}/skills/aws-customer-account-ops/get-customer-credentials.sh"

if [[ ! -f "$SCRIPT" ]]; then
    echo "FAIL: ${SCRIPT} missing" >&2
    exit 1
fi

# Shell prerequisite checks
for tool in bash jq mktemp awk sed; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "SKIP: missing prerequisite: ${tool}" >&2
        exit 0
    fi
done

# -- Scratch directory --------------------------------------------------------
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

failures=0

# -- Fixture builders ----------------------------------------------------------

# setup_expired_cache <dir> <account_id>
# Creates a cache file with Expiration 1 hour in the PAST.
# (Identical to test/cleanup.test.sh's helper -- each test/*.test.sh file is
# self-contained, so this is duplicated rather than shared.)
setup_expired_cache() {
    local dir="$1"
    local account_id="$2"
    local cache_dir="${dir}/.cache/msp/customer-creds"
    mkdir -p "$cache_dir"

    local exp_ts
    if exp_ts=$(date -u -d "1 hour ago" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null); then
        :
    elif exp_ts=$(date -u -v-1H +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null); then
        :
    else
        echo "FAIL: cannot generate past timestamp" >&2
        return 1
    fi

    cat > "${cache_dir}/${account_id}.json" <<CACHE
{"Version":1,"AccessKeyId":"AKIATEST","SecretAccessKey":"secret","SessionToken":"token","Expiration":"${exp_ts}"}
CACHE
}

# setup_poisoned_hybrid_config <dir>
# A single [profile csg-poisoned] section carrying BOTH SSO keys AND an
# injected CSG credential_process -- the exact incident shape (account
# 333333333333).
setup_poisoned_hybrid_config() {
    local dir="$1"
    mkdir -p "${dir}/.aws"
    cat > "${dir}/.aws/config" <<'AWSCONF'
[profile csg-poisoned]
sso_start_url = https://example.awsapps.com/start
sso_region = us-east-1
credential_process = /path/to/get-customer-credentials.sh --account-id 333333333333 --agent claude-code
region = ap-northeast-2

[default]
region = ap-northeast-2
AWSCONF
}

# setup_crlf_config <dir>
# [profile customer-a] header line ends with a literal \r before the
# newline (account 444444444444, clean credential_process). Built with
# printf -- a heredoc does not reliably preserve an embedded \r.
setup_crlf_config() {
    local dir="$1"
    mkdir -p "${dir}/.aws"
    printf '[profile customer-a]\r\ncredential_process = /path/to/get-customer-credentials.sh --account-id 444444444444 --agent claude-code\nregion = ap-northeast-2\n\n[default]\nregion = ap-northeast-2\n' \
        > "${dir}/.aws/config"
}

# setup_bom_config <dir>
# Prepends the 3-byte UTF-8 BOM before an otherwise-normal
# setup_test_config-style config (infra profile + clean CSG profile,
# account 111111111111).
setup_bom_config() {
    local dir="$1"
    mkdir -p "${dir}/.aws"
    {
        printf '\xef\xbb\xbf'
        cat <<'AWSCONF'
[profile crossaccount-user]
credential_process = /path/to/get-sts-token.sh --some-arg
region = ap-northeast-2

[profile customer-a]
credential_process = /path/to/get-customer-credentials.sh --account-id 111111111111 --agent claude-code
region = ap-northeast-2

[default]
region = ap-northeast-2
AWSCONF
    } > "${dir}/.aws/config"
}

# setup_quoted_name_config <dir>
# [profile 'csg-a'] (single-quoted name), clean credential_process,
# account 555555555555.
setup_quoted_name_config() {
    local dir="$1"
    mkdir -p "${dir}/.aws"
    cat > "${dir}/.aws/config" <<'AWSCONF'
[profile 'csg-a']
credential_process = /path/to/get-customer-credentials.sh --account-id 555555555555 --agent claude-code
region = ap-northeast-2

[default]
region = ap-northeast-2
AWSCONF
}

# setup_double_space_header_config <dir>
# [profile  csg-a] (TWO spaces between "profile" and the name), clean
# credential_process, account 666666666666.
setup_double_space_header_config() {
    local dir="$1"
    mkdir -p "${dir}/.aws"
    cat > "${dir}/.aws/config" <<'AWSCONF'
[profile  csg-a]
credential_process = /path/to/get-customer-credentials.sh --account-id 666666666666 --agent claude-code
region = ap-northeast-2

[default]
region = ap-northeast-2
AWSCONF
}

# setup_sso_session_adjacent_config <dir>
# A [sso-session my-sso] block (sso_start_url/sso_region) placed IMMEDIATELY
# BEFORE a clean [profile customer-a] section that has ONLY credential_process
# (no foreign keys of its own), account 111111111111.
setup_sso_session_adjacent_config() {
    local dir="$1"
    mkdir -p "${dir}/.aws"
    cat > "${dir}/.aws/config" <<'AWSCONF'
[sso-session my-sso]
sso_start_url = https://example.awsapps.com/start
sso_region = us-east-1

[profile customer-a]
credential_process = /path/to/get-customer-credentials.sh --account-id 111111111111 --agent claude-code
region = ap-northeast-2

[default]
region = ap-northeast-2
AWSCONF
}

# -- Edge-case test cases (PROF-07 criterion 4) --------------------------------

run_case_sso_session_adjacent() {
    local case_dir="${WORK_DIR}/sso_session_adjacent"
    mkdir -p "$case_dir"
    local label="PROF-07 criterion 4: [sso-session ...] block does not leak into the adjacent [profile customer-a]"

    (
        export HOME="$case_dir"
        setup_sso_session_adjacent_config "$case_dir"
        setup_expired_cache "$case_dir" "111111111111"

        # Invoke as an UNRELATED account so PROF-06 self-protection does not
        # exclude customer-a's own (expired) cache from the sweep set.
        bash "${SCRIPT}" --account-id 000000000000 --agent claude-code 2>/dev/null || true

        # If the [sso-session ...] block's sso_start_url/sso_region leaked into
        # customer-a's foreign-key state, customer-a would be wrongly protected
        # and survive. It must NOT survive -- the reset-bug fix must not
        # over-protect a section that carries no foreign key of its own.
        if grep -q '\[profile customer-a\]' "${case_dir}/.aws/config"; then
            echo "FAIL: ${label} -- customer-a still in config (sso-session block must not leak into it)" >&2
            exit 1
        fi

        echo "PASS: ${label}"
    ) || return 1
    return 0
}

run_case_crlf() {
    local case_dir="${WORK_DIR}/crlf"
    mkdir -p "$case_dir"
    local label="PROF-07 criterion 4: CRLF profile-header line survives cleanup --all without crashing"

    (
        export HOME="$case_dir"
        setup_crlf_config "$case_dir"

        local out_file="${case_dir}/out.txt"
        set +e
        bash "${SCRIPT}" cleanup --all >"$out_file" 2>&1
        local rc=$?
        set -e

        if [[ $rc -ne 0 ]]; then
            echo "FAIL: ${label} -- exit code ${rc}, expected 0" >&2
            cat "$out_file" >&2
            exit 1
        fi

        if grep -qiE 'syntax error|unbound variable|command not found|segmentation fault|core dumped|unexpected token' "$out_file"; then
            echo "FAIL: ${label} -- shell error/crash detected in output" >&2
            cat "$out_file" >&2
            exit 1
        fi

        if [[ ! -s "${case_dir}/.aws/config" ]]; then
            echo "FAIL: ${label} -- ~/.aws/config is empty after run" >&2
            exit 1
        fi
        if ! grep -q '^\[' "${case_dir}/.aws/config"; then
            echo "FAIL: ${label} -- ~/.aws/config has no recognizable [...] header after run" >&2
            exit 1
        fi

        echo "PASS: ${label}"
    ) || return 1
    return 0
}

run_case_bom() {
    local case_dir="${WORK_DIR}/bom"
    mkdir -p "$case_dir"
    local label="PROF-07 criterion 4: UTF-8 BOM at top of config survives cleanup --all without crashing"

    (
        export HOME="$case_dir"
        setup_bom_config "$case_dir"

        local out_file="${case_dir}/out.txt"
        set +e
        bash "${SCRIPT}" cleanup --all >"$out_file" 2>&1
        local rc=$?
        set -e

        if [[ $rc -ne 0 ]]; then
            echo "FAIL: ${label} -- exit code ${rc}, expected 0" >&2
            cat "$out_file" >&2
            exit 1
        fi

        if grep -qiE 'syntax error|unbound variable|command not found|segmentation fault|core dumped|unexpected token' "$out_file"; then
            echo "FAIL: ${label} -- shell error/crash detected in output" >&2
            cat "$out_file" >&2
            exit 1
        fi

        if [[ ! -s "${case_dir}/.aws/config" ]]; then
            echo "FAIL: ${label} -- ~/.aws/config is empty after run" >&2
            exit 1
        fi
        if ! grep -q '^\[' "${case_dir}/.aws/config"; then
            echo "FAIL: ${label} -- ~/.aws/config has no recognizable [...] header after run" >&2
            exit 1
        fi

        echo "PASS: ${label}"
    ) || return 1
    return 0
}

run_case_quoted_name() {
    local case_dir="${WORK_DIR}/quoted_name"
    mkdir -p "$case_dir"
    local label="PROF-07 criterion 4: single-quoted profile name survives cleanup --all without crashing"

    (
        export HOME="$case_dir"
        setup_quoted_name_config "$case_dir"

        local out_file="${case_dir}/out.txt"
        set +e
        bash "${SCRIPT}" cleanup --all >"$out_file" 2>&1
        local rc=$?
        set -e

        if [[ $rc -ne 0 ]]; then
            echo "FAIL: ${label} -- exit code ${rc}, expected 0" >&2
            cat "$out_file" >&2
            exit 1
        fi

        if grep -qiE 'syntax error|unbound variable|command not found|segmentation fault|core dumped|unexpected token' "$out_file"; then
            echo "FAIL: ${label} -- shell error/crash detected in output" >&2
            cat "$out_file" >&2
            exit 1
        fi

        if [[ ! -s "${case_dir}/.aws/config" ]]; then
            echo "FAIL: ${label} -- ~/.aws/config is empty after run" >&2
            exit 1
        fi
        if ! grep -q '^\[' "${case_dir}/.aws/config"; then
            echo "FAIL: ${label} -- ~/.aws/config has no recognizable [...] header after run" >&2
            exit 1
        fi

        echo "PASS: ${label}"
    ) || return 1
    return 0
}

run_case_double_space_header() {
    local case_dir="${WORK_DIR}/double_space"
    mkdir -p "$case_dir"
    local label="PROF-07 criterion 4: double-space '[profile  X]' header survives cleanup --all without crashing"

    (
        export HOME="$case_dir"
        setup_double_space_header_config "$case_dir"

        local out_file="${case_dir}/out.txt"
        set +e
        bash "${SCRIPT}" cleanup --all >"$out_file" 2>&1
        local rc=$?
        set -e

        if [[ $rc -ne 0 ]]; then
            echo "FAIL: ${label} -- exit code ${rc}, expected 0" >&2
            cat "$out_file" >&2
            exit 1
        fi

        if grep -qiE 'syntax error|unbound variable|command not found|segmentation fault|core dumped|unexpected token' "$out_file"; then
            echo "FAIL: ${label} -- shell error/crash detected in output" >&2
            cat "$out_file" >&2
            exit 1
        fi

        if [[ ! -s "${case_dir}/.aws/config" ]]; then
            echo "FAIL: ${label} -- ~/.aws/config is empty after run" >&2
            exit 1
        fi
        if ! grep -q '^\[' "${case_dir}/.aws/config"; then
            echo "FAIL: ${label} -- ~/.aws/config has no recognizable [...] header after run" >&2
            exit 1
        fi

        echo "PASS: ${label}"
    ) || return 1
    return 0
}

# setup_test_config <dir>
# Normal, unpoisoned config: one infra profile (never touched) + one clean
# CSG profile (customer-a, account 111111111111, no foreign keys) + [default].
setup_test_config() {
    local dir="$1"
    mkdir -p "${dir}/.aws"
    cat > "${dir}/.aws/config" <<'AWSCONF'
[profile crossaccount-user]
credential_process = /path/to/get-sts-token.sh --some-arg
region = ap-northeast-2

[profile customer-a]
credential_process = /path/to/get-customer-credentials.sh --account-id 111111111111 --agent claude-code
region = ap-northeast-2

[default]
region = ap-northeast-2
AWSCONF
}

# setup_no_csg_config <dir>
# Infra profile(s) only -- no section has a credential_process pointing at
# get-customer-credentials.sh. Used to prove PROF-14/D-08: a cleanup run
# that deletes nothing stays silent about .bak.
setup_no_csg_config() {
    local dir="$1"
    mkdir -p "${dir}/.aws"
    cat > "${dir}/.aws/config" <<'AWSCONF'
[profile crossaccount-user]
credential_process = /path/to/get-sts-token.sh --some-arg
region = ap-northeast-2

[default]
region = ap-northeast-2
AWSCONF
}

# -- Incident-reproduction case (PROF-07 criterion 2) --------------------------

run_incident_repro() {
    local case_dir="${WORK_DIR}/incident_repro"
    mkdir -p "$case_dir"
    local label="PROF-07 criterion 2 (incident repro): SSO keys + injected credential_process + expired cache survives cleanup --all"

    (
        export HOME="$case_dir"
        setup_poisoned_hybrid_config "$case_dir"
        setup_expired_cache "$case_dir" "333333333333"

        bash "${SCRIPT}" cleanup --all 2>/dev/null || true

        if ! grep -q "\\[profile csg-poisoned\\]" "${case_dir}/.aws/config"; then
            echo "FAIL: ${label} -- csg-poisoned section was removed (must survive as a foreign-key-carrying hybrid)" >&2
            exit 1
        fi

        echo "PASS: incident-repro -- ${label}"
    ) || return 1
    return 0
}

# -- Unit-level predicate tests (PROF-07 criterion 1) ---------------------------

run_unit_predicates() {
    local case_dir="${WORK_DIR}/unit_predicates"
    mkdir -p "$case_dir"
    local label="PROF-07 criterion 1 + PROF-08: is_csg_profile / is_contaminated_hybrid / is_foreign_key unit-level verdicts"

    (
        local func_file="${case_dir}/funcs.sh"
        awk '/^# --- Profile cleanup helpers ---$/,/^# --- Subcommand routing/' "$SCRIPT" | sed '$d' > "$func_file"

        local clean_cp="/path/to/get-customer-credentials.sh --account-id 777777777777 --agent claude-code"
        # PROF-08: a section that carries the csg_managed marker but NO
        # credential_process at all (the Phase 23 rename/migration shape).
        local no_cp=""

        # assert_rc <expected_rc> <note> <predicate> [args...]
        # Runs <predicate> in a fresh subshell that sources the awk-extracted
        # helper block, then compares the exit code. Keeps the file's existing
        # FAIL shape: both the expected and the actual rc are always printed.
        assert_rc() {
            local expected="$1"; shift
            local note="$1"; shift

            set +e
            ( source "$func_file"; "$@" )
            local actual=$?
            set -e

            if [[ $actual -ne $expected ]]; then
                echo "FAIL: ${label} -- $* returned ${actual}, expected ${expected} (${note})" >&2
                return 1
            fi
            return 0
        }

        # -- Phase 21 verdicts (must stay unchanged) --------------------------
        assert_rc 1 "excluded: foreign key present" \
            is_csg_profile "$clean_cp" "csg-a" "true" || exit 1
        assert_rc 0 "eligible: clean legacy CSG profile" \
            is_csg_profile "$clean_cp" "csg-a" "false" || exit 1
        assert_rc 0 "poisoned hybrid" \
            is_contaminated_hybrid "$clean_cp" "csg-a" "true" || exit 1
        assert_rc 1 "not contaminated" \
            is_contaminated_hybrid "$clean_cp" "csg-a" "false" || exit 1

        # -- PROF-08 marker truth table (D-06) --------------------------------
        assert_rc 0 "marker alone establishes ownership (Phase 23 forward contract)" \
            is_csg_profile "$no_cp" "csg-a" "false" "true" || exit 1
        assert_rc 0 "legacy markerless profile is NOT orphaned (superset, D-06)" \
            is_csg_profile "$clean_cp" "csg-a" "false" "false" || exit 1
        assert_rc 1 "foreign-key veto beats the marker (D-06, veto stays top-level)" \
            is_csg_profile "$clean_cp" "csg-a" "true" "true" || exit 1
        assert_rc 1 "SKIP_PROFILES outranks the marker" \
            is_csg_profile "$no_cp" "default" "false" "true" || exit 1
        assert_rc 1 "no ownership evidence at all" \
            is_csg_profile "$no_cp" "csg-a" "false" "false" || exit 1
        assert_rc 1 "3-arg call stays backward compatible (has_marker defaults false)" \
            is_csg_profile "$clean_cp" "csg-a" "true" || exit 1
        # Mutation sentinel: this is the ONE assertion that observes the
        # has_marker DEFAULT. Every other row passes all 4 args explicitly, so
        # flipping "${4:-false}" to "${4:-true}" would otherwise go unnoticed --
        # with a true default, a section carrying no ownership evidence at all
        # would become sweep-eligible.
        assert_rc 1 "3-arg call must NOT infer a marker (default is false)" \
            is_csg_profile "$no_cp" "csg-a" "false" || exit 1

        assert_rc 0 "marker-only contamination is still reported" \
            is_contaminated_hybrid "$no_cp" "csg-a" "true" "true" || exit 1
        assert_rc 0 "Phase 21 behavior preserved on 3-arg call" \
            is_contaminated_hybrid "$clean_cp" "csg-a" "true" || exit 1
        assert_rc 1 "marker without a foreign key is not contamination" \
            is_contaminated_hybrid "$clean_cp" "csg-a" "false" "true" || exit 1
        # Mutation sentinel for is_contaminated_hybrid's own default (see above).
        assert_rc 1 "3-arg call must NOT infer a marker (default is false)" \
            is_contaminated_hybrid "$no_cp" "csg-a" "true" || exit 1

        # -- PROF-08: the marker must NOT be classified as a foreign key -------
        # (adding a "csg_" family to FOREIGN_KEY_PREFIXES would silently make
        # every CSG profile permanently un-sweepable.)
        assert_rc 1 "csg_managed must never be a foreign key" \
            is_foreign_key "csg_managed" || exit 1
        assert_rc 0 "sso_ prefix family still matches (Phase 21 regression)" \
            is_foreign_key "sso_registration_scopes" || exit 1

        echo "PASS: ${label}"
    ) || return 1
    return 0
}

# -- PROF-08 marker presence-only behavioral regression -------------------------

# setup_marker_config <dir>
# Three sections exercising the marker axis end-to-end:
#   [profile csg-future]   marker with an UNKNOWN future version string
#                          (account 111111111111) -- must still be swept
#   [profile csg-poisoned] marker + a foreign SSO key (account 333333333333)
#                          -- the Phase 21 veto must still protect it
#   [default]              infrastructure profile -- never touched
setup_marker_config() {
    local dir="$1"
    mkdir -p "${dir}/.aws"
    cat > "${dir}/.aws/config" <<'AWSCONF'
[profile csg-future]
credential_process = /path/to/get-customer-credentials.sh --account-id 111111111111 --agent claude-code
csg_managed = 9.9.9-future
region = ap-northeast-2

[profile csg-poisoned]
credential_process = /path/to/get-customer-credentials.sh --account-id 333333333333 --agent claude-code
csg_managed = 1.7.0
sso_start_url = https://example.awsapps.com/start
region = ap-northeast-2

[default]
region = ap-northeast-2
AWSCONF
}

run_marker_presence_only() {
    local case_dir="${WORK_DIR}/marker_presence_only"
    mkdir -p "$case_dir"
    local label="PROF-08: csg_managed is consumed presence-only -- a future version string is still swept, and the foreign-key veto still wins"

    (
        export HOME="$case_dir"
        setup_marker_config "$case_dir"

        local out_file="${case_dir}/out.txt"
        set +e
        bash "${SCRIPT}" cleanup --all >"$out_file" 2>&1
        local rc=$?
        set -e

        if [[ $rc -ne 0 ]]; then
            echo "FAIL: ${label} -- exit code ${rc}, expected 0" >&2
            cat "$out_file" >&2
            exit 1
        fi

        local config_file="${case_dir}/.aws/config"

        # (1) csg_managed = 9.9.9-future must NOT act as a shield: the value is
        #     never compared, only its presence is read.
        local future_count
        future_count=$(grep -c '^\[profile csg-future\]' "$config_file" || true)
        if [[ "$future_count" != "0" ]]; then
            echo "FAIL: ${label} -- csg-future survived; the marker VALUE appears to be matched instead of just its presence" >&2
            exit 1
        fi

        # (2) A marker does not license touching a foreign-key section.
        local poisoned_count
        poisoned_count=$(grep -c '^\[profile csg-poisoned\]' "$config_file" || true)
        if [[ "$poisoned_count" != "1" ]]; then
            echo "FAIL: ${label} -- csg-poisoned was removed (marker must not override the Phase 21 foreign-key veto)" >&2
            exit 1
        fi

        # (3) Infrastructure profile untouched.
        local default_count
        default_count=$(grep -c '^\[default\]' "$config_file" || true)
        if [[ "$default_count" != "1" ]]; then
            echo "FAIL: ${label} -- [default] section is missing after cleanup --all" >&2
            exit 1
        fi

        echo "PASS: ${label}"
    ) || return 1
    return 0
}

# -- WR-03 marker-only orphan visibility ----------------------------------------

# HOME CHOICE (WR03-03): this case lives HERE and not in test/cleanup.test.sh
# because its subject is the foreign-key VETO -- the Phase 21 invariant this
# suite owns -- and it is the direct sibling of run_marker_presence_only above.
# WR03-01/WR03-02 (recovery + expiry-mode decline) live in test/cleanup.test.sh
# because their subject is cleanup's own two modes. No assertion is duplicated
# across the two suites.
#
# setup_marker_only_foreign_config <dir>
#   [profile csg-orphan-poisoned]  csg_managed + a foreign SSO key, NO
#                                  credential_process. The WR-03 relaxation now
#                                  makes this section VISIBLE to _process_profile;
#                                  the veto downstream must still protect it.
#   [default]                      infrastructure profile -- never touched
setup_marker_only_foreign_config() {
    local dir="$1"
    mkdir -p "${dir}/.aws"
    cat > "${dir}/.aws/config" <<'AWSCONF'
[profile csg-orphan-poisoned]
csg_managed = 1.7.0
sso_start_url = https://example.awsapps.com/start
region = ap-northeast-2

[default]
region = ap-northeast-2
AWSCONF
}

run_wr03_foreign_veto_outranks_relaxation() {
    local case_dir="${WORK_DIR}/wr03_foreign_veto"
    mkdir -p "$case_dir"
    local label="WR03-03: a marker-only section that ALSO carries a foreign key stays inviolable -- the foreign veto outranks the WR-03 relaxation"

    (
        export HOME="$case_dir"
        setup_marker_only_foreign_config "$case_dir"

        local out_file="${case_dir}/out.txt"
        set +e
        bash "${SCRIPT}" cleanup --all >"$out_file" 2>&1
        local rc=$?
        set -e

        if [[ $rc -ne 0 ]]; then
            echo "FAIL: ${label} -- exit code ${rc}, expected 0" >&2
            cat "$out_file" >&2
            exit 1
        fi

        local config_file="${case_dir}/.aws/config"

        # (1) The section survives. Widening _process_profile's entry guard must
        #     not widen ELIGIBILITY -- is_csg_profile's foreign check is
        #     downstream of the relaxation and still returns 1 here.
        local poisoned_count
        poisoned_count=$(grep -c '^\[profile csg-orphan-poisoned\]' "$config_file" || true)
        if [[ "$poisoned_count" != "1" ]]; then
            echo "FAIL: ${label} -- csg-orphan-poisoned was removed; the WR-03 relaxation leaked past the foreign-key veto" >&2
            cat "$out_file" >&2
            exit 1
        fi

        # (2) Its foreign key is still present verbatim (not surgically stripped
        #     by cleanup -- that is doctor's job, never cleanup's).
        if ! grep -q '^sso_start_url = https://example.awsapps.com/start$' "$config_file"; then
            echo "FAIL: ${label} -- the foreign sso_start_url key was modified or removed by cleanup" >&2
            exit 1
        fi

        # (3) Infrastructure profile untouched.
        local default_count
        default_count=$(grep -c '^\[default\]' "$config_file" || true)
        if [[ "$default_count" != "1" ]]; then
            echo "FAIL: ${label} -- [default] section is missing after cleanup --all" >&2
            exit 1
        fi

        echo "PASS: ${label}"
    ) || return 1
    return 0
}

# -- PROF-14 .bak recovery-message tests (criterion 3) --------------------------

run_prof14_deletion_message() {
    local case_dir="${WORK_DIR}/prof14_deletion"
    mkdir -p "$case_dir"
    local label="PROF-14 criterion 3: deletion prints a copy-paste-able cp recovery command referencing an existing .bak file"

    (
        export HOME="$case_dir"
        setup_test_config "$case_dir"
        setup_expired_cache "$case_dir" "111111111111"

        local stderr_file="${case_dir}/stderr.txt"
        set +e
        bash "${SCRIPT}" cleanup 2>"$stderr_file"
        local rc=$?
        set -e

        if [[ $rc -ne 0 ]]; then
            echo "FAIL: ${label} -- exit code ${rc}, expected 0" >&2
            cat "$stderr_file" >&2
            exit 1
        fi

        local recovery_line
        recovery_line=$(grep -E 'cp .*\.bak\.[0-9]+ .*config' "$stderr_file" || true)
        if [[ -z "$recovery_line" ]]; then
            echo "FAIL: ${label} -- no 'cp <...>.bak.<timestamp> <...>config' recovery command found in stderr" >&2
            echo "  stderr was: $(cat "$stderr_file")" >&2
            exit 1
        fi

        local bak_path
        bak_path=$(printf '%s' "$recovery_line" | grep -oE '[^ ]+\.bak\.[0-9]+' | head -1)
        if [[ -z "$bak_path" || ! -f "$bak_path" ]]; then
            echo "FAIL: ${label} -- extracted .bak path does not exist on disk: ${bak_path}" >&2
            exit 1
        fi

        echo "PASS: ${label}"
    ) || return 1
    return 0
}

run_prof14_silence() {
    local case_dir="${WORK_DIR}/prof14_silence"
    mkdir -p "$case_dir"
    local label="PROF-14 criterion 3 (D-08): cleanup run that deletes nothing stays silent about .bak"

    (
        export HOME="$case_dir"
        setup_no_csg_config "$case_dir"

        local stderr_file="${case_dir}/stderr.txt"
        set +e
        bash "${SCRIPT}" cleanup 2>"$stderr_file"
        local rc=$?
        set -e

        if [[ $rc -ne 0 ]]; then
            echo "FAIL: ${label} -- exit code ${rc}, expected 0" >&2
            cat "$stderr_file" >&2
            exit 1
        fi

        if grep -q '\.bak' "$stderr_file"; then
            echo "FAIL: ${label} -- stderr mentions .bak even though nothing was deleted" >&2
            echo "  stderr was: $(cat "$stderr_file")" >&2
            exit 1
        fi

        echo "PASS: ${label}"
    ) || return 1
    return 0
}

# -- Guard skip-line dedup test (D-06) -------------------------------------------

run_dedup_skip_line() {
    local case_dir="${WORK_DIR}/dedup_skip"
    mkdir -p "$case_dir"
    local label="D-06: guard skip line for a poisoned hybrid fires once, then is silenced + dedup-recorded across invocations"

    (
        export HOME="$case_dir"
        setup_poisoned_hybrid_config "$case_dir"

        local stderr1="${case_dir}/stderr1.txt"
        local stderr2="${case_dir}/stderr2.txt"

        bash "${SCRIPT}" --account-id 000000000000 --agent claude-code 2>"$stderr1" || true
        bash "${SCRIPT}" --account-id 000000000000 --agent claude-code 2>"$stderr2" || true

        if ! grep -q '\[guard\].*csg-poisoned' "$stderr1"; then
            echo "FAIL: ${label} -- first invocation did not print the guard skip line for csg-poisoned" >&2
            echo "  stderr1 was: $(cat "$stderr1")" >&2
            exit 1
        fi

        if grep -q '\[guard\].*csg-poisoned' "$stderr2"; then
            echo "FAIL: ${label} -- second invocation repeated the guard skip line (dedup should have silenced it)" >&2
            echo "  stderr2 was: $(cat "$stderr2")" >&2
            exit 1
        fi

        local record_file="${case_dir}/.cache/msp/customer-creds/guard-skips.jsonl"
        if [[ ! -f "$record_file" ]]; then
            echo "FAIL: ${label} -- guard-skips.jsonl was not created" >&2
            exit 1
        fi
        if ! grep -q 'csg-poisoned' "$record_file"; then
            echo "FAIL: ${label} -- guard-skips.jsonl does not mention csg-poisoned" >&2
            exit 1
        fi

        echo "PASS: ${label}"
    ) || return 1
    return 0
}

# -- Runner -------------------------------------------------------------------

echo "=== Phase 21: Sweep Guard (Foreign-Key Immunity) (PROF-07 criteria 1/2/4, PROF-14 criterion 3) ==="
echo ""

run_case_sso_session_adjacent || failures=$((failures + 1))
run_case_crlf || failures=$((failures + 1))
run_case_bom || failures=$((failures + 1))
run_case_quoted_name || failures=$((failures + 1))
run_case_double_space_header || failures=$((failures + 1))
run_incident_repro || failures=$((failures + 1))
run_unit_predicates || failures=$((failures + 1))
run_marker_presence_only || failures=$((failures + 1))
run_wr03_foreign_veto_outranks_relaxation || failures=$((failures + 1))
run_prof14_deletion_message || failures=$((failures + 1))
run_prof14_silence || failures=$((failures + 1))
run_dedup_skip_line || failures=$((failures + 1))

echo ""
if [[ $failures -gt 0 ]]; then
    echo "RESULT: ${failures} case(s) FAILED (out of 12)"
    exit 1
fi
echo "RESULT: all 12 cases PASS"
exit 0
