#!/usr/bin/env python3
"""scripts/hermes_hook.py 테스트.

실제 `~/.hermes` 는 건드리지 않는다 — 전부 임시 디렉터리다. 실제 업데이트·전송도 하지 않는다 —
명령 실행은 가짜 `call` 로 받아 순서만 본다.
"""

from __future__ import annotations

import importlib.util
import json
import os
import shlex
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/hermes_hook.py"

spec = importlib.util.spec_from_file_location("hermes_hook", SCRIPT)
hermes_hook = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(hermes_hook)

try:
    import yaml  # noqa: F401 — 있으면 결과를 실제 YAML 로 읽어 본다
    HAS_YAML = True
except ImportError:  # pragma: no cover
    HAS_YAML = False


class RunHookTests(unittest.TestCase):
    """Hermes 가 on_session_start 때 부르는 쪽."""

    def setUp(self) -> None:
        self.calls: list[list[str]] = []

    def call(self, argv: list[str], cwd: Path) -> None:
        self.assertEqual(cwd, ROOT, "저장소 루트에서 돌려야 한다")
        self.calls.append(argv)

    def run_hook(self, payload, os_name: str = "posix") -> str:
        text = payload if isinstance(payload, str) else json.dumps(payload)
        return hermes_hook.run_hook(text, repo=ROOT, os_name=os_name, call=self.call)

    def test_outside_the_workspace_does_nothing(self) -> None:
        """훅은 모든 Hermes 세션에서 발동한다. tiket 이 아닌 곳에서는 아무것도 하지 않는다."""
        out = self.run_hook({"hook_event_name": "on_session_start", "cwd": str(ROOT.parent)})
        self.assertEqual(self.calls, [])
        self.assertEqual(json.loads(out), {})

    def test_inside_the_workspace_updates_then_sends(self) -> None:
        """세션 시작 훅과 같은 순서 — 업데이트가 끝난 뒤 전송한다 (2026-09-29)."""
        out = self.run_hook({"cwd": str(ROOT / "tickets")})
        self.assertEqual(len(self.calls), 2)
        self.assertEqual(self.calls[0][:2], ["bash", str(ROOT / "scripts/check-freshness.sh")])
        self.assertEqual(self.calls[1][1:], [str(ROOT / "scripts/report_usage.py"), "--if-due"])
        self.assertNotIn("--send", self.calls[1])
        self.assertEqual(json.loads(out), {})

    def test_windows_uses_the_powershell_freshness_check(self) -> None:
        self.run_hook({"cwd": str(ROOT)}, os_name="nt")
        self.assertEqual(self.calls[0][0], "pwsh")
        self.assertIn(str(ROOT / "scripts/check-freshness.ps1"), self.calls[0])
        self.assertIn(str(ROOT / "scripts/report_usage.py"), self.calls[1])

    def test_a_failed_update_still_sends(self) -> None:
        """`;` 와 같다 — 업데이트가 실패해도 전송은 돈다."""
        def flaky(argv, cwd):
            self.calls.append(argv)
            if len(self.calls) == 1:
                raise subprocess.TimeoutExpired(argv, 1)
        out = hermes_hook.run_hook(json.dumps({"cwd": str(ROOT)}), repo=ROOT, os_name="posix", call=flaky)
        self.assertEqual(len(self.calls), 2)
        self.assertEqual(json.loads(out), {})

    def test_bad_input_does_nothing_and_still_answers_json(self) -> None:
        """stdout 이 JSON 이 아니면 Hermes 가 경고를 남긴다. 어떤 입력에도 {} 로 답한다."""
        for payload in ("", "not json", "[]", json.dumps({"cwd": 3})):
            self.calls.clear()
            self.assertEqual(json.loads(self.run_hook(payload)), {}, payload)
            self.assertEqual(self.calls, [], payload)


