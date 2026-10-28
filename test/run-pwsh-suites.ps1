# .github/scripts/run-pwsh-suites.ps1 — run every *.test.ps1 in a directory,
# record one JSON line per suite, and never short-circuit on the first failure.
#
# Usage: pwsh -NoProfile -File .github/scripts/run-pwsh-suites.ps1 [DIR]
#   DIR   directory scanned NON-recursively for *.test.ps1. Default: test
#
# Env:
#   RUNNER_RECORD_FILE   JSONL record path.      Default .ci-records/pwsh.jsonl
#   RUNNER_CAPTURE_DIR   per-suite capture dir.  Default .ci-records/pwsh
#
# Exit: 0 iff every suite in DIR passed judgement. 1 otherwise, and 1 on a hard
#       precondition failure (Pester absent; DIR holds no *.test.ps1). A missing
#       prerequisite is NEVER a SKIP here — ci.yml's `Ensure AWS CLI` step is the
#       house precedent: say what would silently go green, ::error::, exit 1.
#
# Why this loop lives in a FILE instead of inline in ci.yml
# --------------------------------------------------------
# CI-03 requires the must-fail canary run and the normal run to execute the SAME
# loop; a copy of the loop proves nothing about the loop CI actually uses. While
# the loop was an inline `run:` block there was no file to share. 27-05 rewires
# ci.yml to call this script for both `test` and `test/canary`.
#
# Getting the L3 story right (27-RESEARCH F-1 / F-2)
# --------------------------------------------------
# The roadmap's L3 hypothesis was that `$LASTEXITCODE` never propagated Pester
# failures. That hypothesis is FALSE and should not be repeated: Pester 5's
# auto-run path ends with `exit $global:LASTEXITCODE` and `Invoke-Pester` always
# sets it, so the old `& $t.FullName; if ($LASTEXITCODE -ne 0)` loop WAS
# propagating ordinary Pester failures. The justification for the canary is
# different and stronger: this script REPLACES that loop, and the canary proves
# the NEW loop still propagates, on every single run.
#
# What the old loop genuinely did not catch — the three paths F-2 measured:
#   1. a .test.ps1 whose tests all vanished runs zero tests and leaves
#      $LASTEXITCODE at the PREVIOUS suite's value (stale inheritance);
#   2. a prereq head block (`Write-Host "SKIP: ..."; exit 0`, as in
#      test/doctor.test.ps1:33-41) sets $LASTEXITCODE to 0 explicitly and skips
#      the entire suite silently;
#   3. once execution is inside `Invoke-Pester`, a top-level `exit 1` in a
#      container is swallowed entirely — nothing exits, nothing is reported.
# `TotalCount -eq 0` is the SINGLE rule that closes all three. Do not delete it
# as redundant. test/canary/zero-tests.test.ps1 makes it fire on every run.
#
# The other thing this file must never lose: routing is derived from file
# CONTENT, never from a hand-maintained filename list. Seven of the nine repo
# suites are Pester; test/get-sts-token.test.ps1 and test/migrate.test.ps1 are
# NOT (their own headers say so) and exit with their FAILURE COUNT rather than
# 0/1 (C-8) — hence the `-ne 0` judgement below, never `-eq 1`. Feeding those two
# to Invoke-Pester runs their bodies as a Discovery side effect, reports
# TotalCount=0 and corrupts their $script: counters (measured locally as
# "RESULT: all 0 cases PASS"). A filename list would rot the first time a suite
# is renamed or converted; the `^\s*Describe\b` oracle was verified to agree with
# Pester Discovery on all nine suites (RESEARCH §Pattern 3-B).
#
# Security (T-27-04): $Dir reaches only `Get-ChildItem -LiteralPath`. There is no
# `Invoke-Expression`, no string-built command line, and 27-05 passes literals
# rather than any ${{ github.event.* }} interpolation. Do not introduce
# interpolation here.
#
# Record schema — one compact JSON object per line, appended to
# $RUNNER_RECORD_FILE. Field names and types are IDENTICAL to
# .github/scripts/run-bash-suites.sh; keep the two in sync (27-04 codes against
# this contract without reading either runner's source):
#
#   {"runner":"pwsh","suite":"test/doctor.test.ps1","rc":0,
#    "total":17,"skipped":0,"capture":".ci-records/pwsh/doctor.test.ps1.log"}
#
#   runner   "bash" | "pwsh"
#   suite    DIR + "/" + filename (the invocation uses the resolved absolute
#            path for robustness; the RECORD carries the DIR-relative form so
#            both runners' rows are directly comparable)
#   rc       runner judgement for the Pester branch (0/1); $LASTEXITCODE for the
#            non-Pester branch (which is a failure COUNT, not 0/1)
#   total    test-case count, or -1 when it could not be determined
#   skipped  SKIP count. AUTHORITATIVE: 27-04's gate reads this field rather
#            than re-deriving counts from the capture
#   capture  path to this suite's capture file
#
# Capture files:
#   non-Pester branch — real merged stream (all streams via *>&1).
#   Pester branch     — SYNTHESIZED from the result object: one `RUNNER: pester`
#            counts line plus one `SKIP: <test>` line per skipped test, so the
#            file is greppable with the same `^SKIP:` anchor the bash runner
#            uses. Pester's console output is deliberately NOT teed: piping
#            `Invoke-Pester -PassThru` would push the result object into the pipe
#            and destroy the judgement. For this branch the record's `skipped`
#            field is authoritative and the capture is the diagnostic surface.
#
# `total` / `skipped` derivation for the text-scanned branch matches the bash
# runner exactly (first hit wins): `^RESULT: all N case`, then
# `^RESULT: N case(s) FAILED (out of M)` with an UNANCHORED tail (doctor.test.sh
# appends prose after the paren), then the count of `^PASS: ` lines (the only
# path for migrate.test.ps1:454, which prints "RESULT: all cases PASS" with no
# number), else -1. All matching is case-SENSITIVE (`-cmatch`) to mirror
# `grep '^SKIP:'`; the suites contain SKIP_PROFILES / PARITY-SKIP / SKIP_RECORD
# identifiers that a loose match would count as skips (§P-2).
#
# Error-preference scoping — why both suite invocations are wrapped
# -----------------------------------------------------------------
# PowerShell preference variables are DYNAMICALLY scoped, so the script-scope
# `$ErrorActionPreference = 'Stop'` below leaks into everything this runner
# calls — including every suite, on BOTH branches. That is wrong. `Stop` is the
# runner's OWN policy (a bug in this file must fail loudly, never silently skip
# a suite); a suite's error semantics belong to the suite, and a suite that
# wants `Stop` sets it itself.
#
# Measured, not theoretical (pwsh 7.6.2 / Pester 5.7.1, macOS):
#   Invoke-Pester -Path test/update.test.ps1 -PassThru           -> 12/12 pass
#   same call with $ErrorActionPreference = 'Stop' set first     -> 11/12
# The casualty is test/update.test.ps1:406, UPDATE-04 "rolls back failed agent
# independently". That test chmods the kiro agent directory unreadable on
# purpose, so self-update.ps1:208's `Test-Path -LiteralPath` emits a
# NON-terminating "Access to the path ... is denied". Under an inherited
# `Stop` that error becomes TERMINATING: `Try-SelfUpdate` aborts before it
# writes the claude_code SKILL.md and the `Should -Match "v9\.9\.9"` assertion
# fails. The runner would have turned a green suite red — the mirror image of
# the silent-green this plan exists to remove.
#
# Hence both invocation sites save `$ErrorActionPreference`, set it to
# 'Continue' (what a suite gets when run standalone) for the duration of the
# call, and restore it in a `finally`. Do not "simplify" this away: deleting
# either wrapper reintroduces the UPDATE-04 failure on every run.
#
# Style: diagnostics go through Write-Host only — the repo bans Write-Output in
# scripts because it pollutes the stdout contract.

