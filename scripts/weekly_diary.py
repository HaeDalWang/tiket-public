#!/usr/bin/env python3
"""일기(주간회고) 초안의 재료를 모은다. 화면에만 낸다 — 보내지도, 파일로 남기지도 않는다.
(사이트 임시저장은 `weekly_diary_save.py` 가 따로 한다 — 사람이 시켰을 때만.)

팀이 주간회고를 "일기" 라고 부른다. 사이트의 회고 양식은 글 칸 넷과 티켓 수 셋이다.
이 스크립트는 재료만 모으고, 글은 에이전트가 `playbooks/weekly-diary.md` 대로 쓴다.

  글     그 주(월~일)에 쓴 `tickets/` 기록 — 제목·상태·산출물·물어본 것
  숫자   Zendesk 에서 나에게 배정된 티켓 수 — 신규(그 주에 만들어짐)·진행 중(지금 안 끝남)·종료(그 주에 해결됨).
         알람·월간보고서(`usage_zendesk.AUTO_TAGS`)는 세지 않는다.

`tickets/` 는 tiket 으로 처리한 건만 있어서 숫자를 거기서 세면 실제보다 적다 (2026-10-08 유지보수자).
"진행 중" 은 지금 시점의 값이다 — 지난 주를 `--week` 로 불러도 그때의 값이 아니다.

출력에는 실제 고객사명이 들어간다. 추적 파일로 옮기지 않는다.

사용:
  python3 scripts/weekly_diary.py                    이번 주 (한국 시간, 월요일부터)
  python3 scripts/weekly_diary.py --week 2026-10-05  그 월요일의 주
  python3 scripts/weekly_diary.py --no-zendesk       Zendesk 를 부르지 않는다

Zendesk 를 못 읽어도 글 재료는 낸다. 숫자는 지어내지 않고 못 읽었다고 적는다.
자격증명·인증은 `usage_zendesk.py`(= `fetch-ticket.sh`)와 같다.
"""

from __future__ import annotations

import argparse
import sys
import time
import urllib.parse
from datetime import date, datetime, timedelta, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(Path(__file__).resolve().parent))

from check_ticket_record import header_field, is_evaluation, record_date, section_body, strip_comments  # noqa: E402
import usage_zendesk as uz  # noqa: E402

KST = timezone(timedelta(hours=9))
ASKED_HEADING = "## 물어본 것"
PLAYBOOK = "playbooks/weekly-diary.md"
TOTAL_TIMEOUT_SECONDS = 20


def week_monday(today: date) -> date:
    """그 날이 든 주의 월요일. 사이트가 회고를 이 날짜로 묶는다."""
    return today - timedelta(days=today.weekday())


def collect_records(root: Path, monday: date) -> list[dict]:
    """`날짜:` 가 그 주(월~일)에 드는 기록. 평가 기록과 날짜 없는 기록은 뺀다."""
    sunday = monday + timedelta(days=6)
    records: list[dict] = []
    for path in sorted((root / "tickets").glob("*.md")):
        try:
            text = path.read_text(encoding="utf-8", errors="ignore")
        except OSError:
            continue
        day = record_date(text)
        if day is None or not (monday <= day <= sunday) or is_evaluation(text):
            continue
        title = next((line[2:].strip() for line in text.splitlines() if line.startswith("# ")), path.stem)
        records.append(
            {
                "id": path.stem,
                "title": title,
                "status": header_field(text, "상태") or "",
                "output": header_field(text, "산출물") or "",
                "asked": strip_comments(section_body(text, ASKED_HEADING) or "").strip(),
            }
        )
    return records


