#!/usr/bin/env python3
"""fetch-ticket 의 429 재시도. 진짜 Zendesk 는 부르지 않는다 — `curl`·`sleep` 을 가짜로 바꿔 요청 함수만 돌린다.

Zendesk 한도는 분당 400 이고 계정 전체가 나눠 쓴다(응답 헤더 `x-rate-limit: 400`, developer.zendesk.com
rate-limits, 2026-10-07 조회). 한도에 걸리면 429 와 `Retry-After`(초)가 온다. 예전에는 그냥 실패로 끝나서
에이전트가 곧바로 다시 불렀고, 그러면 한도를 더 쓴다.
"""

from __future__ import annotations

import os
import re
import shutil
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SH = (ROOT / "scripts/fetch-ticket.sh").read_text(encoding="utf-8")
PS1 = (ROOT / "scripts/fetch-ticket.ps1").read_text(encoding="utf-8")

# 응답 목록을 차례로 내놓는 가짜 curl. `-D <파일>` 에 헤더를 쓰고, 본문 뒤에 `-w` 의 상태 코드를 붙인다.
FAKE_CURL = r"""#!/usr/bin/env bash
dir="$(dirname "$0")"; n=$(cat "$dir/count" 2>/dev/null || echo 0); echo $((n + 1)) > "$dir/count"
line=$(sed -n "$((n + 1))p" "$dir/responses"); [ -n "$line" ] || line=$(tail -1 "$dir/responses")
code="${line%%|*}"; rest="${line#*|}"; retry="${rest%%|*}"; body="${rest#*|}"
headers=""
while [ $# -gt 0 ]; do case "$1" in -D) headers="$2"; shift ;; esac; shift; done
if [ -n "$headers" ]; then
    printf 'HTTP/2 %s\r\n' "$code" > "$headers"
    [ -n "$retry" ] && printf 'Retry-After: %s\r\n' "$retry" >> "$headers"
fi
printf '%s\n%s' "$body" "$code"
"""
FAKE_SLEEP = '#!/usr/bin/env bash\necho "$1" >> "$(dirname "$0")/slept"\n'


def function_text(name: str) -> str:
    found = re.search(rf"^{name}\(\) \{{.*?^\}}\n", SH, re.DOTALL | re.MULTILINE)
    assert found, f"{name} 을 못 찾았다"
    return found.group(0)


def constants() -> str:
    return "\n".join(re.findall(r"^MAX_RATE_[A-Z_]+=\d+$", SH, re.MULTILINE))


class RateLimitTests(unittest.TestCase):
    def run_fetch(self, responses: list[str], function: str = "zd_fetch", args: str = "https://x/api") -> tuple[int, str, str, list[str], int]:
        with tempfile.TemporaryDirectory() as tmp:
            bin_dir = Path(tmp)
            for name, text in (("curl", FAKE_CURL), ("sleep", FAKE_SLEEP)):
                (bin_dir / name).write_text(text, encoding="utf-8")
                (bin_dir / name).chmod(stat.S_IRWXU)
            (bin_dir / "responses").write_text("\n".join(responses) + "\n", encoding="utf-8")
            script = "\n".join(["set -euo pipefail", 'AUTH="a:b"', 'BASE="https://x/api"', constants(),
                                function_text("zd_fetch"), function_text("zd"), f"{function} {args}"])
            done = subprocess.run(["bash", "-c", script], capture_output=True, text=True,
                                  env={**os.environ, "PATH": f"{bin_dir}{os.pathsep}{os.environ['PATH']}"})
            slept = (bin_dir / "slept").read_text(encoding="utf-8").split() if (bin_dir / "slept").exists() else []
            return done.returncode, done.stdout, done.stderr, slept, int((bin_dir / "count").read_text())

    def test_waits_as_long_as_zendesk_says_then_gets_the_ticket(self) -> None:
        code, out, err, slept, calls = self.run_fetch(["429|7|", '200||{"ticket":{"id":1}}'])
        self.assertEqual((code, calls, slept), (0, 2, ["7"]))
        self.assertEqual(out, '{"ticket":{"id":1}}\n200')
        self.assertIn("7초", err)

    def test_gives_up_after_two_retries_and_says_not_to_hammer(self) -> None:
        code, out, err, slept, calls = self.run_fetch(["429|5|"], function="zd", args="/tickets/1.json")
        self.assertEqual((code, calls, slept), (1, 3, ["5", "5"]))
        self.assertIn("HTTP 429", err)
        self.assertIn("바로 다시 실행하지", err)

    def test_a_long_or_missing_retry_after_is_bounded(self) -> None:
        """세션을 몇 분씩 세워 두지 않는다. 헤더가 없으면 짧게 한 번 쉰다."""
        _, _, _, slept, _ = self.run_fetch(["429|600|", "429||", '200||{}'])
        self.assertEqual(slept, ["60", "10"])

    def test_other_failures_are_not_retried(self) -> None:
        for status in ("404", "401", "500"):
            with self.subTest(status=status):
                code, _, _, slept, calls = self.run_fetch([f"{status}||"], function="zd", args="/tickets/1.json")
                self.assertEqual((code, calls, slept), (1, 1, []))

    def test_every_zendesk_call_goes_through_the_retrying_fetch(self) -> None:
        """재시도는 한 곳에만 있다. 본문 이미지 내려받기(`-o`)만 예외다 — 실패해도 조회를 막지 않는다."""
        calls = [line.strip() for line in SH.splitlines() if "curl -sS" in line and " -o " not in line]
        self.assertEqual(len(calls), 1, calls)
        self.assertIn(calls[0], function_text("zd_fetch"))


