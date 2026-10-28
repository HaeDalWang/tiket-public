#!/usr/bin/env python3
"""고객 AWS 조회 스킬을 $HOME 사본에서 이 워크스페이스로 옮긴다 — 세션 시작 때 local_capabilities 가 부른다.

옛 설치기는 스킬을 ~/.claude·~/.kiro·~/.agents·~/.hermes 의 skills/ 에 복사하고, ~/.aws/config 의
csg-* 프로필이 그 사본의 스크립트를 부르게 했다. 이제 스킬은 저장소에 있다 (0040). 그래서 이미 설치된 PC 만
  1. ~/.aws/config 를 백업하고 csg-* 의 credential_process 에서 옛 사본 경로를 이 워크스페이스 경로로 바꾼다.
  2. 아무 프로필도 가리키지 않게 된 사본을 ~/.config/msp/skill-home-copies-<시각>/ 으로 옮긴다.
     Claude Code 는 이름이 같으면 개인 사본을 먼저 읽는다 — 옛 SKILL.md 의 경로 신뢰 규칙은 워크스페이스를
     몰라 조회가 멈춘다. 그래서 둘을 같은 때에 한다.
csg- 밖의 프로필은 바꾸지 않는다. 그런 프로필이 가리키는 사본은 남기고 매번 알린다 (2026-10-20 유지보수자).
메인 체크아웃에서만 돈다 — 워크트리나 평가 사본을 가리키면 그 폴더를 지울 때 조회가 깨진다.
여러 번 돌려도 같고, 네트워크에 닿지 않는다. 바꾼 날만 한 줄과 되돌리는 명령이 나온다.
"""

from __future__ import annotations

import os
import re
import shlex
import shutil
from datetime import datetime
from pathlib import Path
from typing import Mapping

SKILL = "aws-customer-account-ops"
HOSTS = (".claude", ".kiro", ".agents", ".hermes")
MARKER_PROFILE = "csg-login"
OUR_PREFIX = "csg-"
WORKSPACE_MARKERS = ("get-sts-token.sh", "get-sts-token.ps1")
PROFILE_HEADER = re.compile(r"^\[profile\s+(.+?)\]\s*$")
# POSIX credential_process 는 따옴표 없이 쓰여 있다. 이런 글자가 든 경로로 바꾸면 aws 가 명령을 쪼갠다.
UNSAFE_UNQUOTED = re.compile(r"[\s'\"\\]")


def config_path(home: Path, env: Mapping[str, str]) -> Path:
    return Path(env.get("AWS_CONFIG_FILE") or home / ".aws/config")


def copy_pattern(home: Path, host: str, os_name: str) -> re.Pattern[str]:
    """옛 사본 폴더. 구분자는 / \\ 둘 다, Windows 는 대소문자를 가리지 않는다. 뒤에 구분자가 와야 한다."""
    parts = [*re.split(r"[\\/]", str(home)), host, "skills", SKILL]
    body = r"[\\/]".join(re.escape(part) for part in parts)
    return re.compile(body + r"(?=[\\/])", re.IGNORECASE if os_name == "nt" else 0)


def profile_name(line: str) -> str | None:
    match = PROFILE_HEADER.match(line.rstrip("\r\n"))
    return match.group(1).strip().strip("'\"") if match else None


def is_credential_process(line: str) -> bool:
    key, sep, _ = line.partition("=")
    return bool(sep) and key.strip().lower() == "credential_process"


def rewrite(text: str, patterns: dict[str, re.Pattern[str]], new: str
            ) -> tuple[str, int, bool, dict[str, list[str]]]:
    """(새 내용, 바꾼 csg 줄 수, 마커가 있는가, 사본별 csg 밖 프로필)."""
    lines = text.splitlines(keepends=True)
    name: str | None = None
    changed, has_marker = 0, False
    pinned: dict[str, list[str]] = {}
    for index, line in enumerate(lines):
        if line.startswith("["):
            name = profile_name(line)
            continue
        if name is None or not is_credential_process(line):
            continue
        has_marker = has_marker or name == MARKER_PROFILE
        for host, pattern in patterns.items():
            if not pattern.search(line):
                continue
            if name.startswith(OUR_PREFIX):
                lines[index] = line = pattern.sub(lambda _: new, line)
                changed += 1
            else:
                pinned.setdefault(host, []).append(name)
    return "".join(lines), changed, has_marker, pinned


