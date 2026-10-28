#!/usr/bin/env python3
"""onboarding.sh 와 onboarding.ps1 이 어긋나지 않는지 검사한다.

두 스크립트는 서로 다른 OS 를 담당하므로 한쪽만 고치고 다른 쪽을 잊기 쉽다.
support-skills 에서 install.ps1 이 install.sh 의 파일 목록 두 개를 빠뜨린 채
배포돼 Windows 설치가 통째로 깨진 사고가 있었고, 그걸 잡는 테스트가 없어서
CI 를 그냥 통과했다. 같은 사고를 막는다.
"""

from __future__ import annotations

import json
import re
import shutil
import subprocess
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))

import local_capabilities as lc  # noqa: E402

SH = ROOT / "scripts/onboarding.sh"
PS1 = ROOT / "scripts/onboarding.ps1"
FETCH_SH = ROOT / "scripts/fetch-ticket.sh"
FETCH_PS1 = ROOT / "scripts/fetch-ticket.ps1"

BLOCK = re.compile(r"# STEPS-PARITY-START(.*?)# STEPS-PARITY-END", re.S)


def steps(path: Path) -> list[str]:
    text = path.read_text(encoding="utf-8")
    match = BLOCK.search(text)
    if match is None:
        raise AssertionError(f"STEPS-PARITY 블록이 없다: {path.name}")
    return re.findall(r'"([^"]+)"', match.group(1))


