# 회사 규정 검토 대기사항

Raw 18개 문서를 정책 카드로 정리하면서 확인이 필요한 사항이다. 아래 결정을 받기 전까지 모든 카드는 `draft`이며 강제 규칙으로 사용하지 않는다.

## 결정 완료 1 — 저장소에 보관 가능한 고객 정보 범위

**결정일**: 2026-08-24
**결정**: 보안팀/팀장 확인 전에는 고객 보안정보를 Git에 저장하지 않고 비식별화된 기술 내용만 저장한다.

### 확인된 충돌

- 고객 보안 정보 가이드에서는 Account ID, Payer ID, IP, CIDR도 보안 정보로 정의한다.
- 같은 가이드의 승인된 팀 공유 플랫폼은 Microsoft Teams Files와 회사 OneDrive로 적혀 있다.
- 고객 Offboarding 문서에서는 기술 정보 보관 위치를 `Outline, Git`으로 적고 있다.

### 적용된 repository rule

다음 정보는 보안팀/팀장 승인 전까지 private GitHub `example-org/tiket`에 저장하지 않는다.

- 고객 AWS Account ID / Payer ID
- IP / CIDR / 네트워크 구성
- 아키텍처 다이어그램과 설정 정보
- 담당자 이름·회사 이메일·연락처
- 티켓 원문과 고객 제공 자료

tracked 파일에는 `CUST-NNN`, `CONTACT-NNN`, `ACCOUNT-NNN` reference만 사용한다. 실제 연결 정보는 gitignored `.private/customer-map.md`에만 저장한다. 자격증명·token·private key는 향후 승인 범위와 무관하게 항상 금지한다.

**2026-10-06 개정**: 가명(`CUST-NNN`·`CONTACT-NNN`·`ACCOUNT-NNN`)과 대조표를 쓰지 않는다. tracked 파일에는 고객 이름·연락처·계정을 적지 않고 패턴만 쓴다. 실제 내용은 로컬 전용 `tickets/` 에 둔다. 대조표가 동료 PC 에 없어 가명 규칙을 실행할 수 없었다(`development/plans/2026-10-06-drop-pseudonyms.md`). 위 저장 금지 목록과 자격증명 금지는 그대로다.

## 결정 완료 2 — 문서별 정본과 승인 주체

**결정일**: 2026-08-24
**결정**: 승인자·시행일·현재 버전이 확인되기 전에는 모든 Raw 문서와 파생 카드를 `draft` 또는 참고자료로 유지한다.

다음 문서들은 버전·승인·시행 정보가 충분하지 않다.

- CSG 통합 Job Description과 팀별 Job Description의 우선순위
- COC 노티 가이드의 최신 roster와 절차
- TS 주요 사항
- COP Q&A / CMP팀 질문 정리
- HR 체계

각 문서의 owner와 최신 정본 위치를 확인해야 한다. 확인된 카드를 `active`로 전환할 때는 `source_owner`, `source_version`, `effective_from`/`applicability`, `authority_verified_at`, `approved_by`, `approved_at`을 기록한다.

## 결정 완료 3 — 약관의 고객별 적용 여부

**결정일**: 2026-08-24
**결정**: 별도 예외가 고객 프로필에 기록되지 않은 고객에는 active 상태의 빌링 플랫폼 MSP 표준 약관을 기본 계약 baseline으로 적용한다.

빌링 플랫폼 MSP 서비스 표준 약관은 고객이 계약을 체결해야 효력이 발생한다고 적고 있다. 티켓에서 다음을 확인할 수 있는 경로가 필요하다.

- 해당 고객이 표준 약관을 체결했는지
- 별도 SLA/SOW/addendum이 있는지
- 정상 업무시간과 24x7 긴급 지원 계약 여부
- 고객별 응답 목표와 보안 사고 통보 조건

고객별 별도 SLA/SOW/addendum, 적용 제외, non-applicability가 기록되면 해당 문서가 그 범위에서 우선한다. 계약 분쟁·손해배상·해지·법적 보존처럼 법적 영향이 큰 해석은 예외 기록이 없어도 CSR/법무가 실제 계약을 확인한다. 표준 약관 policy card가 아직 `draft`인 동안에는 고객 약속의 확정 근거로 사용하지 않는다.

## 보류 4 — 빌링 플랫폼 Support Level별 지원 범위와 24x7 표현

**보류일**: 2026-08-24
**보류 사유**: 고객의 지원 범위는 AWS Support Plan이 아니라 빌링 플랫폼 고객 Support Level에 따라 달라질 수 있다. 관련 PDF 수신 후 결정한다.

