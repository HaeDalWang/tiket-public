# BILLING API 레퍼런스

> AWS 고객 계정 관리를 위한 BILLING Admin API 명세

> **호출 방식**: 모든 BILLING 호출은 `billing-api.sh` 래퍼를 사용합니다.
> 래퍼가 API 키를 env(`BILLING_API_KEY`) → `~/.config/msp/credential-broker.conf`
> 순으로 해석하고 `Authorization: Bearer` 헤더와 기본 URL을 자동으로 붙이므로,
> 아래 예시는 `"$SKILL_DIR/billing-api.sh" METHOD "/api/..." [JSON_BODY]` 형태로 표기합니다.
> `SKILL_DIR=$(dirname "$(aws configure get profile.csg-login.credential_process 2>/dev/null)")`

## 기본 정보

| 항목 | 값 |
|------|-----|
| Base URL | `https://billing.example.com` (래퍼가 자동 접두) |
| 인증 | `billing-api.sh` 래퍼가 env 또는 conf의 키로 Bearer 헤더 자동 부착 |
| 응답 형식 | JSON |

## 응답 구조

모든 API는 동일한 wrapper 형식으로 응답한다:

```json
{
  "header": {
    "code": 200,
    "message": "Data has been searched."
  },
  "body": [...]
}
```

`header.message` 는 `"success"` 가 아니다(2026-10-20 실호출). 성공 판별은 `header.code == 200` 으로만 한다.
값이 없는 필드는 `null` 이 아니라 **키 자체가 빠진다**(`companies` 의 `mspActiveFlag`·`customPriceId`·`endPeriod`·`billingAccount`·`tradingStartDate` 등).

## 에러 처리

HTTP 상태가 200 이어도 실패일 수 있다 — 항상 `header.code` 를 본다.

| 상황 | 실제로 오는 것 | 확인 |
|------|-----------|------|
| 성공 | HTTP 200, `header.code` 200 | |
| **데이터 없음** | HTTP 200, `header.code` **204**, `message` `"no data found."`, `body` 는 빈 배열이 아니라 **객체 `{}`** — 계정이 없는 회사의 `companies/{corpId}/accounts` | 2026-10-21 실호출 (60곳 중 4곳) |
| 요청 실패 | HTTP 200, `header.code` 800 — 수기 청구 인보이스 조회 등 | 2026-10-20 실호출 |
| **호출 한도** | HTTP **429** — 한도는 분당 50·시간당 200·하루 500회이고 키를 쓰는 곳이 나눠 쓴다(2026-10-22 운영자 안내). 한 번 걸리면 21분 넘게 풀리지 않았다. 반복 호출(회사마다 계정 조회)을 피하고, 걸리면 길게 쉰다 | 2026-10-21 실호출 |
| 인증 실패 | `header.code` 401, `message` `"invalid token!!"`, `body` `null` (HTTP 상태는 래퍼가 보여 주지 않아 모른다) | 2026-10-21 실호출 |

> 여러 회사의 계정이 필요하면 회사마다 `companies/{corpId}/accounts` 를 부르지 말고 **`/api/admin/v1/accounts` 한 번**으로 받는다(아래 1번 — 모든 행에 `corpId`·`corpName` 이 온다, 2026-10-22 실호출).

---

## 엔드포인트

### 1. 전체 계정 조회

```
GET /api/admin/v1/accounts
```

전체 AWS 계정 목록을 조회한다. 파라미터는 없다. 2026-10-22 실호출: 1,870행(약 0.9MB), 회사 1,055곳 — **삭제된 계정·회사도 들어 있다**(`deleteFlag` `"1"` 960행 · `"0"` 910행).
활성 계정만 쓰려면 `deleteFlag == "0"` 으로 거르고, 삭제된 회사의 계정까지 빼려면 2번(회사 목록)의 `deleteFlag` 와 맞춰 본다.
Swagger(Admin API)는 응답 본문을 `object` 로만 적는다 — 아래 필드는 실호출에서 본 것이다.

**⚠️ 이 엔드포인트에는 `assume_role_type`이 없다!**

#### 응답 필드

| 필드 | 타입 | 설명 |
|------|------|------|
| `accountId` | string | AWS 계정 ID (12자리) |
| `accountName` | string | 계정 이름 |
| `corpName` | string | 소속 회사명 |
| `corpId` | string (UUID) | 소속 회사 ID |
| `deleteFlag` | string | `"1"` 삭제됨 / `"0"` 활성 |
| `createDate` | string | 생성일 |
| `updateDate` | string | 수정일 |
| `awsSupportRealDesc` | string | AWS Support 플랜 설명 — 일부 행에만 온다(1,870 중 1,260) |

