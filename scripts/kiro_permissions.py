#!/usr/bin/env python3
"""Kiro 가 이 워크스페이스의 정해진 작업을 매번 묻지 않게 한다.

Kiro(IDE·CLI v3)의 권한 규칙은 저장소에 둘 수 없다 — 사용자 PC 의
`~/.kiro/workspace-roots/<hash>/permissions.yaml` 에만 있다("A cloned repo cannot inject permission
rules", kiro.dev/docs/permissions, 2026-10-01 조회). 그래서 온보딩이 각자 PC 에서 이 파일을 부른다.

    python3 scripts/kiro_permissions.py            지금 상태만 알린다. 아무것도 바꾸지 않는다
    python3 scripts/kiro_permissions.py --install  규칙을 넣는다. 이미 있던 규칙은 두고 백업한다

허용하는 것은 아래 RULES 다 — 프레임워크 스크립트, `aws` 읽기 호출, `cat`·`grep` 같은 읽기 명령, 기록 폴더 쓰기.
`exclude` 에 걸리면 허용에서 빠져 도로 묻는다: 비밀을 돌려주는 읽기, 자격증명 파일 읽기, `>` 로 파일에 쓰기.
그리고 **deny** 로 못 박는 것 — `aws` 쓰기 호출·`s3` 쓰기, `curl` 의 쓰기 호출, AWS 실행 MCP 도구. Kiro 를 Trust All
Tools 로 쓰면 "묻기" 는 그냥 통과하지만 deny 는 어느 범위의 allow·ask 보다 세다("deny > ask > allow … regardless of
scope", kiro.dev/docs/permissions, 2026-10-04). deny 는 벽이 아니라 문턱이다 — glob 은 `python -c`·스크립트·변수 치환으로
우회된다. 벽은 토큰 범위와 브로커다. 고객 계정 잠금(`agents/customer-access-locks.md`)은 이 규칙이 보지 못한다 — 에이전트
규칙이 지킨다 (development/decisions/0030).
"""

from __future__ import annotations

import hashlib
import json
import os
import shutil
import sys
import unicodedata
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

# 스크립트 이름까지 적는다. `python3 scripts/*` 는 `python3 scripts/../tickets/x.py` 도 통과시킨다.
_PYTHON_SCRIPTS = ("check_ticket_record", "validate_workspace", "verify_mcp_servers", "local_capabilities",
                   "weekly_diary", "customer_notes")
_SCRIPTS = ("bash scripts/fetch-ticket.sh*",) + tuple(
    f"{python} scripts/{name}.py*" for name in _PYTHON_SCRIPTS for python in ("python3", "python"))

# `>` 가 있으면 묻는다 — `cat a > scripts/check_ticket_record.py` 로 허용된 스크립트를 바꿔 치지 못하게.
_REDIRECT = ("*>*",)

# 읽기 동사만. 프로필이 앞에 와도(`aws --profile x ec2 describe-…`) 맞는다.
_AWS_READS = ("aws * describe-*", "aws * list-*", "aws * get-*", "aws * batch-get-*", "aws * lookup-events*",
              "aws * filter-log-events*", "aws s3 ls*", "aws * s3 ls*", "aws configure get *", "aws configure list*")
# ponytail: glob 은 동사 자리를 못 고정한다 — 쓰기 호출 뒤에 ` --query get-x` 를 붙이면 위 패턴에 맞는다.
# 그래서 쓰기 동사를 따로 뺀다. 목록에 없는 쓰기 동사는 샌다 — 고객 계정은 브로커가 서버에서 읽기 전용으로 막는다.
_AWS_WRITE_VERBS = (
    "create-", "delete-", "update-", "modify-", "put-", "terminate-", "run-", "start-", "stop-", "reboot-",
    "attach-", "detach-", "add-", "remove-", "set-", "reset-", "restore-", "replace-", "change-", "apply-",
    "tag-", "untag-", "associate-", "disassociate-", "authorize-", "revoke-", "register-", "deregister-",
    "enable-", "disable-", "cancel-", "send-", "copy-", "import-", "execute-", "assume-", "allocate-", "release-",
    "purchase-", "accept-", "reject-", "publish", "invoke",
)
_AWS_S3_WRITES = ("rm", "cp", "mv", "sync", "rb", "mb")
# 읽기 동사지만 비밀을 돌려준다.
_AWS_SECRET_READS = ("get-secret-value", "get-parameter", "get-session-token", "get-federation-token",
                     "get-login-password", "get-authorization-token")
