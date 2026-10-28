#!/usr/bin/env python3
"""ITSM 에서 티켓 한 건과 그 스레드를 읽는다 (development/plans/2026-10-06-itsm-ticket-read.md).

`fetch-ticket.sh` 의 사람이 읽는 형식을 따른다. 아직 `fetch-ticket.sh` 에 연결하지 않았다.

**읽기만 한다.** 읽기 요청만 만들고(`customer_notes.fetch` 가 헤더만 단 읽기 요청을 보낸다), 고객 전체를
훑는 목록 경로는 부르지 않는다. 번호 한 개를 검색으로 찾아 → 그 한 건의 단건 → 활동만 읽는다.

**내부 메모를 고객 발언으로 읽지 않는다.** 내부 전용 종류는 `[내부 메모]`, 목록에 없는 종류는
`[구분 모름 — 고객 발언으로 읽지 않는다]` 이다. 공개는 아는 종류만.

**못 읽으면 멈춘다.** 토큰 없음·401/403·5xx·네트워크 오류·깨진 JSON·다른 티켓이 돌아온 경우 모두 종료 코드 2.
출력은 다 읽은 뒤에 한 번에 한다 — 반쪽 출력이 완성본처럼 보이지 않는다. 파일은 쓰지 않는다.

토큰: `~/.config/msp/itsm` 의 `ITSM_API_TOKEN` (`--dev` 는 `DEV_ITSM_API_TOKEN`). 값은 출력하지 않는다.

사용:
  python3 scripts/itsm_ticket.py <번호>            사람이 읽는 형식
  python3 scripts/itsm_ticket.py <번호> --json     원본 JSON (티켓 + 활동)
  python3 scripts/itsm_ticket.py <번호> --dev      개발 서버
"""

from __future__ import annotations

import argparse
import datetime
import json
import re
import sys
import urllib.parse
from html.parser import HTMLParser
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import customer_notes  # noqa: E402
import https_fetch  # noqa: E402,F401  (테스트가 이 이름으로 네트워크 문을 갈아 끼운다)

CONF = customer_notes.CONF
SERVERS = customer_notes.SERVERS
fetch = customer_notes.fetch
Unavailable = customer_notes.NotesUnavailable
EXIT_STOP = customer_notes.EXIT_STOP

SEARCH_LIMIT = 25  # 검색 라우트의 MAX_LIMIT. 정확 일치 말고 Zendesk 번호 후보도 넉넉히 받는다.
# 종류 → (단건, 활동). 검색이 돌려주는 4종 전부(backend/routes/ticket-search.js). 문제(problem)는 활동 경로가 없다.
TYPE_PATHS = {
    "incident": ("/api/incidents/{}", "/api/incidents/{}/activity"),
    "service_request": ("/api/service-requests/{}", "/api/service-requests/{}/activity"),
    "change_request": ("/api/change-requests/{}", "/api/change-requests/{}/activity"),
    "problem": ("/api/problems/{}", None),
}

# 출처: ~/work/itsm backend/lib/activity-visibility.js @ origin/dev 0f910b9d8ec3 (2026-10-23 읽음).
# INTERNAL_ONLY_ACTIVITY_TYPES, INTERNAL_SYSTEM_NOTE_AUTHORS 를 그대로 옮겼다. 거기가 정의의 유일한 곳이고
# 목록이 늘면 여기도 늘려야 한다 — 모르는 종류는 아래에서 '구분 모름' 으로 떨어지므로 늦어도 공개로 읽히진 않는다.
INTERNAL_ONLY_ACTIVITY_TYPES = ("work_note", "internal_note", "reply_cc", "escalation")
INTERNAL_SYSTEM_NOTE_AUTHORS = ("connect-attacher", "slack-notifier")
# 고객 화면에서 숨기는 AI 초안 답변의 멱등 키 접두사 (backend/routes/incidents.js 활동 조회, 같은 커밋).
AI_DRAFT_KEY_PREFIX = "ai-support-case-public-reply:"
# 고객에게 보이는 것으로 확인한 종류: activity-visibility.js 가 이름을 든 공개 종류와
# incidents.js 가 쓰는 customer_reply·customer_note, zendesk-comment-mirror-store.js 의 inbound_email.
PUBLIC_ACTIVITY_TYPES = ("customer_reply", "customer_note", "inbound_email", "status_change", "assigned",
                         "major_incident", "customer_confirmed", "system_note")

INTERNAL_LABEL = "내부 메모"
PUBLIC_LABEL = "공개"
UNKNOWN_LABEL = "[구분 모름 — 고객 발언으로 읽지 않는다]"
RULE = "═" * 60
THIN = "─" * 46


