#!/usr/bin/env python3
"""release.py — 태그를 찍어도 되는지 판단하고, 릴리스 노트를 만든다."""

from __future__ import annotations

import os
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import release  # noqa: E402

SSH_KEYGEN = shutil.which("ssh-keygen")

READY = release.RepoState(
    branch="main", dirty=[], head="abc", origin_main="abc", latest_tag="v0.1.0", tag_exists=False,
)


def with_(**changes: object) -> release.RepoState:
    return READY._replace(**changes)


class DeployCommandsTests(unittest.TestCase):
    """배포는 태그 push 다음에 GitHub 릴리스다 (2026-10-20 유지보수자 — 태그만 올리지 않는다)."""

    def test_tag_push_comes_before_the_github_release(self) -> None:
        commands = release.deploy_commands("v0.2.6")
        self.assertEqual(commands[0], "TIKET_ALLOW_UPSTREAM_PUSH=1 git push origin v0.2.6")
        # --verify-tag: 원격에 태그가 없으면 만들지 않는다. 노트는 서명된 태그의 메시지 그대로.
        self.assertEqual(commands[1], "gh release create v0.2.6 --verify-tag --notes-from-tag")


class PreflightTests(unittest.TestCase):
    def test_ready_state_has_no_problems(self) -> None:
        self.assertEqual(release.preflight("v0.2.0", READY), [])

    def test_first_release_has_no_previous_tag(self) -> None:
        self.assertEqual(release.preflight("v0.1.0", with_(latest_tag=None)), [])

    def test_rejects_non_release_format(self) -> None:
        for bad in ("0.2.0", "v0.2", "v0.2.0-rc1", "alpha-20260924.1"):
            self.assertTrue(release.preflight(bad, READY), bad)

    def test_version_must_move_forward(self) -> None:
        # 자동 업데이트는 더 높은 태그만 따라간다. 같거나 낮으면 아무도 안 받는다.
        self.assertTrue(release.preflight("v0.1.0", READY))
        self.assertTrue(release.preflight("v0.0.9", READY))

    def test_existing_tag_is_rejected(self) -> None:
        self.assertTrue(release.preflight("v0.2.0", with_(tag_exists=True)))

    def test_must_be_on_main(self) -> None:
        self.assertTrue(release.preflight("v0.2.0", with_(branch="feature")))

    def test_uncommitted_changes_are_not_released(self) -> None:
        problems = release.preflight("v0.2.0", with_(dirty=["scripts/x.py"]))
        self.assertTrue(problems)
        self.assertIn("scripts/x.py", " ".join(problems))

    def test_head_must_already_be_on_origin_main(self) -> None:
        """태그가 가리키는 커밋이 origin/main 에 없으면 main 과 릴리스가 갈라진다."""
        self.assertTrue(release.preflight("v0.2.0", with_(origin_main="def")))


class NotesTests(unittest.TestCase):
    def test_first_line_is_the_tag_then_subjects(self) -> None:
        notes = release.notes("v0.2.0", ["feat: 자동 업데이트", "fix: 온보딩 폴백"])
        self.assertEqual(notes.splitlines(), ["v0.2.0", "", "- feat: 자동 업데이트", "- fix: 온보딩 폴백"])

    def test_long_history_is_capped(self) -> None:
        notes = release.notes("v0.1.0", [f"commit {i}" for i in range(100)])
        self.assertLessEqual(len(notes.splitlines()), 2 + release.MAX_NOTE_LINES + 1)
        self.assertIn("외", notes.splitlines()[-1])

    def test_notices_come_before_subjects(self) -> None:
        notes = release.notes("v0.2.0", ["feat: 무엇"], ["교훈 후보를 보낸다 · 끄기 TIKET_LESSONS=off"])
        self.assertEqual(
            notes.splitlines(),
            ["v0.2.0", "", "알림: 교훈 후보를 보낸다 · 끄기 TIKET_LESSONS=off", "", "- feat: 무엇"],
        )

    def test_blank_notices_are_dropped(self) -> None:
        self.assertEqual(release.notes("v0.2.0", ["feat: 무엇"], ["  ", ""]), release.notes("v0.2.0", ["feat: 무엇"]))

    def test_notice_survives_the_subject_cap(self) -> None:
        notes = release.notes("v0.2.0", [f"commit {i}" for i in range(100)], ["고지"])
        self.assertIn("알림: 고지", notes.splitlines())
        subject_lines = [line for line in notes.splitlines() if line.startswith("- commit")]
        self.assertEqual(len(subject_lines), release.MAX_NOTE_LINES)

    def test_notice_is_the_first_line_colleagues_see(self) -> None:
        """v0.1.1 에서 고지가 빠졌다 (2026-09-28). 동료는 check-freshness 가 자른 앞 8줄만 본다."""
        subjects = [f"commit {i}" for i in range(20)]
        notes = release.notes("v0.2.0", subjects, ["첫째 고지", "둘째 고지"])
        freshness = (Path(__file__).resolve().parent / "check-freshness.sh").read_text(encoding="utf-8")
        display = re.search(r"%\(contents\)'.*?\n\s*\| (sed .*?)\n", freshness, re.S).group(1)
        shown = subprocess.run(["bash", "-c", display], input=notes, capture_output=True, text=True, check=True)
        self.assertEqual(shown.stdout.splitlines()[:2], ["  알림: 첫째 고지", "  알림: 둘째 고지"])


