#!/usr/bin/env python3
"""customer_notes.py 가 **그 고객 것만 읽고, 못 읽으면 멈추라고 말하는지** 본다.

틀리면 비싼 쪽은 "못 읽었는데 읽은 것처럼 끝나는 것" 이다 — `금지` 항목을 모른 채 고객 계정을
조회하게 된다(development/decisions/0034). 그래서 실패 경로를 하나씩 종료 코드 2 로 못 박는다.

**어떤 테스트도 ITSM 에 닿지 않는다.** 네트워크는 `fetch` 한 곳뿐이고 전부 가짜를 넣는다.
"""

from __future__ import annotations

import contextlib
import importlib.util
import io
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

spec = importlib.util.spec_from_file_location("customer_notes", ROOT / "scripts/customer_notes.py")
customer_notes = importlib.util.module_from_spec(spec)
spec.loader.exec_module(customer_notes)

CORP = "92c6b5c3-ae30-4ab5-a763-6f151f4ba9be"
TOKEN = "cops-token-value-for-tests"
CUSTOMER = {"id": "cust-1", "name": "합성고객", "billing_corp_id": CORP}


def note(severity: str, content: str, **extra) -> dict:
    labels = {"prohibit": "금지", "caution": "주의", "info": "참고"}
    return {
        "id": f"cnote-{severity}", "category": "access", "category_label": "접근 제약",
        "severity": severity, "severity_label": labels[severity], "content": content,
        "evidence": "2026-09-30 담당자 메일", "verification": "assumed", "review_at": None,
        "review_due": False, "created_by": "engineer",
        "created_at": "2026-10-02T06:00:00.000Z", "active": True, **extra,
    }


class FakeServer:
    """`fetch(url, token, timeout)` 자리에 들어간다. 부른 URL 을 남긴다."""

    def __init__(self, lookup=(200, {**CUSTOMER, "status": "active"}), notes=None) -> None:
        self.lookup = lookup
        self.notes = notes if notes is not None else (200, {"customer": CUSTOMER, "notes": []})
        self.calls: list[tuple[str, str]] = []

    def __call__(self, url: str, token: str, timeout: int):
        self.calls.append((url, token))
        answer = self.lookup if "/lookup?" in url else self.notes
        if isinstance(answer, Exception):
            raise answer
        return answer


class Harness(unittest.TestCase):
    def setUp(self) -> None:
        self.tempdir = tempfile.TemporaryDirectory(prefix="tiket-notes-")
        self.conf = Path(self.tempdir.name) / "itsm"
        self.conf.write_text(f"ITSM_API_TOKEN={TOKEN}\n", encoding="utf-8")

    def tearDown(self) -> None:
        self.tempdir.cleanup()

    def run_main(self, server: FakeServer, *argv: str) -> tuple[int, str, str]:
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = customer_notes.main(list(argv) or [CORP], fetch=server, conf=self.conf)
        return code, out.getvalue(), err.getvalue()


class ReadTests(Harness):
    def test_prints_the_customer_and_each_note_with_its_grade(self) -> None:
        server = FakeServer(notes=(200, {"customer": CUSTOMER, "notes": [
            note("prohibit", "Payer 계정은 담당 엔지니어만 접근한다", verification="confirmed",
                 review_at="2026-01-01", review_due=True),
            note("info", "월간 리뷰는 대면으로 한다"),
        ]}))

        code, out, _ = self.run_main(server)

        self.assertEqual(code, 0)
        self.assertIn(f"고객: 합성고객 (corpId {CORP})", out)
        self.assertIn("특이사항 2건 — 금지 1 · 참고 1", out)
        self.assertIn("- [금지][접근 제약][확인] Payer 계정은 담당 엔지니어만 접근한다", out)
        self.assertIn("- [참고][접근 제약][추측] 월간 리뷰는 대면으로 한다", out)
        self.assertIn("근거: 2026-09-30 담당자 메일", out)
        self.assertIn("재확인 2026-01-01 (지남)", out)
        self.assertLess(out.index("[금지]"), out.index("[참고]"))

    def test_no_notes_is_a_successful_read_that_says_so(self) -> None:
        code, out, _ = self.run_main(FakeServer())

        self.assertEqual(code, 0)
        self.assertIn("고객: 합성고객", out)
        self.assertIn("특이사항 없음", out)

    def test_looks_up_by_quoted_corp_id_then_reads_that_customer_only(self) -> None:
        odd = "a b&c"
        customer = {**CUSTOMER, "billing_corp_id": odd}
        server = FakeServer(lookup=(200, customer), notes=(200, {"customer": customer, "notes": []}))

        code, _, _ = self.run_main(server, odd)

        self.assertEqual(code, 0)
        self.assertEqual([url for url, _ in server.calls], [
            "https://itsm.example.com/api/customers/lookup?corpId=a%20b%26c",
            "https://itsm.example.com/api/customers/cust-1/notes",
        ])

    def test_dev_flag_uses_the_dev_server_and_the_dev_token(self) -> None:
        self.conf.write_text(f'ITSM_API_TOKEN={TOKEN}\nexport DEV_ITSM_API_TOKEN="dev-token"\n', encoding="utf-8")
        server = FakeServer()

        code, _, _ = self.run_main(server, CORP, "--dev")

        self.assertEqual(code, 0)
        self.assertTrue(all(url.startswith("https://dev.itsm.example.com/") for url, _ in server.calls))
        self.assertEqual({token for _, token in server.calls}, {"dev-token"})


