#!/usr/bin/env python3
"""Regression tests for the workspace validator's Alpha safety gates."""

from __future__ import annotations

import importlib.util
import json
import os
import shutil
import subprocess
import tempfile
import unittest
from datetime import date, timedelta
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def _load_validator_module():
    """Import validate_workspace.py as a module so its functions can be unit-tested."""
    spec = importlib.util.spec_from_file_location(
        "validate_workspace", ROOT / "scripts" / "validate_workspace.py"
    )
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


# 문서용 예약 대역(RFC 5737 TEST-NET-3). 리터럴로 적으면 이 파일 자체가
# 고객 IP 스캔에 걸리므로 쪼개서 조립한다.
DOC_IP = "203.0" + ".113.77"


TODAY = date.today()
DOC_URL = "https://docs.aws.amazon.com/savingsplans/latest/userguide/sp-inventory.html"


def days(offset: int) -> str:
    return (TODAY + timedelta(days=offset)).isoformat()


def pitfall_card(
    observed: str = f"  - {days(0)} | ticket 100012",
    sources: str = (
        f"  - {days(0)} | aws-doc | {DOC_URL} | 표기 없음\n"
        f"  - {days(0)} | billing-portal | Billings > Savings Plans > Inventory | 2026-09 메뉴"
    ),
    review: str = f"review_by: {days(90)}",
    facts: str = f"- 콘솔 Inventory 는 linked account 에서 막힌다 → {DOC_URL}",
    body: str = "x",
    log: str = f"- {days(0)}: 작성",
    title: str = "# 콘솔 경로를 문서대로 안내하면 권한 없는 고객이 못 본다",
) -> str:
    review_line = f"{review}\n" if review else ""
    return f"""---
observed:
{observed}
sources:
{sources}
{review_line}---

{title}

## 무엇을 하면 틀리는가

{body}

## 실제로 있었던 일

{body}

## 확인된 사실

{facts}

## 해야 할 것

{body}

## 다시 쓰기 전에 확인할 것

{body}

## 변경 이력

{log}
"""


POLICY_CARD = "policy/cards/POLICY-TEST-001-probe.md"


def policy_card(
    status: str = "active",
    source_document: str = "SRC-COST-ESC-001",
    source_version: str = '"probe announcement v1"',
    effective_from: str = days(0),
    reviewed_at: str = days(0),
    review_by: str = days(90),
    authority_verified_at: str = f'"{days(0)} KST"',
    approved_at: str = f'"{days(0)} 10:00 KST"',
    replacement: str = '""',
    control: str = "Probe control statement.",
    history: str = f"- {days(0)} — probe card activated",
) -> str:
    return f"""---
id: POLICY-TEST-001
title: Probe policy card
status: {status}
applies_to: [probe]
triggers: [probe]
source_document: {source_document}
source_location: "probe lines"
source_owner: MSP team lead
source_version: {source_version}
effective_from: {effective_from}
applicability: "Probe applicability"
reviewed_at: {reviewed_at}
reviewed_by: Claude Code
review_by: {review_by}
authority_verified_at: {authority_verified_at}
approved_by: MSP team lead
approved_at: {approved_at}
activation_blocker: ""
retired_at: ""
retirement_reason: ""
replacement: {replacement}
supersedes: ""
---

# Probe policy card

## Control statement

{control}

## Scope

- Applies when: probing

## Required behavior

1. Probe.

## Prohibited behavior

- Nothing.

## Exceptions and escalation

- None.

## Evidence

- Source document: probe

## Change history

{history}
"""


def policy_route(status: str = "active", effective: str = days(0), review: str = days(90)) -> str:
    return (
        f"| `POLICY-TEST-001` | Probe policy card | {status} | probe | probe | {effective} | {review} "
        "| `cards/POLICY-TEST-001-probe.md` |"
    )


class WorkspaceValidatorTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tempdir = tempfile.TemporaryDirectory(prefix="tiket-validator-test-")
        self.repo = Path(self.tempdir.name) / "repo"
        shutil.copytree(
            ROOT,
            self.repo,
            ignore=self._fixture_ignore,
        )

    @staticmethod
    def _fixture_ignore(src_dir: str, names: list[str]) -> set[str]:
        """픽스처는 깨끗한 clone 을 흉내낸다.

        최상위 `tickets/` 와 `customers/` 는 실명 고객 자료를 담는 로컬 전용 디렉터리라
        가져오지 않는다 — 가져오면 로컬에 그 자료가 있는 사람에게서만 테스트가 깨진다.
        이름으로 거르면 `examples/CUST-900/tickets/` 까지 같이 사라지므로 최상위에서만 거른다.

        `customers/` 가 빠져 있어서, 고객 프로필을 하나라도 만든 엔지니어에게는
        `--framework` 검사가 "framework candidate contains workspace-owned customer
        directories" 로 실패했다 (2026-09-18 관측). 프로필 생성은 정상 작업이다.
        """
        skip = {".git", ".private", "__pycache__", ".venv"} & set(names)
        source = Path(src_dir).resolve()
        if source == ROOT.resolve():
            # `excavation/` 은 고객 발굴 결과(실명 자료)를 담는 로컬 전용 디렉터리다.
            skip |= {"tickets", "excavation"} & set(names)
        if source == (ROOT / "customers").resolve():
            # `_index.md` 는 프레임워크 파일이라 남기고, 엔지니어가 만든 프로필
            # 디렉터리(CUST-NNN)만 거른다.
            skip |= {name for name in names if (source / name).is_dir()}
        return skip

    def tearDown(self) -> None:
        self.tempdir.cleanup()

    def run_validator(self, *args: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            ["python3", "scripts/validate_workspace.py", *args],
            cwd=self.repo,
            check=False,
            capture_output=True,
            text=True,
        )

    def replace_once(self, relative: str, old: str, new: str) -> None:
        path = self.repo / relative
        content = path.read_text(encoding="utf-8")
        self.assertIn(old, content)
        path.write_text(content.replace(old, new, 1), encoding="utf-8")

    def assert_rejected(self, result: subprocess.CompletedProcess[str], marker: str) -> None:
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn(marker, result.stdout)

    def git(self, *args: str, cwd: Path | None = None) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            ["git", *args],
            cwd=cwd or self.repo,
            check=False,
            capture_output=True,
            text=True,
        )

    def init_git(self, activate_hooks: bool = True) -> None:
        """Give the fixture a real repository so the Git-dependent gates run."""
        self.git("init", "-q", "-b", "main")
        self.git("config", "user.email", "test@invalid")
        self.git("config", "user.name", "test")
        if activate_hooks:
            self.git("config", "core.hooksPath", ".githooks")

    def test_gitignored_local_work_is_not_scanned_as_tracked(self) -> None:
        """tickets/ 는 실명 고객 자료를 일부러 담는다. gitignore 되어 공용 저장소에
        도달할 수 없으므로 유출 스캔 대상이 아니다. 여기서 잡히면 실제 티켓 작업을
        시작하는 순간부터 validator 가 항상 FAIL 이고, 사람은 곧 무시하게 된다."""
        self.init_git()
        tickets = self.repo / "tickets"
        tickets.mkdir(exist_ok=True)
        (tickets / "100008.md").write_text(
            f"# 100008\n접속 IP {DOC_IP} 확인\n", encoding="utf-8"
        )
        result = self.run_validator()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertNotIn("tickets/100008.md", result.stdout)

    def test_tracked_file_with_a_customer_ip_is_still_rejected(self) -> None:
        """위 예외가 스캔 자체를 끄지 않았는지 확인한다."""
        self.init_git()
        (self.repo / "playbooks/_probe.md").write_text(
            f"# probe\n접속 IP {DOC_IP} 확인\n", encoding="utf-8"
        )
        self.assert_rejected(self.run_validator(), "possible tracked customer IPv4 address")

    def test_msp_own_account_ids_may_be_written_down(self) -> None:
        """2026-10-22 유지보수자: 우리 회사 계정(인터널 계정·메인 Payer 계정·빌링 플랫폼 계정)은 쓰는 사람이 모두 알고 헷갈리지 않아야 한다.
        계정 번호 하나로는 아무것도 못 한다 — 추적 파일에 적어도 된다."""
        self.init_git()
        (self.repo / "playbooks/_probe.md").write_text(
            "# probe\n브로커 444455556666, Payer 111122223333, 빌링 플랫폼 777788889999\n", encoding="utf-8"
        )
        result = self.run_validator()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_any_other_account_id_is_still_rejected(self) -> None:
        self.init_git()
        (self.repo / "playbooks/_probe.md").write_text(
            "# probe\n브로커 444455556666, 고객 " + "2879978829" + "79\n", encoding="utf-8"  # 이 파일도 스캔된다
        )
        self.assert_rejected(self.run_validator(), "possible tracked customer 12-digit account-like value")

    def test_non_ascii_repository_path_is_rejected(self) -> None:
        (self.repo / "templates/한글파일.md").write_text("x\n", encoding="utf-8")
        self.assert_rejected(
            self.run_validator(),
            "non-ASCII repository path",
        )

    def read_manifest(self) -> dict:
        return json.loads(
            (self.repo / "agents/environment/mcp-manifest.json").read_text(encoding="utf-8")
        )

    def write_manifest(self, manifest: dict) -> None:
        (self.repo / "agents/environment/mcp-manifest.json").write_text(
            json.dumps(manifest, indent=2, ensure_ascii=False) + "\n", encoding="utf-8"
        )

    def test_mcp_host_config_drift_is_rejected(self) -> None:
        self.replace_once(".kiro/settings/mcp.json", '"--read-only",', "")
        self.assert_rejected(
            self.run_validator(),
            "MCP host configs no longer match the manifest",
        )

    def test_mcp_proxy_must_keep_its_guard_flags(self) -> None:
        manifest = self.read_manifest()
        for server in manifest["servers"]:
            if server["transport"] == "stdio":
                server["args"] = [arg for arg in server["args"] if arg != "--read-only"]
        self.write_manifest(manifest)
        subprocess.run(
            ["python3", "scripts/render_agent_configs.py"],
            cwd=self.repo,
            check=True,
            capture_output=True,
        )
        self.assert_rejected(
            self.run_validator(),
            "missing required guard flag --read-only",
        )

    def test_mcp_manifest_cannot_allow_a_customer_account_tool(self) -> None:
        manifest = self.read_manifest()
        manifest["servers"][0]["allowed_tools"].append("aws___call_aws")
        manifest["servers"][0]["blocked_tools"].remove("aws___call_aws")
        self.write_manifest(manifest)
        subprocess.run(
            ["python3", "scripts/render_agent_configs.py"],
            cwd=self.repo,
            check=True,
            capture_output=True,
        )
        self.assert_rejected(
            self.run_validator(),
            "allows a customer-account tool",
        )

    def test_mcp_manifest_must_cover_routed_capabilities(self) -> None:
        manifest = self.read_manifest()
        manifest["servers"] = [
            server for server in manifest["servers"] if server["capability"] != "current-web-research"
        ]
        self.write_manifest(manifest)
        subprocess.run(
            ["python3", "scripts/render_agent_configs.py"],
            cwd=self.repo,
            check=True,
            capture_output=True,
        )
        self.assert_rejected(
            self.run_validator(),
            "does not cover routed capability: current-web-research",
        )

    def test_mcp_manifest_must_not_require_environment_values(self) -> None:
        manifest = self.read_manifest()
        manifest["servers"][0]["required_env"] = ["SOME_API_KEY"]
        self.write_manifest(manifest)
        self.assert_rejected(
            self.run_validator(),
            "requires environment values in a shared manifest",
        )

    def test_generated_mcp_host_config_is_required(self) -> None:
        (self.repo / ".codex/config.toml").unlink()
        self.assert_rejected(
            self.run_validator(),
            "missing required file: .codex/config.toml",
        )

    def test_raw_inbox_source_filenames_stay_exempt(self) -> None:
        """Raw company sources keep their original names without failing the gate."""
        result = self.run_validator()
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn("ASCII-only paths:", result.stdout)

    def test_push_guard_must_be_activated(self) -> None:
        self.init_git(activate_hooks=False)
        self.assert_rejected(
            self.run_validator(),
            "push guard is inactive; run: git config core.hooksPath .githooks",
        )

    def test_operational_customer_data_must_be_gitignored(self) -> None:
        self.replace_once(".gitignore", "customers/*", "# rule removed")
        self.init_git()
        self.assert_rejected(
            self.run_validator(),
            ".gitignore missing safety rule: customers/*",
        )

    def test_a_customer_folder_under_any_name_is_gitignored(self) -> None:
        """가명 폴더만 막으면 실명 폴더가 새 나간다 — 평가에서 에이전트가 `customers/<고객명>/` 을 만들었다 (2026-10-02)."""
        self.init_git()
        for name in ("CUST-901", "합성고객", "acme"):
            ignored = subprocess.run(["git", "check-ignore", "-q", f"customers/{name}/profile.md"],
                                     cwd=self.repo, check=False)
            self.assertEqual(ignored.returncode, 0, name)
        kept = subprocess.run(["git", "check-ignore", "-q", "customers/_index.md"], cwd=self.repo, check=False)
        self.assertNotEqual(kept.returncode, 0, "중단 안내문은 추적한다")

    def test_push_guard_blocks_a_customer_folder_under_a_real_name(self) -> None:
        upstream = Path(self.tempdir.name) / "upstream3.git"
        self.git("init", "-q", "--bare", str(upstream), cwd=Path(self.tempdir.name))
        self.init_git()
        self.git("remote", "add", "upstream", str(upstream))
        customer = self.repo / "customers/합성고객"
        customer.mkdir()
        (customer / "notes.md").write_text("x\n", encoding="utf-8")
        self.git("add", "-A")
        self.git("add", "-f", "customers/합성고객/notes.md")
        self.git("commit", "-q", "-m", "customer work")
        blocked = subprocess.run(
            ["git", "push", "upstream", "main"], cwd=self.repo, check=False, capture_output=True, text=True,
            env={**os.environ, "TIKET_ALLOW_UPSTREAM_PUSH": "1"},
        )
        self.assertNotEqual(blocked.returncode, 0, blocked.stderr)
        self.assertIn("customers/합성고객/notes.md", blocked.stderr)

    def test_push_guard_lets_the_customer_index_through(self) -> None:
        upstream = Path(self.tempdir.name) / "upstream4.git"
        self.git("init", "-q", "--bare", str(upstream), cwd=Path(self.tempdir.name))
        self.init_git()
        self.git("remote", "add", "upstream", str(upstream))
        self.git("add", "-A")
        self.git("commit", "-q", "-m", "framework")
        pushed = subprocess.run(
            ["git", "push", "upstream", "main"], cwd=self.repo, check=False, capture_output=True, text=True,
            env={**os.environ, "TIKET_ALLOW_UPSTREAM_PUSH": "1"},
        )
        self.assertEqual(pushed.returncode, 0, pushed.stderr)

    def test_tracked_operational_customer_file_is_rejected(self) -> None:
        customer = self.repo / "customers/CUST-901"
        customer.mkdir()
        (customer / "profile.md").write_text("# 합성\n", encoding="utf-8")
        self.init_git()
        self.git("add", "-f", "customers/CUST-901/profile.md")
        self.assert_rejected(
            self.run_validator(),
            "operational customer files are tracked",
        )

    def test_an_untracked_local_customer_folder_is_not_checked_as_a_profile(self) -> None:
        """프로필은 걷어냈다 — 고객 특이사항은 ITSM 에서 읽는다 (0031·0034). 가명 폴더 이름과 프로필 칸을 더 보지 않는다.
        나가지 않게 막는 셋(gitignore·pre-push·추적 파일 검사)은 그대로다."""
        customer = self.repo / "customers/acme"
        customer.mkdir()
        (customer / "notes.md").write_text("# 합성\n", encoding="utf-8")
        self.init_git()
        result = self.run_validator()
        self.assertEqual(result.returncode, 0, result.stdout)

    def test_push_guard_blocks_operational_customer_data(self) -> None:
        upstream = Path(self.tempdir.name) / "upstream.git"
        self.git("init", "-q", "--bare", str(upstream), cwd=Path(self.tempdir.name))
        self.init_git()
        self.git("remote", "add", "upstream", str(upstream))
        customer = self.repo / "customers/CUST-901"
        customer.mkdir()
        (customer / "profile.md").write_text("# 합성\n", encoding="utf-8")
        self.git("add", "-A")
        self.git("add", "-f", "customers/CUST-901/profile.md")
        self.git("commit", "-q", "-m", "customer work")

        blocked = subprocess.run(
            ["git", "push", "upstream", "main"],
            cwd=self.repo,
            check=False,
            capture_output=True,
            text=True,
            env={**os.environ, "TIKET_ALLOW_UPSTREAM_PUSH": "1"},
        )
        self.assertNotEqual(blocked.returncode, 0, blocked.stderr)
        self.assertIn("customers/CUST-901/profile.md", blocked.stderr)

    def test_push_guard_blocks_shared_repository_without_explicit_override(self) -> None:
        upstream = Path(self.tempdir.name) / "upstream2.git"
        self.git("init", "-q", "--bare", str(upstream), cwd=Path(self.tempdir.name))
        self.init_git()
        self.git("remote", "add", "upstream", str(upstream))
        self.git("add", "-A")
        self.git("commit", "-q", "-m", "framework only")

        env = {key: value for key, value in os.environ.items() if key != "TIKET_ALLOW_UPSTREAM_PUSH"}
        blocked = subprocess.run(
            ["git", "push", "upstream", "main"],
            cwd=self.repo,
            check=False,
            capture_output=True,
            text=True,
            env=env,
        )
        self.assertNotEqual(blocked.returncode, 0, blocked.stderr)
        self.assertIn("개인 운영 저장소가 아직 없습니다", blocked.stderr)

    def test_framework_candidate_passes(self) -> None:
        result = self.run_validator("--framework")
        self.assertEqual(result.returncode, 0, result.stdout)

    def test_aws_customer_skill_conformance_runner_is_required(self) -> None:
        (self.repo / "scripts/test_aws_customer_skill.py").unlink()
        self.assert_rejected(
            self.run_validator("--framework"),
            "missing required file: scripts/test_aws_customer_skill.py",
        )

    def test_framework_rejects_operational_customer_directory(self) -> None:
        customer = self.repo / "customers/CUST-901"
        customer.mkdir()
        (customer / "profile.md").write_text("# 합성\n", encoding="utf-8")
        self.assert_rejected(
            self.run_validator("--framework"),
            "framework candidate contains workspace-owned customer directories",
        )

    def test_framework_rejects_operational_customer_index_entries(self) -> None:
        index = self.repo / "customers/_index.md"
        index.write_text(
            index.read_text(encoding="utf-8")
            + "\n| CUST-901 | customers/CUST-901/profile.md | 1 | 2026-08-31 | local |\n",
            encoding="utf-8",
        )
        self.assert_rejected(
            self.run_validator("--framework"),
            "framework candidate customer index differs from the clean template",
        )

    def test_reply_template_contract_markers_are_required(self) -> None:
        self.replace_once(
            "playbooks/reply-templates.md",
            "## 02. 즉시 확답이 어려울 때",
            "## 02. 중간 안내",
        )
        self.assert_rejected(
            self.run_validator("--framework"),
            "reply template contract missing marker",
        )



    # --- 사례(pitfalls/) 양식 — 0027. 날짜·출처·버전이 박혀 있어야 판례로 쓸 수 있다.
    # 각 테스트는 2026-09-30 검토에서 검사기를 실제로 통과한 허점 하나씩이다.

    def write_pitfall(self, body: str) -> None:
        (self.repo / "pitfalls" / "probe-card.md").write_text(body, encoding="utf-8")

    def assert_pitfall_rejected(self, body: str, marker: str) -> None:
        self.write_pitfall(body)
        self.assert_rejected(self.run_validator(), marker)

    def assert_pitfall_accepted(self, body: str) -> None:
        self.write_pitfall(body)
        result = self.run_validator()
        self.assertEqual(result.returncode, 0, result.stdout)

    def test_pitfall_well_formed_card_passes(self) -> None:
        self.assert_pitfall_accepted(pitfall_card())

    def test_pitfall_template_is_required(self) -> None:
        (self.repo / "templates/pitfall.md").unlink()
        self.assert_rejected(self.run_validator(), "missing required file: templates/pitfall.md")

    def test_pitfall_card_without_frontmatter_is_rejected(self) -> None:
        self.assert_pitfall_rejected("# 제목만 있는 사례\n", "pitfall card has no frontmatter: pitfalls/probe-card.md")

    def test_pitfall_card_without_a_title_line_is_rejected(self) -> None:
        """지식 도서관은 제목을 첫 `# ` 줄에서 읽는다(knowledge-library-site 계획 4절)."""
        self.assert_pitfall_rejected(pitfall_card(title=""), "pitfall card has no # title line")

    def test_pitfall_card_without_observation_is_rejected(self) -> None:
        self.assert_pitfall_rejected(pitfall_card(observed=""), "pitfall card has no observed entry")

    def test_pitfall_observation_cannot_carry_a_customer_name(self) -> None:
        """고객은 카드에 적지 않는다. CUST-NNN 은 사람마다 번호가 다르고, 고객 사정은 git 이 아니다(0026)."""
        self.assert_pitfall_rejected(
            pitfall_card(observed=f"  - {days(0)} | ticket 100012 | 어떤고객사"),
            "pitfall observed entry is malformed",
        )

    def test_pitfall_impossible_date_is_rejected(self) -> None:
        self.assert_pitfall_rejected(
            pitfall_card(observed="  - 2026-13-45 | ticket 100012"), "pitfall observed entry is malformed"
        )

    def test_pitfall_compact_date_is_rejected(self) -> None:
        """date.fromisoformat 은 20260930 도 받는다 — 형식을 먼저 본다."""
        self.assert_pitfall_rejected(pitfall_card(review=f"review_by: {days(90).replace('-', '')}"),
                                     "pitfall card has invalid review_by")

    def test_pitfall_future_check_date_is_rejected(self) -> None:
        """미래 조회일은 만료 상한을 늘리는 우회로다."""
        self.assert_pitfall_rejected(
            pitfall_card(sources=f"  - {days(1)} | aws-doc | {DOC_URL} | 표기 없음"),
            "pitfall date is in the future",
        )

    def test_pitfall_card_without_sources_is_rejected(self) -> None:
        self.assert_pitfall_rejected(pitfall_card(sources="", facts="- x"), "pitfall card has no source")

    def test_pitfall_source_without_a_version_is_rejected(self) -> None:
        self.assert_pitfall_rejected(
            pitfall_card(sources=f"  - {days(0)} | aws-doc | {DOC_URL} | "), "pitfall source is malformed"
        )

    def test_pitfall_source_with_a_placeholder_version_is_rejected(self) -> None:
        """버전을 안 본 것과 없는 것을 가른다. 없으면 `표기 없음` 이라고 적는다."""
        for dodge in ["-", "?", "unknown", "모름"]:
            with self.subTest(dodge=dodge):
                self.assert_pitfall_rejected(
                    pitfall_card(sources=f"  - {days(0)} | aws-doc | {DOC_URL} | {dodge}"),
                    "pitfall source version is a placeholder",
                )

    def test_pitfall_source_without_a_check_date_is_rejected(self) -> None:
        self.assert_pitfall_rejected(
            pitfall_card(sources=f"  - 최근 | aws-doc | {DOC_URL} | 표기 없음"), "pitfall source is malformed"
        )

    def test_pitfall_unknown_source_kind_is_rejected(self) -> None:
        self.assert_pitfall_rejected(
            pitfall_card(sources=f"  - {days(0)} | blog | {DOC_URL} | 표기 없음"), "pitfall source is malformed"
        )

    def test_pitfall_web_source_needs_a_url(self) -> None:
        self.assert_pitfall_rejected(
            pitfall_card(sources=f"  - {days(0)} | aws-doc | 어딘가 | 표기 없음", facts="- x"),
            "pitfall web source location is not an https URL",
        )

    def test_pitfall_review_date_in_the_past_is_rejected(self) -> None:
        self.assert_pitfall_rejected(pitfall_card(review="review_by: 2000-01-01"), "pitfall review date has passed")

    def test_pitfall_review_date_is_required_for_aging_sources(self) -> None:
        self.assert_pitfall_rejected(pitfall_card(review=""), "pitfall card with aging sources has no review_by")

    def test_pitfall_review_date_cannot_run_far_ahead(self) -> None:
        """2999 를 적으면 만료 장치가 없는 것과 같다."""
        self.assert_pitfall_rejected(pitfall_card(review="review_by: 2999-01-01"),
                                     "pitfall review_by is more than 180 days after its oldest source check")

    def test_pitfall_review_date_counts_from_the_oldest_source(self) -> None:
        """출처는 1년 전 그대로 두고 기한만 미는 것 — 문서를 다시 열지 않은 재확인이다."""
        self.assert_pitfall_rejected(
            pitfall_card(
                sources=f"  - {days(-365)} | aws-doc | {DOC_URL} | 표기 없음\n"
                        f"  - {days(0)} | billing-portal | Billings > Savings Plans > Inventory | 2026-09 메뉴",
                review=f"review_by: {days(30)}",
            ),
            "pitfall review_by is more than 180 days after its oldest source check",
        )

    def test_pitfall_review_date_at_the_limit_passes(self) -> None:
        self.assert_pitfall_accepted(pitfall_card(review=f"review_by: {days(180)}"))

    def test_pitfall_internal_share_still_ages(self) -> None:
        """사내 공유는 누가 전했든 바깥 세상에 대한 주장이다 — 루트 이메일 사례가 그랬다."""
        self.assert_pitfall_rejected(
            pitfall_card(sources=f"  - {days(0)} | internal-share | aws-tips | 표기 없음", review="", facts="- x"),
            "pitfall card with aging sources has no review_by",
        )

    def test_pitfall_ticket_only_lesson_needs_no_review_date(self) -> None:
        """이미 일어난 사건의 기록은 낡지 않는다."""
        self.assert_pitfall_accepted(
            pitfall_card(sources=f"  - {days(0)} | ticket | ticket 100012 | 해당 없음", review="", facts="- x")
        )

    def test_pitfall_body_url_must_be_listed_in_sources(self) -> None:
        """본문에 인용한 문서가 조회일·버전 없이 들어오는 길을 막는다."""
        self.assert_pitfall_rejected(
            pitfall_card(facts="- 된다 → https://docs.aws.amazon.com/UNLISTED.html"),
            "pitfall body cites a URL missing from sources: https://docs.aws.amazon.com/UNLISTED.html",
        )

    def test_pitfall_body_url_fragment_matches_its_source(self) -> None:
        self.assert_pitfall_accepted(pitfall_card(facts=f"- 된다 → {DOC_URL}#section-2."))

    def test_pitfall_empty_section_is_rejected(self) -> None:
        self.assert_pitfall_rejected(pitfall_card(body="<!-- 나중에 -->"), "pitfall card section is empty")

    def test_pitfall_missing_section_is_rejected(self) -> None:
        self.assert_pitfall_rejected(
            pitfall_card().replace("## 해야 할 것", "## 기타"), "pitfall card missing section: ## 해야 할 것"
        )

    def test_pitfall_change_log_needs_a_dated_line(self) -> None:
        self.assert_pitfall_rejected(pitfall_card(log="- 작성"), "pitfall change log has no dated entry")

    # --- 규칙(policy/) 카드 — 2026-09-30 검토에서 active 카드 변형 10개 중 9개가 통과했다.
    # 테스트마다 그 허점 하나다. review_by 는 카드마다 정하되 reviewed_at + 1년을 넘지 못한다.

    def write_policy(self, card: str, route: str | None = None) -> None:
        (self.repo / POLICY_CARD).write_text(card, encoding="utf-8")
        routing = self.repo / "policy/_routing.md"
        lines = [line for line in routing.read_text(encoding="utf-8").split("\n") if "`POLICY-TEST-001`" not in line]
        separator = next(i for i, line in enumerate(lines) if line.startswith("|---"))
        lines.insert(separator + 1, route or policy_route())
        routing.write_text("\n".join(lines), encoding="utf-8")

    def assert_policy_rejected(self, card: str, marker: str, route: str | None = None) -> None:
        self.write_policy(card, route)
        self.assert_rejected(self.run_validator(), marker)

    def assert_policy_accepted(self, card: str, route: str | None = None) -> None:
        self.write_policy(card, route)
        result = self.run_validator()
        self.assertEqual(result.returncode, 0, result.stdout)

    def test_policy_well_formed_active_card_passes(self) -> None:
        self.assert_policy_accepted(policy_card())

    def test_policy_active_card_needs_a_registered_source(self) -> None:
        """회사 규칙이라면서 근거 문서 없이 active 가 되는 길."""
        self.assert_policy_rejected(policy_card(source_document='""'),
                                    "active policy card source_document is not a registered source")

    def test_policy_review_date_cannot_run_far_ahead(self) -> None:
        self.assert_policy_rejected(policy_card(review_by="2999-01-01"),
                                    "active policy card review_by is more than 365 days after reviewed_at",
                                    route=policy_route(review="2999-01-01"))

    def test_policy_review_date_counts_from_the_last_review(self) -> None:
        """원문을 다시 열지 않고 기한만 미는 것."""
        self.assert_policy_rejected(policy_card(reviewed_at=days(-400), review_by=days(30)),
                                    "active policy card review_by is more than 365 days after reviewed_at",
                                    route=policy_route(review=days(30)))

    def test_policy_review_date_in_the_past_is_rejected(self) -> None:
        self.assert_policy_rejected(policy_card(reviewed_at=days(-100), review_by=days(-1)),
                                    "active policy card review date has passed",
                                    route=policy_route(review=days(-1)))

    def test_policy_impossible_review_record_date_is_rejected(self) -> None:
        self.assert_policy_rejected(policy_card(reviewed_at="2026-13-45"),
                                    "active policy card has invalid reviewed_at")

    def test_policy_review_date_at_the_limit_passes(self) -> None:
        self.assert_policy_accepted(policy_card(review_by=days(365)), route=policy_route(review=days(365)))

    def test_policy_compact_review_date_is_rejected(self) -> None:
        compact = days(90).replace("-", "")
        self.assert_policy_rejected(policy_card(review_by=compact), "active policy card has invalid review_by",
                                    route=policy_route(review=compact))

    def test_policy_future_review_record_is_rejected(self) -> None:
        self.assert_policy_rejected(policy_card(reviewed_at=days(1)),
                                    "active policy card date is in the future: reviewed_at")

    def test_policy_impossible_effective_date_is_rejected(self) -> None:
        self.assert_policy_rejected(policy_card(effective_from="2026-13-45"),
                                    "active policy card has invalid effective_from",
                                    route=policy_route(effective="2026-13-45"))

    def test_policy_approval_needs_a_date(self) -> None:
        self.assert_policy_rejected(policy_card(approved_at='"어제쯤"'),
                                    "active policy card approved_at does not start with a date")

    def test_policy_future_authority_check_is_rejected(self) -> None:
        self.assert_policy_rejected(policy_card(authority_verified_at=f'"{days(1)} KST"'),
                                    "active policy card date is in the future: authority_verified_at")

    def test_policy_placeholder_source_version_is_rejected(self) -> None:
        for dodge in ['"-"', '"?"', '"n/a"']:
            with self.subTest(dodge=dodge):
                self.assert_policy_rejected(policy_card(source_version=dodge),
                                            "active policy card missing verified source_version")

    def test_policy_superseded_card_needs_an_existing_replacement(self) -> None:
        """policy/README.md: superseded 는 대체 카드에 연결해야 한다 — 검사가 없었다."""
        self.assert_policy_rejected(policy_card(status="superseded"),
                                    "superseded policy card replacement is not an existing card id",
                                    route=policy_route(status="superseded"))

    def test_policy_superseded_card_with_a_replacement_passes(self) -> None:
        self.assert_policy_accepted(policy_card(status="superseded", replacement="POLICY-COST-ESC-001"),
                                    route=policy_route(status="superseded"))

    def test_policy_empty_control_statement_is_rejected(self) -> None:
        self.assert_policy_rejected(policy_card(control="<!-- 나중에 -->"),
                                    "active policy card section is empty: ## Control statement")

    def test_policy_missing_section_is_rejected(self) -> None:
        self.assert_policy_rejected(policy_card().replace("## Scope", "## Notes"),
                                    "active policy card missing section: ## Scope")

    def test_policy_change_history_needs_a_dated_line(self) -> None:
        self.assert_policy_rejected(policy_card(history="- activated"),
                                    "active policy card change history has no dated entry")

    def test_policy_routing_dates_must_match_the_card(self) -> None:
        """라우팅 표에도 발효일·기한이 있다. 카드만 고치면 둘이 어긋난 채 통과했다."""
        self.assert_policy_rejected(policy_card(), "routing review_by differs from card: POLICY-TEST-001",
                                    route=policy_route(review=days(91)))


