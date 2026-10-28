#!/usr/bin/env python3
"""release_tags.py — 정식 태그 중 가장 높은 것을 고른다."""

from __future__ import annotations

import subprocess
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))

import release_tags  # noqa: E402


class LatestTests(unittest.TestCase):
    def test_numeric_not_lexical_order(self) -> None:
        # 문자열 정렬이면 v1.9.0 이 이긴다.
        self.assertEqual(release_tags.latest(["v1.9.0", "v1.10.0", "v1.2.3"]), "v1.10.0")

    def test_prerelease_and_non_release_tags_are_ignored(self) -> None:
        tags = ["v2.0.0-rc1", "alpha-20260918.1", "v1.8.3", "latest", "1.9.0"]
        self.assertEqual(release_tags.latest(tags), "v1.8.3")

    def test_none_when_no_release_tag(self) -> None:
        self.assertIsNone(release_tags.latest(["alpha-1", "v1.0"]))

    def test_parses_ls_remote_output_and_ignores_peeled_refs(self) -> None:
        raw = (
            "e1146e0\trefs/tags/v1.8.0\n"
            "9f4da99\trefs/tags/v1.8.3\n"
            "bdfee82\trefs/tags/v1.8.3^{}\n"
        )
        self.assertEqual(release_tags.tags_from_ls_remote(raw), ["v1.8.0", "v1.8.3"])


class IsNewerTests(unittest.TestCase):
    def test_newer(self) -> None:
        self.assertTrue(release_tags.is_newer("v0.2.0", "v0.1.9"))

    def test_same_or_older(self) -> None:
        self.assertFalse(release_tags.is_newer("v0.1.0", "v0.1.0"))
        self.assertFalse(release_tags.is_newer("v0.1.0", "v0.10.0"))


class CliTests(unittest.TestCase):
    def run_cli(self, stdin: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [sys.executable, str(ROOT / "scripts/release_tags.py"), "latest"],
            input=stdin, capture_output=True, text=True, check=False,
        )

    def test_prints_latest_from_ls_remote(self) -> None:
        result = self.run_cli("a\trefs/tags/v1.9.0\nb\trefs/tags/v1.10.0\n")
        self.assertEqual((result.returncode, result.stdout.strip()), (0, "v1.10.0"))

    def test_exit_1_and_no_output_when_nothing_found(self) -> None:
        result = self.run_cli("a\trefs/tags/nightly\n")
        self.assertEqual((result.returncode, result.stdout), (1, ""))


if __name__ == "__main__":
    unittest.main(verbosity=2)
