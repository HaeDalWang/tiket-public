#!/usr/bin/env python3
"""check-freshness 의 자동 업데이트를 실제 git 저장소로 검사한다 (0025).

임시 디렉터리에 유지보수자 작업본 → 공용(bare) 저장소 → 동료 clone 을 만들고,
동료 clone 안의 스크립트를 그대로 돌린다. 문자열이 아니라 결과(HEAD, 파일 내용)를 본다.
pwsh 가 있으면 .ps1 도 같은 시나리오로 돌린다.
"""

from __future__ import annotations

import os
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SHIPPED = ["scripts/check-freshness.sh", "scripts/check-freshness.ps1", "scripts/release_tags.py"]
PWSH = shutil.which("pwsh")
SSH_KEYGEN = shutil.which("ssh-keygen")


def git(cwd: Path, *args: str) -> str:
    return subprocess.run(
        ["git", "-c", "user.name=t", "-c", "user.email=t@t", "-c", "init.defaultBranch=main", *args],
        cwd=cwd, check=True, capture_output=True, text=True,
    ).stdout.strip()


def new_signing_key(path: Path, comment: str = "tiket-release") -> str:
    """임시 ssh ed25519 키 한 쌍을 만들고 공개키 한 줄을 돌려 준다.

    이 PC 의 ~/.ssh 를 건드리지 않는다 — path 는 임시 디렉터리 안이다.
    """
    subprocess.run(
        [SSH_KEYGEN, "-t", "ed25519", "-N", "", "-C", comment, "-f", str(path), "-q"],
        check=True, capture_output=True, text=True,
    )
    return (path.with_suffix(".pub")).read_text(encoding="utf-8").strip()


def signers_line(pub: str) -> str:
    """ssh allowed_signers 한 줄. principal 은 이메일 모양이 아닌 tiket-release 다
    (검사기가 이메일 모양을 고객 정보로 본다)."""
    return f'tiket-release namespaces="git" {pub}\n'


class Workspace:
    """maintainer → origin.git → user."""

    def __init__(self, base: Path) -> None:
        self.base = base
        self.maintainer = base / "maintainer"
        self.origin = base / "origin.git"
        self.user = base / "user"
        self.maintainer.mkdir()
        git(self.maintainer, "init", "-q")
        for relative in SHIPPED:
            target = self.maintainer / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(ROOT / relative, target)
        (self.maintainer / "CLAUDE.md").write_text("rules v1\n", encoding="utf-8")
        (self.maintainer / "playbook.md").write_text("playbook v1\n", encoding="utf-8")
        (self.maintainer / ".gitignore").write_text("tickets/\n", encoding="utf-8")
        git(self.maintainer, "add", "-A")
        git(self.maintainer, "commit", "-qm", "init")
        git(base, "clone", "-q", "--bare", str(self.maintainer), str(self.origin))
        git(self.maintainer, "remote", "add", "origin", str(self.origin))
        git(base, "clone", "-q", str(self.origin), str(self.user))

    def release(self, tag: str, notes: str = "", change: dict[str, str] | None = None,
                sign_key: Path | None = None) -> None:
        for name, content in (change or {"playbook.md": f"playbook {tag}\n"}).items():
            (self.maintainer / name).write_text(content, encoding="utf-8")
        git(self.maintainer, "add", "-A")
        git(self.maintainer, "commit", "-qm", f"change for {tag}")
        message = f"{tag}\n\n{notes}".strip()
        if sign_key is not None:
            git(self.maintainer, "-c", "gpg.format=ssh", "-c", f"user.signingkey={sign_key}",
                "tag", "-s", "-a", tag, "-m", message)
        else:
            git(self.maintainer, "tag", "-a", tag, "-m", message)
        git(self.maintainer, "push", "-q", "origin", "main", tag)

    def release_lightweight(self, tag: str, change: dict[str, str] | None = None) -> None:
        """annotated 가 아닌 lightweight 태그. 서명이 붙을 자리가 없다 — 올라가면 안 된다."""
        for name, content in (change or {"playbook.md": f"playbook {tag}\n"}).items():
            (self.maintainer / name).write_text(content, encoding="utf-8")
        git(self.maintainer, "add", "-A")
        git(self.maintainer, "commit", "-qm", f"change for {tag}")
        git(self.maintainer, "tag", tag)
        git(self.maintainer, "push", "-q", "origin", "main", tag)

    def commit_signers(self, pub: str, extra: dict[str, str] | None = None) -> None:
        """서명자 파일을 maintainer main 에 커밋해 둔다. 동료가 이 커밋을 받으면
        그 뒤로 들어오는 태그를 이 목록으로 검증한다."""
        target = self.maintainer / "scripts" / "release-signers"
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(signers_line(pub), encoding="utf-8")
        for name, content in (extra or {}).items():
            (self.maintainer / name).write_text(content, encoding="utf-8")
        git(self.maintainer, "add", "-A")
        git(self.maintainer, "commit", "-qm", "add release-signers")
        git(self.maintainer, "push", "-q", "origin", "main")

    def head(self) -> str:
        return git(self.user, "rev-parse", "HEAD")

    def commit_of(self, tag: str) -> str:
        return git(self.maintainer, "rev-parse", f"{tag}^{{commit}}")


