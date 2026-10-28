# Secrets Manager & API Gateway 비용 최적화 컨설팅

> 사용자 요청: "샘플고객 고객사에서 아래와 같은 문의사항이 왔는데 AWS 계정을 조회하고 문의사항에 대한 내용을 검토해주세요."

## 시나리오

고객사 "(주)샘플고객"로부터 Secrets Manager API 및 API Gateway 비용 급증에 대한 최적화 문의를 받아,
AWS 계정의 리소스 현황을 분석하고 최적화 방안을 정리하여 고객사 전달용 이메일 답변을 작성하는 전체 흐름.

이 예제는 단순 리소스 조회를 넘어, **CloudWatch 메트릭 분석 → 비용 추정 → 아키텍처 최적화 제안 → 고객 답변 작성**까지 이어지는 종합 컨설팅 케이스를 보여준다.

---

## 전체 대화 흐름

```
사용자 프롬프트 1: 고객 문의 전달 + AWS 계정 조회 및 검토 요청
  → 고객 식별, 프로필 생성, 리소스 조회, 메트릭 분석, 종합 보고서 작성

사용자 프롬프트 2: "Secret manager도 3월에 비해 많이 증가했는데 최적화 방안이 있을까요"
  → Lambda 동시성 메트릭 추가 조회, SM 비용 증가 원인 심층 분석, 추가 최적화 방안 제시

사용자 프롬프트 3: "이 내용이랑 아까 답변해준 내용이랑 같이 정리해서 고객사 답변용으로 만들어줘"
  → 이메일 본문 형태, 공식적 톤으로 통합 작성

사용자 프롬프트 4: "비용 부분에 대한 내용은 민감하니 제거해주고, 너무 AI스러운 말투랑 문장만 제거해주세요"
  → 비용 수치 제거, 자연스러운 문체로 수정

사용자 프롬프트 5: "고객사한테 전달해줄 참고할만한 공식 문서나 repost 글 없을까?"
  → AWS 공식 문서/블로그/re:Post URL 수집, 검증, 주제별 정리

사용자 프롬프트 6: "표로 만든것들 전부 zendesk markdown 규격에 맞게 고쳐줘. 메일 하단에 참고문서 항목도 포함, 문서 제목도 포함"
  → Zendesk markdown 규격(파이프 테이블 미지원) 확인 후, 리스트/볼드 형태로 전체 재작성
```

---

## Step 1 — 고객사 식별

### 사용자 프롬프트

```
샘플고객 고객사에서 아래와 같은 문의사항이 왔는데 AWS 계정을 조회하고 문의사항에 대한 내용을 검토해주세요.

최근 저희 유저가 많이 늘어 Secret manager API 및 API 게이트웨이 관련 비용이 빠르게 증가하고 있습니다.
이에 따라 관련 부분 최적화 관련해서 문의드리고자 하는데요, Secret manager의 경우 RDS 데이터베이스를
Lambda function에서 조회할 때 사용되어 많은 사용량이 발생하는 것 같고, API 게이트웨이의 경우 호출 빈도가
너무 높아 사용량이 많이 발생하는 것 같습니다.

업계에서 사용하는 최적화 방법론 혹은 관련 컨설팅을 받고 싶은데요. 혹시 가능할까요?
```

### 에이전트 동작

회사명 "샘플고객"로 BILLING API 검색 (`billing-api.sh` 래퍼가 API 키를 env 또는 conf에서 해석):

```bash
SKILL_DIR=$(dirname "$(aws configure get profile.csg-login.credential_process 2>/dev/null)")

"$SKILL_DIR/billing-api.sh" GET "/api/admin/v1/companies" \
  | jq '.body[] | select(.corpName | test("샘플고객"; "i")) | {corpId, corpName}'
```

응답:
```json
{
  "corpId": "00000000-0000-0000-0000-00000000000b",
  "corpName": "(주)샘플고객"
}
```

## Step 2 — 계정 조회

corpId로 회사별 계정 조회:

