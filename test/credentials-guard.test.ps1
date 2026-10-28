# Phase 21 -- get-customer-credentials.ps1 foreign-key sweep-guard behavioral
# tests (Pester 5.x). PowerShell twin of test/credentials-guard.test.sh.
# Covers: PROF-07 (criteria 1, 2, 4), PROF-14 (criterion 3).
#
# Stubbing model:
#   - HOME/USERPROFILE override per case isolates filesystem state
#   - Synthetic ~/.aws/config edge-case fixtures (poisoned-hybrid, CRLF, BOM,
#     quoted-name, double-space-header, [sso-session]-adjacent)
#   - Subprocess invocation via Invoke-ScriptUnderTest (copied verbatim from
#     test/cleanup.ps1.test.ps1, this codebase's established idiom)

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

    # --- Fixture builders ---

    # New-PoisonedHybridConfig: the exact incident shape -- ONE section
    # carrying BOTH our credential_process line AND SSO foreign keys.
    # Account 333333333333.
    function New-PoisonedHybridConfig {
        param([string]$Dir)

        $awsDir = Join-Path $Dir ".aws"
        New-Item -ItemType Directory -Path $awsDir -Force | Out-Null

        $configContent = @"
[profile csg-poisoned]
sso_start_url = https://example.awsapps.com/start
sso_region = ap-northeast-2
credential_process = pwsh -NoProfile -File /path/to/get-customer-credentials.ps1 -AccountId 333333333333 -Agent claude-code
region = ap-northeast-2
"@
        $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
        [IO.File]::WriteAllText((Join-Path $awsDir "config"), $configContent, $utf8NoBom)
    }

    # New-CrlfConfig: the [profile customer-a] header line genuinely ends in
    # a carriage return before the newline. Account 444444444444.
    function New-CrlfConfig {
        param([string]$Dir)

        $awsDir = Join-Path $Dir ".aws"
        New-Item -ItemType Directory -Path $awsDir -Force | Out-Null

        $lines = @(
            "[profile customer-a]`r",
            "credential_process = pwsh -NoProfile -File /path/to/get-customer-credentials.ps1 -AccountId 444444444444 -Agent claude-code",
            "region = ap-northeast-2",
            "",
            "[default]",
            "region = ap-northeast-2",
            ""
        )
        $configContent = ($lines -join "`n")
        $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
        [IO.File]::WriteAllText((Join-Path $awsDir "config"), $configContent, $utf8NoBom)
    }

    # New-BomConfig: an otherwise-normal config written WITH a UTF-8 BOM --
    # deliberately opposite this codebase's no-BOM convention, for this one
    # fixture only. Account 888888888888.
    function New-BomConfig {
        param([string]$Dir)

        $awsDir = Join-Path $Dir ".aws"
        New-Item -ItemType Directory -Path $awsDir -Force | Out-Null

        $configContent = @"
[profile customer-bom]
credential_process = pwsh -NoProfile -File /path/to/get-customer-credentials.ps1 -AccountId 888888888888 -Agent claude-code
region = ap-northeast-2

[default]
region = ap-northeast-2
"@
        $utf8Bom = [System.Text.UTF8Encoding]::new($true)
        [IO.File]::WriteAllText((Join-Path $awsDir "config"), $configContent, $utf8Bom)
    }

    # New-QuotedNameConfig: [profile 'csg-a'] -- single-quoted profile name.
    # Account 555555555555.
    function New-QuotedNameConfig {
        param([string]$Dir)

        $awsDir = Join-Path $Dir ".aws"
        New-Item -ItemType Directory -Path $awsDir -Force | Out-Null

        $configContent = @"
[profile 'csg-a']
credential_process = pwsh -NoProfile -File /path/to/get-customer-credentials.ps1 -AccountId 555555555555 -Agent claude-code
region = ap-northeast-2

[default]
region = ap-northeast-2
"@
        $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
        [IO.File]::WriteAllText((Join-Path $awsDir "config"), $configContent, $utf8NoBom)
    }

    # New-DoubleSpaceHeaderConfig: [profile  csg-a] -- two spaces between
    # "profile" and the name. Account 666666666666.
    function New-DoubleSpaceHeaderConfig {
        param([string]$Dir)

        $awsDir = Join-Path $Dir ".aws"
        New-Item -ItemType Directory -Path $awsDir -Force | Out-Null

        $configContent = @"
[profile  csg-a]
credential_process = pwsh -NoProfile -File /path/to/get-customer-credentials.ps1 -AccountId 666666666666 -Agent claude-code
region = ap-northeast-2

[default]
region = ap-northeast-2
"@
        $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
        [IO.File]::WriteAllText((Join-Path $awsDir "config"), $configContent, $utf8NoBom)
    }

    # New-SsoSessionAdjacentConfig: a modern [sso-session ...] block
    # immediately BEFORE a clean, unrelated [profile customer-a] -- proves
    # the sso_start_url/sso_region keys inside the [sso-session] block do
    # not leak into the following profile's foreign-key tracking
    # (Architecture Pattern 3's "reset on ANY [...] header" fix).
    # Account 111111111111, no foreign keys of its own.
    function New-SsoSessionAdjacentConfig {
        param([string]$Dir)

        $awsDir = Join-Path $Dir ".aws"
        New-Item -ItemType Directory -Path $awsDir -Force | Out-Null

        $configContent = @"
[sso-session my-sso]
sso_start_url = https://example.awsapps.com/start
sso_region = ap-northeast-2

[profile customer-a]
credential_process = pwsh -NoProfile -File /path/to/get-customer-credentials.ps1 -AccountId 111111111111 -Agent claude-code
region = ap-northeast-2
"@
        $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
        [IO.File]::WriteAllText((Join-Path $awsDir "config"), $configContent, $utf8NoBom)
    }

    # New-ExpiredCache: create an expired cache file (Expiration 1 hour in
    # the past). Mirrors test/cleanup.ps1.test.ps1's helper of the same
    # name. Cache key is <account-id>.json (Phase 18 scheme, no role
    # segment).
    function New-ExpiredCache {
        param([string]$Dir, [string]$AccountId)

        $cacheDir = Join-Path $Dir ".cache/msp/customer-creds"
        New-Item -ItemType Directory -Path $cacheDir -Force | Out-Null

        $expiration = [DateTimeOffset]::UtcNow.AddHours(-1).ToString("yyyy-MM-ddTHH:mm:ssZ")
        $json = @{
            Version        = 1
            AccessKeyId    = "AKIAEXPIRED"
            SecretAccessKey = "expiredsecret"
            SessionToken   = "expiredtoken"
            Expiration     = $expiration
        } | ConvertTo-Json -Compress

        $filePath = Join-Path $cacheDir "$AccountId.json"
        Set-Content -LiteralPath $filePath -Value $json -NoNewline -Encoding UTF8
    }

    # Invoke-ScriptUnderTest: copied verbatim from test/cleanup.ps1.test.ps1.
    # Runs the script under test in a subprocess with HOME/USERPROFILE
    # override. Returns hashtable with ExitCode, Stdout, Stderr keys.
    function Invoke-ScriptUnderTest {
        param(
            [string]$TestDir,
            [string[]]$Arguments
        )

        $stderrFile = Join-Path $TestDir "stderr_capture.txt"
        $stdoutFile = Join-Path $TestDir "stdout_capture.txt"
        $wrapperScript = Join-Path $TestDir "wrapper_$([IO.Path]::GetRandomFileName()).ps1"

        # Build argument array literal for the wrapper script
        $argLines = @()
        foreach ($a in $Arguments) {
            $argLines += "    `"$a`""
        }
        $argArrayLiteral = $argLines -join ",`n"

        # Write a wrapper script that sets env vars and invokes the script under test
        $wrapperContent = @"
`$ErrorActionPreference = "Stop"
`$env:HOME = "$TestDir"
`$env:USERPROFILE = "$TestDir"
`$scriptArgs = @(
$argArrayLiteral
)
& "$($script:ScriptUnderTest)" @scriptArgs
exit `$LASTEXITCODE
"@
        $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
        [IO.File]::WriteAllText($wrapperScript, $wrapperContent, $utf8NoBom)

        $proc = Start-Process -FilePath "pwsh" `
            -ArgumentList @("-NoProfile", "-File", $wrapperScript) `
            -RedirectStandardOutput $stdoutFile `
            -RedirectStandardError $stderrFile `
            -NoNewWindow -Wait -PassThru

        $stdout = ""
        $stderr = ""
        if (Test-Path $stdoutFile) { $stdout = Get-Content -Raw -LiteralPath $stdoutFile }
        if (Test-Path $stderrFile) { $stderr = Get-Content -Raw -LiteralPath $stderrFile }

        return @{
            ExitCode = $proc.ExitCode
            Stdout   = $stdout
            Stderr   = $stderr
        }
    }
}

Describe "Credentials Guard (PROF-07, PROF-14)" {

    Context "sso-session-adjacent config does not leak foreign keys into the following profile" {
        It "removes the expired customer-a profile when sweep is triggered by an unrelated invocation" {
            $testDir = Join-Path $TestDrive "case-sso-adjacent-$([IO.Path]::GetRandomFileName())"
            New-Item -ItemType Directory -Path $testDir -Force | Out-Null

            New-SsoSessionAdjacentConfig -Dir $testDir
            New-ExpiredCache -Dir $testDir -AccountId "111111111111"

            # Trigger auto-sweep via an unrelated account so customer-a's own
            # PROF-06 self-protection does not apply.
            $result = Invoke-ScriptUnderTest -TestDir $testDir -Arguments @(
                "-AccountId", "999999999999",
                "-Agent", "claude-code"
            )

            $configContent = Get-Content -Raw (Join-Path $testDir ".aws/config")
            $configContent | Should -Not -Match '\[profile customer-a\]'
        }
    }

    Context "CRLF header survives cleanup --all without crashing or corrupting the config" {
        It "exits 0 and leaves a valid, non-empty config" {
            $testDir = Join-Path $TestDrive "case-crlf-$([IO.Path]::GetRandomFileName())"
            New-Item -ItemType Directory -Path $testDir -Force | Out-Null

            New-CrlfConfig -Dir $testDir

            $result = Invoke-ScriptUnderTest -TestDir $testDir -Arguments @("cleanup", "--all")

            $result.ExitCode | Should -Be 0
            $configContent = Get-Content -Raw (Join-Path $testDir ".aws/config")
            $configContent | Should -Not -BeNullOrEmpty
            $configContent | Should -Match '^\['
        }
    }

    Context "BOM-encoded config survives cleanup --all without crashing or corrupting the config" {
        It "exits 0 and leaves a valid, non-empty config" {
            $testDir = Join-Path $TestDrive "case-bom-$([IO.Path]::GetRandomFileName())"
            New-Item -ItemType Directory -Path $testDir -Force | Out-Null

            New-BomConfig -Dir $testDir

            $result = Invoke-ScriptUnderTest -TestDir $testDir -Arguments @("cleanup", "--all")

            $result.ExitCode | Should -Be 0
            $configContent = Get-Content -Raw (Join-Path $testDir ".aws/config")
            $configContent | Should -Not -BeNullOrEmpty
            $configContent | Should -Match '^\['
        }
    }

    Context "Quoted profile name survives cleanup --all without crashing or corrupting the config" {
        It "exits 0 and leaves a valid, non-empty config" {
            $testDir = Join-Path $TestDrive "case-quoted-$([IO.Path]::GetRandomFileName())"
            New-Item -ItemType Directory -Path $testDir -Force | Out-Null

            New-QuotedNameConfig -Dir $testDir

            $result = Invoke-ScriptUnderTest -TestDir $testDir -Arguments @("cleanup", "--all")

            $result.ExitCode | Should -Be 0
            $configContent = Get-Content -Raw (Join-Path $testDir ".aws/config")
            $configContent | Should -Not -BeNullOrEmpty
            $configContent | Should -Match '^\['
        }
    }

    Context "Double-space header survives cleanup --all without crashing or corrupting the config" {
        It "exits 0 and leaves a valid, non-empty config" {
            $testDir = Join-Path $TestDrive "case-doublespace-$([IO.Path]::GetRandomFileName())"
            New-Item -ItemType Directory -Path $testDir -Force | Out-Null

            New-DoubleSpaceHeaderConfig -Dir $testDir

            $result = Invoke-ScriptUnderTest -TestDir $testDir -Arguments @("cleanup", "--all")

            $result.ExitCode | Should -Be 0
            $configContent = Get-Content -Raw (Join-Path $testDir ".aws/config")
            $configContent | Should -Not -BeNullOrEmpty
            $configContent | Should -Match '^\['
        }
    }

    Context "Incident reproduction: poisoned hybrid survives cleanup --all" {
        It "keeps csg-poisoned present after cleanup --all even with an expired cache" {
            # The exact incident shape: "SSO 키 + 주입된 credential_process 공존
            # 섹션 + 만료 캐시" -- must NOT be swept, even under --all.
            $testDir = Join-Path $TestDrive "case-incident-$([IO.Path]::GetRandomFileName())"
            New-Item -ItemType Directory -Path $testDir -Force | Out-Null

            New-PoisonedHybridConfig -Dir $testDir
            New-ExpiredCache -Dir $testDir -AccountId "333333333333"

            $result = Invoke-ScriptUnderTest -TestDir $testDir -Arguments @("cleanup", "--all")

            $result.ExitCode | Should -Be 0
            $configContent = Get-Content -Raw (Join-Path $testDir ".aws/config")
            $configContent | Should -Match '\[profile csg-poisoned\]'
        }
    }

    Context "Predicate verdicts: HasForeign gate vs. the baseline CSG path, same run" {
        It "keeps the foreign-key hybrid profile and removes the plain CSG profile in one invocation" {
            $testDir = Join-Path $TestDrive "case-predicate-$([IO.Path]::GetRandomFileName())"
            $awsDir = Join-Path $testDir ".aws"
            New-Item -ItemType Directory -Path $awsDir -Force | Out-Null

            $configContent = @"
[profile csg-hybrid]
sso_start_url = https://example.awsapps.com/start
credential_process = pwsh -NoProfile -File /path/to/get-customer-credentials.ps1 -AccountId 222222222222 -Agent claude-code
region = ap-northeast-2

[profile csg-plain]
credential_process = pwsh -NoProfile -File /path/to/get-customer-credentials.ps1 -AccountId 777777777777 -Agent claude-code
region = ap-northeast-2
"@
            $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
            [IO.File]::WriteAllText((Join-Path $awsDir "config"), $configContent, $utf8NoBom)

            New-ExpiredCache -Dir $testDir -AccountId "777777777777"

            $result = Invoke-ScriptUnderTest -TestDir $testDir -Arguments @("cleanup", "--all")

            $result.ExitCode | Should -Be 0
            $finalConfig = Get-Content -Raw (Join-Path $testDir ".aws/config")

            # Test-IsCsgProfile's HasForeign gate: the hybrid section survives.
            $finalConfig | Should -Match '\[profile csg-hybrid\]'

            # Baseline path unaffected: the plain CSG profile is removed.
            $finalConfig | Should -Not -Match '\[profile csg-plain\]'
        }
    }

    Context "PROF-14 recovery notice: fires only when a deletion genuinely happened" {
        It "prints an executable cp recovery command and creates the .bak file when a profile is deleted" {
            $testDir = Join-Path $TestDrive "case-prof14-deletes-$([IO.Path]::GetRandomFileName())"
            $awsDir = Join-Path $testDir ".aws"
            New-Item -ItemType Directory -Path $awsDir -Force | Out-Null

            $configContent = @"
[profile csg-recover]
credential_process = pwsh -NoProfile -File /path/to/get-customer-credentials.ps1 -AccountId 123456789012 -Agent claude-code
region = ap-northeast-2
"@
            $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
            [IO.File]::WriteAllText((Join-Path $awsDir "config"), $configContent, $utf8NoBom)

            New-ExpiredCache -Dir $testDir -AccountId "123456789012"

            $result = Invoke-ScriptUnderTest -TestDir $testDir -Arguments @("cleanup")

            $result.ExitCode | Should -Be 0
            $result.Stderr | Should -Match '복구하려면: cp'
            $result.Stderr | Should -Match '\.bak\.'

            $backups = Get-ChildItem -Path $awsDir -Filter "config.bak.*" -ErrorAction SilentlyContinue
            $backups | Should -Not -BeNullOrEmpty
        }

        It "stays silent about .bak when no CSG profiles are present" {
            $testDir = Join-Path $TestDrive "case-prof14-nothing-$([IO.Path]::GetRandomFileName())"
            $awsDir = Join-Path $testDir ".aws"
            New-Item -ItemType Directory -Path $awsDir -Force | Out-Null

            $configContent = @"
[default]
region = ap-northeast-2
"@
            $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
            [IO.File]::WriteAllText((Join-Path $awsDir "config"), $configContent, $utf8NoBom)

            $result = Invoke-ScriptUnderTest -TestDir $testDir -Arguments @("cleanup", "--all")

            $result.ExitCode | Should -Be 0
            $result.Stderr | Should -Not -Match '\.bak'
        }
    }

    Context "Skip-line dedup: the guard notice fires once per section, not on every invocation" {
        It "prints the skip line on the first run and stays silent on the second, while the record file persists" {
            $testDir = Join-Path $TestDrive "case-dedup-$([IO.Path]::GetRandomFileName())"
            New-Item -ItemType Directory -Path $testDir -Force | Out-Null

            New-PoisonedHybridConfig -Dir $testDir

            $result1 = Invoke-ScriptUnderTest -TestDir $testDir -Arguments @("cleanup")
            $result2 = Invoke-ScriptUnderTest -TestDir $testDir -Arguments @("cleanup")

            $result1.Stderr | Should -Match '\[guard\]'
            $result1.Stderr | Should -Match 'csg-poisoned'

            $result2.Stderr | Should -Not -Match '외래 키 섹션 건너뜀'

            $skipRecord = Join-Path $testDir ".cache/msp/customer-creds/guard-skips.jsonl"
            (Test-Path -LiteralPath $skipRecord) | Should -BeTrue
            $skipContent = Get-Content -Raw -LiteralPath $skipRecord
            $skipContent | Should -Match 'csg-poisoned'
        }
    }

    # --- Phase 22 (PROF-08): csg_managed ownership-marker axis ----------------
    # D-06 truth table -- sweep/cleanup eligibility is the SUPERSET
    #   (csg_managed marker present) OR (credential_process carries the .ps1 signature)
    # AND the name is not in $SkipProfiles
    # AND the section carries no foreign credential key (Phase 21 veto, top-level).
    #
    # The predicates cannot be dot-sourced for a unit-style truth table the way
    # the bash twin extracts its functions with awk: this script routes and parses
    # at top level, so sourcing it would execute it. Every row below is therefore
    # observed BEHAVIORALLY through the same subprocess isolation the Phase 21
    # cases use -- write a ~/.aws/config fixture, run "cleanup --all", and read
    # the verdict off the surviving section set.
    Context "PROF-08 marker axis: eligibility is (marker OR credential_process signature)" {

        It "removes a marked CSG profile (marker + signature, no foreign key)" {
            $testDir = Join-Path $TestDrive "case-marker-plain-$([IO.Path]::GetRandomFileName())"
            $awsDir = Join-Path $testDir ".aws"
            New-Item -ItemType Directory -Path $awsDir -Force | Out-Null

            $configContent = @"
[profile csg-marked]
credential_process = pwsh -NoProfile -File /path/to/get-customer-credentials.ps1 -AccountId 111111111111 -Agent claude-code
csg_managed = 1.7.0
region = ap-northeast-2

[default]
region = ap-northeast-2
"@
            $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
            [IO.File]::WriteAllText((Join-Path $awsDir "config"), $configContent, $utf8NoBom)

            $result = Invoke-ScriptUnderTest -TestDir $testDir -Arguments @("cleanup", "--all")

            $result.ExitCode | Should -Be 0
            $finalConfig = Get-Content -Raw (Join-Path $awsDir "config")
            $finalConfig | Should -Not -Match '\[profile csg-marked\]'
        }

        It "removes a legacy unmarked CSG profile (signature only) -- D-06 superset keeps pre-marker profiles sweepable" {
            $testDir = Join-Path $TestDrive "case-marker-legacy-$([IO.Path]::GetRandomFileName())"
            $awsDir = Join-Path $testDir ".aws"
            New-Item -ItemType Directory -Path $awsDir -Force | Out-Null

            $configContent = @"
[profile csg-legacy]
credential_process = pwsh -NoProfile -File /path/to/get-customer-credentials.ps1 -AccountId 222222222222 -Agent claude-code
region = ap-northeast-2

[default]
region = ap-northeast-2
"@
            $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
            [IO.File]::WriteAllText((Join-Path $awsDir "config"), $configContent, $utf8NoBom)

            $result = Invoke-ScriptUnderTest -TestDir $testDir -Arguments @("cleanup", "--all")

            $result.ExitCode | Should -Be 0
            $finalConfig = Get-Content -Raw (Join-Path $awsDir "config")
            $finalConfig | Should -Not -Match '\[profile csg-legacy\]'
        }

        It "removes a marked profile whose credential_process no longer matches the .ps1 signature" {
            # Isolates the marker axis: this section is INVISIBLE to the
            # pre-Phase-22 predicate (the helper path was renamed/moved, so the
            # '*get-customer-credentials.ps1*' match fails), so its removal can
            # only be explained by csg_managed being honored as ownership.
            $testDir = Join-Path $TestDrive "case-marker-only-$([IO.Path]::GetRandomFileName())"
            $awsDir = Join-Path $testDir ".aws"
            New-Item -ItemType Directory -Path $awsDir -Force | Out-Null

            $configContent = @"
[profile csg-moved]
credential_process = pwsh -NoProfile -File /old/path/csg-creds-legacy.ps1 -AccountId 121212121212 -Agent claude-code
csg_managed = 1.7.0
region = ap-northeast-2

[default]
region = ap-northeast-2
"@
            $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
            [IO.File]::WriteAllText((Join-Path $awsDir "config"), $configContent, $utf8NoBom)

            $result = Invoke-ScriptUnderTest -TestDir $testDir -Arguments @("cleanup", "--all")

            $result.ExitCode | Should -Be 0
            $finalConfig = Get-Content -Raw (Join-Path $awsDir "config")
            $finalConfig | Should -Not -Match '\[profile csg-moved\]'
        }

        It "keeps a marked profile that also carries a foreign key -- the Phase 21 veto outranks the marker" {
            # T-22-12: the marker must NOT become an override for the foreign-key
            # veto. csg-poisoned carries our marker, our signature AND sso_start_url;
            # it must survive cleanup --all exactly as it did in Phase 21.
            $testDir = Join-Path $TestDrive "case-marker-poisoned-$([IO.Path]::GetRandomFileName())"
            $awsDir = Join-Path $testDir ".aws"
            New-Item -ItemType Directory -Path $awsDir -Force | Out-Null

            $configContent = @"
[profile csg-poisoned]
sso_start_url = https://example.awsapps.com/start
sso_region = ap-northeast-2
credential_process = pwsh -NoProfile -File /path/to/get-customer-credentials.ps1 -AccountId 333333333333 -Agent claude-code
csg_managed = 1.7.0
region = ap-northeast-2
"@
            $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
            [IO.File]::WriteAllText((Join-Path $awsDir "config"), $configContent, $utf8NoBom)

            $result = Invoke-ScriptUnderTest -TestDir $testDir -Arguments @("cleanup", "--all")

            $result.ExitCode | Should -Be 0
            $finalConfig = Get-Content -Raw (Join-Path $awsDir "config")
            $finalConfig | Should -Match '\[profile csg-poisoned\]'
            $finalConfig | Should -Match 'sso_start_url'
        }

        It "WR03-03: keeps a MARKER-ONLY section that also carries a foreign key -- the veto outranks the WR-03 relaxation" {
            # HOME CHOICE (WR03-03): mirrors run_wr03_foreign_veto_outranks_relaxation
            # in test/credentials-guard.test.sh. Subject is the Phase 21 foreign-key
            # veto, which this suite owns; WR03-01/02 live in cleanup.ps1.test.ps1.
            # Distinct from the csg-poisoned case above: this section has NO
            # credential_process at all, so it only becomes visible to ProcessProfile
            # BECAUSE of the WR-03 relaxation. The veto must still protect it.
            $testDir = Join-Path $TestDrive "case-wr03-foreign-veto-$([IO.Path]::GetRandomFileName())"
            $awsDir = Join-Path $testDir ".aws"
            New-Item -ItemType Directory -Path $awsDir -Force | Out-Null

            $configContent = @"
[profile csg-orphan-poisoned]
csg_managed = 1.7.0
sso_start_url = https://example.awsapps.com/start
region = ap-northeast-2

[default]
region = ap-northeast-2
"@
            $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
            [IO.File]::WriteAllText((Join-Path $awsDir "config"), $configContent, $utf8NoBom)

            $result = Invoke-ScriptUnderTest -TestDir $testDir -Arguments @("cleanup", "--all")

            $result.ExitCode | Should -Be 0
            $finalConfig = Get-Content -Raw (Join-Path $awsDir "config")
            $finalConfig | Should -Match '\[profile csg-orphan-poisoned\]'
            # The foreign key stays verbatim -- surgery is doctor's job, never cleanup's.
            $finalConfig | Should -Match 'sso_start_url = https://example\.awsapps\.com/start'
            $finalConfig | Should -Match '\[default\]'
        }

        It "keeps [default] even when it carries both the marker and the signature" {
            # $SkipProfiles still outranks positive ownership -- a marker on an
            # infrastructure section must never make it deletable.
            $testDir = Join-Path $TestDrive "case-marker-default-$([IO.Path]::GetRandomFileName())"
            $awsDir = Join-Path $testDir ".aws"
            New-Item -ItemType Directory -Path $awsDir -Force | Out-Null

            $configContent = @"
[default]
credential_process = pwsh -NoProfile -File /path/to/get-customer-credentials.ps1 -AccountId 444444444444 -Agent claude-code
csg_managed = 1.7.0
region = ap-northeast-2
"@
            $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
            [IO.File]::WriteAllText((Join-Path $awsDir "config"), $configContent, $utf8NoBom)

            $result = Invoke-ScriptUnderTest -TestDir $testDir -Arguments @("cleanup", "--all")

            $result.ExitCode | Should -Be 0
            $finalConfig = Get-Content -Raw (Join-Path $awsDir "config")
            $finalConfig | Should -Match '\[default\]'
        }
    }

    Context "PROF-08 marker is presence-only: the version value is never compared" {

        It "removes a profile marked csg_managed = 9.9.9-future" {
            # T-22-06: a value-matching predicate would read 9.9.9-future as
            # 'not ours' and silently orphan the profile (or, worse, let a
            # forged value flip a verdict). The fixture also drops the .ps1
            # signature so ONLY the marker can produce the removal.
            $testDir = Join-Path $TestDrive "case-marker-future-$([IO.Path]::GetRandomFileName())"
            $awsDir = Join-Path $testDir ".aws"
            New-Item -ItemType Directory -Path $awsDir -Force | Out-Null

            $configContent = @"
[profile csg-future]
credential_process = pwsh -NoProfile -File /old/path/csg-creds-legacy.ps1 -AccountId 555555555555 -Agent claude-code
csg_managed = 9.9.9-future
region = ap-northeast-2

[default]
region = ap-northeast-2
"@
            $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
            [IO.File]::WriteAllText((Join-Path $awsDir "config"), $configContent, $utf8NoBom)

            $result = Invoke-ScriptUnderTest -TestDir $testDir -Arguments @("cleanup", "--all")

            $result.ExitCode | Should -Be 0
            $finalConfig = Get-Content -Raw (Join-Path $awsDir "config")
            $finalConfig | Should -Not -Match '\[profile csg-future\]'
            $finalConfig | Should -Match '\[default\]'
        }
    }

    Context "PROF-08 marker constant" {

        It "declares `$CsgManagedVersion = ""1.7.0""" {
            # Value equality with the bash CSG_MANAGED_VERSION literal is gated
            # separately by credentials-parity.test.sh (PARITY-07, plan 22-08);
            # this case only pins the PS-side literal so a local edit cannot
            # drift it silently between parity runs.
            $scriptText = Get-Content -Raw -LiteralPath $script:ScriptUnderTest
            $scriptText | Should -Match '\$CsgManagedVersion\s*=\s*"1\.7\.0"'
        }
    }
}
