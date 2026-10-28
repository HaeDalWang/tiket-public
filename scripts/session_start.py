#!/usr/bin/env python3
"""세션 시작 훅 본체 — 업데이트(check-freshness) 뒤 사용 지표 전송(report_usage --if-due).

Claude Code·Codex 는 `bash scripts/check-freshness.sh; python3 scripts/report_usage.py --if-due`
를 그대로 쓴다. 이 파일은 셸에 기대지 않아야 하는 곳이 부른다.

  - Kiro: IDE 가 Node `spawn(command, {shell: true})` 로 돌린다 — Unix `/bin/sh`, Windows 는
    `ComSpec`(cmd.exe). cmd 에서 `;` 는 구분자가 아니라서 Windows 에서 매번 깨졌다
    (Kiro IDE 1.1.14 번들, nodejs.org child_process, 2026-09-29). 그래서 Kiro 훅은
    `python3 scripts/session_start.py || python scripts/session_start.py` 다 — `||` 는 두 셸에서 같다.
  - Hermes: scripts/hermes_hook.py 가 같은 순서를 여기서 가져간다.

업데이트 알림은 stdout 으로 둔다 — 호스트가 그것을 에이전트 맥락에 넣는다. stderr 는 버린다 —
Kiro 는 stdout 이 비면 stderr 를 맥락에 넣는다. 무엇이 실패해도 0 으로 끝난다.
"""

from __future__ import annotations

import os
import subprocess
import sys
from pathlib import Path
from typing import Callable

REPO = Path(__file__).resolve().parents[1]
STEP_TIMEOUT_SECONDS = 50
STDOUT = None  # 물려받는다 — 업데이트 알림이 에이전트에게 간다
STDERR = subprocess.DEVNULL


def session_commands(repo: Path, os_name: str) -> list[list[str]]:
    if os_name == "nt":
        freshness = ["pwsh", "-NoProfile", "-File", str(repo / "scripts/check-freshness.ps1")]
    else:
        freshness = ["bash", str(repo / "scripts/check-freshness.sh")]
    return [freshness, [sys.executable, str(repo / "scripts/report_usage.py"), "--if-due"]]


def default_call(argv: list[str], cwd: Path) -> None:
    subprocess.run(argv, cwd=cwd, stdin=subprocess.DEVNULL, stdout=STDOUT, stderr=STDERR,
                   timeout=STEP_TIMEOUT_SECONDS, check=False)


def run(repo: Path = REPO, os_name: str = os.name,
        call: Callable[[list[str], Path], None] = default_call) -> None:
    # `;` 와 같다 — 업데이트가 실패해도 전송은 돈다.
    for argv in session_commands(repo, os_name):
        try:
            call(argv, repo)
        except Exception:  # noqa: BLE001 — 세션 시작을 어떤 이유로도 막지 않는다
            pass


if __name__ == "__main__":
    run()
    sys.exit(0)
