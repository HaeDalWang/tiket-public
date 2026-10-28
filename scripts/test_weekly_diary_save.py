#!/usr/bin/env python3
"""weekly_diary_save 가 사람이 쓴 것을 덮지 않고, 제출하지 않고, 실패를 성공처럼 말하지 않는지 본다.

**실서버(사이트)에 닿지 않는다** — http 심에 가짜를 끼운다.
"""

from __future__ import annotations

import importlib.util
import json
import sys
import unittest
from datetime import date
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))

spec = importlib.util.spec_from_file_location("weekly_diary_save", ROOT / "scripts/weekly_diary_save.py")
ws = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ws)

MONDAY = date(2026, 10, 5)
BASE = "https://example.test"
EMPTY = {
    "week": "2026-10-05", "status": "missing", "version": 0,
    "workHighlights": "", "actionItems": "", "topsProjects": "", "otherNotes": "",
    "ticketsNew": 0, "ticketsInProgress": 0, "ticketsDone": 0,
}
DRAFT = {
    "workHighlights": "- 가나고객 — 느린 쿼리 확인 (종료)", "actionItems": "- 이어서 회신",
    "topsProjects": "(직접 작성)", "otherNotes": "",
    "ticketsNew": 4, "ticketsInProgress": 7, "ticketsDone": 3,
}


class FakeSite:
    def __init__(self, stored: dict, put_status: int = 200, get_status: int = 200) -> None:
        self.stored = stored
        self.put_status = put_status
        self.get_status = get_status
        self.calls: list[tuple[str, str, dict | None]] = []

    def __call__(self, method: str, url: str, body: dict | None, timeout: float) -> tuple[int, bytes]:
        self.calls.append((method, url, body))
        if method == "GET":
            return self.get_status, json.dumps(self.stored).encode()
        if method == "PUT":
            if self.put_status != 200:
                return self.put_status, b'{"error":"x"}'
            return 200, json.dumps({**self.stored, **body, "status": "draft", "version": self.stored["version"] + 1}).encode()
        return 405, b""

    @property
    def put_body(self) -> dict | None:
        return next((body for method, _, body in self.calls if method == "PUT"), None)


