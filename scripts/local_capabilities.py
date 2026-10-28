#!/usr/bin/env python3
"""이 PC 에서 아직 안 되는 기능을 한 줄로 알린다 — 세션 시작 때 check-freshness 가 부른다.

온보딩 결과는 파일로 남기지 않는다. 나중에 설치하면 그 순간 낡기 때문이다. 대신 매번
파일만 보고 가린다 — 네트워크에 닿지 않고, 자격증명 값은 있는지만 보고 내보내지 않는다.
온보딩 뒤에 생긴 PC 쪽 설정(Kiro 권한 규칙)도 여기서 알린다. 규칙을 아직 안 넣은 PC 에는 손대지 않고(설치는 온보딩이 한다),
이미 우리 블록이 든 PC 만 지금 규칙으로 다시 맞춘다 — 바꾼 날만 한 줄이 나온다 (development/decisions/0030, 2026-10-04 하드닝 계획 2번).
고객 AWS 조회 스킬을 $HOME 사본에서 이 워크스페이스로 옮기는 것도 같은 방식이다 (skill_migration.py, 0040).
`agents/runtime-status.md` 는 팀 공통 상태다. 이 PC 에 깔렸는지는 여기가 답한다.

    python3 scripts/local_capabilities.py               한 줄 (다 되면 다 된다고)
    python3 scripts/local_capabilities.py --if-missing  빠진 게 있을 때만 (세션 훅)
"""

from __future__ import annotations

import configparser
import os
import shutil
import sys
from pathlib import Path
from typing import Callable, Mapping

import customer_notes
import kiro_permissions
import skill_migration
import skill_setup

# 온보딩의 '제한' 줄과 같은 이름이다 (test_onboarding_parity.py 가 맞춘다).
TICKET_FETCH = "티켓 번호로 가져오기"
CUSTOMER_LOOKUP = "고객 AWS·비용 조회"
# 없으면 customer_notes.py 가 멈추고 그 고객의 계정 조회도 멈춘다 (development/decisions/0034).
CUSTOMER_NOTES = "고객 특이사항 읽기"
# Kiro 를 쓰는 사람에게만 나온다. 온보딩은 한 번뿐이라 그 뒤에 생긴 설정은 여기서 알린다.
KIRO_PROMPTS = "Kiro 승인 창 줄이기"

# fetch-ticket 과 같은 순서: 우리 환경변수 → 외부 스킬 호환 이름 → conf 파일.
ZENDESK_KEYS = (
    ("ZENDESK_SUBDOMAIN", "Zendesk_SUBDOMAIN"),
    ("ZENDESK_EMAIL", "Zendesk_EMAIL"),
    ("ZENDESK_API_TOKEN", "Zendesk_API"),
)
# fetch-ticket.sh 만 쓴다. Windows 판은 Invoke-RestMethod 라 필요 없다.
POSIX_FETCH_TOOLS = ("curl", "jq")


def conf_values(path: Path) -> dict[str, str]:
    """`KEY=값` 줄. 같은 키는 첫 줄이 이긴다 — fetch-ticket 의 `grep | head -1` 과 같다."""
    try:
        text = path.read_text(encoding="utf-8-sig")
    except (OSError, UnicodeDecodeError):
        return {}
    values: dict[str, str] = {}
    for line in text.splitlines():
        key, sep, value = line.partition("=")
        if sep and key not in values:
            values[key] = value
    return values


def zendesk_ready(home: Path, env: Mapping[str, str]) -> bool:
    conf = conf_values(home / ".config/msp/zendesk.conf")
    return all(env.get(ours) or env.get(theirs) or conf.get(ours) for ours, theirs in ZENDESK_KEYS)


def skill_installed(home: Path, env: Mapping[str, str]) -> bool:
    """온보딩 5단계와 같은 판단: csg-login 의 credential_process 가 실제 파일을 가리킨다."""
    config = Path(env.get("AWS_CONFIG_FILE") or home / ".aws/config")
    parser = configparser.RawConfigParser(strict=False)
    try:
        parser.read(config, encoding="utf-8")
    except (configparser.Error, UnicodeDecodeError):
        return False
    marker = skill_setup.marker_target(parser.get("profile csg-login", "credential_process", fallback=""))
    return bool(marker) and Path(marker).is_file()


