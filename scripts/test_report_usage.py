#!/usr/bin/env python3
"""report_usage.py 가 고객 식별자를 절대 내보내지 않는지 검사한다.

수집 함수를 고치다가 조용히 구멍이 나는 것을 막는다. 페이로드에 식별자가 섞이면
전송이 실패해야 한다 — 실패가 유출보다 낫다.
"""

from __future__ import annotations

import contextlib
import importlib.util
import io
import json
import tempfile
import os
import shutil
import subprocess
import sys
import time
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]

# 리터럴로 적으면 이 파일 자체가 validate_workspace 의 고객 식별자 스캔에 걸린다.
# test_validate_workspace.py 와 같은 관용구로 쪼개서 조립한다.
# 값은 문서용 예약 대역/도메인(RFC 5737, RFC 2606)이다.
DOC_EMAIL = "hong@" + "example.com"
DOC_ACCOUNT = "1234" + "56789012"
DOC_IP = "203.0" + ".113.77"

spec = importlib.util.spec_from_file_location("report_usage", ROOT / "scripts/report_usage.py")
report_usage = importlib.util.module_from_spec(spec)
spec.loader.exec_module(report_usage)


SHIPPED_DEFAULTS: dict = {}


def setUpModule() -> None:
    """**테스트가 실제 수집기로 전송하지 못하게 막는다.**

    `DEFAULT_TELEMETRY_URL` 이 생긴 뒤로 "엔드포인트 없음" 상태를 환경변수로 만들 수
    없게 됐다. 그걸 모른 채 통과하던 테스트가 실제로 프로덕션 테이블에 항목을 넣고
    있었다 (2026-09-21 발견). 기본값을 비워 그 경로를 원천 차단한다.

    원본은 `SHIPPED_DEFAULTS` 에 남긴다 — 기본값 해석을 검사하는 테스트가 **자기가
    만든 값이 아니라 모듈이 실제로 선언한 값**을 봐야 하기 때문이다.
    """
    global SHIPPED_DEFAULTS
    SHIPPED_DEFAULTS = dict(report_usage.DEFAULTS)
    # build_payload 가 Zendesk 를 읽는다(지표 B·C·D, 2026-10-04). 테스트는 이 PC 의 진짜 Zendesk 에
    # 닿으면 안 된다 — 환경변수로 끄면 하위 프로세스로 돌리는 훅 테스트까지 함께 막힌다.
    os.environ["TIKET_ZENDESK"] = "off"
    report_usage.DEFAULTS = {}


sys.path.insert(0, str(ROOT / "scripts"))
from test_check_ticket_record import COMPLETE, PRE_SCHEMA  # noqa: E402


def real(body: str) -> str:
    """고정 기록은 제목이 합성고객이라 평가로 빠진다. 실사용 기록으로 바꾼다."""
    return body.replace("합성고객", "고객사")


class LeaderViewTests(unittest.TestCase):
    """리더용 화면에 보낼 묶음과 분포 (2026-09-28). 임시 tickets/ 로만 센다."""

    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        tickets = self.root / "tickets"
        tickets.mkdir()
        records = {
            # 안전장치 문제 두 개 — 기록 수로는 1
            "900001": real(COMPLETE).replace("[x] 물어본 것", "[ ] 물어본 것")
                              .replace("  → https://example.com/pricing 2026-09-14 확인\n", ""),
            # 초안 비고 등급 없음 — 기록 1, 처리 방향 1
            "900002": real(COMPLETE).replace("```text\n안내드립니다.\n```", "```text\n\n```")
                              .replace("등급: standard\n", ""),
            "900003": real(COMPLETE),
            # 등급·산출물이 양식에 없던 때의 기록 — 분포에서 빠져야 한다
            "900004": real(PRE_SCHEMA),
        }
        for name, body in records.items():
            (tickets / f"{name}.md").write_text(body, encoding="utf-8")

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def test_categories_count_records_not_problems(self) -> None:
        categories = report_usage.collect_checks(self.root)["categories"]
        self.assertEqual({code: row["records"] for code, row in categories.items()},
                         {"safety": 1, "routing": 1, "record": 1, "lessons": 0, "format": 0})

    def test_categories_carry_the_checker_names(self) -> None:
        categories = report_usage.collect_checks(self.root)["categories"]
        name, why = report_usage.CATEGORIES["safety"]
        self.assertEqual((categories["safety"]["name"], categories["safety"]["why"]), (name, why))

    def test_summary_matches_the_checker(self) -> None:
        checks = report_usage.collect_checks(self.root)
        self.assertEqual({k: checks[k] for k in ("total", "passed", "failed", "pre_schema")},
                         {"total": 4, "passed": 1, "failed": 2, "pre_schema": 1})
        self.assertEqual(sum(checks["problems"].values()), 4)
        self.assertTrue(all("N" in label or not any(ch.isdigit() for ch in label) for label in checks["problems"]))

    def test_distributions_skip_records_written_before_the_field_existed(self) -> None:
        tickets = report_usage.collect_tickets(self.root)
        self.assertEqual(tickets["count"], 4)
        self.assertEqual(tickets["tier"], {"standard": 2, "missing": 1})
        self.assertEqual(sum(tickets["output"].values()), 3)
        self.assertEqual(sum(tickets["policy_field"].values()), 3)

    def test_payload_with_categories_passes_the_identifier_screen(self) -> None:
        payload = {"checks": report_usage.collect_checks(self.root), "tickets": report_usage.collect_tickets(self.root)}
        self.assertEqual(report_usage.assert_no_identifiers(payload), [])


