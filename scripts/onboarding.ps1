#!/usr/bin/env pwsh
#
# onboarding.ps1 — Windows 온보딩. macOS / Linux 는 onboarding.sh 를 쓴다.
#
# 셸 프로필을 건드리지 않는다. 자격증명은 ~/.config/msp/*.conf 에 저장하고
# 저장소 스크립트가 그 파일을 직접 읽는다. onboarding.sh 와 같은 경로 규약을 쓰므로
# 같은 사람이 두 OS 를 오가도 설정 위치가 같다.
#
# 사용:
#   pwsh -File scripts/onboarding.ps1           대화형
#   pwsh -File scripts/onboarding.ps1 -Check    확인만 (입력 없음)

param([switch]$Check)

$ErrorActionPreference = "Continue"

# STEPS-PARITY-START
$StepNames = @(
  "required-tools"
  "agents"
  "push-guard"
  "mcp"
  "customer-skill"
  "zendesk-credentials"
  "itsm-token"
  "usage-telemetry"
  "workspace-validation"
)
# STEPS-PARITY-END

$Root = Split-Path (Split-Path $MyInvocation.MyCommand.Path -Parent) -Parent
$UserHome = if ($env:USERPROFILE) { $env:USERPROFILE } else { $HOME }
# 에이전트 이름 → 스킬 설치 경로. install.ps1 의 테이블과 같은 규약.
$AgentTable = @(
  @{ Name = "claude-code"; Home = (Join-Path $UserHome ".claude") }
  @{ Name = "opencode";    Home = (Join-Path $UserHome ".config/opencode") }
  @{ Name = "kiro";        Home = (Join-Path $UserHome ".kiro") }
  @{ Name = "cursor";      Home = (Join-Path $UserHome ".cursor") }
  @{ Name = "windsurf";    Home = (Join-Path $UserHome ".codeium/windsurf") }
  @{ Name = "augment";     Home = (Join-Path $UserHome ".augment") }
  @{ Name = "codex";       Home = (Join-Path $UserHome ".agents") }
  @{ Name = "gemini";      Home = (Join-Path $UserHome ".gemini") }
  @{ Name = "hermes";      Home = (Join-Path $UserHome ".hermes") }
)

$ConfDir = Join-Path $UserHome ".config/msp"
$ZendeskConf = Join-Path $ConfDir "zendesk.conf"
$UsageConf = Join-Path $ConfDir "tiket-usage.conf"