_AWS_ASK = (tuple(f"aws * {verb}*" for verb in _AWS_WRITE_VERBS + _AWS_SECRET_READS)
            + tuple(f"aws{profile} s3 {verb}*" for verb in _AWS_S3_WRITES for profile in ("", " *")) + _REDIRECT)

# 쓰기 호출은 deny 로 못 박는다 — Kiro 를 Trust All Tools 로 쓰면 "묻기" 는 그냥 통과하지만 deny 는
# 어느 범위의 allow·ask 보다 세다("deny > ask > allow … regardless of scope", kiro.dev/docs/permissions, 2026-10-04).
# start-query·stop-query 는 쓰기 동사지만 CloudWatch Logs Insights·Athena 조회라 exclude 로 빼서 "묻기" 로 남긴다.
# 비밀을 돌려주는 읽기(_AWS_SECRET_READS)와 `>` 리다이렉트는 deny 로 올리지 않는다 — 지금처럼 _AWS_ASK 로 묻는다.
_AWS_QUERY_VERBS = ("aws * start-query*", "aws * stop-query*")
_AWS_DENY = (tuple(f"aws * {verb}*" for verb in _AWS_WRITE_VERBS)
             + tuple(f"aws{profile} s3 {verb}*" for verb in _AWS_S3_WRITES for profile in ("", " *")))

# curl 의 쓰기 호출 — 메서드 지정과 본문·업로드 플래그. GET 조회(`curl https://…`)는 deny 가 아니다(기본값대로 묻는다).
_CURL_METHODS = ("POST", "PUT", "PATCH", "DELETE")
_CURL_DENY = (tuple(pattern for method in _CURL_METHODS for pattern in (
                  f"curl *-X {method}*", f"curl *-X{method}*",
                  f"curl *--request {method}*", f"curl *--request={method}*"))
              + tuple(pattern for flag in ("-d", "--data", "--json", "-F", "--form", "-T", "--upload-file")
                      for pattern in (f"curl * {flag} *", f"curl * {flag}*", f"curl {flag} *", f"curl {flag}*")))

# AWS 를 실제로 실행·업로드하는 MCP 도구 — .claude/settings.json 의 deny 5개와 같은 도구 이름.
# 서버 자리는 `*` 로 둔다(서버 이름이 무엇이든). 서버 자리 와일드카드가 Kiro 에서 실제로 먹는지는 조율자가 진짜 Kiro 로 확인한다.
_MCP_DENY = ("*/aws___call_aws", "*/aws___run_script", "*/aws___get_presigned_url",
             "*/aws___get_tasks", "*/aws___retrieve_skill")

_READ_COMMANDS = ("cat", "head", "tail", "grep", "rg", "ls", "wc", "sort", "uniq", "jq", "find")
# 작업 폴더 밖 읽기는 기본값이 묻는다. `cat *` 이 그 확인을 없애므로 자격증명 자리는 도로 묻게 한다.
_SECRET_PATHS = ("*.aws/*", "*msp*", "*.ssh/*", "*.env*", "*.pem*", "*.key*", "*credential*", "*.kiro/settings*")
_READ_ASK = _SECRET_PATHS + _REDIRECT + ("find * -delete*", "find * -exec*", "find * -ok*", "sort -o*", "sort * -o*")