def activity_label(row: dict) -> str:
    kind = row.get("type")
    if kind in INTERNAL_ONLY_ACTIVITY_TYPES:
        return INTERNAL_LABEL
    if kind == "system_note" and row.get("username") in INTERNAL_SYSTEM_NOTE_AUTHORS:
        return INTERNAL_LABEL
    if str(row.get("idempotency_key") or "").startswith(AI_DRAFT_KEY_PREFIX):
        return INTERNAL_LABEL
    return PUBLIC_LABEL if kind in PUBLIC_ACTIVITY_TYPES else UNKNOWN_LABEL


class _PlainText(HTMLParser):
    BLOCK = {"p", "div", "br", "ul", "ol", "li", "tr", "table", "blockquote", "pre",
             "h1", "h2", "h3", "h4", "h5", "h6"}
    SKIP = {"script", "style"}

    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.out: list[str] = []
        self.skipping = 0
        self.href: str | None = None

    def handle_starttag(self, tag, attrs) -> None:
        if tag in self.SKIP:
            self.skipping += 1
        elif tag == "li":
            self.out.append("\n- ")
        elif tag in self.BLOCK:
            self.out.append("\n")
        elif tag == "img":
            self.out.append("[이미지]")
        elif tag == "a":
            self.href = dict(attrs).get("href")

    def handle_endtag(self, tag) -> None:
        if tag in self.SKIP:
            self.skipping = max(0, self.skipping - 1)
        elif tag in self.BLOCK and tag != "br":
            self.out.append("\n")
        elif tag == "a" and self.href:
            self.out.append(f" ({self.href})")
            self.href = None

    def handle_data(self, data) -> None:
        if not self.skipping:
            self.out.append(data)


def body_text(content, content_format) -> str:
    text = content if isinstance(content, str) else ""
    if content_format == "html":
        parser = _PlainText()
        parser.feed(text)
        parser.close()
        text = "".join(parser.out)
    return re.sub(r"\n{3,}", "\n\n", "\n".join(line.rstrip() for line in text.splitlines())).strip()


def get(base: str, path: str, token: str, call, what: str) -> dict:
    return customer_notes.get(f"{base}{path}", token, call, what)


def quote(value) -> str:
    return urllib.parse.quote(str(value), safe="")


def describe(item: dict) -> str:
    return f"{item.get('type')} {item.get('id')} #{item.get('ticket_number')}"


def resolve(number: str, base: str, token: str, call) -> tuple[dict, dict]:
    """(검색 항목, 단건). 번호가 정확히 맞는 한 건만 돌려준다 — 검색은 제목 부분 일치도 섞어 온다."""
    found = get(base, f"/api/search/tickets?q={number}&limit={SEARCH_LIMIT}", token, call, "티켓 검색")
    items = found.get("items")
    if not isinstance(items, list):
        raise Unavailable("티켓 검색 응답이 예상한 형식이 아니다")
    details: dict[str, dict] = {}

    def detail_of(item: dict) -> dict:
        kind = item.get("type")
        if kind not in TYPE_PATHS:
            raise Unavailable(f"알 수 없는 티켓 종류({kind})라 읽지 않는다")
        key = f"{kind}:{item.get('id')}"
        if key not in details:
            details[key] = get(base, TYPE_PATHS[kind][0].format(quote(item.get("id"))), token, call, "티켓 조회")
            if details[key].get("id") != item.get("id"):
                raise Unavailable("찾던 티켓과 다른 티켓이 돌아왔다")
        return details[key]

    hits = [i for i in items if isinstance(i, dict)]
    exact = [i for i in hits if str(i.get("ticket_number")) == number]
    if not exact:
        # 검색 항목에 Zendesk 번호가 없어 단건을 열어 대조한다 — 다른 고객 티켓이 열리므로 정확 일치가 없을 때만.
        exact = [i for i in hits if i.get("type") in TYPE_PATHS and str(detail_of(i).get("zendesk_ticket_id")) == number]
    if not exact:
        raise Unavailable(f"번호 {number} 에 정확히 맞는 티켓을 찾지 못했다")
    if len(exact) > 1:
        raise Unavailable(f"번호 {number} 에 정확히 맞는 티켓이 {len(exact)}건이라 고르지 않는다 — "
                          + ", ".join(describe(i) for i in exact))
    return exact[0], detail_of(exact[0])