- 표준 약관은 24x7 긴급 지원이 추가 계약된 경우에 한한다고 적는다.
- 마이그레이션 첫 미팅 가이드는 파트너 가치로 `24x7 기술 지원`을 제시한다.
- COC 가이드는 고객 지원 등급과 시간대에 따라 대응을 달리한다.

고객 회신에서는 계약 확인 전 24x7 지원을 약속하지 않는 것을 기본값으로 두었다.

PDF 수신 후 Support Level 명칭, 정상 업무시간, 24x7 대상, 긴급/일반 문의, severity별 응답 목표, COC/MSP/TS/CSR 라우팅을 추출해 이 항목을 다시 검토한다. AWS Support Plan과 빌링 플랫폼 Support Level은 별도 축으로 관리한다.

## 결정 완료 5 — Offboarding 보존 기간

> 2026-10-01 갱신: 4번째 단계(active Offboarding 가이드)는 `POLICY-OFFBOARD-001` 삭제로 비어서 뺐다. 지금은 법령 → 계약 → active 표준 약관 3단계다. 가이드가 다시 active 가 되면 되돌린다.

**결정일**: 2026-08-24
**결정**: 법령 → 고객별 계약/SLA/SOW → active 표준 약관 → active Offboarding 가이드 순으로 적용한다. 충돌·미확인은 삭제 또는 보존 기간을 선택하지 않고 법무 확인을 받는다.

표준 약관과 Offboarding 가이드의 일부 보존 기간 및 `영구 보관` 표현이 다르다. 실제 적용 시 다음 우선순위를 확인해야 한다.

1. 관련 법령
2. 고객별 계약/SLA/SOW
3. 회사 승인 정책
4. 일반 운영 가이드

현재 카드는 어떤 기간도 고객 공통값으로 자동 적용하지 않는다. 무기한 보존도 안전한 fallback으로 간주하지 않는다. 법적 근거와 기간이 확인되기 전에는 실제 삭제·보존 조치를 제안하거나 실행하지 않는다.

## 결정 완료 6 — 단독 Payer 정책의 현재성

**결정일**: 2026-08-24
**결정**: 단독 Payer 문서에서는 역할·개념·일반 제약만 참고한다. 비용·임계값·할인·빌링 플랫폼/CUR 제공 여부·지원 범위·현재 기능은 매번 CSR 계약 정보, COP 구현 상태, 빌링 플랫폼 실측으로 확인한다.

단독 Payer 문서에는 다음이 혼재한다.

- 현재 운영 절차
- 별도 계약 지원 범위
- 내부 비용·목표 수치
- 향후 roadmap

빌링 플랫폼 제공 범위, CUR 제공, 기술 지원, 비용, 전환 기준은 고객 회신 전에 현재 계약과 COP/CSR 확인이 필요하다.

roadmap와 KPI/목표 수치는 현재 제공 기능이나 고객 약속으로 사용하지 않는다. 검증 결과는 고객 프로필과 티켓에 Payer model, 확인일, CSR/COP/빌링 플랫폼 reference로 남긴다.

## 결정 완료 7 — COC 문서의 개인정보와 시점

**결정일**: 2026-08-24
**결정**: COC Raw에서는 역할·절차 후보만 참고한다. 실제 담당자는 매 routing 시점에 빌링 플랫폼과 현재 on-call roster에서 확인하고, tracked 파일에는 `CONTACT-NNN` reference·source reference·확인일시만 기록한다. 실제 연락처와 roster는 Git에 저장하지 않는다.

**2026-10-06 개정**: `CONTACT-NNN` 을 쓰지 않는다. tracked 파일에는 역할·출처·확인일시만 기록하고 사람을 적지 않는다.

COC Raw에는 개인 전화번호, 이메일, 고객명, 계정 예시와 여러 시행일이 섞여 있다.

- policy card에는 개인 연락처를 복사하지 않았다.
- 담당자는 빌링 플랫폼 또는 현재 roster에서 확인하도록 했다.
- 날짜별 절차 중 무엇이 현재 유효한지 COC owner 확인이 필요하다.

문서 내부에 더 최근 날짜가 있다는 이유만으로 해당 절차나 roster를 자동 활성화하지 않는다.

## 결정 완료 8 — 리뷰 기한 경과

**결정일**: 2026-08-24
**결정**: CSG Leadership가 현재 버전과 새 review date를 확인할 때까지 CSG 리스크 관리·고객 Offboarding 문서와 파생 카드를 `draft`로 유지한다.

다음 문서는 `다음 리뷰: 2026-05-12`로 적혀 있어 현재 기준 리뷰 기한이 지났다.

- CSG 리스크 관리
- 고객 Offboarding 프로세스 및 데이터 관리