class PayloadV2Tests(unittest.TestCase):
    """schema 2 (2026-09-28): 평가 제외 · 최근 창 · 발송 기록 · release."""

    TODAY = report_usage.date(2026, 9, 28)

    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        (self.root / "tickets").mkdir()

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def write(self, name: str, body: str) -> None:
        (self.root / "tickets" / f"{name}.md").write_text(body, encoding="utf-8")

    def dated(self, day: str, body: str | None = None) -> str:
        return (body or real(COMPLETE)).replace("날짜: 2026-09-25", f"날짜: {day}")

    def test_evaluation_records_are_not_usage(self) -> None:
        self.write("900001", COMPLETE.replace("[x] 물어본 것", "[ ] 물어본 것"))
        self.write("900002", real(COMPLETE))
        tickets = report_usage.collect_tickets(self.root)
        checks = report_usage.collect_checks(self.root)
        self.assertEqual((tickets["count"], tickets["evaluation_excluded"]), (1, 1))
        self.assertEqual((checks["total"], checks["categories"]["safety"]["records"]), (1, 0))

    def test_recent_windows_count_by_record_date(self) -> None:
        self.write("a", self.dated("2026-09-26", real(COMPLETE).replace("[x] 물어본 것", "[ ] 물어본 것")))
        self.write("b", self.dated("2026-09-18"))
        # 창 밖의 옛 실패 — 최근 창에 섞이면 안 된다
        self.write("c", self.dated("2026-08-01", real(COMPLETE).replace("[x] 물어본 것", "[ ] 물어본 것")))
        self.write("d", real(COMPLETE).replace("날짜: 2026-09-25\n", ""))
        self.write("e", self.dated("2026-10-05"))
        recent = report_usage.collect_recent(self.root, self.TODAY)
        self.assertEqual(recent["7"]["count"], 1)
        self.assertEqual(recent["28"]["count"], 2)
        self.assertEqual(recent["7"]["categories"]["safety"], 1)
        self.assertEqual(recent["28"]["categories"]["safety"], 1)
        self.assertEqual(recent["undated"], 2)

    def test_written_date_decides_the_window_over_the_thread_date(self) -> None:
        """2026-10-22 평가 12회 중 5회가 `날짜:` 에 스레드 날짜를 적었다. 주는 `작성일:` 로 정한다."""
        self.write("a", self.dated("2026-08-01").replace("날짜: 2026-08-01", "날짜: 2026-08-01\n작성일: 2026-09-26"))
        self.write("b", self.dated("2026-09-20").replace("날짜: 2026-09-20", "날짜: 2026-09-20\n작성일: 2026-08-01"))
        recent = report_usage.collect_recent(self.root, self.TODAY)
        self.assertEqual((recent["7"]["count"], recent["28"]["count"]), (1, 1))

    def test_window_edges(self) -> None:
        """오늘 포함 7일 = 09-22 ~ 09-28. 09-21 은 빠진다."""
        self.write("a", self.dated("2026-09-22"))
        self.write("b", self.dated("2026-09-21"))
        recent = report_usage.collect_recent(self.root, self.TODAY)
        self.assertEqual((recent["7"]["count"], recent["28"]["count"]), (1, 2))

    def test_sent_reply_is_recorded_or_empty(self) -> None:
        self.write("a", real(COMPLETE).replace("## 실제 발송\n", "## 실제 발송\n\n2026-09-26 발송함\n"))
        self.write("b", real(COMPLETE))
        self.write("c", real(COMPLETE).replace("## 실제 발송\n", ""))
        self.assertEqual(report_usage.collect_tickets(self.root)["sent"], {"recorded": 1, "empty": 2})
        self.assertEqual(report_usage.collect_recent(self.root, self.TODAY)["7"]["sent"], {"recorded": 1, "empty": 2})

    def test_the_collector_has_a_sample_of_every_key_we_send(self) -> None:
        """수집기는 이 페이로드를 그대로 DynamoDB 에 넣는다. `zendesk` 를 실은 날(v0.1.18) 그 안의 소수 하나 때문에
        저장이 `TypeError` 로 죽었고, 클라이언트는 실패를 조용히 넘겨 이틀 동안 아무도 몰랐다(2026-10-07).

        키를 더하거나 값의 모양(소수·null·빈 맵)을 바꾸면 이 목록과 함께 **수집기 저장소**
        `tiket-usage-collector/lambda/fixtures/` 에 견본을 더하고, 배포 뒤 `tools/check_ingest.py smoke` 를 돌린다."""
        self.assertEqual(set(report_usage.build_payload()), {
            "schema_version", "sent_at", "engineer", "head", "release",
            "tickets", "checks", "recent", "weekly", "zendesk", "customers"})

    def test_payload_is_schema_2_with_release_and_without_behind(self) -> None:
        payload = report_usage.build_payload()
        self.assertEqual(payload["schema_version"], 2)
        self.assertIn("release", payload)
        self.assertIn("recent", payload)
        self.assertNotIn("behind", payload)
        self.assertEqual(report_usage.assert_no_identifiers(payload), [])
        self.assertIn("최근 7일", report_usage.render(payload))


