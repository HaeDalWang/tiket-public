# check-freshness.ps1 — check-freshness.sh 의 Windows 대응본.
#
# 새 정식 버전(vX.Y.Z 태그)이 나왔으면 워크스페이스를 올린다. 태그만 올리고, 안전할
# 때만 올린다 — main 브랜치이고, 고친 추적 파일이 없고, fast-forward 로 갈 수 있을 때.
# 하나라도 아니면 올리지 않고 이유와 명령을 알린다. development/decisions/0025 참조.
#
# 사용:
#   pwsh -File scripts/check-freshness.ps1               6시간에 1회. 세션 시작 훅이 부른다
#   pwsh -File scripts/check-freshness.ps1 -Force        스로틀 무시
#   pwsh -File scripts/check-freshness.ps1 -NotifyOnly   올리지 않고 알리기만 (fetch-ticket)
#
# 어떤 실패도 세션을 막지 않는다. 확인이 안 되면 조용히 끝낸다.

param([switch]$Force, [switch]$NotifyOnly)

$ErrorActionPreference = "SilentlyContinue"

# TIKET_* 재정의는 테스트용이다 (test_check_freshness.py).
$ExpectedRemote = if ($env:TIKET_EXPECTED_REMOTE) { $env:TIKET_EXPECTED_REMOTE } else { "https://github.com/example-org/tiket.git" }
$UserHome = if ($env:HOME) { $env:HOME } else { $env:USERPROFILE }
$Stamp = if ($env:TIKET_FRESHNESS_STAMP) { $env:TIKET_FRESHNESS_STAMP } else { Join-Path $UserHome ".config/msp/tiket-freshness" }
# 6시간. 사용 지표와 같다 — 새 릴리스가 하루 늦게 닿지 않게 (2026-09-29).
$IntervalSeconds = 21600
$UpdateBranch = "main"
# 세션이 시작될 때 이미 읽혔을 수 있는 진입 규칙. 바뀌면 다시 읽으라고 알린다.
$EntryFiles = @("CLAUDE.md", "AGENTS.md", ".kiro/steering")

$Root = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
if (-not $Root) { exit 0 }
Set-Location $Root
git rev-parse --git-dir *> $null
if ($LASTEXITCODE -ne 0) { exit 0 }

# 이 PC 에서 아직 안 되는 기능을 매 세션 알린다 — 스로틀보다 먼저다. check-freshness.sh 와 같다.
# 세션 도중 부르는 fetch-ticket(-NotifyOnly)에서는 되풀이하지 않는다. 판단은 local_capabilities.py.
if (-not $NotifyOnly) {
    $capPy = Get-Command python3 -ErrorAction SilentlyContinue
    if (-not $capPy) { $capPy = Get-Command python -ErrorAction SilentlyContinue }
    if ($capPy) { & $capPy.Source (Join-Path $Root "scripts/local_capabilities.py") --if-missing 2>$null }
}

# "소유자/저장소" 만 비교한다. SSH 별칭, 사용자명이 붙은 https, ssh:// 를 모두 같은 저장소로 본다 —
# 주소 전체를 비교했더니 다르게 clone 한 사람은 영영 안 올라갔다 (2026-09-29). check-freshness.sh 와 같다.
function Get-NormalizedRemote {
    param([string]$Url)
    $u = ($Url -replace '\\', '/') -replace '/+$', ''
    $u = ($u -replace '\.git$', '') -replace ':', '/'
    $parts = @($u -split '/' | Where-Object { $_ -ne '' })
    if ($parts.Count -lt 2) { return $u.ToLowerInvariant() }
    return ("{0}/{1}" -f $parts[-2], $parts[-1]).ToLowerInvariant()
}

# origin 이 옛 주소면 스로틀과 무관하게 매번 알린다. 옛 저장소는 살아 있어서
# fetch 가 성공하고 "새 버전 없음" 이 나온다 — 거짓 초록불이 뜨는 자리다.
$originUrl = git remote get-url origin 2>$null
if ($originUrl -and
    ((Get-NormalizedRemote $originUrl) -ne (Get-NormalizedRemote $ExpectedRemote))) {
    Write-Output "origin 이 공용 저장소가 아니다: $originUrl"
    Write-Output "  git remote set-url origin $ExpectedRemote"
    exit 0
}