# 결과는 셋으로 가른다 (2026-10-01). onboarding.sh 와 같다.
#   막힘 — 워크스페이스가 안 돌거나 경계가 깨진다. 이것만 exit 1 이다
#   제한 — 그 기능만 빠지고 나머지는 돈다. 어떤 기능이 빠지는지 이름을 붙인다
#   건너뜀 — 해당 없거나 대체 경로가 있다
# OUTCOME-START
# '제한' 이 붙이는 기능 이름. 세션 시작 알림(scripts/local_capabilities.py)과 같은 말이다.
$FTicket = "티켓 번호로 가져오기"
$FCustomer = "고객 AWS·비용 조회"
$FNotes = "고객 특이사항 읽기"
$FHermes = "Hermes 자동 업데이트·지표"
$FMetrics = "지표에 내 이름 표시"
$FValidate = "저장소 규칙 검사"
$script:BlockedCount = 0
$script:LimitedFeatures = @()
function Write-Ok      { param([string]$m) Write-Host "  OK    $m" -ForegroundColor Green }
function Write-Blocked { param([string]$m) Write-Host "  막힘  $m" -ForegroundColor Red; $script:BlockedCount++ }
function Write-Limited {
    param([string]$Feature, [string]$m)
    Write-Host "  제한  [$Feature] $m" -ForegroundColor Yellow
    if ($script:LimitedFeatures -notcontains $Feature) { $script:LimitedFeatures += $Feature }
}
function Write-Skip    { param([string]$m) Write-Host "  건너뜀 $m" -ForegroundColor Yellow }
function Write-Step    { param([string]$n, [string]$m) Write-Host "`n[$n] $m" }
function Complete-Onboarding {
    $limits = ""
    if ($script:LimitedFeatures.Count -gt 0) {
        $limits = "이 PC 에서 아직 안 되는 것: $($script:LimitedFeatures -join ', ') (위 '제한' 줄). 나머지는 지금 쓸 수 있다."
    }
    Write-Host ""
    if ($script:BlockedCount -gt 0) {
        Write-Host "막힌 항목 $($script:BlockedCount)개 — 이것부터 풀어야 워크스페이스가 돈다. 위 '막힘' 줄의 해결 방법을 따른 뒤 다시 실행한다." -ForegroundColor Red
        if ($limits) { Write-Host $limits }
        exit 1
    }
    Write-Host "온보딩 완료. 다음: ONBOARDING.md 의 `"연습해보기`"" -ForegroundColor Green
    Write-Host "AI 도구는 항상 이 폴더($Root)를 열어서 시작한다 — 상위 폴더를 열면 규칙·훅이 조용히 빠진다."
    if ($limits) { Write-Host $limits }
    exit 0
}
# OUTCOME-END

# ── 1. required-tools ────────────────────────────────────────────────────────
Write-Step "1/9" "필수 도구"
foreach ($bin in @("git", "python3", "curl", "jq")) {
    $found = Get-Command $bin -ErrorAction SilentlyContinue
    # Windows 에서 python3 가 없고 python 만 있는 경우가 흔하다.
    if (-not $found -and $bin -eq "python3") {
        $found = Get-Command "python" -ErrorAction SilentlyContinue
        if ($found) { Write-Ok "python (python3 대신)"; continue }
    }
    if ($found) { Write-Ok $bin }
    elseif ($bin -in @("git", "python3")) { Write-Blocked "$bin 없음 — winget install $bin 또는 scoop install $bin" }
    # curl·jq 는 fetch-ticket.sh 만 쓴다. Windows 판 fetch-ticket·고객 조회 스킬(.ps1)은 쓰지 않는다
    else        { Write-Skip "$bin 없음 — Windows 에서는 쓰지 않는다" }
}

# ── 2. agents ────────────────────────────────────────────────────────────────
Write-Step "2/9" "설치된 에이전트"
$detected = @()
foreach ($a in $AgentTable) {
    if (Test-Path $a.Home) {
        $detected += $a.Name
        $skillDir = Join-Path $a.Home "skills/aws-customer-account-ops"
        if (Test-Path (Join-Path $skillDir "SKILL.md")) {
            Write-Ok "$($a.Name)  (고객 조회 스킬 있음)"
        } else {
            Write-Ok $a.Name
        }
    }
}
if ($detected.Count -eq 0) {
    Write-Blocked "감지된 에이전트 없음 — Claude Code·Codex·Kiro·Hermes 중 하나는 설치돼 있어야 한다"
}

# ── 2. push-guard ────────────────────────────────────────────────────────────
Write-Step "3/9" "push guard"
$currentHooks = (git -C $Root config --get core.hooksPath 2>$null)
if ($currentHooks -eq ".githooks") {
    Write-Ok "core.hooksPath = .githooks"
} elseif ($Check) {
    Write-Blocked "core.hooksPath 미설정 — 해결: git config core.hooksPath .githooks"
} else {
    git -C $Root config core.hooksPath .githooks 2>$null
    if ($LASTEXITCODE -eq 0) { Write-Ok "core.hooksPath 를 .githooks 로 설정했다" }
    else                     { Write-Blocked "core.hooksPath 를 설정하지 못했다 — 해결: git config core.hooksPath .githooks" }
}
if (Test-Path (Join-Path $Root ".githooks/pre-push")) {
    Write-Ok "pre-push hook 존재"
} else {
    Write-Blocked "pre-push hook 이 없다"
}

# ── 4. mcp ───────────────────────────────────────────────────────────────────
# MCP 설정 파일은 clone 으로 따라온다. 확인할 것은 "실제로 붙는가" 뿐이다.
Write-Step "4/9" "MCP 연결"
foreach ($host_file in @(".mcp.json", ".claude/settings.json", ".codex/config.toml", ".kiro/settings/mcp.json")) {
    if (-not (Test-Path (Join-Path $Root $host_file))) {
        Write-Blocked "MCP 설정 누락: $host_file — python3 scripts/render_agent_configs.py 로 생성"
    }
}
$pyMcp = (Get-Command python3 -ErrorAction SilentlyContinue) ?? (Get-Command python -ErrorAction SilentlyContinue)
if ($pyMcp) {
    Push-Location $Root
    $mcpOut = & $pyMcp.Source scripts/verify_mcp_servers.py 2>&1
    $mcpRc = $LASTEXITCODE
    Pop-Location
    $mcpLast = ($mcpOut | Select-Object -Last 1)
    switch ($mcpRc) {
        0 { Write-Ok $mcpLast }
        2 { Write-Skip $mcpLast }   # 전제 조건 미비·네트워크 — 경계 위반이 아니다
        default { Write-Blocked $mcpLast }
    }
}
if (Test-Path (Join-Path $UserHome ".hermes")) {
    Write-Skip "Hermes 는 MCP 설정을 저장소 밖 프로필에 둔다. agents/environment/mcp-manifest.json 에 맞춰 직접 정렬한다"
    # Hermes 는 저장소 훅을 읽지 않는다. 세션 시작 훅(업데이트·지표)을 사용자 설정에 등록한다.
    # -Check 는 상태만 본다. 등록은 ~/.hermes/config.yaml 을 백업한 뒤에 하고 되돌리는 명령을 알린다.
    $hermesPy = (Get-Command python3 -ErrorAction SilentlyContinue) ?? (Get-Command python -ErrorAction SilentlyContinue)
    $hermesHook = Join-Path $Root "scripts/hermes_hook.py"
    if (-not $hermesPy) {
        Write-Skip "Hermes 세션 훅: python 이 없어 확인하지 못했다"
    } elseif ($Check) {
        $hermesState = (& $hermesPy.Source $hermesHook --status 2>$null) -join " "
        if ($LASTEXITCODE -eq 0) { Write-Ok "Hermes 세션 훅: $hermesState" } else { Write-Skip "Hermes 세션 훅: $hermesState" }
    } else {
        $hermesOut = @(& $hermesPy.Source $hermesHook --install 2>&1)
        if ($LASTEXITCODE -eq 0) {
            Write-Ok "Hermes 세션 훅: $($hermesOut[0])"
            $hermesOut | Select-Object -Skip 1 | ForEach-Object { Write-Host "        $_" }
        } else {
            Write-Limited $FHermes "Hermes 세션 훅: $($hermesOut -join ' ')"
        }
    }
}

# Kiro CLI 의 기본 v2 엔진은 저장소 훅(.kiro/hooks)을 읽지 않는다 — v3 에서만 돈다. 동료 대부분이
# v3 를 받아 놓고 --v3 없이 v2 로 쓰고 있었다(chat.agentEngine 이 비어 있다). -Check 는 알리기만 하고,
# 그 밖에는 **비어 있을 때만** `kiro-cli settings chat.agentEngine v3` 로 바꾸고 되돌리는 명령을 알린다.
# 판단은 scripts/kiro_engine.py 한 곳에 있다(fetch-ticket 도 같은 것을 부른다).
$kiroPy = (Get-Command python3 -ErrorAction SilentlyContinue) ?? (Get-Command python -ErrorAction SilentlyContinue)
if ((Get-Command kiro-cli -ErrorAction SilentlyContinue) -and $kiroPy) {
    $kiroScript = Join-Path $Root "scripts/kiro_engine.py"
    if (-not $Check) {
        $kiroChanged = (& $kiroPy.Source $kiroScript --ensure-v3 2>$null) -join " "
        if ($kiroChanged) { Write-Ok $kiroChanged }
    }
    $kiroState = (& $kiroPy.Source $kiroScript --status 2>$null) -join " "
    if ($LASTEXITCODE -eq 0) { Write-Ok $kiroState } else { Write-Skip $kiroState }
}

# Kiro(IDE·CLI v3)의 권한 규칙은 저장소에 둘 수 없고 각자 PC 의 ~/.kiro 에만 있다. 명령을 따로 돌리라고 하면
# 아무도 안 돌려서 여기서 바로 넣는다 — 있던 규칙은 두고 백업하며 되돌리는 명령을 알린다. -Check 는 알리기만 한다 (0030).
if ((Test-Path (Join-Path $HOME ".kiro")) -and $kiroPy) {
    $kiroRulesArgs = @()
    if (-not $Check) { $kiroRulesArgs = @("--install") }
    $kiroRules = (& $kiroPy.Source (Join-Path $Root "scripts/kiro_permissions.py") @kiroRulesArgs 2>$null) -join "`n"
    if ($LASTEXITCODE -eq 0) { Write-Ok $kiroRules } else { Write-Skip $kiroRules }
}

