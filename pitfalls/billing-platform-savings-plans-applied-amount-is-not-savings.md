---
observed:
  - 2026-10-20 | ticket 100022
sources:
  - 2026-10-26 | aws-doc | https://docs.aws.amazon.com/cur/latest/userguide/cur-sp.html | 표기 없음
review_by: 2027-04-24
---

# 빌링 플랫폼 Trend 의 Savings Plans 적용 금액(`ApplySavingsPlan*`)을 "할인액" 으로 안내하면 틀린다 — 커버된 사용량의 온디맨드 환산액이고, 절감액은 여기서 약정 비용을 뺀 값이다

## 무엇을 하면 틀리는가

- 빌링 플랫폼 비용 화면에서 Savings Plans 적용 항목의 금액을 보고 "이만큼 할인받았다" 고 답한다.
- 그 금액을 Savings Plans 효과(절감액)로 보고서·회신에 옮긴다.

## 실제로 있었던 일

- 2026-10-20: 고객 비용 문의를 처리하다 `ApplySavingsPlan*` 금액을 할인액으로 읽었다가, 커버된 사용량을 온디맨드 단가로 환산한 값이라는 것이 드러나 정정했다.

## 확인된 사실

- AWS CUR 에서 Savings Plans 가 적용된 사용량은 `SavingsPlanCoveredUsage` 줄로 남고, 그 줄의 비용은 **Savings Plans 가 없었다면 냈을 온디맨드 요금**이다.
  같은 금액을 `SavingsPlanNegation` 줄이 상쇄한다. 실제로 그 사용량에 매겨진 값은 `savingsPlan/SavingsPlanEffectiveCost` 다
  (https://docs.aws.amazon.com/cur/latest/userguide/cur-sp.html).
- 그래서 절감액 = 온디맨드 환산액 − 실제 약정 비용(effective cost)이다. 환산액 자체는 절감액이 아니다.

`unknown` — 빌링 플랫폼 `ApplySavingsPlan*` 칸이 CUR 의 어느 값(Negation 인지 CoveredUsage 인지)과 같은지는 빌링 플랫폼 문서·API 로 확인하지 않았다.
후보의 승인 판단(2026-10-21)과 위 CUR 정의가 일치할 뿐이다.

## 해야 할 것

1. 빌링 플랫폼의 Savings Plans 적용 금액을 할인액이라고 쓰지 않는다. "Savings Plans 가 적용된 사용량의 온디맨드 기준 금액" 이라고 쓴다.
2. 고객이 절감액을 물으면 빌링 플랫폼이 보여 주는 절감·약정 항목으로 답한다. 원시 AWS 청구 금액은 회신에 쓰지 않는다 — CUR 는 칸의 뜻을 이해하는 데만 쓴다.
3. 어느 칸이 절감액인지 화면에서 가를 수 없으면 단정하지 않고, 비용 문의 인계 카드(`POLICY-COST-ESC-001`)를 따른다.

## 다시 쓰기 전에 확인할 것

- 빌링 플랫폼 Trend 의 Savings Plans 관련 칸 이름과 정의가 그대로인지 — 포털 화면 또는 Admin API 응답.

## 변경 이력

- 2026-10-26: 작성. 2026-10-21 승인된 교훈 후보에서 옮겼다. 승인 때 후보 근거가 지워져 티켓 경위는 후보 한 줄에서만 가져왔다.
