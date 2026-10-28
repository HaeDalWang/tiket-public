# 흐름 — 이 프레임워크가 하는 일을 단계로

`python3 scripts/dev_map.py` 가 이 파일을 읽어 지도(`development/map.html`)를 그린다.

**상태는 여기 적지 않는다.** 단계마다 `근거` 칸에 그 단계를 이루는 파일을 적으면, 지도가
git 태그를 뒤져 "어느 릴리스에 처음 다 들어갔는지"를 계산한다. 사람이 ✅ 를 쓰는 순간
릴리스와 지도가 어긋날 수 있어서다.

`근거` 칸 쓰는 법 — 쉼표로 여럿:

| 모양 | 뜻 |
|---|---|
| `path` | 그 파일이 있으면 된다 |
| `path#문자열` | 그 파일에 그 문자열이 있어야 한다. 이미 있던 파일에 기능을 더했을 때 |
| `collector:path` | 수집기 저장소(`tiket-usage-collector`) 파일. tiket 릴리스와 따로 배포되므로 태그로 계산하지 않는다 |
| `site:path` | MSP 사이트 저장소(`MSP_주간회고`) 파일. 위와 같다 |
| `-` | 아직 아무것도 없다 → 계획 |

`#문자열` 은 **그 기능이 들어오기 전 파일에는 없던 것**으로 고른다. 흔한 문구를 고르면 옛 릴리스에서도
찾아져 거짓 초록불이 된다 (첫 지도에서 `git reset --keep` 이 그랬다). 고른 뒤 `git show <직전 태그>:<path>`
에 없는지 본다.

단계를 더하거나 근거를 바꾸면 이 파일만 고친다. 지도는 볼 때마다 새로 그린다.

## 티켓 처리

| 단계 | 하는 일 | 근거 | 참고 |
|---|---|---|---|
| 가져오기 | Zendesk 티켓과 첨부 이미지를 받는다 | `scripts/fetch-ticket.sh`, `scripts/fetch-ticket.ps1` | 0006 |
| ITSM 에서 가져오기 | 티켓이 ITSM 으로 넘어오면 쓸 읽기 — 만들어 뒀고 `fetch-ticket` 에는 아직 안 이었다 | `scripts/itsm_ticket.py` | `plans/2026-10-06-itsm-ticket-read.md`, 전환 2027-04 쯤 |
| 분류 | quick · standard · high-risk 로 나눈다 | `agents/task-router.md#high-risk` | 0005, 0007 |
| 기록 | `tickets/<id>.md` 를 양식으로 연다 | `templates/ticket-intake.md` | 0001, 0002, 0019 |
| 작성일 | `날짜:` 는 스레드 날짜, `작성일:` 은 기록을 처음 만든 날 — 가져올 때 찍힌 `조회일` 을 옮긴다. 주별 지표는 작성일로 센다 | `templates/ticket-intake.md#작성일:`, `scripts/fetch-ticket.sh#조회일`, `scripts/fetch-ticket.ps1#조회일`, `scripts/check_ticket_record.py#기록 시점은` | 평가 12회 중 5회가 `날짜:` 에 스레드 날짜를 적었다 (2026-10-22) |
| 규칙 찾기 | 주제가 맞는 정책 카드만 읽는다 | `policy/_routing.md` | |
| 결과물 | 작업 지시서 · 조사+답변 · 답변+출처 | `playbooks/ticket-outputs.md` | 0008~0011 |
| 회신 양식 | 팀 답변 템플릿 00~11 중 하나로 쓰고 `회신 유형:` 을 적는다 | `playbooks/reply-templates.md`, `templates/ticket-intake.md#회신 유형:` | 0041 |
| 내부 확인 | 사람에게 물어 정할 것을 정리하고, 답은 사람이 적는다 | `templates/ticket-intake.md### 내부 확인` | 0041 |
| 발송 전 점검 | 보내기 전에 스스로 확인한다 (2026-10-21 6 → 9항목) | `templates/ticket-intake.md#발송 전 점검` | 0012, 0041 |
| 기록 검사 | 기록이 양식을 지켰는지 본다 | `scripts/check_ticket_record.py` | |
| 저장할 때 기록 검사 (Kiro) | 기록을 저장할 때마다 에이전트에게 검사기를 돌리라고 한다 | `.kiro/hooks/ticket-record-check.json` | 0038 |
| 평가 | 케이스를 깨끗한 사본에서 사람 없이 돌린다 (Kiro) | `scripts/eval_run.py` | 0033 |
| 평가 채점 | 회차마다 맞는 카드를 골랐나 · 고른 뒤 초안이 지켰나를 센다 | `scripts/eval_score.py` | `plans/2026-10-08-routing-recall.md` |

