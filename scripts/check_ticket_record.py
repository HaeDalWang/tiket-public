#!/usr/bin/env python3
"""티켓 기록이 실제로 채워졌는지 검사한다.

절차를 밟았는지는 지금까지 사람이 트랜스크립트를 읽어야만 알 수 있었다. 2026-09-11 에
라우팅을 건너뛰고 산출물 없이 끝난 세션이 그렇게 발견됐다. 이 검사기는 그 판정을
스크립트로 옮긴다 — 훅과 달리 스크립트는 Claude Code·Codex·Kiro·Hermes 전부에 걸린다.

검사하는 것은 **형태**다. 대충 채우면 통과한다. 품질은 여전히 사람이 본다.
얻는 것은 "조용히 건너뜀"이 "눈에 보이는 미완성"으로 바뀌는 것까지다.

사용:
  python3 scripts/check_ticket_record.py 100014
  python3 scripts/check_ticket_record.py tickets/100014.md
  python3 scripts/check_ticket_record.py --all

판정은 PASS / FAIL / 미평가 셋이다. **미평가는 실패가 아니다.** 검사 항목은 한
번에 생기지 않았고, 도입 전에 쓰인 기록에는 그 칸이 존재하지도 않았다. 그런
기록은 `schema: YYYY-MM-DD` 헤더로 자기 시점을 밝히고, 검사기는 FIELD_SINCE 와
대조해 그날 없던 항목만 건너뛴다. 나머지는 그대로 검사한다 — 면제는 항목별이지
기록 단위가 아니다.

`schema:` 가 없으면 새 기록으로 보고 전부 검사한다. 새 기록에 이 헤더를 붙이지
않는다. 소급 표시 전용이다.

고객 내용은 출력하지 않는다. 위반한 항목의 이름과 줄 번호만 말한다.
"""

from __future__ import annotations

import argparse
import re
import sys
from datetime import date
from pathlib import Path
from typing import NamedTuple

ROOT = Path(__file__).resolve().parents[1]
TICKETS = ROOT / "tickets"

# 각 검사 항목이 templates/ticket-intake.md 에 들어온 날이다. 그 전에 쓰인 기록에는
# 항목 자체가 없었다 — 에이전트가 절차를 건너뛴 게 아니라 절차가 아직 없었다.
# 소급으로 등급과 정책을 지어 넣는 대신, 기록이 `schema:` 로 자기 시점을 밝히면
# 그날 존재하지 않던 항목은 평가하지 않는다.
#
# 커트 하나로 묶지 않는 이유: 도입일이 서로 다르다. `## 발송 전 점검` 은 09-07,
# `등급:`·`policy_ids:` 는 09-14 다. 09-14 단일 커트는 09-07 이후에 실제로
# 빠뜨린 점검까지 덮는다.
FIELD_SINCE = {
    "intake": date(2026, 9, 4),    # 0d5571b — 자리표시자, `## 물어본 것`
    "output": date(2026, 9, 5),    # 559c838 — `산출물:` 과 산출물별 섹션
    "sources": date(2026, 9, 7),   # 748fdc4 — `[확인]` 에 출처 필수
    "gate": date(2026, 9, 7),      # 49b6536 — `## 발송 전 점검`
    "routing": date(2026, 9, 14),  # 164bc77 — `등급:`, `policy_ids:`
    "lessons": date(2026, 9, 24),  # 0026 — `## 교훈 후보`
    # 이 변경 — `확인한 곳:`. 비교가 `schema > since` 라서 작성일 2026-10-26 기록부터 걸리게 하루 앞을 적는다
    "seen_places": date(2026, 10, 25),
}
# `schema:` 가 없을 때 `날짜:` 로 도입 전을 가리는 항목. 이 항목이 생겼을 때 동료 PC 에는
# 이미 헤더 없는 기록이 있었고, 그건 소급 표시를 할 수 없다. report_usage.py 가 --all 결과를
# 지표로 보내므로 날짜로 가리지 않으면 모든 동료의 옛 기록이 한꺼번에 FAIL 로 뒤집힌다.
DATED_BY_RECORD = {"lessons", "seen_places"}

