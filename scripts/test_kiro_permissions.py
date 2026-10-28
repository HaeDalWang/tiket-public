#!/usr/bin/env python3
"""scripts/kiro_permissions.py 테스트. 실제 ~/.kiro 는 건드리지 않는다 — 임시 홈에서 본다.

실제 PC 에서 확인한 것 (2026-10-01, kiro-cli 2.26.1, macOS):
  Kiro 가 직접 만든 workspace-roots 폴더 2개의 이름이 sha256(NFC 경로)의 앞 16자와 같았다.
  Kiro 가 쓴 permissions.yaml 은 `rules:` 아래 두 칸 들여쓴 `- capability:` 목록이다.
"""

from __future__ import annotations

import importlib.util
import json
import tempfile
import unittest
from unittest import mock
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("kiro_permissions", ROOT / "scripts/kiro_permissions.py")
kp = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(kp)

WORKSPACE = Path("/tmp/tiket")
WORKSPACE_HASH = "5012de0680896a93"  # `printf %s /tmp/tiket | shasum -a 256` 앞 16자

KIRO_WRITTEN = """rules:
  - capability: shell
    effect: allow
    match:
      - echo *
      - git *
"""


class HomeCase(unittest.TestCase):
    def setUp(self) -> None:
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.home = Path(tmp.name)
        (self.home / ".kiro").mkdir()

    def target(self) -> Path:
        return self.home / ".kiro/workspace-roots" / WORKSPACE_HASH / "permissions.yaml"


class LocateTests(HomeCase):
    def test_folder_name_is_the_first_16_hex_of_sha256_of_the_path(self) -> None:
        self.assertEqual(kp.workspace_dir(WORKSPACE, self.home).name, WORKSPACE_HASH)

    def test_a_folder_kiro_already_made_for_this_root_wins(self) -> None:
        """Kiro 가 남긴 .trust-migration.json 의 root 가 같으면 그 폴더다 — 해시 규칙을 모르는 OS 에서도 찾는다."""
        made = self.home / ".kiro/workspace-roots/abc123"
        made.mkdir(parents=True)
        (made / ".trust-migration.json").write_text(json.dumps({"root": str(WORKSPACE)}), encoding="utf-8")
        self.assertEqual(kp.workspace_dir(WORKSPACE, self.home, os_name="nt"), made)

    def test_windows_without_a_known_folder_is_not_guessed(self) -> None:
        """Windows 경로를 Kiro 가 어떻게 해시하는지 모른다. 틀린 폴더에 쓰면 조용히 안 먹는다."""
        self.assertIsNone(kp.workspace_dir(WORKSPACE, self.home, os_name="nt"))


class InstallTests(HomeCase):
    def test_fresh_install_writes_a_rules_file(self) -> None:
        code, message = kp.install(WORKSPACE, self.home)
        text = self.target().read_text(encoding="utf-8")
        self.assertEqual(code, 0)
        self.assertTrue(text.startswith("rules:\n"))
        self.assertIn('"bash scripts/fetch-ticket.sh*"', text)
        self.assertIn(f"rm '{self.target()}'", message)  # 되돌리는 명령

    def test_existing_rules_are_kept_and_backed_up(self) -> None:
        self.target().parent.mkdir(parents=True)
        self.target().write_text(KIRO_WRITTEN, encoding="utf-8")
        code, message = kp.install(WORKSPACE, self.home)
        text = self.target().read_text(encoding="utf-8")
        backup = self.target().with_name("permissions.yaml.bak")
        self.assertEqual(code, 0)
        self.assertTrue(text.startswith(KIRO_WRITTEN))
        self.assertIn("fetch-ticket.sh", text)
        self.assertEqual(backup.read_text(encoding="utf-8"), KIRO_WRITTEN)
        self.assertIn(f"cp '{backup}' '{self.target()}'", message)

    def test_running_twice_changes_nothing(self) -> None:
        self.target().parent.mkdir(parents=True)
        self.target().write_text(KIRO_WRITTEN, encoding="utf-8")
        kp.install(WORKSPACE, self.home)
        first = self.target().read_text(encoding="utf-8")
        kp.install(WORKSPACE, self.home)
        self.assertEqual(self.target().read_text(encoding="utf-8"), first)
        self.assertEqual(first.count(kp.BEGIN), 1)

    def test_an_older_block_is_replaced_not_stacked(self) -> None:
        old = KIRO_WRITTEN + f"{kp.BEGIN}\n  - capability: shell\n    effect: allow\n    match:\n      - \"old *\"\n{kp.END}\n"
        self.target().parent.mkdir(parents=True)
        self.target().write_text(old, encoding="utf-8")
        kp.install(WORKSPACE, self.home)
        text = self.target().read_text(encoding="utf-8")
        self.assertNotIn("old *", text)
        self.assertIn("- git *", text)
        self.assertEqual(text.count(kp.BEGIN), 1)

    def test_a_file_in_another_shape_is_left_alone(self) -> None:
        """목록이 들여쓰기 없이 적힌 파일에 두 칸 들여쓴 규칙을 붙이면 YAML 이 깨진다 — Kiro 가 파일 전체를 못 읽는다."""
        odd = "rules:\n- capability: shell\n  effect: allow\n  match: [\"git *\"]\n"
        self.target().parent.mkdir(parents=True)
        self.target().write_text(odd, encoding="utf-8")
        code, message = kp.install(WORKSPACE, self.home)
        self.assertEqual(code, 1)
        self.assertEqual(self.target().read_text(encoding="utf-8"), odd)
        self.assertIn("fetch-ticket.sh", message)  # 손으로 붙일 규칙을 보여 준다

    def test_unknown_folder_writes_nothing(self) -> None:
        code, message = kp.install(WORKSPACE, self.home, os_name="nt")
        self.assertEqual(code, 1)
        self.assertFalse((self.home / ".kiro/workspace-roots").exists())
        self.assertIn("Always allow", message)

    def test_status_follows_the_install(self) -> None:
        self.assertEqual(kp.status(WORKSPACE, self.home)[0], 1)
        kp.install(WORKSPACE, self.home)
        self.assertEqual(kp.status(WORKSPACE, self.home)[0], 0)


