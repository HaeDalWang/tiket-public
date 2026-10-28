#!/usr/bin/env python3
"""local_capabilities — 이 PC 에서 아직 안 되는 기능을 파일만 보고 가린다.

임시 HOME 에 conf·AWS 설정을 만들어 판단을 본다. 네트워크에 닿지 않는다.
"""

from __future__ import annotations

import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))

import kiro_permissions  # noqa: E402
import local_capabilities as lc  # noqa: E402

KIRO_ROOT = Path("/tmp/tiket")

SECRET = "tok-should-never-print"
ALL_TOOLS = lambda name: f"/usr/bin/{name}"  # noqa: E731


class LocalCapabilityTests(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory(prefix="tiket-capabilities-")
        self.home = Path(self._tmp.name)
        # 다른 기능을 보는 테스트가 특이사항 줄에 흔들리지 않게 기본으로 둔다. 없는 경우는 따로 본다.
        self.itsm(f"ITSM_API_TOKEN={SECRET}")

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def zendesk(self, *lines: str) -> None:
        conf = self.home / ".config/msp/zendesk.conf"
        conf.parent.mkdir(parents=True, exist_ok=True)
        conf.write_text("\n".join(("# tiket Zendesk credentials", *lines)) + "\n", encoding="utf-8")

    def itsm(self, *lines: str) -> None:
        conf = self.home / ".config/msp/itsm"
        conf.parent.mkdir(parents=True, exist_ok=True)
        conf.write_text("\n".join(lines) + "\n", encoding="utf-8")

    def full_zendesk(self) -> None:
        self.zendesk("ZENDESK_SUBDOMAIN=example", "ZENDESK_EMAIL=agent-login", f"ZENDESK_API_TOKEN={SECRET}")

    def skill(self, *, marker_exists: bool = True, config: Path | None = None) -> None:
        marker = self.home / "skills/aws-customer-account-ops/get-sts-token.sh"
        if marker_exists:
            marker.parent.mkdir(parents=True, exist_ok=True)
            marker.write_text("#!/bin/sh\n", encoding="utf-8")
        config = config or self.home / ".aws/config"
        config.parent.mkdir(parents=True, exist_ok=True)
        config.write_text(
            "[default]\nregion = ap-northeast-2\n\n"
            f"[profile csg-login]\ncredential_process = {marker}\n",
            encoding="utf-8",
        )

    def missing(self, env: dict[str, str] | None = None, os_name: str = "posix", which=ALL_TOOLS) -> dict:
        return lc.missing(self.home, env or {}, os_name, which)

    # ── 다 된다 ───────────────────────────────────────────────────────────

    def test_nothing_missing_when_everything_is_set_up(self) -> None:
        self.full_zendesk()
        self.skill()
        self.assertEqual(self.missing(), {})

    # ── 티켓 가져오기 ─────────────────────────────────────────────────────

    def test_no_zendesk_conf_means_no_ticket_fetch(self) -> None:
        self.skill()
        self.assertEqual(self.missing(), {lc.TICKET_FETCH: ["Zendesk 미설정"]})

    def test_each_zendesk_key_is_required(self) -> None:
        self.skill()
        keys = ["ZENDESK_SUBDOMAIN=example", "ZENDESK_EMAIL=agent-login", f"ZENDESK_API_TOKEN={SECRET}"]
        for dropped in range(len(keys)):
            with self.subTest(dropped=keys[dropped]):
                self.zendesk(*(k for i, k in enumerate(keys) if i != dropped))
                self.assertIn(lc.TICKET_FETCH, self.missing())

    def test_an_empty_value_is_not_a_credential(self) -> None:
        self.skill()
        self.zendesk("ZENDESK_SUBDOMAIN=example", "ZENDESK_EMAIL=agent-login", "ZENDESK_API_TOKEN=")
        self.assertIn(lc.TICKET_FETCH, self.missing())

    def test_environment_variables_count_like_fetch_ticket(self) -> None:
        """fetch-ticket 은 환경변수 → 외부 스킬 이름 → conf 순으로 읽는다."""
        self.skill()
        self.zendesk("ZENDESK_SUBDOMAIN=example")
        env = {"ZENDESK_EMAIL": "agent-login", "Zendesk_API": SECRET}
        self.assertEqual(self.missing(env), {})

    def test_posix_needs_curl_and_jq_for_ticket_fetch(self) -> None:
        self.full_zendesk()
        self.skill()
        no_jq = lambda name: None if name == "jq" else f"/usr/bin/{name}"  # noqa: E731
        self.assertEqual(self.missing(which=no_jq), {lc.TICKET_FETCH: ["jq 없음"]})

    def test_windows_fetch_does_not_need_curl_or_jq(self) -> None:
        self.full_zendesk()
        self.skill()
        self.assertEqual(self.missing(os_name="nt", which=lambda name: None), {})

    # ── 고객 조회 ─────────────────────────────────────────────────────────

    def test_no_aws_config_means_no_customer_lookup(self) -> None:
        self.full_zendesk()
        self.assertEqual(self.missing(), {lc.CUSTOMER_LOOKUP: ["스킬 미설치"]})

    def test_a_marker_pointing_at_nothing_is_not_installed(self) -> None:
        self.full_zendesk()
        self.skill(marker_exists=False)
        self.assertIn(lc.CUSTOMER_LOOKUP, self.missing())

    def test_the_windows_marker_form_counts_as_installed(self) -> None:
        """Windows 마커는 `pwsh -NoProfile -File "<경로>"` 다 — 값 전체를 경로로 보면 늘 미설치로 나온다."""
        self.full_zendesk()
        script = self.home / "skills/aws-customer-account-ops/get-sts-token.ps1"
        script.parent.mkdir(parents=True)
        script.write_text("#\n", encoding="utf-8")
        config = self.home / ".aws/config"
        config.parent.mkdir(parents=True)
        config.write_text(f'[profile csg-login]\ncredential_process = pwsh -NoProfile -File "{script}"\n', encoding="utf-8")
        self.assertEqual(self.missing(os_name="nt"), {})

    def test_aws_config_file_variable_is_honoured(self) -> None:
        self.full_zendesk()
        elsewhere = self.home / "elsewhere/config"
        self.skill(config=elsewhere)
        self.assertEqual(self.missing({"AWS_CONFIG_FILE": str(elsewhere)}), {})

    def test_a_messy_aws_config_does_not_crash(self) -> None:
        self.full_zendesk()
        config = self.home / ".aws/config"
        config.parent.mkdir(parents=True)
        config.write_text("[default]\n[default]\nregion = a\nregion = b\nnot a pair\n", encoding="utf-8")
        self.assertIn(lc.CUSTOMER_LOOKUP, self.missing())

    # ── 고객 특이사항 ─────────────────────────────────────────────────────
    # 토큰이 없으면 customer_notes.py 가 멈추고, 라우터는 그 고객의 계정 조회를 멈춘다 (0034).

    def test_no_itsm_token_means_no_customer_notes(self) -> None:
        self.full_zendesk()
        self.skill()
        (self.home / ".config/msp/itsm").unlink()
        self.assertEqual(self.missing(), {lc.CUSTOMER_NOTES: ["ITSM 토큰 없음"]})

    def test_only_the_dev_token_is_not_enough(self) -> None:
        self.full_zendesk()
        self.skill()
        self.itsm("DEV_ITSM_API_TOKEN=dev-value", "ITSM_API_TOKEN=")
        self.assertEqual(self.missing(), {lc.CUSTOMER_NOTES: ["ITSM 토큰 없음"]})

    def test_session_line_names_the_missing_token_without_values(self) -> None:
        self.full_zendesk()
        self.skill()
        self.itsm(f"DEV_ITSM_API_TOKEN={SECRET}")
        out = self.run_script("--if-missing")
        self.assertIn("고객 특이사항 읽기(ITSM 토큰 없음)", out)
        self.assertIn("설정: bash scripts/onboarding.sh", out)
        self.assertNotIn(SECRET, out)

    # ── Kiro 승인 창 ──────────────────────────────────────────────────────
    # 온보딩은 한 번뿐이라, 그 뒤에 생긴 설정은 세션 시작이 알린다. 권한 규칙은 여기서 넣지 않는다 —
    # 세션 훅은 저장소가 싣고 온 명령이라, 거기서 쓰면 Kiro 가 막은 "저장소가 권한을 주입한다" 가 된다 (0030).

    def kiro_gap(self, os_name: str = "posix") -> dict:
        self.full_zendesk()
        self.skill()
        return lc.missing(self.home, {}, os_name, ALL_TOOLS, root=KIRO_ROOT)

    def test_people_without_kiro_hear_nothing_about_it(self) -> None:
        self.assertEqual(self.kiro_gap(), {})

    def test_kiro_user_without_the_rules_is_told(self) -> None:
        (self.home / ".kiro").mkdir()
        self.assertEqual(self.kiro_gap(), {lc.KIRO_PROMPTS: ["권한 규칙 미설치"]})

    def test_installed_rules_end_the_notice(self) -> None:
        (self.home / ".kiro").mkdir()
        self.assertEqual(kiro_permissions.install(KIRO_ROOT, self.home, "posix")[0], 0)
        self.assertEqual(self.kiro_gap(), {})

    def test_a_pc_where_the_rules_cannot_be_installed_is_not_nagged(self) -> None:
        """Windows 는 Kiro 가 만든 폴더가 없으면 넣을 곳을 모른다. 온보딩으로 못 고치는 것을 매 세션 말하지 않는다."""
        (self.home / ".kiro").mkdir()
        self.assertEqual(self.kiro_gap("nt"), {})

    def test_session_never_writes_the_rules(self) -> None:
        (self.home / ".kiro").mkdir()
        self.full_zendesk()
        self.skill()
        self.assertIn("Kiro 승인 창 줄이기(권한 규칙 미설치)", self.run_script("--if-missing"))
        self.assertEqual([p.name for p in (self.home / ".kiro").iterdir()], [])

    def test_session_refreshes_an_outdated_block_and_says_so(self) -> None:
        """이미 우리 블록이 든 PC 는 세션 시작이 지금 규칙으로 맞추고 한 줄을 낸다. 새로 넣지는 않는다."""
        target = self.home / ".kiro/workspace-roots" / kiro_permissions.workspace_dir(
            ROOT, self.home).name / "permissions.yaml"
        target.parent.mkdir(parents=True)
        target.write_text(
            "rules:\n" + f"{kiro_permissions.BEGIN}\n  - capability: shell\n    effect: allow\n"
            "    match:\n      - \"old-rule *\"\n" + f"{kiro_permissions.END}\n", encoding="utf-8")
        out = self.run_script("--if-missing")
        self.assertIn("최신으로 맞췄다", out)
        self.assertIn("effect: deny", target.read_text(encoding="utf-8"))

    @unittest.skipUnless((ROOT / ".git").is_dir(), "전환은 메인 체크아웃에서만 돈다")
    def test_session_moves_the_skill_into_the_workspace_and_says_so(self) -> None:
        """세부는 test_skill_migration.py. 여기는 세션 시작 경로가 부르는지와, 옮긴 뒤 설치됨으로 보이는지만."""
        old = self.home / ".kiro/skills/aws-customer-account-ops"
        old.mkdir(parents=True)
        (old / "get-sts-token.sh").write_text("#!/bin/sh\n", encoding="utf-8")
        config = self.home / ".aws/config"
        config.parent.mkdir(parents=True)
        config.write_text(f"[profile csg-login]\ncredential_process = {old}/get-sts-token.sh\n", encoding="utf-8")
        self.full_zendesk()
        out = self.run_script("--if-missing")
        self.assertIn("워크스페이스", out)
        self.assertNotIn("스킬 미설치", out)
        self.assertIn(str(ROOT / "skills/aws-customer-account-ops/get-sts-token.sh"), config.read_text(encoding="utf-8"))
        self.assertFalse(old.exists())

    # ── 출력 ──────────────────────────────────────────────────────────────

    def test_line_names_each_feature_with_its_reasons_and_the_fix(self) -> None:
        line = lc.render({lc.TICKET_FETCH: ["Zendesk 미설정", "jq 없음"], lc.CUSTOMER_LOOKUP: ["스킬 미설치"]}, "posix")
        self.assertEqual(
            line,
            "이 PC 에서 아직 안 되는 것: 티켓 번호로 가져오기(Zendesk 미설정·jq 없음), "
            "고객 AWS·비용 조회(스킬 미설치). 나머지는 쓸 수 있다. 설정: bash scripts/onboarding.sh",
        )

    def test_windows_line_points_at_the_powershell_onboarding(self) -> None:
        self.assertTrue(lc.render({lc.CUSTOMER_LOOKUP: ["스킬 미설치"]}, "nt").endswith("pwsh -File scripts/onboarding.ps1"))

    def run_script(self, *args: str) -> str:
        env = {**os.environ, "HOME": str(self.home), "USERPROFILE": str(self.home)}
        for name in ("ZENDESK_SUBDOMAIN", "ZENDESK_EMAIL", "ZENDESK_API_TOKEN",
                     "Zendesk_SUBDOMAIN", "Zendesk_EMAIL", "Zendesk_API", "AWS_CONFIG_FILE"):
            env.pop(name, None)
        result = subprocess.run([sys.executable, str(ROOT / "scripts/local_capabilities.py"), *args],
                                env=env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout

    def test_session_mode_is_silent_when_nothing_is_missing(self) -> None:
        self.full_zendesk()
        self.skill()
        self.assertEqual(self.run_script("--if-missing"), "")
        self.assertIn("다 된다", self.run_script())

    def test_session_mode_reports_what_is_missing_without_values(self) -> None:
        self.zendesk("ZENDESK_SUBDOMAIN=example", f"ZENDESK_API_TOKEN={SECRET}")
        out = self.run_script("--if-missing")
        self.assertIn("고객 AWS·비용 조회(스킬 미설치)", out)
        self.assertIn("Zendesk 미설정", out)
        self.assertNotIn(SECRET, out)
        self.assertNotIn("example", out)


if __name__ == "__main__":
    unittest.main(verbosity=2)
