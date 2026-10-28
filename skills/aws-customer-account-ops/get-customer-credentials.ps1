# get-customer-credentials.ps1
#
# AWS CLI credential_process wrapper that exchanges a cached Slack Bearer for a
# ready-to-use, read-only customer session by calling the broker endpoint
#   POST /v1/customer-credentials
# The broker performs the customer AssumeRole and attaches ReadOnlyAccess
# SERVER-SIDE (Phase 17). This client holds ZERO privileged credentials and
# runs NO local STS AssumeRole -- read-only is enforced structurally at the
# IAM layer, not by this script. (PowerShell twin of get-customer-credentials.sh.)
#
# Usage (registered as credential_process for a customer profile):
#   pwsh -NoProfile -File get-customer-credentials.ps1 -AccountId <12-digit> [-Agent <name>]
#
# Subcommands:
#   cleanup        Remove expired CSG profiles from ~/.aws/config
#   cleanup --all  Remove ALL CSG profiles and all cache files
#   register       Register a customer profile in ~/.aws/config (PROF-08/10/11).
#         The `register` SUBCOMMAND has its own, SEPARATE stdout contract: on
#         success it prints EXACTLY ONE line (the profile name) and on any abort
#         it prints NOTHING at all, with every diagnostic going to stderr
#         prefixed "[register] ". register is never invoked from inside
#         credential_process, so the two stdout contracts can never interleave.
#
# Auth:   Bearer read from ~/.cache/msp/sts-token.json (.SlackAccessToken),
#         obtained by running get-sts-token.ps1 first. The Bearer is NEVER passed
#         on argv and NEVER logged. If it is missing/empty this script fails fast
#         (no browser/OAuth is ever opened from inside credential_process).
# Output: AWS CLI credential_process JSON on stdout -- exactly the 5-key contract
#         { Version:1, AccessKeyId, SecretAccessKey, SessionToken, Expiration }.
#         BrokerVersion (returned by the broker) is projected out.
# Cache:  $HOME/.cache/msp/customer-creds/<account-id>.json (macOS/Linux)
#         $env:USERPROFILE\.cache\msp\customer-creds\<account-id>.json (Windows)
#
# Notes:
#   * The customer role/external-id/session-policy/identity-stamping are all
#     resolved server-side; this client only supplies {accountId, agent}.
#   * All diagnostic output goes to stderr; stdout is reserved for the
#     credential_process JSON contract.

# No param() block -- manual $args parsing supports both cleanup subcommand
# and named-parameter credential_process invocation (D-02).

$ErrorActionPreference = "Stop"

$HomeDir = if ($env:USERPROFILE) { $env:USERPROFILE } else { $env:HOME }
$CacheDir = Join-Path $HomeDir ".cache/msp/customer-creds"
# Foreign-key skip-visibility record (D-04/D-05). ".jsonl", NOT ".json" -- the
# "cleanup --all" orphan-cache wipe below globs "*.json" only; a ".json" suffix
# would be silently deleted by that same glob every time (Common Pitfalls #2).
$SkipRecord = Join-Path $CacheDir "guard-skips.jsonl"
# PROF-12: one-shot completion marker for the client fleet migration. MUST end in
# ".jsonl" for exactly the same reason as $SkipRecord above -- Invoke-DoCleanup's
# "*.json" orphan-cache glob would otherwise delete it and RE-ARM the destructive
# migration on every `cleanup --all`, which is the one code path in this milestone
# that must never run twice by accident.
$MigrationRecord = Join-Path $CacheDir "migrations.jsonl"
# Identity of the migration this client version ships. A future migration gets a
# NEW id (and therefore runs once more); it never reuses this one. Byte-identical
# to get-customer-credentials.sh MIGRATION_ID -- PARITY-MIGRATE-CONST locks them.
$MigrationId = "v1.7-csg-namespace"
# Counters filled in by Invoke-DoMigrate and consumed by Invoke-MigrationOnce's
# marker write. Script-scoped rather than a return value because stdout is the
# credential JSON channel and Invoke-DoMigrate's rc carries the abort semantics.
$script:MigrateRenamed = 0
$script:MigrateRepaired = 0
$script:MigrateSkipped = 0
# Subset of MigrateSkipped that is worth RETRYING (a failed delete, a failed key
# carry, ...) as opposed to permanently unconvertible (name-collision,
# account-mismatch, no-account-id). See Invoke-MigrationOnce step (5).
$script:MigrateTransientFailures = 0
# PROF-12 / T-23-09: ONE rollback point per multi-step config session. When set,
# Remove-ProfilesFromConfig and Remove-KeysFromProfile reuse this single .bak path
# instead of minting one per call, so a fleet migration that calls them N times
# still leaves exactly one pre-migration snapshot. Empty on every other path, which
# restores the historical per-call behaviour byte for byte.
$script:CsgBackupSession = ""
# --- scope brake constants (SCP-05) ---
# The deterministic client-side fan-out brake. Calibration point is the v1.7
# incident: one agent issued credentials for 12 customer accounts in 54 seconds
# and no single log showed that as ONE event. What this buys is 마찰, a local
# 기록 and a 결정론적 거부 -- it is not a wall, because the agent owns both the
# shell and the filesystem (X7 honest labelling; the server-side backstop is
# Phase 25 DET-01).
#
# Both records MUST end in ".jsonl", for exactly the same reason as $SkipRecord
# and $MigrationRecord above: Invoke-DoCleanup's orphan-cache wipe is
# `Get-ChildItem -Path $CacheDir -Filter "*.json" | Remove-Item -Force`, and a
# four-character filter cannot match a five-character ".jsonl" name. If it could,
# `cleanup --all` would be a one-command window reset -- precisely the bypass
# this brake exists to close (D-08).
# Byte-identical to get-customer-credentials.sh SCOPE_WINDOW_RECORD /
# SCOPE_ACK_RECORD -- PARITY-SCOPE-CONST locks them.
$ScopeWindowRecord = Join-Path $CacheDir "scope-window.jsonl"   # operational, pruned
$ScopeAckRecord = Join-Path $CacheDir "scope-acks.jsonl"        # audit, append-only
# A FILE, never a directory, and the SAME literal path the bash twin uses. The
# bricking runs both ways (Phase 23 WR-09 records both directions): a directory
# left here by a pre-Phase-23 bash client makes [IO.File]::Open throw forever, so
# this client's brake would read as "held" on every future run; a plain file left
# here by a killed pwsh run made the old mkdir-shaped bash lock fail forever.
# Deliberately NOT .sweep.lock: that lock is non-blocking with 2 attempts and is
# held across whole ~/.aws/config rewrites, so a brake sharing it would have to
# fail open on every contended parallel invocation -- the exact hole D-17 exists
# to close. Byte-identical to get-customer-credentials.sh SCOPE_LOCK --
# PARITY-SCOPE-CONST locks it.
$ScopeLock = Join-Path $CacheDir ".scope.lock"
# D-02: the 12-in-54s incident is the calibration point. One customer's routine
# 2-4 accounts must keep passing untouched, so the allowance sits above that and
# far below the incident, over a window short enough that a genuine fan-out lands
# inside it.
# D-04: release-only. There is deliberately NO $env: read and NO
# credential-broker.conf key for any of these three. The agent owns the shell and
# that conf file, so a tunable would not be a knob -- it would be an unlogged
# bypass, and an unlogged bypass is the thing this brake is here to make loud.
# Bare integer literals, byte-identical to the bash twin's SCOPE_MAX_ACCOUNTS /
# SCOPE_WINDOW_SECONDS / SCOPE_ACK_TTL_SECONDS -- PARITY-SCOPE-CONST locks them.
$ScopeMaxAccounts = 5
$ScopeWindowSeconds = 300
$ScopeAckTtlSeconds = 3600
$CacheSkewSeconds = 300
$ConfigFile = Join-Path $HomeDir ".config/msp/credential-broker.conf"
$StsCache = Join-Path $HomeDir ".cache/msp/sts-token.json"
# PROF-08 (Phase 22): value written into every register-created profile as
# "csg_managed = <version>"; presence-only, never value-matched by any predicate.
# Must stay byte-identical to get-customer-credentials.sh CSG_MANAGED_VERSION
# (the VERSION file is absent from install.sh SKILL_FILES, so it cannot be read
# at runtime -- hardcoding on both sides is the only option, and a parity case
# asserts the two literals are equal).
$CsgManagedVersion = "1.7.0"
# ERR-10 (Phase 30): the client build this process is running. Sent to the broker as
# `clientVersion` in the POST body below and logged there as a spread-observation signal
# only -- the broker reads it unvalidated and it can NEVER fail an issuance (D-07).
#
# install.sh stamps this literal with the release $VERSION on BOTH install paths (do_pack
# and direct repo install), so the value below is only ever observed when the script runs
# straight out of a repo checkout. Must stay byte-identical to
# get-customer-credentials.sh CLIENT_VERSION -- a parity case asserts the two literals are
# equal, the same way it does for $CsgManagedVersion above.
#
# Deliberately UN-SCOPED, matching its neighbours in this block. The spelling is
# load-bearing (T-30-13): install.sh's stamping sed is ^-anchored and exits 0 whether or
# not it matched, so a rename here would silently ship a stale version fleet-wide with a
# green build.
# tiket 으로 옮긴 뒤 (0040, 2026-10-20): 클라이언트 버전은 tiket 릴리스 태그다. 스크립트가 든 워크스페이스의
# git 에서 읽고, 못 읽으면 tiket-unknown — 브로커는 unknown 을 막지 않는다(D-07). git 이 없거나 실패해도
# 발급을 멈추지 않는다. 남는 $LASTEXITCODE 는 성공 경로 끝의 exit 0 이 덮는다.
$ClientVersion = "tiket-unknown"
try {
    $tiketTag = & git -C $PSScriptRoot describe --tags --abbrev=0 2>$null
    if ($LASTEXITCODE -eq 0 -and $tiketTag) { $ClientVersion = "tiket-$(([string]$tiketTag).Trim())" }
}
catch { }
# PROF-13: set to $true only for the duration of Invoke-DoDoctor's collection
# pass, which suppresses Write-GuardSkipRecord's "run doctor to repair" advisory
# while doctor is the one running (T-23-21). Declared here so the flag is never
# an undefined variable on any other code path.
$script:GuardSkipQuiet = $false
# T-23-29: the lock path this process actually acquired, so Unlock-Sweep unlinks
# the file it owns and never one a different holder is still using. Declared here
# for the same reason as the flag above.
$script:SweepLockStream = $null
$script:SweepLockPath = ""
# SCP-05 / T-24-10: the scope brake's OWN lock handle and the path it acquired.
# Declared here for the same reason as the two above -- so neither is ever an
# undefined variable on any other code path -- and dedicated for a load-bearing
# one. Invoke-ScopePrune deliberately does not reuse the sweep lock's singletons:
# a prune running while Invoke-SweepExpiredProfiles holds the sweep lock would
# overwrite the sweep's handle, and Unlock-Sweep would then dispose and unlink a
# lock whose real holder is still mid-rewrite of ~/.aws/config, letting a third
# process acquire a second "exclusive" sweep lock on a fresh inode. That is
# exactly the failure Unlock-Sweep's own header comment exists to prevent.
#
# It is also why bash's acquire_scope_lock can be a two-line delegation to
# acquire_sweep_lock while this side copies the body instead: the two clients
# differ in code and agree in behaviour, and PARITY-SCOPE-CONST pins the shared
# ".scope.lock" literal so the PATH can never drift apart.
$script:ScopeLockStream = $null
$script:ScopeLockPath = ""