class FreshnessBehaviour:
    """.sh 와 .ps1 이 공유하는 시나리오. 하위 클래스가 run() 을 정한다."""

    def setUp(self) -> None:  # noqa: D401
        self._tmp = tempfile.TemporaryDirectory(prefix="tiket-freshness-")
        self.ws = Workspace(Path(self._tmp.name))
        self.ws.release("v0.1.0", "첫 릴리스")
        git(self.ws.user, "pull", "-q", "--ff-only")  # 동료는 v0.1.0 에서 시작한다
        self.stamp = Path(self._tmp.name) / "stamp"

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def env(self, expected_remote: str | None = None) -> dict[str, str]:
        return {
            **os.environ,
            "HOME": self._tmp.name,
            "TIKET_EXPECTED_REMOTE": expected_remote or str(self.ws.origin),
            # 로컬 경로만 허용한다 — origin 을 github 주소로 바꾸는 테스트가 실제 GitHub 에 닿지 않게
            "GIT_ALLOW_PROTOCOL": "file",
            "GIT_TERMINAL_PROMPT": "0",
            "TIKET_FRESHNESS_STAMP": str(self.stamp),
        }

    def check(self, *, force: bool = True, notify_only: bool = False, expected_remote: str | None = None) -> str:
        raise NotImplementedError

    # ── 올린다 ────────────────────────────────────────────────────────────
    def test_updates_to_the_new_release_tag(self) -> None:
        self.ws.release("v0.2.0", "- 회신 규칙 정리")
        out = self.check()
        self.assertEqual(self.ws.head(), self.ws.commit_of("v0.2.0"))
        self.assertIn("v0.2.0", out)
        self.assertIn("회신 규칙 정리", out)
        self.assertIn("git reset --keep", out)

    def test_flags_a_changed_entry_contract(self) -> None:
        """세션은 이미 옛 CLAUDE.md 를 읽고 시작했을 수 있다."""
        self.ws.release("v0.2.0", change={"CLAUDE.md": "rules v2\n"})
        self.assertIn("CLAUDE.md", self.check())

    def test_does_not_flag_entry_contract_when_unchanged(self) -> None:
        self.ws.release("v0.2.0")
        self.assertNotIn("CLAUDE.md", self.check())

    def test_ignored_local_files_do_not_block(self) -> None:
        """tickets/ 는 gitignore 다. 고객 기록이 있다고 업데이트를 막으면 아무도 안 올라간다."""
        (self.ws.user / "tickets").mkdir()
        (self.ws.user / "tickets/1.md").write_text("고객 기록\n", encoding="utf-8")
        self.ws.release("v0.2.0")
        self.check()
        self.assertEqual(self.ws.head(), self.ws.commit_of("v0.2.0"))
        self.assertEqual((self.ws.user / "tickets/1.md").read_text(encoding="utf-8"), "고객 기록\n")

    # ── 조용하다 ──────────────────────────────────────────────────────────
    def test_silent_when_already_on_the_latest_tag(self) -> None:
        before = self.ws.head()
        self.assertEqual(self.check().strip(), "")
        self.assertEqual(self.ws.head(), before)

    def test_untagged_main_is_not_an_update(self) -> None:
        """태그 없는 main 은 아직 릴리스가 아니다 — 공지되지 않은 main 을 자동 적용하지 않는다."""
        before = self.ws.head()
        (self.ws.maintainer / "playbook.md").write_text("work in progress\n", encoding="utf-8")
        git(self.ws.maintainer, "commit", "-qam", "wip")
        git(self.ws.maintainer, "push", "-q", "origin", "main")
        self.assertEqual(self.check().strip(), "")
        self.assertEqual(self.ws.head(), before)

    # ── 올리지 않고 알린다 ────────────────────────────────────────────────
    def test_never_touches_a_modified_tracked_file(self) -> None:
        (self.ws.user / "playbook.md").write_text("내가 고친 것\n", encoding="utf-8")
        before = self.ws.head()
        self.ws.release("v0.2.0")
        out = self.check()
        self.assertEqual(self.ws.head(), before)
        self.assertEqual((self.ws.user / "playbook.md").read_text(encoding="utf-8"), "내가 고친 것\n")
        self.assertIn("v0.2.0", out)
        self.assertIn("playbook.md", out)

    def test_never_rewrites_local_commits(self) -> None:
        (self.ws.user / "local.md").write_text("mine\n", encoding="utf-8")
        git(self.ws.user, "add", "local.md")
        git(self.ws.user, "commit", "-qm", "local")
        before = self.ws.head()
        self.ws.release("v0.2.0")
        out = self.check()
        self.assertEqual(self.ws.head(), before)
        self.assertIn("v0.2.0", out)
        self.assertIn("로컬 커밋", out)

    def test_only_updates_main(self) -> None:
        git(self.ws.user, "checkout", "-qb", "experiment")
        before = self.ws.head()
        self.ws.release("v0.2.0")
        out = self.check()
        self.assertEqual(self.ws.head(), before)
        self.assertIn("experiment", out)

    def test_notify_only_mode_does_not_update(self) -> None:
        """fetch-ticket 은 세션 도중에 부른다. 세션 도중 계약을 바꾸지 않는다 (0016)."""
        before = self.ws.head()
        self.ws.release("v0.2.0")
        out = self.check(notify_only=True)
        self.assertEqual(self.ws.head(), before)
        self.assertIn("v0.2.0", out)

    def test_a_blocked_update_keeps_notifying(self) -> None:
        """막힌 채로 스탬프를 찍으면 하루 동안 아무도 모른다."""
        (self.ws.user / "playbook.md").write_text("내가 고친 것\n", encoding="utf-8")
        self.ws.release("v0.2.0")
        self.check()
        self.assertIn("v0.2.0", self.check(force=False))

    def test_up_to_date_is_throttled(self) -> None:
        self.check()
        self.ws.release("v0.2.0")
        self.assertEqual(self.check(force=False).strip(), "")

    def test_wrong_origin_is_reported_first(self) -> None:
        git(self.ws.user, "remote", "set-url", "origin", "https://github.com/someone/old.git")
        self.assertIn("set-url", self.check())

    def test_other_spellings_of_the_same_repository_are_not_blocked(self) -> None:
        """origin 검사는 옛 저장소를 거르려는 것이다. 같은 example-org/tiket 을 다르게 적은 사람을 막으면
        그 사람은 영영 안 올라간다 — 유지보수자 장비(SSH 별칭)가 그랬다 (2026-09-29)."""
        expected = "https://github.com/example-org/tiket.git"
        at = "@"  # 주소를 통째로 적으면 저장소 검사기가 이메일로 본다
        for url in (f"git{at}maintainer-gh:example-org/tiket.git", f"https://someone{at}github.com/example-org/tiket.git",
                    f"ssh://git{at}github.com/example-org/tiket", f"git{at}github.com:example-org/tiket.git",
                    "https://github.com/example-org/tiket/"):
            git(self.ws.user, "remote", "set-url", "origin", url)
            # 이 주소들로는 fetch 가 실패해 조용히 끝나야 한다 — "공용 저장소가 아니다" 가 나오면 막힌 것이다
            self.assertNotIn("set-url", self.check(expected_remote=expected), url)
        git(self.ws.user, "remote", "set-url", "origin", f"git{at}github.com:maintainer-gh/tiket.git")
        self.assertIn("set-url", self.check(expected_remote=expected))

    def test_rechecks_six_hours_later(self) -> None:
        """새 릴리스가 하루 늦게 닿지 않게 사용 지표와 같은 6시간 (2026-09-29)."""
        self.check()
        self.ws.release("v0.2.0")
        self.stamp.write_text(str(int(time.time()) - 6 * 3600 - 60), encoding="utf-8")
        self.assertIn("v0.2.0", self.check(force=False))
        self.assertEqual(self.ws.head(), self.ws.commit_of("v0.2.0"))

    # ── 이 PC 에서 안 되는 기능 ───────────────────────────────────────────

    def test_three_failed_fetches_in_a_row_speak_up(self) -> None:
        """토큰이 만료됐거나 SSH 키가 잠긴 PC 는 fetch 가 매번 실패한다. 예전에는 스탬프만 찍고 끝나서 영영 안
        올라갔고 아무도 몰랐다(2026-10-07 검토). 한두 번은 오프라인일 수 있다 — 세 번째부터 말한다."""
        self.ws.release("v0.2.0")
        good = git(self.ws.user, "remote", "get-url", "origin")
        broken = str(Path(self._tmp.name) / "gone" / Path(good).parent.name / Path(good).name)
        git(self.ws.user, "remote", "set-url", "origin", broken)
        outputs = [self.check(expected_remote=broken) for _ in range(3)]
        self.assertEqual([o.strip() for o in outputs[:2]], ["", ""])
        self.assertIn("3번 연속", outputs[2])
        self.assertIn("git fetch --tags origin", outputs[2])
        git(self.ws.user, "remote", "set-url", "origin", good)
        self.check()
        self.assertEqual(self.ws.head(), self.ws.commit_of("v0.2.0"))
        git(self.ws.user, "remote", "set-url", "origin", broken)
        self.assertEqual(self.check(expected_remote=broken).strip(), "", "성공한 뒤에는 처음부터 다시 센다")

    def ship_capabilities(self) -> None:
        """Workspace 는 이 스크립트를 싣지 않는다 — 위 시나리오의 '조용함' 은 업데이트만 본다."""
        for name in ("local_capabilities.py", "kiro_permissions.py", "skill_migration.py", "skill_setup.py", "customer_notes.py", "https_fetch.py"):  # 앞의 것이 뒤의 것들을 가져다 쓴다
            shutil.copy2(ROOT / "scripts" / name, self.ws.user / "scripts" / name)

    def test_reports_missing_capabilities_every_session(self) -> None:
        """6시간 스로틀과 상관없이 매 세션 알린다. 임시 HOME 이라 자격증명도 스킬도 없다."""
        self.ship_capabilities()
        self.check()
        self.assertIn("이 PC 에서 아직 안 되는 것", self.check(force=False))

    def test_notify_only_leaves_capabilities_to_the_session(self) -> None:
        """fetch-ticket 은 세션 도중에 부른다 — 세션 시작 때 한 알림을 되풀이하지 않는다."""
        self.ship_capabilities()
        self.assertNotIn("이 PC", self.check(notify_only=True))