class OnboardingParityTests(unittest.TestCase):
    def test_both_scripts_exist(self) -> None:
        for path in (SH, PS1):
            self.assertTrue(path.is_file(), f"없음: {path}")

    def test_step_lists_are_identical_and_ordered(self) -> None:
        """단계 이름과 순서가 같아야 한다. 순서가 다르면 사용자 경험이 갈린다."""
        self.assertEqual(steps(SH), steps(PS1))

    def test_step_count_matches_progress_labels(self) -> None:
        """'[1/4]' 같은 진행 표시가 실제 단계 수와 맞아야 한다."""
        for path in (SH, PS1):
            declared = len(steps(path))
            labels = set(re.findall(r"(\d+)/(\d+)", path.read_text(encoding="utf-8")))
            totals = {int(total) for _, total in labels}
            self.assertIn(
                declared, totals, f"{path.name}: 단계 {declared}개인데 진행 표시는 {totals}"
            )

    def test_both_use_the_same_config_path(self) -> None:
        """설정 경로가 갈리면 OS 를 옮겼을 때 자격증명을 다시 넣어야 한다."""
        for path in (SH, PS1):
            text = path.read_text(encoding="utf-8")
            self.assertIn(".config/msp", text, f"{path.name}: 공통 설정 경로를 안 쓴다")
            self.assertIn("zendesk.conf", text)

    def test_both_declare_the_same_conf_keys(self) -> None:
        keys = {"ZENDESK_SUBDOMAIN", "ZENDESK_EMAIL", "ZENDESK_API_TOKEN"}
        for path in (SH, PS1):
            text = path.read_text(encoding="utf-8")
            for key in keys:
                self.assertIn(key, text, f"{path.name}: {key} 누락")

    def test_neither_touches_a_shell_profile(self) -> None:
        """셸 프로필을 건드리면 그 셸을 안 쓰는 사람에게서 조용히 실패한다."""
        for path in (SH, PS1):
            text = path.read_text(encoding="utf-8")
            for profile in (".zshenv", ".zshrc", ".bashrc", ".bash_profile", "$PROFILE"):
                # 주석에서 '안 건드린다'고 설명하는 건 허용, 실제 쓰기는 금지.
                for line in text.splitlines():
                    stripped = line.strip()
                    if profile in stripped and not stripped.startswith("#"):
                        self.fail(f"{path.name}: 셸 프로필 참조: {stripped}")

    def test_token_input_is_hidden_in_both(self) -> None:
        self.assertIn("read -rs", SH.read_text(encoding="utf-8"))
        self.assertIn("-AsSecureString", PS1.read_text(encoding="utf-8"))

    def test_skipping_requires_an_explicit_word(self) -> None:
        """빈 Enter 로 건너뛰게 두면 대부분 그걸 누르고, 나중에 안 된다고 되돌아온다."""
        for path in (SH, PS1):
            text = path.read_text(encoding="utf-8")
            self.assertIn('"skip"', text, f"{path.name}: 명시적 skip 입력이 없다")
            self.assertIn("값이 필요하다", text, f"{path.name}: 빈 입력 재질문이 없다")

    def test_email_prompt_is_not_called_agent_email(self) -> None:
        """이 저장소에서 '에이전트'는 AI 도구다. Zendesk 의 agent(상담원)와 겹치면
        읽는 사람이 자기 이메일을 넣는 자리인지 알 수 없다."""
        for path in (SH, PS1):
            text = path.read_text(encoding="utf-8")
            self.assertNotIn("에이전트 이메일", text, f"{path.name}: 모호한 라벨")
            self.assertIn("Zendesk 로그인 이메일", text, f"{path.name}: 명확한 라벨이 없다")

    def test_both_default_the_engineer_name_to_the_zendesk_agent(self) -> None:
        """6단계에서 이미 자기 Zendesk 자격증명을 넣는다. 거기 있는 상담사 이름이
        git user.name 보다 사람 이름에 가깝다 — 지표 이름의 기본값으로 제시한다."""
        self.assertIn("zendesk_agent_name", SH.read_text(encoding="utf-8"))
        self.assertIn("Get-ZendeskAgentName", PS1.read_text(encoding="utf-8"))

    def test_both_fall_back_when_zendesk_is_unavailable(self) -> None:
        """Zendesk 가 안 되거나 자격증명이 없어도 온보딩이 멈추면 안 된다."""
        for path in (SH, PS1):
            self.assertIn("git config user.name", path.read_text(encoding="utf-8"))

    def test_both_reject_an_email_shaped_agent_name(self) -> None:
        """Zendesk 이름이 이메일 형태인 계정이 있다. 그대로 쓰면 지표가 422 로 거절된다."""
        self.assertIn("*@*.*", SH.read_text(encoding="utf-8"))
        self.assertIn("EMAIL_SHAPED", PS1.read_text(encoding="utf-8"))

    def test_both_list_the_same_agent_homes(self) -> None:
        """에이전트 경로 테이블이 갈리면 한쪽 OS 에서만 스킬을 못 찾는다."""
        homes = [".claude", ".config/opencode", ".kiro", ".cursor",
                 ".codeium/windsurf", ".augment", ".agents", ".gemini", ".hermes"]
        for path in (SH, PS1):
            text = path.read_text(encoding="utf-8")
            for home in homes:
                self.assertIn(home, text, f"{path.name}: 에이전트 경로 {home} 누락")

    def test_broker_defaults_carry_only_what_the_client_reads(self) -> None:
        """온보딩이 conf 를 만들 때 쓰는 설치 상수. 들인 스크립트가 conf 에서 읽는 것은 둘뿐이다 —
        EXTERNAL_ID·역할 ARN 은 브로커가 서버에서 해석하게 된 뒤로 아무도 안 읽는다 (0040, 2026-10-20)."""
        path = ROOT / "skills" / "aws-customer-account-ops" / "broker-defaults.conf"
        lines = [line for line in path.read_text(encoding="utf-8").splitlines() if line and not line.startswith("#")]
        values = dict(line.split("=", 1) for line in lines)
        self.assertEqual(sorted(values), ["API_URL", "CLIENT_ID"])
        self.assertRegex(values["API_URL"], r"^https://[a-z0-9.-]+/Prod/v1/credentials$")
        self.assertRegex(values["CLIENT_ID"], r"^\d+\.\d+$")

    def test_skill_client_is_vendored_and_the_old_installer_is_gone(self) -> None:
        """스킬 클라이언트는 이 저장소에 있다 (0040, 0014 를 뒤집었다). 온보딩은 더 이상 스킬 저장소에서
        받지 않는다 — gh·조직 접근·태그 clone·사본 해시 대조가 다 빠졌다 (계획서 3단계 C-2, 2026-10-20)."""
        skill = ROOT / "skills" / "aws-customer-account-ops"
        for name in ("SKILL.md", "get-customer-credentials.sh", "get-customer-credentials.ps1"):
            self.assertTrue((skill / name).is_file(), f"들인 스킬에 {name} 이 없다")
        # 워크플로에서 부르지 않는 옛 조회 스크립트 — 내부 Lambda ARN 이 박혀 있어 들이지 않았다.
        self.assertFalse((skill / "get_account_info.sh").exists())
        for path in (SH, PS1):
            code = "\n".join(code_lines(path))
            for gone in ("support-skills", "bootstrap", "gh auth", " clone "):
                self.assertNotIn(gone, code, f"{path.name}: 옛 설치 경로가 남았다: {gone}")

    def test_onboarding_sets_up_the_skill_unless_checking(self) -> None:
        """conf·csg-login 마커·빌링 플랫폼 키는 scripts/skill_setup.py 한 곳이 맞춘다 — 두 OS 가 같은 판단을 쓴다.
        --check 는 아무것도 바꾸지 않는다. 입력을 받아야 하므로 stderr 를 버리지 않는다."""
        expected = {
            SH: ('skill_setup_arg=""\n'
                 '[ "$CHECK_ONLY" -eq 0 ] && skill_setup_arg="--install"\n'
                 'if skill_state=$(python3 "$ROOT/scripts/skill_setup.py" $skill_setup_arg); then\n'),
            PS1: ('    $skillSetupArgs = @()\n'
                  '    if (-not $Check) { $skillSetupArgs = @("--install") }\n'
                  '    $skillState = (& $kiroPy.Source (Join-Path $Root "scripts/skill_setup.py") @skillSetupArgs) -join "`n"\n'),
        }
        for path in (SH, PS1):
            self.assertIn(expected[path], path.read_text(encoding="utf-8"), path.name)

    def test_onboarding_asks_for_the_itsm_token_right_after_zendesk(self) -> None:
        """각자 본인 토큰을 발급해 넣는다 (0034 개정 1). 판단·저장은 scripts/itsm_token.py 한 곳이라 두 OS 가
        같은 파일을 같은 방식으로 쓴다 — 다른 키는 그대로 둔다. --check 는 아무것도 바꾸지 않는다. 입력을 받아야
        하므로 stderr 를 버리지 않는다."""
        names = steps(SH)
        self.assertEqual(names[names.index("zendesk-credentials") + 1], "itsm-token")
        expected = {
            SH: ('itsm_arg=""\n'
                 '[ "$CHECK_ONLY" -eq 0 ] && itsm_arg="--install"\n'
                 'if itsm_state=$(python3 "$ROOT/scripts/itsm_token.py" $itsm_arg); then\n'
                 '  ok "$itsm_state"\n'
                 'else\n'
                 '  limited "$F_NOTES" '),
            PS1: ('    $itsmArgs = @()\n'
                  '    if (-not $Check) { $itsmArgs = @("--install") }\n'
                  '    $itsmState = (& $kiroPy.Source (Join-Path $Root "scripts/itsm_token.py") @itsmArgs) -join "`n"\n'
                  '    if ($LASTEXITCODE -eq 0) { Write-Ok $itsmState } else { Write-Limited $FNotes $itsmState }\n'),
        }
        for path in (SH, PS1):
            self.assertIn(expected[path], path.read_text(encoding="utf-8"), path.name)

    def test_both_support_a_non_interactive_check_mode(self) -> None:
        self.assertIn("--check", SH.read_text(encoding="utf-8"))
        self.assertIn("$Check", PS1.read_text(encoding="utf-8"))

    def test_onboarding_installs_kiro_permission_rules_unless_checking(self) -> None:
        """Kiro 권한 규칙은 사용자 PC 에만 둘 수 있다(kiro.dev/docs/permissions). 명령을 따로 돌리라고 하면
        아무도 안 돌린다 — 온보딩이 바로 넣는다(0030, 2026-10-01 개정). --check 는 아무것도 바꾸지 않는다.
        IDE 만 쓰는 사람도 받도록 kiro-cli 가 아니라 ~/.kiro 로 가른다."""
        expected = {
            SH: ('if [ -d "$HOME/.kiro" ]; then\n'
                 '  kiro_rules_arg=""\n'
                 '  [ "$CHECK_ONLY" -eq 0 ] && kiro_rules_arg="--install"\n'
                 '  if kiro_rules=$(python3 "$ROOT/scripts/kiro_permissions.py" $kiro_rules_arg 2>/dev/null); then\n'),
            PS1: ('if ((Test-Path (Join-Path $HOME ".kiro")) -and $kiroPy) {\n'
                  '    $kiroRulesArgs = @()\n'
                  '    if (-not $Check) { $kiroRulesArgs = @("--install") }\n'
                  '    $kiroRules = (& $kiroPy.Source (Join-Path $Root "scripts/kiro_permissions.py") @kiroRulesArgs 2>$null)'),
        }
        for path in (SH, PS1):
            self.assertIn(expected[path], path.read_text(encoding="utf-8"), path.name)


