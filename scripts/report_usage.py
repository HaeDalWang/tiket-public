#!/usr/bin/env python3
"""워크스페이스 사용 지표를 모은다. 고객 내용은 보내지 않는다.

배포는 했는데 어떻게 쓰이는지 측정이 안 된다. 피드백을 요청해도 안 온다 — 이 프레임워크는
"구조를 안 봐도 된다"가 장점이라 동료에게 구조 의견을 달라는 것은 안 해도 된다고 약속한
일을 해달라는 요청이다. 그래서 능동 피드백 대신 **쓰기만 해도 나오는 부산물**을 모은다.

보내는 것은 숫자와 고정 문자열뿐이다. 티켓 번호, 고객 reference, 계정 ID, 이메일, 본문은
페이로드에 들어가지 않는다. 그렇게 만든 뒤 `assert_no_identifiers` 로 한 번 더 막는다 —
설계가 틀려도 식별자가 섞이면 전송이 실패한다.

기본 동작은 **출력**이다. 전송하려면 `--send` 를 명시해야 한다. 무엇이 나가는지 언제든
눈으로 볼 수 있어야 나중에 문제가 되지 않는다.

사용:
  python3 scripts/report_usage.py             보낼 내용을 출력만 한다
  python3 scripts/report_usage.py --json      JSON 그대로
  python3 scripts/report_usage.py --send      실제 전송 (키 필요)
  python3 scripts/report_usage.py --if-due    세션 훅용. 6시간에 한 번, 조용히, 안 막는다
  python3 scripts/report_usage.py --diagnose  전송이 안 될 때. 원인을 가릴 것을 한 번에 출력한다

API 키는 없다. 엔드포인트는 private 저장소에만 적혀 있고, 키를 같은 저장소에 두면
키를 아는 사람과 저장소를 볼 수 있는 사람이 같아져 키가 URL 과 구분되지 않는다.
남는 방어는 private 저장소·throttle·수집기의 금지 패턴 재검사다. 페이로드가 메트릭
전용이라 최악이 "가짜 통계가 섞인다" 수준이라서 이 균형을 택했다.

**기본 켜짐** (2026-09-29). 온보딩이 (`--check` 포함) 항상 고지하고, 끄려면 본인이
conf 에 `TIKET_TELEMETRY=off` 를 넣는다. 그 전에는 conf 의 `TIKET_ENGINEER` 가 있어야
보냈는데, pull 만 했거나 AI 로 온보딩한 동료가 조용히 빠졌다.

`--if-due` 는 이어서 `report_lessons.py` 의 교훈 후보도 보낸다. 그쪽은 고객 맥락을 담으므로
파일과 정책이 따로다(0026). **이 파일의 페이로드는 여전히 숫자뿐이다.**

설정 (~/.config/msp/tiket-usage.conf, 온보딩이 쓴다):
  TIKET_ENGINEER        지표에 표시될 이름. 없으면 git user.name
  TIKET_TELEMETRY       off 면 보내지 않는다
  TIKET_TELEMETRY_URL   수집 엔드포인트 (기본값 있음 — 보통 설정할 필요가 없다)
"""

from __future__ import annotations

import argparse
import collections
import contextlib
import hashlib
import io
import json
import os
import re
import subprocess
import sys
import time
import urllib.error
import urllib.request
from datetime import date, datetime, timezone
from pathlib import Path
from typing import NamedTuple

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(Path(__file__).resolve().parent))

