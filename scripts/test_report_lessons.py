#!/usr/bin/env python3
"""report_lessons.py 가 **보낼 것만 보내는지** 본다.

교훈 후보는 고객 맥락을 담는다(0026). 그래서 틀리면 비싼 쪽은 두 가지다 —
합성·평가 기록이 팀 후보에 섞이는 것, 그리고 비밀값이 나가는 것. 둘 다 여기서 막는다.

**어떤 테스트도 실제 수집기에 닿지 않는다.** setUpModule 이 기본 URL 을 비운다
(test_report_usage.py 가 2026-09-21 에 프로덕션 테이블에 쓰고 있던 것을 발견한 뒤의 관용구).
"""

from __future__ import annotations

import importlib.util
import os
import subprocess
import sys
import tempfile
import unittest
import urllib.error
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))

spec = importlib.util.spec_from_file_location("report_lessons", ROOT / "scripts/report_lessons.py")
report_lessons = importlib.util.module_from_spec(spec)
spec.loader.exec_module(report_lessons)

SHIPPED_URL = ""
CORP = "92c6b5c3-ae30-4ab5-a763-6f151f4ba9be"


def setUpModule() -> None:
    global SHIPPED_URL
    SHIPPED_URL = report_lessons.DEFAULT_LESSONS_URL
    report_lessons.DEFAULT_LESSONS_URL = ""


def record(lessons: str, title: str = "# 100012 · 어떤고객 · SP 구매 문의",
           extra_header: str = "", corp: str = CORP) -> str:
    return f"""{title}

상태: 진행중
날짜: 2026-09-25
corp_id: {corp}
{extra_header}
## 물어본 것

1. 구매 후 확인 방법 — 콘솔 조회 권한이 없다

## 확인한 것

- [확인] Inventory 는 빌링 플랫폼에 있다
  → https://example.com

## 교훈 후보

{lessons}
"""


LESSON = """- 종류: pitfall
  트리거: T2, T1
  한 줄: 고객이 콘솔 권한이 없어 공식 문서 경로가 통하지 않는다
  근거: 물어본 것 1번"""


class CollectTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tempdir = tempfile.TemporaryDirectory(prefix="tiket-lessons-")
        self.root = Path(self.tempdir.name)
        (self.root / "tickets").mkdir()

    def tearDown(self) -> None:
        self.tempdir.cleanup()

    def write(self, name: str, text: str) -> None:
        (self.root / "tickets" / f"{name}.md").write_text(text, encoding="utf-8")

    def collect(self) -> list[dict]:
        return report_lessons.collect_candidates(self.root)

    def test_candidate_carries_what_the_reviewer_needs(self) -> None:
        self.write("100012", record(LESSON))
        [item] = self.collect()
        self.assertEqual(item["ticket_ref"], "100012")
        self.assertEqual(item["corp_id"], CORP)
        self.assertEqual(item["kind"], "pitfall")
        self.assertEqual(item["trigger"], ["T1", "T2"])
        self.assertEqual(item["summary"], "고객이 콘솔 권한이 없어 공식 문서 경로가 통하지 않는다")

    def test_evidence_carries_the_question_so_the_reviewer_can_judge(self) -> None:
        """승인자는 동료 PC 의 기록을 못 본다. 근거 위치만 보내면 판단할 수 없다."""
        self.write("100012", record(LESSON))
        [item] = self.collect()
        self.assertIn("물어본 것 1번", item["evidence"])
        self.assertIn("콘솔 조회 권한이 없다", item["evidence"])
        self.assertIn("Inventory 는 빌링 플랫폼에 있다", item["evidence"])

    def test_evidence_is_capped(self) -> None:
        self.write("100012", record(LESSON).replace("1. 구매 후", "1. " + "가" * 9000))
        [item] = self.collect()
        self.assertLessEqual(len(item["evidence"]), report_lessons.MAX_EVIDENCE)

    def test_pitfall_carries_its_source_and_observed_date_for_the_reviewer(self) -> None:
        """승인자가 한 줄만 보고 카드를 쓰지 않게, 기록의 `출처:`·`관측일:` 을 그대로 싣는다 (2026-10-22)."""
        lesson = LESSON + "\n  출처: https://docs.aws.amazon.com/x.html\n  관측일: 2026-10-20"
        self.write("100012", record(lesson))
        [item] = self.collect()
        self.assertEqual(item["source"], "https://docs.aws.amazon.com/x.html")
        self.assertEqual(item["observed_on"], "2026-10-20")

    def test_seen_places_are_not_sent_to_the_server(self) -> None:
        """`확인한 곳:` 은 수집기 계약에 없다. 기록 안에서 검사기만 읽는다."""
        marker = "SEEN-PLACES-MARKER"
        self.write("100012", record(LESSON + f"\n  확인한 곳: pitfalls/ 목록, grep {marker} pitfalls/ — 해당 없음"))
        [item] = self.collect()
        self.assertNotIn(marker, str(item))
        self.assertNotIn("확인한 곳", str(item))

    def test_missing_or_malformed_source_lines_are_left_out_not_guessed(self) -> None:
        self.write("100012", record(LESSON))
        self.write("100013", record(LESSON + "\n  관측일: 10월 20일"))
        for item in self.collect():
            self.assertNotIn("source", item)
            self.assertNotIn("observed_on", item)

    def test_miss_carries_the_rule_it_broke_and_no_provenance(self) -> None:
        (self.root / "policy").mkdir()
        (self.root / "policy/_routing.md").write_text("x\n", encoding="utf-8")
        miss = LESSON.replace("종류: pitfall", "종류: miss") + "\n  막을 규칙: `policy/_routing.md`\n  제안 위치: playbooks/x.md"
        self.write("100012", record(miss))
        [item] = self.collect()
        self.assertEqual(item["kind"], "miss")
        self.assertEqual(item["rule"], "policy/_routing.md")
        self.assertNotIn("proposed_location", item)
        self.assertNotIn("source", item)

    def test_other_kinds_carry_the_proposed_location_only_when_given(self) -> None:
        playbook = LESSON.replace("종류: pitfall", "종류: playbook")
        self.write("100012", record(playbook + "\n  제안 위치: " + "가" * 300))
        self.write("100013", record(playbook))
        first, second = self.collect()
        self.assertEqual(first["proposed_location"], "가" * 200)
        self.assertNotIn("rule", first)
        self.assertNotIn("proposed_location", second)

    def test_miss_with_a_rule_file_missing_in_this_repository_is_not_sent(self) -> None:
        miss = LESSON.replace("종류: pitfall", "종류: miss") + "\n  막을 규칙: policy/_routing.md"
        self.write("100012", record(miss))
        self.assertEqual(self.collect(), [])

    def test_none_sends_nothing(self) -> None:
        self.write("100012", record("- 없음"))
        self.assertEqual(self.collect(), [])

    def test_reobservation_is_sent_as_its_own_kind(self) -> None:
        """실제 사례 파일에 기대지 않는다 — 사례는 지워지고 바뀐다(2026-09-30 에 전부 지웠다).
        재관측 대상은 넘겨받은 root 에서 찾는다."""
        (self.root / "pitfalls").mkdir()
        (self.root / "pitfalls/probe-trap.md").write_text("x\n", encoding="utf-8")
        self.write("EMAIL-1", record("- 재관측: pitfalls/probe-trap.md"))
        [item] = self.collect()
        self.assertEqual(item["kind"], "reobserved")
        self.assertEqual(item["target"], "pitfalls/probe-trap.md")

    def test_record_without_the_section_is_skipped(self) -> None:
        """옛 기록은 소급 전송하지 않는다."""
        self.write("100003", record(LESSON).split("## 교훈 후보")[0])
        self.assertEqual(self.collect(), [])

    def test_synthetic_customer_records_are_skipped(self) -> None:
        """평가 케이스는 전부 고객을 '합성고객' 으로 준다. 팀 후보에 섞이면 안 된다."""
        self.write("900101", record(LESSON, title="# 900101 · 합성고객 · RDS 변경"))
        self.write("LOCAL-1", record(LESSON, title="# LOCAL-1 · 합성고객(신규·미식별) · 점검"))
        self.assertEqual(self.collect(), [])

    def test_synthetic_number_with_a_real_thread_is_not_skipped(self) -> None:
        """900111 은 번호만 합성이고 스레드는 실제다. 번호로 가르면 틀린다."""
        self.write("900111", record(LESSON, title="# 900111 · 실제고객 · 위수탁 점검"))
        self.assertEqual(len(self.collect()), 1)

    def test_mentioning_the_synthetic_name_in_the_body_is_not_skipped(self) -> None:
        """가르는 것은 제목의 고객명이다. 실제 기록 본문이 평가를 언급할 수 있다."""
        self.write("100012", record(LESSON).replace("1. 구매 후", "1. (EVAL 의 합성고객 건과 비슷) 구매 후"))
        self.assertEqual(len(self.collect()), 1)

    def test_explicit_evaluation_marker_is_skipped(self) -> None:
        self.write("100012", record(LESSON, extra_header="평가: EVAL-005\n"))
        self.assertEqual(self.collect(), [])

    def test_malformed_section_is_not_guessed_at(self) -> None:
        """검사기가 FAIL 을 내는 기록이다. 추측해서 보내지 않는다."""
        self.write("100012", record(LESSON.replace("종류: pitfall", "종류: 기타")))
        self.assertEqual(self.collect(), [])

    def test_missing_or_bad_corp_id_is_sent_as_null(self) -> None:
        for corp in ("", "모름", "어떤고객"):
            with self.subTest(corp=corp):
                self.write("100012", record(LESSON, corp=corp))
                [item] = self.collect()
                self.assertIsNone(item["corp_id"])

    def test_empty_corp_id_does_not_borrow_the_next_line(self) -> None:
        """템플릿은 `corp_id:` 를 빈 값으로 둔다. 다음 줄이 ID 처럼 생겨도 가져오면 안 된다."""
        text = record(LESSON, corp="").replace("corp_id: \n", "corp_id:\nWUysHwWnYWsAAAFjmavzCI_0\n")
        self.write("100012", text)
        [item] = self.collect()
        self.assertIsNone(item["corp_id"])

    def test_candidate_with_a_secret_is_held_back_on_this_machine(self) -> None:
        """수집기도 막지만, 애초에 장비를 떠나지 않는 편이 낫다."""
        leaked = LESSON.replace("근거: 물어본 것 1번", "근거: 키 AKIA" + "ABCDEFGHIJKLMNOP")
        self.write("100012", record(leaked))
        self.assertEqual(self.collect(), [])

    def test_secret_table_matches_the_collector(self) -> None:
        """복제인 것을 알고 한다 — 수집기가 이 코드를 import 할 수 없다. 이름으로 대조한다."""
        self.assertEqual(set(report_lessons.SECRETS), {
            "aws_access_key_id", "private_key", "aws_secret_assignment",
            "aws_session_token_assignment", "slack_token", "github_token",
            "bearer_token", "password_assignment",
        })