기존 approval 표기만으로 현재성을 간주하지 않는다. 두 카드에는 activation blocker를 기록했고, 과거 review date 또는 `TBD`인 active 카드는 validator가 차단한다.

## 결정 완료 9 — TS 원격 지원 접근 방식

**결정일**: 2026-08-24
**결정**: 해당 remote-support PC/shared account 절차는 거의 사용되지 않고 폐기 예정이므로 repository에서 `retired` 처리한다. 사람과 에이전트 모두 승인된 접근 방법으로 사용하지 않는다.

TS 주요 사항 Raw에는 다음과 같은 민감한 운영 힌트가 포함돼 있다.

- 원격 지원용 PC의 IP와 shared account
- password/PIN을 특정 인원의 DM으로 받는 절차
- 접속 전후 Slack 통보 및 미통보 접속 강제 해지

실제 secret 값은 없고 credential signature 검사도 통과했다. Raw는 판단 이력으로 보존하되 접근 세부정보는 tracked 문서에 복사하지 않는다. 실제 PC 제거, shared account 비활성화, credential 회수, 접근 로그 확인은 human IT 작업이며 증빙 전에는 폐기 완료로 기록하지 않는다.

## 현재 안전 상태

- Raw 텍스트 18개는 Git에서 제외됨
- SHA-256 기준 완전 동일 중복 없음
- credential signature 검사 통과
- Raw의 개인 연락처와 고객별 account 예시는 tracked 문서에 복사하지 않음
- 정책 카드 15개: `active` 13개, `draft` 1개(`POLICY-RISK-001` — CSG 리더십이 현행 판을 확인해야 한다), `retired` 1개 (2026-10-06 기준, 목록은 `_routing.md`). `POLICY-TAM-001`·`POLICY-OT-001`·`POLICY-CASE-001` 은 2026-10-06 에 저장소 소유자가 승인해 활성으로 올렸다 — 출처 소유자는 MSP 팀장, 출처 날짜는 2026-09-27 로 고정.

## 결정 완료 10 — 초안 카드 검토 (2026-10-01)

**결정일**: 2026-10-01 (유지보수자)
**결정**: 초안 11장을 한 장씩 읽고 가렸다. 카드 문장은 원문 범위와 대조했고(`sources.json` 해시 일치), 승인자는 유지보수자다.

- **활성화(7)**: `POLICY-ACCESS-001`, `GUIDE-ONBOARD-001`, `GUIDE-BILLING-001`, `POLICY-SUPPORT-001`(필수 행동의 심각도 기록 삭제), `POLICY-DATA-001`(계약 종료는 담당 엔지니어·영업 담당·CSG 리더가 반드시 인지, 첫 필수 행동), `POLICY-PAYER-001`(Organizations all features·Control Tower·IAM Identity Center 언급 때 읽는다), `GUIDE-ROLE-001`(COP→FinOps팀 "옛 COP팀", TS팀은 MSP에 흡수)
- **삭제(3)**: `POLICY-OFFBOARD-001`, `POLICY-INCIDENT-001`, `GUIDE-MIGRATION-001`. 원문은 inbox 에 남아 있고 카드는 git 이력에서 되살릴 수 있다
- **초안 유지(1)**: `POLICY-RISK-001` — 필수 행동을 새로 썼다(Slack `general` 공유, MSP 담당 엔지니어 해결, 보안 사고는 담당 SA 합류). 원문 기한이 지났고 `general` 공유가 `POLICY-SEC-001` 과 부딪치는지 확인이 남았다
- 결정 3·5·6·7·8 에서 이 카드들을 가리키던 "초안으로 둔다" 는 위 결정으로 대체된다. 결정 4(Support Level PDF)는 그대로 열려 있다

## 결정 완료 11 — tiket 프로젝트 승인과 ITSM 통폐합 (2026-10-28)

**결정일**: 2026-10-28 (유지보수자 전달)
**결정**: 경영진이 tiket 프로젝트를 승인했다. 같은 날 ITSM 회의에서 프로젝트를 공유했고, 기능을 ITSM 과 비교·분석해 통폐합하기로 했다. 그동안 신규 기능 개발은 잠정 중단한다 — 버그 수정과 통폐합 준비만 한다.

- README 의 "회사 승인을 아직 확인하지 못했다" 상자는 이 결정으로 지운다.
- 그 상자가 묻던 세부 항목(도구별 회사 계정·학습 미사용 여부, 입력 금지 정보, 고객 약관의 제3자 AI 조항)에 대한 개별 답은 이 기록에 없다. 확인되면 여기에 덧붙인다. 그 전까지 입력 금지 정보는 `CLAUDE.md` 의 경계(자격증명·고객 식별 정보 비추적)를 따른다.