class WeeklyTests(unittest.TestCase):
    """지표 A — 작성 주(`날짜:` 의 ISO 주)별 검사 결과. 매번 지금 검사기로 다시 채점한다.

    누적 합계는 옛 기록이 영원히 섞여 주끼리 비교가 안 된다. 주로 묶어 통과율이
    주마다 오르는지 본다. 날짜 없는·미래 기록은 어느 주에도 넣지 않는다.
    """

    TODAY = report_usage.date(2026, 10, 4)  # 2026-W40

    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        (self.root / "tickets").mkdir()

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def write(self, name: str, body: str) -> None:
        (self.root / "tickets" / f"{name}.md").write_text(body, encoding="utf-8")

    def dated(self, day: str, body: str | None = None) -> str:
        return (body or real(COMPLETE)).replace("날짜: 2026-09-25", f"날짜: {day}")

    def test_records_are_grouped_by_iso_week(self) -> None:
        # 같은 ISO 주(2026-W39)의 두 기록 — 하나는 통과, 하나는 안전장치 실패
        self.write("a", self.dated("2026-09-25"))
        self.write("b", self.dated("2026-09-26", real(COMPLETE).replace("[x] 물어본 것", "[ ] 물어본 것")))
        # 다른 주(2026-W40)의 통과 기록 하나
        self.write("c", self.dated("2026-09-28"))
        weekly = report_usage.collect_weekly(self.root, self.TODAY)
        self.assertEqual(set(weekly), {"2026-W39", "2026-W40"})
        self.assertEqual(
            weekly["2026-W39"],
            {"count": 2, "passed": 1, "failed": 1, "pre_schema": 0,
             "categories": {"safety": 1, "routing": 0, "record": 0, "lessons": 0, "format": 0}},
        )
        self.assertEqual(
            weekly["2026-W40"],
            {"count": 1, "passed": 1, "failed": 0, "pre_schema": 0,
             "categories": {"safety": 0, "routing": 0, "record": 0, "lessons": 0, "format": 0}},
        )

    def test_undated_and_future_records_are_left_out(self) -> None:
        self.write("a", self.dated("2026-09-25"))
        self.write("b", real(COMPLETE).replace("날짜: 2026-09-25\n", ""))  # 날짜 없음
        self.write("c", self.dated("2026-10-19"))  # 오늘(10-04) 이후 — 미래
        weekly = report_usage.collect_weekly(self.root, self.TODAY)
        self.assertEqual(set(weekly), {"2026-W39"})
        self.assertEqual(weekly["2026-W39"]["count"], 1)

    def test_only_the_most_recent_eight_weeks_are_kept(self) -> None:
        # 오늘(2026-W40) 기준으로 W40..W33 이 최근 8주. W32 는 빠진다.
        days = {
            "2026-W40": "2026-09-28", "2026-W39": "2026-09-25", "2026-W38": "2026-09-18",
            "2026-W37": "2026-09-11", "2026-W36": "2026-09-04", "2026-W35": "2026-08-28",
            "2026-W34": "2026-08-21", "2026-W33": "2026-08-14", "2026-W32": "2026-08-07",
        }
        for i, (week, day) in enumerate(days.items()):
            self.write(f"r{i}", self.dated(day))
        weekly = report_usage.collect_weekly(self.root, self.TODAY)
        self.assertNotIn("2026-W32", weekly)
        self.assertEqual(len(weekly), 8)
        self.assertEqual(min(weekly), "2026-W33")
        self.assertEqual(max(weekly), "2026-W40")

    def test_evaluation_records_are_not_counted(self) -> None:
        # real() 을 거치지 않은 COMPLETE 는 제목이 합성고객이라 평가로 빠진다
        self.write("a", COMPLETE)  # 평가
        self.write("b", self.dated("2026-09-25"))  # 실사용
        weekly = report_usage.collect_weekly(self.root, self.TODAY)
        self.assertEqual(weekly["2026-W39"]["count"], 1)

    def test_categories_count_records_not_problems(self) -> None:
        # 한 기록에 안전장치 문제 두 개 — 묶음 수로는 1
        broken = real(COMPLETE).replace("[x] 물어본 것", "[ ] 물어본 것") \
            .replace("  → https://example.com/pricing 2026-09-14 확인\n", "")
        self.write("a", self.dated("2026-09-25", broken))
        weekly = report_usage.collect_weekly(self.root, self.TODAY)
        self.assertEqual(weekly["2026-W39"]["categories"]["safety"], 1)

    def test_preview_says_which_zendesk_call_failed_and_what_survived(self) -> None:
        """미리 보기가 "값을 싣지 않음" 만 말하면 무엇이 막혔는지 모른다 (2026-10-07 의 429)."""
        base = report_usage.build_payload()
        failed = report_usage.render({**base, "zendesk": {"error": "http_429", "stage": "search"}})
        self.assertIn("Zendesk 지표  http_429 · search 호출에서 (값을 싣지 않음)", failed)
        partial = report_usage.render({**base, "zendesk": {
            "weeks": {"2026-W40": {}}, "draft_similarity": {}, "similarity_error": "http_429", "stage": "comments"}})
        self.assertIn("Zendesk 지표  1주 · 초안 비교 못 읽음(http_429 · comments 호출에서)", partial)
        whole = report_usage.render({**base, "zendesk": {"weeks": {"2026-W40": {}}, "draft_similarity": {"2026-W40": {}}}})
        self.assertIn("Zendesk 지표  1주 · 초안 비교 1주", whole)

    def test_payload_carries_weekly_without_changing_existing_aggregates(self) -> None:
        payload = report_usage.build_payload()
        self.assertIn("weekly", payload)
        # 기존 집계는 그대로 있어야 한다
        for key in ("tickets", "checks", "recent", "customers"):
            self.assertIn(key, payload)
        self.assertEqual(report_usage.assert_no_identifiers(payload), [])

    def test_render_shows_one_line_per_week(self) -> None:
        self.write("a", self.dated("2026-09-25"))
        self.write("b", self.dated("2026-09-28"))
        weekly = report_usage.collect_weekly(self.root, self.TODAY)
        rendered = report_usage.render({**report_usage.build_payload(), "weekly": weekly})
        self.assertIn("2026-W39", rendered)
        self.assertIn("2026-W40", rendered)

    def test_nothing_but_numbers_leaves(self) -> None:
        self.write("a", self.dated("2026-09-25"))
        weekly = report_usage.collect_weekly(self.root, self.TODAY)
        self.assertEqual(report_usage.assert_no_identifiers({"weekly": weekly}), [])


class ZendeskLinkTests(unittest.TestCase):
    """지표 B·C·D 는 usage_zendesk 가 만든다. report_usage 는 싣기만 하고, 끄는 스위치를 지킨다."""

    def test_payload_carries_what_the_zendesk_collector_returns(self) -> None:
        stub = {"computed_at": "2026-10-04T05:00:00+00:00", "weeks": {}, "draft_similarity": {}}
        with mock.patch.dict(os.environ, {"TIKET_ZENDESK": ""}), \
             mock.patch.object(report_usage, "conf_value", return_value=""), \
             mock.patch("usage_zendesk.collect_zendesk", return_value=stub) as collector:
            payload = report_usage.build_payload()
        collector.assert_called_once()
        self.assertEqual(payload["zendesk"], stub)

    def test_off_switch_never_reads_zendesk(self) -> None:
        with mock.patch.dict(os.environ, {"TIKET_ZENDESK": "off"}), \
             mock.patch("usage_zendesk.collect_zendesk") as collector:
            payload = report_usage.build_payload()
        collector.assert_not_called()
        self.assertEqual(payload["zendesk"], {"error": "off"})


class CustomerLinkTests(unittest.TestCase):
    """`customers/` 가 쓰이는지 재는 세 값 (2026-10-01). 프로필 개수만으로는 "쌓였나" 만 보이고
    "이을 수 있나 · 다시 오는 고객인가 · 고객 사정이 남나" 가 안 보였다. 나가는 것은 개수뿐이다."""

    CORP = "0a1b2c3d-" + "1111-2222-3333-" + "4444aaaa6666"

    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        (self.root / "tickets").mkdir()

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def write(self, name: str, customer: str, body: str = COMPLETE) -> None:
        (self.root / "tickets" / f"{name}.md").write_text(body.replace("합성고객", customer), encoding="utf-8")

    def with_corp(self, value: str) -> str:
        return COMPLETE.replace("policy_ids: []\n", f"policy_ids: []\ncorp_id: {value}\n")

    def test_corp_id_counts_only_well_formed_values(self) -> None:
        self.write("a", "가나", self.with_corp(self.CORP))
        self.write("b", "다라", self.with_corp(""))
        self.write("c", "마바", self.with_corp("모름"))
        self.write("d", "사아")  # 칸 자체가 없다
        link = report_usage.collect_customers(self.root)
        self.assertEqual(link["corp_id"], {"filled": 1, "empty": 3})

    def test_corp_id_skips_records_written_before_the_field_existed(self) -> None:
        # 옛 기록에는 `## 교훈 후보` 절이 없다 — 절이 있으면 날짜와 상관없이 새 양식으로 본다(2026-10-22).
        old = COMPLETE.replace("날짜: 2026-09-25", "날짜: 2026-09-20").replace("## 교훈 후보\n\n- 없음\n\n", "")
        self.assertNotIn("## 교훈 후보", old)
        self.write("a", "가나", old)
        self.write("b", "가나")
        self.assertEqual(report_usage.collect_customers(self.root)["corp_id"], {"filled": 0, "empty": 1})

    def test_repeat_counts_customers_seen_more_than_once(self) -> None:
        for name, customer in (("a", "가나"), ("b", "가나"), ("c", " 가나 "), ("d", "다라"), ("e", "ABC"), ("f", "abc")):
            self.write(name, customer)
        self.write("g", "x", COMPLETE.replace("# 900001 · 합성고객 · 테스트 티켓", "# 제목만 있는 기록"))
        repeat = report_usage.collect_customers(self.root)["repeat"]
        self.assertEqual(repeat, {"customers": 3, "repeat_customers": 2, "repeat_tickets": 5, "unnamed": 1})

    def test_customer_lessons_counts_only_the_customer_kind(self) -> None:
        lessons = "- 종류: customer\n  트리거: T2\n  한 줄: 이 고객은 변경 창이 화요일뿐이다\n" \
                  "- 종류: pitfall\n  트리거: T1\n  한 줄: 파라미터 그룹은 재시작이 필요하다\n"
        self.write("a", "가나", COMPLETE.replace("- 없음", lessons))
        self.write("b", "다라")
        self.assertEqual(report_usage.collect_customers(self.root)["customer_lessons"], 1)

    def test_evaluation_records_are_left_out(self) -> None:
        self.write("a", "합성고객", self.with_corp(self.CORP))
        link = report_usage.collect_customers(self.root)
        self.assertEqual((link["corp_id"], link["repeat"]["customers"]), ({"filled": 0, "empty": 0}, 0))

    def test_nothing_but_numbers_leaves(self) -> None:
        self.write("a", "가나상사", self.with_corp(self.CORP))
        link = report_usage.collect_customers(self.root)
        blob = json.dumps(link, ensure_ascii=False)
        self.assertNotIn("가나상사", blob)
        self.assertNotIn(self.CORP, blob)
        self.assertEqual(report_usage.assert_no_identifiers({"customers": link}), [])
        self.assertIn("재방문", report_usage.render({**report_usage.build_payload(), "customers": link}))


