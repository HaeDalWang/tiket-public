#!/usr/bin/env python3
"""평가 회차를 기계로 센다 — 카드를 골랐나(재현율)와 고른 뒤 지켰나(금지 문구)를 따로.

계획서: development/plans/2026-10-08-routing-recall.md 8절. 2026-10-08 FTR 카드 평가에서 카드는 전부 골랐는데
실패는 고른 뒤에 났다 — 재현율만 재면 100% 가 나오고 안심하게 된다.

케이스 파일 머리에 두 줄을 둔다 (없으면 그 케이스는 채점하지 않는다):
  - 기대 policy_ids: `GUIDE-HEALTH-001`, `POLICY-ESC-001`
  - 회신 금지 문구: "다른 고객사", "공지를 드리겠습니다"
금지 문구는 `## 답변 초안` 블록에서만 찾는다 — 내부 메모에 "다른 고객사를 언급하지 않는다" 고 적는 것은 괜찮다.
부정문 안에서도 걸리지 않을 만큼 구체적으로 적는다("대신 열어" 는 "대신 열어 드리는 것도 불가" 에 걸린다).
따옴표 안은 인용이라 세지 않는다 — 고객이 들은 "관리 대상이 아니다" 를 옮긴 초안이 적중으로 셌다(2026-10-23, EVAL-020).

회차는 `scripts/eval_run.py` 가 남긴 폴더(`summary.json` 의 `case`·`ref`)에서 읽고 프레임워크 버전(`ref`)별로 묶는다.
사람 채점을 대신하지 않는다 — 어느 회차를 사람이 읽을지 고르는 데 쓴다.

사용:
  python3 scripts/eval_score.py EVAL-013 EVAL-014
  python3 scripts/eval_score.py --all                  머리 두 줄이 있는 케이스 전부
  python3 scripts/eval_score.py EVAL-013 --runs-dir <폴더>
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(Path(__file__).resolve().parent))

from check_ticket_record import header_field, section_body  # noqa: E402

RUNS_DIR = Path.home() / "work/tiket-eval-runs"
CARD_ID = re.compile(r"\b(?:POLICY|GUIDE)-[A-Z0-9]+(?:-[A-Z0-9]+)*-\d{3}\b")
DRAFT_HEADING = "## 답변 초안"
REF_LENGTH = 7
MAX_QUOTE = 80  # 이보다 긴 따옴표 구간은 짝이 어긋난 것으로 본다 — 뒤의 단정까지 인용으로 삼키지 않게
QUOTED = re.compile(rf'"[^"]{{1,{MAX_QUOTE}}}"|“[^“”]{{1,{MAX_QUOTE}}}”')


def parse_case(text: str) -> tuple[list[str], list[str]]:
    """(기대 카드, 금지 문구). 머리 줄이 없으면 빈 목록."""
    expected = re.search(r"^- 기대 policy_ids:\s*(.+)$", text, re.MULTILINE)
    forbidden = re.search(r"^- 회신 금지 문구:\s*(.+)$", text, re.MULTILINE)
    return (
        CARD_ID.findall(expected.group(1)) if expected else [],
        re.findall(r'"([^"]+)"', forbidden.group(1)) if forbidden else [],
    )


def score_record(text: str, expected: list[str], forbidden: list[str]) -> dict:
    loaded = CARD_ID.findall(header_field(text, "policy_ids") or "")
    draft = section_body(text, DRAFT_HEADING)
    sent = re.sub(r"<!--.*?-->", "", draft, flags=re.DOTALL) if draft else ""  # 주석은 내부 메모다
    flat = QUOTED.sub(" ", re.sub(r"\s+", " ", sent))  # 초안은 줄을 접는다 — 문구가 줄을 넘어도 잡는다. 인용은 뺀다
    return {
        "found": [card for card in expected if card in loaded],
        "missed": [card for card in expected if card not in loaded],
        "extra": [card for card in loaded if card not in expected],
        "forbidden": [phrase for phrase in forbidden if flat and re.sub(r"\s+", " ", phrase) in flat],
        "has_draft": draft is not None,
    }


def _runs(runs_dir: Path, case: str) -> list[tuple[Path, dict]]:
    found = []
    for summary in sorted(list(runs_dir.glob("*/summary.json")) + list(runs_dir.glob("*/*/summary.json"))):
        try:
            data = json.loads(summary.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            continue
        if data.get("case") == case:
            found.append((summary.parent, data))
    return found


def collect(runs_dir: Path, case: str, expected: list[str], forbidden: list[str]) -> dict[str, dict]:
    """ref(앞 7자) → 회차 수·재현·금지 적중·과다 로드."""
    groups: dict[str, dict] = {}
    for folder, data in _runs(runs_dir, case):
        ref = str(data.get("ref") or "?")[:REF_LENGTH]
        group = groups.setdefault(ref, {"runs": 0, "no_record": 0, "found": 0, "expected": 0, "forbidden_runs": 0,
                                         "phrases": {}, "extra": {}, "folders": []})
        group["runs"] += 1
        group["expected"] += len(expected)
        group["folders"].append(folder.name)
        records = sorted(p for p in (folder / "tickets").glob("*.md") if p.name != "README.md")
        if not records:
            group["no_record"] += 1
            continue
        score = score_record(records[0].read_text(encoding="utf-8", errors="ignore"), expected, forbidden)
        group["found"] += len(score["found"])
        if score["forbidden"]:
            group["forbidden_runs"] += 1
        for phrase in score["forbidden"]:
            group["phrases"][phrase] = group["phrases"].get(phrase, 0) + 1
        for card in score["extra"]:
            group["extra"][card] = group["extra"].get(card, 0) + 1
    return groups


def render(case: str, expected: list[str], forbidden: list[str], groups: dict[str, dict]) -> str:
    lines = [f"{case}  기대 {', '.join(expected) or '-'}  ·  금지 {len(forbidden)}개"]
    if not groups:
        lines.append("  회차 없음")
    for ref, g in groups.items():
        recall = f"{g['found']}/{g['expected']}" if g["expected"] else "-"
        phrases = ", ".join(f'"{p}" {n}' for p, n in g["phrases"].items())
        extra = ", ".join(f"{c} {n}" for c, n in sorted(g["extra"].items(), key=lambda kv: -kv[1]))
        lines.append(f"  {ref}  {g['runs']}회  재현 {recall}  금지 적중 {g['forbidden_runs']}회" + (f" ({phrases})" if phrases else "")
                     + (f"  기록 없음 {g['no_record']}회" if g["no_record"] else ""))
        if extra:
            lines.append(f"           기대 밖 카드: {extra}")
    return "\n".join(lines)


def main() -> int:
    parser = argparse.ArgumentParser(description="평가 회차를 기계로 센다 — 재현율과 금지 문구.")
    parser.add_argument("cases", nargs="*", help="EVAL-013 처럼")
    parser.add_argument("--all", action="store_true", help="머리 두 줄이 있는 케이스 전부")
    parser.add_argument("--runs-dir", type=Path, default=RUNS_DIR)
    args = parser.parse_args()
    files = sorted((ROOT / "evals/cases").glob("EVAL-*.md"))
    if not args.all:
        files = [f for f in files if f.name.split("-", 2)[0] + "-" + f.name.split("-", 2)[1] in args.cases]
    if not files:
        print("채점할 케이스가 없다 — 번호를 주거나 --all", file=sys.stderr)
        return 2
    shown = 0
    for path in files:
        case = "-".join(path.name.split("-", 2)[:2])
        expected, forbidden = parse_case(path.read_text(encoding="utf-8"))
        if not expected and not forbidden:
            if not args.all:
                print(f"{case}  머리에 `기대 policy_ids`·`회신 금지 문구` 가 없다 — 채점하지 않는다")
            continue
        print(render(case, expected, forbidden, collect(args.runs_dir, case, expected, forbidden)))
        shown += 1
    return 0 if shown else 2


if __name__ == "__main__":
    sys.exit(main())
