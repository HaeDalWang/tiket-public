---
id: POLICY-SUPPORT-001
title: Contract-dependent service scope and response targets
status: active
applies_to: [support-scope, ticket-severity, response-time, emergency-support, customer-duty]
triggers: [sla, slt, critical, high, medium, low, response-time, business-hours, emergency, 24x7, support-contract]
source_document: SRC-BILLING-TERMS-001
source_location: "lines 24-89, 127-137, 247-251"
source_owner: "Not recorded in the source (standard terms of service)"
source_version: "빌링 플랫폼 MSP 서비스 표준 약관, effective 2025-04-02"
effective_from: 2026-10-01
applicability: "Default baseline unless the ticket thread, ITSM notes, or the engineer records an exception, separate SLA/SOW/addendum, or non-applicability"
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

# Contract-dependent service scope and response targets

## Control statement

Use the standard terms as the default baseline unless the ticket thread, ITSM notes, or the engineer records an exception, separate SLA/SOW/addendum, or non-applicability. Classify the request by the applicable severity model and distinguish a target (`SLT`) from a compensation-bearing commitment. Legally consequential interpretation still requires actual-contract verification.

## Scope

- Applies to questions about support hours, severity, first-response targets, monitoring, incident response, reports, and emergency support.
- Applies to obligations assigned to the customer or company under the standard terms.
- Does not replace a customer-specific contract, SLA, SOW, or addendum.

## Required behavior

1. Check the ticket thread and ITSM notes (or ask the engineer) for recorded exceptions, separate SLA/SOW/addendum, or non-applicability before quoting scope or time.
2. Distinguish normal operating hours from separately contracted 24x7 emergency support.
3. Describe response times as targets unless the customer contract states otherwise.
4. Confirm customer prerequisites such as least-privilege access, change notice, payment, and cooperation with security measures.
5. If a security incident is confirmed and the terms apply, route the customer-notification deadline to a human owner; an agent must not send the notification.

Severity is chosen at intake (the customer may set it) and means:

| Level (terms) | Item | Meaning | First-response target |
|---|---|---|---|
| Critical | 운영 시스템 중단 | A critical function is down at a level that affects the business | within 1 hour |
| High | 운영 시스템 손상 | A critical function is impaired or performance is severely degraded | within 4 hours |
| Medium | 시스템 손상 | A non-critical function behaves abnormally | within 12 hours |
| Low | 일반 지침 | A general question or a request for guidance | within 24 hours, during normal operating hours |

Response time runs from the customer's submission to the first response. Any other level of SLA is by separate contract.

6. Customers reach the Support Desk by phone, mail, or the support portal; a ticket needs a title, a description, and the company. The intake form asks for Account ID, service, region, resource, and the time of the error or the requested work window — when one of these is missing and needed, ask for it.
7. Every customer can see their own inquiry history in the support portal. A customer with an MSP contract also gets the technical-support history in the monthly report.

## Prohibited behavior

- Promising 24x7 response without confirming the additional contract
- Treating the standard-terms SLT as an unconditional SLA or damages commitment
- Quoting a severity response time without classifying the incident
- Using this card as proof that a specific customer accepted the terms
- Sending customer notification directly

## Exceptions and escalation

- When a customer-specific agreement conflicts with this card, the customer-specific agreement controls after human verification.
- Contract interpretation, damages, termination, and legal disputes require human/legal review.
- The billing platform customer Support Level may define support hours, 24x7 eligibility, severity, and routing independently of the AWS Support Plan. This card remains blocked for those claims until the authoritative Support Level PDF is ingested and reviewed.

## Evidence

- `SRC-BILLING-TERMS-001:24-30` — the terms become effective when the customer enters the service agreement.
- `SRC-BILLING-TERMS-001:37-49` — service scope includes design/build support, monitoring/incident response, ticket support, cost optimization, security, and reports; details are set by a separate SLA.
- `SRC-BILLING-TERMS-001:51-69` — normal hours are weekdays 09:00–18:00 KST; 24x7 emergency support applies only when separately contracted; severity response values are described as targets.
- `SRC-BILLING-TERMS-001:71-89` — customer and company duties include least-privilege access and confidentiality.
- `SRC-BILLING-TERMS-001:127-137` — the source states customer notification within 24 hours after awareness of a security incident.
- `SRC-BILLING-TERMS-001:247-251` — the source states an effective date of 2025-04-02.

- `SRC-FTR-SPT-001` SPT-001·003·004·010 — the same four levels and targets as the terms, with a plain definition of each level; ticket intake fields; inquiry channels; history in the portal and the MSP monthly report.

## Change history

- 2026-10-01 — Re-read every cited range against the source (SHA-256 matches `sources.json`); removed the required step to record the severity classification and why it applies (owner decision); activated by the maintainer. The Support Level PDF is still outstanding (pending-review item 4), so the 24x7 and Support Level claims stay blocked as the Exceptions section says.