같은 값이 snake_case 사본(`account_id`·`corp_id`·`corp_name`·`delete_flag`·`create_date` 등)으로 한 번 더 온다. camelCase 를 쓴다.

#### curl 예시

```bash
"$SKILL_DIR/billing-api.sh" GET "/api/admin/v1/accounts"
```

#### 응답 예시

```json
{
  "header": {"code": 200, "message": "Data has been searched."},
  "body": [
    {
      "accountId": "<ACCOUNT_ID>",
      "accountName": "example-prod",
      "corpName": "Example Corp",
      "corpId": "00000000-0000-0000-0000-00000000000a",
      "deleteFlag": "0",
      "createDate": "2024-01-15",
      "updateDate": "2024-06-01"
    }
  ]
}
```

---

### 2. 전체 회사 조회

```
GET /api/admin/v1/companies
```

전체 고객사 목록을 조회한다. 약 1,062개 회사가 반환된다.

#### 응답 필드

| 필드 | 타입 | 설명 |
|------|------|------|
| `corpId` | string (UUID) | 회사 고유 ID |
| `corpName` | string | 회사명 |
| `salesManagerName` | string | 담당 영업 매니저 |
| `deleteFlag` | string | `"1"` 삭제됨 / `"0"` 활성 |

#### curl 예시

```bash
"$SKILL_DIR/billing-api.sh" GET "/api/admin/v1/companies"
```

#### 응답 예시

```json
{
  "header": {"code": 200, "message": "Data has been searched."},
  "body": [
    {
      "corpId": "00000000-0000-0000-0000-00000000000a",
      "corpName": "Example Corp",
      "salesManagerName": "홍길동",
      "deleteFlag": "0"
    }
  ]
}
```

---

### 3. 회사별 계정 조회

```
GET /api/admin/v1/companies/{corpId}/accounts
```

특정 회사에 속한 AWS 계정 목록을 조회한다.
**`assume_role_type`을 제공하는 유일한 엔드포인트이다.**

#### 경로 파라미터

| 파라미터 | 설명 |
|----------|------|
| `corpId` | 회사 UUID (예: `00000000-0000-0000-0000-00000000000a`) |

#### 응답 필드

| 필드 | 타입 | 설명 |
|------|------|------|
| `accountName` | string | 계정 이름 |
| `accountId` | string | AWS 계정 ID (12자리) |
| `assume_role_type` | string | `"Role"` 또는 `"User"` |
| `deleteFlag` | string | `"1"` 삭제됨 / `"0"` 활성 |
| `creditSharingFlag` | string | 크레딧 공유 여부 |
| `awsSupportLevel` | string | AWS 서포트 레벨 |
| `awsSupportType` | string | AWS 서포트 유형 |

#### curl 예시

```bash
"$SKILL_DIR/billing-api.sh" GET "/api/admin/v1/companies/00000000-0000-0000-0000-00000000000a/accounts"
```

#### 응답 예시

```json
{
  "header": {"code": 200, "message": "Data has been searched."},
  "body": [
    {
      "accountName": "example-prod",
      "accountId": "<ACCOUNT_ID>",
      "assume_role_type": "Role",
      "deleteFlag": "0",
      "creditSharingFlag": "N"
    }
  ]
}
```

---

## 참고 필드: assume_role_type

`assume_role_type`은 BILLING가 `/api/admin/v1/companies/{corpId}/accounts`에서 제공하는 필드로, 고객 AWS 계정의 접근 방식을 나타낸다:

- **`"Role"`**: cross-account IAM Role로 AssumeRole 접근 (역할 이름은 고객사마다 다를 수 있음)
- **`"User"`**: IAM User 기반 접근

단, **v1.6부터 접근 방식(역할 이름/external-id/체이닝)은 브로커가 서버측에서 해석**하므로, 클라이언트 워크플로우에서는 이 필드를 조회하거나 그 값으로 분기하지 않는다 (참고용 필드). 클라이언트는 Step-1에서 `corpId`(빌링)와 12자리 `accountId`(브로커에 전달)만 식별하면 된다.

### 엔드포인트별 필드 제공 차이

`/api/admin/v1/accounts`는 전체 계정 목록을 제공하지만 **`assume_role_type` 필드가 없다.** 이 필드는 `/api/admin/v1/companies/{corpId}/accounts`에서만 제공된다 (위 엔드포인트 3 참조).