OUTCOME = re.compile(r"# OUTCOME-START\n(.*?)# OUTCOME-END", re.S)
# 막힘은 워크스페이스가 아예 안 돌거나 경계가 깨지는 것뿐이다.
BLOCKED_TOPICS = ("core.hooksPath", "pre-push", "MCP 설정 누락", "감지된 에이전트 없음")
BLOCKED_ALLOWED = BLOCKED_TOPICS + ("$bin 없음", "$mcp_last", "$mcpLast")
HELPERS = {SH: ("blocked", "limited"), PS1: ("Write-Blocked", "Write-Limited")}
FEATURE_ARG = {SH: r'limited "\$F_[A-Z]+" ', PS1: r"Write-Limited \$F[A-Z]\w* "}
PWSH = shutil.which("pwsh")


def code_lines(path: Path) -> list[str]:
    lines = (line.strip() for line in path.read_text(encoding="utf-8").splitlines())
    return [line for line in lines if line and not line.startswith("#")]


def calls(path: Path, helper: str) -> list[str]:
    pattern = re.compile(rf"(^|[\s;{{(|&]){re.escape(helper)} ")
    definition = (f"{helper}()", "function ")
    return [line for line in code_lines(path) if pattern.search(line) and not line.startswith(definition)]


class OnboardingOutcomeTests(unittest.TestCase):
    """하나만 빠져도 빨간 FAIL·exit 1 이라 동료가 유지보수자를 불렀다 (2026-10-01).
    막힘 — 워크스페이스가 안 돌거나 경계가 깨진다. 제한 — 그 기능만 빠지고 나머지는 돈다."""

    def test_nothing_is_called_a_failure(self) -> None:
        for path in (SH, PS1):
            for line in code_lines(path):
                self.assertNotIn("FAIL", line, f"{path.name}: {line}")
                self.assertNotIn("실패", line, f"{path.name}: {line}")

    def test_blocked_is_only_for_what_stops_the_workspace(self) -> None:
        for path, (blocked, _) in HELPERS.items():
            lines = calls(path, blocked)
            for line in lines:
                self.assertTrue(any(topic in line for topic in BLOCKED_ALLOWED), f"{path.name}: 막힘이 아니다: {line}")
            for topic in BLOCKED_TOPICS:
                self.assertTrue(any(topic in line for line in lines), f"{path.name}: {topic} 이 막힘이 아니다")

    def test_every_limit_names_the_feature_it_takes_away(self) -> None:
        for path, (_, limited) in HELPERS.items():
            lines = calls(path, limited)
            self.assertGreater(len(lines), 5, path.name)
            for line in lines:
                self.assertRegex(line, FEATURE_ARG[path], f"{path.name}: 기능 이름 없음")

    def test_feature_names_match_the_session_notice(self) -> None:
        """세션 시작 알림(local_capabilities.py)과 같은 말이어야 같은 기능으로 읽힌다."""
        sh, ps1 = SH.read_text(encoding="utf-8"), PS1.read_text(encoding="utf-8")
        for name, label in (("TICKET", lc.TICKET_FETCH), ("CUSTOMER", lc.CUSTOMER_LOOKUP),
                            ("NOTES", lc.CUSTOMER_NOTES)):
            self.assertIn(f'F_{name}="{label}"', sh)
            self.assertIn(f'$F{name.title()} = "{label}"', ps1)

    def test_success_tells_them_to_open_this_folder(self) -> None:
        """상위 폴더를 열면 규칙·훅·MCP 가 에러 없이 빠진다 (2026-10-01, Kiro IDE 동료).
        저장소는 그 상태를 스스로 알 길이 없다 — 온보딩 끝의 한 줄이 유일한 알림이다."""
        for path in (SH, PS1):
            if path == PS1 and PWSH is None:
                continue  # pwsh 가 없는 PC·CI 에서는 sh 쪽만 본다
            result = self.finish(path, [])
            self.assertEqual(result.returncode, 0, path.name)
            self.assertIn("상위 폴더를 열면", result.stdout, path.name)

    # ── 결과 줄과 종료 코드 — 실제로 돌려 본다 ──────────────────────────

    def finish(self, path: Path, body: list[str]) -> subprocess.CompletedProcess:
        block = OUTCOME.search(path.read_text(encoding="utf-8"))
        self.assertIsNotNone(block, f"{path.name}: OUTCOME 블록 없음")
        if path == SH:
            return subprocess.run(["bash", "-c", "\n".join([block.group(1), *body, "finish"])],
                                  capture_output=True, text=True)
        return subprocess.run([PWSH, "-NoProfile", "-Command", "\n".join([block.group(1), *body, "Complete-Onboarding"])],
                              capture_output=True, text=True)

    def scenarios(self) -> list[tuple[Path, dict[str, list[str]]]]:
        sh = {
            "limited": ['limited "$F_TICKET" "a"', 'limited "$F_TICKET" "b"', 'limited "$F_CUSTOMER" "c"'],
            "blocked": ['blocked "core.hooksPath 미설정"', 'limited "$F_TICKET" "a"'],
            "clean": ['ok "git"'],
        }
        ps1 = {
            "limited": ['Write-Limited $FTicket "a"', 'Write-Limited $FTicket "b"', 'Write-Limited $FCustomer "c"'],
            "blocked": ['Write-Blocked "core.hooksPath 미설정"', 'Write-Limited $FTicket "a"'],
            "clean": ['Write-Ok "git"'],
        }
        return [(SH, sh)] + ([(PS1, ps1)] if PWSH else [])

    def test_limits_alone_still_complete_onboarding(self) -> None:
        for path, bodies in self.scenarios():
            result = self.finish(path, bodies["limited"])
            self.assertEqual(result.returncode, 0, f"{path.name}: {result.stdout}{result.stderr}")
            self.assertIn("온보딩 완료", result.stdout, path.name)
            self.assertIn(f"이 PC 에서 아직 안 되는 것: {lc.TICKET_FETCH}, {lc.CUSTOMER_LOOKUP} ", result.stdout, path.name)

    def test_only_a_block_fails_the_run(self) -> None:
        for path, bodies in self.scenarios():
            result = self.finish(path, bodies["blocked"])
            self.assertEqual(result.returncode, 1, f"{path.name}: {result.stdout}{result.stderr}")
            self.assertIn("막힌 항목 1개", result.stdout, path.name)
            self.assertNotIn("온보딩 완료", result.stdout, path.name)
            self.assertIn(f"이 PC 에서 아직 안 되는 것: {lc.TICKET_FETCH} ", result.stdout, path.name)

    def test_a_clean_run_mentions_no_limits(self) -> None:
        for path, bodies in self.scenarios():
            result = self.finish(path, bodies["clean"])
            self.assertEqual(result.returncode, 0, f"{path.name}: {result.stdout}{result.stderr}")
            self.assertIn("온보딩 완료", result.stdout, path.name)
            self.assertNotIn("안 되는 것", result.stdout, path.name)


