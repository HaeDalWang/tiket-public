# Phase 18 -- get-sts-token.ps1 (login-only) tests -- PowerShell twin of
# test/get-sts-token.test.sh. Plain pass/fail counter harness (NOT Pester) so it
# runs directly via `pwsh -NoProfile -File test/get-sts-token.test.ps1` and sets
# a deterministic exit code ($LASTEXITCODE == failure count).
#
# Requirements covered (18-VALIDATION anchor invariants #1, #4, #5):
#   CLI-03: after a successful Slack login, sts-token.json persists ONLY the
#           identity/cadence fields and NONE of AccessKeyId/SecretAccessKey/
#           SessionToken (zero privileged residue ON DISK).
#   CLI-03 / ROADMAP SC3: the fresh-login run EMITS the same identity-only
#           projection on STDOUT (no AWS credential distributed).
#   CLI-03: -CheckOnly returns exit 0 (valid) / exit 2 (expired-absent), no browser.
#   CLI-03 (migration): a pre-existing full-AWS-session sts-token.json is
#           overwritten with identity-only by the login-only run.
#
# Stubbing model (mirrors get-customer-credentials.test.ps1's wrapper pattern):
#   - A generated wrapper.ps1 sets HOME/USERPROFILE to the case dir and defines
#     stub Invoke-WebRequest (the /v1/credentials POST -> canned 9-key body) and
#     Invoke-RestMethod (self-update probes -> $null no-op) that SHADOW the
#     cmdlets inside the invoked script's scope. No real Slack/broker network.
#   - The OAuth loopback (HttpListener) is driven locally: the child runs with
#     -NoBrowser, the parent reads the printed auth URL to recover the CSRF
#     `state`, and delivers the callback to http://localhost:9876/callback.

$ErrorActionPreference = "Stop"

$RepoRoot = Split-Path -Parent $PSScriptRoot
$Script   = Join-Path $RepoRoot "skills/aws-customer-account-ops/get-sts-token.ps1"
$Port     = 9876

if (-not (Test-Path -LiteralPath $Script)) {
    Write-Host "FAIL: $Script missing"
    exit 1
}

$pass = 0
$fail = 0
function Pass([string]$m) { $script:pass++; Write-Host "PASS: $m" }
function Fail([string]$m) { $script:fail++; Write-Host "FAIL: $m" }

$WorkDir = Join-Path ([System.IO.Path]::GetTempPath()) ("sts-login-test-" + [System.IO.Path]::GetRandomFileName())
New-Item -ItemType Directory -Force -Path $WorkDir | Out-Null

function Get-FutureTs { [DateTimeOffset]::UtcNow.AddHours(1).ToString("yyyy-MM-ddTHH:mm:ss.000Z") }
# Realistic expiration values must work in the machine's local time zone.
function Get-FarFutureTs { [DateTimeOffset]::UtcNow.AddHours(1).ToString("yyyy-MM-ddTHH:mm:ss.000Z") }
function Get-FarPastTs   { [DateTimeOffset]::UtcNow.AddHours(-1).ToString("yyyy-MM-ddTHH:mm:ss.000Z") }

$Utf8NoBom = [System.Text.UTF8Encoding]::new($false)

function Set-Conf([string]$Dir) {
    New-Item -ItemType Directory -Force -Path (Join-Path $Dir ".config/msp") | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $Dir ".cache/msp") | Out-Null
    $conf = "API_URL=https://example.execute-api.ap-northeast-2.amazonaws.com/Prod/v1/credentials`nCLIENT_ID=test-client-id`n"
    [IO.File]::WriteAllText((Join-Path $Dir ".config/msp/credential-broker.conf"), $conf, $Utf8NoBom)
}

# The canned /v1/credentials 200 body: the full 9-key privileged login response.
function Set-LoginBody([string]$Dir) {
    $stub = Join-Path $Dir ".stub"
    New-Item -ItemType Directory -Force -Path $stub | Out-Null
    $f = Get-FutureTs
    $body = "{`"Version`":1,`"AccessKeyId`":`"ASIAEXAMPLE`",`"SecretAccessKey`":`"wJalrExampleSecretKey`",`"SessionToken`":`"FQoGExampleSessionToken`",`"Expiration`":`"$f`",`"BrokerVersion`":`"1.3.0`",`"SlackAccessToken`":`"xoxp-test-bearer-value`",`"SlackUserId`":`"U0TESTUSER`",`"BrokerMetadata`":{`"SlackUserId`":`"U0TESTUSER`"}}"
    [IO.File]::WriteAllText((Join-Path $stub "login.json"), $body, $Utf8NoBom)
}

