#!/usr/bin/env python3
"""Zendesk 에서 지표 B·C·D 를 모은다. 숫자와 ISO 주 문자열만 내놓는다.

계획서: development/plans/2026-10-04-usage-metrics-abcd.md

`report_usage.py` 가 기록(tickets/) 에서 A 를 모으는 것과 짝을 이룬다. 이 파일은
**Zendesk 를 읽어야만 알 수 있는 것**만 맡는다:

  B  `## 답변 초안` 과 Zendesk 에 실제로 올라간 내 공개 답변의 유사도 (draft_similarity)
  C  첫 응답·해결까지 걸린 시간과 재오픈 — tiket 기록이 있는 티켓과 없는 티켓을 나눠서
  D  그 주에 해결된, 나에게 배정된 티켓 수와 그중 기록이 있는 수.
     알람·월간보고서(AUTO_TAGS)는 빼고 `auto_excluded` 로 따로 센다 — C 의 시간에도 넣지 않는다.
     남의 담당 티켓을 도와 쓴 기록은 `helped_with_record` 로 따로 센다 (그 티켓은 담당자의 solved 에 든다).

내놓는 것은 `collect_zendesk(root, today, http=...) -> dict` 하나다. 결과에는 티켓 번호·
고객명·본문이 들어가지 않는다 — `report_usage.assert_no_identifiers` 를 통과해야 한다.

Zendesk 를 못 읽으면 값을 지어내지 않고 `{"error": "<짧은 코드>", "stage": "<어느 호출>"}` 만 돌려준다:
  no_credentials · auth · timeout · http_<code> · parse / search · show_many · me · comments. 예외는 밖으로 던지지 않는다.
B(유사도)만 못 읽으면 C·D 는 내고 `similarity_error`·`stage` 를 붙인다.

하루 한 번만 계산한다. 오류 없이 끝난 결과만 캐시 파일에 두고(기본 ~/.config/msp/tiket-zendesk-metrics.json,
TIKET_ZENDESK_METRICS 로 바꿀 수 있다), 같은 UTC 날짜에 다시 부르면 그 값을 돌려준다.

자격증명은 scripts/fetch-ticket.sh 와 같은 우선순위다:
  환경변수 ZENDESK_SUBDOMAIN·ZENDESK_EMAIL·ZENDESK_API_TOKEN
  → 외부 스킬 호환 이름 (Zendesk_SUBDOMAIN·Zendesk_EMAIL·Zendesk_API)
  → ~/.config/msp/zendesk.conf
인증 방식도 같다 — email/token Basic 인증.

사용:
  python3 scripts/usage_zendesk.py          계산 결과를 화면에 보여 주는 미리 보기 (보내지 않는다)
실제 Zendesk 는 사람이 이 명령을 치거나, 조율자가 report_usage.build_payload 에서
collect_zendesk() 를 부를 때만 불린다 — 어느 쪽이든 하루 한 번만 실제로 계산하고
나머지는 캐시다. 캐시 덕에 6시간마다의 사용 지표 전송이 Zendesk 를 다시 때리지 않는다.
"""

from __future__ import annotations

import base64
import difflib
import json
import os
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import date, datetime, timedelta, timezone
from pathlib import Path
from typing import Callable

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(Path(__file__).resolve().parent))

from check_ticket_record import is_evaluation, section_body, strip_comments  # noqa: E402
import https_fetch  # noqa: E402

# fetch-ticket.sh 와 같은 자리. 환경변수로 덮을 수 있게 둔다 — 테스트가 홈을 건드리지 않기 위해서다.
ZENDESK_CONF = Path(
    os.environ.get("ZENDESK_CONF") or Path.home() / ".config/msp/zendesk.conf"
)
# 캐시. 하루 한 번 계산한 값을 여기 둔다. 경로는 환경변수로 바꿀 수 있다.
CACHE = Path(
    os.environ.get("TIKET_ZENDESK_METRICS")
    or Path.home() / ".config/msp/tiket-zendesk-metrics.json"
)

