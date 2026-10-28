# Phase 18 -- get-customer-credentials.ps1 (thin Bearer HTTP credential_process) tests (Pester 5.x)
# PowerShell twin of test/get-customer-credentials.test.sh -- mirrors it CASE-FOR-CASE.
#
# Shared case IDs (1:1 with the bash test's run_case1..4):
#   case1 (CLI-01/02): success emits exactly the 5-key credential_process contract
#                      {Version:1,AccessKeyId,SecretAccessKey,SessionToken,Expiration}
#                      (BrokerVersion projected out), writes customer-creds/<account-id>.json
#                      (NO role segment), and performs NO local `aws sts assume-role`.
#   case2 (CLI-01):    second invocation is a cache HIT -- the broker (Invoke-RestMethod)
#                      is NOT called again.
#   case3 (CLI-01/03): missing/empty Bearer -> non-zero exit, no browser, no broker call,
#                      stderr points the user at get-sts-token.
#   case4 (RES-02):    broker {"error":...} body (HTTP 200 defensive path) -> non-zero exit
#                      surfacing the server message, and NO cache file is written.
#   case5 (RES-02):    HTTP 401 -> re-login message (names get-sts-token), NO retry, no cache.
#   case6 (RES-02):    HTTP 403 -> uniform not-authorized message, NO retry, no cache.
#   case7 (RES-02):    HTTP 503 -> bounded retry (>1, <=3 calls) then retryable failure, no cache.
#   case8 (RES-02):    HTTP 500 -> bounded retry then generic retryable failure.
#   case9 (T-19-05-01):the Bearer never appears in stderr on success / 403 / 500-retry paths.
#
# Stubbing model (mirrors cleanup.ps1.test.ps1 subprocess pattern):
#   - HOME/USERPROFILE override per case isolates filesystem state (conf + sts-token + cache).
#   - The wrapper script defines a stub `Invoke-WebRequest` (shadows the cmdlet in the
#     invoked script's scope) that records each call and returns an object carrying the
#     seeded StatusCode + body Content (matching Invoke-WebRequest -SkipHttpErrorCheck),
#     so the client's status->message map + bounded retry can be exercised per case.
#   - The wrapper also defines a stub `aws` that records a marker if ever asked to
#     assume-role, proving the no-local-assume invariant (never invoked by the new script).
#   - Seeded sts-token.json is IDENTITY-ONLY (SlackAccessToken + SlackUserId), never an
#     AWS session.
#
# This test is RED until get-customer-credentials.ps1 is rewritten (Task 2 GREEN).

if (-not (Get-Module -ListAvailable Pester)) {
    Write-Host "SKIP: Pester not installed"
    exit 0
}

BeforeAll {
    $script:RepoRoot = Split-Path -Parent $PSScriptRoot
    $script:ScriptUnderTest = Join-Path $script:RepoRoot "skills/aws-customer-account-ops/get-customer-credentials.ps1"

    if (-not (Test-Path $script:ScriptUnderTest)) {
        throw "get-customer-credentials.ps1 not found at $script:ScriptUnderTest"
    }

    # Cross-platform future ISO-8601 timestamp (1 hour ahead), millisecond ".000Z".
    function Get-FutureTs {
        return [DateTimeOffset]::UtcNow.AddHours(1).ToString("yyyy-MM-ddTHH:mm:ss.000Z")
    }

    # Seed conf + sts-token.json under a fresh HOME.
    #   -Bearer ""  => identity-only (no SlackAccessToken), simulating an expired/absent login.
    function New-BrokerEnv {
        param([string]$Dir, [string]$Bearer)

        New-Item -ItemType Directory -Force -Path (Join-Path $Dir ".config/msp") | Out-Null
        New-Item -ItemType Directory -Force -Path (Join-Path $Dir ".cache/msp/customer-creds") | Out-Null

        $conf = @"
API_URL=https://example.execute-api.ap-northeast-2.amazonaws.com/Prod/v1/credentials
CLIENT_ID=test-client-id
"@
        $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
        [IO.File]::WriteAllText((Join-Path $Dir ".config/msp/credential-broker.conf"), $conf, $utf8NoBom)

        $future = Get-FutureTs
        if ([string]::IsNullOrEmpty($Bearer)) {
            $tok = "{`"Version`":1,`"Expiration`":`"$future`",`"BrokerVersion`":`"1.3.0`",`"SlackUserId`":`"U0TESTUSER`"}"
        } else {
            $tok = "{`"Version`":1,`"Expiration`":`"$future`",`"BrokerVersion`":`"1.3.0`",`"SlackAccessToken`":`"$Bearer`",`"SlackUserId`":`"U0TESTUSER`"}"
        }
        [IO.File]::WriteAllText((Join-Path $Dir ".cache/msp/sts-token.json"), $tok, $utf8NoBom)
    }

    # Seed the stubbed broker response. Mode "ok" => 6-key body (incl. BrokerVersion, to be
    # projected out). Mode "err" => structured {"error":...} body. -Status is the HTTP status
    # the stub emits (default 200); "0" simulates a transport/connect failure.
    #
    # Mode "creds-no-exp" (CR-01) is ADDITIVE: a 2xx body carrying live-looking
    # credential values with a null Expiration. It is the one shape both upstream
    # guards let through -- the status is 200 so no status arm fires, and there is no
    # error/message field so the structured-error surfacing does not fire -- leaving
    # the 5-key projection as the only thing standing between the broker body and the
    # engineer's screen. The canary substring lives ONLY in the three secret VALUES,
    # never in a field name, so a diagnostic may name the absent field while every
    # byte of credential material stays forbidden. Neither shipped body string
    # changes, so every pre-existing Context sees a byte-identical fixture.
    function Set-BrokerResponse {
        param([string]$Dir, [ValidateSet("ok", "err", "creds-no-exp")][string]$Mode, [int]$Status = 200)

        $stubDir = Join-Path $Dir ".stub"
        New-Item -ItemType Directory -Force -Path $stubDir | Out-Null

        if ($Mode -eq "ok") {
            $future = Get-FutureTs
            $body = "{`"Version`":1,`"AccessKeyId`":`"ASIAEXAMPLE`",`"SecretAccessKey`":`"wJalrExampleKey`",`"SessionToken`":`"FQoGExampleToken`",`"Expiration`":`"$future`",`"BrokerVersion`":`"1.3.0`"}"
        } elseif ($Mode -eq "creds-no-exp") {
            $body = '{"Version":1,"AccessKeyId":"ASIALEAKCANARY000000","SecretAccessKey":"wJalrLEAKCANARYsecretkey","SessionToken":"FQoGLEAKCANARYsessiontoken","Expiration":null,"BrokerVersion":"1.3.0"}'
        } else {
            $body = '{"error":"account 111111111111 is not authorized"}'
        }
        $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
        [IO.File]::WriteAllText((Join-Path $stubDir "resp.json"), $body, $utf8NoBom)
        [IO.File]::WriteAllText((Join-Path $stubDir "mode"), $Mode, $utf8NoBom)
        [IO.File]::WriteAllText((Join-Path $stubDir "status"), "$Status", $utf8NoBom)
    }

    # Invoke the script under test in a subprocess with HOME/USERPROFILE override and
    # stub Invoke-RestMethod / aws injected into the invoked script's scope.
    # Returns a hashtable with ExitCode, Stdout, Stderr.
    # Get-BrokerAgent: the `agent` value the client POSTed to the broker, captured
    # by the stub Invoke-WebRequest from its -Body. Empty string if never sent.
    function Get-BrokerAgent {
        param([string]$Dir)
        $bodyFile = Join-Path $Dir ".stub/last_body.json"
        if (-not (Test-Path -LiteralPath $bodyFile)) { return "" }
        try {
            $body = Get-Content -Raw -LiteralPath $bodyFile | ConvertFrom-Json
            return [string]$body.agent
        } catch { return "" }
    }

    # Get-BrokerClientVersion: the `clientVersion` value the client POSTed to the
    # broker (ERR-10 spread-observation field), read out of the same captured
    # request body as Get-BrokerAgent. Empty string if never sent.
    function Get-BrokerClientVersion {
        param([string]$Dir)
        $bodyFile = Join-Path $Dir ".stub/last_body.json"
        if (-not (Test-Path -LiteralPath $bodyFile)) { return "" }
        try {
            $body = Get-Content -Raw -LiteralPath $bodyFile | ConvertFrom-Json
            return [string]$body.clientVersion
        } catch { return "" }
    }

    # SCP-05 additions (-TimeoutSeconds / -CloseStdin) are STRICTLY ADDITIVE:
    # both default to today's behaviour, and the two extra return keys
    # (TimedOut / DurationMs) are invisible to the 28 shipped Contexts, which
    # read only ExitCode/Stdout/Stderr.
    #   -TimeoutSeconds 0 (default) keeps the shipped `Start-Process ... -Wait`
    #     call byte-for-byte. A positive value drops -Wait and arms a
    #     Wait-Process/Kill watchdog, so a brake that reintroduced a prompt fails
    #     the case at the budget instead of hanging the suite (the file header
    #     records a prior ~120s agent hang from exactly this).
    #   -CloseStdin gives the child a closed, non-TTY stdin (T-24-06). It is a
    #     SWITCH, not unconditional: turning it on for the 20+ shipped Contexts
    #     would be a behaviour change to cases this plan does not verify, and the
    #     property it buys is asserted only by the scope cases.
    function Invoke-CredScript {
        param(
            [string]$TestDir,
            [string[]]$Arguments,
            [hashtable]$EnvVars = @{},
            [int]$TimeoutSeconds = 0,
            [switch]$CloseStdin,
            [switch]$NoWait,
            [string]$CaptureTag = "",
            [string]$ScriptPath = $script:ScriptUnderTest
        )

        # -CaptureTag suffixes the capture filenames so SCOPE-8's twelve
        # CONCURRENT children can share one $TestDir (they must -- they contend on
        # one window file) without overwriting each other's stdout. Default "" is
        # the shipped filename, byte for byte.
        $stderrFile = Join-Path $TestDir "stderr_capture$CaptureTag.txt"
        $stdoutFile = Join-Path $TestDir "stdout_capture$CaptureTag.txt"
        $wrapperScript = Join-Path $TestDir "wrapper_$([IO.Path]::GetRandomFileName()).ps1"

        # T-24-08b: each argument reaches the child through a BASE64 ROUND-TRIP
        # rather than being interpolated into a double-quoted PowerShell literal.
        # The literal form breaks on exactly the values SCOPE-6 has to send -- a
        # raw '"' closes the string and a raw LF splits the array element -- so an
        # injection row would have produced a wrapper PARSE ERROR instead of
        # reaching the client, and the case would then have asserted nothing while
        # still looking red-capable. Base64 is 7-bit, quote-free and dollar-free,
        # so the emitted expression is inert inside the here-string; the decoded
        # value is byte-identical to $a, which is why the 28 shipped Contexts see
        # exactly the arguments they saw before.
        $argLines = @()
        foreach ($a in $Arguments) {
            $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes([string]$a))
            $argLines += "    [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(`"$b64`"))"
        }
        $argArrayLiteral = $argLines -join ",`n"

        # Agent-detection env isolation: always CLEAR every runtime signal in the
        # child (the test host itself may run under Claude Code, which exports
        # CLAUDECODE=1, or a VSCode-fork terminal that sets TERM_PROGRAM/
        # __CFBundleIdentifier, either of which would otherwise contaminate the
        # path-fallback case), then set ONLY the ones this case requests.
        $envLines = @(
            'Remove-Item Env:MSP_AGENT -ErrorAction SilentlyContinue',
            'Remove-Item Env:AI_AGENT -ErrorAction SilentlyContinue',
            'Remove-Item Env:CLAUDECODE -ErrorAction SilentlyContinue',
            'Remove-Item Env:TERM_PROGRAM -ErrorAction SilentlyContinue',
            'Remove-Item Env:__CFBundleIdentifier -ErrorAction SilentlyContinue',
            # HOME isolation is only airtight while no AWS_* override redirects
            # the delegated CLI: AWS_CONFIG_FILE / AWS_SHARED_CREDENTIALS_FILE
            # would make `aws configure set` write into the DEVELOPER'S REAL
            # config despite the HOME override (test/fleet-migrate.test.sh).
            'Remove-Item Env:AWS_CONFIG_FILE -ErrorAction SilentlyContinue',
            'Remove-Item Env:AWS_SHARED_CREDENTIALS_FILE -ErrorAction SilentlyContinue',
            'Remove-Item Env:AWS_PROFILE -ErrorAction SilentlyContinue',
            'Remove-Item Env:AWS_DEFAULT_PROFILE -ErrorAction SilentlyContinue'
        )
        foreach ($k in $EnvVars.Keys) {
            $envLines += "`$env:$k = `"$($EnvVars[$k])`""
        }
        $envBlock = $envLines -join "`n"

        # Absolute path of the REAL aws binary (-CommandType Application, so this
        # can never resolve to the stub FUNCTION defined in the wrapper below).
        # Empty when the CLI is absent, in which case the stub keeps its historic
        # swallow-everything behaviour and the migration cases SKIP.
        $realAws = ""
        $awsCmd = Get-Command aws -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($awsCmd) { $realAws = $awsCmd.Source }

        $wrapperContent = @"
`$ErrorActionPreference = "Stop"
`$env:HOME = "$TestDir"
`$env:USERPROFILE = "$TestDir"
$envBlock

# --- Stub Invoke-WebRequest: shadows the cmdlet inside the invoked script's scope ---
# The rewritten client calls Invoke-WebRequest -SkipHttpErrorCheck (PS7), which returns
# the response for ANY HTTP status without throwing. Mirror that: record the call, then
# return an object carrying the seeded StatusCode + body Content. A seeded status of 0
# simulates a transport failure (throw with no .Response -> client maps to StatusCode 0).
function Invoke-WebRequest {
    param(
        [Parameter(ValueFromRemainingArguments = `$true)] `$Rest,
        `$Uri, `$Method, `$ContentType, `$Body, `$Headers, `$TimeoutSec,
        [switch]`$SkipHttpErrorCheck
    )
    `$stub = Join-Path `$env:HOME ".stub"
    New-Item -ItemType Directory -Force -Path `$stub | Out-Null
    Add-Content -LiteralPath (Join-Path `$stub "http_calls") -Value "called"
    # ADDITIVE (#50): optional per-call latency in ms so parallel callers overlap the
    # in-flight POST. Absent file => no sleep => every earlier Context is unchanged.
    `$delayFile = Join-Path `$stub "delay"
    if (Test-Path -LiteralPath `$delayFile) {
        Start-Sleep -Milliseconds ([int](Get-Content -Raw -LiteralPath `$delayFile).Trim())
    }
    if (`$Body) {
        # Capture the POST body ({accountId,agent}) so tests can assert the sent agent.
        Set-Content -LiteralPath (Join-Path `$stub "last_body.json") -Value `$Body -NoNewline
    }

    `$status = 200
    `$statusFile = Join-Path `$stub "status"
    if (Test-Path -LiteralPath `$statusFile) {
        `$status = [int](Get-Content -Raw -LiteralPath `$statusFile).Trim()
    }
    # --- .stub/status_seq (SCP-05, additive) --------------------------------
    # Per-CALL status inside ONE invocation, the twin of the bash CURLSTUB branch
    # 24-05 added. COMPATIBILITY: this branch is unreachable unless
    # .stub/status_seq exists and NO shipped case creates that file, so every
    # pre-existing Context sees a byte-identical stub.
    # NECESSITY: without it there is no way to express "the broker was down and
    # then came back INSIDE one invocation", which is the only fixture that
    # separates "one window record per invocation" from "one per HTTP call" --
    # two readings of D-01 that differ by 3x on exactly the failure pattern this
    # phase exists to catch. The append of "called" above happens FIRST, so the
    # line count is a 1-based index naming the CURRENT call.
    `$seqFile = Join-Path `$stub "status_seq"
    if (Test-Path -LiteralPath `$seqFile) {
        `$callIdx = @(Get-Content -LiteralPath (Join-Path `$stub "http_calls")).Count
        `$seq = @(Get-Content -LiteralPath `$seqFile | Where-Object { `$_.Trim() -ne "" })
        if (`$seq.Count -gt 0) {
            `$pick = if (`$callIdx -ge 1 -and `$callIdx -le `$seq.Count) { `$seq[`$callIdx - 1] } else { `$seq[`$seq.Count - 1] }
            if (-not [string]::IsNullOrWhiteSpace(`$pick)) { `$status = [int]`$pick.Trim() }
        }
    }
    `$respBody = ""
    `$respFile = Join-Path `$stub "resp.json"
    if (Test-Path -LiteralPath `$respFile) {
        `$respBody = Get-Content -Raw -LiteralPath `$respFile
    }

    if (`$status -eq 0) {
        throw [System.Net.WebException]::new("stub: the remote server could not be reached")
    }

    return [PSCustomObject]@{ StatusCode = `$status; Content = `$respBody }
}

# --- Stub aws: record a marker if ever asked to assume-role (no-local-assume guard) ---
# `configure` is DELEGATED to the REAL CLI when one exists (absolute path frozen
# by the harness). The HOOK-B/STDOUT cases drive the auto-migration that now runs
# on the credential_process path, and migration is pure ~/.aws/config
# manipulation: a stub that swallows every `configure` verb makes EVERY fixture
# look like a machine with zero profiles, so the ordering and stdout-purity
# assertions would pass while proving nothing (test/fleet-migrate.test.sh:29-38
# records the same reasoning). \$LASTEXITCODE is a global automatic, so the real
# binary's exit code reaches the client unchanged.
function aws {
    `$stub = Join-Path `$env:HOME ".stub"
    New-Item -ItemType Directory -Force -Path `$stub | Out-Null
    `$argline = `$args -join ' '
    Add-Content -LiteralPath (Join-Path `$stub "aws_calls") -Value `$argline
    if (`$argline -match 'assume-role') {
        Add-Content -LiteralPath (Join-Path `$stub "aws_assume") -Value `$argline
        return
    }
    if (`$args.Count -gt 0 -and `$args[0] -eq 'configure' -and "$realAws" -ne "") {
        & "$realAws" @args
        return
    }
}

