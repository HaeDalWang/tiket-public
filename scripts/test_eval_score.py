#!/usr/bin/env python3
"""eval_score 가 카드를 골랐는지(재현율)와 고른 뒤 지켰는지(금지 문구)를 따로 세는지 본다."""

from __future__ import annotations

import importlib.util
import json
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("eval_score", ROOT / "scripts/eval_score.py")
es = importlib.util.module_from_spec(spec)
spec.loader.exec_module(es)

CASE = """# EVAL-099 · 시험

- 덮는 것: `GUIDE-HEALTH-001`
- 기대 policy_ids: `GUIDE-HEALTH-001`, `POLICY-ESC-001`
- 회신 금지 문구: "다른 고객사", "공지를 드리겠습니다"

## 프롬프트
"""


def record(ids: str, draft: str, memo: str = "") -> str:
    return (f"# 900199 · 합성고객 · 시험\n\n상태: 진행중\npolicy_ids: [{ids}]\n\n## 확인한 것\n\n- [확인] {memo}\n\n"
            f"## 답변 초안\n\n```text\n{draft}\n```\n\n## 발송 전 점검\n")


class HeaderTest(unittest.TestCase):
    def test_header_gives_expected_cards_and_forbidden_phrases(self) -> None:
        self.assertEqual(es.parse_case(CASE), (["GUIDE-HEALTH-001", "POLICY-ESC-001"], ["다른 고객사", "공지를 드리겠습니다"]))

    def test_a_case_without_the_header_has_nothing_to_score(self) -> None:
        self.assertEqual(es.parse_case("# EVAL-001\n\n- 덮는 것: `POLICY-X-001`\n"), ([], []))


class ScoreRunTest(unittest.TestCase):
    EXPECTED = ["GUIDE-HEALTH-001", "POLICY-ESC-001"]
    FORBIDDEN = ["다른 고객사"]

    def test_recall_counts_each_expected_card(self) -> None:
        score = es.score_record(record("GUIDE-HEALTH-001, POLICY-SEC-001", "괜찮습니다"), self.EXPECTED, self.FORBIDDEN)
        self.assertEqual(score["found"], ["GUIDE-HEALTH-001"])
        self.assertEqual(score["missed"], ["POLICY-ESC-001"])
        self.assertEqual(score["extra"], ["POLICY-SEC-001"])

    def test_a_forbidden_phrase_in_the_draft_is_a_hit_even_when_the_card_was_chosen(self) -> None:
        score = es.score_record(record("GUIDE-HEALTH-001, POLICY-ESC-001", "다른 고객사도 확인 중입니다"), self.EXPECTED, self.FORBIDDEN)
        self.assertEqual(score["missed"], [])
        self.assertEqual(score["forbidden"], ["다른 고객사"])

    def test_the_phrase_outside_the_draft_does_not_count(self) -> None:
        """내부 메모에 "다른 고객사에 묻지 않는다" 고 적는 것은 괜찮다 — 고객에게 나가는 블록만 본다."""
        score = es.score_record(record("GUIDE-HEALTH-001", "괜찮습니다", memo="다른 고객사 언급 금지"), self.EXPECTED, self.FORBIDDEN)
        self.assertEqual(score["forbidden"], [])

    def test_a_comment_inside_the_draft_section_does_not_count(self) -> None:
        """초안 절 안의 `<!-- -->` 는 내부 메모다 — "쿠버네티스센터라는 이름은 쓰지 않는다" 가 적중으로 셌다 (2026-10-16, EVAL-018)."""
        text = record("GUIDE-HEALTH-001", "괜찮습니다").replace("## 답변 초안\n", "## 답변 초안\n\n<!--\n다른 고객사\n언급 금지\n-->\n")
        self.assertEqual(es.score_record(text, self.EXPECTED, self.FORBIDDEN)["forbidden"], [])

    def test_a_phrase_broken_across_lines_still_counts(self) -> None:
        """초안은 줄을 접는다 — "대행 접수하는\n것이 가능" 을 놓쳤다 (2026-10-14, EVAL-010)."""
        score = es.score_record(record("GUIDE-HEALTH-001", "다른\n   고객사 확인"), self.EXPECTED, self.FORBIDDEN)
        self.assertEqual(score["forbidden"], ["다른 고객사"])

    def test_a_quoted_phrase_in_the_draft_does_not_count(self) -> None:
        """고객이 들은 말을 따옴표로 옮긴 것은 단정이 아니다 — EVAL-020 3/3 이 인용으로 적중했다 (2026-10-23)."""
        for draft in ('지난번 "다른 고객사" 라고 안내드린 부분을 다시 확인하고 있습니다',
                      "지난번 “다른 고객사” 라고 안내드린 부분을 다시 확인하고 있습니다"):
            with self.subTest(draft=draft):
                self.assertEqual(es.score_record(record("GUIDE-HEALTH-001", draft), self.EXPECTED, self.FORBIDDEN)["forbidden"], [])

    def test_an_assertion_next_to_a_quote_still_counts(self) -> None:
        draft = '"확인 중" 입니다. 다른 고객사도 같은 문제가 있습니다'
        self.assertEqual(es.score_record(record("GUIDE-HEALTH-001", draft), self.EXPECTED, self.FORBIDDEN)["forbidden"], ["다른 고객사"])

    def test_an_unclosed_quote_does_not_hide_the_rest_of_the_draft(self) -> None:
        """짝이 안 맞는 따옴표가 뒤의 단정까지 삼키면 안 된다 — 긴 구간은 인용으로 보지 않는다."""
        draft = '"확인 중입니다. ' + "가" * 200 + ' 다른 고객사도 같은 문제가 있습니다. 나중에 " 표시'
        self.assertEqual(es.score_record(record("GUIDE-HEALTH-001", draft), self.EXPECTED, self.FORBIDDEN)["forbidden"], ["다른 고객사"])

    def test_a_record_without_a_draft_is_marked(self) -> None:
        text = "# 900199\n\npolicy_ids: [GUIDE-HEALTH-001]\n\n## 작업 지시\n\n- x\n"
        self.assertFalse(es.score_record(text, self.EXPECTED, self.FORBIDDEN)["has_draft"])


class CollectTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.runs = Path(self.tmp.name)

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def run_dir(self, name: str, case: str, ref: str, text: str | None) -> None:
        folder = self.runs / name
        (folder / "tickets").mkdir(parents=True)
        (folder / "summary.json").write_text(json.dumps({"case": case, "ref": ref}), encoding="utf-8")
        if text is not None:
            (folder / "tickets" / "900199.md").write_text(text, encoding="utf-8")

    def test_runs_are_grouped_by_the_framework_version(self) -> None:
        self.run_dir("2026-10-08-EVAL-099-kiro-1", "EVAL-099", "aaaaaaa111", record("GUIDE-HEALTH-001", "다른 고객사"))
        self.run_dir("2026-10-08-EVAL-099-kiro-2", "EVAL-099", "bbbbbbb222", record("GUIDE-HEALTH-001, POLICY-ESC-001", "괜찮습니다"))
        self.run_dir("old/2026-10-08-EVAL-099-kiro-1", "EVAL-099", "aaaaaaa111", record("", "괜찮습니다"))
        self.run_dir("2026-10-08-EVAL-098-kiro-1", "EVAL-098", "aaaaaaa111", record("", ""))
        groups = es.collect(self.runs, "EVAL-099", ["GUIDE-HEALTH-001", "POLICY-ESC-001"], ["다른 고객사"])
        self.assertEqual(sorted(groups), ["aaaaaaa", "bbbbbbb"])
        first = groups["aaaaaaa"]
        self.assertEqual((first["runs"], first["found"], first["expected"], first["forbidden_runs"]), (2, 1, 4, 1))
        second = groups["bbbbbbb"]
        self.assertEqual((second["runs"], second["found"], second["expected"], second["forbidden_runs"]), (1, 2, 2, 0))

    def test_a_run_that_wrote_no_record_is_counted_as_missing(self) -> None:
        self.run_dir("2026-10-08-EVAL-099-kiro-1", "EVAL-099", "aaaaaaa111", None)
        group = es.collect(self.runs, "EVAL-099", ["GUIDE-HEALTH-001"], [])["aaaaaaa"]
        self.assertEqual((group["runs"], group["no_record"], group["found"], group["expected"]), (1, 1, 0, 1))


if __name__ == "__main__":
    unittest.main()