function Show-Usage {
    # WR-04: route through stderr (not Write-Host, which writes to the host/
    # Information stream and can be interleaved into captured stdout by the
    # default console host), matching the bash twin's `cat >&2` usage() and
    # this file's own stated stdout/stderr contract.
    [Console]::Error.WriteLine(@"
사용법: get-customer-credentials.ps1 [OPTIONS]

AWS CLI credential_process로 등록되어, 캐시된 Slack Bearer로 브로커
(/v1/customer-credentials)를 호출해 고객사 read-only 세션을 받아옵니다.
AssumeRole 과 ReadOnlyAccess 세션 정책은 모두 브로커(서버)가 처리합니다.
이 스크립트는 어떤 권한 자격 증명도 보관하지 않으며 로컬 assume 를 하지 않습니다.

SUBCOMMANDS:
  cleanup        만료된 CSG 프로필을 ~/.aws/config에서 제거
  cleanup --all  모든 CSG 프로필과 캐시 파일 전체 삭제
  register --account-id <id> --account-name "{name}" [--corp-name "{corp}"]
                 고객사 프로필을 ~/.aws/config에 등록 (프로필 이름은 스크립트가
                 --account-name 에서 직접 도출; 이름 충돌 시 병합 없이 중단)
  doctor         오염된 하이브리드 섹션(엔지니어 본인 credential 키에 CSG 키가
                 섞인 상태)을 찾아 csg_managed / credential_process 두 키만
                 제거. 섹션과 sso_*/region/output 은 값까지 보존. 인자 없음.
  scope-ack --account-ids <id,id,...>
                 2개 이상 계정 배치를 시작하기 전에 대상 범위를 승인 기록에
                 남깁니다 (1시간 유효). 성공 시 stdout 1줄.

PARAMS:
  -AccountId        (필수) 고객 AWS 계정 ID (12자리)
  -Agent            (선택) AI 에이전트 이름 (claude-code, kiro 등).
                    생략 시 런타임 환경(MSP_AGENT/AI_AGENT/CLAUDECODE/
                    TERM_PROGRAM/__CFBundleIdentifier)에서 실제 호출 에이전트를
                    자동 감지하고, 없으면 설치 경로로 폴백.
  -Region           (선택, 하위호환용 no-op -- 로컬 assume 가 없어 무시됨)
  -SessionName      (선택, 하위호환용 no-op -- 신원은 브로커가 서버에서 각인)
  -Help             도움말 출력

AUTH:
  ~/.cache/msp/sts-token.json 의 SlackAccessToken (get-sts-token.ps1 로 발급)

OUTPUT:
  stdout -- AWS CLI credential_process JSON (5-key 계약)
  stderr -- 진단 메시지 (캐시 hit/miss, 에러 등)
  scope-ack 는 자체 stdout 계약을 씁니다: 성공 시 중괄호 없는 1줄, 중단 시 완전히
  비움. register 와 마찬가지로 credential_process 안에서 호출되지 않으므로 두
  계약이 섞일 일은 없습니다.

CACHE:
  ~/.cache/msp/customer-creds/<account-id>.json
"@)
}

# Read-ApiUrl: extract API_URL from credential-broker.conf (no new conf key).
# Mirrors get-customer-credentials.sh:read_api_url + get-sts-token.ps1:Read-Config.
function Read-ApiUrl {
    if (-not (Test-Path -LiteralPath $ConfigFile)) { return $null }
    foreach ($rawLine in Get-Content -LiteralPath $ConfigFile) {
        $line = $rawLine.Trim()
        if ([string]::IsNullOrWhiteSpace($line) -or $line.StartsWith("#")) { continue }
        $sep = $line.IndexOf("=")
        if ($sep -lt 0) { continue }
        $key = $line.Substring(0, $sep).Trim()
        if ($key -eq "API_URL") {
            return $line.Substring($sep + 1).Trim()
        }
    }
    return $null
}

function Write-Log {
    param([string]$Message)
    [Console]::Error.WriteLine("[get-customer-credentials] $Message")
}

function Stop-WithError {
    param([string]$Message)
    Write-Log "ERROR: $Message"
    exit 1
}

# Invoke-BrokerRequest: one broker POST that returns
#   @{ StatusCode = <int>; Body = <string>; Error = <string|$null> }
# for ANY HTTP status, so the caller can map status -> message + bounded retry (RES-02).
# The Bearer is passed ONLY in the Authorization header (never argv, never logged).
#
# WR-01 asymmetry, recorded so a later "make the two clients match" pass does not
# invert it: this function hands the header to Invoke-WebRequest IN-PROCESS, as a
# hashtable. There is no child process, therefore no argument vector, therefore
# nothing for another local UID to read. The bash twin had to be moved off argv
# onto a stdin config stanza to reach the same property. Rewriting this call as a
# curl invocation for symmetry with that change would CREATE an exposure Windows
# does not currently have; the parity that matters here is the property, not the
# mechanism, and the lexical parity suite cannot see either.
#   * PS7+  : Invoke-WebRequest -SkipHttpErrorCheck returns the response for any 4xx/5xx
#             without throwing -> read $resp.StatusCode / $resp.Content directly.
#   * PS5.1 : no -SkipHttpErrorCheck, so a non-2xx throws -> read the status from
#             $_.Exception.Response.StatusCode.value__ and the body from the response
#             stream (mirrors get-sts-token.ps1:437-472). PS7 HttpResponseMessage has
#             no GetResponseStream(), but PS7 never reaches that catch for an HTTP status.
#   * A transport failure (connect refused / timeout) throws with no usable HTTP status
#             on BOTH editions -> mapped to StatusCode 0 (retryable transport-fail class).
#
# Error (Phase 30, ERR-03 / D-02): the .NET exception message, or $null when the request
# completed at the transport layer. Before this it was caught and thrown away -- the exact
# twin of the bash side's unread $CURL_ERR. It exists so the StatusCode 0 arm can print a
# diagnostic on its FINAL failure. ALL THREE return sites carry the key: if either success
# return omitted it, the caller would read $null off a PS7 4xx and the diagnostic would
# vanish on precisely the edition most engineers run. The caller MUST route the value
# through the display sanitizer at :1082 before showing it (T-30-08) -- it is transport
# text a hostile proxy can influence.
function Invoke-BrokerRequest {
    param([string]$Url, [string]$Body, [string]$Bearer)

    $headers = @{ Authorization = "Bearer $Bearer" }
    try {
        if ($PSVersionTable.PSVersion.Major -ge 6) {
            $resp = Invoke-WebRequest -Uri $Url -Method Post -TimeoutSec 30 `
                -Headers $headers -ContentType 'application/json' -Body $Body `
                -SkipHttpErrorCheck
            return @{ StatusCode = [int]$resp.StatusCode; Body = [string]$resp.Content; Error = $null }
        }
        $resp = Invoke-WebRequest -Uri $Url -Method Post -TimeoutSec 30 `
            -Headers $headers -ContentType 'application/json' -Body $Body
        return @{ StatusCode = [int]$resp.StatusCode; Body = [string]$resp.Content; Error = $null }
    }
    catch {
        $code = 0
        $bodyText = $null
        $exResp = $_.Exception.Response
        if ($exResp) {
            try { $code = [int]$exResp.StatusCode.value__ } catch { $code = 0 }
            try {
                $stream = $exResp.GetResponseStream()
                if ($stream) {
                    $reader = [System.IO.StreamReader]::new($stream)
                    try { $bodyText = $reader.ReadToEnd() } finally { $reader.Dispose() }
                }
            } catch {
                # Fall through: body stays $null; the status is what drives the mapping.
            }
        }
        return @{ StatusCode = $code; Body = $bodyText; Error = $_.Exception.Message }
    }
}

# --- Profile cleanup helpers ---
# Infrastructure profiles that must never be touched by cleanup operations, and
# (via the Invoke-Register veto) never MINTED either.
# Byte-parallel to get-customer-credentials.sh SKIP_PROFILES; PARITY-SKIP locks
# the two sets together. This is NOT install.sh's never-touch list -- that one is
# shorter and serves the installer's own narrower purpose. Do not "resync" them.
#
# `csg-login` is here because of Phase 23: once Get-DerivedProfileName namespaces
# every derived name under `csg-`, `--account-name "Login"` becomes a reachable
# spelling of the broker anchor profile for the first time (T-23-01).
$SkipProfiles = @("crossaccount-user", "crossaccount-role", "default",
                   "msp-homepage", "msp-internal", "csg-login")

# Foreign-key PREFIX FAMILIES (PROF-07, Phase 21). Case-folded prefix match,
# not a fixed literal list -- entries ending in "_" are startswith-prefix
# families (e.g. "sso_" also catches sso_region/sso_registration_scopes,
# which are not individually named but share the family), the rest are exact
# matches. Byte-parallel to get-customer-credentials.sh FOREIGN_KEY_PREFIXES.
$ForeignKeyPrefixes = @("sso_", "role_", "source_profile", "credential_source",
                         "aws_", "web_identity_token_file", "mfa_serial",
                         "external_id", "duration_seconds")

# Test-IsForeignKey: $true iff $Key (an INI key name) belongs to any foreign
# credential-key prefix family. Comparison is lowercase-normalized for clarity
# even though PowerShell string ops are case-insensitive by default.
function Test-IsForeignKey {
    param([string]$Key)

    $k = $Key.ToLowerInvariant()
    foreach ($prefix in $ForeignKeyPrefixes) {
        if ($prefix.EndsWith("_")) {
            if ($k.StartsWith($prefix)) { return $true }
        }
        elseif ($k -eq $prefix) {
            return $true
        }
    }
    return $false
}

# Test-IsCsgProfile: Check if a profile is a CSG customer profile (eligible for cleanup).
# D-08: CSG profiles have credential_process containing "get-customer-credentials.ps1".
# PROF-08/D-06 (Phase 22): positive ownership is the UNION of the csg_managed
# marker and the legacy credential_process signature (a superset), so pre-marker
# CSG profiles never become orphans once the marker ships. $HasMarker is a
# presence flag only -- the marker's VALUE is never compared here or anywhere else.
# PROF-07: a section carrying ANY foreign credential key is NEVER eligible, even
# if it also carries our credential_process line or our marker (poisoned-hybrid
# immunity). That veto stays LAST so it outranks both ownership signals.
function Test-IsCsgProfile {
    param([string]$CpValue, [string]$ProfileName, [bool]$HasForeign = $false, [bool]$HasMarker = $false)

    # D-08: Check for .ps1 (not .sh) in credential_process. Skipped when the
    # section carries the csg_managed marker -- the marker alone proves ownership.
    if (-not $HasMarker) {
        if ($CpValue -notlike '*get-customer-credentials.ps1*') { return $false }
    }

    # Exclude infrastructure profiles (D-06)
    if ($ProfileName -in $SkipProfiles) { return $false }

    # PROF-07: foreign-key sections are never sweep/cleanup-eligible.
    if ($HasForeign) { return $false }

    return $true
}

# Test-IsContaminatedHybrid: $true only for the exact incident shape -- a
# section that carries BOTH our credential_process line AND a foreign key.
# Distinct from Test-IsCsgProfile: fires only when this section WOULD have
# been swept under the old (pre-Phase-21) predicate. Drives the D-04/D-05/
# D-06/D-07 skip-record + stderr notice. Byte-parallel to bash is_contaminated_hybrid.
function Test-IsContaminatedHybrid {
    param([string]$CpValue, [string]$ProfileName, [bool]$HasForeign, [bool]$HasMarker = $false)

    # WR-03: $ProfileName is intentionally NOT checked against $SkipProfiles here.
    # Test-IsCsgProfile (sweep/cleanup ELIGIBILITY) still excludes $SkipProfiles,
    # so those sections are never deleted -- but the audit/warning predicate must
    # report contamination of ANY section, including infra profiles like
    # [default] (which drives every unqualified AWS CLI call and is arguably the
    # highest-value section to flag, not the lowest).
    #
    # PROF-08/D-06 (Phase 22): ownership is (credential_process signature OR
    # csg_managed marker) here too, so a marked-but-poisoned section is still
    # reported. Presence-only -- the marker value is not compared.
    if (-not $HasMarker) {
        if ($CpValue -notlike '*get-customer-credentials.ps1*') { return $false }
    }
    return $HasForeign
}

# Test-AlreadyRecordedSkip: $true iff $Name already has an entry in $SkipRecord
# (D-06 dedup, persists across invocations via the file). Fail-open on any
# read error -- a missing/corrupt record file must never block credential
# issuance, it just means the section gets recorded (again).
function Test-AlreadyRecordedSkip {
    param([string]$Name)

    if (-not (Test-Path -LiteralPath $SkipRecord)) { return $false }
    try {
        # WR-02: match on the SAME JSON-escaped string literal Write-GuardSkipRecord
        # writes (a raw-interpolated match breaks dedup the moment $Name contains a
        # '"', e.g. a legal INI section like [profile csg-"a]).
        $escapedName = $Name | ConvertTo-Json -Compress
        return [bool](Select-String -LiteralPath $SkipRecord -SimpleMatch "`"section`":$escapedName" -Quiet)
    }
    catch {
        return $false
    }
}

# Write-GuardSkipRecord: Append a one-line JSON record for a newly-seen
# contaminated-hybrid section (D-04/D-05) and emit a single stderr notice
# referencing the doctor subcommand (D-07). D-06: silent on repeat (dedup via
# Test-AlreadyRecordedSkip). Never fatal -- the append is best-effort.
function Write-GuardSkipRecord {
    param([string]$Name)

    if (Test-AlreadyRecordedSkip -Name $Name) { return }

    try {
        # WR-02: JSON-escape the (attacker-influenceable) profile name via
        # ConvertTo-Json rather than raw-interpolating it -- a name containing '"'
        # previously produced a malformed JSONL line and silently broke the
        # Test-AlreadyRecordedSkip dedup above.
        $firstSeen = [DateTimeOffset]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
        $record = [PSCustomObject]@{ section = $Name; first_seen = $firstSeen } | ConvertTo-Json -Compress
        # WR-01: create the parent directory rather than letting the catch below
        # swallow a missing-directory error. Dropping the audit record silently is
        # worse than the cost of one Test-Path -- the bash twin's routing blocks
        # mkdir CACHE_DIR for the same reason.
        $skipRecordDir = Split-Path -Parent $SkipRecord
        if (-not [string]::IsNullOrEmpty($skipRecordDir) -and -not (Test-Path -LiteralPath $skipRecordDir)) {
            New-Item -ItemType Directory -Force -Path $skipRecordDir | Out-Null
        }
        Add-Content -LiteralPath $SkipRecord -Value $record -Encoding UTF8
    }
    catch {
        # Best-effort -- never let the skip-record append block credential issuance.
    }

    # PROF-13/T-23-21: Invoke-DoDoctor calls Get-CsgProfiles to FIND these very
    # sections and repairs them in the same run, so the advisory below would tell
    # the engineer to run the command they are already running. The JSONL record
    # above is still written -- doctor genuinely did observe the contamination;
    # only the now-self-referential advisory is suppressed.
    if ($script:GuardSkipQuiet) { return }

    [Console]::Error.WriteLine("[guard] 외래 키 섹션 건너뜀: $Name (get-customer-credentials.ps1 doctor 로 복구 가능)")
}

# Test-IsCacheExpired: Returns $true if cache is expired or missing/unparseable.
# Reuses [DateTimeOffset]::Parse() pattern from Get-CachedCredentials.
# Note: ConvertFrom-Json auto-converts ISO 8601 strings to DateTime, losing the
# "Z" timezone suffix. We extract the raw Expiration string via regex to preserve
# UTC offset for correct [DateTimeOffset]::Parse() behavior.
function Test-IsCacheExpired {
    param([string]$CacheFilePath, [long]$NowEpoch = 0)

    # D-02: No cache file = expired
    if (-not (Test-Path -LiteralPath $CacheFilePath)) { return $true }

    try {
        # Extract Expiration from raw JSON to avoid ConvertFrom-Json DateTime auto-conversion
        $rawJson = Get-Content -Raw -LiteralPath $CacheFilePath
        if ($rawJson -match '"Expiration"\s*:\s*"([^"]+)"') {
            $exp = $Matches[1]
        } else {
            return $true
        }
        if ([string]::IsNullOrWhiteSpace($exp)) { return $true }

        $expEpoch = [DateTimeOffset]::Parse($exp).ToUnixTimeSeconds()
        if ($NowEpoch -eq 0) {
            $NowEpoch = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        }

        # Still valid if expiry is more than CacheSkewSeconds in the future
        return (($expEpoch - $NowEpoch) -le $CacheSkewSeconds)
    }
    catch {
        return $true  # Can't parse = treat as expired
    }
}

# Get-AccountIdFromCredentialProcess: Extract the 12-digit AWS account ID from a
# credential_process value; $null when the value carries no account id.
# IMPORTANT: Must match BOTH bash-style (--account-id) and PowerShell-style (-AccountId).
# This is the SINGLE home of that regex in this file -- every other caller
# (cache-path derivation, and the Phase 22 register subcommand) goes through here
# rather than re-spelling the pattern, so the two flag spellings can never drift apart.
function Get-AccountIdFromCredentialProcess {
    param([string]$CpValue)

    if ($CpValue -match '[-][-]?(?:account-id|AccountId)\s+(\d{12})') {
        return $Matches[1]
    }
    return $null
}

# Get-CachePathFromCredentialProcess: Extract account ID from credential_process
# value, return the cache file path.
# Phase 18: the cache key is <account-id>.json ONLY -- the client no longer knows
# the role name (the broker resolves it server-side), so no role segment exists.
function Get-CachePathFromCredentialProcess {
    param([string]$CpValue)

    $accountId = Get-AccountIdFromCredentialProcess -CpValue $CpValue
    if ($null -eq $accountId) { return $null }

    return (Join-Path $CacheDir "$accountId.json")
}

# Remove-ProfilesFromConfig: Remove INI sections for specified profiles.
# D-10: Backup as .bak.timestamp. D-09: regex line-by-line. D-11: atomic write.
# T-13-01: Reject profile names containing pipe character.
function Remove-ProfilesFromConfig {
    param(
        [string]$ConfigFile,
        [string[]]$ProfilesToRemove
    )

    if ($ProfilesToRemove.Count -eq 0) { return }
    if (-not (Test-Path -LiteralPath $ConfigFile)) { return }

    # D-10: Backup before modification.
    # PROF-12: $script:CsgBackupSession pins ONE backup path for a multi-step
    # session -- a fleet migration calls this helper and Remove-KeysFromProfile
    # several times, and a per-call .bak would both bury the only useful rollback
    # target (the pre-migration state) under N intermediate snapshots and break
    # the "one migrate run leaves one .bak" contract. Create-once, so the FIRST
    # mutating helper of the session takes the genuine pre-migration snapshot and
    # a session that mutates nothing leaves no .bak at all.
    $backupFile = if ([string]::IsNullOrEmpty($script:CsgBackupSession)) {
        "$ConfigFile.bak.$(Get-Date -Format 'yyyyMMddHHmmss')"
    } else {
        $script:CsgBackupSession
    }
    if (-not (Test-Path -LiteralPath $backupFile)) {
        Copy-Item -LiteralPath $ConfigFile -Destination $backupFile
    }

    # Build target set: PLAIN profile name => $true for O(1) lookup.
    # T-21-01: matching on the parsed name (not the raw "[profile X]" header
    # string) mirrors the collect-time parser, so a CRLF/double-space/quoted-
    # name header can no longer cause a false "removed" claim while the
    # section silently survives (Architecture Pattern 4).
    # T-13-01: Reject profile names containing pipe character
    $targetSections = @{}
    foreach ($p in $ProfilesToRemove) {
        if ($p -match '\|') {
            Write-Log "WARNING: skipping profile with pipe character in name: $p"
            continue
        }
        $targetSections[$p] = $true
    }
    if ($targetSections.Count -eq 0) { return }

    # Get-HeaderProfileName: parse a bracketed header line into a plain
    # profile name, using the SAME extraction shape as the collect-time
    # parser (Get-CsgProfiles), so delete-time matching can never silently
    # diverge from collect-time detection.
    function Get-HeaderProfileName {
        param([string]$Line)
        $headerLine = $Line.TrimEnd("`r")
        if ($headerLine -match '^\[profile\s+([^\]]+)\]\s*$') {
            return $Matches[1].Trim().Trim("'", '"')
        }
        elseif ($headerLine -eq '[default]') {
            return "default"
        }
        return $null
    }

    # Filter lines: skip target sections until next section header
    $lines = Get-Content -LiteralPath $ConfigFile
    $outputLines = [System.Collections.Generic.List[string]]::new()
    $skip = $false

    foreach ($line in $lines) {
        if ($line -match '^\[') {
            $name = Get-HeaderProfileName -Line $line
            $skip = ($null -ne $name -and $targetSections.ContainsKey($name))
            if ($skip) { continue }
        }
        if (-not $skip) {
            $outputLines.Add($line)
        }
    }

    # D-11: Atomic write via temp file + Move-Item
    # T-13-06: Write with no BOM using [IO.File]::WriteAllLines()
    $tmpFile = Join-Path (Split-Path -Parent $ConfigFile) ".config_tmp.$([IO.Path]::GetRandomFileName())"
    $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
    [IO.File]::WriteAllLines($tmpFile, $outputLines.ToArray(), $utf8NoBom)
    Move-Item -LiteralPath $tmpFile -Destination $ConfigFile -Force

    # Architecture Pattern 6 (D-08/D-09): post-condition re-read -- only claim
    # a deletion, and only print the .bak recovery notice, after confirming
    # via the SAME normalized-name parse that the section is genuinely gone
    # from the rewritten file. Closes the "backup created but nothing
    # removed" false-success mode (Pitfall 1/Pattern 4).
    $remainingNames = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($line in Get-Content -LiteralPath $ConfigFile) {
        if ($line -match '^\[') {
            $name = Get-HeaderProfileName -Line $line
            if ($null -ne $name) { [void]$remainingNames.Add($name) }
        }
    }

    $actuallyRemoved = [System.Collections.Generic.List[string]]::new()
    foreach ($p in $ProfilesToRemove) {
        if ($targetSections.ContainsKey($p) -and -not $remainingNames.Contains($p)) {
            $actuallyRemoved.Add($p)
        }
    }

    # CSG_RENAME_NOTICE: set ONLY around Invoke-CsgMigrate's rename deletion.
    # There the section is not lost -- it moved to `csg-<old>` -- so "섹션 N개
    # 삭제됨" reads as data loss (23-10 checkpoint finding 2). The migrate path
    # prints its own `[migrate] 개명:` line and one `[migrate] backup=` per run.
    # Sweep/cleanup deletions are genuine and keep the PROF-14 notice untouched.
    if ($actuallyRemoved.Count -gt 0 -and $env:CSG_RENAME_NOTICE -ne "1") {
        [Console]::Error.WriteLine("[guard] 섹션 $($actuallyRemoved.Count)개 삭제됨: $($actuallyRemoved -join ', ')")
        [Console]::Error.WriteLine("[guard] 복구하려면: cp `"$backupFile`" `"$ConfigFile`"")
    }
    # D-08: if nothing was confirmed removed, stay silent about .bak -- the
    # unconditional backup above is untouched; only this stderr notice is
    # conditional on a genuine, confirmed deletion.
}

# Get-CsgProfiles: Parse ~/.aws/config INI, return CSG profiles matching mode.
# Returns array of hashtables with ProfileName and CachePath keys.
# PROF-13: -ContaminatedOut is an OPTIONAL out-parameter collecting the names of
# CONTAMINATED HYBRID sections -- which never appear in the returned array,
# because Test-IsCsgProfile (sweep/cleanup eligibility) rejects any section
# carrying a foreign key. Invoke-DoDoctor needs exactly that rejected set, and
# this is how it gets it WITHOUT a third INI parser in this file. Omitting the
# parameter leaves every pre-existing call site unchanged.
function Get-CsgProfiles {
    param(
        [string]$ConfigFile,
        [string]$Mode,  # "expired" or "all"
        [System.Collections.Generic.List[string]]$ContaminatedOut = $null
    )

    if (-not (Test-Path -LiteralPath $ConfigFile)) { return @() }

    $nowEpoch = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $profiles = [System.Collections.Generic.List[hashtable]]::new()
    $currentProfile = ""
    $currentCp = ""
    $currentForeign = $false
    # PROF-08 (Phase 22): presence of a "csg_managed" key in the section. Tracked
    # beside $currentForeign and consumed as the second positive-ownership signal.
    $currentMarker = $false

    # Process a completed profile section
    function ProcessProfile {
        # WR-03: a marker-only section (csg_managed present, credential_process
        # absent) MUST stay visible here. The 22-01 rationale that called this
        # shape unreachable was wrong, and 22-REVIEW corrected it: register writes
        # the marker FIRST, so an abort between key 1 and key 4 leaves exactly this
        # section behind, and the Phase 23 migration's class-D marker backfill
        # produces it deliberately. If the old `-or $currentCp -eq ""` guard stayed,
        # such an orphan would be invisible to `cleanup --all` forever -- making
        # the documented "removes every CSG profile" claim false.
        if ($currentProfile -eq "") { return }
        if ($currentCp -eq "" -and -not $currentMarker) { return }

        # PROF-07/D-04..D-07: report (once) the exact incident shape -- a
        # section that would have been sweep-eligible under the OLD predicate
        # but carries a foreign key -- BEFORE gating on the new predicate.
        if (Test-IsContaminatedHybrid -CpValue $currentCp -ProfileName $currentProfile -HasForeign $currentForeign -HasMarker $currentMarker) {
            Write-GuardSkipRecord -Name $currentProfile
            # PROF-13: hand the name to the optional out-parameter. This is the
            # ONLY place the contaminated set is computed -- Invoke-DoDoctor
            # consumes it rather than re-walking the file.
            if ($null -ne $ContaminatedOut) { $ContaminatedOut.Add($currentProfile) }
        }

        if (-not (Test-IsCsgProfile -CpValue $currentCp -ProfileName $currentProfile -HasForeign $currentForeign -HasMarker $currentMarker)) { return }

        if ($Mode -eq "all") {
            $cachePath = Get-CachePathFromCredentialProcess -CpValue $currentCp
            $profiles.Add(@{ ProfileName = $currentProfile; CachePath = $cachePath })
        } else {
            # mode="expired": only include if cache file EXISTS and is expired;
            # missing cache = never-used = protected.
            # T-oro-01: the caller-side Test-Path guard short-circuits before
            # Test-IsCacheExpired, mirroring the bash `[[ -f "$cache_path" ]]`
            # guard, so a profile that has never written a cache file is NEVER
            # swept. Protects ALL never-used profiles, complementing PROF-06's
            # single-active-profile protection. Test-IsCacheExpired is unchanged.
            $cachePath = Get-CachePathFromCredentialProcess -CpValue $currentCp
            if ($null -eq $cachePath) { return }
            if (-not (Test-Path -LiteralPath $cachePath)) { return }
            if (Test-IsCacheExpired -CacheFilePath $cachePath -NowEpoch $nowEpoch) {
                $profiles.Add(@{ ProfileName = $currentProfile; CachePath = $cachePath })
            }
        }
    }

    foreach ($line in Get-Content -LiteralPath $ConfigFile) {
        # Architecture Pattern 3: reset tracking state on ANY bracketed header,
        # not only [profile ...]/[default] -- otherwise a [sso-session ...] /
        # [services ...] / [plugins] block's key lines (which may include
        # foreign keys like sso_start_url) silently leak into whatever
        # [profile ...] section preceded it.
        if ($line -match '^\[') {
            ProcessProfile
            $currentProfile = ""
            $currentCp = ""
            $currentForeign = $false
            $currentMarker = $false

            $headerLine = $line.TrimEnd("`r")
            if ($headerLine -match '^\[profile\s+([^\]]+)\]\s*$') {
                $currentProfile = $Matches[1].Trim().Trim("'", '"')
            }
            elseif ($headerLine -eq '[default]') {
                $currentProfile = "default"
            }
            # else: a non-profile header ([sso-session ...] etc.) -- leave
            # $currentProfile = "" so its key lines are parsed below but
            # never attributed to any profile.
            continue
        }

        # Not inside a tracked profile section -- parse-but-ignore.
        if ($currentProfile -eq "") { continue }

        if ($line -match '^\s*credential_process\s*=\s*(.+)$') {
            $currentCp = $Matches[1]
        }

        # Foreign-key detection: evaluated for every key line independently
        # of the credential_process branch above (Architecture Pattern 2/3).
        $eqIndex = $line.IndexOf('=')
        if ($eqIndex -gt 0) {
            $key = $line.Substring(0, $eqIndex).Trim().ToLowerInvariant()
            if (Test-IsForeignKey -Key $key) {
                $currentForeign = $true
            }
            # PROF-08: ownership marker presence. The VALUE after "=" is
            # deliberately ignored -- any csg_managed key marks the section,
            # so a forged/stale/future version string cannot flip the verdict.
            if ($key -eq 'csg_managed') {
                $currentMarker = $true
            }
        }
    }

    # Process last profile (don't forget!)
    ProcessProfile

    return ,$profiles.ToArray()
}

# Lock-Sweep: Acquire exclusive file lock for sweep concurrency protection (D-04).
# Uses [IO.File]::Open() with FileShare.None. Returns $true on success, $false on
# failure (lock held by an ACTIVE process).
#
# T-23-29 -- WHY THERE IS NO STALE-PID RECOVERY HERE (and why the version that
# had one did not lock at all):
#   The lock is an OS-held exclusive handle (flock on Unix, a share-mode handle on
#   Windows). Both are released by the KERNEL when the holder exits, including on
#   SIGKILL -- so a lock file left behind by a dead process is just a file, and
#   the very next Open() succeeds on it. A stale HANDLE cannot exist. (bash's twin
#   needs its stale-PID dance because `mkdir` leaves a directory that nothing
#   releases; the two implementations reach the same guarantee by different means.)
#   The previous implementation read the holder's PID out of the LOCK FILE ITSELF
#   on the failure path. That read is IMPOSSIBLE while FileShare::None is in force
#   -- Get-Content, ReadAllText and even Open(Read, FileShare::ReadWrite) all throw
#   "being used by another process" -- so the PID lookup ALWAYS threw, every
#   contender always concluded "stale", deleted the live holder's lock file and
#   acquired a second lock on a fresh inode. The lock excluded nobody. Treating a
#   failed Open() as "held" is both correct and the fail-safe direction.
function Lock-Sweep {
    # T-23-29 / PROF-12: the default IS the shared lock path. Invoke-MigrationOnce
    # takes THIS lock rather than minting a second one -- a private migrate lock
    # would let sweep and migrate interleave two rewrites of the same
    # ~/.aws/config. Passing $LockFilePath explicitly stays supported for the
    # cleanup suite's direct calls.
    param([string]$LockFilePath = (Join-Path $CacheDir ".sweep.lock"))

    # WR-09: THE LOCK IS A FILE, IN BOTH CLIENTS. bash used to take a DIRECTORY
    # at this identical path, so on any machine where both clients can run
    # (Windows with WSL/Git-Bash, or a mixed install) residue from one
    # PERMANENTLY disabled the other. Two things are needed on this side:
    #
    #   (a) a leftover DIRECTORY from a pre-Phase-23 bash client makes
    #       [IO.File]::Open throw forever, which the catch below would report as
    #       "held" on every future run -- sweep and migrate become silent no-ops
    #       for good. Nothing holds an OS lock on a directory, so it is residue,
    #       not a lock: clear it.
    #
    #   (b) the bash twin's lock is an O_EXCL file plus its pid, NOT an OS handle
    #       (there is no portable flock on macOS), so [IO.File]::Open would happily
    #       succeed while bash is mid-rewrite. A LIVE pid in the file is therefore
    #       consulted BEFORE the Open. This is not the stale-PID dance T-23-29
    #       removed: that one ran on the FAILURE path, where FileShare::None makes
    #       the read throw and every contender wrongly concluded "stale". Here the
    #       read happens before any handle exists, and only a pid that is
    #       DEFINITELY alive is treated as held -- an unreadable or dead pid falls
    #       through to Open(), which remains the authority for pwsh<->pwsh.
    try {
        if (Test-Path -LiteralPath $LockFilePath -PathType Container) {
            Remove-Item -LiteralPath $LockFilePath -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    catch { }

    if (Test-Path -LiteralPath $LockFilePath -PathType Leaf) {
        $holderPid = 0
        try {
            $raw = [IO.File]::ReadAllText($LockFilePath)
            $digits = ($raw -replace '[^0-9]', '')
            if (-not [string]::IsNullOrEmpty($digits)) { $holderPid = [int]$digits }
        }
        catch {
            # Unreadable => another pwsh holds it under FileShare::None. Open()
            # below will fail anyway; leave the verdict to it.
            $holderPid = 0
        }
        if ($holderPid -gt 0 -and $holderPid -ne $PID) {
            $holderAlive = $false
            try { $holderAlive = $null -ne (Get-Process -Id $holderPid -ErrorAction SilentlyContinue) } catch { $holderAlive = $false }
            if ($holderAlive) {
                $script:SweepLockStream = $null
                return $false
            }
        }
    }

    try {
        $script:SweepLockStream = [IO.File]::Open(
            $LockFilePath,
            [IO.FileMode]::OpenOrCreate,
            [IO.FileAccess]::ReadWrite,
            [IO.FileShare]::None  # exclusive
        )
        # Our PID, for post-mortem inspection of an orphaned lock file only. It is
        # deliberately NOT consulted on the failure path below -- see the header.
        $pidBytes = [System.Text.Encoding]::UTF8.GetBytes("$PID")
        $script:SweepLockStream.SetLength(0)
        $script:SweepLockStream.Write($pidBytes, 0, $pidBytes.Length)
        $script:SweepLockStream.Flush()
        $script:SweepLockPath = $LockFilePath
        return $true
    }
    catch {
        # The kernel refused the exclusive handle, so a LIVE process holds it.
        # Non-blocking by design: the loser returns immediately and in silence,
        # because every operation behind this lock is idempotent and the next
        # invocation picks the work up.
        $script:SweepLockStream = $null
        return $false
    }
}

# Unlock-Sweep: Release the sweep lock (Pitfall 4: caller MUST use try/finally).
# Removes the lock FILE only when this process actually held the handle: unlinking
# it otherwise would let a third process create a fresh inode and acquire a second
# "exclusive" lock while the real holder is still working.
function Unlock-Sweep {
    if ($null -eq $script:SweepLockStream) { return }

    $script:SweepLockStream.Dispose()
    $script:SweepLockStream = $null

    $lockFile = if ([string]::IsNullOrEmpty($script:SweepLockPath)) {
        Join-Path $CacheDir ".sweep.lock"
    } else {
        $script:SweepLockPath
    }
    $script:SweepLockPath = ""
    Remove-Item -LiteralPath $lockFile -Force -ErrorAction SilentlyContinue
}

# Invoke-SweepExpiredProfiles: Called on every normal invocation (D-01).
# Scans all CSG profiles, removes those whose cache is expired or missing.
#
# PROF-06: If -ExcludeCachePath is supplied, the profile owning that cache
# file is excluded from sweep. This protects the *currently invoked* profile
# from self-removal before its first STS call has had a chance to write its
# own cache (D-02 would otherwise classify it as expired and the same
# invocation would delete its own [profile X] section).
function Invoke-SweepExpiredProfiles {
    param([string]$ExcludeCachePath = "")

    $configFile = Join-Path $HomeDir ".aws/config"
    if (-not (Test-Path -LiteralPath $configFile)) { return }

    if (-not (Lock-Sweep)) { return }

    try {
        $expiredProfiles = Get-CsgProfiles -ConfigFile $configFile -Mode "expired"

        # D-03: No output when nothing removed
        if ($null -eq $expiredProfiles -or $expiredProfiles.Count -eq 0) { return }

        # PROF-06: Drop the active invocation's own profile from the sweep set.
        if (-not [string]::IsNullOrEmpty($ExcludeCachePath)) {
            $expiredProfiles = @($expiredProfiles | Where-Object {
                $_.CachePath -ne $ExcludeCachePath
            })
            if ($expiredProfiles.Count -eq 0) { return }
        }

        # Remove expired profiles from config
        $profileNames = $expiredProfiles | ForEach-Object { $_.ProfileName }
        Remove-ProfilesFromConfig -ConfigFile $configFile -ProfilesToRemove $profileNames

        # Delete corresponding cache files (D-09)
        # WR-01: skip any profile name containing '|' -- Remove-ProfilesFromConfig's
        # T-13-01 pipe-injection defense rejects such names, leaving the config
        # section in place; wiping its cache anyway would orphan it in a
        # neither-swept-nor-cached state until an operator manually intervenes.
        foreach ($p in $expiredProfiles) {
            if ($p.ProfileName -match '\|') { continue }
            if ($null -ne $p.CachePath -and (Test-Path -LiteralPath $p.CachePath)) {
                Remove-Item -LiteralPath $p.CachePath -Force -ErrorAction SilentlyContinue
            }
        }

        # D-03: Log with [sweep] prefix
        $namesCsv = ($profileNames -join ", ")
        [Console]::Error.WriteLine("[sweep] removed $($expiredProfiles.Count) expired profiles: $namesCsv")
    }
    finally {
        Unlock-Sweep
    }
}

# Invoke-DoCleanup: Handle "cleanup" (expired only) and "cleanup --all" (all CSG).
function Invoke-DoCleanup {
    param([bool]$AllMode = $false)

    $configFile = Join-Path $HomeDir ".aws/config"

    if (-not (Test-Path -LiteralPath $configFile)) {
        [Console]::Error.WriteLine("[cleanup] ~/.aws/config not found")
        exit 0
    }

    $mode = if ($AllMode) { "all" } else { "expired" }

    $targetProfiles = Get-CsgProfiles -ConfigFile $configFile -Mode $mode

    # Report results
    if ($null -eq $targetProfiles -or $targetProfiles.Count -eq 0) {
        if ($AllMode) {
            [Console]::Error.WriteLine("[cleanup] No CSG profiles found")
        } else {
            [Console]::Error.WriteLine("[cleanup] No expired CSG profiles found")
        }
        exit 0
    }

    # Remove profiles from config
    $profileNames = $targetProfiles | ForEach-Object { $_.ProfileName }
    Remove-ProfilesFromConfig -ConfigFile $configFile -ProfilesToRemove $profileNames

    # Delete cache files
    # WR-01: skip any profile name containing '|' (see Invoke-SweepExpiredProfiles
    # for why -- Remove-ProfilesFromConfig's pipe-injection defense leaves such a
    # section's config in place, so its cache must not be wiped either).
    foreach ($p in $targetProfiles) {
        if ($p.ProfileName -match '\|') { continue }
        if ($null -ne $p.CachePath -and (Test-Path -LiteralPath $p.CachePath)) {
            Remove-Item -LiteralPath $p.CachePath -Force -ErrorAction SilentlyContinue
        }
    }

    # For --all mode, also delete any orphan cache files
    if ($AllMode) {
        Get-ChildItem -Path $CacheDir -Filter "*.json" -ErrorAction SilentlyContinue |
            Remove-Item -Force -ErrorAction SilentlyContinue
    }

    # Summary report
    $namesCsv = ($profileNames -join ", ")
    if ($AllMode) {
        [Console]::Error.WriteLine("[cleanup] Removed $($targetProfiles.Count) CSG profiles: $namesCsv")
    } else {
        [Console]::Error.WriteLine("[cleanup] Removed $($targetProfiles.Count) expired profiles: $namesCsv")
    }
    exit 0
}

# --- register subcommand helpers (PROF-08/10/11) ---
#
# PowerShell twin of the get-customer-credentials.sh register helper block. The
# bash side is the parity source of truth: reason tokens, the stdout rules, the
# alternative-name rule, the write order and the 7-row decision table must stay
# byte-identical in behaviour (22-08 PARITY-08 compares them mechanically).
#
# Unlike the bash twin, PLACEMENT here is only a language requirement, not a test
# contract: test/credentials-guard.test.ps1 observes this file BEHAVIOURALLY (it
# routes and parses at top level, so it cannot be dot-sourced). Functions must be
# defined before the routing block that calls them, hence this position.
#
# STDOUT CONTRACT (register mode) -- distinct from the credential_process 5-key
# JSON contract declared in the file header:
#   success -> exactly ONE line on stdout: the profile name. Nothing else.
#   abort   -> stdout stays completely EMPTY; every diagnostic goes to stderr.
# Every stderr line is prefixed "[register] " (same convention as [sweep]/
# [cleanup]/[guard]) and every abort emits a machine-readable
# "[register] reason=<token>" line FIRST.
#
# WR-04 applies to every line below: every diagnostic goes through
# [Console]::Error.WriteLine and NEVER through the host/Information-stream writer
# banned by the WR-04 note at the top of this file (it can be interleaved into
# captured stdout by the default console host). The phase verification gate is a
# raw occurrence count of that cmdlet name across this file, so this comment
# deliberately does not spell it out.

function Write-RegisterLog {
    param([string]$Message)
    [Console]::Error.WriteLine("[register] $Message")
}

# Write-RegisterReason: emit the machine-readable abort token. ALWAYS the first
# line of an abort, so a caller (or a test) can grep it without parsing the
# Korean prose that follows.
# Tokens: config-unparseable | account-mismatch | contaminated-hybrid |
#         foreign-profile | unknown-profile | reserved-profile-name |
#         invalid-account-name | invalid-account-id | invalid-arguments |
#         missing-dependency | write-failed | postcondition-failed
function Write-RegisterReason {
    param([string]$Token)
    [Console]::Error.WriteLine("[register] reason=$Token")
}

# Stop-RegisterWithError: reason line, then one "[register] <msg>" line per
# message, then exit 1. NEVER writes to stdout (abort contract: empty stdout).
# Multi-paragraph aborts that need helper output in the middle call
# Write-RegisterReason themselves and end with `exit 1`.
function Stop-RegisterWithError {
    param([string]$Reason, [string[]]$Messages = @())

    Write-RegisterReason -Token $Reason
    foreach ($msg in $Messages) {
        [Console]::Error.WriteLine("[register] $msg")
    }
    exit 1
}

# ConvertTo-NormalizedNameToken: D-03 profile-name rule, byte-parallel to bash
# normalize_name_token. lowercase -> every character outside [a-z0-9-] becomes
# '-' -> collapse runs of '-' -> strip leading and trailing '-'.
# -creplace (case-SENSITIVE) is deliberate: the input is already lowercased, and
# a case-insensitive [^a-z0-9-] would behave differently on any future edit that
# drops the ToLowerInvariant. Verified equal to the bash pipeline on
# "Example-Dev" -> example-dev, "Demo Ops" -> demo-ops,
# "DemoCo_Prod!!" -> democo-prod.
# This function stays PREFIX-FREE. Phase 23 landed the `csg-` namespace in
# Get-DerivedProfileName, not here, because Get-SuggestedAlternativeName also
# calls this normalizer and already emits its own `csg-` literal -- prefixing
# here would double-prefix every suggested name.
function ConvertTo-NormalizedNameToken {
    param([string]$Raw)

    if ($null -eq $Raw) { return "" }
    $token = $Raw -creplace "[`r`n]", ''
    $token = $token.ToLowerInvariant()
    $token = $token -creplace '[^a-z0-9-]', '-'
    $token = $token -creplace '-{2,}', '-'
    $token = $token -creplace '^-', ''
    $token = $token -creplace '-$', ''
    return $token
}

# Get-DerivedProfileName: normalize, strip a single leading `csg-`, assert the
# token is legal, then return `csg-<token>` (PROF-09 / D-08: every name this
# project mints lives in the `csg-` namespace). Aborts (invalid-account-name)
# when the token is not legal.
# T-22-04: the assertion blocks two things at once -- an empty or all-hyphen
# token would emit a syntax-breaking "[profile -]" INI header, and a leading '-'
# would be parsed as a flag by the very `aws` call that writes it. It is applied
# to the PRE-PREFIX token on purpose: checking the final `csg-<token>` instead
# would re-open exactly that hazard, because the bare string `csg-` satisfies
# "starts with [a-z0-9]" and would sail through as `[profile csg-]` (T-23-04).
# \z (absolute end) rather than $ (which also matches before a trailing newline
# in .NET) so the assertion is exactly as strict as the bash ERE.
#
# IDEMPOTENCY (D-08, 22-03 Decision #2): Show-RegisterRetrySuggestion prints a
# retry command whose --account-name is Get-SuggestedAlternativeName's output,
# which ALREADY carries a `csg-` literal, and tells the engineer to run it
# verbatim. Without the strip that command would mint `csg-csg-<name>` -- the
# printed command would not produce the printed name.
# ConvertTo-DisplaySafe: bash sanitize_for_display's twin (T-22-05).
# Show-RegisterRetrySuggestion echoes only normalized [a-z0-9-] tokens, but two
# abort paths interpolate RAW input -- the BILLING `accountName` (an external API
# response that SKILL.md tells the agent to pass 원문 그대로) and an unrecognised
# argv element. Control sequences there can rewrite the terminal title, erase
# printed lines, or recolour an abort so it reads as a success.
# \p{Cc} covers all control characters (so CR cannot overwrite a line and LF
# cannot forge extra "[register] ..." lines); \p{Cf} additionally drops bidi
# overrides, which can visually reorder text without any control byte.
function ConvertTo-DisplaySafe {
    param([string]$Text)
    if ($null -eq $Text) { return "" }
    $safe = $Text -creplace '[\p{Cc}\p{Cf}]', ''
    if ($safe.Length -gt 120) { $safe = $safe.Substring(0, 120) }
    return $safe
}

# Test-IsSkipProfile: $true when $Name is one of the infrastructure sections this
# tool must never operate on ($SkipProfiles). Twin of bash is_skip_profile.
#
# CR-03: Test-IsContaminatedHybrid is deliberately BLIND to $SkipProfiles so the
# REPORTING predicate can flag contamination in [default] and the other infra
# sections -- that rationale is sound. The defect was that Invoke-DoDoctor step
# (3) and Invoke-DoMigrate pass 1 fed that same unfiltered list straight into
# Remove-KeysFromProfile as their ACTION list. `csg-login` is the login anchor
# every customer session is brokered through, and `doctor` would strip its
# credential_process and exit 0.
#
# -ccontains: AWS profile names are case-SENSITIVE, same as the register veto.
function Test-IsSkipProfile {
    param([string]$Name)
    return ($SkipProfiles -ccontains $Name)
}

function Get-DerivedProfileName {
    # -NoAbort: return $null instead of exiting when the token is not legal.
    # PROF-12 needs this because bash's `( derive_profile_name ... )` SUBSHELL
    # idiom -- which contains register_die's `exit` -- has no PowerShell analogue:
    # `exit` inside a function terminates the whole script and cannot be caught,
    # so an in-process call would take the migration down mid-fleet. The switch
    # keeps ONE naming rule and ONE regex in this file; re-deriving the check at
    # the migrate call site is what it exists to prevent.
    param([string]$AccountName, [switch]$NoAbort)

    $name = ConvertTo-NormalizedNameToken -Raw $AccountName
    $name = $name -creplace '^csg-', ''

    if ($name -cnotmatch '^[a-z0-9][a-z0-9-]{0,63}\z') {
        if ($NoAbort) { return $null }
        Stop-RegisterWithError -Reason 'invalid-account-name' -Messages @(
            "중단: --account-name 을 프로필 이름으로 정규화할 수 없습니다.",
            "입력: '$(ConvertTo-DisplaySafe -Text $AccountName)' / 정규화 결과: '${name}'",
            "프로필 이름은 ^[a-z0-9][a-z0-9-]{0,63}`$ 를 만족해야 합니다 (영소문자 또는 숫자로 시작).",
            "영숫자를 포함한 계정명으로 다시 시도하세요. ~/.aws/config 는 변경되지 않았습니다."
        )
    }

    return "csg-$name"
}

# Get-SuggestedAlternativeName: the D-04 alternative name.
# Returns @{ Name = <csg-...>; CorpContributed = <bool> } so the caller can add
# "회사명을 주면 더 구체적인 이름을 제안할 수 있습니다" when corp did not help.
# Never emits a doubled hyphen: the emptiness test is on the NORMALIZED corp
# token, not on the raw argument.
function Get-SuggestedAlternativeName {
    param([string]$CorpName, [string]$AccountName)

    $corpToken = ConvertTo-NormalizedNameToken -Raw $CorpName
    $accountToken = ConvertTo-NormalizedNameToken -Raw $AccountName

    if (-not [string]::IsNullOrEmpty($corpToken)) {
        return @{ Name = "csg-$corpToken-$accountToken"; CorpContributed = $true }
    }
    return @{ Name = "csg-$accountToken"; CorpContributed = $false }
}

# Stop-ConfigUnparseable: D-07 / PROF-10 criterion 3. A non-zero
# `aws configure list-profiles` is NEVER read as "no profiles exist" -- it means
# the config is unreadable, so collision detection is impossible and the only
# safe action is to stop before writing.
# S2: mirrors the PROF-14 recovery-notice format at Remove-ProfilesFromConfig.
# register creates NO backup of its own (it never rewrites the file) -- it only
# LISTS backups other code paths left behind.
# D-07 explicitly rejects auto-diagnosis: these are CANDIDATES, never a verdict.
# No BOM/duplicate-section self-detection is attempted here, by decision.
# WR-05: -Caller is "enumeration" (list-profiles itself failed -- the config really
# is unreadable) or "classification" (a per-key `aws configure get` returned 255
# AFTER list-profiles already reported the name). aws-cli 2.35.20 returns 255 for
# BOTH an unparseable config AND a profile that does not exist, so on the
# classification branch the far likelier cause is that the profile VANISHED between
# enumeration and classification -- a TOCTOU race with a concurrent cleanup/sweep or
# another agent's register. The BOM / duplicate-header cause list is a misdiagnosis
# there, and `cp <backup> ~/.aws/config` would undo unrelated work to "fix" a
# perfectly healthy file.
#
# list_recent_backups_note -- PowerShell half of the shared ordering rule; the
# bash anchor of the same name in get-customer-credentials.sh carries the full
# derivation. Applies here, to Stop-DoctorUnparseable and to
# Stop-MigrateUnparseable.
#
#   NEVER order these by LastWriteTime. Order by NAME.
#
# Every backup is `config.bak.<yyyyMMddHHmmss>` (fixed width, zero padded), so
# the NAME is already a total chronological key. Sorting on LastWriteTime was a
# straight port of bash's `ls -t` and inherited its defect: two backups written
# back-to-back in one run can carry the SAME timestamp, and on that tie
# `Sort-Object` is documented as UNSTABLE (no -Stable here), so which backup the
# recovery line names is not merely wrong-by-tie-break as in bash -- it is
# undefined. Name ordering removes the tie entirely: a directory cannot hold two
# entries with the same name, so the sort is total by construction.
# The Where-Object shape filter is not cosmetic -- the ordering argument holds
# only for the timestamp shape, and without it a hand-made `config.bak.orig`
# would sort above every real backup and always be offered. `[0-9]` is spelled
# out rather than `\d` because .NET's `\d` also matches non-ASCII Unicode digits.
function Stop-ConfigUnparseable {
    param([int]$ExitCode, [string]$Caller = "enumeration")

    $configFile = Join-Path $HomeDir ".aws/config"

    Write-RegisterReason -Token "config-unparseable"
    Write-RegisterLog -Message "중단: ~/.aws/config 를 읽을 수 없습니다 (aws configure list-profiles exit=${ExitCode})."
    Write-RegisterLog -Message "이 상태에서는 기존 프로필을 볼 수 없으므로 '충돌 없음'으로 간주하지 않고 중단합니다."
    Write-RegisterLog -Message "흔한 원인:"
    Write-RegisterLog -Message "  - 파일 맨 앞의 UTF-8 BOM (에디터가 붙였을 수 있음)"
    Write-RegisterLog -Message "  - 같은 [profile X] 섹션 헤더가 두 번 존재"
    Write-RegisterLog -Message "  - 닫는 ']' 가 빠진 헤더"
    if ($Caller -ceq "classification") {
        Write-RegisterLog -Message "  - 프로필이 조회 도중 사라졌을 수 있습니다 (동시 실행 중인 cleanup/sweep 또는 다른 register)"
        Write-RegisterLog -Message "이 경우 설정 파일 자체는 멀쩡합니다. 백업을 되돌리면 무관한 작업까지 되돌아가므로,"
        Write-RegisterLog -Message "복구 명령 대신 같은 명령을 그대로 다시 실행하세요."
    }

    $backups = @()
    try {
        $awsDir = Split-Path -Parent $configFile
        if (Test-Path -LiteralPath $awsDir) {
            # Ordered by NAME, never by LastWriteTime -- see list_recent_backups_note.
            $backups = @(Get-ChildItem -LiteralPath $awsDir -Filter "config.bak.*" -File -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -match '\.bak\.[0-9]{14}$' } |
                Sort-Object -Property Name -Descending |
                Select-Object -First 3)
        }
    }
    catch {
        # Best-effort listing only -- a failure here must not mask the abort.
        $backups = @()
    }

    if ($backups.Count -eq 0) {
        Write-RegisterLog -Message "최근 백업: 백업 파일이 없습니다"
    }
    else {
        Write-RegisterLog -Message "최근 백업:"
        foreach ($backup in $backups) {
            Write-RegisterLog -Message "  $($backup.FullName)"
        }
        # The runnable recovery command is offered ONLY when the config really is
        # the suspect. On the classification branch it would restore a healthy
        # file over unrelated work (WR-05).
        if ($Caller -cne "classification") {
            [Console]::Error.WriteLine("[register] 복구하려면: cp `"$($backups[0].FullName)`" `"$configFile`"")
        }
    }

    Write-RegisterLog -Message "아무것도 기록하지 않았습니다 — ~/.aws/config 는 변경되지 않았습니다."
    exit 1
}

# Test-SectionHasForeignKey: walk ONLY the [profile <name>] section of
# <ConfigFile> and return the first key matching Test-IsForeignKey; $null when
# the section is clean or absent.
# S5: deliberately NOT Get-CsgProfiles -- that whole-file walker calls
# Write-GuardSkipRecord, which appends to guard-skips.jsonl and prints [guard]
# lines, so calling it during a registration would fabricate guard warnings and
# mutate a Phase 21 audit file. It also uses a nested-function closure over
# parent-scope variables, which cannot be written without $script:/Set-Variable;
# this helper takes explicit parameters and returns a value instead.
# T-22-05: returns the key NAME only. Key VALUES are never returned or printed
# (an SSO section carries an internal start URL).
function Test-SectionHasForeignKey {
    param([string]$ConfigFile, [string]$ProfileName)

    if (-not (Test-Path -LiteralPath $ConfigFile)) { return $null }

    $inSection = $false
    foreach ($rawLine in Get-Content -LiteralPath $ConfigFile) {
        $trimmed = $rawLine.TrimEnd("`r").Trim()

        # Section boundary. Same "^\[ resets state" rule the collector uses, but
        # independent logic (Architecture Pattern 3).
        if ($trimmed.StartsWith("[")) {
            $name = $trimmed.Substring(1)
            $closeIndex = $name.IndexOf("]")
            if ($closeIndex -ge 0) { $name = $name.Substring(0, $closeIndex) }
            $name = $name.Trim()
            if ($name.StartsWith("profile ")) { $name = $name.Substring(8) }
            # WR-08: strip surrounding quotes, exactly as Remove-ProfilesFromConfig
            # does. Without this, a `[profile "acme"]` section is never entered,
            # the config half of the foreign probe reports "clean", and the
            # foreign-key veto silently degrades to the aws_access_key_id-only
            # probe.
            $name = $name.Trim().Trim("'", '"')
            # -ceq: AWS profile names are case-SENSITIVE; PowerShell -eq is not.
            $inSection = ($name -ceq $ProfileName)
            continue
        }

        if (-not $inSection) { continue }
        if ($trimmed.StartsWith("#") -or $trimmed.StartsWith(";")) { continue }

        $eqIndex = $trimmed.IndexOf("=")
        if ($eqIndex -le 0) { continue }

        $key = $trimmed.Substring(0, $eqIndex).Trim().ToLowerInvariant()
        if (Test-IsForeignKey -Key $key) { return $key }
    }

    return $null
}

# Invoke-AwsConfigureGet: run `aws configure get <key> --profile <profile>` and
# return @{ Value = <stdout>; Rc = <exit code> } so the caller can branch three
# ways: 0 = present, 1 = absent, 255 = config unparseable (or the profile
# vanished). Verified against aws-cli 2.35.20.
#
# S4/T-22-03: $LASTEXITCODE is read on the VERY NEXT LINE after the native call.
# Two distinct hazards are covered here:
#   (a) $ErrorActionPreference = "Stop" (:37) does NOT turn a native binary's
#       non-zero exit into a terminating error. $LASTEXITCODE is the only signal,
#       and ANY command in between overwrites it -- a 255 would then degrade
#       silently into "no value", which is fail-OPEN in the exact helper whose
#       job is to prevent one.
#   (b) On Windows PowerShell 5.1 a native command that writes to stderr while
#       stderr is redirected can raise NativeCommandError, which "Stop" makes
#       terminating. Temporarily relaxing the preference (the PS analogue of
#       bash's `set +e` fence) plus the catch keeps that on the fail-CLOSED side:
#       Rc stays 255 and the caller aborts, rather than the script dying bare.
#
# NEVER use the dotted `profile.<name>.<key>` form: it is a verified
# false-negative for names containing '.'.
function Invoke-AwsConfigureGet {
    param([string]$Key, [string]$ProfileName)

    $value = ""
    $rc = 255

    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $output = & aws configure get $Key --profile $ProfileName 2>$null
        $rc = $LASTEXITCODE
        if ($rc -eq 0) {
            $value = (@($output) -join "`n").Trim()
        }
    }
    catch {
        $rc = 255
    }
    finally {
        $ErrorActionPreference = $previousPreference
    }

    return @{ Value = $value; Rc = $rc }
}

# Invoke-ProfileForeignProbe: return
#   @{ Found = <bool>; Key = <key name>; Source = "config"|"credentials" }
# T-22-02: BOTH halves are required. The config-side INI scan is free and catches
# a credential_process injected into an existing SSO/role section; the
# aws_access_key_id probe reads the MERGED view and is the only way to see the
# ~/.aws/credentials half, which is structurally invisible to any config reader
# and whose static keys silently outrank credential_process.
function Invoke-ProfileForeignProbe {
    param([string]$ProfileName)

    $configFile = Join-Path $HomeDir ".aws/config"

    $found = Test-SectionHasForeignKey -ConfigFile $configFile -ProfileName $ProfileName
    if ($null -ne $found) {
        return @{ Found = $true; Key = $found; Source = "config" }
    }

    $probe = Invoke-AwsConfigureGet -Key "aws_access_key_id" -ProfileName $ProfileName
    if ($probe.Rc -eq 0) {
        return @{ Found = $true; Key = "aws_access_key_id"; Source = "credentials" }
    }
    if ($probe.Rc -ne 1) {
        Stop-ConfigUnparseable -ExitCode $probe.Rc -Caller "classification"
    }

    return @{ Found = $false; Key = ""; Source = "" }
}

# Get-CollisionClassLabel: name the collision CLASS for the abort message
# (Pattern 5). Key NAMES only -- never a key value.
function Get-CollisionClassLabel {
    param([string]$Key, [string]$Source)

    $k = $Key.ToLowerInvariant()

    if ($k.StartsWith("sso_")) { return "SSO 프로필" }
    if ($k.StartsWith("role_")) { return "role-chaining 프로필" }

    $roleChainingKeys = @("source_profile", "credential_source", "mfa_serial",
                          "external_id", "duration_seconds", "web_identity_token_file")
    if ($roleChainingKeys -ccontains $k) { return "role-chaining 프로필" }

    if ($k.StartsWith("aws_")) {
        if ($Source -ceq "credentials") { return "~/.aws/credentials 정적 키 프로필" }
        return "config 내 정적 키 프로필"
    }

    return "알 수 없는 기존 섹션"
}

# Get-ExistingProfileClassification: RESEARCH Pattern 3, five stages in the same
# order as bash classify_existing_profile. Returns
#   @{ Class = owned-same|owned-different|contaminated|foreign|unknown
#      BlockingKey; BlockingSource; ExistingAccount }
# Read-only: at most 4 `aws` subprocesses, no writes, no network, no Bearer.
function Get-ExistingProfileClassification {
    param([string]$ProfileName, [string]$RequestedAccountId)

    $hasMarker = $false
    $cpSignature = $false
    $cpValue = ""

    # (1) marker probe -- PRESENCE only; the value is never compared (Pitfall 4).
    $markerProbe = Invoke-AwsConfigureGet -Key "csg_managed" -ProfileName $ProfileName
    if ($markerProbe.Rc -eq 0) {
        $hasMarker = $true
    }
    elseif ($markerProbe.Rc -ne 1) {
        Stop-ConfigUnparseable -ExitCode $markerProbe.Rc -Caller "classification"
    }

    # (2) legacy credential_process signature. The substring is deliberately
    # language-AGNOSTIC ("get-customer-credentials", not ".ps1"): a profile the
    # bash twin registered is still CSG-owned and must not be misread as foreign.
    $cpProbe = Invoke-AwsConfigureGet -Key "credential_process" -ProfileName $ProfileName
    if ($cpProbe.Rc -eq 0) {
        $cpValue = $cpProbe.Value
        if ($cpValue -clike '*get-customer-credentials*') { $cpSignature = $true }
    }
    elseif ($cpProbe.Rc -ne 1) {
        Stop-ConfigUnparseable -ExitCode $cpProbe.Rc -Caller "classification"
    }

    # (3) no positive ownership -> foreign or unknown. Probe anyway so the abort
    # message can name the blocking key and the collision class.
    if ((-not $hasMarker) -and (-not $cpSignature)) {
        $probe = Invoke-ProfileForeignProbe -ProfileName $ProfileName
        if ($probe.Found) {
            return @{ Class = "foreign"; BlockingKey = $probe.Key; BlockingSource = $probe.Source; ExistingAccount = "" }
        }
        return @{ Class = "unknown"; BlockingKey = ""; BlockingSource = ""; ExistingAccount = "" }
    }

    # (4) CSG-owned, but contaminated? The marker is not a license to write into
    # a section carrying foreign credentials (the Phase 21 veto, D-06).
    $ownedProbe = Invoke-ProfileForeignProbe -ProfileName $ProfileName
    if ($ownedProbe.Found) {
        return @{ Class = "contaminated"; BlockingKey = $ownedProbe.Key; BlockingSource = $ownedProbe.Source; ExistingAccount = "" }
    }

    # (5) same account or a silent re-pointing (D-09)? A CSG-owned section with
    # no parseable account id (marker-only after a partial write, or a malformed
    # cp) cannot be re-pointing anything, so it converges on the idempotent
    # re-registration row and gets repaired.
    $existingAccount = ""
    if (-not [string]::IsNullOrEmpty($cpValue)) {
        $extracted = Get-AccountIdFromCredentialProcess -CpValue $cpValue
        if ($null -ne $extracted) { $existingAccount = $extracted }
    }

    if ((-not [string]::IsNullOrEmpty($existingAccount)) -and ($existingAccount -cne $RequestedAccountId)) {
        return @{ Class = "owned-different"; BlockingKey = ""; BlockingSource = ""; ExistingAccount = $existingAccount }
    }

    return @{ Class = "owned-same"; BlockingKey = ""; BlockingSource = ""; ExistingAccount = $existingAccount }
}

# Show-RegisterRetrySuggestion: print the D-04 alternative-name guidance.
# The retry command passes the suggested name as --account-name because register
# derives the profile name itself (D-03) -- there is no --profile-name flag. This
# is exact, not approximate: the suggestion is already a normalized token, and
# ConvertTo-NormalizedNameToken is idempotent on such a token, so the printed
# command genuinely produces the printed name.
# The PS form is wrapped in `pwsh -NoProfile -File "<abs>"` so the printed line is
# actually runnable on Windows; the bash twin prints the bare script path.
# T-22-05: only normalized [a-z0-9-] strings are echoed, so no attacker-supplied
# ANSI escape can reach the terminal through this path.
function Show-RegisterRetrySuggestion {
    param([string]$ScriptAbs, [string]$AccountId, [string]$CorpName, [string]$AccountName)

    $alternative = Get-SuggestedAlternativeName -CorpName $CorpName -AccountName $AccountName

    Write-RegisterLog -Message "대체 이름으로 다시 시도하세요 (제안: $($alternative.Name)):"
    [Console]::Error.WriteLine("[register]   pwsh -NoProfile -File `"$ScriptAbs`" register --account-id $AccountId --account-name `"$($alternative.Name)`"")
    if (-not $alternative.CorpContributed) {
        Write-RegisterLog -Message "  (--corp-name `"<회사명>`" 을 함께 주면 더 구체적인 대체명을 제안합니다)"
    }
}

# Invoke-DoRegister: PROF-08/10/11. Eight stages, byte-parallel to bash
# do_register: parse -> derive name -> fail-closed enumeration -> membership ->
# classify (decision table) -> write -> read-back -> stdout.
# NO network call, NO Bearer read, NO JSON parsing -- pure ~/.aws/config work.
# T-22-01: every read happens before the first write. Rows 4..7 all abort and
# NOTHING is deleted or merged; on any abort ~/.aws/config is byte-identical.
function Invoke-DoRegister {
    param([string[]]$Arguments = @())

    if ($null -eq $Arguments) { $Arguments = @() }

    $accountId = ""
    $accountName = ""
    $corpName = ""
    $accountNameGiven = $false

    # [1] argv. register consumes its own arguments; these flags must never reach
    # the main parser below, whose `default` branch dies with the misleading
    # "Unknown option" (Pitfall 2).
    # NOTE: PowerShell's `switch` is case-INSENSITIVE, so "--Account-Name" is also
    # accepted here while the bash twin's `case` is case-sensitive. This mirrors
    # the pre-existing asymmetry of the main parser below and is deliberately NOT
    # part of the parity contract.
    $argIndex = 0
    while ($argIndex -lt $Arguments.Count) {
        $currentArg = $Arguments[$argIndex]
        switch ($currentArg) {
            '--account-id' {
                if ($argIndex + 1 -ge $Arguments.Count) {
                    Stop-RegisterWithError -Reason 'invalid-arguments' -Messages @(
                        "중단: 옵션 '$currentArg' 에 값이 필요합니다."
                    )
                }
                $argIndex++
                $accountId = $Arguments[$argIndex]
            }
            '--account-name' {
                if ($argIndex + 1 -ge $Arguments.Count) {
                    Stop-RegisterWithError -Reason 'invalid-arguments' -Messages @(
                        "중단: 옵션 '$currentArg' 에 값이 필요합니다."
                    )
                }
                $argIndex++
                $accountName = $Arguments[$argIndex]
                $accountNameGiven = $true
            }
            '--corp-name' {
                if ($argIndex + 1 -ge $Arguments.Count) {
                    Stop-RegisterWithError -Reason 'invalid-arguments' -Messages @(
                        "중단: 옵션 '$currentArg' 에 값이 필요합니다."
                    )
                }
                $argIndex++
                $corpName = $Arguments[$argIndex]
            }
            '--help' { Show-Usage; exit 0 }
            '-h'     { Show-Usage; exit 0 }
            default {
                Stop-RegisterWithError -Reason 'invalid-arguments' -Messages @(
                    "중단: register 가 모르는 인자입니다: $(ConvertTo-DisplaySafe -Text $currentArg)",
                    "사용법: get-customer-credentials.ps1 register --account-id <12자리> --account-name `"<계정명>`" [--corp-name `"<회사명>`"]"
                )
            }
        }
        $argIndex++
    }

    # A6: the same shape the main parser and the broker enforce. \z (absolute end)
    # rather than $, which in .NET also matches before a trailing newline.
    if ($accountId -cnotmatch '^[0-9]{12}\z') {
        Stop-RegisterWithError -Reason 'invalid-account-id' -Messages @(
            "중단: 유효하지 않은 --account-id (12자리 숫자만 허용): '${accountId}'",
            "~/.aws/config 는 변경되지 않았습니다."
        )
    }
    if (-not $accountNameGiven) {
        Stop-RegisterWithError -Reason 'invalid-account-name' -Messages @(
            "중단: --account-name 은 필수입니다.",
            "사용법: get-customer-credentials.ps1 register --account-id <12자리> --account-name `"<계정명>`" [--corp-name `"<회사명>`"]"
        )
    }

    # Absolute path of THIS script. $PSCommandPath is the resolved full path under
    # `pwsh -File`; $PSScriptRoot is the fallback for any host that leaves it
    # empty. NEVER derived from an existing credential_process value: when that
    # value is empty the derivation collapses to a RELATIVE path baked into
    # ~/.aws/config -- the fail-open this milestone is closing.
    $scriptAbs = $PSCommandPath
    if ([string]::IsNullOrEmpty($scriptAbs)) {
        $scriptAbs = Join-Path $PSScriptRoot "get-customer-credentials.ps1"
    }
    # No $scriptBase: the post-condition below compares the FULL expected
    # credential_process, so a base-name substring is no longer needed (CR-03).

    # [2] derive the profile name -- D-03, computed here and nowhere else.
    $profileName = Get-DerivedProfileName -AccountName $accountName

    # [2b] SkipProfiles veto (D-06 applied to the WRITE path, not just cleanup).
    # Test-IsCsgProfile refuses to DELETE anything in $SkipProfiles; without the
    # mirror-image guard here, register can CREATE one. Two concrete harms:
    #   (a) `--account-name "Default"` normalizes to `default`, and
    #       `aws configure set ... --profile default` special-cases that name into
    #       the [default] section -- every unqualified `aws` command on the machine
    #       silently starts resolving a customer read-only session, which inverts
    #       the audit story the milestone exists to protect;
    #   (b) any other SkipProfiles name mints a section cleanup can NEVER reclaim,
    #       because the cleanup predicate vetoes exactly this list.
    # -ccontains: AWS profile names are case-SENSITIVE; -contains is not.
    # Runs BEFORE enumeration, so ~/.aws/config is byte-identical on this abort.
    if ($SkipProfiles -ccontains $profileName) {
        Write-RegisterReason -Token "reserved-profile-name"
        Write-RegisterLog -Message "중단: '${profileName}' 은(는) 인프라 예약 프로필명입니다 (SkipProfiles)."
        Write-RegisterLog -Message "충돌 대상: 인프라 예약 이름 (cleanup 이 절대 건드리지 않는 보호 목록)"
        Write-RegisterLog -Message "이 이름으로 등록하면 cleanup 이 영구히 회수할 수 없고, 'default' 의 경우"
        Write-RegisterLog -Message "모든 무지정 AWS CLI 호출이 고객사 세션으로 해석됩니다. 쓰지 않고 중단합니다."
        Write-RegisterLog -Message "~/.aws/config 는 변경되지 않았습니다."
        Show-RegisterRetrySuggestion -ScriptAbs $scriptAbs -AccountId $accountId -CorpName $corpName -AccountName $accountName
        exit 1
    }

    # [3] enumeration, fail-closed (decision-table row 1 / D-07 / PROF-10).
    # list-profiles (not a ~/.aws/config scan) is what makes SSO-only and
    # credentials-file-only profiles visible at all. S4/T-22-03: $LASTEXITCODE is
    # read on the VERY NEXT LINE -- a 255 must never degrade into "no profiles".
    $listOutput = $null
    $listRc = 255
    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $listOutput = & aws configure list-profiles 2>$null
        $listRc = $LASTEXITCODE
    }
    catch {
        $listRc = 255
    }
    finally {
        $ErrorActionPreference = $previousPreference
    }
    if ($listRc -ne 0) {
        Stop-ConfigUnparseable -ExitCode $listRc
    }
    # V18: rc == 0 with EMPTY output is the legitimate fresh-machine case.
    # "없음" and "못 읽음" are never conflated.

    $allProfiles = @()
    foreach ($rawProfile in @($listOutput)) {
        if ($null -eq $rawProfile) { continue }
        $trimmedProfile = ([string]$rawProfile).Trim()
        if (-not [string]::IsNullOrEmpty($trimmedProfile)) {
            $allProfiles += $trimmedProfile
        }
    }

    # [4] whole-ELEMENT, case-SENSITIVE membership. @() wrapping handles the
    # single-profile case where the native call yields a scalar String rather
    # than an array. A substring match would make `csg-acme` false-positive
    # against an existing `csg-acme-dev`.
    $exists = (@($allProfiles) -ccontains $profileName)

    # [5] decision-table rows 3..7.
    $action = "create"
    if ($exists) {
        $classification = Get-ExistingProfileClassification -ProfileName $profileName -RequestedAccountId $accountId
        switch ($classification.Class) {
            'owned-same' {
                # row 3 -- idempotent re-registration (D-08)
                $action = "reregister"
            }
            'owned-different' {
                # row 4 (D-09)
                Write-RegisterReason -Token "account-mismatch"
                Write-RegisterLog -Message "중단: 프로필 '${profileName}' 은(는) CSG 소유이지만 다른 고객 계정에 묶여 있습니다."
                Write-RegisterLog -Message "충돌 대상: 다른 계정의 CSG 프로필 (기존 계정ID $($classification.ExistingAccount) / 요청 계정ID ${accountId})"
                Write-RegisterLog -Message "조용히 재지정하면 진행 중인 '--profile ${profileName}' 명령이 엉뚱한 고객 계정을 조회하게 되고,"
                Write-RegisterLog -Message "기존 계정의 credential 캐시가 고아가 됩니다. 쓰지 않고 중단합니다."
                Write-RegisterLog -Message "~/.aws/config 는 변경되지 않았습니다."
                Show-RegisterRetrySuggestion -ScriptAbs $scriptAbs -AccountId $accountId -CorpName $corpName -AccountName $accountName
                Write-RegisterLog -Message "register 는 어떤 섹션도 삭제하지 않습니다. 기존 등록을 정리하려면 cleanup 서브커맨드를 쓰세요."
                exit 1
            }
            'contaminated' {
                # row 5
                $classLabel = Get-CollisionClassLabel -Key $classification.BlockingKey -Source $classification.BlockingSource
                Write-RegisterReason -Token "contaminated-hybrid"
                Write-RegisterLog -Message "중단: 프로필 '${profileName}' 은(는) CSG 소유이지만 외래 credential 키가 섞여 있습니다 (오염된 하이브리드)."
                Write-RegisterLog -Message "충돌 대상: ${classLabel} ($($classification.BlockingKey) 키 보유)"
                Write-RegisterLog -Message "CSG 가 쓴 키와 엔지니어 본인의 credential 키가 한 섹션에 공존하는 상태입니다."
                Write-RegisterLog -Message "덮어쓰면 본인 신원 설정이 손상될 수 있어 register 는 병합도 복구도 하지 않습니다."
                Write-RegisterLog -Message "~/.aws/config 는 변경되지 않았습니다."
                # Pitfall 11 / ROADMAP criterion 5 is now SATISFIED BY SHIPPING,
                # not by hedging: `doctor` exists as of Phase 23, so the imperative
                # below names a command that actually runs. It takes no required
                # parameters -- keep it that way, or reword this line to match.
                Write-RegisterLog -Message "복구하려면 doctor 를 실행하세요:"
                [Console]::Error.WriteLine("[register]   pwsh -NoProfile -File `"$scriptAbs`" doctor")
                Write-RegisterLog -Message "doctor 는 오염된 섹션에서 csg_managed 와 credential_process 두 키만 제거하고"
                Write-RegisterLog -Message "섹션 자체와 sso_* / region / output 은 값까지 보존합니다. 복구 후 이 명령을 다시 실행하세요."
                Show-RegisterRetrySuggestion -ScriptAbs $scriptAbs -AccountId $accountId -CorpName $corpName -AccountName $accountName
                exit 1
            }
            'foreign' {
                # row 6 -- PROF-11 proper
                $classLabel = Get-CollisionClassLabel -Key $classification.BlockingKey -Source $classification.BlockingSource
                Write-RegisterReason -Token "foreign-profile"
                Write-RegisterLog -Message "중단: 프로필 '${profileName}' 이(가) 이미 존재하며 CSG 소유가 아닙니다."
                Write-RegisterLog -Message "충돌 대상: ${classLabel} ($($classification.BlockingKey) 키 보유)"
                if ($classification.BlockingSource -ceq "credentials") {
                    Write-RegisterLog -Message "~/.aws/credentials 의 정적 키는 credential_process 보다 우선하므로, 병합하면 이 프로필은"
                    Write-RegisterLog -Message "브로커를 거치지 않고 조용히 엔지니어 본인 신원으로 해석됩니다. 쓰지 않고 중단합니다."
                }
                else {
                    Write-RegisterLog -Message "병합하면 이 섹션에 credential_process 가 주입되어 엔지니어 본인 신원이 조용히 바뀌고,"
                    Write-RegisterLog -Message "이후 sweep 이 섹션 전체를 삭제할 수 있습니다. 쓰지 않고 중단합니다."
                }
                Write-RegisterLog -Message "~/.aws/config 는 변경되지 않았습니다."
                Show-RegisterRetrySuggestion -ScriptAbs $scriptAbs -AccountId $accountId -CorpName $corpName -AccountName $accountName
                exit 1
            }
            default {
                # row 7 -- unknown existing section (conservative)
                Write-RegisterReason -Token "unknown-profile"
                Write-RegisterLog -Message "중단: 프로필 '${profileName}' 이(가) 이미 존재하지만 CSG 가 만든 섹션이라는 증거가 없습니다."
                Write-RegisterLog -Message "충돌 대상: 알 수 없는 기존 섹션 (csg_managed 마커도 CSG credential_process 도 없음)"
                Write-RegisterLog -Message "CSG 가 만들지 않은 섹션에 키를 주입하는 것이 바로 이번에 막으려는 쓰기 경로 결함입니다."
                Write-RegisterLog -Message "이름이 겹쳤을 뿐이라면 대체 이름을 쓰는 편이 안전합니다. 쓰지 않고 중단합니다."
                Write-RegisterLog -Message "~/.aws/config 는 변경되지 않았습니다."
                Show-RegisterRetrySuggestion -ScriptAbs $scriptAbs -AccountId $accountId -CorpName $corpName -AccountName $accountName
                exit 1
            }
        }
    }

    # [6] write. Every read is done; only now is the file touched.
    # Pitfall 6 / T-22-07 / PROF-08: csg_managed FIRST, credential_process LAST.
    # The four `aws configure set` calls are four separate processes. A section
    # holding only the marker is inert to credential resolution (the CLI stores an
    # unrecognized key without interpreting it) and is unambiguously CSG-owned, so
    # a re-run lands on decision-table row 3 and completes cleanly. The reverse
    # order would leave a RESOLVABLE profile in an unowned state.
    $cpValue = "pwsh -NoProfile -File `"$scriptAbs`" -AccountId $accountId"
    $setKeys = @("csg_managed", "region", "output", "credential_process")
    $setValues = @($CsgManagedVersion, "ap-northeast-2", "json", $cpValue)

    for ($keyIndex = 0; $keyIndex -lt $setKeys.Count; $keyIndex++) {
        $setKey = $setKeys[$keyIndex]
        $setValue = $setValues[$keyIndex]

        # T-22-04: values are passed as individual argv elements. No
        # Invoke-Expression, no string-assembled `aws` command line.
        $writeRc = 255
        $previousPreference = $ErrorActionPreference
        $ErrorActionPreference = "Continue"
        try {
            $null = & aws configure set $setKey $setValue --profile $profileName 2>$null
            $writeRc = $LASTEXITCODE
        }
        catch {
            $writeRc = 255
        }
        finally {
            $ErrorActionPreference = $previousPreference
        }

        if ($writeRc -ne 0) {
            $written = "(없음)"
            if ($keyIndex -gt 0) {
                $written = ($setKeys[0..($keyIndex - 1)] -join " ")
            }
            Stop-RegisterWithError -Reason 'write-failed' -Messages @(
                "중단: 'aws configure set ${setKey}' 이(가) exit=${writeRc} 로 실패했습니다.",
                "프로필: ${profileName} / 지금까지 기록된 키: ${written}",
                "마커를 먼저 쓰므로 부분 기록된 섹션은 credential 해석에 관여하지 않습니다.",
                "원인을 해결한 뒤 같은 명령을 다시 실행하면 재등록 경로로 수렴합니다."
            )
        }
    }

    # [7] post-condition re-read (S3). The project does not trust a tool's exit
    # code for a mutation claim -- read the result back before claiming success.
    # Deliberately a config read-back and NOT an STS caller-identity round-trip:
    # that would need a live Bearer plus a broker call, and would fail for reasons
    # that have nothing to do with whether the profile got registered.
    $readBackCp = Invoke-AwsConfigureGet -Key "credential_process" -ProfileName $profileName
    if ($readBackCp.Rc -ne 0) {
        Stop-RegisterWithError -Reason 'postcondition-failed' -Messages @(
            "중단: 기록 직후 credential_process 를 다시 읽지 못했습니다 (exit=$($readBackCp.Rc)).",
            "프로필 '${profileName}' 의 상태를 직접 확인하세요."
        )
    }
    # EXACT-value post-condition, against an INDEPENDENTLY RECOMPUTED oracle --
    # deliberately not the $cpValue variable the write used, because comparing
    # the read-back to the same variable would mirror a write-side regression
    # instead of catching it. Same shape as the bash twin (CR-03): a substring
    # test on the script base name plus the account id cannot detect a value
    # whose PATH QUOTING was lost, which is the failure botocore actually trips
    # over.
    $expectedCp = "pwsh -NoProfile -File `"$scriptAbs`" -AccountId $accountId"
    if ($readBackCp.Value -cne $expectedCp) {
        Stop-RegisterWithError -Reason 'postcondition-failed' -Messages @(
            "중단: 기록된 credential_process 가 기대값과 일치하지 않습니다.",
            "기대: '${expectedCp}'",
            "실제: '$($readBackCp.Value)'",
            "프로필 '${profileName}' 의 상태를 직접 확인하세요."
        )
    }

    $readBackMarker = Invoke-AwsConfigureGet -Key "csg_managed" -ProfileName $profileName
    if (($readBackMarker.Rc -ne 0) -or [string]::IsNullOrEmpty($readBackMarker.Value)) {
        Stop-RegisterWithError -Reason 'postcondition-failed' -Messages @(
            "중단: 기록 직후 csg_managed 마커를 다시 읽지 못했습니다 (exit=$($readBackMarker.Rc))."
        )
    }

    # [8] success. EXACTLY one line on stdout: the profile name.
    if ($action -ceq "reregister") {
        Write-RegisterLog -Message "이미 등록됨 — 갱신함: ${profileName} (계정 ${accountId})"
    }
    else {
        Write-RegisterLog -Message "등록 완료: ${profileName} (계정 ${accountId})"
    }
    Write-RegisterLog -Message "사용: aws --profile ${profileName} <command>"
    [Console]::Out.WriteLine($profileName)
    exit 0
}

# Remove-KeysFromProfile -ConfigFile <path> -ProfileName <name> -Keys <string[]>
#
# PROF-13 / D-09: PowerShell twin of the bash `remove_keys_from_profile`. Removes
# SPECIFIC keys from ONE INI section and preserves every other byte -- the section
# header, sso_*/region/output and every other key, comments, blank lines, key
# spacing, the BOM (if any) and CRLF line terminators. Non-target sections are
# never touched (T-23-05).
#
# This is deliberately NOT Remove-ProfilesFromConfig (whole-section delete, which
# would take an engineer's SSO configuration with it -- T-23-06) and deliberately
# NOT `aws configure set <key> ""` (rc 0 with the key left behind holding an
# empty value -- 23-RESEARCH V1).
#
# Returns $true only after every requested key is confirmed absent via
# `aws configure get` rc 1; $false otherwise. The rewrite's own success is never
# accepted as proof of removal (T-23-08).
#
# Extraction note: test/doctor.test.ps1 sources this function by the text range
# from its `function` line to the first column-0 `}`, so everything below stays
# indented and the closing brace is the only `}` in column 0.
function Remove-KeysFromProfile {
    param(
        [string]$ConfigFile,
        [string]$ProfileName,
        [string[]]$Keys
    )

    if ($null -eq $Keys -or $Keys.Count -eq 0) { return $true }
    if (-not (Test-Path -LiteralPath $ConfigFile)) { return $false }

    # The post-condition IS the contract. Without `aws` there is no way to prove
    # a key is gone, so refuse to mutate rather than make an unverifiable claim.
    if (-not (Get-Command aws -ErrorAction SilentlyContinue)) {
        [Console]::Error.WriteLine("[doctor] 중단: 키 제거 사후검증에 필요한 aws 명령을 찾을 수 없습니다")
        return $false
    }

    # T-23-07 / CR-01: `|` is the KEYS delimiter in the bash twin; the same value
    # is rejected here so the two implementations accept exactly the same inputs.
    if ($ProfileName -cmatch '\|') {
        [Console]::Error.WriteLine("[doctor] 중단: 프로필 이름에 파이프 문자가 있습니다: $ProfileName")
        return $false
    }
    $keySet = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($k in $Keys) {
        if ($k -cmatch '\|') {
            [Console]::Error.WriteLine("[doctor] 중단: 키 이름에 파이프 문자가 있습니다: $k")
            return $false
        }
        [void]$keySet.Add($k.ToLowerInvariant())
    }

    # D-10 / T-23-09: back up BEFORE touching anything.
    # PROF-12: same session-pinned, create-once rule as Remove-ProfilesFromConfig --
    # see the rationale there. Unset outside a migration, so doctor/sweep/cleanup
    # keep their historical per-call .bak.
    $backupFile = if ([string]::IsNullOrEmpty($script:CsgBackupSession)) {
        "$ConfigFile.bak.$(Get-Date -Format 'yyyyMMddHHmmss')"
    } else {
        $script:CsgBackupSession
    }
    if (-not (Test-Path -LiteralPath $backupFile)) {
        Copy-Item -LiteralPath $ConfigFile -Destination $backupFile
    }

    # Get-NormalizedHeaderName: the same normalization the collect-time parser
    # uses, plus the WR-08 quote strip -- botocore strips the quotes off
    # [profile "x"] when it resolves --profile x, so the remover must too.
    function Get-NormalizedHeaderName {
        param([string]$Line)
        $h = $Line.TrimEnd("`r")
        if ($h -cmatch '^\[profile[ \t]+') {
            $name = $h.Substring($Matches[0].Length)
            $name = $name -creplace '\][ \t]*$', ''
            return $name.Trim(" ", "`t").Trim("'", '"')
        }
        elseif ($h -cmatch '^\[default\][ \t]*$') {
            return "default"
        }
        return $null
    }

    # Read as raw bytes, not Get-Content / ReadAllLines: ReadAllLines consumes
    # the \r as part of the terminator, which would silently rewrite a CRLF
    # config to LF. Splitting the raw text on "`n" keeps each line's trailing
    # \r attached to the line, so re-joining restores the file byte for byte
    # (V4, DOCTOR-KEY-02).
    $bytes = [System.IO.File]::ReadAllBytes($ConfigFile)
    $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
    $raw = [System.Text.Encoding]::UTF8.GetString($bytes)
    if ($hasBom -and $raw.Length -gt 0) { $raw = $raw.Substring(1) }

    # String.Split, not the -split operator: `-split "`n", -1` does NOT mean
    # "no limit" -- a negative max-substrings counts from the END of the string,
    # so it returns the input unsplit. String.Split keeps every empty element,
    # including the trailing one produced by a final newline.
    $parts = $raw.Split([char]10)
    $outParts = [System.Collections.Generic.List[string]]::new()
    $inTarget = $false
    $dropping = $false
    $removed = 0
    $removedSet = [System.Collections.Generic.HashSet[string]]::new()

    foreach ($line in $parts) {
        $stripped = $line.TrimEnd("`r")

        # EVERY bracketed line re-decides membership and cancels an in-flight
        # drop -- not only [profile ...]/[default] (Pattern 4 / T-23-05).
        if ($stripped.StartsWith('[')) {
            $name = Get-NormalizedHeaderName -Line $line
            $inTarget = ($null -ne $name -and $name -ceq $ProfileName)
            $dropping = $false
            $outParts.Add($line)
            continue
        }

        # botocore treats an indented line after "key =" as a nested value; the
        # whole continuation leaves with its parent key.
        if ($inTarget -and $dropping -and $stripped -cmatch '^[ \t]+') { continue }
        $dropping = $false

        if ($inTarget -and $stripped -cmatch '^[ \t]*[^#;\[][^=]*=') {
            $keyName = ($stripped -creplace '=.*$', '').Trim(" ", "`t")
            if ($keySet.Contains($keyName.ToLowerInvariant())) {
                $dropping = $true
                $removed++
                # Record WHICH key left so the count and the reported list agree
                # (23-10 checkpoint finding 1) -- naming the whole target set
                # printed two names for a one-key removal.
                [void]$removedSet.Add($keyName.ToLowerInvariant())
                continue
            }
        }

        # Untouched lines are re-emitted verbatim: the \r strip above only ever
        # applied to the comparison copy, never to the output.
        $outParts.Add($line)
    }

    # D-11: atomic write via a temp file in the SAME directory + Move-Item.
    # [IO.File]::WriteAllText only -- the line-oriented content cmdlets append a
    # trailing newline and apply the platform EOL, which would destroy the CRLF
    # fidelity established above.
    $tmpFile = Join-Path (Split-Path -Parent $ConfigFile) ".config_tmp.$([IO.Path]::GetRandomFileName())"
    try {
        $encoding = [System.Text.UTF8Encoding]::new($hasBom)
        [IO.File]::WriteAllText($tmpFile, ($outParts -join "`n"), $encoding)
        Move-Item -LiteralPath $tmpFile -Destination $ConfigFile -Force
    }
    catch {
        if (Test-Path -LiteralPath $tmpFile) { Remove-Item -LiteralPath $tmpFile -Force -ErrorAction SilentlyContinue }
        [Console]::Error.WriteLine("[doctor] 키 제거 실패: $($_.Exception.Message)")
        [Console]::Error.WriteLine("[doctor] 복구하려면: cp `"$backupFile`" `"$ConfigFile`"")
        return $false
    }

    # Architecture Pattern 6 / T-23-08: post-condition re-read. Only rc 1 from
    # the CLI proves genuine absence (23-RESEARCH V2):
    #   rc 0   -> key survived (a blanked value still reads as present -- V1)
    #   rc 1   -> genuinely absent
    #   rc 255 -> the rewritten config no longer parses
    # AWS_CONFIG_FILE is pinned so the probe reads the file that was just
    # rewritten, never whatever config the ambient environment resolves.
    $prevConfigFile = $env:AWS_CONFIG_FILE
    $prevProfile = $env:AWS_PROFILE
    $prevDefaultProfile = $env:AWS_DEFAULT_PROFILE
    $previousPreference = $ErrorActionPreference
    try {
        $env:AWS_CONFIG_FILE = $ConfigFile
        $env:AWS_PROFILE = $null
        $env:AWS_DEFAULT_PROFILE = $null
        $ErrorActionPreference = "Continue"

        foreach ($k in $Keys) {
            $rc = 255
            try {
                & aws configure get $k --profile $ProfileName 2>$null | Out-Null
                $rc = $LASTEXITCODE
            }
            catch {
                $rc = 255
            }

            if ($rc -ne 1) {
                if ($rc -eq 0) {
                    [Console]::Error.WriteLine("[doctor] 키 제거 사후검증 실패: $k (exit=0, 값이 비워졌을 뿐 제거되지 않음)")
                }
                else {
                    [Console]::Error.WriteLine("[doctor] 키 제거 사후검증 실패: $k (exit=$rc)")
                }
                [Console]::Error.WriteLine("[doctor] 복구하려면: cp `"$backupFile`" `"$ConfigFile`"")
                return $false
            }
        }
    }
    finally {
        $env:AWS_CONFIG_FILE = $prevConfigFile
        $env:AWS_PROFILE = $prevProfile
        $env:AWS_DEFAULT_PROFILE = $prevDefaultProfile
        $ErrorActionPreference = $previousPreference
    }

    # PROF-14: everything this function says goes to stderr -- stdout on this
    # script carries the 5-key credential JSON contract.
    # Name ONLY the keys that actually left, in the caller's key order, so the
    # count and the list agree (23-10 checkpoint finding 1). Space-separated to
    # match the bash twin byte-for-byte.
    $removedNames = @($Keys | Where-Object { $removedSet.Contains($_.ToLowerInvariant()) }) -join ' '
    if ([string]::IsNullOrEmpty($removedNames)) { $removedNames = "없음" }
    [Console]::Error.WriteLine("[doctor] 키 ${removed}개 제거됨: $removedNames (프로필 $ProfileName)")
    [Console]::Error.WriteLine("[doctor] 복구하려면: cp `"$backupFile`" `"$ConfigFile`"")
    return $true
}

# Copy-SectionKeys: PowerShell twin of bash carry_section_keys.
#
# CR-01: makes `migrate`'s rename an actual RENAME. The register child writes
# exactly four keys into the freshly minted section (csg_managed, region, output,
# credential_process) from its own hardcoded defaults and knows nothing about the
# section it replaces, so without this step every other key the engineer had set
# -- cli_pager, ca_bundle, an `s3 =` sub-section, anything -- dies with the
# subsequent delete, and region/output are silently reset. A silent region flip
# is not cosmetic here: every later read-only customer query then runs against
# the wrong region and returns "no resources".
#
# Contract (identical to bash):
#   - every key of -OldProfile EXCEPT -OwnedKeys is copied into -NewProfile
#     VERBATIM (original spelling, spacing and indented continuation block),
#     replacing whatever register wrote for that key;
#   - -OwnedKeys (csg_managed / credential_process) are never carried;
#   - the OLD section's key order is preserved;
#   - a key that exists ONLY in the new section survives untouched.
#
# Same byte-fidelity discipline as Remove-KeysFromProfile: raw byte read, split
# on LF so CRLF survives, atomic temp-file + Move-Item write.
# Returns $true when the file was rewritten, $false on any failure; the caller
# treats $false as "do NOT delete the old section".
function Copy-SectionKeys {
    param(
        [string]$ConfigFile,
        [string]$OldProfile,
        [string]$NewProfile,
        [string[]]$OwnedKeys
    )

    if (-not (Test-Path -LiteralPath $ConfigFile)) { return $false }

    $ownedSet = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($k in $OwnedKeys) { [void]$ownedSet.Add($k.ToLowerInvariant()) }

    function Get-CarryHeaderName {
        param([string]$Line)
        $h = $Line.TrimEnd("`r")
        if ($h -cmatch '^\[profile[ \t]+') {
            $name = $h.Substring($Matches[0].Length)
            $name = $name -creplace '\][ \t]*$', ''
            # IN-06: strip at most ONE quote from each end, exactly like the awk
            # twin's gsub(/^['"]|['"]$/) -- .Trim() would strip a whole run.
            $name = $name.Trim(" ", "`t")
            $name = $name -creplace '^[''"]', '' -creplace '[''"]$', ''
            return $name
        }
        elseif ($h -cmatch '^\[default\][ \t]*$') { return "default" }
        return $null
    }

    try {
        $bytes = [System.IO.File]::ReadAllBytes($ConfigFile)
        $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
        $raw = [System.Text.Encoding]::UTF8.GetString($bytes)
        if ($hasBom -and $raw.Length -gt 0) { $raw = $raw.Substring(1) }
        $parts = $raw.Split([char]10)

        # ---- pass 1: harvest the OLD section ----
        $order = [System.Collections.Generic.List[string]]::new()
        $blk = @{}
        $inOld = $false
        $cur = ""
        $dropping = $false
        foreach ($line in $parts) {
            $stripped = $line.TrimEnd("`r")
            if ($stripped.StartsWith('[')) {
                $hn = Get-CarryHeaderName -Line $line
                $inOld = ($null -ne $hn -and $hn -ceq $OldProfile)
                $cur = ""; $dropping = $false
                continue
            }
            if (-not $inOld) { continue }
            # A continuation block travels with its parent key.
            if ($stripped -cmatch '^[ \t]+') {
                if ($dropping) { continue }
                if ($cur -ne "") { $blk[$cur] = $blk[$cur] + "`n" + $line }
                continue
            }
            $cur = ""; $dropping = $false
            if ($stripped -cmatch '^[ \t]*[^#;\[][^=]*=') {
                $keyName = ($stripped -creplace '=.*$', '').Trim(" ", "`t")
                $lk = $keyName.ToLowerInvariant()
                if ($ownedSet.Contains($lk)) { $dropping = $true; continue }
                if (-not $blk.ContainsKey($lk)) { $order.Add($lk) }
                $blk[$lk] = $line
                $cur = $lk
            }
        }

        # ---- pass 2: rewrite the NEW section ----
        $outParts = [System.Collections.Generic.List[string]]::new()
        $pending = [System.Collections.Generic.List[string]]::new()
        $inNew = $false
        $dropping = $false

        # Local flush: carried keys first (in the OLD section's order), then the
        # blank lines that were held back so they stay at the section's tail.
        $flush = {
            foreach ($lk in $order) { if ($blk.ContainsKey($lk)) { $outParts.Add([string]$blk[$lk]) } }
            foreach ($b in $pending) { $outParts.Add($b) }
            $pending.Clear()
        }

        foreach ($line in $parts) {
            $stripped = $line.TrimEnd("`r")
            if ($stripped.StartsWith('[')) {
                if ($inNew) { & $flush }
                elseif ($pending.Count -gt 0) { foreach ($b in $pending) { $outParts.Add($b) }; $pending.Clear() }
                $hn = Get-CarryHeaderName -Line $line
                $inNew = ($null -ne $hn -and $hn -ceq $NewProfile)
                $dropping = $false
                $outParts.Add($line)
                continue
            }
            if ($inNew) {
                if ($dropping -and $stripped -cmatch '^[ \t]+') { continue }
                $dropping = $false
                if ($stripped -cmatch '^[ \t]*[^#;\[][^=]*=') {
                    $keyName = ($stripped -creplace '=.*$', '').Trim(" ", "`t")
                    # The OLD value wins, and it is re-emitted at flush in the
                    # old section's key order -- not here, where it would be
                    # re-ordered.
                    if ($blk.ContainsKey($keyName.ToLowerInvariant())) { $dropping = $true; continue }
                }
                if ($stripped -cmatch '^[ \t]*$') { $pending.Add($line); continue }
                if ($pending.Count -gt 0) { foreach ($b in $pending) { $outParts.Add($b) }; $pending.Clear() }
                $outParts.Add($line)
                continue
            }
            if ($pending.Count -gt 0) { foreach ($b in $pending) { $outParts.Add($b) }; $pending.Clear() }
            $outParts.Add($line)
        }
        if ($inNew) { & $flush }
        elseif ($pending.Count -gt 0) { foreach ($b in $pending) { $outParts.Add($b) } }

        $tmpFile = Join-Path (Split-Path -Parent $ConfigFile) ".config_tmp.$([IO.Path]::GetRandomFileName())"
        try {
            $encoding = [System.Text.UTF8Encoding]::new($hasBom)
            [IO.File]::WriteAllText($tmpFile, ($outParts -join "`n"), $encoding)
            Move-Item -LiteralPath $tmpFile -Destination $ConfigFile -Force
        }
        catch {
            if (Test-Path -LiteralPath $tmpFile) { Remove-Item -LiteralPath $tmpFile -Force -ErrorAction SilentlyContinue }
            return $false
        }
        return $true
    }
    catch {
        return $false
    }
}

# --- doctor subcommand (PROF-13 / D-03 / ROADMAP criterion 4) ---
#
# PowerShell twin of get-customer-credentials.sh's do_doctor. The bash side is the
# parity source of truth: the [doctor] prefix, the reason tokens, the stderr
# wording and the exit semantics must stay identical.
#
# Repairs CONTAMINATED HYBRID sections: a section carrying CSG ownership evidence
# (csg_managed marker or a credential_process pointing at this script) AND a
# foreign credential key belonging to the engineer (sso_*, aws_access_key_id,
# role_arn, ...). Phase 21's guard refuses to sweep those, which leaves them
# stranded until something repairs them. This is that something, and it is what
# every printed `doctor` reference in this client points at.
#
# WHY KEY-LEVEL AND NOT SECTION-LEVEL: the section belongs to the ENGINEER. A
# whole-section delete would take their SSO configuration with it (T-23-06).
#
# Contract: stdout ALWAYS EMPTY (T-23-18 -- stdout carries the 5-key
# credential_process JSON contract); every stderr line prefixed "[doctor] ";
# exit 0 when the config was READ and every contaminated section (possibly none)
# is repaired, 1 when the config could not be read or a repair failed.
# "Unreadable" is never reported as "nothing to repair" (T-23-19).
function Write-DoctorLog {
    param([string]$Message)
    [Console]::Error.WriteLine("[doctor] $Message")
}

# T-23-19 / 23-RESEARCH Pitfall 7. A non-zero `aws configure list-profiles` means
# the config is UNREADABLE -- a different fact from "no contaminated sections
# found". Mirrors Stop-ConfigUnparseable's cause list under the [doctor] prefix;
# it cannot call that function because register's variant emits [register] and
# exits the process.
function Stop-DoctorUnparseable {
    param([int]$ExitCode)

    $configFile = Join-Path $HomeDir ".aws/config"

    [Console]::Error.WriteLine("[doctor] reason=config-unparseable")
    Write-DoctorLog -Message "중단: ~/.aws/config 를 읽을 수 없습니다 (aws configure list-profiles exit=${ExitCode})."
    Write-DoctorLog -Message "이 상태에서는 섹션을 볼 수 없으므로 '오염 없음'으로 간주하지 않고 중단합니다."
    Write-DoctorLog -Message "흔한 원인:"
    Write-DoctorLog -Message "  - 파일 맨 앞의 UTF-8 BOM (에디터가 붙였을 수 있음)"
    Write-DoctorLog -Message "  - 같은 [profile X] 섹션 헤더가 두 번 존재"
    Write-DoctorLog -Message "  - 닫는 ']' 가 빠진 헤더"

    # Ordered by NAME, never by LastWriteTime -- see list_recent_backups_note.
    $backups = @(Get-ChildItem -LiteralPath (Split-Path -Parent $configFile) -Filter "config.bak.*" -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '\.bak\.[0-9]{14}$' } |
        Sort-Object -Property Name -Descending | Select-Object -First 3)

    if ($backups.Count -eq 0) {
        Write-DoctorLog -Message "최근 백업: 백업 파일이 없습니다"
    }
    else {
        Write-DoctorLog -Message "최근 백업:"
        foreach ($b in $backups) { Write-DoctorLog -Message "  $($b.FullName)" }
        [Console]::Error.WriteLine("[doctor] 복구하려면: cp `"$($backups[0].FullName)`" `"$configFile`"")
    }

    Write-DoctorLog -Message "아무것도 고치지 않았습니다 — ~/.aws/config 는 변경되지 않았습니다."
    return 1
}

function Invoke-DoDoctor {
    $configFile = Join-Path $HomeDir ".aws/config"

    if (-not (Test-Path -LiteralPath $configFile)) {
        Write-DoctorLog -Message "~/.aws/config 가 없습니다 — 복구 대상 없음."
        return 0
    }

    # (1) FAIL-CLOSED ENTRY. AWS_CONFIG_FILE is pinned so the readability verdict
    # is about the file doctor would actually operate on, never whatever config
    # the ambient environment resolves (the same pin Remove-KeysFromProfile uses
    # for its post-condition probe).
    # S4/T-22-03 fence, same shape as Invoke-AwsConfigureGet: $LASTEXITCODE is
    # read on the VERY NEXT LINE, and the preference is relaxed for the duration
    # so a native command writing to a redirected stderr cannot raise a
    # terminating NativeCommandError. On the catch path $listRc stays non-zero --
    # fail-CLOSED, which is the whole point of this probe.
    $prevConfigFile = $env:AWS_CONFIG_FILE
    $prevProfileEnv = $env:AWS_PROFILE
    $prevDefaultProfileEnv = $env:AWS_DEFAULT_PROFILE
    $previousPreference = $ErrorActionPreference
    $listRc = 255
    try {
        $ErrorActionPreference = "Continue"
        $env:AWS_CONFIG_FILE = $configFile
        Remove-Item -LiteralPath "Env:\AWS_PROFILE" -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath "Env:\AWS_DEFAULT_PROFILE" -ErrorAction SilentlyContinue
        & aws configure list-profiles 2>$null | Out-Null
        $listRc = $LASTEXITCODE
    }
    catch {
        $listRc = 255
    }
    finally {
        $ErrorActionPreference = $previousPreference
        if ($null -eq $prevConfigFile) { Remove-Item -LiteralPath "Env:\AWS_CONFIG_FILE" -ErrorAction SilentlyContinue }
        else { $env:AWS_CONFIG_FILE = $prevConfigFile }
        if ($null -ne $prevProfileEnv) { $env:AWS_PROFILE = $prevProfileEnv }
        if ($null -ne $prevDefaultProfileEnv) { $env:AWS_DEFAULT_PROFILE = $prevDefaultProfileEnv }
    }

    if ($listRc -ne 0) {
        return (Stop-DoctorUnparseable -ExitCode $listRc)
    }

    # (2) SELECT. The out-parameter carries the contaminated set; the returned
    # array is the sweep-eligible set, which doctor deliberately ignores -- a
    # HEALTHY CSG profile holds csg_managed and credential_process too, and is
    # not a repair target.
    # GuardSkipQuiet: see Write-GuardSkipRecord -- suppresses the "run doctor to
    # repair" advisory while doctor is the one running.
    $contaminated = [System.Collections.Generic.List[string]]::new()
    $script:GuardSkipQuiet = $true
    try {
        Get-CsgProfiles -ConfigFile $configFile -Mode "all" -ContaminatedOut $contaminated | Out-Null
    }
    finally {
        $script:GuardSkipQuiet = $false
    }

    if ($contaminated.Count -eq 0) {
        Write-DoctorLog -Message "복구 대상 없음 — 오염된 하이브리드 섹션이 없습니다."
        return 0
    }

    # T-23-17: profile names come from a file this script does not own and are not
    # guaranteed to match [a-z0-9-]. Every name reaching the operator's terminal
    # or a CI log goes through ConvertTo-DisplaySafe first.
    Write-DoctorLog -Message "오염된 하이브리드 섹션 $($contaminated.Count)개를 발견했습니다:"
    foreach ($name in $contaminated) {
        if (Test-IsSkipProfile -Name $name) {
            Write-DoctorLog -Message "  - $(ConvertTo-DisplaySafe -Text $name) (보호 섹션 — 수술 제외, 수동 확인 필요)"
        }
        else {
            Write-DoctorLog -Message "  - $(ConvertTo-DisplaySafe -Text $name)"
        }
    }

    # (3) SURGERY. Exactly two keys, named literally, per D-09. A third key here
    # would start deleting configuration this tool did not write.
    #
    # CR-03: the $SkipProfiles filter is applied HERE, between the (blind)
    # reporting predicate and the surgery. Without it doctor strips
    # credential_process from `csg-login`, the login anchor, and exits 0.
    $surgeryTargets = [System.Collections.Generic.List[string]]::new()
    $protected = [System.Collections.Generic.List[string]]::new()
    foreach ($name in $contaminated) {
        if (Test-IsSkipProfile -Name $name) { $protected.Add($name); continue }
        $surgeryTargets.Add($name)
    }

    $repaired = [System.Collections.Generic.List[string]]::new()
    $failed = [System.Collections.Generic.List[string]]::new()
    foreach ($name in $surgeryTargets) {
        $ok = $false
        try {
            $ok = Remove-KeysFromProfile -ConfigFile $configFile -ProfileName $name -Keys @("csg_managed", "credential_process")
        }
        catch {
            $ok = $false
        }
        if ($ok) { $repaired.Add($name) } else { $failed.Add($name) }
    }

    if ($protected.Count -gt 0) {
        Write-DoctorLog -Message "보호 섹션 $($protected.Count)개는 수술하지 않았습니다 (인프라 예약 프로필):"
        foreach ($name in $protected) {
            Write-DoctorLog -Message "  - $(ConvertTo-DisplaySafe -Text $name) — 수동 확인 필요"
        }
        Write-DoctorLog -Message "이 섹션들은 csg-login 로그인 앵커와 [default] 를 포함하므로 자동으로 키를 제거하지 않습니다."
    }

    # (4) SUMMARY, Invoke-DoCleanup's CSV shape under the [doctor] prefix.
    if ($repaired.Count -gt 0) {
        $namesCsv = (($repaired | ForEach-Object { ConvertTo-DisplaySafe -Text $_ }) -join ", ")
        Write-DoctorLog -Message "복구한 프로필 $($repaired.Count)개: $namesCsv"

        # (5) D-04: the engineer owns these sections. Surgery on them is not
        # something to do silently, and an SSO session cached against the
        # pre-surgery section should be re-confirmed before the next call.
        Write-DoctorLog -Message "다음 단계: 위 프로필의 SSO 로그인이 아직 유효한지 'aws sso login --profile <프로필>' 로 재확인하세요."
    }

    # (6) D-09: say what was NOT removed, and why. region/output are ordinary AWS
    # settings -- there is no way to tell CSG's from the engineer's own.
    Write-DoctorLog -Message "제거한 키는 csg_managed 와 credential_process 두 개뿐입니다. sso_* / region / output 등"
    Write-DoctorLog -Message "나머지 키는 엔지니어 본인 설정과 구분할 수 없어 값까지 그대로 보존했습니다."

    # (7) Known scope limit, stated rather than hidden. The collector reads
    # ~/.aws/config only, so a section whose foreign key lives exclusively in
    # ~/.aws/credentials is invisible to it and is not classified as contaminated.
    Write-DoctorLog -Message "알려진 범위 한계: 외래 키가 ~/.aws/credentials 에만 있는 섹션은 config 만 읽는 이 검사에"
    Write-DoctorLog -Message "보이지 않으므로 오염으로 분류되지 않습니다."

    if ($failed.Count -gt 0) {
        Write-DoctorLog -Message "복구 실패 $($failed.Count)개:"
        foreach ($name in $failed) {
            Write-DoctorLog -Message "  - $(ConvertTo-DisplaySafe -Text $name)"
        }
        Write-DoctorLog -Message "위 섹션은 아직 오염 상태입니다. 원인 메시지를 확인한 뒤 다시 실행하세요."
        return 1
    }

    return 0
}

# --- migrate subcommand (PROF-12 / D-01/D-02/D-03/D-06/D-07) ---
#
# PowerShell twin of get-customer-credentials.sh's run_migration_once / do_migrate.
# The bash side is the parity source of truth: the "[migrate] " prefix, the reason
# tokens, the completion-marker filename, the migration id and the shared lock
# path must stay identical. test/credentials-parity.test.sh enforces that
# statically -- do NOT re-shape any of them here.
#
# Contract:
#   stdout : ALWAYS EMPTY on every path (stdout carries the 5-key
#            credential_process JSON contract).
#   stderr : every line prefixed "[migrate] " (the [guard]/[doctor] lines the
#            reused helpers emit are the documented exception).
#   rc     : 0 on success AND on the already-migrated no-op; non-zero only on a
#            fail-closed abort.
#   tokens : name-collision (D-07), config-unparseable (Pitfall 7).
#   NO confirmation prompt, ever (D-02): there is no TTY on the
#   credential_process path, so a prompt would hang the whole fleet.

# Test-MigrationCompleted
# $true when $MigrationId has already been recorded. A missing record file means
# "not yet". This is the FIRST thing Invoke-MigrationOnce does -- in the steady
# state (every AWS call on an already-migrated machine) the entire cost of the
# migration hook must be this one substring scan of a tiny file.
function Test-MigrationCompleted {
    if (-not (Test-Path -LiteralPath $MigrationRecord)) { return $false }
    try {
        # -SimpleMatch on the exact literal the writer emits, the same discipline
        # Test-AlreadyRecordedSkip uses. ConvertTo-Json -Compress puts no space
        # after the colon, so this pair is byte-identical to what was written.
        return [bool](Select-String -LiteralPath $MigrationRecord -SimpleMatch "`"id`":`"$MigrationId`"" -Quiet)
    }
    catch {
        return $false
    }
}

# Write-MigrationRecord <renamed> <repaired> <skipped>
# Appends the one-line completion record. Built as an ORDERED hashtable and
# serialized with ConvertTo-Json -Compress -- never string-concatenated JSON,
# the same rule Write-GuardSkipRecord follows. [ordered] so "id" is the first
# key on every platform, which is what Test-MigrationCompleted scans for.
# Best-effort append: losing the marker would silently RE-ARM a destructive
# migration, but so would letting an append failure abort the run.
function Write-MigrationRecord {
    param([int]$Renamed = 0, [int]$Repaired = 0, [int]$Skipped = 0)

    try {
        $now = [DateTimeOffset]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
        $record = [ordered]@{
            id           = $MigrationId
            completed_at = $now
            renamed      = $Renamed
            repaired     = $Repaired
            skipped      = $Skipped
        } | ConvertTo-Json -Compress
        Add-Content -LiteralPath $MigrationRecord -Value $record -Encoding UTF8
    }
    catch {
        # Best-effort -- never let the marker append become the thing that fails
        # an otherwise successful migration.
    }
}

# Stop-MigrateUnparseable <exit_code>
# Pitfall 7 / T-23-30. A non-zero `aws configure list-profiles` means the config
# is UNREADABLE -- which is a different fact from "nothing to migrate". Treating
# it as the latter would write the completion marker and permanently skip the
# machine that most needs the repair, so this branch records NOTHING and returns
# non-zero. Mirrors Stop-DoctorUnparseable's cause list under the [migrate]
# prefix (it cannot call that one: the prefix is baked into every line there).
function Stop-MigrateUnparseable {
    param([int]$ExitCode)

    $configFile = Join-Path $HomeDir ".aws/config"

    [Console]::Error.WriteLine("[migrate] reason=config-unparseable")
    [Console]::Error.WriteLine("[migrate] 중단: ~/.aws/config 를 읽을 수 없습니다 (aws configure list-profiles exit=${ExitCode}).")
    [Console]::Error.WriteLine("[migrate] 이 상태에서는 섹션을 볼 수 없으므로 '대상 없음'으로 간주하지 않고 중단합니다.")
    [Console]::Error.WriteLine("[migrate] 흔한 원인:")
    [Console]::Error.WriteLine("[migrate]   - 파일 맨 앞의 UTF-8 BOM (에디터가 붙였을 수 있음)")
    [Console]::Error.WriteLine("[migrate]   - 같은 [profile X] 섹션 헤더가 두 번 존재")
    [Console]::Error.WriteLine("[migrate]   - 닫는 ']' 가 빠진 헤더")

    # @()-wrapped: a one-element result would otherwise unwrap to a scalar and
    # .Count would report the string length instead of 1.
    # Ordered by NAME, never by LastWriteTime -- see list_recent_backups_note.
    $backups = @(Get-ChildItem -LiteralPath (Split-Path -Parent $configFile) -Filter "config.bak.*" -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '\.bak\.[0-9]{14}$' } |
        Sort-Object -Property Name -Descending | Select-Object -First 3)

    if ($backups.Count -eq 0) {
        [Console]::Error.WriteLine("[migrate] 최근 백업: 백업 파일이 없습니다")
    }
    else {
        [Console]::Error.WriteLine("[migrate] 최근 백업:")
        foreach ($b in $backups) { [Console]::Error.WriteLine("[migrate]   $($b.FullName)") }
        [Console]::Error.WriteLine("[migrate] 복구하려면: cp `"$($backups[0].FullName)`" `"$configFile`"")
    }

    [Console]::Error.WriteLine("[migrate] 아무것도 바꾸지 않았습니다 — 원인을 고친 뒤 다시 실행하면 그때 마이그레이션합니다.")
    return 1
}

# Get-MigrateTargetName <old_profile_name>
# The `csg-` namespaced target name for <old>, or $null when the old name cannot
# be normalized into a legal profile name.
# Get-DerivedProfileName is THE single owner of the naming rule (D-03/D-08) and
# that is the whole reason the target name is not recomputed here. -NoAbort is
# the PowerShell stand-in for bash's SUBSHELL around derive_profile_name: its
# rejection path calls Stop-RegisterWithError, and `exit` inside a PowerShell
# function terminates the script outright -- in-process that would take the
# migration down mid-fleet.
function Get-MigrateTargetName {
    param([string]$OldName)
    return (Get-DerivedProfileName -AccountName $OldName -NoAbort)
}

# Get-ConfigProfileNames
# @{ Rc = <exit code>; Names = <string[]> } from `aws configure list-profiles`.
# The ONE enumeration behind both the collision probe and the post-delete
# confirmation in Invoke-DoMigrate.
# `aws configure get` deliberately does NOT serve the latter: aws-cli returns 255
# -- not 1 -- for a profile that does not exist AT ALL, which is
# indistinguishable from an unparseable config (the same WR-05 fact recorded on
# Stop-ConfigUnparseable). list-profiles separates the two cleanly: rc 0 with the
# name absent is a confirmed deletion; any non-zero rc is a failure, never a
# "well, it's gone then".
# S4/T-22-03 fence: $LASTEXITCODE is read on the VERY NEXT LINE and the
# preference is relaxed for the duration, so a native command writing to a
# redirected stderr cannot raise a terminating NativeCommandError.
function Get-ConfigProfileNames {
    $rc = 255
    $names = @()
    $previousPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        $names = @(& aws configure list-profiles 2>$null)
        $rc = $LASTEXITCODE
    }
    catch {
        $rc = 255
    }
    finally {
        $ErrorActionPreference = $previousPreference
    }
    return @{ Rc = $rc; Names = $names }
}

# Test-ProfileNameListed <names> <name>
# Case-SENSITIVE membership, the PowerShell twin of bash's `grep -Fxq --`.
# -contains would fold case, and AWS profile names do not.
function Test-ProfileNameListed {
    param([string[]]$Names, [string]$Name)

    foreach ($candidate in $Names) {
        if (([string]$candidate).Trim() -ceq $Name) { return $true }
    }
    return $false
}

# Invoke-DoMigrate
# The 23-RESEARCH Pattern 3 classification table, executed in the ONE order that
# is correct: class E surgery over every section FIRST, then the class A/B rename
# pass. A repaired section carries no CSG evidence any more, so it falls out of
# the rename pass on its own; the reverse order fires renames at still-poisoned
# sections and produces contaminated-hybrid abort noise for sections that were
# about to be fixed anyway.
#
# Renaming is delegated to the `register` subcommand as a SUBPROCESS, never
# called in-process: every one of Invoke-DoRegister's outcomes ends in `exit`, so
# an in-process call would terminate the migration mid-fleet. Delegating also
# means the frozen collision table -- above all its account-mismatch abort, the
# guard against silently re-pointing a customer profile at a different account
# (T-23-35) -- is consumed as-is rather than reimplemented here.
#
# Never throws for an individual profile: one that cannot be converted is counted
# as skipped and reported, because one collision must not abandon the rest of the
# fleet (D-07).
function Invoke-DoMigrate {
    $configFile = Join-Path $HomeDir ".aws/config"

    $script:MigrateRenamed = 0
    $script:MigrateRepaired = 0
    $script:MigrateSkipped = 0
    $script:MigrateTransientFailures = 0

    # ONE rollback point for the whole session. The path is reserved here and the
    # file is created EAGERLY as soon as pass 1 knows there is work to do (see
    # the $migPending block below), never lazily by whichever helper happens to
    # mutate first -- see CR-02.
    $backupSession = "$configFile.bak.$(Get-Date -Format 'yyyyMMddHHmmss')"
    $script:CsgBackupSession = $backupSession
    # Same rationale as Invoke-DoDoctor: the "run doctor to repair" advisory would
    # tell the engineer to run the repair that is running right now. The JSONL
    # audit record is still written.
    $script:GuardSkipQuiet = $true

    # Absolute path of THIS script. $PSCommandPath is the resolved full path under
    # `pwsh -File`; $PSScriptRoot is the fallback. NEVER derived from a config
    # value -- see the identical note in the register handler. (Spelled that way
    # so a `grep -c` for the register function name inside this range stays 0:
    # the ONLY register in here is the child PROCESS below.)
    $scriptAbs = $PSCommandPath
    if ([string]::IsNullOrEmpty($scriptAbs)) {
        $scriptAbs = Join-Path $PSScriptRoot "get-customer-credentials.ps1"
    }

    $renamedOld = [System.Collections.Generic.List[string]]::new()
    $renamedNew = [System.Collections.Generic.List[string]]::new()

    try {
        # ---- Pass 1: class E (contaminated hybrid) surgery, D-03 ----
        # The section belongs to the ENGINEER. Only the two keys CSG injected come
        # out; the header and every sso_*/region/output key survive with their
        # values. A contaminated section is NEVER renamed.
        $contaminated = [System.Collections.Generic.List[string]]::new()
        # The profile array is CAPTURED (not piped to Out-Null as it used to be):
        # the CR-02 pending-work probe below needs the pre-surgery rename
        # candidates, and re-reading the file to get them would be a second parse.
        $preProfiles = Get-CsgProfiles -ConfigFile $configFile -Mode "all" -ContaminatedOut $contaminated
        if ($null -eq $preProfiles) { $preProfiles = @() }

        # ---- CR-02: the backup is taken HERE, before ANY mutation ----
        # It used to be created lazily by the first helper that happened to
        # rewrite the file. On a machine with no contaminated sections -- the
        # common case -- that first helper is Remove-ProfilesFromConfig, which
        # runs AFTER the `register` CHILD has already written the new section, so
        # the file advertised as `[migrate] backup=` already contained register's
        # work and was not a pre-migration rollback point at all. On the
        # owned-same re-register path that was outright unrecoverable data loss.
        #
        # FM-05 ("a run with nothing to do leaves no .bak") still holds: the
        # snapshot is conditional on at least one pending unit of work, and the
        # candidate set is exactly the one that could ever have produced a .bak
        # before -- a class-E surgery or a real rename.
        # CR-03: a contaminated section that is in $SkipProfiles is REPORTED but
        # never operated on, so it is not a unit of work and must not mint a .bak.
        $migPending = $false
        foreach ($probe in $contaminated) {
            if (-not (Test-IsSkipProfile -Name $probe)) { $migPending = $true; break }
        }
        if (-not $migPending) {
            foreach ($probe in $preProfiles) {
                $probeTarget = Get-MigrateTargetName -OldName $probe.ProfileName
                if (-not [string]::IsNullOrEmpty($probeTarget) -and $probeTarget -cne $probe.ProfileName) {
                    $migPending = $true
                    break
                }
            }
        }
        if ($migPending -and -not (Test-Path -LiteralPath $backupSession)) {
            try { Copy-Item -LiteralPath $configFile -Destination $backupSession -Force } catch { }
        }

        foreach ($name in $contaminated) {
            $dispOld = ConvertTo-DisplaySafe -Text $name
            # CR-03: same filter as Invoke-DoDoctor step (3). Get-CsgProfiles's
            # -ContaminatedOut is deliberately blind to $SkipProfiles so it can
            # REPORT poisoned infra sections; it must never be used as an action
            # list without this gate, or migrate strips credential_process from
            # the `csg-login` login anchor.
            if (Test-IsSkipProfile -Name $name) {
                [Console]::Error.WriteLine("[migrate] 보호 섹션 — 수술 제외, 수동 확인 필요: $dispOld")
                continue
            }
            $repairOk = $false
            try {
                $repairOk = Remove-KeysFromProfile -ConfigFile $configFile -ProfileName $name -Keys @("csg_managed", "credential_process")
            }
            catch {
                $repairOk = $false
            }
            if ($repairOk) {
                $script:MigrateRepaired++
                [Console]::Error.WriteLine("[migrate] 오염 섹션 복구: $dispOld")
            }
            else {
                $script:MigrateSkipped++
                # WR-08: TRANSIENT. The section is still poisoned and a later run
                # can still fix it, so the completion marker must not be written.
                $script:MigrateTransientFailures++
                [Console]::Error.WriteLine("[migrate] reason=repair-failed $dispOld")
            }
        }

        # ---- Pass 2: re-read. Surgery changed the file, and a repaired section is
        #      now class F (foreign, no CSG evidence) -- it must not be
        #      re-classified from the pre-surgery snapshot.
        # NOT @()-wrapped: Get-CsgProfiles returns `,$array`, i.e. it emits the
        # whole array as ONE pipeline item precisely so the caller receives it
        # intact. An extra @() around that produces a 1-element array whose single
        # element is the profile array, and the loop below then sees one "profile"
        # whose .ProfileName is every name at once.
        $migProfiles = Get-CsgProfiles -ConfigFile $configFile -Mode "all"
        if ($null -eq $migProfiles) { $migProfiles = @() }

        # Classes F (foreign without CSG evidence) and G ($SkipProfiles, incl.
        # csg-login and default) never reach this loop: Test-IsCsgProfile vetoes
        # both, so Get-CsgProfiles never reports them.
        # D-06: the currently-invoked profile is NOT excluded. There is no
        # PROF-06-style self-protection here -- skipping the most-used profile
        # would leave the fleet in two shapes forever.
        foreach ($entry in $migProfiles) {
            $name = $entry.ProfileName
            $dispOld = ConvertTo-DisplaySafe -Text $name

            $newName = Get-MigrateTargetName -OldName $name
            if ([string]::IsNullOrEmpty($newName)) {
                $script:MigrateSkipped++
                [Console]::Error.WriteLine("[migrate] reason=invalid-name $dispOld")
                continue
            }

            # ---- Classes C and D: already inside the `csg-` namespace ----
            # Get-DerivedProfileName strips a single leading `csg-` before
            # re-applying it, so an already-namespaced name maps to itself. Class C
            # (marker present) is a no-op; class D (marker missing) gets the marker
            # backfilled and nothing else. -ceq: AWS profile names are
            # case-SENSITIVE.
            if ($newName -ceq $name) {
                $markerProbe = Invoke-AwsConfigureGet -Key "csg_managed" -ProfileName $name
                if ($markerProbe.Rc -eq 1) {
                    $setRc = 255
                    $previousPreference = $ErrorActionPreference
                    try {
                        $ErrorActionPreference = "Continue"
                        & aws configure set csg_managed $CsgManagedVersion --profile $name 2>$null | Out-Null
                        $setRc = $LASTEXITCODE
                    }
                    catch {
                        $setRc = 255
                    }
                    finally {
                        $ErrorActionPreference = $previousPreference
                    }
                    if ($setRc -eq 0) {
                        [Console]::Error.WriteLine("[migrate] 마커 보강: $dispOld")
                    }
                    else {
                        $script:MigrateSkipped++
                        # WR-08: TRANSIENT -- the section is convertible, the
                        # write just did not land this time.
                        $script:MigrateTransientFailures++
                        [Console]::Error.WriteLine("[migrate] reason=marker-backfill-failed $dispOld")
                    }
                }
                continue
            }

            $dispNew = ConvertTo-DisplaySafe -Text $newName

            # ---- Classes A and B: legacy un-prefixed CSG sections ----
            # D-08: the account id is recovered OFFLINE from the section's own
            # credential_process. Zero BILLING calls, and
            # Get-AccountIdFromCredentialProcess stays the single home of that
            # pattern -- no second regex is written here.
            $accountId = $null
            $cpProbe = Invoke-AwsConfigureGet -Key "credential_process" -ProfileName $name
            if ($cpProbe.Rc -eq 0) {
                $accountId = Get-AccountIdFromCredentialProcess -CpValue $cpProbe.Value
            }
            if ([string]::IsNullOrEmpty($accountId)) {
                $script:MigrateSkipped++
                [Console]::Error.WriteLine("[migrate] reason=no-account-id $dispOld")
                continue
            }

            # Collision probe, re-taken per profile because every rename changes
            # the profile set. Only used to LABEL the outcome -- the decision
            # itself is register's (D-07 class H).
            $targetExisted = $false
            $beforeProbe = Get-ConfigProfileNames
            if ($beforeProbe.Rc -eq 0) {
                $targetExisted = Test-ProfileNameListed -Names $beforeProbe.Names -Name $newName
            }

            # D-08: the OLD profile name is passed as --account-name; the child
            # derives the target itself, so exactly one naming rule exists.
            # ProcessStartInfo (not Start-Process / not `&` with a `2>` file
            # redirect): ArgumentList passes each argument as its own element, so a
            # profile name containing spaces or quotes cannot be re-split, and the
            # stderr text arrives verbatim instead of through PowerShell's
            # file-redirection formatter (which line-wraps at the host width).
            # Both streams are drained ASYNCHRONOUSLY -- reading one to the end
            # while the other fills its pipe buffer is the classic deadlock.
            # CSG_MIGRATE_ACTIVE is cheap insurance only -- the child hits the
            # routing block and exits long before the main flow, so it cannot
            # re-enter this hook.
            $regRc = 255
            $regOut = ""
            $regErr = ""
            try {
                $psi = [System.Diagnostics.ProcessStartInfo]::new()
                $psi.FileName = "pwsh"
                foreach ($childArg in @("-NoProfile", "-File", $scriptAbs, "register",
                                        "--account-id", $accountId, "--account-name", $name)) {
                    [void]$psi.ArgumentList.Add($childArg)
                }
                $psi.UseShellExecute = $false
                $psi.RedirectStandardOutput = $true
                $psi.RedirectStandardError = $true
                $psi.EnvironmentVariables["CSG_MIGRATE_ACTIVE"] = "1"

                $child = [System.Diagnostics.Process]::Start($psi)
                $outTask = $child.StandardOutput.ReadToEndAsync()
                $errTask = $child.StandardError.ReadToEndAsync()
                $child.WaitForExit()
                $regOut = $outTask.GetAwaiter().GetResult()
                $regErr = $errTask.GetAwaiter().GetResult()
                $regRc = $child.ExitCode
                $child.Dispose()
            }
            catch {
                $regRc = 255
            }

            # register's success contract: EXACTLY ONE stdout line, the new name.
            $newSection = ""
            if (-not [string]::IsNullOrWhiteSpace($regOut)) {
                $firstLine = @($regOut -split "`n" | Where-Object { $_.Trim() -ne "" } | Select-Object -First 1)
                if ($firstLine.Count -gt 0) { $newSection = ([string]$firstLine[0]).Trim() }
            }

            if ($regRc -eq 0 -and -not [string]::IsNullOrEmpty($newSection)) {
                # D-01: the old section is DELETED. No alias, no forwarding
                # section. Remove-ProfilesFromConfig is the project's ONLY section
                # deleter -- backup, atomic write, header normalization,
                # post-condition re-read and the PROF-14 recovery notice all live
                # in it. It returns nothing (adding a return value would leak a
                # boolean into the stdout of every existing BARE call site, and
                # this script's stdout is the credential JSON contract), so the
                # deletion is confirmed by re-enumerating: rc 0 with the old name
                # absent, and nothing else, counts as removed.
                # The [guard] deletion notice is suppressed here (see
                # CSG_RENAME_NOTICE in Remove-ProfilesFromConfig) and replaced by
                # the rename-specific line below, which says where the settings
                # went instead of only that a section disappeared.
                # CR-01: make the rename an actual rename BEFORE the old section
                # is deleted. The register child authored csg_managed / region /
                # output / credential_process from its own hardcoded defaults;
                # every other key -- and the engineer's own region/output -- only
                # exists in the section that is about to disappear.
                $carryOk = $false
                try {
                    $carryOk = Copy-SectionKeys -ConfigFile $configFile -OldProfile $name `
                        -NewProfile $newSection -OwnedKeys @("csg_managed", "credential_process")
                }
                catch {
                    $carryOk = $false
                }
                if (-not $carryOk) {
                    $script:MigrateSkipped++
                    $script:MigrateTransientFailures++
                    [Console]::Error.WriteLine("[migrate] reason=carry-failed $dispOld")
                    [Console]::Error.WriteLine("[migrate] 구 섹션은 삭제하지 않았습니다 — 설정을 옮기지 못했기 때문입니다.")
                    continue
                }

                $deleteOk = $false
                $prevRenameNotice = $env:CSG_RENAME_NOTICE
                try {
                    $env:CSG_RENAME_NOTICE = "1"
                    Remove-ProfilesFromConfig -ConfigFile $configFile -ProfilesToRemove @($name)
                    $afterProbe = Get-ConfigProfileNames
                    $deleteOk = ($afterProbe.Rc -eq 0 -and -not (Test-ProfileNameListed -Names $afterProbe.Names -Name $name))
                }
                catch {
                    $deleteOk = $false
                }
                finally {
                    $env:CSG_RENAME_NOTICE = $prevRenameNotice
                }

                if ($deleteOk) {
                    $renamedOld.Add($name)
                    $renamedNew.Add($newSection)
                    $script:MigrateRenamed++
                    $dispNewSection = ConvertTo-DisplaySafe -Text $newSection
                    [Console]::Error.WriteLine("[migrate] 개명: $dispOld → $dispNewSection (구 섹션 제거, 설정은 새 섹션으로 이전)")
                    # CR-02: the target ALREADY existed and register
                    # re-registered over it (the owned-same row of the collision
                    # table), so that section's previous settings were replaced by
                    # this one's. Say so -- the rename line above alone reads as
                    # if a new section had been minted. The pre-migration .bak
                    # (taken above) is where the replaced values still exist.
                    if ($targetExisted) {
                        [Console]::Error.WriteLine("[migrate] reason=target-overwritten $dispOld → $dispNew (기존 섹션의 설정이 대체되었습니다)")
                    }
                }
                else {
                    $script:MigrateSkipped++
                    # WR-08: TRANSIENT, and the WORST of the three -- register has
                    # already created csg-<name>, so the machine is left with BOTH
                    # the old section and the new one, pointing at the same
                    # account. Writing the completion marker here would guarantee
                    # migrate never revisits that duplication.
                    $script:MigrateTransientFailures++
                    [Console]::Error.WriteLine("[migrate] reason=delete-failed $dispOld")
                }
                continue
            }

            # Abort. register left ~/.aws/config byte-identical, so the old section
            # is still there and still working -- which is exactly what D-07 asks
            # for. Report, count, and carry on with the rest of the fleet.
            # The child's stderr is NEVER echoed wholesale (T-23-34): only the
            # single machine-readable token is lifted out of it.
            $token = ""
            foreach ($errLine in ($regErr -split "`n")) {
                if ($errLine.TrimEnd("`r") -cmatch '^\[register\] reason=(.+)$') {
                    $token = $Matches[1].Trim()
                    break
                }
            }
            if ([string]::IsNullOrEmpty($token)) { $token = "register-failed" }
            $token = ConvertTo-DisplaySafe -Text $token

            $script:MigrateSkipped++
            if ($targetExisted) {
                [Console]::Error.WriteLine("[migrate] reason=name-collision $dispOld → $dispNew (register=$token)")
            }
            else {
                [Console]::Error.WriteLine("[migrate] reason=$token $dispOld")
            }
        }

        # ---- Summary (D-01/D-02) ----
        # Bounded on purpose: one line per profile plus a fixed tail. This runs on
        # the credential_process hot path on the first post-update invocation.
        # Profile names come from a file this script does not own, so every one of
        # them goes through ConvertTo-DisplaySafe before it reaches a terminal or a
        # CI log (T-23-31). Key NAMES and profile names only -- never key values.
        for ($i = 0; $i -lt $renamedOld.Count; $i++) {
            $mapOld = ConvertTo-DisplaySafe -Text $renamedOld[$i]
            $mapNew = ConvertTo-DisplaySafe -Text $renamedNew[$i]
            [Console]::Error.WriteLine("[migrate] $mapOld → $mapNew")
        }

        [Console]::Error.WriteLine("[migrate] rewritten=$($script:MigrateRenamed)")
        [Console]::Error.WriteLine("[migrate] repaired=$($script:MigrateRepaired)")
        [Console]::Error.WriteLine("[migrate] skipped=$($script:MigrateSkipped)")
        if (Test-Path -LiteralPath $backupSession) {
            [Console]::Error.WriteLine("[migrate] backup=$backupSession")
        }
        # Pitfall 5: the agent is holding the OLD names in its conversation context
        # and will keep issuing `aws --profile <old>` unless it is told, in the same
        # breath as the mapping table, that those names no longer exist.
        if ($script:MigrateRenamed -gt 0) {
            [Console]::Error.WriteLine("[migrate] 지금부터는 위 표의 새 이름을 쓰세요. 예전 이름으로 `"aws --profile <구명>`" 을 호출하면 실패합니다.")
        }
        if ($script:MigrateRepaired -gt 0) {
            [Console]::Error.WriteLine("[migrate] 복구한 섹션은 `"aws sso login --profile <프로필>`" 로 로그인이 아직 유효한지 확인하세요.")
        }
    }
    finally {
        # Both flags are session-scoped: doctor, sweep and cleanup must see them
        # exactly as they were before migrate ran.
        $script:GuardSkipQuiet = $false
        $script:CsgBackupSession = ""
    }
}

# Invoke-MigrationOnce
# The idempotent entry point. Safe to call from anywhere, in any order relative
# to sweep -- it takes the SAME lock sweep does, so the two can never rewrite
# ~/.aws/config concurrently (T-23-29).
function Invoke-MigrationOnce {
    # (1) Completion marker FIRST -- before the lock and before ~/.aws/config is
    #     opened. Steady-state cost is one substring scan of a small file.
    if (Test-MigrationCompleted) {
        [Console]::Error.WriteLine("[migrate] status=already-migrated")
        return 0
    }

    $configFile = Join-Path $HomeDir ".aws/config"
    if (-not (Test-Path -LiteralPath $configFile)) {
        [Console]::Error.WriteLine("[migrate] ~/.aws/config 가 없습니다 — 마이그레이션 대상 없음.")
        Write-MigrationRecord -Renamed 0 -Repaired 0 -Skipped 0
        return 0
    }

    # (2) The SHARED sweep lock, not a second one (Lock-Sweep's default path).
    #     Non-blocking: losing the race returns 0 in silence, because the work is
    #     idempotent and the next invocation will pick it up.
    if (-not (Lock-Sweep)) { return 0 }

    try {
        # (3) FAIL CLOSED. AWS_CONFIG_FILE is pinned so the verdict is about the
        #     file migrate would actually rewrite, never whatever the ambient
        #     environment resolves. NO marker is written on this branch
        #     (Pitfall 7). S4/T-22-03 fence, same shape as Invoke-DoDoctor's:
        #     $LASTEXITCODE is read on the VERY NEXT LINE and the preference is
        #     relaxed for the duration so a native command writing to a
        #     redirected stderr cannot raise a terminating NativeCommandError.
        #     On the catch path $listRc stays non-zero -- fail-CLOSED.
        $prevConfigFile = $env:AWS_CONFIG_FILE
        $prevProfileEnv = $env:AWS_PROFILE
        $prevDefaultProfileEnv = $env:AWS_DEFAULT_PROFILE
        $previousPreference = $ErrorActionPreference
        $listRc = 255
        try {
            $ErrorActionPreference = "Continue"
            $env:AWS_CONFIG_FILE = $configFile
            Remove-Item -LiteralPath "Env:\AWS_PROFILE" -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath "Env:\AWS_DEFAULT_PROFILE" -ErrorAction SilentlyContinue
            & aws configure list-profiles 2>$null | Out-Null
            $listRc = $LASTEXITCODE
        }
        catch {
            $listRc = 255
        }
        finally {
            $ErrorActionPreference = $previousPreference
            if ($null -eq $prevConfigFile) { Remove-Item -LiteralPath "Env:\AWS_CONFIG_FILE" -ErrorAction SilentlyContinue }
            else { $env:AWS_CONFIG_FILE = $prevConfigFile }
            if ($null -ne $prevProfileEnv) { $env:AWS_PROFILE = $prevProfileEnv }
            if ($null -ne $prevDefaultProfileEnv) { $env:AWS_DEFAULT_PROFILE = $prevDefaultProfileEnv }
        }

        if ($listRc -ne 0) {
            return (Stop-MigrateUnparseable -ExitCode $listRc)
        }

        # (4) The work itself.
        Invoke-DoMigrate | Out-Null

        # (5) Record completion -- but ONLY when nothing failed TRANSIENTLY.
        #     Written BEFORE the lock is released so a concurrent loser that
        #     retries immediately sees the marker.
        #
        #     WR-08: D-07 asks for the marker on a name-collision, and that is
        #     right -- the old section is untouched and still works, and no
        #     number of retries frees the occupied target, so re-arming would
        #     loop forever. account-mismatch and no-account-id are equally
        #     PERMANENT verdicts.
        #
        #     delete-failed / repair-failed / marker-backfill-failed /
        #     carry-failed are NOT verdicts, they are failed writes.
        #     delete-failed is the worst: it is reached AFTER register created
        #     csg-<name>, so the machine is left with X and csg-X both present
        #     and both pointing at the same account.
        if ($script:MigrateTransientFailures -eq 0) {
            Write-MigrationRecord -Renamed $script:MigrateRenamed -Repaired $script:MigrateRepaired -Skipped $script:MigrateSkipped
        }
        else {
            [Console]::Error.WriteLine("[migrate] 마커를 기록하지 않았습니다 — 다음 실행에서 재시도합니다 (일시적 실패 $($script:MigrateTransientFailures)건)")
        }
        return 0
    }
    finally {
        Unlock-Sweep
    }
}

# --- scope brake helpers (SCP-05) ---
#
# PowerShell twin of get-customer-credentials.sh's scope brake engine.
#
# THE BASH SIDE IS THE PARITY SOURCE OF TRUTH. Every literal, every filename, the
# lock path, the record shape and every stderr byte below mirrors it, and where
# the two disagree the .sh wins. test/credentials-parity.test.sh enforces that
# statically from 24-04 (PARITY-SCOPE-CONST / -ROUTE / -TOKENS) -- do NOT
# re-shape any of them here. Four divergences are deliberate and each is argued
# where it occurs: the copied lock body with its own singletons, try/finally
# release, the bounded-retry append, and the client filename on the refusal's
# final line.
#
# ENGINE ONLY. Nothing below is called from anywhere yet, deliberately. The
# scope-ack routing branch, Invoke-DoScopeAck and the main-flow brake check
# between the request-body build and the broker POST are all 24-04's. This
# section holds function definitions and comments and nothing else, the same
# property the Profile cleanup, register and migrate sections above have.
#
# FAIL-OPEN BY CONSTRUCTION. Every reader here answers empty/zero on a missing,
# empty, truncated, garbled or fully-binary state file and never throws. That
# matters more on this side than on bash's: $ErrorActionPreference = "Stop" is
# active file-wide, so an ordinary Get-Content on a missing path is a TERMINATING
# error. Every file touch therefore carries a Test-Path guard, a try/catch, or
# -ErrorAction SilentlyContinue. The state is local, agent-owned and disposable;
# killing a legitimate single-account issuance because of a corrupt local file is
# strictly worse than missing one fan-out (CLAUDE.md Core Value).
#
# STDOUT DISCIPLINE AND PIPELINE HYGIENE. On the credential_process path stdout is
# the 5-key JSON contract and nothing else (T-24-05). PowerShell emits every
# un-consumed expression value to the success stream, which makes this a
# correctness requirement rather than a style nit: a bare $set.Add($x) (returns
# [bool]) or a bare New-Item (returns a FileSystemInfo) turns a [string] return
# value into an [Object[]], and 24-04's call sites would then be comparing an
# array against $ScopeMaxAccounts. Every such call below is [void]-cast or piped
# to Out-Null, and every function has exactly one explicit return value. This is
# the pwsh analog of the bash twin's "never `local x=$( … )`" rule, and no linter
# in this repo catches it.

# Lock-Scope [-LockFilePath <path>]   -> [bool]. $true when acquired. Never throws.
# Unlock-Scope                        -> void. Unlinks only if this process holds it.
#
# A COPY of Lock-Sweep's body, not a delegation, and the copy is the point.
# Lock-Sweep parks its handle in the sweep's own script-scoped singletons, so a
# brake prune running while a sweep holds that lock would clobber them; the full
# argument sits at the singleton declarations near the top of this file. The
# brake therefore mints its own pair and takes its own path. bash can delegate
# because its lock carries no in-process state at all -- the two clients differ
# in code and agree in behaviour.
#
# T-23-29, summarised because the reasoning transfers verbatim: the handle this
# function takes is an OS-held exclusive handle (flock on Unix, a share-mode
# handle on Windows), released by the KERNEL when the holder dies, including on
# SIGKILL. A lock file left behind by a dead process is therefore just a file and
# the very next Open() succeeds on it -- a stale HANDLE cannot exist. That is why
# there is no stale-PID recovery on the FAILURE path here. The implementation
# that had one read the holder's PID out of the lock file AFTER a failed Open(),
# which is impossible under FileShare::None: the read always threw, every
# contender always concluded "stale", deleted the live holder's file and acquired
# a second lock on a fresh inode. The lock excluded nobody. Treating a failed
# Open() as "held" is both correct and the fail-safe direction.
#
# The live-PID pre-check below is the opposite case and is NOT that dance: it runs
# BEFORE any handle exists, because the bash twin's lock is an O_EXCL file plus
# its pid rather than an OS handle (there is no portable flock on macOS), so
# Open() would happily succeed while bash is mid-write. Only a pid that is
# DEFINITELY alive counts as held; an unreadable or dead pid falls through to
# Open(), which stays the authority for pwsh<->pwsh.
#
# Non-blocking by design (T-24-06): the loser returns immediately and in silence.
# No retry loop, no wait, no prompt anywhere on this path -- the file header
# records a ~120s agent hang from exactly that class, and this code runs on the
# credential_process path where there is no TTY at all.
#
# THE ACQUIRE IS FileMode::CreateNew, NEVER OpenOrCreate (24-08 / WR-01 residual,
# measured -- do not "simplify" it back). Lock-Sweep uses OpenOrCreate and gets
# away with it because it is taken once per process; the brake takes this lock on
# every credential invocation, so the release path runs constantly and OpenOrCreate
# opens a TWO-HOLDER window across it:
#   A holds inode I1. A's Unlock-Scope disposes the handle and THEN unlinks --
#   two statements, and Remove-Item is a cmdlet dispatch, so the gap is
#   milliseconds. A contender B whose pre-check read threw (A held it under
#   FileShare::None, so the read cannot succeed) falls through to Open() in that
#   gap; OpenOrCreate happily attaches to the still-linked I1 and B believes it
#   holds the lock. A then unlinks I1 out from under B. A third contender C finds
#   no file, creates a FRESH inode I2, and also believes it holds the lock. B and
#   C append concurrently, .NET's seek-to-end append resolves one offset twice and
#   one window record is lost -- silently, which is the exact failure 24-08 exists
#   to close. Measured on macOS 25.4 / pwsh 7.6.2 / APFS: 5 of 20 twelve-way
#   fleets lost a record, with ZERO lock timeouts, and the losing runs printed
#   "Remove-Item: .scope.lock does not exist" from the process whose inode had
#   been deleted underneath it.
# CreateNew closes it by construction: acquiring REQUIRES creating the file, so
# nobody can attach to an inode that its owner is about to unlink, and while the
# file exists every contender declines. This is also what the bash twin has always
# done -- `( set -o noclobber; printf '%s' "$$" > "$lock_file" )` is O_EXCL, and
# CreateNew is its .NET spelling. The two clients now share one acquire protocol
# rather than merely one path.
#
# CreateNew makes RESIDUE RECLAIM mandatory rather than free: OpenOrCreate used to
# reclaim a dead holder's leftover file simply by opening it. Step (3b) below does
# it explicitly, and PARITY-SCOPE-LOCK case (3) -- "a dead pid in the bash FILE
# shape, pwsh reclaims" -- is the case that fails the moment it is dropped.
function Lock-Scope {
    param([string]$LockFilePath = $ScopeLock)

    # (1) Re-entrancy guard, and it must be the FIRST statement. This is an
    # addition over Lock-Sweep, which is only ever called once per process and so
    # never reaches the case. FileShare::None excludes a second handle from THIS
    # process too, so without the guard a second call would land in the catch
    # below and set $script:ScopeLockStream = $null while the first handle is
    # still open -- leaking the handle and turning Unlock-Scope into a permanent
    # no-op that never unlinks the file. Invoke-ScopePrune and 24-04's call sites
    # make a second in-process acquire reachable.
    if ($null -ne $script:ScopeLockStream) { return $false }

    # (2) Directory-shaped residue from a pre-Phase-23 bash client. Nothing holds
    # an OS lock on a directory, so it is residue, not a lock: clear it. Left in
    # place it makes [IO.File]::Open throw forever and the brake reads as
    # permanently held on every future run (WR-09).
    try {
        if ([IO.Directory]::Exists($LockFilePath)) {
            Remove-Item -LiteralPath $LockFilePath -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    catch { }

    # (3) Live-PID pre-check, BEFORE Open(). See the header.
    if ([IO.File]::Exists($LockFilePath)) {
        $readable = $false
        $holderPid = 0
        try {
            $raw = [IO.File]::ReadAllText($LockFilePath)
            $readable = $true
            $digits = ($raw -replace '[^0-9]', '')
            if (-not [string]::IsNullOrEmpty($digits)) { $holderPid = [int]$digits }
        }
        catch {
            # Unreadable => a live pwsh holds it under FileShare::None, which is
            # the ONE thing that cannot be residue. Decline here rather than
            # falling through: under CreateNew the acquire would decline anyway,
            # and returning now keeps the residue probe below off the contended
            # hot path entirely (it is reached only with positive evidence of
            # residue), which is what keeps the 40-spin/1000 ms budget intact.
            $readable = $false
        }
        if (-not $readable) {
            $script:ScopeLockStream = $null
            return $false
        }
        if ($holderPid -gt 0 -and $holderPid -ne $PID) {
            $holderAlive = $false
            try { $holderAlive = $null -ne (Get-Process -Id $holderPid -ErrorAction SilentlyContinue) } catch { $holderAlive = $false }
            if ($holderAlive) {
                $script:ScopeLockStream = $null
                return $false
            }
        }

        # (3b) Residue reclaim. We got here only by READING the file, and the pid
        # it named is gone (or it named none), so this is a leftover from a dead
        # holder -- exactly PARITY-SCOPE-LOCK case (3), the dead pid written in
        # the bash file shape. Under CreateNew the acquire below cannot reclaim it
        # implicitly, so unlink it here.
        #
        # NEVER unlink it unconditionally. Taking an exclusive handle on the
        # EXISTING inode first is what makes this safe: if a live pwsh acquired in
        # the gap since our read, that Open throws and we leave its file alone --
        # deleting a live holder's lock is the one direction that produces two
        # holders, the failure 23-07 and this header both describe. Two contenders
        # racing the reclaim serialize on this same handle: the first one unlinks,
        # the second one's Open fails against the vanished path and it simply
        # falls through to CreateNew.
        try {
            $residue = [IO.File]::Open(
                $LockFilePath,
                [IO.FileMode]::Open,
                [IO.FileAccess]::ReadWrite,
                [IO.FileShare]::None  # exclusive
            )
            $residue.Dispose()
            Remove-Item -LiteralPath $LockFilePath -Force -ErrorAction SilentlyContinue
        }
        catch { }
    }

    # Prepare encoding before taking the lock: cold PowerShell binding belongs
    # outside the critical section when many processes start simultaneously.
    $pidBytes = [System.Text.Encoding]::UTF8.GetBytes("$PID")
    # (4) Acquire. CreateNew, not OpenOrCreate -- see the header.
    try {
        $script:ScopeLockStream = [IO.File]::Open(
            $LockFilePath,
            [IO.FileMode]::CreateNew,
            [IO.FileAccess]::ReadWrite,
            [IO.FileShare]::None  # exclusive
        )
        # Our PID, for post-mortem inspection of an orphaned lock file and for the
        # bash twin's own live-holder pre-check. Deliberately NOT consulted on the
        # failure path below -- see the header.
        $script:ScopeLockStream.Write($pidBytes, 0, $pidBytes.Length)
        $script:ScopeLockStream.Flush()
        $script:ScopeLockPath = $LockFilePath
        return $true
    }
    catch {
        # (5) The kernel refused the exclusive handle, so a LIVE process holds it.
        $script:ScopeLockStream = $null
        return $false
    }
}

# Releases the brake lock. Removes the lock FILE only when this process actually
# held the handle: unlinking it otherwise would let a third process create a
# fresh inode and acquire a second "exclusive" lock while the real holder is
# still working. Same rule the sweep's release carries, on the brake's own pair.
function Unlock-Scope {
    if ($null -eq $script:ScopeLockStream) { return }

    $script:ScopeLockStream.Dispose()
    $script:ScopeLockStream = $null

    $lockFile = if ([string]::IsNullOrEmpty($script:ScopeLockPath)) {
        $ScopeLock
    } else {
        $script:ScopeLockPath
    }
    $script:ScopeLockPath = ""
    try { [IO.File]::Delete($lockFile) } catch { }
}

# Compile before acquiring a lock. Keeping acquisition, append and release in
# one managed call avoids cold PowerShell binding pauses while sibling processes
# wait. The on-disk PID/exclusive-file protocol and bounded advisory timeout stay
# compatible with Lock-Scope (pruning) and the Bash client's live-PID check.
function Initialize-ScopeFileWriter {
    if ('Msp.Csg.ScopeFileWriter' -as [type]) { return }
    Add-Type -TypeDefinition @'
using System;
using System.Diagnostics;
using System.IO;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
namespace Msp.Csg {
    public sealed class ScopeWriteResult {
        public bool Written { get; set; }
        public bool LockTimedOut { get; set; }
    }
    public static class ScopeFileWriter {
        private static bool LivePid(string text) {
            int pid;
            if (!Int32.TryParse(Regex.Replace(text, "[^0-9]", ""), out pid) || pid <= 0) return false;
            try { using (Process process = Process.GetProcessById(pid)) { return !process.HasExited; } }
            catch (ArgumentException) { return false; }
            catch { return true; } // Inability to inspect a process never proves it dead.
        }
        private static FileStream TryAcquire(string path, byte[] pid) {
            FileStream owner = null;
            try {
                if (Directory.Exists(path)) Directory.Delete(path, true);
                if (File.Exists(path)) {
                    // FileShare.None makes an active PowerShell holder unreadable;
                    // a readable live PID belongs to a Bash holder or a releaser.
                    if (LivePid(File.ReadAllText(path))) return null;
                    // Re-read on an exclusive handle before reclaiming residue.
                    // Delete while holding it, including on Windows, so another
                    // process cannot replace it between close and unlink.
                    using (FileStream residue = new FileStream(path, FileMode.Open, FileAccess.ReadWrite, FileShare.Delete)) {
                        using (StreamReader reader = new StreamReader(residue, Encoding.UTF8, true, 1024, true)) {
                            if (LivePid(reader.ReadToEnd())) return null;
                        }
                        File.Delete(path);
                    }
                }
                owner = new FileStream(path, FileMode.CreateNew, FileAccess.ReadWrite, FileShare.None);
                owner.Write(pid, 0, pid.Length);
                owner.Flush();
                return owner;
            }
            catch {
                if (owner != null) owner.Dispose();
                return null;
            }
        }
        public static ScopeWriteResult Append(string lockPath, string path, byte[] bytes, bool alreadyHeld) {
            // Allocate and encode before acquisition, not inside the critical section.
            UTF8Encoding encoding = new UTF8Encoding(false);
            string text = encoding.GetString(bytes);
            byte[] pid;
            using (Process current = Process.GetCurrentProcess()) {
                pid = Encoding.UTF8.GetBytes(current.Id.ToString());
            }
            FileStream owner = null;
            if (!alreadyHeld) {
                Stopwatch watch = Stopwatch.StartNew();
                for (int spin = 0; spin < 40; spin++) {
                    owner = TryAcquire(lockPath, pid);
                    if (owner != null || watch.ElapsedMilliseconds >= 1000) break;
                    Thread.Sleep(20);
                }
            }
            ScopeWriteResult result = new ScopeWriteResult { LockTimedOut = !alreadyHeld && owner == null };
            try {
                // AppendAllText is not assumed atomic. The shared lock serializes
                // writers; its existing advisory fallback still warns on timeout.
                for (int attempt = 0; attempt < 5; attempt++) {
                    try { File.AppendAllText(path, text, encoding); result.Written = true; break; }
                    catch { Thread.Sleep(20); }
                }
            }
            finally {
                if (owner != null) {
                    owner.Dispose();
                    try { File.Delete(lockPath); } catch { }
                }
            }
            return result;
        }
    }
}
'@
}

function Write-ScopeLineLocked {
    param([string]$Path = "", [byte[]]$Bytes = @())
    $alreadyHeld = ($null -ne $script:ScopeLockStream)
    Initialize-ScopeFileWriter
    return [Msp.Csg.ScopeFileWriter]::Append($ScopeLock, $Path, $Bytes, $alreadyHeld)
}

# Write-ScopeWindowRecord -AccountId <12 digits>   -> void
# Appends exactly ONE line -- {"ts":<epoch>,"accountId":"<12 digits>"} -- and
# returns, writing nothing to the success stream. One line per NEW-ISSUANCE
# ATTEMPT (D-01), which is why 24-04's caller belongs BEFORE the broker retry
# loop: a 503-then-200 recovery is one attempt, not three.
#
# No `acked` field. Acked-ness is derived at READ time by intersecting with the
# ack set, so no record is ever on disk carrying a value that is already stale.
#
# T-24-08: the argument is re-validated against ^[0-9]{12}$ HERE, at the write
# boundary. 24-04's caller validates -AccountId at the input gate, but
# re-validating means no unvalidated byte can reach the record no matter which
# caller is added later; an invalid argument writes nothing and still returns.
# The line is built as an [ordered] hashtable through ConvertTo-Json -Compress,
# never string-concatenated JSON -- the rule Write-GuardSkipRecord states.
# [ordered] so "ts" is the first key on every platform, and -Compress because it
# emits no space after a colon, the same property Test-MigrationCompleted already
# relies on and what makes this byte-identical to the bash twin's printf.
#
# THE TIMESTAMP IS DELIBERATELY A UNIX EPOCH, not the yyyy-MM-ddTHH:mm:ssZ string
# Write-MigrationRecord uses: the window needs arithmetic against a cutoff, and
# the bash twin's `date -u +%s` is the parity reference.
#
# RESEARCH A5 / Pitfall 8 -- WHY THIS IS A BOUNDED APPEND RETRY AND NOT
# THE Add-Content EVERY OTHER APPEND IN THIS FILE USES. Add-Content is
# open-write-close, and its analog in Write-MigrationRecord wraps the whole thing
# in a swallowing `catch { }`. That is correct for an advisory marker and wrong
# here: a swallowed sharing violation drops a WINDOW record, which under-counts
# the fan-out and weakens the brake -- categorically worse than losing an
# advisory line. So this path calls Write-ScopeLineLocked, retries a bounded
# number of times, and when it still cannot write emits one
# stderr line instead of silence. It is a T-24-04 mitigation, not a style choice.
#
# Encoding is UTF-8 with NO BOM and the terminator is a literal LF, never the
# platform line separator: bash and pwsh read the same file on the same machine,
# so a CRLF record or a BOM on line 1 breaks the other client's parse. That is
# also why this path cannot use the Set-Content / Add-Content family even for the
# very first line -- the append explicitly uses UTF8Encoding($false).
#
# STATUS OF A5, DATED. A5 -- "FileMode::Append + FileShare::ReadWrite interleaves
# twelve concurrent lines without loss" -- was [ASSUMED] by 24-03, MEASURED FALSE
# by 24-07 on 2026-08-27 (macOS 25.4, pwsh 7.6.2, APFS: twelve concurrent appends
# produced 9-12 surviving records, whole records lost rather than torn, with the
# bounded-retry exhaustion branch never firing because each loser believed it
# wrote), and CLOSED by 24-08 by routing this append through
# Write-ScopeLineLocked, which serializes it under .scope.lock.
#
# What is and is not claimed, stated plainly. This side still does NOT claim POSIX
# O_APPEND atomicity -- FileMode::Append remains a seek-to-end-then-write, and the
# bash twin's comment is the only one entitled to the O_APPEND claim. What this
# side claims is MUTUAL EXCLUSION BETWEEN THE PWSH WRITERS ON THIS MACHINE, which
# is exactly what D-17's count-accuracy guarantee needs. Known residual, named
# rather than papered over: a bash append (which never takes .scope.lock, because
# it does not need one) landing between a pwsh writer's Open() and Write() can
# still clobber bytes on a machine running BOTH clients concurrently -- Windows
# with WSL/Git-Bash beside pwsh. Same-client concurrency, the 12-in-54s incident
# shape, is what is made deterministic here.
#
# The fallback stays fail-OPEN in the same direction as before: a lock timeout
# still writes the record (unlocked) and warns, so a wedged lock can never BLOCK
# an issuance -- it can only cost 1000 ms and one stderr line.
#
# T-24-09: this function deliberately does NOT create $CacheDir. The main flow
# already does New-Item + chmod 700, and 24-04's routing block must do the same
# (the WR-01 rationale in Write-GuardSkipRecord). Creating the directory here
# without that chmod is the information-disclosure bug, not a fix -- so a missing
# directory lands in the retry-exhaustion branch below instead, which is the
# correct fail-open outcome.
function Write-ScopeWindowRecord {
    param([string]$AccountId = "")

    if ($AccountId -notmatch '^[0-9]{12}$') { return }

    $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $line = [ordered]@{ ts = $now; accountId = $AccountId } | ConvertTo-Json -Compress
    $bytes = [Text.Encoding]::UTF8.GetBytes($line + "`n")

    # RESEARCH A5 re-verified 2026-08-28 (24-08): with this append serialized under
    # .scope.lock, twelve concurrent invocations against one window file left
    # exactly 12 records on 5 of 5 fleets, every line matching the record regex.
    # The same probe against the unlocked append measured 11, 12, 11, 10, 11.
    $scopeWriteResult = Write-ScopeLineLocked -Path $ScopeWindowRecord -Bytes $bytes

    # Exactly ONE warning per invocation, never two -- hence elseif. Deliberately
    # NOT silent either way: a dropped record under-counts the fan-out (T-24-04).
    if (-not $scopeWriteResult.Written) {
        Write-Log "윈도우 기록을 저장하지 못했습니다: $ScopeWindowRecord — 이번 발급은 집계에 반영되지 않습니다."
    }
    elseif ($scopeWriteResult.LockTimedOut) {
        Write-Log "윈도우 기록 직렬화 실패(scope-lock-timeout): 락을 얻지 못해 잠금 없이 기록했습니다 — 동시 실행 중이면 이 기록이 유실될 수 있습니다."
    }
}

# Get-ScopeWindowIds -Cutoff <long> [-AckCsv "<id,id,...>"]   -> [string]
# Returns "id,id,id": the DISTINCT accountIds recorded at or after -Cutoff that
# are not in -AckCsv, in first-seen (append/chronological) order. Returns "" when
# the file is absent or nothing qualifies. Never throws.
#
# One entry point beyond the outline's frozen list, mirroring the bash twin's
# scope_window_ids. It exists so that the count and the refusal message's account
# list come from a SINGLE parse.
#
# WHERE THAT PROPERTY IS ACTUALLY ENFORCED (WR-03, corrected). It was never a
# property of this helper alone -- it is a property of the CALLER. This function
# and Get-ScopeWindowDistinct each read the file correctly, and the main-flow
# brake block used to call BOTH, so the shipped hot path read
# scope-window.jsonl TWICE. The claim previously written here, that a mismatched
# refusal was "structurally impossible", was true of the helpers and false of the
# caller that used them.
# It is now enforced where it belongs: the brake block derives its count from the
# CSV this function returns, so "승인되지 않은 계정 N개" and the id list beside it
# are computed from ONE string and cannot disagree. The consequence that
# motivated the fix is not cosmetic -- the second parse could return a list
# missing an id the first one had counted, and that list is what the
# copy-pasteable `scope-ack --account-ids` retry line carries, so the user pastes
# the command the tool printed and is refused again.
#
# A fixed regex is a COMPLETE parser here, and that is a property of the data
# rather than a shortcut: both fields are machine-owned -- an epoch this file
# wrote and a 12-digit id it validated first. guard-skips.jsonl is the opposite
# case, its `section` field carries attacker-influenceable profile names and
# genuinely needs ConvertFrom-Json / -SimpleMatch (WR-02).
#
# Fail-open: Test-Path first (under "Stop" a Get-Content on a missing path is a
# TERMINATING error), then the whole parse inside try/catch returning "". A line
# whose ts or id does not match is skipped, never fatal (T-24-07). The ts capture
# is length-clamped before the [long] cast so a 30-digit garbage epoch cannot
# throw and take the whole parse down with it.
function Get-ScopeWindowIds {
    param([long]$Cutoff = 0, [string]$AckCsv = "")

    if (-not (Test-Path -LiteralPath $ScopeWindowRecord -PathType Leaf)) { return "" }

    try {
        $acked = [System.Collections.Generic.HashSet[string]]::new()
        foreach ($a in ($AckCsv -split ',')) {
            if ($a -match '^[0-9]{12}$') { [void]$acked.Add($a) }
        }

        $seen = [System.Collections.Generic.HashSet[string]]::new()
        $order = [System.Collections.Generic.List[string]]::new()

        foreach ($line in @(Get-Content -LiteralPath $ScopeWindowRecord -ErrorAction SilentlyContinue)) {
            if ($null -eq $line) { continue }
            $tsMatch = [regex]::Match($line, '"ts":([0-9]+)')
            if (-not $tsMatch.Success) { continue }
            $tsRaw = $tsMatch.Groups[1].Value
            if ($tsRaw.Length -gt 18) { continue }
            if ([long]$tsRaw -lt $Cutoff) { continue }
            $idMatch = [regex]::Match($line, '"accountId":"([0-9]{12})"')
            if (-not $idMatch.Success) { continue }
            $id = $idMatch.Groups[1].Value
            if ($acked.Contains($id)) { continue }
            if ($seen.Add($id)) { [void]$order.Add($id) }
        }

        return ($order -join ',')
    }
    catch {
        return ""
    }
}

# Get-ScopeWindowDistinct -Cutoff <long> [-AckCsv "<id,id,...>"]   -> [int]
# The count of the ids Get-ScopeWindowIds would list. 0 when the window file is
# missing, empty or unparseable.
#
# Derived from Get-ScopeWindowIds rather than from a second parse, for the reason
# recorded on that function: Stop-WithScopeRefusal prints both the count and the
# id list, so deriving one from the other is what keeps "승인되지 않은 계정 5개"
# from ever sitting next to a four-item list.
#
# NOT CALLED FROM THE MAIN FLOW (WR-03). The brake block derives its count inline
# from Get-ScopeWindowIds so the hot path reads the window file once. This helper
# stays defined deliberately: it is a frozen entry-point name that PARITY-SCOPE-*
# and the unit-level cases call directly, and deleting it would be a larger change
# than the defect. Keep the two derivations identical -- if this one ever changes,
# change the caller's inline copy in the same commit.
#
# The [int] return type is part of the contract: 24-04 compares it against
# $ScopeMaxAccounts, and an accidental [Object[]] from pipeline pollution would
# make that comparison silently meaningless.
function Get-ScopeWindowDistinct {
    param([long]$Cutoff = 0, [string]$AckCsv = "")

    $csv = Get-ScopeWindowIds -Cutoff $Cutoff -AckCsv $AckCsv
    if ([string]::IsNullOrWhiteSpace($csv)) { return 0 }
    return [int](($csv -split ',').Count)
}

# Get-ScopeAckSet -NowEpoch <long>   -> [string]
# The comma-joined UNION of accountIds across every scope-acks.jsonl record whose
# expiresAt > -NowEpoch, deduped, in first-seen order. "" when the file is absent
# or every record has expired. Never throws.
#
# D-06 / A2 / A3, all three parts stated because each one is a decision:
#   * UNION, not "the latest record replaces the previous one". The ack file is
#     append-only with no tombstone, which is exactly what makes
#     resume-after-failure (D-16) work without asking the user to approve the
#     same list a second time.
#   * The honest downside: an agent can widen the set incrementally with repeated
#     small scope-ack calls. Each such call is still a separate transcript
#     artifact and a separate local audit line -- friction and a record, which is
#     the entire value on offer here, and the reason the backstop that does not
#     depend on the agent's cooperation is server-side (Phase 25 DET-01).
#   * Acked accounts are excluded from the count ENTIRELY, not merely exempted
#     from refusal. Otherwise a legitimately approved 12-account batch would sit
#     in the window and block an unrelated 13th account for the next 5 minutes.
#
# Same guards as Get-ScopeWindowIds: Test-Path first, the parse inside try/catch,
# per-line regex, length-clamped numeric capture, and a skipped line is never
# fatal. The array field is captured as raw bracket contents and then stripped to
# [0-9,] before the split, so a future non-compact writer (extra spaces) still
# parses -- the space-tolerance the bash twin gets from substr/gsub.
function Get-ScopeAckSet {
    param([long]$NowEpoch = 0)

    if (-not (Test-Path -LiteralPath $ScopeAckRecord -PathType Leaf)) { return "" }

    try {
        $seen = [System.Collections.Generic.HashSet[string]]::new()
        $order = [System.Collections.Generic.List[string]]::new()

        foreach ($line in @(Get-Content -LiteralPath $ScopeAckRecord -ErrorAction SilentlyContinue)) {
            if ($null -eq $line) { continue }
            $expMatch = [regex]::Match($line, '"expiresAt":([0-9]+)')
            if (-not $expMatch.Success) { continue }
            $expRaw = $expMatch.Groups[1].Value
            if ($expRaw.Length -gt 18) { continue }
            if ([long]$expRaw -le $NowEpoch) { continue }
            $arrMatch = [regex]::Match($line, '"accountIds":\[([^\]]*)\]')
            if (-not $arrMatch.Success) { continue }
            $ids = ($arrMatch.Groups[1].Value -replace '[^0-9,]', '')
            foreach ($id in ($ids -split ',')) {
                if ($id -match '^[0-9]{12}$' -and $seen.Add($id)) { [void]$order.Add($id) }
            }
        }

        return ($order -join ',')
    }
    catch {
        return ""
    }
}

# Invoke-ScopePrune -Cutoff <long>   -> void
# Best effort. Writes nothing to the success stream. Shares the writer lock with
# the window and acknowledgement appends.
#
# D-17, stated in full so this is not read as a deviation. The append still
# happens BEFORE any count is read (append-then-count), which is what makes the
# k-th-appender argument work; what changed in 24-08 is that the append itself is
# now serialized under .scope.lock by Write-ScopeLineLocked, because .NET's
# FileMode::Append is a seek-to-end write and an unlocked one silently lost
# records under contention -- see that function's header. THIS lock, the prune's,
# is still best effort and is still taken AFTER the append has returned: losing it
# never means the verdict was wrong, it only means the file keeps a few stale
# lines, which the cutoff filter ignores anyway. Do not reorder the append and the
# prune; Write-ScopeLineLocked's re-entrancy short-circuit assumes this order.
#
# RELEASE VIA try/finally, a deliberate divergence from the bash twin. bash
# releases with an explicit call and relies on "there is no early return between
# acquire and release". The shipped Invoke-SweepExpiredProfiles uses exactly this
# try/finally shape and Unlock-Sweep's own header says the caller MUST use it.
# Under $ErrorActionPreference = "Stop" a throw is a live termination path, so
# `finally` is strictly stronger than the bash argument, and it is what makes
# Pitfall 2 -- a lock abandoned on disk by a path that never reaches its release
# -- impossible here. Nothing between the acquire and the finally terminates the
# process.
#
# The temp file is "<...>/scope-window.jsonl.<6 hex>": six hex characters and no
# ".json" suffix, so Invoke-DoCleanup's `-Filter "*.json"` cannot eat it
# mid-rewrite (A6, the same property the bash twin's mktemp template relies on).
# The rewrite goes through a raw UTF8Encoding($false) WriteAllText with explicit
# LF joins, so the file keeps the no-BOM, LF-only shape the append established --
# a Set-Content-shaped rewrite that reintroduced CRLF on Windows would break the
# bash client's parse of a shared file after the very first prune.
#
# NO-OP GUARD -- required, and the same deliberate divergence from RESEARCH's
# reference implementation that 24-01 makes. When the kept-line count equals the
# total line count, nothing is written at all. The timeout fallback and the bash
# client append without this lock, so a sibling can lose its write to the
# pre-replace file. When nothing is actually stale the rewrite changes nothing
# and would take that risk for zero benefit; when something IS stale the worst
# case is one lost record for one sibling, which under-counts by one and still
# refuses at the threshold. In steady state -- every record inside the window --
# no replace ever happens and the race does not exist.
#
# HONEST WINDOWS NOTE: AppendAllText permits readers but NOT FileShare::Delete,
# so on Windows a Move-Item -Force over
# a file another process currently has open throws a sharing violation. That
# lands in the catch, the prune is skipped for this invocation and the stale
# lines stay -- which is exactly the documented best-effort semantics, because
# the cutoff filter ignores them anyway and the verdict was already computed from
# a file this process had appended to. Do NOT "fix" this by adding
# FileShare::Delete to the append: A5's share mode is what 24-07's 12-parallel
# case measures, and widening it would let a sibling's in-flight writes land in
# an orphaned inode.
function Invoke-ScopePrune {
    param([long]$Cutoff = 0)

    if (-not (Test-Path -LiteralPath $ScopeWindowRecord -PathType Leaf)) { return }
    # Fresh windows need no rewrite. Check outside the lock so twelve cold
    # credential processes do not serialize twelve no-op Get-Content/regex
    # initializations ahead of writers. A rewrite re-reads under the lock below;
    # this snapshot is never used as replacement content.
    try {
        $needsPrune = $false
        foreach ($line in [IO.File]::ReadAllLines($ScopeWindowRecord)) {
            $match = [regex]::Match($line, '^\{"ts":([0-9]+),"accountId":"([0-9]{12})"\}$')
            if (-not $match.Success -or $match.Groups[1].Value.Length -gt 18 -or
                [long]$match.Groups[1].Value -lt $Cutoff) {
                $needsPrune = $true
                break
            }
        }
        if (-not $needsPrune) { return }
    }
    catch { return }
    # Losing the lock is a no-op, never an error: another process is already
    # pruning the same file.
    if (-not (Lock-Scope $ScopeLock)) { return }

    $tmp = ""
    try {
        $lines = @(Get-Content -LiteralPath $ScopeWindowRecord -ErrorAction SilentlyContinue)
        $kept = [System.Collections.Generic.List[string]]::new()
        foreach ($line in $lines) {
            if ($null -eq $line) { continue }
            # Same regex discipline as Get-ScopeWindowIds. A line that does not
            # parse is DROPPED, which is the correct outcome for a prune.
            $m = [regex]::Match($line, '^\{"ts":([0-9]+),"accountId":"([0-9]{12})"\}$')
            if (-not $m.Success) { continue }
            $tsRaw = $m.Groups[1].Value
            if ($tsRaw.Length -gt 18) { continue }
            if ([long]$tsRaw -lt $Cutoff) { continue }
            $kept.Add($line)
        }

        # The no-op guard. See the header for why this is not an optimisation.
        if ($kept.Count -eq $lines.Count) { return }

        $tmp = "$ScopeWindowRecord." + [Guid]::NewGuid().ToString('N').Substring(0, 6)
        $payload = ""
        if ($kept.Count -gt 0) { $payload = ($kept -join "`n") + "`n" }
        [IO.File]::WriteAllText($tmp, $payload, [Text.UTF8Encoding]::new($false))
        Move-Item -LiteralPath $tmp -Destination $ScopeWindowRecord -Force
        $tmp = ""
    }
    catch {
        # Best effort. Leave no temp residue accumulating under $CacheDir -- the
        # "*.json" filter cannot reach it, so nothing else would ever clean it up.
        if (-not [string]::IsNullOrEmpty($tmp)) {
            Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        }
    }
    finally {
        Unlock-Scope
    }
}

# Stop-WithScopeRefusal -DistinctCount <int> -IdsCsv "<id,id,...>"
# stderr only, then a non-zero process termination. Never returns. Writes zero
# bytes to the success stream on every path (T-24-05) -- on the
# credential_process path stdout is the 5-key JSON contract and nothing else,
# which is also why nothing in this section uses the host-write cmdlet: in pwsh 7
# it writes to the Information stream, which a redirected child process renders
# on STDOUT and would make the stdout-purity assertion vacuous.
#
# THIS TEXT IS THE ERROR THE AGENT SEES. botocore's ProcessProvider pipes both
# streams; on a non-zero return code it raises
# CredentialRetrievalError(error_msg=<the entire stderr buffer>) and the AWS CLI
# prints that verbatim, wrapped as "Error when retrieving credentials from
# custom-process: …". On returncode == 0 stderr is discarded ENTIRELY, which is
# why "warn and proceed" is not an option here and why a refusal must always mean
# a non-zero return code (Pitfall 3).
#
# It is also emitted LAST. The whole buffer is surfaced as one blob, so any
# [sweep]/[migrate]/[guard] line already written this invocation precedes it;
# putting the refusal at the end keeps the actionable instruction from being
# buried in the middle (Pitfall 4). The machine token goes FIRST so a caller or a
# test can grep it without parsing the Korean prose (S1), and it goes through
# [Console]::Error rather than Write-Log because Write-Log prefixes
# "[get-customer-credentials] " and that would break the token contract -- the
# bash twin uses a bare printf to stderr for the same reason.
#
# The prose lines mirror the bash twin's scope_refuse BYTE FOR BYTE. Do not
# paraphrase, do not re-translate, do not "improve" the Korean: 24-04's
# PARITY-SCOPE-TOKENS diffs the two rendered stderr buffers. There are now TWO
# intentional byte differences, and both are parity of BEHAVIOUR rather than
# drift -- each line is copy-pasteable in its OWN shell, which is the property
# SKILL.md and troubleshooting.md actually promise:
#   1. The client filename on the final line, which the frozen-vocabulary table
#      pins per client.
#   2. WR-02: this client QUOTES the id CSV on that final line and the bash twin
#      does not. bash needs no quotes -- it does not word-split on ',' -- while
#      PowerShell parses an unquoted `a,b` as an array expression, so the
#      unquoted pwsh line pastes back as a nested [object[]] rather than as one
#      argument. Quoting is what makes the pasted command mean what it reads as.
#      The bash refusal line must NOT gain quotes to "match": its own
#      $-anchored regression regex would break and it would be fixing nothing.
# That final line is the copy-pasteable retry command and must stay last.
#
# The message carries account ids and nothing else. They are already present in
# ~/.aws/config, and a credential_process tool must never put a secret on stderr.
function Stop-WithScopeRefusal {
    param([int]$DistinctCount = 0, [string]$IdsCsv = "")

    [Console]::Error.WriteLine("[scope] reason=fan-out-threshold")
    Write-Log "중단: 최근 ${ScopeWindowSeconds}초 안에 승인되지 않은 고객사 계정 ${DistinctCount}개의 신규 발급이 감지되었습니다 (허용 ${ScopeMaxAccounts}개)."
    Write-Log "윈도우 내 계정: ${IdsCsv}"
    Write-Log "대상 목록을 사용자에게 확인받은 뒤 아래를 실행하고 같은 명령을 다시 실행하세요:"
    Write-Log "  get-customer-credentials.ps1 scope-ack --account-ids `"${IdsCsv}`""
    exit 1
}

# --- scope-ack subcommand (SCP-05) ---
#
# BOUNDARY CHANGE -- read this before extracting the section above (24-05 /
# 24-07). The brake-helpers section 24-03 added used to be delimited on its lower
# side by the migrate-routing marker. It is now delimited by THIS marker, because
# this section sits between the two. Any later extraction of the brake helpers
# must use the scope-ack section marker on the line above as its END anchor, or
# it will pull Invoke-DoScopeAck and Stop-ScopeAckWithError in with it and every
# region-scoped static gate will be measuring the wrong lines. No marker literal
# is quoted anywhere in this paragraph, deliberately: a quotation would double
# the substring count of an anchor that another plan greps for.
#
# The upside of placing this section HERE rather than above the helpers is that
# it is exactly where the bash twin puts its own: from now on BOTH clients bound
# their brake-helpers section with the same two anchors, so 24-07 writes ONE
# extraction shape instead of two.
#
# THERE IS NO EXTRACTION-RANGE HAZARD ON THIS SIDE -- stated outright so nobody
# invents a constraint that does not exist here. The bash twin carries a
# PLACEMENT paragraph because test/credentials-guard.test.sh extracts a literal
# line range out of the .sh and `source`s it, which would EXECUTE any top-level
# statement inside that range. The PowerShell guard suite
# (test/credentials-guard.test.ps1) invokes this script as a SUBPROCESS instead
# and never dot-sources a range of it, so nothing in this file is placement-
# constrained by a harness.
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
# stopping it. What it buys is 마찰, one transcript artifact the agent has to
# quote back, and one durable local line in scope-acks.jsonl. The backstop that
# does not depend on the agent's cooperation is server-side (Phase 25 DET-01).

# Stop-ScopeAckWithError: reason line, then one "[scope-ack] <msg>" line per
# message, then exit 1. NEVER writes to stdout (abort contract: empty stdout).
# A direct clone of Stop-RegisterWithError rather than of the generic
# Stop-WithError, because the machine-readable token has to come FIRST -- so a
# caller or a test can grep it without parsing the Korean prose that follows (S1)
# -- and because Write-Log's "[get-customer-credentials] " prefix would break the
# token contract.
# Tokens: invalid-account-id | invalid-arguments | write-failed
#
# `write-failed` is deliberately Write-RegisterReason's EXISTING token rather
# than a new spelling for the same idea. It exists on this path at all because
# this handler's ack append is fail-CLOSED (see [8] below), unlike every other
# write in the brake, so it needs an abort token for a failed write -- and
# register already documents exactly that one.
#
# CALL-SITE STYLE IS LOAD-BEARING. The cmdlet name and its -Reason '<token>'
# argument stay on ONE source line at every call site (register's shipped style
# already does this). PARITY-SCOPE-TOKENS extracts three of the four scope tokens
# from those call sites -- they are ARGUMENTS, not inline literals, exactly like
# register's -- so a line-wrapped call is invisible to that gate.
function Stop-ScopeAckWithError {
    param([string]$Reason, [string[]]$Messages = @())

    [Console]::Error.WriteLine("[scope-ack] reason=$Reason")
    foreach ($msg in $Messages) {
        [Console]::Error.WriteLine("[scope-ack] $msg")
    }
    exit 1
}

# Invoke-DoScopeAck -Arguments <string[]>
# Records one explicit, time-limited approval covering >= 2 distinct customer
# accounts, so the fan-out brake below lets those accounts through for
# $ScopeAckTtlSeconds. This is the ONLY override channel: the brake reads its
# verdict from scope-acks.jsonl and from nothing else -- there is no environment
# variable, no credential-broker.conf key and no flag on the credential path that
# can widen it (D-05, T-24-03).
#
# The step order below is the contract, not an implementation detail; it mirrors
# the shipped bash do_scope_ack step for step. The parameter name -Arguments and
# the $null guard mirror Invoke-DoRegister exactly.
function Invoke-DoScopeAck {
    param([string[]]$Arguments = @())

    if ($null -eq $Arguments) { $Arguments = @() }

    $idsCsv = ""

    # [1] argv. scope-ack consumes its own arguments; these flags must never
    # reach the main parser below, whose `default` branch dies with the
    # misleading "Unknown option" (Pitfall 2). Same missing-value guard shape as
    # Invoke-DoRegister.
    # NOTE: PowerShell's `switch` is case-INSENSITIVE, so "--Account-Ids" is also
    # accepted here while the bash twin's `case` is case-sensitive. This mirrors
    # the pre-existing asymmetry register already ships and is deliberately NOT
    # part of the parity contract.
    $argIndex = 0
    while ($argIndex -lt $Arguments.Count) {
        $currentArg = $Arguments[$argIndex]
        switch ($currentArg) {
            '--account-ids' {
                if ($argIndex + 1 -ge $Arguments.Count) {
                    Stop-ScopeAckWithError -Reason 'invalid-arguments' -Messages @(
                        "중단: 옵션 '$currentArg' 에 값이 필요합니다."
                    )
                }
                $argIndex++
                $idsCsv = $Arguments[$argIndex]
            }
            '--help' { Show-Usage; exit 0 }
            '-h'     { Show-Usage; exit 0 }
            default {
                Stop-ScopeAckWithError -Reason 'invalid-arguments' -Messages @(
                    "중단: scope-ack 가 모르는 인자입니다: $(ConvertTo-DisplaySafe -Text $currentArg)",
                    "사용법: get-customer-credentials.ps1 scope-ack --account-ids <12자리>,<12자리>[,...]"
                )
            }
        }
        $argIndex++
    }

    # [2] Split the CSV so the ELEMENT COUNT matches bash's byte for byte. The
    # guard is [string]::IsNullOrEmpty and deliberately NOT IsNullOrWhiteSpace.
    # bash pipes `printf '%s' "$ids_csv" | tr ',' '\n'`, so:
    #   ""      -> ZERO lines          -> the >= 2 check -> invalid-arguments
    #   "a,,b"  -> THREE lines, one empty -> invalid-account-id
    #   " "     -> ONE line            -> invalid-account-id
    # A naive `"" -split ','` in PowerShell returns a ONE-element array holding
    # "", which would report invalid-account-id where bash reports
    # invalid-arguments. IsNullOrEmpty reproduces bash; IsNullOrWhiteSpace would
    # additionally swallow the single-space case and diverge again.
    $idsElems = @()
    if (-not [string]::IsNullOrEmpty($idsCsv)) {
        $idsElems = @($idsCsv -split ',')
    }

    $scopeAckSeen = [System.Collections.Generic.HashSet[string]]::new()
    $scopeAckList = [System.Collections.Generic.List[string]]::new()
    foreach ($elem in $idsElems) {
        # [3] Validate EVERY element BEFORE dedupe, BEFORE the >= 2 check and
        # before it reaches any record, message or command word (T-24-08). \z
        # (absolute end) rather than $, which in .NET ALSO matches immediately
        # before a trailing newline -- a $-anchored check would admit
        # "111111111111`n{injected}" into the record. -cnotmatch rather than
        # -notmatch for the same reason the A6 gate in Invoke-DoRegister uses it.
        # This ordering is an acceptance criterion, not a style preference: it is
        # what makes `--account-ids 1,2` report invalid-account-id instead of
        # invalid-arguments. The offending token goes through ConvertTo-DisplaySafe
        # before it reaches a terminal or a CI log. No Invoke-Expression, no `&`
        # on interpolated input anywhere on this path.
        if ($elem -cnotmatch '^[0-9]{12}\z') {
            Stop-ScopeAckWithError -Reason 'invalid-account-id' -Messages @(
                "중단: 유효하지 않은 계정 ID (12자리 숫자만 허용): '$(ConvertTo-DisplaySafe -Text $elem)'",
                "승인 기록은 남지 않았습니다."
            )
        }

        # [4] Dedupe, first-seen order: a HashSet for membership plus a List for
        # order. Every .Add() is [void]-prefixed and that is not cosmetic --
        # HashSet.Add returns [bool], and an un-[void]'d call puts that bool on
        # the SUCCESS stream, which on this file's contract means stray bytes on
        # stdout. It is the pwsh analog of bash's "never `local x=$(...)`" rule
        # and no linter in this repo catches it. Membership is tested with
        # .Contains so the Add itself is never used as a condition.
        if (-not $scopeAckSeen.Contains($elem)) {
            [void]$scopeAckSeen.Add($elem)
            [void]$scopeAckList.Add($elem)
        }
    }

    # [5] Require >= 2 DISTINCT ids, with no upper cap. This single check absorbs
    # three inputs: an empty value, a single id, and a list that collapses to one
    # after dedupe. Two alternatives were considered and rejected (RESEARCH
    # A7/A8): a one-account ack is meaningless because the brake never fires for
    # a single account, and an upper cap would only force the agent to split one
    # approval into two -- a second failure mode bought for no safety gain.
    $n = $scopeAckList.Count
    if ($n -lt 2) {
        Stop-ScopeAckWithError -Reason 'invalid-arguments' -Messages @(
            "중단: --account-ids 에는 서로 다른 계정 ID 가 2개 이상 필요합니다 (현재 ${n}개).",
            "1개 계정 작업에는 브레이크가 걸리지 않으므로 승인이 필요하지 않습니다."
        )
    }

    # [6] Epoch. Unlike every READER in the brake, this path must NOT fail open:
    # an ack written with a bogus expiry is an approval that silently does not
    # work -- the command reports success and the agent still meets a refusal at
    # account 6 with no way to connect the two. The guard mirrors bash's
    # `date -u +%s` failure branch. It is near-unreachable on .NET, and keeping
    # it anyway is what makes the abort taxonomy and the reason-token vocabulary
    # identical across the two clients, which is exactly what
    # PARITY-SCOPE-TOKENS asserts.
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    if ($now -le 0) {
        Stop-ScopeAckWithError -Reason 'write-failed' -Messages @(
            "중단: 시스템 시각을 읽지 못해 승인 기록의 만료 시각을 계산할 수 없습니다."
        )
    }
    $expires = $now + $ScopeAckTtlSeconds

    # [7] Human-readable expiry. InvariantCulture is MANDATORY, not decoration:
    # ToString(format) alone formats with the CURRENT culture, and on a
    # non-Gregorian calendar or a culture with non-ASCII digits the rendered
    # timestamp stops matching the bash twin's `date -u +%Y-%m-%dT%H:%M:%SZ` byte
    # for byte. Note for the 24-02 hand-off: this side needs no GNU-vs-BSD `date`
    # ladder at all because FromUnixTimeSeconds is native -- that is a code
    # divergence with identical output, not drift.
    $expiresIso = [DateTimeOffset]::FromUnixTimeSeconds($expires).UtcDateTime.ToString(
        "yyyy-MM-ddTHH:mm:ssZ", [System.Globalization.CultureInfo]::InvariantCulture)

    # [8] Append exactly ONE record, fail-CLOSED. [ordered] fixes key order across
    # platforms, -Compress emits no space after a colon (the property
    # Test-MigrationCompleted already relies on) and together they make this line
    # byte-identical to the bash twin's printf. The explicit [string[]] cast keeps
    # accountIds a JSON ARRAY -- unreachable here because $n >= 2, but the record
    # shape is asserted and the cast costs nothing. JSON is never
    # string-concatenated here (the Write-GuardSkipRecord rule). The array is a
    # flat list of quoted 12-digit strings and nothing else, because 24-03's
    # Get-ScopeAckSet captures the bracket contents and keeps only length-12
    # digit elements.
    #
    # The append goes through Write-ScopeLineLocked, the same lock-serialized
    # helper Write-ScopeWindowRecord uses, with a raw GetBytes + explicit LF
    # terminator so the file stays byte-compatible with the bash client on the
    # same machine (no BOM, no CRLF). T-24-13 / 24-08: this record had the
    # identical unlocked-append defect, and losing it is worse than losing a
    # window record -- two simultaneous scope-ack calls could drop an approval
    # this command had already reported as recorded.
    #
    # THE ONE DIVERGENCE FROM Write-ScopeWindowRecord IS THE EXHAUSTION BRANCH.
    # There, a lost record logs a warning and returns; here it aborts. Losing a
    # WINDOW record under-counts the brake, which is the safe direction. Losing
    # an ACK record makes this command report an approval that does not exist,
    # and the agent then meets an unexplained refusal at account 6 with a
    # transcript saying the range was approved. That is the unsafe direction, so
    # this is the one write in the brake that is fail-closed -- matching the bash
    # twin, which is `|| true` on the window append and fail-closed here.
    $line = [ordered]@{ ts = $now; expiresAt = $expires; accountIds = [string[]]$scopeAckList; count = $n } | ConvertTo-Json -Compress
    $bytes = [Text.Encoding]::UTF8.GetBytes($line + "`n")

    $ackWriteResult = Write-ScopeLineLocked -Path $ScopeAckRecord -Bytes $bytes

    # ORDERING IS MECHANICALLY GATED. The fail-CLOSED abort goes FIRST and the
    # lock-timeout warning strictly after it: SCOPE-9 asserts the FIRST stderr
    # line is byte-equal to the write-failed reason line Stop-ScopeAckWithError
    # emits below, so a warning emitted ahead of the abort would fail that
    # assertion on a contended run -- a real test failure caused purely by
    # ordering. (The reason line itself is not quoted here: PARITY-SCOPE-TOKENS
    # greps both clients for that shape and diffs the sets.)
    if (-not $ackWriteResult.Written) {
        Stop-ScopeAckWithError -Reason 'write-failed' -Messages @(
            "중단: 승인 기록을 저장하지 못했습니다: ${ScopeAckRecord}",
            "승인은 적용되지 않았습니다. 디스크 여유 공간과 권한을 확인한 뒤 다시 실행하세요."
        )
    }

    if ($ackWriteResult.LockTimedOut) {
        Write-Log "승인 기록 직렬화 실패(scope-lock-timeout): 락을 얻지 못해 잠금 없이 기록했습니다 — 동시 실행 중이면 이 기록이 유실될 수 있습니다."
    }

    # [9] stdout -- exactly one line, no '{' and no '}' (see the STDOUT CONTRACT
    # paragraph at the top of this section). [Console]::Out.WriteLine is the
    # shape the cache emit uses; Write-Host is never correct here because pwsh 7
    # routes it to the Information stream, which a redirected child renders on
    # STDOUT -- invisible in an interactive test and fatal to the contract. The
    # literal prefix "scope-ack: " is FROZEN: PARITY-SCOPE-ROUTE pins the routing
    # branch, the handler and this stdout shape TOGETHER, because proving that
    # the string "scope-ack" appears somewhere in a file proves nothing at all.
    [Console]::Out.WriteLine("scope-ack: ${n} accounts approved until ${expiresIso}")

    # [10] stderr -- exactly ONE [scope-ack] line (D-07: 로컬 jsonl 기록과 stderr
    # 1줄이 전부). Bare [Console]::Error, not Write-Log: Write-Log prefixes
    # "[get-customer-credentials] " and the prefix has to match the reason
    # token's, which is the same reason the doctor and migrate reason lines
    # bypass it. One line carries the count, the expiry and the id list; do not
    # add a second summary line.
    $uniqCsv = $scopeAckList -join ','
    [Console]::Error.WriteLine("[scope-ack] ${n}개 계정 범위 승인 기록 — 만료 ${expiresIso} — 계정: ${uniqCsv}")

    return
}

# --- migrate subcommand routing (must be before parameter parsing, D-01) ---
if ($args.Count -gt 0 -and $args[0] -eq 'migrate') {
    # T-22-18: no $args[1..] range slice here -- migrate takes no arguments, so
    # the reversed-array hazard that bites at $args.Count -eq 1 cannot arise.
    # Pitfall 10: deliberately a single `aws` presence gate and NOT the broker
    # prerequisite check -- migrate makes no network call and parses no JSON it
    # did not write itself. Same rationale as register's and doctor's gates.
    if (-not (Get-Command aws -ErrorAction SilentlyContinue)) {
        [Console]::Error.WriteLine("[migrate] reason=missing-dependency")
        [Console]::Error.WriteLine("[migrate] 중단: aws 명령이 설치되어 있지 않습니다. 확인 없이 프로필을 바꾸지 않습니다.")
        exit 1
    }
    # The completion marker and the shared lock both live here, so the directory
    # has to exist before either is touched.
    if (-not (Test-Path -LiteralPath $CacheDir)) {
        New-Item -ItemType Directory -Force -Path $CacheDir | Out-Null
        if ($IsLinux -or $IsMacOS) {
            try { & chmod 700 $CacheDir 2>$null } catch { }
        }
    }
    exit (Invoke-MigrationOnce)
}

# --- doctor subcommand routing (must be before parameter parsing, D-01) ---
if ($args.Count -gt 0 -and $args[0] -eq 'doctor') {
    # Pitfall 10: deliberately a single `aws` presence gate and NOT the broker
    # prerequisite check -- doctor makes no network call and parses no JSON. Same
    # rationale as register's gate.
    if (-not (Get-Command aws -ErrorAction SilentlyContinue)) {
        [Console]::Error.WriteLine("[doctor] reason=missing-dependency")
        Write-DoctorLog -Message "중단: 'aws' 명령이 설치되어 있지 않습니다. 키 제거는 사후검증 없이 수행하지 않습니다."
        exit 1
    }
    # WR-01: the `cleanup` and `migrate` routing blocks both do this; `doctor` did
    # not. Invoke-DoDoctor reaches Write-GuardSkipRecord, whose Add-Content
    # target lives under $CacheDir -- and the try/catch there swallowed the
    # missing-directory error entirely, so the D-04/D-06 audit record was
    # silently dropped on the machine that most needs it.
    if (-not (Test-Path -LiteralPath $CacheDir)) {
        New-Item -ItemType Directory -Force -Path $CacheDir | Out-Null
        if ($IsLinux -or $IsMacOS) {
            try { & chmod 700 $CacheDir 2>$null } catch { }
        }
    }
    exit (Invoke-DoDoctor)
}

# --- Subcommand routing (must be before parameter parsing, D-01/D-02) ---
if ($args.Count -gt 0 -and $args[0] -eq 'cleanup') {
    $cleanupAll = $false
    if ($args.Count -gt 1 -and $args[1] -eq '--all') {
        $cleanupAll = $true
    }
    # Ensure CacheDir exists
    if (-not (Test-Path $CacheDir)) {
        New-Item -ItemType Directory -Force -Path $CacheDir | Out-Null
        if ($IsLinux -or $IsMacOS) {
            try { & chmod 700 $CacheDir 2>$null } catch { }
        }
    }
    Invoke-DoCleanup -AllMode $cleanupAll
    exit 0
}

# --- register subcommand routing (must be before parameter parsing, D-01) ---
if ($args.Count -gt 0 -and $args[0] -eq 'register') {
    # T-22-18: $args[1..($args.Count - 1)] would produce a REVERSED array when
    # $args.Count is 1 (the range operator counts DOWN from 1 to 0), handing
    # register a phantom argument. The empty case is handled explicitly instead.
    $registerArgs = @()
    if ($args.Count -gt 1) {
        $registerArgs = @($args[1..($args.Count - 1)])
    }

    # Pitfall 10: deliberately a single `aws` presence gate and NOT the broker
    # prerequisite check -- register makes no network call and parses no JSON, so
    # it must not inherit a curl/jq hard dependency. Reported through the register
    # stderr contract (reason token first), not through Stop-WithError.
    if (-not (Get-Command aws -ErrorAction SilentlyContinue)) {
        Stop-RegisterWithError -Reason 'missing-dependency' -Messages @(
            "중단: 'aws' 명령이 설치되어 있지 않습니다."
        )
    }

    Invoke-DoRegister -Arguments $registerArgs
    exit 0
}

# --- scope-ack subcommand routing (must be before parameter parsing, D-01) ---
if ($args.Count -gt 0 -and $args[0] -eq 'scope-ack') {
    # T-22-18: $args[1..($args.Count - 1)] would produce a REVERSED array when
    # $args.Count is 1 (the range operator counts DOWN from 1 to 0), handing the
    # handler a phantom argument. The empty case is handled explicitly instead.
    # This matters more here than it does for register: `scope-ack` with no
    # arguments at all is a realistic agent mistake, and it has to report
    # invalid-arguments rather than an abort about an argument nobody passed.
    #
    # WR-02: each element is FLATTENED to a string before the hand-off. When this
    # .ps1 is invoked DIRECTLY -- `.\get-customer-credentials.ps1 ...` or
    # `& './get-customer-credentials.ps1' ...` from a pwsh session -- PowerShell
    # parses an unquoted `a,b` as an ARRAY EXPRESSION, so $args receives a nested
    # [object[]]. That nested array then binds to Invoke-DoScopeAck's
    # [string[]]$Arguments, where PowerShell space-joins it to "a b", and the
    # handler reports invalid-account-id naming the token '500000000001
    # 500000000002' -- a token the user never typed and cannot find in their own
    # command line. The NATIVE form that SKILL.md:163 documents
    # (`pwsh -NoProfile -File ... scope-ack --account-ids a,b`) passes a plain
    # string, so `$_ -is [array]` is $false there and this is a no-op on the
    # documented path.
    #
    # Rejoining with ',' is lossless rather than a guess: Invoke-DoScopeAck's own
    # [2] handling splits the value on ',', so a round trip through -join ','
    # reproduces exactly the element list PowerShell destructured.
    $scopeAckArgs = @()
    if ($args.Count -gt 1) {
        $scopeAckArgs = @($args[1..($args.Count - 1)] | ForEach-Object {
            if ($_ -is [array]) { ($_ -join ',') } else { [string]$_ }
        })
    }

    # Pitfall 10, taken one step past migrate/doctor/register. This block is
    # deliberately NOT the broker prerequisite check AND it deliberately has no
    # `Get-Command aws` gate either. scope-ack makes no network call, parses no
    # JSON it did not write itself, and never touches ~/.aws/config. It is the
    # FIRST subcommand in this file with ZERO external-binary dependency, and
    # there is no precedent for that here, so it is stated outright: adding a
    # binary gate would break scope-ack on exactly the machine where the agent
    # most needs to record an approval.
    #
    # WR-01 / T-24-09: Invoke-DoScopeAck APPENDS to $ScopeAckRecord under
    # $CacheDir, so the directory has to exist AND be mode 700 before the handler
    # runs -- otherwise the approval record is world-readable on a shared machine,
    # and on a first-ever scope-ack the append fails outright and the approval is
    # silently lost on the machine that most needs it. 24-03 deliberately did NOT
    # create $CacheDir from inside its helpers so that this pair could never be
    # separated from the directory creation. The guarded Test-Path + New-Item +
    # platform-guarded chmod is a code divergence from the bash twin's
    # unconditional `mkdir -p` + `chmod 700` with identical behaviour -- it is the
    # shape the migrate, doctor and cleanup routing blocks already ship. The
    # `| Out-Null` is not cosmetic: without it the DirectoryInfo lands on stdout
    # and breaks this subcommand's one-line contract.
    if (-not (Test-Path -LiteralPath $CacheDir)) {
        New-Item -ItemType Directory -Force -Path $CacheDir | Out-Null
        if ($IsLinux -or $IsMacOS) {
            try { & chmod 700 $CacheDir 2>$null } catch { }
        }
    }

    Invoke-DoScopeAck -Arguments $scopeAckArgs
    exit 0
}

# --- Manual parameter parsing (D-02, replaces param() block) ---
# Handles named parameters case-insensitively (PowerShell switch is case-insensitive).
# Phase 18: the old local-assume parameters are GONE (no client-side sts call).
# -Region/-SessionName are accepted-but-ignored no-ops for backward-compat with
# un-migrated profiles (mirrors get-customer-credentials.sh).
$AccountId = ""
$Agent = ""
$ShowHelp = $false

$i = 0
while ($i -lt $args.Count) {
    switch ($args[$i]) {
        '-AccountId'   { $i++; $AccountId = $args[$i] }
        '-Agent'       { $i++; $Agent = $args[$i] }
        '-Region'      { $i++ }   # backward-compat no-op (no local assume; broker owns region)
        '-SessionName' { $i++ }   # backward-compat no-op (identity stamped server-side)
        '-Help'        { $ShowHelp = $true }
        default        { Stop-WithError "Unknown option: $($args[$i])" }
    }
    $i++
}

if ($ShowHelp) {
    Show-Usage
    exit 0
}

# --- Agent detection from script install path (FINAL fallback only) ---
# The install path ($PSCommandPath) is FIXED per customer profile -- it reflects
# whichever agent CREATED the profile, not the agent running now. When several
# agents share a profile, this mapping mis-attributes every caller to the
# creator, so it is used ONLY after the runtime-env signals below fail.
function Resolve-AgentFromPath {
    param([string]$ScriptPath)
    if ([string]::IsNullOrEmpty($ScriptPath)) { return 'unknown' }
    # Normalize path separators for cross-platform matching
    $normalizedPath = $ScriptPath -replace '/', '\'
    switch -Wildcard ($normalizedPath) {
        '*\.claude\*'           { return 'claude-code' }
        '*\.config\opencode\*'  { return 'opencode' }
        '*\.kiro\*'             { return 'kiro' }
        '*\.cursor\*'           { return 'cursor' }
        '*\.codeium\windsurf\*' { return 'windsurf' }
        '*\.augment\*'          { return 'augment' }
        '*\.agents\*'           { return 'codex' }
        '*\.gemini\*'           { return 'gemini' }
        '*\.hermes\*'           { return 'hermes' }
        default                 { return 'unknown' }
    }
}

# --- KNOWN CSG agent ids (single source; gates the env-signal layers below) ----
# The 9 agents this skill installs into. Mirrors get-customer-credentials.sh:KNOWN_AGENTS.
# The TERM_PROGRAM / __CFBundleIdentifier layers accept a runtime value ONLY if it is
# a member of this set, so a generic terminal (TERM_PROGRAM=vscode/iterm/apple_terminal,
# or a non-agent bundle id) never mis-maps to an audit-subject label.
$KnownAgents = @('claude-code', 'opencode', 'kiro', 'cursor', 'windsurf',
                 'augment', 'codex', 'gemini', 'hermes')

# Test-IsKnownAgent: $true iff $Candidate is one of the 9 CSG agent ids.
function Test-IsKnownAgent {
    param([string]$Candidate)
    return ($KnownAgents -contains $Candidate)
}

# --- Layered RUNTIME agent detection (first hit wins) -------------------------
# PowerShell twin of get-customer-credentials.sh:detect_agent. Resolves the AI
# agent ACTUALLY invoking this credential_process so the audit reflects the real
# caller, not the install that created the shared profile. Priority:
#   1. explicit -Agent <name>   (handled before this fn; deliberate override)
#   2. $env:MSP_AGENT       (explicit session override; validated downstream)
#   3. $env:AI_AGENT             (leading token before the FIRST '_', lowercased)
#   4. $env:CLAUDECODE           (Claude Code sets this even when AI_AGENT is absent)
#   5. $env:TERM_PROGRAM         (VSCode-fork agents w/ NO custom var, e.g. Kiro sets
#                                 TERM_PROGRAM=kiro; KNOWN-AGENT-gated)
#   6. $env:__CFBundleIdentifier (macOS backup: dev.<name>.desktop/.app; KNOWN-gated)
#   7. Resolve-AgentFromPath     (install-path mapping; frozen per profile)
# MSP_AGENT is passed through verbatim so the SAME ^[a-z0-9-]{1,32}$ check
# below rejects a malformed value; AI_AGENT/TERM_PROGRAM/__CFBundleIdentifier are
# auto-detected signals used ONLY if they pass their check (charset for AI_AGENT,
# KNOWN_AGENTS membership for the two new layers), else they fall through.
function Resolve-Agent {
    param([string]$ScriptPath)

    # 2. Explicit session override (validated downstream; may die if malformed).
    if (-not [string]::IsNullOrEmpty($env:MSP_AGENT)) {
        return $env:MSP_AGENT
    }

    # 3. AI_AGENT: leading token before the FIRST '_', lowercased.
    #    e.g. "claude-code_2-1-204_agent" -> "claude-code"; "kiro_9-9_agent" -> "kiro";
    #    a value with no '_' is used whole. Accepted only if it matches the charset.
    if (-not [string]::IsNullOrEmpty($env:AI_AGENT)) {
        $candidate = ($env:AI_AGENT -split '_')[0].ToLowerInvariant()
        if ($candidate -match '^[a-z0-9-]{1,32}$') {
            return $candidate
        }
    }

    # 4. Claude Code exports CLAUDECODE in its shell env.
    if (-not [string]::IsNullOrEmpty($env:CLAUDECODE)) {
        return 'claude-code'
    }

    # 5. TERM_PROGRAM: VSCode-fork agents that inject NO custom var still set this
    #    (e.g. Kiro -> TERM_PROGRAM=kiro). Lowercase it and accept it ONLY if it is
    #    a KNOWN CSG agent id, so generic terminals (vscode/iterm/apple_terminal/"")
    #    fall through instead of being stamped as the audit subject.
    if (-not [string]::IsNullOrEmpty($env:TERM_PROGRAM)) {
        $candidate = $env:TERM_PROGRAM.ToLowerInvariant()
        if (Test-IsKnownAgent $candidate) {
            return $candidate
        }
    }

    # 6. __CFBundleIdentifier (macOS backup): dev.<name>.desktop or dev.<name>.app
    #    (e.g. Kiro -> dev.kiro.desktop). Extract <name>, lowercase, and accept it
    #    ONLY if <name> is a KNOWN CSG agent id -- catches macOS cases where
    #    TERM_PROGRAM differs from the agent id.
    if (-not [string]::IsNullOrEmpty($env:__CFBundleIdentifier)) {
        if ($env:__CFBundleIdentifier.ToLowerInvariant() -match '^dev\.([a-z0-9-]+)\.(desktop|app)$') {
            $candidate = $Matches[1]
            if (Test-IsKnownAgent $candidate) {
                return $candidate
            }
        }
    }

    # 7. Final fallback: the frozen install-path mapping.
    return (Resolve-AgentFromPath -ScriptPath $ScriptPath)
}

if ([string]::IsNullOrEmpty($Agent)) {
    $Agent = Resolve-Agent -ScriptPath $PSCommandPath
}

# --- Input validation (V5: same shape the broker enforces server-side) ---
if ($AccountId -notmatch '^[0-9]{12}$') {
    Stop-WithError "유효하지 않은 -AccountId (12자리 숫자만 허용)"
}
if ($Agent -notmatch '^[a-z0-9-]{1,32}$') {
    Stop-WithError "유효하지 않은 -Agent (^[a-z0-9-]{1,32}$ 위반): $Agent"
}

# --- Ensure CacheDir exists (needed by auto-sweep lock file) ---
if (-not (Test-Path $CacheDir)) {
    New-Item -ItemType Directory -Force -Path $CacheDir | Out-Null
    if ($IsLinux -or $IsMacOS) {
        try { & chmod 700 $CacheDir 2>$null } catch { }
    }
}

# --- Auto-sweep expired profiles (D-01) ---
# PROF-06: exclude this invocation's own cache path so the profile that
# triggered this credential_process call is not self-removed before it has
# had a chance to write its own cache.
$activeCachePath = Join-Path $CacheDir "$AccountId.json"
Invoke-SweepExpiredProfiles -ExcludeCachePath $activeCachePath

# --- HOOK-B: auto-migrate to the csg- namespace (PROF-12) ---
# This is the delivery mechanism for the fleet migration. Self-update replaces
# skill FILES and never re-runs the installer, so a migration hosted only in the
# installer reaches ~0 already-deployed machines; the everyday credential_process
# path is where they actually converge.
#
# ORDERING CONTRACT -- this MUST stay after Invoke-SweepExpiredProfiles above.
# Get-AccountIdFromCredentialProcess keys the cache on the ACCOUNT ID, not the
# profile name (Phase 18 collapse), so a freshly renamed `csg-X` inherits old
# `X`'s <account-id>.json -- and that is a 1-hour session, so it is almost always
# expired. Migrating first therefore hands the sweep a brand-new `csg-X` that it
# classifies as expired-with-cache and deletes on the spot: the mapping table
# claims N renames while the fleet ends up empty. Sweeping first means migrate
# only ever rewrites the survivors.
#
# The marker check is repeated here (Invoke-MigrationOnce does it too) so the
# steady state on an already-migrated machine is ONE substring scan and complete
# silence: without it every AWS command on every converged machine would carry a
# `[migrate] status=already-migrated` line on its stderr.
#
# `$null =` is mandatory, not stylistic: Invoke-MigrationOnce RETURNS an int, and
# an uncaptured return value would be written to stdout -- which on this path is
# the 5-key credential JSON channel (T-23-37).
#
# try/catch is the PowerShell spelling of bash's `|| true`: a migration failure
# must NEVER stop this machine from resolving credentials.
if (-not (Test-MigrationCompleted) -and (Get-Command aws -ErrorAction SilentlyContinue)) {
    try { $null = Invoke-MigrationOnce } catch { }
}

$CacheFile = Join-Path $CacheDir "$AccountId.json"

# --- Cache lookup ---
function Get-CachedCredentials {
    if (-not (Test-Path $CacheFile)) { return $null }
    try {
        $rawJson = Get-Content -Raw -LiteralPath $CacheFile
        $cached = $rawJson | ConvertFrom-Json
        # Extract Expiration from raw JSON to avoid ConvertFrom-Json DateTime auto-conversion
        if ($rawJson -match '"Expiration"\s*:\s*"([^"]+)"') {
            $exp = $Matches[1]
        } else {
            return $null
        }
        $expEpoch = [DateTimeOffset]::Parse($exp).ToUnixTimeSeconds()
        $nowEpoch = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        if (($expEpoch - $nowEpoch) -gt $CacheSkewSeconds) {
            Write-Log "cache HIT (expires $exp)"
            return $cached
        } else {
            Write-Log "cache STALE (expires $($cached.Expiration)), refreshing"
            return $null
        }
    } catch {
        return $null
    }
}

$cached = Get-CachedCredentials
if ($cached) {
    [Console]::Out.WriteLine(($cached | ConvertTo-Json -Compress -Depth 10))
    exit 0
}

# --- Per-account single-flight (credential-broker #50) ---
# Twin of the bash mkdir lock. One caller issues; the rest wait, then re-read the cache
# the winner wrote. A FileShare.None handle is the lock: the OS drops it when this process
# exits (even on a crash or `exit 1`), so there is no stale-lock reclaim and no cleanup
# path to forget. The file is dotted (not matched by the "*.json" cleanup glob) and never
# deleted, which avoids a delete/create race between waiters. It sits in CacheDir beside
# the cache and is chmod 600 like it; it holds no credentials. Sits BEFORE the scope brake
# so a waiter served from the cache consumes no fan-out budget.
# Fail OPEN: no lock within the wait cap (or an unopenable file) means POST unlocked,
# which is the pre-#50 behaviour.
$AcctLockPath = Join-Path $CacheDir ".$AccountId.lock"
$AcctLockWaitMs = 45000   # under the bash twin's 60s stale age, over a normal ~1s issuance
$script:AcctLock = $null
$lockDeadline = [DateTime]::UtcNow.AddMilliseconds($AcctLockWaitMs)
while ($true) {
    try {
        $script:AcctLock = [System.IO.File]::Open($AcctLockPath, [System.IO.FileMode]::OpenOrCreate,
            [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
        break
    } catch [System.IO.IOException] {
        if ([DateTime]::UtcNow -ge $lockDeadline) { break }
        Start-Sleep -Milliseconds 100
    } catch {
        break
    }
}
if ($script:AcctLock) {
    if ($IsLinux -or $IsMacOS) {
        try { & chmod 600 $AcctLockPath 2>$null } catch { }
    }
    # The winner we waited for may have just written the cache.
    $cached = Get-CachedCredentials
    if ($cached) {
        [Console]::Out.WriteLine(($cached | ConvertTo-Json -Compress -Depth 10))
        exit 0
    }
} else {
    Write-Log "WARNING: 계정 잠금을 얻지 못해 잠금 없이 발급합니다 ($AcctLockPath)"
}

# --- Read the Slack Bearer from the login-token cache (NO OAuth here) ---
# credential_process must NEVER open a browser: if the Bearer is missing/empty we
# fail fast so the AWS CLI does not hang (the prior ~120s agent hang). The Bearer
# is read from sts-token.json (never a parameter) and is never logged.
$Bearer = ""
if (Test-Path -LiteralPath $StsCache) {
    try {
        $stsCache = Get-Content -Raw -LiteralPath $StsCache | ConvertFrom-Json
        if ($stsCache.PSObject.Properties['SlackAccessToken'] -and
            -not [string]::IsNullOrWhiteSpace($stsCache.SlackAccessToken)) {
            $Bearer = [string]$stsCache.SlackAccessToken
        }
    } catch {
        # Ignore parse errors -- treated as a missing Bearer below.
    }
}
if ([string]::IsNullOrWhiteSpace($Bearer)) {
    Stop-WithError "로그인이 필요합니다. 먼저 get-sts-token.ps1 를 실행해 Slack 로그인 토큰을 발급받으세요 (credential_process 안에서는 브라우저 로그인을 열지 않습니다)."
}

# --- Derive the customer endpoint from API_URL (no new conf key; mirrors self-update) ---
$ApiUrl = Read-ApiUrl
if ([string]::IsNullOrWhiteSpace($ApiUrl)) {
    Stop-WithError "설정 파일에서 API_URL을 찾을 수 없습니다: $ConfigFile"
}
if (-not $ApiUrl.StartsWith("https://", [System.StringComparison]::OrdinalIgnoreCase)) {
    Stop-WithError "API_URL은 https://로 시작해야 합니다"
}
$CustomerUrl = $ApiUrl -replace '/credentials$', '/customer-credentials'

# --- Exchange {accountId, agent, clientVersion} + Bearer for a read-only session ---
# clientVersion is ERR-10 observation only; the hashtable + ConvertTo-Json is the
# injection-safe path, exactly as --arg is on the bash side.
$Body = @{ accountId = $AccountId; agent = $Agent; clientVersion = $ClientVersion } | ConvertTo-Json -Compress

# --- SCP-05 fan-out brake (D-01/D-06/D-17) ---
#
# PLACEMENT. Five reasons this block cannot move, all structural:
#
#  1. AFTER the cache short-circuit above (the Get-CachedCredentials result that
#     writes the 5-key JSON and exits 0), so a cache HIT reaches this on no path
#     at all and writes no window record. That is D-01's counting unit --
#     신규 발급만 -- and it is enforced by POSITION, not by a condition that a
#     later edit could quietly invert.
#  2. AFTER every fail-fast: the -AccountId regex, the missing-Bearer
#     Stop-WithError and the missing/non-https API_URL Stop-WithError all sit
#     above. A machine that is not logged in must keep getting
#     "로그인이 필요합니다", and a login failure is not a fan-out, so it must not
#     consume window budget.
#  3. BEFORE the bounded retry loop's counter reset below (Pitfall 9). A check
#     inside that loop would record the same account up to three times and could
#     refuse on retry 2 of a legitimate 5xx recovery. One record per invocation =
#     one per broker POST ATTEMPT. That is the D-01 discretion call -- 시도 시점,
#     not 응답 시점: twelve consecutive failures are still a fan-out.
#  4. This block installs no cleanup handler and holds no resource across its own
#     exit, so nothing it does can be undone by a later finally/Remove-Item in
#     the request path.
#  5. The sweep -> migrate ordering block ~90 lines above -- the one whose header
#     comment reads "this MUST stay after Invoke-SweepExpiredProfiles above." --
#     is a DIFFERENT contract and is not touched here. It is named so a reader
#     recognises it on sight instead of going looking for the brake up there. Its
#     two-word banner token is deliberately NOT reproduced verbatim: this plan's
#     gate greps the diff for that token to prove the block was untouched, so
#     quoting it would make the gate report this very comment.
#
# FAIL OPEN (T-24-07), AND WHY THE try/catch IS MANDATORY ON THIS SIDE. The whole
# computation sits inside a try whose catch sets the refusal flag back to $false
# and logs one warning. Under $ErrorActionPreference = "Stop" at the top of this
# file, an ordinary reader error is a TERMINATING error, so without the catch an
# unreadable state file would kill a legitimate single-account issuance. This is
# the pwsh analog of the bash twin's per-assignment `|| fallback`, not a new
# policy. The clock is sanity-checked the same way: a non-positive epoch skips
# the brake entirely, the same direction as every reader 24-03 shipped. Breaking
# a legitimate single-account read is strictly worse than missing one fan-out
# (CLAUDE.md Core Value).
#
# THE REFUSAL IS HOISTED OUT OF THE try ON PURPOSE -- a code divergence from the
# bash twin, which refuses inline inside its `if`. Stop-WithScopeRefusal calls
# `exit 1`, and in PowerShell an `exit` inside a `try` is a live flow-control path
# that a `catch` can observe. Calling it from a flag test OUTSIDE the try makes it
# structurally impossible for the refusal to be swallowed or reordered, and it
# provably runs AFTER Invoke-ScopePrune has released .scope.lock. Behavioural
# parity, code divergence.
#
# D-17, APPEND-THEN-COUNT -- stated with the comparison so it is not misread as a
# deviation. Write-ScopeWindowRecord is the FIRST statement in the block, before
# any read, so this invocation's own record is durable before any count is taken
# and no process can observe an empty window after writing to it. .scope.lock
# still exists and still guards the counter file; it just guards only the PRUNE,
# where losing it degrades to "the file keeps a few stale lines the cutoff filter
# ignores anyway" instead of "the verdict was wrong". A lock-first design would
# have to fail open on every contended invocation -- which is exactly the
# situation a fan-out creates, i.e. the exact hole D-17 exists to close. Honest
# consequence: with twelve truly simultaneous invocations the number that PASS is
# "about 5", not "exactly 5"; every process that reads after six appends refuses.
# 24-07 therefore asserts bounds, not an exact split -- an exact-count assertion
# would flake by construction.
#
# WHY THE PRUNE COMES BEFORE THE VERDICT (Pitfall 2). Invoke-ScopePrune acquires
# .scope.lock and releases it in a finally; Stop-WithScopeRefusal exits. Calling
# the prune first -- and hoisting the refusal out of the try -- makes it
# structurally impossible to `exit` while holding the lock. Never reorder these
# two. Nothing else in this block touches the lock, and the acquire helper is not
# called from here at all.
#
# D-06 IS TWO RULES, NOT ONE. Get-ScopeWindowIds/Get-ScopeWindowDistinct already
# exclude every acked id from the count entirely (RESEARCH A3 -- otherwise a
# legitimately approved 12-account batch would sit in the window and block an
# unrelated 13th). The -like membership test below is the OTHER half: an account
# that IS in the ack set must pass even when six OTHER unapproved accounts sit in
# the window. Without it an approved account would be refused for its neighbours'
# behaviour, which is not what "집합에 적힌 계정만 브레이크 면제" means. Accounts
# outside the set are still counted against each other and still refused.
# That -like test is safe ONLY because $AccountId was validated ^[0-9]{12}$ by the
# input gate above and therefore cannot carry a wildcard metacharacter (*, ?, [).
# Stated here so that a future loosening of that regex is visibly load-bearing.
#
# THE RECORD IS WRITTEN EVEN FOR AN ACKED ACCOUNT. D-01's unit is the issuance
# attempt, not the unapproved issuance attempt. Acked-ness is applied at READ
# time by intersecting with the ack set, so there is never a write-then-update
# window where a record sits on disk with an already-stale value.
#
# T-24-05 / T-24-06. Every Get-Scope* call below is on an ASSIGNMENT line -- an
# unassigned call emits its return value to the success stream, i.e. onto the
# credential_process stdout that must carry the 5-key JSON and nothing else.
# Write-ScopeWindowRecord, Invoke-ScopePrune and Stop-WithScopeRefusal write to
# the success stream on no path, so that contract is untouched whether this block
# passes, refuses or fails open. There is no prompt, no blocking wait and no
# sleep here, and the lock acquire reached inside the prune is non-blocking. The
# file header records a prior ~120s agent hang from exactly this class; the
# budget for this block is fail-fast in well under two seconds.
#
# WHAT THIS IS, STATED PLAINLY. 결정론적 거부와 기록. An agent that calls
# `scope-ack` itself walks straight through it (T-24-02, accepted); the backstop
# that does not depend on the agent's cooperation is server-side (Phase 25
# DET-01). Fleet timing: a machine still running the old client mid-rollout
# neither reads nor writes these files, so the window UNDER-counts during a
# rollout and never over-counts.
#
# Locals are lower-camelCase scope* on purpose, so that a grep for $Scope[A-Z]
# keeps returning exactly the six frozen constants T-24-03's gate depends on.
$scopeRefuse = $false
$scopeCount = 0
$scopeIds = ""
try {
    $scopeNow = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    if ($scopeNow -gt 0) {
        $scopeCutoff = $scopeNow - $ScopeWindowSeconds

        Write-ScopeWindowRecord -AccountId $AccountId

        $scopeAcks = Get-ScopeAckSet -NowEpoch $scopeNow
        $scopeIds = Get-ScopeWindowIds -Cutoff $scopeCutoff -AckCsv $scopeAcks
        # WR-03: the count is DERIVED from $scopeIds, not read by a second call to
        # Get-ScopeWindowDistinct. Both numbers reach the same refusal message, and
        # two separate reads of scope-window.jsonl can see two different files --
        # a sibling invocation appends between them. The second read is also the
        # one that feeds the copy-pasteable scope-ack line, so what a second parse
        # buys is a retry command missing an id the message just counted: a paste
        # that gets refused again. The [int] cast is not cosmetic -- it is the
        # return-type contract Get-ScopeWindowDistinct's header states, because
        # `$scopeCount -gt $ScopeMaxAccounts` below is silently meaningless against
        # an [Object[]]. IsNullOrWhiteSpace, not IsNullOrEmpty, matches what that
        # helper uses internally so the empty case still yields 0 rather than 1.
        $scopeCount = if ([string]::IsNullOrWhiteSpace($scopeIds)) { 0 } else { [int](@($scopeIds -split ',').Count) }

        Invoke-ScopePrune -Cutoff $scopeCutoff

        $scopeAcked = (",$scopeAcks," -like "*,$AccountId,*")
        $scopeRefuse = ((-not $scopeAcked) -and ($scopeCount -gt $ScopeMaxAccounts))
    }
}
catch {
    $scopeRefuse = $false
    Write-Log "브레이크 상태를 읽지 못해 이번 발급은 집계 없이 진행합니다: $ScopeWindowRecord"
}

if ($scopeRefuse) {
    Stop-WithScopeRefusal -DistinctCount $scopeCount -IdsCsv $scopeIds
}

Write-Log "POST $CustomerUrl (account=$AccountId, agent=$Agent)"

# --- Bounded retry loop with a broker HTTP status -> Korean message map (RES-02) ---
# Same taxonomy + retry policy as get-customer-credentials.sh: retry ONLY on the
# retryable class (503 / other 5xx / 0 transport-fail) -- three separate arms sharing
# ONE $attempt counter (D-01) -- bounded to $maxAttempts with a linear Start-Sleep
# backoff; NEVER retry the deterministic deny class (401/403/404/424).
# The Bearer stays in the Authorization header only (never argv, never logged) --
# and on this platform that is free: Invoke-BrokerRequest passes the header
# in-process, so no child process ever carries it. The bash twin needed an actual
# code change to reach the same place (WR-01); see the note above that function.
$attempt = 0
$maxAttempts = 3
$respBody = $null
while ($true) {
    $r = Invoke-BrokerRequest -Url $CustomerUrl -Body $Body -Bearer $Bearer
    $code = [int]$r.StatusCode
    if ($code -ge 200 -and $code -lt 300) {
        $respBody = $r.Body
        break
    }
    switch ($code) {
        401 { Stop-WithError "Slack 로그인이 만료되었습니다. get-sts-token.ps1 를 다시 실행해 로그인하세요." }
        403 { Stop-WithError "이 계정에 접근 권한이 없습니다 (등록된 활성 고객 계정이 아니거나 인가 실패)." }
        404 { Stop-WithError "브로커 엔드포인트를 찾을 수 없습니다. API_URL 설정을 확인하세요." }
        # ERR-02 (Phase 30): deterministic deny -- twin of get-customer-credentials.sh's
        # 424) arm and a copy of the 403 shape above. No $attempt, no Start-Sleep: a
        # customer-side trust-policy failure never heals by waiting, and keeping it out of
        # every retry arm is what holds "total requests <= $maxAttempts for every status
        # class" (D-01). The sentence is a client-side literal, byte-identical to the bash
        # twin; the 424 body is deliberately not parsed (D-09, T-30-10).
        # tiket (2026-10-20): the broker's MIN_CLIENT_VERSION refused this workspace's release.
        # Deterministic like 424 -- no retry. Client-side literal, byte-identical to the bash twin.
        426 { Stop-WithError "tiket 워크스페이스가 오래돼 브로커가 발급을 거절했습니다. 에이전트 세션을 새로 시작하면 자동으로 올라갑니다. 안 되면 워크스페이스에서 git pull 을 하세요." }
        424 { Stop-WithError "고객사 계정 설정 또는 등록 정보 문제로 세션을 발급할 수 없습니다 (고객사 역할/신뢰정책, 등록 계정 정보 확인 필요). 재시도해도 해결되지 않습니다." }
        # credential-broker #49: API-stage throttle. Transient, so it shares the ONE
        # $attempt counter (total POSTs <= $maxAttempts for every class). Jittered 1-2s
        # sleep so throttled siblings do not retry in lockstep. Twin of the bash 429) arm.
        429 {
            $attempt++
            if ($attempt -ge $maxAttempts) {
                Stop-WithError "브로커가 요청 제한(429)으로 응답했습니다. 잠시 후 다시 시도하세요."
            }
            Start-Sleep -Milliseconds ($attempt * 1000 + (Get-Random -Maximum 1000))
        }
        503 {
            $attempt++
            if ($attempt -ge $maxAttempts) {
                Stop-WithError "브로커 의존성을 일시적으로 사용할 수 없습니다. 잠시 후 다시 시도하세요."
            }
            Start-Sleep -Seconds $attempt
        }
        # ERR-03 (Phase 30): transport failure -- Invoke-BrokerRequest maps "threw with no
        # usable HTTP status" to 0, so there was no HTTP response at all. Split out of the
        # default guard below (whose 5xx-only condition was narrowed in the same edit so it
        # no longer also owns status 0) -- the budget accounting for this class now lives in
        # exactly one place.
        #
        # D-01: same $attempt, same $maxAttempts as 503 and the 5xx default -- no second
        # counter, exactly as in the bash twin (T-30-11).
        #
        # D-02: the diagnostic is appended on the FINAL Stop-WithError only. The exception
        # message can be multi-line, so take line 0 first, then the display sanitizer at
        # :1082 (strips \p{Cc} + \p{Cf}, caps at 120 chars) -- proxy-influenced text, and
        # the output is read by an AI agent as well as a human (T-30-08). The fixed Korean
        # prefix up to and including "진단: " is byte-identical to the bash twin; only the
        # quoted platform text differs, and parity asserts only that it is non-empty (D-03).
        0 {
            $attempt++
            if ($attempt -ge $maxAttempts) {
                $errFirstLine = ([string]$r.Error -split '\r?\n')[0]
                Stop-WithError "브로커에 연결할 수 없습니다 (네트워크/DNS/프록시 확인). 진단: '$(ConvertTo-DisplaySafe -Text $errFirstLine)'"
            }
            Start-Sleep -Seconds $attempt
        }
        default {
            if ($code -ge 500 -and $code -le 599) {
                $attempt++
                if ($attempt -ge $maxAttempts) {
                    Stop-WithError "브로커를 일시적으로 사용할 수 없습니다. 잠시 후 다시 시도하세요."
                }
                Start-Sleep -Seconds $attempt
            } else {
                Stop-WithError "브로커 호출 실패 (HTTP $code)."
            }
        }
    }
}

if ([string]::IsNullOrWhiteSpace($respBody)) {
    Stop-WithError "브로커 응답이 비어 있습니다"
}

# Parse the 2xx body; the existing .error surfacing + 5-key projection below operate on $resp.
try {
    $resp = $respBody | ConvertFrom-Json
}
catch {
    # CR-01: a 2xx body that does not parse is still an untrusted broker string,
    # and a response truncated mid-SecretAccessKey is exactly the shape that
    # reaches here. Printing it put that fragment on stderr. The status and the
    # byte count are enough to tell "the broker sent garbage" apart from "the
    # broker sent nothing", and neither is attacker-chosen text.
    Stop-WithError "브로커 응답 형식 오류: 본문이 JSON 이 아닙니다 (HTTP $code, $($respBody.Length)바이트)."
}

if ($null -eq $resp) {
    Stop-WithError "브로커 응답이 비어 있습니다"
}

# Surface a structured broker error even on a 2xx {"error":...} body (fail closed).
# Unconditional on any error/message field, matching the bash twin exactly —
# even if AccessKeyId is also present (partial-failure response), fail closed.
if ($resp.PSObject.Properties['error'] -or $resp.PSObject.Properties['message']) {
    $msg = if ($resp.PSObject.Properties['error']) { [string]$resp.error } else { [string]$resp.message }
    Stop-WithError "브로커 오류: $msg"
}

# Project to EXACTLY the 5-key credential_process contract (drops BrokerVersion).
# Fail closed if any required credential field is absent (unexpected/error body).
#
# CR-01: the message names the HTTP status and the CONTRACT FIELDS this client's
# own guard rejected -- never the body. The body used to be re-serialised whole
# into the failure string, and the shape that arrives here is a 200 carrying a
# live AccessKeyId / SecretAccessKey / SessionToken with an unusable expiry, which
# neither the status arms nor the error surfacing above can catch. Those
# credentials went to stderr: the engineer's terminal, the AI agent transcript and
# any CI log capturing the run.
#
# The list is a FIXED client-side array, so the printed string cannot be anything
# but a subset of those four literals -- zero broker-controlled bytes, which makes
# injection at this point unrepresentable rather than merely sanitized. The
# predicate is the SAME per-field IsNullOrEmpty test the four-clause condition
# used; this change moves where the failure is described, not what counts as one.
# The prefix through the status is byte-identical to the bash twin.
$missing = @(
    @('AccessKeyId', 'SecretAccessKey', 'SessionToken', 'Expiration') |
        Where-Object { [string]::IsNullOrEmpty([string]$resp.$_) }
)
if ($missing.Count -gt 0) {
    Stop-WithError "브로커 응답 형식 오류 또는 인증 실패 (HTTP $code, 누락 필드: $($missing -join ','))."
}

$credsObj = [PSCustomObject]@{
    Version         = 1
    AccessKeyId     = $resp.AccessKeyId
    SecretAccessKey = $resp.SecretAccessKey
    SessionToken    = $resp.SessionToken
    Expiration      = $resp.Expiration
}

$credsJson = $credsObj | ConvertTo-Json -Compress -Depth 10

# Atomic cache write
$tmpCache = [System.IO.Path]::Combine(
    [System.IO.Path]::GetDirectoryName($CacheFile),
    [System.IO.Path]::GetRandomFileName()
)
Set-Content -Path $tmpCache -Value $credsJson -NoNewline -Encoding UTF8

# POSIX permission hardening for non-Windows (chmod 600)
if ($IsLinux -or $IsMacOS) {
    try { & chmod 600 $tmpCache 2>$null } catch { }
}

# Restrict ACL to current user only -- the parent directory's inherited ACL
# typically grants Users read access. Mirrors the hardening in
# get-sts-token.ps1:436-451. Best-effort; non-fatal on systems where the
# ACL APIs are unavailable.
try {
    $acl = Get-Acl -LiteralPath $tmpCache
    $acl.SetAccessRuleProtection($true, $false)
    $acl.Access | ForEach-Object { $acl.RemoveAccessRule($_) } | Out-Null
    $rule = [System.Security.AccessControl.FileSystemAccessRule]::new(
        [System.Security.Principal.WindowsIdentity]::GetCurrent().Name,
        [System.Security.AccessControl.FileSystemRights]::FullControl,
        [System.Security.AccessControl.AccessControlType]::Allow
    )
    $acl.AddAccessRule($rule)
    Set-Acl -LiteralPath $tmpCache -AclObject $acl
}
catch {
    # Non-fatal -- permission restriction is best-effort
}

Move-Item -Force -Path $tmpCache -Destination $CacheFile

[Console]::Out.WriteLine($credsJson)

# 성공 경로의 종료 코드를 확정한다. 앞선 migrate 검사의 `aws` 가 남긴 $LASTEXITCODE(255)가
# 호출 방식에 따라 새어 나간다 — Windows 는 끝의 chmod 가 없어 덮이지 않는다 (tiket CI, 2026-10-20).
exit 0
