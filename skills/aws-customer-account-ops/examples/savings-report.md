# 고객사 할인 내역 분석 — RI/SP/CF Savings Report (빌링 API)

> 사용자 요청: "데모상사 올해 상반기 RI, SP 할인 현황 보여줘"

## 시나리오

고객사 "데모상사"의 6개월간 할인 내역(Reserved Instance, Savings Plans, CloudFront)을 조회하고, OnDemand 비용 대비 절감 효과를 분석하는 전체 흐름.
이 작업은 **AWS 계정 접근 없이** BILLING 빌링 API만으로 처리한다.

---

## 전체 대화 흐름

```
사용자 프롬프트 1: "데모상사 올해 상반기 RI, SP 할인 현황 보여줘"
  → 고객 식별, Savings 조회, 카테고리별 분석, 종합 보고

사용자 프롬프트 2: "4월 RI 상세 내역 계정별로 보여줘"
  → 특정 월 + 카테고리 필터링, 계정별 그룹핑
```

---

## Step 1 — 고객사 식별

회사명 "데모상사"으로 BILLING API 검색 (`billing-api.sh` 래퍼가 API 키를 env 또는 conf에서 해석):

```bash
SKILL_DIR=$(dirname "$(aws configure get profile.csg-login.credential_process 2>/dev/null)")

"$SKILL_DIR/billing-api.sh" GET "/api/admin/v1/companies" \
  | jq '.body[] | select(.corpName | test("데모상사"; "i")) | {corpId, corpName}'
```

응답:
```json
{
  "corpId": "a1b2c3d4-e5f6-7890-abcd-ef1234567890",
  "corpName": "(주)데모상사"
}
```

> 빌링 조회에는 `corpId`만 필요하다. 프로필 생성이나 STS 토큰은 불필요.

## Step 2 — Savings (할인 내역) 조회

6개월간 RI/SP/CF/IVS 할인 내역 + OnDemand 추이 조회:

```bash
CORP_ID="a1b2c3d4-e5f6-7890-abcd-ef1234567890"

"$SKILL_DIR/billing-api.sh" POST "/api/v1/costs/savings/corp/monthly" \
  '{"from": "202601", "to": "202606", "corpId": "'${CORP_ID}'"}'
```

응답 예시:
```json
{
  "header": {"code": 200, "message": "success"},
  "body": {
    "ondemands": [
      {"billingPeriod": "202601", "usageFee": 11234.56},
      {"billingPeriod": "202602", "usageFee": 12456.78},
      {"billingPeriod": "202603", "usageFee": 12890.12},
      {"billingPeriod": "202604", "usageFee": 13616.24},
      {"billingPeriod": "202605", "usageFee": 13450.00},
      {"billingPeriod": "202606", "usageFee": 14200.50}
    ],
    "reservationInstances": [
      {"billingPeriod": "202601", "usageFee": 5678.90, "corpId": "a1b2c3d4-...", "usageAccountId": "<ACCOUNT_ID>"},
      {"billingPeriod": "202601", "usageFee": 2345.60, "corpId": "a1b2c3d4-...", "usageAccountId": "<ACCOUNT_ID_2>"},
      {"billingPeriod": "202602", "usageFee": 5678.90, "corpId": "a1b2c3d4-...", "usageAccountId": "<ACCOUNT_ID>"},
      {"billingPeriod": "202602", "usageFee": 2345.60, "corpId": "a1b2c3d4-...", "usageAccountId": "<ACCOUNT_ID_2>"},
      {"billingPeriod": "202603", "usageFee": 5700.00, "corpId": "a1b2c3d4-...", "usageAccountId": "<ACCOUNT_ID>"},
      {"billingPeriod": "202604", "usageFee": 5700.00, "corpId": "a1b2c3d4-...", "usageAccountId": "<ACCOUNT_ID>"},
      {"billingPeriod": "202604", "usageFee": 2345.60, "corpId": "a1b2c3d4-...", "usageAccountId": "<ACCOUNT_ID_2>"},
      {"billingPeriod": "202605", "usageFee": 5700.00, "corpId": "a1b2c3d4-...", "usageAccountId": "<ACCOUNT_ID>"},
      {"billingPeriod": "202606", "usageFee": 5700.00, "corpId": "a1b2c3d4-...", "usageAccountId": "<ACCOUNT_ID>"}
    ],
    "savingsPlans": [
      {"billingPeriod": "202601", "usageFee": 3456.78},
      {"billingPeriod": "202602", "usageFee": 3456.78},
      {"billingPeriod": "202603", "usageFee": 3456.78},
      {"billingPeriod": "202604", "usageFee": 3500.00},
      {"billingPeriod": "202605", "usageFee": 3500.00},
      {"billingPeriod": "202606", "usageFee": 3500.00}
    ],
    "cloudfronts": [
      {"billingPeriod": "202601", "usageFee": 234.56, "corpId": "a1b2c3d4-...", "accountId": "<ACCOUNT_ID>"},
      {"billingPeriod": "202604", "usageFee": 250.00, "corpId": "a1b2c3d4-...", "accountId": "<ACCOUNT_ID>"}
    ],
    "ivs": []
  }
}
```

