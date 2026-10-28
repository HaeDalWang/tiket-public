---
id: GUIDE-SUPPORT-PLAN-001
title: The billing platform AWS Support Plan service codes and tiering
status: active
applies_to: [aws-support-plan, billing-platform, support-tiering, pls, payer-type]
triggers: [support-plan, aws-support, business-support-plus, bs-plus, enterprise-support, edp, pls, resold, tiering, payer-type, service-code]
source_document: SRC-SUPPORT-PLAN-001
source_location: "policy/excerpts/SRC-SUPPORT-PLAN-001-billing-platform-support-plan-codes.md, whole file (pasted text and table screenshot, 2026-10-01)"
source_owner: "Not recorded in the source; authority rests on the maintainer's approval, given on a senior-executive instruction"
source_version: "undated text; table column '202603 설정 여부' (March 2026 snapshot)"
effective_from: 2026-10-01
applicability: "[company] Billing-platform billing reference for how each AWS Support Plan service code is tiered and which Payer types it applies to. Not a statement of a customer's MSP support grade"
reviewed_at: 2026-10-01
reviewed_by: Claude Code
review_by: 2026-12-30
authority_verified_at: "2026-10-01 KST"
approved_by: maintainer
approved_at: "2026-10-01 KST"
activation_blocker: ""
retired_at: ""
retirement_reason: ""
replacement: ""
supersedes: ""
---

# The billing platform AWS Support Plan service codes and tiering

## Control statement

Use this card only to read what a billing platform Support Plan service code means: its tiering basis (per Account or per Corp/customer) and the Payer types it can apply to. It does not identify any customer's plan, set a price for a customer, or define the MSP support grade. A contract that assigns Support (for example EDP) overrides the standard row.

## Scope

- Applies when: a ticket asks what a Support Plan code means, how it is tiered, or which Payer type it fits.
- Does not apply when: deciding a customer's MSP support level (see `POLICY-SUPPORT-001`) or quoting a cost to a customer (see `POLICY-PAYER-001` and the billing-platform-curated output boundary in `CLAUDE.md`).
- Terminology: PLS = Partner-Led Support; PLS, RESOLD, and EDP are Payer types in the table.

## Required behavior

1. Read the code, tiering type, and Payer type from the table below; treat blank cells as unknown.
2. Confirm the customer's actual plan and Payer type from the billing platform before applying a row to a customer.
3. If a contract fixes the Support plan, follow the contract and treat the standard row as background.
4. Treat the `202603` column as a March 2026 snapshot; re-verify current configuration before relying on it.

## Prohibited behavior

- Do not state or imply a customer's plan, Payer type, or fee from this card alone.
- Do not give the customer-specific fee figure (the `NXT` percentage) or any raw AWS billing figure in a customer reply; customer-facing cost figures must be billing-platform-curated.
- Do not equate an AWS Support Plan code with the billing platform/MSP support level; the mapping between the two is unresolved (`policy/pending-review.md` item 4).
- Do not copy customer names or account IDs from the source into tracked files.

## Exceptions and escalation

- The text and the table disagree or are incomplete: the text omits `AWSBasicSupport`; the table leaves the Payer type for `BusinessSupport+(NXT)` blank. Treat these as unknown and ask a human.
- `AWSSupportEnterprise` is marked not configured (`X`) in the `202603` column. Whether that is still true is unknown.
- `BusinessSupport+(NXT)` is applied to one specific customer's accounts (named in the source, omitted here). Confirm it in the billing platform; it does not belong in this card.
- Two rows carry customer names in the notes column (omitted here).

## Evidence

- Source document: `SRC-SUPPORT-PLAN-001` (`policy/excerpts/SRC-SUPPORT-PLAN-001-billing-platform-support-plan-codes.md`)
- Page/section: whole excerpt
- Authority: the repository owner (the maintainer) confirmed the content and approved activation on 2026-10-01, acting on a senior executive's instruction; the agent did not verify the source independently.
- Source text, abridged (customer name and account IDs omitted):

> PLS: Partner-Led Support
> - AWSDeveloperSupport : Account 기준 tiering
> - AWSSupportEssential(BS+) : 고객이 AWS Business Support+ 를 선택한 경우. Account 기준 tiering
> - AWSSupportBusiness+ : PLS 고객 대상 AWS Business Support+. 고객별 기준 tiering.
> - AWSSupportEnterprise : Account 기준 tiering.
> - AWS Support Enterprise(EDP): EDP 고객 대상 고객별 기준 tiering
> - BusinessSupport+(NXT): AWS 사용 요금 * 10% ([특정 고객사] 의 계정 2개에 적용 — 이름·계정 ID 생략)
>
> ※ EDP 등 계약으로 Support가 지정된 경우 해당 계약에 따릅니다. (별도 요금 체계 생성 ex. AWSSupportEnterprise(EDP))

- Table, transcribed from the screenshot (notes-column customer names omitted):

| Service Code | Service Name | Tiering Type | Payer Type | 202603 set | Note |
|---|---|---|---|---|---|
| AWSBasicSupport | AWS Basic Support | Account | PLS / RESOLD / EDP | O | |
| AWSDeveloperSupport | AWS Developer Support | Account | PLS / RESOLD / EDP | O | |
| AWSSupportEssential(BS+) | AWSSupportEssential(BS+) | Account | RESOLD / EDP | O | |
| BusinessSupport+(NXT) | BusinessSupport+(NXT) | Account | (blank) | O | AWS 사용 요금 * 10% (특정 고객사 적용) |
| AWSSupportBusiness+ | AWSSupportBusiness+ | Corp | PLS | O | |
| AWSSupportEnterprise(EDP) | AWS Support Enterprise(EDP) | Corp | EDP | O | (고객사명 2개 생략) |
| AWSSupportEnterprise | AWS Support Enterprise | Account | PLS / RESOLD | X | |

## Change history

- 2026-10-01 — activated on a senior executive's verbal instruction relayed by the repository owner; source owner and source version remain unrecorded and the `202603` column is a March 2026 snapshot, so the 3-month review date applies
