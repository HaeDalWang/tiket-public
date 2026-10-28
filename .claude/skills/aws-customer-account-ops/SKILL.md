---
name: aws-customer-account-ops
description: Manages AWS customer account operations by identifying customers via BILLING API, dynamically creating account-scoped AWS CLI profiles (read-only enforced server-side by the broker), and executing read-only AWS commands for resource queries and troubleshooting. Also provides billing/cost analysis via BILLING billing API without AWS account access. Triggers on customer AWS account requests like resource listing, security checks, issue investigation, cost analysis, invoice lookup, or savings reporting.
---
<!-- Generated from skills/aws-customer-account-ops/SKILL.md by scripts/render_agent_configs.py. Do not edit by hand. -->

# AWS Customer Account Operations

고객 AWS 계정에 접근하여 리소스 조회 및 트러블슈팅을 수행하고, BILLING 빌링 API를 통해 비용/청구 데이터를 분석합니다. BILLING API로 고객을 식별하고, 계정 ID만 담은 AWS CLI 프로필을 동적 생성한 뒤, 읽기 전용 명령만 실행합니다(read-only 는 브로커가 서버측에서 강제). 비용/인보이스 조회는 AWS 계정 접근 없이 빌링 API만으로 처리할 수 있습니다.

## When to Use

**AWS 리소스 조회 및 트러블슈팅:**
- 고객 AWS 계정의 EC2, S3, RDS 등 리소스 목록 조회
- 보안 설정 점검 (Security Group, IAM Policy, S3 버킷 정책)
- 고객 환경 트러블슈팅 (서비스 장애, 연결 문제, 리소스 상태 확인)
- 비용 관련 리소스 확인 (사용 중인 인스턴스, 미사용 리소스)
- 고객사명, 계정 ID, 계정명으로 AWS 계정 식별이 필요할 때

**빌링/비용 조회 (AWS 계정 접근 불필요):**
- 고객사 월별 AWS 비용 조회 ("이번 달 비용 얼마야?")
- 청구 내역(인보이스) 조회 ("인보이스 보여줘")
- RI/SP/CloudFront 할인 현황 분석 ("절감 효과 보여줘")
- 전체 고객사 청구 요약 조회 ("이번 달 전체 청구 현황")

## Prerequisites

작업 전 반드시 확인:

```bash
# 1. csg-login marker 프로필 존재 확인 (SKILL_DIR 경로 탐색 전용 앵커, login-only)
aws configure get profile.csg-login.credential_process 2>/dev/null

# 2. credential_process 가 tiket 워크스페이스의 skills/aws-customer-account-ops/get-sts-token.sh 를 가리키는지 확인
aws configure get profile.csg-login.credential_process 2>/dev/null

# 3. ⚠️ STS 토큰 사전 확인 및 자동 인증 (반드시 AWS 작업 전에 실행!)
SKILL_DIR=$(dirname "$(aws configure get profile.csg-login.credential_process 2>/dev/null)")
"$SKILL_DIR/get-sts-token.sh" --check-only > /dev/null 2>&1
if [ $? -eq 2 ]; then
    # 토큰이 만료되었거나 없습니다. 아래 우선순위로 처리하세요:
    #
    # [우선] 에이전트가 직접 get-sts-token.sh를 실행합니다.
    #   - 사용자 브라우저가 자동으로 열리고 Slack 인증을 완료하면 토큰이 발급됩니다.
    #   - 스크립트가 완료될 때까지(최대 120초) 대기합니다.
    #   - 사용자에게 "Slack 인증 브라우저가 열립니다. 인증을 완료해주세요." 안내 후 실행하세요.
    "$SKILL_DIR/get-sts-token.sh"
    #
    # [대체] 위 실행이 실패하면 (SSH, 헤드리스 등 브라우저를 띄울 수 없는 환경):
    #   사용자에게 터미널에서 직접 실행하도록 안내하세요:
    #   echo "STS 토큰이 만료되었습니다. 아래 명령을 터미널에서 실행해주세요:"
    #   echo "  $SKILL_DIR/get-sts-token.sh"
fi

# 4. Slack 인증 설정 파일 존재 확인 (내용을 출력하지 마세요 — 민감 정보 포함)
test -f ~/.config/msp/credential-broker.conf && echo "설정 파일 존재" || echo "설정 파일 없음"

# 5. BILLING_API_KEY 설정 확인 — env 또는 conf 파일 어느 쪽이든 OK (값을 출력하지 마세요 — API 키 노출 위험)
# billing-api.sh 는 env -> ~/.config/msp/credential-broker.conf 순으로 키를 해석합니다.
if [ -n "$BILLING_API_KEY" ] || grep -q '^BILLING_API_KEY=' ~/.config/msp/credential-broker.conf 2>/dev/null; then
  echo "BILLING_API_KEY 설정됨 (env 또는 conf)"
else
  echo "BILLING_API_KEY 미설정"
fi

# 6. 필수 도구 설치 확인
which aws jq python3 curl
```

하나라도 실패하면 작업을 중단하고 사용자에게 설정 안내를 제공하세요.

> **⚠️ 스크립트 경로 신뢰**: `credential_process`에 등록된 스크립트 경로가 지금 열린 tiket 워크스페이스(`git rev-parse --show-toplevel`)의 `skills/aws-customer-account-ops/` 이거나, 이전 설치 디렉터리(`~/.claude/skills/`, `~/.config/opencode/skills/`, `~/.kiro/skills/`, `~/.cursor/skills/`, `~/.codeium/windsurf/skills/`, `~/.augment/skills/`, `~/.agents/skills/`, `~/.gemini/skills/`, `~/.hermes/skills/`) 내에 위치하는지 확인하세요. 예상 밖의 경로에서 스크립트가 실행되는 경우, 사용자에게 경고 후 작업을 중단하세요.