param([string]$Dir = 'test')

# Runner-scope only. Never allowed to reach a suite — see the header section
# "Error-preference scoping" and the wrappers in the loop below.
$ErrorActionPreference = 'Stop'

function Stop-Hard([string]$Message) {
    Write-Host "::error::run-pwsh-suites: $Message"
    exit 1
}

# ── Capture-file scanners (same rules as run-bash-suites.sh) ─────────────────

function Get-CaptureTotal([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return -1 }
    $lines = @(Get-Content -LiteralPath $Path -ErrorAction SilentlyContinue)
    if ($lines.Count -eq 0) { return -1 }

    foreach ($line in $lines) {
        if ($line -cmatch '^RESULT: all ([0-9]+) case') { return [int]$Matches[1] }
    }
    foreach ($line in $lines) {
        # End deliberately unanchored: doctor.test.sh:106 appends trailing prose.
        if ($line -cmatch '^RESULT: [0-9]+ case\(s\) FAILED \(out of ([0-9]+)\)') { return [int]$Matches[1] }
    }
    $passCount = @($lines | Where-Object { $_ -cmatch '^PASS: ' }).Count
    if ($passCount -gt 0) { return $passCount }
    return -1
}

function Get-CaptureSkipped([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return 0 }
    $lines = @(Get-Content -LiteralPath $Path -ErrorAction SilentlyContinue)
    if ($lines.Count -eq 0) { return 0 }
    return @($lines | Where-Object { $_ -cmatch '^SKIP:' }).Count
}

