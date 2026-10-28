BeforeAll {
    $wrapper = Join-Path $TestDrive 'invoke-billing.ps1'
    $source = Join-Path $PSScriptRoot '../skills/aws-customer-account-ops/billing-api.ps1'
    @'
param($Source, $Target, $Capture)
$ErrorActionPreference = 'Stop'
$env:USERPROFILE = Split-Path -Parent $Capture
$env:BILLING_API_KEY = 'synthetic-billing-key'
function Invoke-RestMethod {
    param($Method, $Uri, $Headers, $TimeoutSec, $MaximumRedirection)
    @{ uri = $Uri; header = $Headers.Authorization; redirects = $MaximumRedirection } |
        ConvertTo-Json | Set-Content -LiteralPath $Capture
    return @{ ok = $true }
}
& $Source GET $Target
exit $LASTEXITCODE
'@ | Set-Content -LiteralPath $wrapper
}

Describe 'BILLING destination boundary' {
    It 'sends the key only to the configured HTTPS origin: <target>' -TestCases @(
        @{ target = '/api/foo'; expected = 'https://billing.example.com/api/foo' }
        @{ target = 'https://billing.example.com/api/foo'; expected = 'https://billing.example.com/api/foo' }
    ) {
        param($target, $expected)
        $capture = Join-Path $TestDrive ([IO.Path]::GetRandomFileName())
        $output = & pwsh -NoProfile -File $wrapper $source $target $capture 2>&1
        $LASTEXITCODE | Should -Be 0
        $sent = Get-Content -Raw $capture | ConvertFrom-Json
        $sent.uri | Should -BeExactly $expected
        $sent.header | Should -BeExactly 'Bearer synthetic-billing-key'
        $sent.redirects | Should -BeExactly 0
        ($output -join "`n") | Should -Not -Match 'synthetic-billing-key'
    }

    It 'rejects unsafe destination before transport: <target>' -TestCases @(
        @{ target = 'http://billing.example.com/api/foo' }
        @{ target = 'https://other.example/x' }
        @{ target = 'https://billing.example.com.evil.example/x' }
        @{ target = 'https://billing.example.com@evil.example/x' }
        @{ target = 'https://user@billing.example.com/x' }
        @{ target = 'https://billing.example.com:444/x' }
        @{ target = '//evil.example/x' }
        @{ target = 'https://billing.example.com\@evil.example/x' }
        @{ target = "https://billing.example.com`n.evil.example/x" }
    ) {
        param($target)
        $capture = Join-Path $TestDrive ([IO.Path]::GetRandomFileName())
        $output = & pwsh -NoProfile -File $wrapper $source $target $capture 2>&1
        $LASTEXITCODE | Should -Not -Be 0
        Test-Path $capture | Should -BeFalse
        ($output -join "`n") | Should -Not -Match 'synthetic-billing-key'
    }
}