class CommandTests(unittest.TestCase):
    def test_command_survives_spaces_in_the_path(self) -> None:
        """Hermes 는 command 를 shlex.split 한다. 한국어·공백 폴더에서도 경로 하나여야 한다."""
        repo = Path("/tmp/고객 지원/tiket")
        command = hermes_hook.hook_command(repo)
        self.assertEqual(shlex.split(command), [str(repo / "scripts/hermes_hook.py")])

    def test_script_runs_directly(self) -> None:
        """POSIX 에서 Hermes 는 command 를 그대로 Popen 한다 — 실행 비트와 shebang 이 있어야 한다."""
        self.assertTrue(os.access(SCRIPT, os.X_OK), "실행 비트가 없다")
        self.assertTrue(SCRIPT.read_text(encoding="utf-8").startswith("#!/usr/bin/env python3\n"))


class InstallTests(unittest.TestCase):
    """온보딩이 부르는 쪽. 사용자 전역 설정을 바꾸므로 백업하고, 모르는 모양은 건드리지 않는다."""

    COMMAND = "/repo/scripts/hermes_hook.py"

    def setUp(self) -> None:
        self.tempdir = tempfile.TemporaryDirectory(prefix="tiket-hermes-")
        self.home = Path(self.tempdir.name)
        self.config = self.home / "config.yaml"

    def tearDown(self) -> None:
        self.tempdir.cleanup()

    def install(self) -> int:
        code, _message = hermes_hook.install(self.home, self.COMMAND, stamp="20260929-120000")
        return code

    def backups(self) -> list[Path]:
        return sorted(self.home.glob("config.yaml.bak.tiket-*"))

    def assert_hook_registered(self) -> None:
        text = self.config.read_text(encoding="utf-8")
        self.assertEqual(text.count(self.COMMAND), 1, text)
        if HAS_YAML:
            import yaml
            entries = yaml.safe_load(text)["hooks"]["on_session_start"]
            self.assertEqual(entries[0]["command"], self.COMMAND)
            self.assertGreaterEqual(entries[0]["timeout"], 30)

    def test_appends_to_a_config_without_hooks_and_backs_up(self) -> None:
        original = "model:\n  default: x\nhooks_auto_accept: false\n"
        self.config.write_text(original, encoding="utf-8")
        self.assertEqual(self.install(), 0)
        self.assert_hook_registered()
        self.assertTrue(self.config.read_text(encoding="utf-8").startswith(original), "기존 내용을 바꿨다")
        self.assertEqual([b.read_text(encoding="utf-8") for b in self.backups()], [original])

    def test_file_without_trailing_newline(self) -> None:
        self.config.write_text("model: x", encoding="utf-8")
        self.assertEqual(self.install(), 0)
        self.assert_hook_registered()

    def test_replaces_an_empty_hooks_block(self) -> None:
        for empty in ("hooks: {}\n", "hooks:\n", "hooks: null\n"):
            self.config.write_text("model: x\n" + empty + "other: 1\n", encoding="utf-8")
            for backup in self.backups():
                backup.unlink()
            self.assertEqual(self.install(), 0, empty)
            self.assert_hook_registered()
            self.assertIn("other: 1", self.config.read_text(encoding="utf-8"))

    def test_second_run_changes_nothing(self) -> None:
        self.config.write_text("model: x\n", encoding="utf-8")
        self.install()
        after_first = self.config.read_text(encoding="utf-8")
        self.assertEqual(self.install(), 0)
        self.assertEqual(self.config.read_text(encoding="utf-8"), after_first)
        self.assertEqual(len(self.backups()), 1, "바뀐 것이 없는데 백업을 또 만들었다")

    def test_existing_hooks_are_left_alone(self) -> None:
        """남이 만든 hooks 는 YAML 파서 없이 안전하게 합칠 수 없다. 손대지 않고 방법을 알린다."""
        original = "hooks:\n  pre_tool_call:\n    - command: ~/x.sh\n"
        self.config.write_text(original, encoding="utf-8")
        code, message = hermes_hook.install(self.home, self.COMMAND, stamp="20260929-120000")
        self.assertEqual(code, 2)
        self.assertEqual(self.config.read_text(encoding="utf-8"), original)
        self.assertEqual(self.backups(), [])
        self.assertIn(self.COMMAND, message, "직접 넣을 내용을 알려야 한다")

    def test_creates_the_config_when_missing(self) -> None:
        self.assertEqual(self.install(), 0)
        self.assert_hook_registered()

    def test_status_reads_install_and_approval(self) -> None:
        self.assertEqual(hermes_hook.status(self.home, self.COMMAND), "missing")
        self.install()
        self.assertEqual(hermes_hook.status(self.home, self.COMMAND), "unapproved")
        (self.home / "shell-hooks-allowlist.json").write_text(json.dumps(
            {"approvals": [{"event": "on_session_start", "command": self.COMMAND}]}), encoding="utf-8")
        self.assertEqual(hermes_hook.status(self.home, self.COMMAND), "approved")