class IdentifierGuardTests(unittest.TestCase):
    def setUp(self) -> None:
        self.payload = report_usage.build_payload()

    def test_real_payload_carries_no_identifier(self) -> None:
        self.assertEqual(report_usage.assert_no_identifiers(self.payload), [])

    def test_each_forbidden_pattern_is_caught(self) -> None:
        samples = {
            "email": DOC_EMAIL,
            "aws_account_id": DOC_ACCOUNT,
            "ip_or_cidr": DOC_IP,
            "arn": "arn:aws:iam::x:role/y",
            "customer_ref": "CUST-002",
            "contact_ref": "CONTACT-003",
            "account_ref": "ACCOUNT-004",
        }
        self.assertEqual(set(samples), set(report_usage.FORBIDDEN))
        for name, value in samples.items():
            with self.subTest(pattern=name):
                hits = report_usage.assert_no_identifiers({**self.payload, "probe": value})
                self.assertIn(name, hits)

    def test_identifier_nested_deep_is_caught(self) -> None:
        polluted = {**self.payload, "tickets": {"policy_citations": {DOC_EMAIL: 1}}}
        self.assertIn("email", report_usage.assert_no_identifiers(polluted))

    def test_payload_does_not_carry_ticket_or_customer_names(self) -> None:
        """집계만 보낸다. 어느 티켓·어느 고객인지는 페이로드에 없어야 한다."""
        blob = json.dumps(self.payload, ensure_ascii=False)
        for path in sorted((ROOT / "tickets").glob("*.md")):
            self.assertNotIn(path.stem, blob, f"티켓 식별자 유출: {path.stem}")
        for path in sorted((ROOT / "customers").glob("CUST-*")):
            self.assertNotIn(path.name, blob, f"고객 reference 유출: {path.name}")

    def test_send_refuses_without_endpoint(self) -> None:
        """엔드포인트가 없으면 조용히 성공한 척하지 않는다."""
        import os
        saved = os.environ.pop("TIKET_TELEMETRY_URL", None)
        try:
            self.assertEqual(report_usage.send(self.payload), 1)
        finally:
            if saved is not None:
                os.environ["TIKET_TELEMETRY_URL"] = saved


