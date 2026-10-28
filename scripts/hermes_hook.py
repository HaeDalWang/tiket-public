#!/usr/bin/env python3
"""Hermes 세션 시작 훅 — 다른 호스트의 세션 훅과 같은 일을 Hermes 에서 한다.

Hermes 는 저장소 안의 훅 설정을 읽지 않는다. shell hook 은 사용자 프로필
`~/.hermes/config.yaml` 의 `hooks:` 에만 등록된다(Hermes 문서 "Shell Hooks",
v0.20.5 `agent/shell_hooks.py` 로 확인). 그래서 온보딩이 이 파일을 거기에 등록한다.

    python3 scripts/hermes_hook.py              훅 본체. Hermes 가 stdin 으로 JSON 을 준다
    python3 scripts/hermes_hook.py --install    ~/.hermes/config.yaml 에 등록 (백업 먼저)
    python3 scripts/hermes_hook.py --status     등록·승인 상태만 본다. 아무것도 바꾸지 않는다

훅은 모든 Hermes 세션에서 발동한다. 세션 위치(`cwd`)가 이 저장소 안일 때만 업데이트
(check-freshness)와 지표 전송(report_usage --if-due)을 이 순서로 한다. 첫 발동 때 Hermes 가
명령마다 한 번 승인을 묻는다 — Hermes 쪽 안전장치라 건너뛰지 않는다.

stdout 은 Hermes 가 JSON 으로 읽는다. 언제나 `{}` 만 내고, 무엇이 실패해도 0 으로 끝난다.
"""

from __future__ import annotations

import json
import os
import shlex
import shutil
import subprocess
import sys
from datetime import datetime
from pathlib import Path
from typing import Callable

REPO = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(Path(__file__).resolve().parent))

import session_start  # noqa: E402 — 순서(업데이트 → 전송)는 한 곳에서 정한다

EVENT = "on_session_start"
# Hermes 기본 60초, 최대 300초. 업데이트(git fetch)와 전송 두 번(각 10초)이 들어간다.
HOOK_TIMEOUT_SECONDS = 60
STEP_TIMEOUT_SECONDS = 25
BACKUP_PREFIX = "config.yaml.bak.tiket-"


def hook_command(repo: Path = REPO) -> str:
    """Hermes 는 command 를 shlex.split 한다. 공백·한국어 경로에서도 인자 하나가 되게 감싼다."""
    return shlex.quote(str(repo / "scripts/hermes_hook.py"))


def default_call(argv: list[str], cwd: Path) -> None:
    # stdout 은 Hermes 가 JSON 으로 읽는다 — 업데이트 알림도 버린다.
    subprocess.run(argv, cwd=cwd, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                   stderr=subprocess.DEVNULL, timeout=STEP_TIMEOUT_SECONDS, check=False)


def is_inside(cwd: str, repo: Path) -> bool:
    try:
        Path(cwd).resolve().relative_to(repo.resolve())
        return True
    except (ValueError, OSError):
        return False


def run_hook(stdin_text: str, repo: Path = REPO, os_name: str = os.name,
             call: Callable[[list[str], Path], None] = default_call) -> str:
    try:
        payload = json.loads(stdin_text) if stdin_text.strip() else {}
    except ValueError:
        payload = {}
    cwd = payload.get("cwd") if isinstance(payload, dict) else None
    if isinstance(cwd, str) and is_inside(cwd, repo):
        session_start.run(repo, os_name, call)
    return "{}"


def hook_block(command: str) -> str:
    # JSON 문자열은 그대로 YAML 큰따옴표 문자열이다 — 경로에 무엇이 있어도 이스케이프가 맞다.
    return (
        "hooks:\n"
        f"  {EVENT}:\n"
        f"    # tiket 워크스페이스 — 업데이트 뒤 사용 지표 전송. scripts/hermes_hook.py\n"
        f"    - command: {json.dumps(command, ensure_ascii=False)}\n"
        f"      timeout: {HOOK_TIMEOUT_SECONDS}\n"
    )


def top_level_hooks(lines: list[str]) -> tuple[int, bool] | None:
    """최상위 `hooks:` 줄의 위치와, 비어 있는지. 없으면 None."""
    for index, line in enumerate(lines):
        if not line.startswith("hooks:"):
            continue
        value = line[len("hooks:"):].split("#", 1)[0].strip()
        if value in ("{}", "null", "~"):
            return index, True
        if value:
            return index, False
        following = next((l for l in lines[index + 1:] if l.strip() and not l.lstrip().startswith("#")), "")
        return index, not following.startswith((" ", "\t", "-"))
    return None