DRAFT_HEADING = "## 답변 초안"
CACHE_SHAPE = 3                # 주별 값에 키를 더하면 올린다 — 같은 날의 옛 캐시를 버리게 한다
WEEKS = 8                      # 최근 8주
TOTAL_TIMEOUT_SECONDS = 20     # 전체 상한. 넘으면 그때까지 것을 버리고 timeout.
PER_REQUEST_TIMEOUT = 10
SHOW_MANY_BATCH = 100          # tickets/show_many 는 한 번에 100건.
# 유사도 구간 — 계획서. high ≥ 0.9, mid 0.6~0.9, low < 0.6.
# 사람이 푼 티켓이 아닌 것. 알람은 `auto_notification`·`sla_excluded`, 월간보고서는 `monthly_report` 태그가 붙는다
# (2026-10-13 실측: 8주 해결 79건 중 알람 46·보고서 5). 분모에 넣으면 기록 비율이 6% 로 나온다.
AUTO_TAGS = frozenset({"auto_notification", "sla_excluded", "monthly_report"})
DONE_STATUSES = {"solved", "closed"}
SIMILARITY_HIGH = 0.9
SIMILARITY_MID = 0.6


# ── 자격증명 (fetch-ticket.sh 와 같은 우선순위·같은 인증) ──────────────────────────


def _conf_value(name: str) -> str:
    try:
        for line in ZENDESK_CONF.read_text(encoding="utf-8").splitlines():
            key, _, value = line.partition("=")
            if key.strip() == name:
                return value.strip()
    except OSError:
        pass
    return ""


def _credential(our_name: str, compat_name: str) -> str:
    """우리 환경변수 → 외부 스킬 호환 이름 → conf 파일. fetch-ticket.sh 와 같은 순서."""
    return (
        os.environ.get(our_name, "").strip()
        or os.environ.get(compat_name, "").strip()
        or _conf_value(our_name)
    )


class _Credentials:
    __slots__ = ("host", "email", "token")

    def __init__(self, host: str, email: str, token: str) -> None:
        self.host = host
        self.email = email
        self.token = token

    @property
    def base(self) -> str:
        return f"https://{self.host}/api/v2"

    @property
    def auth_header(self) -> str:
        raw = f"{self.email}/token:{self.token}".encode("utf-8")
        return "Basic " + base64.b64encode(raw).decode("ascii")


def _load_credentials() -> _Credentials | None:
    sub = _credential("ZENDESK_SUBDOMAIN", "Zendesk_SUBDOMAIN")
    email = _credential("ZENDESK_EMAIL", "Zendesk_EMAIL")
    token = _credential("ZENDESK_API_TOKEN", "Zendesk_API")
    if not (sub and email and token):
        return None
    host = sub if sub.endswith(".zendesk.com") else f"{sub}.zendesk.com"
    return _Credentials(host, email, token)


# ── HTTP 심 (테스트가 가짜를 끼운다) ─────────────────────────────────────────────

# http(url, timeout) -> (status:int, body:bytes). 네트워크를 타는 유일한 지점이라 여기만
# 바꾸면 테스트가 실서버에 닿지 않는다. timeout 은 호출마다 남은 예산에서 _get 이 넘긴다.
Http = Callable[[str, float], "tuple[int, bytes]"]


class _ZendeskError(Exception):
    """collect_zendesk 안에서만 쓰는 짧은 코드. 밖으로는 {"error": code} 로만 나간다."""

    def __init__(self, code: str, stage: str = "") -> None:
        super().__init__(code)
        self.code = code
        self.stage = stage  # 어느 호출이었나 — search · show_many · me · comments

    def as_payload(self, key: str = "error") -> dict:
        return {key: self.code, **({"stage": self.stage} if self.stage else {})}


class _Budget:
    """전체 상한 하나를 모든 호출이 나눠 쓴다. search·show_many·users/me·comments 가
    각자 10초를 쓰면 최악에 100초가 넘고, 세션 시작 훅 단계 상한(50초)을 깨 사용 지표
    전송 전체가 죽는다 (조율자 검토 1차, 2026-10-04). 시계는 주입할 수 있다 — 테스트가
    가짜 시계로 "N번째 호출에서 시간이 다 됨" 을 재현한다."""

    __slots__ = ("deadline", "clock")

    def __init__(self, seconds: float, clock: Callable[[], float]) -> None:
        self.clock = clock
        self.deadline = clock() + seconds

    def remaining(self) -> float:
        return self.deadline - self.clock()

    def expired(self) -> bool:
        return self.remaining() <= 0

    def per_request_timeout(self) -> float:
        """남은 예산을 넘지 않는 요청 타임아웃. 호출 전에 expired() 로 거른 뒤 쓴다."""
        return min(PER_REQUEST_TIMEOUT, self.remaining())