```bash
"$SKILL_DIR/billing-api.sh" GET "/api/admin/v1/companies/00000000-0000-0000-0000-00000000000b/accounts" \
  | jq '.body[] | select(.deleteFlag == "0") | {accountName, accountId}'
```

응답:
```json
{
  "accountName": "SampleCorp",
  "accountId": "<ACCOUNT_ID>"
}
```

## Step 3 — 프로필 생성

Step 2에서 얻은 12자리 `accountId`와 `accountName` **원문**을 `register` 서브커맨드에 그대로 넘긴다. 프로필명은 register 가 정하므로 에이전트가 계산하지 않고, 프로필에 대해 `aws configure set` 을 직접 실행하지 않는다. 역할 이름·external-id·assume 타입은 **브로커가 서버측에서 해석**하므로 클라이언트는 조회하거나 지정하지 않는다:

```bash
SKILL_DIR=$(dirname "$(aws configure get profile.csg-login.credential_process 2>/dev/null)")

# 성공 시 stdout 1줄이 생성된 프로필명이므로 그대로 변수로 받는다.
PROFILE_NAME=$("$SKILL_DIR/get-customer-credentials.sh" register --account-id <ACCOUNT_ID> --account-name "SampleCorp" --corp-name "(주)샘플고객")

aws sts get-caller-identity --profile "${PROFILE_NAME}"
```

> register 는 최종 프로필명을 **stdout 1줄로 출력**하므로 위처럼 `PROFILE_NAME` 으로 받아 두고, 아래 단계들은 전부 `--profile ${PROFILE_NAME}` 을 쓴다 — 프로필명 리터럴을 문서에 박지 않는다. 이름을 손으로 정하지 않고 register 의 stdout 을 받는 것이 원칙이며, 충돌이 나면 register 가 제안하는 대체 이름(`csg-{회사명}-{계정명}`)이 대신 쓰인다. 파생 이름은 `csg-` 네임스페이스 안에서 만들어지지만, 문서가 그 값을 미리 알 필요는 없다 — 그래서 네임스페이스가 또 바뀌어도 이 예제는 고칠 곳이 없다.
>
> `SKILL_DIR` 은 register 를 **호출할 경로**를 찾기 위한 것이며, 프로필에 구워지는 `credential_process` 문자열은 register 가 자기 실행 경로에서 직접 만든다. 중단(exit 1)되면 stdout 은 비어 있고 `~/.aws/config` 는 **한 바이트도 변경되지 않은** 상태이므로, stderr 첫 줄의 `[register] reason=<토큰>` 을 그대로 보고한다.

> 🔒 read-only(`ReadOnlyAccess`)는 브로커가 `AssumeRole` 시 **서버측에서 부착**한다 — 클라이언트는 `--policy-arns`를 붙이지 않으며 프로필에는 계정 ID만 전달한다. 고객사 역할에 AdministratorAccess가 부여되어 있어도 세션은 IAM 차원에서 ReadOnlyAccess로 차단된다.

## Step 4 — 리소스 조회 (병렬 실행)

문의 내용(Secrets Manager + API Gateway)에 따라 관련 리소스를 **병렬로** 조회:

```bash
# Secrets Manager — 시크릿 목록
aws secretsmanager list-secrets --profile ${PROFILE_NAME}

# Lambda — 함수 목록 (Secrets Manager Extension 사용 여부 확인)
aws lambda list-functions --profile ${PROFILE_NAME} \
  --query 'Functions[].{Name:FunctionName,Runtime:Runtime,Layers:Layers[].Arn}'

# API Gateway — REST API 목록
aws apigateway get-rest-apis --profile ${PROFILE_NAME}

# API Gateway — HTTP API 목록
aws apigatewayv2 get-apis --profile ${PROFILE_NAME}

# RDS — DB 인스턴스 및 클러스터
aws rds describe-db-instances --profile ${PROFILE_NAME}
aws rds describe-db-clusters --profile ${PROFILE_NAME}

# RDS Proxy — 프록시 목록 (IAM 인증 상태 확인)
aws rds describe-db-proxies --profile ${PROFILE_NAME}
```