> **⚠️ 중요 — Agent 먹통 방지**: `csg-login` marker 프로필은 login-only `get-sts-token.sh`를 `credential_process`로 가리키는 **경로 탐색 전용 앵커**입니다 — AWS 자격증명을 담지 않으며, 직접 자격증명 소스로 사용하지 마세요.
> 고객사 프로필의 `get-customer-credentials.sh`는 Bearer(로그인 토큰)가 없거나 만료되면 **즉시(<2초) 실패**하며 브라우저 OAuth를 띄우지 않습니다 — 더 이상 먹통이 되지 않습니다.
> 다만 로그인 자체(`get-sts-token.sh`)는 브라우저 Slack 인증을 띄우므로, **반드시 위 Prerequisites 3번 절차를 먼저 수행**하세요: `--check-only`로 토큰 유효성을 확인하고, 만료 시 `get-sts-token.sh`를 직접 실행하여 로그인을 완료한 뒤 AWS CLI 명령을 실행하세요.
> 이 앵커를 지키는 것은 **이름 규칙이 아니라 예약 목록**입니다: 고객사 이름이 `csg-` 네임스페이스로 들어오면서 `--account-name "Login"` 같은 입력이 `csg-login` 으로 파생될 수 있게 되었으므로, register 는 예약 프로필명(SKIP_PROFILES)에 걸리면 `reason=reserved-profile-name` 으로 **쓰기 전에** 중단합니다. 앵커가 고객사 프로필로 덮이는 경로는 없습니다.

## Workflow

### Step 1: 고객 식별

3가지 방법 중 상황에 맞는 것을 선택합니다.

> BILLING 호출은 `billing-api.sh` 래퍼를 통합니다. 래퍼가 API 키를 env 또는
> `~/.config/msp/credential-broker.conf` 에서 해석하므로 curl/Authorization 헤더를 직접 작성하지 않습니다.
> 아래 셸 블록에서 `SKILL_DIR`을 한 번 해석한 뒤 재사용하세요:
>
> ```bash
> SKILL_DIR=$(dirname "$(aws configure get profile.csg-login.credential_process 2>/dev/null)")
> ```

**방법 A — 회사명 검색:**

```bash
# 회사 검색
"$SKILL_DIR/billing-api.sh" GET "/api/admin/v1/companies" \
  | jq '.body[] | select(.corpName | test("검색어"; "i")) | {corpId, corpName}'

# 회사별 계정 조회
"$SKILL_DIR/billing-api.sh" GET "/api/admin/v1/companies/{corpId}/accounts" \
  | jq '.body[] | select(.deleteFlag == "0") | {accountName, accountId}'
```

**방법 B — 계정 ID로 검색:**

```bash
# 전체 계정에서 corpId 확인
"$SKILL_DIR/billing-api.sh" GET "/api/admin/v1/accounts" \
  | jq '.body[] | select(.accountId == "<ACCOUNT_ID>") | {corpId, accountName}'
```

**방법 C — 계정 이름 검색:**

```bash
# 계정명으로 검색하여 corpId 획득
"$SKILL_DIR/billing-api.sh" GET "/api/admin/v1/accounts" \
  | jq '.body[] | select(.accountName | test("검색어"; "i")) | {accountId, accountName, corpId, corpName}'
```

> **참고**: 브로커가 역할 타입을 **서버측에서** 해석하므로, 클라이언트는 `assume_role_type`를 조회할 필요가 없습니다 — 식별에는 `corpId`(빌링)와 12자리 `accountId`(브로커 전달)만 있으면 됩니다.

### Step 1.5: 다계정 범위 게이트

**계정이 2개 이상이면 항상** 이 게이트를 먼저 통과합니다. 브레이크가 걸리는 5계정 기준을 따로 계산하지 않습니다 — 습관을 하나로 유지하기 위해서이고, 미리 승인해 둔 배치는 도중에 브레이크를 만나지 않기 때문입니다. 대상에 **2개 이상의 corpId** 가 섞이면 **계정 수와 무관하게** 이 게이트를 통과합니다. **단일 계정이면 해당 없음** — 바로 Step 2 로 갑니다.

**1) 대상 계정 열거.** Step 1 의 BILLING 응답에 이미 들어 있는 값을 그대로 옮깁니다. 두 번째 조회를 하지 않습니다.

| accountId | accountName | corpName |
|---|---|---|
| <ACCOUNT_ID_1> | acme-production | 에이크미 |
| <ACCOUNT_ID_2> | beta-prod | 베타상사 |

**2) 한 줄 요약.** 형식은 `N계정 / M고객사` 입니다.

- `6계정 / 1고객사` — 한 고객사 안에서 계정을 여러 개 여는 경우
- `6계정 / 4고객사 — ⚠ 고객사 경계 교차` — M 이 2 이상이면 이 표시를 붙입니다

둘은 다른 사건입니다. 앞은 한 고객사에 대한 작업 규모이고, 뒤는 서로 다른 고객사의 데이터를 한 세션에서 다루는 일입니다.

**3) 의도 명시.** `수행할 작업:` 을 한 줄로 적습니다. 예: `수행할 작업: 각 계정의 EC2 인스턴스 목록과 상태 조회 (읽기 전용)`. 무엇을 할지 적지 않은 승인은 아무것도 승인하지 않은 것입니다.

**4) 승인, 그리고 기록.** 위 세 가지를 사용자에게 보여주고 **사용자 승인을 받은 뒤**, 승인된 범위를 스크립트에 기록합니다. `SKILL_DIR` / `$SkillDir` 은 Step 1 에서 이미 해석한 값을 그대로 재사용합니다.

**Linux / macOS:**

```bash
"$SKILL_DIR/get-customer-credentials.sh" scope-ack --account-ids <ACCOUNT_ID_1>,<ACCOUNT_ID_2>
```

**Windows PowerShell:**

```powershell
pwsh -NoProfile -File "$SkillDir\get-customer-credentials.ps1" scope-ack --account-ids <ACCOUNT_ID_1>,<ACCOUNT_ID_2>
```

stdout 은 정확히 한 줄입니다. 그 줄을 **그대로 인용해** 사용자에게 돌려주세요:

```
scope-ack: 2 accounts approved until 2026-08-26T12:34:56Z
```

인용된 이 줄이 게이트의 산출물입니다 — 문장이 아니라 호출이므로, 게이트를 건너뛴 사실은 대화 기록에 그대로 드러납니다. 승인은 **1시간** 유효하며 `--account-ids` 에 적은 계정만 덮습니다. 목록에 없는 계정은 승인 대상이 아닙니다. `--account-ids` 는 서로 다른 12자리 계정 **2개 이상**을 요구하므로, 1개만 넘기면 `[scope-ack] reason=invalid-arguments` 로 중단됩니다.