function Set-CachedToken([string]$Dir, [string]$Exp) {
    New-Item -ItemType Directory -Force -Path (Join-Path $Dir ".cache/msp") | Out-Null
    $tok = "{`"Version`":1,`"Expiration`":`"$Exp`",`"BrokerVersion`":`"1.3.0`",`"SlackAccessToken`":`"xoxp-test-bearer-value`",`"SlackUserId`":`"U0TESTUSER`"}"
    [IO.File]::WriteAllText((Join-Path $Dir ".cache/msp/sts-token.json"), $tok, $Utf8NoBom)
}

function Set-StaleAwsSession([string]$Dir, [string]$Exp) {
    New-Item -ItemType Directory -Force -Path (Join-Path $Dir ".cache/msp") | Out-Null
    $tok = "{`"Version`":1,`"AccessKeyId`":`"ASIASTALE`",`"SecretAccessKey`":`"staleSecret`",`"SessionToken`":`"staleToken`",`"Expiration`":`"$Exp`",`"BrokerVersion`":`"1.3.0`",`"SlackAccessToken`":`"xoxp-old`",`"SlackUserId`":`"U0TESTUSER`"}"
    [IO.File]::WriteAllText((Join-Path $Dir ".cache/msp/sts-token.json"), $tok, $Utf8NoBom)
}

# Generate the wrapper that stubs the HTTP cmdlets and invokes the real script.
# -TargetScript defaults to the script under test; the HOOK-A cases point it at a
# COPY living in a synthetic skills dir whose sibling client is a recorder.
function New-Wrapper([string]$Dir, [string]$ScriptArgs, [string]$TargetScript = $Script) {
    $wrapperPath = Join-Path $Dir ("wrapper_" + [IO.Path]::GetRandomFileName() + ".ps1")
    $content = @"
`$ErrorActionPreference = 'Stop'
`$env:HOME = '$Dir'
`$env:USERPROFILE = '$Dir'
`$env:MSP_DISABLE_UPDATE = '1'

function Invoke-WebRequest {
    [CmdletBinding()]
    param(`$Uri, `$Method, `$ContentType, `$Body, `$Headers, `$TimeoutSec, `$OutFile, [switch]`$UseBasicParsing, [Parameter(ValueFromRemainingArguments=`$true)] `$Rest)
    `$stub = Join-Path `$env:HOME '.stub'
    New-Item -ItemType Directory -Force -Path `$stub | Out-Null
    Add-Content -LiteralPath (Join-Path `$stub 'iwr_calls') -Value ([string]`$Uri)
    if (`$OutFile) {
        Copy-Item -LiteralPath (Join-Path `$stub 'update.zip') -Destination `$OutFile
        return
    }
    `$body = Get-Content -Raw -LiteralPath (Join-Path `$stub 'login.json')
    return [PSCustomObject]@{ Content = `$body }
}

function Invoke-RestMethod {
    [CmdletBinding()]
    param(`$Uri, `$Method, `$ContentType, `$Body, `$Headers, `$TimeoutSec, `$OutFile, [switch]`$UseBasicParsing, [Parameter(ValueFromRemainingArguments=`$true)] `$Rest)
    `$stub = Join-Path `$env:HOME '.stub'
    if (Test-Path (Join-Path `$stub 'version.json')) {
        if (`$Uri -like '*/version') { return Get-Content -Raw (Join-Path `$stub 'version.json') | ConvertFrom-Json }
        if (`$Uri -like '*/download') {
            if (`$Headers.Authorization -eq 'Bearer xoxp-test-bearer-value' -and -not (Test-Path (Join-Path `$stub 'update-fail'))) {
                return Get-Content -Raw (Join-Path `$stub 'download.json') | ConvertFrom-Json
            }
            throw 'Invalid Slack access token'
        }
    }
    return `$null
}

& '$TargetScript' $ScriptArgs
exit `$LASTEXITCODE
"@
    [IO.File]::WriteAllText($wrapperPath, $content, $Utf8NoBom)
    return $wrapperPath
}

