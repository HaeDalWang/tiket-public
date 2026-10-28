# 가명과 `.private/` 의존을 걷어낸다

- 시작: 2026-10-06 · 결정: 유지보수자 — "이제 그 둘(Q7·가명)을 처리한다"
- 배경: 0002 가 티켓에서, 0026 이 팀 키에서 가명(`CUST-NNN`·`ACCOUNT-NNN`·`CONTACT-NNN`)을 버렸다. 계약서·잠금·push 차단·프로필에는 남아 있다.
  동료 PC 에는 `.private/` 가 없어 "`.private/customer-map.md` 로 대조하라" 는 규칙을 실행할 수 없다.

## 조사 (2026-10-06)

- 추적 파일 25개에 가명이나 `.private` 가 남아 있다(`development/`·평가 결과 제외). 많은 곳: 검사기와 그 테스트, `DISTRIBUTION.md`, `templates/customer-profile.md`.
- **유지보수자 PC 의 `.private/` 도 비어 있다**(폴더만 있다, 2026-10-02 09:37 수정). 대조표가 어디에도 없다 —
  공용 잠금표의 `CUST-002`/`ACCOUNT-003` 이 어느 계정인지 지금은 어떤 에이전트도 풀 수 없다. **잠금이 지금 아무 데서도 강제되지 않는다.**
- `customers/<실명>/` 은 gitignore 에도 pre-push 에도 안 걸렸다 — 둘 다 `customers/CUST-` 만 봤다.

## 단계

### 1. push 차단 셋 — 폴더 이름과 무관하게 (끝, 2026-10-06)

`.gitignore` `customers/*`(안내문 `_index.md` 만 예외), `.githooks/pre-push` 가 `customers/` 아래 전부를 막고 `_index.md` 만 통과,
검사기가 가명·실명 폴더 둘 다 무시되는지 본다. 테스트 먼저, 변이 둘(막는 줄 제거·예외 제거) 확인.

### 2. hard-lock — 잠긴 계정이 없다 (끝, 2026-10-06)

유지보수자: 잠금을 쓰는 사람이 없고, 유일한 잠금은 본인 것이었는데 대조표를 직접 지웠다. 걷어낸다.
공용 잠금표에서 가명 행을 지우고 "지금 잠긴 계정 없음" 을 적었다. 장치(호출 전에 이 파일을 본다)는 그대로 둔다.
잠금 파일 자리·대조 스크립트는 만들지 않았다 — 잠글 계정이 생기면 그때 정한다. 후보는 `~/.config/msp/` (저장소 밖이라 워크트리에서도 보인다).

### 3. 에이전트가 읽는 글에서 가명을 뺀다 (끝, 2026-10-06)

`CLAUDE.md:14`(4,265/4,500자), `AGENTS.md`, Kiro steering, `agents/task-router.md`, `playbooks/reply-style.md`.
원칙: 커밋되는 파일에는 고객 이름·연락처·계정 ID·`corpId` 를 적지 않고 패턴만 쓴다. 실제 내용은 로컬 전용 `tickets/` 에 둔다.
실행기가 안 돌아 Kiro TUI 로 `EVAL-002` 를 전 3회·후 3회 돌렸다 — 전·후 모두 3/3 통과, 등급·정책 카드 같음
(`evals/results/2026-10-06-eval-002-tui-before-after.md`). `EVAL-006`·`007` 은 돌리지 않았다.

### 4. 사람용 문서 (끝, 2026-10-06) — 프로필 코드는 남긴다

`ONBOARDING.md`·`TECHNICAL.md`·`DISTRIBUTION.md` 의 가명 설명을 고쳤다.
**남긴 것**: 검사기의 `customers/CUST-NNN/profile.md` 검사, `report_usage.collect_customers`, `templates/customer-profile.md`.
프로필은 폐기가 아니라 일시 중단이다(0031) — ITSM 고객 특이사항이 정해질 때 같이 걷어내거나 되살린다. 지표 페이로드의 `customers` 키는 사이트가 읽는다.
`policy/pending-review.md`·`POLICY-SEC-001` 의 가명 문구는 유지보수자 검토가 끝난 뒤.

## 상태

- 2026-10-06: 조사, 1~4단계 끝. 남은 것은 `policy/` 두 곳(유지보수자 검토 뒤)과 프로필 코드(고객 특이사항과 같이).
