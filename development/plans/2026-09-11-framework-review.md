# 프레임워크 검토 — 외부 사례 대조 + 파일 전수 점검

- 작성: 2026-09-11
- 물음 둘: ① 이런 프로젝트의 선행 사례·모범 사례가 밖에 있는가 ② 에이전트가 읽는 파일들이 지금 상태로 괜찮은가

---

## 요약 — 먼저 결론

**① 있습니다. 그것도 아주 가까운 것이.** 감으로만 만든 게 아니라는 증거도, 놓치고 있는 것도 둘 다 나왔습니다.

**② 구조는 외부 모범 사례와 대체로 일치합니다. 빠진 것은 하나이고, 그게 정확히 "입증이 안 된다"는 고민의 답입니다 — 행동 평가(eval)가 없습니다.**

지금 저장소에 있는 검증은 전부 **정적 검사**입니다. 파일에 그 문장이 있는지, 경로가 맞는지,
비식별이 됐는지. **에이전트가 실제로 그렇게 행동하는지를 보는 것은 하나도 없습니다.**
오늘 두 결함(절차 건너뜀·산출물 없이 멈춤)을 사람이 트랜스크립트를 읽어서 발견한 게 그 증거입니다.

---

## 1. 밖에 무엇이 있는가

### 1-1. 표준은 실재한다 — 그리고 우리는 이미 그 위에 있다

**`AGENTS.md` 는 정식 표준입니다.** OpenAI가 2025년 8월에 내놓았고, 2025년 12월 9일부터
**Linux Foundation 산하 Agentic AI Foundation(AAIF)** 이 MCP·goose와 함께 관리합니다.
6만 개 이상의 오픈소스 저장소가 쓰고, 30개 이상의 에이전트가 읽습니다 — Codex, Claude Code,
Copilot, Cursor, Gemini CLI, Jules, Aider, Zed, Windsurf, Devin 등.

우리는 `AGENTS.md` 와 `llms.txt` 를 **둘 다** 갖고 있습니다. 표준을 모르고 만들었지만
결과적으로 맞게 갔습니다. 하나 놓친 것: **표준은 하위 디렉터리의 중첩 `AGENTS.md` 를 지원하고,
에이전트는 트리에서 가장 가까운 파일을 읽습니다.** OpenAI 저장소는 88개를 씁니다.
우리는 루트 1개만 씁니다 — `policy/`, `playbooks/` 처럼 규칙이 다른 구역에 쓸 수 있는 수단입니다.

### 1-2. 거의 같은 프로젝트가 둘 있다

| 프로젝트 | 우리와 겹치는 것 | 다른 것 |
|---|---|---|
| **AgentCrew** (MIT) | 마크다운 우선, `roles / playbooks / skills / templates / policies / gates` 구조, 사람 승인이 최종, Codex·Claude Code·Cursor·Hermes 공통 | 도메인이 코딩. 저장소 밖에 설치(우리는 저장소 안) |
| **kontourai/flow-agents** (Apache-2.0) | **Claude Code·Codex·Kiro·opencode에 같은 워크플로 설치**, 증거 게이트, 단계별 상태 sidecar, "증거가 뒷받침할 때까지 완료로 치지 않음" | 훅으로 강제. **평가 스위트 보유** |

`flow-agents` 의 문제 정의가 우리가 오늘 겪은 것과 **글자 그대로 같습니다**:

> 에이전트는 강력하지만 잘 잊는다. 계획은 잘 세우고 나서 표류한다. 컨텍스트가 붐비면
> 검증을 건너뛴다. **부분적으로 한 일을 다 했다고 말한다.**

그리고 그쪽이 쓰는 해법이 제가 지난 턴에 제안한 것과 같습니다 — **훅 4종**:

| 정책 | 하는 일 | 훅 |
|---|---|---|
| Workflow steering | 단계 전환 알림 주입 | `userPromptSubmit` |
| Quality gate | 편집 직후 검사 | `postToolUse` |
| **Stop-goal-fit** | **멈추려 할 때 증거가 없으면 경고·차단** | `stop` |
| Config protection | 설정 파일 쓰기 거부 | `preToolUse` |

**`Stop-goal-fit` 이 정확히 오늘의 결함 B("산출물 없이 멈춤")를 막는 장치입니다.** 우리만 겪는
문제가 아니고, 이미 알려진 해법이 있습니다.

### 1-3. 다른 범주도 있다 — 우리와 경쟁하지 않는다

`ForgeFlow`, `governai`, `Keviq Core`, `Portarium`, `EngineX` 는 전부 **런타임 컨트롤 플레인**입니다.
LangGraph/FastAPI/PostgreSQL 위에 정책·승인·감사·샌드박스를 코드로 강제합니다.

핵심 문장은 `governai` 에 있습니다.

> **제어 흐름은 프롬프트가 아니라 런타임이 결정한다.**

우리는 마크다운 방법론(범주 A)이지, 런타임(범주 B)이 아닙니다. **그런데 우리에게는 범주 B
요소가 하나 있습니다** — 고객 AWS read-only를 브로커가 서버에서 강제하는 것. 범주 A 프로젝트
대부분은 강제 수단이 아예 없고 산문뿐입니다. **이 혼합은 우리 쪽이 앞선 부분입니다.**

### 1-4. 우리 도메인은 비어 있다

어느 프로젝트도 **고객 지원 티켓 + 비식별 + 정책 카드 라우팅 + 근거 등급**을 하지 않습니다.
`ForgeFlow` 의 `support_ops` 는 "template scaffold"(미구현), `ailouros` 의 `support_triage` 는
12개 시나리오 중 하나입니다. **중복 투자가 아닙니다.**

---

## 2. 우리 구조를 외부 잣대로 재보면

### 2-1. 잘 가고 있는 것 (외부 권고와 일치)

**점진적 공개(progressive disclosure)를 이미 하고 있습니다.** Anthropic의 Claude 5 컨텍스트
엔지니어링 지침은 "CLAUDE.md를 모든 관행의 중앙 저장소로 만들려 하지 말고, 필요한 때 로드되는
파일 트리를 두라"고 합니다. 우리 구조가 그겁니다.

| 구분 | 크기 |
|---|---:|
| **상시 로드** (CLAUDE.md + AGENTS.md) | **5,028자** (~1,300 토큰) |
| 라우팅 후 조건부 로드 대상 전체 | 90,622자 |

**86,000자를 매번 읽는 게 아닙니다.** 티켓 하나에 실제로 들어가는 건 진입점 5천 자 +
라우터가 고른 모듈 몇 개입니다. 이건 걱정하실 부분이 아니라 **이미 맞게 한 부분**입니다.

**결정 기록 17개가 있습니다.** 이게 생각보다 큰 자산입니다 — 아래 2-2 참조.

### 2-2. 논문 한 편이 우리 상황과 정확히 겹칩니다

**"Why Does CLAUDE.md Keep Growing? Catastrophic Remembering in Agentic Coding"**
(1,867개 저장소, 247,694건의 지시문 생애 분석)

- 지시문은 생애 동안 **226% 증가**한다. 커밋당 평균 **+4.9개**.
- **삭제 확률은 지시문이 오래될수록 떨어진다.** 왜 넣었는지 모르니 못 지운다.
- 추가 비용은 O(1)인데 안전한 삭제 비용은 O(2^n) — **래칫 효과**로 무한 증가한다.
- 전면 재작성을 해도 **"증가가 즉시, 더 빠른 속도로 재개된다."**

**처방: 각 지시문에 원래의 실패와 가설을 기록하는 구조화된 주석을 붙일 것.**
결과 — 초과 지시문 **+211.3% → +1.4%** (99.3% 감소), 지시 준수 **+23.1%** 향상.

