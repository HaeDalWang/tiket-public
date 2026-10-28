#!/usr/bin/env python3
"""평가 케이스를 Kiro CLI 로 사람 없이 돌린다 — 유지보수자용.

    python3 scripts/eval_run.py EVAL-002              한 번
    python3 scripts/eval_run.py EVAL-001 EVAL-002 --runs 3
    python3 scripts/eval_run.py EVAL-002 --ref v0.1.15   그 버전으로

손으로 돌리면 이전 대화·이전 기록·답안지·옆에 있던 고객 파일이 답을 도와준다 (2026-10-02 에 셋 다 일어났다).
그래서 회차마다 깨끗한 사본을 만든다:

  - 사본은 `git archive <ref>` 다 — 커밋된 프레임워크만 있다. `tickets/`·`.private/` 같은 로컬 자료가 없다.
  - `evals/`(답안지)와 `development/`(평가 결과와 결정 기록)를 사본에서 지운다.
  - 사본 경로에 "eval" 이 들어가지 않는다 — 폴더 이름으로 평가인 줄 알게 하지 않는다.

**안전은 Kiro 의 권한 규칙이 지킨다.** `--trust-all-tools` 를 쓰지 않는다. 사본 폴더 전용 규칙을
`~/.kiro/workspace-roots/<해시>/permissions.yaml` 에 넣고 끝나면 지운다. 허용하는 것은 프레임워크 스크립트 셋,
사본 안에서만 도는 읽기 명령(`cat`·`ls`·`grep` …), `tickets/` 쓰기, 문서 조회(저장소가 정한 MCP 서버 둘과 웹)뿐이다.
그 밖의 셸 명령과 MCP 서버는 `deny` 로 못 박는다 — 내 PC 의 전역 규칙이 무엇을 허용하든 진다.
그래서 `aws`·스킬 스크립트·`python3 -c` 로 고객 계정에 닿을 길이 없다 (실측은 scripts/test_eval_run.py 머리말).
거절된 호출은 summary.json 에 남는다 — 거절이 많으면 그 회차는 평소와 다르게 돈 것이다.

사용 지표는 보내지 않는다(`TIKET_TELEMETRY=off`). 결과는 저장소 밖 `~/work/tiket-eval-runs/` 에 둔다 —
저장소 안에 두면 다음 회차가 읽는다. 채점은 하지 않는다. 기록 형태 검사(`check_ticket_record.py`)까지만 돌린다.

걸러내지 못하는 것: 내 PC 의 Kiro 글로벌 스티어링(`~/.kiro/steering/`)은 그대로 들어간다. 무엇이 들어갔는지는
summary.json 의 `context_files` 에 남는다. `fetch-ticket.sh` 는 허용되어 있어 합성 번호로 Zendesk 를 한 번 조회한다.
"""

from __future__ import annotations

import argparse
import datetime
import json
import os
import re
import shutil
import subprocess
import sys
import uuid
from pathlib import Path
from typing import Callable, NamedTuple

sys.path.insert(0, str(Path(__file__).resolve().parent))
import kiro_permissions  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
PROMPT_HEADING = "## 프롬프트"
CHANGES_HEADING = "## 사본 바꾸기"
CHANGE_SEPARATOR = "====="
REMOVED_FROM_SANDBOX = ("evals", "development")
TIMEOUT_SECONDS = 1200
# kiro-cli 2.27.1 은 사람 없이 돌 때 내장 에이전트를 못 찾고 종료 4 로 끝난다(`agent "kiro_default" not found`).
# 파일로 정의한 에이전트를 이름으로 주면 돈다. 지시문·도구 제한은 넣지 않는다 — 스티어링·스킬·`AGENTS.md` 는
# 사용자 에이전트도 물려받고(kiro.dev/docs/custom-agents/configuration-reference), 도구와 저장소 MCP 는 따로 켜야 한다.
# 무엇을 실제로 부를 수 있는지는 여전히 아래 권한 규칙이 정한다.
AGENT_NAME = "workspace"
AGENT_CONFIG = {"name": AGENT_NAME, "description": "Workspace agent", "tools": ["*"], "includeMcpJson": True}