def _default_http(credentials: _Credentials) -> Http:
    header = credentials.auth_header

    def http(url: str, timeout: float) -> tuple[int, bytes]:
        request = urllib.request.Request(
            url, headers={"Authorization": header, "Accept": "application/json"}
        )
        try:
            with https_fetch.urlopen(request, timeout=timeout) as response:
                return response.status, response.read()
        except urllib.error.HTTPError as exc:
            return exc.code, b""

    return http


def _get(http: Http, url: str, budget: _Budget, stage: str) -> dict:
    """2xx 면 JSON, 아니면 _ZendeskError. 네트워크 실패는 timeout 으로 접는다.

    예산이 바닥나면 **호출하지 않고** timeout 이다 — 남은 시간이 없는데 또 10초를 걸면
    전체 상한의 의미가 사라진다.
    """
    if budget.expired():
        raise _ZendeskError("timeout", stage)
    try:
        status, body = http(url, budget.per_request_timeout())
    except (urllib.error.URLError, OSError, TimeoutError) as exc:
        raise _ZendeskError("cert" if https_fetch.is_cert_error(exc) else "timeout", stage)
    if status == 401 or status == 403:
        raise _ZendeskError("auth", stage)
    if status < 200 or status >= 300:
        raise _ZendeskError(f"http_{status}", stage)
    try:
        return json.loads(body.decode("utf-8"))
    except (ValueError, UnicodeDecodeError):
        raise _ZendeskError("parse", stage)


# ── 주 계산 ──────────────────────────────────────────────────────────────────


def _iso_week(value: date) -> str:
    year, week, _ = value.isocalendar()
    return f"{year}-W{week:02d}"


def _week_window(today: date) -> tuple[date, list[str]]:
    """오늘이 든 주를 포함해 최근 WEEKS 주. (가장 이른 날, ISO 주 라벨 목록)."""
    monday = today - timedelta(days=today.weekday())
    start = monday - timedelta(weeks=WEEKS - 1)
    labels = [_iso_week(start + timedelta(weeks=i)) for i in range(WEEKS)]
    return start, labels


def _median(values: list[float]) -> float | None:
    if not values:
        return None
    ordered = sorted(values)
    mid = len(ordered) // 2
    if len(ordered) % 2:
        return ordered[mid]
    return (ordered[mid - 1] + ordered[mid]) / 2


# ── 기록 (tickets/) ────────────────────────────────────────────────────────────


def _record_ids(root: Path) -> set[str]:
    """tickets/ 의 파일 이름에서 티켓 번호. 평가 기록은 뺀다 (report_usage 와 같은 기준)."""
    ids: set[str] = set()
    for path in sorted((root / "tickets").glob("*.md")):
        if path.name == "README.md":
            continue
        try:
            text = path.read_text(encoding="utf-8", errors="ignore")
        except OSError:
            continue
        if is_evaluation(text):
            continue
        if path.stem.isdigit():
            ids.add(path.stem)
    return ids


def _draft_of(root: Path, ticket_id: str) -> str | None:
    """그 티켓 기록의 `## 답변 초안` 본문. 없거나 비면 None."""
    path = root / "tickets" / f"{ticket_id}.md"
    try:
        text = path.read_text(encoding="utf-8", errors="ignore")
    except OSError:
        return None
    body = section_body(text, DRAFT_HEADING)
    if body is None:
        return None
    plain = _flatten(body)
    return plain or None


def _flatten(text: str) -> str:
    """주석·코드펜스 표시를 걷어내고 공백을 접은 평문. 유사도는 이것끼리 잰다."""
    stripped = strip_comments(text)
    stripped = re.sub(r"```[a-z]*", "", stripped)  # 코드펜스 울타리만 지운다
    return re.sub(r"\s+", " ", stripped).strip()


# ── Zendesk 호출 ────────────────────────────────────────────────────────────────