def zendesk_counts(monday: date, http: uz.Http, base: str, budget: uz._Budget | None = None) -> dict:
    """신규·진행 중·종료. 하나라도 못 읽으면 숫자 없이 `{"error", "stage"}` 만 돌려준다."""
    sunday = monday + timedelta(days=6)
    span = f">={monday.isoformat()}", f"<={sunday.isoformat()}"
    # 알람·월간보고서는 사람이 푼 티켓이 아니다 — 지표 D 와 같은 태그로 뺀다 (09-28 주 종료 21 → 5, 2026-10-14).
    human = "type:ticket assignee:me " + " ".join(f"-tags:{tag}" for tag in sorted(uz.AUTO_TAGS))
    queries = {
        "new": f"{human} created{span[0]} created{span[1]}",
        "in_progress": f"{human} status<solved",
        "done": f"{human} solved{span[0]} solved{span[1]}",
    }
    budget = budget or uz._Budget(TOTAL_TIMEOUT_SECONDS, time.monotonic)
    counts: dict = {}
    try:
        for key, query in queries.items():
            data = uz._get(http, f"{base}/search/count.json?query={urllib.parse.quote(query)}", budget, "count")
            if not isinstance(data.get("count"), int):
                raise uz._ZendeskError("parse", "count")
            counts[key] = data["count"]
    except uz._ZendeskError as exc:
        return exc.as_payload()
    return counts


def render(monday: date, records: list[dict], counts: dict | None) -> str:
    sunday = monday + timedelta(days=6)
    lines = [f"# 일기 재료 — {monday.isoformat()} 주 ({monday.isoformat()} ~ {sunday.isoformat()})", ""]
    if counts is None:
        lines.append("티켓 수: Zendesk 를 부르지 않았다 — 사람이 채운다.")
    elif "error" in counts:
        lines.append(f"티켓 수: Zendesk 에서 못 읽었다 ({counts['error']}) — 0 으로 적지 않는다. 사람이 채운다.")
    else:
        lines.append(f"티켓 수 (Zendesk, 나에게 배정): 신규 {counts['new']} · 진행 중 {counts['in_progress']} · 종료 {counts['done']}")
        lines.append("  신규 = 이 주에 만들어진 것 · 진행 중 = 지금 안 끝난 것 · 종료 = 이 주에 해결된 것")
    lines += ["", f"## 이 주에 tiket 으로 처리한 기록 {len(records)}건", ""]
    for item in records:
        tags = " · ".join(value for value in (item["status"], item["output"]) if value)
        lines.append(f"- {item['title']}" + (f" [{tags}]" if tags else ""))
        for asked in item["asked"].splitlines():
            if asked.strip():
                lines.append(f"    {asked.strip()}")
    lines += ["", f"쓰는 법: {PLAYBOOK}. 이 출력에는 실제 고객사명이 있다 — 추적 파일로 옮기지 않는다."]
    return "\n".join(lines)


def main() -> int:
    parser = argparse.ArgumentParser(description="일기(주간회고) 초안의 재료를 모아 화면에 낸다.")
    parser.add_argument("--week", help="그 주의 월요일 (YYYY-MM-DD). 기본은 이번 주")
    parser.add_argument("--no-zendesk", action="store_true", help="Zendesk 를 부르지 않는다")
    args = parser.parse_args()

    if args.week:
        try:
            monday = date.fromisoformat(args.week)
        except ValueError:
            print(f"--week 는 YYYY-MM-DD 다: {args.week}", file=sys.stderr)
            return 2
        if monday.weekday() != 0:
            print(f"--week 는 월요일이어야 한다 — 그 주의 월요일은 {week_monday(monday).isoformat()}", file=sys.stderr)
            return 2
    else:
        monday = week_monday(datetime.now(KST).date())

    counts: dict | None = None
    if not args.no_zendesk:
        credentials = uz._load_credentials()
        if credentials is None:
            counts = {"error": "no_credentials"}
        else:
            counts = zendesk_counts(monday, uz._default_http(credentials), credentials.base)
    print(render(monday, collect_records(ROOT, monday), counts))
    return 0


if __name__ == "__main__":
    sys.exit(main())
