# 사용 지표 수집 — 개발 계획서

2026-09-21 작성. 대상은 세 갈래다.

1. 수집기 인프라 (Lambda + API Gateway + DynamoDB)
2. 언제 자동으로 보낼 것인가
3. 옛 기록 8건이 기준선을 흐리는 문제

클라이언트(`scripts/report_usage.py`)는 `c1f2b3d` 로 이미 있다. 받는 쪽도
배포됐다 (2026-09-23 완료 — 5절 참조). 이 문서는 그 과정의 기록이다.

---

## 0. 인프라를 어디에 둘 것인가 — 결론부터

**별도 저장소로 뺀다.** `tiket` 에 `terraform/` 을 넣지 않는다.

### 근거

| | |
|---|---|
| **자기 규칙** | `CLAUDE.md:44` — *"Actual Terraform and implementation code lives under `~/work/<customer>/` or another designated project"* |
| **전례 3건** | `0014` 스킬 벤더링 안 함 · `0015` 온보딩이 설치 · `0018` bootstrap. **구현체는 밖, 계약은 안** — 이미 확립된 패턴이다 |
| **배포 비대칭** | 수집기는 **한 사람이 한 번** 배포한다. 프레임워크는 **전원이 매일** 쓴다 |
| **export 가 allowlist** | `UPSTREAM_DIRS` 에 넣어야 동료에게 간다. 안 넣으면 저장소에 있는데 안 나가는 유령 디렉터리가 된다 |
| **수명 주기** | 프레임워크는 주 단위로 바뀐다. 수집기는 배포 후 거의 안 바뀐다 |
| **딸려오는 것** | `.terraform/`, `.terraform.lock.hcl`, state backend 설정, provider 버전. `validate_workspace.py` 의 `TEXT_SUFFIXES`·ASCII 경로·정본 파일 목록에 전부 예외가 필요하다 |

현재 `tiket` 은 추적 파일 116개 / 577KB / `.git` 1.5M 이다. 작고 단단하다. 이 성질이 이 프레임워크의 장점이라 지킬 값어치가 있다.

### 단 하나의 반대 논거 — 스키마 드리프트

`report_usage.py` 가 만드는 페이로드와 Lambda 가 받는 모양이 갈라질 수 있다. 저장소가 나뉘면 같이 안 바뀐다.

**해결: 계약을 `tiket` 에 두고 구현만 밖에 둔다.** 스킬과 똑같다.

```
tiket/  (계약)                         tiket-usage-collector/  (구현)
  scripts/report_usage.py                terraform/
  agents/environment/usage-schema.json ───▶ lambda/handler.py 가 이걸 읽어 검증
  development/decisions/0021-...md            README.md
```

`agents/environment/mcp-manifest.json` → `render_agent_configs.py` 가 이미 같은 모양이다. **선언은 여기, 소비는 저기.**

v1 은 `schema_version: 1` 정수 하나로 충분하다. JSON Schema 파일은 v2 에서 필요해지면 만든다.

### 저장소 이름과 접근 — **확정 2026-09-21**

- `example-org/tiket-usage-collector` · private · 배포 권한자만 write
- 로컬: `~/work/tiket-usage-collector/`
  `~/work/` 은 고객사 디렉터리 전용(고객사별 폴더)이라
  맞지 않는다. `~/work/` 에는 이미 example-org org 저장소가 있다 (`MSP_주간회고` → `example-org/msp-team`)
- AWS: `msp-internal` 프로필, `ap-northeast-2`
  계정 번호와 버킷 전체 이름은 **여기 적지 않는다** — `tiket` 은 de-identified 만
  담는다. 구체값은 `tiket-usage-collector/terraform/main.tf` 와 그 README 에 있다
- `tiket` 의 `development/decisions/0021` 이 이 저장소를 가리킨다. 그게 유일한 연결고리다.

---

## 1. 수집기 인프라

### 1.1 구성

```
report_usage.py --send
      │ POST /ingest
      │ X-Api-Key: <키>
      ▼
API Gateway (HTTP API)
      │  · API key 검증은 Lambda 에서. HTTP API 는 사용량 계획이 없다
      │  · throttle: burst 10 / rate 5   (사람 손으로 만드는 트래픽이다)
      ▼
Lambda  ingest  (Python 3.12, 의존성 없음)
      │  1. X-Api-Key 를 SSM Parameter Store 값과 상수시간 비교
      │  2. schema_version 확인. 모르는 버전은 400
      │  3. 금지 패턴 재검사 ← 클라이언트를 믿지 않는다
      │  4. 크기 상한 64KB 초과는 413
      │  5. PutItem
      ▼
DynamoDB  tiket_usage   (on-demand)
      PK  engineer      S    "maintainer-gh"
      SK  sent_at       S    "2026-09-21T02:10:00+00:00"
      payload           M
      ttl               N    수집 후 400일
```