class SaveTest(unittest.TestCase):
    def test_a_new_week_is_saved_as_a_draft_with_the_version_it_read(self) -> None:
        site = FakeSite(dict(EMPTY))
        result = ws.save(MONDAY, DRAFT, site, BASE)
        self.assertEqual(result["status"], "draft")
        self.assertEqual(site.put_body["version"], 0)
        self.assertEqual(site.put_body["workHighlights"], DRAFT["workHighlights"])
        self.assertEqual(site.put_body["ticketsDone"], 3)
        for _, url, _ in site.calls:
            self.assertIn("/api/v1/me/reviews?week=2026-10-05", url)

    def test_placeholders_and_empty_fields_are_not_sent(self) -> None:
        site = FakeSite(dict(EMPTY))
        result = ws.save(MONDAY, DRAFT, site, BASE)
        self.assertNotIn("topsProjects", site.put_body)
        self.assertNotIn("otherNotes", site.put_body)
        self.assertEqual(sorted(result["empty"]), ["otherNotes", "topsProjects"])

    def test_what_the_person_already_wrote_is_kept(self) -> None:
        stored = {**EMPTY, "status": "draft", "version": 3, "workHighlights": "내가 쓴 것", "ticketsNew": 9}
        site = FakeSite(stored)
        result = ws.save(MONDAY, DRAFT, site, BASE)
        self.assertNotIn("workHighlights", site.put_body)
        self.assertNotIn("ticketsNew", site.put_body)
        self.assertEqual(site.put_body["actionItems"], DRAFT["actionItems"])
        self.assertEqual(site.put_body["version"], 3)
        self.assertEqual(sorted(result["kept"]), ["ticketsNew", "workHighlights"])

    def test_the_sites_own_filler_counts_as_empty(self) -> None:
        """사이트는 제출할 때 빈 칸을 `특이사항 없음` 으로 채운다. 그것을 사람이 쓴 글로 보면 한 번 제출했던 주에는 아무것도 못 넣는다
        (2026-10-08 실서버에서 그렇게 됐다)."""
        stored = {**EMPTY, "status": "draft", "version": 25, "workHighlights": "특이사항 없음", "actionItems": " 특이사항 없음 "}
        site = FakeSite(stored)
        result = ws.save(MONDAY, DRAFT, site, BASE)
        self.assertEqual(site.put_body["workHighlights"], DRAFT["workHighlights"])
        self.assertEqual(site.put_body["actionItems"], DRAFT["actionItems"])
        self.assertEqual(result["kept"], [])

    def test_overwrite_replaces_what_was_there(self) -> None:
        stored = {**EMPTY, "status": "draft", "version": 3, "workHighlights": "내가 쓴 것"}
        site = FakeSite(stored)
        ws.save(MONDAY, DRAFT, site, BASE, overwrite=True)
        self.assertEqual(site.put_body["workHighlights"], DRAFT["workHighlights"])

    def test_a_submitted_review_is_never_touched(self) -> None:
        for status in ("submitted", "reviewed"):
            site = FakeSite({**EMPTY, "status": status, "version": 5})
            with self.assertRaises(ws.SaveError) as caught:
                ws.save(MONDAY, DRAFT, site, BASE, overwrite=True)
            self.assertEqual(caught.exception.code, "already_submitted")
            self.assertIsNone(site.put_body)

    def test_nothing_new_means_no_write(self) -> None:
        stored = {**EMPTY, "status": "draft", "version": 2, "workHighlights": "a", "actionItems": "b",
                  "ticketsNew": 1, "ticketsInProgress": 1, "ticketsDone": 1}
        site = FakeSite(stored)
        result = ws.save(MONDAY, DRAFT, site, BASE)
        self.assertIsNone(site.put_body)
        self.assertEqual(result["sent"], [])

    def test_it_never_calls_submit(self) -> None:
        site = FakeSite(dict(EMPTY))
        ws.save(MONDAY, DRAFT, site, BASE)
        self.assertEqual([method for method, _, _ in site.calls], ["GET", "PUT"])
        self.assertFalse(any("submit" in url for _, url, _ in site.calls))

    def test_unknown_fields_are_refused_before_any_call(self) -> None:
        site = FakeSite(dict(EMPTY))
        with self.assertRaises(ws.SaveError) as caught:
            ws.save(MONDAY, {**DRAFT, "status": "submitted"}, site, BASE)
        self.assertEqual(caught.exception.code, "bad_field")
        self.assertEqual(site.calls, [])

    def test_ticket_counts_must_be_whole_numbers(self) -> None:
        with self.assertRaises(ws.SaveError) as caught:
            ws.save(MONDAY, {**DRAFT, "ticketsNew": "N"}, FakeSite(dict(EMPTY)), BASE)
        self.assertEqual(caught.exception.code, "bad_field")

    def test_failures_carry_the_http_code(self) -> None:
        for kwargs, code in (({"get_status": 401}, "http_401"), ({"put_status": 409}, "http_409"), ({"put_status": 403}, "http_403")):
            with self.assertRaises(ws.SaveError) as caught:
                ws.save(MONDAY, DRAFT, FakeSite(dict(EMPTY), **kwargs), BASE)
            self.assertEqual(caught.exception.code, code)

    def test_week_must_be_a_monday(self) -> None:
        with self.assertRaises(ws.SaveError) as caught:
            ws.save(date(2026, 10, 8), DRAFT, FakeSite(dict(EMPTY)), BASE)
        self.assertEqual(caught.exception.code, "not_monday")


if __name__ == "__main__":
    unittest.main()
