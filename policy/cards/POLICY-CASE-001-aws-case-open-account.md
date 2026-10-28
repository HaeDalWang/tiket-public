---
id: POLICY-CASE-001
title: Which account to open an AWS Support Case from
status: active
applies_to: [aws-case, aws-support, refund-case, ri-case, pls-support-plan, quota-increase, case-on-behalf]
triggers: [aws-case, support-case, refund, credential-leak, unauthorized-usage, 무단-사용, 요금-조정, extended-support, ri-purchase, ri-cancel, support-plan-change, quota, quota-increase, main-payer, pls-technical-support]
source_document: SRC-CASE-001
source_location: "MSP 엔지니어가 AWS Support Case 를 여는 계정 안내 + 메인 Payer 보완 (repository owner 가 2026-10-01 에 두 번 붙여넣음); 원문 일자·버전 없음"
source_owner: MSP team lead
source_version: "Slack MSP 팀 내부 사항; no version in the text — date fixed as 2026-09-27 by the repository owner"
effective_from: 2026-09-27
applicability: "[team: MSP] Applies when an MSP engineer needs to open an AWS Support Case; the [PLS] rows apply to PLS accounts"
reviewed_at: 2026-10-06
reviewed_by: Claude Code
review_by: 2027-01-04
authority_verified_at: "2026-10-06"
approved_by: repository owner
approved_at: "2026-10-06"
activation_blocker: ""
retired_at: ""
retirement_reason: ""
replacement: ""
supersedes: ""
---

# Which account to open an AWS Support Case from

## Control statement

Open the AWS Support Case from the main Payer account for refund, RI, and PLS support-plan cases, and for a case opened on a customer's behalf. For PLS quota increases, request through the PLS technical Slack channel instead of opening a case. Agents prepare the case text; humans open cases and post requests.

## Scope

- Applies when: an MSP engineer must choose where to open an AWS Support Case.
- Does not cover TAM escalation of an open case; see `POLICY-TAM-001`.
- "Main Payer" is resolved per customer as defined below.

## Required behavior

Which account is the main Payer:

| Customer model | Main Payer account |
|---|---|
| Not a separate-Payer customer | The MSP main Payer, account `111122223333`; open cases from it |
| Separate-Payer customer | That customer's own `msp-<customer>` account, which is the main Payer |

"Separate Payer" means the same as the standalone Payer of `POLICY-PAYER-001` (단독 / 독립 / 별도 Payer). Under that model the customer pays AWS directly, but the `msp-<customer>` account used as the main Payer for cases is a separate account owned by MSP 회사.

Access to a separate-Payer account belongs to the assigned MSP engineer; in special cases the CSG leader or the FinOps team (옛 COP팀) holds it.

Which route to use:

| Case type | Route |
|---|---|
| Refund after access key or credential leak (for example Bedrock) | Open the case from the main Payer |
| Refund after a mistake (for example Extended Support) | Open the case from the main Payer |
| Mistaken RI purchase and its cancellation | Open the case from the main Payer |
| PLS support plan upgrade or downgrade | Open the case from the main Payer |
| [PLS] Quota increase | Fast request in the PLS technical Slack channel |
| [PLS] Customer's technical support case opened on its behalf | Open the case from the main Payer; if urgent, also fast request in the PLS technical Slack channel |

1. Determine whether the customer is separate-Payer (the billing platform or the ticket), then classify the request against the table before choosing a route.
2. Record the chosen route and the case number or Slack request time in the ticket history using role references.
3. A human opens the case or posts the Slack request.

Refund after a credential leak or other security incident, for a PLS customer (repository owner, 2026-10-27):

