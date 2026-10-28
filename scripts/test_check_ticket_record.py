#!/usr/bin/env python3
"""check_ticket_record.py 가 실제로 무는지 본다.

검사기는 통과시키는 것보다 **걸러내는 것**이 일이다. 그래서 완결된 기록 하나를
기준으로 두고, 항목마다 일부러 깨뜨려 그 항목이 잡히는지 확인한다. 통과 경로만
시험하면 아무것도 안 잡는 검사기도 초록불이 난다.
"""

from __future__ import annotations

import importlib.util
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
CHECKER = ROOT / "scripts/check_ticket_record.py"

COMPLETE = """# 900001 · 합성고객 · 테스트 티켓

상태: 진행중
날짜: 2026-09-25
링크: https://example.zendesk.com/agent/tickets/900001
등급: standard
산출물: 조사 결과 + 답변
policy_ids: []

## 물어본 것

1. 왜 비용이 늘었나

## 확인한 것

- [확인] 온디맨드 단가가 적용되고 있다
  → https://example.com/pricing 2026-09-14 확인

## 답변 초안

```text
안내드립니다.
```

## 발송 전 점검

```
[x] 고객이 문의에서 밝힌 제약을 답변이 지키는가
[x] 물어본 것 전부에 답했는가
[x] 콘솔 경로를 고객이 보는 화면 그대로 썼는가
[x] 지금 답할 수 있는데 되묻고 있지 않은가
[x] [확인] 에 전부 출처가 붙었는가
[x] 비용 수치가 빌링 플랫폼 정제값인가
```

## 교훈 후보

- 없음

## 실제 발송
"""


class CheckerHarness:
    """검사기를 임시 파일에 대고 CLI 로 돌린다. 두 테스트 클래스가 같이 쓴다."""

    def run_checker(self, body: str) -> subprocess.CompletedProcess:
        with tempfile.TemporaryDirectory(prefix="tiket-record-") as tempdir:
            path = Path(tempdir) / "900001.md"
            path.write_text(body, encoding="utf-8")
            return subprocess.run(
                [sys.executable, str(CHECKER), str(path)],
                capture_output=True,
                text=True,
                check=False,
            )

    def assert_flags(self, body: str, fragment: str) -> None:
        result = self.run_checker(body)
        self.assertEqual(result.returncode, 1, f"통과해서는 안 되는 기록이 통과했다\n{result.stdout}")
        self.assertIn(fragment, result.stdout)

    def assert_not_flagged(self, body: str, fragment: str) -> None:
        result = self.run_checker(body)
        self.assertNotIn(fragment, result.stdout)


class CheckTicketRecordTests(CheckerHarness, unittest.TestCase):
    def test_gate_count_follows_the_items_in_the_record(self) -> None:
        """항목 수는 기록마다 다르다(2026-10-21 에 6 → 9). 분모는 기록에 있는 항목 수다."""
        body = COMPLETE.replace(
            "[x] 비용 수치가 빌링 플랫폼 정제값인가\n",
            "[x] 비용 수치가 빌링 플랫폼 정제값인가\n[ ] 고객이 직접 확인할 방법을 줬는가\n"
            "[x] 링크만 보내고 끝내지 않았는가\n[x] 날짜를 일괄 확약하지 않았는가\n",
        )
        self.assert_flags(body, "미통과 항목 1/9 개")

    def test_complete_record_passes(self) -> None:
        result = self.run_checker(COMPLETE)
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn("PASS", result.stdout)

    def test_gate_wording_is_not_mistaken_for_a_violation(self) -> None:
        """발송 전 점검 항목문에 '[확인] 에 전부 출처가 붙었는가' 가 들어 있다.

        그 구간을 세면 검사기가 자기 자신을 위반으로 잡는다. 실제로 처음에 그렇게 났다.
        """
        result = self.run_checker(COMPLETE)
        self.assertNotIn("출처 없는", result.stdout)

    def test_missing_tier_is_flagged(self) -> None:
        self.assert_flags(COMPLETE.replace("등급: standard\n", ""), "`등급:` 이 없다")

    def test_missing_output_is_flagged(self) -> None:
        self.assert_flags(COMPLETE.replace("산출물: 조사 결과 + 답변\n", ""), "`산출물:` 이 없다")

    def test_missing_policy_ids_is_flagged(self) -> None:
        self.assert_flags(COMPLETE.replace("policy_ids: []\n", ""), "`policy_ids:` 가 없다")

    def test_unresolved_tier_choice_is_flagged(self) -> None:
        body = COMPLETE.replace("등급: standard", "등급: quick · standard · high-risk 중 하나")
        self.assert_flags(body, "후보가 여러 개")

    def test_unchecked_gate_item_is_flagged(self) -> None:
        self.assert_flags(COMPLETE.replace("[x] 물어본 것", "[ ] 물어본 것"), "미통과 항목")

    def test_confirmed_claim_without_a_source_is_flagged(self) -> None:
        body = COMPLETE.replace("  → https://example.com/pricing 2026-09-14 확인\n", "")
        self.assert_flags(body, "출처 없는")

    def test_empty_draft_is_flagged(self) -> None:
        """9월 11일 세션이 남긴 서명이 이것이다 — 산출물을 정하고 초안을 안 썼다."""
        body = COMPLETE.replace("```text\n안내드립니다.\n```", "```text\n\n```")
        self.assert_flags(body, "`## 답변 초안` 이 비어 있다")

    def test_template_placeholder_left_behind_is_flagged(self) -> None:
        self.assert_flags(COMPLETE.replace("900001 · 합성고객", "<번호> · <고객사명>"), "자리표시자")

    def test_real_output_wording_variants_are_accepted(self) -> None:
        """실제 기록은 `조사 결과 + 답변`, `답변 + 출처` 처럼 공백과 '결과'를 넣어 쓴다."""
        for wording in ("조사 결과 + 답변", "조사+답변", "답변 + 출처", "작업 지시서"):
            with self.subTest(wording=wording):
                body = COMPLETE.replace("산출물: 조사 결과 + 답변", f"산출물: {wording}")
                if wording == "작업 지시서":
                    body = body.replace("## 확인한 것", "## 작업 지시")
                result = self.run_checker(body)
                self.assertNotIn("3종 중 하나가 아니다", result.stdout)