class GitignoredRelativesTests(unittest.TestCase):
    """gitignored_relatives must recognize non-ASCII paths that git ignores.

    git 기본값(core.quotePath=true)이면 check-ignore 가 한글 경로를 8진수 이스케이프와
    따옴표로 싸서 돌려주어 입력 경로와 비교가 어긋난다. 그 결과 gitignore 된 한글 이름
    파일이 무시 목록에서 빠지고 유출 스캔에 걸린다."""

    def setUp(self) -> None:
        self.module = _load_validator_module()
        self.tempdir = tempfile.TemporaryDirectory(prefix="tiket-checkignore-test-")
        self.repo = Path(self.tempdir.name) / "repo"
        self.repo.mkdir()
        subprocess.run(["git", "init", "-q"], cwd=self.repo, check=True)
        self._saved_root = self.module.ROOT
        self.module.ROOT = self.repo

    def tearDown(self) -> None:
        self.module.ROOT = self._saved_root
        self.tempdir.cleanup()

    def test_gitignored_korean_filename_is_recognized(self) -> None:
        # Arrange: a .gitignore'd file whose name is Korean (non-ASCII).
        (self.repo / ".gitignore").write_text("비밀.md\n", encoding="utf-8")
        secret = self.repo / "비밀.md"
        secret.write_text("x\n", encoding="utf-8")

        # Act
        ignored = self.module.gitignored_relatives([secret])

        # Assert: it must appear in the ignore set so the leak scan skips it.
        self.assertIn("비밀.md", ignored)

    def test_gitignored_ascii_filename_still_recognized(self) -> None:
        # Guard: the fix must not break the common ASCII case.
        (self.repo / ".gitignore").write_text("secret.md\n", encoding="utf-8")
        secret = self.repo / "secret.md"
        secret.write_text("x\n", encoding="utf-8")

        ignored = self.module.gitignored_relatives([secret])

        self.assertIn("secret.md", ignored)


if __name__ == "__main__":
    unittest.main()
