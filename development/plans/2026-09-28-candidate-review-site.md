# 계획서 · 교훈 후보 승인 화면 — MSP 사이트에 기능 추가

- **상태**: 계획 (2026-09-28). MSP 사이트 저장소(`~/work/MSP_주간회고`)에 넘길 기능 명세다.
- **상태 (2026-09-28): 배포 완료.** 사이트 `dfc358a`·`d400b21`. 권한은 5절과 다르게 갔다 — 아래 진행 기록.
- 배경: [[2026-09-24-knowledge-loop]] 6절, [[0026-ticket-lessons-flow-to-a-candidate-table]]. 지금은 CLI
  (`tiket-usage-collector/tools/review_candidates.py`)로 승인한다. 이 계획은 같은 일을 사이트에서 하게 한다.
- 이 문서를 받는 쪽(사이트 작업자·에이전트)은 사이트의 `AGENTS.md` · `docs/ARCHITECTURE.md` 를 먼저 따른다.
  여기 적힌 것은 **무엇을·어떤 규칙으로** 이고, 코드 배치는 사이트 규칙이 정한다.

---

## 1. 한 줄 목표

DynamoDB `tiket_candidates` 에 쌓인 교훈 후보를 사이트에서 **보고, 승인·반려·병합**한다.
결정 규칙은 CLI 와 **완전히 같아야** 한다 — 같은 행을 두 도구가 다르게 바꾸면 안 된다.

## 2. 이미 있는 것 (확인됨, 2026-09-28)

| 항목 | 값 |
|---|---|
| AWS 계정 | MSP 회사 인터널 계정 — 사이트와 같은 계정 (번호는 사이트 `AGENTS.md` 에 있다) |
| 리전 | `ap-northeast-2` |
| 테이블 | `tiket_candidates` — 해시 키 `candidate_id`(S), TTL 속성 `expires_at`, PITR 켬 |
| 테이블 소유 | `tiket-usage-collector` 저장소 `terraform/candidates.tf`. **사이트는 테이블을 만들지도 바꾸지도 않는다** |
| 사이트 | Express + React 한 이미지, EC2, IAM Role `aws_iam_role.app` 로 AWS 호출 (월간 리포트 Lambda 와 같은 방식) |
| 사이트 역할 | `admin` · `lead` · `member` (`requireRole`) |

## 3. 행 모양 (수집기 `lambda/candidates.py` `build_item`)

| 속성 | 타입 | 언제 있나 | 뜻 |
|---|---|---|---|
| `candidate_id` | S | 항상 | 32자 hex. 서버가 계산 |
| `engineer` | S | 항상 | 보낸 사람 표시 이름 |
| `ticket_ref` | S | 항상 | 티켓 번호(또는 로컬 번호) |
| `kind` | S | 항상 | `pitfall` · `policy` · `playbook` · `customer` · `reobserved` |
| `status` | S | 항상 | `new` · `approved` · `rejected` · `merged` |
| `created_at` | N | 항상 | epoch 초 |
| `expires_at` | N | 결정 전·반려·병합 | epoch 초. 지나면 DynamoDB 가 지운다(최대 이틀 늦음) |
| `sent_at` · `head` · `schema_version` | S·S·N | 항상 | 보낸 시각, 워크스페이스 커밋, 스키마 |
| `corp_id` | S | 있을 때만 | 빌링 플랫폼 corpId |
| `trigger` | L(S) | 교훈일 때 | `T1`~`T4` |
| `summary` | S | 교훈일 때 | 한 줄 교훈 |
| `evidence` | S | 결정 전·반려·병합 | 근거 + 티켓의 `## 물어본 것`·`## 확인한 것` 발췌. **고객 내용이 들어 있다.** 최대 4000자 |
| `target` | S | `reobserved` 일 때 | 다시 밟힌 `pitfalls/<file>.md` |
| `reviewed_by` · `reviewed_at` · `review_note` | S·N·S | 결정 뒤 | 누가·언제·왜 |

값이 없으면 속성 자체가 없다(null 을 넣지 않는다). 화면은 없는 속성을 견딘다.

