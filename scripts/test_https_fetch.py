#!/usr/bin/env python3
"""https_fetch — Python 으로 밖에 나가는 유일한 문. 네트워크는 여기서 부르지 않는다.

동료 한 명의 PC 에서 지표·교훈 후보·Zendesk 지표가 전부 조용히 실패했다(2026-10-07). python.org 설치판 Python 은
루트 인증서를 따로 깔아야 하는데 안 깔려 있었다 — `CERTIFICATE_VERIFY_FAILED`. 같은 PC 의 `git`·`curl` 은 OS 인증서를
써서 멀쩡했다. 검증이 실패하면 OS 인증서 묶음으로 한 번 더 시도한다. **검증을 끄지는 않는다.**
"""

from __future__ import annotations

import re
import ssl
import sys
import unittest
import urllib.error
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
import https_fetch  # noqa: E402

CERT_ERROR = urllib.error.URLError(ssl.SSLCertVerificationError(1, "certificate verify failed"))


class FakeOpen:
    def __init__(self, *outcomes) -> None:
        self.outcomes = list(outcomes)
        self.calls: list[dict] = []

    def __call__(self, request, **kwargs):
        self.calls.append(kwargs)
        outcome = self.outcomes.pop(0)
        if isinstance(outcome, Exception):
            raise outcome
        return outcome


class UrlopenTests(unittest.TestCase):
    def setUp(self) -> None:
        self.bundle = str(ROOT / "scripts/release-signers")  # 있는 파일이면 된다 — 가짜 문맥 함수가 받는다
        self.contexts: list[str] = []
        self.kwargs = {"bundles": (str(ROOT / "no-such-file"), self.bundle),
                       "certifi_for": lambda: None,  # 기본: certifi 없는 PC. 있는 PC 는 아래 전용 케이스에서 본다
                       "context_for": lambda path: self.contexts.append(path) or f"context:{path}"}

    def test_a_working_python_is_left_alone(self) -> None:
        opener = FakeOpen("response")
        self.assertEqual(https_fetch.urlopen("req", timeout=7, opener=opener, **self.kwargs), "response")
        self.assertEqual(opener.calls, [{"timeout": 7}])

    def test_cert_failure_is_retried_with_certifi_before_any_os_bundle(self) -> None:
        """certifi 가 있으면 OS 묶음보다 먼저 쓴다 — OS 는 최신인데 Python 번들만 낡은 PC 를 위한 칸이다."""
        opener = FakeOpen(CERT_ERROR, "response")
        kwargs = {**self.kwargs, "certifi_for": lambda: "/fake/certifi/cacert.pem"}
        self.assertEqual(https_fetch.urlopen("req", timeout=7, opener=opener, **kwargs), "response")
        self.assertEqual(self.contexts, ["/fake/certifi/cacert.pem"])

    def test_without_certifi_the_cert_failure_falls_back_to_the_os_bundle(self) -> None:
        opener = FakeOpen(CERT_ERROR, "response")
        self.assertEqual(https_fetch.urlopen("req", timeout=7, opener=opener, **self.kwargs), "response")
        self.assertEqual(self.contexts, [self.bundle])

    def test_other_failures_are_not_retried(self) -> None:
        for error in (urllib.error.URLError(TimeoutError("timed out")),
                      urllib.error.HTTPError("u", 429, "Too Many", None, None), OSError("refused")):
            with self.subTest(error=type(error).__name__):
                opener = FakeOpen(error)
                with self.assertRaises(type(error)):
                    https_fetch.urlopen("req", timeout=7, opener=opener, **self.kwargs)
                self.assertEqual(len(opener.calls), 1)

    def test_without_an_os_bundle_the_cert_failure_is_raised_as_it_was(self) -> None:
        opener = FakeOpen(CERT_ERROR)
        with self.assertRaises(urllib.error.URLError) as raised:
            https_fetch.urlopen("req", timeout=7, opener=opener,
                                bundles=(str(ROOT / "no-such-file"),), certifi_for=lambda: None)
        self.assertIs(raised.exception, CERT_ERROR)
        self.assertEqual(len(opener.calls), 1)

    def test_the_retry_still_verifies_the_certificate(self) -> None:
        """묶음만 바꾼다. 검증을 끄면 중간에서 가로채도 모른다."""
        bundle = next((path for path in https_fetch.OS_CA_BUNDLES if Path(path).exists()), None)
        if bundle is None:
            self.skipTest("이 PC 에는 OS 인증서 묶음이 없다")
        context = https_fetch.verified_context(bundle)
        self.assertEqual(context.verify_mode, ssl.CERT_REQUIRED)
        self.assertTrue(context.check_hostname)

    def test_says_whether_a_failure_is_about_certificates(self) -> None:
        self.assertTrue(https_fetch.is_cert_error(CERT_ERROR))
        self.assertFalse(https_fetch.is_cert_error(urllib.error.URLError(TimeoutError())))
        self.assertFalse(https_fetch.is_cert_error(OSError("x")))


class SingleDoorTests(unittest.TestCase):
    def test_no_script_opens_urls_on_its_own(self) -> None:
        """한 곳만 고치면 되게 한다. 문이 둘이면 한쪽만 다시 조용히 실패한다."""
        direct = [path.name for path in sorted((ROOT / "scripts").glob("*.py"))
                  if not path.name.startswith("test_") and path.name != "https_fetch.py"
                  and re.search(r"urllib\.request\.urlopen\(", path.read_text(encoding="utf-8"))]
        self.assertEqual(direct, [])


if __name__ == "__main__":
    unittest.main(verbosity=2)