PRE_SCHEMA = """# 900002 · 합성고객 · Phase 1 이전 기록

상태: 완료
날짜: 2026-09-05
schema: 2026-09-05
링크: https://example.zendesk.com/agent/tickets/900002

## 물어본 것

1. 스냅샷 요금이 왜 붙나

## 확인한 것

- 스냅샷은 변경 블록만 과금된다

## 답변 초안

```text
안내드립니다.
```
"""


class PreSchemaRecordTests(CheckerHarness, unittest.TestCase):
    """Phase 1 이전 기록은 없던 항목으로 감점되지 않는다.

    `등급:` 과 `policy_ids:` 는 164bc77 (2026-09-14) 에, `## 발송 전 점검` 은
    49b6536 (2026-09-07) 에 템플릿으로 들어왔다. 도입일이 서로 다르므로 커트
    하나로 8건을 통째로 면제하면 09-07 이후에 실제로 빠뜨린 것까지 덮는다.
    검사기가 항목별 도입일을 들고 `schema:` 날짜와 대조한다.
    """

    def test_pre_schema_record_is_not_failed_for_fields_that_did_not_exist(self) -> None:
        result = self.run_checker(PRE_SCHEMA)
        self.assertEqual(result.returncode, 0, result.stdout)
        for fragment in ("`등급:` 이 없다", "`policy_ids:` 가 없다", "`## 발송 전 점검` 섹션이 없다"):
            self.assertNotIn(fragment, result.stdout)

    def test_pre_schema_record_is_counted_as_unevaluated_not_passed(self) -> None:
        result = self.run_checker(PRE_SCHEMA)
        self.assertIn("미평가", result.stdout)

    def test_gate_is_still_required_after_its_introduction_date(self) -> None:
        """09-07 에 발송 전 점검이 생겼다. 09-08 기록에 없으면 그건 진짜 누락이다."""
        body = PRE_SCHEMA.replace("schema: 2026-09-05", "schema: 2026-09-08")
        self.assert_flags(body, "`## 발송 전 점검` 섹션이 없다")

    def test_tier_is_still_exempt_after_the_gate_date(self) -> None:
        """같은 09-08 기록이라도 등급은 09-14 도입이라 여전히 면제다."""
        body = PRE_SCHEMA.replace("schema: 2026-09-05", "schema: 2026-09-08")
        self.assert_not_flagged(body, "`등급:` 이 없다")

    def test_introduction_day_itself_is_exempt(self) -> None:
        """도입 커밋과 같은 날이면 전후를 가릴 수 없다. 소급 판정은 관대한 쪽으로 둔다."""
        body = PRE_SCHEMA.replace("schema: 2026-09-05", "schema: 2026-09-07")
        self.assert_not_flagged(body, "`## 발송 전 점검` 섹션이 없다")

    def test_schema_header_does_not_exempt_anything_after_the_last_field(self) -> None:
        """schema 를 최근 날짜로 적어도 면제는 없다. 빠져나갈 구멍이 되면 안 된다."""
        body = PRE_SCHEMA.replace("schema: 2026-09-05", "schema: 2026-09-20")
        self.assert_flags(body, "`등급:` 이 없다")

    def test_malformed_schema_value_is_flagged(self) -> None:
        body = PRE_SCHEMA.replace("schema: 2026-09-05", "schema: 옛날")
        self.assert_flags(body, "`schema:`")

    def test_record_without_schema_header_is_evaluated_in_full(self) -> None:
        """헤더가 없으면 새 기록이다. 자동으로 평가 대상이 된다."""
        body = PRE_SCHEMA.replace("schema: 2026-09-05\n", "")
        self.assert_flags(body, "`등급:` 이 없다")


