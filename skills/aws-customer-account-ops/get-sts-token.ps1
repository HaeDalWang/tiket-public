# get-sts-token.ps1 -- LOGIN-ONLY Slack token acquisition (CLI-03).
# PowerShell twin of get-sts-token.sh. Performs Slack OAuth + POST /v1/credentials
# to obtain the Slack Bearer, then persists AND emits ONLY the identity/cadence
# fields (Version, Expiration, BrokerVersion, SlackAccessToken, SlackUserId).
# The AWS-credential fields in the login response (AccessKeyId / SecretAccessKey
# / SessionToken) are a privileged crossaccount residue and are NEVER written to
# disk NOR printed to stdout (ROADMAP SC3: "distributes no AWS credential").
param(
    [switch]$ClearCache,
    [switch]$NoBrowser,
    [switch]$CheckOnly,
    [switch]$NoUpdate,  # accepted for old callers; auto-update is gone
    [switch]$Help,
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$RemainingArgs
)

$ErrorActionPreference = "Stop"

$ConfigFile = Join-Path $env:USERPROFILE ".config\msp\credential-broker.conf"
$CacheFile = Join-Path $env:USERPROFILE ".cache\msp\sts-token.json"
$CallbackPort = 9876
$RedirectUri = "http://localhost:$CallbackPort/callback"
$AuthTimeoutSeconds = 120
$CacheSkewSeconds = 300

function Show-Usage {
    Write-Host @"
사용법: get-sts-token.ps1 [OPTIONS]

Slack OAuth 로그인을 수행하고 Slack 토큰만 캐시합니다.
(AWS 자격 증명은 디스크에 저장하지 않으며 stdout으로도 출력하지 않습니다.)

OPTIONS:
  -ClearCache       캐시된 토큰 삭제 후 다시 인증
  -NoBrowser        브라우저를 자동으로 열지 않고 URL만 출력
  -CheckOnly        캐시 유효성만 확인 (유효: exit 0 + JSON, 만료/없음: exit 2, 브라우저 열지 않음)
  -Help             도움말 출력

설정 파일:
  ~/.config/msp/credential-broker.conf

예시:
  # MSP 회사 Credential Broker 설정
  API_URL=https://xxx.execute-api.ap-northeast-2.amazonaws.com/Prod/v1/credentials
  CLIENT_ID=your-slack-app-client-id
"@
}

function ConvertTo-CompactJson {
    param(
        [Parameter(Mandatory = $true)]
        $InputObject
    )

    return ($InputObject | ConvertTo-Json -Compress -Depth 10)
}

function Write-JsonToStdout {
    param(
        [Parameter(Mandatory = $true)]
        $InputObject
    )

    [Console]::Out.WriteLine((ConvertTo-CompactJson -InputObject $InputObject))
}

function Get-TrimmedValue {
    param(
        [AllowNull()]
        [string]$Value
    )

    if ($null -eq $Value) {
        return ""
    }

    return $Value.Trim()
}

function Read-Config {
    if (-not (Test-Path -LiteralPath $ConfigFile)) {
        Write-Host "오류: 설정 파일을 찾을 수 없습니다: $ConfigFile"
        Write-Host "아래 내용으로 파일을 생성해주세요:"
        Write-Host @"
# MSP 회사 Credential Broker 설정
API_URL=https://xxx.execute-api.ap-northeast-2.amazonaws.com/Prod/v1/credentials
CLIENT_ID=your-slack-app-client-id
"@
        exit 1
    }

    $apiUrl = ""
    $clientId = ""

    foreach ($rawLine in Get-Content -LiteralPath $ConfigFile) {
        $line = Get-TrimmedValue -Value $rawLine
        if ([string]::IsNullOrWhiteSpace($line) -or $line.StartsWith("#")) {
            continue
        }

        $separatorIndex = $line.IndexOf("=")
        if ($separatorIndex -lt 0) {
            continue
        }

        $key = Get-TrimmedValue -Value $line.Substring(0, $separatorIndex)
        $value = Get-TrimmedValue -Value $line.Substring($separatorIndex + 1)

        switch ($key) {
            "API_URL" { $apiUrl = $value }
            "CLIENT_ID" { $clientId = $value }
        }
    }

    if ([string]::IsNullOrWhiteSpace($apiUrl) -or [string]::IsNullOrWhiteSpace($clientId)) {
        Write-Host "오류: 설정 파일에 API_URL과 CLIENT_ID를 모두 설정해야 합니다."
        exit 1
    }

    if (-not $apiUrl.StartsWith("https://", [System.StringComparison]::OrdinalIgnoreCase)) {
        Write-Host "오류: API_URL은 https://로 시작해야 합니다."
        exit 1
    }

    return @{
        API_URL = $apiUrl
        CLIENT_ID = $clientId
    }
}

