# 0043. 인증서 폴백이 OS 묶음보다 certifi 를 먼저 시도한다

- **언제**: 2026-10-23
- **정한 것** (유지보수자 — "이런 경우 너의 추천은" → certifi 폴백은 넣고, 온보딩 강제 설치는 안 한다):
  - `https_fetch.urlopen` 의 인증서 폴백 사다리를 **certifi(최신 Mozilla 루트) → OS 묶음** 순으로 넓힌다.
    certifi 를 OS 묶음보다 **앞에** 둔다.
  - certifi 가 없으면 그 칸을 건너뛰고 기존대로 OS 묶음만 시도한다 — 없다고 더 나빠지지 않는다.
  - `report_usage.py --diagnose` 의 `ca file` 줄에 `certifi 있음/없음` 을 찍는다.
  - **온보딩에 `pip install certifi` 를 넣지 않는다.** 터진 PC 에서만 `--diagnose` 한 줄로 가린다.
- **왜**: 0039 의 OS-묶음 폴백은 "Python 에 인증서가 아예 없는" 한 엔지니어의 codex 건(2026-10-07)은 막았지만,
  다른 엔지니어의 Kiro TUI 건(2026-10-23)은 못 막았다. OS 는 최신인데 **Python 이 들고 있는 번들만 낡아서** —
  OS `cert.pem` 을 넘겨도 못 넘고, `pip install certifi` 로만 넘었다. 유지보수자가 그 PC 옆에서 수동으로
  certifi 를 깔아 처음으로 한 건이 들어왔다(사이트 "사용한 날" 10-23 첫 점). certifi 가 실제로 고쳤으니
  폴백 사다리에 박으면 다음 사람은 자동으로 넘는다.
- **왜 certifi 를 OS 묶음보다 앞에**: 이 실패 모드(OS 최신·Python 번들 구식)는 OS 묶음으로는 못 넘는다.
  OS 묶음을 먼저 시도하면 이 PC 들은 그 칸에서 또 걸려 certifi 까지 못 간다.
- **왜 온보딩 강제 설치는 안 하나**: 모수가 작다(겪은 2명 중 certifi 로 갈린 1명). 온보딩에 설치 단계를
  넣으면 실패할 자리(프록시·pip 권한·오프라인)가 늘고, 0039 가 경계한 "환경을 건드리는 쪽" 으로 번진다.
  `requests`·`boto3` 류가 certifi 를 끌고 와 대개 이미 깔려 있다 — 폴백만으로 대부분 잡힌다.
- **뒤집지 않는 것**: 검증은 여전히 끄지 않는다. 묶음만 바꾼다(0039 와 같다).
- **모르는 것 · 한계**:
  - 그 PC 의 `OPENSSL_VERSION` 을 못 받았다. `pip install certifi` 만으로 고쳐진 것으로 보아
    **낡은 루트 번들** 문제로 추정하나, **낡은 OpenSSL 라이브러리 자체**(TLS 1.3 미지원·cipher 거부)
    문제였을 가능성은 못 배제했다. 후자면 certifi 로도 안 넘는다 — 그때는 "Python 재설치" 안내로 가야 한다.
  - 다음에 또 터지면 `--diagnose` 의 `certifi` 칸이 가린다: certifi 가 **있는데도** 실패 → OpenSSL
    라이브러리 문제. certifi 가 **없어서** 실패 → 그 PC 만 `pip install certifi`.
- **근거**: `scripts/https_fetch.py`(`certifi_bundle`·`urlopen`), `scripts/test_https_fetch.py`,
  `scripts/report_usage.py`(`diagnose`)