# 문제를 리더가 읽는 묶음으로 나눈다. report_usage.py 가 묶음별 해당 기록 수를 이 이름 그대로
# 보내고, MSP 사이트는 받은 이름을 보여 주기만 한다 — 번역의 원본은 여기 하나다 (2026-09-28).
CATEGORIES = {
    "safety": ("발송 전 점검 미완료", "근거 없이 확인했다고 적었거나 보내기 전 점검을 끝내지 않았다"),
    "routing": ("처리 방향을 안 정함", "난이도·결과물 종류·적용 규칙 검색 결과를 기록하지 않았다"),
    "record": ("기록이 비어 있음", "고객이 물어본 것이나 답변 초안 같은 칸이 비어 있어 이어받을 수 없다"),
    "lessons": ("배운 걸 안 남김", "교훈 후보 칸을 비웠거나 형식이 틀렸다"),
    "format": ("양식 오류", "기록 머리나 섹션 모양이 양식과 다르다"),
}

# 평가 케이스는 전부 이 고객명을 쓴다 (evals/README.md). 실사용 지표와 교훈 전송에서 뺀다.
SYNTHETIC_MARK = "합성고객"

TIERS = {"quick", "standard", "high-risk"}
OUTPUTS = {"작업 지시서", "조사+답변", "답변+출처"}


def normalize_output(value: str) -> str:
    """실제 기록은 `조사 결과 + 답변`, `답변 + 출처` 처럼 쓴다. 템플릿 표기와 맞춘다."""
    text = re.sub(r"\s+", "", value)
    text = text.replace("조사결과", "조사")
    return text

# playbooks/ticket-outputs.md "어디에 적나" 의 표를 그대로 옮긴 것이다.
REQUIRED_SECTIONS = {
    "작업 지시서": ["## 작업 지시"],
    "조사+답변": ["## 확인한 것", "## 답변 초안"],
    "답변+출처": ["## 확인한 것", "## 답변 초안"],
}
# 해당 산출물에서 쓰지 않는 섹션. 빈 제목만 남겨두지 않는다.
UNUSED_SECTIONS = {
    "작업 지시서": ["## 확인한 것"],
    "조사+답변": ["## 작업 지시"],
    "답변+출처": ["## 작업 지시"],
}

# 교훈 후보 — development/plans/2026-09-24-knowledge-loop.md 4절.
# 수집 클라이언트가 이 형식을 그대로 읽는다. 여기서 막지 못한 오타는 조용히 사라진다.
LESSONS_HEADING = "## 교훈 후보"
LESSON_KINDS = {"pitfall", "policy", "playbook", "customer", "miss"}
LESSON_TRIGGERS = {"T1", "T2", "T3", "T4"}
LESSON_REQUIRED = ("종류", "트리거", "한 줄")
LESSON_KEYS = {*LESSON_REQUIRED, "근거", "출처", "관측일", "재관측", "막을 규칙", "제안 위치", "확인한 곳"}
SEEN_KINDS = {"pitfall", "policy", "playbook"}  # 새 규칙을 세우자는 후보 — 먼저 있는 규칙을 찾아봐야 한다
MAX_PATH = 200  # 수집기 lambda/candidates.py 의 `rule` 상한과 같다
PLACEHOLDERS = ["<번호>", "<고객사명>", "<한 줄 제목>", "<subdomain>", "YYYY-MM-DD"]


CORP_ID = re.compile(
    r"^(?:[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}|[A-Za-z0-9_-]{24})$"
)


def corp_id_of(text: str) -> str | None:
    """`corp_id:` 칸의 값. 형식이 맞을 때만 — 교훈 후보와 사용 지표가 같은 판정을 쓴다."""
    # 같은 줄만 본다. `\s*` 는 빈 값일 때 다음 줄까지 넘어간다.
    corp = re.search(r"^corp_id[ \t]*:[ \t]*(\S*)[ \t]*$", strip_comments(text), re.MULTILINE)
    return corp.group(1) if corp and CORP_ID.match(corp.group(1)) else None


def strip_comments(text: str) -> str:
    """HTML 주석은 안내문이다. 본문이 채워졌는지 볼 때 세면 안 된다."""
    return re.sub(r"<!--.*?-->", "", text, flags=re.DOTALL)


