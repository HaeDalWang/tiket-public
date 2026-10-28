# 0018. 설치를 bootstrap 으로 바꾼다 — clone 은 미릴리스 코드를 검증 없이 깔고 있었다

- **언제**: 2026-09-18
- **정한 것**: [[0015-onboarding-installs-the-external-skill]] 의 **자동 clone 을 폐기**한다.
  온보딩 5단계는 `gh api` 로 `bootstrap.sh`/`bootstrap.ps1` 을 받아 실행한다.
  "온보딩이 설치까지 한다"는 유지된다 — 수단만 바뀐다.

- **왜 이 논의가 나왔나**: 스킬 소유자가 `INSTALL.md` 와 `bootstrap.sh`/`bootstrap.ps1` 을
  새로 냈다. 설치를 이 프레임워크 안으로 통폐합해서, 엔지니어가 저쪽 저장소를 몰라도
  되게 하자는 요청이 있었다.

- **확인한 사실** (2026-09-18, `origin/main` 대조):
  - `INSTALL.md` 가 **"ZIP을 직접 내려받거나 저장소를 복제할 필요가 없습니다"** 라고 못박는다.
  - `bootstrap.sh` 는 81줄이고, `gh api .../releases/latest` 로 **정식 릴리스**를 고른 뒤
    **SHA256 을 대조**하고(불일치면 설치기를 아예 실행하지 않는다) 압축을 풀어 설치한다.
  - `bootstrap.sh:22-23` 이 `gh` 와 `unzip` 을 요구한다. 우리 1단계는 `git python3 curl jq`
    만 검사하고 있었다.
  - `bootstrap.sh:32-39` 가 **macOS Bash 3.2 에서 실행되면서 Bash 4+ 를 스스로 찾는다.**
  - 원격 `VERSION` 은 1.8.3, 이 워크스페이스 설치본은 1.8.1.

- **0015 를 뒤집은 이유**: 우리 자동 clone 은 `main` **HEAD** 를 설치했다. 릴리스가 아니라
  개발 중인 코드이고, 무결성 검증도 없었다. bootstrap 은 태그된 릴리스에 SHA256 대조를
  건다. **공급망 관점에서 우리 쪽이 더 나빴다.** 0015 를 쓸 때 이 구분을 하지 않았다.

- **같이 철회한 것**: `agents/install-verification.md` 는 macOS `/bin/bash` 3.2 를
  "외부 스킬의 이식성 한계이니 소유자에게 수정을 요청하라"고 적어두었다. **upstream 에서
  고쳐졌으므로 철회한다.** 다만 런타임에 에이전트 프로세스의 `PATH` 가 3.2 를 고르면
  여전히 실행이 안 되므로, 그 구분은 남긴다 — 설치의 문제가 아니라 실행 환경의 문제다.

- **새 전제조건**: `gh` 설치 + 인증 + **example-org 조직 SSO 승인**. 로그인만으로는 부족하다.
  bootstrap 이 릴리스를 받는 통로라 여기서 막히면 5단계가 통째로 실패한다. 그래서
  4단계와 5단계 사이에 `gh auth status` 와 `gh repo view` 검사를 넣었다. 조회만 한다.

- **`--check` 에서 bootstrap 을 부르지 않는 이유**: `INSTALL.md` 에 따르면 `--status` 조차
  릴리스를 내려받는다. 우리 `--check` 계약은 "아무것도 바꾸지 않고 입력도 받지 않는다"이다.
  다운로드는 그 계약의 경계에 있으므로, `--check` 에서는 전제조건만 보고 명령을 안내한다.

- **엔지니어에게 끝까지 남는 것 3개** (자동화할 수 없다):
  - `gh auth login` — 브라우저 인증
  - BILLING API Key 입력 — 설치 메뉴에서 직접. 채팅이나 인자로 받지 않는다
  - Slack 로그인 — 브라우저

- **고정 방법**: `test_onboarding_parity.py` 에
  `test_both_install_through_bootstrap_not_a_clone`(양쪽에 bootstrap 이 있고 `git clone` 이
  없을 것)과 `test_both_check_github_cli_access`(양쪽에 gh 인증·접근 검사가 있을 것)를 넣었다.

- **아직 안 한 것**: 실제 미설치 환경에서 bootstrap 이 끝까지 도는 것은 확인하지 못했다.
  이 머신에는 이미 설치돼 있어 5단계가 설치 분기를 타지 않는다. 1.8.1 → 1.8.3 갱신 여부도
  확인하지 않았다.

- **2026-09-24 보완**: [[0024-skill-install-falls-back-to-a-release-tag-over-git]] — gh 가
  없으면 git 으로 받는다. 이 문서가 막은 것은 clone 자체가 아니라 main HEAD 를 까는
  것이었으므로, 정식 태그에만 거는 clone 은 허용한다.