class RefreshTests(HomeCase):
    """이미 설치된 PC 를 새 규칙으로 맞춘다 — 세션 시작이 PC 쪽 상태를 따라가게 한다.
    tiket 표식 블록이 있고 내용이 다를 때만 다시 쓴다. 블록이 없으면 아무것도 쓰지 않는다."""

    def write(self, text: str) -> None:
        self.target().parent.mkdir(parents=True, exist_ok=True)
        self.target().write_text(text, encoding="utf-8")

    def test_an_outdated_block_is_rewritten_with_a_backup(self) -> None:
        old = ("rules:\n" + f"{kp.BEGIN}\n  - capability: shell\n    effect: allow\n"
               "    match:\n      - \"old-rule *\"\n" + f"{kp.END}\n")
        self.write(old)
        message = kp.refresh_if_installed(WORKSPACE, self.home)
        text = self.target().read_text(encoding="utf-8")
        self.assertIsNotNone(message)
        self.assertNotIn("old-rule", text)
        self.assertIn("effect: deny", text)
        self.assertEqual(text.count(kp.BEGIN), 1)
        self.assertTrue(self.target().with_name("permissions.yaml.bak").is_file())

    def test_a_current_block_is_left_alone_and_silent(self) -> None:
        kp.install(WORKSPACE, self.home)
        before = self.target().read_text(encoding="utf-8")
        self.assertIsNone(kp.refresh_if_installed(WORKSPACE, self.home))
        self.assertEqual(self.target().read_text(encoding="utf-8"), before)
        self.assertFalse(self.target().with_name("permissions.yaml.bak").is_file())

    def test_a_file_without_our_block_is_not_touched(self) -> None:
        self.write(KIRO_WRITTEN)
        self.assertIsNone(kp.refresh_if_installed(WORKSPACE, self.home))
        self.assertEqual(self.target().read_text(encoding="utf-8"), KIRO_WRITTEN)

    def test_no_file_at_all_writes_nothing(self) -> None:
        self.assertIsNone(kp.refresh_if_installed(WORKSPACE, self.home))
        self.assertFalse(self.target().exists())

    def test_an_odd_shaped_file_with_our_marker_is_left_alone(self) -> None:
        """표식은 있지만 merge 가 모양을 거절하면(들여쓰기 없는 목록) 아무것도 쓰지 않는다."""
        odd = "rules:\n- capability: shell\n" + f"{kp.BEGIN}\n  - capability: shell\n{kp.END}\n"
        self.write(odd)
        self.assertIsNone(kp.refresh_if_installed(WORKSPACE, self.home))
        self.assertEqual(self.target().read_text(encoding="utf-8"), odd)

    def test_a_pc_without_a_known_folder_is_silent(self) -> None:
        self.assertIsNone(kp.refresh_if_installed(WORKSPACE, self.home, os_name="nt"))

    def test_it_never_raises(self) -> None:
        """세션 시작 경로에서 부른다 — 어떤 예외도 밖으로 던지지 않는다."""
        self.assertIsNone(kp.refresh_if_installed(Path("/nonexistent/root"), Path("/nonexistent/home")))

    def test_a_failure_while_rewriting_is_swallowed(self) -> None:
        """다시 쓰다가 터져도(권한·디스크) 세션 시작을 막지 않는다."""
        target = kp.workspace_dir(WORKSPACE, self.home) / "permissions.yaml"
        target.parent.mkdir(parents=True)
        target.write_text(f"rules:\n{kp.BEGIN}\n{kp.END}\n", encoding="utf-8")
        with mock.patch.object(kp.shutil, "copyfile", side_effect=OSError("disk")):
            self.assertIsNone(kp.refresh_if_installed(WORKSPACE, self.home))