## 배포와 업데이트

| 단계 | 하는 일 | 근거 | 참고 |
|---|---|---|---|
| 온보딩 | 설치 · 점검 · 사용 지표 고지 | `scripts/onboarding.sh`, `scripts/onboarding.ps1` | 0015, 0040 |
| 고객 AWS 조회 스킬 설정 | 브로커 conf · `csg-login` 마커 · 빌링 플랫폼 키를 맞춘다 (온보딩 5단계) | `scripts/skill_setup.py` | 0040 |
| 정식 버전으로 받기 | clone 뒤 최신 태그로 맞춘다 | `ONBOARDING.md#describe --tags --abbrev=0` | |
| 릴리스 | 검사를 통과해야 태그를 찍는다 | `scripts/release.py` | 0025 |
| 릴리스 알림 | 노트 맨 위에 동료가 꼭 볼 문구 | `scripts/release.py#--notice` | v0.1.1 에서 고지가 빠진 뒤 |
| 릴리스 요약 | 커밋 제목 대신 동료 눈으로 쓴 바뀐 점, 없으면 태그를 안 찍는다 | `scripts/release.py#--summary` | v0.2.12 노트가 우리 말뿐이었다 |
| 자동 업데이트 | 세션 시작 때 새 태그로 올라간다 | `scripts/check-freshness.sh`, `scripts/check-freshness.ps1` | 0016, 0020, 0025 |
| 세션 시작 순서 | 업데이트가 끝난 뒤에 지표를 보낸다 (훅 하나, `;`) | `scripts/render_agent_configs.py#SESSION_HOOK_COMMAND` | 하네스가 훅을 동시에 돌린다 |
| 이 PC 에서 되는 기능 알리기 | 세션마다 빠진 기능을 한 줄로 | `scripts/local_capabilities.py` | 0029 |
| 예전 스킬 사본 옮기기 | 세션 시작이 `csg-*` 프로필을 워크스페이스로 돌리고 `$HOME` 사본을 백업 폴더로 | `scripts/skill_migration.py` | 0040 |
| Kiro 승인 창 줄이기 | 읽기 명령·티켓 쓰기를 묻지 않게 각 PC 에 권한 규칙을 넣는다 | `scripts/kiro_permissions.py` | 0030 |
| 막힌 것 알리기 | 새 버전 확인이 세 번 연속 실패하면 한 줄 알린다 | `scripts/check-freshness.sh#번 연속 실패했다`, `scripts/check-freshness.ps1#번 연속 실패했다` | 0039 |

## 사용 지표

| 단계 | 하는 일 | 근거 | 참고 |
|---|---|---|---|
| 세기 | 숫자만 모은다 (고객 내용 없음) | `scripts/report_usage.py` | 0021 |
| 못 보내면 알리기 | 세 번 연속 수집기에 못 닿으면 알린다 · 막히면 사유를 대신 보낸다 | `scripts/report_usage.py#번 연속 실패했다` | 0039 |
| 리더용 묶음 | 검사 실패를 발송 전 점검·처리 방향·기록·교훈·양식으로 | `scripts/check_ticket_record.py#CATEGORIES` | 번역의 원본은 검사기 |
| 믿을 수 있는 숫자 | 평가 기록 제외 · 최근 7·28일 · 발송 기록 (schema 2) | `scripts/report_usage.py#evaluation_excluded`, `scripts/report_usage.py#collect_recent`, `scripts/report_usage.py#SENT_HEADING` | |
| 초안을 얼마나 고쳤나 | 기록의 답변 초안과 Zendesk 에 보낸 공개 답변의 문자열 유사도 (지표 B) | `scripts/usage_zendesk.py#draft_similarity` | |
| 맡은 티켓·응답 시간 | 해결한 담당 티켓 중 기록 비율(D) · MTTA·MTTR·재오픈(C) | `scripts/usage_zendesk.py#reply_minutes` | `docs/metrics.md` |
| 받기 | 인터널 계정 `tiket_usage` 테이블 (schema 1·2) | `collector:lambda/handler.py` | |
| 보기 | MSP 사이트 사용 지표 대시보드. 지표마다 세는 법을 한 줄씩 단다 | `site:src/usage.mjs`, `site:frontend/src/features/Usage.tsx#문자열 유사도` | 사이트는 별도 저장소·배포: https://msp-internal.example.com/#usage (관리자·팀장만) |