from check_ticket_record import (  # noqa: E402

    CATEGORIES, LESSONS_HEADING, Result, active_fields, check, corp_id_of, has_content, is_evaluation,
    parse_lessons, record_date, section_body, strip_comments, tally,
)
import https_fetch  # noqa: E402
# 온보딩이 쓰고 여기서 읽는다. 셸 프로필은 건드리지 않는다 —
# 그 셸을 안 쓰는 사람에게서 조용히 실패하기 때문이다 (scripts/onboarding.sh 와 같은 원칙).
# 경로를 환경변수로 덮을 수 있게 둔다 — 테스트가 홈 디렉터리를 건드리지 않기 위해서다.
CONF = Path(os.environ.get("TIKET_USAGE_CONF") or Path.home() / ".config/msp/tiket-usage.conf")
# 세션 시작 훅이 쓰는 스로틀 스탬프. check-freshness.sh 와 같은 자리, 같은 방식.
STAMP = Path(os.environ.get("TIKET_USAGE_STAMP") or Path.home() / ".config/msp/tiket-usage-sent")
# 마지막 자동 전송이 어떻게 끝났는지. 자동 전송은 조용해서, 미리보기가 이 파일을 보여 준다.
STATUS = Path(str(STAMP) + "-status")
# 마지막 시도에서 6시간. 24시간이면 하루 세션이 한 번뿐인 사람(오후에 보냈으면 다음 날 오전
# 세션은 건너뛴다)과 미팅으로 세션이 드문 사람이 빠진다 (2026-09-29). 행이 늘어도 사이트는
# 사람마다 최신 행과 날짜만 쓰고, 교훈 후보는 수집기가 같은 ID 를 한 번만 저장한다.
THROTTLE_SECONDS = 6 * 3600
# 3초는 느린 망에서 실패했고, 실패해도 스탬프가 찍혀 그 창의 지표가 빠졌다. 지표·후보 두 번이
# 가장 짧은 호스트 기본 제한(Kiro 60초)의 절반 안에 들도록 10초 (2026-09-29).
HOOK_TIMEOUT_SECONDS = 10
# 한두 번은 망이 나빴을 수 있다. 세 번 연속(18시간 이상)이면 그 PC 는 못 보내는 것이다 — 그때만 말한다.
FAILURE_NOTICE_AFTER = 3
FAILURE_NOTICE = (
    "[tiket] 사용 지표 전송이 {count}번 연속 실패했다. 지금 하는 작업에는 영향이 없다 — 작업을 먼저 끝낸다.\n"
    "답 끝에 사용자에게 한 줄로 알리고, `python3 scripts/report_usage.py --diagnose` 를 돌려 그 출력을 "
    "유지보수자에게 전해 달라고 한다.\n"
    "직접 고치려 하지 않는다 — 인증서 검증·프록시·시스템 설정·이 저장소의 스크립트를 바꾸지 않는다."
)
# 팀에 수집기는 하나다. 전원에게 손으로 붙여넣게 하면 오타가 나고 그 사람 지표만
# 조용히 사라진다. URL 은 secret 이 아니다 — 키가 없으면 수집기가 401 을 돌려준다.
# 저장소는 private 이고, 키는 여전히 저장소 밖(conf)에 둔다.
# 엔드포인트가 바뀌면 conf 나 환경변수로 덮을 수 있다.
DEFAULT_TELEMETRY_URL = "https://usage.example.com/ingest"
# 2 (2026-09-28): 평가 기록 제외 · 분포는 칸이 생긴 뒤 기록만 · recent · sent · release, behind 삭제.
# 계산 방식이 바뀌면 올린다 — 사이트가 옛 방식으로 센 행과 구분할 수 있어야 한다.
# 수집기 SUPPORTED_SCHEMA_VERSIONS 에 먼저 넣고 배포한 뒤 릴리스한다. 모르는 버전은 400 이다.
SCHEMA_VERSION = 2
RECENT_WINDOWS = (7, 28)
WEEKLY_WEEKS = 8  # 주별 집계는 최근 8주만. 그 전은 주끼리 비교할 분량이 쌓인 뒤라 걷어낸다.
SENT_HEADING = "## 실제 발송"
TIMEOUT_SECONDS = 10

POLICY_ID = re.compile(r"(?:POLICY|GUIDE)-[A-Z]+(?:-[A-Z]+)*-\d+")
TIERS = ("quick", "standard", "high-risk")
OUTPUTS = ("작업 지시서", "조사+답변", "답변+출처")
CUSTOMER_FIELDS = ("payer_model", "payer_verified_at", "coc_owner_ref", "contract_exceptions")

