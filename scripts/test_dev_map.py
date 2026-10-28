#!/usr/bin/env python3
"""dev_map.py — 지도의 상태는 사람이 아니라 git 태그가 정한다."""

from __future__ import annotations

import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import dev_map  # noqa: E402

FLOW = """# 흐름

설명 문단. 아래 표는 흐름이 아니다.

| 모양 | 뜻 |
|---|---|
| `path` | 무시돼야 한다 |

## 첫 흐름

| 단계 | 하는 일 | 근거 | 참고 |
|---|---|---|---|
| 하나 | 첫 일 | `a.txt`, `b.txt#기능` | 0001 |
| 둘 | 둘째 일 | - | 계획 |
| 셋 | 셋째 일 | `collector:lambda/x.py` | |

## 둘째 흐름

| 단계 | 하는 일 | 근거 | 참고 |
|---|---|---|---|
| 넷 | 넷째 일 | `c.txt` | |
"""

BACKLOG = """# 백로그

## 지금 방향 (2026-09-24)

**Alpha.**

## 관찰 중 — 기다린다

- **첫 관찰.**
  설명 줄.
  - **하위 굵은 글씨는 항목이 아니다**
- **둘째 관찰.**

## 다음 — 바로 착수

- **다음 일.** 설명

## 대기 — 조건이 차면

| 항목 | 꺼낼 조건 | 근거 |
|---|---|---|
| 대기 일 | 조건 | [[x]] |

## 안 하기로 한 것

- 여기는 세지 않는다
"""


def git(root: Path, *args: str) -> str:
    return subprocess.run(
        ["git", "-c", "user.name=t", "-c", "user.email=t@t", *args],
        cwd=root, check=True, capture_output=True, text=True,
    ).stdout.strip()


class FlowParseTests(unittest.TestCase):
    def test_only_sections_become_flows(self) -> None:
        flows = dev_map.parse_flow(FLOW)
        self.assertEqual([flow.name for flow in flows], ["첫 흐름", "둘째 흐름"])
        self.assertEqual([stage.name for stage in flows[0].stages], ["하나", "둘", "셋"])

    def test_evidence_cells(self) -> None:
        stages = dev_map.parse_flow(FLOW)[0].stages
        self.assertEqual(stages[0].evidence, ["a.txt", "b.txt#기능"])
        self.assertEqual(stages[1].evidence, [])
        self.assertEqual(stages[2].evidence, ["collector:lambda/x.py"])
        self.assertEqual((stages[0].does, stages[0].note), ("첫 일", "0001"))

    def test_real_flow_file_parses_and_names_real_files(self) -> None:
        """development/flow.md 의 근거가 오타면 지도가 조용히 '계획' 으로 그린다. 여기서 막는다."""
        root = Path(__file__).resolve().parents[1]
        flows = dev_map.parse_flow((root / "development" / "flow.md").read_text(encoding="utf-8"))
        self.assertTrue(flows)
        repo = dev_map.Repo(root)
        for flow in flows:
            for stage in flow.stages:
                for item in stage.evidence:
                    if not item.startswith(dev_map.EXTERNAL):
                        self.assertTrue(repo.has(None, item), f"{flow.name}/{stage.name}: {item}")


