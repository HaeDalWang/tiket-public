#!/usr/bin/env python3
"""scripts/eval_run.py 테스트. Kiro 를 띄우지 않고, 실제 ~/.kiro 와 네트워크에 닿지 않는다.

실제 PC 에서 확인한 것 (2026-10-02, kiro-cli 2.27.0 · KAS 0.66.22, macOS, `--no-interactive --trust-tools=`):
  권한 규칙에 없는 셸 명령과 파일 쓰기는 거절된다(`tool_call_update` 의 `status: failed`). 작업 폴더 안 읽기는 된다.
  `~/.kiro/workspace-roots/<해시>/permissions.yaml` 의 allow 규칙은 비대화형에서도 먹는다.
  `;`·`|`·`&&` 로 이은 명령은 조각마다 따로 본다 — 조각 하나라도 규칙 밖이면 전체가 거절된다. `2>&1` 은 괜찮다.
  `exclude` 의 `* /*`·`* ~*`·`*..*`·`*$*` 는 `cat /etc/hosts`·`cat ~/.zshrc`·`cat ../x`·`cat $HOME/x` 를 막았다.
  유지보수자 PC 의 전역 규칙(`~/.kiro/settings/permissions.yaml`)이 `python3 *` 를 허용하고 있어 사본 규칙에 없는
  `python3 -c "print(1)"` 이 돌았다. 공식 문서: "deny > ask > allow … the most restrictive effect wins regardless of which
  scope" · "When no interactive client is available, every `ask` is treated as a deny" (kiro.dev/docs/permissions, 2026-10-02 조회).
  그래서 허용 목록 밖은 사본 규칙이 `deny` 로 못 박는다. 전역 MCP 서버(`aws-mcp` 등)도 같은 방법으로 막는다.
  입력 리다이렉트는 규칙이 못 본다 — `cat</etc/hosts` 가 `*<*` 제외를 지나 돌았다. 맨 `cat` 을 허용하지 않아 이 모양은 막고,
  `head -5 < 밖` 같은 모양은 못 막는다. 대신 그런 호출이 돌면 summary 의 `escaped` 에 남긴다.
  **거절을 "사용자가 거절했다" 로 읽고 멈춘다** — 첫 실행에서 `python3 scripts/local_capabilities.py 2>&1 | head -40` 이
  거절되자 기록 없이 끝났다. 그래서 작업 폴더 안 읽기 명령은 허용한다.
"""

from __future__ import annotations

import importlib.util
import json
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("eval_run", ROOT / "scripts/eval_run.py")
er = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(er)

CASE = """# EVAL-900 · 시험

## 프롬프트

```
티켓 900900 처리해줘.

--- 티켓 900900 ---
제목: [합성고객] 시험
--- 끝 ---
```

## 기대 결과

```
이 블록은 프롬프트가 아니다
```
"""

SWAP_SECTION = """
## 사본 바꾸기

```replace agents/locks.md
잠금 없음
=====
잠금 하나
```

```replace agents/locks.md
| — |
=====
| 합성 |
```

```
=====
이 블록은 replace 가 아니라서 무시된다
```
"""

CHECKER = "import sys\nprint('ticket record: PASS 1 / FAIL 0 / 미평가 0 (총 1건)' if sys.argv[1] == '900900' else 'FAIL')\n"


def event(update: dict) -> str:
    return json.dumps({"type": "sessionUpdate", "data": {"update": update}}, ensure_ascii=False)


TRANSCRIPT = "\n".join([
    json.dumps({"type": "runStarted", "data": {"engine": "v3"}}),
    "[INFO] 로그 줄은 JSON 이 아니다",
    event({"sessionUpdate": "session_info_update", "_meta": {"kiro": {"breakdown": {"contextFiles": {"items": [
        {"name": "~/.kiro/steering/00-global.md"}, {"name": ".kiro/steering/00-repository-rules.md"}]}}}}}),
    event({"sessionUpdate": "tool_call", "toolCallId": "a", "kind": "read", "rawInput": {"path": "/ws/CLAUDE.md"}}),
    event({"sessionUpdate": "tool_call_update", "toolCallId": "a", "status": "completed"}),
    event({"sessionUpdate": "tool_call", "toolCallId": "b", "kind": "execute", "rawInput": {"command": "aws sts get-caller-identity"}}),
    event({"sessionUpdate": "tool_call_update", "toolCallId": "b", "status": "in_progress"}),
    event({"sessionUpdate": "tool_call_update", "toolCallId": "b", "status": "failed"}),
    event({"sessionUpdate": "tool_call", "toolCallId": "c", "kind": "execute", "rawInput": {"command": "head -5 < /Users/x/secret"}}),
    event({"sessionUpdate": "tool_call_update", "toolCallId": "c", "status": "completed"}),
    json.dumps({"type": "runFinished", "data": {"status": "success", "stopReason": "end_turn", "finalText": "끝났다"}}),
])