# Run a full login by driving the loopback. Returns @{ ExitCode; Stdout; Stderr }.
function Invoke-StsLogin([string]$Dir) {
    $wrapper = New-Wrapper -Dir $Dir -ScriptArgs "-NoBrowser"
    $out = Join-Path $Dir "stdout.txt"
    $err = Join-Path $Dir "stderr.txt"

    $proc = Start-Process -FilePath "pwsh" -ArgumentList @("-NoProfile", "-File", $wrapper) `
        -RedirectStandardOutput $out -RedirectStandardError $err -NoNewWindow -PassThru

    $state = $null
    for ($i = 0; $i -lt 200; $i++) {
        if ((Test-Path $out) -and (Select-String -Path $out -Pattern 'state=' -Quiet -ErrorAction SilentlyContinue)) {
            $line = Get-Content -LiteralPath $out | Where-Object { $_ -match 'state=([A-Za-z0-9._~%-]+)' } | Select-Object -First 1
            if ($line -and $line -match 'state=([A-Za-z0-9._~%-]+)') {
                $state = $Matches[1]
                break
            }
        }
        if ($proc.HasExited) { break }
        Start-Sleep -Milliseconds 250
    }

    if (-not $state) {
        try { $proc.Kill() } catch { }
        $proc.WaitForExit(5000) | Out-Null
        return @{ ExitCode = 127; Stdout = (Get-Content -Raw $out -ErrorAction SilentlyContinue); Stderr = (Get-Content -Raw $err -ErrorAction SilentlyContinue) }
    }

    try {
        Invoke-WebRequest -Uri "http://localhost:$Port/callback?code=test-auth-code&state=$state" -UseBasicParsing -TimeoutSec 10 | Out-Null
    } catch { }

    if (-not $proc.WaitForExit(30000)) {
        try { $proc.Kill() } catch { }
    }

    $stdout = if (Test-Path $out) { Get-Content -Raw -LiteralPath $out } else { "" }
    $stderr = if (Test-Path $err) { Get-Content -Raw -LiteralPath $err } else { "" }
    return @{ ExitCode = $proc.ExitCode; Stdout = $stdout; Stderr = $stderr }
}

# Run a synchronous -CheckOnly invocation (no OAuth reached).
function Invoke-StsCheckOnly([string]$Dir, [string]$TargetScript = $Script) {
    $wrapper = New-Wrapper -Dir $Dir -ScriptArgs "-CheckOnly" -TargetScript $TargetScript
    $out = Join-Path $Dir "stdout.txt"
    $err = Join-Path $Dir "stderr.txt"
    $proc = Start-Process -FilePath "pwsh" -ArgumentList @("-NoProfile", "-File", $wrapper) `
        -RedirectStandardOutput $out -RedirectStandardError $err -NoNewWindow -PassThru -Wait
    $stdout = if (Test-Path $out) { Get-Content -Raw -LiteralPath $out } else { "" }
    $stderr = if (Test-Path $err) { Get-Content -Raw -LiteralPath $err } else { "" }
    return @{ ExitCode = $proc.ExitCode; Stdout = $stdout; Stderr = $stderr }
}

