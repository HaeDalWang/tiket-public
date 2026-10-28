#!/usr/bin/env python3
"""Export a clean framework snapshot without this repository's Git history."""

from __future__ import annotations

import argparse
import json
import shutil
import stat
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ROOT_FILES = {
    ".gitignore",
    ".mcp.json",
    "AGENTS.md",
    "CLAUDE.md",
    "DISTRIBUTION.md",
    "ONBOARDING.md",
    "README.md",
    "TECHNICAL.md",
}
UPSTREAM_DIRS = {
    ".agents",
    ".claude",
    ".codex",
    ".githooks",
    ".github",
    ".kiro/hooks",
    ".kiro/settings",
    ".kiro/skills",
    ".kiro/steering",
    "agents",
    "assets",
    "docs",
    "evals",
    "examples",
    "pitfalls",
    "scripts",
    "skills",
    "templates",
    "test",
}
POLICY_FILES = {
    "policy/README.md",
    "policy/_routing.md",
    "policy/pending-review.md",
    "policy/sources.json",
    "policy/source-inventory.md",
    "policy/inbox/README.md",
}


def run(command: list[str], cwd: Path = ROOT) -> subprocess.CompletedProcess[str]:
    return subprocess.run(command, cwd=cwd, check=False, capture_output=True, text=True)


def registered_excerpts() -> set[str]:
    payload = json.loads((ROOT / "policy/sources.json").read_text(encoding="utf-8"))
    return {entry["path"] for entry in payload["sources"] if "path" in entry}


def repository_candidates() -> list[Path]:
    result = run(["git", "ls-files", "--cached", "--others", "--exclude-standard", "-z"])
    if result.returncode != 0:
        raise RuntimeError(result.stderr.strip() or "git ls-files failed")
    candidates: list[Path] = []
    for value in result.stdout.split("\0"):
        if not value:
            continue
        relative = Path(value)
        source = ROOT / relative
        if not source.exists() and not source.is_symlink():
            continue
        mode = source.lstat().st_mode
        if stat.S_ISLNK(mode):
            raise RuntimeError(f"symlink candidate is not allowed: {relative}")
        if not stat.S_ISREG(mode):
            raise RuntimeError(f"non-regular candidate is not allowed: {relative}")
        resolved = source.resolve(strict=True)
        if ROOT not in resolved.parents:
            raise RuntimeError(f"candidate resolves outside repository: {relative}")
        candidates.append(relative)
    return candidates


def classification(relative: Path, excerpts: set[str]) -> str:
    text = relative.as_posix()
    if text in ROOT_FILES or text in POLICY_FILES or text in excerpts:
        return "include"
    if any(text == prefix or text.startswith(f"{prefix}/") for prefix in UPSTREAM_DIRS):
        return "include"
    if text == "customers/_index.md":
        return "workspace-owned"
    if text.startswith("playbooks/"):
        return "include"
    if text.startswith("policy/cards/"):
        return "include"
    if text.startswith("customers/CUST-"):
        return "workspace-owned"
    # development/ records how this framework is being built, not how to use it.
    # A downstream workspace gets the framework, not our build journal.
    if text == "development" or text.startswith("development/"):
        return "workspace-owned"

    if text.startswith("policy/inbox/") or text.startswith("policy/excerpts/"):
        return "workspace-owned"
    return "unexpected"


def prepare_destination(destination: Path) -> None:
    resolved = destination.resolve()
    if resolved == ROOT or ROOT in resolved.parents:
        raise ValueError("destination must be outside the source repository")
    if destination.exists() and any(destination.iterdir()):
        raise ValueError("destination must not exist or must be empty")
    destination.mkdir(parents=True, exist_ok=True)


def export(destination: Path, init_git: bool) -> int:
    excerpts = registered_excerpts()
    candidates = repository_candidates()
    groups = {"include": [], "workspace-owned": [], "unexpected": []}
    for relative in candidates:
        groups[classification(relative, excerpts)].append(relative)

    if groups["unexpected"]:
        print("framework export: FAIL", file=sys.stderr)
        for relative in groups["unexpected"]:
            print(f"- unclassified candidate path: {relative}", file=sys.stderr)
        return 1

    prepare_destination(destination)
    for relative in groups["include"]:
        source = ROOT / relative
        target = destination / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        if destination.resolve() not in target.parent.resolve().parents and target.parent.resolve() != destination.resolve():
            raise RuntimeError(f"export target escapes destination: {relative}")
        shutil.copy2(source, target, follow_symlinks=False)
        if target.is_symlink() or not stat.S_ISREG(target.lstat().st_mode):
            raise RuntimeError(f"exported path is not a regular file: {relative}")

    clean_customer_index = destination / "customers/_index.md"
    clean_customer_index.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(ROOT / "templates/customer-index.md", clean_customer_index, follow_symlinks=False)

    validation = run(["python3", "scripts/validate_workspace.py", "--framework"], destination)
    if validation.returncode != 0:
        print(validation.stdout, end="", file=sys.stderr)
        print(validation.stderr, end="", file=sys.stderr)
        print("framework export: FAIL (validator)", file=sys.stderr)
        return 1

    tests = run(["python3", "scripts/test_validate_workspace.py"], destination)
    if tests.returncode != 0:
        print(tests.stdout, end="", file=sys.stderr)
        print(tests.stderr, end="", file=sys.stderr)
        print("framework export: FAIL (regression tests)", file=sys.stderr)
        return 1

    if init_git:
        initialized = run(["git", "init", "-b", "main"], destination)
        if initialized.returncode != 0:
            print(initialized.stdout, initialized.stderr, file=sys.stderr)
            return 1
        staged = run(["git", "add", "-A"], destination)
        if staged.returncode != 0:
            print(staged.stdout, staged.stderr, file=sys.stderr)
            return 1
        whitespace = run(["git", "diff", "--cached", "--check"], destination)
        if whitespace.returncode != 0:
            print(whitespace.stdout, whitespace.stderr, file=sys.stderr)
            return 1

    print(
        "framework export: PASS "
        f"({len(groups['include'])} files included, {len(groups['workspace-owned'])} workspace-owned files excluded)"
    )
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("destination", type=Path)
    parser.add_argument("--init-git", action="store_true", help="initialize a new main branch and stage the clean snapshot")
    args = parser.parse_args()
    try:
        return export(args.destination, args.init_git)
    except (OSError, ValueError, RuntimeError, json.JSONDecodeError) as exc:
        print(f"framework export: FAIL ({exc})", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