LESSON = """- 종류: pitfall
  트리거: T2
  한 줄: 고객이 콘솔 조회 권한이 없어 공식 문서 경로가 통하지 않는다
  근거: ## 확인한 것 2번째 항목"""


MISS = """- 종류: miss
  트리거: T2
  한 줄: 라우터가 고른 정책 카드를 읽지 않고 약속했다
  막을 규칙: policy/_routing.md"""


def with_lessons(body: str) -> str:
    return COMPLETE.replace("## 교훈 후보\n\n- 없음\n", f"## 교훈 후보\n\n{body}\n")


class LessonCandidateTests(CheckerHarness, unittest.TestCase):
    """`## 교훈 후보` — 2026-09-24 도입 (0026).

    칸이 비면 "넘어진 게 없었다"와 "안 봤다"가 구분되지 않는다. 그래서 없으면 `없음` 을
    명시한다. 형식이 틀린 후보는 수집 클라이언트가 읽지 못해 조용히 사라진다.
    """

    def test_explicit_none_passes(self) -> None:
        result = self.run_checker(COMPLETE)
        self.assertEqual(result.returncode, 0, result.stdout)

    def test_well_formed_candidate_passes(self) -> None:
        result = self.run_checker(with_lessons(LESSON))
        self.assertEqual(result.returncode, 0, result.stdout)

    def test_reobservation_of_an_existing_pitfall_passes(self) -> None:
        """실제 사례 파일에 기대지 않는다 — 사례는 지워지고 바뀐다(2026-09-30 에 전부 지웠다)."""
        spec = importlib.util.spec_from_file_location("check_ticket_record", CHECKER)
        checker = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(checker)
        with tempfile.TemporaryDirectory(prefix="tiket-pitfall-") as tempdir:
            (Path(tempdir) / "pitfalls").mkdir()
            (Path(tempdir) / "pitfalls/probe-trap.md").write_text("x\n", encoding="utf-8")
            with mock.patch.object(checker, "ROOT", Path(tempdir)):
                problems = checker.lesson_problems([{"재관측": "pitfalls/probe-trap.md"}])
        self.assertEqual(problems, [])

    def test_reobservation_with_a_kind_is_flagged(self) -> None:
        """`재관측:` 이 먼저 읽혀 `종류: miss` 가 버려진 채 reobserved 로 나갔다(2026-10-26 EVAL-027 7회차)."""
        spec = importlib.util.spec_from_file_location("check_ticket_record", CHECKER)
        checker = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(checker)
        with tempfile.TemporaryDirectory(prefix="tiket-pitfall-") as tempdir:
            (Path(tempdir) / "pitfalls").mkdir()
            (Path(tempdir) / "pitfalls/probe-trap.md").write_text("x\n", encoding="utf-8")
            with mock.patch.object(checker, "ROOT", Path(tempdir)):
                problems = checker.lesson_problems(
                    [{"재관측": "pitfalls/probe-trap.md", "종류": "miss", "한 줄": "x"}]
                )
        self.assertEqual(len(problems), 1, problems)
        self.assertIn("하나만", problems[0])

    def test_missing_section_is_flagged(self) -> None:
        body = COMPLETE.replace("## 교훈 후보\n\n- 없음\n\n", "")
        self.assert_flags(body, "`## 교훈 후보` 가 없다")

    def test_section_with_only_guidance_comments_is_flagged(self) -> None:
        self.assert_flags(with_lessons("<!-- 없으면 없음 -->"), "`## 교훈 후보` 가 비어 있다")

    def test_unknown_kind_is_flagged(self) -> None:
        self.assert_flags(with_lessons(LESSON.replace("종류: pitfall", "종류: 기타")), "종류")

    def test_unknown_trigger_is_flagged(self) -> None:
        self.assert_flags(with_lessons(LESSON.replace("트리거: T2", "트리거: T9")), "트리거")

    def test_several_triggers_are_accepted(self) -> None:
        result = self.run_checker(with_lessons(LESSON.replace("트리거: T2", "트리거: T1, T2")))
        self.assertEqual(result.returncode, 0, result.stdout)

    def test_candidate_without_summary_is_flagged(self) -> None:
        body = LESSON.replace("  한 줄: 고객이 콘솔 조회 권한이 없어 공식 문서 경로가 통하지 않는다\n", "")
        self.assert_flags(with_lessons(body), "한 줄")

    def test_reobservation_of_a_missing_pitfall_is_flagged(self) -> None:
        """오타 난 재관측은 어느 판례에도 안 쌓인다."""
        self.assert_flags(with_lessons("- 재관측: pitfalls/no-such-trap.md"), "재관측")

    def test_reobservation_outside_pitfalls_is_flagged(self) -> None:
        self.assert_flags(with_lessons("- 재관측: playbooks/reply-style.md"), "재관측")

    def test_none_mixed_with_candidates_is_flagged(self) -> None:
        self.assert_flags(with_lessons("- 없음\n" + LESSON), "없음")

    def test_record_dated_before_introduction_is_not_flagged_without_schema(self) -> None:
        """동료 PC 의 옛 기록은 소급 표시를 할 수 없다. 날짜로 도입 전을 가린다.

        report_usage.py 가 --all 결과를 지표로 보내므로, 이 칸 하나로 모든 동료의
        옛 기록이 FAIL 로 뒤집히면 지표가 거짓말을 한다.
        """
        body = COMPLETE.replace("날짜: 2026-09-25", "날짜: 2026-09-20").replace(
            "## 교훈 후보\n\n- 없음\n\n", ""
        )
        self.assert_not_flagged(body, "`## 교훈 후보`")

    def test_record_dated_on_the_introduction_day_is_exempt(self) -> None:
        """schema 와 같은 규칙이다 — 도입 당일은 커밋 전후를 가릴 수 없어 면제한다."""
        body = COMPLETE.replace("날짜: 2026-09-25", "날짜: 2026-09-24").replace(
            "## 교훈 후보\n\n- 없음\n\n", ""
        )
        self.assert_not_flagged(body, "`## 교훈 후보`")

    def test_a_lessons_section_is_checked_even_when_the_date_is_the_thread_date(self) -> None:
        """2026-10-22 평가: `날짜:` 에 고객 스레드 날짜(09-14)를 적어 기록 전체가 미평가로 빠졌다.
        절이 있으면 새 양식으로 쓴 기록이다 — 날짜와 상관없이 검사하고, 통과하면 PASS 다."""
        body = COMPLETE.replace("날짜: 2026-09-25", "날짜: 2026-09-14")
        result = self.run_checker(body)
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn("PASS 1", result.stdout)
        self.assertNotIn("미평가 1", result.stdout)
        self.assert_flags(with_lessons("<!-- 없으면 없음 -->").replace("날짜: 2026-09-25", "날짜: 2026-09-14"), "`## 교훈 후보` 가 비어 있다")

    def test_a_pitfall_candidate_without_source_or_observed_date_is_a_warning_not_a_failure(self) -> None:
        """2026-10-22 유지보수자: 승인은 한 줄만 보고 하는데 그 한 줄이 사실과 달랐다(10-19 넷 중 둘).
        pitfall 후보는 출처와 관측일을 싣는다. 처음에는 경고만 한다 — 동료 기록이 한꺼번에 FAIL 로 뒤집히지 않게."""
        result = self.run_checker(with_lessons(LESSON))
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn("교훈 후보 1번: pitfall 은 `출처:`", result.stdout)
        self.assertIn("`관측일:`", result.stdout)
        sourced = LESSON + "\n  출처: https://docs.aws.amazon.com/example\n  관측일: 2026-10-20"
        self.assertNotIn("교훈 후보 1번: pitfall", self.run_checker(with_lessons(sourced)).stdout)
        bad_date = LESSON + "\n  출처: https://docs.aws.amazon.com/example\n  관측일: 지난주"
        self.assertIn("`관측일:`", self.run_checker(with_lessons(bad_date)).stdout)
        policy = LESSON.replace("종류: pitfall", "종류: policy").replace("트리거: T2", "트리거: T3")
        self.assertNotIn("교훈 후보 1번: pitfall", self.run_checker(with_lessons(policy)).stdout)

    def test_a_wrapped_one_line_summary_is_kept_whole(self) -> None:
        """2026-10-26 사전 검토: 줄을 바꿔 쓴 `한 줄:` 이 첫 줄만 서버에 갔다. 이어지는 줄에 `:` 가 있어도 가짜 키가 되지 않는다."""
        wrapped = LESSON.replace(
            "  한 줄: 고객이 콘솔 조회 권한이 없어 공식 문서 경로가 통하지 않는다",
            "  한 줄: EC2 의 MTU 9001 을 \"Amazon Linux AMI 기본값\" 으로 설명하면 비-Amazon Linux\n"
            "    인스턴스에서 틀린다 — 근거 문서: 블로그뿐이다",
        ) + "\n  출처: https://docs.aws.amazon.com/example\n  관측일: 2026-10-07"
        [item] = checker.parse_lessons(wrapped)
        self.assertEqual(
            item["한 줄"],
            "EC2 의 MTU 9001 을 \"Amazon Linux AMI 기본값\" 으로 설명하면 비-Amazon Linux "
            "인스턴스에서 틀린다 — 근거 문서: 블로그뿐이다",
        )
        self.assertEqual(set(item), {"종류", "트리거", "한 줄", "근거", "출처", "관측일"})
        self.assertEqual(item["관측일"], "2026-10-07")

    def test_miss_with_an_existing_rule_file_passes(self) -> None:
        result = self.run_checker(with_lessons(MISS))
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertNotIn("교훈 후보 1번: pitfall", result.stdout)

    def test_miss_without_a_rule_is_flagged(self) -> None:
        self.assert_flags(with_lessons(MISS.replace("\n  막을 규칙: policy/_routing.md", "")), "막을 규칙")

    def test_miss_with_a_rule_file_that_does_not_exist_is_flagged(self) -> None:
        self.assert_flags(with_lessons(MISS.replace("policy/_routing.md", "policy/no-such-rule.md")), "막을 규칙")

    def test_miss_rule_must_stay_inside_the_repository(self) -> None:
        for bad in ("../README.md", "/etc/hosts", "policy/../README.md", "policy", "README.txt", "가" * 201 + ".md"):
            with self.subTest(rule=bad[:30]):
                self.assert_flags(with_lessons(MISS.replace("policy/_routing.md", bad)), "막을 규칙")

    def test_miss_rule_may_be_wrapped_in_backticks(self) -> None:
        result = self.run_checker(with_lessons(MISS.replace("policy/_routing.md", "`policy/_routing.md`")))
        self.assertEqual(result.returncode, 0, result.stdout)

    def test_miss_still_needs_trigger_and_summary(self) -> None:
        self.assert_flags(with_lessons(MISS.replace("  트리거: T2\n", "")), "트리거")
        self.assert_flags(with_lessons(MISS.replace("  한 줄: 라우터가 고른 정책 카드를 읽지 않고 약속했다\n", "")), "한 줄")

    def test_miss_is_not_asked_for_pitfall_source_and_observed_date(self) -> None:
        self.assertNotIn("교훈 후보 1번: pitfall", self.run_checker(with_lessons(MISS)).stdout)

    def test_candidate_without_a_proposed_location_is_a_warning_not_a_failure(self) -> None:
        playbook = LESSON.replace("종류: pitfall", "종류: playbook")
        result = self.run_checker(with_lessons(playbook))
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn("`제안 위치:`", result.stdout)
        located = playbook + "\n  제안 위치: playbooks/reply-style.md"
        self.assertNotIn("`제안 위치:`", self.run_checker(with_lessons(located)).stdout)

    def test_miss_is_not_asked_for_a_proposed_location(self) -> None:
        self.assertNotIn("`제안 위치:`", self.run_checker(with_lessons(MISS)).stdout)

    def test_a_wrapped_line_before_the_new_keys_does_not_swallow_them(self) -> None:
        """`막을 규칙`·`제안 위치` 가 LESSON_KEYS 에 없으면 앞 값의 줄바꿈으로 붙어 버린다."""
        [item] = checker.parse_lessons(MISS + "\n  제안 위치: playbooks/new-file.md")
        self.assertEqual(item["막을 규칙"], "policy/_routing.md")
        self.assertEqual(item["제안 위치"], "playbooks/new-file.md")
        self.assertEqual(item["한 줄"], "라우터가 고른 정책 카드를 읽지 않고 약속했다")

    def test_unknown_kind_message_lists_miss(self) -> None:
        self.assertIn("miss", self.run_checker(with_lessons(LESSON.replace("종류: pitfall", "종류: 기타"))).stdout)

    def test_written_date_wins_over_the_thread_date(self) -> None:
        """`날짜:` 는 고객 스레드 날짜, `작성일:` 은 기록을 처음 만든 날이다 (2026-10-22 유지보수자)."""
        from datetime import date
        from check_ticket_record import record_date
        self.assertEqual(record_date("날짜: 2026-09-14\n작성일: 2026-10-22\n"), date(2026, 10, 22))
        self.assertEqual(record_date("날짜: 2026-09-14\n"), date(2026, 9, 14))
        self.assertEqual(record_date("날짜: 2026-09-14\n작성일: YYYY-MM-DD\n"), date(2026, 9, 14))

    def test_seen_places_alone_does_not_turn_a_schema_record_unevaluated(self) -> None:
        """`확인한 곳:` 은 새 후보에만 붙는 좁은 검사다. 그것 하나 때문에 옛 기록이 미평가로 뒤집히면 동료 지표가 바뀐다."""
        body = COMPLETE.replace("날짜: 2026-09-25", "날짜: 2026-09-25\nschema: 2026-10-01")
        result = self.run_checker(body)
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertNotIn("미평가 1", result.stdout)

    def test_schema_header_still_wins_over_date(self) -> None:
        body = COMPLETE.replace("날짜: 2026-09-25", "날짜: 2026-09-20\nschema: 2026-09-25").replace(
            "## 교훈 후보\n\n- 없음\n\n", ""
        )
        self.assert_flags(body, "`## 교훈 후보` 가 없다")