$now = [int][double]::Parse((Get-Date -UFormat %s))
if (-not $Force -and (Test-Path $Stamp)) {
    $last = 0
    [void][int]::TryParse((Get-Content $Stamp -Raw).Trim(), [ref]$last)
    if (($now - $last) -lt $IntervalSeconds) { exit 0 }
}

function Set-Stamp {
    New-Item -ItemType Directory -Force -Path (Split-Path $Stamp) *> $null
    Set-Content -Path $Stamp -Value $now -NoNewline
}

# 네트워크 실패에는 스탬프를 찍는다. 오프라인에서 매 세션 느린 fetch 를 반복하지 않기
# 위해서다. 대신 오프라인인 날은 확인을 한 번 건너뛴다.
# 멈춘 연결은 git 이 스스로 끊는다(15초 동안 1KB/s 미만). check-freshness.sh 와 같다.
# 세 번 연속 실패하면 말한다 — check-freshness.sh 의 fetch_failed 와 같다 (2026-10-07).
$FetchFailures = "$Stamp-fetch-failures"
$FetchNoticeAfter = 3
git -c http.lowSpeedLimit=1000 -c http.lowSpeedTime=15 fetch --quiet --tags origin *> $null
if ($LASTEXITCODE -ne 0) {
    Set-Stamp
    $count = 0
    if (Test-Path $FetchFailures) { [void][int]::TryParse((Get-Content $FetchFailures -Raw).Trim(), [ref]$count) }
    $count++
    Set-Content -Path $FetchFailures -Value $count -NoNewline
    if ($count -ge $FetchNoticeAfter) {
        Write-Output "[tiket] 워크스페이스 새 버전 확인이 ${count}번 연속 실패했다 — 자동 업데이트가 멈춰 있다. 지금 하는 작업에는 영향이 없다 — 작업을 먼저 끝낸다."
        Write-Output '답 끝에 사용자에게 한 줄로 알리고, `git fetch --tags origin` 을 직접 돌려 나온 오류를 유지보수자에게 전해 달라고 한다.'
        Write-Output '직접 고치려 하지 않는다 — 원격 주소·자격 증명·git 설정을 바꾸지 않는다.'
    }
    exit 0
}
Remove-Item -Force -ErrorAction SilentlyContinue $FetchFailures

$python = (Get-Command python3 -ErrorAction SilentlyContinue) ?? (Get-Command python -ErrorAction SilentlyContinue)
if (-not $python) { Set-Stamp; exit 0 }
$refs = git for-each-ref --format='%(objectname)%09%(refname)' refs/tags
$latest = ($refs -join "`n") | & $python.Source (Join-Path $Root "scripts/release_tags.py") latest
if ($LASTEXITCODE -ne 0 -or -not $latest) { Set-Stamp; exit 0 }
$latest = ($latest | Select-Object -First 1).Trim()

# 이미 그 태그를 품고 있으면(같거나 앞서 있으면) 할 일이 없다.
git merge-base --is-ancestor $latest HEAD *> $null
if ($LASTEXITCODE -eq 0) { Set-Stamp; exit 0 }

$current = git describe --tags --abbrev=0 --match 'v[0-9]*' HEAD 2>$null
if ($LASTEXITCODE -ne 0 -or -not $current) { $current = "태그 이전" }

# 올리지 못할 때는 스탬프를 찍지 않는다. 호출 지점이 여럿이라 한 곳에서 스탬프만
# 소모되고 알림은 사용자에게 안 보이는 경우가 생긴다. 올라갈 때까지 매번 알린다.
function Stop-HeldBack {
    param([string]$Reason, [string]$Hint)
    Write-Output "워크스페이스 새 버전 $latest 이 나왔다 (지금 $current). 자동으로 올리지 않았다 — $Reason"
    if ($Hint) { Write-Output "  $Hint" }
    exit 0
}