def _search_solved(http: Http, base: str, start: date, today: date, budget: _Budget) -> list[dict]:
    """assignee:me, 최근 WEEKS 주 안에 solved 된 티켓. id·solved 주를 쓸 만큼만 모은다.

    계획서 근거: 검색어 `assignee:me solved>… solved<…`, 페이지당 100건.
    """
    end = today + timedelta(days=1)  # 오늘 solved 도 포함
    query = f"type:ticket assignee:me solved>{start.isoformat()} solved<{end.isoformat()}"
    url = f"{base}/search.json?query={urllib.parse.quote(query)}&per_page=100"
    tickets: list[dict] = []
    pages = 0
    while url and pages < 10:  # 쿼리당 최대 1,000건 = 100 × 10 페이지
        data = _get(http, url, budget, "search")
        tickets.extend(data.get("results") or [])
        url = data.get("next_page") or ""
        pages += 1
    return tickets


def _metric_sets(http: Http, base: str, ids: list[str], budget: _Budget) -> dict[str, dict]:
    """tickets/show_many?ids=…&include=metric_sets 로 100건씩. ticket_id → metric_set."""
    by_ticket: dict[str, dict] = {}
    for i in range(0, len(ids), SHOW_MANY_BATCH):
        chunk = ids[i : i + SHOW_MANY_BATCH]
        url = (
            f"{base}/tickets/show_many.json?ids={','.join(chunk)}&include=metric_sets"
        )
        data = _get(http, url, budget, "show_many")
        for metric in data.get("metric_sets") or []:
            ticket_id = metric.get("ticket_id")
            if ticket_id is not None:
                by_ticket[str(ticket_id)] = metric
    return by_ticket


def _is_auto(ticket: dict) -> bool:
    return bool(AUTO_TAGS.intersection(ticket.get("tags") or []))


def _helped_weeks(http: Http, base: str, ids: list[str], labels: list[str], budget: _Budget) -> dict[str, int]:
    """내 검색에 안 나온 기록의 티켓 — 남의 담당이다. 해결됐고 알람이 아니면 해결된 주에 센다. 주 라벨 → 건수."""
    allowed = set(labels)
    weeks: dict[str, int] = {}
    for i in range(0, len(ids), SHOW_MANY_BATCH):
        chunk = ids[i : i + SHOW_MANY_BATCH]
        data = _get(http, f"{base}/tickets/show_many.json?ids={','.join(chunk)}&include=metric_sets", budget, "show_many")
        metrics = {str(m.get("ticket_id")): m for m in data.get("metric_sets") or []}
        for ticket in data.get("tickets") or []:
            if ticket.get("status") not in DONE_STATUSES or _is_auto(ticket):
                continue
            solved = _solved_week(metrics.get(str(ticket.get("id")), {}), ticket)
            if solved is not None and _iso_week(solved) in allowed:
                weeks[_iso_week(solved)] = weeks.get(_iso_week(solved), 0) + 1
    return weeks


def _my_user_id(http: Http, base: str, budget: _Budget) -> int | None:
    data = _get(http, f"{base}/users/me.json", budget, "me")
    user = data.get("user") or {}
    return user.get("id")


def _my_public_reply(
    http: Http, base: str, ticket_id: str, my_id: int | None, budget: _Budget
) -> str | None:
    """그 티켓에서 내가 쓴 공개 댓글을 이어 붙인 평문. 없으면 None."""
    url = f"{base}/tickets/{ticket_id}/comments.json?sort_order=asc"
    data = _get(http, url, budget, "comments")
    mine: list[str] = []
    for comment in data.get("comments") or []:
        if not comment.get("public"):
            continue
        if my_id is not None and comment.get("author_id") != my_id:
            continue
        body = comment.get("body") or ""
        if body:
            mine.append(body)
    if not mine:
        return None
    return _flatten("\n".join(mine)) or None


# ── 집계 ──────────────────────────────────────────────────────────────────────


def _blank_bucket() -> dict:
    return {"n": 0, "calendar": [], "business": []}


def _blank_week() -> dict:
    return {
        "solved": 0,
        "with_record": 0,
        "reply": {"with": _blank_bucket(), "without": _blank_bucket()},
        "resolution": {"with": _blank_bucket(), "without": _blank_bucket()},
        "requester_wait": _blank_bucket(),
        "reopened": {"with": 0, "without": 0},
    }