sys.path.insert(0, str(ROOT / "scripts"))
import check_ticket_record as checker  # noqa: E402

SEEN = "  확인한 곳: pitfalls/ 목록, grep \"MTU\" pitfalls/ — 해당 없음"


def written_on(body: str, day: str) -> str:
    return body.replace("날짜: 2026-09-25", f"날짜: 2026-09-25\n작성일: {day}")


class SeenPlacesTests(CheckerHarness, unittest.TestCase):
    """`확인한 곳:` — 판례를 찾아봤다는 흔적 (EVAL-027 3/10, 2026-10-26).

    `pitfalls/` 를 열지도 않고 "판례 없음" 이라 적은 뒤 새 pitfall 을 올린 회차가 3번이었다.
    """

    def run_new(self, lessons: str, day: str = "2026-10-26"):
        return self.run_checker(written_on(with_lessons(lessons), day))

    def test_pitfall_without_seen_places_is_flagged(self) -> None:
        result = self.run_new(LESSON)
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn("`확인한 곳:`", result.stdout)
        self.assertIn("pitfalls/", result.stdout)

    def test_seen_places_without_pitfalls_dir_is_flagged(self) -> None:
        result = self.run_new(LESSON + "\n  확인한 곳: 찾아봤다 — 해당 없음")
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn("`확인한 곳:`", result.stdout)

    def test_pitfall_with_seen_places_passes(self) -> None:
        result = self.run_new(LESSON + "\n" + SEEN)
        self.assertEqual(result.returncode, 0, result.stdout)

    def test_policy_and_playbook_also_need_seen_places(self) -> None:
        for kind in ("policy", "playbook"):
            with self.subTest(kind=kind):
                result = self.run_new(LESSON.replace("종류: pitfall", f"종류: {kind}"))
                self.assertEqual(result.returncode, 1, result.stdout)
                self.assertIn("`확인한 곳:`", result.stdout)

    def test_miss_customer_and_reobserved_do_not_need_it(self) -> None:
        customer = LESSON.replace("종류: pitfall", "종류: customer")
        for lessons in (MISS, customer, "- 재관측: pitfalls/probe-trap.md"):
            with self.subTest(lessons=lessons[:20]):
                self.assertNotIn("`확인한 곳:`", self.run_new(lessons).stdout)

    def test_record_written_before_the_rule_is_not_flagged(self) -> None:
        result = self.run_new(LESSON, day="2026-10-24")
        self.assertNotIn("`확인한 곳:`", result.stdout)
        self.assertEqual(result.returncode, 0, result.stdout)

    def test_record_written_on_the_cut_day_is_exempt(self) -> None:
        self.assertNotIn("`확인한 곳:`", self.run_new(LESSON, day="2026-10-25").stdout)

    def test_a_wrapped_seen_places_value_does_not_leak_into_the_previous_key(self) -> None:
        wrapped = LESSON + "\n  확인한 곳: pitfalls/ 목록을 봤다,\n    grep \"MTU\" pitfalls/ — 해당 없음"
        [item] = checker.parse_lessons(wrapped)
        self.assertEqual(item["근거"], "## 확인한 것 2번째 항목")
        self.assertEqual(item["확인한 곳"], "pitfalls/ 목록을 봤다, grep \"MTU\" pitfalls/ — 해당 없음")
        # 이어 줄에 ':' 가 있어도 앞 칸에 붙지 않는다
        [item] = checker.parse_lessons(LESSON + "\n  확인한 곳: pitfalls/\n    grep: 해당 없음")
        self.assertEqual(item["근거"], "## 확인한 것 2번째 항목")

    def test_the_rule_does_not_block_reporting_old_records(self) -> None:
        """lesson_problems 는 report_lessons 가 쓴다. 여기 넣으면 소급 없이 서버 전송이 멈춘다."""
        self.assertEqual(checker.lesson_problems(checker.parse_lessons(LESSON)), [])


