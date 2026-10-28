#!/usr/bin/env pwsh
#
# fetch-ticket.ps1 — Zendesk 티켓 번호로 메타 + 전체 코멘트 스레드를 가져온다.
# fetch-ticket.sh 의 Windows 대응. 같은 conf 파일을 읽고 같은 형식으로 출력한다.
#
# 사용:
#   pwsh -File scripts/fetch-ticket.ps1 <티켓번호>
#   pwsh -File scripts/fetch-ticket.ps1 <티켓번호> -Json
#   pwsh -File scripts/fetch-ticket.ps1 <티켓번호> -Images <디렉터리>

param(
    [Parameter(Mandatory = $true, Position = 0)][string]$TicketId,
    [switch]$Json,
    [string]$Images
)

$ErrorActionPreference = "Stop"

$UserHome = if ($env:USERPROFILE) { $env:USERPROFILE } else { $HOME }
$Conf = Join-Path $UserHome ".config/msp/zendesk.conf"

function Get-ConfValue {
    param([string]$Key)
    if (-not (Test-Path $Conf)) { return "" }
    $line = Get-Content $Conf | Where-Object { $_ -match "^$Key=" } | Select-Object -First 1
    if ($line) { return ($line -replace "^$Key=", "") }
    return ""
}

function Resolve-Setting {
    param([string]$OurEnv, [string]$LegacyEnv, [string]$ConfKey)
    foreach ($v in @($OurEnv, $LegacyEnv)) {
        if ($v) { $val = [Environment]::GetEnvironmentVariable($v); if ($val) { return $val } }
    }
    return (Get-ConfValue $ConfKey)
}

if ($TicketId -notmatch '^\d+$') {
    Write-Error "티켓번호는 숫자만: $TicketId"; exit 1
}

# 2층. 세션 훅은 프로젝트를 신뢰로 표시해야 돌고, 갓 clone 한 사람에게는 꺼져 있다.
# 티켓을 가져오는 시점은 호스트와 신뢰 설정에 무관하게 반드시 지나간다 (0020).
# 세션 도중이라 올리지 않고 알리기만 한다 (0025). 알림은 stderr 로 보낸다 — stdout 은
# 티켓 본문이고 -Json 이면 파싱된다. (이전에는 *> $null 이라 알림이 아예 안 보였다.)
& pwsh -NoProfile -File (Join-Path $PSScriptRoot 'check-freshness.ps1') -NotifyOnly 2>$null |
    ForEach-Object { [Console]::Error.WriteLine($_) }
# 사용 지표도 여기서 한 번 보낸다. Hermes·신뢰 전 Codex·훅이 안 도는 Windows 는 세션 훅으로
# 못 보낸다 (2026-09-29). 6시간 스로틀·무출력·실패 무시는 --if-due 안에 있다.
$usagePy = (Get-Command python3 -ErrorAction SilentlyContinue) ?? (Get-Command python -ErrorAction SilentlyContinue)
if ($usagePy) {
    try { & $usagePy.Source (Join-Path $PSScriptRoot 'report_usage.py') --if-due *> $null } catch { }
    # Kiro CLI v2 엔진은 세션 훅을 안 돌려서 여기가 유일하게 닿는 곳이다. 엔진 설정이 비어 있으면
    # v3 로 바꾸고 되돌리는 명령을 stderr 로 알린다. 일부러 정한 값은 덮지 않는다 (kiro_engine.py).
    try {
        & $usagePy.Source (Join-Path $PSScriptRoot 'kiro_engine.py') --ensure-v3 2>$null |
            ForEach-Object { [Console]::Error.WriteLine($_) }
    } catch { }
}

$zdSub   = Resolve-Setting "ZENDESK_SUBDOMAIN"  "Zendesk_SUBDOMAIN" "ZENDESK_SUBDOMAIN"
$zdEmail = Resolve-Setting "ZENDESK_EMAIL"      "Zendesk_EMAIL"     "ZENDESK_EMAIL"
$zdToken = Resolve-Setting "ZENDESK_API_TOKEN"  "Zendesk_API"       "ZENDESK_API_TOKEN"

$missing = @()
if (-not $zdSub)   { $missing += "ZENDESK_SUBDOMAIN" }
if (-not $zdEmail) { $missing += "ZENDESK_EMAIL" }
if (-not $zdToken) { $missing += "ZENDESK_API_TOKEN" }
if ($missing.Count -gt 0) {
    Write-Host "Zendesk 자격증명 없음: $($missing -join ' ')" -ForegroundColor Red
    Write-Host "해결: pwsh -File scripts/onboarding.ps1 를 실행해 토큰을 등록한다."
    exit 1
}