def git(repo: Path, *args: str) -> None:
    subprocess.run(["git", *args], cwd=repo, check=True, capture_output=True)


def make_repo(base: Path) -> Path:
    repo = base / "repo"
    for relative, content in {
        "CLAUDE.md": "계약\n",
        "scripts/check_ticket_record.py": CHECKER,
        "evals/cases/EVAL-900-probe.md": CASE,
        "development/backlog.md": "EVAL-900 의 답이 여기 적혀 있다\n",
        "agents/locks.md": "잠금 없음\n| — |\n끝\n",
        "evals/cases/EVAL-901-swap.md": CASE + SWAP_SECTION,
    }.items():
        path = repo / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content, encoding="utf-8")
    git(repo, "init", "-q")
    git(repo, "add", "-A")
    git(repo, "-c", "user.name=t", "-c", "user.email=t", "commit", "-q", "-m", "init")
    # 커밋하지 않은 것들 — 사본에 들어가면 안 된다
    (repo / "tickets").mkdir()
    (repo / "tickets/900900.md").write_text("이전 회차 기록\n", encoding="utf-8")
    (repo / ".private").mkdir()
    (repo / ".private/real-customer.md").write_text("실제 고객\n", encoding="utf-8")
    (repo / "CLAUDE.md").write_text("커밋 안 한 수정\n", encoding="utf-8")
    return repo


class PromptTests(unittest.TestCase):
    def test_takes_only_the_block_under_the_prompt_heading(self) -> None:
        prompt = er.prompt_of(CASE)
        self.assertTrue(prompt.startswith("티켓 900900 처리해줘."))
        self.assertTrue(prompt.endswith("--- 끝 ---"))
        self.assertNotIn("프롬프트가 아니다", prompt)

    def test_refuses_a_case_without_a_prompt_block(self) -> None:
        with self.assertRaises(ValueError):
            er.prompt_of("# EVAL-901\n\n## 기대 결과\n\n```\n없음\n```\n")