def section_body(text: str, heading: str) -> str | None:
    """heading 다음부터 다음 ## 까지. 섹션이 없으면 None."""
    pattern = re.compile(
        rf"^{re.escape(heading)}\s*$(.*?)(?=^## |\Z)", re.MULTILINE | re.DOTALL
    )
    match = pattern.search(text)
    return match.group(1) if match else None


def has_content(body: str | None) -> bool:
    if body is None:
        return False
    stripped = strip_comments(body)
    stripped = re.sub(r"```[a-z]*\s*```", "", stripped)  # 빈 코드블록
    stripped = re.sub(r"^\s*[-*\d.]+\s*$", "", stripped, flags=re.MULTILINE)  # 빈 항목
    return bool(stripped.strip())


def header_field(text: str, name: str) -> str | None:
    match = re.search(rf"^{re.escape(name)}\s*:\s*(.+)$", text, re.MULTILINE)
    return match.group(1).strip() if match else None


def schema_date(text: str) -> str | date | None:
    """기록이 밝힌 작성 시점. 헤더가 없으면 None, 형식이 틀리면 원문 문자열."""
    raw = header_field(text, "schema")
    if raw is None:
        return None
    match = re.match(r"^(\d{4})-(\d{2})-(\d{2})$", raw)
    if not match:
        return raw
    return date(*(int(g) for g in match.groups()))


def parse_lessons(section: str) -> list[dict[str, str]]:
    """`## 교훈 후보` 본문을 항목으로 나눈다. 주석은 뺀다.

    `- 없음` → {"none": ""}, `- 재관측: <path>` → {"재관측": path},
    그 밖의 `- 키: 값` 과 들여쓴 `키: 값` 줄은 한 항목으로 묶는다.
    알려진 키로 시작하지 않는 들여쓴 줄은 바로 앞 값의 줄바꿈으로 보고 이어 붙인다.
    """
    items: list[dict[str, str]] = []
    last_key = ""
    for line in strip_comments(section).splitlines():
        if not line.strip():
            continue
        is_new_item = line.startswith("- ")
        if is_new_item:
            items.append({})
            line = line[2:]
            last_key = ""
        elif not items:
            items.append({})
        text = line.strip()
        if text == "없음":
            items[-1]["none"] = ""
            continue
        key, sep, value = text.partition(":")
        key = key.strip()
        if last_key and not is_new_item and not (sep and key in LESSON_KEYS):
            items[-1][last_key] = f"{items[-1][last_key]} {text}".strip()
            continue
        if not sep:
            key, value = "?", text
        items[-1][key] = value.strip()
        last_key = key if sep else ""
    return items


def rule_exists(raw: str, root: Path) -> bool:
    path = raw.strip("` ")
    parts = Path(path).parts
    return bool(
        path.endswith(".md") and len(path) <= MAX_PATH and not Path(path).is_absolute()
        and ".." not in parts and (root / path).is_file()
    )


def lesson_problems(items: list[dict[str, str]], root: Path | None = None) -> list[str]:
    problems: list[str] = []
    if any("none" in item for item in items) and len(items) > 1:
        problems.append("`## 교훈 후보` 에 `없음` 과 후보가 같이 있다 — 하나만 남긴다")
        return problems
    for number, item in enumerate(items, start=1):
        if "none" in item:
            continue
        if "재관측" in item:
            target = item["재관측"].strip("` ")
            if not re.fullmatch(r"pitfalls/[\w.-]+\.md", target) or not ((root or ROOT) / target).is_file():
                problems.append(f"교훈 후보 {number}번: `재관측:` 은 있는 `pitfalls/*.md` 여야 한다")
            if "종류" in item:
                problems.append(
                    f"교훈 후보 {number}번: `재관측:` 과 `종류:` 가 한 항목에 있다 — 하나만 남긴다 "
                    "(이미 보낸 답이 판례와 어긋났으면 `- 종류: miss`, 모든 답이 판례대로였으면 `- 재관측:`)"
                )
            continue
        missing = [key for key in LESSON_REQUIRED if not item.get(key)]
        if missing:
            problems.append(f"교훈 후보 {number}번: " + ", ".join(f"`{k}:`" for k in missing) + " 이 없다")
            continue
        if item["종류"] not in LESSON_KINDS:
            problems.append(f"교훈 후보 {number}번: `종류:` 는 pitfall/policy/playbook/customer/miss 중 하나다")
        if item["종류"] == "miss" and not rule_exists(item.get("막을 규칙", ""), root or ROOT):
            problems.append(f"교훈 후보 {number}번: miss 는 저장소에 있는 `막을 규칙:`(상대 경로 .md)이 필요하다")
        triggers = set(re.findall(r"[^\s,·/]+", item["트리거"]))
        if not triggers or not triggers <= LESSON_TRIGGERS:
            problems.append(f"교훈 후보 {number}번: `트리거:` 는 T1~T4 다")
    return problems