# -- HOOK-A fixtures ------------------------------------------------------------
# HOOK-A shells out to the SIBLING get-customer-credentials.ps1, so the cases run
# a COPY of the script under test from a synthetic skills dir where that sibling
# is a recorder we control.
#
# -Mode record -- recorder sibling: logs argv, writes a line to STDOUT (which the
#                 hook must swallow) and a mapping table to STDERR (which the hook
#                 must let through)
# -Mode absent -- no sibling at all
# Returns the path of the copied get-sts-token.ps1.
function Set-SkillDir([string]$Dir, [string]$Mode, [int]$ChildRc = 0) {
    $sd = Join-Path $Dir "skills"
    New-Item -ItemType Directory -Force -Path $sd | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $Dir ".stub") | Out-Null
    Copy-Item -LiteralPath $Script -Destination (Join-Path $sd "get-sts-token.ps1") -Force

    if ($Mode -ne "absent") {
        $arrow = [char]0x2192
        $recorder = @"
# Recorder stand-in for the real client. Logs argv, then deliberately writes to
# BOTH streams so the hook's stdout-only redirection is observable from outside.
`$stub = Join-Path `$env:HOME '.stub'
New-Item -ItemType Directory -Force -Path `$stub | Out-Null
Add-Content -LiteralPath (Join-Path `$stub 'gcc_calls') -Value (`$args -join ' ')
[Console]::Out.WriteLine('STDOUT-LEAK-FROM-MIGRATE')
[Console]::Error.WriteLine('[migrate] samplecorp $arrow csg-samplecorp')
[Console]::Error.WriteLine('[migrate] rewritten=1')
exit $ChildRc
"@
        [IO.File]::WriteAllText((Join-Path $sd "get-customer-credentials.ps1"), $recorder, $Utf8NoBom)
    }

    return (Join-Path $sd "get-sts-token.ps1")
}

# ConvertTo-CapturedText: normalize a captured stream to a plain [string].
# `Get-Content -Raw` on an EMPTY capture file yields AutomationNull, and casting
# that to [string] still yields $null -- so `.Contains()` on it throws, and
# `-match`/`-notmatch` treat it as a COLLECTION and return an empty (falsy)
# array instead of $true. Either way an "empty stream" assertion silently
# passes/throws instead of failing honestly. Normalize once, here.
function ConvertTo-CapturedText($Value) {
    if ($null -eq $Value) { return "" }
    return [string]$Value
}

function Get-Names($obj) { @($obj.PSObject.Properties.Name) }
function Has-Any($names, [string[]]$keys) {
    foreach ($k in $keys) { if ($names -contains $k) { return $true } }
    return $false
}
function Get-EmittedJson([string]$stdout) {
    $line = ($stdout -split "`n") | Where-Object { $_.TrimStart().StartsWith('{') } | Select-Object -Last 1
    if (-not $line) { return $null }
    return ($line | ConvertFrom-Json)
}

$awsKeys = @("AccessKeyId", "SecretAccessKey", "SessionToken")

Write-Host "=== Phase 18: get-sts-token.ps1 (login-only) ==="
Write-Host ""

# -- case1: fresh login -> identity-only on disk AND on stdout ------------------
try {
    $d = Join-Path $WorkDir "case1"; New-Item -ItemType Directory -Force -Path $d | Out-Null
    $label = "CLI-03: fresh login persists identity-only ON DISK and emits identity-only ON STDOUT (no AWS creds)"
    Set-Conf $d; Set-LoginBody $d
    $r = Invoke-StsLogin $d

    if ($r.ExitCode -eq 127) {
        Fail "$label -- harness could not drive the login (no state captured). stderr: $($r.Stderr)"
    } elseif ($r.ExitCode -ne 0) {
        Fail "$label -- login exited $($r.ExitCode), expected 0. stderr: $($r.Stderr)"
    } else {
        $tok = Join-Path $d ".cache/msp/sts-token.json"
        if (-not (Test-Path -LiteralPath $tok)) {
            Fail "$label -- sts-token.json was not written"
        } else {
            $diskObj = Get-Content -Raw -LiteralPath $tok | ConvertFrom-Json
            $diskNames = Get-Names $diskObj
            $emit = Get-EmittedJson $r.Stdout

            $diskOk   = ($diskNames -contains 'SlackAccessToken') -and ($diskNames -contains 'SlackUserId') -and (-not (Has-Any $diskNames $awsKeys))
            $emitOk   = $false
            if ($emit) {
                $en = Get-Names $emit
                $emitOk = ($en -contains 'SlackAccessToken') -and ($en -contains 'SlackUserId') -and (-not (Has-Any $en $awsKeys))
            }

            if (-not $diskOk) {
                Fail "$label -- sts-token.json is not identity-only (residue ON DISK): $(Get-Content -Raw $tok)"
            } elseif (-not $emit) {
                Fail "$label -- no JSON emitted on stdout"
            } elseif (-not $emitOk) {
                Fail "$label -- stdout emission is not identity-only (residue ON STDOUT): $($emit | ConvertTo-Json -Compress)"
            } else {
                Pass $label
            }
        }
    }
} catch { Fail "case1 threw: $($_.Exception.Message)" }

# -- case2: -CheckOnly valid -> exit 0, no browser -----------------------------
try {
    $d = Join-Path $WorkDir "case2"; New-Item -ItemType Directory -Force -Path $d | Out-Null
    $label = "CLI-03: -CheckOnly with a fresh valid token exits 0 and opens no browser"
    Set-Conf $d; Set-LoginBody $d; Set-CachedToken $d (Get-FarFutureTs)
    $r = Invoke-StsCheckOnly $d
    if ($r.ExitCode -ne 0) {
        Fail "$label -- exit $($r.ExitCode), expected 0. stderr: $($r.Stderr)"
    } elseif (($r.Stdout -match 'state=') -or ($r.Stderr -match 'state=')) {
        Fail "$label -- an OAuth URL was produced under -CheckOnly"
    } else {
        Pass $label
    }
} catch { Fail "case2 threw: $($_.Exception.Message)" }

