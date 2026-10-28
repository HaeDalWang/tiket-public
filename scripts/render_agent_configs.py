#!/usr/bin/env python3
"""Render project-scoped MCP configuration for every supported host from one manifest.

The manifest at agents/environment/mcp-manifest.json is the only place a capability
is declared. Host files are generated so that Kiro, Claude Code, and Codex cannot
drift apart, and so the validator can prove they match.

Usage:
    python3 scripts/render_agent_configs.py            # write host files
    python3 scripts/render_agent_configs.py --check    # verify without writing
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MANIFEST_PATH = ROOT / "agents/environment/mcp-manifest.json"

GENERATED_NOTE = (
    "Generated from agents/environment/mcp-manifest.json by "
    "scripts/render_agent_configs.py. Do not edit by hand."
)
# JSON has no comment syntax and host schemas may reject unknown top-level keys, so
# the generated marker only appears in the TOML output. Drift is caught by
# scripts/validate_workspace.py instead of by an in-file marker.


def load_manifest() -> dict:
    return json.loads(MANIFEST_PATH.read_text(encoding="utf-8"))


def server_by_id(manifest: dict) -> dict[str, dict]:
    return {server["id"]: server for server in manifest["servers"]}


# 세션 시작 훅은 **한 명령**이고, 업데이트(check-freshness) → 지표 전송(report_usage --if-due) 순서는
# scripts/session_start.py 안에서 지킨다 (2026-09-29). 호스트 파일은 얇은 어댑터다 — 판단 로직은
# 스크립트 안에 있다 (0016, 0020, agents/shared-agent-environment.md "Hook portability").
#
# **이 명령은 고정이다.** Codex 는 훅 내용의 해시를 사용자별로 승인받고, 바뀌면 "Hooks need review" 를
# 띄운 뒤 건너뛰면 끈다(openai/codex hooks/src/engine/discovery.rs). v0.1.4 에서 명령을 합친 순간 먼저
# 승인한 사람 전원의 훅이 꺼졌다. 바꿀 것은 스크립트 안에서 바꾼다. 해시는
# test_onboarding_parity.py 의 PINNED_CODEX_HOOK_HASH 가 붙잡는다.
#
# git 루트 기준이다 — Claude Code·Codex 모두 세션을 연 폴더에서 돌린다("Codex may start from a
# subdirectory", learn.chatgpt.com/docs/hooks). `||` 는 Windows Git Bash 처럼 python3 가 없는 곳에서
# python 으로 넘어간다. 병렬 실행 문제(두 훅이 동시에 돌아 전송이 옛 버전으로 찍힘)도 한 명령이라 없다.
SESSION_HOOK_NAME = "tiket-session-start"
# Codex 는 v0.1.4 명령을 그대로 둔다 — 그때 Trust 한 사람을 다시 묻지 않으려고. 셸 차이는 Codex 에 없다
# (macOS·Linux 는 $SHELL -lc, Windows 는 command_windows 를 따로 쓴다). 하위 폴더 보정은 포기한 값이다.
CODEX_SESSION_HOOK_COMMAND = "bash scripts/check-freshness.sh; python3 scripts/report_usage.py --if-due"
_SESSION_SCRIPT = '"$(git rev-parse --show-toplevel)/scripts/session_start.py"'
SESSION_HOOK_COMMAND = f"python3 {_SESSION_SCRIPT} || python {_SESSION_SCRIPT}"
# Windows 에서 `bash …; python3 …` 가 도는지 모른다. Codex 만 Windows 전용 명령을 받는다
# (learn.chatgpt.com/docs/hooks "command_windows", 2026-09-29). 셸이 `;` 를 어떻게 읽는지
# 문서에 없어서 프로그램 하나를 부른다. 순서는 스크립트 안에서 지킨다.
SESSION_HOOK_COMMAND_WINDOWS = "pwsh -NoProfile -File scripts/session-start.ps1"
# Kiro IDE 는 Node spawn(shell: true) 로 돌린다 — Windows 는 cmd.exe 라 `;` 가 구분자가 아니다
# (Kiro IDE 1.1.14 번들, nodejs.org child_process, 2026-09-29). `||` 는 sh·cmd 에서 같은 뜻이고,
# Windows 에 python3 가 없으면 python 으로 넘어간다. 순서는 session_start.py 안에서 지킨다.
KIRO_SESSION_HOOK_COMMAND = "python3 scripts/session_start.py || python scripts/session_start.py"
# 기본 60초. git fetch 가 느린 날에도 전송까지 가게 넉넉히 (kiro.dev/docs/hooks "timeout").
KIRO_HOOK_TIMEOUT_SECONDS = 120
SESSION_HOOK_LABEL = "Updating the workspace if safe, then sending usage metrics (no customer content)"


def render_kiro_hook_file(name: str, command: str) -> str:
    """Kiro: .kiro/hooks/*.json, v1 스키마.

    SessionStart 는 IDE 전용이고 AgentSpawn 은 CLI 전용이라 둘 다 등록해야 양쪽이 덮인다
    (kiro.dev/docs/hooks, 2026-09-20 조회).
    """
    payload = {
        "version": "v1",
        "hooks": [
            {
                "name": f"{name}-{trigger.lower()}",
                "trigger": trigger,
                "action": {"type": "command", "command": command},
                "timeout": KIRO_HOOK_TIMEOUT_SECONDS,
            }
            for trigger in ("SessionStart", "AgentSpawn")
        ],
    }
    return json.dumps(payload, indent=2, ensure_ascii=False) + "\n"


def render_kiro_hooks(manifest: dict) -> str:
    return render_kiro_hook_file(SESSION_HOOK_NAME, KIRO_SESSION_HOOK_COMMAND)


# 기록을 저장하면 검사기를 돌리라고 에이전트에게 말한다 (0038). 명령 훅으로 검사기를 직접 돌려도 그 출력은
# 에이전트에게 안 간다 — kiro-cli 2.27.1 에서 종료 0 의 stdout 도, 종료 1·2 의 stderr 도 안 갔다(2026-10-06 실측).
# 지시문 훅(`type: agent`)은 간다. 규칙은 여기 두지 않는다 — 검사기가 정본이다.
KIRO_RECORD_CHECK_MATCHER = r"(^|/)tickets/[^/]+\.md$"
KIRO_RECORD_CHECK_PROMPT = (
    "You just saved a ticket record under tickets/. Before you end this turn, run "
    "`python3 scripts/check_ticket_record.py <ticket id>` on it (use `python` if `python3` is missing). "
    "If it reports FAIL, fix the record and run it again. "
    "If it reports PASS, or you already saw PASS for the current content, do nothing further for this notice."
)


def render_kiro_record_check_hook(manifest: dict) -> str:
    payload = {
        "version": "v1",
        "hooks": [
            {
                "name": "tiket-ticket-record-check",
                "trigger": "PostFileSave",
                "matcher": KIRO_RECORD_CHECK_MATCHER,
                "action": {"type": "agent", "prompt": KIRO_RECORD_CHECK_PROMPT},
            }
        ],
    }
    return json.dumps(payload, indent=2, ensure_ascii=False) + "\n"


def render_kiro(manifest: dict) -> str:
    servers: dict[str, dict] = {}
    for server in manifest["servers"]:
        entry: dict[str, object] = {}
        if server["transport"] == "stdio":
            entry["command"] = server["command"]
            entry["args"] = list(server["args"])
        else:
            entry["url"] = server["url"]
        entry["disabled"] = False
        entry["autoApprove"] = list(server["allowed_tools"])
        if server["blocked_tools"]:
            entry["disabledTools"] = list(server["blocked_tools"])
        servers[server["id"]] = entry
    payload = {"mcpServers": servers}
    return json.dumps(payload, indent=2, ensure_ascii=False) + "\n"


def render_claude_mcp(manifest: dict) -> str:
    servers: dict[str, dict] = {}
    for server in manifest["servers"]:
        if server["transport"] == "stdio":
            entry: dict[str, object] = {
                "type": "stdio",
                "command": server["command"],
                "args": list(server["args"]),
            }
        else:
            entry = {"type": "http", "url": server["url"]}
        servers[server["id"]] = entry
    payload = {"mcpServers": servers}
    return json.dumps(payload, indent=2, ensure_ascii=False) + "\n"


def render_claude_settings(manifest: dict) -> str:
    deny: list[str] = []
    for server in manifest["servers"]:
        for tool in server["blocked_tools"]:
            deny.append(f"mcp__{server['id']}__{tool}")
    payload = {
        "enableAllProjectMcpServers": True,
        "enabledMcpjsonServers": [server["id"] for server in manifest["servers"]],
        "permissions": {"deny": deny},
        # 세션 시작마다 공용 규칙이 갱신됐는지 알린다. 스크립트가 스로틀과
        # 실패 처리를 모두 갖고 있어서 여기서는 호출만 한다 (0016).
        "hooks": {
            "SessionStart": [
                {
                    "hooks": [
                        {
                            "type": "command",
                            "command": SESSION_HOOK_COMMAND,
                        },
                    ]
                }
            ]
        },
    }
    return json.dumps(payload, indent=2, ensure_ascii=False) + "\n"


def toml_string(value: str) -> str:
    escaped = value.replace("\\", "\\\\").replace('"', '\\"')
    return f'"{escaped}"'


def toml_array(values: list[str]) -> str:
    return "[" + ", ".join(toml_string(value) for value in values) + "]"


def render_codex(manifest: dict) -> str:
    lines = [f"# {GENERATED_NOTE}", ""]
    for server in manifest["servers"]:
        lines.append(f"[mcp_servers.{server['id']}]")
        if server["transport"] == "stdio":
            lines.append(f"command = {toml_string(server['command'])}")
            lines.append(f"args = {toml_array(list(server['args']))}")
        else:
            lines.append(f"url = {toml_string(server['url'])}")
        lines.append(f"enabled_tools = {toml_array(list(server['allowed_tools']))}")
        if server["blocked_tools"]:
            lines.append(f"disabled_tools = {toml_array(list(server['blocked_tools']))}")
        lines.append("enabled = true")
        lines.append('default_tools_approval_mode = "auto"')
        lines.append("")
    # Codex 훅. matcher 는 신규 세션과 재개를 모두 잡는다
    # (learn.chatgpt.com/docs/hooks, 2026-09-20 조회).
    lines.append("")
    lines.append("[[hooks.SessionStart]]")
    lines.append('matcher = "startup|resume"')
    lines.append("")
    lines.append("[[hooks.SessionStart.hooks]]")
    lines.append('type = "command"')
    lines.append(f"command = {toml_string(CODEX_SESSION_HOOK_COMMAND)}")
    lines.append(f"command_windows = {toml_string(SESSION_HOOK_COMMAND_WINDOWS)}")
    lines.append(f"statusMessage = {toml_string(SESSION_HOOK_LABEL)}")
    return "\n".join(lines) + "\n"


# 고객 AWS 조회 스킬은 skills/ 에 한 벌 있다 (0040). 호스트는 각자 정한 자리에서만 워크스페이스 스킬을 읽는다
# (code.claude.com/docs/en/skills, kiro.dev/docs/skills, learn.chatgpt.com/docs/build-skills,
# hermes-agent.nousresearch.com skills — 2026-10-20). Codex 와 Hermes 는 .agents/skills 를 같이 읽는다.
# symlink 는 쓰지 않는다 — Windows git 기본값(core.symlinks=false)에서 일반 파일로 풀린다.
# 사본은 SKILL.md 하나다. 스크립트는 csg-login 마커로 찾고(SKILL.md "SKILL_DIR"), 문서 링크는 원본을 가리키게 고친다.
SKILL_NAME = "aws-customer-account-ops"
SKILL_SOURCE_DIR = f"skills/{SKILL_NAME}"
SKILL_HOST_DIRS = (".claude/skills", ".kiro/skills", ".agents/skills")
SKILL_LINKED_DIRS = ("reference", "examples")


def render_skill_copy(host_dir: str) -> str:
    source = (ROOT / SKILL_SOURCE_DIR / "SKILL.md").read_text(encoding="utf-8")
    head, body = source.split("\n---\n", 1)
    up = "../" * (host_dir.count("/") + 2)
    for linked in SKILL_LINKED_DIRS:
        body = body.replace(f"]({linked}/", f"]({up}{SKILL_SOURCE_DIR}/{linked}/")
    note = f"<!-- Generated from {SKILL_SOURCE_DIR}/SKILL.md by scripts/render_agent_configs.py. Do not edit by hand. -->\n"
    return f"{head}\n---\n{note}{body}"


RENDERERS = {
    ".kiro/settings/mcp.json": render_kiro,
    ".kiro/hooks/session-start.json": render_kiro_hooks,
    ".kiro/hooks/ticket-record-check.json": render_kiro_record_check_hook,
    ".mcp.json": render_claude_mcp,
    ".claude/settings.json": render_claude_settings,
    ".codex/config.toml": render_codex,
    **{
        f"{host_dir}/{SKILL_NAME}/SKILL.md": (lambda manifest, host_dir=host_dir: render_skill_copy(host_dir))
        for host_dir in SKILL_HOST_DIRS
    },
}


def rendered_files(manifest: dict) -> dict[str, str]:
    return {relative: render(manifest) for relative, render in RENDERERS.items()}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="verify without writing")
    args = parser.parse_args()

    try:
        manifest = load_manifest()
    except (OSError, json.JSONDecodeError) as exc:
        print(f"agent config render: FAIL ({exc})", file=sys.stderr)
        return 1

    expected = rendered_files(manifest)
    if args.check:
        drifted = []
        for relative, content in expected.items():
            path = ROOT / relative
            if not path.is_file() or path.read_text(encoding="utf-8") != content:
                drifted.append(relative)
        if drifted:
            print("agent config render: FAIL (drift)", file=sys.stderr)
            for relative in drifted:
                print(f"- out of date: {relative}", file=sys.stderr)
            print(
                "- run: python3 scripts/render_agent_configs.py",
                file=sys.stderr,
            )
            return 1
        print(f"agent config render: PASS ({len(expected)} host files match the manifest)")
        return 0

    for relative, content in expected.items():
        path = ROOT / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content, encoding="utf-8")
    print(f"agent config render: wrote {len(expected)} host files")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