조회 결과 요약:
- **Secrets Manager**: 시크릿 4개. `rds-db-credentials/...`이 핵심 (14개 Lambda에서 사용)
- **Lambda**: 67개 함수. 14개가 AWS Parameters and Secrets Lambda Extension 사용
- **API Gateway REST API**: `ChellyTemplateSQLTableAPI` (Edge, 캐싱 미사용)가 핵심
- **API Gateway HTTP API**: `roblox-template-preview-image-dynamoDBReader`가 활발
- **RDS**: Aurora PostgreSQL 15.12 클러스터
- **RDS Proxy**: 2개 모두 IAM 인증 DISABLED

## Step 5 — CloudWatch 메트릭 분석

트래픽 규모와 추이를 파악하기 위해 CloudWatch 메트릭 조회:

```bash
# Lambda 호출량 (주간, 일별)
aws cloudwatch get-metric-statistics --profile ${PROFILE_NAME} \
  --namespace AWS/Lambda \
  --metric-name Invocations \
  --dimensions Name=FunctionName,Value=Template_Lambda_Query \
  --start-time 2026-03-30T00:00:00Z \
  --end-time 2026-04-06T00:00:00Z \
  --period 86400 \
  --statistics Sum

# Lambda 동시 실행 수 (평균/최대)
aws cloudwatch get-metric-statistics --profile ${PROFILE_NAME} \
  --namespace AWS/Lambda \
  --metric-name ConcurrentExecutions \
  --dimensions Name=FunctionName,Value=Template_Lambda_Query \
  --start-time 2026-03-01T00:00:00Z \
  --end-time 2026-04-06T00:00:00Z \
  --period 604800 \
  --statistics Average Maximum

# API Gateway REST API 호출량
aws cloudwatch get-metric-statistics --profile ${PROFILE_NAME} \
  --namespace AWS/ApiGateway \
  --metric-name Count \
  --dimensions Name=ApiName,Value=ChellyTemplateSQLTableAPI \
  --start-time 2026-03-30T00:00:00Z \
  --end-time 2026-04-06T00:00:00Z \
  --period 86400 \
  --statistics Sum
```

핵심 발견:
- `Template_Lambda_Query`: 주간 ~7천만 호출, 4월 기준 일 최대 2,916만 (3월 대비 10배+ 급증)
- Lambda 동시성: 3월 avg 5~6 → 4월 avg 44, max 755
- `ChellyTemplateSQLTableAPI` (REST API): 주간 ~6,370만 호출, REST API 단가($3.50/백만) 적용 중

## Step 6 — 분석 결과 보고

조회 결과를 바탕으로 종합 분석 보고서를 작성하여 사용자에게 제공.

에이전트 응답 포함 내용:
1. **현재 아키텍처 분석** — 시크릿/Lambda/API Gateway/RDS/RDS Proxy 현황
2. **트래픽 추이** — 3월 초 → 3월 말 → 4월 첫째 주 비교 (10배 급증 확인)
3. **비용 추정** — API Gateway REST API가 비용의 98% 이상, SM은 Extension으로 99%+ 절감 중
4. **최적화 권장사항** — 우선순위별 4가지 방안 (REST→HTTP 전환, CloudFront, RDS Proxy IAM, 인프로세스 캐싱)
5. **실행 로드맵** — 우선순위, 예상 절감, 난이도, 시급성

---

## Step 7 — 후속 프롬프트: Secrets Manager 심층 분석

### 사용자 프롬프트

```
Secret manager도 3월에 비해 많이 증가했는데 최적화 방안이 있을까요
```

### 에이전트 동작

Lambda 동시성 메트릭을 추가 조회하여 SM 비용 증가의 구조적 원인을 분석:

```bash
# 3월 vs 4월 동시성 비교 (주간 단위)
aws cloudwatch get-metric-statistics --profile ${PROFILE_NAME} \
  --namespace AWS/Lambda \
  --metric-name ConcurrentExecutions \
  --dimensions Name=FunctionName,Value=Template_Lambda_Query \
  --start-time 2026-03-01T00:00:00Z \
  --end-time 2026-04-06T00:00:00Z \
  --period 604800 \
  --statistics Average Maximum

# Lambda 환경변수 확인 (SECRETS_MANAGER_TTL 설정 여부)
aws lambda get-function-configuration --profile ${PROFILE_NAME} \
  --function-name Template_Lambda_Query \
  --query 'Environment.Variables'
```

핵심 분석:
- Extension 캐시는 **실행 환경별로 독립** → 동시성 증가 = SM API 호출 비례 증가
- `SECRETS_MANAGER_TTL` 환경변수 **미설정** (기본 300초 사용 중)
- DB 자격증명 **자동 로테이션 미사용** → TTL을 늘리거나 IAM 인증으로 SM 호출 자체를 제거 가능

에이전트 응답 포함 내용:
1. **비용 증가 원인** — 동시 실행 환경 급증 → Extension 캐시 미스(cold start) 비례 증가
2. **방안 1**: RDS Proxy IAM 인증 활성화 → SM 호출 100% 제거 (가장 권장)
3. **방안 2**: Extension TTL 최대화 → 이미 최대치(300초)여서 추가 효과 없음
4. **방안 3**: 인프로세스 캐싱(코드 레벨) → Extension의 5분 TTL 제한 우회하여 15분+ 캐싱

---

## Step 8 — 고객사 이메일 답변 작성

### 사용자 프롬프트

```
이 내용이랑 아까 답변해준 내용이랑 같이 정리해서 고객사 답변용으로 만들어줘
```

형식/톤 확인 질문 후:
- 형식: **이메일 본문 형태**
- 톤: **공식적 / 상세 포함**

### 에이전트 동작

Step 6, Step 7의 분석 결과를 통합하여 고객사 전달용 이메일 본문 작성.

포함 내용:
1. 현재 사용 현황 분석 (트래픽, API Gateway, Secrets Manager, RDS Proxy)
2. 비용 추정 (API GW/SM 각각)
3. 최적화 권장사항 (API GW: REST→HTTP, CloudFront / SM: IAM 인증, 인프로세스 캐싱)
4. 종합 실행 로드맵

---

## Step 9 — 고객 답변 수정 (비용 제거, 문체 보정)

### 사용자 프롬프트

```
비용 부분에 대한 내용은 민감하니 제거해주고, 너무 AI스러운 말투랑 문장만 어떻게 제거해주세요
```

### 에이전트 동작

수정 사항:
- **비용 수치 전체 제거** — 단가, 월 비용 추정, 절감액 등 모든 금액 정보 삭제
- **AI 투 표현 제거** — "~할 수 있습니다", "기대할 수 있습니다" 등 반복 패턴을 자연스럽게 수정
- 기술 내용과 구조는 유지

---

## Step 10 — 참고 문서 수집 및 검증

### 사용자 프롬프트

```
고객사한테 전달해줄 참고할만한 공식 문서나 repost 글 없을까?
```

### 에이전트 동작

웹 검색 + webfetch로 AWS 공식 문서 URL을 수집하고, 각 URL에 접근하여 **실제 접근 가능 여부와 문서 제목**을 검증.

수집한 참고 문서 (주제별):

**Secrets Manager — Lambda Extension 캐싱:**
- Use AWS Secrets Manager secrets in AWS Lambda functions (AWS 공식 문서)
- Use Secrets Manager secrets in Lambda functions (AWS Lambda 공식 문서)
- Using the AWS Parameter and Secrets Lambda extension to cache parameters and secrets (AWS Compute Blog)

**RDS Proxy IAM 인증 전환:**
- Amazon RDS Proxy (AWS 공식 문서)
- Configuring IAM authentication for RDS Proxy (AWS 공식 문서)
- Use Amazon RDS Proxy with IAM authentication for cross-account access (AWS Database Blog)