`$scriptArgs = @(
$argArrayLiteral
)
& "$ScriptPath" @scriptArgs
exit `$LASTEXITCODE
"@
        $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
        [IO.File]::WriteAllText($wrapperScript, $wrapperContent, $utf8NoBom)

        $spArgs = @{
            FilePath               = "pwsh"
            ArgumentList           = @("-NoProfile", "-File", $wrapperScript)
            RedirectStandardOutput = $stdoutFile
            RedirectStandardError  = $stderrFile
            NoNewWindow            = $true
            PassThru               = $true
        }
        if ($CloseStdin) {
            # An empty FILE, not /dev/null: Start-Process -RedirectStandardInput
            # takes a PATH and /dev/null does not exist on Windows, so a zero-byte
            # file is the portable primitive that hands the child a closed,
            # non-TTY stdin on every platform this suite runs on.
            $stdinFile = Join-Path $TestDir "empty_stdin_$([IO.Path]::GetRandomFileName()).txt"
            [IO.File]::WriteAllBytes($stdinFile, [byte[]]@())
            $spArgs['RedirectStandardInput'] = $stdinFile
        }

        # -NoWait hands the caller a live process object instead of a result.
        # SCOPE-8 needs twelve children RUNNING AT ONCE against one window file;
        # a -Wait loop would serialise them and the case would measure nothing
        # about concurrency at all.
        if ($NoWait) {
            return @{
                Process    = (Start-Process @spArgs)
                StdoutFile = $stdoutFile
                StderrFile = $stderrFile
            }
        }

        $sw = [Diagnostics.Stopwatch]::StartNew()
        $timedOut = $false
        if ($TimeoutSeconds -le 0) {
            $proc = Start-Process @spArgs -Wait
        } else {
            $proc = Start-Process @spArgs
            Wait-Process -InputObject $proc -Timeout $TimeoutSeconds -ErrorAction SilentlyContinue
            if (-not $proc.HasExited) {
                $timedOut = $true
                try { $proc.Kill() } catch { }
                Wait-Process -InputObject $proc -Timeout 5 -ErrorAction SilentlyContinue
            }
        }
        $sw.Stop()

        $exitCode = -1
        try { $proc.Refresh(); $exitCode = $proc.ExitCode } catch { $exitCode = -1 }

        $stdout = ""
        $stderr = ""
        if (Test-Path $stdoutFile) { $stdout = Get-Content -Raw -LiteralPath $stdoutFile }
        if (Test-Path $stderrFile) { $stderr = Get-Content -Raw -LiteralPath $stderrFile }

        return @{
            ExitCode   = $exitCode
            Stdout     = $stdout
            Stderr     = $stderr
            TimedOut   = $timedOut
            DurationMs = [long]$sw.ElapsedMilliseconds
        }
    }

    # Invoke-CredScriptRaw -TestDir <d> -RawArgs '<verbatim pwsh argument text>'
    # The PARSER-FIDELITY twin of Invoke-CredScript, and the two are not
    # interchangeable. Invoke-CredScript sends every argument through a base64
    # round trip precisely so the wrapper's parser can NEVER see the value -- the
    # right call for SCOPE-6's injection rows, and exactly wrong for WR-02, where
    # the defect IS how PowerShell parses the text a user pastes. An unquoted
    # `--account-ids a,b` becomes an [object[]] only when a pwsh PARSER reads it;
    # synthesising a nested array in this file instead would not reproduce it
    # anyway, because Invoke-CredScript's own [string[]]$Arguments flattens one.
    # So this helper emits the argument text VERBATIM and lets the parser work.
    #
    # Therefore: never route an injection or newline-bearing value through here.
    # $RawArgs lands inside a double-quoted here-string, so a '$' in it WOULD
    # interpolate -- that is Invoke-CredScript's job, and this helper exists only
    # for the small, 7-bit, hand-written command lines the refusal prints.
    #
    # Deliberately minimal: scope-ack makes no network call, reads no ~/.aws/config
    # and touches nothing but $CacheDir, so HOME isolation is the whole fixture.
    # Do NOT grow this into a second Invoke-CredScript.
    function Invoke-CredScriptRaw {
        param(
            [string]$TestDir,
            [string]$RawArgs,
            [int]$TimeoutSeconds = 20,
            [string]$ScriptPath = $script:ScriptUnderTest
        )

        $tag = [IO.Path]::GetRandomFileName()
        $stdoutFile = Join-Path $TestDir "raw_stdout_$tag.txt"
        $stderrFile = Join-Path $TestDir "raw_stderr_$tag.txt"
        $wrapperScript = Join-Path $TestDir "rawwrapper_$tag.ps1"

        $wrapperContent = @"
`$ErrorActionPreference = "Stop"
`$env:HOME = "$TestDir"
`$env:USERPROFILE = "$TestDir"
& "$ScriptPath" $RawArgs
exit `$LASTEXITCODE
"@
        [IO.File]::WriteAllText($wrapperScript, $wrapperContent, [System.Text.UTF8Encoding]::new($false))

        $proc = Start-Process -FilePath "pwsh" `
            -ArgumentList @("-NoProfile", "-File", $wrapperScript) `
            -RedirectStandardOutput $stdoutFile `
            -RedirectStandardError $stderrFile `
            -NoNewWindow -PassThru
        Wait-Process -InputObject $proc -Timeout $TimeoutSeconds -ErrorAction SilentlyContinue
        $timedOut = $false
        if (-not $proc.HasExited) {
            $timedOut = $true
            try { $proc.Kill() } catch { }
            Wait-Process -InputObject $proc -Timeout 5 -ErrorAction SilentlyContinue
        }

        $exitCode = -1
        try { $proc.Refresh(); $exitCode = $proc.ExitCode } catch { $exitCode = -1 }
        $stdout = ""
        $stderr = ""
        if (Test-Path -LiteralPath $stdoutFile) { $stdout = Get-Content -Raw -LiteralPath $stdoutFile }
        if (Test-Path -LiteralPath $stderrFile) { $stderr = Get-Content -Raw -LiteralPath $stderrFile }

        return @{
            ExitCode = $exitCode
            Stdout   = $stdout
            Stderr   = $stderr
            TimedOut = $timedOut
        }
    }

    # Get-ScopeAckRaw -Dir <d> -> the whole scope-acks.jsonl text, "" when absent.
    function Get-ScopeAckRaw {
        param([string]$Dir)
        $path = Join-Path $Dir ".cache/msp/customer-creds/scope-acks.jsonl"
        if (-not (Test-Path -LiteralPath $path)) { return "" }
        try { return [IO.File]::ReadAllText($path) } catch { return "" }
    }

    # -- Migration (HOOK-B / STDOUT) fixtures ----------------------------------
    # Fixture builders are DUPLICATED per suite in this repo by convention -- do
    # NOT source them from test/fleet-migrate.test.ps1. Account ids are
    # deliberately distinct from the invocation's own 111111111111 so PROF-06's
    # exclude-own-cache rule never masks what these cases assert.
    $script:Utf8NoBom = [System.Text.UTF8Encoding]::new($false)

    function Test-RealAwsPresent {
        return [bool](Get-Command aws -CommandType Application -ErrorAction SilentlyContinue)
    }

    # stale-cust -- legacy CSG (222222222222), paired with an EXPIRED cache below
    #               so the sweep removes it.
    # samplecorp     -- legacy CSG (333333333333), NO cache, therefore protected from
    #               the sweep and MUST be migrated to csg-samplecorp.
    function New-LegacyConfig {
        param([string]$Dir)
        New-Item -ItemType Directory -Force -Path (Join-Path $Dir ".aws") | Out-Null
        $conf = @'
[profile stale-cust]
credential_process = pwsh -NoProfile -File /path/to/get-customer-credentials.ps1 -AccountId 222222222222 -Agent claude-code
region = ap-northeast-2

[profile samplecorp]
credential_process = pwsh -NoProfile -File /path/to/get-customer-credentials.ps1 -AccountId 333333333333 -Agent claude-code
region = ap-northeast-2

[default]
region = ap-northeast-2
'@
        [IO.File]::WriteAllText((Join-Path $Dir ".aws/config"), $conf, $script:Utf8NoBom)
    }

    # class H: the rename target `csg-acme` is already taken (D-07).
    # The two sections MUST carry DIFFERENT account ids: the collision is
    # detected by register's `account-mismatch` abort, and a same-account
    # `csg-acme` is instead a legitimate idempotent re-registration.
    function New-CollisionConfig {
        param([string]$Dir)
        New-Item -ItemType Directory -Force -Path (Join-Path $Dir ".aws") | Out-Null
        $conf = @'
[profile acme]
credential_process = pwsh -NoProfile -File /path/to/get-customer-credentials.ps1 -AccountId 444444444444 -Agent claude-code
region = ap-northeast-2

[profile csg-acme]
credential_process = pwsh -NoProfile -File /path/to/get-customer-credentials.ps1 -AccountId 777777777777 -Agent claude-code
csg_managed = 1.7.0
region = ap-northeast-2

[profile other]
credential_process = pwsh -NoProfile -File /path/to/get-customer-credentials.ps1 -AccountId 888888888888 -Agent claude-code
region = ap-northeast-2

[default]
region = ap-northeast-2
'@
        [IO.File]::WriteAllText((Join-Path $Dir ".aws/config"), $conf, $script:Utf8NoBom)
    }

    # The composite "incident machine": every migration class at once, so a
    # single credential_process call exercises the whole destructive path while
    # the stdout contract is under assertion. `samplecorp` deliberately carries the
    # SAME account id as the invocation (D-06: the currently-in-use profile is
    # rewritten too), which is the highest-risk shape for stdout purity.
    function New-IncidentConfig {
        param([string]$Dir)
        New-Item -ItemType Directory -Force -Path (Join-Path $Dir ".aws") | Out-Null
        $conf = @'
[profile samplecorp]
credential_process = pwsh -NoProfile -File /path/to/get-customer-credentials.ps1 -AccountId 111111111111 -Agent claude-code
region = ap-northeast-2

[profile example-dev]
csg_managed = 1.6.2
credential_process = pwsh -NoProfile -File /path/to/get-customer-credentials.ps1 -AccountId 222222222222 -Agent claude-code
region = ap-northeast-2

[profile csg-already]
csg_managed = 1.7.0
credential_process = pwsh -NoProfile -File /path/to/get-customer-credentials.ps1 -AccountId 333333333333 -Agent claude-code
region = ap-northeast-2

[profile poisoned-a]
sso_start_url = https://acme.awsapps.com/start
sso_region = ap-northeast-2
sso_account_id = 444444444444
sso_role_name = ReadOnlyAccess
csg_managed = 1.6.2
credential_process = pwsh -NoProfile -File /path/to/get-customer-credentials.ps1 -AccountId 444444444444 -Agent claude-code
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
credential_process = pwsh -NoProfile -File /path/to/get-sts-token.ps1 -Agent claude-code
region = ap-northeast-2
'@
        [IO.File]::WriteAllText((Join-Path $Dir ".aws/config"), $conf, $script:Utf8NoBom)
    }

    # Pitfall 7: a UTF-8 BOM makes the FIRST header unparseable to `aws configure`,
    # so migrate must fail closed -- touch nothing, record NO marker.
    function New-BomConfig {
        param([string]$Dir)
        New-Item -ItemType Directory -Force -Path (Join-Path $Dir ".aws") | Out-Null
        $conf = "[profile samplecorp]`ncredential_process = pwsh -NoProfile -File /path/to/get-customer-credentials.ps1 -AccountId 333333333333 -Agent claude-code`nregion = ap-northeast-2`n`n[default]`nregion = ap-northeast-2`n"
        [IO.File]::WriteAllText((Join-Path $Dir ".aws/config"), $conf, [System.Text.UTF8Encoding]::new($true))
    }

    function New-ExpiredCache {
        param([string]$Dir, [string]$AccountId)
        $cacheDir = Join-Path $Dir ".cache/msp/customer-creds"
        New-Item -ItemType Directory -Force -Path $cacheDir | Out-Null
        $past = [DateTimeOffset]::UtcNow.AddHours(-2).ToString("yyyy-MM-ddTHH:mm:ss.000Z")
        $body = "{`"Version`":1,`"AccessKeyId`":`"ASIAEXPIRED`",`"SecretAccessKey`":`"expired`",`"SessionToken`":`"expired`",`"Expiration`":`"$past`"}"
        [IO.File]::WriteAllText((Join-Path $cacheDir "$AccountId.json"), $body, $script:Utf8NoBom)
    }

    # `.jsonl`, never `.json`: Invoke-DoCleanup's orphan-cache glob is `*.json`,
    # and deleting the marker would re-arm a destructive migration.
    function New-MigrationMarker {
        param([string]$Dir)
        $cacheDir = Join-Path $Dir ".cache/msp/customer-creds"
        New-Item -ItemType Directory -Force -Path $cacheDir | Out-Null
        [IO.File]::WriteAllText((Join-Path $cacheDir "migrations.jsonl"),
            '{"id":"v1.7-csg-namespace","completed_at":"2026-01-01T00:00:00Z","renamed":0,"repaired":0,"skipped":0}' + "`n",
            $script:Utf8NoBom)
    }

    function Get-MigrationMarkerPath {
        param([string]$Dir)
        return (Join-Path $Dir ".cache/msp/customer-creds/migrations.jsonl")
    }

    # Exact section-header match (case-sensitive, the twin of `grep -Fxq`).
    function Test-ConfigHasProfile {
        param([string]$Dir, [string]$Name)
        $path = Join-Path $Dir ".aws/config"
        if (-not (Test-Path -LiteralPath $path)) { return $false }
        foreach ($line in [IO.File]::ReadAllLines($path)) {
            if ($line.TrimEnd() -ceq "[profile $Name]") { return $true }
        }
        return $false
    }

    function Get-BakCount {
        param([string]$Dir)
        return @(Get-ChildItem -Path (Join-Path $Dir ".aws") -Filter "config.bak.*" -ErrorAction SilentlyContinue).Count
    }

    # The credential_process contract: stdout parses as JSON, carries EXACTLY the
    # 5 canonical keys, and nothing else precedes or follows it. The first-char
    # check is what catches a leaked [migrate]/[register] line.
    # STRICTER than Assert-Pure5KeyStdout: stdout must be byte-equal to the
    # compact re-serialization of its own JSON, which means NOTHING was written
    # before or after it. The client emits compact JSON through a single
    # [Console]::Out.WriteLine, so one leaked line from migrate or from the
    # register CHILD is immediately visible here -- and would break credential
    # resolution for every AWS command on that machine (T-23-37).
    function Assert-StdoutIsOnlyJson {
        param([string]$Stdout, [string]$Because)
        $text = ($Stdout -replace "`r", "").Trim("`n")
        $text.StartsWith('{') | Should -BeTrue -Because "stdout must start with '{'. $Because. stdout: [$Stdout]"
        $compact = ($text | ConvertFrom-Json | ConvertTo-Json -Compress -Depth 10)
        # Compare the PARSED shapes, not the raw text: ConvertTo-Json may reorder
        # or re-space. What must hold is that the WHOLE capture is one JSON value.
        ($text -split "`n").Count | Should -Be 1 -Because "stdout must be a single line -- extra lines mean a leaked diagnostic. $Because. stdout: [$Stdout]"
        $compact | Should -Not -BeNullOrEmpty -Because "stdout must parse as one JSON value. $Because. stdout: [$Stdout]"
    }

    function Assert-Pure5KeyStdout {
        param([string]$Stdout, [string]$Because)
        $Stdout.TrimStart()[0] | Should -Be '{' -Because "stdout must start with '{' -- a leaked diagnostic line would land first. $Because. stdout: $Stdout"
        $obj = $Stdout | ConvertFrom-Json
        $keys = ($obj.PSObject.Properties.Name | Sort-Object) -join ","
        $keys | Should -Be "AccessKeyId,Expiration,SecretAccessKey,SessionToken,Version" -Because "$Because. stdout: $Stdout"
    }

    # -- SCP-05 scope-brake fixtures (D-01/D-02/D-06/D-17) ---------------------
    # Byte-exact twins of the bash helpers in test/get-customer-credentials.test.sh
    # (scope_acct / seed_scope_window / seed_scope_ack / scope_window_lines /
    # scope_window_distinct). "Byte-exact" is the point: a record seeded by this
    # suite and one seeded by the bash suite must be indistinguishable on disk,
    # which is what makes PARITY-SCOPE-STATE's byte-diff meaningful.
    # Fixture builders are DUPLICATED per suite in this repo by convention.

    # Get-ScopeAcct -Lead 5 -N 1 -> "500000000001".
    # Blocks: 5... = window/unapproved, 6... = accounts that get acked, 9... = the
    # deliberately out-of-set account. No case hand-types a 12-digit literal: the
    # client rejects a non-12-digit -AccountId at its input gate long before the
    # brake runs, so a miscounted digit would make a case assert nothing at all
    # while still reporting PASS.
    function Get-ScopeAcct {
        param([int]$Lead, [int]$N)
        return ("{0}{1:D11}" -f $Lead, $N)
    }

    function Get-ScopeCacheDir {
        param([string]$Dir)
        $cacheDir = Join-Path $Dir ".cache/msp/customer-creds"
        New-Item -ItemType Directory -Force -Path $cacheDir | Out-Null
        return $cacheDir
    }

    # New-ScopeWindow -Dir <d> -AgeSeconds <n> -AccountIds <id...>
    # One {"ts":<now-age>,"accountId":"<id>"} line per id, i.e. exactly what
    # Write-ScopeWindowRecord writes. Ages are RELATIVE so a case can straddle the
    # 300-second cutoff without knowing the wall clock.
    # The line is built with a FORMAT STRING, never ConvertTo-Json on a hashtable:
    # key ORDER is part of the byte contract and a hashtable does not guarantee it.
    function New-ScopeWindow {
        param([string]$Dir, [int]$AgeSeconds, [string[]]$AccountIds)
        $cacheDir = Get-ScopeCacheDir -Dir $Dir
        $path = Join-Path $cacheDir "scope-window.jsonl"
        $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
        foreach ($id in $AccountIds) {
            $line = '{{"ts":{0},"accountId":"{1}"}}' -f ($now - $AgeSeconds), $id
            [IO.File]::AppendAllText($path, $line + "`n", $utf8NoBom)
        }
    }

    # New-ScopeAck -Dir <d> -TtlOffsetSeconds <n> -AccountIds <id...>
    # One {"ts":..,"expiresAt":..,"accountIds":[..],"count":N} line. A NEGATIVE
    # offset is the expired-ack fixture. The array is built by a loop + join for
    # the same reason the bash twin refuses jq: this record has to be byte-shaped
    # exactly like Invoke-DoScopeAck's own output.
    function New-ScopeAck {
        param([string]$Dir, [int]$TtlOffsetSeconds, [string[]]$AccountIds)
        $cacheDir = Get-ScopeCacheDir -Dir $Dir
        $path = Join-Path $cacheDir "scope-acks.jsonl"
        $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        $quoted = @()
        foreach ($id in $AccountIds) { $quoted += ('"' + $id + '"') }
        $line = '{{"ts":{0},"expiresAt":{1},"accountIds":[{2}],"count":{3}}}' -f `
            $now, ($now + $TtlOffsetSeconds), ($quoted -join ','), $AccountIds.Count
        [IO.File]::AppendAllText($path, $line + "`n", [System.Text.UTF8Encoding]::new($false))
    }

    # Both counters return 0 when the file is absent -- the fresh-machine path --
    # and never throw under the file-wide $ErrorActionPreference = "Stop".
    function Get-ScopeWindowLineCount {
        param([string]$Dir)
        $path = Join-Path $Dir ".cache/msp/customer-creds/scope-window.jsonl"
        if (-not (Test-Path -LiteralPath $path)) { return 0 }
        return @([IO.File]::ReadAllLines($path) | Where-Object { $_.Trim() -ne "" }).Count
    }

    function Get-ScopeWindowDistinctCount {
        param([string]$Dir)
        $path = Join-Path $Dir ".cache/msp/customer-creds/scope-window.jsonl"
        if (-not (Test-Path -LiteralPath $path)) { return 0 }
        $raw = ""
        try { $raw = [IO.File]::ReadAllText($path) } catch { return 0 }
        $found = @{}
        foreach ($m in [regex]::Matches($raw, '"accountId":"([0-9]{12})"')) {
            $found[$m.Groups[1].Value] = $true
        }
        return $found.Keys.Count
    }

    function Test-ScopeWindowHas {
        param([string]$Dir, [string]$AccountId)
        $path = Join-Path $Dir ".cache/msp/customer-creds/scope-window.jsonl"
        if (-not (Test-Path -LiteralPath $path)) { return $false }
        $raw = ""
        try { $raw = [IO.File]::ReadAllText($path) } catch { return $false }
        return $raw.Contains('"accountId":"' + $AccountId + '"')
    }

    function Get-HttpCallCount {
        param([string]$Dir)
        $path = Join-Path $Dir ".stub/http_calls"
        if (-not (Test-Path -LiteralPath $path)) { return 0 }
        return @(Get-Content -LiteralPath $path).Count
    }

    function Get-ScopeAckLineCount {
        param([string]$Dir)
        $path = Join-Path $Dir ".cache/msp/customer-creds/scope-acks.jsonl"
        if (-not (Test-Path -LiteralPath $path)) { return 0 }
        return @([IO.File]::ReadAllLines($path) | Where-Object { $_.Trim() -ne "" }).Count
    }

    # Get-ClientStateFileName -ConstantName ScopeWindowRecord -> "scope-window.jsonl"
    # The basename comes from the CLIENT'S OWN constant, never from a literal in
    # this file: a fixture that hardcoded the name would keep seeding a .jsonl file
    # after the client had been changed to .json, and the case would stay green
    # while the shipped state file became deletable by cleanup's "*.json" glob.
    # An empty extraction is a FAIL, never an implicit match.
    function Get-ClientStateFileName {
        param([string]$ConstantName)
        $pattern = '^\s*\$' + [regex]::Escape($ConstantName) + '\s*=\s*Join-Path \$CacheDir "([^"]+)"'
        foreach ($line in [IO.File]::ReadAllLines($script:ScriptUnderTest)) {
            $m = [regex]::Match($line, $pattern)
            if ($m.Success) { return $m.Groups[1].Value }
        }
        throw "Get-ClientStateFileName: no assignment line for the constant '$ConstantName' in $($script:ScriptUnderTest) -- an empty extraction is a FAIL, never an implicit match"
    }

    # Set-BrokerStatusSequence -Dir <d> -Codes 503,503,200
    # The HTTP status the stub emits on the 1st, 2nd, 3rd ... call of a SINGLE
    # invocation; the last code repeats once the sequence is exhausted. Seeds the
    # .stub/status_seq file the stub's additive branch reads.
    function Set-BrokerStatusSequence {
        param([string]$Dir, [int[]]$Codes)
        $stubDir = Join-Path $Dir ".stub"
        New-Item -ItemType Directory -Force -Path $stubDir | Out-Null
        $text = (($Codes | ForEach-Object { [string]$_ }) -join "`n") + "`n"
        [IO.File]::WriteAllText((Join-Path $stubDir "status_seq"), $text, [System.Text.UTF8Encoding]::new($false))
    }

    # The three things every scope fixture needs before it can measure the brake
    # instead of the migration: a valid Bearer, a 200 broker body, and the PROF-12
    # completion marker that short-circuits HOOK-B (the shape HOOK-B-02 uses).
    # No ~/.aws/config is seeded, so the sweep has nothing to scan and these cases
    # need no real `aws` binary -- unlike the HOOK-B/STDOUT Contexts above.
    function New-ScopeEnv {
        param([string]$Dir)
        New-Item -ItemType Directory -Path $Dir -Force | Out-Null
        New-BrokerEnv -Dir $Dir -Bearer "xoxp-test-bearer-value"
        Set-BrokerResponse -Dir $Dir -Mode "ok"
        New-MigrationMarker -Dir $Dir
    }

    # A refusal must write ZERO bytes to stdout -- the twin of the bash suite's
    # `[[ -s stdout.json ]]` check. Asserted on LENGTH rather than by piping the
    # value into Should: Get-Content -Raw returns $null for a zero-byte file, and
    # an empty string does not survive the pipeline as a distinct value, so
    # `"" | Should -Be ""` reports "but got $null" and a genuine leak would be
    # indistinguishable from the harness artefact.
    function Assert-EmptyStdout {
        param($Stdout, [string]$Because)
        $text = if ($null -eq $Stdout) { "" } else { [string]$Stdout }
        $text.Length | Should -Be 0 -Because "$Because. stdout: [$text]"
    }

    # Invoke-ScopeParallelFleet -Dir <d> -Count 12
    # Launches <Count> credential_process invocations AT ONCE against one shared
    # $Dir (they must share it -- they contend on one window file), waits for all
    # of them, and returns the tallied outcome. Extracted so SCOPE-8's two Its can
    # each take their own independent measurement rather than reasoning about one
    # shared run.
    function Invoke-ScopeParallelFleet {
        param([string]$Dir, [int]$Count = 12)

        New-ScopeEnv -Dir $Dir
        $children = @()
        for ($i = 1; $i -le $Count; $i++) {
            $children += Invoke-CredScript -TestDir $Dir `
                -Arguments @("-AccountId", (Get-ScopeAcct -Lead 5 -N $i), "-Agent", "claude-code") `
                -CloseStdin -NoWait -CaptureTag "-child$i"
        }
        foreach ($child in $children) {
            Wait-Process -InputObject $child.Process -Timeout 180 -ErrorAction SilentlyContinue
        }

        $passes = 0
        $refusals = 0
        $verdicts = @()
        $fleetLockTimeouts = 0
        $passStdout = @()
        $refuseStdout = @()
        foreach ($child in $children) {
            $rc = -1
            try { $child.Process.Refresh(); $rc = $child.Process.ExitCode } catch { $rc = -1 }
            $childOut = ""
            if (Test-Path -LiteralPath $child.StdoutFile) { $childOut = [IO.File]::ReadAllText($child.StdoutFile) }
            $childErr = ""
            if (Test-Path -LiteralPath $child.StderrFile) { $childErr = [IO.File]::ReadAllText($child.StderrFile) }
            $errTail = @(($childErr -replace "`r", "") -split "`n" | Where-Object { $_.Trim() -ne "" } | Select-Object -Last 1)
            # Include contention diagnostics even when a later refusal line is
            # the last stderr line. Otherwise CI record loss hides whether the
            # bounded lock wait expired or the exclusive lock itself failed.
            $lockTimeouts = [regex]::Matches($childErr, 'scope-lock-timeout').Count
            $fleetLockTimeouts += $lockTimeouts
            $verdicts += ("rc=" + $rc + " lock-timeouts=" + $lockTimeouts + " err=" + ($errTail -join ""))

            if ($rc -eq 0) {
                $passes++
                $passStdout += $childOut
            } elseif ($rc -eq 1 -and $childErr.Contains('[scope] reason=fan-out-threshold')) {
                $refusals++
                $refuseStdout += $childOut
            }
        }

        return @{
            Count        = $Count
            Passes       = $passes
            Refusals     = $refusals
            Verdicts     = ($verdicts -join ' | ')
            PassStdout   = $passStdout
            RefuseStdout = $refuseStdout
            Records      = (Get-ScopeWindowLineCount -Dir $Dir)
            LockTimeouts = $fleetLockTimeouts
        }
    }

    # The refusal's first token line and its last (copy-pasteable) line, as the
    # cases assert them. Blank lines are dropped before "last" is taken, mirroring
    # the bash twin's `grep -v '^[[:space:]]*$' | tail -n 1`.
    function Get-StderrLines {
        param([string]$Stderr)
        $text = if ($null -eq $Stderr) { "" } else { [string]$Stderr }
        return @(($text -replace "`r", "") -split "`n" | Where-Object { $_.Trim() -ne "" })
    }
}