# 허용 목록. Kiro 는 거절을 "사용자가 거절했다" 로 읽고 멈추므로, 평소 쓰는 읽기 명령은 열어 둔다.
_SCRIPTS = ("bash scripts/fetch-ticket.sh*",) + tuple(
    f"{python} scripts/{name}.py*" for name in ("check_ticket_record", "local_capabilities") for python in ("python3", "python"))
# 맨 `cat` 은 넣지 않는다 — 입력 리다이렉트는 규칙에 안 보여서 `cat</etc/hosts` 가 맨 `cat` 으로 통과한다.
_PIPE_ONLY = ("head", "tail", "wc", "sort", "uniq")
_READS = tuple(f"{command} *" for command in ("cat", "head", "tail", "grep", "rg", "ls", "wc", "sort", "uniq", "jq", "find", "echo")
               ) + _PIPE_ONLY + ("ls", "pwd", "date", "date *", "whoami",
                                  "git status*", "git log*", "git diff*", "git rev-parse*", "git branch*")
# 사본 밖으로 못 나가게 — 절대 경로·홈·상위 폴더·변수·명령 치환이 보이면 거절.
# ponytail: glob 으로 "경로가 사본 안인가" 를 정확히 가릴 수는 없고, `head -5 < 밖` 같은 입력 리다이렉트는 아예 안 보인다.
# 그런 호출이 돌면 summary.json 의 `escaped` 에 남는다. 근본 해법은 OS 샌드박스다.
_OUTSIDE = ("* /*", "* ~*", "*..*", "*$*", "*`*", "*=/*", "*=~*", '*"/*', "*'/*", '*"~*', "*'~*",
            "find * -delete*", "find * -exec*", "find * -ok*", "sort -o*", "sort * -o*")
_MCP = ("aws-docs/*", "exa/*")  # 저장소가 정한 문서·검색 서버. 실행 도구는 .kiro/settings/mcp.json 이 꺼 둔다

# 허용만으로는 부족하다. 내 PC 의 전역 규칙이나 전역 MCP 서버가 더 넓게 허용하고 있으면 그대로 통과한다
# (실제로 `python3 *` 가 그랬다). deny 는 어느 범위의 allow 보다 세므로, 허용 목록 밖을 deny 로 못 박는다.
SANDBOX_RULES: tuple[dict, ...] = (
    {"capability": "shell", "match": _SCRIPTS},
    {"capability": "shell", "match": _READS, "exclude": _OUTSIDE},
    {"capability": "fs_read", "match": ("./**",)},
    {"capability": "fs_write", "match": ("tickets/**",)},
    {"capability": "mcp", "match": _MCP},
    {"capability": "web_fetch", "match": ("*",)},
    {"capability": "web_search", "match": ("*",)},
    {"capability": "shell", "effect": "deny", "match": ("*",), "exclude": _SCRIPTS + _READS},
    {"capability": "shell", "effect": "deny", "match": _OUTSIDE},
    {"capability": "mcp", "effect": "deny", "match": ("*",), "exclude": _MCP},
)

Runner = Callable[[list[str], Path, dict, int], tuple[int, str, str]]


class Paths(NamedTuple):
    root: Path
    home: Path
    runs: Path
    sandboxes: Path


def default_paths() -> Paths:
    home = Path.home()
    return Paths(root=ROOT, home=home, runs=home / "work/tiket-eval-runs", sandboxes=home / ".cache/tiket-runs")


def prompt_of(case_text: str) -> str:
    """`## 프롬프트` 아래 첫 코드 블록. 케이스 파일의 다른 블록은 프롬프트가 아니다."""
    _, found, after = case_text.partition(PROMPT_HEADING)
    section = after.split("\n## ", 1)[0]
    parts = section.split("```")
    if not found or len(parts) < 3:
        raise ValueError(f"`{PROMPT_HEADING}` 아래에 코드 블록이 없다")
    return parts[1].split("\n", 1)[1].rstrip("\n") if "\n" in parts[1] else parts[1]


