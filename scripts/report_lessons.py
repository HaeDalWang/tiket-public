#!/usr/bin/env python3
"""티켓 기록의 `## 교훈 후보` 를 팀 후보 테이블로 보낸다 (development/decisions/0026).

**`report_usage.py` 와 정책이 반대다.** 그쪽은 숫자만 보내고 고객 식별자를 막는다.
여기는 고객 맥락을 보낸다 — 티켓 번호, 빌링 플랫폼 corpId, 한 줄 교훈, 그리고 승인자가
판단할 수 있도록 `## 물어본 것`·`## 확인한 것` 발췌. MSP 회사 인터널 계정에 두고
원문은 90일 뒤 지워진다. 승인된 것만 팀 자산이 된다.

그래서 파일을 나눴다. `report_usage.py` 의 "고객 내용은 보내지 않는다" 는 그대로 사실이다.

보내지 않는 것:
  - `- 없음`, 그리고 `## 교훈 후보` 가 없는 옛 기록 (소급 전송하지 않는다)
  - 평가 기록 — 제목에 `합성고객`, 또는 헤더에 `평가:` (평가 케이스가 전부 합성고객을 준다)
  - 형식이 틀린 섹션 — check_ticket_record.py 가 FAIL 을 내는 것을 추측해서 보내지 않는다
  - 비밀값 패턴에 걸리는 후보 — 수집기도 막지만 애초에 장비를 떠나지 않는다

동의: 알리고 기본 켜짐이다 (0026 B안). 2026-09-29 부터 conf 가 없어도 켜져 있다 — 이름은
conf 의 TIKET_ENGINEER, 없으면 git user.name.
끄기: conf 에 `TIKET_LESSONS=off`. `TIKET_TELEMETRY=off` 도 이것을 끈다.

사용:
  python3 scripts/report_lessons.py          보낼 후보를 출력만 한다
  python3 scripts/report_lessons.py --send   실제 전송
세션 시작 훅은 `report_usage.py --if-due` 가 이 파일의 send_quietly 를 함께 부른다.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
import urllib.error
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(Path(__file__).resolve().parent))

from check_ticket_record import (  # noqa: E402
    LESSONS_HEADING, corp_id_of, is_evaluation, lesson_problems, parse_lessons, section_body,
    strip_comments,
)
from report_usage import conf_value, engineer_name, run  # noqa: E402
import https_fetch  # noqa: E402

DEFAULT_LESSONS_URL = "https://usage.example.com/candidates"
SCHEMA_VERSION = 1
TIMEOUT_SECONDS = 10
# 수집기 lambda/candidates.py 와 같은 상한이다. 바뀌면 양쪽을 같이 고친다.
MAX_CANDIDATES = 50
MAX_EVIDENCE = 4000
MAX_SOURCE = 500
MAX_LOCATION = 200
EVIDENCE_SECTIONS = ("## 물어본 것", "## 확인한 것")

# 수집기 lambda/candidates.py 의 SECRETS 와 같은 표다. **복제인 것을 알고 한다** —
# 수집기가 이 코드를 import 할 수 없다. test_report_lessons.py 가 이름을 대조한다.
SECRETS = {
    "aws_access_key_id": re.compile(r"\b(?:AKIA|ASIA)[0-9A-Z]{16}\b"),
    "private_key": re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY-----"),
    "aws_secret_assignment": re.compile(r"(?i)aws_secret_access_key\s*[=:]"),
    "aws_session_token_assignment": re.compile(r"(?i)aws_session_token\s*[=:]"),
    "slack_token": re.compile(r"\bxox[abprs]-[0-9A-Za-z-]{10,}"),
    "github_token": re.compile(r"\bgh[pousr]_[0-9A-Za-z]{30,}"),
    "bearer_token": re.compile(r"(?i)\bbearer\s+[A-Za-z0-9._~+/=-]{20,}"),
    "password_assignment": re.compile(r"(?i)\b(?:password|passwd|pwd)\s*[=:]\s*\S{6,}"),
}


def setting(name: str) -> str:
    """환경변수 → conf. 기본값은 URL 하나뿐이고 호출자가 붙인다."""
    return os.environ.get(name, "").strip() or conf_value(name)


def lessons_url() -> str:
    return setting("TIKET_LESSONS_URL") or DEFAULT_LESSONS_URL


def evidence_for(text: str, pointer: str) -> str:
    parts = [f"근거: {pointer}"] if pointer else []
    for heading in EVIDENCE_SECTIONS:
        body = section_body(text, heading)
        if body is not None:
            parts.append(f"{heading}\n{strip_comments(body).strip()}")
    return "\n\n".join(parts)[:MAX_EVIDENCE]


def to_candidate(item: dict[str, str], ticket_ref: str, corp_id: str | None, text: str) -> dict:
    base = {"ticket_ref": ticket_ref, "corp_id": corp_id}
    if "재관측" in item:
        return {**base, "kind": "reobserved", "target": item["재관측"].strip("` ")}
    extra = {}
    if item["종류"] == "miss":
        extra["rule"] = item["막을 규칙"].strip("` ")
    elif item.get("제안 위치", "").strip():
        extra["proposed_location"] = item["제안 위치"].strip()[:MAX_LOCATION]
    return {
        **base,
        "kind": item["종류"],
        "trigger": sorted(set(re.findall(r"T[1-4]", item["트리거"]))),
        "summary": item["한 줄"],
        "evidence": evidence_for(text, item.get("근거", "")),
        **provenance(item),
        **extra,
    }


def provenance(item: dict[str, str]) -> dict[str, str]:
    """pitfall 의 `출처:`·`관측일:`. 없거나 날짜 꼴이 아니면 빼고 보낸다 — 검사기가 경고한다."""
    found = {"source": item.get("출처", "").strip()[:MAX_SOURCE]}
    if re.fullmatch(r"\d{4}-\d{2}-\d{2}", item.get("관측일", "").strip()):
        found["observed_on"] = item["관측일"].strip()
    return {key: value for key, value in found.items() if value}


def has_secret(candidate: dict) -> bool:
    blob = json.dumps(candidate, ensure_ascii=False)
    return any(pattern.search(blob) for pattern in SECRETS.values())


def candidates_in(path: Path, root: Path = ROOT) -> list[dict]:
    text = path.read_text(encoding="utf-8", errors="ignore")
    if is_evaluation(text):
        return []
    section = section_body(text, LESSONS_HEADING)
    if section is None:
        return []
    items = parse_lessons(section)
    if lesson_problems(items, root):
        return []
    corp_id = corp_id_of(text)
    found = [to_candidate(item, path.stem, corp_id, text) for item in items if "none" not in item]
    return [candidate for candidate in found if not has_secret(candidate)]


def collect_candidates(root: Path = ROOT) -> list[dict]:
    paths = sorted((root / "tickets").glob("*.md"))
    return [candidate for path in paths for candidate in candidates_in(path, root)]


def batches(items: list[dict]) -> list[list[dict]]:
    return [items[i : i + MAX_CANDIDATES] for i in range(0, len(items), MAX_CANDIDATES)]


def build_payload(candidates: list[dict], engineer: str) -> dict:
    return {
        "schema_version": SCHEMA_VERSION,
        "sent_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "engineer": engineer,
        "head": run("git", "rev-parse", "--short", "HEAD"),
        "candidates": candidates,
    }


def post(url: str, payload: dict, timeout: int) -> dict:
    request = urllib.request.Request(
        url,
        data=json.dumps(payload, ensure_ascii=False).encode("utf-8"),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with https_fetch.urlopen(request, timeout=timeout) as response:
        return json.loads(response.read().decode("utf-8") or "{}")


def consented() -> str:
    """보내도 되면 엔지니어 이름, 꺼져 있으면 빈 문자열. **기본 켜짐**이다 (2026-09-29) —
    온보딩이 고지하고, 끄는 것만 본인이 conf 에 적는다. 이름은 사용 지표와 같은 규칙."""
    if "off" in (setting("TIKET_LESSONS").lower(), setting("TIKET_TELEMETRY").lower()):
        return ""
    return engineer_name()


def send_quietly(root: Path = ROOT, timeout: int = 10) -> str:
    """세션 시작 훅용. **아무것도 출력하지 않고, 무엇이 실패해도 예외를 내지 않는다.**

    어떻게 끝났는지만 돌려준다 — `off` · `none` · `sent <건수>` · `failed:<예외 종류>[ <HTTP 상태>]`.
    예전에는 그것도 없어서 실패가 어디에도 안 남았다(2026-10-07 검토). 예외 문구는 싣지 않는다 — 후보 내용이 섞일 수 있다."""
    try:
        trace = os.environ.get("TIKET_LESSONS_TRACE")  # 훅 연결을 확인하는 테스트 전용
        if trace:
            Path(trace).touch()
        engineer, url = consented(), lessons_url()
        if not engineer or not url:
            return "off"
        candidates = collect_candidates(root)
        for batch in batches(candidates):
            post(url, build_payload(batch, engineer), timeout)
        return f"sent {len(candidates)}" if candidates else "none"
    except Exception as exc:  # noqa: BLE001 — 세션 시작을 어떤 이유로도 막지 않는다
        code = f" {exc.code}" if isinstance(exc, urllib.error.HTTPError) else ""
        return f"failed:{type(exc).__name__}{code}"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--send", action="store_true", help="실제로 전송한다")
    args = parser.parse_args()

    candidates = collect_candidates()
    for item in candidates:
        label = item.get("summary") or item.get("target")
        print(f"{item['ticket_ref']:<24} {item['kind']:<10} {label}")
    print(f"\n보낼 후보 {len(candidates)}건")
    if not args.send:
        print("(출력만 했다. 전송하려면 --send)")
        return 0
    engineer = consented()
    if not engineer:
        print("보내지 않았다 — TIKET_ENGINEER 가 없거나 TIKET_LESSONS/TIKET_TELEMETRY 가 off 다.", file=sys.stderr)
        return 1
    try:
        for batch in batches(candidates):
            result = post(lessons_url(), build_payload(batch, engineer), TIMEOUT_SECONDS)
            print(f"저장 {result.get('stored', 0)} · 중복 {result.get('duplicate', 0)} · "
                  f"거절 {len(result.get('rejected', []))}")
    except (urllib.error.URLError, OSError, ValueError) as exc:
        print(f"전송 실패 — 작업에는 영향 없다: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