def install(hermes_home: Path, command: str, stamp: str | None = None) -> tuple[int, str]:
    """0 등록됨(또는 이미 있음) · 2 손으로 넣어야 함. 바꾸기 전에 백업한다."""
    config = hermes_home / "config.yaml"
    text = config.read_text(encoding="utf-8") if config.exists() else ""
    if json.dumps(command, ensure_ascii=False) in text or f"command: {command}" in text:
        return 0, f"이미 등록됨: {config}"

    lines = text.splitlines(keepends=True)
    found = top_level_hooks(lines)
    block = hook_block(command)
    if found is None:
        new_text = text + ("" if not text or text.endswith("\n") else "\n") + block
    elif found[1]:
        index = found[0]
        new_text = "".join(lines[:index]) + block + "".join(lines[index + 1:])
    else:
        return 2, (f"{config} 에 이미 다른 hooks 가 있어 자동으로 합치지 않았다. "
                   f"hooks: 아래에 직접 넣는다:\n{block}")

    backup = None
    if config.exists():
        backup = hermes_home / f"{BACKUP_PREFIX}{stamp or datetime.now().strftime('%Y%m%d-%H%M%S')}"
        shutil.copy2(config, backup)
    hermes_home.mkdir(parents=True, exist_ok=True)
    config.write_text(new_text, encoding="utf-8")
    undo = f"되돌리기: cp '{backup}' '{config}'" if backup else f"되돌리기: rm '{config}'"
    return 0, f"등록함: {config}\n{undo}"


def default_run(argv: list[str], env: dict[str, str]) -> tuple[int, str]:
    result = subprocess.run(argv, env=env, stdin=subprocess.DEVNULL, capture_output=True, text=True,
                            timeout=STEP_TIMEOUT_SECONDS, check=False)
    return result.returncode, result.stdout + result.stderr


def trust_skills(hermes_home: Path, repo: Path = REPO, hermes: str | None = None,
                 run: Callable[[list[str], dict[str, str]], tuple[int, str]] = default_run,
                 stamp: str | None = None) -> tuple[int, str]:
    """0 신뢰됨(또는 이미) · 2 손으로 해야 함.

    Hermes 는 skills.trusted_project_dirs 에 든 저장소의 .agents/skills 만 읽는다 — 경로 하나씩이라
    워크트리는 따로 신뢰해야 한다(v0.20.5 agent/skill_utils.py). 형식은 문서에 없어 Hermes 명령에 맡긴다.
    그 명령은 config.yaml 을 통째로 다시 쓰므로 먼저 백업한다.
    """
    quoted = shlex.quote(str(repo))
    if hermes is None:
        return 2, f"hermes 명령을 찾지 못해 스킬 신뢰를 못 했다. 직접: hermes skills trust {quoted}"
    config = hermes_home / "config.yaml"
    backup = None
    if config.exists():
        backup = hermes_home / f"{BACKUP_PREFIX}{stamp or datetime.now().strftime('%Y%m%d-%H%M%S')}-skills"
        shutil.copy2(config, backup)
    code, output = run([hermes, "skills", "trust", str(repo)], {**os.environ, "HERMES_HOME": str(hermes_home)})
    if code != 0:
        kept = f" 백업: {backup}" if backup else ""
        return 2, f"스킬 신뢰 실패 — 직접: hermes skills trust {quoted}.{kept}\n{output.strip()}"
    if output.startswith("Already trusted") and backup:
        backup.unlink()
        return 0, f"스킬: 이미 신뢰함 ({repo})"
    return 0, f"스킬: 이 워크스페이스를 신뢰함 — 되돌리기: hermes skills untrust {quoted}"


def status(hermes_home: Path, command: str) -> str:
    """missing · unapproved · approved"""
    config = hermes_home / "config.yaml"
    text = config.read_text(encoding="utf-8") if config.exists() else ""
    if json.dumps(command, ensure_ascii=False) not in text and f"command: {command}" not in text:
        return "missing"
    try:
        approvals = json.loads((hermes_home / "shell-hooks-allowlist.json").read_text(encoding="utf-8"))
        approved = any(a.get("event") == EVENT and a.get("command") == command
                       for a in approvals.get("approvals", []))
    except (OSError, ValueError, AttributeError):
        approved = False
    return "approved" if approved else "unapproved"


def hermes_home() -> Path:
    return Path(os.environ.get("HERMES_HOME") or Path.home() / ".hermes")


STATUS_MESSAGES = {
    "missing": "미등록 — 설치: python3 scripts/hermes_hook.py --install",
    "unapproved": "등록됨, 승인 전 — 다음 hermes 세션에서 한 번 묻는다. 승인하면 된다",
    "approved": "등록·승인됨",
}


def main(argv: list[str]) -> int:
    if "--install" in argv:
        code, message = install(hermes_home(), hook_command())
        print(message)
        if code == 0:
            print("다음 hermes 세션에서 이 명령을 한 번 승인하라고 묻는다. 승인하면 된다.")
        trust_code, trust_message = trust_skills(hermes_home(), hermes=shutil.which("hermes"))
        print(trust_message)
        return code or trust_code
    if "--status" in argv:
        state = status(hermes_home(), hook_command())
        print(STATUS_MESSAGES[state])
        return 0 if state == "approved" else 1
    stdin_text = "" if sys.stdin is None or sys.stdin.isatty() else sys.stdin.read()
    print(run_hook(stdin_text))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