class SummaryNotesTests(unittest.TestCase):
    """커밋 제목은 우리 말이다 — "3단계 d", "EVAL-012 회귀" 를 동료가 읽었다 (v0.2.12, 2026-10-26).
    동료 눈으로 쓴 요약이 위, 커밋 제목은 `세부 변경:` 아래로 내린다."""

    def test_summary_comes_first_and_subjects_go_under_details(self) -> None:
        notes = release.notes("v0.2.0", ["docs: 3단계 d"], summary=["답변 초안이 고객을 재촉하지 않습니다"])
        self.assertEqual(notes.splitlines(),
                         ["v0.2.0", "", "- 답변 초안이 고객을 재촉하지 않습니다", "", "세부 변경:", "- docs: 3단계 d"])

    def test_notice_stays_above_the_summary(self) -> None:
        notes = release.notes("v0.2.0", ["feat: 무엇"], ["고지"], summary=["요약"])
        self.assertEqual(notes.splitlines()[:5], ["v0.2.0", "", "알림: 고지", "", "- 요약"])

    def test_colleagues_see_the_summary_not_the_commit_subjects(self) -> None:
        subjects = [f"commit {i}" for i in range(20)]
        notes = release.notes("v0.2.0", subjects, summary=["첫째 요약", "둘째 요약"])
        freshness = (Path(__file__).resolve().parent / "check-freshness.sh").read_text(encoding="utf-8")
        display = re.search(r"%\(contents\)'.*?\n\s*\| (sed .*?)\n", freshness, re.S).group(1)
        shown = subprocess.run(["bash", "-c", display], input=notes, capture_output=True, text=True, check=True)
        self.assertEqual(shown.stdout.splitlines()[:3], ["  - 첫째 요약", "  - 둘째 요약", "  세부 변경:"])

    def test_summary_is_repeatable(self) -> None:
        args = release.parse_args(["v0.2.0", "--summary", "A", "--summary", "B"])
        self.assertEqual(args.summary, ["A", "B"])

    def test_a_real_release_without_a_summary_is_refused(self) -> None:
        self.assertTrue(release.summary_problems(release.parse_args(["v0.2.0"])))
        self.assertTrue(release.summary_problems(release.parse_args(["v0.2.0", "--summary", "  "])))
        self.assertEqual(release.summary_problems(release.parse_args(["v0.2.0", "--summary", "요약"])), [])

    def test_a_dry_run_without_a_summary_is_allowed(self) -> None:
        self.assertEqual(release.summary_problems(release.parse_args(["v0.2.0", "--dry-run"])), [])


class ArgsTests(unittest.TestCase):
    def test_notice_is_repeatable_and_dry_run_is_kept(self) -> None:
        args = release.parse_args(["v0.2.0", "--notice", "A", "--dry-run", "--notice", "B"])
        self.assertEqual((args.tag, args.notice, args.dry_run), ("v0.2.0", ["A", "B"], True))

    def test_no_notice_by_default(self) -> None:
        args = release.parse_args(["v0.2.0"])
        self.assertEqual((args.notice, args.dry_run), ([], False))