def _solved_week(metric: dict, ticket: dict) -> date | None:
    """해결된 주의 날짜. metric_set 의 solved_at 을 우선하고, 없으면 검색 결과를 쓴다."""
    for value in (metric.get("solved_at"), ticket.get("updated_at")):
        parsed = _parse_date(value)
        if parsed is not None:
            return parsed
    return None


def _parse_date(value: object) -> date | None:
    if not isinstance(value, str):
        return None
    match = re.match(r"^(\d{4})-(\d{2})-(\d{2})", value)
    if not match:
        return None
    try:
        return date(*(int(g) for g in match.groups()))
    except ValueError:
        return None


def _aggregate(
    tickets: list[dict],
    metrics: dict[str, dict],
    record_ids: set[str],
    labels: list[str],
) -> dict:
    """C·D 를 주별로 집계한다. 값은 전부 숫자다."""
    allowed = set(labels)

    week_entry = _blank_week

    weeks: dict[str, dict] = {}
    for ticket in tickets:
        ticket_id = str(ticket.get("id"))
        metric = metrics.get(ticket_id, {})
        solved = _solved_week(metric, ticket)
        if solved is None:
            continue
        label = _iso_week(solved)
        if label not in allowed:
            continue
        entry = weeks.setdefault(label, week_entry())
        side = "with" if ticket_id in record_ids else "without"
        entry["solved"] += 1
        if side == "with":
            entry["with_record"] += 1

        reply_cal = metric.get("reply_time_in_minutes") or {}
        _push(entry["reply"][side], reply_cal)
        resolution_cal = metric.get("full_resolution_time_in_minutes") or {}
        _push(entry["resolution"][side], resolution_cal)
        # 고객이 우리를 기다린 시간(new·open·on-hold 합, pending 은 빠진다). 기록 유무로 가르지 않는다 —
        # 깊게 본 티켓에만 기록이 있어 두 묶음을 견주면 tiket 이 느리게 보인다(2026-10-07).
        _push(entry["requester_wait"], metric.get("requester_wait_time_in_minutes") or {})
        if metric.get("reopens"):
            entry["reopened"][side] += 1

    return {label: _finalize_week(weeks[label]) for label in weeks}


def _push(bucket: dict, timings: dict) -> None:
    calendar = timings.get("calendar")
    business = timings.get("business")
    if isinstance(calendar, (int, float)):
        bucket["calendar"].append(calendar)
    if isinstance(business, (int, float)):
        bucket["business"].append(business)
    if isinstance(calendar, (int, float)) or isinstance(business, (int, float)):
        bucket["n"] += 1


def _finalize_bucket(bucket: dict) -> dict:
    """중앙값과 함께 합계·건수를 낸다 — MTTA·MTTR 은 평균이라 사람별 합계를 더해야 팀 값이 정확하다
    (development/plans/2026-10-21-mttx-metrics.md). 달력·근무시간은 따로 센다 — 한쪽만 있는 티켓이 있다."""
    calendar = _median(bucket["calendar"])
    business = _median(bucket["business"])
    return {
        "n": bucket["n"],
        "calendar": None if calendar is None else int(round(calendar)),
        "business": None if business is None else int(round(business)),
        "calendar_sum": int(round(sum(bucket["calendar"]))),
        "calendar_n": len(bucket["calendar"]),
        "business_sum": int(round(sum(bucket["business"]))),
        "business_n": len(bucket["business"]),
    }


def _finalize_week(entry: dict) -> dict:
    return {
        "solved": entry["solved"],
        "with_record": entry["with_record"],
        "helped_with_record": 0,
        "auto_excluded": 0,
        "reply_minutes": {
            "with": _finalize_bucket(entry["reply"]["with"]),
            "without": _finalize_bucket(entry["reply"]["without"]),
        },
        "resolution_minutes": {
            "with": _finalize_bucket(entry["resolution"]["with"]),
            "without": _finalize_bucket(entry["resolution"]["without"]),
        },
        "requester_wait_minutes": _finalize_bucket(entry["requester_wait"]),
        "reopened": entry["reopened"],
    }


