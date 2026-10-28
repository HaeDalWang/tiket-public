# 고객사 월별 비용 조회 및 인보이스 분석 (빌링 API)

> 사용자 요청: "데모상사 이번 달 AWS 비용 얼마야? 인보이스도 보여줘"

## 시나리오

고객사 "데모상사"의 이번 달 AWS 비용을 서비스별로 조회하고, 청구 내역(인보이스)까지 확인하는 전체 흐름.
이 작업은 **AWS 계정 접근 없이** BILLING 빌링 API만으로 처리한다.

---

## 전체 대화 흐름

```
사용자 프롬프트 1: "데모상사 이번 달 AWS 비용 얼마야? 인보이스도 보여줘"
  → 고객 식별, 비용 조회, 인보이스 조회, 종합 보고

사용자 프롬프트 2: "지난 3개월 비용 추이도 보여줘"
  → 기간 확장 조회, 월별 비교 분석
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

> 빌링 조회에는 `corpId`만 필요하다. 고객사 계정 프로필 생성이나 STS 토큰은 불필요.

## Step 2 — 월별 OnDemand 비용 조회

서비스별 비용 Top 10 조회:

```bash
CORP_ID="a1b2c3d4-e5f6-7890-abcd-ef1234567890"

"$SKILL_DIR/billing-api.sh" POST "/api/v1/costs/ondemand/corp/monthly" \
  '{"from": "202604", "to": "202604", "corpId": "'${CORP_ID}'"}' \
  | jq '[.body[] | {serviceName, usageFee}] | group_by(.serviceName) | map({service: .[0].serviceName, total: (map(.usageFee) | add)}) | sort_by(-.total) | .[:10]'
```

응답 예시:
```json
[
  {"service": "Amazon Elastic Compute Cloud", "total": 8234.56},
  {"service": "Amazon Relational Database Service", "total": 3456.78},
  {"service": "Amazon Simple Storage Service", "total": 1234.56},
  {"service": "AWS Lambda", "total": 456.78},
  {"service": "Amazon CloudFront", "total": 234.56}
]
```

전체 합계 계산:

```bash
"$SKILL_DIR/billing-api.sh" POST "/api/v1/costs/ondemand/corp/monthly" \
  '{"from": "202604", "to": "202604", "corpId": "'${CORP_ID}'"}' \
  | jq '[.body[].usageFee] | add'
```

## Step 3 — 인보이스 조회

청구 내역 확인:

```bash
"$SKILL_DIR/billing-api.sh" POST "/api/v1/invoice/corp/monthly" \
  '{"billingPeriod": "202604", "corpId": "'${CORP_ID}'"}' \
  | jq '.body[] | {invoiceDivision, invoiceItem, usageFee, usageFeeKrw, currencyCode}'
```

응답 예시:
```json
{
  "invoiceDivision": "AWS 사용료",
  "invoiceItem": "AWS 서비스 사용료",
  "usageFee": 13616.24,
  "usageFeeKrw": "18,366,708",
  "currencyCode": "USD"
}
{
  "invoiceDivision": "할인",
  "invoiceItem": "RI 할인",
  "usageFee": -2345.67,
  "usageFeeKrw": "-3,162,153",
  "currencyCode": "USD"
}
{
  "invoiceDivision": "청구금액",
  "invoiceItem": "총 청구금액",
  "usageFee": 11270.57,
  "usageFeeKrw": "15,204,555",
  "currencyCode": "USD"
}
```

## Step 4 — 결과 보고

에이전트 응답 포함 내용:
1. **월별 총 비용** — OnDemand 기준 총액 + 인보이스 기준 청구 총액
2. **서비스별 비용 Top 10** — 어떤 서비스가 가장 많은 비용을 차지하는지
3. **청구 구조** — AWS 사용료, 할인(RI/SP/크레딧), 최종 청구 금액
4. **환율 정보** — USD → KRW 환산 금액 및 적용 환율

---

## Step 5 — 후속 프롬프트: 3개월 비용 추이

### 사용자 프롬프트

```
지난 3개월 비용 추이도 보여줘
```

### 에이전트 동작

기간을 확장하여 월별 비용 추이 조회:

```bash
"$SKILL_DIR/billing-api.sh" POST "/api/v1/costs/ondemand/corp/monthly" \
  '{"from": "202602", "to": "202604", "corpId": "'${CORP_ID}'"}' \
  | jq '[.body[] | {billingPeriod, usageFee}] | group_by(.billingPeriod) | map({month: .[0].billingPeriod, total: (map(.usageFee) | add)}) | sort_by(.month)'
```

응답 예시:
```json
[
  {"month": "202602", "total": 11234.56},
  {"month": "202603", "total": 12456.78},
  {"month": "202604", "total": 13616.24}
]
```

에이전트 분석:
- 2월 → 3월: +$1,222 (+10.9% 증가)
- 3월 → 4월: +$1,160 (+9.3% 증가)
- 3개월간 지속적 증가 추세 → 서비스별 상세 분석 권장

---

## 포인트 정리

이 예제에서 보여주는 핵심:

1. **AWS 계정 접근 불필요**: `corpId`만으로 빌링 데이터 직접 조회 — 프로필 생성/STS 토큰 불필요
2. **OnDemand + 인보이스 병행 조회**: 순수 사용 비용과 실제 청구 금액을 구분하여 제공
3. **jq 집계 활용**: 서비스별 그룹핑, 월별 합산, 정렬을 한 줄로 처리
4. **기간 확장**: `from`/`to` 파라미터만 변경하여 추이 분석으로 확장
5. **환율 포함**: 인보이스 API가 원화 환산액과 환율을 함께 제공