**우리는 이걸 우연히 이미 하고 있습니다.** `development/decisions/` 17개가 "왜 이 규칙이 있는지"의
보관소이고, 오늘 마커에 붙인 주석(`# 2026-09-11: 라우터가 ... 로만 줄여 담고 있었다`)이
바로 논문이 말하는 그 형태입니다. **의도적으로 규칙화할 가치가 있습니다.**

님이 글로벌 CLAUDE.md가 과했다고 하신 것도 이 논문의 현상 그대로입니다.

### 2-3. 경고 — 우리도 같은 함정에 있다

Anthropic이 자기 반성으로 적은 문장입니다.

> **우리는 Claude Code를 과도하게 제약하고 있었다** — 시스템 프롬프트에서도, CLAUDE.md와
> 스킬에서도. **불필요한 숙고를 강요하는 상충 지침을 찾아보라.**

그리고 방향 전환을 이렇게 요약합니다.

> **"규칙을 주기"에서 "Claude가 판단하게 하기"로. "전부 선행 적재"에서 "점진적 공개"로.**

**오늘 결함 A가 정확히 "상충 지침"이었습니다.** `first` 가 두 개였던 것. 이건 우리 저장소에
같은 종류가 더 있을 수 있다는 뜻입니다. 지금까지는 사람이 읽어야 찾았습니다.

---

## 3. 파일 25개 전수 판정

에이전트가 읽는 파일 전부입니다. 판정 기준: **상시/조건부 적정성 · 중복 · 근거(왜) 보유 ·
검증 가능한 완료 조건**.

### 진입점 (상시 로드)

| 파일 | 크기 | 판정 |
|---|---:|---|
| `CLAUDE.md` | 4,067자 | **적정.** 예산 4,500자 안. 오늘 전제 한 줄 추가로 4,067. 여유 433자뿐이라 다음 추가부터는 무언가를 빼야 함 |
| `AGENTS.md` | 961자 | **적정.** CLAUDE.md를 가리키는 얇은 진입점. 표준 형태에 부합 |
| `.kiro/steering/00-repository-rules.md` | 863자 | **적정.** 위와 동일 역할 |
| `llms.txt` | 4,330자 | **재검토.** 네 번째 진입점이다. 자동 로딩이 없는 에이전트용이라는 목적은 타당하나, 규칙이 또 한 곳에 요약돼 있다 — 결함 B와 같은 구조적 위험 |

### 라우팅·능력 (조건부)

| 파일 | 크기 | 판정 |
|---|---:|---|
| `agents/task-router.md` | 3,002자 | **핵심.** 참조 12회로 최다급. 오늘 두 문장 보강 |
| `agents/capability-catalog.md` | 4,575자 | **적정** |
| `agents/runtime-status.md` | 10,391자 | **비대.** `as_of` 로 신선도를 추적하는 유일한 축 중 하나라 가치가 크지만, 증거 출처 서술이 길다. 상태표와 증거 이력을 분리할 후보 |
| `agents/install-verification.md` | 9,635자 | **분류 재고.** 티켓 처리 시 로드될 일이 없다. 온보딩·점검용이다 |
| `agents/shared-agent-environment.md` | **11,793자** | **잘못된 위치.** 가장 큰 파일인데 **티켓 워크플로가 로드하지 않는다.** `DISTRIBUTION.md` 와 검증 스크립트만 참조하는 배포 평가 문서다. `agents/` 에 있어서 에이전트 표면이 실제보다 커 보인다. `development/` 이나 배포 문서 쪽이 맞다 |
| `agents/compatibility.md` | 1,966자 | **적정.** 참조 1회지만 다중 에이전트 인계용으로 역할이 분명 |

### 산출물·회신 (조건부)