class SkippedSendTests(unittest.TestCase):
    """보내지 못한 것을 본인도 유지보수자도 몰랐다(2026-10-07). 자동 전송은 금지 패턴에 걸리거나 수집이 죽으면
    말없이 넘어갔고, 요청이 아예 안 나가 수집기 로그에도 없었다. 이름이 메일 꼴이면 매번 그랬다.

    건너뛴 사유만 담은 짧은 보고를 대신 보낸다 — 패턴 이름과 예외 종류까지만, 값은 싣지 않는다."""

    def attempt(self, *, payload=None, error=None, name="tester", send_result=0):
        sent: list[dict] = []
        build = mock.Mock(side_effect=error) if error else mock.Mock(return_value=payload)
        with mock.patch.object(report_usage, "build_payload", build), \
                mock.patch.object(report_usage, "engineer_name", return_value=name), \
                mock.patch.object(report_usage, "send", side_effect=lambda p, **kw: sent.append(p) or send_result):
            outcome = report_usage.attempt(timeout=1)
        return outcome, sent

    def test_a_clean_payload_goes_out_as_it_is(self) -> None:
        payload = {"schema_version": 2, "engineer": "tester", "tickets": {"count": 3}}
        self.assertEqual(self.attempt(payload=payload), ("sent", [payload]))

    def test_a_failed_send_is_told_apart_from_a_sent_one(self) -> None:
        outcome, _ = self.attempt(payload={"engineer": "tester"}, send_result=1)
        self.assertEqual(outcome, "send_failed")

    def test_a_blocked_payload_sends_only_the_reason(self) -> None:
        outcome, sent = self.attempt(payload={"engineer": "tester", "tickets": {"note": DOC_EMAIL}})
        self.assertEqual(outcome, "skipped: email")
        self.assertEqual(len(sent), 1)
        self.assertEqual(set(sent[0]), {"schema_version", "sent_at", "engineer", "head", "release", "skipped"})
        self.assertEqual((sent[0]["engineer"], sent[0]["skipped"]), ("tester", ["email"]))
        self.assertNotIn(DOC_EMAIL, json.dumps(sent[0], ensure_ascii=False))

    def test_a_reason_that_could_not_be_delivered_is_a_failed_send(self) -> None:
        """사유 보고도 못 닿았으면 수집기에는 아무것도 안 갔다. `skipped` 로 적으면 연속 실패가 0 으로 돌아가
        알림(0039)이 영영 안 뜬다(2026-10-07 검토)."""
        outcome, sent = self.attempt(payload={"engineer": "tester", "tickets": {"note": DOC_EMAIL}}, send_result=1)
        self.assertEqual((outcome, len(sent)), ("send_failed", 1))

    def test_a_name_that_is_itself_an_identifier_is_replaced_not_sent(self) -> None:
        """이름이 메일이면 그 보고도 금지 패턴에 걸린다. 같은 사람이 늘 같은 칸에 오도록 해시 앞자리로 바꾼다."""
        outcome, sent = self.attempt(payload={"engineer": DOC_EMAIL}, name=DOC_EMAIL)
        self.assertEqual(outcome, "skipped: email")
        self.assertRegex(sent[0]["engineer"], r"^이름확인필요-[0-9a-f]{8}$")
        self.assertEqual(report_usage.assert_no_identifiers(sent[0]), [])
        self.assertEqual(sent[0]["engineer"], report_usage.safe_engineer(DOC_EMAIL))
        self.assertNotEqual(sent[0]["engineer"], report_usage.safe_engineer("other@" + "example.com"))

    def test_a_crash_while_collecting_is_reported_by_its_type_only(self) -> None:
        outcome, sent = self.attempt(error=KeyError("고객사 이름"))
        self.assertEqual(outcome, "skipped: build_error:KeyError")
        self.assertEqual(sent[0]["skipped"], ["build_error:KeyError"])
        self.assertNotIn("고객사", json.dumps(sent[0], ensure_ascii=False))

    def test_a_certificate_failure_says_so_and_what_to_do(self) -> None:
        import ssl
        import urllib.error

        err = io.StringIO()
        cert = urllib.error.URLError(ssl.SSLCertVerificationError(1, "certificate verify failed"))
        # 주소가 없으면 send 가 호출 전에 돌아간다(CI 에는 기본 주소가 없다). 죽은 주소를 준다 — 호출은 가짜가 받는다.
        url = mock.patch.dict(os.environ, {"TIKET_TELEMETRY_URL": "https://localhost:1/ingest"})
        url.start()
        self.addCleanup(url.stop)
        with mock.patch.object(report_usage.https_fetch, "urlopen", side_effect=cert), contextlib.redirect_stderr(err):
            code = report_usage.send({"engineer": "tester"}, notice=io.StringIO())
        self.assertEqual(code, 1)
        self.assertIn("인증서", err.getvalue())
        with mock.patch.object(report_usage.https_fetch, "urlopen", side_effect=OSError("refused")), \
                contextlib.redirect_stderr(io.StringIO()) as other:
            report_usage.send({"engineer": "tester"}, notice=io.StringIO())
        self.assertNotIn("인증서", other.getvalue())

    def test_the_manual_run_says_to_change_the_name_when_the_name_is_the_problem(self) -> None:
        err = io.StringIO()
        with mock.patch.object(report_usage, "engineer_name", return_value=DOC_EMAIL), \
                mock.patch.object(sys, "argv", ["report_usage.py"]), contextlib.redirect_stderr(err), \
                contextlib.redirect_stdout(io.StringIO()):
            code = report_usage.main()
        self.assertEqual(code, 2)
        self.assertIn("TIKET_ENGINEER", err.getvalue())
        self.assertNotIn("수집 함수를 고쳐야", err.getvalue())


class JsonOutputTests(unittest.TestCase):
    """`--json` 의 stdout 은 기계가 읽는다. 사람용 문구가 섞이면 파이프가 깨진다."""

    def run_cli(self, *args: str) -> subprocess.CompletedProcess:
        return subprocess.run(
            [sys.executable, str(ROOT / "scripts/report_usage.py"), *args],
            cwd=ROOT, capture_output=True, text=True, check=False,
        )

    def test_json_stdout_parses_as_json(self) -> None:
        result = self.run_cli("--json")
        self.assertEqual(result.returncode, 0, result.stderr)
        payload = json.loads(result.stdout)  # 여기서 깨지면 수집기가 400 을 돌려준다
        self.assertEqual(payload["schema_version"], report_usage.SCHEMA_VERSION)

    def test_human_notice_goes_to_stderr_under_json(self) -> None:
        result = self.run_cli("--json")
        self.assertNotIn("전송하려면", result.stdout)
        self.assertIn("전송하려면", result.stderr)

    def test_default_output_keeps_the_notice_on_stdout(self) -> None:
        """사람이 보는 기본 출력에서는 안내가 그대로 보여야 한다."""
        result = self.run_cli()
        self.assertIn("전송하려면", result.stdout)