# -- case3: -CheckOnly absent -> exit 2, no browser ----------------------------
try {
    $d = Join-Path $WorkDir "case3"; New-Item -ItemType Directory -Force -Path $d | Out-Null
    $label = "CLI-03: -CheckOnly with an absent token exits 2 and opens no browser"
    Set-Conf $d; Set-LoginBody $d   # no cached token seeded
    $r = Invoke-StsCheckOnly $d
    if ($r.ExitCode -ne 2) {
        Fail "$label -- exit $($r.ExitCode), expected 2. stderr: $($r.Stderr)"
    } elseif (($r.Stdout -match 'state=') -or ($r.Stderr -match 'state=')) {
        Fail "$label -- an OAuth URL was produced under -CheckOnly"
    } else {
        Pass $label
    }
} catch { Fail "case3 threw: $($_.Exception.Message)" }

# -- case4: migration -> stale full-AWS-session file overwritten identity-only --
try {
    $d = Join-Path $WorkDir "case4"; New-Item -ItemType Directory -Force -Path $d | Out-Null
    $label = "CLI-03 (migration): a stale full-AWS-session sts-token.json is overwritten with identity-only"
    Set-Conf $d; Set-LoginBody $d; Set-StaleAwsSession $d (Get-FarPastTs)   # expired -> re-login rewrites
    $tok = Join-Path $d ".cache/msp/sts-token.json"

    $seedNames = Get-Names (Get-Content -Raw -LiteralPath $tok | ConvertFrom-Json)
    if (-not (Has-Any $seedNames $awsKeys)) {
        Fail "$label -- test seed did not contain a stale AWS session"
    } else {
        $r = Invoke-StsLogin $d
        if ($r.ExitCode -eq 127) {
            Fail "$label -- harness could not drive the login. stderr: $($r.Stderr)"
        } elseif ($r.ExitCode -ne 0) {
            Fail "$label -- login exited $($r.ExitCode), expected 0. stderr: $($r.Stderr)"
        } else {
            $afterNames = Get-Names (Get-Content -Raw -LiteralPath $tok | ConvertFrom-Json)
            if (Has-Any $afterNames $awsKeys) {
                Fail "$label -- stale AWS session still present after login-only run: $(Get-Content -Raw $tok)"
            } elseif (-not (($afterNames -contains 'SlackAccessToken') -and ($afterNames -contains 'SlackUserId'))) {
                Fail "$label -- identity fields missing after overwrite"
            } else {
                Pass $label
            }
        }
    }
} catch { Fail "case4 threw: $($_.Exception.Message)" }

# ==============================================================================
# HOOK-A -- the login path fires the fleet migration (PROF-12)
# ==============================================================================
# Self-update replaces skill FILES and never re-runs the installer, so the
# migration has to be triggered by the clients themselves. This is the ONE hook
# with a real TTY, which is why its stderr stays attached: the mapping table is
# the only human-facing artifact of the whole migration.

# -- HOOK-A-01: the sibling client is invoked, sweep FIRST then migrate ---------
# WR-05: the expected argv is now 'cleanup|migrate', not 'migrate'. That ordering
# is load-bearing, and the credential_process hook documents why: the cache is
# keyed on the ACCOUNT ID (Phase 18 collapse), so a freshly renamed csg-X
# inherits old X's <account-id>.json -- a 1-hour session, so almost always
# expired. Migrating first hands the next sweep a brand-new csg-X it classifies
# as expired and deletes on the spot, and the mapping table printed on THIS path
# (the single human-facing artifact of the whole migration) then lists profile
# names that no longer exist. `cleanup` with no --all IS that sweep.
try {
    $d = Join-Path $WorkDir "hooka1"; New-Item -ItemType Directory -Force -Path $d | Out-Null
    $label = "HOOK-A-01 WR-05: get-sts-token sweeps (cleanup) BEFORE it migrates"
    Set-Conf $d; Set-LoginBody $d; Set-CachedToken $d (Get-FarFutureTs)
    $copied = Set-SkillDir -Dir $d -Mode "record"

    $r = Invoke-StsCheckOnly $d $copied
    $callsFile = Join-Path $d ".stub/gcc_calls"
    if ($r.ExitCode -ne 0) {
        Fail "$label -- exit $($r.ExitCode), expected 0. stderr: $($r.Stderr)"
    } elseif (-not (Test-Path -LiteralPath $callsFile)) {
        Fail "$label -- the sibling client was never invoked. stderr: $($r.Stderr)"
    } elseif (((Get-Content -LiteralPath $callsFile) -join '|').Trim() -ne 'cleanup|migrate') {
        Fail "$label -- invoked with argv '$((Get-Content -LiteralPath $callsFile) -join '|')', expected exactly 'cleanup|migrate' (sweep->migrate order)"
    } else {
        Pass $label
    }
} catch { Fail "HOOK-A-01 threw: $($_.Exception.Message)" }

