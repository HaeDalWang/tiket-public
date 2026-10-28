#!/usr/bin/env python3
"""itsm_token.py — 온보딩이 엔지니어 본인의 ITSM 토큰을 받아 두는 단계.

틀리면 비싼 쪽은 둘이다: 같은 파일의 다른 키(유지보수자 PC 의 `DEV_ITSM_API_TOKEN`)를 지우는 것,
토큰 값을 화면에 내는 것. **어떤 테스트도 ITSM 에 닿지 않는다** — 확인 호출은 전부 가짜를 넣는다.
"""

from __future__ import annotations

import stat
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))

import itsm_token as ct  # noqa: E402
import customer_notes as cn  # noqa: E402

TOKEN = "cops_value-that-must-never-print"


def never_ask() -> str:
    raise AssertionError("묻지 않아야 한다")


class Conf(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory(prefix="tiket-itsm-")
        self.conf = Path(self._tmp.name) / ".config/msp/itsm"

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def write_conf(self, text: str) -> None:
        self.conf.parent.mkdir(parents=True, exist_ok=True)
        self.conf.write_text(text, encoding="utf-8")


class WithTokenTests(unittest.TestCase):
    def test_rewrites_only_the_token_key_and_keeps_every_other_line(self) -> None:
        before = '# 메모\nDEV_ITSM_API_TOKEN=dev-value\nexport ITSM_API_TOKEN=""\nOTHER=1\n'
        after = ct.with_token(before, "cops_new")
        self.assertEqual(after.splitlines(),
                         ["# 메모", "DEV_ITSM_API_TOKEN=dev-value", "OTHER=1", "ITSM_API_TOKEN=cops_new"])

    def test_the_reader_sees_the_new_token_even_when_an_old_line_came_first(self) -> None:
        """customer_notes.token_from 은 첫 줄이 이긴다. 옛 줄을 남기면 새 토큰이 안 읽힌다."""
        with tempfile.TemporaryDirectory() as tmp:
            conf = Path(tmp) / "itsm"
            conf.write_text(ct.with_token("ITSM_API_TOKEN=old\nDEV_ITSM_API_TOKEN=dev\n", "cops_new"),
                            encoding="utf-8")
            self.assertEqual(cn.token_from(conf, "ITSM_API_TOKEN"), "cops_new")
            self.assertEqual(cn.token_from(conf, "DEV_ITSM_API_TOKEN"), "dev")


class SetupTests(Conf):
    def test_saves_the_token_with_mode_600_and_keeps_the_dev_key(self) -> None:
        self.write_conf("DEV_ITSM_API_TOKEN=dev-value\n")
        ready, message = ct.setup(self.conf, write=True, ask=lambda: TOKEN)
        self.assertTrue(ready)
        self.assertNotIn(TOKEN, message)
        self.assertEqual(stat.S_IMODE(self.conf.stat().st_mode), 0o600)
        self.assertEqual(cn.token_from(self.conf, "ITSM_API_TOKEN"), TOKEN)
        self.assertEqual(cn.token_from(self.conf, "DEV_ITSM_API_TOKEN"), "dev-value")

    def test_a_token_already_set_is_reported_and_never_asked_again(self) -> None:
        self.write_conf(f"ITSM_API_TOKEN={TOKEN}\n")
        ready, message = ct.setup(self.conf, write=True, ask=never_ask)
        self.assertTrue(ready)
        self.assertIn("설정됨", message)
        self.assertNotIn(TOKEN, message)

    def test_only_the_dev_token_does_not_count(self) -> None:
        self.write_conf("DEV_ITSM_API_TOKEN=dev-value\n")
        ready, _ = ct.setup(self.conf, write=False, ask=None)
        self.assertFalse(ready)

    def test_check_mode_reports_the_gap_and_writes_nothing(self) -> None:
        ready, message = ct.setup(self.conf, write=False, ask=None)
        self.assertFalse(ready)
        self.assertIn("onboarding", message)
        self.assertFalse(self.conf.exists())

    def test_without_a_terminal_it_neither_asks_nor_writes(self) -> None:
        ready, message = ct.setup(self.conf, write=True, ask=None)
        self.assertFalse(ready)
        self.assertIn("터미널", message)
        self.assertFalse(self.conf.exists())

    def test_skipping_writes_nothing(self) -> None:
        self.write_conf("DEV_ITSM_API_TOKEN=dev-value\n")
        ready, _ = ct.setup(self.conf, write=True, ask=lambda: None)
        self.assertFalse(ready)
        self.assertEqual(self.conf.read_text(encoding="utf-8"), "DEV_ITSM_API_TOKEN=dev-value\n")

    def test_an_unreadable_conf_is_left_alone(self) -> None:
        """읽지 못한 파일을 덮으면 그 안의 다른 키가 사라진다."""
        self.conf.parent.mkdir(parents=True)
        self.conf.write_bytes(b"DEV_ITSM_API_TOKEN=\xff\xfe\n")
        ready, _ = ct.setup(self.conf, write=True, ask=lambda: TOKEN)
        self.assertFalse(ready)
        self.assertEqual(self.conf.read_bytes(), b"DEV_ITSM_API_TOKEN=\xff\xfe\n")


class PromptTests(unittest.TestCase):
    def prompt(self, answers: list[str], verdicts: dict[str, bool | None] | None = None) -> tuple[str | None, list[str]]:
        said: list[str] = []
        replies = iter(answers)
        result = ct.prompt_token(lambda _prompt: next(replies), lambda token: (verdicts or {}).get(token, True),
                                 said.append)
        return result, said

    def test_blank_wrong_shape_and_rejected_tokens_are_asked_again(self) -> None:
        result, said = self.prompt(["", "zendesk-token", "cops_rejected", TOKEN], {"cops_rejected": False})
        self.assertEqual(result, TOKEN)
        text = "\n".join(said)
        self.assertIn("값이 필요하다", text)
        self.assertIn("cops_", text)
        self.assertIn("401", text)
        self.assertNotIn(TOKEN, text)

    def test_skip_returns_nothing(self) -> None:
        self.assertIsNone(self.prompt(["skip"])[0])

    def test_an_unverifiable_token_is_kept_and_said_so(self) -> None:
        result, said = self.prompt([TOKEN], {TOKEN: None})
        self.assertEqual(result, TOKEN)
        self.assertIn("확인하지 못했다", "\n".join(said))

    def test_explains_that_each_engineer_issues_their_own(self) -> None:
        _, said = self.prompt([TOKEN])
        text = "\n".join(said)
        self.assertIn("각자", text)
        self.assertIn("API 토큰", text)


class TokenWorksTests(unittest.TestCase):
    def test_one_get_to_my_tokens_on_the_production_server(self) -> None:
        calls: list[tuple[str, str]] = []

        def fake(url: str, token: str, timeout: int):
            calls.append((url, token))
            return 200, []

        self.assertTrue(ct.token_works(TOKEN, fake))
        self.assertEqual(calls, [("https://itsm.example.com/api/me/tokens", TOKEN)])

    def test_statuses_map_to_yes_no_and_unknown(self) -> None:
        for status, verdict in ((401, False), (403, False), (500, None), (404, None)):
            with self.subTest(status=status):
                self.assertIs(ct.token_works(TOKEN, lambda *_: (status, None)), verdict)

    def test_network_failure_is_unknown(self) -> None:
        def down(*_):
            raise OSError("timed out")

        self.assertIsNone(ct.token_works(TOKEN, down))


if __name__ == "__main__":
    unittest.main(verbosity=2)