function Test-CacheValid {
    if (-not (Test-Path -LiteralPath $CacheFile)) {
        return $false
    }

    try {
        $cached = Get-Content -LiteralPath $CacheFile -Raw | ConvertFrom-Json
        $expiration = $cached.Expiration
        # ConvertFrom-Json can return DateTime. Casting it to string discards
        # Kind/offset and makes a UTC expiry look like local wall-clock time.
        if ($expiration -is [DateTime]) {
            if ($expiration.Kind -eq [DateTimeKind]::Unspecified) { return $false }
            $expiresAt = [DateTimeOffset]::new($expiration)
        } elseif ($expiration -is [DateTimeOffset]) {
            $expiresAt = $expiration
        } else {
            if ([string]::IsNullOrWhiteSpace($expiration)) { return $false }
            $expiresAt = [DateTimeOffset]::Parse($expiration, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind)
        }

        $threshold = [DateTimeOffset]::UtcNow.AddSeconds($CacheSkewSeconds)
        return $expiresAt -gt $threshold
    }
    catch {
        return $false
    }
}

function Emit-CachedJson {
    $cached = Get-Content -LiteralPath $CacheFile -Raw | ConvertFrom-Json
    Write-JsonToStdout -InputObject $cached
}

function New-StateToken {
    $bytes = [byte[]]::new(32)
    [System.Security.Cryptography.RandomNumberGenerator]::Fill($bytes)

    return [Convert]::ToBase64String($bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
}

function Get-AuthUrl {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ClientId,
        [Parameter(Mandatory = $true)]
        [string]$State
    )

    $encodedClientId = [System.Uri]::EscapeDataString($ClientId)
    $encodedScope = [System.Uri]::EscapeDataString("identity.basic,identity.email")
    $encodedRedirectUri = [System.Uri]::EscapeDataString($RedirectUri)
    $encodedState = [System.Uri]::EscapeDataString($State)

    return "https://slack.com/oauth/v2/authorize?client_id=$encodedClientId&user_scope=$encodedScope&redirect_uri=$encodedRedirectUri&state=$encodedState"
}

function Parse-QueryParameters {
    param(
        [AllowNull()]
        [string]$Query
    )

    $result = @{}
    if ([string]::IsNullOrEmpty($Query)) {
        return $result
    }

    foreach ($pair in $Query.TrimStart('?').Split('&', [System.StringSplitOptions]::RemoveEmptyEntries)) {
        $parts = $pair.Split('=', 2)
        $name = [System.Uri]::UnescapeDataString($parts[0])
        $value = ""
        if ($parts.Count -gt 1) {
            $value = [System.Uri]::UnescapeDataString($parts[1].Replace('+', ' '))
        }
        $result[$name] = $value
    }

    return $result
}

function Send-CallbackResponse {
    param(
        [Parameter(Mandatory = $true)]
        [System.Net.HttpListenerResponse]$Response
    )

    $body = @"
<!doctype html>
<html lang="ko">
  <head>
    <meta charset="utf-8">
    <title>MSP 회사 인증 완료</title>
  </head>
  <body>
    <p>✅ 인증 완료! 이 창을 닫아도 됩니다.</p>
  </body>
</html>
"@

    $bytes = [System.Text.Encoding]::UTF8.GetBytes($body)
    $Response.StatusCode = 200
    $Response.ContentType = "text/html; charset=utf-8"
    $Response.ContentLength64 = $bytes.Length
    $Response.OutputStream.Write($bytes, 0, $bytes.Length)
    $Response.OutputStream.Close()
}

