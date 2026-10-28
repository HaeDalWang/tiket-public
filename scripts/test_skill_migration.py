#!/usr/bin/env python3
"""skill_migration — 세션 시작이 고객 AWS 조회 스킬을 $HOME 사본에서 이 워크스페이스로 옮긴다 (0040 3단계 조각 C).

임시 HOME·임시 워크스페이스에서만 돈다. 네트워크에 닿지 않는다.
"""

from __future__ import annotations

import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))

import skill_migration as sm  # noqa: E402

SKILL = "aws-customer-account-ops"
STAMP = "20261020-140000"


class MigrationTests(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory(prefix="tiket-skill-migration-")
        base = Path(self._tmp.name)
        self.home = base / "home"
        self.root = base / "tiket"
        (self.root / ".git").mkdir(parents=True)
        self.new = self.root / "skills" / SKILL
        self.new.mkdir(parents=True)
        (self.new / "get-sts-token.sh").write_text("#!/bin/sh\n", encoding="utf-8")
        self.config = self.home / ".aws/config"
        self.config.parent.mkdir(parents=True)

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def copy(self, host: str) -> Path:
        folder = self.home / host / "skills" / SKILL
        folder.mkdir(parents=True)
        (folder / "SKILL.md").write_text(f"old {host}\n", encoding="utf-8")
        return folder

    def write_config(self, text: str) -> str:
        self.config.write_bytes(text.encode("utf-8"))
        return text

    def migrate(self, os_name: str = "posix", env: dict[str, str] | None = None) -> str | None:
        return sm.migrate(self.root, self.home, env or {}, os_name=os_name, stamp=STAMP)

    def standard(self) -> str:
        claude, kiro = self.copy(".claude"), self.copy(".kiro")
        self.copy(".hermes")
        return self.write_config(
            "[default]\nregion = ap-northeast-2\n\n"
            f"[profile csg-login]\ncredential_process = {kiro}/get-sts-token.sh\n\n"
            "[profile csg-acme]\ncsg_managed = true\n"
            f"credential_process = {claude}/get-customer-credentials.sh --account-id ACCOUNT\n"
            "region = ap-northeast-2\n\n"
            "[profile personal]\nregion = us-east-1\n"
        )

    def backups(self) -> list[Path]:
        return sorted(self.config.parent.glob("config.bak.tiket-*"))

    # ── 바꾼다 ───────────────────────────────────────────────────────────
    def test_csg_profiles_point_at_the_workspace_and_nothing_else_changes(self) -> None:
        original = self.standard()
        self.migrate()
        expected = (original
                    .replace(str(self.home / ".kiro/skills" / SKILL), str(self.new))
                    .replace(str(self.home / ".claude/skills" / SKILL), str(self.new)))
        self.assertEqual(self.config.read_text(encoding="utf-8"), expected)
        self.assertIn(f"{self.new}/get-customer-credentials.sh --account-id ACCOUNT\n", expected)

    def test_config_is_backed_up_before_it_changes(self) -> None:
        original = self.standard()
        self.migrate()
        self.assertEqual([b.read_text(encoding="utf-8") for b in self.backups()], [original])

    def test_home_copies_move_to_a_backup_folder_so_no_host_reads_them(self) -> None:
        self.standard()
        self.copy(".agents")
        self.migrate()
        kept = self.home / f".config/msp/skill-home-copies-{STAMP}"
        for host in (".claude", ".kiro", ".agents", ".hermes"):
            self.assertFalse((self.home / host / "skills" / SKILL).exists(), host)
            self.assertEqual((kept / host / SKILL / "SKILL.md").read_text(encoding="utf-8"), f"old {host}\n")

    def test_says_what_moved_and_how_to_undo_it(self) -> None:
        self.standard()
        message = self.migrate()
        self.assertIsNotNone(message)
        self.assertIn(str(self.backups()[0]), message)
        self.assertIn(f"skill-home-copies-{STAMP}/.claude/{SKILL}", message)
        self.assertIn("되돌리기", message)

    def test_second_run_is_silent_and_changes_nothing(self) -> None:
        self.standard()
        self.migrate()
        after = self.config.read_bytes()
        self.assertIsNone(self.migrate())
        self.assertEqual(self.config.read_bytes(), after)
        self.assertEqual(len(self.backups()), 1)

    def test_crlf_and_odd_headers_survive(self) -> None:
        kiro = self.copy(".kiro")
        original = self.write_config(
            f"[profile  \"csg-login\" ]\r\ncredential_process = {kiro}/get-sts-token.sh\r\n"
            "[sso-session x]\r\nsso_region = us-east-1\r\n"
        )
        self.migrate()
        self.assertEqual(self.config.read_bytes(),
                         original.replace(str(kiro), str(self.new)).encode("utf-8"))

    def test_a_longer_folder_name_is_not_mistaken_for_the_copy(self) -> None:
        kiro = self.copy(".kiro")
        lookalike = f"{kiro}-old/get-customer-credentials.sh"
        self.write_config(
            f"[profile csg-login]\ncredential_process = {kiro}/get-sts-token.sh\n"
            f"[profile csg-x]\ncredential_process = {lookalike}\n"
        )
        self.migrate()
        self.assertIn(f"credential_process = {lookalike}\n", self.config.read_text(encoding="utf-8"))

    def test_windows_form_is_matched_regardless_of_case_and_slashes(self) -> None:
        home = Path("C:/Users/Kim")
        value = 'pwsh -NoProfile -File "c:\\users\\kim\\.kiro\\skills\\aws-customer-account-ops\\get-sts-token.ps1"'
        self.write_config(f"[profile csg-login]\ncredential_process = {value}\n")
        sm.migrate(self.root, home, {"AWS_CONFIG_FILE": str(self.config)}, os_name="nt", stamp=STAMP)
        self.assertEqual(self.config.read_text(encoding="utf-8"),
                         f'[profile csg-login]\ncredential_process = pwsh -NoProfile -File "{self.new}\\get-sts-token.ps1"\n')

    def test_aws_config_file_variable_is_honoured(self) -> None:
        kiro = self.copy(".kiro")
        other = self.home / "elsewhere/config"
        other.parent.mkdir(parents=True)
        other.write_text(f"[profile csg-login]\ncredential_process = {kiro}/get-sts-token.sh\n", encoding="utf-8")
        self.migrate(env={"AWS_CONFIG_FILE": str(other)})
        self.assertIn(str(self.new), other.read_text(encoding="utf-8"))

    # ── 남이 만든 것은 건드리지 않는다 ──────────────────────────────────────
    def test_a_copy_used_by_a_non_csg_profile_stays_and_is_named(self) -> None:
        """crossaccount-user 처럼 csg- 밖의 프로필이 가리키는 사본은 옮기면 그 프로필이 깨진다 (2026-10-20 유지보수자)."""
        self.standard()
        claude = self.home / ".claude/skills" / SKILL
        with self.config.open("a", encoding="utf-8") as config:
            config.write(f"\n[profile crossaccount-user]\ncredential_process = {claude}/get-sts-token.sh\n")
        message = self.migrate()
        self.assertTrue((claude / "SKILL.md").is_file())
        self.assertFalse((self.home / ".hermes/skills" / SKILL).exists())
        self.assertIn(f"[profile crossaccount-user]\ncredential_process = {claude}/get-sts-token.sh\n",
                      self.config.read_text(encoding="utf-8"))
        self.assertIn("crossaccount-user", message)
        self.assertIn(str(claude), message)

    def test_the_kept_copy_is_named_every_session_until_it_is_freed(self) -> None:
        claude = self.copy(".claude")
        self.write_config(
            f"[profile csg-login]\ncredential_process = {self.new}/get-sts-token.sh\n"
            f"[profile crossaccount-user]\ncredential_process = {claude}/get-sts-token.sh\n"
        )
        self.assertIn("crossaccount-user", self.migrate())
        self.assertEqual(self.backups(), [])

    def test_a_non_csg_profile_pointing_at_a_vanished_copy_is_not_our_notice(self) -> None:
        gone = self.home / ".claude/skills" / SKILL
        self.write_config(
            f"[profile csg-login]\ncredential_process = {self.new}/get-sts-token.sh\n"
            f"[profile crossaccount-user]\ncredential_process = {gone}/get-sts-token.sh\n"
        )
        self.assertIsNone(self.migrate())

    # ── 하지 않는다 ───────────────────────────────────────────────────────
    def test_a_pc_without_the_skill_is_left_alone(self) -> None:
        claude = self.copy(".claude")
        original = self.write_config("[profile personal]\nregion = us-east-1\n")
        self.assertIsNone(self.migrate())
        self.assertEqual(self.config.read_text(encoding="utf-8"), original)
        self.assertTrue((claude / "SKILL.md").is_file())

    def test_without_the_login_marker_nothing_is_touched(self) -> None:
        """마커가 없으면 반쯤 설치된 PC 다 — 고치는 것은 온보딩 몫이다."""
        claude = self.copy(".claude")
        original = self.write_config(f"[profile csg-acme]\ncredential_process = {claude}/get-customer-credentials.sh\n")
        self.assertIsNone(self.migrate())
        self.assertEqual(self.config.read_text(encoding="utf-8"), original)
        self.assertTrue((claude / "SKILL.md").is_file())

    def test_no_aws_config_does_nothing(self) -> None:
        claude = self.copy(".claude")
        self.assertIsNone(self.migrate())
        self.assertTrue((claude / "SKILL.md").is_file())

    def test_worktrees_and_copies_never_migrate(self) -> None:
        """링크된 워크트리(.git 이 파일)나 평가 사본(.git 없음)을 가리키면 그 폴더가 지워질 때 조회가 깨진다."""
        original = self.standard()
        (self.root / ".git").rmdir()
        (self.root / ".git").write_text("gitdir: /elsewhere\n", encoding="utf-8")
        self.assertIsNone(self.migrate())
        (self.root / ".git").unlink()
        self.assertIsNone(self.migrate())
        self.assertEqual(self.config.read_text(encoding="utf-8"), original)
        self.assertTrue((self.home / ".claude/skills" / SKILL / "SKILL.md").is_file())

    def test_a_workspace_without_the_skill_does_nothing(self) -> None:
        original = self.standard()
        (self.new / "get-sts-token.sh").unlink()
        self.assertIsNone(self.migrate())
        self.assertEqual(self.config.read_text(encoding="utf-8"), original)

    def test_a_workspace_path_with_spaces_is_not_written_unquoted(self) -> None:
        """POSIX 의 credential_process 는 따옴표 없이 쓰여 있다 — 공백 든 경로로 바꾸면 aws 가 명령을 쪼갠다."""
        spaced = self.root.parent / "고객 지원/tiket"
        self.root.rename(self.root.parent / "moved")
        spaced.parent.mkdir()
        (self.root.parent / "moved").rename(spaced)
        self.root, self.new = spaced, spaced / "skills" / SKILL
        original = self.standard()
        message = self.migrate()
        self.assertEqual(self.config.read_text(encoding="utf-8"), original)
        self.assertTrue((self.home / ".claude/skills" / SKILL / "SKILL.md").is_file())
        self.assertIn("공백", message)


if __name__ == "__main__":
    unittest.main()
