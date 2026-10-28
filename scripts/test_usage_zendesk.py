#!/usr/bin/env python3
"""usage_zendesk.collect_zendesk 가 B·C·D 를 바로 세는지, 실패를 지어내지 않는지 본다.

**실서버(Zendesk)에 닿지 않는다** — http 심에 가짜를 끼운다. 가짜는 URL 로 응답을 고른다.
통과 경로만 보면 아무것도 안 잡는 집계도 초록불이 나므로, 핵심마다 값을 흔들어 확인한다.
"""

from __future__ import annotations

import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import unittest
import urllib.error
from datetime import date
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

spec = importlib.util.spec_from_file_location("usage_zendesk", ROOT / "scripts/usage_zendesk.py")
uz = importlib.util.module_from_spec(spec)
spec.loader.exec_module(uz)

sys.path.insert(0, str(ROOT / "scripts"))
import report_usage  # noqa: E402

TODAY = date(2026, 10, 4)  # 2026-W40 (일요일)
BASE = "https://example.zendesk.com/api/v2"
MY_ID = 777


def iso_week(value: date) -> str:
    year, week, _ = value.isocalendar()
    return f"{year}-W{week:02d}"


def medians(bucket: dict) -> dict:
    return {key: bucket[key] for key in ("n", "calendar", "business")}


class FakeClock:
    """부를 때마다 현재 값을 돌려준다. advance 로 시간을 민다 — 테스트가 "N번째 호출에서
    예산 소진" 을 틱 수에 의존하지 않고 재현한다."""

    def __init__(self, start: float = 0.0) -> None:
        self.now = start

    def __call__(self) -> float:
        return self.now

    def advance(self, seconds: float) -> None:
        self.now += seconds


# ── 가짜 Zendesk ───────────────────────────────────────────────────────────────


class FakeZendesk:
    """URL 로 응답을 고르는 가짜 http. (status, bytes) 를 돌려준다 — 실제 심과 같은 계약."""

    def __init__(self) -> None:
        self.tickets: list[dict] = []
        self.metric_sets: list[dict] = []
        self.comments: dict[str, list[dict]] = {}
        self.other_tickets: list[dict] = []   # 내 검색에는 안 나오는 티켓 — 남의 담당이거나 아직 안 끝난 것
        self.me: dict | None = {"user": {"id": MY_ID}}
        self.calls: list[str] = []
        self.timeouts: list[float] = []
        self.status_for: dict[str, int] = {}  # URL 조각 → 강제 상태코드
        self.raw_for: dict[str, bytes] = {}   # URL 조각 → 날바이트 (parse 테스트용)
        self.pages: list[dict] | None = None  # 설정하면 search 가 페이지를 하나씩 돌려준다
        self.clock: FakeClock | None = None   # 설정하면 매칭된 호출 뒤 시간을 민다
        self.advance_on: dict[str, float] = {}  # URL 조각 → 응답 뒤 advance 할 초

    def __call__(self, url: str, timeout: float) -> tuple[int, bytes]:
        self.calls.append(url)
        self.timeouts.append(timeout)
        if self.clock is not None:
            for fragment, seconds in self.advance_on.items():
                if fragment in url:
                    self.clock.advance(seconds)
        for fragment, status in self.status_for.items():
            if fragment in url:
                return status, b""
        for fragment, raw in self.raw_for.items():
            if fragment in url:
                return 200, raw
        if "/users/me" in url:
            return 200, json.dumps(self.me).encode()
        if "/search.json" in url:
            if self.pages is not None:
                page = self.pages.pop(0)
                return 200, json.dumps(page).encode()
            return 200, json.dumps({"results": self.tickets, "next_page": None}).encode()
        if "/tickets/show_many" in url:
            ids = url.split("ids=")[1].split("&")[0].split(",")
            sets = [m for m in self.metric_sets if str(m["ticket_id"]) in ids]
            found = [t for t in self.tickets + self.other_tickets if str(t["id"]) in ids]
            return 200, json.dumps({"tickets": found, "metric_sets": sets}).encode()
        if "/comments.json" in url:
            ticket_id = url.split("/tickets/")[1].split("/comments")[0]
            return 200, json.dumps({"comments": self.comments.get(ticket_id, [])}).encode()
        return 404, b""

    def add_other_ticket(self, ticket_id: int, solved_at: str | None, *, status="closed", tags=()) -> None:
        self.other_tickets.append({"id": ticket_id, "status": status, "tags": list(tags), "updated_at": solved_at})
        self.metric_sets.append({"ticket_id": ticket_id, "solved_at": solved_at})

    def add_ticket(self, ticket_id: int, solved_at: str, *, reply=None, resolution=None, reopens=0, waited=None, tags=()) -> None:
        self.tickets.append({"id": ticket_id, "updated_at": solved_at, "status": "closed", "tags": list(tags)})
        self.metric_sets.append(
            {
                "ticket_id": ticket_id,
                "solved_at": solved_at,
                "reply_time_in_minutes": reply,
                "full_resolution_time_in_minutes": resolution,
                "requester_wait_time_in_minutes": waited,
                "reopens": reopens,
            }
        )

    def add_comment(self, ticket_id: int, body: str, *, public=True, author_id=MY_ID) -> None:
        self.comments.setdefault(str(ticket_id), []).append(
            {"body": body, "public": public, "author_id": author_id}
        )