def kiro_rules_missing(home: Path, root: Path, os_name: str) -> bool:
    """알리기만 한다. 세션 훅은 저장소가 싣고 온 명령이라 여기서 권한 규칙을 쓰지 않는다 (0030).
    넣을 폴더를 모르는 PC 는 온보딩으로도 못 고치므로 말하지 않는다."""
    if not (home / ".kiro").is_dir():
        return False
    try:
        return (kiro_permissions.workspace_dir(root, home, os_name) is not None
                and kiro_permissions.status(root, home, os_name)[0] != 0)
    except (OSError, UnicodeDecodeError):
        return False


def missing(home: Path, env: Mapping[str, str], os_name: str = os.name,
            which: Callable[[str], str | None] = shutil.which,
            root: Path = kiro_permissions.ROOT) -> dict[str, list[str]]:
    gaps: dict[str, list[str]] = {}
    if not zendesk_ready(home, env):
        gaps.setdefault(TICKET_FETCH, []).append("Zendesk 미설정")
    if os_name != "nt":
        gaps.setdefault(TICKET_FETCH, []).extend(f"{tool} 없음" for tool in POSIX_FETCH_TOOLS if not which(tool))
    if not skill_installed(home, env):
        gaps.setdefault(CUSTOMER_LOOKUP, []).append("스킬 미설치")
    if not customer_notes.token_from(home / ".config/msp/itsm", "ITSM_API_TOKEN"):
        gaps.setdefault(CUSTOMER_NOTES, []).append("ITSM 토큰 없음")
    if kiro_rules_missing(home, root, os_name):
        gaps.setdefault(KIRO_PROMPTS, []).append("권한 규칙 미설치")
    return {feature: reasons for feature, reasons in gaps.items() if reasons}


def render(gaps: dict[str, list[str]], os_name: str = os.name) -> str:
    if not gaps:
        return f"이 PC 에서 다 된다: {TICKET_FETCH}, {CUSTOMER_LOOKUP}, {CUSTOMER_NOTES}."
    fix = "pwsh -File scripts/onboarding.ps1" if os_name == "nt" else "bash scripts/onboarding.sh"
    items = ", ".join(f"{feature}({'·'.join(reasons)})" for feature, reasons in gaps.items())
    return f"이 PC 에서 아직 안 되는 것: {items}. 나머지는 쓸 수 있다. 설정: {fix}"


def main(argv: list[str]) -> int:
    home = Path.home()
    # 이미 우리 블록이 든 PC 만 지금 규칙으로 맞춘다(새로 넣지는 않는다 — 설치는 온보딩이 한다, 0030).
    # 바꾼 날만 한 줄이 나오고 평소에는 조용하다. 어떤 예외도 던지지 않는다.
    refreshed = kiro_permissions.refresh_if_installed(kiro_permissions.ROOT, home)
    if refreshed:
        print(refreshed)
    # 고객 AWS 조회 스킬을 $HOME 사본에서 이 워크스페이스로 — 이미 설치된 PC 만, 바꾼 날만 한 줄 (0040).
    # 설치됨 판단보다 먼저 한다. 옮긴 뒤의 마커로 판단해야 한다.
    try:
        moved = skill_migration.migrate(kiro_permissions.ROOT, home, os.environ)
    except Exception as error:  # noqa: BLE001 — 세션 시작을 어떤 이유로도 막지 않는다
        moved = (f"고객 AWS 조회 스킬을 워크스페이스로 옮기다 멈췄다({type(error).__name__}). "
                 "옛 사본으로 계속 조회한다. 유지보수자에게 이 줄을 전한다.")
    if moved:
        print(moved)
    gaps = missing(home, os.environ)
    if gaps or "--if-missing" not in argv:
        print(render(gaps))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
