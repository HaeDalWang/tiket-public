#!/usr/bin/env python3
"""Python 으로 밖에 나가는 유일한 문.

python.org 설치판 Python(macOS)은 루트 인증서를 따로 깔아야 한다. 안 깔린 PC 에서는 모든 HTTPS 가
`CERTIFICATE_VERIFY_FAILED` 로 죽는다 — 사용 지표·교훈 후보·Zendesk 지표·고객 특이사항이 전부 조용히 실패했고,
같은 PC 의 `git`·`curl` 은 OS 인증서를 써서 멀쩡했기 때문에 아무도 몰랐다(2026-10-07).

검증이 실패하면 **certifi(최신 Mozilla 루트) → OS 인증서 묶음** 순으로 **한 번 더** 시도한다.
검증을 끄지 않는다 — 묶음만 바꾼다.

certifi 를 OS 묶음보다 앞에 두는 이유: OS 는 최신인데 Python 이 들고 있는 번들만 낡은 PC 가 있었다
(한 엔지니어 PC, 2026-10-23). 이 경우 OS 묶음으로는 못 넘고 `pip install certifi` 로만 넘었다. certifi 가
없으면 그 칸을 건너뛰고 OS 묶음만 시도한다 — 없다고 더 나빠지지는 않는다.
"""

from __future__ import annotations

import os
import ssl
import urllib.error
import urllib.request

# macOS · Debian/Ubuntu · RHEL 계열. Windows 의 Python 은 OS 저장소를 직접 읽어서 해당이 없다.
OS_CA_BUNDLES = ("/etc/ssl/cert.pem", "/etc/ssl/certs/ca-certificates.crt", "/etc/pki/tls/certs/ca-bundle.crt")


def verified_context(bundle: str) -> ssl.SSLContext:
    return ssl.create_default_context(cafile=bundle)


def is_cert_error(error: BaseException) -> bool:
    return isinstance(getattr(error, "reason", None), ssl.SSLCertVerificationError)


def certifi_bundle() -> str | None:
    """certifi 가 깔려 있으면 그 번들 경로. 없으면 None — 부를 때 찾는다(테스트가 갈아 끼울 수 있게)."""
    try:
        import certifi
    except ImportError:
        return None
    return certifi.where()


def urlopen(request, timeout: float, *, opener=None, bundles=OS_CA_BUNDLES,
            context_for=verified_context, certifi_for=certifi_bundle):
    opener = opener or urllib.request.urlopen  # 부를 때 찾는다 — 테스트가 갈아 끼울 수 있게
    try:
        return opener(request, timeout=timeout)
    except urllib.error.URLError as error:
        if not is_cert_error(error):
            raise
        # certifi(최신 Mozilla 루트) 먼저 — OS 는 최신인데 Python 번들만 낡은 PC 를 OS 묶음으로는 못 넘는다.
        candidates = [certifi_for(), *(path for path in bundles if os.path.exists(path))]
        bundle = next((path for path in candidates if path), None)
        if bundle is None:
            raise
    return opener(request, timeout=timeout, context=context_for(bundle))