| 파일 | 크기 | 판정 |
|---|---:|---|
| `playbooks/ticket-outputs.md` | 6,031자 | **핵심.** 참조 13회로 최다. 산출물 3종 정의 |
| `playbooks/evidence-verification.md` | 5,179자 | **핵심** |
| `playbooks/reply-writing-rules.md` | 4,001자 | **적정.** 우선순위 사다리가 여기 묻혀 있었다 — 오늘 README로 승격 |
| `playbooks/reply-style.md` | 6,398자 | **점검 필요.** Anthropic 경고("과도한 제약")가 가장 잘 들어맞을 후보. 문체 규칙은 판단에 맡길 여지가 큰 영역 |
| `playbooks/infra-change-process.md` | 2,320자 | **적정.** 오늘 결함 B의 정본이 여기였다 |
| `templates/ticket-intake.md` | 6,115자 | **핵심이자 최대 기회.** 아래 4-2 참조 |
| `templates/customer-profile.md` | 3,436자 | **적정** |
| `templates/customer-index.md` | 1,076자 | **적정.** 고아처럼 보이나 `export_framework_snapshot.py:140` 이 쓴다 |

### 정책·함정·인계 (조건부)

| 파일 | 크기 | 판정 |
|---|---:|---|
| `policy/_routing.md` | 4,789자 | **핵심.** 카드 15장의 라우팅 |
| `playbooks/pitfalls/*` (4건 + README) | 7,347자 | **적정.** 이름으로 참조되지 않지만 `task-router.md:32` 가 디렉터리 검색으로 지목한다 — 고아 아님 |
| `handoff/README.md` | 1,734자 | **적정** |

### 판정 요약

- **잘못된 위치 1건** — `shared-agent-environment.md`(11,793자)가 `agents/` 에 있다
- **분류 재고 1건** — `install-verification.md`(9,635자)는 런타임 컨텍스트가 아니다
- **진입점 4개** — 셋이면 충분한 자리에 `llms.txt` 가 넷째로 있다
- **고아 0건** — 검사해보니 전부 참조 경로가 있다
- **신선도 추적 2건뿐** — `as_of` 를 가진 건 `runtime-status.md` 와 `shared-agent-environment.md` 뿐이다

이 둘(20,000자, 전체의 23%)을 `agents/` 밖으로 옮기면 **에이전트 표면이 86k → 66k로 줄어듭니다.**
내용을 지우는 게 아니라 분류만 바로잡는 것이라 잃는 것이 없습니다.

---

## 4. 빠진 것 — 이게 "입증이 어렵다"의 답입니다

### 4-1. 우리에게 없는 것: 행동 평가

| 검증 종류 | 우리 | 외부 사례 |
|---|---|---|
| 정적 검사 (문구·경로·비식별) | `validate_workspace.py` ✅ | — |
| 스크립트 대칭 | `test_onboarding_parity.py` ✅ | — |
| 외부 스킬 적합성 | `test_aws_customer_skill.py` ✅ | — |
| **에이전트 행동 평가** | **없음** ❌ | `flow-agents`: `evals/run.sh` / `ForgeFlow`: CI 평가 회귀 게이트 + 기준선 JSON |

**밖에서 쓰는 방법은 단순합니다.**

1. **같은 과업을 지시문 있는 채/뺀 채로 각각 10회 이상 돌려 비교한다.** LLM은 비결정적이라
   1회 비교는 의미가 없다.
2. **섹션을 XML 태그로 감싸 A/B 한다.** 섹션을 빼고 돌려 차이를 본다.
   (300~500줄짜리 큰 스킬에서는 문구·형식 미세 변경의 효과가 거의 없다는 실측도 있다)
3. **가장 싼 확인**: *"에이전트에게 우리 빌드 명령을 설명해보라고 시킨다. 그대로 재현하지
   못하면 그 지시문은 읽히지 않았거나 너무 장황한 것이다."*

3번은 **오늘 당장 할 수 있습니다.** 새 세션에서 "이 저장소에서 티켓을 처리하는 순서를
1번부터 말해봐"를 시켜보면 됩니다. `task-router.md` 의 tier 3종과 산출물 3종을 못 말하면
읽히지 않은 것입니다.