> **정직한 표기**: **이 게이트는 UX 이며 강제가 아닙니다.** 에이전트가 사용자에게 묻지 않고 스스로 `scope-ack` 를 호출하는 것도 기술적으로 가능합니다 — 알려진, 받아들인 성질입니다. 이 게이트가 만드는 것은 마찰과 대화 기록에 남는 흔적입니다. **결정론적 백스톱**은 스크립트의 fan-out 브레이크로, 300초 안에 승인되지 않은 서로 다른 계정 6개째의 신규 발급을 시도하면 `[scope] reason=fan-out-threshold` 를 stderr 에 찍고 exit 1 합니다. 권위 있는 기록은 브로커의 서버측 감사입니다.

> **경계**: `get-customer-credentials.{sh,ps1}` 는 서로 다른 `accountId` 의 개수만 셉니다. `corpId` 는 보지 않습니다 — 고객사 경계 규칙은 이 문서가 에이전트에게 주는 지시이지 클라이언트가 검사할 수 있는 것이 아닙니다. 클라이언트가 고객사 경계를 판정한다고 적는 문서는 거짓 보증입니다.

### Step 2: AWS CLI 프로필 생성

고객사 프로필은 `get-customer-credentials.{sh,ps1}` 의 **`register` 서브커맨드 단일 호출**로 생성합니다.
에이전트는 프로필명을 직접 계산하지 않고, 프로필에 대해 `aws configure set` 을 실행하지 않습니다.

register 가 한 번의 호출로 아래를 모두 수행합니다:

1. **프로필명 계산** — BILLING 의 `accountName` **원문 그대로**를 `--account-name` 으로 넘기면 스크립트가 이름 규칙(소문자화 → `[a-z0-9-]` 이외 문자를 하이픈으로 → 연속 하이픈 축약 → 앞뒤 하이픈 제거 → **마지막에 `csg-` 접두사 부착**)을 적용해 최종 이름을 만듭니다. 즉 이 프로젝트가 만드는 모든 고객사 프로필은 `csg-` 네임스페이스 안에 있습니다 — `Example-Dev` 는 `csg-example-dev` 가 됩니다. 이미 `csg-` 로 시작하는 이름을 넘겨도 접두사는 한 번만 붙습니다(`csg-csg-…` 가 되지 않으므로, 충돌 시 register 가 제시한 대체명을 **그대로** 재입력해도 안전합니다). 규칙 구현체는 스크립트 안 **한 곳**뿐이라 문서와 코드가 어긋날 수 없습니다. `--profile-name` 같은 플래그는 의도적으로 없습니다.
2. **중복·충돌 확인** — `aws configure list-profiles` 로 프로필을 열거하므로 `~/.aws/credentials` 에만 존재하는 프로필과 SSO 전용 프로필까지 보입니다. 열거가 실패하면(설정 파일 파싱 오류 등) "없음"으로 오해하지 않고 **아무것도 쓰지 않은 채 중단**합니다(fail-closed).
3. **소유권 판정 후 쓰기** — CSG 가 만든 프로필이면 멱등하게 갱신하고, 남의 프로필(SSO·정적 키·role chaining 등)이거나 같은 이름이 **다른 계정 ID** 에 묶여 있으면 기존 설정을 **한 바이트도 건드리지 않고 중단**한 뒤 stderr 로 충돌 대상과 대체 이름을 알려줍니다.

**프로필 생성 (assume_role_type 무관, 단일 형태):**

> 역할 이름·external-id·assume 타입은 이제 **브로커가 서버측에서 해석**하므로, 클라이언트는 조회하거나 지정하지 않습니다. 고객사 프로필은 **계정 ID만** 담은 단일 `credential_process` 형태로 등록되며, 그 문자열은 register 가 만듭니다.

> **🔒 read-only 서버측 강제**: 고객사 세션은 **브로커가 서버에서** `AssumeRole` 시 `ReadOnlyAccess`를 부착합니다 — 클라이언트는 더 이상 `--policy-arns`를 붙이지 않으며 프로필에는 계정 ID만 전달됩니다. 따라서 **고객사 역할에 AdministratorAccess가 부여되어 있어도 세션은 ReadOnlyAccess로 IAM 차원에서 차단**됩니다 (서버측 session policy 강제).
>
> ⚠️ 세션 최대 수명은 **1시간**입니다. 만료 시 `get-customer-credentials.sh`가 자동으로 재발급합니다.

**Linux / macOS:**

```bash
SKILL_DIR=$(dirname "$(aws configure get profile.csg-login.credential_process 2>/dev/null)")

# 성공 시 stdout 1줄이 생성된 프로필명이므로 그대로 변수로 받습니다.
# 위 예시에서 PROFILE_NAME 은 csg-example-dev 가 됩니다 (csg- 네임스페이스).
PROFILE_NAME=$("$SKILL_DIR/get-customer-credentials.sh" register --account-id <ACCOUNT_ID> --account-name "Example-Dev" --corp-name "Example Corp")
```

**Windows PowerShell:**

```powershell
$SkillDir = Split-Path (aws configure get profile.csg-login.credential_process 2>$null) -Parent

# 성공 시 stdout 1줄이 생성된 프로필명이므로 그대로 변수로 받습니다.
# 위 예시에서 $ProfileName 은 csg-example-dev 가 됩니다 (csg- 네임스페이스).
$ProfileName = pwsh -NoProfile -File "$SkillDir\get-customer-credentials.ps1" register --account-id <ACCOUNT_ID> --account-name "Example-Dev" --corp-name "Example Corp"
```

- `--account-id` (필수) 12자리 계정 ID, `--account-name` (필수) BILLING 계정명 원문, `--corp-name` (선택) 회사명 — **충돌 시 대체 이름을 더 구체적으로 만드는 데만** 쓰입니다.
- 위 `SKILL_DIR` 산출은 **스크립트 위치를 찾기 위한 것**이며, `credential_process` 문자열 자체는 register 가 자기 실행 경로에서 직접 만듭니다. 그래서 `csg-login` marker 가 없어 `SKILL_DIR` 이 비면 상대 경로가 config 에 구워지는 대신 "파일을 찾을 수 없음"으로 **즉시 시끄럽게 실패**합니다.

**호출 결과 판정:**