def apply_sandbox_changes(case_text: str, sandbox: Path) -> list[str]:
    """`## 사본 바꾸기` 의 ```` ```replace <경로> ```` 블록을 사본에 적용한다. 바꾼 상대경로를 돌려준다.

    블록 본문은 한 줄짜리 `=====` 로 앞(옛 글)·뒤(새 글)를 나눈다. 옛 글이 그 파일에 정확히 한 번 나오지 않거나
    경로가 사본 밖이면 ValueError — 프레임워크 문서가 바뀌어 조용히 안 바뀐 채 Kiro 가 도는 일을 막는다.
    """
    _, found, after = case_text.partition("\n" + CHANGES_HEADING)
    section = after.split("\n## ", 1)[0] if found else ""
    changed: dict[str, None] = {}
    for info, body in re.findall(r"^```([^\n]*)\n(.*?)\n```$", section, re.MULTILINE | re.DOTALL):
        if not info.startswith("replace "):
            continue
        relative = info[len("replace "):].strip()
        lines = body.split("\n")
        cuts = [index for index, line in enumerate(lines) if line == CHANGE_SEPARATOR]
        if len(cuts) != 1:
            raise ValueError(f"`replace {relative}` 블록에는 `{CHANGE_SEPARATOR}` 한 줄이 정확히 하나 있어야 한다")
        old, new = "\n".join(lines[:cuts[0]]), "\n".join(lines[cuts[0] + 1:])
        target = (sandbox / relative).resolve()
        if Path(relative).is_absolute() or not target.is_relative_to(sandbox.resolve()):
            raise ValueError(f"사본 밖 경로는 바꾸지 않는다: {relative}")
        if not target.is_file():
            raise ValueError(f"사본에 없는 파일이다: {relative}")
        text = target.read_text(encoding="utf-8")
        if not old or text.count(old) != 1:
            raise ValueError(f"{relative}: 옛 글이 정확히 한 번 나와야 한다 (지금 {text.count(old) if old else 0}번) — 문서가 바뀌었나")
        target.write_text(text.replace(old, new), encoding="utf-8")
        changed[relative] = None
    return list(changed)


def case_path(case: str, root: Path) -> Path:
    found = sorted((root / "evals/cases").glob(f"{case}-*.md"))
    if len(found) != 1:
        raise ValueError(f"케이스를 하나로 못 골랐다: {case} → {[path.name for path in found]}")
    return found[0]


def commit_of(root: Path, ref: str) -> str:
    return subprocess.run(["git", "rev-parse", "--verify", f"{ref}^{{commit}}"], cwd=root, check=True,
                          capture_output=True, text=True).stdout.strip()


def build_sandbox(root: Path, ref: str, dest: Path) -> Path:
    dest.mkdir(parents=True)
    archive = dest.parent / "archive.tar"
    subprocess.run(["git", "archive", "--format=tar", "-o", str(archive), ref], cwd=root, check=True, capture_output=True)
    subprocess.run(["tar", "-xf", str(archive), "-C", str(dest)], check=True, capture_output=True)
    archive.unlink()
    for name in REMOVED_FROM_SANDBOX:
        shutil.rmtree(dest / name, ignore_errors=True)
    (dest / "tickets").mkdir(exist_ok=True)
    agents = dest / ".kiro/agents"
    agents.mkdir(parents=True, exist_ok=True)
    (agents / f"{AGENT_NAME}.json").write_text(json.dumps(AGENT_CONFIG, indent=2) + "\n", encoding="utf-8")
    return dest


def permissions_text() -> str:
    """tiket 표식 줄은 뺀다. 표식이 있으면 사본 안에서 돈 `local_capabilities.py` 가 이 파일을 평소 규칙으로 다시 쓴다."""
    block = kiro_permissions.render_block(SANDBOX_RULES).splitlines(keepends=True)
    markers = (kiro_permissions.BEGIN, kiro_permissions.END)
    return "rules:\n" + "".join(line for line in block if line.rstrip("\n") not in markers)


