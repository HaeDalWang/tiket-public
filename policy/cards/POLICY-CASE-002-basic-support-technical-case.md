---
id: POLICY-CASE-002
title: Technical AWS case for a Basic Support account
status: active
applies_to: [aws-case, aws-support, basic-support, support-plan-change, case-on-behalf]
triggers: [basic-support, technical-case, support-plan-upgrade, support-plan-downgrade, case-on-behalf, pls]
source_document: SRC-CASE-002
source_location: "저장소 주인이 2026-10-08 에 적은 팀 규칙과 같은 날의 보충 답변; 문서 원본 없음"
applicability: "[team: MSP] Applies when a technical AWS Support Case is needed for an account whose AWS Support Plan is Basic"
source_owner: repository owner (MSP engineer); the rule is set verbally within the MSP team
source_version: "no written original; written down and date fixed as 2026-10-08 by the repository owner"
effective_from: 2026-10-08
reviewed_at: 2026-10-08
reviewed_by: Claude Code
review_by: 2027-01-08
authority_verified_at: "2026-10-08"
approved_by: repository owner
approved_at: "2026-10-08"
activation_blocker: ""
retired_at: ""
retirement_reason: ""
replacement: ""
supersedes: ""
---

# Technical AWS case for a Basic Support account

## Control statement

An account on Basic Support cannot get a technical AWS Support Case: the customer cannot open one, and the MSP cannot open one on its behalf either. When a technical case is truly needed, the path is to raise the account's AWS Support Plan to PLS Business, open and resolve the case, then lower the plan again before the next month's charge. Agents prepare the text; humans change the plan and open cases.

## Scope

- Applies when: a ticket needs AWS technical support for an account whose AWS Support Plan is Basic.
- Does not apply when: the account is already above Basic — choose the route in `POLICY-CASE-001`.
- Does not cover: Kubernetes questions, which are out of scope at every AWS Support Plan; see `POLICY-K8S-001`.

## Required behavior

Most MSP customers' accounts are on AWS Basic Support or PLS (Partner-Led Support); do not confuse either with the billing platform/MSP Support Level (`POLICY-SUPPORT-001`).

1. Confirm the account's AWS Support Plan before promising or drafting anything about an AWS case (the billing platform support-plan codes: `GUIDE-SUPPORT-PLAN-001`). If it cannot be confirmed, state it as unknown and ask a human.
2. If the plan is Basic, tell the engineer that a technical case is not available as-is — including on the customer's behalf.
3. Raise the plan only when the case is truly needed. The customer pays for the raised month, so before raising it: the customer agrees first — knowing that it is charged to them — and is told what will be done, and the account's sales manager is informed.
4. The assigned MSP engineer carries it out: raise the AWS Support Plan to PLS Business, open the case, see it resolved. The plan-change case goes through the main Payer (`POLICY-CASE-001`).
5. Lower the AWS Support Plan back within one month of raising it; past one month the charge is made a second time. Record the date it was raised and the date one month later in the ticket history.
6. The sales manager phones the customer each time to tell them about the one-month limit and the charge. Leave that for the sales manager; note in the ticket that the call is needed.
7. Record the customer's agreement, the notice to the sales manager, and the case number in the ticket history using role references.

## Prohibited behavior

- Do not tell a Basic Support customer that the MSP will open a technical case for them, or that they can open one themselves.
- Do not treat "opened on the customer's behalf" (`POLICY-CASE-001`) as a way around Basic Support.
- Do not raise the AWS Support Plan without the customer's prior agreement, or without the sales manager knowing.
- Do not leave the raised plan in place past one month.
- Do not quote a price for the raised plan in a customer reply; customer-facing cost figures must be billing-platform-curated (`CLAUDE.md`). Say that the charge is the customer's and that the sales manager will give the amount.
- Do not suggest the MSP will absorb the charge.
- Do not change a support plan or open an AWS Case from an agent session.

## Exceptions and escalation

- The source says "above Basic, PLS"; the repository owner fixed the target as PLS Business and the payer as the customer (2026-10-08).
- If the case is not resolved within the month, the customer's agreement is asked for again and the raised plan runs another month, charged again. Raise it with the sales manager before the month ends; the plan is not left raised without that renewed agreement.
- The cut-off is one month from the day the plan was raised.
- An account under a Payer that is not PLS takes the same path.
- The rule has no written original. It is set verbally within the MSP team and was written down by the repository owner.

## Evidence

- Source document: `SRC-CASE-002` (no written original; excerpt in `policy/excerpts/`)
- Page/section: whole excerpt
- Verbatim source excerpt:

> 베이직 서포트는 고객사가 직접 기술 케이스를 못염 우리가 대신해도 절대 못열어줌 서포트레벨을 베이직 이상 PLS로 올린 후 케이스열고 해결하고 한달후에 비용나가기전에 다시 레벨을 내려야하는 절차를 밣아야함

- Supplement (same day):

> 실제 서포트케이스 올리는거는 담당 MSP엔지니어가 해야하며, 담당영업 매니저도 알아야한다, 고객에게는 진짜 필요하시면 먼저 동의를 받고 공유한뒤 올린다

- Corroboration: `SRC-FTR-SPT-001` SPT-005 (AWS Support 에스컬레이션):

> AWS Support Plan이 Basic인 경우 기술 문의는 불가하기 때문에, 고객에게 Support Plan 업그레이드를 권장할지 영업 담당자와 확인해야 합니다.

## Change history

- 2026-10-08 — Created and activated. The repository owner (final approver for these cards) wrote the rule down, confirmed it is an actual rule set verbally each time, and added who acts, who must know, and that the customer agrees first.
