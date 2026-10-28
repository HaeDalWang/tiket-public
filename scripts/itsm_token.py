#!/usr/bin/env python3
"""엔지니어 본인의 ITSM 개인 토큰을 이 PC 에 둔다 — 온보딩 7단계가 부른다 (development/decisions/0034 개정 1).

`scripts/customer_notes.py` 가 이 토큰으로 고객 특이사항을 읽는다. 없으면 특이사항 없이 진행하고(경고), 등록했는데 못 읽으면 그 고객의 계정 조회를 멈춘다.
토큰은 각자 발급한다 — 하나를 나눠 쓰면 ITSM 감사 로그에 누가 읽고 썼는지 남지 않는다.

`~/.config/msp/itsm` 의 `ITSM_API_TOKEN` 한 줄만 바꾼다. 같은 파일의 다른 키(`DEV_ITSM_API_TOKEN` 등)는 그대로 둔다.
확인은 GET 한 번이다. 쓰기 호출은 없다.

    python3 scripts/itsm_token.py            지금 상태만 알린다. 아무것도 바꾸지 않는다
    python3 scripts/itsm_token.py --install  없으면 묻는다(터미널에서만, 입력은 안 보인다)

한 줄을 내고, 토큰이 있으면 0, 없으면 1 로 끝난다. 토큰 값은 출력하지 않는다.
"""

from __future__ import annotations

import getpass
import os
import sys
from pathlib import Path
from typing import Callable

import customer_notes as cn
from skill_setup import write_private

BASE, KEY = cn.SERVERS[False]
# 로그인한 누구나 부를 수 있는 읽기(`authenticateToken` 만, itsm origin/main backend/routes/users.js). 응답 본문은 안 쓴다.
CHECK_URL = f"{BASE}/api/me/tokens"
PREFIX = "cops_"
ISSUE_HINT = f"발급: {BASE} 오른쪽 위 내 이름 → Profile → API 토큰 → 토큰 발행 (전체 값은 발급할 때 한 번만 보인다)"


def fix_command(os_name: str = os.name) -> str:
    return "pwsh -File scripts/onboarding.ps1" if os_name == "nt" else "bash scripts/onboarding.sh"


def with_token(text: str, token: str) -> str:
    """`KEY=` 과 `export KEY=` 줄을 모두 빼고 끝에 새 줄을 붙인다. 다른 줄은 그대로.
    customer_notes.token_from 은 첫 줄이 이기므로 옛 줄을 남기면 새 토큰이 안 읽힌다."""
    kept = [line for line in text.splitlines()
            if line.strip().removeprefix("export ").partition("=")[0].strip() != KEY]
    return "\n".join([*kept, f"{KEY}={token}"]) + "\n"


def token_works(token: str, call: cn.Fetch = cn.fetch) -> bool | None:
    """200 이면 True, 401·403 이면 False, 그 밖(네트워크·서버)은 None — 판단하지 못했다."""
    try:
        status, _ = call(CHECK_URL, token, cn.TIMEOUT_SECONDS)
    except (OSError, ValueError):
        return None
    if status == 200:
        return True
    return False if status in (401, 403) else None


def prompt_token(read_secret: Callable[[str], str], check: Callable[[str], bool | None],
                 say: Callable[[str], None]) -> str | None:
    """빈 Enter 는 다시 묻는다 — 건너뛰려면 skip 을 친다 (Zendesk 입력과 같은 규칙)."""
    say("  ITSM 개인 토큰을 등록한다. 고객 특이사항(scripts/customer_notes.py)을 읽으려면 필요하고,")
    say("  등록하지 않으면 특이사항 없이 진행한다. 등록한 뒤 못 읽으면 그 고객의 계정 조회를 멈춘다.")
    say("  토큰은 각자 발급한다 — 남의 토큰을 받아 쓰지 않는다. ITSM 감사 로그에 누가 읽었는지 남는다.")
    say(f"  {ISSUE_HINT}")
    while True:
        try:
            token = read_secret(f"  ITSM 토큰 {PREFIX}… (화면에 안 보인다, 건너뛰려면 skip): ").strip()
        except EOFError:
            return None
        if token == "skip":
            return None
        if not token:
            say("    값이 필요하다. 지금 등록할 수 없으면 skip 을 입력한다.")
            continue
        if any(character.isspace() for character in token) or not token.startswith(PREFIX):
            say(f"    {PREFIX} 로 시작하는 개인 API 토큰이 아니다. 다시 넣는다.")
            continue
        verdict = check(token)
        if verdict is False:
            say("    ITSM 이 이 토큰을 받지 않았다(401/403) — 맞지 않거나 폐기됐다. 다시 넣는다.")
            continue
        if verdict is None:
            say("    ITSM 에 닿지 못해 토큰을 확인하지 못했다. 그대로 저장한다.")
        return token


def setup(conf: Path, *, write: bool, ask: Callable[[], str | None] | None,
          os_name: str = os.name) -> tuple[bool, str]:
    """(토큰이 있는가, 알릴 말). write=False 면 아무것도 바꾸지 않는다."""
    if cn.token_from(conf, KEY):
        return True, f"설정됨: {conf} 의 {KEY} (값은 출력하지 않는다)"
    fix = fix_command(os_name)
    if not write:
        return False, f"ITSM 토큰 없음 — 해결: 터미널에서 {fix}"
    if ask is None:
        return False, f"터미널에서 직접 실행해야 토큰을 입력받을 수 있다 — 해결: {fix}"
    try:
        existing = conf.read_text(encoding="utf-8") if conf.exists() else ""
    except (OSError, UnicodeDecodeError) as error:
        return False, f"{conf} 를 읽지 못해 그대로 두었다({type(error).__name__}). 다른 키가 지워지지 않게 직접 고친다"
    token = ask()
    if not token:
        return False, f"토큰 등록을 건너뛰었다. 고객 특이사항을 못 읽는다 — 나중에: {fix}"
    write_private(conf, with_token(existing, token))
    return True, f"저장: {conf} 의 {KEY} (권한 600, 다른 키는 그대로)"


def main(argv: list[str]) -> int:
    write = "--install" in argv
    ask = None
    if write and sys.stdin.isatty():
        ask = lambda: prompt_token(getpass.getpass, token_works, lambda line: print(line, file=sys.stderr))  # noqa: E731
    ready, message = setup(cn.CONF, write=write, ask=ask)
    print(message)
    return 0 if ready else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