class StatusTests(unittest.TestCase):
    """임시 저장소: v0.1.0 에 a·b(기능 없음), v0.2.0 에 b 기능, main 에 c, 디스크에만 d."""

    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        git(self.root, "init", "-q", "-b", "main")
        (self.root / "a.txt").write_text("a", encoding="utf-8")
        (self.root / "b.txt").write_text("아직", encoding="utf-8")
        git(self.root, "add", ".")
        git(self.root, "commit", "-q", "-m", "첫")
        git(self.root, "tag", "-a", "v0.1.0", "-m", "v0.1.0")
        (self.root / "b.txt").write_text("이제 기능", encoding="utf-8")
        git(self.root, "commit", "-qam", "기능")
        git(self.root, "tag", "-a", "v0.2.0", "-m", "v0.2.0")
        (self.root / "c.txt").write_text("c", encoding="utf-8")
        git(self.root, "add", "c.txt")
        git(self.root, "commit", "-q", "-m", "c 추가")
        (self.root / "d.txt").write_text("d", encoding="utf-8")
        self.repo = dev_map.Repo(self.root)

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def status(self, *evidence: str) -> dev_map.Status:
        return dev_map.stage_status(self.repo, list(evidence))

    def test_released_in_the_first_tag_that_has_everything(self) -> None:
        self.assertEqual(self.status("a.txt"), dev_map.Status("released", "v0.1.0"))

    def test_marker_moves_the_release_to_where_the_feature_landed(self) -> None:
        """파일은 v0.1.0 부터 있었다. 기능은 v0.2.0 에 들어갔다 — 파일만 보면 거짓 초록불."""
        self.assertEqual(self.status("a.txt", "b.txt#기능"), dev_map.Status("released", "v0.2.0"))

    def test_on_main_but_not_released(self) -> None:
        self.assertEqual(self.status("a.txt", "c.txt"), dev_map.Status("main", None))

    def test_only_on_disk_is_work_in_progress(self) -> None:
        self.assertEqual(self.status("d.txt"), dev_map.Status("working", None))

    def test_missing_or_empty_is_planned(self) -> None:
        self.assertEqual(self.status("없는.txt"), dev_map.Status("planned", None))
        self.assertEqual(self.status(), dev_map.Status("planned", None))
        self.assertEqual(self.status("b.txt#없는 기능"), dev_map.Status("planned", None))

    def test_collector_only_is_external(self) -> None:
        self.assertEqual(self.status("collector:lambda/x.py"), dev_map.Status("external", None))

    def test_site_only_is_external_too(self) -> None:
        self.assertEqual(self.status("site:src/usage.mjs"), dev_map.Status("external", None))

    def test_collector_items_do_not_hold_back_local_ones(self) -> None:
        self.assertEqual(self.status("a.txt", "collector:lambda/x.py"), dev_map.Status("released", "v0.1.0"))

    def test_removed_from_the_latest_release_is_not_released(self) -> None:
        git(self.root, "rm", "-q", "a.txt")
        git(self.root, "commit", "-q", "-m", "a 삭제")
        git(self.root, "tag", "-a", "v0.3.0", "-m", "v0.3.0")
        self.assertEqual(self.status("a.txt"), dev_map.Status("planned", None))

    def test_released_at_the_start_of_the_unbroken_run(self) -> None:
        """v0.1.0 에 있다가 v0.2.0 에서 빠지고 v0.3.0 에 돌아왔다면, 지금 릴리스 기준은 v0.3.0 이다."""
        (self.root / "e.txt").write_text("e", encoding="utf-8")
        git(self.root, "add", "e.txt")
        git(self.root, "commit", "-q", "-m", "e")
        git(self.root, "tag", "-a", "v0.3.0", "-m", "v0.3.0")
        git(self.root, "rm", "-q", "e.txt")
        git(self.root, "commit", "-q", "-m", "e 삭제")
        git(self.root, "tag", "-a", "v0.4.0", "-m", "v0.4.0")
        (self.root / "e.txt").write_text("e", encoding="utf-8")
        git(self.root, "add", "e.txt")
        git(self.root, "commit", "-q", "-m", "e 복구")
        git(self.root, "tag", "-a", "v0.5.0", "-m", "v0.5.0")
        self.assertEqual(self.status("e.txt"), dev_map.Status("released", "v0.5.0"))

    def test_tags_are_in_version_order_not_name_order(self) -> None:
        git(self.root, "tag", "-a", "v0.10.0", "-m", "v0.10.0")
        self.assertEqual([tag for tag, _ in self.repo.tags()][-1], "v0.10.0")

    def test_releases_list_unreleased_commits(self) -> None:
        self.assertEqual(self.repo.unreleased(), ["c 추가"])


class BacklogParseTests(unittest.TestCase):
    def test_sections_and_items(self) -> None:
        backlog = dev_map.parse_backlog(BACKLOG)
        self.assertEqual(backlog["관찰 중"], ["첫 관찰", "둘째 관찰"])
        self.assertEqual(backlog["다음"], ["다음 일"])
        self.assertEqual(backlog["대기"], ["대기 일"])
        self.assertNotIn("안 하기로 한 것", backlog)

    def test_real_backlog_has_the_three_sections(self) -> None:
        root = Path(__file__).resolve().parents[1]
        backlog = dev_map.parse_backlog((root / "development" / "backlog.md").read_text(encoding="utf-8"))
        self.assertEqual(set(backlog), {"관찰 중", "다음", "대기"})
        self.assertTrue(all(backlog.values()))


class RenderTests(unittest.TestCase):
    def test_html_shows_status_and_escapes(self) -> None:
        flows = dev_map.parse_flow(FLOW.replace("첫 일", "<b>첫</b> 일"))
        statuses = {("첫 흐름", "하나"): dev_map.Status("released", "v0.2.0")}
        html = dev_map.render_html(
            flows, statuses, releases=[("v0.2.0", "2026-09-28")], unreleased=["c 추가"],
            backlog={"관찰 중": ["첫 관찰"], "다음": [], "대기": []}, plans=[("계획 제목", "상태 줄")],
        )
        self.assertIn("v0.2.0", html)
        self.assertIn("&lt;b&gt;첫&lt;/b&gt; 일", html)
        self.assertNotIn("<b>첫</b>", html)
        self.assertIn("c 추가", html)
        self.assertIn("계획 제목", html)


if __name__ == "__main__":
    unittest.main(verbosity=2)