class EngineerIdentityTests(unittest.TestCase):
    """`engineer` 는 DynamoDB 의 PK 다. 비면 여러 사람이 한 칸에 섞인다."""

    def setUp(self) -> None:
        self.tempdir = tempfile.TemporaryDirectory(prefix="tiket-conf-")
        self.conf = Path(self.tempdir.name) / "tiket-usage.conf"
        self.saved_conf = report_usage.CONF
        report_usage.CONF = self.conf
        self.saved_env = {
            k: os.environ.pop(k, None)
            for k in ("TIKET_ENGINEER", "TIKET_TELEMETRY_URL", "TIKET_TELEMETRY_KEY")
        }

    def tearDown(self) -> None:
        report_usage.CONF = self.saved_conf
        for key, value in self.saved_env.items():
            os.environ.pop(key, None)
            if value is not None:
                os.environ[key] = value
        self.tempdir.cleanup()

    def test_conf_value_is_used_when_present(self) -> None:
        self.conf.write_text("TIKET_ENGINEER=maintainer\n", encoding="utf-8")
        self.assertEqual(report_usage.engineer_name(), "maintainer")

    def test_environment_overrides_the_conf_file(self) -> None:
        """환경변수는 일회성 덮어쓰기용으로 남긴다 — 이미 쓰고 있는 사람이 있다."""
        self.conf.write_text("TIKET_ENGINEER=conf-name\n", encoding="utf-8")
        os.environ["TIKET_ENGINEER"] = "env-name"
        self.assertEqual(report_usage.engineer_name(), "env-name")

    def test_falls_back_to_git_user_name(self) -> None:
        self.assertEqual(report_usage.engineer_name(), report_usage.run("git", "config", "user.name"))

    def test_never_returns_empty(self) -> None:
        """빈 값이 PK 로 들어가면 안 된다. 최소한 unknown 이어야 한다."""
        self.assertTrue(report_usage.engineer_name().strip())

    def test_manual_send_refuses_without_a_chosen_name(self) -> None:
        """2026-09-24: git user.name 대체로 보낸 한 건 때문에 같은 사람이 `maintainer-gh`·`유지보수자`
        두 PK 로 갈라졌다. 자동 전송은 이미 이름이 있어야 보낸다 — 수동 --send 도 같은 규칙.
        send 를 가로챈다. 구현이 없을 때 이 테스트가 실제 수집기로 보내면 안 된다."""
        sent: list[dict] = []
        saved_send, saved_argv = report_usage.send, sys.argv
        report_usage.send = lambda payload, notice, **_: sent.append(payload) or 0
        sys.argv = ["report_usage.py", "--send"]
        try:
            with contextlib.redirect_stdout(io.StringIO()) as out:
                code = report_usage.main()
        finally:
            report_usage.send, sys.argv = saved_send, saved_argv
        self.assertEqual(sent, [])
        self.assertNotEqual(code, 0)
        self.assertIn("TIKET_ENGINEER", out.getvalue())

    def test_manual_send_uses_the_chosen_name(self) -> None:
        self.conf.write_text("TIKET_ENGINEER=maintainer\n", encoding="utf-8")
        sent: list[dict] = []
        saved_send, saved_argv = report_usage.send, sys.argv
        report_usage.send = lambda payload, notice, **_: sent.append(payload) or 0
        sys.argv = ["report_usage.py", "--send"]
        try:
            with contextlib.redirect_stdout(io.StringIO()):
                report_usage.main()
        finally:
            report_usage.send, sys.argv = saved_send, saved_argv
        self.assertEqual([p["engineer"] for p in sent], ["maintainer"])

    def test_korean_name_survives_the_identifier_screen(self) -> None:
        """한글 실명은 금지 패턴이 아니다. 걸리면 표가 너무 넓은 것이다."""
        payload = {**report_usage.build_payload(), "engineer": "maintainer"}
        self.assertEqual(report_usage.assert_no_identifiers(payload), [])

    def test_missing_conf_file_is_not_an_error(self) -> None:
        self.assertEqual(report_usage.conf_value("TIKET_ENGINEER"), "")

    def test_endpoint_defaults_to_the_team_collector(self) -> None:
        """팀에 엔드포인트는 하나다. 전원이 손으로 붙여넣게 하면 오타가 나고
        그 사람 지표만 조용히 사라진다. URL 은 secret 이 아니다 — 이 저장소가
        private 이고, 수집기에는 애초에 키가 없다."""
        self.assertTrue(report_usage.DEFAULT_TELEMETRY_URL.startswith("https://"))
        # setUpModule 이 전송 차단을 위해 DEFAULTS 를 비웠다. **모듈이 실제로 선언한**
        # 값을 되돌려 해석 경로를 본다 — setting() 은 전송하지 않으므로 안전하다.
        saved = report_usage.DEFAULTS
        report_usage.DEFAULTS = SHIPPED_DEFAULTS
        try:
            self.assertEqual(
                report_usage.setting("TIKET_TELEMETRY_URL"),
                report_usage.DEFAULT_TELEMETRY_URL,
                "기본 엔드포인트가 모듈 선언과 다르다",
            )
        finally:
            report_usage.DEFAULTS = saved

    def test_explicit_endpoint_overrides_the_default(self) -> None:
        """기본값은 편의지 고정이 아니다. 엔드포인트가 바뀌면 conf 로 덮는다."""
        self.conf.write_text(
            "TIKET_TELEMETRY_URL=https://other.invalid/ingest\n", encoding="utf-8"
        )
        self.assertEqual(
            report_usage.setting("TIKET_TELEMETRY_URL"), "https://other.invalid/ingest"
        )

    def test_there_is_no_api_key_concept(self) -> None:
        """키를 두지 않는다 — 엔드포인트가 private 저장소에만 있어서 키를 같은 곳에
        두면 URL 과 구분되지 않는다. 수집기 README 의 "왜 API 키가 없나" 참조."""
        self.assertNotIn("TIKET_TELEMETRY_KEY", report_usage.__doc__ or "")

    def test_endpoint_can_come_from_the_conf_file(self) -> None:
        """온보딩은 셸 프로필을 건드리지 않는다. conf 로 전달해야 한다."""
        self.conf.write_text(
            "TIKET_TELEMETRY_URL=https://example.invalid/ingest\n"
            "TIKET_TELEMETRY_KEY=k\n",
            encoding="utf-8",
        )
        self.assertEqual(
            report_usage.setting("TIKET_TELEMETRY_URL"), "https://example.invalid/ingest"
        )