class FreshnessParityTests(unittest.TestCase):
    """check-freshness 의 .sh 와 .ps1 이 같은 계약을 지키는지 본다."""

    SH = ROOT / "scripts/check-freshness.sh"
    PS1 = ROOT / "scripts/check-freshness.ps1"

    def test_both_scripts_exist(self) -> None:
        for path in (self.SH, self.PS1):
            self.assertTrue(path.is_file(), f"없음: {path}")

    def test_only_fast_forwards_to_a_release_tag(self) -> None:
        """2026-09-24: 알리기만 하던 0016 을 0025 가 뒤집었다. 올리되 태그로만,
        fast-forward 로만 올린다. pull 은 태그 없는 main 을 끌어오므로 여전히 금지다.
        실제 동작은 test_check_freshness.py 가 git 저장소로 검사한다."""
        for path in (self.SH, self.PS1):
            text = path.read_text(encoding="utf-8")
            self.assertIn("release_tags.py", text, f"{path.name}: 정식 태그 선택 없음")
            self.assertIn("merge --ff-only", text, f"{path.name}: fast-forward 전용이 아니다")
            for line in text.splitlines():
                stripped = line.strip()
                if stripped.startswith("#"):
                    continue
                self.assertNotIn("git pull", stripped, f"{path.name}: pull 금지")

    def test_both_pin_the_canonical_remote(self) -> None:
        """origin 이 옛 주소면 fetch 가 성공하고 '뒤처짐 0' 이 나온다 — 거짓 초록불."""
        for path in (self.SH, self.PS1):
            text = path.read_text(encoding="utf-8")
            self.assertIn("github.com/example-org/tiket", text, f"{path.name}: 정본 remote 미고정")
            self.assertIn("set-url", text, f"{path.name}: 교정 명령 안내 없음")

    def test_both_throttle_and_support_force(self) -> None:
        for path in (self.SH, self.PS1):
            text = path.read_text(encoding="utf-8")
            self.assertIn("21600", text, f"{path.name}: 스로틀 간격(6시간)이 양쪽에서 다르다")
            self.assertIn("tiket-freshness", text, f"{path.name}: 스탬프 파일 없음")
        self.assertIn("--force", self.SH.read_text(encoding="utf-8"))
        self.assertIn("$Force", self.PS1.read_text(encoding="utf-8"))