class PayloadTests(unittest.TestCase):
    def test_batches_respect_the_collector_limit(self) -> None:
        items = [{"ticket_ref": str(n)} for n in range(report_lessons.MAX_CANDIDATES * 2 + 1)]
        batches = report_lessons.batches(items)
        self.assertEqual([len(b) for b in batches], [report_lessons.MAX_CANDIDATES] * 2 + [1])

    def test_payload_shape(self) -> None:
        payload = report_lessons.build_payload([{"ticket_ref": "1"}], engineer="tester")
        self.assertEqual(payload["schema_version"], 1)
        self.assertEqual(payload["engineer"], "tester")
        self.assertEqual(payload["candidates"], [{"ticket_ref": "1"}])
        self.assertTrue(payload["sent_at"])

    def test_default_url_points_at_the_candidates_route(self) -> None:
        self.assertTrue(SHIPPED_URL.endswith("/candidates"), SHIPPED_URL)


class SendQuietlyTests(unittest.TestCase):
    """세션 시작 훅에서 불린다. 조용하고, 안 막고, 동의한 사람만."""

    def setUp(self) -> None:
        self.tempdir = tempfile.TemporaryDirectory(prefix="tiket-lessons-")
        self.root = Path(self.tempdir.name)
        (self.root / "tickets").mkdir()
        (self.root / "tickets/100012.md").write_text(record(LESSON), encoding="utf-8")
        self.sent: list[dict] = []

    def tearDown(self) -> None:
        self.tempdir.cleanup()

    def run_quietly(self, **settings: str) -> None:
        values = {"TIKET_ENGINEER": "tester", "TIKET_LESSONS_URL": "https://localhost:1/candidates",
                  **settings}
        with mock.patch.object(report_lessons, "setting", side_effect=lambda n: values.get(n, "")), \
             mock.patch.object(report_lessons, "engineer_name",
                               side_effect=lambda: values.get("TIKET_ENGINEER") or "git-user"), \
             mock.patch.object(report_lessons, "post", side_effect=lambda url, p, t: self.sent.append(p)):
            report_lessons.send_quietly(self.root, timeout=1)

    def test_sends_after_onboarding(self) -> None:
        self.run_quietly()
        self.assertEqual(len(self.sent), 1)
        self.assertEqual(self.sent[0]["engineer"], "tester")

    def test_sends_without_onboarding_under_the_git_name(self) -> None:
        """기본 켜짐 (2026-09-29). 이름이 없으면 사용 지표와 같이 git user.name 으로 보낸다."""
        self.run_quietly(TIKET_ENGINEER="")
        self.assertEqual(len(self.sent), 1)
        self.assertEqual(self.sent[0]["engineer"], "git-user")

    def test_lessons_have_their_own_off_switch(self) -> None:
        """0026 B안 — 알리고 기본 켜짐. 끄는 방법이 한 줄이어야 한다."""
        self.run_quietly(TIKET_LESSONS="off")
        self.assertEqual(self.sent, [])

    def test_telemetry_off_also_stops_lessons(self) -> None:
        """사용 지표를 끈 사람은 이것도 원하지 않았다고 본다."""
        self.run_quietly(TIKET_TELEMETRY="off")
        self.assertEqual(self.sent, [])

    def test_nothing_to_send_makes_no_request(self) -> None:
        (self.root / "tickets/100012.md").write_text(record("- 없음"), encoding="utf-8")
        self.run_quietly()
        self.assertEqual(self.sent, [])

    def test_no_url_makes_no_request(self) -> None:
        self.run_quietly(TIKET_LESSONS_URL="")
        self.assertEqual(self.sent, [])

    def test_it_says_how_it_ended_without_any_content(self) -> None:
        """조용하되 결과는 돌려준다 — 호출자(report_usage)가 상태 파일에 적는다. 예외 문구에는 후보 내용이 섞일 수
        있어 종류와 HTTP 상태까지만."""
        values = {"TIKET_ENGINEER": "tester", "TIKET_LESSONS_URL": "https://localhost:1/candidates"}

        def outcome(post=None, **settings) -> str:
            post = post or (lambda url, p, t: None)
            with mock.patch.object(report_lessons, "setting", side_effect=lambda n: {**values, **settings}.get(n, "")), \
                 mock.patch.object(report_lessons, "engineer_name", return_value="tester"), \
                 mock.patch.object(report_lessons, "post", side_effect=post):
                return report_lessons.send_quietly(self.root, timeout=1)

        def rejected(url, payload, timeout):
            raise urllib.error.HTTPError(url, 400, "summary: " + LESSON, None, None)

        self.assertEqual(outcome(), "sent 1")
        self.assertEqual(outcome(TIKET_LESSONS="off"), "off")
        self.assertEqual(outcome(post=rejected), "failed:HTTPError 400")
        self.assertEqual(outcome(post=mock.Mock(side_effect=OSError("secret path"))), "failed:OSError")
        (self.root / "tickets/100012.md").write_text(record("- 없음"), encoding="utf-8")
        self.assertEqual(outcome(), "none")

    def test_any_failure_is_swallowed(self) -> None:
        """동의·URL 이 다 있어서 수집까지 실제로 가야 한다. 일찍 끝나면 아무것도 시험하지 않는다."""
        values = {"TIKET_ENGINEER": "tester", "TIKET_LESSONS_URL": "https://localhost:1/candidates"}
        boom = mock.Mock(side_effect=RuntimeError("boom"))
        with mock.patch.object(report_lessons, "setting", side_effect=lambda n: values.get(n, "")), \
             mock.patch.object(report_lessons, "collect_candidates", boom):
            report_lessons.send_quietly(self.root, timeout=1)  # 예외가 나오면 실패다
        boom.assert_called_once()


