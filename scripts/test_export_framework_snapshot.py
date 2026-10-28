#!/usr/bin/env python3
"""Regression tests for clean framework export."""

from __future__ import annotations

import json
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


class FrameworkExportTests(unittest.TestCase):
    def run_export(self, destination: Path, source: Path = ROOT) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            ["python3", "scripts/export_framework_snapshot.py", str(destination), "--init-git"],
            cwd=source,
            check=False,
            capture_output=True,
            text=True,
        )

    def test_clean_export_has_no_operational_history_or_customer_directory(self) -> None:
        with tempfile.TemporaryDirectory(prefix="tiket-framework-export-test-") as tempdir:
            destination = Path(tempdir) / "framework"
            result = self.run_export(destination)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertTrue((destination / ".git").is_dir())
            self.assertFalse(any((destination / "customers").glob("CUST-*")))
            self.assertFalse((destination / ".private").exists())
            # 계획서·백로그가 들어 있다. 배포본은 프레임워크만 받는다.
            self.assertFalse((destination / "development").exists())
            # 판례는 최상위 자산이다 (0026). 동료가 받아야 라우터가 찾는다.
            self.assertTrue((destination / "pitfalls/README.md").is_file())
            self.assertFalse((destination / "playbooks/pitfalls").exists())
            # README 가 가리키는 그림이 같이 나가야 배포본에서 깨지지 않는다.
            self.assertTrue((destination / "assets/metrics-team-8-weeks.png").is_file())
            # README 가 자세한 설명을 docs/ 로 링크한다(2026-10-22) — 빠지면 배포본의 링크가 깨진다.
            self.assertTrue((destination / "docs/how-it-works.md").is_file())
            self.assertTrue((destination / "assets/metrics-team-8-weeks.png").is_file())
            self.assertFalse(any(path.is_symlink() for path in destination.rglob("*")))
            self.assertEqual(
                (destination / "customers/_index.md").read_text(encoding="utf-8"),
                (destination / "templates/customer-index.md").read_text(encoding="utf-8"),
            )
            inbox_files = sorted(
                str(path.relative_to(destination))
                for path in (destination / "policy/inbox").rglob("*")
                if path.is_file()
            )
            self.assertEqual(inbox_files, ["policy/inbox/README.md"])
            sources = json.loads((destination / "policy/sources.json").read_text(encoding="utf-8"))
            expected_extracts = sorted(entry["path"] for entry in sources["sources"] if "path" in entry)
            actual_extracts = sorted(
                str(path.relative_to(destination))
                for path in (destination / "policy/excerpts").rglob("*")
                if path.is_file()
            )
            self.assertEqual(actual_extracts, expected_extracts)

            history = subprocess.run(
                ["git", "rev-list", "--all", "--count"],
                cwd=destination,
                check=True,
                capture_output=True,
                text=True,
            )
            self.assertEqual(history.stdout.strip(), "0")

            staged = subprocess.run(
                ["git", "-c", "core.quotePath=false", "diff", "--cached", "--name-only"],
                cwd=destination,
                check=True,
                capture_output=True,
                text=True,
            )
            self.assertIn("DISTRIBUTION.md", staged.stdout)

    def test_export_rejects_nonempty_destination(self) -> None:
        with tempfile.TemporaryDirectory(prefix="tiket-framework-export-test-") as tempdir:
            destination = Path(tempdir) / "framework"
            destination.mkdir()
            (destination / "existing.txt").write_text("do not overwrite", encoding="utf-8")
            result = self.run_export(destination)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("destination must not exist or must be empty", result.stderr)

    def test_export_rejects_external_symlink_candidate(self) -> None:
        with tempfile.TemporaryDirectory(prefix="tiket-framework-export-test-") as tempdir:
            base = Path(tempdir)
            source = base / "source"
            shutil.copytree(
                ROOT,
                source,
                symlinks=True,
                ignore=shutil.ignore_patterns(".git", ".private", "__pycache__", ".venv"),
            )
            subprocess.run(["git", "init", "-b", "main"], cwd=source, check=True, capture_output=True)
            sentinel = base / "external-private.txt"
            sentinel.write_text("must not be exported", encoding="utf-8")
            (source / "scripts/local-private.txt").symlink_to(sentinel)
            result = self.run_export(base / "export", source)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("symlink candidate is not allowed", result.stderr)
            self.assertFalse((base / "export/scripts/local-private.txt").exists())


if __name__ == "__main__":
    unittest.main(verbosity=2)