RECORD = """# {id} · 고객사 · 테스트

상태: 발송함
날짜: {date}
등급: standard
산출물: 조사+답변
policy_ids: []

## 물어본 것

1. 왜

## 확인한 것

- [확인] 그렇다
  → https://example.com 2026-10-01 확인

## 답변 초안

```text
{draft}
```

## 발송 전 점검

```
[x] 고객이 문의에서 밝힌 제약을 답변이 지키는가
```

## 교훈 후보

- 없음
"""


class CollectZendeskTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        (self.root / "tickets").mkdir()
        # 캐시가 테스트끼리·실행끼리 새지 않게 각 테스트마다 임시 경로로 바꾼다.
        self.cache = Path(self.tmp.name) / "cache.json"
        self._saved_cache = uz.CACHE
        uz.CACHE = self.cache

    def tearDown(self) -> None:
        uz.CACHE = self._saved_cache
        self.tmp.cleanup()

    def write_record(self, ticket_id: int, when: str, draft: str = "표준 안내 문구입니다.") -> None:
        (self.root / "tickets" / f"{ticket_id}.md").write_text(
            RECORD.format(id=ticket_id, date=when, draft=draft), encoding="utf-8"
        )

    def collect(self, fake: FakeZendesk) -> dict:
        return uz.collect_zendesk(self.root, TODAY, http=fake)

    # ── D: solved 와 with_record ────────────────────────────────────────────

    def test_counts_solved_and_with_record_per_week(self) -> None:
        fake = FakeZendesk()
        fake.add_ticket(101, "2026-10-01T00:00:00Z")  # W40, 기록 있음
        fake.add_ticket(102, "2026-10-02T00:00:00Z")  # W40, 기록 없음
        self.write_record(101, "2026-10-01")
        week = self.collect(fake)["weeks"][iso_week(TODAY)]
        self.assertEqual((week["solved"], week["with_record"]), (2, 1))

    def test_records_outside_the_window_are_ignored(self) -> None:
        """8주 밖(여기서는 과거)의 solved 는 어느 주에도 들어가지 않는다."""
        fake = FakeZendesk()
        fake.add_ticket(201, "2026-01-01T00:00:00Z")  # 한참 전
        payload = self.collect(fake)
        self.assertEqual(payload["weeks"], {})

    def test_evaluation_records_do_not_count_as_with_record(self) -> None:
        """평가 기록(합성고객)은 report_usage 와 같은 기준으로 뺀다 — with_record 로 세면 안 된다."""
        fake = FakeZendesk()
        fake.add_ticket(301, "2026-10-01T00:00:00Z")
        path = self.root / "tickets" / "301.md"
        path.write_text(
            RECORD.format(id="301", date="2026-10-01", draft="x").replace("고객사", "합성고객"),
            encoding="utf-8",
        )
        week = self.collect(fake)["weeks"][iso_week(TODAY)]
        self.assertEqual((week["solved"], week["with_record"]), (1, 0))

    # ── D 의 분모: 알람·월간보고서는 사람이 푼 티켓이 아니다 (2026-10-13) ─────────────

    def test_automatic_tickets_are_left_out_of_solved(self) -> None:
        """8주 해결 79건 중 46건이 알람이었다 — 분모에 넣으면 기록 비율이 6% 로 나온다."""
        fake = FakeZendesk()
        fake.add_ticket(401, "2026-10-01T00:00:00Z")
        fake.add_ticket(402, "2026-10-01T00:00:00Z", tags=["cloudwatch_alarm", "auto_notification"])
        fake.add_ticket(403, "2026-10-01T00:00:00Z", tags=["sla_excluded"])
        fake.add_ticket(404, "2026-10-01T00:00:00Z", tags=["monthly_report", "enterprise"])
        fake.add_ticket(405, "2026-10-01T00:00:00Z", tags=["enterprise"])
        week = self.collect(fake)["weeks"][iso_week(TODAY)]
        self.assertEqual((week["solved"], week["auto_excluded"]), (2, 3))

    def test_automatic_tickets_do_not_pull_the_timings(self) -> None:
        """알람은 몇 분 만에 닫힌다 — 중앙값에 섞이면 해결 시간이 3분으로 나온다."""
        fake = FakeZendesk()
        fake.add_ticket(411, "2026-10-01T00:00:00Z", resolution={"calendar": 600, "business": 300}, waited={"calendar": 90, "business": 60})
        for number in (412, 413, 414):
            fake.add_ticket(number, "2026-10-01T00:00:00Z", tags=["auto_notification"],
                            resolution={"calendar": 3, "business": 3}, waited={"calendar": 1, "business": 1})
        week = self.collect(fake)["weeks"][iso_week(TODAY)]
        self.assertEqual(medians(week["resolution_minutes"]["without"]), {"n": 1, "calendar": 600, "business": 300})
        self.assertEqual(week["requester_wait_minutes"]["n"], 1)

    def test_a_week_with_only_automatic_tickets_still_reports_them(self) -> None:
        fake = FakeZendesk()
        fake.add_ticket(421, "2026-10-01T00:00:00Z", tags=["auto_notification"])
        week = self.collect(fake)["weeks"][iso_week(TODAY)]
        self.assertEqual((week["solved"], week["with_record"], week["auto_excluded"]), (0, 0, 1))

    # ── D 의 분자: 남의 담당 티켓을 도운 기록 (2026-10-13) ─────────────────────────

    def test_records_on_someone_elses_solved_ticket_are_counted_apart(self) -> None:
        """기록 14건 중 7건이 남의 담당 티켓이었다 — 내 검색에 안 나와서 어디에도 안 세졌다."""
        fake = FakeZendesk()
        fake.add_ticket(501, "2026-10-01T00:00:00Z")
        fake.add_other_ticket(502, "2026-10-02T00:00:00Z")
        self.write_record(501, "2026-10-01")
        self.write_record(502, "2026-10-02")
        week = self.collect(fake)["weeks"][iso_week(TODAY)]
        self.assertEqual((week["solved"], week["with_record"], week["helped_with_record"]), (1, 1, 1))

    def test_helped_records_wait_until_the_ticket_is_solved(self) -> None:
        fake = FakeZendesk()
        fake.add_other_ticket(511, None, status="hold")
        fake.add_other_ticket(512, "2026-10-02T00:00:00Z", status="solved")
        fake.add_other_ticket(513, "2026-10-02T00:00:00Z", tags=["auto_notification"])
        fake.add_other_ticket(514, "2026-01-02T00:00:00Z")  # 8주 밖
        fake.add_other_ticket(515, "2026-10-02T00:00:00Z", status="open")  # 해결됐다가 다시 열린 것
        for number in (511, 512, 513, 514, 515):
            self.write_record(number, "2026-10-02")
        (self.root / "tickets" / "LOCAL-20261002-01.md").write_text(RECORD.format(id="L", date="2026-10-02", draft="x"), encoding="utf-8")
        weeks = self.collect(fake)["weeks"]
        self.assertEqual(list(weeks), [iso_week(TODAY)])
        self.assertEqual(weeks[iso_week(TODAY)]["helped_with_record"], 1)

    def test_no_lookup_when_every_record_is_my_own_ticket(self) -> None:
        fake = FakeZendesk()
        fake.add_ticket(521, "2026-10-01T00:00:00Z")
        self.write_record(521, "2026-10-01")
        self.collect(fake)
        self.assertEqual(sum("/tickets/show_many" in url for url in fake.calls), 1)

    def test_a_failed_helped_lookup_fails_the_whole_result(self) -> None:
        """도운 기록을 못 읽었는데 0 으로 내면 지어낸 값이다."""
        fake = FakeZendesk()
        fake.add_other_ticket(531, "2026-10-02T00:00:00Z")
        self.write_record(531, "2026-10-02")
        fake.status_for["/tickets/show_many"] = 500
        self.assertEqual(self.collect(fake), {"error": "http_500", "stage": "show_many"})

    # ── C: 시간·재오픈, with/without 로 갈라서 ────────────────────────────────

    def test_buckets_carry_sums_and_counts_so_the_team_mean_is_exact(self) -> None:
        """MTTA·MTTR 은 평균이다(2026-10-21). 사람별 중앙값으로는 팀 평균을 못 내므로 합계와 건수를 보낸다.
        달력·근무시간은 따로 센다 — 한쪽만 있는 티켓이 있다."""
        fake = FakeZendesk()
        fake.add_ticket(451, "2026-10-01T00:00:00Z", reply={"calendar": 40, "business": 30}, resolution={"calendar": 600, "business": 120})
        fake.add_ticket(452, "2026-10-01T00:00:00Z", reply={"calendar": 61, "business": None}, resolution={"calendar": 900.4, "business": 200})
        fake.add_ticket(453, "2026-10-01T00:00:00Z", reply={"calendar": None, "business": 10})
        week = self.collect(fake)["weeks"][iso_week(TODAY)]
        reply = week["reply_minutes"]["without"]
        self.assertEqual({k: reply[k] for k in ("calendar_sum", "calendar_n", "business_sum", "business_n")},
                         {"calendar_sum": 101, "calendar_n": 2, "business_sum": 40, "business_n": 2})
        self.assertEqual(reply["n"], 3)
        resolution = week["resolution_minutes"]["without"]
        self.assertEqual((resolution["calendar_sum"], resolution["calendar_n"]), (1500, 2))
        self.assertEqual(week["reply_minutes"]["with"]["calendar_n"], 0)
        self.assertEqual(week["reply_minutes"]["with"]["calendar_sum"], 0)

    def test_reply_and_resolution_medians_split_by_record(self) -> None:
        fake = FakeZendesk()
        # 기록 있는 둘: reply calendar 40·60 → median 50
        fake.add_ticket(401, "2026-10-01T00:00:00Z", reply={"calendar": 40, "business": 30})
        fake.add_ticket(402, "2026-10-01T00:00:00Z", reply={"calendar": 60, "business": 50})
        # 기록 없는 하나: reply calendar 100
        fake.add_ticket(403, "2026-10-02T00:00:00Z", reply={"calendar": 100, "business": 90})
        self.write_record(401, "2026-10-01")
        self.write_record(402, "2026-10-01")
        week = self.collect(fake)["weeks"][iso_week(TODAY)]
        self.assertEqual(medians(week["reply_minutes"]["with"]), {"n": 2, "calendar": 50, "business": 40})
        self.assertEqual(medians(week["reply_minutes"]["without"]), {"n": 1, "calendar": 100, "business": 90})

    def test_missing_timings_leave_null_median_and_zero_n(self) -> None:
        """값이 없으면 지어내지 않는다 — median 은 null, n 은 0."""
        fake = FakeZendesk()
        fake.add_ticket(501, "2026-10-01T00:00:00Z", reply=None, resolution=None)
        self.write_record(501, "2026-10-01")
        week = self.collect(fake)["weeks"][iso_week(TODAY)]
        self.assertEqual(medians(week["reply_minutes"]["with"]), {"n": 0, "calendar": None, "business": None})

    def test_reopens_counted_by_record_side(self) -> None:
        fake = FakeZendesk()
        fake.add_ticket(601, "2026-10-01T00:00:00Z", reopens=2)  # 기록 있음 → with 1
        fake.add_ticket(602, "2026-10-01T00:00:00Z", reopens=0)  # 재오픈 없음
        fake.add_ticket(603, "2026-10-02T00:00:00Z", reopens=1)  # 기록 없음 → without 1
        self.write_record(601, "2026-10-01")
        self.write_record(602, "2026-10-01")
        week = self.collect(fake)["weeks"][iso_week(TODAY)]
        self.assertEqual(week["reopened"], {"with": 1, "without": 1})

    def test_requester_wait_is_one_median_over_every_solved_ticket(self) -> None:
        """고객이 우리를 기다린 시간(new·open·on-hold). 기록 유무로 가르지 않는다 — 깊게 본 티켓에만 기록이 있어
        두 묶음은 같은 종류의 티켓이 아니다(2026-10-07). 한 주의 모든 해결 티켓에서 중앙값 하나를 낸다."""
        fake = FakeZendesk()
        fake.add_ticket(701, "2026-10-01T00:00:00Z", waited={"calendar": 600, "business": 30}, resolution={"calendar": 9000, "business": 900})
        fake.add_ticket(702, "2026-10-01T00:00:00Z", waited={"calendar": 100, "business": 10})
        fake.add_ticket(703, "2026-10-02T00:00:00Z", waited={"calendar": 200, "business": 20})
        fake.add_ticket(704, "2026-10-02T00:00:00Z")  # 값이 없는 티켓은 표본에서 빠진다
        self.write_record(701, "2026-10-01")
        week = self.collect(fake)["weeks"][iso_week(TODAY)]
        self.assertEqual(medians(week["requester_wait_minutes"]), {"n": 3, "calendar": 200, "business": 20})

    def test_requester_wait_without_any_value_is_null_not_zero(self) -> None:
        fake = FakeZendesk()
        fake.add_ticket(705, "2026-10-01T00:00:00Z")
        week = self.collect(fake)["weeks"][iso_week(TODAY)]
        self.assertEqual(medians(week["requester_wait_minutes"]), {"n": 0, "calendar": None, "business": None})

    # ── B: 초안 ↔ 실제 공개 답변 유사도 ──────────────────────────────────────

    def test_similarity_only_for_tickets_with_a_record(self) -> None:
        fake = FakeZendesk()
        fake.add_ticket(701, "2026-10-01T00:00:00Z")
        fake.add_ticket(702, "2026-10-02T00:00:00Z")  # 기록 없음 — B 에서 빠진다
        fake.add_comment(701, "표준 안내 문구입니다.")
        fake.add_comment(702, "뭐든")
        self.write_record(701, "2026-10-01", draft="표준 안내 문구입니다.")
        sim = self.collect(fake)["draft_similarity"][iso_week(TODAY)]
        self.assertEqual(sim["n"], 1)
        self.assertEqual(sim["high"], 1)  # 똑같으면 1.0 → high

    def test_only_my_public_comments_are_compared(self) -> None:
        """내부 메모와 남의 댓글은 제외. 초안과 완전히 다른 글이 끼면 유사도가 바닥으로 떨어진다."""
        fake = FakeZendesk()
        fake.add_ticket(801, "2026-10-01T00:00:00Z")
        fake.add_comment(801, "내부 메모 전혀 다른 내용", public=False)
        fake.add_comment(801, "남이 쓴 완전히 다른 글", author_id=999)
        fake.add_comment(801, "표준 안내 문구입니다.")  # 내 공개 댓글, 초안과 동일
        self.write_record(801, "2026-10-01", draft="표준 안내 문구입니다.")
        sim = self.collect(fake)["draft_similarity"][iso_week(TODAY)]
        self.assertEqual((sim["n"], sim["high"]), (1, 1))

    def test_low_similarity_lands_in_low_bucket(self) -> None:
        fake = FakeZendesk()
        fake.add_ticket(901, "2026-10-01T00:00:00Z")
        fake.add_comment(901, "완전히 동떨어진 다른 문장 abcdefg")
        self.write_record(901, "2026-10-01", draft="표준 안내 문구입니다 가나다라마")
        sim = self.collect(fake)["draft_similarity"][iso_week(TODAY)]
        self.assertEqual((sim["n"], sim["low"]), (1, 1))

    # ── 실패: 지어내지 않고 코드만 ──────────────────────────────────────────

    def test_no_credentials_without_http_and_without_env(self) -> None:
        saved = {k: os.environ.pop(k, None) for k in (
            "ZENDESK_SUBDOMAIN", "ZENDESK_EMAIL", "ZENDESK_API_TOKEN",
            "Zendesk_SUBDOMAIN", "Zendesk_EMAIL", "Zendesk_API",
        )}
        saved_conf = uz.ZENDESK_CONF
        uz.ZENDESK_CONF = self.root / "no-such.conf"
        try:
            self.assertEqual(uz.collect_zendesk(self.root, TODAY), {"error": "no_credentials"})
        finally:
            uz.ZENDESK_CONF = saved_conf
            for k, v in saved.items():
                if v is not None:
                    os.environ[k] = v

    def test_auth_error_maps_to_auth(self) -> None:
        fake = FakeZendesk()
        fake.status_for["/search.json"] = 401
        self.assertEqual(self.collect(fake), {"error": "auth", "stage": "search"})

    def test_http_error_carries_the_code(self) -> None:
        fake = FakeZendesk()
        fake.status_for["/search.json"] = 500
        self.assertEqual(self.collect(fake), {"error": "http_500", "stage": "search"})

    def test_network_failure_maps_to_timeout(self) -> None:
        def boom(url: str, timeout: float):
            raise urllib.error.URLError("down")
        self.assertEqual(uz.collect_zendesk(self.root, TODAY, http=boom), {"error": "timeout", "stage": "search"})

    def test_a_certificate_failure_is_not_called_a_timeout(self) -> None:
        """인증서가 없는 PC 에서 이 줄이 `timeout` 으로만 보여 원인을 찾는 데 하루가 걸렸다(2026-10-07)."""
        import ssl

        def boom(url: str, timeout: float):
            raise urllib.error.URLError(ssl.SSLCertVerificationError(1, "certificate verify failed"))
        self.assertEqual(uz.collect_zendesk(self.root, TODAY, http=boom), {"error": "cert", "stage": "search"})

    def test_unparseable_body_maps_to_parse(self) -> None:
        fake = FakeZendesk()
        fake.raw_for["/search.json"] = b"not json"
        self.assertEqual(self.collect(fake), {"error": "parse", "stage": "search"})

    # ── 캐시: 하루 한 번 ────────────────────────────────────────────────────

    def test_second_call_same_day_uses_cache(self) -> None:
        fake = FakeZendesk()
        fake.add_ticket(1001, "2026-10-01T00:00:00Z")
        self.collect(fake)
        calls_after_first = len(fake.calls)
        self.collect(fake)  # 같은 날 두 번째
        self.assertEqual(len(fake.calls), calls_after_first, "같은 날인데 다시 호출했다")

    def test_a_cache_written_before_a_key_was_added_is_not_reused(self) -> None:
        """같은 날의 캐시라도 옛 모양이면 버린다. `requester_wait_minutes` 를 더한 날, 아침에 쓴 캐시에 그 키가 없어
        미리보기가 `KeyError` 로 죽었다(2026-10-07) — 그리고 그날 보낸 값에도 새 키가 빠진다."""
        fake = FakeZendesk()
        fake.add_ticket(1002, "2026-10-01T00:00:00Z", waited={"calendar": 5, "business": 5})
        old = {"computed_at": "x", "weeks": {iso_week(TODAY): {"solved": 9}}, "draft_similarity": {}}
        self.cache.write_text(json.dumps({"date": TODAY.isoformat(), "payload": old}), encoding="utf-8")
        week = self.collect(fake)["weeks"][iso_week(TODAY)]
        self.assertEqual(week["requester_wait_minutes"]["n"], 1)
        self.assertGreater(len(fake.calls), 0)

    def test_a_new_day_recomputes(self) -> None:
        fake = FakeZendesk()
        fake.add_ticket(1101, "2026-10-01T00:00:00Z")
        self.collect(fake)
        first = len(fake.calls)
        uz.collect_zendesk(self.root, date(2026, 10, 5), http=fake)
        self.assertGreater(len(fake.calls), first, "날이 바뀌었는데 캐시를 썼다")

    def test_errors_are_not_cached(self) -> None:
        """오류는 캐시하지 않는다 (2026-10-07 유지보수자). 계정 한도(분당 400, 계정 전체가 나눠 쓴다)에 한 번 걸린 429 가
        그날 치로 캐시돼 다음 날 09:00 KST 까지 B·C·D 가 통째로 비었다. 다음 전송(6시간 뒤) 때 다시 계산한다."""
        fake = FakeZendesk()
        fake.status_for["/search.json"] = 429
        self.assertEqual(self.collect(fake), {"error": "http_429", "stage": "search"})
        self.assertFalse(self.cache.exists(), "오류를 캐시했다")
        fake.status_for.clear()
        fake.add_ticket(1401, "2026-10-01T00:00:00Z")
        self.write_record(1401, "2026-10-01")
        again = self.collect(fake)  # 같은 날 — 한도가 풀렸다
        self.assertNotIn("error", again, "같은 날인데 앞의 오류에 묶였다")
        self.assertIn(iso_week(date(2026, 10, 1)), again["weeks"])

    def test_the_error_says_which_call_failed(self) -> None:
        """2026-10-07 의 429 는 어느 호출에서 났는지 남지 않아 원인을 못 좁혔다."""
        for fragment, stage in (("/search.json", "search"), ("/tickets/show_many", "show_many")):
            with self.subTest(stage=stage):
                fake = FakeZendesk()
                fake.add_ticket(1501, "2026-10-01T00:00:00Z")
                fake.status_for[fragment] = 429
                self.assertEqual(self.collect(fake), {"error": "http_429", "stage": stage})

    def test_a_failed_comment_fetch_keeps_the_timings(self) -> None:
        """B(유사도)는 티켓마다 댓글을 읽는다. 그중 하나가 막혔다고 이미 계산한 C·D 를 버리지 않는다."""
        fake = FakeZendesk()
        fake.add_ticket(1601, "2026-10-01T00:00:00Z", reply={"calendar": 30, "business": None})
        fake.add_comment(1601, "표준 안내 문구입니다.")
        self.write_record(1601, "2026-10-01")
        fake.status_for["/comments.json"] = 429
        payload = self.collect(fake)
        week = payload["weeks"][iso_week(date(2026, 10, 1))]
        self.assertEqual((week["solved"], week["with_record"]), (1, 1))
        self.assertEqual(medians(week["reply_minutes"]["with"]), {"n": 1, "calendar": 30, "business": None})
        self.assertEqual(payload["draft_similarity"], {})
        self.assertEqual((payload["similarity_error"], payload["stage"]), ("http_429", "comments"))
        self.assertNotIn("error", payload, "전체 실패로 읽힌다")
        self.assertFalse(self.cache.exists(), "반쪽 결과를 그날 치로 캐시했다")
        self.assertIn("못 읽었다: http_429 · comments 호출에서", uz._render(payload))
        self.assertIn("solved 1", uz._render(payload))

    def test_without_my_user_id_similarity_is_skipped_not_guessed(self) -> None:
        """내 id 를 모르면 고객이 쓴 공개 댓글까지 내 답변으로 비교하게 된다. 재지 않고 그렇다고 적는다."""
        fake = FakeZendesk()
        fake.add_ticket(1701, "2026-10-01T00:00:00Z")
        fake.add_comment(1701, "고객이 쓴 글", author_id=999)
        self.write_record(1701, "2026-10-01")
        fake.status_for["/users/me"] = 500
        payload = self.collect(fake)
        self.assertIn(iso_week(date(2026, 10, 1)), payload["weeks"])
        self.assertEqual(payload["draft_similarity"], {})
        self.assertEqual((payload["similarity_error"], payload["stage"]), ("http_500", "me"))
        self.assertFalse(any("/comments.json" in call for call in fake.calls), "내 id 없이 댓글을 읽었다")

    def test_an_answer_without_my_id_also_skips_similarity(self) -> None:
        fake = FakeZendesk()
        fake.add_ticket(1801, "2026-10-01T00:00:00Z")
        fake.add_comment(1801, "고객이 쓴 글", author_id=999)
        self.write_record(1801, "2026-10-01")
        fake.me = {"user": {}}
        payload = self.collect(fake)
        self.assertEqual((payload["draft_similarity"], payload["similarity_error"], payload["stage"]), ({}, "parse", "me"))
        self.assertFalse(any("/comments.json" in call for call in fake.calls))

    # ── 식별자·안전 ─────────────────────────────────────────────────────────

    def test_result_has_no_identifiers(self) -> None:
        fake = FakeZendesk()
        fake.add_ticket(1201, "2026-10-01T00:00:00Z", reply={"calendar": 40, "business": 30})
        fake.add_comment(1201, "표준 안내 문구입니다.")
        self.write_record(1201, "2026-10-01", draft="표준 안내 문구입니다.")
        payload = self.collect(fake)
        self.assertEqual(report_usage.assert_no_identifiers({"zendesk": payload}), [])

    def test_no_ticket_numbers_in_the_result(self) -> None:
        fake = FakeZendesk()
        fake.add_ticket(1234567, "2026-10-01T00:00:00Z")
        self.write_record(1234567, "2026-10-01")
        blob = json.dumps(self.collect(fake), ensure_ascii=False)
        self.assertNotIn("1234567", blob, "티켓 번호가 결과에 들어갔다")

    # ── 시간 상한 (조율자 검토 1차) ──────────────────────────────────────────

    def test_overall_timeout_stops_similarity_work(self) -> None:
        """상한을 넘기면 B 를 더 하지 않는다. C·D 는 이미 계산됐으므로 그대로 낸다.

        users/me 호출 뒤 시간을 상한 너머로 민다 — draft_similarity 진입 시 expired."""
        fake = FakeZendesk()
        fake.add_ticket(1301, "2026-10-01T00:00:00Z")
        fake.add_comment(1301, "표준 안내 문구입니다.")
        self.write_record(1301, "2026-10-01", draft="표준 안내 문구입니다.")
        clock = FakeClock()
        fake.clock = clock
        fake.advance_on = {"/users/me": uz.TOTAL_TIMEOUT_SECONDS + 1}
        payload = uz.collect_zendesk(self.root, TODAY, http=fake, clock=clock)
        self.assertIn(iso_week(TODAY), payload["weeks"])  # C·D 는 났다
        self.assertEqual(payload["draft_similarity"], {})  # B 는 비었다

    def test_timeout_mid_search_returns_timeout_error(self) -> None:
        """검색 1페이지 뒤 예산이 다 되면 전체가 timeout 이다 — C·D 도 아직 못 냈다."""
        fake = FakeZendesk()
        fake.pages = [
            {"results": [{"id": 1, "updated_at": "2026-10-01T00:00:00Z"}],
             "next_page": f"{BASE}/search.json?page=2"},
            {"results": [{"id": 2, "updated_at": "2026-10-01T00:00:00Z"}], "next_page": None},
        ]
        clock = FakeClock()
        fake.clock = clock
        # 1페이지 응답 뒤 시간을 상한 너머로 민다 → 2페이지 _get 의 expired() 가 True.
        fake.advance_on = {"/search.json": uz.TOTAL_TIMEOUT_SECONDS + 1}
        self.assertEqual(
            uz.collect_zendesk(self.root, TODAY, http=fake, clock=clock), {"error": "timeout", "stage": "search"}
        )

    def test_per_request_timeout_never_exceeds_remaining_budget(self) -> None:
        """요청마다 타임아웃 = min(10초, 남은 예산). 남은 예산보다 큰 값을 http 에 넘기면 안 된다."""
        fake = FakeZendesk()
        fake.add_ticket(1501, "2026-10-01T00:00:00Z")
        saved = uz.TOTAL_TIMEOUT_SECONDS
        uz.TOTAL_TIMEOUT_SECONDS = 3  # 예산을 요청 상한(10초)보다 작게
        try:
            uz.collect_zendesk(self.root, TODAY, http=fake, clock=FakeClock())
        finally:
            uz.TOTAL_TIMEOUT_SECONDS = saved
        self.assertTrue(fake.timeouts, "요청이 한 번도 안 나갔다")
        self.assertTrue(all(t <= 3 for t in fake.timeouts), f"예산 초과 타임아웃: {fake.timeouts}")


