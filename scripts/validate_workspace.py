#!/usr/bin/env python3
"""Validate the customer-support workspace structure and safety invariants."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
import unicodedata
from datetime import date, timedelta
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
HOOKS_DIR = ".githooks"
# Raw company sources keep the filenames they arrive with. They are never tracked
# and the validator compares them through NFC normalization.
ASCII_PATH_EXEMPT_PREFIXES = ("policy/inbox/",)
# Guard flags that must stay on the AWS MCP proxy command line. --read-only drops
# every tool not annotated readOnlyHint=true; --skip-auth keeps the docs-only
# connection from presenting an AWS credential.
MCP_REQUIRED_PROXY_FLAGS = ("--read-only", "--skip-auth")
# Tools that would bypass the broker-mediated read-only customer boundary.
MCP_FORBIDDEN_TOOLS = (
    "aws___call_aws",
    "aws___run_script",
    "aws___get_presigned_url",
)

REQUIRED_FILES = [
    "CLAUDE.md",
    "AGENTS.md",
    "README.md",
    ".gitignore",
    ".githooks/pre-push",
    ".kiro/steering/00-repository-rules.md",
    ".kiro/settings/mcp.json",
    ".mcp.json",
    ".claude/settings.json",
    ".codex/config.toml",
    "agents/environment/mcp-manifest.json",
    "agents/capability-catalog.md",
    "agents/install-verification.md",
    "agents/compatibility.md",
    "agents/runtime-status.md",
    "agents/task-router.md",
    "customers/_index.md",
    "scripts/check_public_sources.py",
    "scripts/export_framework_snapshot.py",
    "scripts/render_agent_configs.py",
    "scripts/test_aws_customer_skill.py",
    "scripts/test_export_framework_snapshot.py",
    "scripts/test_validate_workspace.py",
    "scripts/verify_mcp_servers.py",
    "policy/README.md",
    "policy/_routing.md",
    "policy/cards/_template.md",
    "policy/source-inventory.md",
    "policy/sources.json",
    "policy/inbox/README.md",
    "policy/pending-review.md",
    "playbooks/evidence-verification.md",
    "playbooks/reply-templates.md",
    "playbooks/infra-change-process.md",
    "pitfalls/README.md",
    "templates/pitfall.md",
    "templates/customer-index.md",
]

CANONICAL_MARKERS = [
    "Draft only. Never send email",
    # 2026-09-11: 경계의 "...runtime-status.md first" 가 번호 절차보다 위에 있어
    # 시작점이 두 개였다. 에이전트는 4번만 하고 1~3번을 건너뛰었다. 아래 두 문장이
    # 시작점을 하나로 고정한다.
    "none of them is a first step",
    "Produce the routed output before yielding",
    # 2026-09-18: 1·2단계가 "For a ticket" 조건절로 시작해서, 티켓 번호 없이 온 고객 건에는
    # 계약서가 아무것도 지시하지 않았다. 한 에이전트가 그래서 기록을 만들지 않았고, 그건
    # 규칙 위반이 아니라 규칙대로 한 것이었다. 조건을 지운 문장을 고정한다.
    "whether or not it arrived as a ticket",
    "Never call customer-account write APIs",
    "Customer-account access is read-only and broker-mediated only",
    "Never print or commit credentials",
    "Commit only de-identified customer context",
    "Customer-facing cost figures must be billing-platform-curated",
    "Exa queries must contain public, de-identified technical terms only",
    "agents/task-router.md",
    "policy/_routing.md",
    "agents/capability-catalog.md",
    "confirmed`, `hypothesis`, and `unknown",
    "appending dated corrections",
    "never subjective judgment",
    "Do not commit, push, merge",
]

TASK_ROUTER_MARKERS = [
    "Never load every policy, playbook, ticket, or skill by default",
    # 2026-09-11: 라우터가 infra-change-process.md:18 의 규칙을 "Stop at the human
    # approval boundary" 로만 줄여 담고 있었다. 산출물 제공 의무가 빠진 절반만
    # 진입점에 있으면, 에이전트는 아무것도 만들지 않고 멈추는 것을 준수로 읽는다.
    # 삭제가 아니라 *요약*으로 사라진 사례이므로 문장 자체를 고정한다.
    "after** delivering the artifact and evidence",
    "Classification is not the deliverable",
    # 같은 날: 라우터가 "Customer ticket:" 으로 조건을 걸어 두어, 컴플라이언스 문의가
    # 스코프 밖으로 판단됐다. 실제로는 ISMS 건 3개가 이미 티켓으로 처리돼 있었다.
    "ticket or not",
    "Scope is the customer, not the subject",
    "`quick`",
    "`standard`",
    "`high-risk`",
    "Load a local skill only when its trigger directly matches",
    # 0001 에서 Decision Packet / Reply Brief 를 폐기하고 대체한 것들
    "playbooks/ticket-outputs.md",
    "발송 전 점검",
    "Reuse confirmed evidence",
]



# 0041: 회신 양식은 팀 템플릿이다. 유형 제목과 이 저장소의 덧붙임(비용·번호 절차·회신 유형 기록)이 빠지면 안 된다.
REPLY_TEMPLATE_MARKERS = [
    "## 01. 확인 질문 답변",
    "## 02. 즉시 확답이 어려울 때",
    "## 08. 앞선 답변 정정",
    "## 11. 종료 안내",
    "`회신 유형:`",
    "**번호 절차**",
    "빌링 플랫폼 정제값만",
]

ROUTED_MODULE_MARKERS = {
    "policy/_routing.md": ["A `draft` card is a cited review artifact"],
    "playbooks/evidence-verification.md": [
        "confirmed",
        "hypothesis",
        "unknown",
        "Treat the reply as a draft until a human reviews and sends it",
    ],
    "playbooks/reply-templates.md": [
        "Only a human sends email or posts to Zendesk",
        "문장 모양이 아니라 의미를 검증한다",
        "Every definitive statement is supported by a `[확인]` item that carries a source",
        # 0012: 발송 전 관문으로 가는 연결. 끊기면 관문이 고아가 된다.
        "## 발송 전 점검",
        "고객이 문의에서 밝힌 제약 안에서 실행 가능한 답을 준다",
        "고객이 실제로 보는 언어의 UI 명칭을 쓴다",
    ],
    "playbooks/infra-change-process.md": ["Stop at the human gate", "Design rollback first"],
}

ALWAYS_ON_CHAR_BUDGETS = {
    "CLAUDE.md": 4_500,
    "AGENTS.md": 1_800,
    ".kiro/steering/00-repository-rules.md": 1_800,
}
AGENTS_CLAUDE_COMBINED_CHAR_BUDGET = 6_000

# 0013: 아래 안전 문장이 세 진입점에서 조용히 사라진 적이 있다. CLAUDE.md 만 검사가 있어
# AGENTS.md 와 Kiro steering 의 삭제는 발견되지 않았다. 셋 다 고정한다.
ENTRYPOINT_SAFETY_MARKERS = [
    "Never call customer-account write APIs",
    "never send",
]

ENTRYPOINT_MARKERS = {
    "AGENTS.md": [
        "CLAUDE.md", "agents/task-router.md", "billing platform", "policy/_routing.md",
        "agents/runtime-status.md", "scripts/fetch-ticket.sh",
        *ENTRYPOINT_SAFETY_MARKERS,
    ],
    ".kiro/steering/00-repository-rules.md": [
        "CLAUDE.md",
        "agents/task-router.md",
        "billing platform",
        "policy/_routing.md",
        "agents/runtime-status.md",
        "scripts/fetch-ticket.sh",
        *ENTRYPOINT_SAFETY_MARKERS,
    ],
}

FRONTMATTER_FILES = [
    "policy/cards/_template.md",
    "templates/pitfall.md",
]

# 검증된 값 자리에 들어가면 "안 봤다"와 구분되지 않는 값. 규칙·사례 카드가 같이 쓴다.
PLACEHOLDER_VALUES = {"unknown", "tbd", "yyyy-mm-dd", "n/a", "na", "none", "없음", "모름", "미상", "미확인"}

# 규칙 카드 — 0028. 규칙 내용은 영원할 수 있어도 "원문의 이 버전이 아직 유효하다"는 주장은 낡는다.
# review_by 는 원문 성격에 맞춰 카드마다 정하되 reviewed_at 에서 1년을 넘지 못한다.
# 영원히 갈 규칙은 카드가 아니라 CLAUDE.md 의 Absolute boundaries 로 올린다.
POLICY_REVIEW_MAX_DAYS = 365
POLICY_SECTIONS = [
    "## Control statement",
    "## Scope",
    "## Required behavior",
    "## Prohibited behavior",
    "## Exceptions and escalation",
    "## Evidence",
    "## Change history",
]
POLICY_REQUIRED_AUTHORITY_FIELDS = [
    "source_owner",
    "source_version",
    "applicability",
    "authority_verified_at",
    "approved_by",
    "approved_at",
]
# 과거 기록이라 오늘 이후일 수 없는 날짜. 뒤 둘은 "2026-08-26 10:05 KST" 처럼 시각이 붙는다
POLICY_RECORD_DATE_FIELDS = ("reviewed_at", "authority_verified_at", "approved_at")
LEADING_DATE = re.compile(r"(\d{4}-\d{2}-\d{2})(?:\s|$)")

# 사례(pitfalls/) 양식 — templates/pitfall.md, 0027. 이미 일어난 사건의 기록(ticket)은 낡지 않고,
# 세상에 대한 주장은 누가 전했든 낡는다. 낡는 출처가 있으면 review_by 를 강제하고, 그 기한은
# 가장 오래된 출처 조회일에서 PITFALL_REVIEW_MAX_DAYS 를 넘지 못한다 — 문서를 다시 열지 않고 기한만 미는 길을 막는다.
PITFALL_REVIEW_MAX_DAYS = 180
PITFALL_URL_KINDS = {"aws-doc", "aws-repost", "vendor-doc"}
PITFALL_SOURCE_KINDS = PITFALL_URL_KINDS | {
    "aws-api", "aws-managed-policy", "aws-support", "billing-api", "billing-portal",
    "account-observation", "poc", "internal-share", "ticket",
}
PITFALL_NON_AGING_KINDS = {"ticket"}
PITFALL_SECTIONS = [
    "## 무엇을 하면 틀리는가",
    "## 실제로 있었던 일",
    "## 확인된 사실",
    "## 해야 할 것",
    "## 다시 쓰기 전에 확인할 것",
    "## 변경 이력",
]
ISO_DATE = re.compile(r"\d{4}-\d{2}-\d{2}")
# 관측 식별자는 ASCII 토큰 하나 — 고객명이 끼어들 자리를 두지 않는다
PITFALL_OBSERVED = re.compile(r"(\S+) \| (?:ticket|share) [A-Za-z0-9#._/-]+")
PITFALL_SOURCE = re.compile(r"(\S+) \| ([a-z-]+) \| (\S.*?) \| (\S.*)")
BODY_URL = re.compile(r"https?://[^\s)`>\]]+")

SECRET_PATTERNS = {
    "AWS access key": re.compile(r"\bAKIA[0-9A-Z]{16}\b"),
    "GitHub token": re.compile(r"\bgh[pousr]_[A-Za-z0-9]{20,}\b"),
    "OpenAI-style key": re.compile(r"\bsk-[A-Za-z0-9_-]{20,}\b"),
    "private key block": re.compile(r"-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----"),
}

ACCOUNT_LIKE = "12-digit account-like value"
TEXT_SUFFIXES = {".md", ".py", ".json", ".yaml", ".yml", ".toml", ".txt"}
POLICY_STATUSES = {"draft", "active", "superseded", "retired"}
TRACKED_POLICY_PII_PATTERNS = {
    "email address": re.compile(r"\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b"),
    "Korean mobile number": re.compile(r"\b01[016789]-\d{3,4}-\d{4}\b"),
    ACCOUNT_LIKE: re.compile(r"(?<!\d)\d{12}(?!\d)"),
}
TRACKED_CUSTOMER_IDENTIFIER_PATTERNS = {
    "email address": re.compile(r"\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b"),
    "phone number": re.compile(r"\b0\d{1,2}-\d{3,4}-\d{4}\b"),
    "IPv4 address": re.compile(
        r"(?<!\d)(?:25[0-5]|2[0-4]\d|1?\d?\d)(?:\.(?:25[0-5]|2[0-4]\d|1?\d?\d)){3}(?:/\d{1,2})?(?!\d)"
    ),
    ACCOUNT_LIKE: re.compile(r"(?<![A-Za-z0-9])\d{12}(?![A-Za-z0-9])"),
}
# MSP 회사 자체 계정 — 인터널(브로커) 계정, 메인 Payer 계정, 빌링 플랫폼 계정. 쓰는 사람이 모두 알아야 해서 추적 파일에
# 적어도 된다(2026-10-22 유지보수자, POLICY-ACCESS-002). 계정 번호만으로는 아무것도 할 수 없다. 고객 계정은 그대로 막는다.
MSP_OWN_ACCOUNT_IDS = frozenset({"444455556666", "111122223333", "777788889999"})


def has_foreign_account_id(pattern: re.Pattern[str], content: str) -> bool:
    return any(match.group(0) not in MSP_OWN_ACCOUNT_IDS for match in pattern.finditer(content))


EXAMPLE_PERSONAL_SIGNATURE_PATTERN = re.compile(
    r"(?m)^(?!\[작성자 소개\]$)[가-힣A-Za-z0-9().&-]{2,30}\s+[가-힣]{2,4}입니다\.?$"
)
DEIDENTIFICATION_SCAN_EXCLUSIONS = {
    "policy/sources.json",
    "policy/source-inventory.md",
}


def fail(errors: list[str], message: str) -> None:
    errors.append(message)


def validate_markdown_sources(relative: str, content: str, errors: list[str]) -> None:
    body, separator, sources = content.partition("## Sources")
    cited = {int(value) for value in re.findall(r"\[(\d+)\]", body)}
    listed_values = [
        int(value)
        for value in re.findall(r"^\[(\d+)\]\s+https?://", sources, re.MULTILINE)
    ]
    listed = set(listed_values)
    if cited and not separator:
        fail(errors, f"{relative} cites sources but has no Sources block")
    if len(listed_values) != len(listed):
        fail(errors, f"{relative} has duplicate source IDs")
    if cited - listed:
        fail(errors, f"{relative} has citations missing from Sources: {sorted(cited - listed)}")
    if listed - cited:
        fail(errors, f"{relative} has unused Sources: {sorted(listed - cited)}")


def read_text(relative: str, errors: list[str]) -> str:
    path = ROOT / relative
    if not path.is_file():
        fail(errors, f"missing required file: {relative}")
        return ""
    try:
        return path.read_text(encoding="utf-8")
    except UnicodeDecodeError:
        fail(errors, f"required text file is not UTF-8: {relative}")
        return ""


def gitignored_relatives(candidates: list[Path]) -> set[str]:
    """git 이 무시하는 경로들. 판단은 git 에게 맡긴다.

    무시되는 파일은 공용 저장소에 도달할 수 없으므로 유출 스캔의 대상이 아니다.
    디렉터리 이름을 하드코딩하면(`.private` 처럼) 다음에 추가되는 로컬 전용 경로마다
    같은 오탐이 반복된다 — `tickets/` 가 정확히 그렇게 걸렸다.

    git 을 못 쓰면 빈 집합을 돌려주어 전부 스캔한다(fail closed). 스캔 범위가 넓어
    오탐이 날지언정, 봐야 할 파일을 조용히 건너뛰지는 않는다.
    """
    if not (ROOT / ".git").exists() or not candidates:
        return set()
    relatives = [str(path.relative_to(ROOT)) for path in candidates]
    result = subprocess.run(
        ["git", "check-ignore", "-z", "--stdin"],
        cwd=ROOT,
        input="\0".join(relatives),
        capture_output=True,
        text=True,
        check=False,
    )
    # 0 = 일부가 무시됨, 1 = 무시되는 것 없음. 그 외는 git 쪽 문제이므로 전부 스캔한다.
    if result.returncode not in (0, 1):
        return set()
    # -z: 입출력을 NUL 로 구분한다. 기본값(core.quotePath=true)이면 한글 경로가
    # 8진수 이스케이프와 따옴표로 싸여 돌아와 입력과 비교가 어긋나지만, -z 는 경로를
    # 날바이트 그대로 돌려주어 공백·따옴표·개행이 든 경로까지 안전하다.
    return {entry for entry in result.stdout.split("\0") if entry}


def iter_text_files() -> list[Path]:
    candidates: list[Path] = []
    for path in ROOT.rglob("*"):
        if not path.is_file() or path.suffix.lower() not in TEXT_SUFFIXES:
            continue
        if ".git" in path.relative_to(ROOT).parts:
            continue
        candidates.append(path)
    ignored = gitignored_relatives(candidates)
    return [path for path in candidates if str(path.relative_to(ROOT)) not in ignored]


def frontmatter_value(frontmatter: str, key: str) -> str:
    """`key: value` 의 값. 빈 값이 다음 줄을 먹지 않게 줄 안에서만 본다."""
    match = re.search(rf"^{key}:[ \t]*([^#\n]*)", frontmatter, re.MULTILINE)
    return match.group(1).strip().strip('"\'') if match else ""


def is_placeholder(value: str) -> bool:
    return not re.search(r"\w", value) or value.lower() in PLACEHOLDER_VALUES


def markdown_sections(body: str) -> tuple[str, dict[str, str]]:
    """주석을 뺀 본문과 `## 제목` → 내용."""
    visible = re.sub(r"<!--.*?-->", "", body, flags=re.DOTALL)
    parts = re.split(r"^(## .+?)[ \t]*$", visible, flags=re.MULTILINE)
    return visible, {parts[i]: parts[i + 1] for i in range(1, len(parts) - 1, 2)}


def check_sections(sections: dict[str, str], required: list[str], label: str, relative: str, errors: list[str]) -> None:
    for section in required:
        if section not in sections:
            fail(errors, f"{label} missing section: {section}: {relative}")
        elif not sections[section].strip():
            fail(errors, f"{label} section is empty: {section}: {relative}")


def frontmatter_list(frontmatter: str, key: str) -> list[str]:
    """`key:` 아래 `  - ` 항목들. 주석 줄은 건너뛴다."""
    match = re.search(rf"^{key}:[ \t]*\n((?:[ \t]+-.*\n?|[ \t]*#.*\n?)*)", frontmatter + "\n", re.MULTILINE)
    if not match:
        return []
    return [line.strip()[1:].strip() for line in match.group(1).splitlines() if line.strip().startswith("-")]


def strict_date(text: str) -> date | None:
    """YYYY-MM-DD 이고 달력에 있는 날짜만. fromisoformat 은 20260930 도 받는다."""
    if not ISO_DATE.fullmatch(text):
        return None
    try:
        return date.fromisoformat(text)
    except ValueError:
        return None


def normalize_url(url: str) -> str:
    return url.split("#", 1)[0].rstrip(".,;:")


def validate_pitfall_sources(frontmatter: str, relative: str, errors: list[str]) -> tuple[list[date], set[str]]:
    """관측·출처 줄을 검사하고 (낡는 출처 조회일, 출처 URL) 을 돌려준다."""
    today = date.today()
    observed = frontmatter_list(frontmatter, "observed")
    if not observed:
        fail(errors, f"pitfall card has no observed entry: {relative}")
    dated: list[date | None] = []
    for entry in observed:
        match = PITFALL_OBSERVED.fullmatch(entry)
        if not match or not strict_date(match.group(1)):
            fail(errors, f"pitfall observed entry is malformed (YYYY-MM-DD | ticket|share <id>): {relative}")
            continue
        dated.append(strict_date(match.group(1)))

    sources = frontmatter_list(frontmatter, "sources")
    if not sources:
        fail(errors, f"pitfall card has no source: {relative}")
    aging: list[date] = []
    urls: set[str] = set()
    for entry in sources:
        match = PITFALL_SOURCE.fullmatch(entry)
        checked = strict_date(match.group(1)) if match else None
        if not match or not checked or match.group(2) not in PITFALL_SOURCE_KINDS:
            fail(errors, f"pitfall source is malformed (YYYY-MM-DD | kind | location | version): {relative}")
            continue
        kind, location, version = match.group(2), match.group(3), match.group(4).strip()
        if is_placeholder(version):
            fail(errors, f"pitfall source version is a placeholder (write 표기 없음 if none): {relative}")
        if kind in PITFALL_URL_KINDS and not location.startswith("https://"):
            fail(errors, f"pitfall web source location is not an https URL: {relative}")
        if location.startswith(("https://", "http://")):
            urls.add(normalize_url(location))
        if kind not in PITFALL_NON_AGING_KINDS:
            aging.append(checked)
        dated.append(checked)
    if any(value and value > today for value in dated):
        fail(errors, f"pitfall date is in the future: {relative}")
    return aging, urls


def validate_pitfall_review(frontmatter: str, aging: list[date], relative: str, errors: list[str]) -> None:
    review = re.search(r"^review_by:[ \t]*(\S*)", frontmatter, re.MULTILINE)
    if not review:
        if aging:
            fail(errors, f"pitfall card with aging sources has no review_by: {relative}")
        return
    review_date = strict_date(review.group(1))
    if not review_date:
        fail(errors, f"pitfall card has invalid review_by: {relative}")
        return
    if review_date < date.today():
        fail(errors, f"pitfall review date has passed: {relative}")
    if aging and review_date > min(aging) + timedelta(days=PITFALL_REVIEW_MAX_DAYS):
        fail(errors, f"pitfall review_by is more than {PITFALL_REVIEW_MAX_DAYS} days after its oldest source check: {relative}")


def validate_pitfall_body(body: str, source_urls: set[str], relative: str, errors: list[str]) -> None:
    visible, sections = markdown_sections(body)
    if not re.search(r"^# \S", visible, re.MULTILINE):
        fail(errors, f"pitfall card has no # title line: {relative}")
    check_sections(sections, PITFALL_SECTIONS, "pitfall card", relative, errors)
    if "## 변경 이력" in sections and not re.search(r"^- \d{4}-\d{2}-\d{2}:", sections["## 변경 이력"], re.MULTILINE):
        fail(errors, f"pitfall change log has no dated entry: {relative}")
    for url in sorted({normalize_url(url) for url in BODY_URL.findall(visible)} - source_urls):
        fail(errors, f"pitfall body cites a URL missing from sources: {url}: {relative}")


def validate_pitfall_cards(errors: list[str]) -> int:
    cards = sorted(path for path in (ROOT / "pitfalls").glob("*.md") if path.name != "README.md")
    for card in cards:
        relative = str(card.relative_to(ROOT))
        content = card.read_text(encoding="utf-8")
        frontmatter_match = re.match(r"^---\n(.*?)\n---\n", content, re.DOTALL)
        if not frontmatter_match:
            fail(errors, f"pitfall card has no frontmatter: {relative}")
            continue
        frontmatter = frontmatter_match.group(1)
        aging, source_urls = validate_pitfall_sources(frontmatter, relative, errors)
        validate_pitfall_review(frontmatter, aging, relative, errors)
        validate_pitfall_body(content[frontmatter_match.end():], source_urls, relative, errors)
    return len(cards)


def validate_active_policy_dates(frontmatter: str, relative: str, errors: list[str]) -> None:
    today = date.today()
    reviewed = strict_date(frontmatter_value(frontmatter, "reviewed_at"))
    if not reviewed:
        fail(errors, f"active policy card has invalid reviewed_at: {relative}")
    for field in POLICY_RECORD_DATE_FIELDS[1:]:
        match = LEADING_DATE.match(frontmatter_value(frontmatter, field))
        if not match or not strict_date(match.group(1)):
            fail(errors, f"active policy card {field} does not start with a date: {relative}")
    for field in POLICY_RECORD_DATE_FIELDS:
        match = LEADING_DATE.match(frontmatter_value(frontmatter, field))
        recorded = strict_date(match.group(1)) if match else None
        if recorded and recorded > today:
            fail(errors, f"active policy card date is in the future: {field}: {relative}")
    effective = frontmatter_value(frontmatter, "effective_from")
    if effective and not strict_date(effective):
        fail(errors, f"active policy card has invalid effective_from: {relative}")
    review = strict_date(frontmatter_value(frontmatter, "review_by"))
    if not review:
        fail(errors, f"active policy card has invalid review_by: {relative}")
        return
    if review < today:
        fail(errors, f"active policy card review date has passed: {relative}")
    if reviewed and review > reviewed + timedelta(days=POLICY_REVIEW_MAX_DAYS):
        fail(errors, f"active policy card review_by is more than {POLICY_REVIEW_MAX_DAYS} days after reviewed_at: {relative}")


def validate_active_policy_card(
    frontmatter: str,
    body: str,
    routing_row: str,
    policy_id: str,
    known_sources: set[str],
    relative: str,
    errors: list[str],
) -> None:
    for field in POLICY_REQUIRED_AUTHORITY_FIELDS:
        if is_placeholder(frontmatter_value(frontmatter, field)):
            fail(errors, f"active policy card missing verified {field}: {relative}")
    if frontmatter_value(frontmatter, "source_document") not in known_sources:
        fail(errors, f"active policy card source_document is not a registered source: {relative}")
    if frontmatter_value(frontmatter, "activation_blocker"):
        fail(errors, f"active policy card still has activation_blocker: {relative}")
    validate_active_policy_dates(frontmatter, relative, errors)

    _, sections = markdown_sections(body)
    check_sections(sections, POLICY_SECTIONS, "active policy card", relative, errors)
    history = sections.get("## Change history", "")
    if history.strip() and not re.search(r"^- \d{4}-\d{2}-\d{2}\b", history, re.MULTILINE):
        fail(errors, f"active policy card change history has no dated entry: {relative}")

    # 라우팅 표: | id | title | status | applies | triggers | effective | review | card |
    cells = [cell.strip() for cell in routing_row.strip().strip("|").split("|")]
    if len(cells) >= 7:
        if cells[5] != frontmatter_value(frontmatter, "effective_from"):
            fail(errors, f"routing effective_from differs from card: {policy_id}")
        if cells[6] != frontmatter_value(frontmatter, "review_by"):
            fail(errors, f"routing review_by differs from card: {policy_id}")


def validate_policy_cards(errors: list[str]) -> tuple[int, int]:
    inventory = read_text("policy/source-inventory.md", errors)
    routing = read_text("policy/_routing.md", errors)
    manifest_content = read_text("policy/sources.json", errors)
    try:
        manifest = json.loads(manifest_content)
    except json.JSONDecodeError as exc:
        fail(errors, f"invalid policy/sources.json: {exc}")
        manifest = {"sources": []}
    source_entries = manifest.get("sources", [])
    sources_by_id = {entry.get("id"): entry for entry in source_entries if entry.get("id")}
    if len(sources_by_id) != len(source_entries):
        fail(errors, "duplicate or missing source id in policy/sources.json")
    known_sources = set(sources_by_id)
    inventory_sources = set(re.findall(r"`(SRC-[A-Z0-9-]+)`", inventory))
    if inventory_sources != known_sources:
        missing_from_inventory = sorted(known_sources - inventory_sources)
        missing_from_manifest = sorted(inventory_sources - known_sources)
        if missing_from_inventory:
            fail(errors, f"source missing from inventory: {', '.join(missing_from_inventory)}")
        if missing_from_manifest:
            fail(errors, f"source missing from manifest: {', '.join(missing_from_manifest)}")
    seen_ids: dict[str, str] = {}
    superseded: list[tuple[str, str]] = []
    cards = sorted((ROOT / "policy/cards").glob("*.md"))
    cards = [card for card in cards if card.name != "_template.md"]

    for card in cards:
        relative = str(card.relative_to(ROOT))
        content = card.read_text(encoding="utf-8")
        frontmatter_match = re.match(r"^---\n(.*?)\n---\n", content, re.DOTALL)
        if not frontmatter_match:
            fail(errors, f"invalid policy card frontmatter: {relative}")
            continue
        frontmatter = frontmatter_match.group(1)
        id_match = re.search(r"^id:\s*([^#\n]+)", frontmatter, re.MULTILINE)
        status_match = re.search(r"^status:\s*([^#\s]+)", frontmatter, re.MULTILINE)
        if not id_match:
            fail(errors, f"policy card missing id: {relative}")
        else:
            policy_id = id_match.group(1).strip().strip('"\'')
            if policy_id in seen_ids:
                fail(errors, f"duplicate policy id {policy_id}: {seen_ids[policy_id]}, {relative}")
            seen_ids[policy_id] = relative
            if f"`{policy_id}`" not in routing:
                fail(errors, f"policy card not routed: {policy_id} ({relative})")
        if not status_match or status_match.group(1) not in POLICY_STATUSES:
            fail(errors, f"invalid policy card status: {relative}")
            card_status = ""
        else:
            card_status = status_match.group(1)

        if id_match:
            policy_id = id_match.group(1).strip().strip('"\'')
            routing_row = next(
                (line for line in routing.splitlines() if f"| `{policy_id}` |" in line),
                "",
            )
            if routing_row and f"| {card_status} |" not in routing_row:
                fail(errors, f"routing status differs from card status: {policy_id}")

        if card_status == "active":
            validate_active_policy_card(
                frontmatter,
                content[frontmatter_match.end():],
                routing_row if id_match else "",
                policy_id if id_match else relative,
                known_sources,
                relative,
                errors,
            )
        if card_status == "superseded":
            superseded.append((relative, frontmatter_value(frontmatter, "replacement")))

        if card_status == "retired":
            for field in [
                "retired_at",
                "retirement_reason",
                "replacement",
                "approved_by",
                "approved_at",
            ]:
                if is_placeholder(frontmatter_value(frontmatter, field)):
                    fail(errors, f"retired policy card missing {field}: {relative}")

        for source_id in set(
            re.findall(r"SRC-[A-Z0-9]+(?:-[A-Z0-9]+)*\b", content)
        ):
            if source_id not in known_sources:
                fail(errors, f"unknown source id {source_id} in {relative}")

        for source_id, start_text, end_text in re.findall(
            r"(SRC-[A-Z0-9-]+):(\d+)(?:-(\d+))?", content
        ):
            entry = sources_by_id.get(source_id)
            if not entry:
                continue
            start = int(start_text)
            end = int(end_text or start_text)
            if start < 1 or end < start or end > int(entry.get("lines", 0)):
                fail(errors, f"invalid citation range {source_id}:{start}-{end} in {relative}")

        for label, pattern in TRACKED_POLICY_PII_PATTERNS.items():
            if has_foreign_account_id(pattern, content) if label == ACCOUNT_LIKE else pattern.search(content):
                fail(errors, f"possible {label} copied into tracked policy card: {relative}")

    # policy/README.md: superseded 카드는 대체 카드에 연결돼야 한다
    for relative, replacement in superseded:
        if replacement not in seen_ids:
            fail(errors, f"superseded policy card replacement is not an existing card id: {relative}")

    for reference in re.findall(r"`(cards/[^`]+\.md)`", routing):
        if not (ROOT / "policy" / reference).is_file():
            fail(errors, f"routing references missing card: {reference}")

    if (ROOT / ".git").exists():
        result = subprocess.run(
            ["git", "-c", "core.quotePath=false", "ls-files", "policy/inbox"],
            cwd=ROOT,
            check=False,
            capture_output=True,
            text=True,
        )
        tracked_raw = [
            line
            for line in result.stdout.splitlines()
            if line and line != "policy/inbox/README.md"
        ]
        if tracked_raw:
            fail(errors, f"raw inbox files are tracked: {', '.join(tracked_raw)}")

    raw_dir = ROOT / "policy/inbox"
    raw_files = sorted(raw_dir.glob("*.txt"))
    raw_by_nfc = {
        unicodedata.normalize("NFC", path.name): path
        for path in raw_files
    }
    verified_sources = 0
    if raw_files:
        expected_names = {
            entry.get("filename_nfc")
            for entry in source_entries
            if entry.get("filename_nfc")
        }
        extra_names = sorted(set(raw_by_nfc) - expected_names)
        if extra_names:
            fail(errors, f"unregistered raw source files: {', '.join(extra_names)}")

    for source_id, entry in sources_by_id.items():
        tracked_relative = entry.get("path")
        if tracked_relative:
            path = (ROOT / tracked_relative).resolve()
            try:
                path.relative_to(ROOT.resolve())
            except ValueError:
                fail(errors, f"manifest tracked source escapes repository: {source_id}")
                continue
            if not path.is_file():
                fail(errors, f"manifest tracked source missing: {source_id} ({tracked_relative})")
                continue
        elif raw_files:
            filename = entry.get("filename_nfc")
            path = raw_by_nfc.get(filename)
            if not path:
                fail(errors, f"manifest source file missing from inbox: {source_id} ({filename})")
                continue
        else:
            continue

        digest = hashlib.sha256(path.read_bytes()).hexdigest()
        if digest != entry.get("sha256"):
            fail(errors, f"source hash changed: {source_id} ({path.name})")
        line_count = len(path.read_text(encoding="utf-8").splitlines())
        if line_count != int(entry.get("lines", 0)):
            fail(
                errors,
                f"source line count changed: {source_id} expected {entry.get('lines')} got {line_count}",
            )
        verified_sources += 1

    return len(cards), verified_sources




def _string_id_list(
    relative: str,
    owner: str,
    value: object,
    pattern: str,
    errors: list[str],
) -> list[str]:
    if not isinstance(value, list) or any(not isinstance(item, str) for item in value):
        fail(errors, f"{relative} {owner} must be a string list")
        return []
    result = list(value)
    for item in result:
        if not re.fullmatch(pattern, item):
            fail(errors, f"{relative} {owner} has invalid ID: {item}")
    if len(result) != len(set(result)):
        fail(errors, f"{relative} {owner} contains duplicate IDs")
    return result


def validate_deidentified_repository(errors: list[str]) -> None:
    # 고객 프로필은 걷어냈다 — 특이사항은 ITSM 에서 읽는다 (0031·0034). 폴더 이름·프로필 칸은 보지 않는다.
    customer_root = ROOT / "customers"
    for path in customer_root.iterdir():
        if path.is_dir():
            # 0002 이후 운영 티켓은 로컬 전용 tickets/ 에 있다.
            ticket_dir = path / "tickets"
            if ticket_dir.is_dir():
                fail(
                    errors,
                    f"tickets moved to the local-only tickets/ directory: "
                    f"{ticket_dir.relative_to(ROOT)}",
                )
    # 작업 지시서 형식 고정 (0009). 항목 나열로 되돌아가면 티켓을 옮겨 적은 것이 되고,
    # 그럴 거면 실행자는 티켓을 본다 — 실제 피드백으로 한 번 폐기된 형태다.
    intake_template = read_text("templates/ticket-intake.md", errors)
    for marker in [
        "## 작업 지시",
        "[변경]",
        "이 줄만 고치면 아래는 그대로 실행된다",
        "되돌릴 근거",
        "적용됐는지 확인한다",
        "[확인]",
        "[추측]",
        "[모름]",
        # 0010: 출처 없는 [확인] 을 막는 문장. 이게 빠지면 등급이 장식이 된다.
        "출처 없는 [확인] 은 [확인] 이 아니다",
        "확인 방법:",
        "유선으로 처리했으면",
        # 0011: 문서 충돌을 조용히 넘기지 않게 하는 문장
        "공식 문서끼리 충돌하면",
        # 0012: 발송 전 관문. 규칙이 있는데도 안 지켜져서 만든 것이라 항목이 사라지면 안 된다.
        "## 발송 전 점검",
        "고객이 문의에서 밝힌 제약을 답변이 지키는가",
        "콘솔 경로를 고객이 보는 화면 그대로 썼는가",
        "지금 답할 수 있는데 되묻고 있지 않은가",
    ]:
        if marker not in intake_template:
            fail(errors, f"ticket intake template missing marker: {marker}")

    retention_hierarchy = (
        "law/legal obligation → customer-specific contract/SLA/SOW → "
        "active standard terms"
    )
    for relative in [
        "policy/cards/POLICY-DATA-001-contract-termination-data-lifecycle.md",
    ]:
        if retention_hierarchy not in read_text(relative, errors):
            fail(errors, f"retention hierarchy missing from {relative}")

    payer_card = read_text("policy/cards/POLICY-PAYER-001-standalone-payer-scope.md", errors)
    for marker in ["CSR", "COP", "billing platform"]:
        if marker not in payer_card:
            fail(errors, f"standalone-Payer verification rule missing: {marker}")

    for path in iter_text_files():
        relative = str(path.relative_to(ROOT))
        if relative.startswith("policy/inbox/") or relative in DEIDENTIFICATION_SCAN_EXCLUSIONS:
            continue
        content = path.read_text(encoding="utf-8")
        for label, pattern in TRACKED_CUSTOMER_IDENTIFIER_PATTERNS.items():
            if has_foreign_account_id(pattern, content) if label == ACCOUNT_LIKE else pattern.search(content):
                fail(
                    errors,
                    f"possible tracked customer {label}: {relative}; value intentionally not printed",
                )

    if (ROOT / ".git").exists():
        result = subprocess.run(
            ["git", "check-ignore", "-q", ".private/customer-map.md"],
            cwd=ROOT,
            check=False,
        )
        if result.returncode != 0:
            fail(errors, ".private/customer-map.md is not gitignored")


def validate_ascii_paths(errors: list[str]) -> int:
    """Repository paths must be ASCII.

    Non-ASCII path names are compared as exact strings by this validator, by
    .gitignore, by grep patterns in agent instructions, and by git plumbing. The
    git/filesystem boundary gives no Unicode normalization guarantee, so the same
    file can appear under NFC on one machine and NFD on another: lookups still
    succeed on macOS while directory enumeration silently stops matching. Raw
    company sources under the inbox are exempt because their names come from the
    source system, they are never tracked, and they are NFC-normalized on read.
    """
    checked = 0
    offenders: list[str] = []

    def offending(relative: str) -> bool:
        if relative.startswith(ASCII_PATH_EXEMPT_PREFIXES):
            return False
        return not relative.isascii()

    if (ROOT / ".git").exists():
        listed = subprocess.run(
            ["git", "-c", "core.quotePath=false", "ls-files", "-z"],
            cwd=ROOT,
            check=False,
            capture_output=True,
            text=True,
        )
        for relative in listed.stdout.split("\0"):
            if not relative:
                continue
            checked += 1
            if offending(relative):
                offenders.append(relative)

    for path in ROOT.rglob("*"):
        relative_parts = path.relative_to(ROOT).parts
        if not relative_parts or relative_parts[0] in {".git", ".private"}:
            continue
        relative = path.relative_to(ROOT).as_posix()
        checked += 1
        if offending(relative):
            offenders.append(relative)

    for relative in sorted(set(offenders)):
        fail(
            errors,
            "non-ASCII repository path; rename it and update every reference: "
            f"{relative}",
        )
    return checked


def validate_mcp_contract(errors: list[str]) -> tuple[int, int]:
    """Project-scoped MCP capability must be declared once and generated for every host.

    The failure this prevents: a capability that works only in the maintainer's
    personal agent profile while the repository documents it as available. Returns
    (server count, host file count).
    """
    relative = "agents/environment/mcp-manifest.json"
    raw = read_text(relative, errors)
    if not raw:
        return 0, 0
    try:
        manifest = json.loads(raw)
    except json.JSONDecodeError as exc:
        fail(errors, f"invalid MCP manifest JSON: {relative} ({exc})")
        return 0, 0

    servers = manifest.get("servers") or []
    if not servers:
        fail(errors, f"MCP manifest declares no server: {relative}")

    declared_capabilities: set[str] = set()
    for server in servers:
        server_id = server.get("id", "<missing id>")
        for field in ("id", "capability", "transport", "authentication", "classification"):
            if not server.get(field):
                fail(errors, f"MCP server missing {field}: {server_id}")
        declared_capabilities.add(server.get("capability", ""))
        if not server.get("allowed_tools"):
            fail(errors, f"MCP server declares no include-only tool list: {server_id}")
        if server.get("required_env"):
            fail(
                errors,
                f"MCP server requires environment values in a shared manifest: {server_id}",
            )
        overlap = set(server.get("allowed_tools") or []) & set(server.get("blocked_tools") or [])
        if overlap:
            fail(
                errors,
                f"MCP server lists the same tool as allowed and blocked: {server_id} "
                f"({', '.join(sorted(overlap))})",
            )
        if server.get("transport") == "stdio":
            if not server.get("pinned_version"):
                fail(errors, f"MCP stdio server is not version pinned: {server_id}")
            args = server.get("args") or []
            for required_flag in MCP_REQUIRED_PROXY_FLAGS:
                if required_flag not in args:
                    fail(
                        errors,
                        f"MCP stdio server missing required guard flag {required_flag}: {server_id}",
                    )
        for tool in MCP_FORBIDDEN_TOOLS:
            if tool in (server.get("allowed_tools") or []):
                fail(errors, f"MCP server allows a customer-account tool: {server_id} ({tool})")

    for capability in ("aws-official-research", "current-web-research"):
        if capability not in declared_capabilities:
            fail(errors, f"MCP manifest does not cover routed capability: {capability}")

    host_files: list[str] = []
    for host in manifest.get("hosts") or []:
        for key in ("config_path", "permissions_path"):
            path = host.get(key)
            if path:
                host_files.append(path)
    for path in host_files:
        if not (ROOT / path).is_file():
            fail(errors, f"generated MCP host config missing: {path}")

    rendered = subprocess.run(
        ["python3", "scripts/render_agent_configs.py", "--check"],
        cwd=ROOT,
        check=False,
        capture_output=True,
        text=True,
    )
    if rendered.returncode != 0:
        drifted = [
            line.strip().removeprefix("- out of date: ")
            for line in rendered.stderr.splitlines()
            if line.strip().startswith("- out of date: ")
        ]
        if drifted:
            fail(
                errors,
                "MCP host configs no longer match the manifest "
                f"({', '.join(drifted)}); run: python3 scripts/render_agent_configs.py",
            )
        else:
            fail(errors, "cannot verify MCP host configs against the manifest")

    return len(servers), len(host_files)


def validate_local_only_customer_data(errors: list[str]) -> None:
    """Alpha remote model: operational customer data stays local and unpushed.

    No personal operational remote is approved yet, so the only configured remote is
    the shared framework repository. Two independent guards must be in place:
    the ignore rule (ships with the repository) and the pre-push hook (needs one
    local activation command).
    """
    if not (ROOT / ".git").exists():
        return

    # 폴더 이름과 무관하게 막혀야 한다 — 가명 폴더만 막던 규칙은 실명 폴더를 내보냈다 (2026-10-06).
    probe = "customers/real-name/profile.md"
    ignored = subprocess.run(["git", "check-ignore", "-q", probe], cwd=ROOT, check=False)
    if ignored.returncode != 0:
        fail(errors, f"operational customer data is not gitignored: {probe}")

    tracked = subprocess.run(
        ["git", "-c", "core.quotePath=false", "ls-files", "customers/"],
        cwd=ROOT,
        check=False,
        capture_output=True,
        text=True,
    )
    unexpected = [
        line
        for line in tracked.stdout.splitlines()
        if line and line != "customers/_index.md"
    ]
    if unexpected:
        fail(
            errors,
            "operational customer files are tracked and would reach the shared "
            f"repository: {', '.join(unexpected)}",
        )

    configured = subprocess.run(
        ["git", "config", "--get", "core.hooksPath"],
        cwd=ROOT,
        check=False,
        capture_output=True,
        text=True,
    )
    hooks_path = configured.stdout.strip()
    if hooks_path != HOOKS_DIR:
        fail(
            errors,
            "push guard is inactive; run: git config core.hooksPath "
            f"{HOOKS_DIR}",
        )
        return
    hook = ROOT / HOOKS_DIR / "pre-push"
    if not hook.is_file():
        fail(errors, f"push guard hook is missing: {HOOKS_DIR}/pre-push")
    elif not os.access(hook, os.X_OK):
        fail(
            errors,
            f"push guard hook is not executable; run: chmod +x {HOOKS_DIR}/pre-push",
        )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--framework",
        action="store_true",
        help="fail when operational customer directories exist in the common upstream candidate",
    )
    args = parser.parse_args()
    errors: list[str] = []

    for relative in REQUIRED_FILES:
        read_text(relative, errors)

    always_on_contents = {
        relative: read_text(relative, errors) for relative in ALWAYS_ON_CHAR_BUDGETS
    }
    canonical = always_on_contents["CLAUDE.md"]
    for relative, budget in ALWAYS_ON_CHAR_BUDGETS.items():
        length = len(always_on_contents[relative])
        if length > budget:
            fail(errors, f"{relative} exceeds always-on character budget: {length} / {budget}")
    combined_length = len(always_on_contents["AGENTS.md"]) + len(canonical)
    if combined_length > AGENTS_CLAUDE_COMBINED_CHAR_BUDGET:
        fail(
            errors,
            "AGENTS.md + CLAUDE.md exceeds combined always-on character budget: "
            f"{combined_length} / {AGENTS_CLAUDE_COMBINED_CHAR_BUDGET}",
        )
    for marker in CANONICAL_MARKERS:
        if marker not in canonical:
            fail(errors, f"CLAUDE.md missing canonical marker: {marker}")

    task_router = read_text("agents/task-router.md", errors)
    for marker in TASK_ROUTER_MARKERS:
        if marker not in task_router:
            fail(errors, f"task router missing marker: {marker}")

    shared_environment = read_text("agents/shared-agent-environment.md", errors)
    validate_markdown_sources("agents/shared-agent-environment.md", shared_environment, errors)

    for relative, markers in {
    }.items():
        content = read_text(relative, errors)
        for marker in markers:
            if marker not in content:
                fail(errors, f"{relative} missing semantic contract marker: {marker}")

    reply_templates = read_text("playbooks/reply-templates.md", errors)
    for marker in REPLY_TEMPLATE_MARKERS:
        if marker not in reply_templates:
            fail(errors, f"reply template contract missing marker: {marker}")



    for relative, markers in ROUTED_MODULE_MARKERS.items():
        content = read_text(relative, errors)
        for marker in markers:
            if marker not in content:
                fail(errors, f"{relative} missing routed safety marker: {marker}")

    for relative, markers in ENTRYPOINT_MARKERS.items():
        content = read_text(relative, errors)
        for marker in markers:
            if marker not in content:
                fail(errors, f"{relative} missing entrypoint marker: {marker}")

    runtime_status = read_text("agents/runtime-status.md", errors)
    for marker in [
        "`customer-aws-readonly` | enabled",
        "`billing-platform` | enabled",
        "### Evidence provenance",
        "Operator-attested",
        "mcp-proxy-for-aws@1.6.4",
        "aws___search_documentation",
        "aws___read_documentation",
        "aws___list_regions",
        "aws___get_regional_availability",
        "aws___call_aws",
        "aws___run_script",
        "aws___get_tasks",
        "aws___get_presigned_url",
        "aws___retrieve_skill",
        "https://mcp.exa.ai/mcp",
        "web_search_exa",
        "web_fetch_exa",
        "agent_run",
        "web_search_advanced_exa",
        "anonymous",
    ]:
        if marker not in runtime_status:
            fail(errors, f"runtime capability status missing marker: {marker}")

    for relative in FRONTMATTER_FILES:
        content = read_text(relative, errors)
        if not content.startswith("---\n") or "\n---\n" not in content[4:]:
            fail(errors, f"invalid or missing frontmatter fence: {relative}")

    gitignore = read_text(".gitignore", errors)
    for marker in [
        ".private/",
        "policy/raw/",
        "policy/inbox/*",
        "!policy/inbox/README.md",
        "customers/*",
        "terraform.tfstate",
        "*.kubeconfig",
    ]:
        if marker not in gitignore:
            fail(errors, f".gitignore missing safety rule: {marker}")

    validate_local_only_customer_data(errors)
    mcp_server_count, mcp_host_count = validate_mcp_contract(errors)
    ascii_path_count = validate_ascii_paths(errors)

    plan_files = sorted(path.name for path in ROOT.glob("계획*.md"))
    if plan_files:
        fail(errors, f"obsolete plan files remain: {', '.join(plan_files)}")

    for path in iter_text_files():
        content = path.read_text(encoding="utf-8")
        for label, pattern in SECRET_PATTERNS.items():
            if pattern.search(content):
                relative = path.relative_to(ROOT)
                fail(errors, f"possible {label} in {relative}; value intentionally not printed")

    policy_card_count, verified_source_count = validate_policy_cards(errors)
    pitfall_card_count = validate_pitfall_cards(errors)
    validate_deidentified_repository(errors)
    if args.framework:
        customer_dirs = sorted(path.name for path in (ROOT / "customers").iterdir() if path.is_dir())
        if customer_dirs:
            fail(errors, "framework candidate contains workspace-owned customer directories")
        customer_index = read_text("customers/_index.md", errors)
        clean_customer_index = read_text("templates/customer-index.md", errors)
        if customer_index != clean_customer_index:
            fail(errors, "framework candidate customer index differs from the clean template")

    if errors:
        print("workspace validation: FAIL")
        for error in errors:
            print(f"- {error}")
        return 1

    print("workspace validation: PASS")
    print(f"- required files: {len(REQUIRED_FILES)}")
    print(f"- CLAUDE.md characters: {len(canonical)} / {ALWAYS_ON_CHAR_BUDGETS['CLAUDE.md']}")
    print(
        "- AGENTS.md + CLAUDE.md characters: "
        f"{combined_length} / {AGENTS_CLAUDE_COMBINED_CHAR_BUDGET}"
    )
    print("- entrypoints: AGENTS.md, Kiro steering")
    print("- local-only customer data: gitignored, push guard active")
    print(
        f"- project-scoped MCP: {mcp_server_count} servers, "
        f"{mcp_host_count} host configs generated from the manifest"
    )
    print(f"- ASCII-only paths: {ascii_path_count} checked")
    print(f"- validation mode: {'framework' if args.framework else 'workspace'}")
    print("- templates: frontmatter present")
    print("- shared documentation citation map: consistent")
    print("- ticket outputs: work order / investigation / advisory, pre-send gate pinned")
    print("- obsolete plan files: none")
    print("- credential signature scan: clear")
    print(f"- policy cards: {policy_card_count}, routed with known sources")
    print(f"- pitfall cards: {pitfall_card_count}, dated with versioned sources")
    print("- tracked policy PII scan: clear")
    print("- raw inbox tracked files: README.md only")
    print("- tracked customer identifier scan: clear")
    if verified_source_count:
        print(f"- raw source hashes and line counts: {verified_source_count} verified")
    else:
        print("- raw source hashes and line counts: skipped (inbox not present)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
