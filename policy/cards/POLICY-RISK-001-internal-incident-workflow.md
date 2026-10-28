---
id: POLICY-RISK-001
title: Internal incident classification and response workflow
status: draft
applies_to: [incident, operational-risk, security-risk, escalation, post-incident]
triggers: [critical, high, medium, low, incident, major-risk, escalation, postmortem, recurrence-prevention]
source_document: SRC-CSG-RISK-001
source_location: "lines 381-458"
effective_from: unknown
reviewed_at: 2026-08-24
reviewed_by: Hermes Agent
review_by: 2026-05-12
activation_blocker: "CSG Leadership must confirm the current version and set a new review date"
supersedes: ""
---

# Internal incident classification and response workflow

## Control statement

Use the CSG risk framework to prepare internal incident classification, escalation, communication ownership, post-incident analysis, and recurrence-prevention tracking. Do not present its internal response times as a customer's contractual SLA/SLT. The source is marked approved but its next review date has passed, so current applicability requires human confirmation.

## Scope

- Applies to internal classification of operational/security incidents and major risks.
- Applies to routing an incident to leadership, technical, customer-response, and security owners.
- Does not replace the customer's SLA, SOW, COC live process, or security-incident contractual notice deadline.

## Required behavior

1. Share the incident or major risk in the Slack `general` channel. An agent drafts the post; a human posts it.
2. The assigned MSP engineer resolves a major risk. For a security incident, if the customer has an assigned SA engineer, share it with them as well so they are aware and handle it together with the MSP engineer.
3. Record initial classification, assigned response team, recovery evidence, customer-communication owner, post-incident analysis, and prevention action.
4. Keep technical response, customer communication, and security response ownership distinct.
5. Reconcile this internal workflow with `POLICY-SUPPORT-001` before quoting any customer-facing time.

## Prohibited behavior

- Treating internal Critical/High/Medium/Low times as a customer contractual commitment
- Sending customer incident communication from an agent session
- Triggering recovery or infrastructure changes without a human-controlled process
- Using the overdue Raw roster as current contact information

## Exceptions and escalation

- Customer contract/SLA controls customer-facing commitments.
- The current COC/on-call process controls live routing after human verification.
- Security incidents may have a separate contractual or legal notification deadline.
- A `general` post reaches the whole company, and `POLICY-SEC-001` (active) restricts sharing customer security information. [Needs owner confirmation] Until confirmed, the post carries a de-identified summary: a customer reference, no account ID, IP, or credential.

## Evidence

- `SRC-CSG-RISK-001:381-416` — governance assigns risk, finance, security, and team roles; major risks are reported immediately and tracked through mitigation/result reporting.
- `SRC-CSG-RISK-001:421-430` — the source defines internal Critical/High/Medium/Low impact and response/escalation levels.
- `SRC-CSG-RISK-001:432-441` — workflow covers immediate detection/reporting, 15-minute classification, 30-minute team assembly, recovery, ongoing customer communication, 24-hour analysis, and one-week prevention action.
- `SRC-CSG-RISK-001:443-450` — incident, technical, customer-response, and security roles are separated.
- `SRC-CSG-RISK-001:455-458` — version 1.0, updated 2026-02-12, review due 2026-05-12, marked approved by the MSP CSG Leadership.

## Change history

- 2026-08-24 — Drafted; source review is overdue and current incident ownership requires human confirmation.