# test_codex_hook_identity_is_pinned 참고. 바꾸면 Codex 사용자 전원이 다시 승인해야 한다.
PINNED_CODEX_HOOK_HASH = "sha256:22ce8824ddbed423ff6be900f6ed40a5e4e030fc852e91c5035dd37276e82030"  # v0.1.4 부터
PINNED_CODEX_WINDOWS_HOOK_HASH = "sha256:a8f66823f08e0c529cc3fe591cefd94c651b629a8430dc4ed47c061518017479"  # v0.1.5 부터


def effective_hosts(hosts: dict[str, str]) -> dict[str, str]:
    """Kiro 훅은 셸 차이 때문에 scripts/session_start.py 를 부른다(2026-09-29). 그 스크립트가
    실제로 부르는 것까지 따라가 같은 계약을 본다."""
    body = (ROOT / "scripts/session_start.py").read_text(encoding="utf-8")
    return {name: text + ("\n" + body if "scripts/session_start.py" in text else "") for name, text in hosts.items()}


class FreshnessHostCoverageTests(unittest.TestCase):
    """세션 훅이 Claude Code 하나만 덮던 것을 세 호스트로 넓힌 뒤의 회귀 방지 (0020)."""

    def hosts(self) -> dict[str, str]:
        import subprocess, sys
        subprocess.run(
            [sys.executable, str(ROOT / "scripts/render_agent_configs.py"), "--check"],
            check=True, capture_output=True,
        )
        return {
            name: (ROOT / name).read_text(encoding="utf-8")
            for name in (".claude/settings.json", ".codex/config.toml", ".kiro/hooks/session-start.json")
        }

    def test_every_hookable_host_runs_the_same_script(self) -> None:
        """판단 로직은 스크립트 하나에 있고 호스트 파일은 얇은 어댑터다.
        네 곳에 정책을 따로 적지 않는다 — agents/shared-agent-environment.md."""
        for name, text in effective_hosts(self.hosts()).items():
            self.assertIn("scripts/check-freshness.sh", text, f"{name}: 훅 미등록")

    def test_kiro_registers_both_ide_and_cli_triggers(self) -> None:
        """SessionStart 는 IDE 전용, AgentSpawn 은 CLI 전용이다. 하나만 걸면 반만 덮는다."""
        text = self.hosts()[".kiro/hooks/session-start.json"]
        for trigger in ("SessionStart", "AgentSpawn"):
            self.assertIn(trigger, text, f"kiro hooks: {trigger} 누락")

    def test_fetch_ticket_also_checks_without_a_hook(self) -> None:
        """훅은 프로젝트 신뢰가 있어야 돈다. 갓 clone 한 사람에게는 꺼져 있으므로
        호스트·신뢰와 무관하게 반드시 지나가는 지점에서도 한 번 본다."""
        for path in (FETCH_SH, FETCH_PS1):
            self.assertIn("check-freshness", path.read_text(encoding="utf-8"), f"{path.name}")

    def test_fetch_ticket_never_updates_mid_session(self) -> None:
        """fetch-ticket 은 세션 도중에 돈다. 세션 도중 계약을 바꾸지 않는다 (0016·0025).
        알림은 stderr 로 — stdout 은 티켓 본문이고 --json 이면 파싱된다.
        막힌 알림이 스탬프로 소모되지 않는지는 test_check_freshness.py 가 본다."""
        self.assertIn("check-freshness.sh\" --notify-only >&2", FETCH_SH.read_text(encoding="utf-8"))
        ps1 = FETCH_PS1.read_text(encoding="utf-8")
        self.assertIn("-NotifyOnly", ps1)
        self.assertIn("[Console]::Error", ps1)


    def test_fetch_ticket_also_sends_usage(self) -> None:
        """Hermes·신뢰 전 Codex·훅이 안 도는 Windows 는 세션 훅으로 못 보낸다. 티켓을 가져오는
        시점은 어디서든 지나가므로 여기서도 보낸다 (2026-09-29). 스로틀은 --if-due 안에 있다.
        stdout 은 티켓 본문이라 전송 쪽 출력은 섞이면 안 된다."""
        sh = FETCH_SH.read_text(encoding="utf-8")
        self.assertIn('report_usage.py" --if-due >&2', sh)
        ps1 = FETCH_PS1.read_text(encoding="utf-8")
        self.assertIn("report_usage.py", ps1)
        self.assertIn("--if-due", ps1)
        for text in (sh, ps1):
            self.assertNotIn("report_usage.py --send", text)
            self.assertNotIn('report_usage.py" --send', text)
        # 업데이트 확인 뒤에 보낸다 — 세션 훅과 같은 순서
        self.assertLess(sh.index("check-freshness.sh"), sh.index("report_usage.py"))
        self.assertLess(ps1.index("check-freshness.ps1"), ps1.index("report_usage.py"))