$zdHost = if ($zdSub -like "*.zendesk.com") { $zdSub } else { "$zdSub.zendesk.com" }
$base = "https://$zdHost/api/v2"
$basic = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("$zdEmail/token:$zdToken"))
$headers = @{ Authorization = "Basic $basic" }

# Zendesk 한도는 분당 400 이고 계정 전체가 나눠 쓴다(응답 헤더 x-rate-limit, 2026-10-07). 걸리면 429 와
# Retry-After(초)가 온다. 그만큼 기다렸다 다시 부른다 — 그냥 실패하면 에이전트가 곧바로 다시 불러 한도를 더 쓴다.
$MaxRateRetries = 2
$MaxRateWait = 60
$MaxRateDefaultWait = 10

function Invoke-Zd {
    param([string]$Url)
    $attempt = 0
    while ($true) {
        try {
            return Invoke-RestMethod -Uri $Url -Headers $headers -TimeoutSec 30 -ErrorAction Stop
        } catch {
            $response = $_.Exception.Response
            $code = if ($response) { [int]$response.StatusCode } else { 0 }
            if ($code -eq 429 -and $attempt -lt $MaxRateRetries) {
                $raw = $null
                try {
                    if ($response.Headers -is [System.Net.WebHeaderCollection]) {
                        $raw = $response.Headers['Retry-After']  # Windows PowerShell 5.1
                    } else {
                        $values = $null
                        if ($response.Headers.TryGetValues('Retry-After', [ref]$values)) { $raw = @($values)[0] }
                    }
                } catch { }
                $wait = 0
                if (-not ([int]::TryParse([string]$raw, [ref]$wait)) -or $wait -le 0) { $wait = $MaxRateDefaultWait }
                if ($wait -gt $MaxRateWait) { $wait = $MaxRateWait }
                $attempt++
                Write-Host "Zendesk 요청 한도 초과(429) — ${wait}초 기다렸다 다시 부른다 ($attempt/$MaxRateRetries)"
                Start-Sleep -Seconds $wait
                continue
            }
            Write-Host "Zendesk API $Url → HTTP $code" -ForegroundColor Red
            if ($code -eq 401) { Write-Host "인증 거부. 토큰을 다시 등록한다: pwsh -File scripts/onboarding.ps1" }
            if ($code -eq 404) { Write-Host "티켓을 찾을 수 없다. 번호와 서브도메인을 확인한다." }
            if ($code -eq 429) { Write-Host "요청 한도 초과가 풀리지 않았다. 계정 전체가 나눠 쓰는 한도다 — 바로 다시 실행하지 말고 1분 뒤에 한다." }
            exit 1
        }
    }
}

# 페이지네이션 끝까지. 코멘트 100건 넘는 스레드가 잘리지 않게 한다.
function Invoke-ZdAll {
    param([string]$Path, [string]$Key)
    $url = "$base$Path"
    $acc = @()
    while ($url) {
        $body = Invoke-Zd $url
        if ($body.$Key) { $acc += $body.$Key }
        # cursor 방식(meta.has_more) 우선, 없으면 offset 방식(next_page)으로 폴백.
        if ($body.meta -and $body.meta.has_more -eq $true -and $body.links.next) {
            $url = $body.links.next
        } elseif ($body.next_page) {
            $url = $body.next_page
        } else {
            $url = $null
        }
    }
    return $acc
}

$ticketResp = Invoke-Zd "$base/tickets/$TicketId.json"
$ticket = $ticketResp.ticket
$comments = Invoke-ZdAll "/tickets/$TicketId/comments.json?sort_order=asc" "comments"

if ($Json) {
    [PSCustomObject]@{ ticket = $ticket; comments = $comments } | ConvertTo-Json -Depth 20
    exit 0
}

$authorIds = ($comments | ForEach-Object { $_.author_id } | Sort-Object -Unique) -join ","
$usersResp = Invoke-Zd "$base/users/show_many.json?ids=$authorIds"
$userMap = @{}
foreach ($u in $usersResp.users) { $userMap[[string]$u.id] = $u }