class IfDueTests(unittest.TestCase):
    """세션 시작 훅에서 불린다. 지켜야 할 것은 셋 — 조용하고, 안 막고, 하루 한 번."""

    @classmethod
    def setUpClass(cls) -> None:
        """스크립트만 든 임시 복제본과 거기서 뻗은 워크트리. 이 테스트 자체가 워크트리에서 돌아도 결과가 같다."""
        cls.repo_dir = tempfile.TemporaryDirectory(prefix="tiket-clone-")
        cls.clone = Path(cls.repo_dir.name) / "clone"
        cls.worktree = Path(cls.repo_dir.name) / "worktree"
        shutil.copytree(ROOT / "scripts", cls.clone / "scripts", ignore=shutil.ignore_patterns("__pycache__"))
        git = ["git", "-C", str(cls.clone), "-c", "user.name=t", "-c", "user.email=none", "-c", "commit.gpgsign=false"]
        for args in (["init", "-q"], ["add", "-A"], ["commit", "-q", "-m", "x"],
                     ["worktree", "add", "-q", str(cls.worktree)]):
            subprocess.run(git + args, check=True, capture_output=True)

    @classmethod
    def tearDownClass(cls) -> None:
        cls.repo_dir.cleanup()

    def setUp(self) -> None:
        self.tempdir = tempfile.TemporaryDirectory(prefix="tiket-stamp-")
        self.stamp = Path(self.tempdir.name) / "tiket-usage-sent"
        self.conf = Path(self.tempdir.name) / "tiket-usage.conf"
        # 별도 프로세스라 setUpModule 의 가드가 닿지 않는다. 죽은 주소를 기본으로 준다.
        self.env = {
            **os.environ,
            "TIKET_TELEMETRY_URL": "https://localhost:1/ingest",
            "TIKET_USAGE_STAMP": str(self.stamp),
            "TIKET_USAGE_CONF": str(self.conf),
            # 여기를 ""로 두면 setting() 이 기본값(운영 수집기)으로 넘어간다. 동의 없이도
            # 보내게 된 뒤(2026-09-29)로는 인자 없는 run_if_due() 가 실제로 전송한다.
            "TIKET_ENGINEER": "",
            # --if-due 는 교훈 후보(report_lessons.py)도 함께 보낸다. 그쪽 기본값은 이 프로세스
            # 밖에서 막을 수 없으므로 죽은 주소를 명시한다 — 실제 tickets/ 가 운영 테이블로 가면 안 된다.
            "TIKET_LESSONS_URL": "https://localhost:1/candidates",
        }

    def tearDown(self) -> None:
        self.tempdir.cleanup()

    def run_if_due(self, root: Path | None = None, **extra) -> subprocess.CompletedProcess:
        root = root or self.clone
        return subprocess.run(
            [sys.executable, str(root / "scripts/report_usage.py"), "--if-due"],
            cwd=root, capture_output=True, text=True, check=False, env={**self.env, **extra},
        )

    def test_a_linked_worktree_does_not_send(self) -> None:
        """워크트리에는 `tickets/` 가 없다. 거기서 보내면 그 사람의 마지막 행이 "티켓 0건" 이 된다
        (2026-10-04 실제로 그랬다). 스탬프도 찍지 않는다 — 원래 폴더의 다음 전송을 미루지 않는다."""
        result = self.run_if_due(self.worktree)
        self.assertEqual((result.returncode, result.stdout), (0, ""))
        self.assertFalse(self.stamp.exists(), "워크트리에서 전송을 시도했다")

    def test_says_nothing_on_stdout(self) -> None:
        """훅의 stdout 이 세션에 섞이면 안 된다. freshness 가 겪은 문제다."""
        self.assertEqual(self.run_if_due().stdout, "")

    def test_sends_without_onboarding(self) -> None:
        """**기본 켜짐** (2026-09-29). conf 가 없어도 보낸다 — pull 만 했거나 AI 로 온보딩한
        동료가 조용히 빠졌다. 끄는 것만 본인이 conf 에 적는다."""
        self.assertFalse(self.conf.exists())
        result = self.run_if_due()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(self.stamp.exists(), "conf 가 없다고 보내지 않았다")

    def test_default_env_never_points_at_the_real_collector(self) -> None:
        """인자 없는 run_if_due() 가 운영 테이블에 닿으면 안 된다."""
        self.assertTrue(self.env["TIKET_TELEMETRY_URL"].startswith("https://localhost:"))
        self.assertTrue(self.env["TIKET_LESSONS_URL"].startswith("https://localhost:"))

    def test_the_last_attempt_is_written_down_and_shown_in_the_preview(self) -> None:
        """자동 전송은 조용하다. 무슨 일이 있었는지는 다음에 미리보기를 돌린 사람이 본다."""
        self.run_if_due()
        status = json.loads(Path(str(self.stamp) + "-status").read_text(encoding="utf-8"))
        self.assertEqual(status["outcome"], "send_failed")  # 죽은 주소
        self.assertRegex(status["at"], r"^\d{4}-\d\d-\d\dT")
        preview = subprocess.run([sys.executable, str(self.clone / "scripts/report_usage.py")], cwd=self.clone,
                                 capture_output=True, text=True, check=False, env=self.env)
        self.assertIn("마지막 자동 전송", preview.stdout)
        self.assertIn("send_failed", preview.stdout)

    def test_the_third_failure_in_a_row_speaks_up_once_per_attempt(self) -> None:
        """한두 번은 망이 나빴을 수 있다 — 조용히 넘긴다. 세 번 연속이면 그 PC 는 못 보내는 것이다.
        동료 한 명이 그 상태로 며칠을 보냈고 본인도 유지보수자도 몰랐다(2026-10-07). 에이전트에게 알리라고 말한다.
        고치라고는 하지 않는다 — 인증서 검증을 끄거나 프록시를 바꾸는 쪽으로 가면 안 된다."""
        outputs = []
        for _ in range(3):
            outputs.append(self.run_if_due().stdout)
            self.stamp.unlink()  # 6시간이 지난 것으로 친다
        self.assertEqual(outputs[:2], ["", ""])
        self.assertIn("3번 연속", outputs[2])
        self.assertIn("python3 scripts/report_usage.py --diagnose", outputs[2])
        self.assertIn("바꾸지 않는다", outputs[2])
        status = json.loads(Path(str(self.stamp) + "-status").read_text(encoding="utf-8"))
        self.assertEqual(status["failures"], 3)

    def test_a_success_clears_the_count(self) -> None:
        status = Path(self.tempdir.name) / "status"
        with mock.patch.object(report_usage, "STATUS", status):
            self.assertEqual([report_usage.write_status(o) for o in ("send_failed", "send_failed", "sent", "send_failed")],
                             [1, 2, 0, 1])
            self.assertEqual(report_usage.write_status("skipped: email"), 0)  # 수집기에는 닿았다

    def test_an_attempt_that_never_finished_counts_as_a_failure(self) -> None:
        """훅이 시간 제한에 죽으면 끝난 뒤에 쓰는 기록은 남지 않는다. 시작할 때 적어 두고, 다음 시도가 그것을 실패로 센다."""
        status = Path(self.tempdir.name) / "status"
        with mock.patch.object(report_usage, "STATUS", status):
            self.assertEqual([report_usage.begin_attempt() for _ in range(4)], [0, 1, 2, 3])
            self.assertEqual(json.loads(status.read_text(encoding="utf-8"))["outcome"], "started")
            self.assertEqual(report_usage.write_status("send_failed"), 4)
            self.assertEqual(report_usage.begin_attempt(), 4)  # 끝난 시도는 다시 세지 않는다
            self.assertEqual(report_usage.write_status("sent"), 0)
            self.assertIn("끝나지 않았다", (report_usage.begin_attempt(), report_usage.last_status())[1])

    def run_in_process(self, *, attempt, lessons="none") -> str:
        out = io.StringIO()
        with mock.patch.object(report_usage, "STAMP", self.stamp), \
                mock.patch.object(report_usage, "STATUS", Path(str(self.stamp) + "-status")), \
                mock.patch.object(report_usage, "setting", return_value=""), \
                mock.patch.object(report_usage, "is_linked_worktree", return_value=False), \
                mock.patch.object(report_usage, "attempt", attempt), \
                mock.patch("report_lessons.send_quietly", return_value=lessons), \
                contextlib.redirect_stdout(out):
            try:
                report_usage.run_if_due()
            except KeyboardInterrupt:
                pass
        return out.getvalue()

    def test_a_killed_hook_leaves_the_stamp_and_speaks_up_the_fourth_time(self) -> None:
        """죽은 시도가 스탬프를 못 찍으면 매 세션 다시 죽는다 — 세션 시작만 느려진다. 시작할 때 찍는다."""
        killed = mock.Mock(side_effect=KeyboardInterrupt)
        outputs = []
        for _ in range(4):
            outputs.append(self.run_in_process(attempt=killed))
            self.assertTrue(self.stamp.exists(), "죽은 시도가 스탬프를 남기지 않았다")
            self.stamp.unlink()
        self.assertEqual(outputs[:3], ["", "", ""])
        self.assertIn("3번 연속", outputs[3])
        self.assertEqual(outputs[3].count("[tiket]"), 1)
        # 이번에는 끝까지 갔지만 못 보냈다 — 시작할 때 이미 말했으면 끝나고 또 말하지 않는다.
        self.assertEqual(self.run_in_process(attempt=mock.Mock(return_value="send_failed")).count("[tiket]"), 1)

    def test_the_lessons_outcome_is_written_down_and_a_failure_rides_the_next_payload(self) -> None:
        """교훈 후보 전송은 실패해도 흔적이 어디에도 없었다(2026-10-07 검토). 상태 파일에 남기고, 실패는 다음 지표에 실어
        유지보수자가 본다 — 본인이 고칠 수 있는 일이 아니다."""
        status = Path(str(self.stamp) + "-status")
        self.run_in_process(attempt=mock.Mock(return_value="sent"), lessons="failed:HTTPError 400")
        self.assertEqual(json.loads(status.read_text(encoding="utf-8"))["lessons"], "failed:HTTPError 400")
        with mock.patch.object(report_usage, "STATUS", status):
            self.assertEqual(report_usage.hook_health(), {"lessons_status": "failed:HTTPError 400"})
            self.assertIn("failed:HTTPError 400", report_usage.last_status())
            self.assertEqual(report_usage.build_payload()["lessons_status"], "failed:HTTPError 400")
            self.assertEqual(report_usage.assert_no_identifiers(report_usage.hook_health()), [])
        self.stamp.unlink()
        self.run_in_process(attempt=mock.Mock(return_value="sent"), lessons="sent 2")
        with mock.patch.object(report_usage, "STATUS", status):
            self.assertEqual(report_usage.hook_health(), {})
            self.assertNotIn("lessons_status", report_usage.build_payload())

    def test_diagnose_prints_everything_the_maintainer_needs_and_no_secret(self) -> None:
        """동료에게 명령을 세 번 부탁했다(2026-10-07). 한 번에 다 나오게 한다. 주소·프록시 값·토큰은 찍지 않는다."""
        result = subprocess.run(
            [sys.executable, str(self.clone / "scripts/report_usage.py"), "--diagnose"], cwd=self.clone,
            capture_output=True, text=True, check=False,
            env={**self.env, "TIKET_ENGINEER": "tester", "HTTPS_PROXY": "http://user:hunter2@localhost:1",
                 "TIKET_DIAGNOSE_REFERENCE_URL": "https://localhost:1/"})
        out = result.stdout + result.stderr
        self.assertEqual(result.returncode, 0, out)
        for label in ("python ", "version ", "telemetry ", "proxy env ", "ca file ", "collector FAIL", "reference FAIL",
                      "마지막 자동 전송", "send exit 1"):
            self.assertIn(label, out)
        self.assertIn("HTTPS_PROXY", out)
        for secret in ("hunter2", "localhost:1/ingest"):
            self.assertNotIn(secret, out)

    def test_an_explicit_off_switch_stops_sending(self) -> None:
        """끄는 방법이 이름을 지우는 것이면 안 된다. 분명한 스위치를 둔다."""
        self.conf.write_text("TIKET_ENGINEER=tester\nTIKET_TELEMETRY=off\n", encoding="utf-8")
        self.run_if_due()
        self.assertFalse(self.stamp.exists(), "off 인데 전송을 시도했다")

    def test_sends_after_onboarding(self) -> None:
        self.conf.write_text("TIKET_ENGINEER=tester\n", encoding="utf-8")
        result = self.run_if_due(TIKET_TELEMETRY_URL="https://localhost:1/ingest")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(self.stamp.exists(), "고지를 봤는데 시도하지 않았다")

    def age_stamp(self, hours: float) -> None:
        self.stamp.write_text("x", encoding="utf-8")
        then = time.time() - hours * 3600
        os.utime(self.stamp, (then, then))

    def test_resends_six_hours_after_the_last_attempt(self) -> None:
        """하루에 세션을 한 번만 여는 사람이 많다. 24시간이면 오후에 보낸 사람이 다음 날
        오전 세션에서 빠진다. 6시간이 지났으면 다시 보낸다 (2026-09-29)."""
        self.conf.write_text("TIKET_ENGINEER=tester\n", encoding="utf-8")
        self.age_stamp(6.1)
        before = self.stamp.stat().st_mtime
        self.run_if_due(TIKET_TELEMETRY_URL="https://localhost:1/ingest")
        self.assertGreater(self.stamp.stat().st_mtime, before, "6시간이 지났는데 보내지 않았다")

    def test_does_not_resend_within_six_hours(self) -> None:
        self.conf.write_text("TIKET_ENGINEER=tester\n", encoding="utf-8")
        self.age_stamp(5.9)
        before = self.stamp.stat().st_mtime
        self.run_if_due(TIKET_TELEMETRY_URL="https://localhost:1/ingest")
        self.assertEqual(self.stamp.stat().st_mtime, before, "6시간 안에 다시 보냈다")

    def test_a_fresh_stamp_short_circuits(self) -> None:
        """스탬프가 최근이면 아무 일도 하지 않는다."""
        self.stamp.write_text("x", encoding="utf-8")
        result = self.run_if_due()
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "")

    def test_stamp_is_written_after_an_attempt(self) -> None:
        """시도했으면 찍는다. 네트워크가 종일 죽은 날 매 세션 재시도하지 않는다 —
        지표는 부수적인 일이고, 세션 시작을 늦추는 쪽이 더 나쁘다."""
        self.conf.write_text("TIKET_ENGINEER=tester\n", encoding="utf-8")
        self.assertFalse(self.stamp.exists())
        self.run_if_due(TIKET_TELEMETRY_URL="https://localhost:1/ingest")
        self.assertTrue(self.stamp.exists(), "전송을 시도했는데 스탬프가 없다")

    def test_a_dead_endpoint_says_nothing_on_stderr_either(self) -> None:
        """Kiro IDE 는 stdout 이 비면 stderr 를 에이전트 맥락에 넣는다(IDE 1.1.14 번들).
        훅 모드는 실패해도 아무 말도 하지 않는다 — 네트워크가 나쁜 날 AI 에게 섞였다."""
        self.conf.write_text("TIKET_ENGINEER=tester\n", encoding="utf-8")
        result = self.run_if_due(TIKET_TELEMETRY_URL="https://localhost:1/ingest")
        self.assertEqual(result.stderr, "")
        self.assertEqual(result.stdout, "")

    def test_a_dead_endpoint_does_not_fail_the_session(self) -> None:
        self.conf.write_text("TIKET_ENGINEER=tester\n", encoding="utf-8")
        result = self.run_if_due(TIKET_TELEMETRY_URL="https://localhost:1/ingest")
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_hook_timeout_is_generous_but_fits_every_host(self) -> None:
        """3초는 느린 망에서 조용히 실패했다 — 실패해도 스탬프가 찍혀 그날 지표가 빠진다.
        지표와 교훈 후보 두 번의 전송이 가장 짧은 호스트 기본 제한(Kiro 60초, kiro.dev/docs/hooks,
        2026-09-29 확인)의 절반 안에 들어가야 한다. 나머지는 업데이트 몫이다."""
        self.assertGreaterEqual(report_usage.HOOK_TIMEOUT_SECONDS, 10)
        self.assertLessEqual(report_usage.HOOK_TIMEOUT_SECONDS * 2, 30)


if __name__ == "__main__":
    unittest.main()
