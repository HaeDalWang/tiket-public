#!/usr/bin/env python3
"""Offline conformance tests for an installed aws-customer-account-ops skill."""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import tempfile
import textwrap
import time
import unittest
from pathlib import Path

SKILL_NAME = "aws-customer-account-ops"
SYNTHETIC_ACCOUNT_ID = "123456" + "789012"
REQUIRED_FILES = (
    "SKILL.md",
    "get-sts-token.sh",
    "get-customer-credentials.sh",
    "billing-api.sh",
)
# Syntax floor actually used by the skill's shell client, not a policy preference:
#   local -n (nameref)  -> 4.3
#   ${var,,}            -> 4.0
#   ;;& in case         -> 4.0
# macOS ships /bin/bash 3.2 and will not ship a newer one. The skill is owned by
# support-skills, so this repository reports the gap instead of failing on it.
SKILL_BASH_FLOOR = (4, 3)
SKILL_OWNER = "스킬 담당자"


def probe_bash() -> tuple[str, tuple[int, ...] | None]:
    """Resolve bash the way the skill does (`#!/usr/bin/env bash`) and read its version."""
    binary = shutil.which("bash") or ""
    if not binary:
        return "", None
    result = subprocess.run(
        [binary, "-c", 'printf "%s %s" "${BASH_VERSINFO[0]}" "${BASH_VERSINFO[1]}"'],
        check=False,
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        return binary, None
    try:
        return binary, tuple(int(value) for value in result.stdout.split())
    except ValueError:
        return binary, None


def resolve_marker_skill_dir() -> Path | None:
    """Resolve the copy that csg-login's credential_process actually points at.

    credential_process lives in the single machine-wide ~/.aws/config, so this is
    the copy that executes at runtime regardless of which agent started the
    session (see the copy-drift note in ONBOARDING.md and
    agents/install-verification.md). Prefer it over the fixed candidate list below
    so this conformance test can never silently validate an unrelated copy while
    the one that actually runs has drifted or gone missing.
    """
    try:
        result = subprocess.run(
            ["aws", "configure", "get", "profile.csg-login.credential_process"],
            capture_output=True,
            text=True,
            check=False,
        )
    except FileNotFoundError:
        return None
    if result.returncode != 0:
        return None
    script_path = result.stdout.strip()
    if not script_path:
        return None
    skill_dir = Path(script_path).expanduser().resolve().parent
    if (skill_dir / "SKILL.md").is_file():
        return skill_dir
    return None


def discover_skill_dir(explicit: str | None) -> Path:
    if explicit:
        return Path(explicit).expanduser().resolve()

    marker_dir = resolve_marker_skill_dir()
    if marker_dir is not None:
        return marker_dir

    # csg-login marker absent or unresolved: fall back to a fixed search order.
    # This path exists so the test is still runnable before first login, not as
    # a substitute for the marker once it is set up. The workspace copy comes
    # first: onboarding points the marker there now (0040); $HOME copies are legacy.
    home = Path.home()
    candidates = (
        Path(__file__).resolve().parents[1] / "skills" / SKILL_NAME,
        home / ".hermes/skills" / SKILL_NAME,
        home / ".claude/skills" / SKILL_NAME,
        home / ".agents/skills" / SKILL_NAME,
        home / ".kiro/skills" / SKILL_NAME,
    )
    for candidate in candidates:
        if (candidate / "SKILL.md").is_file():
            return candidate.resolve()
    raise FileNotFoundError("installed aws-customer-account-ops skill not found")


class AwsCustomerSkillConformanceTests(unittest.TestCase):
    skill_dir: Path
    bash_bin: str
    bash_version: tuple[int, ...] | None

    @classmethod
    def configure(cls, skill_dir: Path) -> None:
        cls.skill_dir = skill_dir
        cls.bash_bin, cls.bash_version = probe_bash()

    @classmethod
    def setUpClass(cls) -> None:
        """Auto-configure for `python -m unittest discover`, which never calls main().

        main() calls configure() explicitly with the parsed --skill-dir before
        building the suite; this only fills in the gap when nothing configured
        it first, so an explicit main() call always wins.
        """
        if not hasattr(cls, "skill_dir"):
            try:
                cls.configure(discover_skill_dir(None))
            except FileNotFoundError as exc:
                raise unittest.SkipTest(str(exc))

    @classmethod
    def bash_meets_floor(cls) -> bool:
        return bool(cls.bash_bin) and cls.bash_version is not None and cls.bash_version >= SKILL_BASH_FLOOR

    def require_supported_bash(self) -> None:
        """Skip instead of fail: an unsupported bash is a skill-side limitation."""
        if not self.bash_meets_floor():
            self.skipTest("environment bash is below the skill's syntax floor")

    def script(self, name: str) -> Path:
        return self.skill_dir / name

    def isolated_env(self, home: Path, bin_dir: Path) -> dict[str, str]:
        env = os.environ.copy()
        env.update(
            {
                "HOME": str(home),
                "PATH": f"{bin_dir}:{os.environ.get('PATH', '')}",
                "MSP_DISABLE_UPDATE": "1",
                "MSP_AGENT": "hermes",
            }
        )
        env.pop("BILLING_API_KEY", None)
        return env

    def write_executable(self, path: Path, content: str) -> None:
        path.write_text(textwrap.dedent(content).lstrip(), encoding="utf-8")
        path.chmod(0o755)

    def test_required_files_exist(self) -> None:
        missing = [name for name in REQUIRED_FILES if not self.script(name).is_file()]
        self.assertEqual(missing, [], f"missing required skill files: {missing}")

    def test_selected_bash_is_supported_by_the_skill(self) -> None:
        self.assertTrue(self.bash_bin, "bash is not available in the agent PATH")
        self.assertIsNotNone(self.bash_version, f"cannot read bash version: {self.bash_bin}")
        self.require_supported_bash()

    def test_shell_scripts_parse_with_selected_bash(self) -> None:
        self.require_supported_bash()
        for script in sorted(self.skill_dir.glob("*.sh")):
            with self.subTest(script=script.name):
                result = subprocess.run(
                    [self.bash_bin, "-n", str(script)],
                    check=False,
                    capture_output=True,
                    text=True,
                )
                self.assertEqual(result.returncode, 0, result.stderr)

    def test_customer_client_has_no_local_assume_role_command(self) -> None:
        source = self.script("get-customer-credentials.sh").read_text(encoding="utf-8")
        command = re.compile(r"^[^#\n]*\baws\s+sts\s+assume-role\b", re.MULTILINE)
        self.assertIsNone(command.search(source), "customer client must not run local sts assume-role")
        self.assertIn("/customer-credentials", source)

    def test_missing_login_token_fails_fast_without_network(self) -> None:
        self.require_supported_bash()
        with tempfile.TemporaryDirectory(prefix="tiket-aws-skill-no-login-") as tempdir:
            root = Path(tempdir)
            home = root / "home"
            bin_dir = root / "bin"
            home.mkdir()
            bin_dir.mkdir()
            curl_log = root / "curl.log"
            self.write_executable(
                bin_dir / "curl",
                f"""
                #!/usr/bin/env bash
                printf 'called\n' >> {str(curl_log)!r}
                exit 99
                """,
            )
            env = self.isolated_env(home, bin_dir)
            started = time.monotonic()
            result = subprocess.run(
                [self.bash_bin, str(self.script("get-customer-credentials.sh")), "--account-id", SYNTHETIC_ACCOUNT_ID],
                env=env,
                check=False,
                capture_output=True,
                text=True,
                timeout=2,
            )
            elapsed = time.monotonic() - started
            self.assertNotEqual(result.returncode, 0)
            self.assertLess(elapsed, 2)
            self.assertIn("로그인이 필요합니다", result.stderr)
            self.assertFalse(curl_log.exists(), "missing-token path attempted a network call")

    def test_login_check_never_runs_the_legacy_self_update(self) -> None:
        # 2026-10-21: the workspace copy still carried self-update (LOCAL_VERSION 1.6.2). The
        # server's min_supported (1.8.1) forced an update with no $HOME copy left to update,
        # so login never completed and no tiket-v* call reached the broker in 14 days.
        self.require_supported_bash()
        with tempfile.TemporaryDirectory(prefix="tiket-aws-skill-no-update-") as tempdir:
            root = Path(tempdir)
            home = root / "home"
            bin_dir = root / "bin"
            conf_dir = home / ".config" / "msp"
            conf_dir.mkdir(parents=True)
            bin_dir.mkdir()
            (conf_dir / "credential-broker.conf").write_text(
                "API_URL=https://broker.invalid/Prod/v1/credentials\n", encoding="utf-8"
            )
            curl_log = root / "curl.log"
            self.write_executable(
                bin_dir / "curl",
                f"""
                #!/usr/bin/env bash
                printf '%s\\n' "$*" >> {str(curl_log)!r}
                printf '{{"version":"9.9.9","sha256":"x","min_supported":"9.9.9"}}'
                """,
            )
            result = subprocess.run(
                [self.bash_bin, str(self.script("get-sts-token.sh")), "--check-only"],
                env=self.isolated_env(home, bin_dir),
                check=False,
                capture_output=True,
                text=True,
                timeout=10,
            )
            self.assertNotIn("업데이트", result.stderr)
            calls = curl_log.read_text(encoding="utf-8") if curl_log.exists() else ""
            self.assertNotIn("/version", calls)

    def test_billing_missing_key_fails_without_network(self) -> None:
        self.require_supported_bash()
        with tempfile.TemporaryDirectory(prefix="tiket-billing-no-key-") as tempdir:
            root = Path(tempdir)
            home = root / "home"
            bin_dir = root / "bin"
            home.mkdir()
            bin_dir.mkdir()
            curl_log = root / "curl.log"
            self.write_executable(
                bin_dir / "curl",
                f"""
                #!/usr/bin/env bash
                printf 'called\n' >> {str(curl_log)!r}
                exit 99
                """,
            )
            result = subprocess.run(
                [self.bash_bin, str(self.script("billing-api.sh")), "GET", "/api/synthetic"],
                env=self.isolated_env(home, bin_dir),
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("BILLING_API_KEY", result.stderr)
            self.assertFalse(curl_log.exists(), "missing-key path attempted a network call")

    def test_billing_wrapper_passes_synthetic_bearer(self) -> None:
        self.require_supported_bash()
        with tempfile.TemporaryDirectory(prefix="tiket-billing-header-") as tempdir:
            root = Path(tempdir)
            home = root / "home"
            bin_dir = root / "bin"
            home.mkdir()
            bin_dir.mkdir()
            curl_log = root / "curl.log"
            self.write_executable(
                bin_dir / "curl",
                f"""
                #!/usr/bin/env bash
                printf '%s\n' "$@" > {str(curl_log)!r}
                printf '{{"body":[]}}\n'
                """,
            )
            env = self.isolated_env(home, bin_dir)
            env["BILLING_API_KEY"] = "synthetic-billing-key"
            result = subprocess.run(
                [self.bash_bin, str(self.script("billing-api.sh")), "GET", "/api/synthetic"],
                env=env,
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            invocation = curl_log.read_text(encoding="utf-8")
            self.assertIn("Authorization: Bearer synthetic-billing-key", invocation)
            self.assertIn("https://billing.example.com/api/synthetic", invocation)

    def test_customer_client_projects_synthetic_broker_response(self) -> None:
        self.require_supported_bash()
        with tempfile.TemporaryDirectory(prefix="tiket-customer-broker-") as tempdir:
            root = Path(tempdir)
            home = root / "home"
            bin_dir = root / "bin"
            config_dir = home / ".config/msp"
            cache_dir = home / ".cache/msp"
            config_dir.mkdir(parents=True)
            cache_dir.mkdir(parents=True)
            bin_dir.mkdir()

            (config_dir / "credential-broker.conf").write_text(
                "API_URL=https://broker.invalid/Prod/v1/credentials\n",
                encoding="utf-8",
            )
            (cache_dir / "sts-token.json").write_text(
                json.dumps(
                    {
                        "Version": 1,
                        "Expiration": "2099-01-01T00:00:00Z",
                        "SlackAccessToken": "synthetic-login-token",
                        "SlackUserId": "U-SYNTHETIC",
                    }
                ),
                encoding="utf-8",
            )

            curl_log = root / "curl.log"
            curl_stdin_log = root / "curl.stdin"
            aws_log = root / "aws.log"
            self.write_executable(
                bin_dir / "curl",
                f"""
                #!/usr/bin/env bash
                printf '%s\n' "$@" > {str(curl_log)!r}
                cat > {str(curl_stdin_log)!r}
                out=''
                while (($#)); do
                    if [[ "$1" == '-o' ]]; then out="$2"; shift 2; else shift; fi
                done
                printf '%s' '{{"AccessKeyId":"synthetic-access","SecretAccessKey":"synthetic-secret","SessionToken":"synthetic-session","Expiration":"2099-01-01T00:00:00Z","BrokerVersion":"synthetic"}}' > "$out"
                printf '200'
                """,
            )
            self.write_executable(
                bin_dir / "aws",
                f"""
                #!/usr/bin/env bash
                printf '%s\n' "$@" >> {str(aws_log)!r}
                exit 99
                """,
            )

            result = subprocess.run(
                [self.bash_bin, str(self.script("get-customer-credentials.sh")), "--account-id", SYNTHETIC_ACCOUNT_ID],
                env=self.isolated_env(home, bin_dir),
                check=False,
                capture_output=True,
                text=True,
                timeout=10,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            payload = json.loads(result.stdout)
            self.assertEqual(
                set(payload),
                {"Version", "AccessKeyId", "SecretAccessKey", "SessionToken", "Expiration"},
            )
            self.assertEqual(payload["Version"], 1)
            invocation = curl_log.read_text(encoding="utf-8")
            self.assertIn("https://broker.invalid/Prod/v1/customer-credentials", invocation)
            self.assertIn(f'"accountId":"{SYNTHETIC_ACCOUNT_ID}"', invocation)
            self.assertIn('"agent":"hermes"', invocation)

            # 1.8.1 부터 Bearer 는 인자가 아니라 stdin 설정 스탠자(`-K -`)로 간다.
            # Linux 는 /proc/<pid>/cmdline 으로 모든 로컬 UID 에 인자를 공개하므로,
            # 인자에 실리면 다른 사용자가 읽어 그 엔지니어 명의로 세션을 발급할 수 있다.
            # 아래 두 줄은 그 속성을 지키는 회귀 방지선이다 — 인자로 되돌아가면 실패한다.
            self.assertIn("-K", invocation.split("\n"))
            self.assertNotIn(
                "synthetic-login-token",
                invocation,
                "Bearer leaked into curl arguments (readable via /proc/<pid>/cmdline)",
            )
            stdin_config = curl_stdin_log.read_text(encoding="utf-8")
            self.assertIn(
                'header = "Authorization: Bearer synthetic-login-token"',
                stdin_config,
            )
            self.assertFalse(aws_log.exists(), "customer client attempted a local AWS command")


def bash_warning_lines(binary: str, version: tuple[int, ...] | None, skipped: int) -> list[str]:
    floor = ".".join(str(part) for part in SKILL_BASH_FLOOR)
    if not binary:
        found = "bash not found in PATH"
    elif version is None:
        found = f"{binary} (version unreadable)"
    else:
        found = f"{binary} is bash {'.'.join(str(part) for part in version)}"
    return [
        f"- WARN: {found}; the skill's shell client needs bash {floor} or newer",
        f"- WARN: {skipped} skill checks were skipped. 이 환경에서 고객 AWS 조회 도구는 동작하지 않습니다.",
        "- 저장소 문제가 아닙니다. 스킬이 bash 4.3 전용 문법(local -n, ${var,,}, ;;&)을 사용합니다.",
        f"- 조치: {SKILL_OWNER}에게 DM 하세요. 스킬 쪽 수정이 필요합니다.",
        "- 임시로 쓰려면 에이전트를 실행하는 환경의 PATH에서 Homebrew bash가 먼저 선택되게 하세요.",
    ]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--skill-dir", help="installed skill directory; otherwise search supported agent paths")
    args = parser.parse_args()

    try:
        skill_dir = discover_skill_dir(args.skill_dir)
    except FileNotFoundError as exc:
        print(f"aws customer skill conformance: FAIL ({exc})")
        return 1

    AwsCustomerSkillConformanceTests.configure(skill_dir)
    suite = unittest.defaultTestLoader.loadTestsFromTestCase(AwsCustomerSkillConformanceTests)
    result = unittest.TextTestRunner(verbosity=2).run(suite)

    if not result.wasSuccessful():
        print(f"aws customer skill conformance: FAIL ({skill_dir})")
        return 1

    if AwsCustomerSkillConformanceTests.bash_meets_floor():
        print(f"aws customer skill conformance: PASS ({skill_dir})")
        return 0

    print(f"aws customer skill conformance: PASS WITH WARNINGS ({skill_dir})")
    for line in bash_warning_lines(
        AwsCustomerSkillConformanceTests.bash_bin,
        AwsCustomerSkillConformanceTests.bash_version,
        len(result.skipped),
    ):
        print(line)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