class HookIntegrationTests(unittest.TestCase):
    """report_usage.py --if-due 가 후보도 함께 보낸다. 실서버에 닿지 않게 두 URL 모두 죽은 주소."""

    def test_usage_hook_calls_lessons_and_stays_silent(self) -> None:
        with tempfile.TemporaryDirectory(prefix="tiket-hook-") as tempdir:
            conf = Path(tempdir) / "tiket-usage.conf"
            conf.write_text("TIKET_ENGINEER=tester\n", encoding="utf-8")
            marker = Path(tempdir) / "lessons-called"
            env = {
                **os.environ,
                "TIKET_USAGE_CONF": str(conf),
                "TIKET_USAGE_STAMP": str(Path(tempdir) / "stamp"),
                "TIKET_TELEMETRY_URL": "https://localhost:1/ingest",
                "TIKET_LESSONS_URL": "https://localhost:1/candidates",
                "TIKET_LESSONS_TRACE": str(marker),
                "TIKET_ZENDESK": "off",  # 진짜 Zendesk 에 닿지 않는다
            }
            result = subprocess.run(
                [sys.executable, str(ROOT / "scripts/report_usage.py"), "--if-due"],
                cwd=ROOT, capture_output=True, text=True, check=False, env=env,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout, "")
            self.assertTrue(marker.exists(), "사용 지표 훅이 교훈 후보 전송을 부르지 않았다")


if __name__ == "__main__":
    unittest.main()
