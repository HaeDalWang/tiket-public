#!/usr/bin/env python3
"""skill_setup — 온보딩 5단계가 설치기 대신 conf·csg-login 마커·빌링 플랫폼 키를 직접 맞춘다 (0040 3단계 조각 C-2).

임시 HOME·임시 워크스페이스에서만 돈다. 키 확인은 가짜 함수로 바꾼다 — 네트워크에 닿지 않는다.
"""

from __future__ import annotations

import os
import stat
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))

import skill_setup as ss  # noqa: E402

SKILL = "aws-customer-account-ops"
STAMP = "20261020-160000"
KEY = "fc-key-should-never-print"
DEFAULTS = "# 설명\nAPI_URL=https://broker.example/Prod/v1/credentials\nCLIENT_ID=123.456\n"
HAS_AWS = lambda name: f"/usr/bin/{name}"  # noqa: E731


class SetupTests(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory(prefix="tiket-skill-setup-")
        base = Path(self._tmp.name)
        self.home = base / "home"
        self.home.mkdir()
        self.root = base / "tiket"
        (self.root / ".git").mkdir(parents=True)
        self.skill = self.root / "skills" / SKILL
        self.skill.mkdir(parents=True)
        for name in ("get-sts-token.sh", "get-sts-token.ps1"):
            (self.skill / name).write_text("#\n", encoding="utf-8")
        (self.skill / "broker-defaults.conf").write_text(DEFAULTS, encoding="utf-8")
        self.config = self.home / ".aws/config"
        self.conf = self.home / ".config/msp/credential-broker.conf"
        self.asked = 0

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def ask(self, answer: str | None = KEY):
        def ask_key() -> str | None:
            self.asked += 1
            return answer
        return ask_key

    def run_setup(self, *, write: bool = True, os_name: str = "posix", env: dict[str, str] | None = None,
                  ask_key=None, which=HAS_AWS) -> tuple[bool, str]:
        return ss.setup(self.root, self.home, env or {}, write=write, os_name=os_name, which=which,
                        ask_key=ask_key, stamp=STAMP)

    def conf_text(self) -> str:
        return self.conf.read_text(encoding="utf-8")

    # ── 새 동료 ──────────────────────────────────────────────────────────
    def test_a_new_pc_gets_conf_marker_and_key_and_is_ready(self) -> None:
        ready, message = self.run_setup(ask_key=self.ask())
        self.assertTrue(ready, message)
        self.assertEqual(self.conf_text(), "API_URL=https://broker.example/Prod/v1/credentials\nCLIENT_ID=123.456\n"
                         f"BILLING_API_KEY={KEY}\n")
        self.assertEqual(self.config.read_text(encoding="utf-8"),
                         f"[profile csg-login]\ncredential_process = {self.skill}/get-sts-token.sh\nregion = ap-northeast-2\n")
        self.assertNotIn(KEY, message)

    def test_conf_holding_the_key_is_readable_only_by_its_owner(self) -> None:
        if os.name == "nt":
            self.skipTest("POSIX 권한")
        self.run_setup(ask_key=self.ask())
        self.assertEqual(stat.S_IMODE(self.conf.stat().st_mode), 0o600)

    def test_windows_marker_runs_the_powershell_script(self) -> None:
        self.run_setup(os_name="nt", ask_key=self.ask())
        self.assertIn(f'credential_process = pwsh -NoProfile -File "{self.skill / "get-sts-token.ps1"}"\n',
                      self.config.read_text(encoding="utf-8"))

    def test_an_existing_aws_config_is_backed_up_and_only_gains_the_marker(self) -> None:
        self.config.parent.mkdir(parents=True)
        original = "[default]\r\nregion = us-east-1\r\n"
        self.config.write_bytes(original.encode("utf-8"))
        self.run_setup(ask_key=self.ask())
        self.assertEqual(self.config.read_bytes().decode("utf-8"), original + "\r\n[profile csg-login]\r\n"
                         f"credential_process = {self.skill}/get-sts-token.sh\r\nregion = ap-northeast-2\r\n")
        self.assertEqual((self.home / f".aws/config.bak.tiket-{STAMP}").read_bytes(), original.encode("utf-8"))

    # ── 키 ───────────────────────────────────────────────────────────────
    def test_a_key_already_in_the_environment_is_not_asked_again(self) -> None:
        """옛 설치기는 키를 셸 프로필의 export 로 남겼다. billing-api 는 환경변수를 먼저 읽는다."""
        ready, _ = self.run_setup(env={"BILLING_API_KEY": KEY}, ask_key=self.ask())
        self.assertTrue(ready)
        self.assertEqual(self.asked, 0)
        self.assertNotIn("BILLING_API_KEY", self.conf_text())

    def test_a_key_already_in_conf_is_kept_and_not_asked(self) -> None:
        self.conf.parent.mkdir(parents=True)
        self.conf.write_text(f"BILLING_API_KEY={KEY}\nSLACK_ACCESS_TOKEN=keep\n", encoding="utf-8")
        ready, _ = self.run_setup(ask_key=self.ask())
        self.assertTrue(ready)
        self.assertEqual(self.asked, 0)
        self.assertEqual(self.conf_text(), f"BILLING_API_KEY={KEY}\nSLACK_ACCESS_TOKEN=keep\n"
                         "API_URL=https://broker.example/Prod/v1/credentials\nCLIENT_ID=123.456\n")

    def test_without_a_terminal_the_rest_is_set_up_and_the_key_is_named_as_missing(self) -> None:
        ready, message = self.run_setup(ask_key=None)
        self.assertFalse(ready)
        self.assertIn("빌링 플랫폼", message)
        self.assertIn("onboarding", message)
        self.assertTrue(self.config.is_file())
        self.assertNotIn("BILLING_API_KEY", self.conf_text())

    def test_skipping_the_key_leaves_lookup_limited(self) -> None:
        ready, message = self.run_setup(ask_key=self.ask(None))
        self.assertFalse(ready)
        self.assertIn("빌링 플랫폼", message)

    # ── 이미 설치된 PC ───────────────────────────────────────────────────
    def test_a_stale_broker_address_is_replaced_and_other_lines_stay(self) -> None:
        """스택을 다시 만들면 주소가 바뀐다 — 옛 설치기도 이 줄만 고쳤다. 토큰 캐시 줄은 그대로 둔다."""
        self.conf.parent.mkdir(parents=True)
        self.conf.write_text("API_URL=https://old.example/x\nCLIENT_ID=123.456\nSLACK_ACCESS_TOKEN=keep\n"
                             "EXTERNAL_ID=legacy\n", encoding="utf-8")
        self.run_setup(env={"BILLING_API_KEY": KEY})
        self.assertEqual(self.conf_text(), "API_URL=https://broker.example/Prod/v1/credentials\nCLIENT_ID=123.456\n"
                         "SLACK_ACCESS_TOKEN=keep\nEXTERNAL_ID=legacy\n")

    def test_home_copies_are_moved_into_the_workspace_first(self) -> None:
        """세션을 열기 전에 온보딩부터 돌려도 같은 결과가 된다 — 세부는 test_skill_migration.py."""
        old = self.home / ".kiro/skills" / SKILL
        old.mkdir(parents=True)
        (old / "get-sts-token.sh").write_text("#\n", encoding="utf-8")
        self.config.parent.mkdir(parents=True)
        self.config.write_text(f"[profile csg-login]\ncredential_process = {old}/get-sts-token.sh\n", encoding="utf-8")
        ready, message = self.run_setup(env={"BILLING_API_KEY": KEY})
        self.assertTrue(ready, message)
        self.assertFalse(old.exists())
        self.assertIn(f"credential_process = {self.skill}/get-sts-token.sh\n", self.config.read_text(encoding="utf-8"))
        self.assertIn("되돌리기", message)

    def test_a_marker_pointing_at_a_missing_file_is_repointed(self) -> None:
        self.config.parent.mkdir(parents=True)
        self.config.write_text("[profile csg-login]\ncredential_process = /gone/get-sts-token.sh\nregion = ap-northeast-2\n"
                               "[profile x]\nregion = a\n", encoding="utf-8")
        self.run_setup(env={"BILLING_API_KEY": KEY})
        self.assertEqual(self.config.read_text(encoding="utf-8"),
                         f"[profile csg-login]\ncredential_process = {self.skill}/get-sts-token.sh\n"
                         "region = ap-northeast-2\n[profile x]\nregion = a\n")

    def test_a_marker_section_without_a_command_gains_one_in_place(self) -> None:
        self.config.parent.mkdir(parents=True)
        self.config.write_text("[profile csg-login]\nregion = ap-northeast-2\n[profile x]\nregion = a\n", encoding="utf-8")
        self.run_setup(env={"BILLING_API_KEY": KEY})
        self.assertEqual(self.config.read_text(encoding="utf-8"),
                         f"[profile csg-login]\ncredential_process = {self.skill}/get-sts-token.sh\n"
                         "region = ap-northeast-2\n[profile x]\nregion = a\n")

    def test_a_working_setup_is_left_byte_for_byte(self) -> None:
        self.run_setup(env={"BILLING_API_KEY": KEY})
        before = (self.config.read_bytes(), self.conf.read_bytes())
        ready, _ = self.run_setup(env={"BILLING_API_KEY": KEY})
        self.assertTrue(ready)
        self.assertEqual((self.config.read_bytes(), self.conf.read_bytes()), before)
        self.assertEqual(list(self.config.parent.glob("config.bak.*")), [])

    # ── 쓰지 않는다 ──────────────────────────────────────────────────────
    def test_check_mode_writes_nothing_and_names_each_gap(self) -> None:
        ready, message = self.run_setup(write=False, ask_key=self.ask())
        self.assertFalse(ready)
        self.assertEqual(self.asked, 0)
        self.assertFalse(self.config.exists())
        self.assertFalse(self.conf.exists())
        for gap in ("conf", "csg-login", "빌링 플랫폼"):
            self.assertIn(gap, message)

    def test_a_worktree_never_becomes_the_marker(self) -> None:
        """워크트리를 가리키면 그 폴더를 지울 때 조회가 깨진다 — 세션 전환과 같은 선."""
        (self.root / ".git").rmdir()
        (self.root / ".git").write_text("gitdir: /elsewhere\n", encoding="utf-8")
        ready, message = self.run_setup(env={"BILLING_API_KEY": KEY})
        self.assertFalse(ready)
        self.assertFalse(self.config.exists())
        self.assertIn("메인", message)

    def test_a_posix_path_with_spaces_is_not_written_unquoted(self) -> None:
        spaced = self.root.parent / "고객 지원"
        self.root.rename(spaced)
        self.root, self.skill = spaced, spaced / "skills" / SKILL
        ready, message = self.run_setup(env={"BILLING_API_KEY": KEY})
        self.assertFalse(ready)
        self.assertFalse(self.config.exists())
        self.assertIn("공백", message)

    def test_missing_aws_cli_is_named(self) -> None:
        ready, message = self.run_setup(env={"BILLING_API_KEY": KEY}, which=lambda name: None)
        self.assertFalse(ready)
        self.assertIn("aws CLI", message)


class MarkerTargetTests(unittest.TestCase):
    def test_both_marker_forms_resolve_to_the_script(self) -> None:
        self.assertEqual(ss.marker_target("/a/b/get-sts-token.sh"), "/a/b/get-sts-token.sh")
        self.assertEqual(ss.marker_target('pwsh -NoProfile -File "C:\\t\\get-sts-token.ps1"'), "C:\\t\\get-sts-token.ps1")
        self.assertEqual(ss.marker_target(""), "")


class PromptKeyTests(unittest.TestCase):
    def prompt(self, answers: list[str], verdicts: dict[str, bool | None] | None = None) -> tuple[str | None, list[str]]:
        said: list[str] = []
        replies = iter(answers)
        key = ss.prompt_key(lambda _: next(replies), lambda k: (verdicts or {}).get(k, True), said.append)
        return key, said

    def test_an_empty_answer_is_asked_again_and_skip_must_be_typed(self) -> None:
        key, said = self.prompt(["", "skip"])
        self.assertIsNone(key)
        self.assertTrue(any("값이 필요하다" in line for line in said))

    def test_a_rejected_key_is_asked_again(self) -> None:
        key, said = self.prompt(["wrong", KEY], {"wrong": False})
        self.assertEqual(key, KEY)
        self.assertTrue(any("맞지 않는다" in line for line in said))
        self.assertFalse(any(KEY in line or "wrong" in line for line in said))

    def test_an_unreachable_check_keeps_the_key_and_says_so(self) -> None:
        key, said = self.prompt([KEY], {KEY: None})
        self.assertEqual(key, KEY)
        self.assertTrue(any("확인하지 못했다" in line for line in said))

    def test_end_of_input_skips(self) -> None:
        def closed(_: str) -> str:
            raise EOFError
        self.assertIsNone(ss.prompt_key(closed, lambda k: True, lambda line: None))


if __name__ == "__main__":
    unittest.main()
