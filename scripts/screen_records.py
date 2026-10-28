#!/usr/bin/env python3
"""조사+답변 기록을 품질 문항으로 스크리닝한다.

`check_ticket_record.py` 는 **형태**를 본다 — 칸이 채워졌는지. 품질은 사람이 봐야 했고,
그래서 2026-09-18 기준선에서 만점 통과한 회차(`900101`)에 실제 결함이 들어 있었다.
가설이 기록에서는 `[추측]` 인데 고객 초안에서 단정으로 올라간 건이다.

이 스크립트는 그 판독을 **좁히는** 일만 한다. 15건을 4건으로 줄여 사람이 읽게 한다.

**플래그는 판정이 아니다.** "읽어봐야 한다"이지 "위반이다"가 아니다. 고객 회신에 내부
등급 표기를 쓰지 않는 것은 정상이므로 오탐이 난다. 그래서 exit code 는 항상 0 이다.

문항 정의는 `evals/rubrics/investigation-reply.md`.

사용:
  python3 scripts/screen_records.py            # tickets/ 전체
  python3 scripts/screen_records.py 900101     # 한 건

고객 내용은 출력하지 않는다. 문항 이름과 개수만 말한다.
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

from check_ticket_record import (
    grade_counts,
    header_field,
    normalize_output,
    resolve,
    section_body,
    unmarked_guesses,
)

ROOT = Path(__file__).resolve().parents[1]
TICKETS = ROOT / "tickets"

TARGET_OUTPUT = "조사+답변"
# 조사 범위를 적은 기록이 실제로 쓴 표현. `P0-001` 이 자리가 없어 스스로 만든 것에서 왔다.
SCOPE_TERMS = ("보지 않은", "조사 범위", "확인하지 못한")


def screen(path: Path) -> tuple[dict, list[str]]:
    """(측정값, 플래그 목록).

    Q7 은 산출물을 가리지 않는다 — `evidence-verification.md` 4번은 3종 전부에 걸린다.
    Q8 만 `ticket-outputs.md` 2번 전용이라 조사+답변에서만 본다. 이 구분을 놓쳐서
    회귀 표본(`900101`, 작업 지시서)이 필터에 걸러지고 스크린이 false green 을 냈다.
    """
    text = path.read_text(encoding="utf-8")
    output = header_field(text, "산출물") or ""
    is_investigation = TARGET_OUTPUT in normalize_output(output)

    counts = grade_counts(text)
    found = section_body(text, "## 확인한 것") or ""
    asked = section_body(text, "## 물어본 것") or ""
    questions = len(re.findall(r"^\s*(?:[-*]|\d+[.)])\s+\S", asked, re.MULTILINE))

    flags = []
    # Q7 — 기록은 추측인데 초안에 등급 표기가 하나도 없다. 승격됐는지는 사람이 읽는다.
    # 판단은 검사기와 한 곳을 쓴다 — 검사기는 같은 것을 경고로 낸다.
    if unmarked_guesses(text):
        flags.append(f"Q7 가설 승격 — 기록 [추측] {counts['추측']}건, 초안 미표기")
    # Q8 — 무엇을 보지 않았는지가 없으면 `원인 없음` 의 의미가 확정되지 않는다.
    if is_investigation and found.strip() and not any(t in found for t in SCOPE_TERMS):
        flags.append("Q8 조사 범위 — `보지 않은 것` 이 없다")

    measured = {
        "등급": counts,
        "질문": questions,
        "산출물": "조사+답변" if is_investigation else (output.split("(")[0].strip() or "-"),
    }
    return measured, flags


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("target", nargs="?", help="티켓 번호 또는 파일 경로")
    args = parser.parse_args()

    paths = [resolve(args.target)] if args.target else sorted(TICKETS.glob("*.md"))
    if not paths:
        print("screen: 검사할 기록 없음")
        return 0

    screened = 0
    flagged = []
    print(f"{'기록':<24}{'산출물':<12}{'확인':>5}{'추측':>5}{'모름':>5}{'질문':>5}  플래그")
    print("-" * 86)
    for path in paths:
        screened += 1
        measured, flags = screen(path)
        c = measured["등급"]
        note = "; ".join(f.split(" — ")[0] for f in flags) or "-"
        print(
            f"{path.stem:<24}{measured['산출물'][:11]:<12}"
            f"{c['확인']:>5}{c['추측']:>5}{c['모름']:>5}{measured['질문']:>5}  {note}"
        )
        if flags:
            flagged.append((path.stem, flags))

    print()
    if flagged:
        print(f"읽을 대상 {len(flagged)}/{screened}건 — 플래그는 판정이 아니다")
        for name, flags in flagged:
            print(f"\n  {name}")
            for flag in flags:
                print(f"    - {flag}")
    else:
        print(f"screen: 플래그 없음 ({screened}건)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