> `deleteFlag`: `"0"` 활성 / `"1"` 삭제됨 | `corpId`: UUID 형식

---

## 빌링/비용 엔드포인트

> AWS 계정 접근 없이 BILLING 빌링 데이터를 직접 조회하는 엔드포인트.
> 고객 식별(Step 1)에서 획득한 `corpId`를 그대로 사용한다.

### 공통 사항

**인증**: 모든 엔드포인트는 `billing-api.sh` 래퍼를 통해 호출하며, 래퍼가 env 또는 conf의 키로 Bearer 헤더를 자동 부착한다.

**Rate Limit**: 300회/분, 1,000회/시간, 10,000회/일. Agent 세션에서 초과할 가능성은 극히 낮다.

**데이터 주의사항**:
- 최종 확정 전 데이터는 변동될 수 있다 (월 마감 전)
- 원화 환산 금액은 소수점 차이가 발생할 수 있다
- 기간 제한: 월별 최대 6개월, 일별 최대 31일

**기간 형식**:
- 월별: `yyyyMM` (예: `202604`)
- 일별: `yyyyMMdd` (예: `20260401`)

---

### 4. 데이터 업데이트 시간 조회

```
GET /api/v1/billing/timestamps
```

빌링 데이터의 최근 업데이트 시간을 조회한다. 비용 데이터가 언제 기준인지 확인할 때 사용한다.

#### 쿼리 파라미터

| 파라미터 | 필수 | 설명 |
|----------|------|------|
| `key` | 아니오 | 타임스탬프 키 (기본값: `cur_last_update`) |

#### curl 예시

```bash
"$SKILL_DIR/billing-api.sh" GET "/api/v1/billing/timestamps?key=cur_last_update"
```

---

### 5. 고객사별 월별 OnDemand 비용

```
POST /api/v1/costs/ondemand/corp/monthly
```

특정 고객사의 월별 순수 OnDemand 비용을 서비스/리전별로 상세 조회한다.

#### 요청 본문 (JSON)

| 필드 | 타입 | 필수 | 설명 |
|------|------|------|------|
| `from` | string | 예 | 시작 월 (`yyyyMM`, 예: `202601`) |
| `to` | string | 예 | 종료 월 (`yyyyMM`, 예: `202606`) |
| `corpId` | string | 예 | 고객사 ID (Step 1에서 획득) |

> `corpId`는 API 스펙상 optional이지만, 고객사별 조회 시 반드시 지정해야 한다.

#### 응답 필드 (`body[]`)

| 필드 | 타입 | 설명 |
|------|------|------|
| `serviceName` | string | AWS 서비스명 (예: `Amazon Elastic Compute Cloud`) |
| `productRegion` | string | 리전 코드 (예: `ap-northeast-2`) |
| `productRegionName` | string | 리전 이름 (예: `Asia Pacific (Seoul)`) |
| `billingPeriod` | string | 청구 기간 (`yyyyMM`) |
| `usageFee` | number | 사용 금액 (USD) |
| `usageAmount` | string | 사용량 |
| `unit` | string | 단위 (예: `Hrs`, `GB`) |
| `lineItemTypeRefine` | string | 요금 유형 |
| `usageType` | string | 서비스 사용 유형 |
| `operation` | string | 서비스 오퍼레이션 |
| `billingEntity` | string | 판매 계정 |
| `currencyCode` | string | 통화 코드 |

#### curl 예시

```bash
"$SKILL_DIR/billing-api.sh" POST "/api/v1/costs/ondemand/corp/monthly" \
  '{"from": "202604", "to": "202604", "corpId": "00000000-0000-0000-0000-00000000000a"}'
```

#### 응답 예시

```json
{
  "header": {"code": 200, "message": "Data has been searched."},
  "body": [
    {
      "serviceName": "Amazon Elastic Compute Cloud",
      "productRegion": "ap-northeast-2",
      "productRegionName": "Asia Pacific (Seoul)",
      "billingPeriod": "202604",
      "usageFee": 1234.56,
      "usageAmount": "720",
      "unit": "Hrs",
      "lineItemTypeRefine": "Usage",
      "usageType": "APN2-BoxUsage:t3.medium",
      "operation": "RunInstances",
      "billingEntity": "AWS",
      "currencyCode": "USD"
    }
  ]
}
```

#### 활용: 서비스별 비용 요약

```bash
"$SKILL_DIR/billing-api.sh" POST "/api/v1/costs/ondemand/corp/monthly" \
  '{"from": "202604", "to": "202604", "corpId": "CORP_ID"}' \
  | jq '[.body[] | {serviceName, usageFee}] | group_by(.serviceName) | map({service: .[0].serviceName, total: (map(.usageFee) | add)}) | sort_by(-.total) | .[:10]'
```