@unittest.skipUnless(shutil.which("pwsh"), "pwsh 가 없다")
class PowerShellRateLimitTests(unittest.TestCase):
    """Windows 동료는 .ps1 을 쓴다. 요청 함수만 떼어 가짜 `Invoke-RestMethod` 로 돌린다."""

    def run_ps(self, statuses: list[str]) -> tuple[int, str]:
        """statuses 는 `코드:Retry-After` 문자열들. 해시테이블 배열로 넘기면 원소가 하나일 때 PowerShell 버전에 따라
        배열이 풀려 가짜가 엉뚱한 응답을 낸다(CI 의 pwsh 에서 그랬다) — 문자열을 쪼개 쓴다."""
        function = re.search(r"^function Invoke-Zd \{.*?^\}\n", PS1, re.DOTALL | re.MULTILINE)
        consts = "\n".join(re.findall(r"^\$MaxRate\w+ = \d+$", PS1, re.MULTILINE))
        self.assertIsNotNone(function)
        # HttpResponseException 은 Utility 모듈에 있다. 그 모듈의 명령을 아직 안 쓴 세션에서는 형식을 못 찾아
        # 가짜가 엉뚱한 예외를 던진다(리눅스 pwsh 에서 그랬다) — 먼저 올린다.
        harness = f"""
Import-Module Microsoft.PowerShell.Utility
$script:calls = 0; $script:slept = ''; $headers = @{{}}
$script:specs = '{",".join(statuses)}'.Split(',')
function Invoke-RestMethod {{
    $spec = $script:specs[[Math]::Min($script:calls, $script:specs.Length - 1)]; $script:calls++
    $parts = $spec.Split(':'); $code = [int]$parts[0]; $retry = $parts[1]
    if ($code -eq 200) {{ return 'ok' }}
    $response = [System.Net.Http.HttpResponseMessage]::new([System.Net.HttpStatusCode]$code)
    if ($retry) {{ $response.Headers.TryAddWithoutValidation('Retry-After', $retry) | Out-Null }}
    throw [Microsoft.PowerShell.Commands.HttpResponseException]::new('fail', $response)
}}
function Start-Sleep {{ param($Seconds) $script:slept += "$Seconds " }}
{consts}
{function.group(0)}
try {{ $r = Invoke-Zd 'https://x/api' }} finally {{ Write-Output "calls=$($script:calls) slept=$($script:slept.Trim())" }}
"""
        done = subprocess.run(["pwsh", "-NoProfile", "-Command", harness], capture_output=True, text=True)
        return done.returncode, done.stdout + done.stderr

    def test_waits_then_succeeds(self) -> None:
        code, out = self.run_ps(["429:7", "200:"])
        self.assertEqual(code, 0, out)
        self.assertIn("calls=2 slept=7", out)

    def test_gives_up_after_two_retries(self) -> None:
        code, out = self.run_ps(["429:600"])
        self.assertEqual(code, 1, out)
        self.assertIn("calls=3 slept=60 60", out)
        self.assertIn("HTTP 429", out)
        self.assertIn("바로 다시 실행하지", out)

    def test_a_missing_retry_after_waits_briefly(self) -> None:
        code, out = self.run_ps(["429:", "200:"])
        self.assertEqual(code, 0, out)
        self.assertIn("calls=2 slept=10", out)

    def test_other_failures_are_not_retried(self) -> None:
        code, out = self.run_ps(["404:"])
        self.assertEqual(code, 1, out)
        self.assertIn("HTTP 404", out)  # 가짜가 엉뚱한 응답을 내면 여기서 드러난다
        self.assertIn("calls=1 slept=", out)



class HeaderTests(unittest.TestCase):
    def test_header_prints_today_so_the_record_can_carry_it_as_written_date(self) -> None:
        """2026-10-22 평가: Kiro 가 오늘을 몰라 `작성일:` 에도 스레드 날짜를 베꼈다. 조회 결과에 오늘을 찍어 준다."""
        self.assertRegex(SH, r'echo "조회일 : \$\(date \+%F\)')
        self.assertRegex(PS1, r"Write-Output \"조회일 : \$\(Get-Date -Format 'yyyy-MM-dd'\)")

if __name__ == "__main__":
    unittest.main(verbosity=2)