class StopTests(Harness):
    """못 읽은 것은 전부 종료 코드 2 이고, 계정 조회를 시작하지 말라고 말한다."""

    def assert_stops(self, server: FakeServer, *argv: str, calls: int | None = None) -> str:
        code, out, err = self.run_main(server, *argv)
        self.assertEqual(code, 2)
        self.assertEqual(out, "")
        self.assertIn("계정 조회를 시작하지 않는다", err)
        self.assertNotIn(TOKEN, out + err)
        if calls is not None:
            self.assertEqual(len(server.calls), calls)
        return err

    def assert_not_set_up(self) -> None:
        """토큰을 등록한 적이 없다 — 멈춤(2)이 아니라 3. 계정 조회는 빌링 플랫폼 키로 되니 경고하고 진행한다(0034 개정 2)."""
        server = FakeServer()
        code, out, err = self.run_main(server)
        self.assertEqual(code, 3)
        self.assertEqual(out, "")
        self.assertEqual(server.calls, [])
        self.assertIn("특이사항 미확인", err)
        self.assertNotIn("계정 조회를 시작하지 않는다", err)

    def test_missing_token_file_is_not_set_up_not_a_stop(self) -> None:
        self.conf.unlink()
        self.assert_not_set_up()

    def test_token_file_without_the_key_is_not_set_up_not_a_stop(self) -> None:
        self.conf.write_text("DEV_ITSM_API_TOKEN=dev-token\n", encoding="utf-8")
        self.assert_not_set_up()

    def test_undecodable_token_file_stops_before_any_call(self) -> None:
        """라우터는 종료 코드 2 를 보고 멈춘다. 읽다 죽어 1 로 끝나면 '멈춤' 으로 읽히지 않는다."""
        self.conf.write_bytes(b"ITSM_API_TOKEN=\xff\xfe\n")
        self.assertIn("토큰", self.assert_stops(FakeServer(), calls=0))

    def test_blank_corp_id_stops_before_any_call(self) -> None:
        self.assert_stops(FakeServer(), "  ", calls=0)

    def test_unknown_customer_stops(self) -> None:
        err = self.assert_stops(FakeServer(lookup=(404, {"error": "해당 corpId 의 고객사가 없습니다."})), calls=1)
        self.assertIn("404", err)

    def test_rejected_token_stops(self) -> None:
        self.assert_stops(FakeServer(lookup=(401, {"error": "Unauthorized"})), calls=1)

    def test_network_failure_stops(self) -> None:
        self.assert_stops(FakeServer(lookup=OSError("timed out")))

    def test_notes_failure_after_lookup_stops(self) -> None:
        self.assert_stops(FakeServer(notes=(500, {"error": "Internal server error"})), calls=2)

    def test_notes_of_another_customer_stop(self) -> None:
        other = {**CUSTOMER, "billing_corp_id": "another-corp"}
        err = self.assert_stops(FakeServer(notes=(200, {"customer": other, "notes": [note("info", "남의 것")]})))
        self.assertNotIn("남의 것", err)

    def test_response_without_notes_stops(self) -> None:
        self.assert_stops(FakeServer(notes=(200, {"customer": CUSTOMER})))

    def test_response_that_is_not_json_stops(self) -> None:
        self.assert_stops(FakeServer(lookup=ValueError("Expecting value")))


if __name__ == "__main__":
    unittest.main()
