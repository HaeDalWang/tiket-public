---
id: POLICY-DATA-001
title: Contract termination and customer data lifecycle
status: active
applies_to: [contract-termination, customer-offboarding, data-transfer, data-deletion, retention]
triggers: [termination, offboarding, migration, data-transfer, delete, retention, access-revocation, destruction-certificate]
source_document: SRC-BILLING-TERMS-001
source_location: "lines 142-180"
source_owner: "Not recorded in the source (standard terms of service)"
source_version: "빌링 플랫폼 MSP 서비스 표준 약관, effective 2025-04-02"
effective_from: 2026-10-01
applicability: "Default baseline unless the ticket thread, ITSM notes, or the engineer records an exception, separate SLA/SOW/addendum, or non-applicability; actual contract verification required for termination and legal retention"
reviewed_at: 2026-10-01
reviewed_by: Claude Code
review_by: 2027-03-31
authority_verified_at: "2026-10-01 KST"
approved_by: maintainer
approved_at: "2026-10-01 KST"
activation_blocker: ""
retired_at: ""
retirement_reason: ""
replacement: ""
supersedes: ""
---

# Contract termination and customer data lifecycle

## Control statement

Use the standard terms as the default baseline unless the ticket thread, ITSM notes, or the engineer records an exception. Treat contract termination as a controlled data-transfer, access-revocation, retention, and deletion process. Do not execute any transfer or deletion from this workspace. Prepare evidence and a human-controlled plan, and verify the actual contract with CSR/legal before using a termination or legal-retention deadline.

## Scope

- Applies to customer offboarding, data migration, access removal, retained operational data, and deletion requests.
- Applies only after confirming the standard terms or an equivalent customer agreement governs the customer.

## Required behavior

1. Confirm the termination was shared: the sales owner (CSR team) normally shares it, but if that did not happen it must be shared anyway. The assigned engineer, the sales owner, and the CSG leader must all be aware of every contract termination, normally by a Slack share. An agent drafts the share message; a human posts it.
2. Confirm the termination date, written notice, customer request, and applicable contract.
3. Identify customer-owned data separately from company-generated operational data.
4. Record the requested destination and human approval for transfer.
5. Prepare access revocation and deletion verification; do not execute it.
6. Verify and apply retention/deletion precedence: law/legal obligation → customer-specific contract/SLA/SOW → active standard terms.
7. Encrypt retained data and restrict it to the stated purpose.
8. Record expiry and destruction evidence for each retained category.
9. If sources conflict or legal basis is unknown, do not select a period or propose deletion; obtain CSR/legal determination.

Leaving the MSP organization. How it runs today — the manual steps in FTR ACM-004 have been replaced by an automated flow:

10. The customer tells the sales owner they want to leave.
11. The sales owner enters it in the automated Slack app. The system carries out the account termination, and the COC sends the customer the notice by mail.
12. The sales owner shares it in the general Slack channel.
13. The assigned MSP engineer needs to be aware of it, nothing more. In a ticket, the agent's part is to tell the engineer whether that sharing is visible in the thread, and to point a customer who asks about leaving to their sales owner.

Facts from FTR ACM-004 that still explain what a customer sees:

14. A member account can leave by itself only under the MSP Consolidated Billing Payer. Every other Payer has an SCP that denies `organizations:LeaveOrganization`, so a customer who tries gets access denied; that is by design.
15. Removal from the organization fails with access denied when the account has no valid payment method — expired, or never entered because the account was created inside the organization.

## Prohibited behavior

- Deleting customer data without confirmed approval and contract basis
- Treating the standard 15-business-day or 30-day period as universal
- Retaining operational data for an undefined future need
- Executing offboarding, access revocation, migration, or deletion from an agent session

## Exceptions and escalation

- The source's "TS 계정 해지 담당자" no longer exists as a role; termination is automated and the COC handles the notice. Whether the automated flow also covers the source's other manual steps (deleting the SNS subscription in MC accounts, setting the customer to not-in-use in 빌링 플랫폼) is not recorded.

- Legal retention requirements and a customer deletion request may conflict; escalate to legal/human review.
- If the customer-specific agreement sets different periods, apply that agreement after verification.

## Evidence

- `SRC-BILLING-TERMS-001:155-163` — requested data transfer is targeted within 15 business days; access is revoked after transfer; absent a request, deletion follows 30 days with final notice.
- `SRC-BILLING-TERMS-001:165-180` — the source lists conditional retention periods, encryption, purpose limitation, customer deletion request, expiry destruction, and optional destruction confirmation.
- `SRC-FTR-ACM-001` — ACM-004 퇴점 (퇴점 시 제한 사항): steps 14–15. Steps 10–13 are the repository owner's account of today's flow. Verbatim: "MSP 회사 Consolidated Billing를 제외한 Payer에는 멤버계정이 조직을 탈퇴할 수 없도록 scp가 설정되어 있기 때문에 고객이 직접 퇴점할 수 없습니다."

## Change history

- 2026-10-01 — Re-read every cited range against the source (SHA-256 matches `sources.json`); added the first required step, that every contract termination is shared with the assigned engineer, the sales owner, and the CSG leader (owner instruction, not in the source); activated by the maintainer. The "active Offboarding guide" tier was dropped from the retention hierarchy because `POLICY-OFFBOARD-001` was removed the same day and no such guide is active; add the tier back when one is activated.
