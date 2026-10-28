#!/usr/bin/env bash
# get-customer-credentials.sh
#
# AWS CLI credential_process wrapper that exchanges a cached Slack Bearer for a
# ready-to-use, read-only customer session by calling the broker endpoint
#   POST /v1/customer-credentials
# The broker performs the customer AssumeRole and attaches ReadOnlyAccess
# SERVER-SIDE (Phase 17). This client holds ZERO privileged credentials and
# runs NO local STS AssumeRole — read-only is enforced structurally at the
# IAM layer, not by this script.
#
# Usage (registered as credential_process for a customer profile):
#   get-customer-credentials.sh --account-id <12-digit> [--agent <name>]
#
# Auth:   Bearer read from ~/.cache/msp/sts-token.json (.SlackAccessToken),
#         obtained by running get-sts-token.sh first. The Bearer is NEVER passed
#         on argv and NEVER logged. If it is missing/empty this script fails fast
#         (no browser/OAuth is ever opened from inside credential_process).
# Output: AWS CLI credential_process JSON on stdout — exactly the 5-key contract
#         { Version:1, AccessKeyId, SecretAccessKey, SessionToken, Expiration }.
#         BrokerVersion (returned by the broker) is projected out.
#         The `register` SUBCOMMAND has its own, SEPARATE stdout contract: on
#         success it prints exactly one line (the profile name) and nothing else;
#         on abort stdout stays completely empty and every diagnostic goes to
#         stderr prefixed "[register] ". register is never invoked from inside
#         credential_process, so the two contracts can never interleave.
#         The `scope-ack` SUBCOMMAND likewise has its own stdout contract: on
#         success exactly one BRACE-FREE line, on abort stdout stays empty — and
#         like register it is never invoked from inside credential_process, so
#         those two contracts cannot interleave either.
# Cache:  ~/.cache/msp/customer-creds/<account-id>.json
#
# Notes:
#   * The customer role/external-id/session-policy/identity-stamping are all
#     resolved server-side; this client only supplies {accountId, agent}.
#   * All diagnostic output goes to stderr; stdout is reserved for the
#     credential_process JSON contract.

set -euo pipefail

CACHE_DIR="${HOME}/.cache/msp/customer-creds"
# D-04/D-05: local-only, best-effort record of contaminated-hybrid sections the
# guard has skipped (see record_and_warn_skip). MUST end in ".jsonl" (not
# ".json") so do_cleanup's `rm -f "${CACHE_DIR}"/*.json` glob (see do_cleanup)
# can never wipe this audit trail.
SKIP_RECORD="${CACHE_DIR}/guard-skips.jsonl"
# PROF-12: one-shot completion marker for the client fleet migration. MUST end in
# ".jsonl" for exactly the same reason as SKIP_RECORD above -- do_cleanup's
# `rm -f "${CACHE_DIR}"/*.json` glob would otherwise delete it and RE-ARM the
# destructive migration on every `cleanup --all`, which is the one code path in
# this milestone that must never run twice by accident.
MIGRATION_RECORD="${CACHE_DIR}/migrations.jsonl"
# Identity of the migration this client version ships. A future migration gets a
# NEW id (and therefore runs once more); it never reuses this one.
MIGRATION_ID="v1.7-csg-namespace"
# Counters filled in by do_migrate and consumed by run_migration_once's marker
# write. Globals rather than stdout because stdout is the credential JSON channel.
MIGRATE_RENAMED=0
MIGRATE_REPAIRED=0
MIGRATE_SKIPPED=0
MIGRATE_TRANSIENT_FAILURES=0

# --- scope brake constants (SCP-05) ---
# The deterministic client-side fan-out brake. Calibration point is the v1.7
# incident: one agent issued credentials for 12 customer accounts in 54 seconds
# and no single log showed that as ONE event. What this buys is friction, a local
# record and a deterministic refusal -- it is not a wall, because the agent owns
# both the shell and the filesystem (X7 honest labelling; the server-side
# backstop is Phase 25 DET-01).
#
# Both records MUST end in ".jsonl", for exactly the same reason as SKIP_RECORD
# and MIGRATION_RECORD above: do_cleanup's `rm -f "${CACHE_DIR}"/*.json` glob
# (see do_cleanup) cannot match a ".jsonl" name. If it could, `cleanup --all`
# would be a one-command window reset -- precisely the bypass this brake exists
# to close (D-08).
SCOPE_WINDOW_RECORD="${CACHE_DIR}/scope-window.jsonl"   # operational, pruned
SCOPE_ACK_RECORD="${CACHE_DIR}/scope-acks.jsonl"        # audit, append-only
# A FILE, never a directory. The PowerShell twin opens this SAME path with
# [IO.File]::Open(..., FileShare::None); a directory left here makes that call
# throw forever and bricks the other client permanently (Phase 23 WR-09 records
# both directions of that two-way bricking).
# Deliberately NOT .sweep.lock: that lock is non-blocking with 2 attempts and is
# held across whole ~/.aws/config rewrites, so a brake sharing it would have to
# fail open on every contended parallel invocation -- the exact hole D-17 exists
# to close.
SCOPE_LOCK="${CACHE_DIR}/.scope.lock"
# D-02: the 12-in-54s incident is the calibration point. One customer's routine
# 2-4 accounts must keep passing untouched, so the allowance sits above that and
# far below the incident, over a window short enough that a genuine fan-out lands
# inside it.
# D-04: release-only. There is deliberately NO env var and NO
# credential-broker.conf key for any of these three. The agent owns the shell and
# that conf file, so a tunable would not be a knob -- it would be an unlogged
# bypass, and an unlogged bypass is the thing this brake is here to make loud.
SCOPE_MAX_ACCOUNTS=5
SCOPE_WINDOW_SECONDS=300
SCOPE_ACK_TTL_SECONDS=3600

CACHE_SKEW_SECONDS="300"
CONFIG_FILE="${HOME}/.config/msp/credential-broker.conf"
STS_CACHE="${HOME}/.cache/msp/sts-token.json"
# PROF-08: value written into every register-created profile as `csg_managed`;
# presence-only, never value-matched by any predicate (a future/older version
# string must stay sweep-eligible). Hardcoded because the VERSION file is not in
# install.sh's SKILL_FILES manifest and therefore unreadable at runtime.
CSG_MANAGED_VERSION="1.7.0"
# ERR-10 (Phase 30): the client build this process is running. Sent to the broker as
# `clientVersion` in the POST body below and logged there as a spread-observation signal
# only -- the broker reads it unvalidated and it can NEVER fail an issuance (D-07). That
# is deliberate: a regex gate on a version field would kill fleet-wide issuance the first
# time a stamp went wrong.
#
# install.sh stamps this literal with the release $VERSION on BOTH install paths (do_pack
# and direct repo install), so the value below is only ever observed when the script runs
# straight out of a repo checkout; drift between it and the VERSION file is expected and
# harmless, exactly like self-update.sh's LOCAL_VERSION. Byte-locked to the
# get-customer-credentials.ps1 twin by a parity case, the same way CSG_MANAGED_VERSION is.
#
# The SPELLING is load-bearing (T-30-13): install.sh's stamping sed is ^-anchored and
# exits 0 whether or not it matched, so renaming this constant would silently ship a stale
# version to the entire fleet with a green build.
# tiket 으로 옮긴 뒤 (0040, 2026-10-20): 클라이언트 버전은 tiket 릴리스 태그다. 위 설명의 install.sh
# 스탬프는 더 이상 이 사본에 닿지 않는다 — 스크립트가 든 워크스페이스의 git 에서 읽는다. 못 읽으면
# tiket-unknown 이고, 브로커는 unknown 을 막지 않는다(D-07). 실패해도 발급을 멈추지 않도록 || 로 감싼다.
CLIENT_VERSION="tiket-$(git -C "$(dirname "${BASH_SOURCE[0]}")" describe --tags --abbrev=0 2>/dev/null || echo unknown)"

ACCOUNT_ID=""
AGENT_NAME=""

usage() {
    cat >&2 <<'EOF'
사용법: get-customer-credentials.sh [SUBCOMMAND | OPTIONS]

AWS CLI credential_process로 등록되어, 캐시된 Slack Bearer로 브로커
(/v1/customer-credentials)를 호출해 고객사 read-only 세션을 받아옵니다.
AssumeRole 과 ReadOnlyAccess 세션 정책은 모두 브로커(서버)가 처리합니다.
이 스크립트는 어떤 권한 자격 증명도 보관하지 않으며 로컬 assume 를 하지 않습니다.

SUBCOMMANDS:
  cleanup        만료된 CSG 프로필을 ~/.aws/config에서 제거
  cleanup --all  모든 CSG 프로필과 캐시 파일 전체 삭제
  register --account-id <id> --account-name "{name}" [--corp-name "{corp}"]
                 고객사 프로필을 충돌 검사 후 생성/갱신 (PROF-08/10/11).
                 성공 시 프로필명 1줄만 stdout, 충돌 시 stdout 비우고 중단.
  doctor         오염된 하이브리드 섹션(엔지니어 본인 credential 키에 CSG 키가
                 섞인 상태)을 찾아 csg_managed / credential_process 두 키만
                 제거. 섹션과 sso_*/region/output 은 값까지 보존. 인자 없음.
  migrate        구 이름 CSG 프로필을 csg- 네임스페이스로 1회 이전 (PROF-12).
                 구 섹션은 삭제되고 구명→새명 매핑표가 stderr 에 출력됩니다.
                 확인 프롬프트 없음. 두 번째 실행부터는 아무것도 하지 않습니다.
  scope-ack --account-ids <id,id,...>
                 2개 이상 계정 배치를 시작하기 전에 대상 범위를 승인 기록에
                 남깁니다 (1시간 유효). 성공 시 stdout 1줄.

OPTIONS:
  --account-id ID         (필수) 고객 AWS 계정 ID (12자리)
  --agent NAME            (선택) AI 에이전트 이름 (claude-code, kiro 등).
                          생략 시 런타임 환경(MSP_AGENT/AI_AGENT/CLAUDECODE/
                          TERM_PROGRAM/__CFBundleIdentifier)에서 실제 호출 에이전트를
                          자동 감지하고, 없으면 설치 경로로 폴백.
  --region REGION         (선택, 하위호환용 no-op — 로컬 assume 가 없어 무시됨)
  --session-name NAME     (선택, 하위호환용 no-op — 신원은 브로커가 서버에서 각인)
  --help                  도움말 출력

AUTH:
  ~/.cache/msp/sts-token.json 의 SlackAccessToken (get-sts-token.sh 로 발급)

OUTPUT:
  stdout — AWS CLI credential_process JSON (5-key 계약)
  stderr — 진단 메시지 (캐시 hit/miss, 에러 등)

CACHE:
  ~/.cache/msp/customer-creds/<account-id>.json
EOF
}

log() {
    printf '[get-customer-credentials] %s\n' "$*" >&2
}

die() {
    log "ERROR: $*"
    exit 1
}

require_cmds() {
    for cmd in curl jq; do
        if ! command -v "$cmd" &>/dev/null; then
            die "'$cmd' 명령이 설치되어 있지 않습니다."
        fi
    done
}

# --- Profile cleanup helpers ---

# Infrastructure profiles that must never be touched by cleanup operations, and
# (via the do_register veto) never MINTED either.
# This is NOT the same list as install.sh's never-touch set -- that one is
# shorter and serves the installer's own narrower purpose. Do not "resync" them.
#
# `csg-login` is here because of Phase 23: once derive_profile_name namespaces
# every derived name under `csg-`, `--account-name "Login"` becomes a reachable
# spelling of the broker anchor profile for the first time. Without this entry
# an engineer (or an agent acting on a BILLING accountName) could overwrite the
# one profile every customer session is brokered through (T-23-01).
readonly -a SKIP_PROFILES=("crossaccount-user" "crossaccount-role" "default" "msp-homepage" "msp-internal" "csg-login")

# Foreign credential-key prefix families (PROF-07 success criterion 1). Entries
# ending in "_" are startswith-prefix families (e.g. "sso_" also catches
# sso_region/sso_registration_scopes/... for free); the rest are exact-match.
# Case-folded comparison happens in is_foreign_key / the INI loop below.
readonly -a FOREIGN_KEY_PREFIXES=("sso_" "role_" "source_profile" "credential_source" "aws_" "web_identity_token_file" "mfa_serial" "external_id" "duration_seconds")

# is_foreign_key <key>
# <key> must already be trimmed and case-folded by the caller. Returns 0 if it
# matches any FOREIGN_KEY_PREFIXES entry: prefix match for entries ending in
# "_", exact match otherwise.
is_foreign_key() {
    local key="$1"
    local prefix
    for prefix in "${FOREIGN_KEY_PREFIXES[@]}"; do
        if [[ "$prefix" == *_ ]]; then
            [[ "$key" == "${prefix}"* ]] && return 0
        else
            [[ "$key" == "$prefix" ]] && return 0
        fi
    done
    return 1
}

# is_csg_profile <credential_process_value> <profile_name> [<has_foreign_keys: true|false>] [<has_marker: true|false>]
# Returns 0 if the profile is a CSG customer profile (eligible for cleanup).
# A CSG profile has POSITIVE OWNERSHIP -- either the `csg_managed` marker key
# (PROF-08, written by register) OR a credential_process containing
# "get-customer-credentials.sh" (D-05, the legacy path-dependent signature)
# AND is NOT in SKIP_PROFILES (D-06)
# AND has NO foreign credential key in its section (PROF-07 -- has_foreign must
# be "false").
#
# PROF-08/D-06: the marker is an OR-widening SUPERSET of the legacy signature --
# a shipped CSG profile that predates the marker is never orphaned. The marker
# is presence-only (a boolean here); its VALUE is never compared, so a profile
# stamped with a future CSG_MANAGED_VERSION stays sweep-eligible.
# The foreign-key check stays LAST: the Phase 21 veto is top-level, and holding
# the marker is not a license to touch a section carrying foreign credentials.
# The 3rd/4th params default to "false" so 2-arg and 3-arg callers stay
# backward compatible.
is_csg_profile() {
    local cp_value="$1"
    local prof_name="$2"
    local has_foreign="${3:-false}"
    local has_marker="${4:-false}"

    # Positive ownership: the csg_managed marker OR credential_process pointing
    # at this script. Only fall back to the cp signature when the marker is absent.
    if [[ "$has_marker" != "true" ]]; then
        [[ "$cp_value" == *get-customer-credentials.sh* ]] || return 1
    fi

    # Must not be an infrastructure profile
    local sp
    for sp in "${SKIP_PROFILES[@]}"; do
        [[ "$prof_name" == "$sp" ]] && return 1
    done

    # PROF-07: never sweep/cleanup-eligible if the section carries any foreign key
    [[ "$has_foreign" == "true" ]] && return 1

    return 0
}

# is_contaminated_hybrid <credential_process_value> <profile_name> <has_foreign_keys> [<has_marker: true|false>]
# Returns 0 if this section is a poisoned hybrid: it WOULD have been
# sweep/cleanup-eligible under the pre-Phase-21 (2-arg) is_csg_profile
# predicate (credential_process points at this script AND not in
# SKIP_PROFILES) but ALSO carries a foreign credential key. Distinct from
# is_csg_profile (sweep-eligibility): this answers the narrower "should this
# be reported to the engineer/doctor as poisoned?" question (D-04/D-05/D-07).
#
# PROF-08/D-06: positive ownership is the same OR-superset as is_csg_profile --
# (csg_managed marker OR cp signature) AND has_foreign. The marker is
# presence-only; its value is never compared. The 4th param defaults to "false"
# so every existing 3-arg caller stays backward compatible.
is_contaminated_hybrid() {
    local cp_value="$1"
    # WR-03: prof_name is intentionally NOT checked against SKIP_PROFILES here.
    # is_csg_profile (sweep/cleanup ELIGIBILITY) still excludes SKIP_PROFILES,
    # so those sections are never deleted -- but the audit/warning predicate
    # must report contamination of ANY section, including infra profiles like
    # [default] (which drives every unqualified AWS CLI call and is arguably
    # the highest-value section to flag, not the lowest).
    local prof_name="$2"
    local has_foreign="$3"
    local has_marker="${4:-false}"

    # Positive ownership: marker OR legacy cp signature (PROF-08 superset).
    if [[ "$has_marker" != "true" ]]; then
        [[ "$cp_value" == *get-customer-credentials.sh* ]] || return 1
    fi
    [[ "$has_foreign" == "true" ]] || return 1

    return 0
}

# already_recorded <section_name>
# Returns 0 if <section_name> already has an entry in SKIP_RECORD (D-06 dedup,
# persists across separate credential_process invocations). Fail-open: a
# missing/unreadable record file means "not yet recorded" (return 1) -- never
# blocks the credential_process hot path.
already_recorded() {
    local name="$1"
    [[ -f "$SKIP_RECORD" ]] || return 1
    # WR-02: match on the SAME jq-escaped JSON string literal record_and_warn_skip
    # writes (a raw substring match against an unescaped name breaks dedup the
    # moment the name contains a '"', e.g. a legal INI section like [profile csg-"a]).
    local escaped
    escaped=$(jq -Rn --arg s "$name" '$s' 2>/dev/null) || return 1
    grep -Fq "\"section\":${escaped}" "$SKIP_RECORD" 2>/dev/null
}

