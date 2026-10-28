# 0024. `gh` 가 없으면 스킬을 git 으로 받는다 — 단 정식 태그만

- **언제**: 2026-09-24
- **정한 것**: 온보딩 5단계는 `gh` 가 설치·인증·조직 접근까지 되면 지금처럼 bootstrap
  ([[0018-install-through-bootstrap-not-a-clone]])을 쓴다. 하나라도 안 되면
  `git ls-remote` 로 **가장 높은 정식 태그**(`vX.Y.Z`)를 골라 그 태그만 `--depth 1` 로
  clone 하고, `VERSION` 이 태그와 같은지 본 뒤 소유자의 `install.sh`/`install.ps1` 을
  실행한다. 1단계에서 `gh`·`unzip` 은 FAIL 이 아니라 선택 도구다.

- **왜**: 동료 다수가 `gh` 설치·`gh auth login`·조직 SSO 승인에서 막혔다. 이 저장소는
  이미 `git clone` 으로 받았으니 **git 자격증명은 모두 갖고 있다.** 막히는 건 스킬을
  받는 통로 하나뿐이었다.

- **0018 과 어떻게 양립하나**: 0018 이 버린 것은 clone 자체가 아니라 **릴리스 안 된 `main`
  HEAD 를 검증 없이 까는 것**이었다. 이번 경로는 정식 태그에만 건다.
  `test_a_clone_is_always_pinned_to_a_release_tag` 가 모든 clone 줄에 `--depth 1 --branch`
  와 `release_tags.py` 를 요구한다 (기존 `git clone` 전면 금지 테스트를 대체).

- **확인한 사실** (2026-09-24, `v1.8.3`):
  - 소유자가 direct repo install 을 지원한다. `install.sh:517-540` "Version-stamp sync" 가
    `VERSION` 파일로 `CLIENT_VERSION`·`LOCAL_VERSION` 을 찍는다. `INSTALL.md:138` 이
    GitHub CLI 가 없는 환경의 경로를 안내한다.
  - 릴리스 ZIP 과 태그 소스는 **다르다** — ZIP 은 파일 22개에 버전이 찍혀 있고, 태그 소스는
    `CLIENT_VERSION="1.7.2"` 같은 옛 리터럴을 갖는다. 설치기가 설치 시점에 고쳐 쓰므로
    결과는 같다. 그래서 `VERSION` 이 태그와 다르면 설치기를 부르지 않는다.
  - 태그 체크아웃에서 `install.sh --status` 가 정상 동작했다.
  - `.sh`(macOS `/bin/bash` 3.2)·`.ps1`(pwsh) 양쪽에서 정상 · VERSION 불일치 · 없는 태그를
    가짜 설치기로 실행해 확인했다.

- **수용한 위험**:
  - **SHA256 대조가 없다.** 무결성은 TLS 위의 git 객체 해시에 기댄다. bootstrap 의 digest 도
    같은 GitHub 에서 같은 TLS 로 오므로 공격면이 크게 다르지 않다고 판단했다.
  - **가장 높은 태그 ≠ 정식 릴리스일 수 있다.** 소유자 `ADMIN.md:15` 는 "태그만 만들었다고
    설치 버전이 바뀌지 않는다" 고 적는다. 릴리스 발행 전 잠깐 태그만 있는 창이 있다.
    정식 버전을 알려주는 `/v1/version` API 는 주소가 설치 후 설정에서 나와서 첫 설치 때
    쓸 수 없고, 브로커 주소를 우리 저장소에 박는 건 [[0014-do-not-vendor-the-external-skill]]
    이 피한 결합이다. 태그 형식을 `vX.Y.Z` 로 엄격히 거르는 데서 멈춘다.

- **버린 선택지**:
  - **gh 를 자동 설치** — `brew`/`winget` 유무, 관리자 권한, 브라우저 인증이 또 걸린다.
    막히는 지점을 하나 옮길 뿐이다.
  - **GitHub REST API 를 curl 로** — 토큰이 필요하다. 토큰을 다루게 만드는 게 더 나쁘다.

- **근거**: `scripts/onboarding.sh` `choose_skill_source`·`install_skill_from_tag`,
  `scripts/onboarding.ps1` `Select-SkillSource`·`Install-SkillFromTag`,
  `scripts/release_tags.py`, `scripts/test_release_tags.py`