# -- HOOK-A-06 (WR-04): a converged machine must not fork the client at all -----
# The credential_process hook guards its call with a completion-marker check for
# this exact reason. get-sts-token.ps1 is csg-login's registered
# credential_process, so without the guard EVERY AWS call resolved through that
# profile spawned a whole pwsh subprocess and printed
# "[migrate] status=already-migrated" onto the engineer's terminal, forever.
# The assertion is on the recorder LOG, not stderr: "no output" could also come
# from a child that ran and stayed quiet; an empty/absent log proves no fork.
try {
    $d = Join-Path $WorkDir "hooka6"; New-Item -ItemType Directory -Force -Path $d | Out-Null
    $label = "HOOK-A-06 WR-04: 완료 마커가 있으면 클라이언트를 아예 실행하지 않는다"
    Set-Conf $d; Set-LoginBody $d; Set-CachedToken $d (Get-FarFutureTs)
    $copied = Set-SkillDir -Dir $d -Mode "record"

    $markerDir = Join-Path $d ".cache/msp/customer-creds"
    New-Item -ItemType Directory -Force -Path $markerDir | Out-Null
    [IO.File]::WriteAllText(
        (Join-Path $markerDir "migrations.jsonl"),
        '{"id":"v1.7-csg-namespace","completed_at":"2026-01-01T00:00:00Z","renamed":0,"repaired":0,"skipped":0}' + "`n",
        [System.Text.UTF8Encoding]::new($false))

    $r = Invoke-StsCheckOnly $d $copied
    $callsFile = Join-Path $d ".stub/gcc_calls"
    $called = (Test-Path -LiteralPath $callsFile) -and -not [string]::IsNullOrWhiteSpace((Get-Content -Raw -LiteralPath $callsFile))
    if ($r.ExitCode -ne 0) {
        Fail "$label -- exit $($r.ExitCode), expected 0. stderr: $($r.Stderr)"
    } elseif ($called) {
        Fail "$label -- 마커가 있는데도 클라이언트를 실행했습니다: $((Get-Content -LiteralPath $callsFile) -join '|')"
    } elseif ($r.Stderr -match '\[migrate\]') {
        Fail "$label -- 수렴한 머신의 stderr 에 [migrate] 줄이 있습니다: $($r.Stderr)"
    } else {
        Pass $label
    }
} catch { Fail "HOOK-A-06 threw: $($_.Exception.Message)" }

# -- HOOK-A-02: STATIC proof ----------------------------------------------------
# The workspace skill has no self-update any more (2026-10-21: a stale copy forced
# an update that could never finish, so login never completed). No remnant of it
# may come back. Also asserts $ScriptDir is assigned once and reused, and that
# stdout (not stderr) is the discarded stream.
try {
    $label = "HOOK-A-02: no self-update remnant, the hook reuses `$ScriptDir, and discards stdout only"
    $lines = [IO.File]::ReadAllLines($Script)
    $hookLine = -1; $scriptDirDefs = 0; $stderrSwallowed = $false; $remnants = @()
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match 'self-update|SelfUpdate|UpdateRequired|DeferredUpdate|Save-SlackToken') { $remnants += $i + 1 }
        if ($hookLine -lt 0 -and $lines[$i] -match 'get-customer-credentials\.ps1') {
            if ($lines[$i] -notmatch '^\s*#') { $hookLine = $i }
        }
        if ($lines[$i] -match '^\s*\$ScriptDir\s*=') { $scriptDirDefs++ }
        if ($lines[$i] -match 'migrate.*2>&1') { $stderrSwallowed = $true }
    }
    if ($hookLine -lt 0) {
        Fail "$label -- no get-customer-credentials.ps1 invocation found in $Script"
    } elseif ($remnants.Count -gt 0) {
        Fail "$label -- self-update remnants still at lines $($remnants -join ', ')"
    } elseif ($scriptDirDefs -ne 1) {
        Fail "$label -- `$ScriptDir is assigned $scriptDirDefs times, expected exactly 1 (the hook must reuse it)"
    } elseif ($stderrSwallowed) {
        Fail "$label -- the hook discards stderr too; the mapping table would be invisible"
    } else {
        Pass $label
    }
} catch { Fail "HOOK-A-02 threw: $($_.Exception.Message)" }