## 지식 순환

| 단계 | 하는 일 | 근거 | 참고 |
|---|---|---|---|
| 교훈 적기 | 넘어진 티켓만 `## 교훈 후보` 를 채운다 (T1~T4) | `templates/ticket-intake.md#교훈 후보`, `scripts/check_ticket_record.py#LESSONS_HEADING` | 0026 |
| 종류 가르기 | 후보를 고르기 전에 pitfall · policy · playbook · customer 를 묻는다 | `templates/ticket-intake.md#종류는 고르기 전에 묻는다` | `EVAL-008`·`009` |
| 판례 대조 | 후보 전에 `pitfalls/` 를 찾아 `확인한 곳:` 에 적는다. 이미 보낸 답이 판례와 어긋났으면 `miss` + `막을 규칙:` | `templates/ticket-intake.md#먼저 판례를 찾는다`, `scripts/check_ticket_record.py#seen_problems`, `scripts/report_lessons.py#막을 규칙`, `collector:lambda/candidates.py#"miss"` | `EVAL-027` 9/10 |
| 보내기 | 세션 시작 때 6시간에 한 번 후보를 팀 테이블로 | `scripts/report_lessons.py` | 끄기 `TIKET_LESSONS=off` |
| 출처·관측일 | 후보의 `출처:`·`관측일:` 을 함께 보내 승인 화면에서 본다 | `scripts/report_lessons.py#observed_on`, `collector:lambda/candidates.py#observed_on`, `site:frontend/src/features/Candidates.tsx#관측일` | 빠지면 검사기가 경고만 한다 |
| 받기 | 인터널 계정 `tiket_candidates`, 90일 보존 | `collector:lambda/candidates.py` | |
| 바로 읽기 | 승인 전 후보를 동료 AI 가 `[추측]` 으로 | - | 2차. 후보가 쌓인 뒤 |
| 검증 | 승인 · 반려 · 병합 | `collector:tools/review_candidates.py`, `site:src/candidates.mjs` | MSP 사이트(리드급 결정) + CLI. 사이트는 따로 배포 |
| 파일로 | 승인된 것을 `pitfalls/`·`policy/` 파일로 | - | 지금은 손으로 |
| 찾아보기 | 최신 릴리스의 규칙·업무 방법·사례를 사이트에서 검색 | `site:src/knowledge.mjs` | 지식 도서관. 태그를 직접 읽어 릴리스와 같다 |
| 퍼뜨리기 | 릴리스 → 자동 업데이트 | `scripts/check-freshness.sh` | |
| 고객 사정 읽기 | 계정 조회 전에 ITSM 에서 그 고객의 특이사항만 읽는다. 토큰 미등록은 경고하고 진행, 못 읽으면 멈춘다 | `scripts/customer_notes.py`, `agents/task-router.md#customer_notes.py`, `scripts/onboarding.sh#itsm-token` | 0031, 0034 개정 2 |

## 주간회고

| 단계 | 하는 일 | 근거 | 참고 |
|---|---|---|---|
| 초안 | "일기 써줘" 로 그 주의 기록과 티켓 수를 모아 초안을 만든다 | `playbooks/weekly-diary.md`, `scripts/weekly_diary.py` | 고객 일이 아니다 — 티켓 기록 없음 |
| 임시저장 | "저장해" 라고 했을 때만 MSP 사이트에 임시저장한다. 제출은 사람이 | `scripts/weekly_diary_save.py` | |