# ── 5. customer-skill ────────────────────────────────────────────────────────
# 스킬은 이 저장소의 skills/aws-customer-account-ops 에 있다 (0040). 옛 설치기 대신 scripts/skill_setup.py 가
# credential-broker.conf·csg-login 마커를 맞추고, 빌링 플랫폼 키가 없으면 터미널에서 한 번 묻는다(입력은 안 보인다).
# -Check 는 아무것도 바꾸지 않는다.
Write-Step "5/9" "고객 AWS 조회 스킬"
if ($kiroPy) {
    $skillSetupArgs = @()
    if (-not $Check) { $skillSetupArgs = @("--install") }
    $skillState = (& $kiroPy.Source (Join-Path $Root "scripts/skill_setup.py") @skillSetupArgs) -join "`n"
    if ($LASTEXITCODE -eq 0) { Write-Ok $skillState } else { Write-Limited $FCustomer $skillState }
} else {
    Write-Limited $FCustomer "python 이 없어 설정하지 못했다 (1단계 확인)"
}

# ── 3. zendesk-credentials ───────────────────────────────────────────────────
Write-Step "6/9" "Zendesk 자격증명"
function Test-ConfKey {
    param([string]$Key)
    if (-not (Test-Path $ZendeskConf)) { return $false }
    return [bool](Get-Content $ZendeskConf | Where-Object { $_ -match "^$Key=" })
}

