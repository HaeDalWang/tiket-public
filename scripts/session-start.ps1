# session-start.ps1 — 세션 시작 훅의 Windows 판. Codex 의 command_windows 가 부른다.
#
# 다른 호스트의 `bash scripts/check-freshness.sh; python3 scripts/report_usage.py --if-due` 와
# 같은 일을 같은 순서로 한다 — 업데이트가 끝난 뒤 전송하고, 업데이트가 실패해도 전송은 돈다.
# 어떤 실패도 세션을 막지 않는다 (scripts/render_agent_configs.py SESSION_HOOK_COMMAND_WINDOWS).

$ErrorActionPreference = 'SilentlyContinue'

try { & pwsh -NoProfile -File (Join-Path $PSScriptRoot 'check-freshness.ps1') } catch { }

$py = (Get-Command python3 -ErrorAction SilentlyContinue) ?? (Get-Command python -ErrorAction SilentlyContinue)
if ($py) {
    try { & $py.Source (Join-Path $PSScriptRoot 'report_usage.py') --if-due } catch { }
}
exit 0