if ($NotifyOnly) {
    Stop-HeldBack "세션 도중이라 알리기만 한다" "다음 세션 시작 때 올라간다. 지금 올리려면: pwsh -File scripts/check-freshness.ps1 -Force"
}

$branch = git symbolic-ref --quiet --short HEAD 2>$null
if ($LASTEXITCODE -ne 0 -or -not $branch) { $branch = "브랜치 없음" }
if ($branch -ne $UpdateBranch) {
    Stop-HeldBack "$UpdateBranch 가 아니라 $branch 에 있다" "git switch $UpdateBranch 후 다시 세션을 연다"
}

$modified = @(git diff --name-only HEAD 2>$null | Select-Object -First 5)
if ($modified.Count -gt 0) {
    Stop-HeldBack "고친 파일이 있다: $($modified -join ' ')" "고친 것을 커밋하거나 되돌린 뒤: git merge --ff-only $latest"
}

git merge-base --is-ancestor HEAD $latest *> $null
if ($LASTEXITCODE -ne 0) {
    Stop-HeldBack "로컬 커밋이 있어 그대로 올릴 수 없다" "git log --oneline $latest..HEAD 로 확인한 뒤: git merge $latest"
}

# 서명 검증 — merge 하기 전. 서명자 파일이 **지금 HEAD 에** 커밋돼 있으면 그 목록으로 태그를
# 검증한 뒤에만 올린다. 새 태그 안의 파일이나 작업 폴더의 파일을 믿지 않는다 (hardening #3).
# HEAD 에 서명자 파일이 없으면(서명 도입 전) 검증 없이 올린다. check-freshness.sh 와 같다.
git cat-file -e "HEAD:scripts/release-signers" *> $null
if ($LASTEXITCODE -eq 0) {
    $signersTmp = [System.IO.Path]::GetTempFileName()
    $signersContent = git show HEAD:scripts/release-signers 2>$null
    if ($LASTEXITCODE -ne 0) {
        Remove-Item -Force $signersTmp -ErrorAction SilentlyContinue
        Stop-HeldBack "HEAD 의 서명자 목록을 읽지 못했다" "git show HEAD:scripts/release-signers 로 확인한다"
    }
    # Set-Content 는 Windows PowerShell 5.1 에서 CRLF 로 쓴다 — ssh-keygen 이 읽는 파일이라 LF 로 직접 쓴다.
    [System.IO.File]::WriteAllText($signersTmp, (($signersContent -join "`n") + "`n"))
    git -c gpg.format=ssh -c "gpg.ssh.allowedSignersFile=$signersTmp" verify-tag $latest *> $null
    $verifyRc = $LASTEXITCODE
    Remove-Item -Force $signersTmp -ErrorAction SilentlyContinue
    if ($verifyRc -ne 0) {
        Stop-HeldBack "태그 서명을 확인하지 못했다" "$latest 가 등록된 키로 서명되어 있는지 유지보수자에게 확인한다"
    }
}

$before = git rev-parse HEAD
$mergeLog = git merge --ff-only --quiet $latest 2>&1
if ($LASTEXITCODE -ne 0) {
    Stop-HeldBack "git merge 가 실패했다: $(@($mergeLog)[0])" "git merge --ff-only $latest"
}

Set-Stamp
Write-Output "워크스페이스를 $latest 로 올렸다 (이전 $current)."
$notes = @(git tag -l --format='%(contents)' $latest 2>$null)
$shown = 0
foreach ($line in ($notes | Select-Object -Skip 1)) {
    if ($line -match '-----BEGIN') { break }
    if ($line.Trim() -eq "" -or $shown -ge 8) { continue }
    Write-Output "  $line"
    $shown++
}
$changedEntry = @(git diff --name-only $before HEAD -- @EntryFiles 2>$null)
if ($changedEntry.Count -gt 0) {
    Write-Output "  진입 규칙이 바뀌었다 ($($changedEntry -join ' ')). 이 세션은 옛 규칙으로 시작했을 수 있다 — 다시 읽는다."
}
Write-Output "  되돌리기: git reset --keep $before"