if ((Test-ConfKey "ZENDESK_SUBDOMAIN") -and (Test-ConfKey "ZENDESK_EMAIL") -and (Test-ConfKey "ZENDESK_API_TOKEN")) {
    Write-Ok "설정됨: ~/.config/msp/zendesk.conf (값은 출력하지 않는다)"
} elseif ($Check) {
    Write-Limited $FTicket "Zendesk 미설정 — 해결: pwsh -File scripts/onboarding.ps1 (본문을 붙여 넣는 건 지금도 된다)"
} else {
    Write-Host ""
    Write-Host "  Zendesk 토큰을 등록한다. 티켓을 번호로 가져오려면 필요하다."
    Write-Host "  토큰 발급: Zendesk 관리센터 → 앱 및 통합 → API → Zendesk API → 토큰 추가"
    Write-Host ""

    # 빈 입력은 건너뛰기가 아니다. 건너뛰려면 skip 을 직접 입력해야 한다 —
    # 필수 단계에 쉬운 탈출구를 두면 대부분 그걸 누르고, 나중에 안 된다고 되돌아온다.
    function Read-Required {
        param([string]$Label)
        for ($i = 0; $i -lt 3; $i++) {
            $v = Read-Host "  $Label"
            if ($v -eq "skip") { return $null }
            if (-not [string]::IsNullOrWhiteSpace($v)) { return $v }
            Write-Host "    값이 필요하다. 지금 등록할 수 없으면 skip 을 입력한다."
        }
        return $null
    }

    $zdSub = Read-Required "Zendesk 서브도메인 (예: msp)"
    if (-not $zdSub) {
        Write-Skip "토큰 등록을 건너뛰었다. 티켓 조회는 아직 안 된다."
        Write-Skip "나중에 다시 실행: pwsh -File scripts/onboarding.ps1"
    } else {
        # 'Zendesk 로그인 이메일'로 적는다. 이 저장소에서 '에이전트'는 AI 도구를 뜻하므로
        # Zendesk 쪽 agent(상담원)와 겹쳐 읽는 사람이 자기 이메일인지 헷갈린다.
        $zdEmail = Read-Required "Zendesk 로그인 이메일 (본인 계정)"
        if (-not $zdEmail) {
            Write-Skip "토큰 등록을 건너뛰었다. 나중에 다시 실행: pwsh -File scripts/onboarding.ps1"
        } else {
            $zdTokenSecure = Read-Host "  API 토큰 (화면에 안 보인다)" -AsSecureString
            $zdToken = [System.Net.NetworkCredential]::new("", $zdTokenSecure).Password

            if ([string]::IsNullOrWhiteSpace($zdToken)) {
                Write-Limited $FTicket "토큰이 비었다. 저장하지 않았다. 다시 실행: pwsh -File scripts/onboarding.ps1"
            } else {
                $zdHost = if ($zdSub -like "*.zendesk.com") { $zdSub } else { "$zdSub.zendesk.com" }
                Write-Host "  확인 중: https://$zdHost ..."
                $pair = "$zdEmail/token:$zdToken"
                $basic = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes($pair))
                $code = 0
                try {
                    $resp = Invoke-WebRequest -Uri "https://$zdHost/api/v2/users/me.json" `
                        -Headers @{ Authorization = "Basic $basic" } `
                        -TimeoutSec 20 -UseBasicParsing -ErrorAction Stop
                    $code = $resp.StatusCode
                } catch {
                    if ($_.Exception.Response) { $code = [int]$_.Exception.Response.StatusCode }
                }

                if ($code -eq 200) {
                    $who = "?"
                    try { $u = ($resp.Content | ConvertFrom-Json).user; $who = "$($u.name) ($($u.role))" } catch {}
                    New-Item -ItemType Directory -Force -Path $ConfDir | Out-Null
                    $lines = @(
                        "# tiket Zendesk credentials. 이 파일 내용을 채팅·이슈·PR 에 붙여넣지 않는다."
                        "# 다시 설정하려면: pwsh -File scripts/onboarding.ps1"
                        "ZENDESK_SUBDOMAIN=$zdSub"
                        "ZENDESK_EMAIL=$zdEmail"
                        "ZENDESK_API_TOKEN=$zdToken"
                    )
                    Set-Content -Path $ZendeskConf -Value $lines -Encoding UTF8
                    # NTFS 에는 chmod 가 없다. 상속을 끊고 현재 사용자만 남긴다.
                    try {
                        $acl = Get-Acl $ZendeskConf
                        $acl.SetAccessRuleProtection($true, $false)
                        $acl.Access | ForEach-Object { $acl.RemoveAccessRule($_) | Out-Null }
                        $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
                            "$env:USERDOMAIN\$env:USERNAME", "FullControl", "Allow")
                        $acl.SetAccessRule($rule)
                        Set-Acl -Path $ZendeskConf -AclObject $acl
                    } catch {
                        Write-Skip "파일 권한을 좁히지 못했다. 사용자만 읽도록 직접 확인한다: $ZendeskConf"
                    }
                    Write-Ok "인증 성공 ($who) — ~/.config/msp/zendesk.conf 에 저장"
                } elseif ($code -eq 401 -or $code -eq 403) {
                    Write-Limited $FTicket "인증 거부 (HTTP $code). 이메일 또는 토큰이 맞지 않는다. 저장하지 않았다."
                } else {
                    Write-Limited $FTicket "Zendesk 응답 HTTP $code. 서브도메인과 네트워크를 확인한다. 저장하지 않았다."
                }
            }
        }
    }
}