4. The assigned MSP engineer opens the refund (billing) case from the MSP main Payer. The customer does not open it.
5. The customer is told only how the case is going — opened, what AWS asked for, waiting, closed.
6. Whether a charge is adjusted, and by how much, stays between AWS and the MSP. Any amount the customer hears comes from the sales manager.
7. The reply draft lists what the customer must do to stop the unauthorized activity — AWS asks the account to confirm these actions: update and then delete exposed access keys, check every IAM user's keys and passwords and deactivate users nobody created, review CloudTrail event history and delete unsanctioned keys, policies, roles, and resources, and put MFA on the root user. Take the steps from the current AWS page (https://repost.aws/knowledge-center/potential-account-compromise), not from memory. Where that page says to review charges in Cost Explorer, point the customer to the billing platform instead (`POLICY-BILL-001` step 9).

## Prohibited behavior

- Do not open a case from a customer's member account when this card routes it to the main Payer.
- Do not assume access to a separate-Payer account; if you are not the assigned MSP engineer, route through the CSG leader or the FinOps team (옛 COP팀).
- Do not copy any customer account ID into tracked files.
- Do not open an AWS Case or post to Slack from an agent session.
- Do not apply a `[PLS]` row to a non-PLS account without a human confirming it.
- Do not tell a customer whether an incident charge will be adjusted or by how much, and do not estimate it (step 6).

## Exceptions and escalation

- The source does not say how to tell a separate-Payer customer from any other. Resolve it through the billing platform or the ticket; if unresolved, ask a human.
- `POLICY-PAYER-001` says the standalone-Payer customer owns its own Payer account; the `msp-<customer>` account named here is a different, MSP-owned account used for opening cases. Do not treat the two as the same account.
- A technical case — the customer's own or one opened on its behalf — is not available while the account is on Basic Support. See `POLICY-CASE-002` for the raise-open-lower path.
- The source marks only two rows `[PLS]`. Whether the other four rows are PLS-only is unknown.
- The source does not say what to do for a case type outside the table. Ask a human.
- Steps 4–7 were stated for PLS customers. Who opens the case and what the customer is told for a non-PLS customer is unknown; ask a human.
- The Slack channel name appears in `POLICY-TAM-001`; the Slack channel is a request route, not a case.

## Evidence

- Source document: `SRC-CASE-001` (Slack is the original; excerpt in `policy/excerpts/`)
- Page/section: MSP 엔지니어가 AWS SupportCase 를 여는 경우 어느 계정에서 열어야 하는가
- Verbatim source excerpt:

> MSP 엔지니어가 AWS SupportCase을 여는 경우 어느 계정에서 열어야하는가??
> 액세스키, 자격증명 유출 (ex. bedrock)으로 인한 환불케이스 => 메인 페이어에서 case open
> 실수(ex. extended support) 로 인한 환불케이스 => 메인 페이어에서 case open
> RI 실수 구매 및 취소에 대한 케이스 => 메인 페이어에서 case open
> PLS support plan 업/다운그레이드 케이스 => 메인 페이어에서 case open
> [PLS] quota 증설에 관한 케이스 => PLS technical slack channel로 빠른요청
> [PLS] 고객의 technical support case 대행 오픈 요청 => 메인 페이어에서 case open, 급하면 PLS technical slack channel로 빠른요청

- Supplement (second paste), customer name and the MSP case account ID omitted, rest verbatim:

> 별도 페이어가 아닌 모든고객은 MSP 회사 계정이 메인페이어 > MSP 회사 케이스 계정: [계정 ID 생략]
> 별도 페이어 고객의 경우 해당 고객사 예를 들어 "[고객사명]" > "msp-[고객사명]" 계정 존재 해당 계정이 메인페이어
> > 별도 페이어접근 권한은 담당 MSP엔지니어이나 특별한 경우 CSG리더나 빌링 플랫폼 팀(옛 cop팀)이 권한을 가지고있음

## Change history

- 2026-10-06 — Activated. The repository owner (final approver for these cards) approved it, named the MSP team lead as source owner, and fixed the source date as 2026-09-27.
- 2026-10-27 — Added steps 4–7 (refund after a security incident, PLS customer: who opens the case, what the customer is and is not told, what the reply asks the customer to do). Source: the repository owner, closing a 2026-09-29 field lesson that found no card answering it.
