BeforeAll {
    $source = Join-Path $PSScriptRoot '../skills/aws-customer-account-ops/get-sts-token.ps1'
    $ast = [Management.Automation.Language.Parser]::ParseFile($source, [ref]$null, [ref]$null)
    $definition = $ast.Find({ param($n)
        $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Test-CacheValid'
    }, $true)
    . ([scriptblock]::Create($definition.Extent.Text))
    $CacheFile = Join-Path $TestDrive 'sts-token.json'
    $CacheSkewSeconds = 300
    $originalTZ = $env:TZ
}
AfterAll {
    $env:TZ = $originalTZ
    [TimeZoneInfo]::ClearCachedData()
}
Describe 'Login cache expiration retains the JSON time zone' {
    It 'honors UTC, offsets and skew in <zone>' -TestCases @(
        @{ zone = 'UTC' }
        @{ zone = 'Asia/Seoul' }
        @{ zone = 'America/Los_Angeles' }
    ) {
        param($zone)
        $env:TZ = $zone
        [TimeZoneInfo]::ClearCachedData()
        foreach ($offset in @(0, 9, -7)) {
            foreach ($minutes in @(60, 4, -5)) {
                $stamp = [DateTimeOffset]::UtcNow.AddMinutes($minutes).ToOffset([TimeSpan]::FromHours($offset)).ToString('o')
                if ($offset -eq 0) { $stamp = $stamp.Replace('+00:00', 'Z') }
                @{ Expiration = $stamp } | ConvertTo-Json | Set-Content -LiteralPath $CacheFile
                Test-CacheValid | Should -Be ($minutes -gt 5)
            }
        }
    }
    It 'rejects missing or invalid expiration' {
        foreach ($value in @('', 'invalid', $null)) {
            @{ Expiration = $value } | ConvertTo-Json | Set-Content -LiteralPath $CacheFile
            Test-CacheValid | Should -BeFalse
        }
    }
}
