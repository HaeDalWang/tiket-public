#!/usr/bin/env python3
"""개발 지도 — 흐름 · 릴리스 · 백로그 · 계획을 한 화면에. 유지보수자용.

**상태는 git 태그가 정한다.** `development/flow.md` 에는 단계와 그 근거 파일만 적는다.
단계가 어느 릴리스에 처음 다 들어갔는지는 볼 때마다 태그를 뒤져 계산한다. 그래서
지도와 릴리스는 어긋날 수 없다. 지도 파일은 커밋하지 않는다 (gitignore).

    python3 scripts/dev_map.py            development/map.html 을 만들고 연다
    python3 scripts/dev_map.py --print    글로만 요약한다 (파일 없음)
    python3 scripts/dev_map.py --no-open  만들기만 한다
"""

from __future__ import annotations

import argparse
import html
import re
import subprocess
import sys
import webbrowser
from datetime import datetime
from pathlib import Path
from typing import NamedTuple

sys.path.insert(0, str(Path(__file__).resolve().parent))

from release_tags import version  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
DEV = ROOT / "development"
OUTPUT = DEV / "map.html"
# 다른 저장소 — tiket 태그와 따로 배포되므로 태그로 계산하지 않는다.
EXTERNAL = ("collector:", "site:")
BACKLOG_SECTIONS = ("관찰 중", "다음", "대기")
LABELS = {
    "released": "✅ {tag}",
    "main": "🔜 main — 아직 릴리스 전",
    "working": "✏️ 커밋 전",
    "planned": "⬜ 계획",
    "external": "↗ 다른 저장소 (따로 배포)",
}


class Stage(NamedTuple):
    name: str
    does: str
    evidence: list[str]
    note: str


class Flow(NamedTuple):
    name: str
    stages: list[Stage]


class Status(NamedTuple):
    kind: str
    tag: str | None

    def label(self) -> str:
        return LABELS[self.kind].format(tag=self.tag)


def table_rows(lines: list[str]) -> list[list[str]]:
    """표의 본문 행. 머리행과 구분행은 뺀다."""
    rows = [[cell.strip() for cell in line.strip().strip("|").split("|")] for line in lines if line.startswith("|")]
    return [row for row in rows[2:]]


def sections(text: str) -> list[tuple[str, list[str]]]:
    found: list[tuple[str, list[str]]] = []
    for line in text.splitlines():
        if line.startswith("## "):
            found.append((line[3:].strip(), []))
        elif found:
            found[-1][1].append(line)
    return found


def parse_flow(text: str) -> list[Flow]:
    flows = []
    for name, lines in sections(text):
        stages = [
            Stage(row[0], row[1], re.findall(r"`([^`]+)`", row[2]), row[3] if len(row) > 3 else "")
            for row in table_rows(lines) if len(row) >= 3
        ]
        if stages:
            flows.append(Flow(name, stages))
    return flows


