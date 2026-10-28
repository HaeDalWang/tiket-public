#!/usr/bin/env python3
"""scripts/session_start.py 테스트. 실제 업데이트·전송은 하지 않는다 — 가짜 `call` 로 순서만 본다."""

from __future__ import annotations

import importlib.util
import subprocess
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("session_start", ROOT / "scripts/session_start.py")
session_start = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(session_start)


class SessionStartTests(unittest.TestCase):
    def setUp(self) -> None:
        self.calls: list[list[str]] = []

    def call(self, argv: list[str], cwd: Path) -> None:
        self.assertEqual(cwd, ROOT)
        self.calls.append(argv)

    def test_updates_then_sends(self) -> None:
        """다른 호스트의 `check-freshness; report_usage --if-due` 와 같은 순서 (2026-09-29)."""
        session_start.run(ROOT, "posix", self.call)
        self.assertEqual(self.calls[0], ["bash", str(ROOT / "scripts/check-freshness.sh")])
        self.assertEqual(self.calls[1], [sys.executable, str(ROOT / "scripts/report_usage.py"), "--if-due"])
        self.assertEqual(len(self.calls), 2)

    def test_windows_uses_powershell_for_the_update(self) -> None:
        session_start.run(ROOT, "nt", self.call)
        self.assertEqual(self.calls[0][0], "pwsh")
        self.assertEqual(self.calls[0][-1], str(ROOT / "scripts/check-freshness.ps1"))

    def test_a_failed_update_still_sends(self) -> None:
        def flaky(argv, cwd):
            self.calls.append(argv)
            if len(self.calls) == 1:
                raise FileNotFoundError("bash")
        session_start.run(ROOT, "posix", flaky)
        self.assertEqual(len(self.calls), 2)

    def test_a_failed_send_is_swallowed(self) -> None:
        def always_fails(argv, cwd):
            self.calls.append(argv)
            raise subprocess.TimeoutExpired(argv, 1)
        session_start.run(ROOT, "posix", always_fails)  # 예외가 나오면 실패다
        self.assertEqual(len(self.calls), 2)

    def test_update_notices_reach_the_agent(self) -> None:
        """업데이트 알림은 stdout 으로 에이전트에게 가야 한다(Kiro·Claude 는 stdout 을 맥락에 넣는다).
        stderr 는 버린다 — Kiro 는 stdout 이 비면 stderr 를 맥락에 넣는다."""
        self.assertIsNone(session_start.STDOUT)
        self.assertEqual(session_start.STDERR, subprocess.DEVNULL)


if __name__ == "__main__":
    unittest.main()
