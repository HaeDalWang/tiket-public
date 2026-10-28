#!/usr/bin/env python3
"""scripts/kiro_engine.py 테스트. 실제 kiro-cli 설정은 건드리지 않는다 — 가짜 runner 로 본다.

kiro-cli 2.25.0 에서 확인한 실제 동작 (2026-09-29, 설정 백업 후 되돌림):
  get(없음)  → 종료 1, stderr "error: No value associated with chat.agentEngine"
  get(있음)  → 종료 0, stdout "v3 (global)"
  set        → 종료 0
"""

from __future__ import annotations

import importlib.util
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("kiro_engine", ROOT / "scripts/kiro_engine.py")
kiro_engine = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(kiro_engine)


class FakeKiro:
    def __init__(self, value: str | None) -> None:
        self.value = value
        self.calls: list[list[str]] = []

    def __call__(self, argv: list[str]) -> tuple[int, str]:
        self.calls.append(argv)
        if argv[1:] == ["settings", "chat.agentEngine"]:
            return (0, f"{self.value} (global)\n") if self.value else (1, "")
        if argv[1:] == ["settings", "chat.agentEngine", "v3"]:
            self.value = "v3"
            return 0, ""
        raise AssertionError(f"예상하지 못한 호출: {argv}")


class ReadTests(unittest.TestCase):
    def test_reads_the_value_without_the_scope_suffix(self) -> None:
        """`v3 (global)` 을 통째로 비교해 v3 사용자를 v2 로 알리던 버그 (v0.1.6)."""
        self.assertEqual(kiro_engine.current("kiro-cli", FakeKiro("v3")), "v3")

    def test_unset_is_none(self) -> None:
        self.assertIsNone(kiro_engine.current("kiro-cli", FakeKiro(None)))


class EnsureTests(unittest.TestCase):
    def test_unset_becomes_v3(self) -> None:
        """다들 v3 로 올려 놓고 --v3 를 안 붙여 v2 로 쓰고 있었다 — 값이 비어 있다."""
        fake = FakeKiro(None)
        changed, message = kiro_engine.ensure_v3("kiro-cli", fake)
        self.assertTrue(changed)
        self.assertEqual(fake.value, "v3")
        self.assertIn("kiro-cli settings -d chat.agentEngine", message, "되돌리는 명령을 알려야 한다")

    def test_already_v3_is_left_alone(self) -> None:
        fake = FakeKiro("v3")
        changed, message = kiro_engine.ensure_v3("kiro-cli", fake)
        self.assertFalse(changed)
        self.assertEqual(len(fake.calls), 1, "읽기만 해야 한다")
        self.assertEqual(message, "", "fetch-ticket 마다 떠든다")

    def test_an_explicit_choice_is_respected(self) -> None:
        """누군가 일부러 v2 를 적었다면 그 선택을 덮지 않는다."""
        fake = FakeKiro("v2")
        changed, message = kiro_engine.ensure_v3("kiro-cli", fake)
        self.assertFalse(changed)
        self.assertEqual(fake.value, "v2")
        self.assertIn("chat.agentEngine v3", message)

    def test_no_kiro_cli_does_nothing(self) -> None:
        changed, message = kiro_engine.ensure_v3(None, FakeKiro(None))
        self.assertFalse(changed)
        self.assertEqual(message, "")

    def test_a_broken_kiro_cli_never_raises(self) -> None:
        def boom(argv):
            raise OSError("kiro-cli")
        self.assertEqual(kiro_engine.ensure_v3("kiro-cli", boom), (False, ""))


class CallerTests(unittest.TestCase):
    """v2 사용자에게 닿는 길은 fetch-ticket 뿐이다(세션 훅이 안 돈다). 온보딩도 같은 스크립트를 쓴다."""

    def test_every_entry_point_uses_the_same_script(self) -> None:
        for name in ("fetch-ticket.sh", "fetch-ticket.ps1", "onboarding.sh", "onboarding.ps1"):
            text = (ROOT / "scripts" / name).read_text(encoding="utf-8")
            self.assertIn("kiro_engine.py", text, name)

    def test_fetch_ticket_keeps_stdout_clean(self) -> None:
        """stdout 은 티켓 본문이다. 안내는 stderr 로."""
        self.assertIn('kiro_engine.py" --ensure-v3 >&2', (ROOT / "scripts/fetch-ticket.sh").read_text(encoding="utf-8"))

    def test_onboarding_check_changes_nothing(self) -> None:
        for name in ("onboarding.sh", "onboarding.ps1"):
            text = (ROOT / "scripts" / name).read_text(encoding="utf-8")
            self.assertIn("kiro_engine.py", text, name)
            self.assertIn("--status", text, name)
            self.assertIn("--ensure-v3", text, name)


if __name__ == "__main__":
    unittest.main()
