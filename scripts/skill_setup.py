#!/usr/bin/env python3
"""고객 AWS 조회 스킬을 이 PC 에서 쓸 수 있게 맞춘다 — 온보딩 5단계가 부른다 (0040 3단계 조각 C-2).

옛 설치기(support-skills install.sh·ps1)가 하던 일 중 지금도 필요한 셋만 한다. 스킬은 이미 저장소에 있다.
  1. ~/.config/msp/credential-broker.conf 에 API_URL·CLIENT_ID (skills/.../broker-defaults.conf 의 값)
  2. ~/.aws/config 의 [profile csg-login] 마커 — 이 워크스페이스의 get-sts-token 을 가리킨다
  3. BILLING_API_KEY — 환경변수에도 conf 에도 없을 때만 묻고 conf 에 둔다. 셸 프로필은 건드리지 않는다 (0003)
먼저 $HOME 사본을 쓰던 PC 면 세션 시작과 같은 전환(skill_migration)을 돌린다.

    python3 scripts/skill_setup.py            지금 상태만 알린다. 아무것도 바꾸지 않는다
    python3 scripts/skill_setup.py --install  맞춘다. 터미널이면 키를 묻는다

한 줄(바꾼 것이 있으면 여러 줄)을 내고, 쓸 수 있으면 0, 아니면 1 로 끝난다. 키 값은 출력하지 않는다.
"""

from __future__ import annotations

import getpass
import os
import shutil
import sys
import urllib.error
import urllib.request
from datetime import datetime
from pathlib import Path
from typing import Callable, Mapping

import https_fetch
import skill_migration as sm

ROOT = Path(__file__).resolve().parents[1]
KEY_NAME = "BILLING_API_KEY"
REGION = "ap-northeast-2"
# 옛 설치기가 키를 확인하던 주소. 읽기 전용이고 응답 본문은 쓰지 않는다.
KEY_CHECK_URL = "https://billing.example.com/api/v1/billing/timestamps?key=cur_last_update"
KEY_CHECK_TIMEOUT_SECONDS = 10
KEY_ISSUE_HINT = "발급: https://billing.example.com > 계정 설정 > API Token Setting"


def marker_target(value: str) -> str:
    """csg-login 의 credential_process 에서 스크립트 경로만. POSIX 는 경로 그대로, Windows 는 `pwsh -NoProfile -File "<경로>"`."""
    _, sep, tail = value.strip().partition("-File ")
    return (tail if sep else value).strip().strip("\"'")


def marker_value(skill_dir: Path, os_name: str) -> str:
    if os_name == "nt":
        return f'pwsh -NoProfile -File "{skill_dir / "get-sts-token.ps1"}"'
    return str(skill_dir / "get-sts-token.sh")


def read_marker(text: str) -> str | None:
    name = None
    for line in text.splitlines():
        if line.startswith("["):
            name = sm.profile_name(line)
        elif name == sm.MARKER_PROFILE and sm.is_credential_process(line):
            return line.partition("=")[2].strip()
    return None


def with_marker(text: str, value: str) -> str:
    """csg-login 의 credential_process 한 줄만 바꾸거나, 섹션이 없으면 끝에 붙인다. 다른 줄은 그대로."""
    newline = "\r\n" if "\r\n" in text else "\n"
    entry = f"credential_process = {value}"
    lines = text.splitlines(keepends=True)
    name = None
    for index, line in enumerate(lines):
        if line.startswith("["):
            name = sm.profile_name(line)
            if name == sm.MARKER_PROFILE and not any(
                    sm.is_credential_process(rest) for rest in section_body(lines, index)):
                return "".join(lines[:index + 1] + [entry + newline] + lines[index + 1:])
        elif name == sm.MARKER_PROFILE and sm.is_credential_process(line):
            lines[index] = entry + line[len(line.rstrip("\r\n")):]
            return "".join(lines)
    gap = "" if not text else (newline if text.endswith(("\n", "\r")) else newline * 2)
    return f"{text}{gap}[profile {sm.MARKER_PROFILE}]{newline}{entry}{newline}region = {REGION}{newline}"


def section_body(lines: list[str], header: int) -> list[str]:
    body = []
    for line in lines[header + 1:]:
        if line.startswith("["):
            break
        body.append(line)
    return body


def conf_lines(path: Path) -> list[str]:
    try:
        return path.read_text(encoding="utf-8").splitlines()
    except FileNotFoundError:
        return []


def first_value(lines: list[str], key: str) -> str:
    """같은 키는 첫 줄이 이긴다 — 스킬 스크립트의 `grep | head -1` 과 같다."""
    return next((line.partition("=")[2] for line in lines if line.startswith(f"{key}=")), "")


def with_conf(lines: list[str], values: Mapping[str, str]) -> list[str]:
    """키마다 첫 줄을 값으로 바꾸거나 끝에 붙인다. 다른 줄(토큰 캐시 등)은 그대로."""
    result = list(lines)
    for key, value in values.items():
        index = next((i for i, line in enumerate(result) if line.startswith(f"{key}=")), None)
        if index is None:
            result.append(f"{key}={value}")
        else:
            result[index] = f"{key}={value}"
    return result


def write_private(path: Path, text: str) -> None:
    """비밀이 드는 파일 — 처음부터 0600 으로 만들고 통째로 바꾼다."""
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    temporary = path.with_name(f"{path.name}.tiket.tmp")
    descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(descriptor, "w", encoding="utf-8", newline="") as handle:
        handle.write(text)
    os.replace(temporary, path)