def seen_problems(items: list[dict[str, str]]) -> list[str]:
    """새 규칙 후보는 `확인한 곳:` 에 `pitfalls/` 를 찾아본 흔적이 있어야 한다.

    lesson_problems 에 넣지 않는다 — report_lessons.py 가 그걸 써서 옛 기록의 전송까지 멈춘다.
    """
    return [
        f"교훈 후보 {number}번: `확인한 곳:` 이 없거나 `pitfalls/` 가 없다 — 후보를 적기 전에 `pitfalls/` 를 나열하고 "
        "이 티켓의 핵심어로 grep 한 뒤, 본 것을 적는다 (예: `확인한 곳: pitfalls/ 목록, grep \"MTU\" pitfalls/ — 해당 없음`). "
        "맞는 판례가 나오면 새 후보 대신 `miss`(이미 보낸 답이 어긋남) 또는 `재관측`(모든 답이 판례대로)이다"
        for number, item in enumerate(items, start=1)
        if item.get("종류") in SEEN_KINDS and "pitfalls/" not in item.get("확인한 곳", "")
    ]


def lesson_warnings(items: list[dict[str, str]]) -> list[str]:
    """pitfall 후보는 카드를 채울 재료를 싣는다 — 출처와 관측일(0027). 아직은 경고만 한다 (2026-10-22 유지보수자)."""
    warnings: list[str] = []
    for number, item in enumerate(items, start=1):
        if item.get("종류") in {"policy", "playbook", "pitfall"} and not item.get("제안 위치"):
            warnings.append(f"교훈 후보 {number}번: `제안 위치:`(덧붙일 기존 파일 또는 새 파일 이름)를 적는다 — 승인자가 어디에 둘지 찾지 않게")
        if item.get("종류") != "pitfall":
            continue
        missing = [] if item.get("출처") else ["`출처:`(URL·문서 위치)"]
        if not re.fullmatch(r"\d{4}-\d{2}-\d{2}", item.get("관측일", "")):
            missing.append("`관측일:`(YYYY-MM-DD)")
        if missing:
            warnings.append(f"교훈 후보 {number}번: pitfall 은 " + "·".join(missing) + " 을 싣는다 — 승인자가 한 줄만 보고 판단하지 않게")
    return warnings


def is_evaluation(text: str) -> bool:
    """제목에 합성고객, 또는 `평가:` 헤더. 본문에 그 낱말이 나오는 것은 세지 않는다."""
    title = next((line for line in text.splitlines() if line.startswith("# ")), "")
    return SYNTHETIC_MARK in title or header_field(text, "평가") is not None


def record_date(text: str) -> date | None:
    """`작성일:`, 없으면 `날짜:` 헤더. 자리표시자나 형식이 틀린 값은 None — 면제 근거로 쓰지 않는다.

    `날짜:` 에 스레드 날짜를 적는 일이 잦아(2026-10-22 평가 12회 중 5회) 기록 시점은 `작성일:` 로 따로 둔다.
    """
    for field in ("작성일", "날짜"):
        match = re.match(r"^(\d{4})-(\d{2})-(\d{2})\b", header_field(text, field) or "")
        if match:
            return date(*(int(g) for g in match.groups()))
    return None


class Result(NamedTuple):
    problems: tuple[str, ...]
    exempted: tuple[str, ...]
    categories: tuple[str, ...] = ()  # problems 와 같은 순서, CATEGORIES 의 키
    warnings: tuple[str, ...] = ()  # 다시 읽으라는 말. 판정에도 지표에도 들어가지 않는다


