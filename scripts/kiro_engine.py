#!/usr/bin/env python3
"""Kiro CLI 기본 엔진을 v3 로 — 저장소 훅(.kiro/hooks)은 v3 에서만 돈다.

Kiro CLI 2.x 의 기본 v2 엔진은 `.kiro/hooks` 를 읽지 않는다(2.25.0 바이너리에 경로 없음,
kiro.dev/docs/hooks "CLI 3.0"). 동료 대부분이 v3 를 받아 놓고 `--v3` 를 안 붙여 v2 로 쓰고
있었다 — `chat.agentEngine` 이 비어 있다. 그러면 자동 업데이트도 세션 지표도 없다.

    python3 scripts/kiro_engine.py --status      지금 엔진만 알린다. 아무것도 바꾸지 않는다
    python3 scripts/kiro_engine.py --ensure-v3   **비어 있을 때만** v3 로 바꾸고 되돌리는 명령을 알린다

일부러 v1·v2 를 적어 둔 사람은 덮지 않는다. v2 사용자에게 닿는 길은 fetch-ticket 뿐이라
(세션 훅이 안 돈다) fetch-ticket 과 온보딩이 이 파일을 부른다. 무엇이 실패해도 0 으로 끝난다.
"""

from __future__ import annotations

import shutil
import subprocess
import sys
from typing import Callable

KEY = "chat.agentEngine"
TARGET = "v3"
UNDO = f"kiro-cli settings -d {KEY}"
Runner = Callable[[list[str]], tuple[int, str]]


def default_runner(argv: list[str]) -> tuple[int, str]:
    result = subprocess.run(argv, stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=15)
    return result.returncode, result.stdout


def current(kiro: str, runner: Runner = default_runner) -> str | None:
    """값이 없으면 None. `v3 (global)` 처럼 범위가 붙어 나온다 — 첫 단어만 쓴다."""
    code, out = runner([kiro, "settings", KEY])
    words = out.split()
    return words[0].strip('"') if code == 0 and words else None


def ensure_v3(kiro: str | None, runner: Runner = default_runner) -> tuple[bool, str]:
    """(바꿨는가, 알릴 말). kiro-cli 가 없거나 무엇이 실패하면 (False, "")."""
    if not kiro:
        return False, ""
    try:
        value = current(kiro, runner)
        if value == TARGET:
            return False, ""
        if value is not None:
            return False, (f"Kiro CLI 엔진이 {value} 로 정해져 있어 두었다. 이 저장소의 세션 훅(자동 업데이트·"
                           f"사용 지표)은 v3 에서만 돈다. 바꾸려면: kiro-cli settings {KEY} {TARGET}")
        code, _ = runner([kiro, "settings", KEY, TARGET])
        if code != 0:
            return False, ""
        return True, (f"Kiro CLI 기본 엔진을 v3 로 바꿨다 — 이 저장소의 세션 훅은 v3 에서만 돈다. "
                      f"다음 kiro-cli 세션부터 적용된다. 되돌리기: {UNDO}")
    except Exception:  # noqa: BLE001 — 티켓 조회·온보딩을 어떤 이유로도 막지 않는다
        return False, ""


def status(kiro: str | None, runner: Runner = default_runner) -> tuple[int, str]:
    if not kiro:
        return 0, "Kiro CLI 없음"
    try:
        value = current(kiro, runner)
    except Exception:  # noqa: BLE001
        return 1, "Kiro CLI 엔진을 읽지 못했다"
    if value == TARGET:
        return 0, "Kiro CLI 엔진 v3 — 세션 훅이 돈다"
    return 1, (f"Kiro CLI 엔진 {value or 'v2(기본)'} — 세션 훅(자동 업데이트·지표)이 안 돈다. "
               f"바꾸려면: kiro-cli settings {KEY} {TARGET} (온보딩을 --check 없이 돌리면 비어 있을 때 바꾼다)")


def main(argv: list[str]) -> int:
    kiro = shutil.which("kiro-cli")
    if "--ensure-v3" in argv:
        _, message = ensure_v3(kiro)
        if message:
            print(message)
        return 0
    code, message = status(kiro)
    print(message)
    return code


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