**API Gateway — REST API vs HTTP API:**
- Choose between REST APIs and HTTP APIs (AWS 공식 문서)
- Cache settings for REST APIs in API Gateway (AWS 공식 문서)

**CloudFront + API Gateway:**
- How do I set up API Gateway with my own CloudFront distribution? (AWS re:Post)

**Lambda Function URL:**
- Creating and managing Lambda function URLs (AWS 공식 문서)
- AWS Lambda function URLs (AWS Prescriptive Guidance)

---

## Step 11 — Zendesk markdown 규격 적용 및 최종본 작성

### 사용자 프롬프트

```
표로 만든것들 전부 zendesk markdown 규격에 맞게 고쳐줘. 그리고 메일 하단에 참고문서 항목으로 저 윗내용도 포함시켜주고, 그리고 문서의 제목이 뭔지도 포함시켜
```

### 에이전트 동작

1. Zendesk markdown 규격 조사 → **파이프 기반 테이블 미지원** 확인
2. 모든 표를 **리스트 + 볼드** 형태로 변환
3. 참고 문서 섹션을 이메일 하단에 추가 (주제별 분류, 문서 제목 + 출처 포함)
4. 링크는 `[제목](URL)` Zendesk markdown 규격으로 작성

---

## 사용된 AWS CLI 명령어 전체 목록

이 컨설팅에서 사용된 읽기 전용 명령어:

```bash
# 계정 접근 확인
aws sts get-caller-identity --profile ${PROFILE_NAME}

# Secrets Manager
aws secretsmanager list-secrets --profile ${PROFILE_NAME}

# Lambda
aws lambda list-functions --profile ${PROFILE_NAME}
aws lambda get-function-configuration --profile ${PROFILE_NAME} --function-name <함수명>

# API Gateway (REST)
aws apigateway get-rest-apis --profile ${PROFILE_NAME}
aws apigateway get-stages --profile ${PROFILE_NAME} --rest-api-id <api-id>
aws apigateway get-resources --profile ${PROFILE_NAME} --rest-api-id <api-id>

# API Gateway (HTTP)
aws apigatewayv2 get-apis --profile ${PROFILE_NAME}
aws apigatewayv2 get-stages --profile ${PROFILE_NAME} --api-id <api-id>

# RDS
aws rds describe-db-instances --profile ${PROFILE_NAME}
aws rds describe-db-clusters --profile ${PROFILE_NAME}
aws rds describe-db-proxies --profile ${PROFILE_NAME}

# CloudWatch 메트릭
aws cloudwatch get-metric-statistics --profile ${PROFILE_NAME} \
  --namespace AWS/Lambda --metric-name Invocations ...
aws cloudwatch get-metric-statistics --profile ${PROFILE_NAME} \
  --namespace AWS/Lambda --metric-name ConcurrentExecutions ...
aws cloudwatch get-metric-statistics --profile ${PROFILE_NAME} \
  --namespace AWS/ApiGateway --metric-name Count ...
```

> ⚠️ 모든 명령은 **읽기 전용**(List, Get, Describe)만 사용됨. 리소스 변경 명령은 일절 실행하지 않음.

## 포인트 정리

이 예제에서 보여주는 핵심:

1. **단순 조회를 넘어선 분석**: 리소스 목록 조회 → CloudWatch 메트릭 기반 트래픽 분석 → 비용 구조 파악
2. **반복적 후속 질문 대응**: 초기 분석 → 심층 분석 → 고객 답변 작성 → 수정 → 참고문서 → 포맷 변환까지 점진적으로 확장
3. **서버측 자격증명 발급**: 12자리 accountId만으로 프로필 생성 → 브로커가 역할·external-id·assume 타입을 서버측에서 해석하고 ReadOnlyAccess를 부착
4. **고객 커뮤니케이션**: 기술 분석을 고객사 눈높이의 이메일로 변환 (비용 민감 정보 제거, 문체 보정)
5. **외부 참고 자료 검증**: URL 수집 후 webfetch로 접근 가능 여부와 실제 문서 제목까지 검증