def grade_counts(text: str) -> dict[str, int]:
    """발송 전 점검은 체크리스트 문구 자체에 등급 표기가 섞인다. 세면 안 된다."""
    gate = section_body(text, "## 발송 전 점검") or ""
    body = text.replace(gate, "") if gate else text
    return {g: body.count(f"[{g}]") for g in ("확인", "추측", "모름")}


def unmarked_guesses(text: str) -> int:
    """Q7 (evals/rubrics/investigation-reply.md) — 기록은 추측인데 초안에 그 표기가 하나도 없으면 추측 건수.

    승격됐는지는 기계가 모른다. 고객 회신에 내부 표기를 안 쓰는 것이 정상이라 오탐이 난다 — 그래서 경고다.
    """
    draft = section_body(text, "## 답변 초안") or ""
    guesses = grade_counts(text)["추측"]
    return guesses if guesses and draft.strip() and "[추측]" not in draft else 0


# 초안이 아무도 안 한 일을 했다고 쓰는 문구 — EVAL-026 초안에서 나왔다(2026-10-24). 약속형("전달드리겠습니다")은 잡지 않는다
FALSE_PROGRESS = re.compile(r"진행하고 있(?:으며|습니다)|전달하고 있습니다|전달(?:드렸|했)습니다|요청해 두었|(?:대응|조치|조사|분석)을 시작했")
MAX_QUOTE = 80  # eval_score.py 와 같다 — 긴 따옴표 구간은 짝이 어긋난 것으로 보고 인용으로 빼지 않는다
QUOTED = re.compile(rf'"[^"]{{1,{MAX_QUOTE}}}"|“[^“”]{{1,{MAX_QUOTE}}}”')


def false_progress(text: str) -> list[str]:
    """답변 초안에서 하지 않은 일을 한 것처럼 쓴 문구. 했는지는 기계가 모른다 — 그래서 경고다.

    주석은 내부 메모, 따옴표 안은 인용이라 빼고, 줄을 접은 문구도 잡는다.
    """
    draft = strip_comments(section_body(text, "## 답변 초안") or "")
    return FALSE_PROGRESS.findall(QUOTED.sub(" ", re.sub(r"\s+", " ", draft)))


def active_fields(body: str) -> dict[str, bool]:
    """이 기록이 쓰인 시점에 있던 검사 항목. `schema:` → 없으면 `날짜:`(DATED_BY_RECORD 만).

    도입일 당일은 커밋 전후를 가릴 수 없으므로 관대한 쪽(면제)으로 둔다.
    형식이 틀린 `schema:` 는 없는 것으로 본다 — check() 가 따로 문제로 잡는다.
    """
    schema = schema_date(body)
    if isinstance(schema, str):
        schema = None
    active = {key: schema is None or schema > since for key, since in FIELD_SINCE.items()}
    written = record_date(body) if schema is None else None
    if written is not None:
        for key in DATED_BY_RECORD:
            active[key] = written > FIELD_SINCE[key]
    # 절이 있으면 새 양식으로 쓴 기록이다. `날짜:` 에 스레드 날짜를 적어도 면제하지 않는다 (2026-10-22 평가).
    if "lessons" in DATED_BY_RECORD and re.search(rf"^{re.escape(LESSONS_HEADING)}\s*$", body, re.MULTILINE):
        active["lessons"] = True
    return active


def tally(results: list[Result]) -> dict[str, int]:
    """CLI 마지막 줄과 사용 지표가 같은 규칙으로 센다. 미평가는 실패가 아니다."""
    failed = sum(1 for result in results if result.problems)
    unevaluated = sum(1 for result in results if not result.problems and result.exempted)
    return {"total": len(results), "passed": len(results) - failed - unevaluated,
            "failed": failed, "pre_schema": unevaluated}


