#!/usr/bin/env python3
"""워크스페이스 정식 버전을 찍는다 — 유지보수자용.

태그는 곧 배포다. 동료의 세션 시작 훅(check-freshness)이 더 높은 `vX.Y.Z` 태그를 보면
그 태그로 스스로 올라간다 (development/decisions/0025). 그래서 찍기 전에 막는다.

    python3 scripts/release.py v0.2.0 --dry-run   검사와 릴리스 노트만 본다
    python3 scripts/release.py v0.2.0             검사 → 검증·테스트 → annotated 태그
    python3 scripts/release.py v0.2.0 --notice "…"  동료가 꼭 알아야 할 것을 노트 맨 위에
    python3 scripts/release.py v0.2.0 --summary "…" --summary "…"  동료 눈으로 쓴 바뀐 점. 정식 릴리스에는 필수

동작이나 밖으로 나가는 데이터가 바뀌면 --notice 를 쓴다. 기존 동료는 온보딩 고지를
다시 보지 않는다 — 자동 업데이트가 보여 주는 노트 앞 8줄이 유일한 알림이다.

push 는 하지 않는다. 마지막에 태그 push 와 GitHub 릴리스 명령을 출력한다 — 배포 스위치는 사람이 누른다.
"""

from __future__ import annotations

import argparse
import os
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import NamedTuple

from release_tags import is_newer, latest, version

ROOT = Path(__file__).resolve().parents[1]
RELEASE_BRANCH = "main"
MAX_NOTE_LINES = 30


class RepoState(NamedTuple):
    branch: str
    dirty: list[str]
    head: str
    origin_main: str
    latest_tag: str | None
    tag_exists: bool


class SigningPlan(NamedTuple):
    sign: bool
    problems: list[str]


def signing_plan(head_has_signers: bool, signing_key: str) -> SigningPlan:
    """서명자 파일이 HEAD 에 있으면 서명을 강제한다 (2026-10-04 hardening #3).

    파일이 생기는 순간부터 강제된다. 없으면 지금처럼 서명 없이 찍는다.
    있는데 git 의 user.signingkey 가 없으면 — 찍기 전에 멈춘다.
    """
    if not head_has_signers:
        return SigningPlan(sign=False, problems=[])
    if not signing_key.strip():
        return SigningPlan(
            sign=False,
            problems=[
                "scripts/release-signers 가 있어 서명이 필요하지만 git 의 user.signingkey 가 없다 — "
                "서명할 SSH 키를 고르고: git config gpg.format ssh && "
                "git config user.signingkey <공개키 또는 키 경로>"
            ],
        )
    return SigningPlan(sign=True, problems=[])


def preflight(tag: str, state: RepoState) -> list[str]:
    problems = []
    if version(tag) is None:
        problems.append(f"{tag} 는 정식 버전 형식(vX.Y.Z)이 아니다 — 자동 업데이트가 따라가지 않는다")
    elif state.latest_tag and not is_newer(tag, state.latest_tag):
        problems.append(f"{tag} 가 최신 {state.latest_tag} 보다 높지 않다 — 아무도 받지 않는다")
    if state.tag_exists:
        problems.append(f"{tag} 태그가 이미 있다")
    if state.branch != RELEASE_BRANCH:
        problems.append(f"{RELEASE_BRANCH} 가 아니라 {state.branch} 에 있다")
    if state.dirty:
        problems.append(f"커밋하지 않은 변경이 있다: {' '.join(state.dirty[:5])}")
    if state.head != state.origin_main:
        problems.append(
            f"HEAD 가 origin/{RELEASE_BRANCH} 와 다르다 — 먼저 push 해서 main 과 릴리스를 맞춘다"
        )
    return problems


def notes(tag: str, subjects: list[str], notices: list[str] = (), summary: list[str] = ()) -> str:
    """알림 → 요약 → 커밋 제목. 동료는 자동 업데이트가 보여 주는 앞 8줄만 본다.

    커밋 제목은 유지보수자의 말이라 요약이 있으면 `세부 변경:` 아래로 내린다.
    """
    alerts = [f"알림: {notice.strip()}" for notice in notices if notice.strip()]
    points = [f"- {point.strip()}" for point in summary if point.strip()]
    lines = [tag, ""] + (alerts + [""] if alerts else []) + (points + ["", "세부 변경:"] if points else [])
    lines += [f"- {subject}" for subject in subjects[:MAX_NOTE_LINES]]
    if len(subjects) > MAX_NOTE_LINES:
        lines.append(f"- 외 {len(subjects) - MAX_NOTE_LINES}건")
    return "\n".join(lines)


def git(*args: str) -> str:
    return subprocess.run(
        ["git", "-c", "core.quotePath=false", *args],
        cwd=ROOT, check=True, capture_output=True, text=True,
    ).stdout.strip()


SIGNERS_PATH = "scripts/release-signers"


def head_has_signers() -> bool:
    """지금 HEAD 에 커밋된 서명자 파일이 있는가. 작업 폴더가 아니라 HEAD 를 본다."""
    result = subprocess.run(
        ["git", "cat-file", "-e", f"HEAD:{SIGNERS_PATH}"],
        cwd=ROOT, capture_output=True, text=True,
    )
    return result.returncode == 0


def signing_key() -> str:
    result = subprocess.run(
        ["git", "config", "--get", "user.signingkey"],
        cwd=ROOT, capture_output=True, text=True,
    )
    return result.stdout.strip() if result.returncode == 0 else ""


