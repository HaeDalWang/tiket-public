---
id: GUIDE-ONBOARD-001
title: Customer onboarding readiness and handoff
status: active
applies_to: [customer-onboarding, architecture-baseline, access-readiness, monitoring, handoff]
triggers: [new-customer, onboarding, kickoff, access-setup, monitoring-setup, handoff, operation-start]
source_document: SRC-CUSTOMER-ONBOARD-001
source_location: "lines 70-200, 330-467"
source_owner: "Not recorded; the source approval rows are blank"
source_version: "v1.0, last updated 2026-02-12; next review after an onboarding retrospective"
effective_from: 2026-10-01
applicability: "[company] Completeness checklist for MSP customer onboarding and the SA-to-MSP handoff; a customer SOW/SLA overrides it"
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

# Customer onboarding readiness and handoff

## Control statement

Use the source as a completeness checklist, not blanket authorization to modify a customer account. Before operational handoff, document the current architecture, establish approved access, verify monitoring/backup/ticket paths, record unresolved risk, and obtain the required human confirmations.

## Scope

- Applies to new MSP/customer onboarding and transition from design/build to operations.
- Applies to ticket context, access readiness, documentation, monitoring, backup, escalation, and handoff.
- Does not authorize an agent to create IAM users, modify networks, enable services, configure alarms, or perform any customer-account write.

## Required behavior

1. Capture the current environment and customer-approved architecture baseline.
2. Identify every access or configuration item that requires a human owner and customer approval.
3. Verify least privilege, MFA, and secure credential delivery in the human-controlled implementation plan.
4. Complete SA-to-MSP handoff with architecture intent, known issues, customer requirements, and checklist status.
5. Before declaring onboarding complete, verify access, monitoring, alarms, backup/restore, ticketing, communication, documents, and escalation contacts.
6. Record incomplete items, risk level, owner, and target date.
7. Obtain human approval from the required customer and internal roles.

Joining the MSP organization (account consolidation, FTR ACM-003). "TS" in the source is the assigned MSP engineer today.

8. An account can belong to one AWS Organization only. An account that is in the customer's own or another MSP's organization must leave it before the invitation can be accepted.
9. The sales owner (CSR) creates the ticket. Its requester is the customer's AWS contact, the sales owner and the management-support team are always in CC, and its title is `[MSP 회사/고객사명] 신규 계정 통합 안내`.
10. The COC sends the organization invitation for the shared Payers; for a customer on a separate Payer, that customer's assigned engineer sends it. The invitation is done when its state is `ACCEPTED`; `OPEN` means the customer has not approved yet.
11. What the customer is told at consolidation, and what a later ticket can rest on:
    - From acceptance on, usage and cost information moves to the MSP's account. **The customer cannot see billing in their own console afterwards, even as the root user** — the billing platform is where they see it.
    - Usage from the 1st of the month up to the moment of consolidation is billed by AWS the way it was before.
    - The billing report is sent between the 5th and the 10th of each following month; the tax invoice is in won.
    - The customer is asked to set up the cross-account role (`POLICY-ACCESS-002`) and, when the account has remaining credit, to enable billing access for IAM so the credit can be seen.
    - Account-protection advice goes out with it: use least-privilege IAM users rather than the root user, MFA for every user, and safe handling of access keys.
12. A billing platform customer record, account entry, and user are created at this point. That is done by a person with the right to create them.

## Prohibited behavior

- Executing IAM, network, monitoring, security, backup, or billing changes from an agent session
- Treating a blank checklist item as evidence that the control is complete
- Declaring onboarding complete without handoff evidence and human confirmation
- Copying credentials or customer security information into the ticket repository
- Writing a billing platform ID, an initial password, or the rule it is made by into a record or a reply draft. The source sets the initial password by a fixed rule; it is deliberately not carried here
- Sending the organization invitation, or creating billing-platform records, from an agent session

## Exceptions and escalation

- Customer-specific SOW/SLA and access constraints override the generic checklist.
- Unsupported or high-risk controls require a separate PoC or implementation project.

## Evidence

- `SRC-CUSTOMER-ONBOARD-001:75-98` — architecture review, documentation, and customer review/approval are checklist items.
- `SRC-CUSTOMER-ONBOARD-001:103-137` — IAM, network, CLI, ticket, channel, document, and monitoring access are explicit setup items with assigned roles.
- `SRC-CUSTOMER-ONBOARD-001:339-347` — SA-to-MSP handoff includes design intent, known issues, customer characteristics, and checklist confirmation.
- `SRC-CUSTOMER-ONBOARD-001:352-385` — final verification, document finalization, completion report, customer confirmation, first report/meeting, and retrospective.
- `SRC-CUSTOMER-ONBOARD-001:438-446` — the source contains approval rows for customer, CSR, SA, MSP, and CCoE leadership.
- `SRC-FTR-ACM-001` — ACM-003 입점 (입점 시 제한 사항, Zendesk Ticket, 조직 초대 및 계정 설정, 빌링 플랫폼 계정 생성): steps 8–12. Verbatim: "통합 이후 \"AWS root\" 계정으로 접속하더라도 빌링 정보 조회가 불가능합니다."
- `SRC-CUSTOMER-ONBOARD-001:466-468` — version 1.0, updated 2026-02-12; next review is after an onboarding retrospective.

## Change history

- 2026-10-01 — Re-read every cited range against the source (SHA-256 matches `sources.json`); activated by the maintainer. The source has no recorded owner or approval and is a checklist, so the card stays a completeness guide and the review date is three months out.