function Write-Capture([string]$Path, [string[]]$Lines) {
    if ($null -eq $Lines -or $Lines.Count -eq 0) {
        Set-Content -LiteralPath $Path -Value ''
    } else {
        Set-Content -LiteralPath $Path -Value $Lines
    }
}

# ── Preconditions — fail loud, never SKIP ────────────────────────────────────

$pesterAvailable = Get-Module -ListAvailable -Name Pester |
    Where-Object { $_.Version -ge [version]'5.0.0' } |
    Sort-Object Version -Descending |
    Select-Object -First 1

if (-not $pesterAvailable) {
    Stop-Hard ("Pester 5+ not found. Seven of the nine PowerShell suites are Pester files; " +
        "without the module they would either be skipped or produce zero tests, and CI would " +
        "report a passing test job that asserted nothing. Install Pester 5 and re-run. " +
        "SKIP is not an acceptable outcome for a missing prerequisite.")
}

Import-Module -Name Pester -MinimumVersion 5.0 -ErrorAction Stop
$pesterVersion = (Get-Module -Name Pester).Version

$dirNorm = $Dir.TrimEnd('/', '\')
if ([string]::IsNullOrWhiteSpace($dirNorm)) { $dirNorm = $Dir }

if (-not (Test-Path -LiteralPath $dirNorm -PathType Container)) {
    Stop-Hard "directory '$dirNorm' does not exist."
}

# NON-recursive on purpose (C-2). Never add -Recurse: it would drag test/canary/
# into the normal run and make CI permanently red (D-04).
$files = @(Get-ChildItem -LiteralPath $dirNorm -Filter *.test.ps1 -File | Sort-Object Name)

if ($files.Count -eq 0) {
    Stop-Hard ("no *.test.ps1 found under '$dirNorm'. An empty match is not an error, it is a " +
        "silent zero-work green: the loop would run nothing and exit 0, and CI would report a " +
        "passing test job that executed no tests. Check the directory argument.")
}

$recordFile = if ($env:RUNNER_RECORD_FILE) { $env:RUNNER_RECORD_FILE } else { '.ci-records/pwsh.jsonl' }
$captureDir = if ($env:RUNNER_CAPTURE_DIR) { $env:RUNNER_CAPTURE_DIR } else { '.ci-records/pwsh' }

$recordDir = Split-Path -Parent $recordFile
if ($recordDir) { New-Item -ItemType Directory -Force -Path $recordDir | Out-Null }
New-Item -ItemType Directory -Force -Path $captureDir | Out-Null

if (Test-Path -LiteralPath $recordFile) {
    Clear-Content -LiteralPath $recordFile
} else {
    New-Item -ItemType File -Force -Path $recordFile | Out-Null
}

# Required diagnostic: the interpreter/Pester pair that produced these results.
# Printed BEFORE the first suite so a truncated log still carries it.
Write-Host "run-pwsh-suites: pwsh $($PSVersionTable.PSVersion) / Pester $pesterVersion"
Write-Host "run-pwsh-suites: scanning '$dirNorm' ($($files.Count) suites)"

# ── Loop — one record per suite, no short-circuit ────────────────────────────

$rc = 0
$failed = 0

foreach ($file in $files) {
    $suitePath = "$dirNorm/$($file.Name)"
    $capture   = Join-Path $captureDir "$($file.Name).log"

    $suiteRc = 0
    $total   = -1
    $skipped = 0

    Write-Host "::group::$suitePath"

    try {
        # Content oracle. NEVER a filename list — see the header.
        $isPester = [bool](Select-String -LiteralPath $file.FullName -Pattern '^\s*Describe\b' -Quiet)

        if ($isPester) {
            # Run the suite under ITS OWN error semantics, not the runner's
            # 'Stop'. Header section "Error-preference scoping" has the measured
            # case (test/update.test.ps1:406 / UPDATE-04). Keep the finally.
            $eapSaved = $ErrorActionPreference
            try {
                $ErrorActionPreference = 'Continue'
                $r = Invoke-Pester -Path $file.FullName -PassThru -Output Detailed
            } finally {
                $ErrorActionPreference = $eapSaved
            }

            $total   = [int]$r.TotalCount
            $skipped = [int]$r.SkippedCount

            # TotalCount -eq 0 is load-bearing: it is the only clause that
            # catches F-2's three silent-green paths. Do not remove it.
            $suiteFailed = ($r.FailedCount -gt 0) -or
                           ($r.FailedContainersCount -gt 0) -or
                           ($r.TotalCount -eq 0)
            $suiteRc = if ($suiteFailed) { 1 } else { 0 }

            $skipLines = @()
            try {
                $skipLines = @(@($r.Tests) |
                    Where-Object { $_.Result -eq 'Skipped' } |
                    ForEach-Object {
                        $name = $_.ExpandedPath
                        if (-not $name) { $name = $_.Name }
                        "SKIP: $name"
                    })
            } catch {
                $skipLines = @()
            }

            # If the installed Pester exposes a different per-test shape, fall
            # back to generic lines so the capture's anchored ^SKIP: count still
            # matches the record's authoritative `skipped` field.
            if ($skipLines.Count -ne $skipped) {
                $skipLines = @()
                for ($i = 1; $i -le $skipped; $i++) {
                    $skipLines += "SKIP: $($file.Name) (skipped $i of $skipped)"
                }
            }

            $capLines = @(
                "RUNNER: pester $suitePath total=$total failed=$($r.FailedCount) skipped=$skipped failedContainers=$($r.FailedContainersCount)"
            ) + $skipLines
            Write-Capture -Path $capture -Lines $capLines
        }
        else {
            # Reset first: a suite with no `exit` would otherwise inherit the
            # PREVIOUS suite's status (F-2 path 1).
            $global:LASTEXITCODE = 0

            # Buffered capture, not `| Tee-Object`. Two reasons, both structural:
            # a pipeline makes $LASTEXITCODE unreliable to read on the next line,
            # and Out-String-style rendering can wrap long lines and break the
            # ^RESULT: / ^PASS: / ^SKIP: anchors the scanners depend on. Buffering
            # keeps one output record per line, so the anchors survive verbatim.
            #
            # Same preference wrapper as the Pester branch: these two harnesses
            # count their own failures and must not inherit the runner's 'Stop'
            # (header section "Error-preference scoping"). $LASTEXITCODE is read
            # inside the try, on the line immediately after the call.
            $eapSaved = $ErrorActionPreference
            try {
                $ErrorActionPreference = 'Continue'
                $out = & $file.FullName *>&1
                $suiteRc = [int]$LASTEXITCODE
            } finally {
                $ErrorActionPreference = $eapSaved
            }

            $outLines = @($out | ForEach-Object { [string]$_ })
            Write-Capture -Path $capture -Lines $outLines
            foreach ($line in $outLines) { Write-Host $line }

            $total   = Get-CaptureTotal $capture
            $skipped = Get-CaptureSkipped $capture

            # Judgement for this branch is `$suiteRc -ne 0`, applied once at the
            # bottom of the loop. NEVER compare `-eq 1`: get-sts-token.test.ps1
            # and migrate.test.ps1 exit with their FAILURE COUNT (C-8), so a
            # 3-failure run exits 3 and an `-eq 1` test would call it a pass.
        }
    }
    catch {
        # One suite throwing must not abort the run — record it and continue.
        Write-Host "run-pwsh-suites: $suitePath threw: $($_.Exception.Message)"
        $suiteRc = 1
        $total   = -1
        $skipped = 0
        Write-Capture -Path $capture -Lines @("RUNNER: exception $($_.Exception.Message)")
    }

    Write-Host "::endgroup::"
    Write-Host "run-pwsh-suites: $suitePath rc=$suiteRc total=$total skipped=$skipped"

    $record = [ordered]@{
        runner  = 'pwsh'
        suite   = $suitePath
        rc      = [int]$suiteRc
        total   = [int]$total
        skipped = [int]$skipped
        capture = $capture
    }
    Add-Content -LiteralPath $recordFile -Value ($record | ConvertTo-Json -Compress)

    if ($suiteRc -ne 0) {
        $rc = 1
        $failed++
    }
}

Write-Host "run-pwsh-suites: $($files.Count) suites, $failed failed"
exit $rc
