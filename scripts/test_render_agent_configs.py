#!/usr/bin/env python3
"""render_agent_configs.py 가 만드는 Kiro 기록 검사 훅.

실측 (kiro-cli 2.27.1, v3, 2026-10-06 — 평가 사본에 탐침 훅을 걸고 사람 없이, 그리고 TUI 로):
  - `PostFileSave` 는 에이전트가 파일을 만들 때도 고칠 때도 돈다. 입력의 `file_path` 는 절대 경로다.
  - 명령 훅의 출력은 에이전트에게 안 간다 — 종료 0 의 stdout 도, 종료 1·2 의 stderr 도. 문서는 간다고 적는다.
  - `"action": {"type": "agent", "prompt": …}` 는 간다. `prompt`·`askAgent`·`agentPrompt` 는 돌지 않는다.
  - TUI 에서 기록을 FAIL 나게 고치게 했더니 에이전트가 이 지시문을 받고 검사기를 돌려 되돌렸다.
"""

from __future__ import annotations

import json
import re
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
import render_agent_configs as rac  # noqa: E402

HOOK_FILE = ".kiro/hooks/ticket-record-check.json"


class KiroRecordCheckHookTests(unittest.TestCase):
    def hook(self) -> dict:
        payload = json.loads(rac.rendered_files(rac.load_manifest())[HOOK_FILE])
        self.assertEqual(payload["version"], "v1")
        self.assertEqual(len(payload["hooks"]), 1)
        return payload["hooks"][0]

    def test_fires_after_the_agent_saves_a_ticket_record_and_nothing_else(self) -> None:
        hook = self.hook()
        self.assertEqual(hook["trigger"], "PostFileSave")
        matcher = re.compile(hook["matcher"])
        for path in ("/Users/someone/tiket/tickets/900103.md", "tickets/900103.md", "C:/work/tiket/tickets/L-001.md"):
            self.assertTrue(matcher.search(path), path)
        for path in ("templates/ticket-intake.md", "/x/tiket/tickets/900103.md.bak", "/x/tiket/tickets/img/a.md",
                     "/x/tiket/mytickets/a.md", "/x/tiket/policy/cards/POLICY-OT-001.md", "/x/tiket/tickets/900103.txt"):
            self.assertFalse(matcher.search(path), path)

    def test_tells_the_agent_instead_of_printing_because_command_output_never_arrives(self) -> None:
        action = self.hook()["action"]
        self.assertEqual(action["type"], "agent")
        self.assertNotIn("command", action)

    def test_asks_only_for_the_existing_checker(self) -> None:
        """훅이 따로 규칙을 들고 있으면 검사기와 두 벌이 된다. 부르라고만 하고, 통과했으면 더 시키지 않는다."""
        prompt = self.hook()["action"]["prompt"]
        self.assertIn("scripts/check_ticket_record.py", prompt)
        self.assertIn("FAIL", prompt)
        self.assertRegex(prompt, r"PASS[^.]*do nothing further")
        for other in ("validate_workspace", "fetch-ticket", "aws ", "Zendesk", "send"):
            self.assertNotIn(other, prompt)

    def test_the_committed_file_is_what_the_generator_writes(self) -> None:
        self.assertEqual((ROOT / HOOK_FILE).read_text(encoding="utf-8"), rac.rendered_files(rac.load_manifest())[HOOK_FILE])


SKILL_SOURCE = ROOT / "skills/aws-customer-account-ops/SKILL.md"
# 호스트가 워크스페이스 스킬을 읽는 자리 (공식 문서, 2026-10-20). Codex 와 Hermes 는 .agents/skills 를 같이 읽는다.
SKILL_HOST_FILES = (
    ".claude/skills/aws-customer-account-ops/SKILL.md",
    ".kiro/skills/aws-customer-account-ops/SKILL.md",
    ".agents/skills/aws-customer-account-ops/SKILL.md",
)


class WorkspaceSkillTests(unittest.TestCase):
    def rendered(self) -> dict[str, str]:
        return rac.rendered_files(rac.load_manifest())

    def test_every_host_gets_the_skill_with_frontmatter_first(self) -> None:
        """Kiro·Codex 는 SKILL.md 가 frontmatter 로 시작해야 읽는다. 생성 표시는 그 뒤에 둔다."""
        source_head = SKILL_SOURCE.read_text(encoding="utf-8").split("\n---\n", 1)[0]
        for relative in SKILL_HOST_FILES:
            content = self.rendered()[relative]
            self.assertTrue(content.startswith(source_head + "\n---\n"), relative)
            self.assertIn("Do not edit by hand", content, relative)

    def test_links_reach_the_one_copy_of_references_and_examples(self) -> None:
        """사본에는 SKILL.md 만 있다. 상대 링크가 그 자리에서 실제 파일로 풀려야 한다."""
        for relative in SKILL_HOST_FILES:
            content = self.rendered()[relative]
            links = re.findall(r"\]\(([^)#]+\.md)\)", content)
            self.assertGreaterEqual(len(links), 9, relative)
            for link in links:
                target = (ROOT / relative).parent / link
                self.assertTrue(target.resolve().is_file(), f"{relative}: {link}")

    def test_body_is_the_source_apart_from_links(self) -> None:
        source = SKILL_SOURCE.read_text(encoding="utf-8")
        for relative in SKILL_HOST_FILES:
            content = self.rendered()[relative]
            strip = lambda text: re.sub(r"\]\([^)]*\)", "]()", re.sub(r"<!--.*?-->\n", "", text))  # noqa: E731
            self.assertEqual(strip(content), strip(source), relative)

    def test_the_committed_copies_are_what_the_generator_writes(self) -> None:
        for relative in SKILL_HOST_FILES:
            self.assertEqual((ROOT / relative).read_text(encoding="utf-8"), self.rendered()[relative], relative)


class ClaudeSettingsTests(unittest.TestCase):
    def test_registers_no_plugins_or_marketplaces_because_the_flow_mod_was_removed(self) -> None:
        settings = json.loads(rac.rendered_files(rac.load_manifest())[".claude/settings.json"])
        self.assertEqual(
            set(settings), {"enableAllProjectMcpServers", "enabledMcpjsonServers", "permissions", "hooks"}
        )


if __name__ == "__main__":
    unittest.main(verbosity=2)