def install_permissions(sandbox: Path, home: Path) -> Path:
    """사본 전용 권한 폴더. 이미 있으면 남의 것이므로 건드리지 않는다."""
    folder = kiro_permissions.workspace_dir(sandbox.resolve(), home)
    if folder is None:
        raise RuntimeError("이 PC 에서 Kiro 의 워크스페이스 권한 폴더를 찾지 못했다 — 권한 규칙 없이 돌리지 않는다")
    folder.mkdir(parents=True)
    (folder / "permissions.yaml").write_text(permissions_text(), encoding="utf-8")
    return folder


def kiro_command(prompt: str) -> list[str]:
    return ["kiro-cli", "chat", "--no-interactive", "--trust-tools=", "--agent", AGENT_NAME, "--output-format", "stream-json", prompt]


def run_env(base: dict, scratch: Path) -> dict:
    return {**base, "TIKET_TELEMETRY": "off", "TIKET_USAGE_STAMP": str(scratch / "usage-stamp")}


def run_kiro(argv: list[str], cwd: Path, env: dict, timeout: int) -> tuple[int, str, str]:
    done = subprocess.run(argv, cwd=cwd, env=env, stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=timeout)
    return done.returncode, done.stdout, done.stderr


def summarize_transcript(transcript: str) -> dict:
    calls: dict[str, dict] = {}
    statuses: dict[str, str] = {}
    context: set[str] = set()
    summary = {"engine": None, "stop_reason": None, "final_text": ""}
    for line in transcript.splitlines():
        try:
            event = json.loads(line)
        except ValueError:
            continue
        if not isinstance(event, dict):
            continue
        data = event.get("data") or {}
        if event.get("type") == "runStarted":
            summary["engine"] = data.get("engine")
        elif event.get("type") == "runFinished":
            summary["stop_reason"] = data.get("stopReason")
            summary["final_text"] = data.get("finalText") or ""
        update = data.get("update") or {}
        kind = update.get("sessionUpdate")
        if kind == "tool_call":
            raw = update.get("rawInput") or {}
            calls[update.get("toolCallId")] = {
                "kind": update.get("kind"), "target": raw.get("command") or raw.get("path") or update.get("title") or ""}
        elif kind == "tool_call_update" and update.get("status") in ("completed", "failed"):
            statuses[update.get("toolCallId")] = update["status"]
        elif kind == "session_info_update":
            items = (((update.get("_meta") or {}).get("kiro") or {}).get("breakdown") or {}).get("contextFiles") or {}
            context.update(item["name"] for item in items.get("items") or [] if item.get("name"))
    failed = [calls.get(call, {"kind": None, "target": ""}) for call, status in statuses.items() if status == "failed"]
    done = [calls.get(call, {"kind": None, "target": ""}) for call, status in statuses.items() if status == "completed"]
    # 규칙이 못 보는 입력 리다이렉트로 돈 셸 명령 — 사본 밖을 읽었을 수 있다. 사람이 본다.
    escaped = [call["target"] for call in done if call["kind"] == "execute" and "<" in call["target"]]
    return {**summary, "tools": {"completed": len(done), "failed": failed}, "escaped": escaped,
            "context_files": sorted(context)}


def check_records(sandbox: Path) -> list[dict]:
    records = []
    for path in sorted((sandbox / "tickets").glob("*.md")):
        done = subprocess.run([sys.executable, "scripts/check_ticket_record.py", path.stem], cwd=sandbox,
                              capture_output=True, text=True, check=False)
        records.append({"file": path.name, "check": (done.stdout or done.stderr).strip()})
    return records


def next_number(case: str, paths: Paths, today: str) -> int:
    number = 1
    while (paths.runs / f"{today}-{case}-kiro-{number}").exists():
        number += 1
    return number


