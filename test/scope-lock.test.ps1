BeforeAll {
    $source = Join-Path (Split-Path -Parent $PSScriptRoot) 'skills/aws-customer-account-ops/get-customer-credentials.ps1'
    $tokens = $null; $parseErrors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($source, [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors.Count) { throw 'Credential script does not parse' }
    foreach ($name in @('Lock-Scope', 'Unlock-Scope', 'Initialize-ScopeFileWriter', 'Write-ScopeLineLocked', 'Invoke-ScopePrune')) {
        $definition = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name }, $true)
        if (-not $definition) { throw "Missing function: $name" }
        . ([scriptblock]::Create($definition.Extent.Text))
    }
}

Describe 'Scope lock critical section' {
    BeforeEach {
        $script:ScopeWindowRecord = Join-Path $TestDrive ([IO.Path]::GetRandomFileName())
        $script:ScopeLock = "$script:ScopeWindowRecord.lock"
        $script:ScopeLockStream = $null
        $script:ScopeLockPath = ''
        $script:utf8 = [Text.UTF8Encoding]::new($false)
    }

    It 'does not acquire the writer lock when every record is fresh' {
        $line = '{"ts":200,"accountId":"111111111111"}' + "`n"
        [IO.File]::WriteAllText($ScopeWindowRecord, $line, $utf8)
        Mock Lock-Scope { throw 'A no-op prune must not contend with writers' }
        Invoke-ScopePrune -Cutoff 100
        Should -Invoke Lock-Scope -Times 0 -Exactly
        [IO.File]::ReadAllText($ScopeWindowRecord) | Should -BeExactly $line
    }

    It 're-reads after acquiring the lock so a concurrent append survives pruning' {
        [IO.File]::WriteAllText($ScopeWindowRecord, ('{"ts":1,"accountId":"111111111111"}' + "`n"), $utf8)
        Mock Lock-Scope {
            [IO.File]::AppendAllText($script:ScopeWindowRecord, ('{"ts":200,"accountId":"222222222222"}' + "`n"), $script:utf8)
            return $true
        }
        Mock Unlock-Scope { }
        Invoke-ScopePrune -Cutoff 100
        [IO.File]::ReadAllText($ScopeWindowRecord) | Should -BeExactly ('{"ts":200,"accountId":"222222222222"}' + "`n")
        Should -Invoke Lock-Scope -Times 1 -Exactly
        Should -Invoke Unlock-Scope -Times 1 -Exactly
    }

    It 'keeps fresh records while removing malformed and oversized timestamps' {
        $fresh = '{"ts":200,"accountId":"222222222222"}' + "`n"
        [IO.File]::WriteAllText($ScopeWindowRecord, ("bad`n" + '{"ts":99999999999999999999999,"accountId":"111111111111"}' + "`n" + $fresh), $utf8)
        Mock Lock-Scope { return $true }
        Mock Unlock-Scope { }
        Invoke-ScopePrune -Cutoff 100
        [IO.File]::ReadAllText($ScopeWindowRecord) | Should -BeExactly $fresh
        Should -Invoke Unlock-Scope -Times 1 -Exactly
    }

    It 'nested writes preserve the caller lock and append BOM-free LF records' {
        $script:ScopeLockStream = [IO.MemoryStream]::new()
        Mock Lock-Scope { throw 'Nested acquire' }
        Mock Unlock-Scope { throw 'Caller owns the lock' }
        try {
            $bytes = $utf8.GetBytes("first`nsecond`n")
            $result = Write-ScopeLineLocked -Path $ScopeWindowRecord -Bytes $bytes
            $result.Written | Should -BeTrue
            $result.LockTimedOut | Should -BeFalse
            [Convert]::ToBase64String([IO.File]::ReadAllBytes($ScopeWindowRecord)) | Should -BeExactly ([Convert]::ToBase64String($bytes))
            Should -Invoke Lock-Scope -Times 0 -Exactly
            Should -Invoke Unlock-Scope -Times 0 -Exactly
        }
        finally { $script:ScopeLockStream.Dispose(); $script:ScopeLockStream = $null }
    }

    It 'honors a live PID in the Bash lock format and reports the advisory timeout' {
        [IO.File]::WriteAllText($ScopeLock, "$PID", $utf8)
        $result = Write-ScopeLineLocked -Path $ScopeWindowRecord -Bytes $utf8.GetBytes("record`n")
        $result.LockTimedOut | Should -BeTrue
        $result.Written | Should -BeTrue
        [IO.File]::ReadAllText($ScopeLock) | Should -BeExactly "$PID"
        [IO.File]::ReadAllText($ScopeWindowRecord) | Should -BeExactly "record`n"
    }

    It 'reclaims an orphaned lock and releases its own lock after writing' {
        [IO.File]::WriteAllText($ScopeLock, '2147483647', $utf8)
        $result = Write-ScopeLineLocked -Path $ScopeWindowRecord -Bytes $utf8.GetBytes("record`n")
        $result.LockTimedOut | Should -BeFalse
        $result.Written | Should -BeTrue
        [IO.File]::Exists($ScopeLock) | Should -BeFalse
        [IO.File]::ReadAllText($ScopeWindowRecord) | Should -BeExactly "record`n"
    }
}
