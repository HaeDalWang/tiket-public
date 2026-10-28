#!/usr/bin/env python3
"""weekly_diary 가 그 주의 기록만 고르고, Zendesk 숫자를 지어내지 않는지 본다.

**실서버(Zendesk)에 닿지 않는다** — http 심에 가짜를 끼운다.
"""

from __future__ import annotations

import importlib.util
import json
import sys
import tempfile
import unittest
import urllib.parse
from datetime import date
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))

spec = importlib.util.spec_from_file_location("weekly_diary", ROOT / "scripts/weekly_diary.py")
wd = importlib.util.module_from_spec(spec)
spec.loader.exec_module(wd)

MONDAY = date(2026, 10, 5)
BASE = "https://example.zendesk.com/api/v2"


def record(number: str, title: str, day: str, status: str = "종료", asked: str = "1. 왜 느린가") -> str:
    return (
        f"# {number} · {title}\n\n상태: {status}\n날짜: {day}\n등급: standard\n산출물: 조사+답변\n"
        f"policy_ids: []\n\n## 물어본 것\n\n<!-- 주석 -->\n{asked}\n\n## 확인한 것\n\n- [확인] x\n"
    )


class FakeCount:
    """search/count 의 검색어에 든 낱말로 숫자를 고른다."""

    def __init__(self, counts: dict[str, int], status: int = 200) -> None:
        self.counts = counts
        self.status = status
        self.queries: list[str] = []

    def __call__(self, url: str, timeout: float) -> tuple[int, bytes]:
        query = urllib.parse.unquote(url.split("query=")[1])
        self.queries.append(query)
        if self.status != 200:
            return self.status, b""
        for word, count in self.counts.items():
            if word in query:
                return 200, json.dumps({"count": count}).encode()
        return 200, json.dumps({"count": 0}).encode()


class WeekTest(unittest.TestCase):
    def test_monday_of_the_week_matches_the_site_key(self) -> None:
        self.assertEqual(wd.week_monday(date(2026, 10, 8)), MONDAY)   # 목요일
        self.assertEqual(wd.week_monday(date(2026, 10, 5)), MONDAY)   # 월요일 당일
        self.assertEqual(wd.week_monday(date(2026, 10, 11)), MONDAY)  # 일요일


class RecordsTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        (self.root / "tickets").mkdir()

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def put(self, name: str, text: str) -> None:
        (self.root / "tickets" / f"{name}.md").write_text(text, encoding="utf-8")

    def test_only_this_weeks_records_are_collected(self) -> None:
        self.put("100", record("100", "가나고객 · 느린 쿼리", "2026-10-05"))
        self.put("101", record("101", "가나고객 · 일요일 건", "2026-10-11"))
        self.put("102", record("102", "다라고객 · 지난 주", "2026-10-04"))
        self.put("103", record("103", "다라고객 · 다음 주", "2026-10-12"))
        ids = [r["id"] for r in wd.collect_records(self.root, MONDAY)]
        self.assertEqual(ids, ["100", "101"])

    def test_evaluation_and_undated_records_are_left_out(self) -> None:
        self.put("900117", record("900117", "합성고객 · 평가", "2026-10-06"))
        self.put("104", record("104", "가나고객 · 날짜 없음", "YYYY-MM-DD"))
        self.assertEqual(wd.collect_records(self.root, MONDAY), [])

    def test_record_carries_title_status_and_the_question_without_comments(self) -> None:
        self.put("100", record("100", "가나고객 · 느린 쿼리", "2026-10-06", status="발송함"))
        (item,) = wd.collect_records(self.root, MONDAY)
        self.assertEqual(item["title"], "100 · 가나고객 · 느린 쿼리")
        self.assertEqual(item["status"], "발송함")
        self.assertEqual(item["output"], "조사+답변")
        self.assertEqual(item["asked"], "1. 왜 느린가")


class CountsTest(unittest.TestCase):
    def test_three_counts_come_from_three_queries_bounded_by_the_week(self) -> None:
        fake = FakeCount({"created>=": 4, "solved>=": 3, "status<solved": 7})
        counts = wd.zendesk_counts(MONDAY, fake, BASE)
        self.assertEqual(counts, {"new": 4, "in_progress": 7, "done": 3})
        self.assertEqual(len(fake.queries), 3)
        for query in fake.queries:
            self.assertIn("assignee:me", query)
        created = next(q for q in fake.queries if "created>=" in q)
        self.assertIn("created>=2026-10-05", created)
        self.assertIn("created<=2026-10-11", created)
        solved = next(q for q in fake.queries if "solved>=" in q)
        self.assertIn("solved>=2026-10-05", solved)
        self.assertIn("solved<=2026-10-11", solved)

    def test_alarms_and_monthly_reports_are_not_counted(self) -> None:
        """09-28 주에 종료 21건 중 16건이 알람이었다 (2026-10-14). 지표 D 와 같은 태그로 뺀다."""
        fake = FakeCount({"created>=": 4, "solved>=": 3, "status<solved": 7})
        wd.zendesk_counts(MONDAY, fake, BASE)
        for query in fake.queries:
            for tag in ("auto_notification", "sla_excluded", "monthly_report"):
                self.assertIn(f"-tags:{tag}", query)

    def test_a_failed_call_gives_an_error_not_a_number(self) -> None:
        counts = wd.zendesk_counts(MONDAY, FakeCount({}, status=401), BASE)
        self.assertEqual(counts, {"error": "auth", "stage": "count"})

    def test_a_response_without_count_is_a_parse_error(self) -> None:
        def http(url: str, timeout: float) -> tuple[int, bytes]:
            return 200, b"{}"
        self.assertEqual(wd.zendesk_counts(MONDAY, http, BASE), {"error": "parse", "stage": "count"})


class RenderTest(unittest.TestCase):
    RECORDS = [{"id": "100", "title": "100 · 가나고객 · 느린 쿼리", "status": "종료", "output": "조사+답변", "asked": "1. 왜 느린가"}]

    def test_render_shows_counts_and_records(self) -> None:
        text = wd.render(MONDAY, self.RECORDS, {"new": 4, "in_progress": 7, "done": 3})
        self.assertIn("2026-10-05", text)
        self.assertIn("신규 4 · 진행 중 7 · 종료 3", text)
        self.assertIn("100 · 가나고객 · 느린 쿼리", text)
        self.assertIn("playbooks/weekly-diary.md", text)

    def test_render_says_the_numbers_are_missing_instead_of_zero(self) -> None:
        text = wd.render(MONDAY, self.RECORDS, {"error": "auth", "stage": "count"})
        self.assertIn("못 읽었다 (auth)", text)
        self.assertNotIn("신규 0", text)

    def test_render_without_zendesk_says_so(self) -> None:
        text = wd.render(MONDAY, [], None)
        self.assertIn("Zendesk 를 부르지 않았다", text)
        self.assertIn("기록 0건", text)


if __name__ == "__main__":
    unittest.main()