class FetchTicketParityTests(unittest.TestCase):
    """fetch-ticket 의 .sh 와 .ps1 이 같은 계약을 지키는지 본다."""

    def test_both_scripts_exist(self) -> None:
        for path in (FETCH_SH, FETCH_PS1):
            self.assertTrue(path.is_file(), f"없음: {path}")

    def test_both_read_the_same_conf_file(self) -> None:
        for path in (FETCH_SH, FETCH_PS1):
            text = path.read_text(encoding="utf-8")
            self.assertIn(".config/msp/zendesk.conf", text, f"{path.name}: conf 경로 불일치")

    def test_both_resolve_the_same_setting_names(self) -> None:
        """우리 이름과 외부 스킬 호환 이름을 양쪽 다 받아야 한다."""
        for path in (FETCH_SH, FETCH_PS1):
            text = path.read_text(encoding="utf-8")
            for key in ("ZENDESK_SUBDOMAIN", "ZENDESK_EMAIL", "ZENDESK_API_TOKEN"):
                self.assertIn(key, text, f"{path.name}: {key} 누락")
            for legacy in ("Zendesk_SUBDOMAIN", "Zendesk_EMAIL", "Zendesk_API"):
                self.assertIn(legacy, text, f"{path.name}: 호환 이름 {legacy} 누락")

    def test_both_follow_pagination(self) -> None:
        """코멘트 100건이 넘는 스레드가 잘리면 답변이 통째로 틀어진다."""
        for path in (FETCH_SH, FETCH_PS1):
            text = path.read_text(encoding="utf-8")
            self.assertIn("has_more", text, f"{path.name}: cursor 페이지네이션 미처리")
            self.assertIn("next_page", text, f"{path.name}: offset 폴백 미처리")

    def test_both_support_json_output(self) -> None:
        self.assertIn("--json", FETCH_SH.read_text(encoding="utf-8"))
        self.assertIn("$Json", FETCH_PS1.read_text(encoding="utf-8"))

    def test_both_count_inline_body_images_not_just_attachments(self) -> None:
        """Zendesk 는 본문에 붙여넣은 이미지를 attachments 에 안 넣기도 한다.
        attachments 만 세면 이미지 4장짜리 티켓이 '첨부 없음'으로 보인다 —
        읽는 쪽이 자기가 뭘 못 봤는지 모르게 되는 게 이 검사가 막는 것이다."""
        for path in (FETCH_SH, FETCH_PS1):
            text = path.read_text(encoding="utf-8")
            self.assertIn("/attachments/token/", text, f"{path.name}: 본문 이미지 URL 탐지 없음")
            self.assertIn("본문 삽입", text, f"{path.name}: 인라인 개수를 따로 안 알림")

    def test_both_download_images_only_on_demand(self) -> None:
        for path, flag in ((FETCH_SH, "--images"), (FETCH_PS1, "-Images")):
            self.assertIn(flag, path.read_text(encoding="utf-8"), f"{path.name}: {flag} 없음")

    def test_credentials_go_only_to_our_own_zendesk_host(self) -> None:
        """티켓 본문에는 고객사 헬프데스크 URL 이 섞여 있다. 거기로 Authorization 을
        보내면 우리 Zendesk 토큰을 제3자에게 넘기는 것이 된다."""
        sh = FETCH_SH.read_text(encoding="utf-8")
        self.assertIn('grep -q "^https://${HOST}/"', sh, "sh: 호스트 검사 없이 인증 전송")
        ps = FETCH_PS1.read_text(encoding="utf-8")
        self.assertIn('StartsWith("https://$zdHost/")', ps, "ps1: 호스트 검사 없이 인증 전송")

    def test_neither_writes_the_thread_to_disk(self) -> None:
        """원본 스레드에는 실명·계정ID가 들어 있다. 어디에 남길지는 호출자가 정한다."""
        for path in (FETCH_SH, FETCH_PS1):
            for line in path.read_text(encoding="utf-8").splitlines():
                stripped = line.strip()
                if stripped.startswith("#"):
                    continue
                for bad in ("Out-File", "Set-Content", "tee "):
                    self.assertNotIn(bad, stripped, f"{path.name}: 디스크 기록: {stripped}")