class CategoryTests(unittest.TestCase):
    """문제마다 묶음이 붙는다. 사용 지표가 리더용 화면에 이 묶음을 보낸다 (2026-09-28)."""

    def categories(self, body: str) -> set[str]:
        with tempfile.TemporaryDirectory(prefix="tiket-record-") as tempdir:
            path = Path(tempdir) / "900001.md"
            path.write_text(body, encoding="utf-8")
            result = checker.check(path)
        self.assertEqual(len(result.categories), len(result.problems))
        return set(result.categories)

    def test_complete_record_has_no_category(self) -> None:
        self.assertEqual(self.categories(COMPLETE), set())

    def test_each_check_lands_in_its_category(self) -> None:
        cases = {
            "safety": [
                COMPLETE.replace("[x] 물어본 것", "[ ] 물어본 것"),
                COMPLETE.replace("  → https://example.com/pricing 2026-09-14 확인\n", ""),
                COMPLETE.replace("## 발송 전 점검", "## 다른 제목"),
            ],
            "routing": [
                COMPLETE.replace("등급: standard\n", ""),
                COMPLETE.replace("산출물: 조사 결과 + 답변\n", ""),
                COMPLETE.replace("policy_ids: []\n", ""),
            ],
            "record": [
                COMPLETE.replace("```text\n안내드립니다.\n```", "```text\n\n```"),
                COMPLETE.replace("900001 · 합성고객", "<번호> · <고객사명>"),
                COMPLETE.replace("1. 왜 비용이 늘었나", ""),
            ],
            "lessons": [
                COMPLETE.replace("## 교훈 후보\n\n- 없음\n", "## 교훈 후보\n\n-\n"),
                COMPLETE.replace("- 없음", "- 종류: pitfall"),
            ],
            "format": [
                COMPLETE.replace("날짜: 2026-09-25", "날짜: 2026-09-25\nschema: 어제"),
                COMPLETE + "\n## 작업 지시\n",
            ],
        }
        for expected, bodies in cases.items():
            for body in bodies:
                with self.subTest(expected=expected, body=body[-80:]):
                    self.assertEqual(self.categories(body), {expected})

    def test_every_category_has_a_name_and_a_reason(self) -> None:
        self.assertEqual(set(checker.CATEGORIES), {"safety", "routing", "record", "lessons", "format"})
        for code, (name, why) in checker.CATEGORIES.items():
            self.assertTrue(name and why, code)

    def test_the_gate_category_is_not_called_a_skipped_safeguard(self) -> None:
        """리더가 읽는 이름이다. 본 것은 "점검이 체크되지 않았다" 이지 건너뛴 증거가 아니다 (2026-10-04 기준선)."""
        self.assertEqual(checker.CATEGORIES["safety"][0], "발송 전 점검 미완료")