class TrustSkillsTests(unittest.TestCase):
    """Hermes 는 신뢰한 저장소의 .agents/skills 만 읽는다(v0.20.5 agent/skill_utils.py). 신뢰는 Hermes 명령으로 한다 —
    config.yaml 을 통째로 다시 쓰므로 먼저 백업한다. 훅 등록 백업과 같은 초에 만들어도 서로 덮지 않는다."""

    REPO = Path("/work/tiket")

    def setUp(self) -> None:
        self.tempdir = tempfile.TemporaryDirectory(prefix="tiket-hermes-")
        self.home = Path(self.tempdir.name)
        self.config = self.home / "config.yaml"
        self.config.write_text("model:\n  default: x\n", encoding="utf-8")
        self.calls: list[tuple[list[str], str | None]] = []
        self.reply = (0, f"Trusted: {self.REPO}\n")

    def tearDown(self) -> None:
        self.tempdir.cleanup()

    def run_cli(self, argv: list[str], env: dict[str, str]) -> tuple[int, str]:
        self.assertTrue(self.backups(), "백업보다 먼저 Hermes 가 설정을 바꿨다")
        self.calls.append((argv, env.get("HERMES_HOME")))
        return self.reply

    def trust(self, hermes: str | None = "/bin/hermes") -> tuple[int, str]:
        return hermes_hook.trust_skills(self.home, self.REPO, hermes=hermes, run=self.run_cli, stamp="20260929-120000")

    def backups(self) -> list[Path]:
        return sorted(self.home.glob("config.yaml.bak.tiket-*"))

    def test_trusts_this_workspace_through_hermes_after_a_backup(self) -> None:
        code, message = self.trust()
        self.assertEqual(code, 0)
        self.assertEqual(self.calls, [(["/bin/hermes", "skills", "trust", str(self.REPO)], str(self.home))])
        self.assertIn(f"hermes skills untrust {shlex.quote(str(self.REPO))}", message)

    def test_does_not_overwrite_the_hook_backup_from_the_same_second(self) -> None:
        hook_backup = self.home / "config.yaml.bak.tiket-20260929-120000"
        hook_backup.write_text("before hook\n", encoding="utf-8")
        self.trust()
        self.assertEqual(hook_backup.read_text(encoding="utf-8"), "before hook\n")
        self.assertEqual(len(self.backups()), 2)

    def test_already_trusted_leaves_no_backup(self) -> None:
        self.reply = (0, f"Already trusted: {self.REPO}\n")
        code, _ = self.trust()
        self.assertEqual(code, 0)
        self.assertEqual(self.backups(), [])

    def test_without_hermes_on_path_says_what_to_run_and_touches_nothing(self) -> None:
        code, message = self.trust(hermes=None)
        self.assertEqual(code, 2)
        self.assertIn(f"hermes skills trust {shlex.quote(str(self.REPO))}", message)
        self.assertEqual((self.calls, self.backups()), ([], []))

    def test_a_failed_trust_keeps_the_backup_and_is_not_ok(self) -> None:
        self.reply = (1, "boom\n")
        code, message = self.trust()
        self.assertEqual(code, 2)
        self.assertIn("boom", message)
        self.assertEqual(len(self.backups()), 1)


if __name__ == "__main__":
    unittest.main()