---

### 6. 고객사별 월별 청구 내역 (인보이스)

```
POST /api/v1/invoice/corp/monthly
```

고객사의 월별 청구 내역을 조회한다. OnDemand 비용 외에 크레딧, 추가 청구, 선납금 등 전체 청구 항목을 포함한다.

> ⚠️ 수기 청구인 경우 데이터가 제공되지 않는다.

#### 요청 본문 (JSON)

| 필드 | 타입 | 필수 | 설명 |
|------|------|------|------|
| `billingPeriod` | string | 예 | 청구 월 (`yyyyMM`, 예: `202604`) |
| `corpId` | string | 예 | 고객사 ID |

#### 응답 필드 (`body[]`)

| 필드 | 타입 | 설명 |
|------|------|------|
| `billingPeriod` | string | 청구 기간 (`yyyyMM`) |
| `corpName` | string | 고객사명 |
| `invoiceDivision` | string | 청구 항목 분류 |
| `viewIndex` | string | 청구 항목 |
| `lineItemType` | string | 요금 유형 |
| `invoiceItem` | string | 과금 항목 |
| `currencyCode` | string | 통화 |
| `usageFee` | number | 금액 (USD) |
| `usageFeeKrw` | string | 원화 환산 금액 |
| `exchangeRate` | string | 환율 정보 |
| `note` | string | 비고 |

#### curl 예시

```bash
"$SKILL_DIR/billing-api.sh" POST "/api/v1/invoice/corp/monthly" \
  '{"billingPeriod": "202604", "corpId": "00000000-0000-0000-0000-00000000000a"}'
```

#### 응답 예시

```json
{
  "header": {"code": 200, "message": "Data has been searched."},
  "body": [
    {
      "billingPeriod": "202604",
      "corpName": "Example Corp",
      "invoiceDivision": "AWS 사용료",
      "viewIndex": "AWS 사용료",
      "lineItemType": "Usage",
      "invoiceItem": "AWS 서비스 사용료",
      "currencyCode": "USD",
      "usageFee": 5678.90,
      "usageFeeKrw": "7,654,321",
      "exchangeRate": "1,348.00",
      "note": ""
    }
  ]
}
```

---

### 7. 계정별 월별 청구 요약 (MSP 회사 전용)

```
GET /api/admin/v1/invoices/monthly-summary
```

전체 고객사의 계정별 월별 청구 요약을 조회한다. 특정 고객사가 아닌 **전체 현황 파악** 시 사용한다.

> ⚠️ MSP 회사 관리자 전용. 외부 고객사 계정으로는 HTTP 403이 반환된다.

#### 쿼리 파라미터

| 파라미터 | 필수 | 설명 |
|----------|------|------|
| `billingMonth` | 예 | 청구 월 (`yyyyMM`, 예: `202604`) |

#### curl 예시

```bash
"$SKILL_DIR/billing-api.sh" GET "/api/admin/v1/invoices/monthly-summary?billingMonth=202604"
```

---

### 8. 고객사별 월별 할인 내역 (RI/SP/CF)

```
POST /api/v1/costs/savings/corp/monthly
```

고객사의 월별 할인 내역을 조회한다. OnDemand 비용 추이와 함께 CloudFront, Reserved Instance, Savings Plans, IVS 할인을 각각 분리하여 제공한다.

#### 요청 본문 (JSON)

| 필드 | 타입 | 필수 | 설명 |
|------|------|------|------|
| `from` | string | 예 | 시작 월 (`yyyyMM`) |
| `to` | string | 예 | 종료 월 (`yyyyMM`) |
| `corpId` | string | 예 | 고객사 ID |

> 기간 제한: 최대 6개월

#### 응답 구조 (`body`)

`body`는 배열이 아니라 **객체**이며, 5개 카테고리별 배열을 포함한다:

| 필드 | 타입 | 설명 |
|------|------|------|
| `ondemands[]` | array | OnDemand 비용 추이 (`billingPeriod`, `usageFee`) |
| `cloudfronts[]` | array | CloudFront 할인 (`billingPeriod`, `usageFee`, `corpId`, `accountId`) |
| `reservationInstances[]` | array | RI 할인 (`billingPeriod`, `usageFee`, `corpId`, `usageAccountId`) |
| `savingsPlans[]` | array | SP 할인 (`billingPeriod`, `usageFee`) |
| `ivs[]` | array | IVS 할인 (`billingPeriod`, `usageFee`, `corpId`) |

