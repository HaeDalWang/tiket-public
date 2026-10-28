#!/usr/bin/env python3
"""고객 한 곳의 특이사항을 ITSM 에서 읽는다 (development/decisions/0034).

빌링 플랫폼 corpId 로 고객을 찾고, 그 고객의 특이사항만 읽는다. 전체 고객을 훑는 길은 없다 —
ITSM 에도 그런 API 가 없다(0031 의 조건).

**못 읽으면 멈춘다.** 토큰이 거절되거나, 고객을 못 찾거나, 서버가 답하지 않거나, 다른 고객 것이
돌아오면 종료 코드 2 로 끝난다. `금지` 항목이 있는지 모르는 채로 고객 계정을 조회하지 않는다.
**토큰을 등록한 적이 없으면 3** 이다 — 멈춤이 아니다. 계정 조회는 빌링 플랫폼 키로 되므로 경고하고 진행한다(0034 개정 2).
읽었는데 항목이 없는 것은 성공이다(종료 코드 0, "특이사항 없음").

읽기만 한다. 쓰기는 여기 없다 — 사람이 "예" 라고 한 항목만 보낸다는 것까지 정했고 아직 만들지 않았다.

토큰: `~/.config/msp/itsm` 의 `ITSM_API_TOKEN` (`--dev` 는 `DEV_ITSM_API_TOKEN`).
값은 출력하지 않는다.

사용:
  python3 scripts/customer_notes.py <corpId>          운영
  python3 scripts/customer_notes.py <corpId> --dev    개발 서버 (운영 반영 전 시험용)
"""

from __future__ import annotations

import argparse
import json
import sys
import urllib.error
import urllib.parse
import urllib.request
from collections import Counter
from pathlib import Path
from typing import Callable

sys.path.insert(0, str(Path(__file__).resolve().parent))
import https_fetch  # noqa: E402

CONF = Path.home() / ".config/msp/itsm"
SERVERS = {
    False: ("https://itsm.example.com", "ITSM_API_TOKEN"),
    True: ("https://dev.itsm.example.com", "DEV_ITSM_API_TOKEN"),
}
TIMEOUT_SECONDS = 15
EXIT_STOP = 2
# 토큰을 등록한 적이 없다(파일이나 키가 없다). 멈춤이 아니다 — 계정 조회는 빌링 플랫폼 키로 되니 경고하고 진행한다.
# 등록했는데 못 읽은 것(401·만료·서버·깨진 파일)은 그대로 멈춤이다 (0034 개정 2).
EXIT_NOT_SET_UP = 3
# 티켓 기록의 등급과 같은 말로 옮긴다. ITSM 은 확인 여부를 안 보내면 추측으로 저장한다.
GRADES = {"confirmed": "확인", "assumed": "추측"}
STOP_ADVICE = "이 고객의 계정 조회를 시작하지 않는다 — 엔지니어에게 알린다."
NOT_SET_UP_ADVICE = ("특이사항 미확인 — ITSM 토큰을 등록하지 않았다 ({conf} 의 {key}). 계정 조회는 진행해도 된다. "
                     "기록에 '특이사항 미확인' 을 남기고 엔지니어에게 온보딩(bash scripts/onboarding.sh)을 안내한다.")

Fetch = Callable[[str, str, int], tuple[int, object]]


class NotesUnavailable(Exception):
    """특이사항을 읽지 못했다. 이유는 사람이 읽는 한 줄이다."""


def token_from(conf: Path, key: str) -> str:
    """`KEY=value` 또는 `export KEY="value"`. 없으면 빈 문자열."""
    try:
        lines = conf.read_text(encoding="utf-8").splitlines()
    except (OSError, UnicodeDecodeError):
        return ""
    for line in lines:
        name, _, value = line.strip().removeprefix("export ").partition("=")
        if name.strip() == key:
            return value.strip().strip("\"'")
    return ""


def fetch(url: str, token: str, timeout: int) -> tuple[int, object]:
    """네트워크에 닿는 유일한 곳이다. HTTP 오류는 상태 코드로 돌려주고, 그 밖은 예외로 둔다."""
    request = urllib.request.Request(url, headers={"Authorization": f"Bearer {token}"})
    try:
        with https_fetch.urlopen(request, timeout=timeout) as response:
            return response.status, json.loads(response.read().decode("utf-8"))
    except urllib.error.HTTPError as error:
        return error.code, None


