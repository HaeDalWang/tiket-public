# playbooks/ — 산출물을 만드는 동안 참조하는 것

`policy/` 가 **무엇이 허용되나**라면 여기는 **무엇을 만들고, 무엇을 통과해야 하고,
무엇에 걸려 넘어지나**다 — 마지막 것(판례)만은 여기가 아니라 최상위 `pitfalls/` 에 있다.

"절차"라는 한 단어로는 안 묶인다. 성격이 다른 3종이 있고, **각각 행동이 다르다.** 판례까지 합쳐 4역할로 읽는다.

## 4역할

| 역할 | 묻는 것 | 파일 | 언제 로드 |
|---|---|---|---|
| **규격** | 무엇을 만드나 | `ticket-outputs.md` | 티켓마다 항상 |
| **규칙** | 어떻게 쓰나 | `reply-templates.md` | 산출물이 회신일 때 |
| **게이트** | 못 넘으면 멈추나 | `evidence-verification.md` · `infra-change-process.md` | 티어·위험도별 |
| **판례** | 여기서 한 번 당했나 | `../pitfalls/` (최상위) | 주제가 걸릴 때 |

티켓 밖의 것이 하나 있다 — `weekly-diary.md` 는 일기(주간회고) 초안을 쓰는 법이고, 고객 건이 아니다.

로드 시점을 정하는 것은 `agents/task-router.md` 다. 이 표는 그 동작을 설명한 것이지
별도의 규칙이 아니다.

### 규격 — 하나뿐이고 항상 읽는다

`ticket-outputs.md` 는 산출물 3종(작업 지시서 / 조사 결과+답변 / 답변+출처)의 형식이다.
**티켓마다 가장 먼저 읽는다.** 티켓 유형이 아니라 산출물이 절차를 바꾸기 때문이다 —
근거는 `development/decisions/0008-three-outputs-not-six-types.md`.

채점표는 `evals/rubrics/` 에 있다. 여기 지시문 한 문장은 거기 채점 문항 하나와 짝이다.

### 규칙 — 산출물이 회신일 때만

고객에게 나가는 글의 형태를 정한다.

모양과 내용 규칙은 `reply-templates.md`(팀 답변 템플릿 00~11)가 정한다.
2026-10-21 유지보수자 스타일(`reply-style.md`)을 지우고 팀 템플릿으로 바꿨다 — `development/decisions/0041`.
그 파일에 있던 근거 규칙은 `evidence-verification.md` 4번에, 내용 원칙은 `reply-templates.md` 에 남았다.

### 게이트 — 규칙과 다르다

규칙은 "이렇게 써라"이고 게이트는 **"못 넘으면 진행하지 마라"**다. 파일이 스스로
그렇게 부른다 — `evidence-verification.md` 의 제목이 `Evidence and Reply Quality Gate`,
`infra-change-process.md` 에는 `## Hard stops` 가 있다.

`evidence-verification.md` 는 `answer-quality-gate` capability 의 **이식 가능한 구현체**다
(`agents/capability-catalog.md`). Claude Code 는 `/maintainer-skills:seonbi` 스킬로 같은
capability 를 채우고, Hermes·Codex·Kiro 는 이 파일을 직접 적용한다.

### 판례 — 절차가 아니라 지식이라 밖에 있다

`pitfalls/` 는 **케이스가 아니라 일반화된 패턴**만 담는다. 규격·규칙·게이트는 이 워크스페이스
설계자가 정하지만, 판례는 현장에서 넘어진 사건을 검증해서 확정한다. **확정하는 사람이 달라서
폴더도 다르다** (`development/decisions/0026-ticket-lessons-flow-to-a-candidate-table.md`).

함정 카드는 **그 자체로 증거가 아니다.** 재검증을 요구하는 라우팅 경고다.

## 새 파일이 생기면 어디 속하나

```
무엇을 만드는지 정한다       → 규격
고객에게 나가는 글의 형태다   → 규칙
못 넘으면 멈춰야 한다        → 게이트
이미 한 번 당한 것이다       → 판례 (`pitfalls/`)
```

**앞의 셋 중 어디에도 안 들어가면 `playbooks/` 가 아니다.**

| 이런 것 | 여기로 |
|---|---|
| 회사 규정·약관 | `policy/` |
| 한 번 당한 것 | `pitfalls/` |
| 빈 양식 | `templates/` |
| 호스트별 능력 매핑 | `agents/` |
| 왜 이렇게 정했는지 | `development/decisions/` |
| 채점 문항 | `evals/rubrics/` |