class SandboxTests(unittest.TestCase):
    def test_copy_holds_committed_framework_only(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            repo = make_repo(Path(tmp))
            sandbox = er.build_sandbox(repo, "HEAD", Path(tmp) / "run/tiket")
            self.assertEqual((sandbox / "CLAUDE.md").read_text(encoding="utf-8"), "계약\n")
            self.assertTrue((sandbox / "scripts/check_ticket_record.py").is_file())
            for gone in ("evals", "development", ".git", ".private"):
                self.assertFalse((sandbox / gone).exists(), gone)
            self.assertEqual(list((sandbox / "tickets").iterdir()), [])

    def test_copy_names_an_agent_that_adds_nothing_but_the_repository_mcp_servers(self) -> None:
        """kiro-cli 2.27.1 은 사람 없이 돌 때 내장 에이전트를 못 찾고 종료 4 로 끝난다 — 파일로 정의한 에이전트는 된다."""
        with tempfile.TemporaryDirectory() as tmp:
            sandbox = er.build_sandbox(make_repo(Path(tmp)), "HEAD", Path(tmp) / "run/tiket")
            config = json.loads((sandbox / f".kiro/agents/{er.AGENT_NAME}.json").read_text(encoding="utf-8"))
            # 지시문·도구 제한을 더하면 기준선(내장 에이전트)과 조건이 달라진다. 이름·설명·도구 전부·MCP 포함만 둔다.
            self.assertEqual(set(config), {"name", "description", "tools", "includeMcpJson"})
            # `tools` 를 비우면 파일 읽기·셸이 아예 없다 — 29초 만에 "도구가 없다" 로 끝났다(2026-10-06 실측).
            self.assertEqual(config["tools"], ["*"])
            self.assertEqual(config["name"], er.AGENT_NAME)
            self.assertIs(config["includeMcpJson"], True)
            # 이름·설명으로 평가인 줄 알게 하지 않는다.
            self.assertNotRegex(json.dumps(config, ensure_ascii=False).lower(), "eval|평가|시험|test")

    def test_rules_allow_framework_scripts_and_ticket_writes_only(self) -> None:
        block = er.permissions_text()
        self.assertIn('"bash scripts/fetch-ticket.sh*"', block)
        self.assertIn('"python3 scripts/check_ticket_record.py*"', block)
        self.assertIn('"tickets/**"', block)
        for forbidden in ('"aws *', '"aws"', "customers", "curl", '"python3 *"', '"python3 -c', "bash -c", '"cd', '"cat"'):
            self.assertNotIn(forbidden, block)

    def test_everything_outside_the_allow_list_is_denied_not_just_unlisted(self) -> None:
        # 전역 규칙이 무엇을 허용하든 이긴다 — deny > ask > allow
        allowed = {pattern for rule in er.SANDBOX_RULES
                   if rule["capability"] == "shell" and rule.get("effect", "allow") == "allow" for pattern in rule["match"]}
        denies = [rule for rule in er.SANDBOX_RULES if rule.get("effect") == "deny"]
        catch_all = [rule for rule in denies if rule["capability"] == "shell" and rule["match"] == ("*",)]
        self.assertEqual(len(catch_all), 1)
        self.assertEqual(set(catch_all[0]["exclude"]), allowed)
        outside = [rule for rule in denies if rule["capability"] == "shell" and "* /*" in rule["match"]]
        self.assertEqual(len(outside), 1)
        self.assertNotIn("exclude", outside[0])
        mcp = [rule for rule in denies if rule["capability"] == "mcp"]
        self.assertEqual([(rule["match"], rule["exclude"]) for rule in mcp], [(("*",), ("aws-docs/*", "exa/*"))])
        self.assertEqual(er.permissions_text().count("effect: deny"), 3)

    def test_read_commands_cannot_leave_the_copy(self) -> None:
        reads = [rule for rule in er.SANDBOX_RULES if "cat *" in rule["match"] and rule.get("effect", "allow") == "allow"]
        self.assertEqual(len(reads), 1)
        for needed in ("* /*", "* ~*", "*..*", "*$*", "*`*", '*"/*', "*'/*", "find * -exec*", "find * -delete*"):
            self.assertIn(needed, reads[0]["exclude"], needed)
        # 따옴표가 든 패턴은 YAML 큰따옴표 안에서 이스케이프돼야 한다 — 안 그러면 파일이 깨져 규칙 전체가 안 먹는다
        self.assertIn('      - "*\\"/*"\n', er.permissions_text())
        for rule in er.SANDBOX_RULES:
            if rule["capability"] == "shell" and rule.get("effect", "allow") == "allow" and rule is not reads[0]:
                self.assertTrue(all(pattern.startswith(("bash scripts/", "python3 scripts/", "python scripts/"))
                                    for pattern in rule["match"]), rule["match"])

    def test_permissions_go_to_the_folder_kiro_reads_and_never_replace_one(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            home, sandbox = Path(tmp) / "home", Path(tmp) / "run/tiket"
            sandbox.mkdir(parents=True)
            folder = er.install_permissions(sandbox, home)
            self.assertEqual(folder.parent, home / ".kiro/workspace-roots")
            self.assertEqual(folder, er.kiro_permissions.workspace_dir(sandbox.resolve(), home))
            self.assertEqual((folder / "permissions.yaml").read_text(encoding="utf-8"), er.permissions_text())
            with self.assertRaises(FileExistsError):
                er.install_permissions(sandbox, home)

    def test_the_session_notice_cannot_swap_the_rules_for_the_everyday_ones(self) -> None:
        """사본 안의 에이전트는 `local_capabilities.py` 를 돌릴 수 있고, 그 스크립트는 tiket 표식이 든 권한 파일을
        평소 규칙(aws 읽기 허용, 전부-deny 없음)으로 다시 쓴다. 2026-10-06 에 실제로 그렇게 덮였다."""
        with tempfile.TemporaryDirectory() as tmp:
            home, sandbox = Path(tmp) / "home", Path(tmp) / "run/tiket"
            sandbox.mkdir(parents=True)
            target = er.install_permissions(sandbox, home) / "permissions.yaml"
            self.assertIsNone(er.kiro_permissions.refresh_if_installed(sandbox.resolve(), home))
            self.assertEqual(target.read_text(encoding="utf-8"), er.permissions_text())
            self.assertFalse(target.with_name("permissions.yaml.bak").exists())

    def test_reads_are_allowed_inside_the_copy_only(self) -> None:
        # 파일로 정의한 에이전트에서는 사본 안 읽기도 묻는다 — 규칙이 없으면 CLAUDE.md 도 못 읽고 23초에 끝난다(2026-10-06).
        reads = [rule for rule in er.SANDBOX_RULES if rule["capability"] == "fs_read"]
        self.assertEqual([(rule.get("effect", "allow"), rule["match"]) for rule in reads], [("allow", ("./**",))])


class SandboxChangeTests(unittest.TestCase):
    def sandbox(self) -> Path:
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        base = Path(tmp.name)
        (base / "box/agents").mkdir(parents=True)
        (base / "box/agents/locks.md").write_text("잠금 없음\n| — |\n끝\n", encoding="utf-8")
        return base / "box"

    def case(self, *blocks: str, info: str = "replace agents/locks.md") -> str:
        body = "".join(f"\n```{info}\n{block}\n```\n" for block in blocks)
        return CASE + "\n## 사본 바꾸기\n" + body

    def locks(self, box: Path) -> str:
        return (box / "agents/locks.md").read_text(encoding="utf-8")

    def test_replaces_old_text_with_new_in_block_order_and_names_the_file_once(self) -> None:
        box = self.sandbox()
        changed = er.apply_sandbox_changes(self.case("잠금 없음\n=====\n잠금 하나", "잠금 하나\n=====\n잠금 둘"), box)
        self.assertEqual(self.locks(box), "잠금 둘\n| — |\n끝\n")
        self.assertEqual(changed, ["agents/locks.md"])

    def test_a_case_without_the_section_changes_nothing(self) -> None:
        box = self.sandbox()
        self.assertEqual(er.apply_sandbox_changes(CASE, box), [])
        self.assertEqual(self.locks(box), "잠금 없음\n| — |\n끝\n")

    def test_blocks_that_are_not_replace_blocks_are_ignored(self) -> None:
        box = self.sandbox()
        self.assertEqual(er.apply_sandbox_changes(self.case("없는 글\n=====\n새 글", info="text"), box), [])
        self.assertEqual(self.locks(box), "잠금 없음\n| — |\n끝\n")

    def test_stops_when_the_old_text_is_missing(self) -> None:
        box = self.sandbox()
        with self.assertRaises(ValueError):
            er.apply_sandbox_changes(self.case("프레임워크가 바뀌었다\n=====\n새 글"), box)
        self.assertEqual(self.locks(box), "잠금 없음\n| — |\n끝\n")

    def test_stops_when_the_old_text_appears_more_than_once(self) -> None:
        box = self.sandbox()
        (box / "agents/locks.md").write_text("끝\n끝\n", encoding="utf-8")
        with self.assertRaises(ValueError):
            er.apply_sandbox_changes(self.case("끝\n=====\n새 글"), box)
        self.assertEqual(self.locks(box), "끝\n끝\n")

    def test_stops_when_a_block_has_no_separator_or_two(self) -> None:
        for block in ("잠금 없음", "잠금 없음\n=====\n하나\n=====\n둘"):
            box = self.sandbox()
            with self.assertRaises(ValueError, msg=block):
                er.apply_sandbox_changes(self.case(block), box)
            self.assertEqual(self.locks(box), "잠금 없음\n| — |\n끝\n")

    def test_never_touches_a_file_outside_the_copy(self) -> None:
        box = self.sandbox()
        outside = box.parent / "outside.md"
        outside.write_text("잠금 없음\n", encoding="utf-8")
        for path in ("../outside.md", str(outside)):
            with self.assertRaises(ValueError, msg=path):
                er.apply_sandbox_changes(self.case("잠금 없음\n=====\n새 글", info=f"replace {path}"), box)
            self.assertEqual(outside.read_text(encoding="utf-8"), "잠금 없음\n", path)

    def test_stops_when_the_file_is_not_in_the_copy(self) -> None:
        with self.assertRaises(ValueError):
            er.apply_sandbox_changes(self.case("a\n=====\nb", info="replace agents/none.md"), self.sandbox())

    def test_the_prompt_is_still_only_the_prompt_block(self) -> None:
        self.assertEqual(er.prompt_of(self.case("잠금 없음\n=====\n새 글")), er.prompt_of(CASE))


class CommandTests(unittest.TestCase):
    def test_kiro_runs_without_a_person_and_trusts_no_tool(self) -> None:
        argv = er.kiro_command("프롬프트")
        self.assertEqual(argv[:2], ["kiro-cli", "chat"])
        self.assertIn("--no-interactive", argv)
        self.assertIn("--trust-tools=", argv)
        self.assertEqual(argv[-1], "프롬프트")
        self.assertEqual(argv[argv.index("--agent") + 1], er.AGENT_NAME)
        for dangerous in ("-a", "--trust-all-tools"):
            self.assertNotIn(dangerous, argv)

    def test_run_never_reports_usage(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            env = er.run_env({"PATH": "/bin", "TIKET_TELEMETRY": "on"}, Path(tmp))
            self.assertEqual(env["TIKET_TELEMETRY"], "off")
            self.assertEqual(env["PATH"], "/bin")
            self.assertTrue(env["TIKET_USAGE_STAMP"].startswith(tmp))


class TranscriptTests(unittest.TestCase):
    def test_summary_names_refused_calls_and_loaded_context(self) -> None:
        summary = er.summarize_transcript(TRANSCRIPT)
        self.assertEqual(summary["engine"], "v3")
        self.assertEqual(summary["stop_reason"], "end_turn")
        self.assertEqual(summary["final_text"], "끝났다")
        self.assertEqual(summary["tools"]["completed"], 2)
        self.assertEqual(summary["escaped"], ["head -5 < /Users/x/secret"])
        self.assertEqual(summary["tools"]["failed"], [{"kind": "execute", "target": "aws sts get-caller-identity"}])
        self.assertEqual(summary["context_files"], [".kiro/steering/00-repository-rules.md", "~/.kiro/steering/00-global.md"])

    def test_a_run_that_never_finished_says_so(self) -> None:
        summary = er.summarize_transcript("[INFO] 시작만 했다\n")
        self.assertIsNone(summary["stop_reason"])
        self.assertEqual(summary["tools"], {"completed": 0, "failed": []})
        self.assertEqual(summary["escaped"], [])


class RunTests(unittest.TestCase):
    def paths(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        base = Path(tmp.name)
        return er.Paths(root=make_repo(base), home=base / "home", runs=base / "runs", sandboxes=base / "sandboxes")

    def test_collects_records_checks_them_and_cleans_up(self) -> None:
        paths, seen = self.paths(), {}

        def runner(argv, cwd, env, timeout):
            seen.update(cwd=cwd, env=env)
            seen["permissions"] = sorted((paths.home / ".kiro/workspace-roots").glob("*/permissions.yaml"))
            (cwd / "tickets/900900.md").write_text("# 900900 · 합성고객 · 시험\n", encoding="utf-8")
            return 0, TRANSCRIPT, "stderr 줄"

        summary = er.run_once("EVAL-900", 1, "HEAD", paths, runner=runner, timeout=5, today="2026-10-02")
        self.assertEqual(len(seen["permissions"]), 1)
        self.assertEqual(seen["cwd"].name, "tiket")
        self.assertNotIn("eval", str(seen["cwd"].relative_to(paths.sandboxes)).lower())
        self.assertEqual(seen["env"]["TIKET_TELEMETRY"], "off")
        run_dir = paths.runs / "2026-10-02-EVAL-900-kiro-1"
        self.assertEqual((run_dir / "tickets/900900.md").read_text(encoding="utf-8"), "# 900900 · 합성고객 · 시험\n")
        self.assertTrue((run_dir / "prompt.txt").read_text(encoding="utf-8").startswith("티켓 900900"))
        self.assertEqual((run_dir / "transcript.jsonl").read_text(encoding="utf-8"), TRANSCRIPT)
        self.assertEqual(json.loads((run_dir / "summary.json").read_text(encoding="utf-8")), summary)
        self.assertEqual(summary["records"], [{"file": "900900.md", "check": "ticket record: PASS 1 / FAIL 0 / 미평가 0 (총 1건)"}])
        self.assertEqual(summary["exit"], 0)
        self.assertEqual(len(summary["ref"]), 40)
        self.assertFalse(seen["cwd"].exists(), "사본이 남았다")
        self.assertEqual(list((paths.home / ".kiro/workspace-roots").iterdir()), [], "권한 폴더가 남았다")

    def test_cleans_up_even_when_the_agent_hangs(self) -> None:
        paths = self.paths()

        def runner(argv, cwd, env, timeout):
            raise subprocess.TimeoutExpired(argv, timeout, output="", stderr="")

        summary = er.run_once("EVAL-900", 1, "HEAD", paths, runner=runner, timeout=5, today="2026-10-02")
        self.assertEqual(summary["exit"], "timeout")
        self.assertEqual(summary["records"], [])
        self.assertEqual(list(paths.sandboxes.iterdir()), [])
        self.assertEqual(list((paths.home / ".kiro/workspace-roots").iterdir()), [])

    def test_does_not_overwrite_an_earlier_run(self) -> None:
        paths = self.paths()

        def runner(argv, cwd, env, timeout):
            return 0, TRANSCRIPT, ""

        er.run_once("EVAL-900", 1, "HEAD", paths, runner=runner, timeout=5, today="2026-10-02")
        with self.assertRaises(FileExistsError):
            er.run_once("EVAL-900", 1, "HEAD", paths, runner=lambda *_: (0, "두 번째", ""), timeout=5, today="2026-10-02")
        kept = paths.runs / "2026-10-02-EVAL-900-kiro-1/transcript.jsonl"
        self.assertEqual(kept.read_text(encoding="utf-8"), TRANSCRIPT)
        self.assertEqual(er.next_number("EVAL-900", paths, "2026-10-02"), 2)

    def test_applies_the_case_changes_to_the_copy_before_kiro_runs_and_records_them(self) -> None:
        paths, seen = self.paths(), {}

        def runner(argv, cwd, env, timeout):
            seen["locks"] = (cwd / "agents/locks.md").read_text(encoding="utf-8")
            return 0, TRANSCRIPT, ""

        summary = er.run_once("EVAL-901", 1, "HEAD", paths, runner=runner, timeout=5, today="2026-10-24")
        self.assertEqual(seen["locks"], "잠금 하나\n| 합성 |\n끝\n")
        self.assertEqual(summary["sandbox_changes"], ["agents/locks.md"])
        saved = json.loads((paths.runs / "2026-10-24-EVAL-901-kiro-1/summary.json").read_text(encoding="utf-8"))
        self.assertEqual(saved["sandbox_changes"], ["agents/locks.md"])

    def test_a_case_without_changes_records_an_empty_list(self) -> None:
        summary = er.run_once("EVAL-900", 1, "HEAD", self.paths(), runner=lambda *_: (0, TRANSCRIPT, ""), timeout=5, today="2026-10-24")
        self.assertEqual(summary["sandbox_changes"], [])

    def test_a_change_that_no_longer_fits_stops_before_kiro_and_leaves_nothing_behind(self) -> None:
        paths, calls = self.paths(), []
        (paths.root / "agents/locks.md").write_text("프레임워크가 바뀌었다\n", encoding="utf-8")
        git(paths.root, "-c", "user.name=t", "-c", "user.email=t", "commit", "-q", "-am", "문서가 바뀌었다")
        with self.assertRaises(ValueError):
            er.run_once("EVAL-901", 1, "HEAD", paths, runner=lambda *a: calls.append(a), timeout=5, today="2026-10-24")
        self.assertEqual(calls, [])
        self.assertFalse(paths.runs.exists() and list(paths.runs.iterdir()), "빈 회차 폴더가 남았다")
        self.assertEqual(list(paths.sandboxes.iterdir()), [])
        self.assertFalse((paths.home / ".kiro/workspace-roots").exists() and list((paths.home / ".kiro/workspace-roots").iterdir()))


if __name__ == "__main__":
    unittest.main()