def quote(path: Path, os_name: str) -> str:
    return "'" + str(path).replace("'", "''") + "'" if os_name == "nt" else shlex.quote(str(path))


def undo_line(config: Path, backup: Path | None, moved: list[tuple[Path, Path]], os_name: str) -> str:
    steps = []
    if backup:
        copy = "Copy-Item -LiteralPath" if os_name == "nt" else "cp"
        steps.append(f"{copy} {quote(backup, os_name)} {quote(config, os_name)}")
    move = "Move-Item -LiteralPath" if os_name == "nt" else "mv"
    steps += [f"{move} {quote(dest, os_name)} {quote(src, os_name)}" for src, dest in moved]
    return "  되돌리기: " + ("; " if os_name == "nt" else " && ").join(steps)


def migrate(root: Path, home: Path, env: Mapping[str, str], os_name: str = os.name,
            stamp: str | None = None) -> str | None:
    """바꿨거나 남긴 사본이 있으면 알릴 줄, 할 일이 없으면 None."""
    new_dir = root / "skills" / SKILL
    if not (root / ".git").is_dir() or not any((new_dir / m).is_file() for m in WORKSPACE_MARKERS):
        return None
    config = config_path(home, env)
    if not config.is_file():
        return None
    original = config.read_bytes().decode("utf-8")
    patterns = {host: copy_pattern(home, host, os_name) for host in HOSTS}
    updated, changed, has_marker, pinned = rewrite(original, patterns, str(new_dir))
    if not has_marker:
        return None  # 스킬을 설치한 적 없는 PC — 설치는 온보딩이 한다
    if changed and os_name != "nt" and UNSAFE_UNQUOTED.search(str(new_dir)):
        return (f"고객 AWS 조회 스킬을 이 워크스페이스로 옮기지 못했다 — 경로에 공백이나 따옴표가 있다({new_dir}). "
                "공백 없는 폴더에 clone 하면 다음 세션에 옮긴다. 지금은 옛 사본으로 조회한다.")

    stamp = stamp or datetime.now().strftime("%Y%m%d-%H%M%S")
    backup = None
    if changed:
        backup = config.with_name(f"{config.name}.bak.tiket-{stamp}")
        shutil.copy2(config, backup)
        temporary = config.with_name(f"{config.name}.tiket-{stamp}.tmp")
        temporary.write_bytes(updated.encode("utf-8"))
        os.replace(temporary, config)

    kept_root = home / ".config/msp" / f"skill-home-copies-{stamp}"
    moved: list[tuple[Path, Path]] = []
    failure = ""
    for host in HOSTS:
        source = home / host / "skills" / SKILL
        if host in pinned or not (source.exists() or source.is_symlink()):
            continue
        destination = kept_root / host / SKILL
        try:
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.move(str(source), str(destination))
        except OSError as error:
            failure = f"  {source} 을 옮기지 못했다({type(error).__name__}). 손으로 옮기거나 지운다 — 남아 있으면 Claude Code 가 옛 사본을 읽는다."
            break
        moved.append((source, destination))

    lines = []
    if changed or moved:
        hosts = ", ".join(src.parents[1].name for src, _ in moved) or "없음"
        lines.append(f"고객 AWS 조회 스킬을 이 워크스페이스({new_dir})로 옮겼다 — csg 프로필 {changed}줄, "
                     f"옛 사본 {len(moved)}개({hosts}) → {kept_root}. 다음 세션부터 워크스페이스 스킬을 읽는다.")
        lines.append(undo_line(config, backup, moved, os_name))
    if failure:
        lines.append(failure)
    for host, names in pinned.items():
        source = home / host / "skills" / SKILL
        if not source.exists():
            continue  # 사본이 이미 없으면 남긴 것도 없다 — 그 프로필은 본인 몫이다
        lines.append(f"고객 AWS 조회 스킬의 옛 사본 {source} 을 남겨 뒀다 — csg 밖의 프로필({', '.join(names)})이 가리킨다. "
                     "Claude Code 는 이 옛 사본을 먼저 읽어 조회가 멈출 수 있다. 그 프로필을 정리하면 다음 세션에 옮긴다.")
    return "\n".join(lines) or None