def check(path: Path) -> Result:
    raw = path.read_text(encoding="utf-8")
    body = strip_comments(raw)
    problems: list[str] = []
    categories: list[str] = []

    def fail(message: str, category: str) -> None:
        problems.append(message)
        categories.append(category)

    # 0. schema — 기록이 밝힌 작성 시점. 그날 없던 항목은 평가하지 않는다.
    # 값은 출력하지 않는다 — 형식이 틀린 헤더에 무엇이 들어 있을지 모른다.
    if isinstance(schema_date(body), str):
        fail("`schema:` 값이 YYYY-MM-DD 형식이 아니다", "format")
    active = active_fields(body)
    # seen_places 는 미평가로 세지 않는다 — 새 후보에만 붙는 좁은 검사라, 이것 하나로 옛 기록이 미평가로 뒤집히면 지표가 거짓말을 한다
    exempted = tuple(sorted(key for key, on in active.items() if not on and key != "seen_places"))

    # 1. 템플릿 자리표시자가 남아 있으면 채우다 만 것이다.
    if active["intake"]:
        for placeholder in PLACEHOLDERS:
            if placeholder in body:
                fail(f"자리표시자가 남아 있다: {placeholder}", "record")

    # 2. 등급 — agents/task-router.md. 분류했는지 자체를 이 칸으로만 확인할 수 있다.
    tier = header_field(body, "등급")
    if not active["routing"]:
        pass
    elif not tier:
        fail("`등급:` 이 없다 — 티어를 분류하지 않았거나 기록하지 않았다", "routing")
    elif not any(t in tier for t in TIERS):
        fail(f"`등급:` 값이 quick/standard/high-risk 중 하나가 아니다", "routing")
    elif sum(t in tier for t in TIERS) > 1:
        fail("`등급:` 에 후보가 여러 개 남아 있다 — 하나만 남긴다", "routing")

    # 3. 산출물 — playbooks/ticket-outputs.md. 무엇을 만들지부터 정해야 한다.
    output_raw = header_field(body, "산출물")
    output = None
    if not output_raw:
        if active["output"]:
            fail("`산출물:` 이 없다 — 무엇을 만들지 정하지 않았다", "routing")
    else:
        normalized = normalize_output(output_raw)
        matched = [o for o in OUTPUTS if normalize_output(o) in normalized]
        if len(matched) == 1:
            output = matched[0]
        elif not matched:
            fail("`산출물:` 값이 3종 중 하나가 아니다", "routing")
        else:
            fail("`산출물:` 에 후보가 여러 개 남아 있다 — 하나만 남긴다", "routing")

    # 4. policy_ids — policy/_routing.md:34. 없으면 빈 배열을 명시하게 돼 있다.
    policy = header_field(body, "policy_ids")
    if not active["routing"]:
        pass
    elif policy is None:
        fail("`policy_ids:` 가 없다 — 정책을 검색하지 않았거나 결과를 적지 않았다", "routing")
    elif not re.match(r"^\[.*\]", policy):
        fail("`policy_ids:` 가 배열 형태가 아니다 — 없으면 `[]` 를 명시한다", "routing")

    # 5. 물어본 것 — 이게 비면 나머지가 무엇에 대한 답인지 알 수 없다.
    if active["intake"] and not has_content(section_body(raw, "## 물어본 것")):
        fail("`## 물어본 것` 이 비어 있다", "record")

    # 6. 산출물별 필수 섹션
    if output and active["output"]:
        for heading in REQUIRED_SECTIONS[output]:
            if not has_content(section_body(raw, heading)):
                fail(f"산출물이 '{output}' 인데 `{heading}` 이 비어 있다", "record")
        # 안 쓰는 섹션은 지운다. 빈 제목만 남겨두지 않는다.
        for heading in UNUSED_SECTIONS[output]:
            candidate = section_body(raw, heading)
            if candidate is not None and not has_content(candidate):
                fail(f"안 쓰는 섹션 `{heading}` 이 빈 제목으로 남아 있다 — 지운다", "format")

    # 7. 출처 없는 [확인] 은 [확인] 이 아니다 — templates/ticket-intake.md
    # 발송 전 점검 항목문에 "[확인] 에 전부 출처가 붙었는가" 라는 문장이 들어 있어서
    # 그 구간을 세면 자기 자신을 위반으로 잡는다. 먼저 제외한다.
    lines = raw.split("\n")
    skip = set()
    in_gate = False
    for index, line in enumerate(lines):
        if line.startswith("## "):
            in_gate = line.strip() == "## 발송 전 점검"
        if in_gate:
            skip.add(index)
    for index, line in enumerate(lines):
        if index in skip or "[확인]" not in line or not active["sources"]:
            continue
        window = line + "\n" + "\n".join(lines[index + 1 : index + 4])
        # 템플릿이 인정하는 출처: `→` 근거줄, 문서 URL, 조회 명령, 첨부 이미지.
        if not re.search(r"→|https?://|`[^`]+`|```|!\[", window):
            fail(f"{index + 1}행: 출처 없는 `[확인]` — 근거(→ / URL / 명령 / 이미지)가 없다", "safety")

    # 8. 발송 전 점검 항목이 남아 있으면 통과시키지 않은 것이다. 항목 수는 기록이 쓰인 때의 양식을 따른다.
    gate = section_body(raw, "## 발송 전 점검")
    if not active["gate"]:
        pass
    elif gate is None:
        fail("`## 발송 전 점검` 섹션이 없다", "safety")
    else:
        unchecked = len(re.findall(r"^\s*\[ \]", gate, re.MULTILINE))
        total = len(re.findall(r"^\s*\[[ xX]\]", gate, re.MULTILINE))
        if unchecked:
            fail(f"`## 발송 전 점검` 에 미통과 항목 {unchecked}/{total} 개가 남아 있다", "safety")

    # 9. 교훈 후보 — 넘어진 게 없으면 `없음` 을 명시한다. 비어 있으면 안 본 것과 구분이 안 된다.
    lesson_notes: list[str] = []
    if active["lessons"]:
        lessons = section_body(raw, LESSONS_HEADING)
        if lessons is None:
            fail("`## 교훈 후보` 가 없다 — 넘어진 게 없으면 `- 없음` 을 적는다", "lessons")
        elif not has_content(lessons):
            fail("`## 교훈 후보` 가 비어 있다 — 넘어진 게 없으면 `- 없음` 을 적는다", "lessons")
        else:
            items = parse_lessons(lessons)
            for problem in lesson_problems(items):
                fail(problem, "lessons")
            if active["seen_places"]:
                for problem in seen_problems(items):
                    fail(problem, "lessons")
            lesson_notes = lesson_warnings(items)

    # 10. 추측이 초안에서 단정이 됐는지 — 기준선(2026-10-04)에서 3회 중 2회 샜다. 사람이 다시 읽게만 한다.
    guesses = unmarked_guesses(body)
    warnings = (f"기록에 [추측] {guesses}건이 있다 — 답변 초안이 그 내용을 사실처럼 단정하지 않았는지 다시 읽는다",) if guesses else ()
    warnings += tuple(lesson_notes)
    warnings += tuple(f"답변 초안의 \"{phrase}\" — 실제로 했거나 `## 내부 확인` 에 사람이 할 일로 적은 것인지 다시 읽는다.  아니면 \"내부 확인 중\" 또는 약속형으로 쓴다" for phrase in false_progress(body))

    return Result(tuple(problems), exempted, tuple(categories), warnings)