### 1.2 왜 EC2 가 아닌가

하루 10~30건 append 다. EC2 는 상시 비용 + 패치 + 퍼블릭 엔드포인트 관리가 붙는데 얻는 게 없다. Lambda 는 이 부하에서 사실상 무료 구간이고 패치 대상이 없다.

### 1.3 서버에서 금지 패턴을 다시 검사하는 이유

클라이언트의 `assert_no_identifiers` 는 **그 장비의 코드**다. 동료가 옛 버전을 쓰거나, 누가 고쳤거나, 직접 POST 할 수 있다. **수집기는 클라이언트를 신뢰하지 않는다.**

걸리면 저장하지 않고 `422` 와 함께 어느 패턴인지만 돌려준다. 값은 로그에도 안 남긴다.

```python
# lambda/handler.py — tiket 의 FORBIDDEN 과 같은 표를 복제한다.
# 복제인 것을 알고 한다. 서버가 클라이언트 코드를 import 할 수 없고,
# 이 표는 거의 안 바뀐다. 바뀌면 양쪽을 같이 고친다.
```

### 1.4 인증

API 키 하나를 SSM Parameter Store (`SecureString`) 에 둔다.

- 저장소에 넣지 않는다. clone 한 전원이 쓰기 권한을 갖게 된다.
- 온보딩이 환경변수로 심는다 — `TIKET_TELEMETRY_URL`, `TIKET_TELEMETRY_KEY`.
- **엔지니어별 키를 발급하지 않는다.** 페이로드가 메트릭 전용이라 키 유출 피해가 "가짜 통계가 섞인다" 수준이다. 복구는 키 회전 한 번. raw 였다면 엔지니어별 키·회전·감사가 전부 필요했다.
- `engineer` 필드는 자기 신고다. 위조 가능하다. **이건 감사 로그가 아니라 사용 통계**라 그 수준이 맞다.

### 1.5 Terraform 구성 — **골격 완료 2026-09-21**

```
~/work/tiket-usage-collector/
  terraform/
    main.tf        provider, backend, default_tags
    api.tf         HTTP API, route, $default stage, throttle, access log
    lambda.tf      function, role, 최소권한 정책, log group (30일)
    dynamodb.tf    table, TTL, PITR
    ssm.tf         SecureString (값은 CLI 주입, ignore_changes)
    variables.tf · outputs.tf
  lambda/
    handler.py       screen() / key_matches() / build_item() 로 분리 — 순수 함수라 테스트된다
    test_handler.py  16개 통과
  README.md          배포·키 주입·회전·왕복 확인 절차
  .gitignore         .terraform.lock.hcl 은 커밋한다
```

`terraform fmt` + `terraform validate` 통과.

#### state backend — 기존 것을 쓴다. 단 격리한다

부트스트랩이 필요 없다. `msp-internal` 에 이미 있다.

```
S3        msp-terraform-state-<계정>-<리전>-an   버전관리 Enabled
DynamoDB  msp-terraform-lock
```

**이 버킷은 MSP 팀 주간회고 웹사이트 인프라용이다.** 2026-09-21 기준 버킷은 비어
있고 주간회고는 아직 로컬 state 를 쓴다(`~/work/MSP_주간회고/terraform/terraform.tfstate`,
09-16). 즉 주간회고의 `key` 가 아직 안 정해졌으므로 충돌 위험이 실재한다.

```hcl
backend "s3" {
  bucket       = "msp-terraform-state-<계정>-<리전>-an"   # 실제 값은 수집기 저장소에
  key          = "tiket-usage-collector/terraform.tfstate"   # prefix 로 격리
  region       = "ap-northeast-2"
  encrypt      = true
  use_lockfile = true                                        # DynamoDB 미사용
}
```

**DynamoDB 락은 쓰지 않는다.** Terraform 공식 문서:

> DynamoDB-based locking is deprecated and will be removed in a future minor version.

`use_lockfile` 은 `<key>.tflock` 을 state 옆에 만들므로 key 와 함께 격리된다.
`dynamodb_table` 을 지정하지 않으면 `msp-terraform-lock` 을 한 번도 건드리지 않는다.
결과적으로 주간회고와 공유하는 것은 **버킷 이름 하나**뿐이다.

Terraform 1.10 이상 필요. 로컬은 v1.14.7.

#### 실행 권한 — 롤 assume (2026-09-21 결정)