# ── 7. itsm-token ────────────────────────────────────────────────────────
# 고객 특이사항(scripts/customer_notes.py)을 읽는 ITSM 개인 토큰. 각자 ITSM 화면에서 발급한다 (0034 개정 1).
# scripts/itsm_token.py 가 터미널에서 묻고(입력은 안 보인다) GET 한 번으로 확인한 뒤
# ~/.config/msp/itsm 의 ITSM_API_TOKEN 한 줄만 바꾼다 — 다른 키는 그대로. -Check 는 아무것도 바꾸지 않는다.
Write-Step "7/9" "ITSM 토큰"
if ($kiroPy) {
    $itsmArgs = @()
    if (-not $Check) { $itsmArgs = @("--install") }
    $itsmState = (& $kiroPy.Source (Join-Path $Root "scripts/itsm_token.py") @itsmArgs) -join "`n"
    if ($LASTEXITCODE -eq 0) { Write-Ok $itsmState } else { Write-Limited $FNotes $itsmState }
} else {
    Write-Limited $FNotes "python 이 없어 설정하지 못했다 (1단계 확인)"
}

# ── 8. usage-telemetry ───────────────────────────────────────────────────────
Write-Step "8/9" "사용 지표"

# 6단계에서 이미 본인 Zendesk 자격증명을 넣었다. 거기 적힌 상담사 이름이
# git user.name 보다 사람 이름에 가깝다. 안 되면 조용히 빈 값을 돌려준다 —
# 지표 이름 때문에 온보딩이 멈추면 안 된다.
$EMAIL_SHAPED = '^[^@\s]+@[^@\s]+\.[^@\s]+$'
function Get-ZendeskAgentName {
    if (-not (Test-Path $ZendeskConf)) { return "" }
    try {
        $conf = @{}
        Get-Content $ZendeskConf | ForEach-Object {
            if ($_ -match '^([A-Z_]+)=(.*)$') { $conf[$Matches[1]] = $Matches[2] }
        }
        $sub = $conf["ZENDESK_SUBDOMAIN"]; $email = $conf["ZENDESK_EMAIL"]; $token = $conf["ZENDESK_API_TOKEN"]
        if (-not $sub -or -not $email -or -not $token) { return "" }
        $zdHost = if ($sub -like "*.zendesk.com") { $sub } else { "$sub.zendesk.com" }
        $pair = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("${email}/token:${token}"))
        $resp = Invoke-RestMethod -Uri "https://$zdHost/api/v2/users/me.json" -TimeoutSec 10 `
            -Headers @{ Authorization = "Basic $pair" } -ErrorAction Stop
        $name = $resp.user.name
        # 이름이 이메일 형태인 계정이 있다. 그대로 쓰면 수집기가 422 로 거절한다.
        if ($name -match $EMAIL_SHAPED) { return "" }
        return $name
    } catch { return "" }
}

function Test-UsageKey {
    param([string]$Key)
    if (-not (Test-Path $UsageConf)) { return $false }
    return [bool](Get-Content $UsageConf | Where-Object { $_ -match "^$Key=" })
}

function Get-UsageValue {
    param([string]$Key)
    if (-not (Test-Path $UsageConf)) { return "" }
    $line = Get-Content $UsageConf | Where-Object { $_ -match "^$Key=" } | Select-Object -First 1
    if ($line) { return ($line -replace "^$Key=", "") }
    return ""
}

# 기본 켜짐이다 (2026-09-29). 고지는 -Check 에서도, AI 가 돌려도 **항상** 나온다 —
# 예전에는 이름을 적어야 켜졌고, AI 온보딩·pull 만 한 동료가 조용히 빠졌다.
function Write-UsageNotice {
    Write-Host ""
    Write-Host "  이 저장소는 기본으로 두 가지를 사내 계정으로 보낸다 (세션 시작 때, 6시간에 한 번)."
    Write-Host "  1) 사용 지표 — 숫자와 고정 문자열뿐이다. 티켓 번호·고객·계정·이메일은 들어가지 않는다."
    Write-Host "     하루 한 번 내 Zendesk 계정으로 내가 해결한 티켓의 처리 시간을 읽어 주별 중앙값·건수만 싣는다."
    Write-Host "  2) 교훈 후보 — 티켓 기록의 '교훈 후보' 칸이 채워졌을 때만. 티켓 번호·고객 corpId·"
    Write-Host "     교훈 한 줄·질문과 확인 내용 발췌가 간다. 90일 뒤 지워지고, 승인된 것만 팀 자산이 된다."
    Write-Host "  무엇이 나가는지 언제든 확인:  python3 scripts/report_usage.py · python3 scripts/report_lessons.py"
    Write-Host "  끄기: ~/.config/msp/tiket-usage.conf 에 TIKET_TELEMETRY=off (둘 다) 또는 TIKET_LESSONS=off (교훈 후보만)"
    Write-Host ""
}

Write-UsageNotice
if ((Get-UsageValue "TIKET_TELEMETRY") -eq "off") {
    Write-Skip "꺼짐 — 본인이 conf 에 TIKET_TELEMETRY=off 를 넣었다"
} elseif (Test-UsageKey "TIKET_ENGINEER") {
    Write-Ok "켜짐 — 이름: $(Get-UsageValue "TIKET_ENGINEER"). 끄기: conf 에 TIKET_TELEMETRY=off"
} else {
    $gitName = (git config user.name 2>$null)
    if ($Check -or [Console]::IsInputRedirected) {
        $shownGit = if ($gitName) { $gitName } else { "unknown" }
        Write-Ok "켜짐 — 이름은 git user.name($shownGit). 이름을 정하려면 터미널에서 pwsh -File scripts/onboarding.ps1"
    } else {
        # Zendesk 상담사 이름 → git user.name → 미설정
        $defaultName = Get-ZendeskAgentName
        if ([string]::IsNullOrWhiteSpace($defaultName)) { $defaultName = $gitName }
        if ([string]::IsNullOrWhiteSpace($defaultName)) { $defaultName = "" }
        $shown = if ($defaultName) { $defaultName } else { "미설정" }
        $engineerName = Read-Host "  지표에 표시될 이름 [$shown]"
        if ([string]::IsNullOrWhiteSpace($engineerName)) { $engineerName = $defaultName }

        if ([string]::IsNullOrWhiteSpace($engineerName)) {
            Write-Limited $FMetrics "이름이 비었다 — git config user.name 도 없다. 지표가 unknown 으로 섞인다"
        } else {
            # 엔드포인트도 API 키도 묻지 않는다. 엔드포인트는 팀에 하나뿐이라
            # report_usage.py 가 기본값으로 알고, 키는 두지 않는다 (0021).
            New-Item -ItemType Directory -Force -Path $ConfDir | Out-Null
            Set-Content -Path $UsageConf -Value @("TIKET_ENGINEER=$engineerName") -Encoding utf8
            Write-Ok "켜짐 — 이름 저장: ~/.config/msp/tiket-usage.conf"
        }
    }
}

# ── 4. workspace-validation ──────────────────────────────────────────────────
Write-Step "9/9" "저장소 검증"
$py = (Get-Command python3 -ErrorAction SilentlyContinue) ?? (Get-Command python -ErrorAction SilentlyContinue)
if ($py) {
    Push-Location $Root
    $out = & $py.Source scripts/validate_workspace.py 2>&1
    $rc = $LASTEXITCODE
    Pop-Location
    if ($rc -eq 0) { Write-Ok ($out | Select-Object -First 1) }
    else           { Write-Limited $FValidate "$(($out | Select-Object -First 3) -join ' / ') — 이 줄을 유지보수자에게 전달한다" }
} else {
    Write-Skip "python 이 없어 검증을 건너뛰었다 (1단계 막힘)"
}

# ── 결과 ─────────────────────────────────────────────────────────────────────
Complete-Onboarding