# 한계 — deny 는 벽이 아니라 문턱이다:
#  · glob 은 우회된다: `python -c`, 스크립트 파일, `V=aws; $V ...` 변수 치환은 이 패턴에 안 걸린다.
#  · 거짓 양성: 읽기 호출의 인자에 ` delete-` 같은 문자열이 있으면 deny 에 걸린다. 그 값을 따옴표로 감싸면 피한다.
#  · 벽은 토큰 범위와 브로커(서버에서 읽기 전용으로 막음)다. 이 규칙은 사람이 보던 승인 창을 대신할 뿐이다.
RULES: tuple[dict, ...] = (
    {"capability": "shell", "match": _SCRIPTS},
    {"capability": "shell", "match": _AWS_READS, "exclude": _AWS_ASK},
    {"capability": "shell", "exclude": _READ_ASK,
     "match": tuple(pattern for command in _READ_COMMANDS for pattern in (command, f"{command} *"))},
    {"capability": "fs_write", "match": ("tickets/**", "customers/**")},
    {"capability": "shell", "effect": "deny", "match": _AWS_DENY, "exclude": _AWS_QUERY_VERBS},
    {"capability": "shell", "effect": "deny", "match": _CURL_DENY},
    {"capability": "mcp", "effect": "deny", "match": _MCP_DENY},
)

BEGIN = "  # tiket-permissions begin — scripts/kiro_permissions.py 가 쓴다. 이 사이는 다시 쓰인다"
END = "  # tiket-permissions end"
COMMAND = "python3 scripts/kiro_permissions.py --install"


def _quoted(pattern: str) -> str:
    """YAML 큰따옴표 문자열 안에 넣을 수 있게."""
    return pattern.replace("\\", "\\\\").replace('"', '\\"')


def render_block(rules: tuple[dict, ...] = RULES) -> str:
    """Kiro 가 쓰는 모양 그대로 — `rules:` 아래 두 칸 들여쓴 목록."""
    lines = [BEGIN]
    for rule in rules:
        lines += [f"  - capability: {rule['capability']}", f"    effect: {rule.get('effect', 'allow')}"]
        for key in ("match", "exclude"):
            if rule.get(key):
                lines += [f"    {key}:"] + [f'      - "{_quoted(pattern)}"' for pattern in rule[key]]
    return "\n".join(lines + [END]) + "\n"


def workspace_dir(root: Path, home: Path, os_name: str = os.name) -> Path | None:
    """이 저장소의 권한 폴더. 모르면 None — 틀린 폴더에 쓰면 조용히 안 먹는다."""
    base = home / ".kiro/workspace-roots"
    for marker in sorted(base.glob("*/.trust-migration.json")):
        try:
            if Path(json.loads(marker.read_text(encoding="utf-8"))["root"]) == root:
                return marker.parent
        except (OSError, ValueError, KeyError, TypeError):
            continue
    if os_name == "nt":
        return None  # Windows 경로를 Kiro 가 어떻게 해시하는지 확인하지 못했다
    # ponytail: Kiro 가 연 경로 문자열 그대로를 해시한다고 본다(macOS 2건 확인). 심볼릭 링크나
    # 대소문자가 다른 경로로 열면 다른 폴더가 된다 — 그런 보고가 오면 --status 가 폴더를 고르게 한다.
    name = hashlib.sha256(unicodedata.normalize("NFC", str(root)).encode("utf-8")).hexdigest()[:16]
    return base / name


def _without_block(text: str) -> str:
    if BEGIN not in text or END not in text:
        return text
    head, rest = text.split(BEGIN, 1)
    return head + rest.split(END, 1)[1].lstrip("\n")


def merge(existing: str | None) -> str | None:
    """새 파일 내용. 붙였을 때 YAML 이 깨질 모양이면 None."""
    kept = _without_block(existing or "")
    if not kept.strip():
        return "rules:\n" + render_block()
    content = [line for line in kept.splitlines() if line.strip() and not line.lstrip().startswith("#")]
    if content[0] != "rules:" or not all(line.startswith("  ") for line in content[1:]):
        return None
    # ponytail: Kiro 가 파일을 다시 쓰며 주석(표식)을 지우면 다음 --install 이 규칙을 한 번 더 붙인다.
    # allow 가 겹칠 뿐 동작은 같다. 그렇게 쌓이는 게 보이면 YAML 을 읽어 합친다.
    return kept.rstrip("\n") + "\n" + render_block()