$bar = "════════════════════════════════════════════════════════════"
Write-Output $bar
Write-Output "TICKET #$($ticket.id)  [$($ticket.status)]"
Write-Output "제목   : $($ticket.subject)"
Write-Output "생성   : $($ticket.created_at)   업데이트: $($ticket.updated_at)"
$pri = if ($ticket.priority) { $ticket.priority } else { "-" }
$typ = if ($ticket.type) { $ticket.type } else { "-" }
Write-Output "우선순위: $pri   유형: $typ"
Write-Output "링크   : https://$zdHost/agent/tickets/$TicketId"
Write-Output "조회일 : $(Get-Date -Format 'yyyy-MM-dd')   (기록의 작성일 — 스레드 날짜가 아니다)"
Write-Output $bar
Write-Output ""

$sep = "──────────────────────────────────────────────"
foreach ($c in $comments) {
    $a = $userMap[[string]$c.author_id]
    $name = if ($a) { $a.name } else { "(알 수 없음)" }
    $role = if ($a) { $a.role } else { "?" }
    $vis = if ($c.public) { "  · 공개" } else { "  · 내부 메모" }
    Write-Output $sep
    Write-Output "[$($c.created_at)] $name ($role)$vis"
    Write-Output $sep
    Write-Output $c.body
    if ($c.attachments -and $c.attachments.Count -gt 0) {
        $list = ($c.attachments | ForEach-Object {
            $kb = [math]::Floor(($(if ($_.size) { $_.size } else { 0 })) / 1024)
            "$($_.file_name) (${kb}KB)"
        }) -join ", "
        Write-Output ""
        Write-Output "첨부: $list"
    }
    Write-Output ""
}

# 첨부는 본문 텍스트에 안 들어온다. 존재만 알리고 내용 확인은 사람에게 넘긴다.
#
# Zendesk 는 본문에 붙여넣은 이미지를 attachments 배열에 안 넣고 본문 마크다운 링크로만
# 남기는 경우가 있다. attachments 만 세면 이미지가 4장 있어도 "첨부 없음"으로 보이고,
# 읽는 쪽은 자기가 뭘 못 봤는지조차 모른 채 답변을 쓰게 된다. 둘 다 센다.
$attachN = ($comments | ForEach-Object { if ($_.attachments) { $_.attachments.Count } else { 0 } } | Measure-Object -Sum).Sum
$inlineUrls = @()
foreach ($c in $comments) {
    if ($c.body) {
        $m = [regex]::Matches($c.body, 'https://[^)\s]+/attachments/token/[^)\s]+')
        foreach ($x in $m) { $inlineUrls += $x.Value }
    }
}
$inlineUrls = $inlineUrls | Sort-Object -Unique
$inlineN = $inlineUrls.Count
$totalImg = $attachN + $inlineN

if ($Images -and $inlineN -gt 0) {
    New-Item -ItemType Directory -Force -Path $Images | Out-Null
    Write-Output ""
    Write-Output $bar
    Write-Output "본문 이미지 ${inlineN}건 내려받기 → $Images"
    $i = 0
    foreach ($url in $inlineUrls) {
        $i++
        $dest = Join-Path $Images "img$i.png"
        try {
            # 자격증명은 우리 Zendesk 호스트에만 보낸다. 고객사 헬프데스크 등 다른 호스트로
            # Authorization 헤더를 흘리면 우리 토큰을 제3자에게 넘기는 것이 된다.
            if ($url.StartsWith("https://$zdHost/")) {
                Invoke-WebRequest -Uri $url -Headers $headers -OutFile $dest -TimeoutSec 60 -ErrorAction Stop
            } else {
                Invoke-WebRequest -Uri $url -OutFile $dest -TimeoutSec 60 -ErrorAction Stop
            }
            Write-Output "  img$i.png  ←  $($url.Substring(0, [Math]::Min(60, $url.Length)))..."
        } catch {
            Write-Output "  img$i.png  실패  ←  $($url.Substring(0, [Math]::Min(60, $url.Length)))..."
        }
    }
    Write-Output $bar
} elseif ($totalImg -gt 0) {
    Write-Output ""
    Write-Output $bar
    Write-Output "※ 이미지 ${totalImg}건 (첨부 ${attachN} · 본문 삽입 ${inlineN})."
    Write-Output "  내용은 위 텍스트에 없다. 답변에 그 정보가 필요하면 추측하지 말고 받아서 본다:"
    Write-Output "    pwsh -File scripts/fetch-ticket.ps1 $TicketId -Images <저장할디렉터리>"
    Write-Output $bar
}