class UsageHookCoverageTests(unittest.TestCase):
    """지표 전송도 freshness 와 같은 세 호스트에 걸린다 (계획서 2번).

    별도 훅으로 둔다 — 관심사가 다르고, 한쪽이 죽어도 다른 쪽이 돈다.
    """

    def hosts(self) -> dict[str, str]:
        import subprocess, sys
        subprocess.run(
            [sys.executable, str(ROOT / "scripts/render_agent_configs.py"), "--check"],
            check=True, capture_output=True,
        )
        return {
            name: (ROOT / name).read_text(encoding="utf-8")
            for name in (
                ".claude/settings.json",
                ".codex/config.toml",
                ".kiro/hooks/session-start.json",
            )
        }

    def test_every_hookable_host_sends_usage(self) -> None:
        for name, text in effective_hosts(self.hosts()).items():
            self.assertIn("report_usage.py", text, f"{name}: 지표 훅 미등록")

    def test_the_hook_uses_the_throttled_entry_point(self) -> None:
        """훅이 `--send` 를 직접 부르면 세션마다 보낸다. `--if-due` 가 스로틀을 안다."""
        for name, text in effective_hosts(self.hosts()).items():
            self.assertIn("--if-due", text, f"{name}: 스로틀 없는 진입점")
            self.assertNotIn("report_usage.py --send", text, f"{name}: 세션마다 전송한다")

    def test_kiro_registers_both_ide_and_cli_triggers(self) -> None:
        text = self.hosts()[".kiro/hooks/session-start.json"]
        for trigger in ("SessionStart", "AgentSpawn"):
            self.assertIn(trigger, text, f"kiro usage hooks: {trigger} 누락")

    def test_freshness_hook_still_stands(self) -> None:
        """지표 훅을 붙이면서 기존 훅을 밀어내지 않았는지 본다."""
        hosts = effective_hosts(self.hosts())
        for name in (".claude/settings.json", ".codex/config.toml"):
            self.assertIn("check-freshness.sh", hosts[name], f"{name}")