> 각 배열 항목의 `usageFee`는 USD 기준이다.

#### curl 예시

```bash
"$SKILL_DIR/billing-api.sh" POST "/api/v1/costs/savings/corp/monthly" \
  '{"from": "202601", "to": "202606", "corpId": "00000000-0000-0000-0000-00000000000a"}'
```

#### 응답 예시

```json
{
  "header": {"code": 200, "message": "Data has been searched."},
  "body": {
    "ondemands": [
      {"billingPeriod": "202601", "usageFee": 12345.67},
      {"billingPeriod": "202602", "usageFee": 13456.78}
    ],
    "cloudfronts": [
      {"billingPeriod": "202601", "usageFee": 234.56, "corpId": "...", "accountId": "<ACCOUNT_ID>"}
    ],
    "reservationInstances": [
      {"billingPeriod": "202601", "usageFee": 5678.90, "corpId": "...", "usageAccountId": "<ACCOUNT_ID>"}
    ],
    "savingsPlans": [
      {"billingPeriod": "202601", "usageFee": 3456.78}
    ],
    "ivs": []
  }
}
```

#### 활용: 월별 총 할인액 계산

```bash
"$SKILL_DIR/billing-api.sh" POST "/api/v1/costs/savings/corp/monthly" \
  '{"from": "202601", "to": "202606", "corpId": "CORP_ID"}' \
  | jq '{
    ondemand_trend: [.body.ondemands[] | {month: .billingPeriod, usd: .usageFee}],
    ri_total: ([.body.reservationInstances[].usageFee] | add // 0),
    sp_total: ([.body.savingsPlans[].usageFee] | add // 0),
    cf_total: ([.body.cloudfronts[].usageFee] | add // 0)
  }'
```

---

### 9. 일별 비용·사용량

```
POST /api/v1/costs/ondemand/corp/daily
POST /api/v1/costs/ondemand/account/daily
POST /api/v1/usage/ondemand/daily
```

요청 본문은 월별과 같고 기간만 `yyyyMMdd` 다(최대 31일). 2026-10-27 실호출로 확인:

```bash
"$SKILL_DIR/billing-api.sh" POST "/api/v1/usage/ondemand/daily" \
  '{"from": "20261022", "to": "20261022", "corpId": "CORP_ID"}'
```

| 경로 | 응답 행이 가르는 것 | 주의 |
|------|------|------|
| `costs/ondemand/corp/daily` | `serviceCode`·`serviceName`·`usageType`·`usageFee`·`lineItemType`·`beginRange`/`endRange`(티어 구간) | `productCode` 가 없다. Data Transfer 는 `serviceCode: AWSDataTransfer`(`serviceName: Data Transfer`) 한 줄로 묶인다 |
| `costs/ondemand/account/daily` | 위와 같은 칸, 계정별 | 위와 같다 |
| `usage/ondemand/daily` | `accountId`·`productCode`·`serviceCode`·`usageType`·`usageAmount`(string)·`onDemandCost`(string)·`tagsJson` | `accountId` 는 `"<12자리> <계정 이름>"` 형태다. RI/SP 할인·티어링 전 순수 온디맨드 금액이다 |

**Data Transfer 가 어느 서비스에서 났나** — `usage/ondemand/daily` 에서 `serviceCode == "AWSDataTransfer"` 행을 `productCode`(예: `AmazonApiGateway`, `AmazonS3`, `AmazonEC2`)로 묶는다.
비용 경로만 보고 "청구 상세에 서비스 구분이 없다" 며 내부 부서로 넘기지 않는다(2026-10-26 현장 교훈).
이 경로의 금액은 할인 전 값이라 고객 청구 금액이 아니다 — 고객에게는 발생 서비스와 비중만 말하거나, 금액은 비용 경로·빌링 플랫폼 화면 값을 쓴다.

---

## 빌링 워크플로우 요약

고객 비용/청구 관련 질문에 대한 처리 흐름:

1. **고객 식별** — 기존 Step 1과 동일 (회사명/계정ID → `corpId` 획득)
2. **비용 조회** — `corpId`로 빌링 API 호출 (AWS 계정 접근 불필요)
3. **결과 분석** — jq로 서비스별/월별 집계 후 사용자에게 보고

> AWS CLI 프로필 생성 없이 BILLING API만으로 비용/청구 데이터를 조회할 수 있다.
> AWS 리소스 상세 조회가 추가로 필요한 경우에만 프로필을 생성한다.