# -- HOOK-A-03: an absent sibling client does not break get-sts-token -----------
try {
    $d = Join-Path $WorkDir "hooka3"; New-Item -ItemType Directory -Force -Path $d | Out-Null
    $label = "HOOK-A-03: an absent sibling client does not break get-sts-token"
    Set-Conf $d; Set-LoginBody $d; Set-CachedToken $d (Get-FarFutureTs)
    $copied = Set-SkillDir -Dir $d -Mode "absent"

    $r = Invoke-StsCheckOnly $d $copied
    if ($r.ExitCode -ne 0) {
        Fail "$label -- exit $($r.ExitCode), expected 0. stderr: $($r.Stderr)"
    } else {
        Pass $label
    }
} catch { Fail "HOOK-A-03 threw: $($_.Exception.Message)" }

# -- HOOK-A-04: a failing migration does not change the exit code --------------
try {
    $d = Join-Path $WorkDir "hooka4"; New-Item -ItemType Directory -Force -Path $d | Out-Null
    $label = "HOOK-A-04: a failing migration does not affect get-sts-token's exit code"
    Set-Conf $d; Set-LoginBody $d; Set-CachedToken $d (Get-FarFutureTs)
    $copied = Set-SkillDir -Dir $d -Mode "record" -ChildRc 1

    $r = Invoke-StsCheckOnly $d $copied
    $callsFile = Join-Path $d ".stub/gcc_calls"
    if ($r.ExitCode -ne 0) {
        Fail "$label -- exit $($r.ExitCode), expected 0 despite the child failing. stderr: $($r.Stderr)"
    } elseif (-not (Test-Path -LiteralPath $callsFile)) {
        Fail "$label -- the failing child was never invoked, so nothing was proven"
    } else {
        Pass $label
    }
} catch { Fail "HOOK-A-04 threw: $($_.Exception.Message)" }

# -- HOOK-A-05: mapping table on stderr, child's stdout swallowed --------------
try {
    $d = Join-Path $WorkDir "hooka5"; New-Item -ItemType Directory -Force -Path $d | Out-Null
    $label = "HOOK-A-05: the [migrate] mapping table reaches stderr while the child's stdout is swallowed"
    Set-Conf $d; Set-LoginBody $d; Set-CachedToken $d (Get-FarFutureTs)
    $copied = Set-SkillDir -Dir $d -Mode "record"

    $r = Invoke-StsCheckOnly $d $copied
    $arrow = [char]0x2192
    # Normalizing both streams is load-bearing -- see ConvertTo-CapturedText.
    $errText = ConvertTo-CapturedText $r.Stderr
    $outText = ConvertTo-CapturedText $r.Stdout
    if ($r.ExitCode -ne 0) {
        Fail "$label -- exit $($r.ExitCode), expected 0. stderr: $errText"
    } elseif (-not $errText.Contains("[migrate] samplecorp $arrow csg-samplecorp")) {
        Fail "$label -- the mapping table did not reach stderr: [$errText]"
    } elseif ($outText.Contains('STDOUT-LEAK-FROM-MIGRATE')) {
        Fail "$label -- the child's stdout leaked into get-sts-token's stdout: [$outText]"
    } else {
        Pass $label
    }
} catch { Fail "HOOK-A-05 threw: $($_.Exception.Message)" }

Write-Host ""
Remove-Item -LiteralPath $WorkDir -Recurse -Force -ErrorAction SilentlyContinue

if ($fail -gt 0) {
    Write-Host "RESULT: $fail case(s) FAILED (out of $($pass + $fail))"
    exit $fail
}
Write-Host "RESULT: all $pass cases PASS"
exit 0
