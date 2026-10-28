---
id: POLICY-COST-ESC-001
title: Cost inquiry handoff and no-response escalation
status: active
applies_to: [customer-cost-inquiry, billing, reserved-instances, savings-plans, discount, invoice, billing-cost]
triggers: [cost, billing, invoice, RI, reserved-instance, savings-plan, SP, discount, commitment, 비용, 청구, 할인, 약정]
source_document: SRC-COST-ESC-001
source_location: "policy/excerpts/SRC-COST-ESC-001-cost-inquiry-csr-handoff.md lines 13-32"
source_owner: MSP team lead
source_version: "Slack announcement; MSP 주요 사항 updated 2026-08-26"
effective_from: 2026-08-26
applicability: "Customer cost-related tickets handled through the MSP support workflow"
reviewed_at: 2026-08-26
reviewed_by: Hermes Agent
review_by: 2026-11-26
authority_verified_at: "2026-08-26 10:05 KST"
approved_by: MSP team lead
approved_at: "2026-08-26 10:05 KST"
activation_blocker: ""
retired_at: ""
retirement_reason: ""
replacement: ""
supersedes: ""
---

# Cost inquiry handoff and no-response escalation

## Control statement

Handoff every customer cost-related ticket to CSR in Slack with the prescribed mention and ticket link. If CSR does not respond within the announced interval, escalate in the same thread to the CSR team lead; after the additional interval without response, escalate by phone to an MSP or CSR team lead. AI agents prepare drafts and timestamps only; humans post Slack messages and place calls.

## Scope

- Applies to customer questions about cost, billing, invoices, RI, Savings Plans, discounts, commitments, or other customer-visible financial treatment.
- Applies whether the originating technical question is handled by MSP, SA, or another CSG function.
- Does not determine the technical answer, contract entitlement, Payer model, or customer-facing cost figure.
- Does not authorize an agent to post to Slack, mention users, or place a phone call.
- CSR is the sales side: "hand to CSR" and "hand to sales" in other cards mean the same handoff (`POLICY-COC-001`).

## Required behavior

1. Classify the ticket as a cost inquiry and record `POLICY-COST-ESC-001` in the ticket.
2. A human posts the following handoff in Slack with a live ticket link: `@csr [고객사명] 비용 문의 티켓입니다. 확인 부탁드립니다 → 티켓 링크`.
3. Record the Slack handoff time and source reference without copying customer names or personal Slack identities into tracked Git files.
4. If there is no CSR response within 6 hours, a human escalates in the same thread to the CSR team lead and includes the prescribed non-response icon from the live MSP 주요 사항 entry.
5. If there is still no response for an additional 1 hour, a human calls an MSP team lead or CSR team lead.
6. Append each handoff, response, and escalation event to the ticket history using de-identified team/role references.
7. Continue to apply `POLICY-PAYER-001`, customer contract checks, and the billing-platform-curated customer-output boundary when the answer includes an actual cost, discount, entitlement, or billing commitment.

## Prohibited behavior

- Do not expose raw AWS billing figures in the customer reply.
- Do not treat CSR handoff as confirmation of a technical conclusion, discount, contract term, or final cost.
- Do not invent the missing icon, a Slack identity, a phone number, or a response-time interpretation not present in the source.
- Do not store customer names, ticket URLs containing sensitive identifiers, personal Slack identities, or phone numbers in tracked policy or ticket files.
- AI agents must not post the Slack handoff or place escalation calls.

## Exceptions and escalation

- The supplied source does not define whether “6 hours” and “additional 1 hour” mean elapsed or business hours. Follow the current live MSP 주요 사항 entry or obtain human clarification before calculating an automated deadline.
- The exact prescribed non-response icon was omitted from the supplied excerpt. A human must copy it from the live entry; agents must leave it unresolved.
- The source does not define call priority between the MSP and CSR team leads. A human selects the appropriate lead based on current availability and the live process.
- `POLICY-PAYER-001` and `GUIDE-ROLE-001` remain applicable for contract, Payer, product, and ownership questions. This card controls the newer, specific CSR handoff timeline for cost inquiries.

## Evidence

- Source: `SRC-COST-ESC-001`
- Location: `policy/excerpts/SRC-COST-ESC-001-cost-inquiry-csr-handoff.md:13-32`
- Authority: live announcement by the MSP team lead stating that the CSR handoff process was updated in MSP 주요 사항.
- Verbatim process: `@csr` handoff with customer name and ticket link → 6 hours without response → CSR team lead escalation in thread with icon → additional 1 hour without response → phone escalation to an MSP or CSR team lead.

## Change history

- 2026-08-26 — Activated from a live MSP team-lead Slack announcement; exact icon and hour interpretation remain explicit operational unknowns rather than activation blockers.