def _similarity_bucket(ratio: float) -> str:
    """계획서 구간: high ≥ 0.9, mid 0.6~0.9, low < 0.6. 경계가 섞이기 쉬워 따로 뺀다 —
    정확히 0.9 는 high, 정확히 0.6 은 mid (조율자 검토 1차)."""
    if ratio >= SIMILARITY_HIGH:
        return "high"
    if ratio >= SIMILARITY_MID:
        return "mid"
    return "low"


def _draft_similarity(
    http: Http,
    base: str,
    tickets: list[dict],
    metrics: dict[str, dict],
    record_ids: set[str],
    labels: list[str],
    root: Path,
    my_id: int | None,
    budget: _Budget,
) -> dict:
    """B. 기록이 있는 티켓만, `## 답변 초안` 과 내 공개 답변을 비교해 주별 분포.

    도중에 예산이 바닥나면 그때까지 것만 낸다 — C·D 는 이미 다 계산됐으므로 B 만 비는 게
    사용 지표 전체를 timeout 으로 버리는 것보다 낫다 (조율자 검토 1차).
    """
    allowed = set(labels)
    by_week: dict[str, list[float]] = {}
    for ticket in tickets:
        if budget.expired():
            break
        ticket_id = str(ticket.get("id"))
        if ticket_id not in record_ids:
            continue
        solved = _solved_week(metrics.get(ticket_id, {}), ticket)
        if solved is None:
            continue
        label = _iso_week(solved)
        if label not in allowed:
            continue
        draft = _draft_of(root, ticket_id)
        if not draft:
            continue
        reply = _my_public_reply(http, base, ticket_id, my_id, budget)
        if not reply:
            continue
        ratio = difflib.SequenceMatcher(None, draft, reply).ratio()
        by_week.setdefault(label, []).append(ratio)

    result: dict = {}
    for label, ratios in by_week.items():
        median = _median(ratios)
        buckets = [_similarity_bucket(r) for r in ratios]
        result[label] = {
            "n": len(ratios),
            "median": None if median is None else round(median, 2),
            "high": buckets.count("high"),
            "mid": buckets.count("mid"),
            "low": buckets.count("low"),
        }
    return result


# ── 진입점 ──────────────────────────────────────────────────────────────────────


def _compute(root: Path, today: date, http: Http, base: str, budget: _Budget) -> dict:
    start, labels = _week_window(today)
    record_ids = _record_ids(root)

    found = _search_solved(http, base, start, today, budget)
    tickets = [t for t in found if not _is_auto(t)]
    ids = [str(t.get("id")) for t in tickets if t.get("id") is not None]
    metrics = _metric_sets(http, base, ids, budget) if ids else {}
    weeks = _aggregate(tickets, metrics, record_ids, labels)

    auto = [t for t in found if _is_auto(t)]
    for ticket in auto:
        solved = _solved_week({}, ticket)
        if solved is not None and _iso_week(solved) in labels:
            weeks.setdefault(_iso_week(solved), _finalize_week(_blank_week()))["auto_excluded"] += 1
    mine = {str(t.get("id")) for t in found}
    others = sorted(record_ids - mine)
    for label, count in (_helped_weeks(http, base, others, labels, budget) if others else {}).items():
        weeks.setdefault(label, _finalize_week(_blank_week()))["helped_with_record"] += count

    # C·D 는 여기서 끝난다. 아래 B 는 티켓마다 댓글을 더 읽는데, 거기서 막혀도 이것은 버리지 않는다 (2026-10-07).
    result = {
        "computed_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "weeks": weeks,
        "draft_similarity": {},
    }
    try:
        my_id = _my_user_id(http, base, budget)
        if my_id is None:
            # 내 id 를 모르면 고객이 쓴 공개 댓글까지 내 답변으로 비교하게 된다 — 재지 않는다.
            raise _ZendeskError("parse", "me")
        result["draft_similarity"] = _draft_similarity(
            http, base, tickets, metrics, record_ids, labels, root, my_id, budget
        )
    except _ZendeskError as exc:
        result.update(exc.as_payload("similarity_error"))
    return result