def _matches(command: str, rule: dict) -> bool:
    import fnmatch
    return (any(fnmatch.fnmatchcase(command, pattern) for pattern in rule.get("match", ()))
            and not any(fnmatch.fnmatchcase(command, pattern) for pattern in rule.get("exclude", ())))


def _effect(command: str, capability: str) -> str:
    """문서가 말하는 결정대로 본다 — deny 가 어느 범위의 allow·ask 보다 세다
    (kiro.dev/docs/permissions "deny > ask > allow … regardless of scope", 2026-10-04 조회).
    match 중 하나에 맞고 exclude 어느 것에도 안 맞는 규칙이 그 명령에 걸린다. deny 가 하나라도 걸리면 deny,
    아니면 allow 가 걸리면 allow, 그 밖은 ask. Kiro 자체를 돌리는 것은 아니다."""
    hits = [rule.get("effect", "allow") for rule in kp.RULES
            if rule["capability"] == capability and _matches(command, rule)]
    if "deny" in hits:
        return "deny"
    if "allow" in hits:
        return "allow"
    return "ask"


def allowed(command: str) -> bool:
    return _effect(command, "shell") == "allow"


def denied(command: str, capability: str = "shell") -> bool:
    return _effect(command, capability) == "deny"


def asks(command: str, capability: str = "shell") -> bool:
    return _effect(command, capability) == "ask"