def sign_and_verify(tag: str, message: str) -> list[str]:
    """SSH 로 서명한 annotated 태그를 만들고 바로 검증한다 — HEAD 의 서명자 파일로.

    검증 실패면 태그를 지우고 문제를 돌려 준다. 임시 파일은 반드시 지운다.
    새 태그 안의 파일이나 작업 폴더의 파일이 아니라, 지금 HEAD 에 커밋된 목록을 믿는다.
    """
    subprocess.run(
        ["git", "-c", "gpg.format=ssh", "tag", "-s", "-a", tag, "-m", message],
        cwd=ROOT, check=True, capture_output=True, text=True,
    )
    with tempfile.NamedTemporaryFile("w", suffix=".signers", delete=False) as handle:
        signers_file = handle.name
        handle.write(git("show", f"HEAD:{SIGNERS_PATH}") + "\n")
    try:
        verify = subprocess.run(
            ["git", "-c", "gpg.format=ssh",
             "-c", f"gpg.ssh.allowedSignersFile={signers_file}", "verify-tag", tag],
            cwd=ROOT, capture_output=True, text=True,
        )
    finally:
        try:
            os.unlink(signers_file)
        except OSError:
            pass
    if verify.returncode != 0:
        subprocess.run(["git", "tag", "-d", tag], cwd=ROOT, capture_output=True, text=True)
        return [
            f"{tag} 서명을 검증하지 못해 태그를 지웠다 — {(verify.stderr or verify.stdout).strip().splitlines()[-1] if (verify.stderr or verify.stdout).strip() else '검증 실패'}"
        ]
    return []


def read_state(tag: str) -> RepoState:
    git("fetch", "--quiet", "--tags", "origin")
    tags = git("tag", "-l").splitlines()
    return RepoState(
        branch=git("branch", "--show-current") or "브랜치 없음",
        dirty=git("diff", "--name-only", "HEAD").splitlines(),
        head=git("rev-parse", "HEAD"),
        origin_main=git("rev-parse", f"origin/{RELEASE_BRANCH}"),
        latest_tag=latest(tags),
        tag_exists=tag in tags,
    )


def run_checks() -> bool:
    commands = [[sys.executable, "scripts/validate_workspace.py"]]
    commands += [[sys.executable, str(path.relative_to(ROOT))] for path in sorted((ROOT / "scripts").glob("test_*.py"))]
    for command in commands:
        print(f"  … {' '.join(command[1:])}", flush=True)
        result = subprocess.run(command, cwd=ROOT, capture_output=True, text=True)
        if result.returncode != 0:
            print(f"실패: {' '.join(command[1:])}\n{(result.stdout + result.stderr)[-2000:]}", file=sys.stderr)
            return False
    return True


def summary_problems(args: argparse.Namespace) -> list[str]:
    """정식 릴리스는 동료 눈으로 쓴 요약이 있어야 한다. --dry-run 은 노트를 보려는 것이라 없어도 된다."""
    if args.dry_run or any(point.strip() for point in args.summary):
        return []
    return ["--summary 가 없다 — 동료가 알아볼 말로 \"무엇이 달라졌고 할 일이 있는지\" 를 한 줄씩 준다 (커밋 제목은 세부 변경으로 내려간다)"]


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("tag")
    parser.add_argument("--dry-run", action="store_true", help="검사와 릴리스 노트만 본다")
    parser.add_argument("--notice", action="append", default=[], help="노트 맨 위에 둘 알림. 여러 번 줄 수 있다")
    parser.add_argument("--summary", action="append", default=[], help="동료 눈으로 쓴 바뀐 점 한 줄. 여러 번. 정식 릴리스에는 필수")
    return parser.parse_args(argv)


def main(argv: list[str]) -> int:
    args = parse_args(argv[1:])
    tag = args.tag
    state = read_state(tag)
    plan = signing_plan(head_has_signers(), signing_key())
    problems = summary_problems(args) + preflight(tag, state) + plan.problems
    if problems:
        print("태그를 찍지 않는다:", file=sys.stderr)
        for problem in problems:
            print(f"  - {problem}", file=sys.stderr)
        return 1

    since = f"{state.latest_tag}..HEAD" if state.latest_tag else "HEAD"
    message = notes(tag, git("log", "--no-merges", "--format=%s", since).splitlines(), args.notice, args.summary)
    signing_line = "서명해서 찍는다 (scripts/release-signers 가 HEAD 에 있다)" if plan.sign \
        else "서명 없이 찍는다 (HEAD 에 scripts/release-signers 가 없다)"
    print(f"이전 버전: {state.latest_tag or '없음 (첫 릴리스)'}\n{signing_line}\n\n{message}\n")
    if args.dry_run:
        print("(--dry-run — 검증·테스트와 태그 생성은 하지 않았다)")
        return 0

    print("검증과 테스트를 돌린다:")
    if not run_checks():
        return 1
    if plan.sign:
        signing_problems = sign_and_verify(tag, message)
        if signing_problems:
            print("태그를 찍지 않는다:", file=sys.stderr)
            for problem in signing_problems:
                print(f"  - {problem}", file=sys.stderr)
            return 1
    else:
        git("tag", "-a", tag, "-m", message)
    print(f"\n{tag} 태그를 만들었다. 아직 아무도 받지 않았다. 배포하려면 차례로:")
    for command in deploy_commands(tag):
        print(f"  {command}")
    print("잘못 찍었으면 push 전에: git tag -d " + tag)
    return 0


def deploy_commands(tag: str) -> list[str]:
    """태그 push 가 곧 배포다. GitHub 릴리스는 그 뒤에 — 원격 태그가 있어야 만들어진다."""
    return [
        f"TIKET_ALLOW_UPSTREAM_PUSH=1 git push origin {tag}",
        f"gh release create {tag} --verify-tag --notes-from-tag",
    ]


if __name__ == "__main__":
    sys.exit(main(sys.argv))