def resolve(target: str) -> Path:
    path = Path(target)
    if path.is_file():
        return path
    candidate = TICKETS / f"{target}.md"
    if candidate.is_file():
        return candidate
    raise SystemExit(f"ticket record: FAIL (파일 없음: {target})")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("target", nargs="?", help="티켓 번호 또는 파일 경로")
    parser.add_argument("--all", action="store_true", help="tickets/ 전체 검사")
    args = parser.parse_args()

    if args.all:
        paths = sorted(p for p in TICKETS.glob("*.md") if p.name != "README.md")
        if not paths:
            print("ticket record: PASS (검사할 기록 없음)")
            return 0
    elif args.target:
        paths = [resolve(args.target)]
    else:
        parser.error("티켓 번호를 주거나 --all 을 쓴다")

    results = []
    for path in paths:
        result = check(path)
        results.append(result)
        if result.problems or result.warnings:
            print(f"\n{path.name}")
            for problem in result.problems:
                print(f"  - {problem}")
            for warning in result.warnings:
                print(f"  ! 경고(실패 아님): {warning}")

    # 미평가 = 그날 없던 항목만 빠진 기록이다. 실패가 아니라 평가 대상이 아니다.
    counts = tally(results)
    print()
    print(
        f"ticket record: PASS {counts['passed']} / FAIL {counts['failed']} / 미평가 {counts['pre_schema']}"
        f" (총 {counts['total']}건)"
    )
    return 1 if counts["failed"] else 0


if __name__ == "__main__":
    sys.exit(main())
