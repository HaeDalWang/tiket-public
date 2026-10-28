---
source_id: SRC-SUPPORT-PLAN-001
source_type: de-identified-internal-reference
channel: pasted text and table screenshot
captured_at: 2026-10-01 KST
source_owner_role: not recorded
source_link: not supplied
reported_by: repository owner
authority_basis: repository owner relayed an instruction from a senior executive to activate the derived card; not independently verified
---

# 빌링 플랫폼 기준 AWS Support Plan 설명 — 비식별 source excerpt

고객사명 1개, 계정 ID 2개, 비고란의 고객사명 2개는 제외했다. 나머지는 원문 그대로다.

## 텍스트

> PLS: Partner-Led Support
> - AWSDeveloperSupport : Account 기준 tiering
> - AWSSupportEssential(BS+) : 고객이 AWS Business Support+ 를 선택한 경우. Account 기준 tiering
> - AWSSupportBusiness+ : PLS 고객 대상 AWS Business Support+. 고객별 기준 tiering.
> - AWSSupportEnterprise : Account 기준 tiering.
> - AWS Support Enterprise(EDP): EDP 고객 대상 고객별 기준 tiering
> - BusinessSupport+(NXT): AWS 사용 요금 * 10% ([특정 고객사] 의 계정 2개에 적용)
>
> ※ EDP 등 계약으로 Support가 지정된 경우 해당 계약에 따릅니다. (별도 요금 체계 생성 ex. AWSSupportEnterprise(EDP))

## 표 (스크린샷 전사)

| Service Code | Service Name | Tiering Type | 적용가능 Payer Type | 202603 설정 여부 | 비고 |
|---|---|---|---|---|---|
| AWSBasicSupport | AWS Basic Support | Account | PLS / RESOLD / EDP | O | |
| AWSDeveloperSupport | AWS Developer Support | Account | PLS / RESOLD / EDP | O | |
| AWSSupportEssential(BS+) | AWSSupportEssential(BS+) | Account | RESOLD / EDP | O | |
| BusinessSupport+(NXT) | BusinessSupport+(NXT) | Account | (공란) | O | AWS 사용 요금 * 10% (특정 고객사 적용) |
| AWSSupportBusiness+ | AWSSupportBusiness+ | Corp | PLS | O | |
| AWSSupportEnterprise(EDP) | AWS Support Enterprise(EDP) | Corp | EDP | O | (고객사명 2개 제외) |
| AWSSupportEnterprise | AWS Support Enterprise | Account | PLS / RESOLD | X | |

## Normalization note

- `[특정 고객사]` 는 제외한 고객 식별 정보의 자리표시자다.
- 표의 `202603 설정 여부` 열은 2026년 3월 시점의 설정을 가리킨다. 이 문서에는 다른 날짜나 버전이 없다.