class SessionHookOrderTests(unittest.TestCase):
    """업데이트가 끝난 뒤에 지표를 보낸다 (2026-09-29).

    Claude Code 와 Codex 는 같은 이벤트의 훅을 **동시에** 돌린다 — "All matching hooks run in
    parallel" (code.claude.com/docs/en/hooks), "launched concurrently" (learn.chatgpt.com/docs/hooks).
    훅 두 개로 두면 전송이 먼저 끝나 그날 행이 옛 버전으로 찍힌다. 한 명령 안에서 `;` 로 잇는다 —
    `&&` 가 아니다: 업데이트가 실패해도 전송은 돈다(따로 두던 이유를 지킨다).
    """

    FILES = (".claude/settings.json", ".codex/config.toml", ".kiro/hooks/session-start.json")

    def setUp(self) -> None:
        import subprocess, sys
        subprocess.run(
            [sys.executable, str(ROOT / "scripts/render_agent_configs.py"), "--check"],
            check=True, capture_output=True,
        )

    STABLE_COMMAND = ('python3 "$(git rev-parse --show-toplevel)/scripts/session_start.py" || '
                      'python "$(git rev-parse --show-toplevel)/scripts/session_start.py"')

    def test_claude_runs_the_stable_entry_point(self) -> None:
        """순서(업데이트 → 전송)는 session_start.py 안에 있다. 명령은 git 루트 기준이다 — 세션을 연 폴더에서
        돌리고(code.claude.com/docs/en/hooks), Windows 의 Git Bash 에는 python3 가 없는 일이 흔하다."""
        text = (ROOT / ".claude/settings.json").read_text(encoding="utf-8")
        self.assertIn(self.STABLE_COMMAND.replace('"', '\\"'), text)

    def test_codex_keeps_the_command_people_already_trusted(self) -> None:
        """Codex 는 v0.1.4 명령을 유지한다 — 바꾸면 그때 Trust 한 사람이 다시 묻는다."""
        text = (ROOT / ".codex/config.toml").read_text(encoding="utf-8")
        self.assertIn("bash scripts/check-freshness.sh; python3 scripts/report_usage.py --if-due", text)

    def test_codex_hook_identity_is_pinned(self) -> None:
        """**이 테스트가 깨지면 모든 Codex 사용자의 훅이 꺼진다.** Codex 는 훅마다 정규화한 내용의 해시를
        ~/.codex/config.toml [hooks.state] 의 trusted_hash 와 비교하고, 다르면 Modified 로 돌리지 않는다
        (openai/codex codex-rs/hooks/src/engine/discovery.rs hook_hash·hook_trust_status). 시작할 때
        "Hooks need review" 를 띄우고, 건너뛰면 꺼진 채로 남는다. v0.1.4 에서 명령을 합친 순간 실제로 전원이
        꺼졌다. 명령·matcher·statusMessage·timeout 을 바꿔야 하면 공지와 함께 이 값을 바꾼다.
        command_windows 는 해시에 들어가지 않는다(Windows 에서는 대신 그것이 command 자리에 들어간다)."""
        import hashlib
        try:
            import tomllib
        except ImportError:  # macOS 기본 파이썬은 3.9 다
            self.skipTest("tomllib 는 파이썬 3.11 부터 있다")
        group = tomllib.loads((ROOT / ".codex/config.toml").read_text(encoding="utf-8"))["hooks"]["SessionStart"][0]
        handler = group["hooks"][0]
        identity = {"event_name": "session_start", "matcher": group["matcher"], "hooks": [{
            "type": "command", "command": handler["command"], "timeout": handler.get("timeout", 600),
            "async": False, "statusMessage": handler["statusMessage"]}]}

        def canonical(value):
            if isinstance(value, dict):
                return {key: canonical(value[key]) for key in sorted(value)}
            return [canonical(v) for v in value] if isinstance(value, list) else value

        def digest(command: str) -> str:
            identity["hooks"][0]["command"] = command
            raw = json.dumps(canonical(identity), separators=(",", ":"), ensure_ascii=False).encode()
            return "sha256:" + hashlib.sha256(raw).hexdigest()

        self.assertEqual(digest(handler["command"]), PINNED_CODEX_HOOK_HASH)
        # Windows 에서는 command_windows 가 command 자리에 들어가 해시된다
        self.assertEqual(digest(handler["command_windows"]), PINNED_CODEX_WINDOWS_HOOK_HASH)

    def test_kiro_command_reads_the_same_in_sh_and_cmd(self) -> None:
        """Kiro IDE 는 Node spawn(shell: true) 로 돌린다 — Unix /bin/sh, Windows ComSpec(cmd.exe)
        (Kiro IDE 1.1.14 번들, nodejs.org child_process). cmd 에서 `;` 는 구분자가 아니다.
        `||` 는 두 셸에서 같은 뜻이다. 순서는 session_start.py 안에서 지킨다."""
        hooks = json.loads((ROOT / ".kiro/hooks/session-start.json").read_text(encoding="utf-8"))["hooks"]
        self.assertEqual({h["trigger"] for h in hooks}, {"SessionStart", "AgentSpawn"})
        for hook in hooks:
            self.assertEqual(hook["action"]["command"],
                             "python3 scripts/session_start.py || python scripts/session_start.py")
            self.assertNotIn(";", hook["action"]["command"])
            # git fetch 가 걸려도 전송까지 가게 기본 60초보다 넉넉히 (kiro.dev/docs/hooks)
            self.assertGreaterEqual(hook["timeout"], 120)

    def test_no_second_hook_races_the_first(self) -> None:
        for name in self.FILES:
            text = (ROOT / name).read_text(encoding="utf-8")
            if name.startswith(".kiro"):
                continue
            self.assertEqual(text.count("report_usage.py"), text.count("check-freshness.sh"), name)
        self.assertEqual((ROOT / ".claude/settings.json").read_text(encoding="utf-8").count('"command":'), 1)
        self.assertEqual((ROOT / ".codex/config.toml").read_text(encoding="utf-8").count("[[hooks.SessionStart.hooks]]"), 1)

    def test_codex_has_a_windows_command(self) -> None:
        """Windows 에서 `bash …; python3 …` 가 도는지 모른다. Codex 는 command_windows 를 받는다
        (learn.chatgpt.com/docs/hooks). 셸이 `;` 를 어떻게 읽는지 문서에 없어 명령 하나로 둔다."""
        try:
            import tomllib
        except ImportError:  # macOS 기본 파이썬은 3.9 다
            self.skipTest("tomllib 는 파이썬 3.11 부터 있다")
        config = tomllib.loads((ROOT / ".codex/config.toml").read_text(encoding="utf-8"))
        hook = config["hooks"]["SessionStart"][0]["hooks"][0]
        self.assertEqual(hook["command_windows"], "pwsh -NoProfile -File scripts/session-start.ps1")
        ps1 = "\n".join(line for line in (ROOT / "scripts/session-start.ps1").read_text(encoding="utf-8").splitlines()
                        if not line.lstrip().startswith("#"))
        self.assertLess(ps1.index("check-freshness.ps1"), ps1.index("report_usage.py"))
        self.assertIn("--if-due", ps1)
        self.assertNotIn("--send", ps1)

    def test_onboarding_points_kiro_cli_at_the_v3_engine(self) -> None:
        """Kiro CLI 기본 v2 엔진은 .kiro/hooks 를 읽지 않는다(2.25.0 바이너리에 경로 없음, 문서 "CLI 3.0").
        전역 설정이라 바꾸지 않고 알린다."""
        for path in (SH, PS1):
            text = path.read_text(encoding="utf-8")
            self.assertIn("chat.agentEngine", text, path.name)
            self.assertIn("kiro-cli settings chat.agentEngine v3", text, path.name)

    def test_onboarding_installs_the_hermes_hook(self) -> None:
        """Hermes 는 저장소 훅을 읽지 않는다. 온보딩이 사용자 설정에 넣고, --check 는 상태만 본다."""
        for path in (SH, PS1):
            text = path.read_text(encoding="utf-8")
            self.assertIn("hermes_hook.py", text, path.name)
            self.assertIn("--install", text, path.name)
            self.assertIn("--status", text, path.name)

    def test_old_split_kiro_files_are_gone(self) -> None:
        for name in (".kiro/hooks/freshness.json", ".kiro/hooks/usage.json"):
            self.assertFalse((ROOT / name).exists(), name)


if __name__ == "__main__":
    unittest.main(verbosity=2)