사람의 자격으로 직접 돌지 않는다. `eks_checklist_terraform_role` 을 assume 한다.
배포자가 바뀌어도 권한이 같고, 롤을 신뢰하는 계정 어느 쪽의 프로필로도 실행된다.

`provider` 와 `backend` **양쪽에 따로** 걸어야 한다. backend 는 provider 설정을
상속하지 않아서, provider 에만 걸면 state 버킷이 403 이다. 문법도 다르다 —
provider 는 블록 `assume_role {`, backend 는 attribute `assume_role = {`.

backend 블록은 변수를 못 쓰므로 ARN 이 두 군데(`main.tf`, `variables.tf`)에
적힌다. 바꾸면 양쪽을 같이 고친다. README 에 적어뒀다.

검증한 것 (2026-09-21):

- 기본 프로필로 assume → `sts:GetCallerIdentity` 가 assumed-role 로 나온다
- assume 한 자격으로 state 버킷 `head-bucket` OK · 우리 prefix 는 비어 있음
- `AWS_PROFILE=default terraform init` 성공 — 크로스 계정 backend 인증 동작
- `terraform plan -lock=false` → **12 to add, 0 to change, 0 to destroy**

**관찰 — 롤의 신뢰 범위가 넓다.** 이 롤은 `AdministratorAccess` 가 붙어 있고,
trust policy 가 계정 10곳의 `:root` 와 `ec2.amazonaws.com` 을 신뢰한다
(`Condition` 없음, ExternalId 없음). `:root` 는 해당 계정에서 assume 권한을 받은
**모든** principal 을 뜻한다. 수집기가 만든 상황은 아니고 2025-03-18 부터
그렇게 있었다. 수집기 배포에는 지장이 없다 — 다만 이 롤은 다른 프로젝트
(`eks-checklist`)의 것이라, 그쪽에서 롤을 지우거나 조이면 수집기 배포가 멈춘다.

### 1.6 비용

`[추측]` — 현재 단가를 조회하지 않았다. 10명 × 1일 1회 = 월 300건 규모면 HTTP API·Lambda·DynamoDB on-demand 모두 최소 과금 구간이라 **월 1달러 미만**으로 본다. 확정하려면 배포 후 첫 달 Cost Explorer 를 본다.

### 1.7 작업 순서

1. ✅ 디렉터리 + Terraform 골격 — `fmt`/`validate` 통과
2. ✅ `handler.py` + 테스트 16개 통과 (금지 패턴 7종, schema_version, 크기, 인증)
3. ✅ `git init` + `example-org/tiket-usage-collector` 생성 — 완료
4. ✅ `terraform apply` — 12 added, 0 changed, 0 destroyed
5. ✅ SSM 에 키 주입 (README 절차) — 완료. 키 값은 문서/저장소에 남기지 않았다
6. ✅ `report_usage.py --send` 왕복 1회 확인 — DynamoDB 도착 확인 (2.3)
7. ✅ `development/decisions/0021-usage-collector-lives-in-its-own-repository.md`
8. ✅ 온보딩 7/8 "사용 지표" 단계 — 고지(B안) + 표시 이름 + 키. sh/ps1 동등, parity 32개 통과

   계획서 1.4 의 "환경변수로 심는다"는 폐기했다. 이 저장소는 온보딩이 셸 프로필을
   건드리지 않는다(`test_neither_touches_a_shell_profile`). Zendesk 와 같이
   `~/.config/msp/tiket-usage.conf` (600) 에 쓴다. 환경변수는 덮어쓰기용으로 남는다.

   엔드포인트는 묻지 않는다 — 팀에 하나뿐이고 secret 이 아니라(키 없으면 401)
   `report_usage.py` 의 `DEFAULT_TELEMETRY_URL` 이 기본값을 든다.

   표시 이름의 기본값은 **Zendesk 상담사 이름**이다(`users/me.json` 의 `.user.name`).
   6단계에서 이미 자격증명을 넣으므로 추가 입력이 없다. 실동작 확인함. 이름이 이메일
   형태면 쓰지 않는다 — 수집기가 422 로 거절해 그 사람 지표만 사라진다.
   실패하면 `git config user.name` 으로 조용히 떨어진다.

#### 배포 직후 확인 (2026-09-21)

SSM 이 placeholder 인 상태에서 엔드포인트가 닫혀 있는지 봤다.

| 요청 | 응답 |
|---|---|
| 키 없이 `POST /ingest` | `401` |
| 틀린 키 | `401 {"message":"unauthorized"}` |
| `GET /ingest` | `404` — `POST` 만 라우트된다 |