class Repo:
    def __init__(self, root: Path) -> None:
        self.root = root

    def git(self, *args: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(["git", "-c", "core.quotePath=false", *args], cwd=self.root,
                              capture_output=True, text=True, encoding="utf-8", errors="replace")

    def read(self, ref: str | None, path: str) -> str | None:
        if ref is None:
            file = self.root / path
            return file.read_text(encoding="utf-8", errors="replace") if file.is_file() else None
        result = self.git("cat-file", "-p", f"{ref}:{path}")
        return result.stdout if result.returncode == 0 else None

    def has(self, ref: str | None, item: str) -> bool:
        """`path` 또는 `path#문자열`. ref 가 None 이면 디스크(커밋 전 포함)."""
        path, _, marker = item.partition("#")
        content = self.read(ref, path)
        return content is not None and marker in content

    def tags(self) -> list[tuple[str, str]]:
        raw = self.git("for-each-ref", "refs/tags", "--format=%(refname:short)\t%(creatordate:short)").stdout
        pairs = [line.split("\t") for line in raw.splitlines() if "\t" in line]
        return sorted(((tag, day) for tag, day in pairs if version(tag)), key=lambda pair: version(pair[0]))

    def unreleased(self) -> list[str]:
        tags = self.tags()
        span = f"{tags[-1][0]}..HEAD" if tags else "HEAD"
        return self.git("log", "--no-merges", "--format=%s", span).stdout.splitlines()


def stage_status(repo: Repo, evidence: list[str], tags: list[str] | None = None) -> Status:
    local = [item for item in evidence if not item.startswith(EXTERNAL)]
    if not evidence:
        return Status("planned", None)
    if not local:
        return Status("external", None)
    tags = [tag for tag, _ in repo.tags()] if tags is None else tags
    contains = [all(repo.has(tag, item) for item in local) for tag in tags]
    if contains and contains[-1]:
        start = len(contains) - 1
        while start > 0 and contains[start - 1]:
            start -= 1
        return Status("released", tags[start])
    if all(repo.has("HEAD", item) for item in local):
        return Status("main", None)
    if all(repo.has(None, item) for item in local):
        return Status("working", None)
    return Status("planned", None)


def parse_backlog(text: str) -> dict[str, list[str]]:
    backlog: dict[str, list[str]] = {}
    for heading, lines in sections(text):
        key = next((name for name in BACKLOG_SECTIONS if heading.startswith(name)), None)
        if key is None:
            continue
        bullets = [match.group(1).rstrip(". ") for line in lines if (match := re.match(r"- \*\*(.+?)\*\*", line))]
        backlog[key] = bullets + [row[0] for row in table_rows(lines)]
    return backlog


def read_plans(folder: Path) -> list[tuple[str, str]]:
    plans = []
    for path in sorted(folder.glob("*.md")):
        text = path.read_text(encoding="utf-8")
        title = next((line[2:].strip() for line in text.splitlines() if line.startswith("# ")), path.stem)
        states = [line for line in text.splitlines() if "**상태" in line]
        state = re.sub(r"[*>`\-]+", "", states[-1]).strip() if states else "상태 줄 없음"
        plans.append((f"{path.stem[:10]} · {title}", state))
    return plans


CSS = """
:root{--bg:#f7f7f5;--card:#fff;--ink:#1d1d1b;--mute:#6b6b66;--line:#dcdcd6;
--released:#e3f1e3;--main:#fff1d6;--working:#fde4e4;--planned:#ececec;--external:#e4ecf7}
@media (prefers-color-scheme:dark){:root:not([data-theme="light"]){--bg:#171716;--card:#222220;--ink:#ecece8;
--mute:#a3a39c;--line:#3a3a36;--released:#1f3a22;--main:#43381c;--working:#46242a;--planned:#2c2c2a;--external:#1f2d42}}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--ink);
font:15px/1.5 -apple-system,"Apple SD Gothic Neo","Malgun Gothic",sans-serif}
main{max-width:1100px;margin:0 auto;padding:24px 16px 64px}h1{font-size:22px;margin:0 0 4px}
h2{font-size:17px;margin:32px 0 12px}.mute{color:var(--mute);font-size:13px}
.flow{background:var(--card);border:1px solid var(--line);border-radius:10px;padding:14px;margin-bottom:12px}
.flow h3{margin:0 0 10px;font-size:15px}.stages{display:flex;flex-wrap:wrap;gap:8px;align-items:stretch}
.stage{flex:1 1 150px;max-width:220px;border-radius:8px;padding:8px 10px;border:1px solid var(--line)}
.stage b{display:block}.stage .st{font-size:12px;font-weight:600;margin-top:4px}
.stage small{display:block;color:var(--mute);font-size:12px}.arrow{align-self:center;color:var(--mute)}
.released{background:var(--released)}.main{background:var(--main)}.working{background:var(--working)}
.planned{background:var(--planned)}.external{background:var(--external)}
.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(260px,1fr));gap:12px}
.box{background:var(--card);border:1px solid var(--line);border-radius:10px;padding:12px 14px}
.box h3{margin:0 0 6px;font-size:14px}ul{margin:0;padding-left:18px}li{margin:3px 0}
.legend{display:flex;flex-wrap:wrap;gap:6px;margin-top:8px}.legend span{font-size:12px;padding:2px 8px;border-radius:6px}
"""


def render_html(flows: list[Flow], statuses: dict[tuple[str, str], Status], *, releases: list[tuple[str, str]],
                unreleased: list[str], backlog: dict[str, list[str]], plans: list[tuple[str, str]]) -> str:
    e = html.escape
    base = releases[-1][0] if releases else "릴리스 없음"
    parts = [f"<!doctype html><html lang='ko'><head><meta charset='utf-8'>"
             f"<meta name='viewport' content='width=device-width,initial-scale=1'><title>개발 지도</title>"
             f"<style>{CSS}</style></head><body><main>",
             f"<h1>개발 지도</h1><div class='mute'>기준 릴리스 <b>{e(base)}</b> · main 에 릴리스 안 된 커밋 "
             f"{len(unreleased)}개 · {datetime.now():%Y-%m-%d %H:%M} 에 git 에서 계산</div>",
             "<div class='legend'>" + "".join(
                 f"<span class='{kind}'>{e(label.format(tag='vX.Y.Z'))}</span>" for kind, label in LABELS.items())
             + "</div><h2>흐름</h2>"]
    for flow in flows:
        cells = []
        for stage in flow.stages:
            status = statuses.get((flow.name, stage.name), Status("planned", None))
            note = f"<small>{e(stage.note)}</small>" if stage.note else ""
            cells.append(f"<div class='stage {status.kind}'><b>{e(stage.name)}</b><small>{e(stage.does)}</small>"
                         f"<div class='st'>{e(status.label())}</div>{note}</div>")
        parts.append(f"<section class='flow'><h3>{e(flow.name)}</h3><div class='stages'>"
                     + "<span class='arrow'>→</span>".join(cells) + "</div></section>")
    parts.append("<h2>릴리스</h2><div class='grid'><div class='box'><h3>태그</h3><ul>"
                 + "".join(f"<li><b>{e(tag)}</b> <span class='mute'>{e(day)}</span></li>" for tag, day in reversed(releases))
                 + "</ul></div><div class='box'><h3>main 에만 있음 (다음 릴리스에 들어감)</h3><ul>"
                 + ("".join(f"<li>{e(subject)}</li>" for subject in unreleased) or "<li class='mute'>없음</li>")
                 + "</ul></div></div><h2>백로그</h2><div class='grid'>")
    for key in BACKLOG_SECTIONS:
        items = backlog.get(key, [])
        parts.append(f"<div class='box'><h3>{e(key)} ({len(items)})</h3><ul>"
                     + ("".join(f"<li>{e(item)}</li>" for item in items) or "<li class='mute'>없음</li>") + "</ul></div>")
    parts.append("</div><h2>계획</h2><div class='grid'>"
                 + "".join(f"<div class='box'><h3>{e(title)}</h3><div class='mute'>{e(state)}</div></div>"
                           for title, state in plans)
                 + "</div><p class='mute'>원본: development/flow.md · backlog.md · plans/ · git 태그</p></main></body></html>")
    return "".join(parts)


def collect(root: Path = ROOT) -> dict:
    repo = Repo(root)
    dev = root / "development"
    flows = parse_flow((dev / "flow.md").read_text(encoding="utf-8"))
    releases = repo.tags()
    tags = [tag for tag, _ in releases]
    statuses = {(flow.name, stage.name): stage_status(repo, stage.evidence, tags) for flow in flows for stage in flow.stages}
    return {
        "flows": flows, "statuses": statuses, "releases": releases, "unreleased": repo.unreleased(),
        "backlog": parse_backlog((dev / "backlog.md").read_text(encoding="utf-8")),
        "plans": read_plans(dev / "plans"),
    }


def summary(data: dict) -> str:
    lines = [f"기준 릴리스 {data['releases'][-1][0] if data['releases'] else '없음'} · "
             f"main 에만 {len(data['unreleased'])}개"]
    for flow in data["flows"]:
        lines.append(f"\n[{flow.name}]")
        lines += [f"  {data['statuses'][(flow.name, stage.name)].label():<28} {stage.name}" for stage in flow.stages]
    lines.append("\n[백로그] " + " · ".join(f"{key} {len(data['backlog'].get(key, []))}" for key in BACKLOG_SECTIONS))
    return "\n".join(lines)


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--print", action="store_true", help="글로만 요약한다")
    parser.add_argument("--no-open", action="store_true", help="브라우저를 열지 않는다")
    args = parser.parse_args(argv)
    data = collect()
    if args.print:
        print(summary(data))
        return 0
    OUTPUT.write_text(render_html(data["flows"], data["statuses"], releases=data["releases"],
                                  unreleased=data["unreleased"], backlog=data["backlog"], plans=data["plans"]),
                      encoding="utf-8")
    print(f"{OUTPUT.relative_to(ROOT)} 를 만들었다.")
    if not args.no_open:
        webbrowser.open(OUTPUT.as_uri())
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