class RuleSetTests(unittest.TestCase):
    def assert_allowed(self, *commands: str) -> None:
        for command in commands:
            self.assertTrue(allowed(command), f"묻게 된다: {command}")

    def assert_asks(self, *commands: str) -> None:
        for command in commands:
            self.assertTrue(asks(command), f"묻지 않는다(allow 거나 deny 다): {command}")

    def assert_denied(self, *commands: str, capability: str = "shell") -> None:
        for command in commands:
            self.assertTrue(denied(command, capability), f"막히지 않는다: {command}")

    def test_framework_scripts_run_without_asking(self) -> None:
        self.assert_allowed(
            "bash scripts/fetch-ticket.sh 12345",
            "python3 scripts/check_ticket_record.py tickets/12345.md",
            "python scripts/validate_workspace.py",
            "python3 scripts/weekly_diary.py --week 2026-10-05",
        )

    def test_reading_customer_notes_runs_without_asking(self) -> None:
        """라우터가 고객 계정 작업 전마다 부른다 — 읽기만 한다 (0034). 같은 이름으로 시작하는 다른 스크립트는 묻는다."""
        self.assert_allowed("python3 scripts/customer_notes.py corp-example",
                            "python scripts/customer_notes.py corp-example --dev")
        self.assert_asks("python3 scripts/customer_notes_write.py corp-example")

    def test_every_allowed_script_exists(self) -> None:
        scripts = [p for rule in kp.RULES for p in rule["match"] if " scripts/" in p]
        self.assertGreaterEqual(len(scripts), 5)
        for pattern in scripts:
            self.assertRegex(pattern, r"^(python3|python|bash) scripts/[A-Za-z0-9_-]+\.(py|sh)\*$")
            self.assertTrue((ROOT / pattern.rstrip("*").split()[-1]).is_file(), pattern)

    def test_scripts_are_named_one_by_one(self) -> None:
        """`python3 scripts/*` 는 `python3 scripts/../tickets/x.py` 도 통과시킨다 — tickets/ 쓰기가 허용이라
        아무 코드나 묻지 않고 돌게 된다. 릴리스는 유지보수자만 한다."""
        self.assert_asks("python3 scripts/../tickets/x.py", "python3 scripts/release.py v9.9.9", "bash scripts/onboarding.sh")

    def test_saving_the_diary_to_the_site_asks(self) -> None:
        """사이트에 쓰는 것은 승인 창이 곧 사람의 "예" 다. `weekly_diary.py*` 허용이 저장 스크립트까지 덮으면 안 된다."""
        self.assert_asks("python3 scripts/weekly_diary_save.py --week 2026-10-05")

    def test_aws_reads_run_without_asking(self) -> None:
        """고객 조회 스킬이 쓰는 모양 그대로다."""
        self.assert_allowed(
            "aws ec2 describe-instances --profile csg-example --region ap-northeast-2",
            "aws s3api list-buckets --profile csg-example --output table",
            "aws --profile csg-example rds describe-db-instances",
            "aws sts get-caller-identity",
            "aws s3 ls s3://example-bucket",
            "aws configure get profile.csg-login.credential_process",
            "aws cloudtrail lookup-events --max-results 5",
            "aws logs filter-log-events --log-group-name x",
        )

    def test_aws_writes_are_denied(self) -> None:
        """CLAUDE.md: 고객 계정 쓰기 API 는 절대 부르지 않는다. Trust All Tools 로 묻기가 통과해도 deny 는 이긴다.
        브로커가 아닌 본인 프로필에도 같은 규칙이 걸린다."""
        self.assert_denied(
            "aws ec2 terminate-instances --instance-ids i-0example",
            "aws ec2 delete-volume --volume-id vol-0example",
            "aws iam create-user --user-name x",
            "aws s3 rm s3://example-bucket/key",
            "aws s3 cp local.txt s3://example-bucket/",
            "aws s3 sync . s3://example-bucket",
            "aws --profile p s3 mv a s3://example-bucket/b",
            "aws ec2 run-instances --image-id ami-0example",
            "aws ssm send-command --document-name x",
            "aws lambda invoke --function-name x out.json",
            "aws sts assume-role --role-arn x --role-session-name y",
        )

    def test_logs_insights_and_athena_queries_still_ask(self) -> None:
        """start-query·stop-query 는 쓰기 동사지만 CloudWatch Logs Insights·Athena 조회다 — 지금처럼 묻기로 남긴다."""
        self.assert_asks(
            "aws logs start-query --log-group-name x --start-time 1 --end-time 2 --query-string fields @message",
            "aws logs stop-query --query-id q-example",
            "aws athena start-query-execution --query-string 'select 1'",
            "aws --profile p logs start-query --log-group-name x",
        )

    def test_a_write_dressed_as_a_read_is_denied(self) -> None:
        """glob 은 동사 자리를 못 고정한다 — ` get-x` 를 뒤에 붙이면 읽기 패턴에 맞는다. 쓰기 deny 가 그 위를 덮는다."""
        self.assert_denied(
            "aws ec2 terminate-instances --instance-ids i-0example --query get-x",
            "aws iam put-role-policy --role-name r --policy-name list-x --policy-document file://p.json",
            "aws s3 rm s3://example-bucket/key --query get-x",
            "aws --profile p s3 sync . s3://example-bucket --exclude list-x",
        )

    def test_curl_writes_are_denied(self) -> None:
        """curl 의 쓰기 호출 — 메서드 지정과 본문·업로드 플래그. 외부로 내보내는 길을 막는다."""
        self.assert_denied(
            "curl -X POST https://example.com/api",
            "curl -XPOST https://example.com/api",
            "curl --request PUT https://example.com/api",
            "curl --request=DELETE https://example.com/api",
            "curl -X PATCH https://example.com/api",
            "curl https://example.com -d '{}'",
            "curl https://example.com --data @body.json",
            "curl https://example.com --json '{}'",
            "curl -F file=@x.png https://example.com",
            "curl --form field=value https://example.com",
            "curl -T upload.txt https://example.com",
            "curl --upload-file x https://example.com",
        )

    def test_curl_reads_still_ask(self) -> None:
        """GET 조회는 deny 가 아니다 — 지금처럼 묻는다(기본값). 허용 목록에도 없다."""
        self.assert_asks(
            "curl https://example.com",
            "curl -s https://example.com/api",
            "curl -o out.txt https://example.com/file",
        )

    def test_a_redirect_still_asks_not_denies(self) -> None:
        """`>` 는 deny 로 올리지 않는다 — 지금처럼 허용에서 빠져 묻는다."""
        self.assert_asks("aws ec2 describe-instances > out.txt", "grep x y >> z")

    def test_aws_reads_that_return_secrets_still_ask(self) -> None:
        """비밀을 돌려주는 읽기는 deny 로 올리지 않는다 — 허용에서 빠져 묻는다."""
        self.assert_asks(
            "aws secretsmanager get-secret-value --secret-id x",
            "aws ssm get-parameter --name x --with-decryption",
            "aws ecr get-login-password",
            "aws sts get-session-token",
        )

    def test_everyday_read_commands_run_without_asking(self) -> None:
        self.assert_allowed(
            "cat tickets/12345.md", "grep -rn fetch-ticket agents", "head -20", "tail -n 5 notes.log",
            "ls", "ls -la tickets", "wc -l ONBOARDING.md", "sort", "uniq -c", "jq .results", "rg TODO",
            "find . -name '*.md'",
        )

    def test_reading_credential_files_still_asks(self) -> None:
        """작업 폴더 밖 읽기는 기본값이 묻는다. `cat *` 이 그 확인을 없애므로 자격증명 자리는 도로 묻게 한다."""
        self.assert_asks(
            "cat ~/.aws/credentials", "cat ~/.config/msp/zendesk.conf", "grep -r TOKEN ~/.config/msp",
            "head ~/.ssh/id_ed25519", "cat .env", "cat prod.pem", "tail ~/.kiro/settings/cli.json",
        )

    def test_read_commands_cannot_write(self) -> None:
        """`cat a > scripts/check_ticket_record.py` 로 허용된 스크립트를 바꿔 치면 아무 코드나 묻지 않고 돈다."""
        self.assert_asks(
            "cat tickets/x.md > scripts/check_ticket_record.py", "grep x y >> z", "sort -o out.txt in.txt",
            "find . -name x -delete", "find . -exec rm {} ;",
        )

    def test_aws_execution_mcp_tools_are_denied(self) -> None:
        """.claude/settings.json 의 deny 5개와 같은 도구 — AWS 를 실제로 실행·업로드하는 MCP 도구.
        서버 자리는 `*` 로 둔다(서버 이름이 무엇이든). 서버 자리 와일드카드가 Kiro 에서 실제로 먹는지는 조율자가 확인한다."""
        self.assert_denied(
            "aws-docs/aws___call_aws", "aws-mcp/aws___call_aws", "aws-docs/aws___run_script",
            "aws-mcp/aws___get_presigned_url", "aws-docs/aws___get_tasks", "aws-mcp/aws___retrieve_skill",
            capability="mcp",
        )

    def test_doc_mcp_tools_are_not_denied(self) -> None:
        """문서·검색 도구는 막지 않는다 — 실행 도구만 deny."""
        for tool in ("aws-docs/aws___read_documentation", "aws-docs/aws___search_documentation", "exa/web_search_exa"):
            self.assertFalse(denied(tool, "mcp"), f"막힌다: {tool}")

    def test_everything_else_still_asks(self) -> None:
        self.assert_asks("rm -rf tickets", "curl https://example.com", "git push origin main", "sed -i s/a/b/ x", "sudo ls")

    def test_the_block_carries_deny_rules(self) -> None:
        text = kp.render_block()
        self.assertIn("effect: deny", text)
        self.assertIn('"aws * terminate-*"', text)
        self.assertIn('"curl *-X POST*"', text)
        self.assertIn('"*/aws___call_aws"', text)

    def test_only_expected_capabilities_appear(self) -> None:
        self.assertEqual({rule["capability"] for rule in kp.RULES}, {"shell", "fs_write", "mcp"})
        writes = [p for rule in kp.RULES if rule["capability"] == "fs_write" for p in rule["match"]]
        self.assertEqual(sorted(writes), ["customers/**", "tickets/**"])
        self.assertFalse([p for rule in kp.RULES if rule.get("effect") == "allow"
                          for p in rule.get("match", ()) if p.strip() in ("*", "**", "aws *")])

    def test_block_is_valid_yaml_in_kiros_own_shape(self) -> None:
        text = kp.merge(KIRO_WRITTEN)
        try:
            import yaml
        except ImportError:
            self.skipTest("PyYAML 없음")
        rules = yaml.safe_load(text)["rules"]
        self.assertEqual(rules[0]["match"], ["echo *", "git *"])
        self.assertEqual(len(rules) - 1, len(kp.RULES))
        for written, rule in zip(rules[1:], kp.RULES):
            self.assertEqual(written["capability"], rule["capability"])
            self.assertEqual(written["effect"], rule.get("effect", "allow"))
            self.assertEqual(written["match"], list(rule.get("match", ())))
            self.assertEqual(written.get("exclude", []), list(rule.get("exclude", ())))


if __name__ == "__main__":
    unittest.main()