## 4. 결정 규칙 — CLI `decide()` 와 같아야 한다 (정본은 CLI)

| 규칙 | 내용 |
|---|---|
| 결정 종류 | `approved` · `rejected` · `merged` 셋뿐 |
| 사유 | `rejected` · `merged` 는 `review_note` 필수(공백 제외). `approved` 는 선택 |
| 한 번만 | `status = new` 인 행만 바꾼다. **조건부 쓰기**로 막는다 — 읽고 나서 확인하는 방식은 경쟁에서 진다 |
| 승인하면 | `evidence` 와 `expires_at` 을 **지운다**. 고객 원문은 버리고, 한 줄 교훈만 영구 자산으로 남긴다 |
| 반려·병합하면 | `expires_at` 을 그대로 둔다 → 90일 뒤 사라진다 |
| 누가·언제 | `reviewed_by` = 로그인한 사용자 이름, `reviewed_at` = **서버** 시각(epoch 초). 요청 본문에서 받지 않는다 |

DynamoDB 요청은 이것과 같아야 한다.

```
UpdateExpression:    SET #s = :d, #by = :by, #at = :at, #note = :note          (승인이면 뒤에 " REMOVE #ev, #exp")
ConditionExpression: #s = :new
Names:  #s=status  #by=reviewed_by  #at=reviewed_at  #note=review_note  (#ev=evidence  #exp=expires_at)
Values: :d=<결정>  :by=<이름>  :at=<epoch 초>  :note=<사유 또는 "">  :new="new"
```

`ConditionalCheckFailedException` → **409** "이미 결정된 후보입니다". 덮어쓰지 않는다.

규칙을 바꿔야 하면 사이트에서 먼저 바꾸지 않는다. 수집기 `decide()` 와 그 테스트를 먼저 고치고 같이 옮긴다.

## 5. 권한

| 누가 | 목록·상세(근거 포함) | 결정 |
|---|---|---|
| `member` | ✗ | ✗ |
| `lead` · `admin` | ✓ | ✗ |
| 승인자 명단 | ✓ | ✓ |

- **승인자는 역할이 아니라 사람이다.** 지금은 유지보수자 한 명, `v1.0.0` 에 팀장·경영진을 더한다 (2026-09-24 결정).
  사이트 설정(`.env` / Secrets Manager `msp-weekly-review/app-config`)에 `CANDIDATE_REVIEWER_IDS`
  (사이트 `users.id` 쉼표 목록)로 둔다. 비어 있으면 아무도 결정하지 못한다(열린 기본값 금지).
- 근거(`evidence`)에는 고객 내용이 있다. `member` 에게 보이지 않는 이유다. 화면에 뿌릴 때 HTML 로 해석하지
  않는다(React 기본 이스케이프, `dangerouslySetInnerHTML` 금지). 서버 로그에 행 내용을 남기지 않는다 — 건수만.
- 모든 권한은 서버에서 확인한다. 버튼을 숨기는 건 편의일 뿐이다.

## 6. 화면

**목록 (기본: 결정 전)**

- 대상: `status = new` 이고 `expires_at` 이 지금보다 뒤인 행. 오래된 것부터 (`created_at` 오름차순)
- 열: 받은 날 · 보낸 사람 · 티켓 · 종류 · 트리거 · 한 줄(`summary`) · corpId
- 필터: 상태(결정 전 / 승인 / 반려 / 병합), 종류
- `reobserved` 는 목록에 섞지 않는다. 별도 칸에 **`target` 별 횟수**만 보인다 ("이 판례가 N번 다시 밟혔다").
  결정 대상이 아니고 90일 뒤 사라진다. CLI 의 `reobserved` 명령과 같은 집계다
- 결정 전 건수를 메뉴에 배지로

**상세**

- 모든 속성. `evidence` 는 줄바꿈을 살린 고정폭 블록
- 승인자에게만: [승인] [반려] [병합] + 사유 입력. 반려·병합은 사유가 비면 버튼이 안 눌린다(서버도 막는다)
- 승인 확인창에 한 줄: "승인하면 근거 원문이 지워지고 되돌릴 수 없습니다"
- 409 가 오면 "다른 사람이 먼저 결정했습니다" 후 새로고침