class EvaluationTests(unittest.TestCase):
    """평가 케이스는 실사용이 아니다. 사용 지표와 교훈 전송이 같은 판별을 쓴다."""

    def test_synthetic_customer_in_the_title_is_an_evaluation(self) -> None:
        self.assertTrue(checker.is_evaluation(COMPLETE))

    def test_evaluation_header_is_an_evaluation(self) -> None:
        body = COMPLETE.replace("합성고객", "고객사").replace("상태: 진행중", "상태: 진행중\n평가: EVAL-001")
        self.assertTrue(checker.is_evaluation(body))

    def test_mentioning_it_in_the_body_is_not(self) -> None:
        body = COMPLETE.replace("합성고객", "고객사").replace("1. 왜 비용이 늘었나", "1. 합성고객 사례처럼 비용이 늘었나")
        self.assertFalse(checker.is_evaluation(body))


class ActiveFieldsTests(unittest.TestCase):
    """사용 지표도 같은 판단으로 도입 전 기록을 분포에서 뺀다 — 한 곳에서 계산한다."""

    def test_pre_schema_record_has_routing_off(self) -> None:
        body = PRE_SCHEMA.replace("schema: 2026-09-05", "schema: 2026-09-08")
        active = checker.active_fields(checker.strip_comments(body))
        self.assertFalse(active["routing"])
        self.assertTrue(active["output"])

    def test_current_record_has_everything_on(self) -> None:
        self.assertTrue(all(checker.active_fields(checker.strip_comments(written_on(COMPLETE, "2026-10-26"))).values()))