def get(url: str, token: str, call: Fetch, what: str) -> dict:
    try:
        status, body = call(url, token, TIMEOUT_SECONDS)
    except (OSError, ValueError) as error:
        raise NotesUnavailable(f"{what} 실패 — {type(error).__name__}") from error
    if status != 200:
        raise NotesUnavailable(f"{what} 실패 — HTTP {status}")
    if not isinstance(body, dict):
        raise NotesUnavailable(f"{what} 응답이 예상한 형식이 아니다")
    return body


def read_notes(corp_id: str, base: str, token: str, call: Fetch = fetch) -> dict:
    """`{"customer": …, "notes": […]}`. 그 corpId 의 고객 것이 아니면 돌려주지 않는다."""
    lookup = get(f"{base}/api/customers/lookup?corpId={urllib.parse.quote(corp_id, safe='')}",
                 token, call, "고객 찾기")
    customer_id = lookup.get("id")
    if not isinstance(customer_id, str) or not customer_id:
        raise NotesUnavailable("고객 찾기 응답에 고객 id 가 없다")
    answer = get(f"{base}/api/customers/{urllib.parse.quote(customer_id, safe='')}/notes",
                 token, call, "특이사항 조회")
    customer, notes = answer.get("customer"), answer.get("notes")
    if not isinstance(customer, dict) or not isinstance(notes, list):
        raise NotesUnavailable("특이사항 조회 응답이 예상한 형식이 아니다")
    if customer.get("billing_corp_id") != corp_id or customer.get("id") != customer_id:
        raise NotesUnavailable("찾던 고객과 다른 고객의 특이사항이 돌아왔다")
    return {"customer": customer, "notes": notes}


def render_note(note: dict) -> str:
    grade = GRADES.get(note.get("verification"), "추측")
    head = f"- [{note.get('severity_label')}][{note.get('category_label')}][{grade}] {note.get('content')}"
    detail = [f"근거: {note.get('evidence')}",
              f"작성 {str(note.get('created_at'))[:10]} {note.get('created_by')}"]
    if note.get("review_at"):
        detail.append(f"재확인 {note['review_at']}" + (" (지남)" if note.get("review_due") else ""))
    return f"{head}\n  {' · '.join(detail)}"


def render(answer: dict) -> str:
    customer, notes = answer["customer"], answer["notes"]
    lines = [f"고객: {customer.get('name')} (corpId {customer.get('billing_corp_id')})"]
    if not notes:
        return "\n".join(lines + ["특이사항 없음"])
    counts = Counter(note.get("severity_label") for note in notes)
    summary = " · ".join(f"{label} {count}" for label, count in counts.items())
    return "\n".join(lines + [f"특이사항 {len(notes)}건 — {summary}"] + [render_note(note) for note in notes])


def main(argv: list[str] | None = None, fetch: Fetch = fetch, conf: Path = CONF) -> int:
    parser = argparse.ArgumentParser(description="고객 한 곳의 특이사항을 ITSM 에서 읽는다.")
    parser.add_argument("corp_id", help="billing platform corpId")
    parser.add_argument("--dev", action="store_true", help="개발 서버에서 읽는다")
    args = parser.parse_args(argv)
    base, key = SERVERS[args.dev]
    corp_id = args.corp_id.strip()
    try:
        if not corp_id:
            raise NotesUnavailable("corpId 가 비었다")
        try:
            conf.read_text(encoding="utf-8")
        except FileNotFoundError:
            print(NOT_SET_UP_ADVICE.format(conf=conf, key=key), file=sys.stderr)
            return EXIT_NOT_SET_UP
        except (OSError, UnicodeDecodeError) as error:
            raise NotesUnavailable(f"토큰 파일을 읽지 못했다 ({conf}, {type(error).__name__})") from error
        token = token_from(conf, key)
        if not token:
            print(NOT_SET_UP_ADVICE.format(conf=conf, key=key), file=sys.stderr)
            return EXIT_NOT_SET_UP
        answer = read_notes(corp_id, base, token, fetch)
    except NotesUnavailable as error:
        print(f"특이사항을 읽지 못했다: {error}. {STOP_ADVICE}", file=sys.stderr)
        return EXIT_STOP
    print(render(answer))
    return 0


if __name__ == "__main__":
    sys.exit(main())
