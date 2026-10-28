#!/usr/bin/env python3
"""일기(주간회고) 초안을 MSP 사이트에 **임시저장**한다. 제출하지 않는다 — 제출하는 코드가 없다.

`weekly_diary.py` 가 재료를 모으고 에이전트가 초안을 쓴 뒤, 사람이 "저장해" 라고 했을 때만 부른다.
사이트의 개인 API(`/api/v1/me/reviews`)를 쓴다. 키 소유자 본인의 회고에만 닿는다.

지키는 것:
  - **이미 적혀 있는 칸은 건드리지 않는다.** 사람이 웹에서 쓴 글·숫자가 있으면 그 칸은 보내지 않는다. 덮으려면 `--overwrite`.
  - **제출됐거나 검토가 끝난 회고는 손대지 않는다.** 저장하면 작성 중으로 돌아가고 검토 표시가 풀린다 — 웹에서 고친다.
  - 빈 칸과 `(직접 작성)` 은 보내지 않는다.
  - 못 보냈으면 종료 코드 2 다. 성공한 것처럼 말하지 않는다.

키: 환경변수 `MSP_PERSONAL_KEY`, 없으면 `~/.config/msp/msp-site` 의 `MSP_PERSONAL_KEY=…` (권한 600).
웹 `내 정보 → 개인 API 키` 에서 본인이 발급한다. 권한은 `reviews:read`·`reviews:write` 만 — `reviews:submit` 은 켜지 않는다.
값은 출력하지 않는다.

사용 (초안은 표준 입력의 JSON — 파일로 남기지 않는다):
  python3 scripts/weekly_diary_save.py --week 2026-10-05 <<'JSON'
  {"workHighlights": "…", "actionItems": "…", "ticketsNew": 1, "ticketsInProgress": 1, "ticketsDone": 2}
  JSON
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import urllib.error
import urllib.request
from datetime import date
from pathlib import Path
from typing import Callable

sys.path.insert(0, str(Path(__file__).resolve().parent))
import https_fetch  # noqa: E402

CONF = Path(os.environ.get("MSP_SITE_CONF") or Path.home() / ".config/msp/msp-site")
SITE = "https://msp-internal.example.com"
TEXT_FIELDS = ("workHighlights", "actionItems", "topsProjects", "otherNotes")
COUNT_FIELDS = ("ticketsNew", "ticketsInProgress", "ticketsDone")
PLACEHOLDER = "(직접 작성)"
SITE_FILLER = "특이사항 없음"  # 사이트가 제출 때 빈 칸에 넣는 말. 사람이 쓴 글로 치지 않는다
LOCKED = {"submitted", "reviewed"}
TIMEOUT_SECONDS = 15

# http(method, url, body, timeout) -> (status, bytes). 네트워크를 타는 유일한 지점이다 — 테스트가 가짜를 끼운다.
Http = Callable[[str, str, "dict | None", float], "tuple[int, bytes]"]


class SaveError(Exception):
    def __init__(self, code: str, detail: str = "") -> None:
        super().__init__(code)
        self.code = code
        self.detail = detail


def _call(http: Http, method: str, url: str, body: dict | None = None) -> dict:
    try:
        status, raw = http(method, url, body, TIMEOUT_SECONDS)
    except (urllib.error.URLError, OSError, TimeoutError) as exc:
        raise SaveError("cert" if https_fetch.is_cert_error(exc) else "network")
    if status < 200 or status >= 300:
        raise SaveError(f"http_{status}")
    try:
        return json.loads(raw.decode("utf-8"))
    except (ValueError, UnicodeDecodeError):
        raise SaveError("parse")


def _clean(draft: dict) -> dict:
    """허용된 칸만, 형식이 맞는 값만. 틀리면 아무것도 부르기 전에 멈춘다."""
    unknown = sorted(set(draft) - set(TEXT_FIELDS) - set(COUNT_FIELDS))
    if unknown:
        raise SaveError("bad_field", ", ".join(unknown))
    for field in TEXT_FIELDS:
        if not isinstance(draft.get(field, ""), str):
            raise SaveError("bad_field", field)
    for field in COUNT_FIELDS:
        value = draft.get(field, 0)
        if isinstance(value, bool) or not isinstance(value, int) or not 0 <= value <= 1024:
            raise SaveError("bad_field", field)
    return draft


def _written(value: object, blank: object) -> bool:
    """그 칸에 사람이 적은 것이 있나."""
    if isinstance(value, str):
        value = value.strip()
        return value not in ("", SITE_FILLER)
    return value not in (blank, None)


def save(monday: date, draft: dict, http: Http, base: str, overwrite: bool = False) -> dict:
    """조회 → 비어 있는 칸만 임시저장. `{status, version, sent, kept, empty}` 를 돌려준다."""
    if monday.weekday() != 0:
        raise SaveError("not_monday")
    draft = _clean(draft)
    url = f"{base}/api/v1/me/reviews?week={monday.isoformat()}"
    stored = _call(http, "GET", url)
    if stored.get("status") in LOCKED:
        raise SaveError("already_submitted")

    body: dict = {}
    kept: list[str] = []
    empty: list[str] = []
    for field in TEXT_FIELDS + COUNT_FIELDS:
        new = draft.get(field, "" if field in TEXT_FIELDS else 0)
        blank = 0 if field in COUNT_FIELDS else ""
        if isinstance(new, str):
            new = new.strip()
        if new == blank or new == PLACEHOLDER:
            empty.append(field)
        elif _written(stored.get(field), blank) and not overwrite:
            kept.append(field)
        else:
            body[field] = new
    result = {"status": stored.get("status"), "version": stored.get("version"), "sent": sorted(body), "kept": kept, "empty": empty}
    if not body:
        return result
    saved = _call(http, "PUT", url, {"version": stored.get("version", 0), **body})
    return {**result, "status": saved.get("status"), "version": saved.get("version")}


def _key() -> str:
    value = os.environ.get("MSP_PERSONAL_KEY", "").strip()
    if value:
        return value
    try:
        for line in CONF.read_text(encoding="utf-8").splitlines():
            name, _, rest = line.partition("=")
            if name.strip() == "MSP_PERSONAL_KEY":
                return rest.strip()
    except OSError:
        pass
    return ""


def _default_http(key: str) -> Http:
    def http(method: str, url: str, body: dict | None, timeout: float) -> tuple[int, bytes]:
        data = json.dumps(body).encode("utf-8") if body is not None else None
        headers = {"Authorization": f"Bearer {key}", "Accept": "application/json"}
        if data is not None:
            headers["Content-Type"] = "application/json"
        request = urllib.request.Request(url, data=data, headers=headers, method=method)
        try:
            with https_fetch.urlopen(request, timeout=timeout) as response:
                return response.status, response.read()
        except urllib.error.HTTPError as exc:
            return exc.code, b""

    return http


HELP = {
    "no_key": "개인 API 키가 없다. 웹 `내 정보 → 개인 API 키` 에서 `reviews:read`·`reviews:write` 로 발급해 "
              "~/.config/msp/msp-site 에 `MSP_PERSONAL_KEY=…` 한 줄로 두고 `chmod 600` 한다. `reviews:submit` 은 켜지 않는다.",
    "already_submitted": "이미 제출했거나 검토가 끝난 회고다. 저장하면 작성 중으로 돌아가므로 손대지 않았다 — 웹에서 고친다.",
    "http_401": "키가 틀렸거나 만료·폐기됐다. 웹에서 새로 발급한다.",
    "http_403": "키에 `reviews:read`·`reviews:write` 권한이 없거나, MSP 엔지니어 계정이 아니다.",
    "http_409": "그 사이 회고가 다른 곳에서 바뀌었다. 다시 실행하면 최신 것을 읽고 저장한다.",
    "http_429": "요청 한도를 넘었다. 1분 뒤에 다시 한다.",
    "not_monday": "--week 는 그 주의 월요일이어야 한다.",
    "bad_field": "보낼 수 없는 칸이나 값이 있다.",
}


def main() -> int:
    parser = argparse.ArgumentParser(description="일기 초안을 MSP 사이트에 임시저장한다. 제출하지 않는다.")
    parser.add_argument("--week", required=True, help="그 주의 월요일 (YYYY-MM-DD)")
    parser.add_argument("--overwrite", action="store_true", help="이미 적혀 있는 칸도 덮는다")
    args = parser.parse_args()
    try:
        monday = date.fromisoformat(args.week)
        draft = json.loads(sys.stdin.read())
        if not isinstance(draft, dict):
            raise ValueError
    except ValueError:
        print("저장하지 않았다 — --week 는 YYYY-MM-DD, 표준 입력은 JSON 객체여야 한다.", file=sys.stderr)
        return 2
    key = _key()
    try:
        if not key:
            raise SaveError("no_key")
        result = save(monday, draft, _default_http(key), os.environ.get("MSP_SITE_URL", SITE).rstrip("/"), args.overwrite)
    except SaveError as exc:
        detail = f" ({exc.detail})" if exc.detail else ""
        print(f"저장하지 않았다 — {exc.code}{detail}. {HELP.get(exc.code, '')}".rstrip(), file=sys.stderr)
        return 2
    if result["sent"]:
        print(f"임시저장했다 ({monday.isoformat()} 주, 상태 {result['status']}). 보낸 칸: {', '.join(result['sent'])}")
    else:
        print(f"보낼 것이 없어 저장하지 않았다 ({monday.isoformat()} 주, 상태 {result['status']}).")
    if result["kept"]:
        print(f"이미 적혀 있어 건드리지 않은 칸: {', '.join(result['kept'])} — 덮으려면 --overwrite")
    if result["empty"]:
        print(f"비어 있어 안 보낸 칸: {', '.join(result['empty'])}")
    print(f"제출은 하지 않았다. 웹에서 확인하고 제출한다: {SITE}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