`api_key()` 가 SSM 을 못 읽거나 값이 안 맞으면 전부 거절한다. **열린 채로 두지 않는다**는
설계가 실물에서 확인됐다.

#### 배포 전에 확인한 것

`report_usage.py --json` 의 실제 출력을 `handler.screen()` 에 넣어 **200 통과**를
확인했다 (1,143 bytes / 64KB 상한). 계약이 맞는지는 apply 없이도 여기까지 볼 수 있다.

그 과정에서 클라이언트 버그를 하나 잡았다 — `--json` 인데도 stdout 마지막에
`(출력만 했다. 전송하려면 --send)` 가 붙어 **JSON 파싱이 깨졌다.** 사람용 줄을
stderr 로 옮기고 회귀 테스트 3개를 추가했다 (`test_report_usage.py`).

---

## 2. 언제 자동으로 보낼 것인가 — **완료 (2026-09-21)**

**세션 시작 훅 + 하루 1회 스로틀.** 고지는 **B안**(첫 회만)으로 온보딩 7/8 단계에 들어갔다.

### 2.1 구조

freshness 와 같은 세 호스트에 걸되 **별도 훅**이다. 관심사가 다르고 한쪽이 죽어도
다른 쪽이 돈다. 선언은 `render_agent_configs.py` 한 곳(0020 과 같은 구조).

```
USAGE_HOOK_COMMAND = "python3 scripts/report_usage.py --if-due"

.claude/settings.json     SessionStart 의 두 번째 hook
.codex/config.toml        두 번째 [[hooks.SessionStart.hooks]]
.kiro/hooks/usage.json    SessionStart + AgentSpawn (IDE·CLI 둘 다)
```

훅은 `--send` 를 부르지 않는다. 그러면 세션마다 보낸다. `--if-due` 가 스로틀을 안다.

### 2.2 지킨 것

| | 어떻게 |
|---|---|
| 세션을 막지 않는다 | 무엇이 실패해도 `return 0`. 타임아웃 **3초** |
| stdout 을 오염시키지 않는다 | `--if-due` 는 아무것도 출력하지 않는다 |
| 하루 1회 | `~/.config/msp/tiket-usage-sent` 스탬프 |
| 설정 안 한 사람 | 키가 없으면 조용히 끝낸다 |

**스탬프는 시도에 찍는다.** 성공에만 찍으면 네트워크가 종일 죽은 날 매 세션 재시도한다.
freshness 가 "뒤처진 동안은 안 찍는다"로 간 것과 반대인데, 그쪽은 알림을 놓치면 안 되고
이쪽은 하루치 지표를 놓쳐도 되기 때문이다.

### 2.3 검증 (2026-09-21)

- `python3 scripts/report_usage.py --if-due` → 종료 0, **출력 0바이트**, 스탬프 생성
- 그 직후 DynamoDB 에 `유지보수자` 항목 도착 — **훅 경로 end-to-end 확인**
- 곧바로 재실행 → 테이블 2건 그대로. **스로틀 동작 확인**
- 죽은 엔드포인트로도 종료 0 (`test_a_dead_endpoint_does_not_fail_the_session`)
- `.codex/config.toml` 을 `tomllib` 로 파싱해 `SessionStart.hooks` 2개 확인

**아직 확인 못 한 것**: 실제 Kiro·Codex 세션에서 이 훅이 발동하는지는 보지 않았다.
스키마는 freshness 와 같은 렌더러를 쓰지만 발동은 **가설**이다 — 0020 이 남긴 한계와 같다.

---

## 3. 옛 기록 8건 — **완료 (2026-09-21)**

### 3.1 무엇이 문제였나

`check_ticket_record.py --all` 이 15건 중 FAIL 8 이었다. 실패 항목은 `등급:`,
`policy_ids:`, `## 발송 전 점검` 세 가지에 몰려 있었다.

**이 필드들은 나중에 생겼다.** 그 전에 쓰인 기록에는 칸이 존재하지도 않았다.
에이전트가 절차를 건너뛴 게 아니라 절차가 아직 없었다.

### 3.2 단일 커트를 버린 이유 — 도입일이 항목별로 다르다

원안은 `schema: pre-2026-09-14` 하나로 8건을 통째로 면제하는 것이었다.
git 으로 확인하니 **항목이 한 날에 생기지 않았다.**

| 검사 항목 | 커밋 | 도입일 |
|---|---|---|
| 자리표시자 · `## 물어본 것` | `0d5571b` | 2026-09-04 |
| `산출물:` · 산출물별 섹션 | `559c838` | 2026-09-05 |
| `[확인]` 출처 | `748fdc4` | 2026-09-07 |
| `## 발송 전 점검` | `49b6536` | **2026-09-07** |
| `등급:` · `policy_ids:` | `164bc77` | 2026-09-14 |