| 결과 | exit | stdout | stderr |
|------|------|--------|--------|
| 성공(신규 생성 또는 갱신) | 0 | 프로필명 **정확히 1줄** | 진행 상황 |
| 중단(충돌·입력 오류·설정 파싱 실패) | 1 | **완전히 빈 값** | 첫 줄이 `[register] reason=<토큰>`, 이어서 충돌 대상과 대체 이름 |

stderr 의 `reason=` 토큰을 그대로 사용자에게 보고하세요. 임의로 `aws configure set` 을 써서 우회하지 마세요 — register 가 막은 이유가 곧 사고 방지입니다.

중단은 두 부류이며 **`~/.aws/config` 상태가 다릅니다**:

- **쓰기 전 중단** — `foreign-profile`, `account-mismatch`, `contaminated-hybrid`, `unknown-profile`, `reserved-profile-name`, `config-unparseable`, `invalid-*`. `~/.aws/config` 는 **한 바이트도 변경되지 않습니다**. 충돌 계열이면 register 가 제안한 대체 이름으로 재시도하세요.
- **쓰기 중/후 중단** — `write-failed`, `postcondition-failed`. **config 는 이미 변경된 상태**이므로 "아무것도 바뀌지 않았습니다" 라고 보고하면 안 됩니다. 마커를 먼저 쓰기 때문에 부분 기록된 섹션은 credential 해석에 관여하지 않으며, 원인을 해결한 뒤 **같은 명령을 다시 실행하면 멱등 재등록 경로로 수렴**합니다.

> 💡 여러 계정을 다룰 때는 먼저 **Step 1.5 의 범위 게이트**를 통과하고, Step 3 의 직렬 규칙에 따라 **한 번에 한 계정씩** 진행합니다. auto-sweep은 credential 캐시 파일이 아직 없는(= 한 번도 사용 안 한) never-used 프로필을 삭제하지 않으므로(T-oro-01), 다른 프로필을 조회하는 동안 아직 사용하지 않은 프로필이 사라지지 않습니다. 이 보장은 **프로필의 수명**에 대한 것이지, 다계정 배치를 시작해도 된다는 허가가 아닙니다.

> **🧭 감사 주체(agent) 자동 감지**: register 가 굽는 `credential_process` 에는 **`--account-id` 만** 들어가고 `--agent` 는 들어가지 않습니다 — 설계된 성질입니다. `--agent` 가 프로필에 박히면 감사 주체가 **프로필을 만든 에이전트로 고정**되어, 그 프로필을 공유하는 다른 에이전트의 호출까지 전부 생성자로 오귀속됩니다. `--agent` 가 없으므로 `get-customer-credentials.{sh,ps1}` 가 **실행 시점 환경**에서 실제 호출 에이전트를 자동 감지합니다(우선순위: `MSP_AGENT`(명시적 override) → `AI_AGENT`(첫 `_` 앞 토큰)/`CLAUDECODE`(Claude Code) → `TERM_PROGRAM`/`__CFBundleIdentifier`(Kiro 등 커스텀 변수를 안 넣는 VSCode 계열 에이전트, 9개 CSG 에이전트 id만 인정) → 설치 경로 폴백). 특정 라벨로 강제하려면 세션에서 `export MSP_AGENT=<name>` (PowerShell은 `$env:MSP_AGENT="<name>"`)만 설정하세요.

> **✅ 감지된 agent 의 노출 경로 — 사내 감사 로그로 한정됨 (해소됨)**: 감지된 `agent` 는 **더 이상 고객사 CloudTrail 에 노출되지 않습니다.** 브로커가 각인하는 `RoleSessionName` 은 `msp-ai@{slackUserId}` 이며, 여기에는 agent 토큰이 **없습니다**. 고객사가 자사 CloudTrail 에서 보는 것은 MSP 파트너 이름과 불투명한 Slack user ID 뿐입니다.
>
> 감지된 agent 값은 **브로커의 사내 CloudWatch 감사 로그**(`/aws/lambda/crossaccount-credential-broker` 의 `event: audit` 라인, `agent` 필드) 에만 남습니다. 즉 도구 정체는 없어진 것이 아니라 **고객 대면 채널에서 사내 채널로 이동**했습니다. 그 대가로 감사 Slack 메시지의 `*Agent:*` 필드는 신 문법 세션에서 `unknown` 으로 보입니다 — 정상 동작이며, 조회는 위 로그 그룹에서 합니다.
>
> **이 변경의 계기**: 2026-08-20, 고객사가 자사 CloudTrail 의 `claude-code` 문자열을 보고 **"ClaudeCode가 누구입니까"** 라고 문의했고, 담당자는 조회 내역을 설명하기 전에 그것부터 해명해야 했습니다. AI 도구 사용을 사전에 고지받지 못한 고객사에서는 그 값 하나가 보안 문의를 촉발했습니다. 세션명이 한눈에 **MSP 파트너**를 말하도록 형식을 바꾼 이유가 이것입니다.
>
> 세션명에 **실명**이나 이메일을 넣는 안은 검토 후 기각되었습니다 — 고객사 CloudTrail 은 MSP 회사가 통제할 수도 삭제할 수도 없는 제3자의 **불변** 로그 저장소이므로, 거기에 직원 개인정보를 남기면 보관 기간을 한정할 수도 이후에 회수할 수도 없기 때문입니다. Slack user ID 는 고객사 입장에서 **불투명(opaque)** 하면서도 사내 역조회로 귀속이 가능한 값이라 그대로 남습니다. `msp-` 접두사는 **동결**된 공개 계약이며, 고객사 trust policy 가 `msp-*` 조건으로 이를 직접 검증합니다.
>
> **행동 지침**: 그래도 문의를 받은 뒤에 대응하지 말고, 광범위한 조회를 시작하기 **전에** 고객사 보안 담당자에게 고지 문서를 먼저 전달합니다. MSP 회사 저장소의 `docs/customer/msp-ai-access-disclosure.md` 에 세션명 해독법, 서버측 IAM read-only 강제, 고객사가 자사 trust policy 로 직접 검증하는 조건이 정리되어 있습니다. 이 문서는 스킬 패키지에 포함되지 않고 저장소(README 안내)에만 있으므로, 링크를 거는 대신 위 경로의 문서를 찾아 전달하세요.

