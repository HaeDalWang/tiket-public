# 0015. 온보딩이 외부 스킬을 직접 받아 설치한다 — 벤더링은 다시 검토하고 다시 버렸다

- **언제**: 2026-09-08
- **정한 것**: [[0014-do-not-vendor-the-external-skill]] 의 "벤더링하지 않는다"는 **유지**한다.
  다만 온보딩 5단계를 **안내에서 실행으로** 바꾼다. 대화형 실행일 때 소스 저장소가 없으면
  동의를 받고 `git clone` 하고, 이어서 `install.sh` / `install.ps1` 을 실행한다.
  `--check`(`-Check`)와 비대화형 실행은 종전대로 안내만 한다.

- **왜 이 논의가 다시 나왔나**: "스킬을 프레임워크에 미리 빌트인하면 온보딩이 편해진다"는
  제안이 다시 올라왔다. 근거는 두 가지였다 — (1) 저장소를 스킬과 같은 org 에 private 으로
  옮길 예정이라 보안 우려가 줄어든다, (2) 스킬이 자체 버전 업그레이드를 갖고 있어서
  드리프트가 문제되지 않는다.

- **확인한 사실** (2026-09-08, 원본 `~/opensource/support-skills` 대조):
  - **(2)는 맞다.** `skills/aws-customer-account-ops/get-sts-token.sh:453-468` 이 로그인
    호출마다 `try_self_update` 를 실행하고, `min_supported` 미달이면 강제 업데이트가
    실패할 때 실행을 차단한다. 갱신 소스는 GitHub 이 아니라 Slack 토큰 → `/version` →
    presigned URL 이다(`self-update.sh:279,467`). 저장소 접근 없이 갱신된다.
  - **그러나 그 자가갱신은 저장소 사본에 닿지 않는다.** `self-update.sh:135-150` 의 대상은
    `$HOME` 기반 9개 경로 하드코딩이고 경로 override 환경변수가 없다.
  - **자가갱신은 부트스트랩되지 않는다.** `self-update.sh:20` 이 `API_URL` 을
    `~/.config/msp/credential-broker.conf` 에서 읽는데, 그 파일은 `install.sh:531-585`
    만 만든다. 즉 **스킬 폴더만 넣으면 아무것도 동작하지 않는다.**
  - 스킬 본체에 **12자리 계정번호 9개**와 **고객사명**이 들어 있다
    (`get_account_info.sh:13` 의 하드코딩 `LAMBDA_ARN`, `examples/`, `reference/`).
    값은 여기 옮겨 적지 않는다.
  - 실측: 스킬을 `skills/` 에 복사하고 검증기를 돌리면
    `validate_workspace.py` 가 7개 파일을 `12-digit account-like value` 로 잡아 FAIL,
    `test_onboarding_parity.py::test_neither_vendors_the_external_skill` 도 FAIL.

- **결정을 뒤집은 사실**: 0014 는 "병목은 배포가 아니라 저장소 접근 권한"이라고 봤다.
  **그 병목이 사라졌다** — 스킬 담당자가 `support-skills` 에 MSP 팀 전체를 초대했다.
  clone 이 더 이상 사람을 기다리지 않으므로, 온보딩이 그냥 받아서 설치하면 된다.

- **벤더링을 다시 버린 이유**:
  - **효과가 없다** — 스킬 폴더만으로는 `credential-broker.conf` 도 `csg-login` 마커도
    안 생긴다. 엔지니어는 여전히 `install.sh` 를 돌려야 한다. 편의성 이득이 0이다.
  - **비식별 계약 위반** — 계정번호와 고객사명이 저장소로 들어온다. `CLAUDE.md` 는
    `ACCOUNT-NNN` 가명만 허용한다. **org 를 private 으로 옮겨도 이건 안 풀린다.**
    저장소 공개 범위의 문제가 아니라 이 저장소 자신의 계약이라서다.
  - 전체(`install.sh` 포함) 벤더링이면 동작은 하지만, `EXTERNAL_ID` 와 Payer 계정 ARN 이
    배포본에 실린다. private org 로 완화될 뿐 없어지지 않는다.

- **자동 clone 이 벤더링보다 나은 점**: 벤더링이 못 하는 것까지 한다 —
  `credential-broker.conf` 생성, `csg-login` 마커 설정, 에이전트별 사본 배치.
  "온보딩 후 바로 사용가능"이 오히려 여기서 완성된다.

- **남는 위험**: clone 이 실패하면(권한 회수, 네트워크) 5단계가 FAIL 로 끝난다.
  이때는 스킬 담당자에게 접근 확인을 안내한다. 자동 설치는 `~/.aws/config` 와
  `~/.config/msp/` 를 바꾸므로 **실행 전 동의를 받는다.**

- **고정 방법**: `test_onboarding_parity.py::test_neither_vendors_the_external_skill` 를
  그대로 둔다. `skills/` 가 저장소에 생기면 여전히 실패한다.