@unittest.skipUnless(SSH_KEYGEN, "ssh-keygen 없음")
class SigningBehaviour:
    """릴리스 태그 서명 검증 (2026-10-04 hardening #3). .sh 와 .ps1 이 공유한다.

    서명자 파일이 **지금 HEAD 에** 있으면, 들어오는 태그를 그 목록으로 검증한 뒤에만
    올린다. 새 태그 안의 파일이나 작업 폴더의 파일을 믿지 않는다. 검증 실패는 held_back.
    HEAD 에 서명자 파일이 없으면(서명 도입 전) 검증 없이 지금처럼 올린다.
    """

    def setUp(self) -> None:  # noqa: D401
        self._tmp = tempfile.TemporaryDirectory(prefix="tiket-signing-")
        base = Path(self._tmp.name)
        self.ws = Workspace(base)
        self.ws.release("v0.1.0", "첫 릴리스")
        self.stamp = base / "stamp"
        # 승인된 서명 키와, 목록에 없는 공격자 키.
        self.good_pub = new_signing_key(base / "good")
        self.good_key = base / "good"
        self.bad_pub = new_signing_key(base / "bad")
        self.bad_key = base / "bad"

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def env(self, expected_remote: str | None = None) -> dict[str, str]:
        return {
            **os.environ,
            "HOME": self._tmp.name,
            "TIKET_EXPECTED_REMOTE": expected_remote or str(self.ws.origin),
            "GIT_ALLOW_PROTOCOL": "file",
            "GIT_TERMINAL_PROMPT": "0",
            "TIKET_FRESHNESS_STAMP": str(self.stamp),
        }

    def check(self, *, force: bool = True, notify_only: bool = False,
              expected_remote: str | None = None) -> str:
        raise NotImplementedError

    def adopt_signers(self, pub: str | None = None) -> None:
        """동료 HEAD 가 서명자 파일을 품게 한다 — 유지보수자가 커밋한 것을 ff 로 당긴다."""
        self.ws.commit_signers(pub or self.good_pub)
        git(self.ws.user, "pull", "-q", "--ff-only")

    # (1) 목록에 있는 키로 서명한 태그 → 올라간다
    def test_listed_signer_updates(self) -> None:
        self.adopt_signers()
        self.ws.release("v0.2.0", "- 서명된 릴리스", sign_key=self.good_key)
        out = self.check()
        self.assertEqual(self.ws.head(), self.ws.commit_of("v0.2.0"), out)
        self.assertIn("v0.2.0", out)

    # (2) 목록에 없는 키로 서명 → 안 올라가고 알린다
    def test_unlisted_signer_is_held_back(self) -> None:
        self.adopt_signers()
        before = self.ws.head()
        self.ws.release("v0.2.0", sign_key=self.bad_key)
        out = self.check()
        self.assertEqual(self.ws.head(), before, out)
        self.assertIn("v0.2.0", out)
        self.assertIn("서명", out)

    # (3) 서명 없는 annotated 태그 → 안 올라감
    def test_unsigned_tag_is_held_back_once_signers_exist(self) -> None:
        self.adopt_signers()
        before = self.ws.head()
        self.ws.release("v0.2.0")  # 서명 없음
        out = self.check()
        self.assertEqual(self.ws.head(), before, out)
        self.assertIn("v0.2.0", out)

    # (4) lightweight 태그 → 안 올라감
    def test_lightweight_tag_is_held_back(self) -> None:
        self.adopt_signers()
        before = self.ws.head()
        self.ws.release_lightweight("v0.2.0")
        out = self.check()
        self.assertEqual(self.ws.head(), before, out)
        self.assertIn("v0.2.0", out)

    # (5) HEAD 에 서명자 파일 없음 → 서명 없어도 올라간다 (서명 도입 전 동작)
    def test_without_signers_file_unsigned_tag_still_updates(self) -> None:
        self.ws.release("v0.2.0", "- 서명 도입 전")
        out = self.check()
        self.assertEqual(self.ws.head(), self.ws.commit_of("v0.2.0"), out)

    # (6) 새 태그가 서명자 파일을 공격자 키로 바꾸고 그 키로 서명 → 안 올라감
    def test_attacker_cannot_swap_signers_in_the_new_tag(self) -> None:
        self.adopt_signers()  # HEAD = 승인 키 목록
        before = self.ws.head()
        # 공격자가 같은 태그 커밋에서 목록을 자기 키로 바꾸고 그 키로 서명한다.
        self.ws.commit_signers(self.bad_pub, extra={"playbook.md": "swapped\n"})
        self.ws.release("v0.2.0", sign_key=self.bad_key,
                        change={"README.md": "attacker payload\n"})
        out = self.check()
        self.assertEqual(self.ws.head(), before, out)
        self.assertIn("v0.2.0", out)

    # (7) 올라간 뒤 다음 릴리스도 같은 키면 올라간다
    def test_subsequent_release_with_same_key_updates(self) -> None:
        self.adopt_signers()
        self.ws.release("v0.2.0", sign_key=self.good_key)
        self.check()
        self.assertEqual(self.ws.head(), self.ws.commit_of("v0.2.0"))
        self.ws.release("v0.3.0", sign_key=self.good_key)
        self.check(force=True)
        self.assertEqual(self.ws.head(), self.ws.commit_of("v0.3.0"))

    def test_signature_block_does_not_leak_into_shown_notes(self) -> None:
        """노트 표시는 -----BEGIN 뒤를 잘라낸다 — 서명 블록이 알림에 섞이면 안 된다."""
        self.adopt_signers()
        self.ws.release("v0.2.0", "- 서명된 릴리스 노트", sign_key=self.good_key)
        out = self.check()
        self.assertEqual(self.ws.head(), self.ws.commit_of("v0.2.0"), out)
        self.assertIn("서명된 릴리스 노트", out)
        self.assertNotIn("-----BEGIN", out)
        self.assertNotIn("SSH SIGNATURE", out)