def _read_cache(today: date) -> dict | None:
    """같은 UTC 날짜에 계산한 캐시가 있으면 그 payload. 아니면 None."""
    try:
        raw = json.loads(CACHE.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None
    if not isinstance(raw, dict):
        return None
    if raw.get("date") != today.isoformat() or raw.get("shape") != CACHE_SHAPE:
        return None
    payload = raw.get("payload")
    return payload if isinstance(payload, dict) else None


def _write_cache(today: date, payload: dict) -> None:
    try:
        CACHE.parent.mkdir(parents=True, exist_ok=True)
        CACHE.write_text(
            json.dumps({"date": today.isoformat(), "shape": CACHE_SHAPE, "payload": payload}, ensure_ascii=False),
            encoding="utf-8",
        )
    except OSError:
        pass


def collect_zendesk(
    root: Path = ROOT,
    today: date | None = None,
    http: Http | None = None,
    clock: Callable[[], float] = time.monotonic,
) -> dict:
    """B·C·D 를 하나의 dict 로. 하루 한 번만 계산하고 나머지는 캐시에서 돌려준다.

    실패는 `{"error": code, "stage": 어느 호출}` 로만 나간다. 예외를 밖으로 던지지 않고, 아무것도 출력하지 않는다.
    B 만 실패하면 C·D 는 그대로 내고 `similarity_error`·`stage` 를 붙인다.
    **오류가 든 결과는 캐시하지 않는다** (2026-10-07 유지보수자) — 계정 한도에 한 번 걸린 429 가 그날 치로 캐시돼
    하루가 통째로 비었다. 다음 전송(6시간 뒤) 때 다시 계산한다.
    """
    today = today or datetime.now(timezone.utc).date()
    try:
        cached = _read_cache(today)
        if cached is not None:
            return cached

        if http is None:
            credentials = _load_credentials()
            if credentials is None:
                return {"error": "no_credentials"}
            http = _default_http(credentials)
            base = credentials.base
        else:
            # 테스트·호출자가 http 를 끼운 경우. base 는 자격증명이 있으면 그 호스트,
            # 없으면 더미. http 가 전체 URL 을 받으므로 라우팅은 http 쪽 책임이다.
            credentials = _load_credentials()
            base = credentials.base if credentials else "https://example.zendesk.com/api/v2"

        budget = _Budget(TOTAL_TIMEOUT_SECONDS, clock)
        payload = _compute(root, today, http, base, budget)
    except _ZendeskError as exc:
        return exc.as_payload()
    except Exception:  # noqa: BLE001 — 세션 지표는 부수적인 일이다. 밖으로 던지지 않는다.
        return {"error": "parse"}

    if "similarity_error" not in payload:
        _write_cache(today, payload)
    return payload


def _render(payload: dict) -> str:
    stage = f" · {payload['stage']} 호출에서" if payload.get("stage") else ""
    if "error" in payload:
        return f"zendesk: {payload['error']}{stage} (값을 지어내지 않는다)"
    lines = [f"computed_at  {payload.get('computed_at', '-')}", "", "주별 (C·D)"]
    weeks = payload.get("weeks", {})
    for label in sorted(weeks):
        w = weeks[label]
        lines.append(
            f"  {label}  solved {w['solved']} · 기록 {w['with_record']} · 도운 기록 {w['helped_with_record']}"
            f" · 알람·보고서 제외 {w['auto_excluded']}"
            f" · reply(with/without n) {w['reply_minutes']['with']['n']}/{w['reply_minutes']['without']['n']}"
            f" · reopened {w['reopened']['with']}/{w['reopened']['without']}"
            f" · 고객 대기(영업시간 중앙값) {w['requester_wait_minutes']['business']}분 n{w['requester_wait_minutes']['n']}"
        )
    lines += ["", "유사도 (B)"]
    similarity = payload.get("draft_similarity", {})
    for label in sorted(similarity):
        s = similarity[label]
        lines.append(
            f"  {label}  n {s['n']} · median {s['median']}"
            f" · high {s['high']} / mid {s['mid']} / low {s['low']}"
        )
    if "similarity_error" in payload:
        lines.append(f"  못 읽었다: {payload['similarity_error']}{stage} — 다음 전송 때 다시 잰다")
    elif not similarity:
        lines.append("  (비교할 초안·답변 쌍 없음)")
    return "\n".join(lines)


def main() -> int:
    """미리 보기. 사람이 이 명령을 칠 때만 실제 Zendesk 를 부른다. 보내지 않는다."""
    payload = collect_zendesk()
    print(_render(payload))
    return 0


if __name__ == "__main__":
    sys.exit(main())