function Wait-ForSlackCallback {
    param(
        [Parameter(Mandatory = $true)]
        [System.Net.HttpListener]$Listener
    )

    $deadline = [DateTimeOffset]::UtcNow.AddSeconds($AuthTimeoutSeconds)

    while ([DateTimeOffset]::UtcNow -lt $deadline) {
        $remaining = $deadline - [DateTimeOffset]::UtcNow
        if ($remaining -lt [TimeSpan]::Zero) {
            break
        }

        $asyncResult = $Listener.BeginGetContext($null, $null)
        try {
            if (-not $asyncResult.AsyncWaitHandle.WaitOne($remaining)) {
                break
            }

            $context = $Listener.EndGetContext($asyncResult)
            if ($context.Request.Url.AbsolutePath -ne "/callback") {
                $responseBytes = [System.Text.Encoding]::UTF8.GetBytes("Not Found")
                $context.Response.StatusCode = 404
                $context.Response.ContentType = "text/plain; charset=utf-8"
                $context.Response.ContentLength64 = $responseBytes.Length
                $context.Response.OutputStream.Write($responseBytes, 0, $responseBytes.Length)
                $context.Response.OutputStream.Close()
                continue
            }

            $query = Parse-QueryParameters -Query $context.Request.Url.Query
            Send-CallbackResponse -Response $context.Response

            $code = ""
            $returnedState = ""
            $callbackError = ""

            if ($query.ContainsKey("code")) {
                $code = [string]$query["code"]
            }

            if ($query.ContainsKey("state")) {
                $returnedState = [string]$query["state"]
            }

            if ($query.ContainsKey("error")) {
                $callbackError = [string]$query["error"]
            }

            return @{
                code = $code
                state = $returnedState
                error = $callbackError
            }
        }
        finally {
            $asyncResult.AsyncWaitHandle.Dispose()
        }
    }

    throw "오류: 인증 시간 초과"
}

function Open-Browser {
    param(
        [Parameter(Mandatory = $true)]
        [string]$AuthUrl
    )

    Write-Host "브라우저가 열리지 않으면 아래 URL을 직접 열어주세요:"
    Write-Host $AuthUrl

    if ($NoBrowser) {
        return
    }

    try {
        Start-Process $AuthUrl | Out-Null
    }
    catch {
        Write-Host "안내: 브라우저 자동 실행에 실패했습니다. 위 URL을 직접 열어주세요."
    }
}

function Validate-ApiResponse {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RawResponse
    )

    try {
        $data = $RawResponse | ConvertFrom-Json
    }
    catch {
        Write-Host "오류: API 응답이 올바른 JSON이 아닙니다. ($($_.Exception.Message))"
        exit 1
    }

    if ($null -ne $data.PSObject.Properties['error']) {
        if ($data.error -is [string] -and -not [string]::IsNullOrWhiteSpace($data.error)) {
            Write-Host "오류: $($data.error)"
            exit 1
        }

        if ($null -ne $data.error) {
            Write-Host "오류: API가 오류를 반환했습니다."
            Write-Host (ConvertTo-CompactJson -InputObject $data.error)
            exit 1
        }
    }

    if ($null -eq $data.PSObject.Properties['Version'] -or $data.Version -ne 1) {
        Write-Host "오류: API 응답에 Version=1 필드가 없습니다."
        exit 1
    }

    return $data
}

