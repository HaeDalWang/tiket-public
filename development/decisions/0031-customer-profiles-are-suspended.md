# 0031. `customers/` 는 일시 중단한다 — 고객 특이사항은 훑을 수 없는 곳에만 둔다

- **언제**: 2026-10-02
- **정한 것**:
  - `customers/` 를 이 워크플로에서 쓰지 않는다. 프로필을 읽으라는 지시문을 걷어냈고(`CLAUDE.md`, `agents/task-router.md`,
    `playbooks/evidence-verification.md`, `playbooks/infra-change-process.md`, `policy/_routing.md`, `templates/ticket-intake.md`),
    `customers/_index.md` 는 중단 안내만 남긴다. `task-router.md` 가 "읽지도 만들지도 않는다" 를 한 줄로 말한다.
  - 고객 특이사항을 다시 여는 조건: **고객 키로 물으면 그 고객 것만 돌아오고, 훑어볼 수는 없는 저장소.**
    방향은 ITSM 의 고객 계정에 붙이는 것이다(유지보수자). 우리가 고칠 수 없는 시스템이므로 요구사항을 정리해 개발자에게 넘긴다.
  - 그동안 고객마다 다른 사정은 티켓 기록에 적는다. 접근 금지 계정은 `agents/customer-access-locks.md` 그대로다.
  - 실제 고객 특이사항은 저장소 안에 두지 않는다 — `.private/` 도 안 된다.
- **왜**: 특이사항을 어디에 모을지 정하기 전에 쓰이는지부터 평가했다(`EVAL-006`·`EVAL-007`, Kiro CLI V3, 각 2회).
  결과는 `evals/results/2026-10-02-eval-006-007.md`.
  - 읽기는 된다. 이름으로 된 폴더를 힌트 없이 찾아 읽었고, 접근 제약과 `[추측]` 등급을 기록까지 옮겼다(006 1회차, 007 2회차).
  - **그런데 옆의 다른 고객 파일도 읽는다.** 1회차는 다른 고객 담당자의 이름을 이 고객 기록에 옮겨 적었다. 2회차는
    합성고객을 실제 고객으로 단정하고 브로커에 로그인해 빌링 플랫폼에서 그 고객의 `corpId` 와 계정 목록을 조회했다.
    유지보수자가 끊어서 고객 AWS 계정 호출 전에 멈췄다. 아무도 `.private/` 를 열라고 하지 않았다.
  - 가명 잠금표(`CUST-NNN`·`ACCOUNT-NNN`)는 대조표가 없으면 판단이 갈린다 — 세 회차가 "호출 금지", "대상 아님", 판별 없이 진행으로 달랐다.
  - 기존 프로필도 쓰이지 않았다: 유지보수자 PC 에서 티켓 18건에 프로필 2개, 2026-09-15 이후 수정 없음.
- **버린 선택지**:
  - 로컬 폴더에 실명으로 쌓는다 — 위 사고가 그대로 난다
  - 고객 특이사항 전용 git 저장소(`example-org` 조직, 비공개) — 인증·이력·검색이 공짜지만 받아 오면 전 고객 파일이 디스크에 놓인다. 같은 문제다
  - "다른 고객 파일은 읽지 마라" 문구 — 두 회차 모두 시키지 않은 폴더를 열었다. 문구로 막을 일이 아니다
  - 수집기(`tiket_candidates`)에 읽기 창구를 연다 — 인증 없는 POST 전용이라 인증부터 새로 만들어야 한다. 보류
  - 프로필 양식과 검사기 코드까지 지운다 — "일시" 중단이다. `templates/customer-profile.md`, 검사기의 프로필 검사,
    `.gitignore`·pre-push 의 `customers/CUST-*` 차단은 남긴다. 차단은 빼면 안 되는 보호 장치다
- **남는 한계**:
  - 평가는 각 2회, Kiro CLI 하나다. "찾아 읽는다" 는 방향일 뿐이다. 사고 쪽은 1회로도 충분한 근거다.
  - 2회차 사고는 평가 환경이 키웠다 — 합성 자료를 실제 고객 파일에서 떠 왔고 원본이 저장소 안에 있었다.
    그래도 "모아 두면 섞인다" 는 결론은 같다. 실제 운영에서는 옆 파일이 전부 진짜 고객이다.
  - 프로필을 전제로 한 문장이 남아 있다(`capability-catalog.md`, `reply-style.md`, `reply-writing-rules.md` 의 "customer profile" 우선순위).
    프로필이 없으면 작동하지 않는 조건문이라 두었다.
  - 변경 작업 쓰기 권한(0022)을 적어 둘 자리가 없어졌다 — 엔지니어가 매번 판단한다.
  - `EVAL-006`·`EVAL-007` 은 프로필을 놓고 돌리는 케이스라 지금은 돌리지 않는다. 다시 열 때 기준선으로 쓴다.
    `EVAL-006` 은 알릴 사람과 요청자가 같아 모호하다 — 그때 요청자를 바꾼다.
  - 사용 지표의 `customers.count` 는 0 으로 남는다. `corp_id`·`repeat`·`customer_lessons` 는 티켓 기록에서 세므로 계속 온다.
- **근거**: `evals/results/2026-10-02-eval-006-007.md`, `evals/cases/EVAL-006-customer-notes-access.md`,
  `evals/cases/EVAL-007-customer-notes-grade.md`, `evals/fixtures/customer-notes-synthetic.md`