**결정된 것**

- 누가·언제·사유. 승인된 `pitfall`·`policy`·`playbook` 은 "git 파일로 옮길 것" 목록이 된다 —
  옮겼는지는 이 기능이 모른다(범위 밖, 9절)

## 7. 서버 API (사이트 규칙대로 도메인 모듈로, `server.mjs` 에는 등록만)

| 메서드 | 경로 | 권한 | 동작 |
|---|---|---|---|
| GET | `/api/candidates?status=new&kind=` | lead·admin·승인자 | Scan → 서버에서 거르고 정렬. `evidence` 는 목록에서 뺀다 |
| GET | `/api/candidates/:id` | lead·admin·승인자 | GetItem |
| POST | `/api/candidates/:id/decision` | 승인자 | 본문 `{decision, note}` → 4절 규칙 그대로 UpdateItem |
| GET | `/api/candidates/reobserved` | lead·admin·승인자 | `kind=reobserved` 살아 있는 행을 `target` 별 집계 |

- `:id` 는 32자 hex 만 받는다. 아니면 400
- 테이블은 작다(90일 보존, 하루 수십 건 이하) — Scan 으로 충분하다. 페이지네이션(`LastEvaluatedKey`)은 끝까지 따라간다
- 테이블 이름은 설정 `CANDIDATES_TABLE`(기본 `tiket_candidates`). 비어 있으면 기능을 끄고 메뉴를 숨긴다 —
  월간 리포트의 `MONTHLY_DIGEST_FUNCTION_NAME` 과 같은 방식
- 패키지: `@aws-sdk/client-dynamodb` + `@aws-sdk/lib-dynamodb`. 이미 `@aws-sdk/client-lambda` 를 쓰므로 같은 계열이다

## 8. 인프라 (사이트 `terraform/`)

EC2 앱 역할에 정책 하나를 더한다. 테이블은 `data "aws_dynamodb_table"` 로 이름만 참조한다.

```hcl
resource "aws_iam_role_policy" "app_tiket_candidates" {
  name = "review-tiket-candidates"
  role = aws_iam_role.app.id
  policy = jsonencode({ Version = "2012-10-17", Statement = [{
    Effect   = "Allow"
    Action   = ["dynamodb:Scan", "dynamodb:GetItem", "dynamodb:UpdateItem"]
    Resource = data.aws_dynamodb_table.tiket_candidates.arn
  }] })
}
```

- **`PutItem` · `DeleteItem` 은 주지 않는다.** 사이트는 후보를 만들거나 지우지 않는다
- 가능하면 `UpdateItem` 이 바꿀 수 있는 속성을 좁힌다 — IAM 조건 키 `dynamodb:Attributes` 로
  `candidate_id, status, reviewed_by, reviewed_at, review_note, evidence, expires_at` 만.
  **미확인이다.** AWS 문서로 동작을 확인하고, 거부되는 요청을 실제로 한 번 본 뒤에만 넣는다. 확인 못 하면 빼고 이유를 적는다
- apply 전에 사이트 규칙대로 계정 번호, backend, plan 의 삭제·교체 여부를 본다. plan 은 유지보수자가 보고 승인한다

## 9. 범위 밖

- 후보 내용 고치기, 후보 지우기, 후보 만들기
- 승인된 것을 `pitfalls/`·`policy/` git 파일로 만들기 — 지금처럼 사람(+에이전트 초안)이 한다
- 승인된 고객 사정을 티켓 처리 중 읽는 길 — 지식 순환 2차 ([[2026-09-24-knowledge-loop]] 3.3, 백로그)
- 새 후보 Slack 알림 — 쓰다가 필요하면

## 10. 검증

**실서버·실테이블에 닿는 자동 테스트는 만들지 않는다** (tiket 2026-09-21 사고 뒤의 규칙).