try {
    if ($RemainingArgs.Count -gt 0) {
        Write-Host "알 수 없는 옵션: $($RemainingArgs[0])"
        Show-Usage
        exit 1
    }

    if ($Help) {
        Show-Usage
        exit 0
    }

    # The skill ships inside the tiket workspace and updates with `git pull`; its
    # old auto-update was removed on 2026-10-21 (a stale copy blocked every login).
    $ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

    # --- HOOK-A: auto-migrate to the csg- namespace (PROF-12) ---
    # The clients themselves are the only delivery mechanism for this migration:
    # an installer-hosted one reaches ~0 already-deployed machines.
    #
    # $ScriptDir is the one resolved above; do not recompute it.
    #
    # Shell out rather than dot-source: get-customer-credentials.ps1 owns the
    # migration, and its routing block exits long before the credential_process
    # main flow, so a subprocess cannot recurse into that script's own hook.
    #
    # stdout ONLY is discarded (`| Out-Null`). stderr stays attached because this
    # is the ONE path with a real TTY -- the old->new mapping table is the single
    # human-facing artifact of the whole migration, and an engineer (or agent)
    # who never sees it keeps using the old profile names. try/catch is the
    # PowerShell spelling of `|| true`: a migration failure must never block a
    # login (and under $PSNativeCommandUseErrorActionPreference the child's
    # non-zero exit would otherwise throw).
    #
    # WR-04 -- COMPLETION-MARKER PRE-CHECK. The credential_process hook in
    # get-customer-credentials.ps1 guards its call the same way: the steady state
    # on an already-migrated machine must be ONE file scan and complete silence.
    # This hook had no such guard, and get-sts-token.ps1 is csg-login's registered
    # credential_process, so EVERY AWS call resolved through that profile spawned
    # a whole pwsh subprocess and printed "[migrate] status=already-migrated" onto
    # the engineer's terminal -- forever. Matching on the id literal (not just the
    # filename) means a FUTURE migration id re-arms this hook.
    #
    # WR-05 -- SWEEP BEFORE MIGRATE. That ordering is load-bearing:
    # Get-CacheFilePath keys the cache on the ACCOUNT ID (Phase 18 collapse), so a
    # freshly renamed `csg-X` inherits old `X`'s <account-id>.json, which is a
    # 1-hour session and therefore almost always expired. Migrating first hands
    # the next sweep a brand-new csg-X it classifies as expired and deletes on the
    # spot -- so the mapping table printed HERE, the single human-facing artifact
    # of the whole migration, lists names that no longer exist by the time the
    # engineer reads it. `cleanup` (no --all) IS the sweep: expired CSG profiles
    # only, silent when it removes nothing (D-03).
    $MigrateClient = Join-Path $ScriptDir "get-customer-credentials.ps1"
    # Same home resolution as $CacheFile at the top of this file.
    $MigrationRecordFile = Join-Path $env:USERPROFILE ".cache\msp\customer-creds\migrations.jsonl"
    $MigrationDone = $false
    if (Test-Path -LiteralPath $MigrationRecordFile) {
        try {
            $MigrationDone = [bool](Select-String -LiteralPath $MigrationRecordFile `
                -SimpleMatch '"id":"v1.7-csg-namespace"' -Quiet)
        } catch { $MigrationDone = $false }
    }
    if ((-not $MigrationDone) -and (Test-Path -LiteralPath $MigrateClient)) {
        try {
            & pwsh -NoProfile -File $MigrateClient cleanup *> $null
        } catch { }
        try {
            & pwsh -NoProfile -File $MigrateClient migrate | Out-Null
        } catch { }
    }

    if ($ClearCache -and (Test-Path -LiteralPath $CacheFile)) {
        Remove-Item -LiteralPath $CacheFile -Force
    }

    if (Test-CacheValid) {
        Emit-CachedJson
        exit 0
    }

    if ($CheckOnly) {
        Write-Host "오류: STS 토큰이 없거나 만료되었습니다. 터미널에서 get-sts-token.ps1을 직접 실행하여 Slack 인증을 완료해주세요."
        exit 2
    }

    $config = Read-Config
    $state = New-StateToken
    $authUrl = Get-AuthUrl -ClientId $config.CLIENT_ID -State $state

    $listener = [System.Net.HttpListener]::new()
    try {
        Write-Host "로컬 인증 서버를 시작합니다."
        $listener.Prefixes.Add("http://localhost:$CallbackPort/")
        $listener.Start()
    }
    catch {
        if ($listener.IsListening) {
            $listener.Stop()
        }
        $listener.Close()
        Write-Host "오류: 로컬 인증 서버를 시작하지 못했습니다. 포트 $CallbackPort 사용 여부를 확인해주세요."
        exit 1
    }

    try {
        Open-Browser -AuthUrl $authUrl

        Write-Host "Slack 인증을 기다리는 중입니다..."
        $callback = Wait-ForSlackCallback -Listener $listener

        if (-not [string]::IsNullOrWhiteSpace($callback.error)) {
            Write-Host "오류: Slack 인증 실패 - $($callback.error)"
            exit 1
        }

        if ($callback.state -ne $state) {
            Write-Host "오류: state 검증에 실패했습니다."
            exit 1
        }

        if ([string]::IsNullOrWhiteSpace($callback.code)) {
            Write-Host "오류: 인증 코드가 전달되지 않았습니다."
            exit 1
        }

        $requestBody = @{ code = $callback.code } | ConvertTo-Json -Compress

        Write-Host "STS 자격 증명을 요청하는 중입니다."
        try {
            $apiResponseRaw = Invoke-WebRequest -Uri $config.API_URL -Method Post -ContentType "application/json" -Body $requestBody -TimeoutSec 30 | Select-Object -ExpandProperty Content
        }
        catch {
            $resp = $_.Exception.Response
            $body = $null
            if ($resp) {
                # HttpWebResponse exposes the response payload via the response
                # stream, not a .Content property. Read it so the actual
                # server-side error message is surfaced to the user instead
                # of the generic .Exception.Message.
                try {
                    $stream = $resp.GetResponseStream()
                    if ($stream) {
                        $reader = [System.IO.StreamReader]::new($stream)
                        try {
                            $body = $reader.ReadToEnd()
                        }
                        finally {
                            $reader.Dispose()
                        }
                    }
                }
                catch {
                    # If reading the response stream fails for any reason,
                    # fall through to the generic message below.
                }
            }

            if (-not [string]::IsNullOrWhiteSpace($body)) {
                Write-Host "오류: STS 자격 증명 요청에 실패했습니다. $body"
            }
            else {
                Write-Host "오류: STS 자격 증명 요청에 실패했습니다. ($($_.Exception.Message))"
            }
            exit 1
        }

        $validated = Validate-ApiResponse -RawResponse $apiResponseRaw

        $cacheDirectory = Split-Path -Parent $CacheFile
        if (-not (Test-Path -LiteralPath $cacheDirectory)) {
            New-Item -ItemType Directory -Path $cacheDirectory -Force | Out-Null
        }

        # CLI-03 (login-only): project the /v1/credentials response to the
        # identity/cadence fields BEFORE it touches disk or stdout. The AWS-
        # credential fields (AccessKeyId/SecretAccessKey/SessionToken) are a
        # privileged crossaccount residue that must NEITHER be persisted NOR
        # distributed. Build the identity object ONCE and reuse it for both the
        # cache write and the final stdout emission -- mirrors the bash twin's
        # persisted/emitted key set exactly. Expiration is kept only as the
        # Test-CacheValid re-login cadence marker.
        $identity = [PSCustomObject]@{
            Version          = $validated.Version
            Expiration       = $validated.Expiration
            BrokerVersion    = $validated.BrokerVersion
            SlackAccessToken = $validated.SlackAccessToken
            SlackUserId      = $validated.SlackUserId
        }
        $identityJson = ConvertTo-CompactJson -InputObject $identity
        $cacheTmp = Join-Path (Split-Path -Parent $CacheFile) ".sts-token.$([System.IO.Path]::GetRandomFileName())"
        [System.IO.File]::WriteAllText($cacheTmp, $identityJson + [Environment]::NewLine, [System.Text.UTF8Encoding]::new($false))

        # Restrict ACL to current user only
        try {
            $acl = Get-Acl -LiteralPath $cacheTmp
            $acl.SetAccessRuleProtection($true, $false)
            $acl.Access | ForEach-Object { $acl.RemoveAccessRule($_) } | Out-Null
            $rule = [System.Security.AccessControl.FileSystemAccessRule]::new(
                [System.Security.Principal.WindowsIdentity]::GetCurrent().Name,
                [System.Security.AccessControl.FileSystemRights]::FullControl,
                [System.Security.AccessControl.AccessControlType]::Allow
            )
            $acl.AddAccessRule($rule)
            Set-Acl -LiteralPath $cacheTmp -AclObject $acl
        }
        catch {
            # Non-fatal — permission restriction is best-effort
        }

        Move-Item -LiteralPath $cacheTmp -Destination $CacheFile -Force

        # Emit the SAME identity-only projection persisted above -- no AWS credential.
        [Console]::Out.WriteLine($identityJson)
        exit 0
    }
    finally {
        if ($listener.IsListening) {
            $listener.Stop()
        }
        $listener.Close()
    }
}
catch {
    Write-Host "오류: $($_.Exception.Message)"
    exit 1
}