> **주의**: `body`는 배열이 아니라 **객체**이다. `ondemands`, `reservationInstances`, `savingsPlans`, `cloudfronts`, `ivs` 5개 카테고리가 각각 배열로 포함된다.

## Step 3 — 카테고리별 할인 총액 분석

jq로 카테고리별 총 할인액을 계산:

```bash
"$SKILL_DIR/billing-api.sh" POST "/api/v1/costs/savings/corp/monthly" \
  '{"from": "202601", "to": "202606", "corpId": "'${CORP_ID}'"}' \
  | jq '{
    ondemand_total: ([.body.ondemands[].usageFee] | add // 0),
    ri_total: ([.body.reservationInstances[].usageFee] | add // 0),
    sp_total: ([.body.savingsPlans[].usageFee] | add // 0),
    cf_total: ([.body.cloudfronts[].usageFee] | add // 0),
    ivs_total: ([.body.ivs[].usageFee] | add // 0)
  } | . + {savings_total: (.ri_total + .sp_total + .cf_total + .ivs_total)}'
```

응답 예시:
```json
{
  "ondemand_total": 77848.20,
  "ri_total": 41194.60,
  "sp_total": 20870.34,
  "cf_total": 484.56,
  "ivs_total": 0,
  "savings_total": 62549.50
}
```

## Step 4 — 월별 OnDemand 추이와 할인 비교

월별 OnDemand 비용 + 할인 금액 추이:

```bash
"$SKILL_DIR/billing-api.sh" POST "/api/v1/costs/savings/corp/monthly" \
  '{"from": "202601", "to": "202606", "corpId": "'${CORP_ID}'"}' \
  | jq '{
    ondemand_trend: [.body.ondemands[] | {month: .billingPeriod, usd: .usageFee}],
    ri_by_month: [.body.reservationInstances[] | {month: .billingPeriod, usd: .usageFee}] | group_by(.month) | map({month: .[0].month, usd: (map(.usd) | add)}),
    sp_by_month: [.body.savingsPlans[] | {month: .billingPeriod, usd: .usageFee}]
  }'
```

## Step 5 — 결과 보고

에이전트 응답 포함 내용:
1. **상반기 할인 총액** — RI + SP + CF 합계와 OnDemand 대비 비율
2. **카테고리별 내역** — RI가 가장 큰 비중, SP 고정 비용, CF 간헐적 적용
3. **월별 추이** — OnDemand 비용 증가 대비 할인 커버리지 분석
4. **IVS 미사용** — IVS 할인 데이터 없음 (해당 서비스 미사용)

---

## Step 6 — 후속 프롬프트: 특정 월 RI 계정별 상세

### 사용자 프롬프트

```
4월 RI 상세 내역 계정별로 보여줘
```

### 에이전트 동작

Savings 응답에서 `reservationInstances`를 4월(`202604`)로 필터링 + 계정별 그룹핑:

```bash
"$SKILL_DIR/billing-api.sh" POST "/api/v1/costs/savings/corp/monthly" \
  '{"from": "202604", "to": "202604", "corpId": "'${CORP_ID}'"}' \
  | jq '[.body.reservationInstances[] | {account: .usageAccountId, usd: .usageFee}] | group_by(.account) | map({account: .[0].account, total_usd: (map(.usd) | add)})'
```

응답 예시:
```json
[
  {"account": "<ACCOUNT_ID>", "total_usd": 5700.00},
  {"account": "<ACCOUNT_ID_2>", "total_usd": 2345.60}
]
```

에이전트 분석:
- 계정 `<ACCOUNT_ID>` — RI 사용액 $5,700 (70.8%)
- 계정 `<ACCOUNT_ID_2>` — RI 사용액 $2,346 (29.2%)
- 프로덕션 계정에 RI가 집중 배치되어 있음

---

## 포인트 정리

이 예제에서 보여주는 핵심:

1. **AWS 계정 접근 불필요**: `corpId`만으로 할인 데이터 직접 조회 — 프로필 생성/STS 토큰 불필요
2. **body는 객체**: Savings 응답의 `body`는 배열이 아닌 객체 — `ondemands[]`, `reservationInstances[]`, `savingsPlans[]`, `cloudfronts[]`, `ivs[]` 5개 카테고리
3. **카테고리별 분석**: RI/SP/CF/IVS를 각각 분리하여 할인 구조 파악
4. **계정별 그룹핑**: `usageAccountId`로 RI 사용 계정을 구분하여 할인 배분 분석
5. **기간 제한**: 최대 6개월까지 조회 가능 — 상반기/하반기 단위 분석에 적합
