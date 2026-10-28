# 0025. 워크스페이스는 정식 태그로 스스로 올라간다 — 안전할 때만

- **언제**: 2026-09-24
- **정한 것**:
  - 정식 버전은 `vX.Y.Z` annotated 태그다. 유지보수자가 `scripts/release.py` 로 찍는다 —
    `main`·깨끗한 트리·`origin/main` 과 같은 HEAD·검증과 전체 테스트 통과가 조건이다.
    push 는 사람이 한다.
  - `check-freshness` 는 세션 시작 훅에서 하루 1회 태그를 받아, 더 높은 태그가 있으면
    **`main` 에 있고, 고친 추적 파일이 없고, fast-forward 가 가능할 때만**
    `git merge --ff-only <tag>` 로 올린다. 올렸으면 버전·릴리스 노트·되돌리기 명령을 출력하고,
    진입 규칙(`CLAUDE.md` 등)이 바뀌었으면 다시 읽으라고 알린다.
  - 하나라도 안 맞으면 **올리지 않고** 이유와 명령을 알린다. 스탬프를 찍지 않아 올라갈 때까지 알린다.
  - `fetch-ticket` 은 세션 도중에 돌므로 `--notify-only` 로 부른다. 알림은 stderr 로 보낸다.
  - 태그 없는 `main` 은 릴리스가 아니다. 따라가지 않는다.

- **왜 이 논의가 나왔나**: [[0016-freshness-check-notifies-instead-of-pulling]] 의 알림
  ("공용 규칙이 N커밋 갱신됐다 — git pull")을 동료들이 매번 귀찮아했고, "괜찮으니 자동으로
  해달라"는 요청이 모였다.

- **0016 의 반대 이유를 하나씩 어떻게 풀었나**:
  | 0016 이 든 이유 | 이번 답 |
  |---|---|
  | 세션 도중 에이전트 계약이 바뀐다 | 세션 **시작** 훅에서만 올린다. 세션 도중(`fetch-ticket`)은 알리기만 한다. 시작 전에 이미 읽힌 `CLAUDE.md` 가 바뀌면 그렇다고 알린다 |
  | 작업 트리가 더러우면 실패하거나 머지 커밋을 만든다 | 고친 추적 파일·로컬 커밋·다른 브랜치면 **손대지 않는다.** fast-forward 만 한다 — 머지 커밋은 생기지 않는다 |
  | fetch 한 줄 알림이면 유도 효과는 같다 | 실제로는 같지 않았다. 사람들이 안 쳤다 |

  그리고 0016 에 없던 것 하나: **알리던 대상이 `main` 커밋 수였다.** 유지보수자의 작업 중인
  커밋까지 "갱신"으로 셌다. 이제는 유지보수자가 릴리스로 찍은 것만 받는다.
  `DISTRIBUTION.md` 가 이미 "공지되지 않은 `main` 상태를 자동 적용하지 않는다" 고 적고 있었고,
  이번 설계는 그 원칙 그대로다.

- **태그 형식**: `DISTRIBUTION.md` 의 `alpha-YYYYMMDD.N` 을 `vX.Y.Z` 로 바꿨다. 외부 스킬과
  같은 형식이라 `release_tags.py` 하나로 둘 다 다룬다 ([[0024-skill-install-falls-back-to-a-release-tag-over-git]]).
  Alpha 동안은 `v0.x.y` 로 간다.

- **확인한 사실** (2026-09-24): `scripts/test_check_freshness.py` 가 임시 유지보수자 작업본 →
  bare 공용 저장소 → 동료 clone 을 만들고 13개 시나리오를 `.sh`(bash)·`.ps1`(pwsh) 양쪽에서
  실제로 돌린다. 올라감 · 진입 규칙 변경 알림 · gitignore 파일은 막지 않음 · 최신이면 조용 ·
  태그 없는 main 무시 · 고친 파일 보존 · 로컬 커밋 보존 · 다른 브랜치 · notify-only ·
  막힌 알림이 스로틀에 소모되지 않음 · 최신이면 스로틀 · origin 교정.
  변이 3개(notify-only 무시, 고친 파일 검사 제거, origin/main 비교 제거)를 테스트가 잡았다.

- **같이 고친 버그**: `fetch-ticket.ps1` 이 `check-freshness.ps1` 출력을 `*> $null` 로
  버려서 Windows 에서는 2층 알림이 **한 번도 보이지 않았다.** `fetch-ticket.sh` 는 알림을
  stdout 에 섞어서 `--json` 출력을 깨뜨릴 수 있었다. 둘 다 stderr 로 보낸다.

- **수용한 위험**:
  - 태그 하나가 곧바로 전원 배포다. `release.py` 의 검사가 유일한 관문이다.
  - 되돌리기는 각자 `git reset --keep <이전>` 이다. 하지만 다음 세션에 다시 올라간다 —
    잘못 낸 버전은 **더 높은 버전으로 고쳐 내는 것**이 유일하게 모두에게 닿는 복구다.
  - Kiro 의 `command` 훅이 stdout 을 보여주는지는 여전히 문서로 확인되지 않았다.
    업데이트는 되지만 알림을 못 볼 수 있다.
  - 끄는 스위치는 만들지 않았다. 고친 파일이 있으면 어차피 안 올라가고, 요청이 오면 그때 둔다.

- **버린 선택지**:
  - **`git pull` 자동 실행** — 태그 없는 `main` 을 끌어오고, 갈라지면 머지 커밋을 만든다.
  - **갈라진 워크스페이스는 자동 merge** — 충돌이 나면 세션 시작에서 사람이 풀어야 한다.
    알리고 멈추는 게 낫다.
  - **`fetch-ticket` 에서도 올리기** — 세션 도중 계약 변경이다. 0016 의 첫째 이유가 그대로 산다.

- **근거**: `scripts/check-freshness.sh`·`.ps1`, `scripts/release.py`, `scripts/release_tags.py`,
  `scripts/test_check_freshness.py`, `scripts/test_release.py`