def key_works(key: str) -> bool | None:
    """200 이면 True, 401·403 이면 False, 그 밖(네트워크·서버)은 None — 판단하지 못했다."""
    request = urllib.request.Request(KEY_CHECK_URL, headers={"Authorization": f"Bearer {key}"})
    try:
        with https_fetch.urlopen(request, timeout=KEY_CHECK_TIMEOUT_SECONDS) as response:
            return response.status == 200 or None
    except urllib.error.HTTPError as error:
        return False if error.code in (401, 403) else None
    except (urllib.error.URLError, OSError):
        return None


def prompt_key(read_secret: Callable[[str], str], check: Callable[[str], bool | None],
               say: Callable[[str], None]) -> str | None:
    """빈 Enter 는 다시 묻는다 — 건너뛰려면 skip 을 친다 (Zendesk 입력과 같은 규칙)."""
    say(f"  빌링 플랫폼 API 키를 넣는다 ({KEY_ISSUE_HINT}). 입력은 화면에 안 보인다.")
    while True:
        try:
            key = read_secret("  빌링 플랫폼 API 키 (건너뛰려면 skip): ").strip()
        except EOFError:
            return None
        if key == "skip":
            return None
        if not key:
            say("  값이 필요하다. 지금 못 넣으면 skip 을 친다.")
            continue
        if any(character.isspace() for character in key):
            say("  키에 공백이 들어 있다. 다시 넣는다.")
            continue
        verdict = check(key)
        if verdict is False:
            say("  빌링 플랫폼이 이 키를 받지 않았다(401/403) — 맞지 않는다. 다시 넣는다.")
            continue
        if verdict is None:
            say("  빌링 플랫폼에 닿지 못해 키를 확인하지 못했다. 그대로 저장한다.")
        return key


def defaults(skill_dir: Path) -> dict[str, str]:
    lines = conf_lines(skill_dir / "broker-defaults.conf")
    return {line.partition("=")[0]: line.partition("=")[2] for line in lines if "=" in line and not line.startswith("#")}


def setup(root: Path, home: Path, env: Mapping[str, str], *, write: bool, os_name: str = os.name,
          which: Callable[[str], str | None] = shutil.which,
          ask_key: Callable[[], str | None] | None = None, stamp: str | None = None) -> tuple[bool, str]:
    """(쓸 수 있는가, 알릴 말). write=False 면 아무것도 바꾸지 않는다."""
    stamp = stamp or datetime.now().strftime("%Y%m%d-%H%M%S")
    skill_dir = root / "skills" / sm.SKILL
    done: list[str] = []
    gaps: list[str] = []

    if write:
        moved = sm.migrate(root, home, env, os_name=os_name, stamp=stamp)
        if moved:
            done.append(moved)

    conf = home / ".config/msp/credential-broker.conf"
    lines = conf_lines(conf)
    wanted = defaults(skill_dir)
    updated = with_conf(lines, wanted)
    has_key = bool(env.get(KEY_NAME) or first_value(updated, KEY_NAME))
    key = ask_key() if not has_key and write and ask_key else None
    if key:
        updated, has_key = with_conf(updated, {KEY_NAME: key}), True
    if updated != lines:
        if write:
            write_private(conf, "\n".join(updated) + "\n")
            done.append(f"{conf} 를 맞췄다 (브로커 주소{'·빌링 플랫폼 키' if key else ''}).")
        else:
            gaps.append("credential-broker.conf 미설정")
    if not has_key:
        gaps.append("빌링 플랫폼 키 없음")

    config = sm.config_path(home, env)
    text = config.read_bytes().decode("utf-8") if config.is_file() else ""
    current = read_marker(text) or ""
    if not (current and Path(marker_target(current)).is_file()):
        reason = marker_blocker(root, skill_dir, os_name)
        if reason:
            gaps.append(reason)
        elif not write:
            gaps.append("csg-login 마커 없음")
        else:
            if text:
                shutil.copy2(config, config.with_name(f"{config.name}.bak.tiket-{stamp}"))
            config.parent.mkdir(parents=True, exist_ok=True)
            temporary = config.with_name(f"{config.name}.tiket-{stamp}.tmp")
            temporary.write_bytes(with_marker(text, marker_value(skill_dir, os_name)).encode("utf-8"))
            os.replace(temporary, config)
            done.append(f"{config} 의 csg-login 이 이 워크스페이스 스킬을 가리키게 했다."
                        + (f" 백업: {config.name}.bak.tiket-{stamp}" if text else ""))

    if not which("aws"):
        gaps.append("aws CLI 없음 (" + ("winget install Amazon.AWSCLI" if os_name == "nt" else "brew install awscli") + ")")

    if gaps:
        fix = "pwsh -File scripts/onboarding.ps1" if os_name == "nt" else "bash scripts/onboarding.sh"
        return False, "\n".join([*done, f"{'·'.join(gaps)} — 해결: 터미널에서 {fix}"])
    return True, "\n".join([*done, f"쓸 수 있다 — 워크스페이스 스킬 {skill_dir}"])


def marker_blocker(root: Path, skill_dir: Path, os_name: str) -> str | None:
    if not (root / ".git").is_dir():
        return "csg-login 마커는 메인 clone 에서만 쓴다 — 워크트리·사본은 지우면 조회가 깨진다"
    if os_name != "nt" and sm.UNSAFE_UNQUOTED.search(str(skill_dir)):
        return f"워크스페이스 경로에 공백이나 따옴표가 있다({root}) — 공백 없는 폴더에 clone 한다"
    return None


def main(argv: list[str]) -> int:
    write = "--install" in argv
    interactive = write and sys.stdin.isatty()
    ask = (lambda: prompt_key(getpass.getpass, key_works, lambda line: print(line, file=sys.stderr))) if interactive else None
    ready, message = setup(ROOT, Path.home(), os.environ, write=write, ask_key=ask)
    print(message)
    return 0 if ready else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