class UnitTests(unittest.TestCase):
    """조율자 검토 1차에서 안 잡힌 변이 셋을 직접 겨눈다 — median·구간 경계·8주 창."""

    def test_median_of_odd_count_is_the_middle_not_the_min(self) -> None:
        """홀수 개(3개)이고 최솟값과 중앙값이 다르다. ordered[mid] → ordered[0] 로 바꾸면 깨진다."""
        self.assertEqual(uz._median([10, 20, 90]), 20)
        self.assertNotEqual(uz._median([10, 20, 90]), 10)

    def test_median_of_even_count_is_the_average_of_two_middles(self) -> None:
        self.assertEqual(uz._median([10, 20, 30, 40]), 25)

    def test_median_of_empty_is_none(self) -> None:
        self.assertIsNone(uz._median([]))

    def test_similarity_bucket_boundaries(self) -> None:
        """정확히 0.9 는 high, 정확히 0.6 은 mid. `>=` → `>` 로 바꾸면 경계가 아래 칸으로 샌다."""
        self.assertEqual(uz._similarity_bucket(0.9), "high")
        self.assertEqual(uz._similarity_bucket(0.90001), "high")
        self.assertEqual(uz._similarity_bucket(0.89999), "mid")
        self.assertEqual(uz._similarity_bucket(0.6), "mid")
        self.assertEqual(uz._similarity_bucket(0.59999), "low")
        self.assertEqual(uz._similarity_bucket(0.0), "low")

    def test_week_window_has_exactly_eight_labels_including_today(self) -> None:
        start, labels = uz._week_window(TODAY)  # 2026-10-04 (일) = 2026-W40
        self.assertEqual(len(labels), uz.WEEKS)
        self.assertEqual(len(set(labels)), uz.WEEKS, "주 라벨이 중복됐다")
        self.assertEqual(labels[-1], iso_week(TODAY), "오늘 주가 창에 없다")
        # 가장 이른 주(start)의 티켓은 들어가고, 그 전 주는 빠진다.
        self.assertEqual(labels[0], iso_week(start))
        self.assertNotIn(iso_week(start - __import__("datetime").timedelta(weeks=1)), labels)

    def test_week_window_earliest_week_in_prior_week_out(self) -> None:
        """WEEKS-1 → WEEKS-2 로 바꾸면 창이 7주가 돼 가장 이른 주가 빠진다. 그걸 집계로 확인한다."""
        start, labels = uz._week_window(TODAY)
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "tickets").mkdir()
            saved_cache = uz.CACHE
            uz.CACHE = root / "cache.json"
            fake = FakeZendesk()
            earliest = start + __import__("datetime").timedelta(days=2)  # start 주 안
            before = start - __import__("datetime").timedelta(days=2)   # 그 전 주
            fake.add_ticket(11, f"{earliest.isoformat()}T00:00:00Z")
            fake.add_ticket(12, f"{before.isoformat()}T00:00:00Z")
            try:
                weeks = uz.collect_zendesk(root, TODAY, http=fake)["weeks"]
            finally:
                uz.CACHE = saved_cache
        self.assertIn(labels[0], weeks, "가장 이른 주의 티켓이 빠졌다")
        self.assertNotIn(iso_week(before), weeks, "창 밖(그 전 주) 티켓이 들어왔다")


class PreviewCliTests(unittest.TestCase):
    """`python3 scripts/usage_zendesk.py` 는 미리 보기만 한다. 자격증명이 없으면 error 를 보여 준다."""

    def run_cli(self, env_extra: dict) -> subprocess.CompletedProcess:
        env = {k: v for k, v in os.environ.items()
               if k not in ("ZENDESK_SUBDOMAIN", "ZENDESK_EMAIL", "ZENDESK_API_TOKEN",
                            "Zendesk_SUBDOMAIN", "Zendesk_EMAIL", "Zendesk_API")}
        env.update(env_extra)
        return subprocess.run(
            [sys.executable, str(ROOT / "scripts/usage_zendesk.py")],
            cwd=ROOT, capture_output=True, text=True, check=False, env=env,
        )

    def test_preview_without_credentials_shows_no_credentials(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            result = self.run_cli({
                "ZENDESK_CONF": str(Path(tmp) / "none.conf"),
                "TIKET_ZENDESK_METRICS": str(Path(tmp) / "cache.json"),
            })
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("no_credentials", result.stdout)


if __name__ == "__main__":
    unittest.main()