class FetchTimeoutTests(unittest.TestCase):
    """Kiro 는 훅 명령 전체를 제한 시간에 끊는다. 걸린 fetch 가 뒤의 전송까지 죽이지 않게
    멈춘 연결을 git 스스로 끊는다 (2026-09-29)."""

    def test_both_fetches_give_up_on_a_stalled_connection(self) -> None:
        root = Path(__file__).resolve().parents[1]
        for name in ("check-freshness.sh", "check-freshness.ps1"):
            fetch = [line for line in (root / "scripts" / name).read_text(encoding="utf-8").splitlines()
                     if line.lstrip().startswith("git ") and " fetch " in line]  # 알림 문구 속 명령은 뺀다
            self.assertTrue(fetch, name)
            for line in fetch:
                self.assertIn("http.lowSpeedLimit", line, name)
                self.assertIn("http.lowSpeedTime", line, name)


class ShellFreshnessTests(FreshnessBehaviour, unittest.TestCase):
    def check(self, *, force: bool = True, notify_only: bool = False,  # type: ignore[override]
              expected_remote: str | None = None) -> str:
        args = ["bash", str(self.ws.user / "scripts/check-freshness.sh")]
        args += ["--force"] if force else []
        args += ["--notify-only"] if notify_only else []
        result = subprocess.run(args, cwd=self.ws.user, env=self.env(expected_remote), capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout


    def test_updates_on_a_pc_that_only_has_python(self) -> None:
        """`python3` 를 이름으로 불러서, `python` 만 있는 PC 는 태그를 못 읽고 스탬프만 찍었다 — 영영 안 올라갔다
        (2026-10-07 검토). 훅 자체는 `|| python` 으로 돌아서 겉으로는 멀쩡했다."""
        self.ws.release("v0.2.0")
        bin_dir = Path(self._tmp.name) / "bin"
        bin_dir.mkdir()
        for tool in ("bash", "git", "sed", "awk", "tr", "date", "cat", "mkdir", "dirname", "head", "mktemp", "rm"):
            found = shutil.which(tool)
            if found:
                (bin_dir / tool).symlink_to(found)
        (bin_dir / "python").symlink_to(sys.executable)
        result = subprocess.run(["bash", str(self.ws.user / "scripts/check-freshness.sh"), "--force"], cwd=self.ws.user,
                                env={**self.env(), "PATH": str(bin_dir)}, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.ws.head(), self.ws.commit_of("v0.2.0"), result.stdout)


@unittest.skipUnless(PWSH, "pwsh 없음")
class PowerShellFreshnessTests(FreshnessBehaviour, unittest.TestCase):
    def check(self, *, force: bool = True, notify_only: bool = False,  # type: ignore[override]
              expected_remote: str | None = None) -> str:
        args = [PWSH, "-NoProfile", "-File", str(self.ws.user / "scripts/check-freshness.ps1")]
        args += ["-Force"] if force else []
        args += ["-NotifyOnly"] if notify_only else []
        result = subprocess.run(args, cwd=self.ws.user, env=self.env(expected_remote), capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout


class ShellSigningTests(SigningBehaviour, unittest.TestCase):
    def check(self, *, force: bool = True, notify_only: bool = False,  # type: ignore[override]
              expected_remote: str | None = None) -> str:
        args = ["bash", str(self.ws.user / "scripts/check-freshness.sh")]
        args += ["--force"] if force else []
        args += ["--notify-only"] if notify_only else []
        result = subprocess.run(args, cwd=self.ws.user, env=self.env(expected_remote), capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout


@unittest.skipUnless(PWSH, "pwsh 없음")
class PowerShellSigningTests(SigningBehaviour, unittest.TestCase):
    def check(self, *, force: bool = True, notify_only: bool = False,  # type: ignore[override]
              expected_remote: str | None = None) -> str:
        args = [PWSH, "-NoProfile", "-File", str(self.ws.user / "scripts/check-freshness.ps1")]
        args += ["-Force"] if force else []
        args += ["-NotifyOnly"] if notify_only else []
        result = subprocess.run(args, cwd=self.ws.user, env=self.env(expected_remote), capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout


if __name__ == "__main__":
    unittest.main(verbosity=2)