Describe "get-customer-credentials.ps1 (thin Bearer HTTP credential_process)" {

    Context "case1 (CLI-01/02): success emits the 5-key contract + account-id.json cache + no assume" {

        It "emits exactly the 5-key contract, caches to the account-id.json cache, never assumes" {
            $testDir = Join-Path $TestDrive "case1-$([IO.Path]::GetRandomFileName())"
            New-Item -ItemType Directory -Path $testDir -Force | Out-Null

            New-BrokerEnv -Dir $testDir -Bearer "xoxp-test-bearer-value"
            Set-BrokerResponse -Dir $testDir -Mode "ok"

            $result = Invoke-CredScript -TestDir $testDir -Arguments @(
                "-AccountId", "111111111111", "-Agent", "claude-code"
            )

            $result.ExitCode | Should -Be 0 -Because "a valid Bearer + a 200 broker body must succeed. stderr: $($result.Stderr)"

            # stdout is valid JSON with EXACTLY the 5 canonical keys (BrokerVersion dropped).
            $obj = $result.Stdout | ConvertFrom-Json
            $keys = ($obj.PSObject.Properties.Name | Sort-Object) -join ","
            $keys | Should -Be "AccessKeyId,Expiration,SecretAccessKey,SessionToken,Version"
            $obj.Version | Should -Be 1

            # Cache written at customer-creds/<account-id>.json (NO role segment).
            $cacheDir = Join-Path $testDir ".cache/msp/customer-creds"
            (Test-Path -LiteralPath (Join-Path $cacheDir "111111111111.json")) | Should -BeTrue
            $roleSegmented = Get-ChildItem -Path $cacheDir -Filter "111111111111-*.json" -ErrorAction SilentlyContinue
            $roleSegmented | Should -BeNullOrEmpty -Because "a role-segmented <acct>-<role>.json cache must never be written"

            # No local assume-role ever happened.
            (Test-Path -LiteralPath (Join-Path $testDir ".stub/aws_assume")) | Should -BeFalse -Because "the client must perform NO local sts assume-role"
        }
    }

    Context "case2 (CLI-01): second invocation is a cache HIT (broker not called again)" {

        It "does not call the broker on the warm second run and still emits the 5-key contract" {
            $testDir = Join-Path $TestDrive "case2-$([IO.Path]::GetRandomFileName())"
            New-Item -ItemType Directory -Path $testDir -Force | Out-Null

            New-BrokerEnv -Dir $testDir -Bearer "xoxp-test-bearer-value"
            Set-BrokerResponse -Dir $testDir -Mode "ok"

            $r1 = Invoke-CredScript -TestDir $testDir -Arguments @("-AccountId", "111111111111", "-Agent", "claude-code")
            $r2 = Invoke-CredScript -TestDir $testDir -Arguments @("-AccountId", "111111111111", "-Agent", "claude-code")

            $r1.ExitCode | Should -Be 0 -Because "first run must succeed. stderr: $($r1.Stderr)"
            $r2.ExitCode | Should -Be 0 -Because "cache-hit run must succeed. stderr: $($r2.Stderr)"

            $httpCalls = Join-Path $testDir ".stub/http_calls"
            $callCount = if (Test-Path -LiteralPath $httpCalls) { (Get-Content -LiteralPath $httpCalls).Count } else { 0 }
            $callCount | Should -Be 1 -Because "the broker must be called exactly once across two runs (2nd = cache HIT)"

            $obj = $r2.Stdout | ConvertFrom-Json
            $keys = ($obj.PSObject.Properties.Name | Sort-Object) -join ","
            $keys | Should -Be "AccessKeyId,Expiration,SecretAccessKey,SessionToken,Version"
        }
    }

    Context "case3 (CLI-01/03): missing Bearer -> fast non-zero exit, no browser, no broker call" {

        It "exits non-zero, points to get-sts-token, and never calls the broker" {
            $testDir = Join-Path $TestDrive "case3-$([IO.Path]::GetRandomFileName())"
            New-Item -ItemType Directory -Path $testDir -Force | Out-Null

            New-BrokerEnv -Dir $testDir -Bearer ""      # identity-only, NO SlackAccessToken
            Set-BrokerResponse -Dir $testDir -Mode "ok" # broker would answer, but must never be reached

            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            $result = Invoke-CredScript -TestDir $testDir -Arguments @("-AccountId", "111111111111", "-Agent", "claude-code")
            $sw.Stop()

            $result.ExitCode | Should -Not -Be 0 -Because "a missing Bearer must fail (credential_process never opens a browser)"
            $result.Stderr | Should -Match 'get-sts-token' -Because "the user must be told to run get-sts-token. stderr: $($result.Stderr)"

            # No broker call / no assume on the fail-fast path.
            (Test-Path -LiteralPath (Join-Path $testDir ".stub/http_calls")) | Should -BeFalse -Because "the broker must not be called when the Bearer is missing"
            (Test-Path -LiteralPath (Join-Path $testDir ".stub/aws_assume")) | Should -BeFalse
        }
    }

    Context "case4 (RES-02): broker {""error""} body -> non-zero exit surfacing the message" {

        It "surfaces the server error, exits non-zero, and writes no cache" {
            $testDir = Join-Path $TestDrive "case4-$([IO.Path]::GetRandomFileName())"
            New-Item -ItemType Directory -Path $testDir -Force | Out-Null

            New-BrokerEnv -Dir $testDir -Bearer "xoxp-test-bearer-value"
            Set-BrokerResponse -Dir $testDir -Mode "err"

            $result = Invoke-CredScript -TestDir $testDir -Arguments @("-AccountId", "111111111111", "-Agent", "claude-code")

            $result.ExitCode | Should -Not -Be 0 -Because "a broker error body must fail closed"
            $result.Stderr | Should -Match 'not authorized' -Because "the server error message must be surfaced. stderr: $($result.Stderr)"

            # A broker error must NOT leave a cache file behind.
            $cacheFile = Join-Path $testDir ".cache/msp/customer-creds/111111111111.json"
            (Test-Path -LiteralPath $cacheFile) | Should -BeFalse -Because "no credential cache may be written on a broker error"
        }
    }

    Context "case5 (RES-02): HTTP 401 -> re-login message, no retry, no cache" {

        It "exits non-zero, names get-sts-token, calls the broker exactly once" {
            $testDir = Join-Path $TestDrive "case5-$([IO.Path]::GetRandomFileName())"
            New-Item -ItemType Directory -Path $testDir -Force | Out-Null

            New-BrokerEnv -Dir $testDir -Bearer "xoxp-test-bearer-value"
            Set-BrokerResponse -Dir $testDir -Mode "ok" -Status 401

            $result = Invoke-CredScript -TestDir $testDir -Arguments @("-AccountId", "111111111111", "-Agent", "claude-code")

            $result.ExitCode | Should -Not -Be 0 -Because "a 401 must fail (auth expired)"
            $result.Stderr | Should -Match 'get-sts-token' -Because "401 must tell the user to re-login. stderr: $($result.Stderr)"

            $httpCalls = Join-Path $testDir ".stub/http_calls"
            $callCount = if (Test-Path -LiteralPath $httpCalls) { (Get-Content -LiteralPath $httpCalls).Count } else { 0 }
            $callCount | Should -Be 1 -Because "a deterministic 401 must NEVER be retried"

            (Test-Path -LiteralPath (Join-Path $testDir ".cache/msp/customer-creds/111111111111.json")) |
                Should -BeFalse -Because "no cache may be written on a 401"
        }
    }

    Context "case6 (RES-02): HTTP 403 -> uniform not-authorized message, no retry, no cache" {

        It "exits non-zero with the uniform not-authorized message, calls the broker exactly once" {
            $testDir = Join-Path $TestDrive "case6-$([IO.Path]::GetRandomFileName())"
            New-Item -ItemType Directory -Path $testDir -Force | Out-Null

            New-BrokerEnv -Dir $testDir -Bearer "xoxp-test-bearer-value"
            Set-BrokerResponse -Dir $testDir -Mode "ok" -Status 403

            $result = Invoke-CredScript -TestDir $testDir -Arguments @("-AccountId", "111111111111", "-Agent", "claude-code")

            $result.ExitCode | Should -Not -Be 0 -Because "a 403 must fail (not authorized)"
            $result.Stderr | Should -Match '접근 권한이 없습니다' -Because "403 is a uniform not-authorized message (no enumeration). stderr: $($result.Stderr)"

            $httpCalls = Join-Path $testDir ".stub/http_calls"
            $callCount = if (Test-Path -LiteralPath $httpCalls) { (Get-Content -LiteralPath $httpCalls).Count } else { 0 }
            $callCount | Should -Be 1 -Because "a deterministic 403 must NEVER be retried"

            (Test-Path -LiteralPath (Join-Path $testDir ".cache/msp/customer-creds/111111111111.json")) |
                Should -BeFalse -Because "no cache may be written on a 403"
        }
    }

    Context "case7 (RES-02): HTTP 503 -> bounded retry then retryable failure" {

        It "retries (bounded) then fails with the retryable message, writing no cache" {
            $testDir = Join-Path $TestDrive "case7-$([IO.Path]::GetRandomFileName())"
            New-Item -ItemType Directory -Path $testDir -Force | Out-Null

            New-BrokerEnv -Dir $testDir -Bearer "xoxp-test-bearer-value"
            Set-BrokerResponse -Dir $testDir -Mode "ok" -Status 503

            $result = Invoke-CredScript -TestDir $testDir -Arguments @("-AccountId", "111111111111", "-Agent", "claude-code")

            $result.ExitCode | Should -Not -Be 0 -Because "a persistent 503 must fail after exhausting retries"
            $result.Stderr | Should -Match '잠시 후 다시 시도' -Because "503 must advise retry-shortly. stderr: $($result.Stderr)"

            $httpCalls = Join-Path $testDir ".stub/http_calls"
            $callCount = if (Test-Path -LiteralPath $httpCalls) { (Get-Content -LiteralPath $httpCalls).Count } else { 0 }
            $callCount | Should -BeGreaterThan 1 -Because "a 503 is in the retryable class"
            $callCount | Should -BeLessOrEqual 3 -Because "the retry is bounded (max 3 attempts)"

            (Test-Path -LiteralPath (Join-Path $testDir ".cache/msp/customer-creds/111111111111.json")) |
                Should -BeFalse -Because "no cache may be written on a 503"
        }
    }

    Context "case8 (RES-02): HTTP 500 -> bounded retry then generic retryable failure" {

        It "retries (bounded) then fails, writing no cache" {
            $testDir = Join-Path $TestDrive "case8-$([IO.Path]::GetRandomFileName())"
            New-Item -ItemType Directory -Path $testDir -Force | Out-Null

            New-BrokerEnv -Dir $testDir -Bearer "xoxp-test-bearer-value"
            Set-BrokerResponse -Dir $testDir -Mode "ok" -Status 500

            $result = Invoke-CredScript -TestDir $testDir -Arguments @("-AccountId", "111111111111", "-Agent", "claude-code")

            $result.ExitCode | Should -Not -Be 0 -Because "a persistent 500 must fail after exhausting retries"
            $result.Stderr | Should -Match '잠시 후 다시 시도' -Because "5xx must advise retry-shortly. stderr: $($result.Stderr)"

            $httpCalls = Join-Path $testDir ".stub/http_calls"
            $callCount = if (Test-Path -LiteralPath $httpCalls) { (Get-Content -LiteralPath $httpCalls).Count } else { 0 }
            $callCount | Should -BeGreaterThan 1 -Because "a 500 is in the retryable class"
            $callCount | Should -BeLessOrEqual 3 -Because "the retry is bounded (max 3 attempts)"
        }
    }

    # -- Phase 30 (ERR-02/03/04/05/10): twins of the bash suite's case21-case24 ---
    # Every -Match below is a REGEX. The shipped Korean sentences carry ( ) / and .
    # so each assertion anchors on the metacharacter-free substring recorded in
    # 30-02-SUMMARY rather than on the whole sentence -- an over-broad pattern
    # would pass vacuously, which is the failure mode that survives review.

    Context "case21 (RES-02): HTTP 424 -> customer-side deny message, no retry, no cache" {

        It "exits non-zero with the customer-side deny sentence, calls the broker exactly once, caches nothing" {
            $testDir = Join-Path $TestDrive "case21-$([IO.Path]::GetRandomFileName())"
            New-Item -ItemType Directory -Path $testDir -Force | Out-Null

            New-BrokerEnv -Dir $testDir -Bearer "xoxp-test-bearer-value"
            Set-BrokerResponse -Dir $testDir -Mode "ok" -Status 424

            $result = Invoke-CredScript -TestDir $testDir -Arguments @("-AccountId", "111111111111", "-Agent", "claude-code")

            $result.ExitCode | Should -Not -Be 0 -Because "a 424 must fail (the customer side refused the session)"
            $result.Stderr | Should -Match '세션을 발급할 수 없습니다' -Because "424 must surface the customer-side deny sentence. stderr: $($result.Stderr)"

            $httpCalls = Join-Path $testDir ".stub/http_calls"
            $callCount = if (Test-Path -LiteralPath $httpCalls) { (Get-Content -LiteralPath $httpCalls).Count } else { 0 }
            $callCount | Should -Be 1 -Because "a 424 is a deterministic deny and never heals by waiting -- retrying it is the exact waste ERR-02 removes"

            (Test-Path -LiteralPath (Join-Path $testDir ".cache/msp/customer-creds/111111111111.json")) |
                Should -BeFalse -Because "no cache may be written on a 424 -- a stale credential on disk is worse than a clean error"
        }
    }

    Context "#50: 4 parallel calls on one account with an empty cache make exactly one broker POST" {

        It "issues once, and every caller exits 0" {
            $testDir = Join-Path $TestDrive "singleflight-$([IO.Path]::GetRandomFileName())"
            New-ScopeEnv -Dir $testDir
            New-Item -ItemType Directory -Force -Path (Join-Path $testDir ".stub") | Out-Null
            [IO.File]::WriteAllText((Join-Path $testDir ".stub/delay"), "2000")

            $children = @()
            for ($i = 1; $i -le 4; $i++) {
                $children += Invoke-CredScript -TestDir $testDir `
                    -Arguments @("-AccountId", (Get-ScopeAcct -Lead 5 -N 1), "-Agent", "claude-code") `
                    -CloseStdin -NoWait -CaptureTag "-child$i"
            }
            foreach ($child in $children) {
                Wait-Process -InputObject $child.Process -Timeout 120 -ErrorAction SilentlyContinue
            }
            foreach ($child in $children) {
                $child.Process.Refresh()
                $child.Process.ExitCode | Should -Be 0 -Because "a waiter is served from the winner's cache. stderr: $([IO.File]::ReadAllText($child.StderrFile))"
            }
            $httpCalls = Join-Path $testDir ".stub/http_calls"
            (Get-Content -LiteralPath $httpCalls).Count | Should -Be 1 -Because "single-flight: one POST for N parallel callers"
        }
    }

    Context "#49: 429 is retried within the shared attempt budget; 424 is not" {

        It "retries 429 then succeeds on 200 (2 calls)" {
            $testDir = Join-Path $TestDrive "t429ok-$([IO.Path]::GetRandomFileName())"
            New-ScopeEnv -Dir $testDir
            Set-BrokerStatusSequence -Dir $testDir -Codes 429, 200

            $result = Invoke-CredScript -TestDir $testDir -Arguments @("-AccountId", "111111111111", "-Agent", "claude-code")

            $result.ExitCode | Should -Be 0 -Because "stderr: $($result.Stderr)"
            (Get-Content -LiteralPath (Join-Path $testDir ".stub/http_calls")).Count | Should -Be 2
        }

        It "stops after 3 calls on a persistent 429 and names the throttle" {
            $testDir = Join-Path $TestDrive "t429bad-$([IO.Path]::GetRandomFileName())"
            New-ScopeEnv -Dir $testDir
            Set-BrokerResponse -Dir $testDir -Mode "ok" -Status 429

            $result = Invoke-CredScript -TestDir $testDir -Arguments @("-AccountId", "111111111111", "-Agent", "claude-code")

            $result.ExitCode | Should -Not -Be 0
            $result.Stderr | Should -Match '429'
            (Get-Content -LiteralPath (Join-Path $testDir ".stub/http_calls")).Count | Should -Be 3
        }

        It "still calls the broker exactly once on 424" {
            $testDir = Join-Path $TestDrive "t424-$([IO.Path]::GetRandomFileName())"
            New-ScopeEnv -Dir $testDir
            Set-BrokerResponse -Dir $testDir -Mode "ok" -Status 424

            $result = Invoke-CredScript -TestDir $testDir -Arguments @("-AccountId", "111111111111", "-Agent", "claude-code")

            $result.ExitCode | Should -Not -Be 0
            (Get-Content -LiteralPath (Join-Path $testDir ".stub/http_calls")).Count | Should -Be 1
        }
    }

    Context "tiket: clientVersion is the release tag of the workspace that holds the script" {

        It "sends tiket-v9.8.7 from a repo tagged v9.8.7 and tiket-unknown outside git" {
            $testDir = Join-Path $TestDrive "tiketver-$([IO.Path]::GetRandomFileName())"
            New-Item -ItemType Directory -Path $testDir -Force | Out-Null
            New-BrokerEnv -Dir $testDir -Bearer "xoxp-test-bearer-value"
            Set-BrokerResponse -Dir $testDir -Mode "ok"

            # The tag is fixed here, not read the way the script reads it, so the case
            # cannot pass by comparing the implementation with itself.
            $repo = Join-Path $testDir "repo"
            $skill = Join-Path $repo "skills/aws-customer-account-ops"
            New-Item -ItemType Directory -Force -Path $skill | Out-Null
            $tagged = Join-Path $skill "get-customer-credentials.ps1"
            Copy-Item -LiteralPath $script:ScriptUnderTest -Destination $tagged
            & git -C $repo init -q
            & git -C $repo -c user.name=t -c user.email=t@example.invalid add -A
            & git -C $repo -c user.name=t -c user.email=t@example.invalid commit -q -m init
            & git -C $repo tag v9.8.7

            $result = Invoke-CredScript -TestDir $testDir -ScriptPath $tagged -Arguments @("-AccountId", "111111111111", "-Agent", "claude-code")
            $result.ExitCode | Should -Be 0 -Because "stderr: $($result.Stderr)"
            Get-BrokerClientVersion -Dir $testDir | Should -Be "tiket-v9.8.7"

            $loose = Join-Path $testDir "loose"
            New-Item -ItemType Directory -Force -Path $loose | Out-Null
            $untracked = Join-Path $loose "get-customer-credentials.ps1"
            Copy-Item -LiteralPath $script:ScriptUnderTest -Destination $untracked
            Remove-Item -Recurse -Force -LiteralPath (Join-Path $testDir ".cache/msp/customer-creds") -ErrorAction SilentlyContinue
            Remove-Item -Force -LiteralPath (Join-Path $testDir ".stub/last_body.json") -ErrorAction SilentlyContinue

            $result = Invoke-CredScript -TestDir $testDir -ScriptPath $untracked -Arguments @("-AccountId", "111111111111", "-Agent", "claude-code") `
                -EnvVars @{ GIT_CEILING_DIRECTORIES = $testDir }
            $result.ExitCode | Should -Be 0 -Because "a missing tag must never fail issuance. stderr: $($result.Stderr)"
            Get-BrokerClientVersion -Dir $testDir | Should -Be "tiket-unknown"
        }
    }

    Context "tiket: HTTP 426 -> update-the-workspace message, no retry, no cache" {

        It "exits non-zero with the update sentence, calls the broker exactly once, caches nothing" {
            $testDir = Join-Path $TestDrive "case426-$([IO.Path]::GetRandomFileName())"
            New-Item -ItemType Directory -Path $testDir -Force | Out-Null
            New-BrokerEnv -Dir $testDir -Bearer "xoxp-test-bearer-value"
            Set-BrokerResponse -Dir $testDir -Mode "ok" -Status 426

            $result = Invoke-CredScript -TestDir $testDir -Arguments @("-AccountId", "111111111111", "-Agent", "claude-code")

            $result.ExitCode | Should -Not -Be 0
            $result.Stderr | Should -Match 'tiket 워크스페이스가 오래돼' -Because "stderr: $($result.Stderr)"
            $httpCalls = Join-Path $testDir ".stub/http_calls"
            $callCount = if (Test-Path -LiteralPath $httpCalls) { (Get-Content -LiteralPath $httpCalls).Count } else { 0 }
            $callCount | Should -Be 1 -Because "waiting never upgrades the workspace"
            (Test-Path -LiteralPath (Join-Path $testDir ".cache/msp/customer-creds/111111111111.json")) | Should -BeFalse
        }
    }

    Context "case22 (RES-02): HTTP 418 (unmapped status) -> fail closed, no retry, no cache, no stdout" {

        It "fails closed on a status the map does not name, minting nothing" {
            $testDir = Join-Path $TestDrive "case22-$([IO.Path]::GetRandomFileName())"
            New-Item -ItemType Directory -Path $testDir -Force | Out-Null

            New-BrokerEnv -Dir $testDir -Bearer "xoxp-test-bearer-value"
            Set-BrokerResponse -Dir $testDir -Mode "ok" -Status 418

            $result = Invoke-CredScript -TestDir $testDir -Arguments @("-AccountId", "111111111111", "-Agent", "claude-code")

            $result.ExitCode | Should -Not -Be 0 -Because "an unmapped status must stop, not fall through"
            $result.Stderr | Should -Match '브로커 호출 실패' -Because "the unmapped-status fallback wording is frozen (D-11). stderr: $($result.Stderr)"

            $httpCalls = Join-Path $testDir ".stub/http_calls"
            $callCount = if (Test-Path -LiteralPath $httpCalls) { (Get-Content -LiteralPath $httpCalls).Count } else { 0 }
            $callCount | Should -Be 1 -Because "an unmapped status is not in the retryable class"

            (Test-Path -LiteralPath (Join-Path $testDir ".cache/msp/customer-creds/111111111111.json")) |
                Should -BeFalse -Because "an unmapped status must not write a credential cache"

            # A client that printed a partial credential JSON before dying would
            # satisfy every assertion above while still minting a usable credential.
            Assert-EmptyStdout -Stdout $result.Stdout -Because "an unmapped status must write ZERO bytes to the credential_process channel"
        }
    }

    Context "case23 (RES-02): transport failure -> exactly 3 requests + non-empty diagnostic" {

        It "spends the single shared retry budget exactly once and prints the sanitized transport diagnosis" {
            $testDir = Join-Path $TestDrive "case23-$([IO.Path]::GetRandomFileName())"
            New-Item -ItemType Directory -Path $testDir -Force | Out-Null

            New-BrokerEnv -Dir $testDir -Bearer "xoxp-test-bearer-value"
            # -Status 0 makes the shadowed Invoke-WebRequest throw with no .Response,
            # so the client maps it to StatusCode 0 -- the twin of the bash 000 seed.
            Set-BrokerResponse -Dir $testDir -Mode "ok" -Status 0

            $result = Invoke-CredScript -TestDir $testDir -Arguments @("-AccountId", "111111111111", "-Agent", "claude-code")

            $result.ExitCode | Should -Not -Be 0 -Because "a persistent transport failure must fail after exhausting retries"
            $result.Stderr | Should -Match '브로커에 연결할 수 없습니다' -Because "transport failure gets its own message, distinct from a bad HTTP answer. stderr: $($result.Stderr)"

            $httpCalls = Join-Path $testDir ".stub/http_calls"
            $callCount = if (Test-Path -LiteralPath $httpCalls) { (Get-Content -LiteralPath $httpCalls).Count } else { 0 }
            $callCount | Should -Be 3 -Because "EXACTLY the shared budget: 6 would mean the transport arm split off 5xx took its own counter with it (case7/case8's >1 && <=3 bound would not catch that). stderr: $($result.Stderr)"

            # Marker present AND at least one character inside the quoted tail: a
            # tail that renders empty means the exception message was read wrong or
            # the sanitizer swallowed it, and matching the marker alone hides that.
            $result.Stderr | Should -Match "진단: '[^']" -Because "the transport diagnosis must actually arrive, not just its label. stderr: $($result.Stderr)"
        }
    }

    Context "case24 (ERR-10): the broker POST body carries a semver-shaped clientVersion" {

        It "sends clientVersion alongside an unchanged agent" {
            $testDir = Join-Path $TestDrive "case24-$([IO.Path]::GetRandomFileName())"
            New-Item -ItemType Directory -Path $testDir -Force | Out-Null

            New-BrokerEnv -Dir $testDir -Bearer "xoxp-test-bearer-value"
            Set-BrokerResponse -Dir $testDir -Mode "ok"

            $result = Invoke-CredScript -TestDir $testDir -Arguments @("-AccountId", "111111111111", "-Agent", "claude-code")

            $result.ExitCode | Should -Be 0 -Because "a valid Bearer + a 200 broker body must succeed. stderr: $($result.Stderr)"

            # The VALUE is not pinned: install.sh stamps it at pack/install time and
            # the repo literal drifts by design. Shape + presence is the contract.
            $sent = Get-BrokerClientVersion -Dir $testDir
            $sent | Should -Not -BeNullOrEmpty -Because "the spread-observation field must be on the wire, or the broker's version distribution stays flat"
            # tiket (0040, 2026-10-20): the value is the tiket release tag, or tiket-unknown in a
            # shallow clone. The exact value is pinned by the tiket-version Context below.
            $sent | Should -Match '^tiket-(v\d+\.\d+\.\d+|unknown)$' -Because "clientVersion must be tiket-vX.Y.Z or tiket-unknown. sent: [$sent]"

            # Re-read agent from the SAME captured body: a body capture that
            # regressed to an empty file would fail both reads rather than let the
            # clientVersion assertion pass vacuously.
            Get-BrokerAgent -Dir $testDir | Should -Be "claude-code" -Because "the third field must be ADDED to the body, not swapped in for an existing one"
        }
    }

    Context "case9 (T-19-05-01): the Bearer never appears in stderr on any path" {

        It "keeps the Bearer out of stderr across success, 403-deny, and 500-retry paths" {
            $testDir = Join-Path $TestDrive "case9-$([IO.Path]::GetRandomFileName())"
            New-Item -ItemType Directory -Path $testDir -Force | Out-Null

            $secret = "xoxp-super-secret-bearer-do-not-leak"
            New-BrokerEnv -Dir $testDir -Bearer $secret

            # success path (fresh account 111...), then 403-deny (222...), then 500-retry (333...)
            Set-BrokerResponse -Dir $testDir -Mode "ok" -Status 200
            $r1 = Invoke-CredScript -TestDir $testDir -Arguments @("-AccountId", "111111111111", "-Agent", "claude-code")
            Set-BrokerResponse -Dir $testDir -Mode "ok" -Status 403
            $r2 = Invoke-CredScript -TestDir $testDir -Arguments @("-AccountId", "222222222222", "-Agent", "claude-code")
            Set-BrokerResponse -Dir $testDir -Mode "ok" -Status 500
            $r3 = Invoke-CredScript -TestDir $testDir -Arguments @("-AccountId", "333333333333", "-Agent", "claude-code")

            $allStderr = "$($r1.Stderr)`n$($r2.Stderr)`n$($r3.Stderr)"
            $allStderr | Should -Not -Match ([regex]::Escape($secret)) -Because "the Bearer is credential-equivalent and must never reach a log/stderr line"
        }
    }

    # case25 (CR-01): the twin of run_case25 in get-customer-credentials.test.sh.
    # The bash side's WR-01 case has no PowerShell counterpart on purpose -- this
    # client passes the header in-process to Invoke-WebRequest, so there is no child
    # process and therefore no argv to inspect. CR-01, by contrast, is present on
    # BOTH clients: a 2xx body that fails the 5-key projection used to be serialised
    # straight back into the terminal, the AI agent transcript and any CI log.
    Context "case25 (CR-01): a 2xx body missing Expiration leaks no credential material" {

        It "fails closed, writes no cache, and names the absent field without echoing the body" {
            $testDir = Join-Path $TestDrive "case25-$([IO.Path]::GetRandomFileName())"
            New-Item -ItemType Directory -Path $testDir -Force | Out-Null

            New-BrokerEnv -Dir $testDir -Bearer "xoxp-test-bearer-value"
            Set-BrokerResponse -Dir $testDir -Mode "creds-no-exp" -Status 200

            $result = Invoke-CredScript -TestDir $testDir -Arguments @("-AccountId", "111111111111", "-Agent", "claude-code")

            $result.ExitCode | Should -Not -Be 0 -Because "a body with no usable Expiration must fail closed, not mint a half-formed credential"
            "$($result.Stdout)`n$($result.Stderr)" | Should -Not -Match ([regex]::Escape('LEAKCANARY')) -Because "the broker body is untrusted input and these three values are live customer credentials"
            $cacheFile = Join-Path $testDir ".cache/msp/customer-creds/111111111111.json"
            Test-Path -LiteralPath $cacheFile | Should -Be $false -Because "a rejected body must leave no cache entry behind"
            $result.Stderr | Should -Match 'Expiration' -Because "the message must say WHICH contract field was absent, or the fix degrades into silence"
        }
    }

    # -- Agent-resolution priority (runtime agent detection; agent-misattribution fix) --
    # Proves Resolve-Agent's 5-level priority (first hit wins): explicit -Agent >
    # $env:MSP_AGENT > $env:AI_AGENT (leading token, validated) > $env:CLAUDECODE >
    # install path. Each case pins the OTHER, lower-priority signals too, so the
    # assertion proves the winner beat them -- not merely that it was the only signal.

    Context "case10 (AGENT-PRIO 1): explicit -Agent wins over every runtime-env signal" {

        It "sends the -Agent value even when MSP_AGENT/AI_AGENT/CLAUDECODE are all set" {
            $testDir = Join-Path $TestDrive "case10-$([IO.Path]::GetRandomFileName())"
            New-Item -ItemType Directory -Path $testDir -Force | Out-Null

            New-BrokerEnv -Dir $testDir -Bearer "xoxp-test-bearer-value"
            Set-BrokerResponse -Dir $testDir -Mode "ok"

            $result = Invoke-CredScript -TestDir $testDir `
                -EnvVars @{ MSP_AGENT = "env-override"; AI_AGENT = "kiro_9-9_agent"; CLAUDECODE = "1" } `
                -Arguments @("-AccountId", "111111111111", "-Agent", "foo")

            $result.ExitCode | Should -Be 0 -Because "a valid Bearer + 200 body must succeed. stderr: $($result.Stderr)"
            (Get-BrokerAgent -Dir $testDir) | Should -Be "foo" -Because "an explicit -Agent overrides all runtime-env signals"
        }
    }

    Context "case11 (AGENT-PRIO 2): MSP_AGENT wins over AI_AGENT/CLAUDECODE when -Agent absent" {

        It "sends MSP_AGENT when no -Agent is passed" {
            $testDir = Join-Path $TestDrive "case11-$([IO.Path]::GetRandomFileName())"
            New-Item -ItemType Directory -Path $testDir -Force | Out-Null

            New-BrokerEnv -Dir $testDir -Bearer "xoxp-test-bearer-value"
            Set-BrokerResponse -Dir $testDir -Mode "ok"

            $result = Invoke-CredScript -TestDir $testDir `
                -EnvVars @{ MSP_AGENT = "bar"; AI_AGENT = "kiro_9-9_agent"; CLAUDECODE = "1" } `
                -Arguments @("-AccountId", "111111111111")

            $result.ExitCode | Should -Be 0 -Because "success expected. stderr: $($result.Stderr)"
            (Get-BrokerAgent -Dir $testDir) | Should -Be "bar" -Because "MSP_AGENT is the explicit session override"
        }
    }

    Context "case12 (AGENT-PRIO 3): AI_AGENT leading token wins over CLAUDECODE" {

        It "extracts the leading token before the first underscore, lowercased" {
            $testDir = Join-Path $TestDrive "case12-$([IO.Path]::GetRandomFileName())"
            New-Item -ItemType Directory -Path $testDir -Force | Out-Null

            New-BrokerEnv -Dir $testDir -Bearer "xoxp-test-bearer-value"
            Set-BrokerResponse -Dir $testDir -Mode "ok"

            $result = Invoke-CredScript -TestDir $testDir `
                -EnvVars @{ AI_AGENT = "kiro_9-9_agent"; CLAUDECODE = "1" } `
                -Arguments @("-AccountId", "111111111111")

            $result.ExitCode | Should -Be 0 -Because "success expected. stderr: $($result.Stderr)"
            (Get-BrokerAgent -Dir $testDir) | Should -Be "kiro" -Because "AI_AGENT='kiro_9-9_agent' resolves to 'kiro' and beats CLAUDECODE"
        }
    }

    Context "case13 (AGENT-PRIO 4): CLAUDECODE -> claude-code when no higher signal is set" {

        It "resolves to claude-code from CLAUDECODE alone" {
            $testDir = Join-Path $TestDrive "case13-$([IO.Path]::GetRandomFileName())"
            New-Item -ItemType Directory -Path $testDir -Force | Out-Null

            New-BrokerEnv -Dir $testDir -Bearer "xoxp-test-bearer-value"
            Set-BrokerResponse -Dir $testDir -Mode "ok"

            $result = Invoke-CredScript -TestDir $testDir `
                -EnvVars @{ CLAUDECODE = "1" } `
                -Arguments @("-AccountId", "111111111111")

            $result.ExitCode | Should -Be 0 -Because "success expected. stderr: $($result.Stderr)"
            (Get-BrokerAgent -Dir $testDir) | Should -Be "claude-code" -Because "CLAUDECODE=1 identifies Claude Code"
        }
    }

    Context "case14 (AGENT-PRIO 7): no env signal -> install-path fallback (UNCHANGED)" {

        It "maps a .kiro install path to 'kiro' when no runtime signal is present" {
            $testDir = Join-Path $TestDrive "case14-$([IO.Path]::GetRandomFileName())"
            New-Item -ItemType Directory -Path $testDir -Force | Out-Null

            New-BrokerEnv -Dir $testDir -Bearer "xoxp-test-bearer-value"
            Set-BrokerResponse -Dir $testDir -Mode "ok"

            # Install a copy under a .kiro/... path so Resolve-AgentFromPath -> 'kiro'.
            $kiroDir = Join-Path $testDir ".kiro/skills/aws-customer-account-ops"
            New-Item -ItemType Directory -Force -Path $kiroDir | Out-Null
            $kiroScript = Join-Path $kiroDir "get-customer-credentials.ps1"
            Copy-Item -LiteralPath $script:ScriptUnderTest -Destination $kiroScript

            $result = Invoke-CredScript -TestDir $testDir `
                -ScriptPath $kiroScript `
                -Arguments @("-AccountId", "111111111111")

            $result.ExitCode | Should -Be 0 -Because "success expected. stderr: $($result.Stderr)"
            (Get-BrokerAgent -Dir $testDir) | Should -Be "kiro" -Because "with no runtime env signal, the frozen install-path mapping still resolves"
        }
    }

    Context "case15 (AGENT-PRIO 3b): a malformed AI_AGENT is ignored and falls through" {

        It "ignores an AI_AGENT that fails the charset check and falls through to CLAUDECODE" {
            $testDir = Join-Path $TestDrive "case15-$([IO.Path]::GetRandomFileName())"
            New-Item -ItemType Directory -Path $testDir -Force | Out-Null

            New-BrokerEnv -Dir $testDir -Bearer "xoxp-test-bearer-value"
            Set-BrokerResponse -Dir $testDir -Mode "ok"

            $result = Invoke-CredScript -TestDir $testDir `
                -EnvVars @{ AI_AGENT = "Not A Valid Agent Name!"; CLAUDECODE = "1" } `
                -Arguments @("-AccountId", "111111111111")

            $result.ExitCode | Should -Be 0 -Because "success expected. stderr: $($result.Stderr)"
            (Get-BrokerAgent -Dir $testDir) | Should -Be "claude-code" -Because "a malformed AI_AGENT must be ignored (used only if it matches the charset)"
        }
    }

    # -- VSCode-fork agent detection (TERM_PROGRAM / __CFBundleIdentifier, KNOWN-gated) --
    # Kiro (and other VSCode forks) inject NO custom AI_AGENT/KIRO_* var; the only
    # reliable runtime signals are TERM_PROGRAM=kiro and (macOS) $env:__CFBundleIdentifier=
    # dev.kiro.desktop. These layers sit AFTER CLAUDECODE and BEFORE the path fallback,
    # gated by the 9-id KNOWN-AGENT set so a generic terminal never mis-maps.

    Context "case16 (AGENT-PRIO 5): TERM_PROGRAM=kiro -> 'kiro'" {

        It "resolves 'kiro' from TERM_PROGRAM when no higher signal is set" {
            $testDir = Join-Path $TestDrive "case16-$([IO.Path]::GetRandomFileName())"
            New-Item -ItemType Directory -Path $testDir -Force | Out-Null

            New-BrokerEnv -Dir $testDir -Bearer "xoxp-test-bearer-value"
            Set-BrokerResponse -Dir $testDir -Mode "ok"

            $result = Invoke-CredScript -TestDir $testDir `
                -EnvVars @{ TERM_PROGRAM = "kiro" } `
                -Arguments @("-AccountId", "111111111111")

            $result.ExitCode | Should -Be 0 -Because "success expected. stderr: $($result.Stderr)"
            (Get-BrokerAgent -Dir $testDir) | Should -Be "kiro" -Because "TERM_PROGRAM=kiro is a KNOWN CSG agent id"
        }
    }

    Context "case17 (AGENT-PRIO 5b): TERM_PROGRAM=vscode ignored -> install-path fallback (NOT 'vscode')" {

        It "ignores a non-agent TERM_PROGRAM and falls through to the path mapping" {
            $testDir = Join-Path $TestDrive "case17-$([IO.Path]::GetRandomFileName())"
            New-Item -ItemType Directory -Path $testDir -Force | Out-Null

            New-BrokerEnv -Dir $testDir -Bearer "xoxp-test-bearer-value"
            Set-BrokerResponse -Dir $testDir -Mode "ok"

            # Install a copy under a .cursor/ path so Resolve-AgentFromPath -> 'cursor';
            # asserting 'cursor' proves TERM_PROGRAM's 'vscode' was never used.
            $cursorDir = Join-Path $testDir ".cursor/skills/aws-customer-account-ops"
            New-Item -ItemType Directory -Force -Path $cursorDir | Out-Null
            $cursorScript = Join-Path $cursorDir "get-customer-credentials.ps1"
            Copy-Item -LiteralPath $script:ScriptUnderTest -Destination $cursorScript

            $result = Invoke-CredScript -TestDir $testDir `
                -ScriptPath $cursorScript `
                -EnvVars @{ TERM_PROGRAM = "vscode" } `
                -Arguments @("-AccountId", "111111111111")

            $result.ExitCode | Should -Be 0 -Because "success expected. stderr: $($result.Stderr)"
            (Get-BrokerAgent -Dir $testDir) | Should -Be "cursor" -Because "TERM_PROGRAM=vscode is not a CSG agent id, so it must fall through to path detection (never 'vscode')"
        }
    }

    Context "case18 (AGENT-PRIO 6): __CFBundleIdentifier=dev.kiro.desktop -> 'kiro'" {

        It "resolves 'kiro' from the macOS bundle id when TERM_PROGRAM is unset" {
            $testDir = Join-Path $TestDrive "case18-$([IO.Path]::GetRandomFileName())"
            New-Item -ItemType Directory -Path $testDir -Force | Out-Null

            New-BrokerEnv -Dir $testDir -Bearer "xoxp-test-bearer-value"
            Set-BrokerResponse -Dir $testDir -Mode "ok"

            $result = Invoke-CredScript -TestDir $testDir `
                -EnvVars @{ __CFBundleIdentifier = "dev.kiro.desktop" } `
                -Arguments @("-AccountId", "111111111111")

            $result.ExitCode | Should -Be 0 -Because "success expected. stderr: $($result.Stderr)"
            (Get-BrokerAgent -Dir $testDir) | Should -Be "kiro" -Because "dev.kiro.desktop extracts the KNOWN agent id 'kiro'"
        }
    }

    Context "case19 (AGENT-PRIO 6b): __CFBundleIdentifier=com.apple.Terminal ignored -> install-path fallback" {

        It "ignores a non-dev.<known>.desktop bundle id and falls through to the path mapping" {
            $testDir = Join-Path $TestDrive "case19-$([IO.Path]::GetRandomFileName())"
            New-Item -ItemType Directory -Path $testDir -Force | Out-Null

            New-BrokerEnv -Dir $testDir -Bearer "xoxp-test-bearer-value"
            Set-BrokerResponse -Dir $testDir -Mode "ok"

            $cursorDir = Join-Path $testDir ".cursor/skills/aws-customer-account-ops"
            New-Item -ItemType Directory -Force -Path $cursorDir | Out-Null
            $cursorScript = Join-Path $cursorDir "get-customer-credentials.ps1"
            Copy-Item -LiteralPath $script:ScriptUnderTest -Destination $cursorScript

            $result = Invoke-CredScript -TestDir $testDir `
                -ScriptPath $cursorScript `
                -EnvVars @{ __CFBundleIdentifier = "com.apple.Terminal" } `
                -Arguments @("-AccountId", "111111111111")

            $result.ExitCode | Should -Be 0 -Because "success expected. stderr: $($result.Stderr)"
            (Get-BrokerAgent -Dir $testDir) | Should -Be "cursor" -Because "com.apple.Terminal does not match dev.<known>.desktop/.app, so it must fall through to path detection"
        }
    }

    Context "case20 (AGENT-PRIO 4>5): CLAUDECODE + TERM_PROGRAM=kiro -> 'claude-code' (CLAUDECODE wins)" {

        It "keeps CLAUDECODE ahead of TERM_PROGRAM (layer 4 before layer 5)" {
            $testDir = Join-Path $TestDrive "case20-$([IO.Path]::GetRandomFileName())"
            New-Item -ItemType Directory -Path $testDir -Force | Out-Null

            New-BrokerEnv -Dir $testDir -Bearer "xoxp-test-bearer-value"
            Set-BrokerResponse -Dir $testDir -Mode "ok"

            $result = Invoke-CredScript -TestDir $testDir `
                -EnvVars @{ CLAUDECODE = "1"; TERM_PROGRAM = "kiro" } `
                -Arguments @("-AccountId", "111111111111")

            $result.ExitCode | Should -Be 0 -Because "success expected. stderr: $($result.Stderr)"
            (Get-BrokerAgent -Dir $testDir) | Should -Be "claude-code" -Because "CLAUDECODE (layer 4) must win over TERM_PROGRAM (layer 5)"
        }
    }

    # =========================================================================
    # HOOK-B -- the credential_process main flow fires the fleet migration
    # =========================================================================
    # PowerShell twin of run_hook_b1..b4 in the bash suite. `Invoke-SelfUpdate`
    # replaces skill FILES and never re-runs the installer, so a migration hosted
    # only in the installer reaches ~0 already-deployed machines; the everyday
    # credential_process path is where they actually converge.

    Context "HOOK-B-01: an ordinary credential_process call fires the migration" {

        It "records the completion marker and migrates the legacy profile" {
            if (-not (Test-RealAwsPresent)) { Set-ItResult -Skipped -Because "the real 'aws' CLI is not installed"; return }

            $testDir = Join-Path $TestDrive "hookb1-$([IO.Path]::GetRandomFileName())"
            New-Item -ItemType Directory -Path $testDir -Force | Out-Null

            New-BrokerEnv -Dir $testDir -Bearer "xoxp-test-bearer-value"
            Set-BrokerResponse -Dir $testDir -Mode "ok"
            New-LegacyConfig -Dir $testDir

            $result = Invoke-CredScript -TestDir $testDir -Arguments @("-AccountId", "111111111111", "-Agent", "claude-code")

            $result.ExitCode | Should -Be 0 -Because "success expected. stderr: $($result.Stderr)"

            $marker = Get-MigrationMarkerPath -Dir $testDir
            (Test-Path -LiteralPath $marker) | Should -BeTrue -Because "no migrations.jsonl means the hook never fired. stderr: $($result.Stderr)"
            (Get-Content -Raw -LiteralPath $marker) | Should -Match ([regex]::Escape('"id":"v1.7-csg-namespace"'))

            (Test-ConfigHasProfile -Dir $testDir -Name "csg-samplecorp") | Should -BeTrue -Because "the legacy profile must have been migrated. config: $(Get-Content -Raw -LiteralPath (Join-Path $testDir '.aws/config'))"
            Assert-Pure5KeyStdout -Stdout $result.Stdout -Because "the hook must not pollute the credential channel"
        }
    }

    Context "HOOK-B-02: an already-migrated machine short-circuits" {

        It "leaves the config byte-identical and creates no new .bak" {
            if (-not (Test-RealAwsPresent)) { Set-ItResult -Skipped -Because "the real 'aws' CLI is not installed"; return }

            $testDir = Join-Path $TestDrive "hookb2-$([IO.Path]::GetRandomFileName())"
            New-Item -ItemType Directory -Path $testDir -Force | Out-Null

            New-BrokerEnv -Dir $testDir -Bearer "xoxp-test-bearer-value"
            Set-BrokerResponse -Dir $testDir -Mode "ok"
            New-LegacyConfig -Dir $testDir
            New-MigrationMarker -Dir $testDir

            $configPath = Join-Path $testDir ".aws/config"
            $before = [IO.File]::ReadAllBytes($configPath)
            $baksBefore = Get-BakCount -Dir $testDir

            $result = Invoke-CredScript -TestDir $testDir -Arguments @("-AccountId", "111111111111", "-Agent", "claude-code")

            $result.ExitCode | Should -Be 0 -Because "success expected. stderr: $($result.Stderr)"

            $after = [IO.File]::ReadAllBytes($configPath)
            [Convert]::ToBase64String($after) | Should -Be ([Convert]::ToBase64String($before)) -Because "the config must not be rewritten once the completion marker exists"
            (Get-BakCount -Dir $testDir) | Should -Be $baksBefore -Because "a short-circuited hook must not create a backup"
            (Test-ConfigHasProfile -Dir $testDir -Name "csg-samplecorp") | Should -BeFalse -Because "the migration must not run again"
            Assert-Pure5KeyStdout -Stdout $result.Stdout -Because "the short-circuit path must still emit clean credentials"
        }
    }

    Context "HOOK-B-03: the ordering contract -- sweep runs BEFORE migrate" {

        It "keeps every rename the mapping table claims, and never renames a profile the sweep should have taken" {
            if (-not (Test-RealAwsPresent)) { Set-ItResult -Skipped -Because "the real 'aws' CLI is not installed"; return }

            $testDir = Join-Path $TestDrive "hookb3-$([IO.Path]::GetRandomFileName())"
            New-Item -ItemType Directory -Path $testDir -Force | Out-Null

            New-BrokerEnv -Dir $testDir -Bearer "xoxp-test-bearer-value"
            Set-BrokerResponse -Dir $testDir -Mode "ok"
            New-LegacyConfig -Dir $testDir
            New-ExpiredCache -Dir $testDir -AccountId "222222222222"   # stale-cust is sweep bait

            $result = Invoke-CredScript -TestDir $testDir -Arguments @("-AccountId", "111111111111", "-Agent", "claude-code")

            $result.ExitCode | Should -Be 0 -Because "success expected. stderr: $($result.Stderr)"
            $result.Stderr | Should -Match ([regex]::Escape('[sweep] removed')) -Because "the sweep must have gone first. stderr: $($result.Stderr)"

            (Test-ConfigHasProfile -Dir $testDir -Name "stale-cust") | Should -BeFalse -Because "the expired legacy profile must be swept"
            # migrate-first would have renamed it and the sweep would then have
            # deleted the freshly created section.
            (Test-ConfigHasProfile -Dir $testDir -Name "csg-stale-cust") | Should -BeFalse -Because "migrate must never see a profile the sweep is about to remove"

            # Every mapping line's target must still exist -- no rename may be
            # claimed and lost.
            $arrow = [char]0x2192
            $claimed = 0
            foreach ($line in ($result.Stderr -split "`r?`n")) {
                if ($line -match "^\[migrate\] .+ $arrow (csg-\S+)$") {
                    $claimed++
                    (Test-ConfigHasProfile -Dir $testDir -Name $Matches[1]) | Should -BeTrue -Because "stderr claims '$($Matches[1])' but no such section exists (migrate ran before the sweep?)"
                }
            }
            $claimed | Should -BeGreaterThan 0 -Because "at least one rename must have been claimed. stderr: $($result.Stderr)"
            (Test-ConfigHasProfile -Dir $testDir -Name "csg-samplecorp") | Should -BeTrue -Because "the never-cached legacy profile must be migrated"
            Assert-Pure5KeyStdout -Stdout $result.Stdout -Because "the ordering run must still emit clean credentials"
        }
    }

    Context "HOOK-B-04: a fail-closed migration does not break credential resolution" {

        It "still resolves credentials, reports the reason token, and records no marker" {
            if (-not (Test-RealAwsPresent)) { Set-ItResult -Skipped -Because "the real 'aws' CLI is not installed"; return }

            $testDir = Join-Path $TestDrive "hookb4-$([IO.Path]::GetRandomFileName())"
            New-Item -ItemType Directory -Path $testDir -Force | Out-Null

            New-BrokerEnv -Dir $testDir -Bearer "xoxp-test-bearer-value"
            Set-BrokerResponse -Dir $testDir -Mode "ok"
            New-BomConfig -Dir $testDir      # unparseable to `aws configure`

            $result = Invoke-CredScript -TestDir $testDir -Arguments @("-AccountId", "111111111111", "-Agent", "claude-code")

            $result.ExitCode | Should -Be 0 -Because "a migration failure must never be fatal. stderr: $($result.Stderr)"
            Assert-Pure5KeyStdout -Stdout $result.Stdout -Because "the fail-closed path must still emit clean credentials"
            $result.Stderr | Should -Match ([regex]::Escape('[migrate] reason=config-unparseable')) -Because "migrate must fail closed on an unreadable config. stderr: $($result.Stderr)"
            (Test-Path -LiteralPath (Get-MigrationMarkerPath -Dir $testDir)) | Should -BeFalse -Because "the fail-closed path must record NO completion marker (Pitfall 7)"
        }
    }

    # =========================================================================
    # STDOUT-0* -- the 5-key contract survives a hook-fired run (T-23-37)
    # =========================================================================
    # 23-RESEARCH flags this as the highest-value case class: `migrate` can be
    # perfect when driven as a SUBCOMMAND (test/fleet-migrate.test.ps1 proves
    # that) while the auto-hook still corrupts credential resolution, because
    # the hook runs on a path whose stdout is a machine-readable contract.
    # These cases drive the REAL main flow, not the `migrate` subcommand.

    Context "STDOUT-01: a hook-fired call on the incident machine emits ONLY the 5-key JSON" {

        It "migrates every class and still emits nothing but the credential JSON" {
            if (-not (Test-RealAwsPresent)) { Set-ItResult -Skipped -Because "the real 'aws' CLI is not installed"; return }

            $testDir = Join-Path $TestDrive "stdout1-$([IO.Path]::GetRandomFileName())"
            New-Item -ItemType Directory -Path $testDir -Force | Out-Null

            New-BrokerEnv -Dir $testDir -Bearer "xoxp-test-bearer-value"
            Set-BrokerResponse -Dir $testDir -Mode "ok"
            New-IncidentConfig -Dir $testDir

            $result = Invoke-CredScript -TestDir $testDir -Arguments @("-AccountId", "111111111111", "-Agent", "claude-code")

            $result.ExitCode | Should -Be 0 -Because "success expected. stderr: $($result.Stderr)"
            # The hook must actually have fired, or this proves nothing.
            (Test-Path -LiteralPath (Get-MigrationMarkerPath -Dir $testDir)) | Should -BeTrue -Because "the migration never ran, so stdout purity was not exercised. stderr: $($result.Stderr)"

            Assert-StdoutIsOnlyJson -Stdout $result.Stdout -Because "a hook-fired run must not pollute the credential channel"
            Assert-Pure5KeyStdout -Stdout $result.Stdout -Because "a hook-fired run must still emit the 5-key contract"
        }
    }

    Context "STDOUT-02: the summary is stderr-only (D-02)" {

        It "puts the [migrate] mapping table on stderr and never on stdout" {
            if (-not (Test-RealAwsPresent)) { Set-ItResult -Skipped -Because "the real 'aws' CLI is not installed"; return }

            $testDir = Join-Path $TestDrive "stdout2-$([IO.Path]::GetRandomFileName())"
            New-Item -ItemType Directory -Path $testDir -Force | Out-Null

            New-BrokerEnv -Dir $testDir -Bearer "xoxp-test-bearer-value"
            Set-BrokerResponse -Dir $testDir -Mode "ok"
            New-IncidentConfig -Dir $testDir

            $result = Invoke-CredScript -TestDir $testDir -Arguments @("-AccountId", "111111111111", "-Agent", "claude-code")

            $result.ExitCode | Should -Be 0 -Because "success expected. stderr: $($result.Stderr)"

            $arrow = [char]0x2192
            $errText = if ($null -eq $result.Stderr) { "" } else { [string]$result.Stderr }
            $outText = if ($null -eq $result.Stdout) { "" } else { [string]$result.Stdout }
            ($errText -match "\[migrate\] .+ $arrow csg-") | Should -BeTrue -Because "the mapping table must reach stderr. stderr: $errText"
            $outText.Contains('[migrate]') | Should -BeFalse -Because "no [migrate] line may reach stdout. stdout: $outText"
            Assert-StdoutIsOnlyJson -Stdout $result.Stdout -Because "the summary belongs on stderr only"
        }
    }

    Context "STDOUT-03: the register child's success line does not leak" {

        It "keeps the child's profile-name line out of the parent's stdout" {
            if (-not (Test-RealAwsPresent)) { Set-ItResult -Skipped -Because "the real 'aws' CLI is not installed"; return }

            $testDir = Join-Path $TestDrive "stdout3-$([IO.Path]::GetRandomFileName())"
            New-Item -ItemType Directory -Path $testDir -Force | Out-Null

            New-BrokerEnv -Dir $testDir -Bearer "xoxp-test-bearer-value"
            Set-BrokerResponse -Dir $testDir -Mode "ok"
            New-LegacyConfig -Dir $testDir     # `samplecorp` has no cache -> its rename WILL succeed

            $result = Invoke-CredScript -TestDir $testDir -Arguments @("-AccountId", "111111111111", "-Agent", "claude-code")

            $result.ExitCode | Should -Be 0 -Because "success expected. stderr: $($result.Stderr)"
            # A rename must genuinely have happened, or the child never printed.
            (Test-ConfigHasProfile -Dir $testDir -Name "csg-samplecorp") | Should -BeTrue -Because "no rename occurred, so the child produced no success line to leak"

            $outText = if ($null -eq $result.Stdout) { "" } else { [string]$result.Stdout }
            $outText.Contains('csg-samplecorp') | Should -BeFalse -Because "the child's profile-name line must not reach stdout. stdout: $outText"
            Assert-StdoutIsOnlyJson -Stdout $result.Stdout -Because "the register child's stdout must be captured"
        }
    }

    Context "STDOUT-04: a name-collision run still emits ONLY the 5-key JSON" {

        It "reports the collision on stderr, keeps the old section, and keeps going" {
            if (-not (Test-RealAwsPresent)) { Set-ItResult -Skipped -Because "the real 'aws' CLI is not installed"; return }

            $testDir = Join-Path $TestDrive "stdout4-$([IO.Path]::GetRandomFileName())"
            New-Item -ItemType Directory -Path $testDir -Force | Out-Null

            New-BrokerEnv -Dir $testDir -Bearer "xoxp-test-bearer-value"
            Set-BrokerResponse -Dir $testDir -Mode "ok"
            New-CollisionConfig -Dir $testDir

            $result = Invoke-CredScript -TestDir $testDir -Arguments @("-AccountId", "111111111111", "-Agent", "claude-code")

            $result.ExitCode | Should -Be 0 -Because "success expected. stderr: $($result.Stderr)"

            $errText = if ($null -eq $result.Stderr) { "" } else { [string]$result.Stderr }
            $errText.Contains('[migrate] reason=name-collision') | Should -BeTrue -Because "the collision must be reported. stderr: $errText"
            # D-07: the old section survives -- losing it would lose data.
            (Test-ConfigHasProfile -Dir $testDir -Name "acme") | Should -BeTrue -Because "the colliding legacy profile must be kept"
            # ...and a collision must not abort the run.
            (Test-ConfigHasProfile -Dir $testDir -Name "csg-other") | Should -BeTrue -Because "the unrelated profile must still be migrated"

            Assert-StdoutIsOnlyJson -Stdout $result.Stdout -Because "a collision run must not pollute the credential channel"
            Assert-Pure5KeyStdout -Stdout $result.Stdout -Because "a collision run must still emit the 5-key contract"
        }
    }

    # =====================================================================
    # SCP-05 fan-out brake -- the Pester twin of run_scope1..run_scope8 in
    # test/get-customer-credentials.test.sh, case for case, against
    # byte-identical fixtures.
    #
    # Why these exist as their own suite rather than as more PARITY-SCOPE-*
    # cases: PARITY-SCOPE-CONST/-ROUTE/-TOKENS prove the pwsh client contains
    # the same TEXT -- the same constants, the same routing branch, the same
    # reason vocabulary. None of that RUNS the brake. A Get-ScopeWindowDistinct
    # that returned 0 on every input would pass all three parity cases and
    # refuse nobody. These cases compare BEHAVIOUR, which is the drift a text
    # comparison structurally cannot see.
    #
    # What they prove, stated honestly (X7): 결정론적 거부 + 기록 -- a
    # deterministic refusal and a durable local record. They deliberately do NOT
    # assert that a fan-out is impossible. An agent owns the shell and can call
    # `scope-ack` itself (T-24-02, accepted); the backstop that does not depend
    # on the agent's cooperation is server-side (Phase 25 DET-01).
    # =====================================================================

    Context "SCOPE-1 (twin of run_scope1): the 6th distinct unapproved account in the window is refused (12-in-54s shape)" {

        # MUTATION CHECK (verified): commenting out the `# --- SCP-05 fan-out
        # brake` block in get-customer-credentials.ps1 makes the refusal half fail
        # (exit 0 where 1 is required); changing `$scopeCount -gt $ScopeMaxAccounts`
        # to `-ge` makes the boundary half fail (the FIFTH account is refused one
        # account early).
        It "passes the 5th account and refuses the 6th with the fan-out-threshold token, a zero-byte stdout, and no broker call" {
            $testDir = Join-Path $TestDrive "scope1-$([IO.Path]::GetRandomFileName())"
            New-ScopeEnv -Dir $testDir

            $a1 = Get-ScopeAcct -Lead 5 -N 1
            $a2 = Get-ScopeAcct -Lead 5 -N 2
            $a3 = Get-ScopeAcct -Lead 5 -N 3
            $a4 = Get-ScopeAcct -Lead 5 -N 4
            $a5 = Get-ScopeAcct -Lead 5 -N 5
            $a6 = Get-ScopeAcct -Lead 5 -N 6
            $a99 = Get-ScopeAcct -Lead 5 -N 99

            # The incident's own cadence: four distinct accounts inside a minute...
            New-ScopeWindow -Dir $testDir -AgeSeconds 54 -AccountIds @($a1)
            New-ScopeWindow -Dir $testDir -AgeSeconds 44 -AccountIds @($a2)
            New-ScopeWindow -Dir $testDir -AgeSeconds 34 -AccountIds @($a3)
            New-ScopeWindow -Dir $testDir -AgeSeconds 24 -AccountIds @($a4)
            # ... plus one record 400 seconds old, i.e. OUTSIDE the 300s window.
            New-ScopeWindow -Dir $testDir -AgeSeconds 400 -AccountIds @($a99)

            # --- the N=5 boundary, asserted from the PASSING side --------------
            # This is the off-by-one guard, not a warm-up. D-02 is "6번째 distinct
            # 계정의 신규 발급부터 거부", so the fifth must still pass. Without this
            # half, a `-ge` where the code needs `-gt` (or a cutoff that counted the
            # 400-second-old record) refuses one account early and every remaining
            # assertion below still goes green -- they only ever check that
            # SOMETHING was refused.
            $r5 = Invoke-CredScript -TestDir $testDir -Arguments @("-AccountId", $a5, "-Agent", "claude-code") -CloseStdin -TimeoutSeconds 20
            $r5.TimedOut | Should -BeFalse -Because "the 5th account must not hang. stderr: $($r5.Stderr)"
            $r5.ExitCode | Should -Be 0 -Because "the 5th distinct account is inside the allowance (N=5 boundary). stderr: $($r5.Stderr)"
            Assert-Pure5KeyStdout -Stdout $r5.Stdout -Because "the passing side of the boundary must still emit the 5-key contract"
            (Get-HttpCallCount -Dir $testDir) | Should -Be 1 -Because "the 5th account must reach the broker exactly once"

            # append-then-count: this invocation's OWN record is on disk, and the
            # 400-second-old one has been pruned away by the same invocation.
            # A raw count of 5 is ambiguous (with the brake removed the file also
            # holds 5 lines), so both directions are asserted explicitly.
            (Test-ScopeWindowHas -Dir $testDir -AccountId $a5) | Should -BeTrue -Because "append-then-count: the 5th account's own window record must be on disk"
            (Test-ScopeWindowHas -Dir $testDir -AccountId $a99) | Should -BeFalse -Because "the 400s-old record must have been pruned by the same invocation"
            (Get-ScopeWindowLineCount -Dir $testDir) | Should -Be 5 -Because "4 seeded + this invocation's own, with the stale record rewritten away by the prune"

            # --- the refusal --------------------------------------------------
            $beforeCalls = Get-HttpCallCount -Dir $testDir
            $r6 = Invoke-CredScript -TestDir $testDir -Arguments @("-AccountId", $a6, "-Agent", "claude-code") -CloseStdin -TimeoutSeconds 20
            $r6.TimedOut | Should -BeFalse -Because "the refusal must not hang. stderr: $($r6.Stderr)"
            # EXACTLY 1, not merely non-zero: a throw-shaped exit and
            # Stop-WithScopeRefusal must not be conflated, and if a later change
            # turns the refusal into rc 2 this case should say so.
            $r6.ExitCode | Should -Be 1 -Because "the 6th distinct unapproved account must be refused with exit 1. stderr: $($r6.Stderr)"
            Assert-EmptyStdout -Stdout $r6.Stdout -Because "a refusal writes ZERO bytes to the credential_process stdout"

            $errLines = Get-StderrLines -Stderr $r6.Stderr
            @($errLines | Where-Object { $_ -eq '[scope] reason=fan-out-threshold' }).Count |
                Should -Be 1 -Because "the machine token must appear exactly once. stderr: $($r6.Stderr)"

            # Pitfall 4: the copy-pasteable retry is the LAST thing the agent reads.
            # A [sweep]/[migrate] line written later in the same invocation must not
            # be able to bury it.
            $last = $errLines[-1]
            # WR-02 (24-08): the CSV is QUOTED on this client and the quotes are
            # REQUIRED here, not optional. An optional-quote regex ("?) would pass
            # against both the fixed and the unfixed line and would stop being a
            # gate. The bash twin's own $-anchored copy of this regex
            # (test/get-customer-credentials.test.sh) stays UNQUOTED on purpose --
            # bash does not word-split on ',' and needs no quotes, so quoting its
            # line would break that regex while fixing nothing.
            $last | Should -Match 'scope-ack --account-ids "[0-9][0-9,]*"$' -Because "the last stderr line must be the copy-pasteable retry command, with the id CSV quoted so pwsh does not re-parse it as an array. stderr: $($r6.Stderr)"

            # All SIX ids, including the one just refused. append-then-count puts
            # this invocation's own record in the window before the count is read,
            # so a retry command that omitted it would refuse again on the
            # copy-paste -- a silently useless instruction. Asserted one id at a
            # time so a failure names the missing one.
            foreach ($want in @($a1, $a2, $a3, $a4, $a5, $a6)) {
                $last.Contains($want) | Should -BeTrue -Because "the retry line must carry $want. line: [$last]"
            }
            # ... and NOT the 400-second-old id: the sliding window applies to the
            # message as well as to the count.
            $last.Contains($a99) | Should -BeFalse -Because "the retry line must not carry the out-of-window id $a99. line: [$last]"

            # The brake sits before the broker POST, so a refusal costs no call.
            (Get-HttpCallCount -Dir $testDir) | Should -Be $beforeCalls -Because "a refusal must make no broker call"
            (Test-Path -LiteralPath (Join-Path $testDir ".cache/msp/customer-creds/$a6.json")) |
                Should -BeFalse -Because "no cache file may be written for a refused account"
        }

        # WR-02 (24-08). SKILL.md and troubleshooting.md both promise that the
        # refusal's last stderr line is a retry command the agent can paste
        # VERBATIM. Nothing proved it: the It above checks the line's SHAPE, and a
        # line can be perfectly shaped and still be refused when it is pasted --
        # which is exactly what happened before this plan, because pwsh parsed the
        # unquoted CSV as an array expression.
        #
        # So this case actually pastes it. The line is taken from the refusal's
        # stderr, the client filename is stripped (Invoke-CredScriptRaw supplies
        # the path), and everything after it goes to a real pwsh parser unchanged.
        # The proof that the retry WORKED is not scope-ack's own exit code -- it is
        # that the account which was just refused now passes.
        It "WR-02: the refusal's last stderr line, pasted back verbatim, is accepted and unblocks the account it refused" {
            $testDir = Join-Path $TestDrive "scope1rt-$([IO.Path]::GetRandomFileName())"
            New-ScopeEnv -Dir $testDir

            $a6 = Get-ScopeAcct -Lead 5 -N 6
            foreach ($n in 1, 2, 3, 4, 5) {
                New-ScopeWindow -Dir $testDir -AgeSeconds (10 * $n) -AccountIds @((Get-ScopeAcct -Lead 5 -N $n))
            }

            $refused = Invoke-CredScript -TestDir $testDir -Arguments @("-AccountId", $a6, "-Agent", "claude-code") -CloseStdin -TimeoutSeconds 20
            $refused.ExitCode | Should -Be 1 -Because "the 6th distinct unapproved account must be refused. stderr: $($refused.Stderr)"

            $lastLine = (Get-StderrLines -Stderr $refused.Stderr)[-1]
            $m = [regex]::Match($lastLine, 'get-customer-credentials\.ps1\s+(scope-ack\s+--account-ids\s+"[0-9][0-9,]*")$')
            $m.Success | Should -BeTrue -Because "the retry line must name the client and carry a quoted id CSV so it can be pasted. line: [$lastLine]"

            # Pasted VERBATIM -- no re-quoting, no splitting, no normalisation.
            $pasted = Invoke-CredScriptRaw -TestDir $testDir -RawArgs $m.Groups[1].Value
            $pasted.TimedOut | Should -BeFalse -Because "the pasted retry must not hang. stderr: $($pasted.Stderr)"
            $pasted.ExitCode | Should -Be 0 -Because "the retry command the client printed must be accepted when pasted back. pasted: [$($m.Groups[1].Value)] stderr: $($pasted.Stderr)"
            (Get-ScopeAckLineCount -Dir $testDir) | Should -Be 1 -Because "the pasted retry must write exactly one ack record. stderr: $($pasted.Stderr)"

            # THE point of the promise: the same invocation now succeeds.
            $retry = Invoke-CredScript -TestDir $testDir -Arguments @("-AccountId", $a6, "-Agent", "claude-code") -CloseStdin -TimeoutSeconds 20
            $retry.ExitCode | Should -Be 0 -Because "after pasting the printed retry, the refused account must pass. stderr: $($retry.Stderr)"
            Assert-Pure5KeyStdout -Stdout $retry.Stdout -Because "the unblocked invocation must still emit the 5-key contract"
        }
    }

    Context "SCOPE-2 (twin of run_scope2): D-06 -- an acked account passes with 6 unapproved neighbours; an out-of-set account is still counted and refused" {

        # MUTATION CHECK (verified): deleting the ack-membership test that feeds
        # Get-ScopeWindowDistinct (-AckCsv) makes the first half fail -- the acked
        # account would be refused for its neighbours' behaviour.
        It "lets an acked account through six unapproved neighbours and still refuses an out-of-set account" {
            $testDir = Join-Path $TestDrive "scope2-$([IO.Path]::GetRandomFileName())"
            New-ScopeEnv -Dir $testDir

            $ack1 = Get-ScopeAcct -Lead 6 -N 1
            $ack2 = Get-ScopeAcct -Lead 6 -N 2
            $out = Get-ScopeAcct -Lead 9 -N 99

            # Six distinct unapproved accounts -- already over the allowance of 5.
            New-ScopeWindow -Dir $testDir -AgeSeconds 50 -AccountIds @((Get-ScopeAcct -Lead 5 -N 1))
            New-ScopeWindow -Dir $testDir -AgeSeconds 40 -AccountIds @((Get-ScopeAcct -Lead 5 -N 2))
            New-ScopeWindow -Dir $testDir -AgeSeconds 30 -AccountIds @((Get-ScopeAcct -Lead 5 -N 3))
            New-ScopeWindow -Dir $testDir -AgeSeconds 20 -AccountIds @((Get-ScopeAcct -Lead 5 -N 4))
            New-ScopeWindow -Dir $testDir -AgeSeconds 10 -AccountIds @((Get-ScopeAcct -Lead 5 -N 5))
            New-ScopeWindow -Dir $testDir -AgeSeconds 5  -AccountIds @((Get-ScopeAcct -Lead 5 -N 6))

            $ack = Invoke-CredScript -TestDir $testDir -Arguments @("scope-ack", "--account-ids", "$ack1,$ack2") -CloseStdin -TimeoutSeconds 20
            $ack.ExitCode | Should -Be 0 -Because "scope-ack must succeed. stderr: $($ack.Stderr)"
            (Get-ScopeAckLineCount -Dir $testDir) | Should -Be 1 -Because "one scope-ack call writes exactly one record"

            # Half one: the acked account PASSES even though six unapproved accounts
            # sit in the window. This is the half a naive port gets wrong.
            $rOk = Invoke-CredScript -TestDir $testDir -Arguments @("-AccountId", $ack1, "-Agent", "claude-code") -CloseStdin -TimeoutSeconds 20
            $rOk.ExitCode | Should -Be 0 -Because "an acked account passes regardless of its unapproved neighbours. stderr: $($rOk.Stderr)"
            Assert-Pure5KeyStdout -Stdout $rOk.Stdout -Because "the acked pass path must emit the 5-key contract"
            (Get-HttpCallCount -Dir $testDir) | Should -Be 1 -Because "the acked account must reach the broker exactly once"

            # Half two: an account OUTSIDE the set is still counted and still refused.
            $rNo = Invoke-CredScript -TestDir $testDir -Arguments @("-AccountId", $out, "-Agent", "claude-code") -CloseStdin -TimeoutSeconds 20
            $rNo.ExitCode | Should -Be 1 -Because "an out-of-set account is still counted and refused. stderr: $($rNo.Stderr)"
            Assert-EmptyStdout -Stdout $rNo.Stdout -Because "a refusal writes zero bytes to stdout"

            $errLines = Get-StderrLines -Stderr $rNo.Stderr
            @($errLines | Where-Object { $_ -eq '[scope] reason=fan-out-threshold' }).Count |
                Should -Be 1 -Because "the refusal must carry the machine token. stderr: $($rNo.Stderr)"

            # RESEARCH A3: acked ids are excluded from the count AND from the
            # message, so a legitimately approved 12-account batch cannot block an
            # unrelated 13th by inflating the list.
            $last = $errLines[-1]
            $last.Contains($ack1) | Should -BeFalse -Because "an acked id must not leak into the retry line. line: [$last]"
            $last.Contains($ack2) | Should -BeFalse -Because "an acked id must not leak into the retry line. line: [$last]"
        }
    }

    Context "SCOPE-3 (twin of run_scope3): an expired ack exempts nothing; a re-ack restores; two acks UNION rather than replace" {

        # MUTATION CHECK (verified): making Get-ScopeAckSet's `expiresAt > now`
        # filter unconditional makes phase 1 fail -- the expired record would
        # exempt the account.
        It "rejects an expired ack, restores on re-ack, and unions two acks instead of replacing" {
            $testDir = Join-Path $TestDrive "scope3-$([IO.Path]::GetRandomFileName())"
            New-ScopeEnv -Dir $testDir

            $b1 = Get-ScopeAcct -Lead 6 -N 1
            $b2 = Get-ScopeAcct -Lead 6 -N 2
            $b3 = Get-ScopeAcct -Lead 6 -N 3
            $b4 = Get-ScopeAcct -Lead 6 -N 4
            $out = Get-ScopeAcct -Lead 9 -N 99

            New-ScopeWindow -Dir $testDir -AgeSeconds 50 -AccountIds @((Get-ScopeAcct -Lead 5 -N 1))
            New-ScopeWindow -Dir $testDir -AgeSeconds 40 -AccountIds @((Get-ScopeAcct -Lead 5 -N 2))
            New-ScopeWindow -Dir $testDir -AgeSeconds 30 -AccountIds @((Get-ScopeAcct -Lead 5 -N 3))
            New-ScopeWindow -Dir $testDir -AgeSeconds 20 -AccountIds @((Get-ScopeAcct -Lead 5 -N 4))
            New-ScopeWindow -Dir $testDir -AgeSeconds 10 -AccountIds @((Get-ScopeAcct -Lead 5 -N 5))
            New-ScopeWindow -Dir $testDir -AgeSeconds 5  -AccountIds @((Get-ScopeAcct -Lead 5 -N 6))

            # -- phase 1: an ack whose expiresAt is 60 seconds in the PAST -------
            # This is the TTL=3600 contract observed from OUTSIDE: the case never
            # reads $ScopeAckTtlSeconds, it seeds an expiresAt the reader must reject.
            New-ScopeAck -Dir $testDir -TtlOffsetSeconds -60 -AccountIds @($b1, $b2)
            $r1 = Invoke-CredScript -TestDir $testDir -Arguments @("-AccountId", $b1, "-Agent", "claude-code") -CloseStdin -TimeoutSeconds 20
            $r1.ExitCode | Should -Be 1 -Because "an expired ack exempts nothing. stderr: $($r1.Stderr)"
            (Get-StderrLines -Stderr $r1.Stderr) | Should -Contain '[scope] reason=fan-out-threshold' -Because "the expired-ack refusal must carry the machine token"

            # -- phase 2: a fresh scope-ack restores the pass --------------------
            # The expired record is still in the file (append-only, no tombstone)
            # and the fresh one wins.
            $ack1 = Invoke-CredScript -TestDir $testDir -Arguments @("scope-ack", "--account-ids", "$b1,$b2") -CloseStdin -TimeoutSeconds 20
            $ack1.ExitCode | Should -Be 0 -Because "the first real scope-ack must succeed. stderr: $($ack1.Stderr)"
            $r2 = Invoke-CredScript -TestDir $testDir -Arguments @("-AccountId", $b1, "-Agent", "claude-code") -CloseStdin -TimeoutSeconds 20
            $r2.ExitCode | Should -Be 0 -Because "a re-acked account passes. stderr: $($r2.Stderr)"
            Assert-Pure5KeyStdout -Stdout $r2.Stdout -Because "the re-acked pass path must emit the 5-key contract"

            # -- phase 3: a SECOND scope-ack must UNION, not replace -------------
            $ack2 = Invoke-CredScript -TestDir $testDir -Arguments @("scope-ack", "--account-ids", "$b3,$b4") -CloseStdin -TimeoutSeconds 20
            $ack2.ExitCode | Should -Be 0 -Because "the second real scope-ack must succeed. stderr: $($ack2.Stderr)"
            (Get-ScopeAckLineCount -Dir $testDir) | Should -Be 3 -Because "expired + two acks, append-only with no tombstone"

            $r3 = Invoke-CredScript -TestDir $testDir -Arguments @("-AccountId", $b3, "-Agent", "claude-code") -CloseStdin -TimeoutSeconds 20
            $r3.ExitCode | Should -Be 0 -Because "the second ack's account passes. stderr: $($r3.Stderr)"
            # The union assertion: if the second scope-ack had REPLACED the set,
            # this account would now be refused and D-16's resume-without-re-ack
            # would be broken.
            $r4 = Invoke-CredScript -TestDir $testDir -Arguments @("-AccountId", $b2, "-Agent", "claude-code") -CloseStdin -TimeoutSeconds 20
            $r4.ExitCode | Should -Be 0 -Because "the FIRST ack's account must still pass after a second ack (union, not replace). stderr: $($r4.Stderr)"
            # Control: a never-acked account is still refused, which is what proves
            # the passes above came from the ack set and not from a window that had
            # drifted below the allowance.
            $r5 = Invoke-CredScript -TestDir $testDir -Arguments @("-AccountId", $out, "-Agent", "claude-code") -CloseStdin -TimeoutSeconds 20
            $r5.ExitCode | Should -Be 1 -Because "a never-acked control account must still be refused. stderr: $($r5.Stderr)"
        }
    }

    Context "SCOPE-4 (twin of run_scope4): SC5 -- the pass path emits ONLY the 5-key JSON, the refuse path emits zero bytes, and the refusal completes in under 2 seconds with a closed stdin" {

        # MUTATION CHECK (verified): any [Console]::Out.Write added inside
        # Stop-WithScopeRefusal makes the refuse half fail on the zero-byte
        # assertion.
        #
        # The stdin closure is an ASSERTION, not a convenience. A Read-Host
        # reintroduced into the brake would block forever on an inherited TTY and
        # merely LOOK slow; with a closed stdin it returns immediately and the case
        # still catches it through the token assertions. Both mechanisms are needed.
        It "keeps stdout pure on the pass path, zero-byte on the refuse path, and refuses in under 2 seconds" {
            # -- pass -------------------------------------------------------------
            $passDir = Join-Path $TestDrive "scope4pass-$([IO.Path]::GetRandomFileName())"
            New-ScopeEnv -Dir $passDir

            # A deliberately LOOSER budget than the refusal's: this path may still
            # spawn the real `aws` binary for the migration hook, and SC5's <2s
            # budget is about the REFUSAL. Do not tighten this into a flake.
            $rPass = Invoke-CredScript -TestDir $passDir -Arguments @("-AccountId", (Get-ScopeAcct -Lead 5 -N 1), "-Agent", "claude-code") -CloseStdin -TimeoutSeconds 30
            $rPass.TimedOut | Should -BeFalse -Because "the pass path must not hang with a closed stdin. stderr: $($rPass.Stderr)"
            $rPass.ExitCode | Should -Be 0 -Because "an empty window passes. stderr: $($rPass.Stderr)"
            # Both assertions: the first proves nothing was written before or after
            # the JSON, the second proves the key set.
            Assert-StdoutIsOnlyJson -Stdout $rPass.Stdout -Because "SC5: the credential channel carries the JSON and nothing else"
            Assert-Pure5KeyStdout -Stdout $rPass.Stdout -Because "SC5: exactly the 5 canonical keys"
            (Get-ScopeWindowLineCount -Dir $passDir) | Should -Be 1 -Because "one invocation writes exactly one window record"

            # -- refuse -----------------------------------------------------------
            $refuseDir = Join-Path $TestDrive "scope4refuse-$([IO.Path]::GetRandomFileName())"
            New-ScopeEnv -Dir $refuseDir
            New-ScopeWindow -Dir $refuseDir -AgeSeconds 54 -AccountIds @((Get-ScopeAcct -Lead 5 -N 1))
            New-ScopeWindow -Dir $refuseDir -AgeSeconds 44 -AccountIds @((Get-ScopeAcct -Lead 5 -N 2))
            New-ScopeWindow -Dir $refuseDir -AgeSeconds 34 -AccountIds @((Get-ScopeAcct -Lead 5 -N 3))
            New-ScopeWindow -Dir $refuseDir -AgeSeconds 24 -AccountIds @((Get-ScopeAcct -Lead 5 -N 4))
            New-ScopeWindow -Dir $refuseDir -AgeSeconds 14 -AccountIds @((Get-ScopeAcct -Lead 5 -N 5))

            $rRefuse = Invoke-CredScript -TestDir $refuseDir -Arguments @("-AccountId", (Get-ScopeAcct -Lead 5 -N 6), "-Agent", "claude-code") -CloseStdin -TimeoutSeconds 20
            $rRefuse.TimedOut | Should -BeFalse -Because "SC5: the refusal must not depend on a TTY. stderr: $($rRefuse.Stderr)"
            $rRefuse.DurationMs | Should -BeLessThan 2000 -Because "SC5: no prompt, no TTY dependence, fail fast -- the file header records a prior ~120s agent hang from exactly this. measured: $($rRefuse.DurationMs)ms"
            $rRefuse.ExitCode | Should -Be 1 -Because "the refusal exits 1. stderr: $($rRefuse.Stderr)"
            Assert-EmptyStdout -Stdout $rRefuse.Stdout -Because "SC5: the refuse path writes zero bytes to stdout"
            (Get-StderrLines -Stderr $rRefuse.Stderr) | Should -Contain '[scope] reason=fan-out-threshold' -Because "the refusal must be attributable to the brake"
        }
    }

    Context "SCOPE-5 (twin of run_scope5): D-01 -- a cache HIT writes no window record; a 503->503->200 retry writes exactly one" {

        # MUTATION CHECK (verified): hoisting Write-ScopeWindowRecord above the
        # cache-emit early return makes a cache HIT consume window budget (records
        # go 1 -> 2); moving the brake block inside the retry loop makes it fire
        # once per HTTP call instead of once per invocation. Both turn this red.
        It "leaves both counters at 1 across a warm second run, and writes one record across three HTTP calls" {
            # -- cache HIT --------------------------------------------------------
            $hitDir = Join-Path $TestDrive "scope5hit-$([IO.Path]::GetRandomFileName())"
            New-ScopeEnv -Dir $hitDir
            $acct = Get-ScopeAcct -Lead 5 -N 1

            $h1 = Invoke-CredScript -TestDir $hitDir -Arguments @("-AccountId", $acct, "-Agent", "claude-code") -CloseStdin -TimeoutSeconds 30
            $h1.ExitCode | Should -Be 0 -Because "the cold run must succeed. stderr: $($h1.Stderr)"
            $c1 = Get-HttpCallCount -Dir $hitDir
            $w1 = Get-ScopeWindowLineCount -Dir $hitDir

            $h2 = Invoke-CredScript -TestDir $hitDir -Arguments @("-AccountId", $acct, "-Agent", "claude-code") -CloseStdin -TimeoutSeconds 30
            $h2.ExitCode | Should -Be 0 -Because "the warm run must succeed. stderr: $($h2.Stderr)"
            $c2 = Get-HttpCallCount -Dir $hitDir
            $w2 = Get-ScopeWindowLineCount -Dir $hitDir

            $c1 | Should -Be 1 -Because "the cold run calls the broker once"
            $c2 | Should -Be 1 -Because "the warm run is a cache HIT and must not call the broker again"
            # D-01: the counting unit is the NEW ISSUANCE, not the cache read above
            # it. If a HIT consumed window budget, five customers' worth of routine
            # re-reads inside five minutes would refuse the sixth -- "정상 3계정
            # 비교도 걸려 override 일상화", exactly the failure mode D-02 rejected
            # N=3/60s to avoid. The guarantee is POSITIONAL (the brake sits below
            # the cache-emit early return), so this case is what notices if the
            # block ever moves.
            $w1 | Should -Be 1 -Because "the cold run writes exactly one window record"
            $w2 | Should -Be 1 -Because "a cache HIT writes NO window record"

            # -- 503 -> 503 -> 200 inside ONE invocation --------------------------
            $retryDir = Join-Path $TestDrive "scope5retry-$([IO.Path]::GetRandomFileName())"
            New-ScopeEnv -Dir $retryDir
            $racct = Get-ScopeAcct -Lead 5 -N 2
            # A stale cache forces the broker call the sequence is about.
            New-ExpiredCache -Dir $retryDir -AccountId $racct
            Set-BrokerStatusSequence -Dir $retryDir -Codes @(503, 503, 200)

            # A deliberately generous budget: the client sleeps 1s then 2s between
            # attempts. SC5's <2s budget is a property of the REFUSAL, not of a
            # legitimate bounded retry -- a timing assertion here would be
            # asserting Phase 19's backoff contract, not this phase's.
            $rRetry = Invoke-CredScript -TestDir $retryDir -Arguments @("-AccountId", $racct, "-Agent", "claude-code") -CloseStdin -TimeoutSeconds 60
            $rRetry.TimedOut | Should -BeFalse -Because "the bounded retry must complete. stderr: $($rRetry.Stderr)"
            $rRetry.ExitCode | Should -Be 0 -Because "503,503,200 must recover. stderr: $($rRetry.Stderr)"
            Assert-Pure5KeyStdout -Stdout $rRetry.Stdout -Because "a recovered retry must still emit the 5-key contract"
            (Get-HttpCallCount -Dir $retryDir) | Should -Be 3 -Because "the status sequence must produce exactly three broker calls"
            # Pitfall 9: a brake check placed inside the retry loop would write
            # three records here and could refuse on the second retry of a
            # legitimate 5xx recovery -- turning a broker hiccup into a fan-out
            # accusation.
            (Get-ScopeWindowLineCount -Dir $retryDir) | Should -Be 1 -Because "ONE invocation over three HTTP calls writes exactly ONE window record"
        }
    }

    Context "SCOPE-6 (twin of run_scope6): T-24-08 -- scope-ack validates every id before any write; injection inputs create no record" {

        # MUTATION CHECK (verified): reordering the >=2 arity check ahead of the
        # per-element regex flips row 1's token from invalid-account-id to
        # invalid-arguments and this case fails on it.
        It "aborts every malformed --account-ids value with a byte-equal token line, creates no record, and writes one deduped record on the success row" {
            $a1 = Get-ScopeAcct -Lead 5 -N 1
            $a2 = Get-ScopeAcct -Lead 5 -N 2

            # -- abort rows -------------------------------------------------------
            $abortDir = Join-Path $TestDrive "scope6abort-$([IO.Path]::GetRandomFileName())"
            New-Item -ItemType Directory -Path $abortDir -Force | Out-Null

            # The embedded-quote, embedded-brace and embedded-NEWLINE rows reach the
            # child as ONE argument only because Invoke-CredScript base64-encodes
            # every argument into its generated wrapper (see the T-24-08b note
            # there). Written as a bare double-quoted literal the '"' would close
            # the string and the LF would split the array element, so the row would
            # have produced a WRAPPER parse error and proved nothing about the
            # client. The token assertion below is also the receipt that the payload
            # actually arrived: a wrapper parse error cannot produce a
            # "[scope-ack] reason=" line.
            $rows = @(
                @{ Token = 'invalid-account-id'; Input = '1,2' },
                @{ Token = 'invalid-arguments';  Input = $a1 },
                @{ Token = 'invalid-arguments';  Input = "$a1,$a1" },
                @{ Token = 'invalid-arguments';  Input = '' },
                @{ Token = 'invalid-account-id'; Input = ($a1 + '","x":"y') },
                @{ Token = 'invalid-account-id'; Input = ($a1 + ',{"a":1}') },
                @{ Token = 'invalid-account-id'; Input = ("$a1,$a2" + "`n" + '{"ts":0,"accountId":"999999999999"}') }
            )

            $rowNum = 0
            foreach ($row in $rows) {
                $rowNum++
                $r = Invoke-CredScript -TestDir $abortDir -Arguments @("scope-ack", "--account-ids", $row.Input) -CloseStdin -TimeoutSeconds 20 -CaptureTag "-row$rowNum"
                $r.TimedOut | Should -BeFalse -Because "row $rowNum must not hang. stderr: $($r.Stderr)"
                $r.ExitCode | Should -Be 1 -Because "row $rowNum must abort with exit 1. stderr: $($r.Stderr)"
                Assert-EmptyStdout -Stdout $r.Stdout -Because "row $rowNum must write nothing to stdout"

                $lines = Get-StderrLines -Stderr $r.Stderr
                $lines.Count | Should -BeGreaterThan 0 -Because "row $rowNum must report a reason on stderr"
                # -Be on the trimmed FIRST line, never -Match: a substring match
                # passes on a token that merely CONTAINS the expected one.
                $lines[0].Trim() | Should -Be "[scope-ack] reason=$($row.Token)" -Because "row $rowNum first stderr line. full stderr: $($r.Stderr)"

                # Log injection: the newline row's payload must not be able to
                # produce an unprefixed line a log reader would attribute to the
                # tool. scope-ack routes before the main parser and before
                # sweep/migrate, so no other prefix can legitimately appear on this
                # path -- which is what makes the assertion exact, not heuristic.
                @($lines | Where-Object { -not $_.StartsWith('[scope-ack] ') }).Count |
                    Should -Be 0 -Because "row $rowNum emitted an unattributed stderr line. full stderr: $($r.Stderr)"
            }

            # `1,2` is rejected before the >=2 check and every injection row is
            # rejected before any write, so nothing may exist here at all. That
            # ordering is what makes the token honest: a user who typed a short id
            # is told the id is wrong, not that they need more accounts.
            (Test-Path -LiteralPath (Join-Path $abortDir ".cache/msp/customer-creds/scope-acks.jsonl")) |
                Should -BeFalse -Because "an aborted scope-ack must not create scope-acks.jsonl at all"

            # -- the success row --------------------------------------------------
            $okDir = Join-Path $TestDrive "scope6ok-$([IO.Path]::GetRandomFileName())"
            New-Item -ItemType Directory -Path $okDir -Force | Out-Null

            $ok = Invoke-CredScript -TestDir $okDir -Arguments @("scope-ack", "--account-ids", "$a1,$a2,$a1") -CloseStdin -TimeoutSeconds 20
            $ok.ExitCode | Should -Be 0 -Because "a valid, deduping row must succeed. stderr: $($ok.Stderr)"

            $outLines = @((([string]$ok.Stdout) -replace "`r", "") -split "`n" | Where-Object { $_.Trim() -ne "" })
            $outLines.Count | Should -Be 1 -Because "scope-ack stdout is exactly one line. stdout: [$($ok.Stdout)]"
            $outLines[0] | Should -BeLike "scope-ack: 2 accounts approved until *" -Because "the frozen stdout literal. stdout: [$($ok.Stdout)]"
            # The no-brace rule is structural: this line must be impossible to
            # confuse with the 5-key JSON contract even if a reader captures the
            # wrong stream (T-24-05).
            $outLines[0].Contains('{') | Should -BeFalse -Because "the scope-ack stdout line must carry no brace"
            $outLines[0].Contains('}') | Should -BeFalse -Because "the scope-ack stdout line must carry no brace"

            @((Get-StderrLines -Stderr $ok.Stderr) | Where-Object { $_.StartsWith('[scope-ack] ') }).Count |
                Should -Be 1 -Because "success emits exactly one [scope-ack] stderr line. stderr: $($ok.Stderr)"

            $recPath = Join-Path $okDir ".cache/msp/customer-creds/scope-acks.jsonl"
            (Test-Path -LiteralPath $recPath) | Should -BeTrue -Because "the success row must write the ack record"
            $recLines = @([IO.File]::ReadAllLines($recPath) | Where-Object { $_.Trim() -ne "" })
            $recLines.Count | Should -Be 1 -Because "one scope-ack call writes exactly one record"
            # Deduped, first-seen order, no third element.
            $recLines[0] | Should -Match "^\{`"ts`":[0-9]+,`"expiresAt`":[0-9]+,`"accountIds`":\[`"$a1`",`"$a2`"\],`"count`":2\}$" -Because "record was [$($recLines[0])]"
        }

        # WR-02 (24-08). A PARSING case, not a validation case, which is why it
        # goes through Invoke-CredScriptRaw: `--account-ids a,b` becomes an
        # [object[]] only when a pwsh parser reads the text, and it is exactly the
        # text SKILL.md tells the engineer to run and the refusal tells them to
        # paste. Before this plan the direct-.ps1 shape exited 1 with
        # reason=invalid-account-id naming the token '500000000001 500000000002'
        # -- a space-joined value that appears nowhere in the user's command line,
        # because the nested array had been bound to a [string[]] parameter.
        #
        # All THREE shapes are asserted on one fixture, because the fix must be a
        # no-op on the shape that already worked: the native
        # `pwsh -NoProfile -File` form SKILL.md documents passes a plain string
        # and must not change behaviour at all.
        It "WR-02: --account-ids accepts the PowerShell array form identically to the CSV string form" {
            $b1 = Get-ScopeAcct -Lead 5 -N 1
            $b2 = Get-ScopeAcct -Lead 5 -N 2

            # -- shape 1: direct .ps1 call, UNQUOTED CSV -> [object[]] ------------
            $arrDir = Join-Path $TestDrive "scope6arr-$([IO.Path]::GetRandomFileName())"
            New-Item -ItemType Directory -Path $arrDir -Force | Out-Null
            $arr = Invoke-CredScriptRaw -TestDir $arrDir -RawArgs "scope-ack --account-ids $b1,$b2"
            $arr.TimedOut | Should -BeFalse -Because "the array form must not hang. stderr: $($arr.Stderr)"
            $arr.ExitCode | Should -Be 0 -Because "the array form must be accepted, not reported as invalid-account-id. stderr: $($arr.Stderr)"
            ([string]$arr.Stdout) | Should -Match "^scope-ack: 2 accounts approved until " -Because "the array form must emit the frozen stdout line. stdout: [$($arr.Stdout)]"
            (Get-ScopeAckLineCount -Dir $arrDir) | Should -Be 1 -Because "the array form must write exactly one ack record"
            # Rejoining with ',' must reproduce the element list PowerShell
            # destructured -- not a space-joined blob, and not a truncation.
            (Get-ScopeAckRaw -Dir $arrDir) | Should -Match "`"accountIds`":\[`"$b1`",`"$b2`"\]" -Because "the flattened array must land as two ids, in order. record: [$(Get-ScopeAckRaw -Dir $arrDir)]"

            # -- shape 2: direct .ps1 call, QUOTED CSV -> plain string ------------
            # The shape the refusal now prints. It must be indistinguishable.
            $qDir = Join-Path $TestDrive "scope6quo-$([IO.Path]::GetRandomFileName())"
            New-Item -ItemType Directory -Path $qDir -Force | Out-Null
            $quoted = Invoke-CredScriptRaw -TestDir $qDir -RawArgs "scope-ack --account-ids `"$b1,$b2`""
            $quoted.ExitCode | Should -Be 0 -Because "the quoted CSV form must be accepted. stderr: $($quoted.Stderr)"
            ([string]$quoted.Stdout) | Should -Match "^scope-ack: 2 accounts approved until " -Because "stdout: [$($quoted.Stdout)]"
            (Get-ScopeAckRaw -Dir $qDir) | Should -Match "`"accountIds`":\[`"$b1`",`"$b2`"\]" -Because "record: [$(Get-ScopeAckRaw -Dir $qDir)]"

            # -- shape 3: the DOCUMENTED native form -- must be untouched ---------
            $natDir = Join-Path $TestDrive "scope6nat-$([IO.Path]::GetRandomFileName())"
            New-Item -ItemType Directory -Path $natDir -Force | Out-Null
            $native = Invoke-CredScript -TestDir $natDir -Arguments @("scope-ack", "--account-ids", "$b1,$b2") -CloseStdin -TimeoutSeconds 20
            $native.ExitCode | Should -Be 0 -Because "the flatten must be a no-op on the form SKILL.md documents. stderr: $($native.Stderr)"
            ([string]$native.Stdout) | Should -Match "^scope-ack: 2 accounts approved until " -Because "stdout: [$($native.Stdout)]"
            (Get-ScopeAckRaw -Dir $natDir) | Should -Match "`"accountIds`":\[`"$b1`",`"$b2`"\]" -Because "record: [$(Get-ScopeAckRaw -Dir $natDir)]"

            # -- and the T-22-18 empty case is still reported as arguments --------
            # The flatten sits inside the `$args.Count -gt 1` guard; if it ever
            # escapes it, `scope-ack` alone would abort about an argument nobody
            # passed instead of reporting invalid-arguments.
            $noneDir = Join-Path $TestDrive "scope6none-$([IO.Path]::GetRandomFileName())"
            New-Item -ItemType Directory -Path $noneDir -Force | Out-Null
            $none = Invoke-CredScriptRaw -TestDir $noneDir -RawArgs "scope-ack"
            $none.ExitCode | Should -Be 1 -Because "bare scope-ack must still abort. stderr: $($none.Stderr)"
            (Get-StderrLines -Stderr $none.Stderr)[0].Trim() | Should -Be "[scope-ack] reason=invalid-arguments" -Because "stderr: $($none.Stderr)"
        }
    }

    Context "SCOPE-7 (twin of run_scope7): a corrupt window fails OPEN; a corrupt ack does NOT become a blanket override" {

        # MUTATION CHECK (verified): replacing a reader's fail-open fallback with a
        # throw turns fixture 1 red; making an unreadable ack file grant exemption
        # (the permissive-parser shape) turns fixture 3 red.
        #
        # This case is NOT redundant with the bash twin. $ErrorActionPreference =
        # "Stop" is file-wide in the pwsh client, so any reader that lets a [long]
        # cast or a ConvertFrom-Json throw becomes a TERMINATING error and turns
        # fail-open into fail-CLOSED on this side only. That failure mode does not
        # exist in bash and no parity grep can see it.
        It "passes on garbage and zero-byte window files and still refuses over a garbage ack file" {
            $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
            $rng = [Security.Cryptography.RandomNumberGenerator]::Create()

            # -- 1. garbage, random bytes and an unterminated final line ----------
            $gDir = Join-Path $TestDrive "scope7garbage-$([IO.Path]::GetRandomFileName())"
            New-ScopeEnv -Dir $gDir
            $gPath = Join-Path $gDir ".cache/msp/customer-creds/scope-window.jsonl"
            $noise = New-Object byte[] 512
            $rng.GetBytes($noise)
            $gBytes = [Collections.Generic.List[byte]]::new()
            $gBytes.AddRange($utf8NoBom.GetBytes("garbage not json`n"))
            $gBytes.AddRange($utf8NoBom.GetBytes('{"ts":"abc","accountId":"zz"}' + "`n"))
            $gBytes.AddRange($noise)
            $gBytes.AddRange($utf8NoBom.GetBytes("`n" + '{"ts":1,"accountId":"nope"'))
            [IO.File]::WriteAllBytes($gPath, $gBytes.ToArray())

            $rG = Invoke-CredScript -TestDir $gDir -Arguments @("-AccountId", (Get-ScopeAcct -Lead 5 -N 1), "-Agent", "claude-code") -CloseStdin -TimeoutSeconds 30
            $rG.ExitCode | Should -Be 0 -Because "a garbage window file must NOT break a single-account issuance. stderr: $($rG.Stderr)"
            Assert-Pure5KeyStdout -Stdout $rG.Stdout -Because "fail-open must still deliver clean credentials"

            # -- 2. a zero-byte window file (the shape a killed writer leaves) ----
            $zDir = Join-Path $TestDrive "scope7empty-$([IO.Path]::GetRandomFileName())"
            New-ScopeEnv -Dir $zDir
            [IO.File]::WriteAllBytes((Join-Path $zDir ".cache/msp/customer-creds/scope-window.jsonl"), [byte[]]@())

            $rZ = Invoke-CredScript -TestDir $zDir -Arguments @("-AccountId", (Get-ScopeAcct -Lead 5 -N 1), "-Agent", "claude-code") -CloseStdin -TimeoutSeconds 30
            $rZ.ExitCode | Should -Be 0 -Because "a truncated window file must NOT break a single-account issuance. stderr: $($rZ.Stderr)"
            Assert-Pure5KeyStdout -Stdout $rZ.Stdout -Because "fail-open must still deliver clean credentials"

            # -- 3. a garbage ACK file over an over-threshold window: still REFUSE -
            # The asymmetry, stated plainly: fail-open on the window (a lost record
            # under-counts, the safe direction), fail-closed-ish on the ack (an
            # unreadable approval is not an approval). CLAUDE.md Core Value:
            # breaking a legitimate single-account read is worse than missing one
            # fan-out, and granting an unrequested override is worse than both.
            $aDir = Join-Path $TestDrive "scope7badack-$([IO.Path]::GetRandomFileName())"
            New-ScopeEnv -Dir $aDir
            New-ScopeWindow -Dir $aDir -AgeSeconds 50 -AccountIds @((Get-ScopeAcct -Lead 5 -N 1))
            New-ScopeWindow -Dir $aDir -AgeSeconds 40 -AccountIds @((Get-ScopeAcct -Lead 5 -N 2))
            New-ScopeWindow -Dir $aDir -AgeSeconds 30 -AccountIds @((Get-ScopeAcct -Lead 5 -N 3))
            New-ScopeWindow -Dir $aDir -AgeSeconds 20 -AccountIds @((Get-ScopeAcct -Lead 5 -N 4))
            New-ScopeWindow -Dir $aDir -AgeSeconds 10 -AccountIds @((Get-ScopeAcct -Lead 5 -N 5))
            New-ScopeWindow -Dir $aDir -AgeSeconds 5  -AccountIds @((Get-ScopeAcct -Lead 5 -N 6))

            $ackNoise = New-Object byte[] 512
            $rng.GetBytes($ackNoise)
            $aBytes = [Collections.Generic.List[byte]]::new()
            $aBytes.AddRange($utf8NoBom.GetBytes("garbage not json`n"))
            $aBytes.AddRange($utf8NoBom.GetBytes('{"ts":"abc","expiresAt":"zz","accountIds":[oops]}' + "`n"))
            $aBytes.AddRange($ackNoise)
            $aBytes.AddRange($utf8NoBom.GetBytes("`n" + '{"ts":1,"expiresAt":9999999999,"accountIds":["'))
            [IO.File]::WriteAllBytes((Join-Path $aDir ".cache/msp/customer-creds/scope-acks.jsonl"), $aBytes.ToArray())

            $rA = Invoke-CredScript -TestDir $aDir -Arguments @("-AccountId", (Get-ScopeAcct -Lead 5 -N 7), "-Agent", "claude-code") -CloseStdin -TimeoutSeconds 30
            $rA.ExitCode | Should -Be 1 -Because "an unreadable ack file must NOT become a blanket override. stderr: $($rA.Stderr)"
            (Get-StderrLines -Stderr $rA.Stderr) | Should -Contain '[scope] reason=fan-out-threshold' -Because "the garbage-ack refusal must carry the machine token"
        }
    }

    # NAMING NOTE (harness constraint, not a weakened claim): the bash twin's label
    # reads "passes <= 5, refusals >= 1, window records >= 12". That exact wording
    # is UNUSABLE as a Pester block name -- Pester expands <...> in a block name as
    # a data-driven template, so "<= 5, refusals >" is compiled and evaluated as
    # an expression and the Context dies at setup with
    # "The term '$=' is not recognized". The bounds asserted below are identical;
    # only the rendering of the comparison operators differs.
    Context "SCOPE-8 (twin of run_scope8): D-17/A5 -- 12 parallel invocations: passes at most 5, refusals at least 1, window records at least 12 (bounds, not an exact split)" {

        # ONE fleet, THREE separately-owned claims. The run is taken once in
        # BeforeAll so all three Its describe the SAME twelve children -- which
        # matters, because the third claim is the precondition for the second.
        #
        # (1) OQ5 DIVERGENCE, stated because this file's convention is exact
        #     counts. Here the assertion is BOUNDS, deliberately: the append is
        #     unlocked and happens before any count is read, so the number that
        #     pass is "about 5", not "exactly 5". An exact assertion would flake by
        #     construction.
        # (2) `passes at most 5` was DESIGNED as a hard guarantee: every
        #     invocation appends its own record before reading, so the k-th
        #     appender observes at least k distinct ids and no more than five can
        #     observe a count inside the allowance. That argument holds only while
        #     every append survives -- see (4).
        # (3) `records at least 12` was expected to hold despite the prune,
        #     because nothing in this fixture is older than the cutoff:
        #     Invoke-ScopePrune's no-op guard skips the rewrite entirely, so no
        #     sibling's append is lost to a pre-Move-Item inode. The prune is
        #     indeed not the culprit -- see (4), measured with the prune out of
        #     the picture entirely.
        # (4) THIS CASE IS WHAT ESTABLISHES RESEARCH A5, AND A5 IS FALSE.
        #     24-03 shipped the bounded
        #     [IO.File]::Open(Append, Write, FileShare::ReadWrite) retry flagged
        #     [ASSUMED]. Measured here for the first time on 2026-08-27 (macOS
        #     25.4, pwsh 7.6.2, APFS): twelve concurrent invocations produce
        #     9-12 records, non-deterministically. Losses are WHOLE records --
        #     never torn, never duplicated, never malformed -- and the
        #     bounded-retry exhaustion branch never fires, so each losing process
        #     believes it wrote successfully. File length is always exactly
        #     45 x surviving-records, which is the signature of a seek-to-end +
        #     write rather than a true O_APPEND: two processes resolve the same
        #     end-of-file offset and the later write lands on the earlier one.
        #     A driver that calls Write-ScopeWindowRecord and NOTHING else
        #     reproduces it identically, so neither the prune nor the lock is
        #     involved.
        #     Consequence, stated plainly: the error direction is fail-OPEN (the
        #     window UNDER-counts, so the brake can only ever let MORE through,
        #     never refuse wrongly), but (2)'s counting argument breaks and
        #     `passes at most 5` degrades from a hard guarantee to a probabilistic
        #     one on the PowerShell client.
        #     Owner: 24-03. NOT repaired here -- changing the append strategy is an
        #     architectural change to a shipped client in an already-verified wave,
        #     and this plan's scope forbids it. Do NOT widen the share mode
        #     (FileShare::Delete would let a sibling's in-flight writes land in an
        #     orphaned inode). Reported in 24-07-SUMMARY.md.
        BeforeAll {
            $script:Scope8Dir = Join-Path $TestDrive "scope8-$([IO.Path]::GetRandomFileName())"
            $script:Scope8Fleet = Invoke-ScopeParallelFleet -Dir $script:Scope8Dir -Count 12
        }

        # Claim 1 -- outcome SHAPE. Independent of the A5 defect: with 12 children
        # and at most a handful of lost records, at least nine distinct ids always
        # survive, so a refusal is guaranteed. Asserted hard on every run.
        It "produces only passes and refusals across all 12 children, at least one refusal, and pure stdout in both directions" {
            $fleet = $script:Scope8Fleet
            foreach ($out in $fleet.PassStdout) {
                Assert-Pure5KeyStdout -Stdout $out -Because "a concurrent pass must still emit the 5-key contract"
            }
            foreach ($out in $fleet.RefuseStdout) {
                Assert-EmptyStdout -Stdout $out -Because "a concurrent refusal must write zero bytes to stdout"
            }
            $fleet.Refusals | Should -BeGreaterOrEqual 1 -Because "12 distinct accounts must produce at least one refusal. verdicts: $($fleet.Verdicts)"
            # No third outcome. Without this, a fixture where eleven children
            # crashed on an unrelated error would satisfy every bound and prove
            # nothing.
            ($fleet.Passes + $fleet.Refusals) | Should -Be 12 -Because "an unrelated failure mode is present. verdicts: $($fleet.Verdicts)"
        }

        # Claim 2 -- D-17's ALLOWANCE. THE BOUND IS NOT RELAXED: `-le 5` is
        # asserted verbatim on every run.
        #
        # HISTORY, kept rather than deleted because it explains the shape of this
        # case. Until 24-08 this It opened with a CONTAMINATION GUARD: if fewer
        # than 12 window records survived it rendered Inconclusive instead of a
        # verdict, on the reasoning that a fixture which lost window records
        # before the brake ever read them is not a measurement OF the brake. That
        # guard existed for the 24-03 unlocked-append defect (RESEARCH A5), whose
        # owner was 24-03 and which is now CLOSED by 24-08's Write-ScopeLineLocked
        # .scope.lock serialization.
        #
        # With that defect closed, `Records -lt 12` is no longer an expected input
        # state -- it is a 24-08 REGRESSION. The former guard is therefore now a
        # hard PRECONDITION assertion: the case still refuses to render a verdict
        # on corrupt input, but it reports that input as a FAILURE rather than
        # hiding it behind an Inconclusive, and the message names which defect
        # regressed so the next reader does not re-litigate the brake.
        #
        # A brake that genuinely over-admits still fails on the second assertion,
        # because the mutation that breaks it (moving Write-ScopeWindowRecord
        # after the count read) leaves all 12 records on disk and therefore sails
        # straight through the precondition.
        It "admits no more than the 5-account allowance when every window record survived" {
            $fleet = $script:Scope8Fleet
            $fleet.Records | Should -BeGreaterOrEqual 12 -Because "precondition: the D-17 counting argument requires every window record to survive. If this fails, 24-08's lock serialization regressed, not the brake. records=$($fleet.Records) verdicts: $($fleet.Verdicts)"
            $fleet.Passes | Should -BeLessOrEqual 5 -Because "the allowance is 5 distinct unapproved accounts. verdicts: $($fleet.Verdicts)"
        }

        # Claim 3 -- RESEARCH A5 itself, RE-ARMED. `-ge 12` verbatim, five times.
        #
        # RE-VERIFIED 2026-08-28 (24-08 / WR-01) on macOS 25.4, pwsh 7.6.2, APFS:
        # 5 of 5 independent 12-child fleets produced 12 window records, zero
        # loss. Before 24-08 the same measurement produced 9-12 records
        # non-deterministically (recorded in 24-07-SUMMARY.md); the cause was the
        # unlocked seek-to-end append and the fix is Write-ScopeLineLocked's
        # .scope.lock serialization. This It no longer MEASURES whether A5 holds
        # -- it ASSERTS that it does.
        #
        # WHY FIVE FLEETS AND NOT ONE. The pre-fix code satisfied this bound
        # roughly 40% of the time, so a single observation of a concurrency fix
        # proves almost nothing. These five are five INDEPENDENT assertions, ALL
        # of which must pass. This is emphatically NOT a retry wrapper and one
        # must never be added here -- 24-07's rule stands: retrying is how a real
        # defect becomes a flake. Each fleet gets its OWN directory: twelve
        # children sharing one window file is the entire point, but two fleets
        # sharing one is not.
        It "RESEARCH A5 (re-verified 24-08): the lock-serialized append survives 12-way concurrency with zero record loss" {
            # Observation #1 is the shared BeforeAll fleet; #2..#5 are fresh.
            $counts = @($script:Scope8Fleet.Records)
            $timeouts = @($script:Scope8Fleet.LockTimeouts)
            for ($iter = 2; $iter -le 5; $iter++) {
                $iterDir = Join-Path $TestDrive "scope8-a5-$iter-$([IO.Path]::GetRandomFileName())"
                $fleet = Invoke-ScopeParallelFleet -Dir $iterDir -Count 12
                $counts += $fleet.Records
                $timeouts += $fleet.LockTimeouts
            }
            foreach ($observed in $counts) {
                $observed | Should -BeGreaterOrEqual 12 -Because "observed record counts across 5 fleets: $($counts -join ', '). Any value below 12 means the lock serialization regressed (24-08 / WR-01) and D-17's allowance stops being a hard guarantee on this client."
            }
            ($timeouts | Measure-Object -Sum).Sum | Should -Be 0 -Because "all five fleets must stay on the serialized path; timeout counts: $($timeouts -join ', ')"
        }
    }

    Context "SCOPE-9: the ack append is fail-CLOSED -- an unwritable scope-acks.jsonl reports write-failed and never claims an approval" {

        # MUTATION CHECK (verified): replacing the ack append's exhaustion branch
        # with the swallowing `catch {}` analog used by the WINDOW append makes
        # this case red -- the command would report an approval it did not record.
        #
        # 24-05 left [scope-ack] reason=write-failed unexercised on the bash side
        # (a disk-full fixture was judged not worth its flake budget) and asked
        # this plan to decide. Decision: exercise it here, POSIX-only, with an
        # honest skip elsewhere. It is worth doing on THIS side because the pwsh
        # ack append is fail-CLOSED by 24-04's design and that branch is a `catch`
        # under $ErrorActionPreference = "Stop" -- the single most likely place for
        # a port to silently swallow and report success.
        It "reports write-failed, leaves the record intact, and never prints an approval it did not achieve" {
            if ($IsWindows) {
                # NOT COVERAGE -- a real, named gap. chmod is a no-op on Windows and
                # the equivalent fixture needs an ACL DENY entry that a
                # developer-machine run would frequently execute as an
                # administrator and defeat. Recorded in 24-07-SUMMARY.md as an
                # untested-on-Windows branch, not papered over.
                Set-ItResult -Skipped -Because "the Windows ACL equivalent of chmod 0444 is not exercised -- named as a real gap in 24-07-SUMMARY.md"
                return
            }
            $uid = (id -u) 2>$null
            if ("$uid" -eq "0") {
                Set-ItResult -Skipped -Because "running as root: mode bits are bypassed and the fixture would silently succeed"
                return
            }

            $testDir = Join-Path $TestDrive "scope9-$([IO.Path]::GetRandomFileName())"
            New-Item -ItemType Directory -Path $testDir -Force | Out-Null
            $b1 = Get-ScopeAcct -Lead 6 -N 1
            $b2 = Get-ScopeAcct -Lead 6 -N 2

            $seed = Invoke-CredScript -TestDir $testDir -Arguments @("scope-ack", "--account-ids", "$b1,$b2") -CloseStdin -TimeoutSeconds 20
            $seed.ExitCode | Should -Be 0 -Because "the seeding scope-ack must succeed. stderr: $($seed.Stderr)"

            $recPath = Join-Path $testDir ".cache/msp/customer-creds/scope-acks.jsonl"
            $beforeBytes = [IO.File]::ReadAllBytes($recPath)

            try {
                chmod 0444 $recPath
                # T-24-09: the fixture targets the FILE, never the directory, so it
                # cannot mask a directory-permission regression that 24-02/24-04 own.
                $r = Invoke-CredScript -TestDir $testDir -Arguments @("scope-ack", "--account-ids", "$b1,$b2") -CloseStdin -TimeoutSeconds 20 -CaptureTag "-ro"

                $r.ExitCode | Should -Be 1 -Because "an unwritable ack record must abort. stderr: $($r.Stderr)"
                Assert-EmptyStdout -Stdout $r.Stdout -Because "an aborted scope-ack writes nothing to stdout"
                $lines = Get-StderrLines -Stderr $r.Stderr
                $lines.Count | Should -BeGreaterThan 0 -Because "the abort must report a reason"
                $lines[0].Trim() | Should -Be '[scope-ack] reason=write-failed' -Because "full stderr: $($r.Stderr)"

                # The assertion that makes this case worth writing: the command did
                # not report a success it did not achieve.
                ([string]$r.Stdout + [string]$r.Stderr).Contains('accounts approved until') |
                    Should -BeFalse -Because "a failed ack must never claim an approval"

                $afterBytes = [IO.File]::ReadAllBytes($recPath)
                [Convert]::ToBase64String($afterBytes) | Should -Be ([Convert]::ToBase64String($beforeBytes)) -Because "no partial write may reach a read-only record"
            }
            finally {
                # Restore the mode so TestDrive cleanup cannot fail.
                chmod 0644 $recPath 2>$null
            }
        }
    }
}