### 4-2. 가장 값싼 시작점: 이미 있는 것을 쓰는 것

**`templates/ticket-intake.md` 가 이미 평가 하네스의 절반입니다.** 섹션이
`물어본 것 / 확인한 것 / 작업 지시 / 답변 초안 / 발송 전 점검 / 실제 발송` 로 나뉘어 있고,
`[확인]/[추측]/[모름]` 등급과 출처 규칙이 붙어 있습니다.

빠진 것은 **이게 채워졌는지 보는 검사기 하나**입니다. 그게 생기면:

- "산출물 없이 멈춤"이 **조용한 실패에서 검사 가능한 실패로** 바뀝니다
- 합성 티켓 몇 건을 고정 입력으로 두면 **그대로 회귀 평가 세트**가 됩니다
- Claude Code 전용 훅과 달리 **스크립트라서 4개 에이전트 전부에 걸립니다**

### 4-3. 1순위 제안

| 순위 | 할 일 | 왜 |
|---|---|---|
| 1 | `scripts/check_ticket_record.py` — 티켓 기록 완결성 검사 | 에이전트 무관. 기존 검증기 패턴의 확장. 평가 세트의 토대 |
| 2 | 합성 티켓 3~5건 고정 + 절차 준수 체크리스트 | 1번이 생기면 거의 공짜로 따라온다 |
| 3 | `agents/` 정리 — 배포·점검 문서를 밖으로 | 20,000자(23%) 감소. 내용 손실 없음 |
| 4 | `Stop` 훅 — 산출물 없이 종료 시 경고 | `flow-agents` 가 검증한 패턴. 단 Claude Code 전용 |
| 5 | 결정 기록 규칙화 — 규칙 추가 시 "어떤 실패 때문인지" 의무화 | 논문 처방. 초과 지시문 99.3% 감소 |

---

## 이 검토의 한계

- 외부 프로젝트는 **README 수준까지만** 봤습니다. 실제 코드·평가 품질은 확인하지 않았습니다.
  `flow-agents` 는 스타 0·이슈 358개, `AgentCrew` 는 스타 6으로 **둘 다 매우 초기**입니다.
  성숙한 선행 사례가 아니라 **동시대의 유사 시도**로 보는 것이 정확합니다.
- 논문은 alphaXiv 초록 기준이며 전문을 읽지 않았습니다.
- 파일 판정은 크기·참조 횟수·역할 기준의 구조 판정입니다. **각 파일 내용의 품질**
  (예: `reply-style.md` 가 실제로 과잉 제약인지)은 행동 평가 없이는 확정할 수 없습니다.
  그게 바로 4항의 요지입니다.

## 출처

- AGENTS.md 표준 — https://agents.md/
- Anthropic, Claude 5 컨텍스트 엔지니어링 — https://claude.com/blog/the-new-rules-of-context-engineering-for-claude-5-generation-models
- Anthropic, 에이전트 평가 — https://www.anthropic.com/engineering/demystifying-evals-for-ai-agents
- Anthropic, 스킬 작성 모범 사례 — https://platform.claude.com/docs/en/agents-and-tools/agent-skills/best-practices
- Catastrophic Remembering 논문 — https://www.alphaxiv.org/abs/2608.11095
- LangChain, 스킬 평가 — https://blog.langchain.com/evaluating-skills/
- kontourai/flow-agents — https://github.com/kontourai/flow-agents
- mlguyYT/AgentCrew — https://github.com/mlguyYT/AgentCrew
- rrrozhd/governai — https://github.com/rrrozhd/governai
- 45ck/Portarium — https://github.com/45ck/Portarium
- JoelJohnsonThomas/ForgeFlow — https://github.com/JoelJohnsonThomas/ForgeFlow
- AGENTS.md 패턴 실측 — https://blakecrosley.com/blog/agents-md-patterns