# 페이로드에 절대 있으면 안 되는 것. 설계가 아니라 마지막 방어선이다.
FORBIDDEN = {
    "email": re.compile(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"),
    "aws_account_id": re.compile(r"(?<!\d)\d{12}(?!\d)"),
    "ip_or_cidr": re.compile(r"(?<!\d)(?:\d{1,3}\.){3}\d{1,3}(?:/\d{1,2})?(?!\d)"),
    "arn": re.compile(r"arn:aws:"),
    "customer_ref": re.compile(r"\bCUST-\d+\b"),
    "contact_ref": re.compile(r"\bCONTACT-\d+\b"),
    "account_ref": re.compile(r"\bACCOUNT-\d+\b"),
}


def run(*args: str) -> str:
    try:
        out = subprocess.run(args, cwd=ROOT, capture_output=True, text=True, timeout=10)
        return out.stdout.strip() if out.returncode == 0 else ""
    except (OSError, subprocess.SubprocessError):
        return ""


def conf_value(name: str) -> str:
    """`~/.config/msp/tiket-usage.conf` 의 `KEY=value`. 없으면 빈 문자열."""
    try:
        for line in CONF.read_text(encoding="utf-8").splitlines():
            key, _, value = line.partition("=")
            if key.strip() == name:
                return value.strip()
    except OSError:
        pass
    return ""


# 기본값을 두는 것은 엔드포인트뿐이다. 키에는 두지 않는다.
DEFAULTS = {"TIKET_TELEMETRY_URL": DEFAULT_TELEMETRY_URL}


def setting(name: str) -> str:
    """환경변수가 먼저다 — 일회성 덮어쓰기와 CI 를 위해 남긴다. 그다음 conf, 그다음 기본값."""
    return os.environ.get(name, "").strip() or conf_value(name) or DEFAULTS.get(name, "")


def engineer_name() -> str:
    """DynamoDB 의 PK 다. 비면 여러 사람이 한 칸에 섞이므로 절대 빈 값을 주지 않는다.

    자기 신고라 위조할 수 있다. 이것은 감사 로그가 아니라 사용 통계다.
    """
    return setting("TIKET_ENGINEER") or run("git", "config", "user.name") or "unknown"


def header_field(text: str, name: str) -> str:
    match = re.search(rf"^{re.escape(name)}\s*:\s*(.+)$", text, re.MULTILINE)
    return match.group(1).strip() if match else ""


def classify(value: str, options: tuple[str, ...]) -> str:
    """기록은 `high-risk (사유…)` 처럼 사유를 덧붙인다. 앞부분만 본다."""
    compact = re.sub(r"\s+", "", value).replace("조사결과", "조사")
    for option in options:
        if re.sub(r"\s+", "", option) in compact:
            return option
    return "unclassified" if value else "missing"


def record_paths(root: Path) -> list[Path]:
    """check_ticket_record.py --all 과 같은 목록."""
    return sorted(p for p in (root / "tickets").glob("*.md") if p.name != "README.md")


class WorkRecord(NamedTuple):
    text: str
    body: str  # 주석을 뺀 본문
    result: Result
    written: date | None  # `날짜:` 헤더


def work_records(root: Path) -> tuple[list[WorkRecord], int]:
    """실사용 기록과, 빼낸 평가 기록 수. 평가 케이스가 섞이면 사용량과 실패율이 부풀려진다."""
    records, excluded = [], 0
    for path in record_paths(root):
        text = path.read_text(encoding="utf-8", errors="ignore")
        if is_evaluation(text):
            excluded += 1
            continue
        body = strip_comments(text)
        records.append(WorkRecord(text, body, check(path), record_date(body)))
    return records, excluded


def sent_counts(records: list[WorkRecord]) -> dict[str, int]:
    """`## 실제 발송` 이 채워졌나. 초안과의 차이는 재지 않는다 — 지금 그 칸은 보낸 문장이 아니라
    메모라서(2026-09-28, 유사도 0.02~0.16) 비교하면 모두 "많이 고침" 이 된다."""
    recorded = sum(has_content(section_body(record.text, SENT_HEADING)) for record in records)
    return {"recorded": recorded, "empty": len(records) - recorded}


def ticket_counts(records: list[WorkRecord]) -> dict:
    tiers: collections.Counter = collections.Counter()
    outputs: collections.Counter = collections.Counter()
    citations: collections.Counter = collections.Counter()
    policy_field = {"present": 0, "empty": 0, "absent": 0}

    for record in records:
        # 그 칸이 양식에 없던 때 쓴 기록은 분포에서 뺀다. 넣으면 "값 없음" 으로 세어져
        # 분류를 안 한 것처럼 보인다 — 검사기가 미평가로 빼는 것과 같은 판단이다.
        active = active_fields(record.body)
        if active["output"]:
            outputs[classify(header_field(record.text, "산출물"), OUTPUTS)] += 1
        if not active["routing"]:
            continue
        tiers[classify(header_field(record.text, "등급"), TIERS)] += 1

        raw = re.search(r"^policy_ids\s*:\s*(.*)$", record.text, re.MULTILINE)
        if not raw:
            policy_field["absent"] += 1
            continue
        ids = POLICY_ID.findall(raw.group(1))
        policy_field["present" if ids else "empty"] += 1
        citations.update(ids)

    return {
        "count": len(records),
        "tier": dict(tiers),
        "output": dict(outputs),
        "policy_field": policy_field,
        "policy_citations": dict(citations),
        "sent": sent_counts(records),
    }


def category_records(records: list[WorkRecord]) -> dict[str, int]:
    """묶음마다 걸린 **기록 수**. 한 기록이 같은 묶음에서 두 번 걸려도 1 이다."""
    return {code: sum(code in record.result.categories for record in records) for code in CATEGORIES}


def collect_tickets(root: Path = ROOT) -> dict:
    records, excluded = work_records(root)
    return {**ticket_counts(records), "evaluation_excluded": excluded}


def collect_checks(root: Path = ROOT) -> dict:
    """검사기 결과는 항목 이름과 개수만 남는다. 어느 티켓인지는 보내지 않는다.

    `categories` 는 리더용 묶음이다 — 묶음마다 걸린 기록 수와 검사기가 정한 이름·이유를
    그대로 싣는다. 사이트는 번역하지 않고 이것을 보여 준다.
    """
    records, _ = work_records(root)
    results = [record.result for record in records]
    problems: collections.Counter = collections.Counter()
    for result in results:
        # 줄 번호만 지운다. 백틱 안은 검사기가 내는 고정 항목명이라 남겨야
        # "어느 섹션이 비었나"를 알 수 있다. 검사기 계약이 깨져 값이 섞이더라도
        # assert_no_identifiers 가 전송을 막는다.
        problems.update(re.sub(r"\d+", "N", problem) for problem in result.problems)
    counts = category_records(records)
    categories = {code: {"name": name, "why": why, "records": counts[code]}
                  for code, (name, why) in CATEGORIES.items()}
    return {**tally(results), "problems": dict(problems), "categories": categories}


def collect_recent(root: Path = ROOT, today: date | None = None) -> dict:
    """`날짜:` 가 최근 N일(오늘 포함)인 기록만. 누적값은 옛 기록이 영원히 섞여 개선이 안 보인다.

    날짜가 없거나 미래인 기록은 어느 창에도 넣지 않고 `undated` 로 센다.
    """
    today = today or date.today()
    records, _ = work_records(root)
    dated = [record for record in records if record.written and record.written <= today]
    recent: dict = {"undated": len(records) - len(dated)}
    for days in RECENT_WINDOWS:
        window = [record for record in dated if (today - record.written).days < days]
        counts = ticket_counts(window)
        summary = tally([record.result for record in window])
        recent[str(days)] = {
            "count": counts["count"], "tier": counts["tier"], "output": counts["output"],
            "sent": counts["sent"], "failed": summary["failed"], "pre_schema": summary["pre_schema"],
            "categories": category_records(window),
        }
    return recent


def iso_week(day: date) -> str:
    """ISO 주 라벨 `YYYY-Www` (예 2026-W40). 사이트가 주를 묶는 키다."""
    year, week, _ = day.isocalendar()
    return f"{year}-W{week:02d}"


def collect_weekly(root: Path = ROOT, today: date | None = None) -> dict:
    """`날짜:` 의 ISO 주별로 지금 검사기 결과를 다시 센다. 최근 8주만.

    누적 합계는 옛 기록이 영원히 섞여 "통과율이 주마다 오르나" 를 못 본다. 주로 묶어
    매번 지금 검사기로 다시 채점한다 — 판정은 WorkRecord.result 를 그대로 쓴다.
    평가 기록은 work_records 가 이미 뺀다. 날짜 없는·미래 기록은 어느 주에도 넣지 않는다.
    """
    today = today or date.today()
    records, _ = work_records(root)
    dated = [record for record in records if record.written and record.written <= today]

    # 오늘이 속한 ISO 주의 월요일에서 8주 전까지만 남긴다. 월요일 기준으로 빼야
    # 연말·연초의 ISO 주 경계(1주가 작년/올해로 갈리는 경우)에서도 어긋나지 않는다.
    today_monday = date.fromisocalendar(*today.isocalendar()[:2], 1)
    weeks: dict[str, list[WorkRecord]] = collections.defaultdict(list)
    for record in dated:
        monday = date.fromisocalendar(*record.written.isocalendar()[:2], 1)
        if 0 <= (today_monday - monday).days < WEEKLY_WEEKS * 7:
            weeks[iso_week(record.written)].append(record)

    weekly: dict = {}
    for label, bucket in weeks.items():
        summary = tally([record.result for record in bucket])
        weekly[label] = {
            "count": summary["total"], "passed": summary["passed"],
            "failed": summary["failed"], "pre_schema": summary["pre_schema"],
            "categories": category_records(bucket),
        }
    return weekly


# `# <번호> · <고객사명> · <한 줄 제목>` 의 가운데 칸. 이름은 묶는 데만 쓰고 내보내지 않는다.
TITLE_CUSTOMER = re.compile(r"^# [^·\n]*·([^·\n]+)·", re.MULTILINE)


def customer_links(records: list[WorkRecord]) -> dict:
    """프로필이 쓰일 조건이 갖춰졌나 — 이을 키, 다시 오는 고객, 남긴 고객 사정. 개수만 낸다.

    `corp_id` 와 교훈 후보는 0026(2026-09-24)에 생겼다. 그 전 기록은 빼야 "안 채웠다" 로 세지 않는다.
    """
    since = [record for record in records if active_fields(record.body)["lessons"]]
    filled = sum(corp_id_of(record.text) is not None for record in since)
    lessons = sum(item.get("종류") == "customer" for record in since
                  for item in parse_lessons(section_body(record.text, LESSONS_HEADING) or ""))

    names = [TITLE_CUSTOMER.search(record.text) for record in records]
    seen = collections.Counter(re.sub(r"\s+", " ", name.group(1)).strip().casefold() for name in names if name)
    again = [count for count in seen.values() if count > 1]
    return {
        "corp_id": {"filled": filled, "empty": len(since) - filled},
        "repeat": {"customers": len(seen), "repeat_customers": len(again), "repeat_tickets": sum(again),
                   "unnamed": len(names) - sum(seen.values())},
        "customer_lessons": lessons,
    }


def collect_customers(root: Path = ROOT) -> dict:
    """프로필은 개수와 필드 충족률만. 값은 읽지 않는다."""
    paths = sorted((root / "customers").glob("CUST-*/profile.md"))
    filled: collections.Counter = collections.Counter()
    for path in paths:
        text = path.read_text(encoding="utf-8", errors="ignore")
        for field in CUSTOMER_FIELDS:
            value = header_field(text, field)
            if value and value not in {'""', "[]", "unknown", "unknown #"} and not value.startswith("unknown"):
                filled[field] += 1
    return {"count": len(paths), "filled": dict(filled), **customer_links(work_records(root)[0])}


def collect_zendesk_metrics() -> dict:
    """지표 B·C·D (usage_zendesk). Zendesk 는 하루 한 번만 부르고 나머지는 그 파일의 캐시다.

    `TIKET_ZENDESK=off`(환경변수나 conf)면 읽지 않는다. 실패는 `{"error": 코드}` 로 돌아오고
    예외를 던지지 않는다 — 세션 시작을 막지 않는다는 이 파일의 원칙과 같다.
    """
    if setting("TIKET_ZENDESK").lower() == "off":
        return {"error": "off"}
    from usage_zendesk import collect_zendesk

    return collect_zendesk()


def build_payload() -> dict:
    return {
        "schema_version": SCHEMA_VERSION,
        "sent_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "engineer": engineer_name(),
        "head": run("git", "rev-parse", "--short", "HEAD"),
        # 이 워크스페이스가 있는 정식 버전. `behind`(origin/main 대비)는 버전이 아니라서 뺐다.
        "release": run("git", "describe", "--tags", "--abbrev=0", "--match", "v[0-9]*"),
        "tickets": collect_tickets(),
        "checks": collect_checks(),
        "recent": collect_recent(),
        "weekly": collect_weekly(),
        "zendesk": collect_zendesk_metrics(),
        "customers": collect_customers(),
        **hook_health(),
    }


def hook_health() -> dict:
    """본인이 고칠 수 없는 훅 쪽 실패를 다음 지표에 실어 유지보수자가 보게 한다. 평소에는 빈 맵이다.
    값은 예외 종류와 HTTP 상태까지만이다(report_lessons.send_quietly)."""
    lessons = read_status().get("lessons")
    return {"lessons_status": lessons} if isinstance(lessons, str) and lessons.startswith("failed") else {}


def assert_no_identifiers(payload: dict) -> list[str]:
    """페이로드를 문자열로 펴서 금지 패턴을 찾는다. 하나라도 걸리면 보내지 않는다."""
    blob = json.dumps(payload, ensure_ascii=False)
    return [name for name, pattern in FORBIDDEN.items() if pattern.search(blob)]


def render(payload: dict) -> str:
    t, c, cu = payload["tickets"], payload["checks"], payload["customers"]
    lines = [
        f"engineer  {payload['engineer']}",
        f"head      {payload['head']}  (정식 버전 {payload.get('release') or '-'})",
        "",
        f"티켓      {t['count']}건 (평가 기록 {t.get('evaluation_excluded', 0)}건 제외)"
        f" · 실제 발송 기록 {t['sent']['recorded']}건",
        f"  등급    " + (", ".join(f"{k} {v}" for k, v in t["tier"].items()) or "-"),
        f"  산출물  " + (", ".join(f"{k} {v}" for k, v in t["output"].items()) or "-"),
        f"  policy_ids  채움 {t['policy_field']['present']} / 빈목록 "
        f"{t['policy_field']['empty']} / 필드없음 {t['policy_field']['absent']}",
        "",
        f"검사기    {c['total']}건 중 PASS {c.get('passed', 0)} / "
        f"FAIL {c['failed']} / 미평가 {c.get('pre_schema', 0)}",
    ]
    lines += [f"  {row['records']:>2}건  {row['name']}" for row in c.get("categories", {}).values() if row["records"]]
    lines.append("  항목별")
    for label, n in sorted(c["problems"].items(), key=lambda kv: -kv[1]):
        lines.append(f"  {n:>2}건  {label}")
    lines += ["", "정책 카드 인용"]
    citations = t["policy_citations"]
    lines += [f"  {n:>2}회  {cid}" for cid, n in
              sorted(citations.items(), key=lambda kv: -kv[1])] or ["  (없음)"]
    names = {code: name for code, (name, _) in CATEGORIES.items()}
    recent = payload.get("recent", {})
    for days in RECENT_WINDOWS:
        window = recent.get(str(days))
        if not window:
            continue
        hits = ", ".join(f"{names[code]} {n}" for code, n in window["categories"].items() if n) or "걸린 것 없음"
        lines += ["", f"최근 {days}일  {window['count']}건 · 실제 발송 기록 {window['sent']['recorded']}건",
                  f"  FAIL {window['failed']} / 미평가 {window['pre_schema']} · {hits}"]
    if recent:
        lines.append(f"  (날짜 없는 기록 {recent.get('undated', 0)}건은 최근 창에 안 넣음)")
    weekly = payload.get("weekly", {})
    if weekly:
        names = {code: name for code, (name, _) in CATEGORIES.items()}
        lines += ["", "주별 (최근 8주, 작성 주 기준 · 지금 검사기로 재채점)"]
        for label in sorted(weekly):
            w = weekly[label]
            hits = ", ".join(f"{names[code]} {n}" for code, n in w["categories"].items() if n) or "걸린 것 없음"
            lines.append(f"  {label}  {w['count']}건 · PASS {w['passed']} / FAIL {w['failed']}"
                         f" / 미평가 {w['pre_schema']} · {hits}")
    zendesk = payload.get("zendesk", {})
    if zendesk:
        stage = f" · {zendesk['stage']} 호출에서" if zendesk.get("stage") else ""
        if "error" in zendesk:
            lines += ["", f"Zendesk 지표  {zendesk['error']}{stage} (값을 싣지 않음)"]
        else:
            compared = (f"초안 비교 못 읽음({zendesk['similarity_error']}{stage})" if "similarity_error" in zendesk
                        else f"초안 비교 {len(zendesk.get('draft_similarity', {}))}주")
            lines += ["", f"Zendesk 지표  {len(zendesk.get('weeks', {}))}주 · {compared}"
                          "  (자세히: python3 scripts/usage_zendesk.py)"]
    lines += ["", f"고객 프로필  {cu['count']}개"]
    for field in CUSTOMER_FIELDS:
        lines.append(f"  {field}: {cu['filled'].get(field, 0)}/{cu['count']} 채움")
    corp, repeat = cu["corp_id"], cu["repeat"]
    lines += [
        f"  corp_id  채움 {corp['filled']} / 비움 {corp['empty']} (칸이 생긴 뒤 기록만)",
        f"  재방문   고객 {repeat['customers']}곳 중 {repeat['repeat_customers']}곳 · 티켓 {repeat['repeat_tickets']}건"
        f" (제목에 고객명 없는 기록 {repeat['unnamed']}건)",
        f"  고객 사정 교훈 후보  {cu['customer_lessons']}건",
    ]
    return "\n".join(lines)


def is_due() -> bool:
    """THROTTLE_SECONDS 에 한 번. 스탬프를 읽지 못하면 due 로 본다 — 못 보내는 것보다 낫다."""
    try:
        return time.time() - STAMP.stat().st_mtime >= THROTTLE_SECONDS
    except OSError:
        return True


def mark_sent() -> None:
    """**시도했으면** 찍는다. 성공만 찍으면 네트워크가 종일 죽은 날 매 세션 재시도한다 —
    지표는 부수적인 일이고, 세션 시작을 늦추는 쪽이 더 나쁘다."""
    try:
        STAMP.parent.mkdir(parents=True, exist_ok=True)
        STAMP.touch()
    except OSError:
        pass


def is_linked_worktree() -> bool:
    """`git worktree add` 로 뻗은 폴더인가. 거기에는 gitignore 된 `tickets/` 가 없어 전부 0 으로 나온다."""
    dirs = run("git", "rev-parse", "--path-format=absolute", "--git-dir", "--git-common-dir").split("\n")
    return len(dirs) == 2 and dirs[0] != dirs[1]


def run_if_due() -> int:
    """세션 시작 훅의 진입점. **아무것도 출력하지 않고, 무엇이 실패해도 0 으로 끝난다.**

    훅이 stdout 을 오염시키면 세션에 섞인다. 종료 코드가 0 이 아니면 호스트에 따라
    세션 시작이 시끄러워진다. 측정은 부수적인 일이라 그 값을 치르지 않는다.
    """
    try:
        # 기본 켜짐 (2026-09-29). 예전에는 conf 의 TIKET_ENGINEER 를 동의 표시로 보고 없으면
        # 멈췄는데, pull 만 했거나 AI 로 온보딩한 동료가 조용히 빠졌다. 고지는 온보딩이
        # (--check 포함) 항상 하고, 끄는 것만 본인이 conf 에 적는다.
        if setting("TIKET_TELEMETRY").lower() == "off":
            return 0
        # 워크트리에서 보낸 "티켓 0건" 이 그 사람의 마지막 행을 덮었다 (2026-10-04). 스탬프도 찍지 않는다.
        if is_linked_worktree():
            return 0
        if not is_due():
            return 0
    except Exception:  # noqa: BLE001
        return 0

    # 게이트를 지났으면 **시도한 것으로 본다.** 여기부터는 결과와 무관하게 스탬프를
    # 찍는다 — 네트워크가 종일 죽은 날 매 세션 재시도하면 세션 시작만 느려진다.
    # stderr 도 조용히 한다. Kiro IDE 는 stdout 이 비면 stderr 를 에이전트 맥락에 넣어서,
    # 네트워크가 나쁜 날 "전송 실패" 가 AI 에게 섞였다 (2026-09-29).
    # stdout 은 에이전트 맥락에 들어간다. 평소에는 비워 두고, 연속으로 실패했을 때만 한 번 말한다 —
    # 시도할 때만 여기 오므로 많아야 6시간에 한 번이다.
    # 스탬프와 "시작했다" 는 **먼저** 적는다. 호스트가 훅을 시간 제한에 죽이면 끝난 뒤에 쓰는 것은 하나도 안 남아,
    # 매 세션 다시 죽으면서 아무 흔적도 없었다(2026-10-07 검토).
    mark_sent()
    try:
        died = begin_attempt()
        if died >= FAILURE_NOTICE_AFTER:
            print(FAILURE_NOTICE.format(count=died), flush=True)
        with contextlib.redirect_stderr(io.StringIO()):
            failures = write_status(attempt(timeout=HOOK_TIMEOUT_SECONDS))
        if failures >= FAILURE_NOTICE_AFTER > died:
            print(FAILURE_NOTICE.format(count=failures))
    except Exception:  # noqa: BLE001 — 세션 시작을 어떤 이유로도 막지 않는다
        pass
    try:
        # 교훈 후보는 정책이 반대라 파일이 따로다(고객 맥락을 보낸다, 0026). 시점만 공유한다.
        # 이 파일의 페이로드는 여전히 숫자뿐이다.
        from report_lessons import send_quietly

        save_status({**read_status(), "lessons": send_quietly(timeout=HOOK_TIMEOUT_SECONDS)})
    except Exception:  # noqa: BLE001
        pass
    return 0


def safe_engineer(name: str) -> str:
    """이름이 금지 패턴에 걸리면(메일 주소를 이름으로 쓴 경우) 그대로 보낼 수 없다. 같은 사람이 늘 같은 칸에
    오도록 해시 앞자리로 바꾼다 — 누구인지는 본인이 미리보기를 보고 이름을 고쳐야 알 수 있다."""
    if not assert_no_identifiers({"engineer": name}):
        return name
    return "이름확인필요-" + hashlib.sha256(name.encode("utf-8")).hexdigest()[:8]


def problem_report(reasons: list[str]) -> dict:
    """보내지 못한 사유만 담은 짧은 보고. 티켓에서 나온 값은 하나도 없다 — 패턴 이름과 예외 종류까지만."""
    return {
        "schema_version": SCHEMA_VERSION,
        "sent_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "engineer": safe_engineer(engineer_name()),
        "head": run("git", "rev-parse", "--short", "HEAD"),
        "release": run("git", "describe", "--tags", "--abbrev=0", "--match", "v[0-9]*"),
        "skipped": reasons,
    }


def attempt(timeout: int) -> str:
    """자동 전송 한 번. 어떻게 끝났는지를 돌려준다 — `sent` · `send_failed` · `skipped: <사유>`.

    예전에는 금지 패턴에 걸리거나 수집이 죽으면 말없이 넘어갔다. 요청이 아예 안 나가 수집기 로그에도 없었고,
    "계속 보내는데 안 보인다" 는 동료를 찾을 길이 없었다(2026-10-07). 사유만 대신 보낸다."""
    try:
        payload = build_payload()
        reasons = assert_no_identifiers(payload)
    except Exception as exc:  # noqa: BLE001 — 예외 문구에는 티켓 내용이 섞일 수 있다. 종류만 남긴다.
        reasons = [f"build_error:{type(exc).__name__}"]
    if not reasons:
        return "sent" if send(payload, notice=io.StringIO(), timeout=timeout) == 0 else "send_failed"
    report = problem_report(reasons)
    # 사유도 못 닿았으면 수집기에는 아무것도 안 갔다 — `skipped` 로 적으면 연속 실패가 0 으로 돌아간다.
    if not assert_no_identifiers(report) and send(report, notice=io.StringIO(), timeout=timeout) != 0:
        return "send_failed"
    return "skipped: " + ", ".join(reasons)


def read_status() -> dict:
    try:
        status = json.loads(STATUS.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}
    return status if isinstance(status, dict) else {}


def save_status(status: dict) -> None:
    try:
        STATUS.parent.mkdir(parents=True, exist_ok=True)
        STATUS.write_text(json.dumps(status, ensure_ascii=False), encoding="utf-8")
    except OSError:
        pass


def _stamped(previous: dict, outcome: str, failures: int) -> dict:
    at = datetime.now(timezone.utc).isoformat(timespec="seconds")
    return {**previous, "at": at, "outcome": outcome, "failures": failures}


def _failures(status: dict) -> int:
    return status["failures"] if isinstance(status.get("failures"), int) else 0


def begin_attempt() -> int:
    """시도를 시작했다고 적고, 수집기에 닿지 못한 것이 지금까지 몇 번 연속인지 돌려준다.
    지난 시도가 `started` 로 남아 있으면 끝나기 전에 죽은 것이다 — 그것도 실패로 센다."""
    previous = read_status()
    failures = _failures(previous) + int(previous.get("outcome") == "started")
    save_status(_stamped(previous, "started", failures))
    return failures


def write_status(outcome: str) -> int:
    """마지막 결과를 남기고, 수집기에 닿지 못한 것이 몇 번째 연속인지 돌려준다. `skipped` 는 닿은 것이다."""
    previous = read_status()
    failures = _failures(previous) + 1 if outcome == "send_failed" else 0
    save_status(_stamped(previous, outcome, failures))
    return failures


def diagnose() -> int:
    """"보내는데 안 보인다" 를 한 번에 가린다. 동료에게 이 한 줄만 부탁한다. 주소·프록시 값·토큰은 찍지 않는다."""
    import ssl

    print("python   ", sys.version.split()[0], sys.executable)
    print("version  ", run("git", "describe", "--tags", "--abbrev=0", "--match", "v[0-9]*") or "-",
          run("git", "rev-parse", "--short", "HEAD"))
    print("telemetry", setting("TIKET_TELEMETRY") or "on", "| 이름 있음" if setting("TIKET_ENGINEER") else "| 이름 없음(git user.name 을 쓴다)")
    print("proxy env", ", ".join(sorted(k for k in os.environ if k.lower().endswith("_proxy"))) or "없음")
    print("ca file  ", ssl.get_default_verify_paths().cafile, "|", ssl.OPENSSL_VERSION,
          "| OS 묶음", next((b for b in https_fetch.OS_CA_BUNDLES if os.path.exists(b)), "없음"),
          "| certifi", https_fetch.certifi_bundle() or "없음")
    targets = (("collector", setting("TIKET_TELEMETRY_URL")),
               ("reference", os.environ.get("TIKET_DIAGNOSE_REFERENCE_URL") or "https://www.google.com"))
    for label, url in targets:
        try:
            https_fetch.urlopen(url, timeout=TIMEOUT_SECONDS).close()
            print(label, "ok")
        except urllib.error.HTTPError as exc:
            print(label, "닿았다 — HTTP", exc.code)  # 수집기는 GET 에 404 를 낸다. 닿았다는 뜻이다
        except Exception as exc:  # noqa: BLE001
            print(label, "FAIL", type(exc).__name__, str(exc).replace(url, "<url>")[:160])
    print(last_status())
    try:
        payload = build_payload()
        leaks = assert_no_identifiers(payload)
    except Exception as exc:  # noqa: BLE001
        print("send 안 함 — 수집 중 오류:", type(exc).__name__)
        return 0
    if leaks:
        print("send 안 함 — 금지 패턴:", ", ".join(leaks))
        return 0
    print("send exit", send(payload))
    return 0


def last_status() -> str:
    status = read_status()
    if "at" not in status or "outcome" not in status:
        return "마지막 자동 전송  기록 없음"
    outcome = "시작했지만 끝나지 않았다" if status["outcome"] == "started" else status["outcome"]
    lessons = f"  · 교훈 후보 {status['lessons']}" if status.get("lessons") else ""
    return f"마지막 자동 전송  {status['at']}  {outcome}{lessons}"


def send(payload: dict, notice=None, timeout: int = TIMEOUT_SECONDS) -> int:
    """`notice` 는 사람이 읽을 줄이 나가는 곳. `--json` 일 때 stdout 을 비워두기 위해
    호출자가 stderr 를 넘긴다 — stdout 이 JSON 하나로 유지돼야 파이프가 안 깨진다."""
    stream = notice or sys.stdout
    url = setting("TIKET_TELEMETRY_URL")
    if not url:
        print("TIKET_TELEMETRY_URL 이 없다. 전송하지 않았다.", file=sys.stderr)
        return 1
    request = urllib.request.Request(
        url,
        data=json.dumps(payload, ensure_ascii=False).encode("utf-8"),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with https_fetch.urlopen(request, timeout=timeout) as response:
            print(f"전송 완료 ({response.status})", file=stream)
            return 0
    except (urllib.error.URLError, OSError) as exc:
        # 전송 실패가 작업을 막지 않는다. 측정은 부수적인 일이다.
        print(f"전송 실패 — 작업에는 영향 없다: {exc}", file=sys.stderr)
        if https_fetch.is_cert_error(exc):
            print("  이 PC 의 Python 이 인증서를 검증하지 못한다. OS 인증서 묶음으로도 안 됐다 — "
                  "회사 보안 프로그램이 인증서를 바꿔 끼우는지 유지보수자에게 알려 달라.", file=sys.stderr)
        return 1


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--send", action="store_true", help="실제로 전송한다")
    parser.add_argument("--json", action="store_true", help="JSON 원문으로 출력")
    parser.add_argument("--diagnose", action="store_true", help="전송이 안 될 때 — 원인을 가릴 것을 한 번에 출력한다")
    parser.add_argument(
        "--if-due", action="store_true", dest="if_due",
        help="세션 훅용 — 6시간에 한 번, 조용히, 무엇이 실패해도 세션을 막지 않는다",
    )
    args = parser.parse_args()

    if args.if_due:
        return run_if_due()
    if args.diagnose:
        return diagnose()

    payload = build_payload()
    leaks = assert_no_identifiers(payload)
    if leaks:
        print(f"식별자가 섞였다: {', '.join(leaks)} — 전송을 중단한다.", file=sys.stderr)
        if assert_no_identifiers({"engineer": payload["engineer"]}):
            print("지표에 쓰는 이름이 걸렸다 — 메일 주소 같은 값은 이름으로 쓸 수 없다.", file=sys.stderr)
            print(f"  {CONF} 에 TIKET_ENGINEER=<이름> 을 적는다 (없으면 git user.name 을 쓴다).", file=sys.stderr)
        else:
            print("scripts/report_usage.py 의 수집 함수를 고쳐야 한다 — 유지보수자에게 이 줄을 알려 달라.", file=sys.stderr)
        return 2

    # `--json` 의 stdout 은 기계가 읽는다. 사람용 줄은 전부 stderr 로 보낸다.
    notice = sys.stderr if args.json else sys.stdout
    print(json.dumps(payload, ensure_ascii=False, indent=2) if args.json else render(payload))
    if args.send:
        print(file=notice)
        # engineer 는 PK 다. git user.name 으로 대신 보내면 온보딩 전후로 같은 사람이 두 칸으로
        # 갈라진다 (2026-09-24, maintainer-gh·유지보수자). 손으로 보낼 때는 이름을 먼저 고르게 한다.
        # 자동 전송은 2026-09-29 부터 이름이 없어도 git user.name 으로 보낸다 — 빠지는 것보다 낫다.
        if not setting("TIKET_ENGINEER"):
            print("보내지 않았다 — 지표에 쓸 이름(TIKET_ENGINEER)이 없다.", file=notice)
            print("  bash scripts/onboarding.sh 의 7단계에서 정한다.", file=notice)
            return 1
        return send(payload, notice)
    print(f"\n{last_status()}", file=notice)
    print("(출력만 했다. 전송하려면 --send)", file=notice)
    return 0


if __name__ == "__main__":
    sys.exit(main())