def _manual(reason: str) -> str:
    return (f"{reason}\nKiro 에서 승인 창이 뜰 때 Always allow → This workspace 를 고르거나, "
            f"Kiro 가 만든 permissions.yaml 의 rules: 아래에 이것을 붙인다:\n{render_block()}")


def install(root: Path, home: Path, os_name: str = os.name) -> tuple[int, str]:
    folder = workspace_dir(root, home, os_name)
    if folder is None:
        return 1, _manual("이 PC 에서 Kiro 의 워크스페이스 권한 폴더를 찾지 못해 아무것도 쓰지 않았다.")
    target = folder / "permissions.yaml"
    existing = target.read_text(encoding="utf-8") if target.is_file() else None
    merged = merge(existing)
    if merged is None:
        return 1, _manual(f"{target} 이 예상한 모양이 아니라 그대로 두었다.")
    if merged == existing:
        return 0, f"Kiro 권한 규칙이 이미 들어 있다 ({target})"
    folder.mkdir(parents=True, exist_ok=True)
    undo = f"rm '{target}'"
    if existing is not None:
        backup = target.with_name("permissions.yaml.bak")
        shutil.copyfile(target, backup)
        undo = f"cp '{backup}' '{target}'"
    target.write_text(merged, encoding="utf-8")
    return 0, f"Kiro 권한 규칙을 넣었다 ({target}). 다음 Kiro 세션부터 적용된다. 되돌리기: {undo}"


def refresh_if_installed(root: Path, home: Path, os_name: str = os.name) -> str | None:
    """이미 tiket 블록이 든 PC 를 지금 RULES 로 다시 맞춘다. 세션 시작 경로에서 부른다.

    표식(BEGIN/END) 블록이 있고 내용이 지금 RULES 와 다르면 install 과 같은 방식으로 다시 쓰고(백업 포함) 한 줄을 돌려준다.
    블록이 없으면(이 PC 가 아직 설치 안 했거나 Kiro 가 표식을 지웠으면) 아무것도 쓰지 않는다 — 설치는 본인이 온보딩으로 한다 (0030).
    바꾼 날만 한 줄이 나오고 평소에는 None. 어떤 예외도 밖으로 던지지 않는다."""
    try:
        folder = workspace_dir(root, home, os_name)
        if folder is None:
            return None
        target = folder / "permissions.yaml"
        if not target.is_file():
            return None
        existing = target.read_text(encoding="utf-8")
        if BEGIN not in existing or END not in existing:
            return None  # 우리 블록이 없으면 손대지 않는다
        merged = merge(existing)
        if merged is None or merged == existing:
            return None  # 모양이 이상하거나 이미 최신이면 조용히
        shutil.copyfile(target, target.with_name("permissions.yaml.bak"))
        target.write_text(merged, encoding="utf-8")
        return f"Kiro 권한 규칙을 최신으로 맞췄다 ({target}). 다음 Kiro 세션부터 적용된다."
    except Exception:
        return None


def status(root: Path, home: Path, os_name: str = os.name) -> tuple[int, str]:
    folder = workspace_dir(root, home, os_name)
    target = folder / "permissions.yaml" if folder else None
    if target and target.is_file() and merge(target.read_text(encoding="utf-8")) == target.read_text(encoding="utf-8"):
        return 0, "Kiro 권한 규칙 설치됨 — 허용(티켓 가져오기·aws 읽기·cat·grep·기록 쓰기)·묻기·막기(aws·s3 쓰기·curl 쓰기·AWS 실행 MCP)"
    return 1, f"Kiro 가 티켓 가져오기·aws 읽기·cat·grep 을 매번 묻고 위험한 쓰기를 막지 않는다(또는 규칙이 옛 것이다). 온보딩을 --check 없이 돌리거나: {COMMAND}"


def main(argv: list[str]) -> int:
    code, message = (install if "--install" in argv else status)(ROOT, Path.home())
    print(message)
    return code


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