def read_ticket(number: str, base: str, token: str, call) -> dict:
    """`{"kind", "ticket", "activities"}`. 활동 경로가 없는 종류는 activities 가 None."""
    item, ticket = resolve(number, base, token, call)
    activity_path = TYPE_PATHS[item["type"]][1]
    activities = None
    if activity_path:
        answer = get(base, activity_path.format(quote(item["id"])), token, call, "활동 조회")
        activities = answer.get("activities")
        if not isinstance(activities, list) or not all(isinstance(row, dict) for row in activities):
            raise Unavailable("활동 조회 응답이 예상한 형식이 아니다")
    return {"kind": item["type"], "ticket": ticket, "activities": activities}


def attachment_line(files) -> str:
    names = [f"{f.get('original_name')} ({int(f.get('size') or 0) // 1024}KB)" for f in files or [] if isinstance(f, dict)]
    return f"첨부: {', '.join(names)}" if names else ""


def render_activity(row: dict) -> str:
    name = row.get("author_display_name") or row.get("author_full_name") or row.get("username") or "(알 수 없음)"
    body = body_text(row.get("content"), row.get("content_format"))
    if not body and (row.get("old_value") or row.get("new_value")):
        body = f"{row.get('old_value') or '-'} → {row.get('new_value') or '-'}"
    parts = [f"{THIN}\n[{row.get('created_at')}] {name} ({row.get('author_role') or '?'})"
             f"  · {activity_label(row)} · {row.get('type')}\n{THIN}", body, attachment_line(row.get("attachments"))]
    return "\n".join(p for p in parts if p) + "\n"


def render(result: dict, today: str) -> str:
    kind, t, activities = result["kind"], result["ticket"], result["activities"]
    lines = [RULE,
             f"TICKET #{t.get('ticket_number')}  [{t.get('status')}]",
             f"제목   : {t.get('title')}",
             f"생성   : {t.get('created_at')}   업데이트: {t.get('updated_at')}",
             f"우선순위: {t.get('priority') or '-'}   유형: {kind}",
             f"고객   : {t.get('customer_name')} (customer_id {t.get('customer_id')})",
             f"권한   : {t.get('ticket_authority') or '-'}"]
    if t.get("zendesk_ticket_id"):
        lines.append(f"Zendesk: {t['zendesk_ticket_id']}")
    lines += [f"조회일 : {today}   (기록의 작성일 — 스레드 날짜가 아니다)", RULE, ""]
    request = body_text(t.get("description") or t.get("details"), t.get("content_format"))
    if request:
        lines += [f"{THIN}\n요청 본문\n{THIN}", request, ""]
    mail = attachment_line(t.get("inbound_attachments"))
    if mail:
        lines += [f"메일 {mail}", ""]
    if activities is None:
        lines.append(NO_THREAD.format(kind=kind))
    else:
        # API 는 최신순이다. 같은 시각이면 API 의 원래 순서를 뒤집은 쪽이 오래된 것이다.
        lines += [render_activity(row) for row in sorted(reversed(activities), key=lambda r: str(r.get("created_at")))]
    return "\n".join(lines)


NO_THREAD = "※ {kind} 는 활동 경로가 없어 스레드를 읽지 못했다 — 위는 티켓 본문뿐이다. 완성본이 아니다."


def main(argv: list[str] | None = None, fetch=fetch, conf: Path = CONF) -> int:
    parser = argparse.ArgumentParser(description="ITSM 에서 티켓 한 건과 스레드를 읽는다.")
    parser.add_argument("number", help="티켓 번호 (숫자)")
    parser.add_argument("--json", action="store_true", help="원본 JSON (티켓 + 활동)")
    parser.add_argument("--dev", action="store_true", help="개발 서버에서 읽는다")
    args = parser.parse_args(argv)
    base, key = SERVERS[args.dev]
    number = args.number.strip()
    try:
        if not re.fullmatch(r"[0-9]+", number):
            raise Unavailable("티켓 번호는 숫자만 쓴다")
        token = customer_notes.token_from(conf, key)
        if not token:
            raise Unavailable(f"ITSM 토큰이 없다 ({conf} 의 {key})")
        result = read_ticket(number, base, token, fetch)
    except Unavailable as error:
        print(f"티켓을 읽지 못했다: {error}", file=sys.stderr)
        return EXIT_STOP
    if result["ticket"].get("ticket_authority") == "zendesk":
        print("경고: ticket_authority 가 zendesk 다 — 이 티켓은 Zendesk 스레드가 정본이다. 여기 스레드는 사본일 수 있다.",
              file=sys.stderr)
    if result["activities"] is None:
        print(NO_THREAD.format(kind=result["kind"]), file=sys.stderr)
    if args.json:
        print(json.dumps({"ticket": result["ticket"], "activities": result["activities"]}, ensure_ascii=False, indent=2))
    else:
        print(render(result, datetime.date.today().isoformat()))
    return 0


if __name__ == "__main__":
    sys.exit(main())