class TallyTests(unittest.TestCase):
    def test_tally_matches_the_cli_summary_rules(self) -> None:
        results = [
            checker.Result((), (), ()),
            checker.Result(("문제",), (), ("record",)),
            checker.Result(("문제",), ("routing",), ("record",)),
            checker.Result((), ("routing",), ()),
        ]
        self.assertEqual(checker.tally(results), {"total": 4, "passed": 1, "failed": 2, "pre_schema": 1})



GUESSED = COMPLETE.replace(
    "## 답변 초안", "- [추측] 인스턴스 유형이 바뀌어서 그렇다\n\n## 답변 초안")


class PromotedGuessWarningTests(CheckerHarness, unittest.TestCase):
    """Q7 — 기록의 `[추측]` 이 초안에서 단정이 된다 (기준선 2026-10-04, EVAL-001 3회 중 2회).
    기계는 승격됐는지 모른다. 그래서 FAIL 이 아니라 다시 읽으라는 경고다."""

    def test_a_guess_with_an_unmarked_draft_warns_but_passes(self) -> None:
        result = self.run_checker(GUESSED)
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn("경고", result.stdout)
        self.assertIn("[추측] 1건", result.stdout)
        self.assertIn("PASS 1 / FAIL 0", result.stdout)

    def test_no_guess_no_warning(self) -> None:
        self.assertNotIn("경고", self.run_checker(COMPLETE).stdout)

    def test_a_draft_that_keeps_the_mark_is_not_warned(self) -> None:
        body = GUESSED.replace("안내드립니다.", "[추측] 인스턴스 유형 변경으로 보입니다.")
        self.assertNotIn("경고", self.run_checker(body).stdout)

    def test_without_a_draft_there_is_nothing_to_promote(self) -> None:
        body = GUESSED.replace("```text\n안내드립니다.\n```\n", "")
        self.assertNotIn("경고", self.run_checker(body).stdout)

    def test_the_gate_wording_is_not_counted_as_a_guess(self) -> None:
        body = COMPLETE.replace("[x] 비용 수치가", "[x] [추측] 을 단정하지 않았는가\n[x] 비용 수치가")
        self.assertNotIn("경고", self.run_checker(body).stdout)

    def test_a_warning_is_not_a_problem_for_the_metrics(self) -> None:
        with tempfile.TemporaryDirectory(prefix="tiket-record-") as tempdir:
            path = Path(tempdir) / "900001.md"
            path.write_text(GUESSED, encoding="utf-8")
            result = checker.check(path)
        self.assertEqual((result.problems, len(result.warnings)), ((), 1))
        self.assertEqual(checker.tally([result])["passed"], 1)