| 층 | 무엇을 |
|---|---|
| 서버 단위 | 가짜 DynamoDB 클라이언트가 **조건식을 실제로 해석**해야 한다 (`#s = :new` 를 무시하는 가짜는 "한 번만" 규칙을 못 잡는다 — 수집기 테스트에서 실제로 잡힌 구멍). 승인 시 `REMOVE` 두 속성, 반려·병합 사유 필수, 409, 400(잘못된 id·결정) |
| 권한 | member 403 · lead 가 결정하면 403 · 승인자 명단이 비면 아무도 결정 못 함 · `reviewed_by` 를 본문에서 못 바꿈 |
| 계약 | 4절의 UpdateExpression·Condition·Names 가 CLI 와 글자 그대로 같은지 — 테스트에 문자열로 박아 둔다 |
| E2E | 가짜 백엔드로 목록 → 상세 → 반려(사유 없음 거절 → 사유 입력) → 승인 → 두 번째 결정 409 |
| 변이 | 조건식 제거 · REMOVE 제거 · 사유 검사 제거 · 권한 검사 제거 — 각각 테스트가 잡는지 |

**운영 확인 (배포 뒤, 한 번)** — 테이블에 쓰기가 들어가므로 유지보수자 승인 뒤에 한다.

1. 합성 후보 1건을 수집기 `/candidates` 로 보낸다 (고객 내용 없음, `ticket_ref` 에 `SMOKE`)
2. 사이트에서 보이는지 → 반려(사유) 또는 승인 → CLI `list`/`show` 로 같은 결과인지
3. 같은 행에 두 번째 결정 → 409
4. 스모크 행을 지운다(CLI 권한으로). 끝에 테이블에 스모크 행이 없는지 본다

## 11. 순서

1. IAM 정책 — plan 을 보여 주고 승인받아 apply
2. 서버 API + 테스트
3. 화면 + E2E
4. 배포 → `/health` → 운영 확인(10절)
5. tiket 쪽 정리: 백로그 대기의 "승인 사이트" 항목을 지우고, `development/flow.md` 지식 순환 "검증" 단계 참고 칸에
   사이트를 적는다. CLI 는 남긴다(사이트가 죽었을 때의 길)

## 12. 정해야 할 것

| 질문 | 기본안 |
|---|---|
| 승인자 명단을 설정으로 둘까, 사이트 DB 에 둘까 | 설정(`CANDIDATE_REVIEWER_IDS`). 사람이 바뀌는 일이 드물고, DB 화면을 새로 만들 필요가 없다 |
| `lead` 가 근거(고객 내용)를 봐도 되나 | 본다. "경영진·팀장도 같이 보는 게 좋다" (2026-09-24) |
| `reobserved` 를 결정 대상으로 둘까 | 두지 않는다. 집계만. 횟수가 그 판례의 가치 신호다 |

## 진행 기록

**2026-09-28 — 배포, 권한을 계획과 다르게 (유지보수자 결정)**

- 사이트 `src/candidates.mjs` · `terraform/candidates.tf`. 4절 결정 요청은 CLI 와 글자 그대로 같다(대조함).
  IAM 은 `Scan`·`GetItem`·`UpdateItem` 을 테이블 하나에만 — 운영 계정에서 정책 문서를 확인했다
- **권한이 5절과 다르다. 유지보수자가 사이트 작업 중에 바꾸라고 했다.**

  | | 5절 계획 | 배포 |
  |---|---|---|
  | 보기(근거 원문 포함) | lead·admin·승인자 | 로그인한 모든 사용자 |
  | 결정 | 승인자 명단(`CANDIDATE_REVIEWER_IDS`, 유지보수자 한 명) | `admin`·`lead` 역할 |

  이유: 리드급이 팀 리드·경영진·유지보수자 세 명뿐이다. 명단을 따로 둘 이유가 없다.
  이 때문에 0026 의 "승인은 유지보수자, `v1.0.0` 에 팀장·경영진" 가 앞당겨졌다 — 0026 에 덧붙였다.
  **다시 볼 때**: `lead` 역할이 네 명 이상이 되거나, 사이트 사용자가 MSP 팀 밖으로 넓어지면(근거 원문이 보인다).
- 12절: 1번(명단 위치)은 명단 없음으로 닫힘. 2·3번은 기본안대로.
- 10절 운영 확인은 유지보수자가 직접 한다(구두 안내). 배포 시점에 테이블은 0행이었다.