09-14 단일 커트는 **09-07 이후에 실제로 빠뜨린 것까지 덮는다.** 실제로 3건이
그랬다. 그래서 검사기가 항목별 도입일 표(`FIELD_SINCE`)를 들고 기록의 `schema:`
날짜와 대조한다. **면제는 항목별이지 기록 단위가 아니다.**

경계 규칙: 도입 커밋과 **같은 날이면 면제**한다. 커밋 전후를 가릴 수단이 없고,
소급 판정은 관대한 쪽이 맞다.

A(소급 기입)를 배제한 판단은 그대로다. 그때 무엇을 골랐을지는 알 수 없다.

### 3.3 한 것

1. `check_ticket_record.py` — `FIELD_SINCE` 표, `schema:` 파싱, 항목별 면제,
   `Result` 네임드튜플, PASS/FAIL/미평가 3분류 출력
2. `test_check_ticket_record.py` — 면제 테스트 8개 추가 (헬퍼는 `CheckerHarness`
   믹스인으로 분리). 19/19 통과
3. 옛 기록 8건에 `schema:` 1줄 삽입. 본문은 손대지 않았다.
   값은 각 파일 mtime — 기록이 마지막으로 손질된 시점
4. `report_usage.py` — 새 출력 형식 파싱, `pre_schema` 집계, 요약 한 줄
5. `evals/rubrics/investigation-reply.md` — "미평가는 실패가 아니다" 절 추가

### 3.4 결과

```
이전:  FAIL 8/15
이후:  PASS 7 / FAIL 3 / 미평가 5 (총 15건)
```

남은 FAIL 3건은 **덮이면 안 되는 진짜 누락**이다.

| 기록 | schema | 남은 문제 | 왜 면제가 아닌가 |
|---|---|---|---|
| `100012` | 09-07 | `## 답변 초안` 이 비어 있다 | `산출물:` 은 09-05 도입 |
| `100014` | 09-11 | 발송 전 점검 미통과 1/6 | 점검은 09-07 도입 |
| `P0-001` | 09-08 | 초안 비어 있음 + 점검 섹션 없음 | 둘 다 09-08 이전 도입 |

### 3.5 확인이 필요한 것

`schema:` 값은 파일 mtime 에서 왔다. **mtime 은 작성 시점의 증거가 아니다** —
`tickets/` 는 git 추적 밖이라 복사·체크아웃으로 바뀐다. 결과가 갈리는 것은
`100012`·`100014`·`P0-001` 세 건뿐이고, 셋 다 실제 작성 시점이 헤더보다
앞선다면 미평가로 바뀐다. 그 판단은 사람만 할 수 있다.

---

## 4. 순서와 의존

```
3번 (옛 기록)  ─── ✅ 완료 2026-09-21. 기준선이 깨끗해졌다
                    └─▶ 1번의 페이로드가 의미를 갖는다

1번 (수집기)   ─── 별도 저장소. terraform apply 는 사람이 실행
                    └─▶ invoke_url 이 나와야 2번을 붙일 수 있다

2번 (전송 시점) ─── ✅ 완료 2026-09-21. 세션 훅 + 하루 1회, 고지는 B안
```

**3 → 1 → 2.** 3번을 먼저 하는 이유는 오염된 기준선을 수집하기 시작하면 나중에 되돌릴 수 없어서다.

---

## 5. 아직 안 정한 것

> **상태 (2026-09-23): 배포 완료.** 수집기 저장소 생성·`terraform apply`·SSM 키
> 주입·`--send` 왕복까지 끝났고, 최신 클라이언트가 팀에 배포된 상태다. 아래는
> 배포와 무관하게 남은 판단 항목이다.

- ~~수집기 저장소 이름~~ — 확정·생성됨 (`example-org/tiket-usage-collector`)
- ~~고지 방식 A/B/C (2.3)~~ — B안으로 확정, 온보딩 7/8 단계에 반영됨
- 대시보드를 만들 것인가 — v1 은 DynamoDB 를 직접 조회해도 된다. 조회가 귀찮아지면 그때 만든다
- `agents/environment/usage-schema.json` 을 v1 에 넣을 것인가 (지금은 `schema_version` 정수로 충분하다고 봄)
- 옛 기록 3건(`100012`·`100014`·`P0-001`)의 `schema:` 날짜가 맞는지 — mtime 에서 온 값이라 사람 확인이 필요하다 (3.5)