# record_and_warn_skip <section_name>
# D-04/D-05/D-06/D-07: append a one-line JSON record of a contaminated-hybrid
# section the guard just skipped (first-seen only, deduped via
# already_recorded) and print exactly one stderr line referencing the doctor
# subcommand. Fail-open on the record append -- must never be fatal on the
# credential_process hot path.
record_and_warn_skip() {
    local name="$1"
    already_recorded "$name" && return 0

    # WR-02: JSON-escape the (attacker-influenceable) profile name via jq rather
    # than raw-interpolating it -- a name containing '"' previously produced a
    # malformed JSONL line and silently broke the already_recorded dedup above.
    # WR-01: the redirection is INSIDE the brace group and the group's stderr is
    # discarded as a whole. `jq ... >> "$SKIP_RECORD" 2>/dev/null` only silences
    # jq -- the shell's own "No such file or directory" for the append target is
    # emitted before jq ever runs and leaked a raw, un-prefixed, $HOME-revealing
    # line onto doctor's stderr, violating the "every line is [doctor]-prefixed"
    # contract. The routing blocks now mkdir CACHE_DIR, but this stays as
    # defence in depth: a future caller that forgets cannot leak either.
    { jq -cn --arg s "$name" --arg t "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '{section:$s, first_seen:$t}' >> "$SKIP_RECORD"; } 2>/dev/null || true

    # PROF-13/T-23-21: do_doctor calls collect_csg_profiles to FIND these very
    # sections and repairs them in the same run, so the advisory below would tell
    # the engineer to run the command they are already running. The JSONL record
    # above is still written -- doctor genuinely did observe the contamination;
    # only the now-self-referential advisory is suppressed.
    [[ "${GUARD_SKIP_QUIET:-false}" == "true" ]] && return 0

    printf '[guard] 외래 키 섹션 건너뜀: %s (get-customer-credentials.sh doctor 로 복구 가능)\n' \
        "$name" >&2
}

# is_cache_expired <cache_file_path> [now_epoch]
# Returns 0 if expired (or missing/unparseable), 1 if still valid.
# Reuses emit_from_cache() expiry logic with CACHE_SKEW_SECONDS (D-04, PROF-05).
is_cache_expired() {
    local cache_file="$1"
    local now="${2:-}"

    # D-02: No cache file = expired
    [[ -f "$cache_file" ]] || return 0

    local exp
    exp=$(jq -r '.Expiration // empty' "$cache_file" 2>/dev/null) || return 0
    [[ -n "$exp" ]] || return 0

    # ISO8601 -> epoch: same dual-path as emit_from_cache (lines 195-203)
    local exp_clean="${exp/Z/+0000}"
    exp_clean=$(printf '%s' "$exp_clean" | sed -E 's/\.[0-9]+([+-])/\1/')
    local exp_epoch
    if exp_epoch=$(date -u -d "$exp" +%s 2>/dev/null); then
        :
    elif exp_epoch=$(date -u -j -f "%Y-%m-%dT%H:%M:%S%z" "$exp_clean" +%s 2>/dev/null); then
        :
    else
        return 0  # Can't parse = treat as expired
    fi

    [[ -z "$now" ]] && now=$(date -u +%s)

    if (( exp_epoch - now > CACHE_SKEW_SECONDS )); then
        return 1  # Still valid
    fi
    return 0  # Expired
}

# extract_account_id <credential_process_value>
# Extracts the 12-digit --account-id from a credential_process string and prints
# it to stdout. Returns 1 if no account id is present.
# PROF-08: this is the SINGLE home of the account-id regex -- extract_cache_path
# (and any future caller that needs the id itself, not the cache path) delegates
# here so the pattern can never drift between two copies.
extract_account_id() {
    local cp_value="$1"

    # Accept BOTH client spellings: `--account-id N` (bash) and `-AccountId N`
    # (PowerShell), exactly as Get-AccountIdFromCredentialProcess already does.
    # classify_existing_profile recognises OWNERSHIP with the language-agnostic
    # substring `get-customer-credentials`, so a PowerShell-written profile IS
    # CSG-owned to the bash client. A one-sided regex then makes that profile
    # look account-LESS, which silently downgrades an account-mismatch abort
    # (D-09) into an idempotent re-registration -- i.e. bash re-points a
    # PowerShell-registered profile at a DIFFERENT customer and reports success.
    if [[ "$cp_value" =~ -{1,2}[Aa]ccount-?[Ii]d[[:space:]]+([0-9]{12}) ]]; then
        printf '%s' "${BASH_REMATCH[1]}"
        return 0
    fi
    return 1
}

# extract_cache_path <credential_process_value>
# Extracts --account-id from the credential_process string and prints the cache
# file path to stdout. Returns 1 if extraction fails.
# Phase 18: the cache key is <account-id>.json ONLY — the client no longer knows
# the role name (the broker resolves it server-side), so no role segment exists.
extract_cache_path() {
    local cp_value="$1"
    local account_id

    account_id=$(extract_account_id "$cp_value") || return 1

    printf '%s' "${CACHE_DIR}/${account_id}.json"
}

# rewrite_config_removing_profiles <config_file> <profile_name1> [profile_name2 ...]
# Removes entire INI sections for the specified profiles from the config file.
# D-10: Creates .bak.<timestamp> backup before modification.
# D-12: Atomic write via mktemp + mv.
# T-11-01: Uses awk -v variable assignment (not string interpolation) with pipe delimiter.
# Pattern 4/6: matching is done on the PARSED profile name (normalized: CR
# stripped, quotes stripped, whitespace trimmed), not raw-line equality, and a
# post-condition re-read confirms what was actually removed before the PROF-14
# recovery notice is printed (D-08/D-09).
rewrite_config_removing_profiles() {
    local config_file="$1"
    shift
    local -a profiles_to_remove=("$@")

    [[ ${#profiles_to_remove[@]} -eq 0 ]] && return 0
    [[ -f "$config_file" ]] || return 1

    # D-10: Backup before modification.
    # CSG_BACKUP_SESSION (set by do_migrate, unset everywhere else) pins ONE
    # backup path for a multi-step session: a fleet migration calls this helper
    # and remove_keys_from_profile several times, and a per-call .bak would both
    # bury the only useful rollback target (the PRE-migration state) under N
    # intermediate snapshots and break the "one migrate run leaves one .bak"
    # contract (FM-10). With the variable unset the behaviour is unchanged.
    local backup_file="${CSG_BACKUP_SESSION:-${config_file}.bak.$(date +%Y%m%d%H%M%S)}"
    [[ -f "$backup_file" ]] || cp "$config_file" "$backup_file"

    # Build pipe-delimited target list for awk (T-11-01: avoid space injection)
    # CR-01 defense: reject profile names containing the pipe delimiter to prevent
    # injection into the awk split() target set (could match infrastructure profiles).
    # Pattern 4: accumulate PLAIN profile names only (not "[profile X]" literal
    # header strings) -- the awk program below normalizes each header it scans
    # and matches on the extracted name, not on raw-line equality.
    local targets=""
    local p
    for p in "${profiles_to_remove[@]}"; do
        if [[ "$p" == *"|"* ]]; then
            log "WARNING: skipping profile with pipe character in name: ${p}"
            continue
        fi
        [[ -n "$targets" ]] && targets="${targets}|"
        targets="${targets}${p}"
    done

    # All profiles were invalid (contained pipe) -- nothing to remove
    [[ -z "$targets" ]] && return 0

    # Pattern 4/6: normalized header-name extraction, shared by the delete-filter
    # pass below (MODE=delete) and the post-condition re-read (MODE=extract).
    # Written to a temp .awk file (rather than an inline -v string) so the
    # quote-stripping regex doesn't have to survive bash single-quote nesting.
    local awk_prog
    awk_prog=$(mktemp "${TMPDIR:-/tmp}/ccred.awk.XXXXXX")
    cat > "$awk_prog" <<'AWKPROG'
function normalize_name(line,    name) {
    sub(/\r$/, "", line)
    name = ""
    if (match(line, /^\[profile[ \t]+/)) {
        name = substr(line, RLENGTH + 1)
        sub(/\][ \t]*$/, "", name)
        gsub(/^[ \t]+|[ \t]+$/, "", name)
        gsub(/^['"]|['"]$/, "", name)
    } else if (line == "[default]") {
        name = "default"
    }
    return name
}
BEGIN {
    mode_extract = (MODE == "extract")
    if (!mode_extract) {
        n = split(TARGETS, arr, "|")
        for (i = 1; i <= n; i++) target_set[arr[i]] = 1
        skip = 0
    }
}
/^\[/ {
    name = normalize_name($0)
    if (mode_extract) {
        if (name != "") print name
        next
    }
    skip = (name != "" && (name in target_set)) ? 1 : 0
    if (skip) next
}
{ if (!mode_extract && !skip) print }
AWKPROG

    # D-12: Atomic write via mktemp + mv
    # WR-02: Clean up temp file on awk failure or interruption
    local tmp_conf
    tmp_conf=$(mktemp "${config_file}.XXXXXX")

    if ! awk -v MODE="delete" -v TARGETS="$targets" -f "$awk_prog" "$config_file" > "$tmp_conf"; then
        rm -f "$tmp_conf" "$awk_prog"
        return 1
    fi

    mv "$tmp_conf" "$config_file"

    # Pattern 6 / D-08 / D-09: post-condition re-read -- only claim a section
    # was removed after confirming it is genuinely absent from the REWRITTEN
    # file, not merely trusting awk's exit code (Pitfall 1: CRLF/double-space/
    # quoted-name headers previously caused a false "removed" claim while the
    # section silently survived).
    local -a still_present=()
    if [[ -f "$config_file" ]]; then
        local present_name
        while IFS= read -r present_name; do
            still_present+=("$present_name")
        done < <(awk -v MODE="extract" -f "$awk_prog" "$config_file")
    fi
    rm -f "$awk_prog"

    local -a actually_removed=()
    local tgt kept found
    for tgt in "${profiles_to_remove[@]}"; do
        found="false"
        for kept in "${still_present[@]}"; do
            [[ "$kept" == "$tgt" ]] && { found="true"; break; }
        done
        [[ "$found" == "false" ]] && actually_removed+=("$tgt")
    done

    # CSG_RENAME_NOTICE: set ONLY around do_migrate's rename deletion. There the
    # section is not lost -- it moved to `csg-<old>` -- so "섹션 N개 삭제됨" reads
    # as data loss to an engineer scanning the transcript (23-10 checkpoint
    # finding 2). do_migrate prints its own `[migrate] 개명:` line instead, and
    # the single `[migrate] backup=` line carries the one recovery path for the
    # whole run. Sweep/cleanup deletions are genuine removals and keep the
    # PROF-14 notice untouched.
    if [[ ${#actually_removed[@]} -gt 0 && "${CSG_RENAME_NOTICE:-}" != "1" ]]; then
        local names_csv
        names_csv=$(printf '%s' "${actually_removed[0]}")
        local i
        for (( i=1; i<${#actually_removed[@]}; i++ )); do
            names_csv="${names_csv}, ${actually_removed[$i]}"
        done
        printf '[guard] 섹션 %d개 삭제됨: %s\n' "${#actually_removed[@]}" "$names_csv" >&2
        printf '[guard] 복구하려면: cp %q %q\n' "$backup_file" "$config_file" >&2
    fi
    # D-08: nothing actually removed -> stay silent about .bak. The
    # unconditional backup at $backup_file still exists either way; only the
    # stderr NOTICE is conditional on a genuine deletion having happened.

    return 0
}

# --- Profile sweep and cleanup functions ---

# collect_csg_profiles <config_file> <mode> <out_profiles_var> <out_cache_paths_var> [<out_contaminated_var>]
# WR-01: Shared config-parsing helper used by sweep, cleanup and doctor.
# Parses ~/.aws/config, identifies CSG profiles, and populates two nameref
# arrays with matching profile names and their cache file paths.
#   mode="expired"  -- only profiles whose cache file EXISTS and is expired;
#                      missing cache = never-used = protected (not swept)
#   mode="all"      -- all CSG profiles regardless of cache state (--all flag)
#
# PROF-13: the OPTIONAL 5th nameref collects the names of CONTAMINATED HYBRID
# sections -- which never appear in _out_profiles, because is_csg_profile
# (sweep/cleanup eligibility) rejects any section carrying a foreign key. do_doctor
# needs exactly that rejected set, and this is how it gets it WITHOUT a third INI
# parser in this file. When the caller omits the argument the nameref binds to a
# function-local throwaway, so every pre-existing 4-arg call site is unchanged.
collect_csg_profiles() {
    local config_file="$1"
    local mode="$2"
    local -n _out_profiles="$3"
    local -n _out_cache_paths="$4"
    local -a _contaminated_sink=()
    local -n _out_contaminated="${5:-_contaminated_sink}"

    [[ -f "$config_file" ]] || return 0

    local now
    now=$(date -u +%s)

    local current_profile=""
    local current_cp=""
    local current_foreign="false"
    # PROF-08: presence of the `csg_managed` key in the current section. Boolean
    # only -- the key's VALUE is deliberately never read here.
    local current_marker="false"

    # _process_profile: evaluate the previous profile and append to output arrays
    _process_profile() {
        # WR-03: a marker-only section (csg_managed present, credential_process
        # absent) MUST stay visible here. The 22-01 rationale that called this
        # shape unreachable was wrong, and 22-REVIEW corrected it: register writes
        # the marker FIRST, so an abort between key 1 and key 4 leaves exactly this
        # section behind, and the Phase 23 migration's class-D marker backfill
        # produces it deliberately. If the old `&& -n "$current_cp"` guard stayed,
        # such an orphan would be invisible to `cleanup --all` forever -- making
        # the documented "removes every CSG profile" claim false.
        [[ -n "$current_profile" ]] || return 0
        [[ -n "$current_cp" || "$current_marker" == "true" ]] || return 0

        # D-04/D-05/D-07: report (once) a section that WOULD have been
        # sweep/cleanup-eligible under the pre-Phase-21 2-arg predicate but
        # carries a foreign key -- a poisoned hybrid.
        if is_contaminated_hybrid "$current_cp" "$current_profile" "$current_foreign" "$current_marker"; then
            record_and_warn_skip "$current_profile"
            # PROF-13: hand the name to the optional 5th out-param. This is the
            # ONLY place the contaminated set is computed -- do_doctor consumes
            # it rather than re-walking the file.
            _out_contaminated+=("$current_profile")
        fi

        is_csg_profile "$current_cp" "$current_profile" "$current_foreign" "$current_marker" || return 0

        if [[ "$mode" == "all" ]]; then
            _out_profiles+=("$current_profile")
            local cache_path
            cache_path=$(extract_cache_path "$current_cp" 2>/dev/null) || true
            # WR-01: always append (even "") so _out_profiles/_out_cache_paths stay
            # index-aligned 1:1 -- callers correlate cache-file deletion back to the
            # profile name by index (to skip pipe-rejected names, see
            # sweep_expired_profiles / do_cleanup), which requires this pairing.
            _out_cache_paths+=("$cache_path")
        else
            # mode="expired": only include if cache file EXISTS and is expired;
            # missing cache = never-used = protected.
            # T-oro-01: the caller-side `[[ -f "$cache_path" ]]` guard short-circuits
            # before is_cache_expired, so a profile that has never written a cache
            # file is NEVER swept. This protects ALL never-used profiles (e.g. a
            # batch of freshly-created profiles), complementing PROF-06 which only
            # protects the single currently-invoked profile. is_cache_expired itself
            # is unchanged — the guard lives here at the caller, never inside it.
            local cache_path
            if cache_path=$(extract_cache_path "$current_cp") \
               && [[ -f "$cache_path" ]] \
               && is_cache_expired "$cache_path" "$now"; then
                _out_profiles+=("$current_profile")
                _out_cache_paths+=("$cache_path")
            fi
        fi
    }

    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" =~ ^\[ ]]; then
            # PROF-07 success criterion 4: reset state on ANY bracketed header,
            # not only [profile ...]/[default] -- otherwise a following
            # [sso-session ...]/[services ...]/etc. block's key lines leak
            # into the preceding profile section.
            _process_profile
            current_profile=""
            current_cp=""
            current_foreign="false"
            current_marker="false"

            local header="${line%$'\r'}"
            if [[ "$header" =~ ^\[profile[[:space:]]+([^]]+)\][[:space:]]*$ ]]; then
                current_profile="${BASH_REMATCH[1]}"
                current_profile="${current_profile%\'}"; current_profile="${current_profile#\'}"
                current_profile="${current_profile%\"}"; current_profile="${current_profile#\"}"
            elif [[ "$header" == "[default]" ]]; then
                current_profile="default"
            fi
            # else: non-profile header ([sso-session ...]/[services ...]/
            # [plugins] etc.) -- current_profile stays "" so its key lines
            # below are parsed but never attributed to any profile.
            continue
        fi

        [[ -n "$current_profile" ]] || continue

        # Parse credential_process field
        local trimmed="${line#"${line%%[![:space:]]*}"}"
        case "$trimmed" in
            credential_process*=*)
                current_cp="${trimmed#*=}"
                current_cp="${current_cp# }"
                ;;
        esac

        # Foreign-key detection: case-fold the trimmed key (part before '=')
        # and check against FOREIGN_KEY_PREFIXES (prefix-family match).
        local key="${trimmed%%=*}"
        key="${key%"${key##*[![:space:]]}"}"
        key="${key,,}"
        if is_foreign_key "$key"; then
            current_foreign="true"
        fi

        # PROF-08: ownership marker detection -- presence only. The value after
        # '=' (CSG_MANAGED_VERSION at write time) is intentionally NOT read or
        # compared, so a profile stamped by a newer/older client version is
        # still recognized as CSG-owned.
        if [[ "$key" == "csg_managed" ]]; then
            current_marker="true"
        fi
    done < "$config_file"

    # Process last profile (don't forget!)
    _process_profile

    unset -f _process_profile
}

# acquire_sweep_lock <lock_file>
# Non-blocking. Returns 0 when this process now holds the lock, 1 when a live
# holder has it (the caller then returns silently -- every operation behind this
# lock is idempotent and the next invocation picks the work up).
#
# WR-09: THE LOCK IS A FILE, IN BOTH CLIENTS. It used to be a DIRECTORY here and
# a FILE at the identical path in the PowerShell twin, which meant that on any
# machine where both can run (Windows with WSL/Git-Bash, or a mixed install)
# residue from one PERMANENTLY disabled the other:
#   - a lock FILE left by a killed pwsh run made this function's `mkdir` fail
#     forever; with no ${lock}/pid to inspect it took the else branch and
#     returned "skip", so sweep AND migrate became silent no-ops for good;
#   - a lock DIRECTORY left by a killed bash run made [IO.File]::Open throw
#     forever, so Lock-Sweep always returned $false -- same outcome.
#
# `set -o noclobber` + `>` is O_CREAT|O_EXCL, i.e. exactly as atomic as the mkdir
# it replaces, and it produces the same filesystem object the PowerShell twin
# creates, so the two exclude each other instead of bricking each other.
#
# A leftover DIRECTORY at the path is treated as recoverable residue from a
# pre-Phase-23 client rather than as a permanent wall.
acquire_sweep_lock() {
    local lock_file="$1"

    # Legacy directory-shaped lock. Honour its pid file if the holder is still
    # alive (an old client may genuinely be running), otherwise clear it.
    if [[ -d "$lock_file" ]]; then
        local legacy_pid=""
        if [[ -f "${lock_file}/pid" ]]; then
            legacy_pid=$(cat "${lock_file}/pid" 2>/dev/null) || legacy_pid=""
        fi
        legacy_pid="${legacy_pid//[^0-9]/}"
        if [[ -n "$legacy_pid" ]] && kill -0 "$legacy_pid" 2>/dev/null; then
            return 1
        fi
        rm -rf "$lock_file" 2>/dev/null || true
    fi

    local attempt holder
    for attempt in 1 2; do
        if ( set -o noclobber; printf '%s' "$$" > "$lock_file" ) 2>/dev/null; then
            return 0
        fi

        holder=$(cat "$lock_file" 2>/dev/null) || holder=""
        holder="${holder//[^0-9]/}"

        if [[ -n "$holder" ]]; then
            # A LIVE pid is the only thing that counts as "held". Deleting a live
            # holder's lock is the dangerous direction (23-07: the contender then
            # acquires a second lock on a fresh inode and the lock excludes
            # nobody), so this branch is deliberately conservative.
            kill -0 "$holder" 2>/dev/null && return 1
        else
            # No pid recorded. The PowerShell twin creates the file and writes
            # its pid as two steps, so an EMPTY file can legitimately mean "a
            # live pwsh holder, caught mid-acquire". Treat it as held unless it
            # is old enough that no acquire could still be in flight -- otherwise
            # an orphaned empty file would brick the lock forever, which is the
            # very failure this function exists to prevent.
            [[ -n "$(find "$lock_file" -maxdepth 0 -mmin +1 2>/dev/null)" ]] || return 1
        fi

        rm -f "$lock_file" 2>/dev/null || true
    done
    return 1
}

# release_sweep_lock <lock_file>
# Both shapes are cleared: a client that upgraded mid-run may have taken the
# legacy directory form.
release_sweep_lock() {
    local lock_file="$1"
    rm -f "$lock_file" 2>/dev/null || true
    rm -rf "$lock_file" 2>/dev/null || true
}

# sweep_expired_profiles [exclude_cache_path]
# Called on every normal invocation (D-01). Scans ALL CSG profiles in
# ~/.aws/config, removes those whose cache file is expired or missing.
# Logs only when profiles are actually removed (D-03).
# CR-02/WR-09: Uses a non-blocking O_EXCL FILE lock (acquire_sweep_lock) to
# prevent concurrent config rewrites. Portable to macOS without flock, and the
# SAME filesystem object the PowerShell client locks.
#
# PROF-06: If exclude_cache_path is supplied, the profile owning that
# cache file is excluded from sweep. This protects the *currently invoked*
# profile from removing itself before its first broker call has had a chance
# to write its own cache (D-02 would otherwise classify it as expired and
# the same invocation would delete its own [profile X] section).
sweep_expired_profiles() {
    local exclude_cache="${1:-}"
    local config_file="${HOME}/.aws/config"
    [[ -f "$config_file" ]] || return 0

    # CR-02/WR-09: non-blocking O_EXCL FILE lock. If a live process holds it,
    # skip sweep silently.
    local lock_file="${CACHE_DIR}/.sweep.lock"
    acquire_sweep_lock "$lock_file" || return 0
    # Ensure lock is released on function exit (normal or error)
    trap 'release_sweep_lock "$lock_file"' RETURN

    local -a expired_profiles=()
    local -a expired_cache_files=()

    collect_csg_profiles "$config_file" "expired" expired_profiles expired_cache_files

    # PROF-06: Drop the currently-invoked profile from the sweep set so a
    # freshly-registered profile is not removed by its own first invocation.
    if [[ -n "$exclude_cache" && ${#expired_profiles[@]} -gt 0 ]]; then
        local -a kept_profiles=()
        local -a kept_cache_files=()
        local idx
        for (( idx=0; idx<${#expired_profiles[@]}; idx++ )); do
            if [[ "${expired_cache_files[$idx]}" != "$exclude_cache" ]]; then
                kept_profiles+=("${expired_profiles[$idx]}")
                kept_cache_files+=("${expired_cache_files[$idx]}")
            fi
        done
        expired_profiles=("${kept_profiles[@]}")
        expired_cache_files=("${kept_cache_files[@]}")
    fi

    # D-03: No output when nothing removed
    [[ ${#expired_profiles[@]} -eq 0 ]] && return 0

    # Remove expired profiles from config
    rewrite_config_removing_profiles "$config_file" "${expired_profiles[@]}"

    # D-09/WR-01: Delete corresponding cache files -- but ONLY for profiles NOT
    # rejected by rewrite_config_removing_profiles's pipe-in-name defense (CR-01).
    # A rejected name's config section survives; wiping its cache anyway would
    # orphan it in a neither-swept-nor-cached state, forcing a broker round-trip
    # on every future invocation until an operator manually intervenes.
    local cf idx
    for (( idx=0; idx<${#expired_profiles[@]}; idx++ )); do
        [[ "${expired_profiles[$idx]}" == *"|"* ]] && continue
        cf="${expired_cache_files[$idx]:-}"
        [[ -n "$cf" ]] && rm -f "$cf"
    done

    # D-03: Log with [sweep] prefix
    local names_csv
    names_csv=$(printf '%s' "${expired_profiles[0]}")
    local i
    for (( i=1; i<${#expired_profiles[@]}; i++ )); do
        names_csv="${names_csv}, ${expired_profiles[$i]}"
    done
    printf '[sweep] removed %d expired profiles: %s\n' "${#expired_profiles[@]}" "$names_csv" >&2
}

# do_cleanup <all_mode>
# Handles "cleanup" (expired only, D-07) and "cleanup --all" (all CSG, D-08).
# $1: "true" for --all mode, "false" for expired-only mode.
do_cleanup() {
    local all_mode="${1:-false}"
    local config_file="${HOME}/.aws/config"

    if [[ ! -f "$config_file" ]]; then
        printf '[cleanup] ~/.aws/config not found\n' >&2
        exit 0
    fi

    local mode="expired"
    [[ "$all_mode" == "true" ]] && mode="all"

    local -a target_profiles=()
    local -a target_cache_files=()

    collect_csg_profiles "$config_file" "$mode" target_profiles target_cache_files

    # Report results
    if [[ ${#target_profiles[@]} -eq 0 ]]; then
        if [[ "$all_mode" == "true" ]]; then
            printf '[cleanup] No CSG profiles found\n' >&2
        else
            printf '[cleanup] No expired CSG profiles found\n' >&2
        fi
        exit 0
    fi

    # Remove profiles from config
    rewrite_config_removing_profiles "$config_file" "${target_profiles[@]}"

    # D-09/WR-01: Delete cache files -- skip any profile name containing '|'
    # (rejected by rewrite_config_removing_profiles's CR-01 pipe-injection
    # defense; its config section survives, so its cache must not be wiped
    # either -- see sweep_expired_profiles for the same guard).
    local cf idx
    for (( idx=0; idx<${#target_profiles[@]}; idx++ )); do
        [[ "${target_profiles[$idx]}" == *"|"* ]] && continue
        cf="${target_cache_files[$idx]:-}"
        [[ -n "$cf" ]] && rm -f "$cf"
    done

    # D-08/D-09: For --all mode, also delete any orphan cache files. This purges
    # BOTH the current <account-id>.json scheme AND any legacy <account-id>-<role>.json
    # files orphaned by the Phase 18 cache-key collapse, so upgraded machines shed
    # the old scheme.
    if [[ "$all_mode" == "true" ]]; then
        rm -f "${CACHE_DIR}"/*.json 2>/dev/null || true
    fi

    # Summary report
    local names_csv
    names_csv=$(printf '%s' "${target_profiles[0]}")
    local i
    for (( i=1; i<${#target_profiles[@]}; i++ )); do
        names_csv="${names_csv}, ${target_profiles[$i]}"
    done

    if [[ "$all_mode" == "true" ]]; then
        printf '[cleanup] Removed %d CSG profiles: %s\n' "${#target_profiles[@]}" "$names_csv" >&2
    else
        printf '[cleanup] Removed %d expired profiles: %s\n' "${#target_profiles[@]}" "$names_csv" >&2
    fi
    exit 0
}

# --- Subcommand routing (must be before --flag parsing) ---
if [[ "${1:-}" == "cleanup" ]]; then
    shift
    cleanup_all="false"
    if [[ "${1:-}" == "--all" ]]; then
        cleanup_all="true"
    fi
    require_cmds
    mkdir -p "$CACHE_DIR"
    chmod 700 "$CACHE_DIR" 2>/dev/null || true
    do_cleanup "$cleanup_all"
    exit $?
fi

# --- register subcommand helpers (PROF-08/10/11) ---
#
# PLACEMENT IS LOAD-BEARING. test/credentials-guard.test.sh extracts everything
# between the literal comments "# --- Profile cleanup helpers ---" and
# "# --- Subcommand routing" and `source`s it in a subshell to unit-test the
# predicates. Everything below this line is deliberately OUTSIDE that range:
# register's helpers must not leak into that harness, and neither marker comment
# may be reworded.
#
# STDOUT CONTRACT (register mode) -- distinct from the credential_process 5-key
# JSON contract declared in the file header:
#   success -> exactly ONE line on stdout: the profile name. Nothing else.
#   abort   -> stdout stays completely EMPTY; every diagnostic goes to stderr.
# Every stderr line is prefixed "[register] " (same convention as [sweep]/
# [cleanup]/[guard]) and every abort emits a machine-readable
# "[register] reason=<token>" line first.

# Classification results, set by classify_existing_profile / profile_foreign_probe.
# Globals rather than stdout because these code paths can abort: an `exit` inside
# a command substitution only kills the subshell, which would silently fail OPEN.
REGISTER_PROFILE_NAME=""
REGISTER_CLASS=""
REGISTER_BLOCKING_KEY=""
REGISTER_BLOCKING_SOURCE=""
REGISTER_EXISTING_ACCOUNT=""

register_log() {
    printf '[register] %s\n' "$*" >&2
}

# register_reason <token>
# Emits the machine-readable abort token. ALWAYS the first line of an abort, so a
# caller (or a test) can grep it without parsing the Korean prose that follows.
# Tokens: config-unparseable | account-mismatch | contaminated-hybrid |
#         foreign-profile | unknown-profile | reserved-profile-name |
#         invalid-account-name | invalid-account-id | invalid-arguments |
#         missing-dependency | write-failed | postcondition-failed
register_reason() {
    printf '[register] reason=%s\n' "$1" >&2
}

# register_die <reason_token> <msg>...
# Emits the machine-readable reason line, then one "[register] <msg>" line per
# argument, then exits 1. NEVER writes to stdout (abort contract: empty stdout).
# Multi-paragraph aborts that need a helper's output in the middle call
# register_reason themselves and end with `exit 1`.
register_die() {
    local reason="$1"
    shift
    register_reason "$reason"
    local msg
    for msg in "$@"; do
        printf '[register] %s\n' "$msg" >&2
    done
    exit 1
}

# normalize_name_token <raw>
# D-03: THE single owner of the profile-name rule for the whole project. Ported
# from the (now deleted) SKILL.md:136 pipeline: lowercase -> every character
# outside [a-z0-9-] becomes '-' -> collapse runs of '-' -> strip leading and
# trailing '-'.
# This function stays PREFIX-FREE. Phase 23 landed the `csg-` namespace in
# derive_profile_name, not here, because suggest_alternative_name also calls
# this normalizer and already emits its own `csg-` literal -- prefixing here
# would double-prefix every suggested name.
normalize_name_token() {
    local raw="$1"
    printf '%s' "$raw" \
        | tr -d '\r\n' \
        | tr '[:upper:]' '[:lower:]' \
        | sed -e 's/[^a-z0-9-]/-/g' -e 's/--*/-/g' -e 's/^-//' -e 's/-$//'
}

# derive_profile_name <account_name>
# Sets REGISTER_PROFILE_NAME to `csg-<token>` (PROF-09 / D-08: every name this
# project mints lives in the `csg-` namespace). Aborts (register_die) when the
# account name cannot be normalized into a legal profile name.
# T-22-04: the assertion blocks two things at once -- an empty or all-hyphen
# token would emit a syntax-breaking "[profile -]" INI header, and a leading '-'
# would be parsed as a flag by the very `aws` call that writes it. It is applied
# to the PRE-PREFIX token on purpose: checking the final `csg-<token>` instead
# would re-open exactly that hazard, because the bare string `csg-` satisfies
# "starts with [a-z0-9]" and would sail through as `[profile csg-]` (T-23-04).
#
# IDEMPOTENCY (D-08, 22-03 Decision #2): a single leading `csg-` is stripped
# before the prefix is re-applied. This is not cosmetic. register_suggest_retry
# prints a retry command whose --account-name is suggest_alternative_name's
# output, which ALREADY carries a `csg-` literal, and tells the engineer to run
# it verbatim. Without the strip that command would mint `csg-csg-<name>` -- the
# printed command would not produce the printed name.
#
# Result is returned via a GLOBAL, not stdout, so the abort is not swallowed by a
# command-substitution subshell.
# sanitize_for_display <raw>
# T-22-05: register_suggest_retry echoes only normalized [a-z0-9-] tokens, but two
# abort paths interpolate RAW input -- the BILLING `accountName` (which SKILL.md
# tells the agent to pass 원문 그대로, i.e. an external API response reaching a
# terminal unfiltered) and an unrecognised argv element. Control sequences there
# can rewrite the terminal title, erase previously printed lines, or recolour an
# abort so it reads as a success -- and this output is what the agent relays to
# the user and what lands in CI logs.
# ALL C0 controls are removed, not just ESC: CR alone can overwrite a line and LF
# would let raw input forge additional "[register] ..." lines. DEL is dropped for
# the same reason. Output is capped so a megabyte-long value cannot flood stderr.
# WR-07: C0 and DEL are NOT the whole hazard set, and the PowerShell twin has
# always stripped more than this one did. Profile names come from a file this
# script does not own and are echoed into the migrate mapping table and the
# doctor report -- the exact surfaces T-22-05/T-23-17 exist to protect:
#   - C1 (U+0080-U+009F) contains CSI at U+009B. On an 8-bit-clean terminal that
#     is a control-sequence introducer, i.e. everything ESC[ can do.
#   - Cf (format characters) contains RLO U+202E, which visually REVERSES a
#     printed name, so the mapping table can read as a different rename than the
#     one performed -- without a single control byte.
# \p{Cc} + \p{Cf} is exactly what ConvertTo-DisplaySafe uses, so the two
# sanitizers now strip the same set (pinned by PARITY-SANITIZE).
#
# The 120-cap is applied INSIDE perl, on CHARACTERS. `cut -c1-120` under LC_ALL=C
# counts BYTES, so a Korean profile name was cut mid-codepoint and emitted
# invalid UTF-8; the PS twin has always used Substring, i.e. characters.
#
# perl -CSD forces UTF-8 I/O layers regardless of locale, so no LC_ALL that
# macOS lacks (C.UTF-8) is needed. The fallback keeps the previous C0/DEL-only
# behaviour rather than dropping the guard entirely: it is strictly no worse
# than what shipped, and `perl` is present on macOS, every mainstream Linux and
# Git-Bash.
sanitize_for_display() {
    local out
    if command -v perl >/dev/null 2>&1 \
       && out=$(printf '%s' "$1" | perl -CSD -pe 's/[\p{Cc}\p{Cf}]//g; $_ = substr($_, 0, 120);' 2>/dev/null); then
        printf '%s' "$out"
        return 0
    fi
    printf '%s' "$1" | LC_ALL=C tr -d '\000-\037\177' | cut -c1-120
}

# is_skip_profile <section_name>
# Returns 0 when <section_name> is one of the infrastructure sections this tool
# must never operate on (SKIP_PROFILES).
#
# CR-03: is_contaminated_hybrid is deliberately BLIND to SKIP_PROFILES so the
# REPORTING predicate can flag contamination in [default] and the other infra
# sections -- that rationale is sound. The defect was that do_doctor step (3) and
# do_migrate pass 1 fed that same unfiltered list straight into
# remove_keys_from_profile as their ACTION list, with no filter anywhere in
# between. `csg-login` is the login anchor every customer session is brokered
# through (install.sh calls deleting it "break login fleet-wide"), and `doctor`
# would strip its credential_process and exit 0.
#
# The filter therefore lives at the ACTION site, not in the predicate: report
# everything, cut nothing that is reserved.
is_skip_profile() {
    local candidate="$1" sp
    for sp in "${SKIP_PROFILES[@]}"; do
        [[ "$candidate" == "$sp" ]] && return 0
    done
    return 1
}

derive_profile_name() {
    local raw="$1"
    local name
    name=$(normalize_name_token "$raw")
    name="${name#csg-}"

    if [[ ! "$name" =~ ^[a-z0-9][a-z0-9-]{0,63}$ ]]; then
        register_die "invalid-account-name" \
            "중단: --account-name 을 프로필 이름으로 정규화할 수 없습니다." \
            "입력: '$(sanitize_for_display "$raw")' / 정규화 결과: '${name}'" \
            "프로필 이름은 ^[a-z0-9][a-z0-9-]{0,63}\$ 를 만족해야 합니다 (영소문자 또는 숫자로 시작)." \
            "영숫자를 포함한 계정명으로 다시 시도하세요. ~/.aws/config 는 변경되지 않았습니다."
    fi

    REGISTER_PROFILE_NAME="csg-${name}"
}

# suggest_alternative_name <corp_name> <account_name>
# Prints the D-04 alternative name on stdout. rc 0 when --corp-name contributed a
# usable token, rc 1 when it did not (so the caller can add "회사명을 주면 더
# 구체적인 이름을 제안할 수 있습니다"). Never emits a doubled hyphen: the
# emptiness test is on the NORMALIZED corp token, not the raw argument.
suggest_alternative_name() {
    local corp_raw="$1"
    local account_raw="$2"
    local corp_token account_token

    corp_token=$(normalize_name_token "$corp_raw")
    account_token=$(normalize_name_token "$account_raw")

    if [[ -n "$corp_token" ]]; then
        printf 'csg-%s-%s' "$corp_token" "$account_token"
        return 0
    fi
    printf 'csg-%s' "$account_token"
    return 1
}

# abort_config_unparseable <exit_code>
# D-07 / PROF-10 criterion 3. A non-zero `aws configure list-profiles` is NEVER
# read as "no profiles exist" -- it means the config is unreadable, so collision
# detection is impossible and the only safe action is to stop before writing.
# S2: mirrors the PROF-14 recovery-notice format (%q keeps paths with spaces
# pasteable). register creates NO backup of its own -- it never rewrites the file
# -- it only lists backups other code paths left behind.
# D-07 explicitly rejects auto-diagnosis: these are CANDIDATES, never a verdict.
# WR-05: <caller> is "enumeration" (list-profiles itself failed -- the config
# really is unreadable) or "classification" (a per-key `aws configure get` returned
# 255 AFTER list-profiles already reported the name). aws-cli 2.35.20 returns 255
# for BOTH an unparseable config AND a profile that does not exist, so on the
# classification branch the far likelier cause is that the profile VANISHED
# between enumeration and classification -- a TOCTOU race with a concurrent
# cleanup/sweep or another agent's register. Printing the BOM / duplicate-header
# cause list there is a misdiagnosis, and offering `cp <backup> ~/.aws/config`
# would undo unrelated work to "fix" a file that is perfectly fine.
#
# list_recent_backups_note -- the ONE ordering rule shared by the three
# *_abort_unparseable functions (here, doctor:~2131, migrate:~2355) and by their
# PowerShell twins. Cited by line number nowhere; grep for this anchor name.
#
#   NEVER order these by mtime. Order by NAME.
#
# Every backup this tool writes is `<config>.bak.$(date +%Y%m%d%H%M%S)` (:432,
# :1801, :2415 via CSG_BACKUP_SESSION) -- fixed-width, zero-padded, so the NAME
# already is a total chronological key and `sort -r` is exactly "newest first"
# with zero dependence on the filesystem clock. The old form was
# `ls -t ... | head -3`, inherited as a house idiom from the v1.4 backup-prune
# snippet and copied verbatim into all three sites. It was wrong on Linux:
#   - Linux stamps files from a COARSE kernel clock (~1 jiffy), so two backups
#     written back-to-back in one run (sweep + migrate) get mtimes that are
#     identical DOWN TO THE NANOSECOND -- not merely to the second.
#   - On that tie GNU *and* BSD `ls -t` both fall back to name ASCENDING, so
#     `head` hands back the OLDEST backup.
#   - macOS only ever passed by luck: APFS advances the nanosecond field between
#     the two writes, so the tie never forms. The tie-break itself is identical.
# An engineer who ran the offered `cp` restored a STALE config -- the exact
# inverse of what D-10/A9 exists to provide.
#
# Three guards make the name ordering sound; none is optional:
#   `-d`             : without it a directory named `config.bak.<x>` would be
#                      listed by its CONTENTS (bare basenames), and the recovery
#                      line would name a path that is not the backup.
#   `grep [0-9]{14}` : the ordering argument holds ONLY for the timestamp shape.
#                      Without this filter a hand-made `config.bak.orig` sorts
#                      above every real backup ('o' > '2') and would ALWAYS be
#                      offered -- trading one wrong-file bug for another. Files
#                      this tool did not write are not backups it can vouch for,
#                      so they degrade to "백업 파일이 없습니다" (fail-closed,
#                      same spirit as WR-05). It also means the unmatched-glob
#                      literal cannot leak even if `2>/dev/null` were dropped.
#   `LC_ALL=C`       : pins collation so the answer cannot depend on the
#                      engineer's locale (same reasoning as :1072).
#   `-f` in the loop : parity with the PowerShell twin's `-File`. Note the
#                      filter runs AFTER `head -3`, so three directories with
#                      backup-shaped names could crowd out a real backup. That
#                      is contrived, and it degrades to "no backups" -- the
#                      fail-closed direction -- so it is not worth restructuring
#                      the pipeline to avoid.
# `|| true` stays load-bearing under `set -euo pipefail`: `head` closing the pipe
# early SIGPIPEs `sort`, and pipefail would surface that as 141.
abort_config_unparseable() {
    local rc="$1"
    local caller="${2:-enumeration}"
    local config_file="${HOME}/.aws/config"

    register_reason "config-unparseable"
    register_log "중단: ~/.aws/config 를 읽을 수 없습니다 (aws configure list-profiles exit=${rc})."
    register_log "이 상태에서는 기존 프로필을 볼 수 없으므로 '충돌 없음'으로 간주하지 않고 중단합니다."
    register_log "흔한 원인:"
    register_log "  - 파일 맨 앞의 UTF-8 BOM (에디터가 붙였을 수 있음)"
    register_log "  - 같은 [profile X] 섹션 헤더가 두 번 존재"
    register_log "  - 닫는 ']' 가 빠진 헤더"
    if [[ "$caller" == "classification" ]]; then
        register_log "  - 프로필이 조회 도중 사라졌을 수 있습니다 (동시 실행 중인 cleanup/sweep 또는 다른 register)"
        register_log "이 경우 설정 파일 자체는 멀쩡합니다. 백업을 되돌리면 무관한 작업까지 되돌아가므로,"
        register_log "복구 명령 대신 같은 명령을 그대로 다시 실행하세요."
    fi

    # Ordered by NAME, never by mtime -- see list_recent_backups_note below.
    local -a backups=()
    local b
    while IFS= read -r b; do
        # -f, not -n: the PowerShell twin filters with -File, and a directory
        # named like a backup must never reach the `cp`. `if`, not `[[ ]] &&`:
        # a false AND-list is the last command in the loop body and would trip
        # `set -e` -- an abort inside the abort path.
        if [[ -f "$b" ]]; then backups+=("$b"); fi
    done < <(ls -1d "${config_file}".bak.* 2>/dev/null | LC_ALL=C grep -E '\.bak\.[0-9]{14}$' | LC_ALL=C sort -r | head -3 || true)

    if [[ ${#backups[@]} -eq 0 ]]; then
        register_log "최근 백업: 백업 파일이 없습니다"
    else
        register_log "최근 백업:"
        for b in "${backups[@]}"; do
            register_log "  ${b}"
        done
        # The runnable recovery command is offered ONLY when the config really is
        # the suspect. On the classification branch it would restore a healthy
        # file over unrelated work (WR-05).
        if [[ "$caller" != "classification" ]]; then
            printf '[register] 복구하려면: cp %q %q\n' "${backups[0]}" "$config_file" >&2
        fi
    fi

    register_log "아무것도 기록하지 않았습니다 — ~/.aws/config 는 변경되지 않았습니다."
    exit 1
}

# section_has_foreign_key <config_file> <profile_name>
# Walks ONLY the [profile <name>] section of <config_file> and prints the first
# key matching is_foreign_key, rc 0. rc 1 when the section is clean or absent.
# S5: deliberately NOT collect_csg_profiles -- that whole-file walker appends to
# guard-skips.jsonl and prints [guard] lines, which would fabricate guard
# warnings and mutate a Phase 21 audit file during a registration.
# T-22-05: prints the key NAME only. Key VALUES are never emitted (an SSO section
# carries an internal start URL).
section_has_foreign_key() {
    local config_file="$1"
    local target="$2"

    [[ -f "$config_file" ]] || return 1

    local in_section="false"
    local line trimmed name key
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%$'\r'}"
        trimmed="${line#"${line%%[![:space:]]*}"}"

        # Section boundary. Independent logic (not shared with the collector's
        # loop) but the same "^\[ resets state" rule.
        if [[ "$trimmed" == \[* ]]; then
            name="${trimmed#\[}"
            name="${name%%]*}"
            name="${name#profile }"
            name="${name#"${name%%[![:space:]]*}"}"
            name="${name%"${name##*[![:space:]]}"}"
            # WR-08: strip surrounding quotes, exactly as collect_csg_profiles
            # does (Pattern 4 exists because a quoted header once produced a
            # false "removed" claim). Without this, a `[profile "acme"]` section
            # is never entered, the config half of profile_foreign_probe reports
            # "clean", and the foreign-key veto silently degrades to the
            # aws_access_key_id-only probe.
            name="${name%\'}"; name="${name#\'}"
            name="${name%\"}"; name="${name#\"}"
            if [[ "$name" == "$target" ]]; then
                in_section="true"
            else
                in_section="false"
            fi
            continue
        fi

        [[ "$in_section" == "true" ]] || continue
        [[ "$trimmed" == \#* || "$trimmed" == \;* ]] && continue
        [[ "$trimmed" == *=* ]] || continue

        key="${trimmed%%=*}"
        key="${key%"${key##*[![:space:]]}"}"
        key="${key,,}"
        if is_foreign_key "$key"; then
            printf '%s' "$key"
            return 0
        fi
    done < "$config_file"

    return 1
}

# aws_configure_get <key> <profile>
# Prints the value on stdout and returns aws's own exit code so the caller can
# branch three ways: 0 = present, 1 = absent, 255 = config unparseable (or the
# profile vanished). Verified against aws-cli 2.35.20.
# S4/T-22-03: the set +e / rc=$? / set -e fence is MANDATORY under `set -euo
# pipefail` (:30). Without it a 255 kills the script before the `rc=` line is
# reached and the D-07 message is never printed -- fail-closed in appearance,
# merely dead in fact. Callers must fence their own command substitution too.
# NEVER use the dotted `profile.<name>.<key>` form: it is a verified
# false-negative for names containing '.'.
# WR-02: the fence SAVES AND RESTORES the caller's errexit rather than ending in
# an unconditional `set -e`. Shell options are global, not function-scoped, so an
# unconditional `set -e` here re-enables errexit BEFORE this function returns
# non-zero -- which voids the caller's own `set +e` fence and kills the script at
# the call site with no diagnostic. That was invisible only because every call
# site but one wrapped this in a command substitution (a subshell, which contains
# the damage) and the exception sat inside an `if` condition, where bash
# suppresses errexit transitively. The next direct call site would have died.
aws_configure_get() {
    local key="$1"
    local profile="$2"
    local out rc had_e="false"

    [[ $- == *e* ]] && had_e="true"
    set +e
    out=$(aws configure get "$key" --profile "$profile" 2>/dev/null)
    rc=$?
    [[ "$had_e" == "true" ]] && set -e

    printf '%s' "$out"
    return "$rc"
}

# profile_foreign_probe <profile_name>
# Sets REGISTER_BLOCKING_KEY / REGISTER_BLOCKING_SOURCE, rc 0 when the profile
# carries any foreign credential key.
# T-22-02: BOTH halves are required. The config-side INI scan is free and catches
# a credential_process injected into an existing SSO/role section; the
# aws_access_key_id probe reads the MERGED view and is the only way to see the
# ~/.aws/credentials half, which is structurally invisible to any config reader
# and whose static keys silently outrank credential_process.
profile_foreign_probe() {
    local profile_name="$1"
    local config_file="${HOME}/.aws/config"

    REGISTER_BLOCKING_KEY=""
    REGISTER_BLOCKING_SOURCE=""

    local found
    if found=$(section_has_foreign_key "$config_file" "$profile_name"); then
        REGISTER_BLOCKING_KEY="$found"
        REGISTER_BLOCKING_SOURCE="config"
        return 0
    fi

    # WR-02: the ONE call site that used to invoke aws_configure_get directly
    # rather than through a command substitution. Every other site is substituted
    # (a subshell, which contains any option damage the callee does); this one was
    # not, and survived only because both callers of profile_foreign_probe sit
    # inside an `if` condition where bash suppresses errexit transitively. Now
    # that aws_configure_get save/restores errexit the direct form would also be
    # safe, but keeping the shape uniform removes the invisible coupling.
    # The captured value is discarded immediately -- only the exit code matters.
    local rc probe_val
    set +e
    probe_val=$(aws_configure_get "aws_access_key_id" "$profile_name")
    rc=$?
    set -e
    unset probe_val
    if (( rc == 0 )); then
        REGISTER_BLOCKING_KEY="aws_access_key_id"
        REGISTER_BLOCKING_SOURCE="credentials"
        return 0
    fi
    if (( rc != 1 )); then
        abort_config_unparseable "$rc" "classification"
    fi

    return 1
}

# collision_class_label <blocking_key> <source>
# Names the collision CLASS for the abort message (Pattern 5). Key names only.
collision_class_label() {
    local key="$1"
    local source="$2"
    case "$key" in
        sso_*)
            printf 'SSO 프로필' ;;
        role_*|source_profile|credential_source|mfa_serial|external_id|duration_seconds|web_identity_token_file)
            printf 'role-chaining 프로필' ;;
        aws_*)
            if [[ "$source" == "credentials" ]]; then
                printf '~/.aws/credentials 정적 키 프로필'
            else
                printf 'config 내 정적 키 프로필'
            fi
            ;;
        *)
            printf '알 수 없는 기존 섹션' ;;
    esac
}

# classify_existing_profile <profile_name> <requested_account_id>
# RESEARCH Pattern 3. Sets REGISTER_CLASS to one of:
#   owned-same | owned-different | contaminated | foreign | unknown
# plus REGISTER_BLOCKING_KEY / REGISTER_BLOCKING_SOURCE / REGISTER_EXISTING_ACCOUNT.
# Read-only: at most 3 `aws` subprocesses, no writes, no network, no Bearer.
classify_existing_profile() {
    local profile_name="$1"
    local requested_account_id="$2"

    REGISTER_CLASS=""
    REGISTER_BLOCKING_KEY=""
    REGISTER_BLOCKING_SOURCE=""
    REGISTER_EXISTING_ACCOUNT=""

    local has_marker="false"
    local cp_sig="false"
    local marker_value cp_value rc

    # (1) marker probe -- PRESENCE only; the value is never compared (Pitfall 4).
    set +e
    marker_value=$(aws_configure_get "csg_managed" "$profile_name")
    rc=$?
    set -e
    if (( rc == 0 )); then
        has_marker="true"
    elif (( rc != 1 )); then
        abort_config_unparseable "$rc" "classification"
    fi
    unset marker_value

    # (2) legacy credential_process signature.
    cp_value=""
    set +e
    cp_value=$(aws_configure_get "credential_process" "$profile_name")
    rc=$?
    set -e
    if (( rc == 0 )); then
        [[ "$cp_value" == *get-customer-credentials* ]] && cp_sig="true"
    elif (( rc != 1 )); then
        abort_config_unparseable "$rc" "classification"
    else
        cp_value=""
    fi

    # (3) no positive ownership -> foreign or unknown. Probe anyway so the abort
    # message can name the blocking key and the collision class.
    if [[ "$has_marker" != "true" && "$cp_sig" != "true" ]]; then
        if profile_foreign_probe "$profile_name"; then
            REGISTER_CLASS="foreign"
        else
            REGISTER_CLASS="unknown"
        fi
        return 0
    fi

    # (4) CSG-owned, but contaminated? The marker is not a license to write into
    # a section carrying foreign credentials (the Phase 21 veto, D-06).
    if profile_foreign_probe "$profile_name"; then
        REGISTER_CLASS="contaminated"
        return 0
    fi

    # (5) same account or a silent re-pointing (D-09)? A CSG-owned section with
    # no parseable account id (marker-only after a partial write, or a malformed
    # cp) cannot be re-pointing anything, so it converges on the idempotent
    # re-registration row and gets repaired.
    local existing_account=""
    if [[ -n "$cp_value" ]]; then
        existing_account=$(extract_account_id "$cp_value") || existing_account=""
    fi
    REGISTER_EXISTING_ACCOUNT="$existing_account"

    if [[ -n "$existing_account" && "$existing_account" != "$requested_account_id" ]]; then
        REGISTER_CLASS="owned-different"
        return 0
    fi

    REGISTER_CLASS="owned-same"
    return 0
}

# register_suggest_retry <script_abs> <account_id> <corp_name> <account_name>
# Prints the D-04 alternative-name guidance to stderr.
# The retry command passes the suggested name as --account-name because register
# derives the profile name itself (D-03) -- there is no --profile-name flag. This
# is exact, not approximate: the suggestion is already a normalized token, and
# normalize_name_token is idempotent on such a token, so the printed command
# genuinely produces the printed name.
# T-22-05: only normalized [a-z0-9-] strings are echoed, so no attacker-supplied
# ANSI escape can reach the terminal through this path.
register_suggest_retry() {
    local script_abs="$1"
    local account_id="$2"
    local corp_raw="$3"
    local account_raw="$4"
    local alt_name alt_rc

    set +e
    alt_name=$(suggest_alternative_name "$corp_raw" "$account_raw")
    alt_rc=$?
    set -e

    register_log "대체 이름으로 다시 시도하세요 (제안: ${alt_name}):"
    printf '[register]   %s register --account-id %s --account-name "%s"\n' \
        "$script_abs" "$account_id" "$alt_name" >&2
    if (( alt_rc != 0 )); then
        register_log "  (--corp-name \"<회사명>\" 을 함께 주면 더 구체적인 대체명을 제안합니다)"
    fi
}

# do_register <args...>
# PROF-08/10/11. Seven stages: parse -> derive name -> fail-closed enumeration ->
# membership -> classify (decision table) -> write -> read-back -> stdout.
# NO network call, NO Bearer read, NO JSON parsing -- pure ~/.aws/config work.
# T-22-01: every read happens before the first write. Rows 4..7 all abort and
# NOTHING is deleted or merged; on any abort ~/.aws/config is byte-identical.
do_register() {
    local account_id=""
    local account_name=""
    local corp_name=""
    local account_name_given="false"

    # [1] argv. register consumes its own arguments; these flags must never reach
    # the main parser below, whose `*)` branch dies with the misleading
    # "알 수 없는 옵션" (Pitfall 2).
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --account-id|--account-name|--corp-name)
                [[ $# -ge 2 ]] || register_die "invalid-arguments" \
                    "중단: 옵션 '$1' 에 값이 필요합니다."
                ;;&
            --account-id)   account_id="$2"; shift 2 ;;
            --account-name) account_name="$2"; account_name_given="true"; shift 2 ;;
            --corp-name)    corp_name="$2"; shift 2 ;;
            --help|-h)      usage; exit 0 ;;
            *)
                register_die "invalid-arguments" \
                    "중단: register 가 모르는 인자입니다: $(sanitize_for_display "$1")" \
                    "사용법: get-customer-credentials.sh register --account-id <12자리> --account-name \"<계정명>\" [--corp-name \"<회사명>\"]"
                ;;
        esac
    done

    # A6: the same shape the main parser and the broker enforce.
    if [[ ! "$account_id" =~ ^[0-9]{12}$ ]]; then
        register_die "invalid-account-id" \
            "중단: 유효하지 않은 --account-id (12자리 숫자만 허용): '${account_id}'" \
            "~/.aws/config 는 변경되지 않았습니다."
    fi
    if [[ "$account_name_given" != "true" ]]; then
        register_die "invalid-account-name" \
            "중단: --account-name 은 필수입니다." \
            "사용법: get-customer-credentials.sh register --account-id <12자리> --account-name \"<계정명>\" [--corp-name \"<회사명>\"]"
    fi

    # Absolute path of THIS script, resolved from BASH_SOURCE. NEVER from
    # `aws configure get profile.csg-login.credential_process`: when that value is
    # empty, `dirname ""` yields "." and a RELATIVE credential_process gets baked
    # into ~/.aws/config -- the fail-open the milestone is closing.
    local script_dir script_base script_abs
    script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
    script_base=$(basename -- "${BASH_SOURCE[0]}")
    script_abs="${script_dir}/${script_base}"

    # [2] derive the profile name -- D-03, computed here and nowhere else.
    derive_profile_name "$account_name"
    local profile_name="$REGISTER_PROFILE_NAME"

    # [2b] SKIP_PROFILES veto (D-06 applied to the WRITE path, not just cleanup).
    # is_csg_profile refuses to DELETE anything in SKIP_PROFILES; without the
    # mirror-image guard here, register can CREATE one. Two concrete harms:
    #   (a) `--account-name "Default"` normalizes to `default`, and
    #       `aws configure set ... --profile default` special-cases that name into
    #       the [default] section -- every unqualified `aws` command on the machine
    #       silently starts resolving a customer read-only session, which inverts
    #       the audit story the milestone exists to protect;
    #   (b) any other SKIP_PROFILES name mints a section cleanup can NEVER reclaim,
    #       because the cleanup predicate vetoes exactly this list.
    # Runs BEFORE enumeration, so ~/.aws/config is byte-identical on this abort.
    local sp
    for sp in "${SKIP_PROFILES[@]}"; do
        if [[ "$profile_name" == "$sp" ]]; then
            register_reason "reserved-profile-name"
            register_log "중단: '${profile_name}' 은(는) 인프라 예약 프로필명입니다 (SKIP_PROFILES)."
            register_log "충돌 대상: 인프라 예약 이름 (cleanup 이 절대 건드리지 않는 보호 목록)"
            register_log "이 이름으로 등록하면 cleanup 이 영구히 회수할 수 없고, 'default' 의 경우"
            register_log "모든 무지정 AWS CLI 호출이 고객사 세션으로 해석됩니다. 쓰지 않고 중단합니다."
            register_log "~/.aws/config 는 변경되지 않았습니다."
            register_suggest_retry "$script_abs" "$account_id" "$corp_name" "$account_name"
            exit 1
        fi
    done

    # [3] enumeration, fail-closed (decision-table row 1 / D-07 / PROF-10).
    # list-profiles (not a ~/.aws/config scan) is what makes SSO-only and
    # credentials-file-only profiles visible at all.
    local all_profiles rc
    set +e
    all_profiles=$(aws configure list-profiles 2>/dev/null)
    rc=$?
    set -e
    if (( rc != 0 )); then
        abort_config_unparseable "$rc"
    fi
    # V18: rc == 0 with EMPTY output is the legitimate fresh-machine case.
    # "없음" and "못 읽음" are never conflated.

    # [4] whole-line fixed-string membership. A prefix match would make
    # `csg-acme` false-positive against an existing `csg-acme-dev`.
    local exists="false"
    if printf '%s\n' "$all_profiles" | grep -Fxq "$profile_name"; then
        exists="true"
    fi

    # [5] decision-table rows 3..7.
    local action="create"
    local class_label
    if [[ "$exists" == "true" ]]; then
        classify_existing_profile "$profile_name" "$account_id"
        case "$REGISTER_CLASS" in
            owned-same)     # row 3 -- idempotent re-registration (D-08)
                action="reregister"
                ;;
            owned-different)    # row 4 (D-09)
                register_reason "account-mismatch"
                register_log "중단: 프로필 '${profile_name}' 은(는) CSG 소유이지만 다른 고객 계정에 묶여 있습니다."
                register_log "충돌 대상: 다른 계정의 CSG 프로필 (기존 계정ID ${REGISTER_EXISTING_ACCOUNT} / 요청 계정ID ${account_id})"
                register_log "조용히 재지정하면 진행 중인 '--profile ${profile_name}' 명령이 엉뚱한 고객 계정을 조회하게 되고,"
                register_log "기존 계정의 credential 캐시가 고아가 됩니다. 쓰지 않고 중단합니다."
                register_log "~/.aws/config 는 변경되지 않았습니다."
                register_suggest_retry "$script_abs" "$account_id" "$corp_name" "$account_name"
                register_log "register 는 어떤 섹션도 삭제하지 않습니다. 기존 등록을 정리하려면 cleanup 서브커맨드를 쓰세요."
                exit 1
                ;;
            contaminated)       # row 5
                class_label=$(collision_class_label "$REGISTER_BLOCKING_KEY" "$REGISTER_BLOCKING_SOURCE")
                register_reason "contaminated-hybrid"
                register_log "중단: 프로필 '${profile_name}' 은(는) CSG 소유이지만 외래 credential 키가 섞여 있습니다 (오염된 하이브리드)."
                register_log "충돌 대상: ${class_label} (${REGISTER_BLOCKING_KEY} 키 보유)"
                register_log "CSG 가 쓴 키와 엔지니어 본인의 credential 키가 한 섹션에 공존하는 상태입니다."
                register_log "덮어쓰면 본인 신원 설정이 손상될 수 있어 register 는 병합도 복구도 하지 않습니다."
                register_log "~/.aws/config 는 변경되지 않았습니다."
                # Pitfall 11 / ROADMAP criterion 5 is now SATISFIED BY SHIPPING,
                # not by hedging: `doctor` exists as of Phase 23, so the imperative
                # below names a command that actually runs. It takes no required
                # flags -- keep it that way, or reword this line to match.
                register_log "복구하려면 doctor 를 실행하세요:"
                printf '[register]   %s doctor\n' "$script_abs" >&2
                register_log "doctor 는 오염된 섹션에서 csg_managed 와 credential_process 두 키만 제거하고"
                register_log "섹션 자체와 sso_* / region / output 은 값까지 보존합니다. 복구 후 이 명령을 다시 실행하세요."
                register_suggest_retry "$script_abs" "$account_id" "$corp_name" "$account_name"
                exit 1
                ;;
            foreign)            # row 6 -- PROF-11 proper
                class_label=$(collision_class_label "$REGISTER_BLOCKING_KEY" "$REGISTER_BLOCKING_SOURCE")
                register_reason "foreign-profile"
                register_log "중단: 프로필 '${profile_name}' 이(가) 이미 존재하며 CSG 소유가 아닙니다."
                register_log "충돌 대상: ${class_label} (${REGISTER_BLOCKING_KEY} 키 보유)"
                if [[ "$REGISTER_BLOCKING_SOURCE" == "credentials" ]]; then
                    register_log "~/.aws/credentials 의 정적 키는 credential_process 보다 우선하므로, 병합하면 이 프로필은"
                    register_log "브로커를 거치지 않고 조용히 엔지니어 본인 신원으로 해석됩니다. 쓰지 않고 중단합니다."
                else
                    register_log "병합하면 이 섹션에 credential_process 가 주입되어 엔지니어 본인 신원이 조용히 바뀌고,"
                    register_log "이후 sweep 이 섹션 전체를 삭제할 수 있습니다. 쓰지 않고 중단합니다."
                fi
                register_log "~/.aws/config 는 변경되지 않았습니다."
                register_suggest_retry "$script_abs" "$account_id" "$corp_name" "$account_name"
                exit 1
                ;;
            *)                  # row 7 -- unknown existing section (conservative)
                register_reason "unknown-profile"
                register_log "중단: 프로필 '${profile_name}' 이(가) 이미 존재하지만 CSG 가 만든 섹션이라는 증거가 없습니다."
                register_log "충돌 대상: 알 수 없는 기존 섹션 (csg_managed 마커도 CSG credential_process 도 없음)"
                register_log "CSG 가 만들지 않은 섹션에 키를 주입하는 것이 바로 이번에 막으려는 쓰기 경로 결함입니다."
                register_log "이름이 겹쳤을 뿐이라면 대체 이름을 쓰는 편이 안전합니다. 쓰지 않고 중단합니다."
                register_log "~/.aws/config 는 변경되지 않았습니다."
                register_suggest_retry "$script_abs" "$account_id" "$corp_name" "$account_name"
                exit 1
                ;;
        esac
    fi

    # [6] write. Every read is done; only now is the file touched.
    # Pitfall 6 / T-22-07: csg_managed FIRST, credential_process LAST. The four
    # `aws configure set` calls are four separate processes. A section holding
    # only the marker is inert to credential resolution (the CLI stores an
    # unrecognized key without interpreting it) and is unambiguously CSG-owned,
    # so a re-run lands on decision-table row 3 and completes cleanly. The
    # reverse order would leave a RESOLVABLE profile in an unowned state.
    # botocore tokenises credential_process with shell-style splitting, so an
    # install path containing whitespace (`/Users/Jane Doe/...`, or the skill's
    # own `$HOME/.claude/skills/...` under such a home) is torn apart and every
    # AWS call fails with an unrelated-looking `Errno 2: No such file`. %q emits
    # the shell-quoted form and is a NO-OP for a path with no special characters,
    # so the common case is byte-identical to what previous versions wrote. The
    # PowerShell twin has always quoted (`-File "$scriptAbs"`); this closes the
    # one-sided gap.
    local cp_value
    printf -v cp_value '%q --account-id %s' "$script_abs" "$account_id"
    local -a set_keys=("csg_managed" "region" "output" "credential_process")
    local -a set_vals=("$CSG_MANAGED_VERSION" "ap-northeast-2" "json" "$cp_value")
    local i wrc written
    for (( i=0; i<${#set_keys[@]}; i++ )); do
        # T-22-04: values are passed as individual argv elements. No eval, no
        # string-assembled `aws` command line.
        set +e
        # WR-06 (same invariant, register's side): stdout is redirected because
        # do_register's own stdout contract is EXACTLY ONE line -- the new
        # section name, which do_migrate reads back as $reg_out and then uses as
        # a profile name. A CLI banner on this channel would be spliced into
        # that name. stderr is deliberately left attached: the failure report
        # below quotes it.
        aws configure set "${set_keys[$i]}" "${set_vals[$i]}" --profile "$profile_name" >/dev/null
        wrc=$?
        set -e
        if (( wrc != 0 )); then
            written="(없음)"
            if (( i > 0 )); then
                written=$(printf '%s ' "${set_keys[@]:0:i}")
                written="${written% }"
            fi
            register_die "write-failed" \
                "중단: 'aws configure set ${set_keys[$i]}' 이(가) exit=${wrc} 로 실패했습니다." \
                "프로필: ${profile_name} / 지금까지 기록된 키: ${written}" \
                "마커를 먼저 쓰므로 부분 기록된 섹션은 credential 해석에 관여하지 않습니다." \
                "원인을 해결한 뒤 같은 명령을 다시 실행하면 재등록 경로로 수렴합니다."
        fi
    done

    # [7] post-condition re-read (S3). The project does not trust a tool's exit
    # code for a mutation claim -- read the result back before claiming success.
    # Deliberately a config read-back and NOT an STS caller-identity round-trip:
    # that would need a live Bearer plus a broker call, and would fail for
    # reasons that have nothing to do with whether the profile got registered.
    local rb_cp rb_marker rb_rc
    set +e
    rb_cp=$(aws_configure_get "credential_process" "$profile_name")
    rb_rc=$?
    set -e
    (( rb_rc == 0 )) || register_die "postcondition-failed" \
        "중단: 기록 직후 credential_process 를 다시 읽지 못했습니다 (exit=${rb_rc})." \
        "프로필 '${profile_name}' 의 상태를 직접 확인하세요."
    # EXACT-value post-condition, against an INDEPENDENTLY RECOMPUTED oracle --
    # deliberately not the $cp_value variable the write used, because comparing
    # the read-back to the same variable would mirror a write-side regression
    # instead of catching it.
    #
    # The two substring tests this replaces (`*get-customer-credentials.sh*` and
    # `*--account-id NNN*`) could not do this job: an UNQUOTED path containing a
    # space satisfies BOTH of them, so a profile that botocore cannot execute at
    # all used to pass the read-back and be reported as a successful register.
    local expected_cp
    printf -v expected_cp '%q --account-id %s' "$script_abs" "$account_id"
    [[ "$rb_cp" == "$expected_cp" ]] || register_die "postcondition-failed" \
        "중단: 기록된 credential_process 가 기대값과 일치하지 않습니다." \
        "기대: '${expected_cp}'" \
        "실제: '${rb_cp}'" \
        "프로필 '${profile_name}' 의 상태를 직접 확인하세요."

    set +e
    rb_marker=$(aws_configure_get "csg_managed" "$profile_name")
    rb_rc=$?
    set -e
    { (( rb_rc == 0 )) && [[ -n "$rb_marker" ]]; } || register_die "postcondition-failed" \
        "중단: 기록 직후 csg_managed 마커를 다시 읽지 못했습니다 (exit=${rb_rc})."

    # [8] success. EXACTLY one line on stdout: the profile name.
    if [[ "$action" == "reregister" ]]; then
        register_log "이미 등록됨 — 갱신함: ${profile_name} (계정 ${account_id})"
    else
        register_log "등록 완료: ${profile_name} (계정 ${account_id})"
    fi
    register_log "사용: aws --profile ${profile_name} <command>"
    printf '%s\n' "$profile_name"
    exit 0
}

# remove_keys_from_profile <config_file> <profile_name> <key1> [key2 ...]
#
# PROF-13 / D-09: remove SPECIFIC keys from ONE INI section. Every other byte of
# the file is preserved -- the section header itself, sso_*/region/output and
# every other key in the section, comments, blank lines, key spacing, and CRLF
# line terminators. Non-target sections are never touched (T-23-05).
#
# This is deliberately NOT `rewrite_config_removing_profiles`: that one deletes
# whole sections, which would take an engineer's SSO configuration with it
# (T-23-06). It is also deliberately NOT `aws configure set <key> ""` -- that
# returns rc 0 while leaving the key behind with an empty value (23-RESEARCH V1),
# so it is not a removal mechanism at all.
#
# Placement note: this function lives OUTSIDE the
#   `# --- Profile cleanup helpers ---` ... `# --- Subcommand routing`
# range that test/credentials-guard.test.sh extracts and sources. Do not move it
# into that range and do not reword either marker literal.
#
# Extraction note: test/doctor.test.sh sources this function via
#   awk '/^remove_keys_from_profile\(\)/,/^}/'
# which stops at the FIRST column-0 `}`. The embedded awk program below is
# therefore indented -- awk ignores the indentation, and it keeps the function's
# closing brace the only `}` in column 0.
#
# Returns 0 only after every requested key is confirmed absent via
# `aws configure get` rc 1. Returns 1 on any other rc -- awk's own exit status is
# never accepted as proof of removal (T-23-08).
remove_keys_from_profile() {
    local config_file="$1"
    local profile_name="$2"
    shift 2

    [[ $# -eq 0 ]] && return 0
    [[ -f "$config_file" ]] || return 1

    # The post-condition below IS the contract. Without `aws` there is no way to
    # prove a key is gone, so refuse to mutate the file at all rather than make
    # an unverifiable claim (T-23-08).
    if ! command -v aws >/dev/null 2>&1; then
        printf '[doctor] 중단: 키 제거 사후검증에 필요한 aws 명령을 찾을 수 없습니다\n' >&2
        return 1
    fi

    # CR-01 / T-11-01 / T-23-07: data reaches awk only through -v, never through
    # string interpolation into the program body. `|` is the KEYS delimiter, so a
    # value carrying one could smuggle an extra key into the removal set.
    if [[ "$profile_name" == *"|"* ]]; then
        printf '[doctor] 중단: 프로필 이름에 파이프 문자가 있습니다: %s\n' "$profile_name" >&2
        return 1
    fi
    local keys="" k
    for k in "$@"; do
        if [[ "$k" == *"|"* ]]; then
            printf '[doctor] 중단: 키 이름에 파이프 문자가 있습니다: %s\n' "$k" >&2
            return 1
        fi
        [[ -n "$keys" ]] && keys="${keys}|"
        keys="${keys}${k}"
    done

    # D-10 / T-23-09: back up BEFORE touching anything.
    # CSG_BACKUP_SESSION: see the identical note in
    # rewrite_config_removing_profiles -- a migrate run performs surgery on N
    # sections and renames M more, and all of that is ONE operation with ONE
    # rollback point. Unset (doctor, sweep, cleanup) the behaviour is unchanged.
    local backup_file="${CSG_BACKUP_SESSION:-${config_file}.bak.$(date +%Y%m%d%H%M%S)}"
    [[ -f "$backup_file" ]] || cp "$config_file" "$backup_file"

    # Written to a temp .awk file (rather than an inline program string) so the
    # quote-stripping regex does not have to survive bash single-quote nesting --
    # same reason as rewrite_config_removing_profiles.
    local awk_prog tmp_conf cnt_file
    awk_prog=$(mktemp "${TMPDIR:-/tmp}/ccred.keys.XXXXXX")
    cat > "$awk_prog" <<'AWKPROG'
    # norm_header(): the shipped normalize_name() plus [default] CRLF tolerance.
    function norm_header(line,    name) {
        sub(/\r$/, "", line)
        name = ""
        if (match(line, /^\[profile[ \t]+/)) {
            name = substr(line, RLENGTH + 1)
            sub(/\][ \t]*$/, "", name)
            gsub(/^[ \t]+|[ \t]+$/, "", name)
            gsub(/^['"]|['"]$/, "", name)      # WR-08: same quote strip as the collector
        } else if (line ~ /^\[default\][ \t]*$/) {
            name = "default"
        }
        return name
    }
    BEGIN {
        n = split(KEYS, arr, "|")
        for (i = 1; i <= n; i++) key_set[tolower(arr[i])] = 1
        in_target = 0; dropping = 0; removed = 0
    }
    # EVERY bracketed line re-decides membership and cancels an in-flight drop --
    # not only [profile ...]/[default]. An [sso-session x] between the target key
    # and its continuation must not inherit the drop state (Pattern 4 / T-23-05).
    /^\[/ { in_target = (norm_header($0) == TARGET); dropping = 0; print; next }
    {
        stripped = $0; sub(/\r$/, "", stripped)
        # botocore treats an indented line after "key =" as a nested value; the
        # whole continuation leaves with its parent key.
        if (in_target && dropping && stripped ~ /^[ \t]+/) next
        dropping = 0
        if (in_target && stripped ~ /^[ \t]*[^#;[][^=]*=/) {
            k = stripped; sub(/=.*$/, "", k); gsub(/^[ \t]+|[ \t]+$/, "", k)
            # removed_set records WHICH keys actually left, so the caller can
            # name exactly those. Naming the whole target set instead made the
            # count and the list disagree ("키 1개 제거됨: csg_managed
            # credential_process") whenever a section carried only one of them.
            if (tolower(k) in key_set) { dropping = 1; removed++; removed_set[tolower(k)] = 1; next }
        }
        # Untouched lines are re-emitted verbatim: the \r strip above only ever
        # applied to the comparison copy, never to the output (V4).
        print
    }
    # Line 1 = count, line 2 = the removed key names in KEYS order (may be
    # empty). Two fixed lines, so the caller parses by line number and never has
    # to guess where the count ends and the names begin.
    END {
        printf "%d\n", removed > "/dev/stderr"
        out = ""
        for (i = 1; i <= n; i++) {
            lk = tolower(arr[i])
            if (lk in removed_set) out = (out == "" ? lk : out " " lk)
        }
        printf "%s\n", out > "/dev/stderr"
    }
AWKPROG

    # D-12: atomic write via mktemp (same directory, so mv cannot cross a
    # filesystem) + mv. WR-02: temp files are removed on every exit path.
    tmp_conf=$(mktemp "${config_file}.XXXXXX")
    cnt_file=$(mktemp "${TMPDIR:-/tmp}/ccred.cnt.XXXXXX")

    if ! awk -v TARGET="$profile_name" -v KEYS="$keys" -f "$awk_prog" "$config_file" \
        > "$tmp_conf" 2>"$cnt_file"; then
        rm -f "$tmp_conf" "$awk_prog" "$cnt_file"
        return 1
    fi

    local removed_count removed_names
    removed_count=$(sed -n '1p' "$cnt_file" | tr -cd '0-9')
    [[ -n "$removed_count" ]] || removed_count=0
    removed_names=$(sed -n '2p' "$cnt_file")
    rm -f "$awk_prog" "$cnt_file"

    mv "$tmp_conf" "$config_file"

    # Architecture Pattern 6 / T-23-08: post-condition re-read. awk's exit status
    # says the program ran, not that the key is gone. Only rc 1 from the CLI
    # proves genuine absence (23-RESEARCH V2):
    #   rc 0   -> key survived (a blanked value still reads as present -- V1)
    #   rc 1   -> genuinely absent
    #   rc 255 -> the rewritten config no longer parses
    # AWS_CONFIG_FILE is pinned so the probe reads the file that was just
    # rewritten, never whatever ~/.aws/config the ambient environment resolves.
    local rc
    for k in "$@"; do
        rc=0
        (
            export AWS_CONFIG_FILE="$config_file"
            unset AWS_PROFILE AWS_DEFAULT_PROFILE
            aws configure get "$k" --profile "$profile_name"
        ) >/dev/null 2>&1 || rc=$?

        if (( rc != 1 )); then
            if (( rc == 0 )); then
                printf '[doctor] 키 제거 사후검증 실패: %s (exit=0, 값이 비워졌을 뿐 제거되지 않음)\n' "$k" >&2
            else
                printf '[doctor] 키 제거 사후검증 실패: %s (exit=%d)\n' "$k" "$rc" >&2
            fi
            printf '[doctor] 복구하려면: cp %q %q\n' "$backup_file" "$config_file" >&2
            return 1
        fi
    done

    # PROF-14: everything this function says goes to stderr -- stdout on this
    # script carries the 5-key credential JSON contract.
    # Name ONLY the keys that actually left: the count and the list must agree,
    # or the reader trusts neither (23-10 checkpoint finding 1).
    [[ -n "$removed_names" ]] || removed_names="없음"
    printf '[doctor] 키 %s개 제거됨: %s (프로필 %s)\n' "$removed_count" "$removed_names" "$profile_name" >&2
    printf '[doctor] 복구하려면: cp %q %q\n' "$backup_file" "$config_file" >&2
    return 0
}

# carry_section_keys <config_file> <old_profile> <new_profile> <owned_key1> [owned_key2 ...]
# CR-01: makes `migrate`'s rename an actual RENAME.
#
# `register` writes exactly four keys into the freshly minted section
# (csg_managed, region, output, credential_process) and knows nothing about the
# section it is replacing, so without this step every other key the engineer had
# set -- cli_pager, ca_bundle, an `s3 =` sub-section, anything -- is destroyed by
# the subsequent delete, and region/output are silently reset to the hardcoded
# defaults. A silent region flip is not cosmetic here: every later read-only
# customer query then runs against the wrong region and returns "no resources",
# which the agent reports to the engineer as fact.
#
# Contract:
#   - every key present in <old_profile> EXCEPT the <owned_key...> set is copied
#     into <new_profile> VERBATIM (original spelling, spacing and indented
#     continuation block), replacing whatever `register` wrote for that key;
#   - the <owned_key...> set (csg_managed / credential_process) is never carried:
#     those are the two keys register legitimately authors;
#   - key order from the old section is preserved;
#   - a key that exists ONLY in the new section survives untouched.
#
# Done with awk over the file rather than a fixed `aws configure set` allow-list
# because (a) the key set is open-ended and (b) `aws configure set` cannot
# reproduce an indented continuation block byte-for-byte.
#
# Returns 0 when the file was rewritten (or when there was nothing to carry),
# 1 on any failure; the caller treats failure as "do not delete the old section".
carry_section_keys() {
    local config_file="$1" old_name="$2" new_name="$3"
    shift 3

    [[ -f "$config_file" ]] || return 1
    # Same delimiter defense as remove_keys_from_profile: data reaches awk only
    # through -v, and `|` is the OWNED-key delimiter.
    [[ "$old_name" == *"|"* || "$new_name" == *"|"* ]] && return 1

    local owned="" k
    for k in "$@"; do
        [[ "$k" == *"|"* ]] && return 1
        [[ -n "$owned" ]] && owned="${owned}|"
        owned="${owned}${k}"
    done

    local awk_prog tmp_conf
    awk_prog=$(mktemp "${TMPDIR:-/tmp}/ccred.carry.XXXXXX") || return 1
    cat > "$awk_prog" <<'AWKPROG'
    # Same header normalizer as remove_keys_from_profile / the collector.
    function norm_header(line,    name) {
        sub(/\r$/, "", line)
        name = ""
        if (match(line, /^\[profile[ \t]+/)) {
            name = substr(line, RLENGTH + 1)
            sub(/\][ \t]*$/, "", name)
            gsub(/^[ \t]+|[ \t]+$/, "", name)
            gsub(/^['"]|['"]$/, "", name)
        } else if (line ~ /^\[default\][ \t]*$/) {
            name = "default"
        }
        return name
    }
    # Emit every carried block that the new section did not already re-emit,
    # then any blank lines that were being held back so the carried keys land
    # INSIDE the section rather than after its trailing blank line.
    function flush(    i, lk) {
        for (i = 1; i <= n_order; i++) {
            lk = order[i]
            if (lk in blk) printf "%s\n", blk[lk]
        }
        if (pending != "") printf "%s", pending
        pending = ""
    }
    BEGIN {
        n_owned = split(OWNED, oarr, "|")
        for (i = 1; i <= n_owned; i++) owned_set[tolower(oarr[i])] = 1
        n_order = 0; carried = 0
    }
    # ---- pass 1 (first copy of the file): harvest the OLD section ----
    NR == FNR {
        line = $0; sub(/\r$/, "", line)
        if (line ~ /^\[/) { in_old = (norm_header($0) == OLD); cur = ""; dropping = 0; next }
        if (!in_old) next
        # botocore treats an indented line after "key =" as a nested value, so a
        # continuation block travels with its parent key.
        if (line ~ /^[ \t]+/) {
            if (dropping) next
            if (cur != "") blk[cur] = blk[cur] "\n" $0
            next
        }
        cur = ""; dropping = 0
        if (line ~ /^[ \t]*[^#;[][^=]*=/) {
            k = line; sub(/=.*$/, "", k); gsub(/^[ \t]+|[ \t]+$/, "", k)
            lk = tolower(k)
            if (lk in owned_set) { dropping = 1; next }
            if (!(lk in blk)) order[++n_order] = lk
            blk[lk] = $0
            cur = lk
            carried = 1
        }
        next
    }
    # ---- pass 2 (second copy): rewrite the NEW section ----
    {
        line = $0; sub(/\r$/, "", line)
        if (line ~ /^\[/) {
            if (in_new) flush()
            in_new = (norm_header($0) == NEW); dropping = 0
            if (pending != "") { printf "%s", pending; pending = "" }
            print
            next
        }
        if (in_new) {
            if (dropping && line ~ /^[ \t]+/) next
            dropping = 0
            if (line ~ /^[ \t]*[^#;[][^=]*=/) {
                k = line; sub(/=.*$/, "", k); gsub(/^[ \t]+|[ \t]+$/, "", k)
                # The old value wins, and it is re-emitted at flush() in the OLD
                # section's key order -- not here, where it would be re-ordered.
                if (tolower(k) in blk) { dropping = 1; next }
            }
            if (line ~ /^[ \t]*$/) { pending = pending $0 "\n"; next }
            if (pending != "") { printf "%s", pending; pending = "" }
            print
            next
        }
        print
    }
    END {
        if (in_new) flush()
        else if (pending != "") printf "%s", pending
        # Line 1 of stderr: 1 when at least one key was harvested, else 0.
        printf "%d\n", carried > "/dev/stderr"
    }
AWKPROG

    # D-12: atomic write via mktemp in the SAME directory + mv.
    tmp_conf=$(mktemp "${config_file}.XXXXXX") || { rm -f "$awk_prog"; return 1; }

    if ! awk -v OLD="$old_name" -v NEW="$new_name" -v OWNED="$owned" \
        -f "$awk_prog" "$config_file" "$config_file" > "$tmp_conf" 2>/dev/null; then
        rm -f "$tmp_conf" "$awk_prog"
        return 1
    fi
    rm -f "$awk_prog"

    mv "$tmp_conf" "$config_file"
    return 0
}

# --- doctor subcommand (PROF-13 / D-03 / ROADMAP criterion 4) ---
#
# Repairs CONTAMINATED HYBRID sections: a section carrying CSG ownership evidence
# (the csg_managed marker or a credential_process pointing at this script) AND a
# foreign credential key that belongs to the engineer (sso_*, aws_access_key_id,
# role_arn, ...). The pre-Phase-21 write path could produce these by injecting
# into a section it did not create; Phase 21's guard then refuses to sweep them,
# which leaves them stranded until something repairs them. This is that something.
#
# Every printed `doctor` reference in this client points here: the [guard] line in
# record_and_warn_skip and register decision-table row 5. Both are runnable as
# printed -- `doctor` takes no required flags (T-23-21).
#
# WHY KEY-LEVEL AND NOT SECTION-LEVEL: the section belongs to the ENGINEER, not to
# CSG. Deleting it would take their SSO configuration with it (T-23-06). Only the
# two keys CSG injected come out.
#
# Contract:
#   stdout -- ALWAYS EMPTY (T-23-18). This script's stdout carries the 5-key
#             credential_process JSON contract; a stray byte here is parsed by the
#             AWS CLI on every customer session.
#   stderr -- every line prefixed "[doctor] ", the convention shared with
#             [sweep]/[cleanup]/[guard]/[register].
#   exit   -- 0 when the config was READ and every contaminated section (possibly
#             none) is repaired; 1 when the config could not be read or a repair
#             failed. "Unreadable" is never reported as "nothing to repair"
#             (T-23-19).
#
# Placement note: this function is deliberately BELOW the `# --- Subcommand
# routing` marker, i.e. outside the range test/credentials-guard.test.sh extracts
# and sources. It also has to be below sanitize_for_display and
# remove_keys_from_profile, which is why its routing block sits beside register's
# rather than beside cleanup's.
doctor_log() {
    printf '[doctor] %s\n' "$*" >&2
}

# doctor_abort_unparseable <exit_code>
# T-23-19 / 23-RESEARCH Pitfall 7. A non-zero `aws configure list-profiles` means
# the config is UNREADABLE. That is a different fact from "no contaminated
# sections were found", and conflating them would have doctor hand the engineer a
# clean bill of health for a file it never managed to parse. Mirrors
# abort_config_unparseable's cause list and recovery-notice format under the
# [doctor] prefix; it cannot call that function because register's variant emits
# the [register] prefix and exits the process.
doctor_abort_unparseable() {
    local rc="$1"
    local config_file="${HOME}/.aws/config"

    printf '[doctor] reason=config-unparseable\n' >&2
    doctor_log "중단: ~/.aws/config 를 읽을 수 없습니다 (aws configure list-profiles exit=${rc})."
    doctor_log "이 상태에서는 섹션을 볼 수 없으므로 '오염 없음'으로 간주하지 않고 중단합니다."
    doctor_log "흔한 원인:"
    doctor_log "  - 파일 맨 앞의 UTF-8 BOM (에디터가 붙였을 수 있음)"
    doctor_log "  - 같은 [profile X] 섹션 헤더가 두 번 존재"
    doctor_log "  - 닫는 ']' 가 빠진 헤더"

    # Ordered by NAME, never by mtime -- see list_recent_backups_note.
    local -a backups=()
    local b
    while IFS= read -r b; do
        # -f, not -n: the PowerShell twin filters with -File, and a directory
        # named like a backup must never reach the `cp`. `if`, not `[[ ]] &&`:
        # a false AND-list is the last command in the loop body and would trip
        # `set -e` -- an abort inside the abort path.
        if [[ -f "$b" ]]; then backups+=("$b"); fi
    done < <(ls -1d "${config_file}".bak.* 2>/dev/null | LC_ALL=C grep -E '\.bak\.[0-9]{14}$' | LC_ALL=C sort -r | head -3 || true)

    if [[ ${#backups[@]} -eq 0 ]]; then
        doctor_log "최근 백업: 백업 파일이 없습니다"
    else
        doctor_log "최근 백업:"
        for b in "${backups[@]}"; do
            doctor_log "  ${b}"
        done
        printf '[doctor] 복구하려면: cp %q %q\n' "${backups[0]}" "$config_file" >&2
    fi

    doctor_log "아무것도 고치지 않았습니다 — ~/.aws/config 는 변경되지 않았습니다."
    return 1
}

do_doctor() {
    local config_file="${HOME}/.aws/config"

    if [[ ! -f "$config_file" ]]; then
        doctor_log "~/.aws/config 가 없습니다 — 복구 대상 없음."
        return 0
    fi

    # (1) FAIL-CLOSED ENTRY. AWS_CONFIG_FILE is pinned so the readability verdict
    # is about the file doctor would actually operate on, never whatever config
    # the ambient environment happens to resolve (the same pin
    # remove_keys_from_profile uses for its post-condition probe).
    local list_rc=0
    (
        export AWS_CONFIG_FILE="$config_file"
        unset AWS_PROFILE AWS_DEFAULT_PROFILE
        aws configure list-profiles
    ) >/dev/null 2>&1 || list_rc=$?
    if (( list_rc != 0 )); then
        doctor_abort_unparseable "$list_rc"
        return 1
    fi

    # (2) SELECT. The 5th out-param carries the contaminated set; the first two
    # are the sweep-eligible profiles, which doctor deliberately ignores -- a
    # healthy CSG profile holds csg_managed and credential_process too, and is
    # not a repair target.
    # GUARD_SKIP_QUIET: see record_and_warn_skip -- suppresses the "run doctor to
    # repair" advisory while doctor is the one running.
    local GUARD_SKIP_QUIET="true"
    local -a csg_profiles=() csg_caches=() contaminated=()
    collect_csg_profiles "$config_file" "all" csg_profiles csg_caches contaminated

    if [[ ${#contaminated[@]} -eq 0 ]]; then
        doctor_log "복구 대상 없음 — 오염된 하이브리드 섹션이 없습니다."
        return 0
    fi

    # T-23-17: profile names come from a file this script does not own and are not
    # guaranteed to match [a-z0-9-]. Every name that reaches the operator's
    # terminal or a CI log goes through sanitize_for_display first.
    local name
    doctor_log "오염된 하이브리드 섹션 ${#contaminated[@]}개를 발견했습니다:"
    for name in "${contaminated[@]}"; do
        if is_skip_profile "$name"; then
            doctor_log "  - $(sanitize_for_display "$name") (보호 섹션 — 수술 제외, 수동 확인 필요)"
        else
            doctor_log "  - $(sanitize_for_display "$name")"
        fi
    done

    # (3) SURGERY. Exactly two keys, named literally, per D-09. Adding a third key
    # here would start deleting configuration this tool did not write.
    #
    # CR-03: the SKIP_PROFILES filter is applied HERE, between the (blind)
    # reporting predicate and the surgery. Without it doctor strips
    # credential_process from `csg-login`, the login anchor, and exits 0 -- and
    # register's decision-table row 5 is the line that tells the engineer to run
    # doctor in the first place.
    local -a surgery_targets=() protected=()
    for name in "${contaminated[@]}"; do
        if is_skip_profile "$name"; then
            protected+=("$name")
            continue
        fi
        surgery_targets+=("$name")
    done

    local -a repaired=() failed=()
    for name in ${surgery_targets[@]+"${surgery_targets[@]}"}; do
        if remove_keys_from_profile "$config_file" "$name" csg_managed credential_process; then
            repaired+=("$name")
        else
            failed+=("$name")
        fi
    done

    if [[ ${#protected[@]} -gt 0 ]]; then
        doctor_log "보호 섹션 ${#protected[@]}개는 수술하지 않았습니다 (인프라 예약 프로필):"
        for name in "${protected[@]}"; do
            doctor_log "  - $(sanitize_for_display "$name") — 수동 확인 필요"
        done
        doctor_log "이 섹션들은 csg-login 로그인 앵커와 [default] 를 포함하므로 자동으로 키를 제거하지 않습니다."
    fi

    # (4) SUMMARY, do_cleanup's CSV shape under the [doctor] prefix.
    local names_csv="" i
    if [[ ${#repaired[@]} -gt 0 ]]; then
        names_csv="$(sanitize_for_display "${repaired[0]}")"
        for (( i=1; i<${#repaired[@]}; i++ )); do
            names_csv="${names_csv}, $(sanitize_for_display "${repaired[$i]}")"
        done
        doctor_log "복구한 프로필 ${#repaired[@]}개: ${names_csv}"
    fi

    # (5) D-04: the engineer owns these sections. Surgery on them is not something
    # to do silently, and an SSO session cached against the pre-surgery section
    # should be re-confirmed before the next customer call.
    if [[ ${#repaired[@]} -gt 0 ]]; then
        doctor_log "다음 단계: 위 프로필의 SSO 로그인이 아직 유효한지 'aws sso login --profile <프로필>' 로 재확인하세요."
    fi

    # (6) D-09: say what was NOT removed, and why. region/output are ordinary AWS
    # settings -- there is no way to tell CSG's from the engineer's own.
    doctor_log "제거한 키는 csg_managed 와 credential_process 두 개뿐입니다. sso_* / region / output 등"
    doctor_log "나머지 키는 엔지니어 본인 설정과 구분할 수 없어 값까지 그대로 보존했습니다."

    # (7) Known scope limit, stated rather than hidden. The collector reads
    # ~/.aws/config only, so a section whose foreign key lives exclusively in
    # ~/.aws/credentials is invisible to it and is not classified as contaminated.
    doctor_log "알려진 범위 한계: 외래 키가 ~/.aws/credentials 에만 있는 섹션은 config 만 읽는 이 검사에"
    doctor_log "보이지 않으므로 오염으로 분류되지 않습니다."

    if [[ ${#failed[@]} -gt 0 ]]; then
        doctor_log "복구 실패 ${#failed[@]}개:"
        for name in "${failed[@]}"; do
            doctor_log "  - $(sanitize_for_display "$name")"
        done
        doctor_log "위 섹션은 아직 오염 상태입니다. 원인 메시지를 확인한 뒤 다시 실행하세요."
        return 1
    fi

    return 0
}

# --- migrate subcommand (PROF-12 / D-01/D-02/D-03/D-06/D-07/D-08) ---
#
# The one-shot, client-side fleet migration into the `csg-` namespace. This is
# the ONLY destructive code path this milestone ships, and the only delivery
# vehicle that reaches an already-deployed fleet: `self-update` swaps files and
# never calls the installer, so an installer-side migration would never run on a
# machine that is already installed.
#
# Contract (frozen by test/fleet-migrate.test.sh):
#   stdout -- ALWAYS EMPTY, on every path. This script's stdout is the 5-key
#             credential_process JSON channel.
#   stderr -- every line prefixed "[migrate] " (the [guard]/[doctor] lines the
#             reused helpers emit are the documented exception).
#   rc     -- 0 on success AND on the already-migrated no-op; non-zero only on a
#             fail-closed abort.
#   tokens -- name-collision (D-07), config-unparseable (Pitfall 7).
#   NO confirmation prompt, ever (D-02): there is no TTY on the
#   credential_process path, so a prompt would hang the whole fleet.
#
# Placement note: like register's and doctor's helpers this lives BELOW the
# `# --- Subcommand routing` marker, outside the range
# test/credentials-guard.test.sh extracts and sources. It also has to sit below
# sanitize_for_display / remove_keys_from_profile / derive_profile_name, all of
# which it reuses.

# migration_completed
# Returns 0 when MIGRATION_ID has already been recorded. A missing record file
# means "not yet" (return 1). This is the FIRST thing run_migration_once does --
# in the steady state (every AWS call on an already-migrated machine) the entire
# cost of the migration hook must be this one grep on a tiny file.
migration_completed() {
    [[ -f "$MIGRATION_RECORD" ]] || return 1
    grep -Fq "\"id\":\"${MIGRATION_ID}\"" "$MIGRATION_RECORD" 2>/dev/null
}

# record_migration_completed <renamed> <repaired> <skipped>
# Appends the one-line completion record. Written with jq -cn --arg/--argjson,
# the same discipline as record_and_warn_skip.
# The printf fallback is NOT a second writer competing with jq: it exists because
# migrate's routing gate deliberately requires only `aws` (Pitfall 10), so jq may
# genuinely be absent -- and every field here is either a constant this file owns
# or an integer this file counted, so there is no interpolation surface. Losing
# the marker would silently RE-ARM a destructive migration, which is strictly
# worse than emitting the same JSON without jq.
record_migration_completed() {
    local renamed="${1:-0}" repaired="${2:-0}" skipped="${3:-0}"
    local now
    now=$(date -u +%Y-%m-%dT%H:%M:%SZ)

    if command -v jq >/dev/null 2>&1; then
        jq -cn --arg id "$MIGRATION_ID" --arg t "$now" \
            --argjson renamed "$renamed" --argjson repaired "$repaired" --argjson skipped "$skipped" \
            '{id:$id, completed_at:$t, renamed:$renamed, repaired:$repaired, skipped:$skipped}' \
            >> "$MIGRATION_RECORD" 2>/dev/null && return 0
    fi

    printf '{"id":"%s","completed_at":"%s","renamed":%d,"repaired":%d,"skipped":%d}\n' \
        "$MIGRATION_ID" "$now" "$renamed" "$repaired" "$skipped" >> "$MIGRATION_RECORD" 2>/dev/null || true
}

# migrate_abort_unparseable <exit_code>
# Pitfall 7 / T-23-30. A non-zero `aws configure list-profiles` means the config
# is UNREADABLE -- which is a different fact from "nothing to migrate". Treating
# it as the latter would write the completion marker and permanently skip the
# machine that most needs the repair, so this branch records NOTHING and returns
# non-zero. Mirrors doctor_abort_unparseable's cause list under the [migrate]
# prefix (it cannot call that one: the prefix is baked into every line there).
migrate_abort_unparseable() {
    local rc="$1"
    local config_file="${HOME}/.aws/config"

    printf '[migrate] reason=config-unparseable\n' >&2
    printf '[migrate] 중단: ~/.aws/config 를 읽을 수 없습니다 (aws configure list-profiles exit=%s).\n' "$rc" >&2
    printf '[migrate] 이 상태에서는 섹션을 볼 수 없으므로 "대상 없음"으로 간주하지 않고 중단합니다.\n' >&2
    printf '[migrate] 흔한 원인:\n' >&2
    printf '[migrate]   - 파일 맨 앞의 UTF-8 BOM (에디터가 붙였을 수 있음)\n' >&2
    printf '[migrate]   - 같은 [profile X] 섹션 헤더가 두 번 존재\n' >&2
    printf '[migrate]   - 닫는 "]" 가 빠진 헤더\n' >&2

    # Ordered by NAME, never by mtime -- see list_recent_backups_note.
    local -a backups=()
    local b
    while IFS= read -r b; do
        # -f, not -n: the PowerShell twin filters with -File, and a directory
        # named like a backup must never reach the `cp`. `if`, not `[[ ]] &&`:
        # a false AND-list is the last command in the loop body and would trip
        # `set -e` -- an abort inside the abort path.
        if [[ -f "$b" ]]; then backups+=("$b"); fi
    done < <(ls -1d "${config_file}".bak.* 2>/dev/null | LC_ALL=C grep -E '\.bak\.[0-9]{14}$' | LC_ALL=C sort -r | head -3 || true)

    if [[ ${#backups[@]} -eq 0 ]]; then
        printf '[migrate] 최근 백업: 백업 파일이 없습니다\n' >&2
    else
        printf '[migrate] 최근 백업:\n' >&2
        for b in "${backups[@]}"; do
            printf '[migrate]   %s\n' "$b" >&2
        done
        printf '[migrate] 복구하려면: cp %q %q\n' "${backups[0]}" "$config_file" >&2
    fi

    printf '[migrate] 아무것도 바꾸지 않았습니다 — 원인을 고친 뒤 다시 실행하면 그때 마이그레이션합니다.\n' >&2
    return 1
}

# migrate_target_name <old_profile_name>
# Prints the `csg-` namespaced target name for <old>, rc 1 when the old name
# cannot be normalized into a legal profile name.
# derive_profile_name is THE single owner of the naming rule (D-03/D-08) and this
# is the whole reason the target name is not recomputed here. It is invoked in a
# SUBSHELL because its rejection path calls register_die, which exits the
# process -- in-process that would take the migration down with it.
migrate_target_name() {
    ( derive_profile_name "$1" 2>/dev/null && printf '%s' "$REGISTER_PROFILE_NAME" )
}

# do_migrate
# The 23-RESEARCH Pattern 3 classification table, executed in the ONE order that
# is correct: class E surgery over every section FIRST, then the class A/B rename
# pass. A repaired section carries no CSG evidence any more, so it falls out of
# the rename pass on its own; the reverse order fires renames at still-poisoned
# sections and produces contaminated-hybrid abort noise for sections that were
# about to be fixed anyway.
#
# Renaming is delegated to the `register` subcommand as a SUBPROCESS, never
# called in-process: every one of register's twelve outcomes ends in `exit`, so
# an in-process call would terminate the migration mid-fleet. Delegating also
# means the frozen seven-row collision table -- above all its account-mismatch
# abort, the guard against silently re-pointing a customer profile at a different
# account (T-23-27) -- is consumed as-is rather than reimplemented here.
#
# Always returns 0: an individual profile that cannot be converted is counted as
# skipped and reported, because one collision must not abandon the rest of the
# fleet (D-07).
do_migrate() {
    local config_file="${HOME}/.aws/config"

    MIGRATE_RENAMED=0
    MIGRATE_REPAIRED=0
    MIGRATE_SKIPPED=0
    # Subset of MIGRATE_SKIPPED that is worth RETRYING (a failed delete, a failed
    # key carry, ...) as opposed to permanently unconvertible (name-collision,
    # account-mismatch, no-account-id). See run_migration_once step (5).
    MIGRATE_TRANSIENT_FAILURES=0

    # ONE rollback point for the whole session. The path is reserved here and the
    # file is created EAGERLY as soon as pass-1 knows there is work to do (see
    # the mig_pending block below), never lazily by whichever helper happens to
    # mutate first -- see CR-02.
    local CSG_BACKUP_SESSION="${config_file}.bak.$(date +%Y%m%d%H%M%S)"
    # Same rationale as do_doctor: the "run doctor to repair" advisory would tell
    # the engineer to run the repair that is running right now. The JSONL audit
    # record is still written.
    local GUARD_SKIP_QUIET="true"

    # Absolute path of THIS script, resolved from BASH_SOURCE (never from a
    # config value -- see the identical note in the register path).
    local script_dir script_base script_abs
    script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
    script_base=$(basename -- "${BASH_SOURCE[0]}")
    script_abs="${script_dir}/${script_base}"

    local -a mig_profiles=() mig_caches=() mig_contaminated=()
    local -a renamed_old=() renamed_new=()
    local name disp_old disp_new

    # ---- Pass 1: class E (contaminated hybrid) surgery, D-03 ----
    # The section belongs to the ENGINEER. Only the two keys CSG injected come
    # out; the header and every sso_*/region/output key survive with their
    # values. A contaminated section is NEVER renamed.
    collect_csg_profiles "$config_file" "all" mig_profiles mig_caches mig_contaminated

    # ---- CR-02: the backup is taken HERE, before ANY mutation ----
    # It used to be created lazily by the first helper that happened to rewrite
    # the file. On a machine with no contaminated sections -- the common case --
    # that first helper is rewrite_config_removing_profiles, which runs AFTER the
    # `register` CHILD has already written the new section. The file advertised
    # as `[migrate] backup=` therefore already contained register's work and was
    # not a pre-migration rollback point at all. On the owned-same re-register
    # path that was outright unrecoverable data loss: register OVERWRITES an
    # existing csg-<name> section, and the only copy of its old region/output was
    # the one this backup was supposed to hold.
    #
    # FM-05 ("a run with nothing to do leaves no .bak") still holds: the snapshot
    # is conditional on there being at least one pending unit of work, and the
    # candidate set is exactly the one that could ever have produced a .bak
    # before -- a class-E surgery or a real rename. A marker-backfill-only run
    # writes a single additive key through `aws configure set` and, as before,
    # leaves no .bak.
    # CR-03: a contaminated section that is in SKIP_PROFILES is REPORTED but never
    # operated on, so it is not a unit of work and must not mint a .bak either.
    local mig_pending="false" probe_name probe_target
    for probe_name in ${mig_contaminated[@]+"${mig_contaminated[@]}"}; do
        if ! is_skip_profile "$probe_name"; then
            mig_pending="true"
            break
        fi
    done
    if [[ "$mig_pending" != "true" ]]; then
        for probe_name in ${mig_profiles[@]+"${mig_profiles[@]}"}; do
            if probe_target=$(migrate_target_name "$probe_name") \
               && [[ "$probe_target" != "$probe_name" ]]; then
                mig_pending="true"
                break
            fi
        done
    fi
    if [[ "$mig_pending" == "true" && ! -f "$CSG_BACKUP_SESSION" ]]; then
        cp "$config_file" "$CSG_BACKUP_SESSION" 2>/dev/null || true
    fi

    for name in ${mig_contaminated[@]+"${mig_contaminated[@]}"}; do
        disp_old=$(sanitize_for_display "$name")
        # CR-03: same filter as do_doctor step (3). collect_csg_profiles's
        # contaminated out-param is deliberately blind to SKIP_PROFILES so it can
        # REPORT poisoned infra sections; it must never be used as an action list
        # without this gate, or migrate strips credential_process from the
        # `csg-login` login anchor.
        if is_skip_profile "$name"; then
            printf '[migrate] 보호 섹션 — 수술 제외, 수동 확인 필요: %s\n' "$disp_old" >&2
            continue
        fi
        if remove_keys_from_profile "$config_file" "$name" csg_managed credential_process; then
            MIGRATE_REPAIRED=$(( MIGRATE_REPAIRED + 1 ))
            printf '[migrate] 오염 섹션 복구: %s\n' "$disp_old" >&2
        else
            MIGRATE_SKIPPED=$(( MIGRATE_SKIPPED + 1 ))
            # WR-08: TRANSIENT. The section is still poisoned and a later run can
            # still fix it, so the completion marker must not be written.
            MIGRATE_TRANSIENT_FAILURES=$(( MIGRATE_TRANSIENT_FAILURES + 1 ))
            printf '[migrate] reason=repair-failed %s\n' "$disp_old" >&2
        fi
    done

    # ---- Pass 2: re-read. Surgery changed the file, and a repaired section is
    #      now class F (foreign, no CSG evidence) -- it must not be re-classified
    #      from the pre-surgery snapshot.
    mig_profiles=(); mig_caches=(); mig_contaminated=()
    collect_csg_profiles "$config_file" "all" mig_profiles mig_caches mig_contaminated

    # Classes F (foreign without CSG evidence) and G (SKIP_PROFILES, incl.
    # csg-login and default) never reach this loop: is_csg_profile vetoes both,
    # so collect_csg_profiles never reports them.
    # D-06: the currently-invoked profile is NOT excluded. There is no
    # PROF-06-style self-protection here -- skipping the most-used profile would
    # leave the fleet in two shapes forever and require a second pass.
    local new_name account_id cp_value cp_rc mk_rc reg_rc reg_out err_file token target_existed all_profiles rc
    for name in ${mig_profiles[@]+"${mig_profiles[@]}"}; do
        disp_old=$(sanitize_for_display "$name")

        if ! new_name=$(migrate_target_name "$name"); then
            MIGRATE_SKIPPED=$(( MIGRATE_SKIPPED + 1 ))
            printf '[migrate] reason=invalid-name %s\n' "$disp_old" >&2
            continue
        fi

        # ---- Classes C and D: already inside the `csg-` namespace ----
        # derive_profile_name strips a single leading `csg-` before re-applying
        # it, so an already-namespaced name maps to itself. Class C (marker
        # present) is a no-op; class D (marker missing) gets the marker
        # backfilled and nothing else. Fleet marker backfill is assigned to this
        # phase by the 22-03 carried contract; sweep-time backfill stays banned.
        if [[ "$new_name" == "$name" ]]; then
            set +e
            aws_configure_get "csg_managed" "$name" >/dev/null
            mk_rc=$?
            set -e
            if (( mk_rc == 1 )); then
                set +e
                # WR-06: REDIRECTED, like every other native invocation on this
                # path. run_migration_once is reached from HOOK-B while stdout is
                # the 5-key credential JSON channel, so any byte the CLI ever
                # decides to write there (a deprecation banner, a plugin notice)
                # would be parsed by the AWS CLI as a credential response. Today
                # `aws configure set` is silent, which makes this a latent hazard
                # rather than an active bug -- and exactly the class of leak the
                # phase's stdout invariant exists to prevent. The PowerShell twin
                # has always defended this same call.
                aws configure set csg_managed "$CSG_MANAGED_VERSION" --profile "$name" >/dev/null 2>&1
                mk_rc=$?
                set -e
                if (( mk_rc == 0 )); then
                    printf '[migrate] 마커 보강: %s\n' "$disp_old" >&2
                else
                    MIGRATE_SKIPPED=$(( MIGRATE_SKIPPED + 1 ))
                    # WR-08: TRANSIENT -- the section is convertible, the write
                    # just did not land this time.
                    MIGRATE_TRANSIENT_FAILURES=$(( MIGRATE_TRANSIENT_FAILURES + 1 ))
                    printf '[migrate] reason=marker-backfill-failed %s\n' "$disp_old" >&2
                fi
            fi
            continue
        fi

        disp_new=$(sanitize_for_display "$new_name")

        # ---- Classes A and B: legacy un-prefixed CSG sections ----
        # D-08: the account id is recovered OFFLINE from the section's own
        # credential_process. Zero BILLING calls, and extract_account_id stays
        # the single home of that pattern -- no second regex is written here.
        cp_value=""
        set +e
        cp_value=$(aws_configure_get "credential_process" "$name")
        cp_rc=$?
        set -e
        account_id=""
        if (( cp_rc == 0 )); then
            account_id=$(extract_account_id "$cp_value") || account_id=""
        fi
        if [[ -z "$account_id" ]]; then
            MIGRATE_SKIPPED=$(( MIGRATE_SKIPPED + 1 ))
            printf '[migrate] reason=no-account-id %s\n' "$disp_old" >&2
            continue
        fi

        # Collision probe, re-taken per profile because every rename changes the
        # profile set. Only used to LABEL the outcome -- the decision itself is
        # register's (D-07 class H).
        target_existed="false"
        set +e
        all_profiles=$(aws configure list-profiles 2>/dev/null)
        rc=$?
        set -e
        if (( rc == 0 )) && grep -Fxq -- "$new_name" <<< "$all_profiles"; then
            target_existed="true"
        fi

        # D-08: the OLD profile name is passed as --account-name; the child
        # derives the target itself, so exactly one naming rule exists.
        # CSG_MIGRATE_ACTIVE is cheap insurance only -- the child hits the
        # routing block and exits long before the main flow, so it cannot
        # re-enter this hook.
        err_file=$(mktemp "${TMPDIR:-/tmp}/ccred.migrate.XXXXXX")
        set +e
        reg_out=$(CSG_MIGRATE_ACTIVE=1 bash "$script_abs" register --account-id "$account_id" --account-name "$name" 2>"$err_file")
        reg_rc=$?
        set -e

        if (( reg_rc == 0 )) && [[ -n "$reg_out" ]]; then
            rm -f "$err_file"
            # CR-01: make the rename an actual rename BEFORE the old section is
            # deleted. register authored exactly csg_managed / region / output /
            # credential_process from its own hardcoded defaults; every other key
            # in the old section -- and the engineer's own region/output -- only
            # exists in the section that is about to disappear. Carrying them
            # first is what makes the "설정은 새 섹션으로 이전" line below true.
            if ! carry_section_keys "$config_file" "$name" "$reg_out" csg_managed credential_process; then
                MIGRATE_SKIPPED=$(( MIGRATE_SKIPPED + 1 ))
                MIGRATE_TRANSIENT_FAILURES=$(( MIGRATE_TRANSIENT_FAILURES + 1 ))
                printf '[migrate] reason=carry-failed %s\n' "$disp_old" >&2
                printf '[migrate] 구 섹션은 삭제하지 않았습니다 — 설정을 옮기지 못했기 때문입니다.\n' >&2
                continue
            fi
            # D-01: the old section is DELETED. No alias, no forwarding section.
            # rewrite_config_removing_profiles is the project's ONLY section
            # deleter -- backup, atomic mv, header normalization, post-condition
            # re-read and the PROF-14 recovery notice all live in it.
            # The [guard] deletion notice is suppressed here (see
            # CSG_RENAME_NOTICE in rewrite_config_removing_profiles) and replaced
            # by the rename-specific line below, which says where the settings
            # went instead of only that a section disappeared.
            CSG_RENAME_NOTICE=1
            if rewrite_config_removing_profiles "$config_file" "$name"; then
                CSG_RENAME_NOTICE=""
                renamed_old+=("$name")
                renamed_new+=("$reg_out")
                MIGRATE_RENAMED=$(( MIGRATE_RENAMED + 1 ))
                printf '[migrate] 개명: %s → %s (구 섹션 제거, 설정은 새 섹션으로 이전)\n' \
                    "$disp_old" "$(sanitize_for_display "$reg_out")" >&2
                # CR-02: the target ALREADY existed and register re-registered
                # over it (the owned-same row of the collision table), so that
                # section's previous settings were replaced by this one's. Say so
                # -- the rename line above alone reads as if a new section had
                # been minted. The pre-migration .bak (taken above) is where the
                # replaced values still exist.
                if [[ "$target_existed" == "true" ]]; then
                    printf '[migrate] reason=target-overwritten %s → %s (기존 섹션의 설정이 대체되었습니다)\n' \
                        "$disp_old" "$disp_new" >&2
                fi
            else
                CSG_RENAME_NOTICE=""
                MIGRATE_SKIPPED=$(( MIGRATE_SKIPPED + 1 ))
                # WR-08: TRANSIENT, and the WORST of the three -- `register` has
                # already created csg-<name>, so the machine is left with BOTH
                # the old section and the new one, pointing at the same account.
                # Writing the completion marker here would guarantee migrate
                # never revisits that duplication.
                MIGRATE_TRANSIENT_FAILURES=$(( MIGRATE_TRANSIENT_FAILURES + 1 ))
                printf '[migrate] reason=delete-failed %s\n' "$disp_old" >&2
            fi
            continue
        fi

        # Abort. register left ~/.aws/config byte-identical, so the old section
        # is still there and still working -- which is exactly what D-07 asks
        # for. Report, count, and carry on with the rest of the fleet.
        token=$(sed -n 's/^\[register\] reason=//p' "$err_file" | head -1)
        rm -f "$err_file"
        [[ -n "$token" ]] || token="register-failed"
        MIGRATE_SKIPPED=$(( MIGRATE_SKIPPED + 1 ))
        if [[ "$target_existed" == "true" ]]; then
            printf '[migrate] reason=name-collision %s → %s (register=%s)\n' "$disp_old" "$disp_new" "$token" >&2
        else
            printf '[migrate] reason=%s %s\n' "$token" "$disp_old" >&2
        fi
    done

    # ---- Summary (D-01/D-02) ----
    # Bounded on purpose: one line per profile plus a fixed tail. This runs on
    # the credential_process hot path on the first post-update invocation.
    # Profile names come from a file this script does not own, so every one of
    # them goes through sanitize_for_display before it reaches a terminal or a
    # CI log (T-23-31). Key NAMES and profile names only -- never key values.
    local i
    for (( i=0; i<MIGRATE_RENAMED; i++ )); do
        disp_old=$(sanitize_for_display "${renamed_old[$i]}")
        disp_new=$(sanitize_for_display "${renamed_new[$i]}")
        printf '[migrate] %s → %s\n' "$disp_old" "$disp_new" >&2
    done

    printf '[migrate] rewritten=%d\n' "$MIGRATE_RENAMED" >&2
    printf '[migrate] repaired=%d\n' "$MIGRATE_REPAIRED" >&2
    printf '[migrate] skipped=%d\n' "$MIGRATE_SKIPPED" >&2
    if [[ -f "$CSG_BACKUP_SESSION" ]]; then
        printf '[migrate] backup=%s\n' "$CSG_BACKUP_SESSION" >&2
    fi
    # Pitfall 5: the agent is holding the OLD names in its conversation context
    # and will keep issuing `aws --profile <old>` unless it is told, in the same
    # breath as the mapping table, that those names no longer exist.
    if (( MIGRATE_RENAMED > 0 )); then
        printf '[migrate] 지금부터는 위 표의 새 이름을 쓰세요. 예전 이름으로 "aws --profile <구명>" 을 호출하면 실패합니다.\n' >&2
    fi
    if (( MIGRATE_REPAIRED > 0 )); then
        printf '[migrate] 복구한 섹션은 "aws sso login --profile <프로필>" 로 로그인이 아직 유효한지 확인하세요.\n' >&2
    fi

    return 0
}

# run_migration_once
# The idempotent entry point. Safe to call from anywhere, in any order relative
# to sweep -- it takes the SAME lock sweep does, so the two can never rewrite
# ~/.aws/config concurrently (T-23-29).
run_migration_once() {
    # (1) Completion marker FIRST -- before the lock and before ~/.aws/config is
    #     opened. Steady-state cost is one grep on a small file.
    if migration_completed; then
        printf '[migrate] status=already-migrated\n' >&2
        return 0
    fi

    local config_file="${HOME}/.aws/config"
    if [[ ! -f "$config_file" ]]; then
        printf '[migrate] ~/.aws/config 가 없습니다 — 마이그레이션 대상 없음.\n' >&2
        record_migration_completed 0 0 0
        return 0
    fi

    # (2) The SHARED sweep lock, not a second one. A private migrate lock would
    #     let sweep and migrate interleave two rewrites of the same file.
    #     Non-blocking: losing the race returns 0 in silence, because the work is
    #     idempotent and the next invocation will pick it up.
    # WR-09: the SAME file-shaped lock sweep takes -- see acquire_sweep_lock.
    local lock_file="${CACHE_DIR}/.sweep.lock"
    acquire_sweep_lock "$lock_file" || return 0
    trap 'release_sweep_lock "$lock_file"' RETURN

    # (3) FAIL CLOSED. AWS_CONFIG_FILE is pinned so the verdict is about the file
    #     migrate would actually rewrite, never whatever the ambient environment
    #     resolves. NO marker is written on this branch (Pitfall 7).
    local list_rc=0
    (
        export AWS_CONFIG_FILE="$config_file"
        unset AWS_PROFILE AWS_DEFAULT_PROFILE
        aws configure list-profiles
    ) >/dev/null 2>&1 || list_rc=$?
    if (( list_rc != 0 )); then
        migrate_abort_unparseable "$list_rc"
        return 1
    fi

    # (4) The work itself.
    do_migrate

    # (5) Record completion -- but ONLY when nothing failed TRANSIENTLY.
    #
    #     WR-08: D-07 asks for the marker to be written on a name-collision, and
    #     that is right: the old section is untouched and still works, and no
    #     number of retries will free the occupied target, so re-arming the
    #     migration would loop forever. The same is true of account-mismatch and
    #     no-account-id -- all three are PERMANENT verdicts.
    #
    #     delete-failed / repair-failed / marker-backfill-failed / carry-failed
    #     are NOT verdicts, they are failed writes. delete-failed is the worst:
    #     it is reached AFTER `register` created csg-<name>, so the machine is
    #     left with X and csg-X both present and both pointing at the same
    #     account -- and the marker would guarantee migrate never revisits it.
    if (( MIGRATE_TRANSIENT_FAILURES == 0 )); then
        record_migration_completed "$MIGRATE_RENAMED" "$MIGRATE_REPAIRED" "$MIGRATE_SKIPPED"
    else
        printf '[migrate] 마커를 기록하지 않았습니다 — 다음 실행에서 재시도합니다 (일시적 실패 %d건)\n' \
            "$MIGRATE_TRANSIENT_FAILURES" >&2
    fi
    return 0
}

# --- scope brake helpers (SCP-05) ---
#
# PLACEMENT IS LOAD-BEARING. test/credentials-guard.test.sh extracts everything
# between the literal comments "# --- Profile cleanup helpers ---" and
# "# --- Subcommand routing" and `source`s it in a subshell. This section is
# deliberately OUTSIDE that range: a top-level statement placed inside it would
# be EXECUTED by that harness with $1 unset. Everything below is a function
# definition and nothing else, and neither marker comment may be reworded.
#
# FAIL-OPEN BY CONSTRUCTION. Every reader here answers empty/zero with rc 0 on a
# missing, empty, truncated or garbage state file and never aborts under
# `set -euo pipefail` (active file-wide). The state is local, agent-owned and
# disposable; killing a legitimate single-account issuance because of a corrupt
# local file is strictly worse than missing one fan-out (CLAUDE.md Core Value).
#
# STDOUT DISCIPLINE. On the credential_process path stdout is the 5-key JSON
# contract and nothing else. The readers below print to stdout ONLY as their
# command-substitution return channel and are never called outside `$( )`;
# scope_window_append, scope_prune_window and scope_refuse write to stdout on no
# path at all.

# acquire_scope_lock <lock_file>   -> rc 0 acquired, rc 1 not acquired
# release_scope_lock <lock_file>   -> always rc 0
#
# Thin delegations to the SHIPPED sweep lock, not a second copy of it.
# acquire_sweep_lock has four properties that took Phase 23 WR-09 to get right:
#   1. a leftover DIRECTORY at the path is pre-Phase-23 residue -- `rm -rf`d,
#      never treated as held;
#   2. `( set -o noclobber; printf '%s' "$$" > "$lock_file" )` is the O_EXCL
#      acquire, producing the same filesystem object the PowerShell twin creates;
#   3. a LIVE pid in the file is the only thing that counts as "held";
#   4. an EMPTY file counts as held only until it is a minute old, because the
#      pwsh twin creates the file and writes its pid as two separate steps.
# A second 45-line copy of that IS the WR-09 failure class. So the shape is
# reused BY CALL and the path is passed through from the caller -- "copy the
# shape, not the path" in its strongest form. Only the path differs, and it
# differs because .sweep.lock is held across whole config rewrites (see
# SCOPE_LOCK above).
#
# The PowerShell twin (24-03) will NOT be able to delegate: Lock-Sweep parks its
# handle in the script-scoped singletons $script:SweepLockStream /
# $script:SweepLockPath, and a brake prune running while a sweep holds its lock
# would clobber the sweep's handle. That client therefore mints
# $script:ScopeLockStream/$script:ScopeLockPath and copies the body. The two
# clients differ in code and agree in behaviour; PARITY-SCOPE-CONST pins the
# shared ".scope.lock" literal so they cannot drift apart on the path.
#
# CALLING CONTRACT: acquire_scope_lock MUST always be invoked in a conditional
# context -- `acquire_scope_lock "$SCOPE_LOCK" || return 0`. Under `set -e` an
# unconditional call aborts the whole script when the delegate's internal
# `kill -0 "$holder" && return 1` list evaluates false; bash suppresses `set -e`
# inside a function only while that function is being evaluated as a condition.
# Every shipped acquire_sweep_lock call site already honours this.
acquire_scope_lock() {
    acquire_sweep_lock "$1"
}

release_scope_lock() {
    release_sweep_lock "$1"
}

# scope_window_append <account_id>
# Appends exactly ONE line -- {"ts":<epoch>,"accountId":"<12 digits>"} -- and
# returns 0 on every path, writing nothing to stdout. One line per NEW-ISSUANCE
# ATTEMPT (D-01), which is why the caller 24-02 adds sits BEFORE the curl retry
# loop: a 503-then-200 recovery is one attempt, not three.
#
# No `acked` field. Acked-ness is derived at READ time by intersecting with the
# ack set, so there is never a write-then-update window where a record is on disk
# with a value that is already wrong.
#
# T-24-08: the argument is re-validated against ^[0-9]{12}$ HERE, at the write
# boundary. The main flow already validates --account-id at the input gate, but
# re-validating means no unvalidated byte can reach the record no matter which
# caller is added later; an invalid argument writes nothing and still returns 0.
#
# printf, never jq. 24-02's `scope-ack` routing block is the first subcommand in
# this file with zero external-binary dependency, so the append path must not
# smuggle a jq requirement into it. Every field written here is either an epoch
# this function just read or a 12-digit id it just validated -- there is no
# interpolation surface, which is the same rule record_migration_completed's
# printf fallback relies on (unlike record_and_warn_skip, whose profile names are
# attacker-influenceable and genuinely need jq).
#
# WR-01: the redirection is INSIDE the brace group and the whole group's stderr
# is discarded. `printf ... >> "$F" 2>/dev/null` alone only silences printf -- the
# SHELL's own "No such file or directory" for the append target is emitted first
# and would leak a raw, un-prefixed, $HOME-revealing line onto the
# credential_process path's stderr.
#
# T-24-09: this function deliberately does NOT create CACHE_DIR. The main flow
# already does `mkdir -p` + `chmod 700`, and 24-02's routing block must do the
# same. Creating the directory here without that chmod is the
# information-disclosure bug, not a fix.
scope_window_append() {
    local account_id="${1:-}"
    [[ "$account_id" =~ ^[0-9]{12}$ ]] || return 0

    local now
    now=$(date -u +%s 2>/dev/null) || now=0
    [[ "$now" =~ ^[0-9]+$ ]] || now=0

    { printf '{"ts":%s,"accountId":"%s"}\n' "$now" "$account_id" \
        >> "$SCOPE_WINDOW_RECORD"; } 2>/dev/null || true
    return 0
}

# scope_window_ids <cutoff_epoch> <ack_csv>
# stdout: "id,id,id" -- the DISTINCT accountIds recorded at or after
# <cutoff_epoch> that are not in <ack_csv>, in first-seen (append/chronological)
# order. Prints the empty string when the file is absent or nothing qualifies.
#
# This function is one beyond the outline's frozen entry-point list. It exists so
# that the count and the refusal message's account list come from a SINGLE parse.
# 24-03 must mirror it as Get-ScopeWindowIds.
#
# WHERE THAT PROPERTY IS ACTUALLY ENFORCED (WR-03, corrected). It was never a
# property of this helper alone -- it is a property of the CALLER. This function
# and scope_window_distinct each read the file correctly, and the main-flow brake
# block used to call BOTH, so the shipped hot path read scope-window.jsonl TWICE
# with an unserialised append window in between. The claim previously written
# here, that a mismatched refusal was "structurally impossible", was true of the
# helpers and false of the caller that used them.
# It is now enforced where it belongs: the brake block derives its count from the
# CSV this function returns, so "승인되지 않은 계정 N개" and the id list beside it
# are computed from ONE string and cannot disagree. The consequence that
# motivated the fix is not cosmetic -- the second parse could return a list
# missing an id the first one had counted, and that list is what the
# copy-pasteable `scope-ack --account-ids` retry line carries, so the user pastes
# the command the tool printed and is refused again.
#
# A fixed regex is a complete parser here: both fields are machine-owned (an
# epoch this file wrote and a 12-digit id it validated first). That is what makes
# it different from guard-skips.jsonl, whose `section` field carries
# attacker-influenceable profile names and needs jq (WR-02).
#
# Two portability constraints, both load-bearing on macOS's awk:
#   * no `length(array)` -- that is a gawk/POSIX-2008 extension; the count and the
#     order come from an explicit counter plus an indexed array;
#   * no ERE interval such as {12} inside the awk program -- id shape is checked
#     with length(x) == 12 plus a ^[0-9]+$ match. sed -E intervals are fine and
#     are already used elsewhere in this file.
#
# Fail-open: `out=$( … ) || out=""` with `local out` declared on its own line
# first. `local out=$( … )` would MASK the pipeline's exit status, which is the
# opposite of what is wanted here -- the status has to be visible so it can be
# swallowed deliberately rather than by accident.
scope_window_ids() {
    local cutoff="$1" ack_csv="$2"
    [[ -f "$SCOPE_WINDOW_RECORD" ]] || { printf ''; return 0; }

    local out
    out=$(
        sed -nE 's/^\{"ts":([0-9]+),"accountId":"([0-9]{12})".*$/\1 \2/p' \
            "$SCOPE_WINDOW_RECORD" 2>/dev/null \
        | awk -v c="$cutoff" -v acks=",${ack_csv}," '
            ($1 + 0) >= (c + 0) && length($2) == 12 && $2 ~ /^[0-9]+$/ \
                && index(acks, "," $2 ",") == 0 {
                if (!($2 in seen)) { seen[$2] = 1; n = n + 1; order[n] = $2 }
            }
            END {
                s = ""
                for (i = 1; i <= n; i = i + 1) {
                    if (i == 1) { s = order[i] } else { s = s "," order[i] }
                }
                printf "%s", s
            }
          '
    ) || out=""

    printf '%s' "$out"
}

# scope_window_distinct <cutoff_epoch> <ack_csv>
# stdout: the decimal count of the ids scope_window_ids would list. "0" when the
# window file is missing, empty or unparseable.
#
# Derived from scope_window_ids rather than from a second parse -- see that
# function's note on why the count and the list must not be able to disagree.
#
# NOT CALLED FROM THE MAIN FLOW (WR-03). The brake block derives its count inline
# from scope_window_ids so the hot path reads the window file once. This helper
# stays defined and exported deliberately: it is a frozen entry-point name that
# PARITY-SCOPE-* and the unit-level cases call directly, and deleting it would be
# a larger change than the defect. Keep the two derivations byte-identical -- if
# this one ever changes, change the caller's inline copy in the same commit.
#
# Pitfall 1: never `grep -c` (rc 1 on zero matches) and never `(( n++ ))` (rc 1
# when the pre-value is 0). Both fire on the MOST COMMON path -- a fresh machine
# with no window file at all -- and under `set -euo pipefail` that would kill a
# legitimate single-account issuance before the broker POST, with no message.
# Neither shape is caught by the linter at --severity=error, so the gate for them
# is the static grep in 24-05, not CI.
scope_window_distinct() {
    local cutoff="$1" ack_csv="$2"
    local ids n

    ids=$(scope_window_ids "$cutoff" "$ack_csv") || ids=""
    if [[ -z "$ids" ]]; then
        printf '0'
        return 0
    fi

    n=$(printf '%s\n' "$ids" | awk -F, '{ print NF }') || n=0
    [[ "$n" =~ ^[0-9]+$ ]] || n=0
    printf '%s' "$n"
}

# scope_ack_set <now_epoch>
# stdout: the comma-joined UNION of accountIds across every scope-acks.jsonl
# record whose expiresAt > now, deduped, in first-seen order. Empty string when
# the file is absent or every record has expired.
#
# D-06/A2/A3, all three parts stated because each one is a decision:
#   * UNION, not "latest record replaces". The ack file is append-only with no
#     tombstone, which is exactly what makes resume-after-failure (D-16) work
#     without asking the user to approve the same list a second time.
#   * The honest downside: an agent can widen the set incrementally with repeated
#     small `scope-ack` calls. Each such call is still a separate transcript
#     artifact and a separate local audit line -- friction and a record, which is
#     the entire value proposition here, and the reason the real backstop is
#     server-side (Phase 25 DET-01).
#   * Acked accounts are excluded from the count ENTIRELY, not merely exempted
#     from refusal. Otherwise a legitimately approved 12-account batch would sit
#     in the window and block an unrelated 13th account for the next 5 minutes.
#
# Same guards as scope_window_ids: [[ -f … ]] first, `local out` then assign, no
# length(array), no awk ERE interval, and a swallowed pipeline status.
scope_ack_set() {
    local now="$1"
    [[ -f "$SCOPE_ACK_RECORD" ]] || { printf ''; return 0; }

    local out
    out=$(
        sed -nE 's/^\{"ts":[0-9]+,"expiresAt":([0-9]+),"accountIds":\[([^]]*)\].*$/\1 \2/p' \
            "$SCOPE_ACK_RECORD" 2>/dev/null \
        | awk -v now="$now" '
            {
                if (($1 + 0) <= (now + 0)) next
                ids = substr($0, index($0, " ") + 1)
                gsub(/[^0-9,]/, "", ids)
                cnt = split(ids, parts, ",")
                for (i = 1; i <= cnt; i = i + 1) {
                    id = parts[i]
                    if (length(id) == 12 && id ~ /^[0-9]+$/ && !(id in seen)) {
                        seen[id] = 1; n = n + 1; order[n] = id
                    }
                }
            }
            END {
                s = ""
                for (i = 1; i <= n; i = i + 1) {
                    if (i == 1) { s = order[i] } else { s = s "," order[i] }
                }
                printf "%s", s
            }
          '
    ) || out=""

    printf '%s' "$out"
}

# scope_prune_window <cutoff_epoch>
# Best effort, always rc 0, writes nothing to stdout. This is the ONLY locked
# section in the brake.
#
# D-17, stated in full so this is not read as a deviation: the append is
# deliberately UNLOCKED and happens before any count is read (append-then-count).
# A lock-first design would have to fail open on every contended invocation --
# which is precisely the hole D-17 exists to close, since a fan-out is exactly
# the situation in which the lock IS contended. Losing this lock therefore never
# means the verdict was wrong; it only means the file keeps a few stale lines,
# which the cutoff filter ignores anyway.
#
# Pitfall 2 disappears by construction with this shape. sweep_expired_profiles
# releases its lock with a RETURN trap, and a RETURN trap does NOT fire on
# `exit`; a lock taken around a checking function whose refusal path exits would
# be abandoned on disk for the next invocation to reclaim. That is why the lock
# wraps ONLY the prune: there is no die, no exit, and no early return between the
# acquire and the release.
#
# The temp file is "${SCOPE_WINDOW_RECORD}.XXXXXX", i.e. "scope-window.jsonl.aB3xY"
# -- no ".json" suffix, so an interleaved `cleanup --all` cannot eat it
# mid-rewrite. Same property TMP_CACHE relies on for the credential cache write.
#
# NO-OP GUARD (a deliberate divergence from the reference implementation): when
# NOTHING in the record is stale, the temp file is removed and the `mv` is
# skipped entirely. The append path is unlocked, so a sibling that already holds
# the record open for append loses its write to the pre-`mv` inode -- and it is
# not one write, it is EVERY append that lands after this awk reached EOF. When
# nothing is actually stale the rewrite changes nothing and would take that risk
# for zero benefit. In steady state -- every record inside the window -- no `mv`
# ever happens and the race does not exist.
#
# BOTH COUNTS MUST COME FROM THE SAME READ. This is the defect the shape below
# fixes, and it is worth stating because the guard LOOKED correct. It used to be
# `wc -l < "$tmp"` compared against `wc -l < "$SCOPE_WINDOW_RECORD"` -- a
# snapshot taken when awk hit EOF, compared against a RE-COUNT of the live file
# one `wc` fork later. With an unlocked append, a single sibling writing in that
# gap makes kept != total even when the stale count is exactly zero. The guard
# then missed, the `mv` fired, and it discarded every record appended since awk's
# EOF. That is why the observed loss was 5-8 records out of 12 rather than the
# "one sibling loses one record" this comment used to claim: one `mv` clobbers
# the whole gap, and the lock only serialises the pruners, so each one repeats it
# in turn. It presented as Linux-only purely because a faster fork/exec widens
# the overlap -- raising the parallelism to 48 reproduces it on macOS.
#
# So awk now counts the lines it READ and the lines it KEPT in a single pass and
# returns their difference, which is the true stale count. A number derived from
# one read cannot be moved by a concurrent append. This is also precisely what
# the PowerShell twin's guard already did (`$kept.Count -eq $lines.Count`, both
# from one Get-Content), so the two clients agree again; the split into two reads
# was introduced by this port and by nothing else.
#
# awk writes the kept lines itself via `print > out` rather than the caller
# redirecting stdout, because stdout is now the return channel for the count.
# `print > expr` is POSIX awk core, not a gawk extension -- verified on mawk
# 1.3.4 (the Linux CI awk) and BWK awk 20200816 (macOS) -- so it does not join
# `length(array)` and ERE intervals on this file's list of awk features to avoid.
#
# FAIL-OPEN DIRECTION, CORRECTED. An unreadable file or a dead awk yields an
# empty count, which now SKIPS the `mv`. The old guard fell through to its `else`
# on exactly that failure and overwrote the record with a possibly-empty temp
# file -- the opposite of this section's stated fail-open rule. Not pruning
# leaves stale lines the cutoff filter ignores anyway; pruning wrongly destroys
# live evidence.
scope_prune_window() {
    local cutoff="$1"
    [[ -f "$SCOPE_WINDOW_RECORD" ]] || return 0

    acquire_scope_lock "$SCOPE_LOCK" || return 0

    local tmp
    tmp=$(mktemp "${SCOPE_WINDOW_RECORD}.XXXXXX") || { release_scope_lock "$SCOPE_LOCK"; return 0; }

    # stdout is the stale count; the kept lines go straight to "$tmp".
    local stale
    stale=$(awk -v c="$cutoff" -v out="$tmp" '
        {
            seen = seen + 1
            keep = 0
            if ($0 ~ /^\{"ts":[0-9]+,"accountId":"[0-9]+"\}$/) {
                ts = $0
                sub(/^\{"ts":/, "", ts)
                sub(/,.*$/, "", ts)
                id = $0
                sub(/^.*"accountId":"/, "", id)
                sub(/".*$/, "", id)
                if (length(id) == 12 && (ts + 0) >= (c + 0)) { keep = 1 }
            }
            if (keep == 1) { print > out; kept = kept + 1 }
        }
        END { printf "%d", (seen + 0) - (kept + 0) }
    ' "$SCOPE_WINDOW_RECORD" 2>/dev/null) || stale=""
    stale="${stale//[^0-9]/}"

    if [[ -z "$stale" || "$stale" == "0" ]]; then
        rm -f "$tmp" 2>/dev/null || true
    else
        mv "$tmp" "$SCOPE_WINDOW_RECORD" 2>/dev/null || rm -f "$tmp" 2>/dev/null || true
    fi

    release_scope_lock "$SCOPE_LOCK"
    return 0
}

# scope_refuse <distinct_count> <ids_csv>
# stderr only, then `exit 1`. Never returns. Writes zero bytes to stdout on every
# path (T-24-05) -- on the credential_process path stdout is the 5-key JSON
# contract and nothing else.
#
# THIS TEXT IS THE ERROR THE AGENT SEES. botocore's ProcessProvider pipes both
# streams; on a non-zero exit it raises
# CredentialRetrievalError(error_msg=<the entire stderr buffer>) and the AWS CLI
# prints that verbatim, wrapped as "Error when retrieving credentials from
# custom-process: …". On returncode == 0 stderr is discarded ENTIRELY, which is
# why "warn and proceed" is not an option here and why a refusal must always mean
# `exit 1` (Pitfall 3).
#
# It is also emitted LAST. On a non-zero exit the whole buffer is surfaced as one
# blob, so any [sweep]/[migrate]/[guard] line already written this invocation
# precedes it; putting the refusal at the end keeps the actionable instruction
# from being buried in the middle (Pitfall 4). The machine token goes first so a
# caller or a test can grep it without parsing the Korean prose (S1), and the
# final line is the literal retry command, copy-pasteable as-is.
#
# The message carries account ids and nothing else. They are already present in
# ~/.aws/config, and a credential_process tool must never put a secret on stderr.
scope_refuse() {
    local distinct="$1" ids_csv="$2"

    printf '[scope] reason=fan-out-threshold\n' >&2
    log "중단: 최근 ${SCOPE_WINDOW_SECONDS}초 안에 승인되지 않은 고객사 계정 ${distinct}개의 신규 발급이 감지되었습니다 (허용 ${SCOPE_MAX_ACCOUNTS}개)."
    log "윈도우 내 계정: ${ids_csv}"
    log "대상 목록을 사용자에게 확인받은 뒤 아래를 실행하고 같은 명령을 다시 실행하세요:"
    log "  get-customer-credentials.sh scope-ack --account-ids ${ids_csv}"
    exit 1
}

# --- scope-ack subcommand (SCP-05) ---
#
# PLACEMENT IS LOAD-BEARING. test/credentials-guard.test.sh extracts everything
# between the literal comments "# --- Profile cleanup helpers ---" and
# "# --- Subcommand routing" and `source`s it in a subshell. This section is
# deliberately OUTSIDE that range, for the same reason the brake helpers above
# are: a top-level statement placed inside it would be EXECUTED by that harness.
#
# BOUNDARY CHANGE -- read this before extracting the section above (24-04 /
# 24-05 / 24-07). The brake-helpers section 24-01 added used to be delimited on
# its lower side by the doctor-routing marker. It is now delimited by THIS
# marker, because this section sits between the two. Any later extraction of the
# brake helpers must use the scope-ack section marker on the line above as its
# END anchor, or it will pull do_scope_ack and scope_ack_die in with it and every
# region-scoped static gate will be measuring the wrong lines. No marker literal
# is quoted anywhere in this paragraph, deliberately: a quotation would double
# the substring count of an anchor that another plan greps for.
#
# STDOUT CONTRACT (scope-ack mode) -- distinct from the credential_process 5-key
# JSON contract declared in the file header, and from register's one-line one:
#   success -> exactly ONE line on stdout, containing no '{' and no '}'.
#   abort   -> stdout stays completely EMPTY; every diagnostic goes to stderr.
# The no-brace rule is structural, not cosmetic: this line has to be impossible
# to confuse with the 5-key JSON contract even if some future reader captures the
# wrong stream (T-24-05). scope-ack is never invoked from inside
# credential_process -- it is a separate, operator-driven invocation -- so the
# two contracts can never interleave.
#
# WHAT THIS IS, STATED PLAINLY. An agent can run scope-ack itself without asking
# the user. Nothing in this file stops that and nothing here is described as
# stopping it. What it buys is friction, one transcript artifact the agent has to
# quote back, and one durable local line in scope-acks.jsonl. The backstop that
# does not depend on the agent's cooperation is server-side (Phase 25 DET-01).

# scope_ack_die <reason_token> <msg>...
# Emits the machine-readable reason line FIRST -- so a caller or a test can grep
# it without parsing the Korean prose that follows (S1) -- then one
# "[scope-ack] <msg>" line per remaining argument, then exits 1. NEVER writes to
# stdout (abort contract: empty stdout). A direct clone of register_die.
# Tokens: invalid-account-id | invalid-arguments | write-failed
#
# `write-failed` is deliberately register_reason's EXISTING token rather than a
# new spelling for the same idea. It exists here at all because this handler's
# ack append is fail-CLOSED (see [8] below), unlike every other write in the
# brake, so it needs an abort token for a failed write -- and register already
# documents exactly that one. 24-04's PARITY-SCOPE-TOKENS list and 24-06's
# troubleshooting entry must both carry all three.
scope_ack_die() {
    local reason="$1"
    shift
    printf '[scope-ack] reason=%s\n' "$reason" >&2
    local msg
    for msg in "$@"; do
        printf '[scope-ack] %s\n' "$msg" >&2
    done
    exit 1
}

# do_scope_ack <args...>
# Records one explicit, time-limited approval covering >= 2 distinct customer
# accounts, so the fan-out brake below lets those accounts through for
# SCOPE_ACK_TTL_SECONDS. This is the ONLY override channel: the brake reads its
# verdict from scope-acks.jsonl and from nothing else -- there is no environment
# variable, no credential-broker.conf key and no flag on the credential path that
# can widen it (D-05, T-24-03).
#
# The step order below is itself a contract; 24-04 mirrors it step for step.
do_scope_ack() {
    local ids_csv=""

    # [1] argv. scope-ack consumes its own arguments; these flags must never
    # reach the main parser below, whose `*)` branch dies with the misleading
    # "알 수 없는 옵션" (Pitfall 2). Same `;;&` fallthrough missing-value guard as
    # do_register.
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --account-ids)
                [[ $# -ge 2 ]] || scope_ack_die "invalid-arguments" \
                    "중단: 옵션 '--account-ids' 에 값이 필요합니다."
                ;;&
            --account-ids)  ids_csv="$2"; shift 2 ;;
            --help|-h)      usage; exit 0 ;;
            *)
                scope_ack_die "invalid-arguments" \
                    "중단: scope-ack 가 모르는 인자입니다: $(sanitize_for_display "$1")" \
                    "사용법: get-customer-credentials.sh scope-ack --account-ids <12자리>,<12자리>[,...]"
                ;;
        esac
    done

    # [2] Split the CSV WITHOUT an array. `IFS=',' read -r -a arr` + "${arr[@]}"
    # is the obvious shape and it is the wrong one here: macOS ships bash 3.2,
    # where expanding an EMPTY array under `set -u` is a fatal error -- which is
    # precisely the `--account-ids ""` case this handler has to report cleanly.
    # The file already acknowledges that hazard with its [[ ${#arr[@]} -eq 0 ]]
    # guards in the sweep/cleanup helpers. `< <( )` keeps the loop in the CURRENT
    # shell, so scope_ack_die's `exit 1` really exits instead of killing only a
    # subshell. The `|| [[ -n "$elem" ]]` tail is what makes a value with no
    # trailing separator (the single-id case) reach the loop body at all.
    local uniq_csv=""
    local n=0
    local elem=""
    while IFS= read -r elem || [[ -n "$elem" ]]; do
        # [3] Validate EVERY element BEFORE dedupe, BEFORE the >= 2 check and
        # before it reaches any record, message or shell word (T-24-08). Same
        # shape the main parser, do_register and the broker all enforce. This
        # ordering is an acceptance criterion, not a style preference: it is what
        # makes `--account-ids 1,2` report invalid-account-id instead of
        # invalid-arguments. The offending token goes through
        # sanitize_for_display before it reaches a terminal or a CI log.
        if [[ ! "$elem" =~ ^[0-9]{12}$ ]]; then
            scope_ack_die "invalid-account-id" \
                "중단: 유효하지 않은 계정 ID (12자리 숫자만 허용): '$(sanitize_for_display "$elem")'" \
                "승인 기록은 남지 않았습니다."
        fi

        # [4] Dedupe, first-seen order. Every survivor is known to be 12 digits,
        # so a substring membership test is a COMPLETE implementation -- bash 3.2
        # has no associative arrays. The counter is n=$((n + 1)), never
        # (( n++ )), which returns 1 when the pre-value is 0 and would abort the
        # handler on the very first id under `set -e` (Pitfall 1).
        case ",${uniq_csv}," in
            *",${elem},"*) continue ;;
        esac
        if [[ -z "$uniq_csv" ]]; then
            uniq_csv="$elem"
        else
            uniq_csv="${uniq_csv},${elem}"
        fi
        n=$((n + 1))
    done < <(printf '%s' "$ids_csv" | tr ',' '\n')

    # [5] Require >= 2 DISTINCT ids, with no upper cap. This single check absorbs
    # three inputs: an empty value, a single id, and a list that collapses to one
    # after dedupe. Two alternatives were considered and rejected (RESEARCH
    # A7/A8): a one-account ack is meaningless because the brake never fires for
    # a single account, and an upper cap would only force the agent to split one
    # approval into two -- a second failure mode bought for no safety gain.
    if (( n < 2 )); then
        scope_ack_die "invalid-arguments" \
            "중단: --account-ids 에는 서로 다른 계정 ID 가 2개 이상 필요합니다 (현재 ${n}개)." \
            "1개 계정 작업에는 브레이크가 걸리지 않으므로 승인이 필요하지 않습니다."
    fi

    # [6] Epoch. Unlike every READER in the brake, this path must NOT fail open.
    # An ack written with a bogus expiry is an approval that silently does not
    # work: the command reports success and the agent still hits a refusal at
    # account 6 with no way to connect the two.
    local now expires
    now=$(date -u +%s 2>/dev/null) || now=0
    [[ "$now" =~ ^[1-9][0-9]*$ ]] || scope_ack_die "write-failed" \
        "중단: 시스템 시각을 읽지 못해 승인 기록의 만료 시각을 계산할 수 없습니다."
    expires=$((now + SCOPE_ACK_TTL_SECONDS))

    # [7] Human-readable expiry -- DISPLAY ONLY, never fatal. The same GNU-vs-BSD
    # ladder emit_from_cache runs for ISO->epoch, run here in the opposite
    # direction: GNU coreutils spells it `date -d @<epoch>`, BSD/macOS spells it
    # `date -r <epoch>`, and neither accepts the other's flag. If both fail the
    # record is still written and only the displayed string degrades to a raw
    # epoch. Note for 24-03/24-04: the PowerShell twin needs no ladder at all --
    # [DateTimeOffset]::FromUnixTimeSeconds() is native.
    local expires_iso
    if expires_iso=$(date -u -d "@${expires}" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null); then
        :
    elif expires_iso=$(date -u -r "${expires}" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null); then
        :
    else
        expires_iso="epoch-${expires}"
    fi

    # [8] Append exactly ONE record, fail-CLOSED. Built with printf over digits
    # this function just validated, so there is no interpolation surface; the
    # routing block below is this file's first subcommand with ZERO
    # external-binary dependency, and calling a JSON tool here would quietly put
    # one back on precisely the machine least likely to have it (RESEARCH A7).
    # The array is a flat list of quoted 12-digit strings and nothing else,
    # because 24-01's scope_ack_set captures the bracket contents and keeps only
    # length-12 digit elements.
    #
    # WR-01: the redirection goes INSIDE the brace group and the whole group's
    # stderr is discarded. `printf ... >> "$F" 2>/dev/null` alone only silences
    # printf -- the SHELL's own "No such file or directory" for the append target
    # is emitted first, raw, un-prefixed and $HOME-revealing.
    #
    # ASYMMETRY WITH scope_window_append, which ends in `|| true`. Losing a
    # WINDOW record under-counts the brake, which is the safe direction. Losing
    # an ACK record makes this command report an approval that does not exist,
    # and the agent then meets an unexplained refusal at account 6 with a
    # transcript that says the range was approved. That is the unsafe direction,
    # so this is the one write in the brake that is fail-closed.
    local ids_json="\"${uniq_csv//,/\",\"}\""
    local line
    line=$(printf '{"ts":%s,"expiresAt":%s,"accountIds":[%s],"count":%s}' \
        "$now" "$expires" "$ids_json" "$n")
    if ! { printf '%s\n' "$line" >> "$SCOPE_ACK_RECORD"; } 2>/dev/null; then
        scope_ack_die "write-failed" \
            "중단: 승인 기록을 저장하지 못했습니다: ${SCOPE_ACK_RECORD}" \
            "승인은 적용되지 않았습니다. 디스크 여유 공간과 권한을 확인한 뒤 다시 실행하세요."
    fi

    # [9] stdout -- exactly one line, no '{' and no '}' (see the STDOUT CONTRACT
    # paragraph at the top of this section). The literal prefix "scope-ack: " is
    # FROZEN: 24-04's PARITY-SCOPE-ROUTE pins the routing branch, the handler and
    # this stdout shape together, because proving that the string "scope-ack"
    # appears somewhere in a file proves nothing at all.
    printf 'scope-ack: %s accounts approved until %s\n' "$n" "$expires_iso"

    # [10] stderr -- exactly ONE [scope-ack] line (D-07: 로컬 jsonl 기록과 stderr
    # 1줄이 전부). Bare printf, not log: log prefixes "[get-customer-credentials]"
    # and the prefix has to match the reason token's, which is the same reason the
    # doctor and migrate routing blocks use bare printf. One line carries the
    # count, the expiry and the id list; do not add a second summary line.
    printf '[scope-ack] %s개 계정 범위 승인 기록 — 만료 %s — 계정: %s\n' \
        "$n" "$expires_iso" "$uniq_csv" >&2

    return 0
}

# --- doctor subcommand routing (must be before --flag parsing, D-01) ---
if [[ "${1:-}" == "doctor" ]]; then
    shift
    # Pitfall 10: deliberately NOT require_cmds -- that gate hardcodes curl and
    # jq, and doctor makes no network call and parses no JSON. Same rationale as
    # register's gate.
    if ! command -v aws >/dev/null 2>&1; then
        printf '[doctor] reason=missing-dependency\n' >&2
        doctor_log "중단: 'aws' 명령이 설치되어 있지 않습니다. 키 제거는 사후검증 없이 수행하지 않습니다."
        exit 1
    fi
    # WR-01: the `cleanup` and `migrate` routing blocks both do this; `doctor` did
    # not. do_doctor reaches record_and_warn_skip, which APPENDS to
    # ${CACHE_DIR}/guard-skips.jsonl -- and the `2>/dev/null` there covers jq's
    # stderr, not the SHELL's own redirection failure, which is emitted first. On
    # a first-ever doctor run that printed a raw, un-prefixed, $HOME-revealing
    # "No such file or directory" and silently dropped the D-04/D-06 audit record
    # on the machine that most needs it.
    mkdir -p "$CACHE_DIR"
    chmod 700 "$CACHE_DIR" 2>/dev/null || true
    do_doctor
    exit $?
fi

# --- migrate subcommand routing (must be before --flag parsing, D-01) ---
if [[ "${1:-}" == "migrate" ]]; then
    shift
    # Pitfall 10: deliberately NOT require_cmds -- that gate hardcodes curl and
    # jq, and migrate makes no network call and parses no JSON it did not write
    # itself. Same rationale as register's and doctor's gates.
    if ! command -v aws >/dev/null 2>&1; then
        printf '[migrate] reason=missing-dependency\n' >&2
        printf '[migrate] 중단: aws 명령이 설치되어 있지 않습니다. 확인 없이 프로필을 바꾸지 않습니다.\n' >&2
        exit 1
    fi
    mkdir -p "$CACHE_DIR"
    chmod 700 "$CACHE_DIR" 2>/dev/null || true
    migrate_rc=0
    run_migration_once || migrate_rc=$?
    exit "$migrate_rc"
fi

# --- register subcommand routing (must be before --flag parsing, D-01) ---
if [[ "${1:-}" == "register" ]]; then
    shift
    # Pitfall 10: deliberately NOT require_cmds -- that gate hardcodes curl and
    # jq, and register makes no network call and parses no JSON.
    command -v aws >/dev/null 2>&1 || register_die "missing-dependency" "중단: 'aws' 명령이 설치되어 있지 않습니다."
    do_register "$@"
    exit $?
fi

# --- scope-ack subcommand routing (must be before --flag parsing, D-01) ---
if [[ "${1:-}" == "scope-ack" ]]; then
    shift
    # Pitfall 10, taken one step past doctor/migrate/register. This block is
    # deliberately NOT require_cmds -- that gate hardcodes curl and jq -- AND it
    # deliberately has no `command -v aws` gate either. scope-ack makes no
    # network call, parses no JSON it did not write itself, and never touches
    # ~/.aws/config. It is the FIRST subcommand in this file with ZERO
    # external-binary dependency, and there is no precedent for that here, so it
    # is stated outright: adding a binary gate would break scope-ack on exactly
    # the machine where the agent most needs to record an approval.
    #
    # WR-01 / T-24-09: do_scope_ack APPENDS to ${CACHE_DIR}/scope-acks.jsonl, and
    # the 2>/dev/null there covers printf's own stderr, not the SHELL's
    # redirection failure, which is emitted first -- on a first-ever scope-ack
    # that is a raw, un-prefixed, $HOME-revealing "No such file or directory",
    # and the approval is silently lost on the machine that most needs it. The
    # chmod 700 is what keeps the approval record from being world-readable on a
    # shared machine; 24-01 deliberately did NOT create CACHE_DIR from inside its
    # helpers so that this pair could never be separated from the directory
    # creation.
    mkdir -p "$CACHE_DIR"
    chmod 700 "$CACHE_DIR" 2>/dev/null || true
    do_scope_ack "$@"
    exit $?
fi

while [[ $# -gt 0 ]]; do
    case "$1" in
        --account-id|--agent|--region|--session-name)
            [[ $# -ge 2 ]] || die "옵션 '$1'에 값이 필요합니다"
            ;;&
        --account-id)             ACCOUNT_ID="$2"; shift 2 ;;
        --agent)                  AGENT_NAME="$2"; shift 2 ;;
        --region|--session-name)  shift 2 ;;   # backward-compat no-op (no local assume; broker owns region/identity)
        --help|-h)                usage; exit 0 ;;
        *)                        die "알 수 없는 옵션: $1" ;;
    esac
done

# --- Agent detection from script install path (FINAL fallback only) ---
# The install path ($0) is FIXED per customer profile — it reflects whichever
# agent CREATED the profile, not the agent actually running now. When several
# agents share a profile, this mapping mis-attributes every caller to the
# creator, so it is used ONLY after the runtime-env signals below fail.
detect_agent_from_path() {
    local script_path="$1"
    case "$script_path" in
        */.claude/*)            echo "claude-code" ;;
        */.config/opencode/*)   echo "opencode" ;;
        */.kiro/*)              echo "kiro" ;;
        */.cursor/*)            echo "cursor" ;;
        */.codeium/windsurf/*)  echo "windsurf" ;;
        */.augment/*)           echo "augment" ;;
        */.agents/*)            echo "codex" ;;
        */.gemini/*)            echo "gemini" ;;
        */.hermes/*)            echo "hermes" ;;
        *)                      echo "unknown" ;;
    esac
}

# --- KNOWN CSG agent ids (single source; gates the env-signal layers below) ----
# The 9 agents this skill installs into. The TERM_PROGRAM / __CFBundleIdentifier
# layers below accept a runtime value ONLY if it is a member of this set, so a
# generic terminal (TERM_PROGRAM=vscode/iterm/apple_terminal, or a non-agent
# bundle id) never mis-maps to an audit-subject label.
readonly -a KNOWN_AGENTS=(claude-code opencode kiro cursor windsurf augment codex gemini hermes)

# is_known_agent <candidate> — returns 0 iff <candidate> is one of the 9 CSG agent ids.
is_known_agent() {
    local needle="$1" a
    for a in "${KNOWN_AGENTS[@]}"; do
        [[ "$a" == "$needle" ]] && return 0
    done
    return 1
}

# --- Layered RUNTIME agent detection (first hit wins) -------------------------
# Resolves the AI agent ACTUALLY invoking this credential_process, so the audit
# trail reflects the real caller rather than the install that created the shared
# profile. Priority:
#   1. explicit --agent <name>  (handled before this fn; deliberate override)
#   2. $MSP_AGENT           (explicit session override an operator/SKILL sets)
#   3. $AI_AGENT                 (leading token before the FIRST '_', lowercased)
#   4. $CLAUDECODE               (Claude Code sets this even when AI_AGENT is absent)
#   5. $TERM_PROGRAM             (VSCode-fork agents that inject NO custom var, e.g.
#                                 Kiro sets TERM_PROGRAM=kiro; KNOWN-AGENT-gated)
#   6. $__CFBundleIdentifier     (macOS backup: dev.<name>.desktop/.app; KNOWN-gated)
#   7. detect_agent_from_path    (install-path mapping; frozen per profile)
# $MSP_AGENT is a deliberate override: passed through verbatim so the SAME
# ^[a-z0-9-]{1,32}$ validation below rejects (→ die) a malformed value.
# $AI_AGENT, $TERM_PROGRAM and $__CFBundleIdentifier are auto-detected signals:
# their extracted value is used ONLY if it passes its check (charset for AI_AGENT;
# KNOWN_AGENTS membership for the two new layers); otherwise resolution falls
# through to the next layer rather than mis-stamping the audit subject.
detect_agent() {
    local candidate

    # 2. Explicit session override (validated downstream; may die if malformed).
    if [[ -n "${MSP_AGENT:-}" ]]; then
        echo "${MSP_AGENT}"
        return 0
    fi

    # 3. AI_AGENT: take the leading token before the FIRST '_', lowercased.
    #    e.g. "claude-code_2-1-204_agent" → "claude-code"; "kiro_9-9_agent" → "kiro";
    #    a value with no '_' is used whole. Accepted only if it matches the charset.
    if [[ -n "${AI_AGENT:-}" ]]; then
        candidate="${AI_AGENT%%_*}"
        candidate="${candidate,,}"
        if [[ "$candidate" =~ ^[a-z0-9-]{1,32}$ ]]; then
            echo "$candidate"
            return 0
        fi
    fi

    # 4. Claude Code exports CLAUDECODE in its shell env.
    if [[ -n "${CLAUDECODE:-}" ]]; then
        echo "claude-code"
        return 0
    fi

    # 5. TERM_PROGRAM: VSCode-fork agents that inject NO custom var still set this
    #    (e.g. Kiro → TERM_PROGRAM=kiro). Lowercase it and accept it ONLY if it is
    #    a KNOWN CSG agent id, so generic terminals (vscode/iterm/apple_terminal/"")
    #    fall through instead of being stamped as the audit subject.
    if [[ -n "${TERM_PROGRAM:-}" ]]; then
        candidate="${TERM_PROGRAM,,}"
        if is_known_agent "$candidate"; then
            echo "$candidate"
            return 0
        fi
    fi

    # 6. __CFBundleIdentifier (macOS backup): dev.<name>.desktop or dev.<name>.app
    #    (e.g. Kiro → dev.kiro.desktop). Extract <name>, lowercase, and accept it
    #    ONLY if <name> is a KNOWN CSG agent id — catches macOS cases where
    #    TERM_PROGRAM differs from the agent id. The var name has LEADING
    #    underscores; reference it as ${__CFBundleIdentifier:-}.
    if [[ -n "${__CFBundleIdentifier:-}" ]]; then
        candidate="${__CFBundleIdentifier,,}"
        if [[ "$candidate" =~ ^dev\.([a-z0-9-]+)\.(desktop|app)$ ]]; then
            candidate="${BASH_REMATCH[1]}"
            if is_known_agent "$candidate"; then
                echo "$candidate"
                return 0
            fi
        fi
    fi

    # 7. Final fallback: the frozen install-path mapping.
    detect_agent_from_path "$1"
}

if [[ -z "$AGENT_NAME" ]]; then
    AGENT_NAME=$(detect_agent "$0")
fi

# --- Input validation (V5: same shape the broker enforces server-side) ---
[[ "$ACCOUNT_ID" =~ ^[0-9]{12}$ ]] \
    || die "유효하지 않은 --account-id (12자리 숫자만 허용)"
[[ "$AGENT_NAME" =~ ^[a-z0-9-]{1,32}$ ]] \
    || die "유효하지 않은 --agent (^[a-z0-9-]{1,32}$ 위반): ${AGENT_NAME}"

require_cmds

CACHE_FILE="${CACHE_DIR}/${ACCOUNT_ID}.json"

mkdir -p "$CACHE_DIR"
chmod 700 "$CACHE_DIR" 2>/dev/null || true

# --- Auto-sweep expired profiles (D-01) ---
# PROF-06: exclude this invocation's own cache path so the profile that
# triggered this credential_process call is not self-removed before it has
# had a chance to write its own cache.
sweep_expired_profiles "$CACHE_FILE"

# --- HOOK-B: auto-migrate to the csg- namespace (PROF-12) ---
# This is the delivery mechanism for the fleet migration. `self-update` replaces
# skill FILES and never re-runs install.sh, so a migration hosted only in the
# installer reaches ~0 already-deployed machines; the everyday credential_process
# path is where they actually converge.
#
# ORDERING CONTRACT -- this MUST stay after `sweep_expired_profiles` above.
# `extract_cache_path` keys the cache on the ACCOUNT ID, not the profile name
# (Phase 18 collapse), so a freshly renamed `csg-X` inherits old `X`'s
# <account-id>.json -- and that is a 1-hour session, so it is almost always
# expired. Migrating first therefore hands the sweep a brand-new `csg-X` that it
# classifies as expired-with-cache and deletes on the spot: the mapping table
# claims N renames while the fleet ends up empty. Sweeping first means migrate
# only ever rewrites the survivors. (The alternative -- plumbing the newly
# created names and their cache paths into the sweep as an exclusion list -- is a
# real signature change to a hot-path function for no benefit, and was rejected.)
#
# The marker check is repeated here (run_migration_once does it too) so the
# steady state on an already-migrated machine is ONE grep and complete silence:
# without it every AWS command on every converged machine would carry a
# `[migrate] status=already-migrated` line on its stderr.
#
# `aws` is checked because require_cmds gates only curl and jq -- an SDK-driven
# credential_process on a machine without the CLI would otherwise report
# config-unparseable on every single credential resolution.
#
# `|| true` is the whole point: a migration failure must NEVER stop this machine
# from resolving credentials.
if ! migration_completed && command -v aws >/dev/null 2>&1; then
    run_migration_once || true
fi

# --- Cache lookup (short-circuits before any Bearer read or broker call) ---
emit_from_cache() {
    [[ -f "$CACHE_FILE" ]] || return 1
    local exp now
    exp=$(jq -r '.Expiration // empty' "$CACHE_FILE" 2>/dev/null) || return 1
    [[ -n "$exp" ]] || return 1
    # Convert ISO8601 → epoch (gdate on macOS via brew, else date -d, else BSD date -j).
    # Lambda emits .toISOString() which carries millisecond precision (".123Z");
    # the BSD format string does not accept fractional seconds, so strip them
    # before parsing or every refresh on macOS would fall through to a re-auth.
    local exp_clean="${exp/Z/+0000}"
    exp_clean=$(printf '%s' "$exp_clean" | sed -E 's/\.[0-9]+([+-])/\1/')
    local exp_epoch
    if exp_epoch=$(date -u -d "$exp" +%s 2>/dev/null); then
        :
    elif exp_epoch=$(date -u -j -f "%Y-%m-%dT%H:%M:%S%z" "$exp_clean" +%s 2>/dev/null); then
        :
    else
        return 1
    fi
    now=$(date -u +%s)
    if (( exp_epoch - now > CACHE_SKEW_SECONDS )); then
        log "cache HIT (expires ${exp})"
        cat "$CACHE_FILE"
        return 0
    fi
    log "cache STALE (expires ${exp}), refreshing"
    return 1
}

if emit_from_cache; then
    exit 0
fi

# --- Per-account single-flight (credential-broker #50) ---
# A cache miss with N parallel callers for the SAME account used to send N broker
# POSTs. One caller issues; the rest wait on the lock, then re-read the cache the
# winner wrote. mkdir is the atomic primitive because `flock` is absent on a stock
# macOS. The lock sits beside the cache in CACHE_DIR (0700); umask 077 keeps the lock
# dir itself 0700. The dotted name cannot match do_cleanup's `*.json` glob.
#
# This sits BEFORE the scope brake on purpose: a waiter that ends up served from the
# cache never issued anything, so it must not consume fan-out window budget (D-01).
# Fail OPEN: a lock that cannot be taken within the wait cap (or a CACHE_DIR we cannot
# write) never blocks issuance -- we POST unlocked, which is the pre-#50 behaviour.
# ponytail: stale = no owner liveness check, only age. Two waiters reclaiming the same
# stale lock can both proceed (one extra POST at worst); add a pid file if that matters.
ACCT_LOCK="${CACHE_DIR}/.${ACCOUNT_ID}.lock.d"
ACCT_LOCK_HELD="false"
LOCK_STALE_SECONDS=60
LOCK_WAIT_DECISECONDS=450   # 45s: under the stale age, over a normal ~1s issuance

lock_age_seconds() {
    local m now
    m=$(stat -c %Y "$ACCT_LOCK" 2>/dev/null || stat -f %m "$ACCT_LOCK" 2>/dev/null) || return 1
    now=$(date -u +%s)
    [[ "$m" =~ ^[0-9]+$ ]] || return 1
    printf '%s' $((now - m))
}

release_acct_lock() {
    [[ "$ACCT_LOCK_HELD" == "true" ]] || return 0
    rmdir "$ACCT_LOCK" 2>/dev/null || true
    ACCT_LOCK_HELD="false"
}

acquire_acct_lock() {
    local i=0 age
    while (( i < LOCK_WAIT_DECISECONDS )); do
        if ( umask 077 && mkdir "$ACCT_LOCK" ) 2>/dev/null; then
            ACCT_LOCK_HELD="true"
            return 0
        fi
        # No lock dir AND mkdir failed => CACHE_DIR not writable; do not spin.
        [[ -d "$ACCT_LOCK" ]] || return 1
        age=$(lock_age_seconds) || age=0
        if (( age > LOCK_STALE_SECONDS )); then
            log "stale lock (${age}s) reclaimed"
            rmdir "$ACCT_LOCK" 2>/dev/null || true
            i=$((i + 1))
            continue
        fi
        sleep 0.1
        i=$((i + 1))
    done
    return 1
}

trap 'release_acct_lock' EXIT
if acquire_acct_lock; then
    # The winner we waited for may have just written the cache.
    if emit_from_cache; then
        exit 0
    fi
else
    log "WARNING: 계정 잠금을 얻지 못해 잠금 없이 발급합니다 (${ACCT_LOCK})"
fi

# --- Read the Slack Bearer from the login-token cache (NO OAuth here) ---
# credential_process must NEVER open a browser: if the Bearer is missing/empty
# we fail fast (<2s) so the AWS CLI does not hang (the prior ~120s agent hang).
BEARER=""
if [[ -f "$STS_CACHE" ]]; then
    BEARER=$(jq -r '.SlackAccessToken // empty' "$STS_CACHE" 2>/dev/null) || true
fi
if [[ -z "$BEARER" ]]; then
    die "로그인이 필요합니다. 먼저 get-sts-token.sh 를 실행해 Slack 로그인 토큰을 발급받으세요 (credential_process 안에서는 브라우저 로그인을 열지 않습니다)."
fi

# --- Derive the customer endpoint from API_URL (no new conf key; mirrors self-update.sh) ---
read_api_url() {
    [[ -f "$CONFIG_FILE" ]] || return 1
    local url
    url=$(grep -E '^[[:space:]]*API_URL[[:space:]]*=' "$CONFIG_FILE" 2>/dev/null | head -1 | cut -d'=' -f2- || true)
    # Trim surrounding whitespace
    url="${url#"${url%%[![:space:]]*}"}"
    url="${url%"${url##*[![:space:]]}"}"
    printf '%s' "$url"
}
API_URL=$(read_api_url) || true
[[ -n "$API_URL" ]] || die "설정 파일에서 API_URL을 찾을 수 없습니다: ${CONFIG_FILE}"
[[ "$API_URL" == https://* ]] || die "API_URL은 https://로 시작해야 합니다"
CUSTOMER_URL="${API_URL%/credentials}/customer-credentials"

# --- Exchange {accountId, agent, clientVersion} + Bearer for a read-only session ---
# clientVersion is ERR-10 observation only; --arg keeps it on the injection-safe path.
BODY=$(jq -nc --arg a "$ACCOUNT_ID" --arg g "$AGENT_NAME" --arg v "$CLIENT_VERSION" \
    '{accountId:$a, agent:$g, clientVersion:$v}')

# --- SCP-05 fan-out brake (D-01/D-06/D-17) ---
#
# PLACEMENT. Five reasons this block cannot move, all structural:
#
#  1. AFTER `if emit_from_cache; then exit 0; fi`, so a cache HIT reaches this on
#     no path at all and writes no window record. That is D-01's counting unit --
#     신규 발급만 -- and it is enforced by POSITION, not by a condition that a
#     later edit could quietly invert.
#  2. AFTER every fail-fast: the --account-id regex, the missing-Bearer die and
#     the missing/non-https API_URL die all sit above. A machine that is not
#     logged in must keep getting "로그인이 필요합니다", and a login failure is not
#     a fan-out, so it must not consume window budget.
#  3. BEFORE the retry loop head `attempt=0` below (Pitfall 9). A check inside
#     that loop would record the same account up to three times and could refuse
#     on retry 2 of a legitimate 5xx recovery. One record per invocation = one
#     per broker POST ATTEMPT. That is the D-01 discretion call -- 시도 시점, not
#     응답 시점: twelve consecutive failures are still a fan-out.
#  4. BEFORE `trap 'rm -f ...' EXIT` is installed. This block installs no trap
#     and holds no resource across its own exit, so nothing it does can be undone
#     when that trap replaces an earlier one.
#  5. The sweep -> migrate ordering block ~90 lines above -- the one whose header
#     comment opens "this MUST stay after `sweep_expired_profiles` above." -- is
#     a DIFFERENT contract and is not touched here. It is named so a reader
#     recognises it on sight instead of going looking for the brake up there.
#     Its two-word banner token is deliberately NOT reproduced verbatim: this
#     plan's gate greps the diff for that token to prove the block was untouched,
#     so quoting it would make the gate report this very comment.
#
# FAIL OPEN ON A BROKEN CLOCK (T-24-07). The whole block is guarded on scope_now
# being a positive integer; an unusable clock skips the brake entirely, the same
# direction as every reader 24-01 shipped. Breaking a legitimate single-account
# read is strictly worse than missing one fan-out (CLAUDE.md Core Value).
#
# D-17, APPEND-THEN-COUNT -- stated with the comparison so it is not misread as a
# deviation. `scope_window_append` is the FIRST statement here, before any read,
# so this invocation's own record is durable before any count is taken and no
# process can observe an empty window after writing to it. `.scope.lock` still
# exists and still guards the counter file; it just guards only the PRUNE, where
# losing it degrades to "the file keeps a few stale lines the cutoff filter
# ignores anyway" instead of "the verdict was wrong". A lock-first design would
# have to fail open on every contended invocation -- which is exactly the
# situation a fan-out creates, i.e. the exact hole D-17 exists to close. Honest
# consequence: with twelve truly simultaneous invocations the number that PASS is
# "about 5", not "exactly 5"; every process that reads after six appends refuses.
# 24-05 therefore asserts bounds (passes <= 5, refusals >= 1, records >= 12), not
# an exact split -- an exact-count assertion would flake by construction.
#
# WHY THE PRUNE COMES BEFORE THE VERDICT (Pitfall 2). scope_prune_window acquires
# and releases .scope.lock and has no exit path; scope_refuse exits. Calling the
# prune first makes it structurally impossible to `exit` while holding the lock,
# and a RETURN trap -- the shape sweep_expired_profiles uses -- does NOT fire on
# `exit`. Never reorder these two. Nothing else here touches the lock;
# acquire_scope_lock is not called from this block at all.
#
# D-06 IS TWO RULES, NOT ONE. scope_window_ids/scope_window_distinct already
# exclude every acked id from the count entirely (A3 -- otherwise a legitimately
# approved 12-account batch would sit in the window and block an unrelated 13th).
# The `case` membership test below is the OTHER half: an account that IS in the
# ack set must pass even when six OTHER unapproved accounts sit in the window.
# Without it an approved account would be refused for its neighbours' behaviour,
# which is not what "집합에 적힌 계정만 브레이크 면제" means. Accounts outside the
# set are still counted against each other and still refused.
#
# THE RECORD IS WRITTEN EVEN FOR AN ACKED ACCOUNT. D-01's unit is the issuance
# attempt, not the unapproved issuance attempt. Acked-ness is applied at READ
# time by intersecting with the ack set, so there is never a write-then-update
# window where a record sits on disk with an already-stale value.
#
# T-24-05 / T-24-06. Every helper's stdout is consumed inside $( );
# scope_window_append, scope_prune_window and scope_refuse write to fd 1 on no
# path -- so the 5-key JSON contract is untouched whether this block passes,
# refuses or fails open. There is no prompt, no blocking wait and no sleep here,
# and acquire_scope_lock (reached only inside the prune) is non-blocking with two
# attempts. The file header records a prior ~120s agent hang from exactly this
# class; the budget for this block is fail-fast in well under two seconds.
#
# WHAT THIS IS, STATED PLAINLY. 결정론적 거부와 기록. An agent that calls
# `scope-ack` itself walks straight through it (T-24-02, accepted); the backstop
# that does not depend on the agent's cooperation is server-side (Phase 25
# DET-01). Fleet timing: a machine still running the old client mid-rollout
# neither reads nor writes these files, so the window UNDER-counts during a
# rollout and never over-counts.
#
# Locals are lowercase scope_* on purpose, so that a grep for SCOPE_[A-Z] keeps
# returning exactly the six frozen constants T-24-03's gate depends on. Each
# capture is on its own line with its own `|| fallback` -- never
# `local x=$( ... )`, which masks the exit status. The `(( scope_count >
# SCOPE_MAX_ACCOUNTS ))` below is safe under `set -e` only because it sits inside
# an `if` condition, where a false result is not fatal.
scope_now=$(date -u +%s 2>/dev/null) || scope_now=0
if [[ "$scope_now" =~ ^[1-9][0-9]*$ ]]; then
    scope_cutoff=$((scope_now - SCOPE_WINDOW_SECONDS))

    scope_window_append "$ACCOUNT_ID"

    scope_acks=$(scope_ack_set "$scope_now") || scope_acks=""
    scope_ids=$(scope_window_ids "$scope_cutoff" "$scope_acks") || scope_ids=""
    # WR-03: the count is DERIVED from $scope_ids, not read by a second call to
    # scope_window_distinct. Both numbers reach the same refusal message, and two
    # separate reads of scope-window.jsonl can see two different files -- a
    # sibling invocation appends between them. The second read is also the one
    # that feeds the copy-pasteable scope-ack line, so the divergence a second
    # parse buys is a retry command missing an id the message just counted: a
    # paste that gets refused again. This derivation is byte-for-byte what
    # scope_window_distinct does internally, so the single-process behaviour is
    # unchanged; what changes is that the credential hot path now reads the
    # window file ONCE.
    if [[ -z "$scope_ids" ]]; then
        scope_count=0
    else
        scope_count=$(printf '%s\n' "$scope_ids" | awk -F, '{ print NF }') || scope_count=0
    fi

    scope_prune_window "$scope_cutoff"

    scope_acked="false"
    case ",${scope_acks}," in
        *",${ACCOUNT_ID},"*) scope_acked="true" ;;
    esac

    if [[ "$scope_acked" != "true" ]] \
        && [[ "$scope_count" =~ ^[0-9]+$ ]] \
        && (( scope_count > SCOPE_MAX_ACCOUNTS )); then
        scope_refuse "$scope_count" "$scope_ids"
    fi
fi

BODY_FILE=$(mktemp "${TMPDIR:-/tmp}/ccred.body.XXXXXX")
CURL_ERR=$(mktemp "${TMPDIR:-/tmp}/ccred.err.XXXXXX")
trap 'rm -f "$BODY_FILE" "$CURL_ERR" "${TMP_CACHE:-}"; release_acct_lock' EXIT

log "POST ${CUSTOMER_URL} (account=${ACCOUNT_ID}, agent=${AGENT_NAME})"

# Bounded retry loop with a broker HTTP status -> actionable Korean message map
# (RES-02, D-19-01). The body is written to a temp file via -o and the status
# code is captured via -w '%{http_code}'; a curl transport failure (connect
# refused/timeout) collapses to HTTP_CODE=000. Retry is scoped to the RETRYABLE
# class ONLY (503 / other 5xx / 000 transport-fail) -- three separate arms sharing
# ONE `attempt` counter (D-01), bounded to max_attempts with a linear
# `sleep $attempt` backoff; the DETERMINISTIC deny class (401/403/404/424) is
# NEVER retried.
#
# WR-01: the Bearer is handed to curl through a CONFIGURATION STANZA ON STDIN
# (`-K -`), so it does not appear among this process's arguments. It used to be
# an argument, while the sentence that stood here claimed the opposite of what
# the code did. Linux publishes every process's arguments to every local UID
# through /proc/<pid>/cmdline for the lifetime of that process, and a Bearer
# read out of there mints customer sessions ATTRIBUTED TO THE ENGINEER IT WAS
# TAKEN FROM -- the broker's audit trail is the authoritative record of who
# touched a customer account, so the wrong name lands in precisely the artifact
# this tool exists to keep honest. Reading a config from stdin has been in curl
# far longer than any platform we support, so this adds no version floor
# (T-30-12), unlike the --write-out placeholders the 000 arm below declines.
#
# The stanza is PARSED, not merely substituted: a value that carried a newline
# or an unescaped quote could smuggle a SECOND curl option (an `output`
# redirect, say) in through a poisoned token cache. `bearer_cfg` below is the
# whole of that defence -- strip CR and LF, then escape backslash before quote,
# order significant -- and it is the only new surface this shape opens. The
# token is still never echoed to a log line or a die string.
bearer_cfg=${BEARER//$'\r'/}
bearer_cfg=${bearer_cfg//$'\n'/}
bearer_cfg=${bearer_cfg//\\/\\\\}
bearer_cfg=${bearer_cfg//\"/\\\"}
attempt=0
max_attempts=3
RESP=""
while :; do
    HTTP_CODE=$(printf 'header = "Authorization: Bearer %s"\n' "$bearer_cfg" \
        | curl -sS --connect-timeout 5 --max-time 30 -K - \
            -o "$BODY_FILE" -w '%{http_code}' \
            -X POST "$CUSTOMER_URL" \
            -H "Content-Type: application/json" \
            -d "$BODY" 2>"$CURL_ERR") || HTTP_CODE=000
    case "$HTTP_CODE" in
        2??)
            RESP=$(cat "$BODY_FILE" 2>/dev/null || true)
            break
            ;;
        401)
            die "Slack 로그인이 만료되었습니다. get-sts-token.sh 를 다시 실행해 로그인하세요."
            ;;
        403)
            die "이 계정에 접근 권한이 없습니다 (등록된 활성 고객 계정이 아니거나 인가 실패)."
            ;;
        404)
            die "브로커 엔드포인트를 찾을 수 없습니다. API_URL 설정을 확인하세요."
            ;;
        426)
            # tiket (2026-10-20): the broker's MIN_CLIENT_VERSION refused this workspace's
            # release. Deterministic like 424 -- waiting never upgrades the workspace, so no
            # retry, no sleep, no continue. Client-side literal; the body is not parsed.
            die "tiket 워크스페이스가 오래돼 브로커가 발급을 거절했습니다. 에이전트 세션을 새로 시작하면 자동으로 올라갑니다. 안 되면 워크스페이스에서 git pull 을 하세요."
            ;;
        424)
            # ERR-02 (Phase 30): DETERMINISTIC DENY -- copied from the 403) shape above,
            # deliberately NOT in any retry arm. 424 means the broker reached the customer
            # side and was refused there (role / trust policy), or our registration data for
            # the account is wrong. Neither condition heals by waiting, so this arm touches
            # `attempt` on no path, sleeps on no path and never `continue`s. That is also
            # how the "total broker requests <= max_attempts for EVERY status class"
            # invariant survives the 5??/000 split below (D-01).
            #
            # D-09: the 424 response body is NOT parsed -- the sentence below is a
            # client-side literal, byte-identical to the 424 arm in
            # get-customer-credentials.ps1. Two consequences: a spoofed or compromised
            # broker cannot put its own text in front of the engineer (T-30-10), and
            # Phase 32 can rename/extend its `code` enum without a client re-release.
            die "고객사 계정 설정 또는 등록 정보 문제로 세션을 발급할 수 없습니다 (고객사 역할/신뢰정책, 등록 계정 정보 확인 필요). 재시도해도 해결되지 않습니다."
            ;;
        429)
            # credential-broker #49: API-stage throttle. Transient, so it shares the ONE
            # `attempt` counter (total POSTs <= max_attempts for every class). Jittered
            # 1-2s sleep so throttled siblings do not retry in lockstep.
            attempt=$((attempt + 1))
            [[ $attempt -ge $max_attempts ]] \
                && die "브로커가 요청 제한(429)으로 응답했습니다. 잠시 후 다시 시도하세요."
            sleep "$((attempt)).$((RANDOM % 10))"
            continue
            ;;
        503)
            attempt=$((attempt + 1))
            [[ $attempt -ge $max_attempts ]] \
                && die "브로커 의존성을 일시적으로 사용할 수 없습니다. 잠시 후 다시 시도하세요."
            sleep "$attempt"
            continue
            ;;
        5??)
            attempt=$((attempt + 1))
            [[ $attempt -ge $max_attempts ]] \
                && die "브로커를 일시적으로 사용할 수 없습니다. 잠시 후 다시 시도하세요."
            sleep "$attempt"
            continue
            ;;
        000)
            # ERR-03 (Phase 30): TRANSPORT failure -- there was no HTTP response at all
            # (DNS, TCP connect, TLS, proxy, timeout). Split out of the old `5??|000)` arm
            # so the engineer can tell "the broker answered badly" from "we never reached
            # the broker"; those two have different next actions.
            #
            # D-01: this arm increments the SAME `attempt` declared at the loop head and
            # compares it against the SAME `max_attempts`. Do not add a per-arm counter --
            # splitting the COUNTER (not splitting the arm) is what would double the request
            # budget to 6 against a fully dead broker, at exactly the moment it hurts most
            # (PITFALLS:434, T-30-11).
            #
            # D-02: the transport diagnostic is attached to the FINAL die only, never to an
            # intermediate retry. `2>"$CURL_ERR"` truncates on every attempt, so the file
            # holds the last attempt's stderr -- the one worth printing. Until now that file
            # was created, filled and deleted by the EXIT trap without ever being read
            # (ARCHITECTURE:592). `head -1` bounds it to one line and sanitize_for_display
            # strips the \p{Cc} + \p{Cf} classes and caps at 120 characters, because a
            # hostile proxy controls part of this string and this stderr is read by an AI
            # agent as well as a human (T-30-08). The curl --write-out transport-error
            # placeholders are deliberately NOT used: they need curl 7.75+ (2021-02) and
            # Ubuntu 20.04 / RHEL 8 are live engineer platforms (T-30-12) -- the
            # `|| HTTP_CODE=000` idiom above is version-independent.
            attempt=$((attempt + 1))
            err_head=$(head -1 "$CURL_ERR" 2>/dev/null || true)
            [[ $attempt -ge $max_attempts ]] \
                && die "브로커에 연결할 수 없습니다 (네트워크/DNS/프록시 확인). 진단: '$(sanitize_for_display "$err_head")'"
            sleep "$attempt"
            continue
            ;;
        *)
            die "브로커 호출 실패 (HTTP ${HTTP_CODE})."
            ;;
    esac
done

[[ -n "$RESP" ]] || die "브로커 응답이 비어 있습니다"

# Surface a structured broker error body (401/400/403 → {"error":"..."}) verbatim.
ERR_MSG=$(printf '%s' "$RESP" | jq -r 'if type=="object" then (.error // .message // empty) else empty end' 2>/dev/null || true)
[[ -z "$ERR_MSG" ]] || die "브로커 오류: ${ERR_MSG}"

# Project to EXACTLY the 5-key credential_process contract (drops BrokerVersion).
# Fails closed if any required credential field is absent (unexpected/error body).
#
# CR-01: the failure message names the HTTP status and the CONTRACT FIELDS this
# client's own guard rejected -- never the body. The body used to be
# interpolated whole, and the shape that reaches here is a 200 carrying a live
# AccessKeyId / SecretAccessKey / SessionToken with an unusable expiry (a broker
# regression, a truncated STS response, a schema change). Nothing above catches
# it: the status arms only see 2xx, and the error surfacing needs an .error
# field a credential body does not have. So those credentials went to stderr --
# the engineer's terminal, the AI agent transcript and any CI log capturing the
# run, all three at once.
#
# The field list is a FIXED client-side array, and the broker's own keys are
# only ever the right-hand operand of the set difference, so the printed string
# cannot be anything but a subset of those four literals. Zero broker-controlled
# bytes reach the terminal, which makes control-character and forged-log-line
# injection UNREPRESENTABLE at this point rather than merely sanitized -- the
# display sanitizer is not needed here and is deliberately not applied. (The
# .error surfacing above still interpolates broker text; that one is open.)
# `select(.value)` is jq's own truthiness -- the same test the `and` chain below
# applies -- so a field named in the message is exactly a field that failed the
# projection. A body that is not a JSON object makes `to_entries` throw, and the
# fallback below says so rather than guessing.
MISSING=$(printf '%s' "$RESP" | jq -r '
    (["AccessKeyId","SecretAccessKey","SessionToken","Expiration"]
     - [to_entries[] | select(.value) | .key]) | join(",")
' 2>/dev/null || true)
[[ -n "$MISSING" ]] || MISSING="(판별 불가)"

CREDS_JSON=$(printf '%s' "$RESP" | jq -ce '
    if (.AccessKeyId and .SecretAccessKey and .SessionToken and .Expiration)
    then {Version:1, AccessKeyId, SecretAccessKey, SessionToken, Expiration}
    else empty end
' 2>/dev/null) || die "브로커 응답 형식 오류 또는 인증 실패 (HTTP ${HTTP_CODE}, 누락 필드: ${MISSING})."

# Atomic cache write — create the temp file under a restrictive umask so the
# credentials are never world-readable, even between mktemp and the rename
# (avoids the TOCTOU window where another local UID could read them).
TMP_CACHE=$(mktemp "${CACHE_FILE}.XXXXXX")
( umask 077 && printf '%s' "$CREDS_JSON" > "$TMP_CACHE" )
chmod 600 "$TMP_CACHE" 2>/dev/null || true
mv "$TMP_CACHE" "$CACHE_FILE"

printf '%s' "$CREDS_JSON"