class SigningPlanTests(unittest.TestCase):
    """서명자 파일이 HEAD 에 있으면 서명을 강제한다 (2026-10-04 hardening #3).

    파일이 생기는 순간부터 강제된다. 그 전 버전은 서명 없이 지금처럼 찍는다.
    """

    def test_no_signers_file_means_unsigned(self) -> None:
        plan = release.signing_plan(head_has_signers=False, signing_key="")
        self.assertFalse(plan.sign)
        self.assertEqual(plan.problems, [])

    def test_signers_file_without_signing_key_blocks(self) -> None:
        plan = release.signing_plan(head_has_signers=True, signing_key="")
        self.assertFalse(plan.sign)
        self.assertTrue(plan.problems)
        self.assertIn("signingkey", " ".join(plan.problems))

    def test_signers_file_with_signing_key_signs(self) -> None:
        plan = release.signing_plan(head_has_signers=True, signing_key="/home/me/.ssh/id_ed25519")
        self.assertTrue(plan.sign)
        self.assertEqual(plan.problems, [])


@unittest.skipUnless(SSH_KEYGEN, "ssh-keygen 없음")
class ReleaseSigningTests(unittest.TestCase):
    """실제 git 저장소에서 release.main() 을 돌려 서명 동작을 본다.

    임시 HOME·GIT_CONFIG_GLOBAL 로 이 PC 의 키·git 전역 설정을 건드리지 않는다.
    실제 origin 에 push 하지 않는다 — origin 은 임시 bare 저장소다.
    """

    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory(prefix="tiket-release-signing-")
        self.base = Path(self._tmp.name)
        self.home = self.base / "home"
        self.home.mkdir()
        self.gitconfig = self.home / "gitconfig"
        self.repo = self.base / "repo"
        self.origin = self.base / "origin.git"
        # 임시 키 한 쌍. 이 PC 의 ~/.ssh 는 건드리지 않는다.
        self.key = self.base / "key"
        subprocess.run(
            [SSH_KEYGEN, "-t", "ed25519", "-N", "", "-C", "tiket-release", "-f", str(self.key), "-q"],
            check=True,
        )
        self.pub = (self.base / "key.pub").read_text(encoding="utf-8").strip()
        self._init_repo()

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def env(self) -> dict[str, str]:
        return {
            **os.environ,
            "HOME": str(self.home),
            "GIT_CONFIG_GLOBAL": str(self.gitconfig),
            "GIT_CONFIG_SYSTEM": os.devnull,
            "GIT_TERMINAL_PROMPT": "0",
        }

    def git(self, *args: str) -> str:
        return subprocess.run(
            ["git", *args], cwd=self.repo, env=self.env(),
            check=True, capture_output=True, text=True,
        ).stdout.strip()

    def _init_repo(self) -> None:
        self.repo.mkdir()
        (self.repo / "scripts").mkdir()
        for name in ("release.py", "release_tags.py"):
            shutil.copy2(release.ROOT / "scripts" / name, self.repo / "scripts" / name)
        # run_checks() 가 validate_workspace.py 와 test_*.py 를 돈다. 서명 동작만 보려는
        # 것이라 통과하는 가짜를 넣는다 — 실서버에 닿지 않고, 전체 검사는 본 저장소에서 돈다.
        (self.repo / "scripts" / "validate_workspace.py").write_text(
            "import sys\nsys.exit(0)\n", encoding="utf-8")
        self.git("init", "-q", "-b", "main")
        self.git("config", "user.name", "t")
        self.git("config", "user.email", "t@t")
        (self.repo / "f.md").write_text("hi\n", encoding="utf-8")
        self.git("add", "-A")
        self.git("commit", "-qm", "init")
        subprocess.run(
            ["git", "clone", "-q", "--bare", str(self.repo), str(self.origin)],
            env=self.env(), check=True, capture_output=True, text=True,
        )
        self.git("remote", "add", "origin", str(self.origin))
        self.git("push", "-q", "origin", "main")

    def add_signers(self, pub: str | None = None) -> None:
        signers = self.repo / "scripts" / "release-signers"
        signers.parent.mkdir(parents=True, exist_ok=True)
        signers.write_text(f'tiket-release namespaces="git" {pub or self.pub}\n', encoding="utf-8")
        self.git("add", "-A")
        self.git("commit", "-qm", "add signers")
        self.git("push", "-q", "origin", "main")

    def configure_signing_key(self) -> None:
        self.git("config", "gpg.format", "ssh")
        self.git("config", "user.signingkey", str(self.key))

    def run_release(self, tag: str, *extra: str) -> subprocess.CompletedProcess:
        return subprocess.run(
            [sys.executable, str(self.repo / "scripts" / "release.py"), tag, "--summary", "시험 요약", *extra],
            cwd=self.repo, env=self.env(), capture_output=True, text=True,
        )

    def tag_exists(self, tag: str) -> bool:
        out = subprocess.run(
            ["git", "tag", "-l", tag], cwd=self.repo, env=self.env(),
            capture_output=True, text=True, check=True,
        ).stdout.strip()
        return out == tag

    # ── 서명자 파일 없음 → 지금처럼 서명 없이 ─────────────────────────────
    def test_without_signers_file_makes_unsigned_tag(self) -> None:
        result = self.run_release("v0.2.0")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(self.tag_exists("v0.2.0"))
        verify = subprocess.run(
            ["git", "verify-tag", "v0.2.0"], cwd=self.repo, env=self.env(),
            capture_output=True, text=True,
        )
        self.assertNotEqual(verify.returncode, 0, "서명 없이 찍었어야 한다")

    def test_a_release_without_a_summary_leaves_no_tag(self) -> None:
        result = subprocess.run(
            [sys.executable, str(self.repo / "scripts" / "release.py"), "v0.2.0"],
            cwd=self.repo, env=self.env(), capture_output=True, text=True,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.tag_exists("v0.2.0"))
        self.assertIn("--summary", result.stderr)

    def test_the_tag_message_carries_the_summary(self) -> None:
        self.assertEqual(self.run_release("v0.2.0").returncode, 0)
        self.assertIn("- 시험 요약", self.git("tag", "-l", "--format=%(contents)", "v0.2.0"))

    def test_dry_run_without_signers_says_unsigned(self) -> None:
        result = self.run_release("v0.2.0", "--dry-run")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(self.tag_exists("v0.2.0"))
        self.assertIn("서명", result.stdout)

    # ── 서명자 파일 있음 + signingkey 없음 → 안 찍는다 ────────────────────
    def test_signers_file_without_signing_key_refuses(self) -> None:
        self.add_signers()
        result = self.run_release("v0.2.0")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.tag_exists("v0.2.0"))
        self.assertIn("signingkey", result.stdout + result.stderr)

    # ── 서명자 파일 있음 + signingkey 있음 → 서명되고 검증 통과 ──────────
    def test_signers_file_with_signing_key_makes_verified_tag(self) -> None:
        self.add_signers()
        self.configure_signing_key()
        result = self.run_release("v0.2.0")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue(self.tag_exists("v0.2.0"))
        signers = self.base / "verify-signers"
        signers.write_text(f'tiket-release namespaces="git" {self.pub}\n', encoding="utf-8")
        verify = subprocess.run(
            ["git", "-c", "gpg.format=ssh",
             "-c", f"gpg.ssh.allowedSignersFile={signers}", "verify-tag", "v0.2.0"],
            cwd=self.repo, env=self.env(), capture_output=True, text=True,
        )
        self.assertEqual(verify.returncode, 0, verify.stderr)

    def test_dry_run_with_signers_says_signed(self) -> None:
        self.add_signers()
        self.configure_signing_key()
        result = self.run_release("v0.2.0", "--dry-run")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(self.tag_exists("v0.2.0"))
        self.assertIn("서명", result.stdout)

    def test_tag_signed_with_key_not_in_list_is_deleted(self) -> None:
        """signingkey 가 서명자 목록에 없으면: 서명은 되지만 검증이 실패한다 →
        만든 태그를 지우고 멈춘다. HEAD 목록을 믿으므로 미등록 키는 통과하지 못한다."""
        self.add_signers()  # HEAD 목록 = self.pub (승인 키)
        other = self.base / "other"
        subprocess.run(
            [SSH_KEYGEN, "-t", "ed25519", "-N", "", "-C", "tiket-release", "-f", str(other), "-q"],
            check=True,
        )
        self.git("config", "gpg.format", "ssh")
        self.git("config", "user.signingkey", str(other))  # 목록에 없는 키
        result = self.run_release("v0.2.0")
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertFalse(self.tag_exists("v0.2.0"), "검증 실패 태그는 지워져야 한다")
        self.assertIn("검증", result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main(verbosity=2)