def run_once(case: str, number: int, ref: str, paths: Paths, runner: Runner = run_kiro,
             timeout: int = TIMEOUT_SECONDS, today: str | None = None, agent: str = "kiro-cli") -> dict:
    today = today or datetime.date.today().isoformat()
    case_text = case_path(case, paths.root).read_text(encoding="utf-8")
    prompt = prompt_of(case_text)
    commit = commit_of(paths.root, ref)
    run_dir = paths.runs / f"{today}-{case}-kiro-{number}"
    run_dir.mkdir(parents=True)  # 이미 있으면 멈춘다 — 앞 회차를 덮어쓰지 않는다
    scratch = paths.sandboxes / uuid.uuid4().hex[:12]
    permissions = None
    try:
        sandbox = build_sandbox(paths.root, commit, scratch / "tiket")
        try:
            changes = apply_sandbox_changes(case_text, sandbox)
        except ValueError:
            run_dir.rmdir()  # Kiro 를 돌리지 않았으니 빈 회차 폴더를 남기지 않는다
            raise
        permissions = install_permissions(sandbox, paths.home)
        started = datetime.datetime.now()
        try:
            code, transcript, stderr = runner(kiro_command(prompt), sandbox, run_env(dict(os.environ), scratch), timeout)
        except subprocess.TimeoutExpired as expired:
            code, transcript, stderr = "timeout", _text(expired.output), _text(expired.stderr)
        seconds = round((datetime.datetime.now() - started).total_seconds())
        (run_dir / "prompt.txt").write_text(prompt + "\n", encoding="utf-8")
        (run_dir / "transcript.jsonl").write_text(transcript, encoding="utf-8")
        (run_dir / "stderr.txt").write_text(stderr, encoding="utf-8")
        records = check_records(sandbox)
        shutil.copytree(sandbox / "tickets", run_dir / "tickets")
        summary = {"case": case, "run": number, "date": today, "agent": agent, "ref": commit, "exit": code,
                   "seconds": seconds, "sandbox_changes": changes, "records": records, **summarize_transcript(transcript)}
        (run_dir / "summary.json").write_text(json.dumps(summary, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        return summary
    finally:
        if permissions is not None:
            shutil.rmtree(permissions, ignore_errors=True)
        shutil.rmtree(scratch, ignore_errors=True)


def _text(value: object) -> str:
    return value.decode("utf-8", "replace") if isinstance(value, bytes) else (value or "")


def agent_version() -> str:
    done = subprocess.run(["kiro-cli", "--version"], capture_output=True, text=True, check=False)
    return done.stdout.strip() or "kiro-cli"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("cases", nargs="+", help="EVAL-001 처럼 케이스 번호")
    parser.add_argument("--runs", type=int, default=1, help="케이스마다 몇 번 (기본 1)")
    parser.add_argument("--ref", default="HEAD", help="어느 커밋의 프레임워크로 돌리나 (기본 HEAD — 커밋 안 한 수정은 안 들어간다)")
    parser.add_argument("--timeout", type=int, default=TIMEOUT_SECONDS, help="한 회차 제한 시간(초)")
    args = parser.parse_args()
    if shutil.which("kiro-cli") is None:
        print("kiro-cli 가 없다", file=sys.stderr)
        return 1
    paths, today, agent = default_paths(), datetime.date.today().isoformat(), agent_version()
    for case in args.cases:
        for _ in range(args.runs):
            number = next_number(case, paths, today)
            print(f"{case} {number}회차 — 돌리는 중 …", flush=True)
            summary = run_once(case, number, args.ref, paths, timeout=args.timeout, today=today, agent=agent)
            checks = ", ".join(f"{record['file']}: {record['check'].splitlines()[0] if record['check'] else '출력 없음'}"
                               for record in summary["records"]) or "기록 없음"
            print(f"  종료 {summary['exit']} · {summary['seconds']}초 · {summary['stop_reason']} · "
                  f"거절·실패한 호출 {len(summary['tools']['failed'])}건 · {checks}")
            if summary["escaped"]:
                print(f"  ⚠ 입력 리다이렉트로 돈 명령 {len(summary['escaped'])}건 — 사본 밖을 읽었는지 summary.json 의 escaped 를 본다")
            print(f"  {paths.runs / f'{today}-{case}-kiro-{number}'}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
