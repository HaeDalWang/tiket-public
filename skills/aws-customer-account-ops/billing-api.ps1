param(
    [Parameter(Position = 0)]
    [string]$Method,
    [Parameter(Position = 1)]
    [string]$Path,
    [Parameter(Position = 2)]
    [string]$JsonBody,
    [switch]$Help
)

# billing-api.ps1 -- PowerShell behavioral port of billing-api.sh.
#
# Resolves the BILLING API key with precedence:
#   1. BILLING_API_KEY environment variable (if non-empty)
#   2. BILLING_API_KEY line in ~/.config/msp/credential-broker.conf
#   3. fail closed (clear remediation message to error stream + non-zero exit)
#
# The resolved key is ONLY ever placed in the Authorization: Bearer header.
# It is never written to stdout or interpolated into any message.
#
# Usage: billing-api.ps1 METHOD PATH-or-URL [JSON_BODY]
#   METHOD       one of GET POST PUT HEAD (case-sensitive uppercase)
#   PATH-or-URL  /api/... OR an https://billing.example.com URL
#   JSON_BODY    optional; only used for POST/PUT (adds Content-Type + body)

$ErrorActionPreference = "Stop"

$ConfigFile = Join-Path $env:USERPROFILE ".config\msp\credential-broker.conf"
$BaseUrl = "https://billing.example.com"

function Show-Usage {
    Write-Host @"
사용법: billing-api.ps1 METHOD PATH-or-URL [JSON_BODY]

BILLING API를 호출하고 응답 본문(raw JSON)을 stdout으로 출력합니다.
API 키는 BILLING_API_KEY 환경변수 또는
~/.config/msp/credential-broker.conf 의 BILLING_API_KEY 라인에서 읽습니다.

인자:
  METHOD        GET | POST | PUT | HEAD (대문자)
  PATH-or-URL   /api/... 또는 https://billing.example.com 의 전체 URL
  JSON_BODY     선택. POST/PUT 시 요청 본문 (JSON)

예시:
  billing-api.ps1 GET "/api/admin/v1/companies"
  billing-api.ps1 POST "/api/v1/costs/ondemand/corp/monthly" '{"corpId":"..."}'
"@
}

# Get-TrimmedValue -- null-safe trim (mirrors get-sts-token.ps1).
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

# ConvertTo-CompactJson -- compact re-serialization (mirrors get-sts-token.ps1).
function ConvertTo-CompactJson {
    param(
        [Parameter(Mandatory = $true)]
        $InputObject
    )

    return ($InputObject | ConvertTo-Json -Compress -Depth 20)
}

# Read-BillingKey -- parse $ConfigFile for the BILLING_API_KEY value.
# Mirrors the Read-Config loop in get-sts-token.ps1 but matches ONLY
# BILLING_API_KEY. Returns the value, or "" if not present.
function Read-BillingKey {
    $found = ""

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
            "BILLING_API_KEY" { $found = $value }
        }
    }

    return $found
}

# Resolve-BillingKey -- apply env -> conf -> fail-closed precedence.
# Returns the resolved key. On total failure, writes a remediation message to
# the error stream and exits 1. NEVER writes the key value.
function Resolve-BillingKey {
    # (1) environment variable wins.
    $envKey = $env:BILLING_API_KEY
    if (-not [string]::IsNullOrWhiteSpace($envKey)) {
        return $envKey
    }

    # (2) fall back to the conf file.
    if (Test-Path -LiteralPath $ConfigFile) {
        $confKey = Read-BillingKey
        if (-not [string]::IsNullOrWhiteSpace($confKey)) {
            return $confKey
        }
    }

    # (3) fail closed -- never write the (absent) key, only remediation guidance.
    [Console]::Error.WriteLine("오류: BILLING_API_KEY를 환경변수에서도 설정 파일에서도 찾을 수 없습니다.")
    [Console]::Error.WriteLine("다음 중 하나로 키를 설정하세요:")
    [Console]::Error.WriteLine("  - 환경변수: `$env:BILLING_API_KEY = '<발급받은 키>'")
    [Console]::Error.WriteLine("  - 설정 파일: ~/.config/msp/credential-broker.conf 에 아래 라인 추가")
    [Console]::Error.WriteLine("      BILLING_API_KEY=<발급받은 키>")
    [Console]::Error.WriteLine("설정 파일에는 비밀값이 저장되므로 반드시 'chmod 600 ~/.config/msp/credential-broker.conf' 로 권한을 제한하세요.")
    exit 1
}

# Validate the destination before loading the bearer credential.
function Resolve-Url {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Target
    )

    if ($Target -match '[\s\p{Cc}\\]' -or $Target.StartsWith('//')) {
        [Console]::Error.WriteLine("오류: 허용되지 않은 BILLING URL 형식입니다.")
        exit 1
    }

    if ($Target -ceq $BaseUrl -or
        $Target.StartsWith("$BaseUrl/", [StringComparison]::Ordinal) -or
        $Target.StartsWith("${BaseUrl}?", [StringComparison]::Ordinal)) {
        return $Target
    }

    if ($Target.StartsWith("/")) {
        return "$BaseUrl$Target"
    }

    [Console]::Error.WriteLine("오류: '/'로 시작하는 경로 또는 https://billing.example.com URL만 허용됩니다.")
    exit 1
}

# Main ------------------------------------------------------------------------

if ($Help) {
    Show-Usage
    exit 0
}

# Require Method + Path.
if ([string]::IsNullOrWhiteSpace($Method) -or [string]::IsNullOrWhiteSpace($Path)) {
    Show-Usage
    exit 1
}

# Validate Method against the allowlist BEFORE resolving the key or requesting.
$allowedMethods = @('GET','POST','PUT','HEAD')
if ($allowedMethods -cnotcontains $Method) {
    [Console]::Error.WriteLine("오류: 허용되지 않은 METHOD 입니다: $Method (허용: GET POST PUT HEAD)")
    exit 1
}

$url = Resolve-Url -Target $Path
$key = Resolve-BillingKey

$headers = @{ Authorization = "Bearer $key" }

try {
    if (($Method -ceq "POST" -or $Method -ceq "PUT") -and -not [string]::IsNullOrWhiteSpace($JsonBody)) {
        $response = Invoke-RestMethod -Method $Method -Uri $url -Headers $headers -TimeoutSec 30 -MaximumRedirection 0 -ContentType 'application/json' -Body $JsonBody
    }
    else {
        $response = Invoke-RestMethod -Method $Method -Uri $url -Headers $headers -TimeoutSec 30 -MaximumRedirection 0
    }
}
catch {
    # Surface request errors to the error stream, paralleling the bash wrapper's
    # curl error path. Do not leak the key.
    [Console]::Error.WriteLine("오류: BILLING API 요청에 실패했습니다. $($_.Exception.Message)")
    exit 1
}

# Invoke-RestMethod deserializes JSON responses into objects; re-serialize
# compactly so stdout carries raw JSON (matching the bash wrapper). Strings are
# passed through unchanged.
if ($response -is [string]) {
    [Console]::Out.WriteLine($response)
}
else {
    [Console]::Out.WriteLine((ConvertTo-CompactJson -InputObject $response))
}