> **기존 프로필 마이그레이션**: `source_profile`/`role_arn` 방식 또는 구버전 인자로 등록된 기존 프로필이 있다면 **같은 `register` 호출을 다시 실행**하면 됩니다 — CSG 소유로 판정되는 프로필은 멱등하게 갱신됩니다. 정상 상태는 `credential_process` 가 `get-customer-credentials.sh --account-id <id>` 형태이고 `source_profile` 이 없는 것입니다. (설치 관리자가 업그레이드 시 구 프로필을 자동 정리합니다.) 재실행이 충돌로 중단되면 그 프로필은 CSG 소유가 아니므로 stderr 안내를 따르세요.

### Step 3: 읽기 전용 명령 실행

프로필이 생성되면 `--profile ${PROFILE_NAME}`으로 AWS CLI 명령을 실행합니다.

```bash
# 예: EC2 인스턴스 조회
aws ec2 describe-instances --profile ${PROFILE_NAME} \
  --query 'Reservations[].Instances[].{Id:InstanceId,Type:InstanceType,State:State.Name}' \
  --output table

# 예: S3 버킷 목록
aws s3api list-buckets --profile ${PROFILE_NAME} --output table
```

#### 다계정 순회 규칙 (직렬 · 첫 실패 중단)

Step 1.5 의 승인을 받은 뒤에는 **한 번에 한 계정씩** 진행합니다. 도구가 동시 실행을 허용하더라도 팬아웃하지 않습니다 — 동시 호출도 브레이크의 카운터에는 그대로 쌓이지만 "동시라서" 거부되지는 않으므로, 팬아웃은 깔끔한 에러 대신 설명되지 않는 거부를 만듭니다.

**exit code 가 0 이 아니면 즉시 중단** 합니다. 이 한 문장이 브로커 4xx/5xx, `credential_process` 비정상 종료, AWS CLI 비정상 종료(AccessDenied·Throttling 등)를 모두 덮습니다. 다음 계정으로 넘어가지 않습니다.

**결과 0건은 실패가 아닙니다** — 비어 있는 조회 결과도 결과이므로 그대로 기록하고 다음 계정으로 계속합니다.

중단했다면 아래를 한 번에 보고합니다:

- 실패한 계정의 `accountId` / `accountName` / `corpName` (Step 1.5 열거 표와 같은 형태)
- 실패 원인은 **stderr 원문 그대로** — 요약하거나 의역하지 않습니다
- **완료 계정 목록** — 조회를 이미 마친 계정
- **미처리 계정 목록** — 아직 시작하지 않은 계정

사용자는 이 보고만 보고 계속할지 멈출지 정합니다(두 번째 조회가 필요 없어야 합니다). 계속하기로 하면, 남은 계정이 아직 만료되지 않은 승인 집합의 부분집합인 한 **재-ack 없이 이어서 진행** 합니다. 승인이 **만료된 경우에만 다시 승인**을 받습니다(유효 기간 1시간). 같은 목록을 두 번 승인시키지 마세요.

## Read-Only Policy

**필수 준수**: 읽기 전용 AWS CLI 명령만 실행합니다.

이 정책은 **3중 방어선**으로 보장됩니다:

1. **IAM 세션 정책 (1차, 강제 · 서버측)** — 고객사 세션은 **브로커가 서버에서** `AssumeRole` 시 `ReadOnlyAccess`를 부착합니다 (클라이언트는 더 이상 `--policy-arns`를 붙이지 않습니다). 세션 정책은 역할 권한과 **교집합**으로 작동하므로, 고객사 역할에 AdministratorAccess가 있어도 세션은 ReadOnlyAccess로 제한됩니다 (AWS API가 직접 차단).
2. **프롬프트 화이트리스트 (2차)** — 아래 [Resource Query Read-Only Policy](#resource-query-read-only-policy) 섹션의 9개 접두사 화이트리스트로 사전 필터링.
3. **사용자 컨펌 (3차)** — 모호하면 실행 전 사용자에게 확인.

> **⚠️ 3중 방어선이 덮지 않는 것 — 탐지 리스크**: 위 세 겹은 **변경 리스크**, 즉 고객사 리소스가 실제로 바뀌는 사고를 막는 데까지만 작동합니다. 조회 행위가 고객사 눈에 어떻게 보이는지 — **탐지 리스크** — 에 대해서는 아무 보호도 제공하지 않습니다.
>
> 읽기 전용이더라도 **다수 계정에 대한 단시간 연속 조회**는 고객사 SIEM·GuardDuty 관점에서 **정찰(reconnaissance)** 과 구분되지 않습니다. 탐지 규칙은 호출자의 권한이 아니라 **호출 패턴**으로 판정합니다. 이것은 가정이 아니라 관측된 사실입니다 — read-only 강제가 완벽히 작동한 접근에서도 고객사가 이를 침해로 인식하고 보안 문의를 제기한 사례가 있었습니다(경위는 Step 2 의 agent 노출 경고를 참조하세요).
>
> 그러므로 **조회 범위를 최소화**하고, 광범위한 조회가 필요하면 **사전에 고지**합니다. 이 리스크에 대한 이 저장소의 구체적인 답은 주의 문구가 아니라 **`Step 1.5` 다계정 범위 게이트**입니다 — 대상 계정 열거 → `N계정 / M고객사` 한 줄 요약 → 의도 명시 → 사용자 승인 후 `scope-ack` 기록. 계정이 2개 이상이면 예외 없이 이 게이트를 먼저 통과하세요.

---

## Billing Workflow (AWS 계정 접근 불필요)

고객사 비용/청구 관련 질문은 AWS 계정에 접근하지 않고 BILLING 빌링 API만으로 처리할 수 있습니다.
**프로필 생성 없이** Step 1(고객 식별) → 빌링 API 호출로 바로 진행합니다.

> 빌링 데이터가 필요할 때 이 워크플로우를 우선 사용하고, AWS 리소스 상세 조회가 추가로 필요한 경우에만 위의 Step 2~3을 진행하세요.

### Billing Step 1: 고객 식별 (기존 Step 1과 동일)

위 Workflow의 Step 1을 따라 `corpId`를 획득합니다.

### Billing Step 2: 비용/청구 데이터 조회

> 아래 호출도 `billing-api.sh` 래퍼를 사용합니다. `SKILL_DIR`이 현재 셸에 없으면 한 번 해석하세요:
> `SKILL_DIR=$(dirname "$(aws configure get profile.csg-login.credential_process 2>/dev/null)")`

**월별 OnDemand 비용 조회:**

```bash
"$SKILL_DIR/billing-api.sh" POST "/api/v1/costs/ondemand/corp/monthly" \
  '{"from": "202604", "to": "202604", "corpId": "'${CORP_ID}'"}' \
  | jq '[.body[] | {serviceName, usageFee}] | group_by(.serviceName) | map({service: .[0].serviceName, total: (map(.usageFee) | add)}) | sort_by(-.total) | .[:10]'
```

**월별 인보이스 조회:**

```bash
"$SKILL_DIR/billing-api.sh" POST "/api/v1/invoice/corp/monthly" \
  '{"billingPeriod": "202604", "corpId": "'${CORP_ID}'"}' \
  | jq '.body[] | {invoiceDivision, invoiceItem, usageFee, usageFeeKrw, currencyCode}'
```

**RI/SP/CF 할인 내역 조회:**

```bash
"$SKILL_DIR/billing-api.sh" POST "/api/v1/costs/savings/corp/monthly" \
  '{"from": "202601", "to": "202606", "corpId": "'${CORP_ID}'"}' \
  | jq '{
    ondemand_trend: [.body.ondemands[] | {month: .billingPeriod, usd: .usageFee}],
    ri_total: ([.body.reservationInstances[].usageFee] | add // 0),
    sp_total: ([.body.savingsPlans[].usageFee] | add // 0),
    cf_total: ([.body.cloudfronts[].usageFee] | add // 0)
  }'
```

**하루 단위·발생 서비스별 사용량 (예: Data Transfer 가 어느 서비스에서 났나):**

비용 경로는 Data Transfer 를 `serviceCode: AWSDataTransfer` 한 줄로 묶는다. 발생 서비스는 이 경로의 `productCode` 로만 갈린다 — 내부 부서로 넘기기 전에 먼저 본다.

```bash
"$SKILL_DIR/billing-api.sh" POST "/api/v1/usage/ondemand/daily" \
  '{"from": "20261022", "to": "20261022", "corpId": "'${CORP_ID}'"}' \
  | jq '[.body[] | select(.serviceCode == "AWSDataTransfer")] | group_by(.productCode) | map({productCode: .[0].productCode, usd: (map(.onDemandCost | tonumber) | add)}) | sort_by(-.usd)'
```

**전체 청구 요약 (MSP 회사 관리자 전용):**

```bash
"$SKILL_DIR/billing-api.sh" GET "/api/admin/v1/invoices/monthly-summary?billingMonth=202604"
```

### Billing Step 3: 결과 분석 및 보고

조회 결과를 바탕으로:
1. **서비스별 비용 Top 10** — OnDemand 비용을 서비스별로 집계하여 상위 항목 파악
2. **월별 비용 추이** — `from`/`to` 기간을 넓혀 증감 추세 분석
3. **할인 효과 분석** — RI/SP/CF 할인이 전체 비용 대비 얼마나 절감되었는지 계산
4. **인보이스 상세** — 청구 항목별 금액과 원화 환산액 정리

> 상세 스키마 및 응답 필드는 [reference/billing-api.md](../../../skills/aws-customer-account-ops/reference/billing-api.md)의 빌링/비용 엔드포인트 섹션을 참조하세요.

---

## Resource Query Read-Only Policy

**입력값 검증**: API 응답에서 가져온 값(accountId, corpId, accountName 등)을 셸 명령에 사용하기 전에 반드시 검증합니다.

```bash
# accountId: 12자리 숫자만 허용
[[ "$ACCOUNT_ID" =~ ^[0-9]{12}$ ]] || { echo "유효하지 않은 계정 ID" >&2; exit 1; }

# corpId: 영숫자만 허용
[[ "$CORP_ID" =~ ^[a-zA-Z0-9-]+$ ]] || { echo "유효하지 않은 Corp ID" >&2; exit 1; }
```

> 프로필명은 검증 대상이 아닙니다 — 에이전트가 만들지 않기 때문입니다. `accountName` 원문을 `register --account-name` 으로 넘기면 스크립트가 정규화하고, 정규화 결과가 legal 한 프로필명이 아니면 `reason=invalid-account-name` 으로 중단합니다.

**STRICT WHITELIST**: 다음 9개 접두사로 시작하는 액션만 실행 허용합니다.

- `Describe`, `Get`, `List`, `Query`, `Scan`
- `Lookup`, `Search`, `Check`, `Head`

**그 외 모든 액션은 무조건 거부**하고 사용자에게 보고하세요.
`Create`/`Delete`뿐 아니라 `Purchase`, `Authorize`, `Accept`, `Associate`, `Attach`, `Allocate`, `Enable`, `Disable`, `Register`, `Provision`, `Restore`, `Copy`, `Import`, `Export`, `Replace`, `Reset`, `Revoke`, `Detach`, `Move`, `Run`, `Invoke`, `Send`, `Put`, `Update`, `Modify`, `Remove`, `Terminate`, `Stop`, `Start`, `Reboot`, `Bundle`, `Confirm`, `Submit` 등 변경·과금·권한·보안에 영향을 주는 모든 동사가 차단 대상입니다. 위 화이트리스트에 명시되지 않은 모든 접두사는 차단으로 간주하세요.

> **차단 대상은 AWS API 액션 접두사입니다.** 위 목록의 `Register` 는 `RegisterInstance`·`RegisterTargets` 같은 **AWS API 액션**을 가리킵니다. 로컬 스크립트 서브커맨드인 `get-customer-credentials.{sh,ps1} register` 는 여기에 해당하지 않으며, AWS 리소스를 전혀 건드리지 않고 로컬 `~/.aws/config` 만 다룹니다 — Step 2 의 **필수 절차**이므로 금지 동사로 오인해 거부하지 마세요.

⚠️ **중요**: 일부 고객 계정은 CrossAccount Role에 `AdministratorAccess`가 부여되어 있지만, 브로커가 모든 고객사 세션을 **서버측에서** `ReadOnlyAccess`로 발급하므로 IAM이 자동 차단합니다. 클라이언트는 privileged 크레덴셜을 쥐지 않으므로 이 보호를 우회할 경로가 없습니다.

**프로필 쓰기 경로**: 프로필 생성·수정은 오직 `get-customer-credentials.{sh,ps1} register` 를 통해서만 합니다. 프로필에 대한 직접 `aws configure set` 은 허용되지 않습니다 — register 가 내부적으로 무엇을 호출하든 그것은 구현 세부사항이지 에이전트에게 주어진 권한이 아닙니다. register 가 충돌로 중단했을 때 `aws configure set` 으로 같은 결과를 만들어내는 것은 이 규칙의 정면 위반입니다.

명령 실행 전 반드시 액션명의 접두사를 화이트리스트와 대조하세요. 확실하지 않으면 실행하지 마세요.

## Best Practices

1. **프로필 재사용**: 사전 확인 없이 그냥 `register` 를 호출하세요. register 는 **멱등**입니다 — 이미 CSG 소유로 등록된 같은 계정이면 조용히 갱신하고 같은 프로필명을 출력합니다. 중복 여부를 미리 확인할 필요가 없고, 충돌이 있으면 register 가 탐지해 보고합니다.
2. **삭제된 계정 필터링**: 항상 `deleteFlag == "0"` 조건으로 필터링
3. **프로필명 충돌**: 대체명을 직접 조립하지 마세요. 충돌 시 register 가 `csg-{회사명}-{계정명}` 형식의 대체명과 **그대로 실행 가능한 재시도 명령**을 stderr 에 직접 제시하므로, 그 명령을 사용자에게 보고하고 실행하면 됩니다 (`--corp-name` 을 함께 넘기면 더 구체적인 대체명이 나옵니다).
4. **리전 지정**: 글로벌 서비스(IAM, S3, Route53) 외에는 필요한 리전을 `--region`으로 명시
5. **출력 포맷**: 사용자에게 보여줄 때는 `--output table`, 파싱할 때는 `--output json`
6. **AWS 문서 참조**: [AWS Agent Toolkit](https://github.com/aws/agent-toolkit-for-aws) 활용 가능 — AWS 공식 문서 검색, 읽기 전용 API 호출, 리전별 서비스 가용성 확인
7. **AWS API 직접 호출**: CLI가 부적합한 경우 AWS Agent Toolkit의 읽기 전용 API 호출 기능 활용

## Common Issues

**"Agent가 AWS 명령 실행 후 먹통/응답 없음"**
→ STS 토큰이 만료된 상태에서 AWS CLI가 `credential_process`(Slack OAuth)를 실행하여 브라우저 인증을 기다리는 중입니다. 작업 전 반드시 Prerequisites 3번 절차를 수행하세요: `--check-only`로 확인 후, 만료 시 에이전트가 직접 `get-sts-token.sh`를 실행하여 브라우저를 띄우세요. 브라우저를 띄울 수 없는 환경(SSH 등)이면 사용자에게 터미널에서 직접 실행하도록 안내하세요.

**"csg-login marker 프로필을 찾을 수 없음"**
→ `aws configure get profile.csg-login.credential_process 2>/dev/null`로 확인. 없으면 설치 관리자(`install.sh`/`install.ps1`)를 재실행해 csg-login marker를 생성하세요. 이 marker는 login-only `get-sts-token`을 가리키는 SKILL_DIR 경로 탐색 전용 앵커입니다(AWS 자격증명 없음).

**"Slack 인증 실패 / 브라우저 안 열림"**
→ Slack 인증 설정 확인: `~/.config/msp/credential-broker.conf` 파일 존재 및 API_URL/CLIENT_ID 값 확인. SSH 환경에서는 `get-sts-token.sh --no-browser` 사용.

**"고객사 자격증명 발급 실패 (get-customer-credentials)"**
→ 브로커가 역할/external-id/타입을 서버측에서 해석하므로, 실패는 브로커 HTTP 응답(403 인가 거부, 400 잘못된 accountId 등)으로 표면화됩니다. stderr의 서버 메시지를 그대로 확인하세요. Bearer(로그인 토큰)가 없거나 만료됐으면 먼저 `get-sts-token.sh`로 로그인하세요.

**"AccessDenied 에러"**
→ 브로커가 서버측에서 해석한 cross-account 역할이 대상 계정에 존재하는지, 신뢰 정책이 올바른지 고객사에 확인 요청.

**"프로필명 충돌" (`reason=foreign-profile` / `account-mismatch` / `contaminated-hybrid` / `unknown-profile`)**
→ register 가 기존 프로필을 **건드리지 않고 중단**한 상태입니다. 에이전트가 이름을 새로 지어내지 말고, stderr 에 register 가 제시한 `csg-{회사명}-{계정명}` 대체명과 재시도 명령을 그대로 쓰세요. 예: `csg-acme-production`. 대체명은 `--account-name` 으로 넘기며(`--profile-name` 플래그는 없습니다), `--corp-name` 을 함께 주면 더 구체적인 대체명이 제안됩니다. `aws configure set` 으로 기존 프로필을 덮어쓰는 것은 금지입니다 — 남의 SSO 프로필이나 다른 고객사 계정을 가리키는 프로필을 지우게 됩니다.

**"BILLING API 401 Unauthorized"**
→ BILLING API 키는 `billing-api.sh` 래퍼가 env(`BILLING_API_KEY`) → `~/.config/msp/credential-broker.conf`(`BILLING_API_KEY=` 라인) 순으로 해석합니다. 환경변수를 설정했거나 conf 파일에 `BILLING_API_KEY=` 라인을 추가했는지 확인하세요(conf 파일은 `chmod 600`). 만료된 키일 수 있음.

**"ExpiredToken / ExpiredTokenException"**
→ 로그인 세션 만료. `get-sts-token.sh --clear-cache` 실행 후 재인증. 스크립트 경로는 `aws configure get profile.csg-login.credential_process`로 확인.

**"고객사 프로필이 ReadOnly 제약 없이 동작함 (구버전 프로필)"**
→ `aws configure get profile.${PROFILE_NAME}.credential_process` 결과를 확인하세요. `get-customer-credentials` 가 포함되지 않거나, 대신 `source_profile`/`role_arn` 키만 설정되어 있다면 브로커를 거치지 않아 서버측 ReadOnly 강제가 적용되지 않는 구버전입니다. Step 2 의 `register` 호출을 같은 계정으로 다시 실행해 **재등록**하세요. 재등록이 충돌로 중단되면 그 프로필은 CSG 소유가 아니라는 뜻이므로 덮어쓰지 말고 stderr 안내를 따르세요.

**"AccessDenied — 읽기 명령인데도 거부됨"**
→ 고객사 역할 자체가 ReadOnlyAccess 미만일 수 있습니다 (예: 특정 서비스만 허용). 세션 정책은 역할 권한을 확장하지 못하므로(intersection only), 이 경우는 정상 동작입니다. 고객사에 권한 확인 요청.

**"고객사 세션이 1시간만 유지됨 / 작업 중 만료"**
→ Role chaining 제약(AWS 강제, 우회 불가). `get-customer-credentials.sh`가 자동 재발급하므로 동일 명령을 다시 실행하면 됩니다. 장시간 작업은 명령을 분할하세요.

**"프로필을 방금 만들었는데 다음 명령에서 사라짐 / `~/.aws/config`에서 자동 삭제됨"**
→ Phase 11 도입 이전 회귀 패턴. v1.4 이후 `get-customer-credentials.sh`/`.ps1`는 매 호출 시 만료된 CSG 프로필을 자동 정리하는데(D-01), 다음 두 단계로 신규 프로필을 보호합니다: (1) **PROF-06** — 자신을 호출한 프로필은 sweep 대상에서 제외, (2) **never-used 보호(T-oro-01)** — credential 캐시 파일이 **아직 존재하지 않는**(= 한 번도 사용 안 한) 프로필은 절대 sweep하지 않음. sweep은 캐시 파일이 **존재하면서 만료된** 경우에만 동작합니다. 이 항목은 **증상**을 설명할 뿐이며 다계정 승인 요건과는 무관합니다 — 계정 2개 이상 작업은 Step 1.5 의 범위 게이트를 먼저 통과합니다. 그래도 사라진다면: (1) 클라이언트 스크립트가 패치 이전 버전인지 확인 — `grep "T-oro-01" $(which get-customer-credentials.sh)` 로 식별, (2) 패치 이전이면 tiket 워크스페이스에서 `git pull` 후 에이전트 세션을 새로 시작. 임시 우회가 필요하면 환경변수(`AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY`/`AWS_SESSION_TOKEN`)로 호출하거나 `cleanup --all`로 정리 후 Step 2 의 `register` 호출을 다시 수행하세요.

**"자격증명 발급이 갑자기 exit 1 / stderr 첫 줄이 `[scope] reason=fan-out-threshold`"**
→ 브로커 장애도 자격증명 실패도 아니라 **fan-out 브레이크**입니다. 300초 안에 승인되지 않은 서로 다른 계정 6개째의 신규 발급을 시도했다는 뜻입니다. stdout 은 건드리지 않으므로 5-키 JSON 계약은 그대로이고, 거부 메시지의 **마지막 stderr 줄이 그대로 붙여 쓸 수 있는 재시도 명령**입니다. Step 1.5 로 돌아가 대상 계정을 열거하고 사용자 승인을 받은 뒤 `scope-ack --account-ids <id,id,...>` 를 실행하고 재시도하세요. 이미 승인된 계정은 카운트에서 면제되지만 승인 목록 밖의 계정은 면제되지 않습니다. `scope-ack` 는 브레이크를 끄는 스위치가 아니라 **승인 범위를 기록하는 수단**입니다.

**"`scope-ack` 이 `[scope-ack] reason=invalid-account-id` / `[scope-ack] reason=invalid-arguments` / `[scope-ack] reason=write-failed` 로 중단됨"**
→ 토큰마다 원인과 후속 조치가 다릅니다.
- `invalid-account-id` — 12자리 숫자가 아닌 id 가 섞였습니다. 승인 기록은 남지 않았으므로 목록을 고쳐 다시 실행하면 됩니다.
- `invalid-arguments` — `--account-ids` 값이 없거나, 중복을 제거한 뒤 서로 다른 계정이 2개 미만입니다. 계정이 하나뿐이라면 애초에 게이트 대상이 아니니 Step 2 로 진행하세요.
- `write-failed` — **승인 기록 파일 쓰기 자체가 실패했으므로 승인은 적용되지 않았습니다.** 이 상태로 배치를 시작하면 6번째 계정에서 브레이크에 걸립니다. 디스크 여유 공간과 `~/.cache/msp/customer-creds` 디렉터리 권한을 확인한 뒤 같은 명령을 다시 실행하고, `scope-ack:` 로 시작하는 stdout 한 줄을 확인한 다음에 진행하세요.

## References

상세 문서:

- [reference/billing-api.md](../../../skills/aws-customer-account-ops/reference/billing-api.md) — BILLING API 엔드포인트 및 응답 스키마 (계정/회사 조회 + 빌링/비용 조회)
- [reference/aws-profile-creation.md](../../../skills/aws-customer-account-ops/reference/aws-profile-creation.md) — `register` 기반 프로필 생성 절차, 이름 규칙의 서술적 설명, `csg-login` marker 설정, 생성 후 수동 검증
- [reference/troubleshooting.md](../../../skills/aws-customer-account-ops/reference/troubleshooting.md) — 일반적인 에러 및 해결 방법
- `docs/customer/msp-ai-access-disclosure.md` — 고객사 보안 담당자용 접근 고지 (세션명 해독법, 서버측 IAM read-only 강제, trust policy 자가 검증 조건). 위 항목들과 달리 스킬 패키지에 함께 배포되지 않고 **MSP 회사 저장소에만** 있어 링크가 아닌 경로로 표기합니다.

실전 예제:

- [examples/ec2-instance-query.md](../../../skills/aws-customer-account-ops/examples/ec2-instance-query.md) — EC2 인스턴스 조회
- [examples/s3-bucket-investigation.md](../../../skills/aws-customer-account-ops/examples/s3-bucket-investigation.md) — S3 보안 감사
- [examples/cost-optimization-consulting.md](../../../skills/aws-customer-account-ops/examples/cost-optimization-consulting.md) — Secrets Manager & API Gateway 비용 최적화 컨설팅
- [examples/billing-cost-analysis.md](../../../skills/aws-customer-account-ops/examples/billing-cost-analysis.md) — 고객사 월별 비용 조회 및 인보이스 분석 (빌링 API)
- [examples/savings-report.md](../../../skills/aws-customer-account-ops/examples/savings-report.md) — RI/SP/CF 할인 현황 분석 (빌링 API)