class FalseProgressWarningTests(CheckerHarness, unittest.TestCase):
    """초안이 아무도 안 한 일을 했다고 쓴다 — EVAL-026 "바로 진행하고 있으며", "사내 대응 라인에 전달하고 있습니다" (2026-10-24).
    했는지는 기계가 모른다. 그래서 FAIL 이 아니라 다시 읽으라는 경고다."""

    def draft(self, sentence: str) -> str:
        return COMPLETE.replace("안내드립니다.", sentence)

    def test_phrases_seen_in_eval_drafts_are_caught(self) -> None:
        for sentence in ("확인 즉시 바로 진행하고 있으며, 결과를 안내드리겠습니다.",
                         "사내 대응 라인에 전달하고 있습니다.",
                         "담당 부서에 요청해 두었습니다.",
                         "저희가 대응을 시작했습니다.",
                         "AWS 에 전달드렸습니다."):
            with self.subTest(sentence=sentence):
                self.assertTrue(checker.false_progress(self.draft(sentence)))

    def test_promises_and_internal_check_are_not_caught(self) -> None:
        sentence = "내부 확인 중이며, 결과는 확인되는 대로 전달드리겠습니다. 아래 자료를 요청드립니다."
        self.assertEqual(checker.false_progress(self.draft(sentence)), [])

    def test_a_phrase_broken_across_lines_is_caught(self) -> None:
        self.assertTrue(checker.false_progress(self.draft("사내 대응 라인에 전달하고\n있습니다.")))

    def test_quotes_comments_and_other_sections_are_not_caught(self) -> None:
        quoted = self.draft('지난 회신의 "전달드렸습니다" 는 잘못된 표현이었습니다.')
        commented = COMPLETE.replace("## 답변 초안\n", "## 답변 초안\n\n<!-- 바로 진행하고 있으며 금지 -->\n")
        memo = COMPLETE.replace("## 답변 초안\n", "## 내부 메모\n\n- 대응을 시작했습니다\n\n## 답변 초안\n")
        for text in (quoted, commented, memo):
            with self.subTest(text=text[-200:]):
                self.assertEqual(checker.false_progress(text), [])

    def test_the_warning_reaches_the_output_and_still_passes(self) -> None:
        result = self.run_checker(self.draft("사내 대응 라인에 전달하고 있습니다."))
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn("전달하고 있습니다", result.stdout)
        self.assertIn("PASS 1 / FAIL 0", result.stdout)


if __name__ == "__main__":
    unittest.main()
