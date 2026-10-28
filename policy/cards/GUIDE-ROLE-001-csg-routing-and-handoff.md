---
id: GUIDE-ROLE-001
title: CSG role routing and handoff
status: active
applies_to: [ticket-routing, escalation, poc, architecture, managed-operations, billing-platform, ai-workload]
triggers: [sa, ts, msp, ai, cop, finops, architecture, poc, incident, runbook, billing-platform, rebilling, billing-error, ai-workload, handoff]
source_document: SRC-CSG-JD-001
source_location: "SRC-CSG-JD-001 lines 5-237; team-specific variants SRC-SA-JD-001, SRC-TS-JD-001, SRC-MSP-JD-001, SRC-AI-JD-001, SRC-COP-JD-001 lines 3-end"
source_owner: "Not recorded; job descriptions carry no owner"
source_version: "undated; no version"
effective_from: 2026-10-01
applicability: "[company] Routing work between CSG teams; customer-specific primary/secondary ownership and contracts override it"
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

# CSG role routing and handoff

## Control statement

Route work by the human team's documented purpose while preserving contract and customer ownership. SA owns requirement analysis, architecture, technical validation, and design handoff; MSP owns contracted managed operations and customer lifecycle, and also what the source assigns to TS (the TS team no longer exists; its work is part of the MSP team, so anything that would go to TS is routed to the MSP team as a general ticket); AI owns AI/ML architecture and PoC/production-transition support; the FinOps team (옛 COP팀, formerly named COP) owns 빌링 플랫폼/Rebilling platform and billing-data system issues. This mapping routes work but does not grant an AI agent authority to execute a human team's write operations.

## Scope

- Applies to ticket assignment suggestions, escalation, cross-team handoff, PoC ownership, and the selection of a separate implementation project.
- Does not establish current staffing, on-call ownership, customer-specific primary/secondary assignment, or approval authority.

## Required behavior

1. Identify the customer support tier and request type before choosing a team.
2. Route architecture, Well-Architected review, technical validation, and design/build handoff to SA.
3. Route general-customer troubleshooting, project technical support, AWS Support escalation, and runbook work to the MSP team as a general ticket (there is no TS team).
4. Route contracted MSP incidents, reports, optimization, primary/secondary ownership, and onboarding/offboarding to MSP.
5. Route AI architecture, AI PoC, model/data pipeline, and AI production-transition questions to AI.
6. Route 빌링 플랫폼/Rebilling, cost allocation, billing-data pipeline, and platform defects to the FinOps team (옛 COP팀).
7. Record the handoff question, evidence, owner, expected result, and receiving repository/team.
8. Verify current ownership in the billing platform or with a human; do not infer it from role documents alone.

## Prohibited behavior

- Treating a team JD as customer contract scope
- Executing a human team's account, deployment, billing, support-case, or platform-write action
- Routing solely by a person's name from a stale document
- Assuming individual team files supersede the aggregate CSG document
- Using role evaluation metrics as customer commitments

## Exceptions and escalation

- Team-specific JDs add competency levels and sometimes stronger execution language than the aggregate source. No version/effective-date metadata establishes precedence; resolve conflicts with CSG leadership.
- Customer-specific primary/secondary ownership and contracts override generic role routing.
- The FinOps team (옛 COP팀) owns platform billing accuracy while MSP reports cost/resource status through 빌링 플랫폼; the sources do not define the final owner who approves a customer-facing billing figure. Apply the billing-platform-only repository rule and obtain current FinOps/MSP confirmation.
- The source job descriptions predate two changes: the COP team was renamed the FinOps team (people still say COP, so write "옛 COP팀" when naming it), and the TS team was dissolved into the MSP team. Where a source section describes TS or COP, apply the current structure above.

## Evidence

- `SRC-CSG-JD-001:5-59` — SA covers business requirements, architecture, PoC/verification, project scope/risk, and handoff.
- `SRC-CSG-JD-001:64-99` — TS covers general/project support, incident/change/problem management, AWS escalation, and runbooks.
- `SRC-CSG-JD-001:104-144` — MSP covers managed operations, SLA incidents, reports, advice, primary/secondary ownership, and onboarding/offboarding.
- `SRC-CSG-JD-001:149-181` — AI covers AI/ML architecture, PoC, production transition, workshops, and operational alignment.
- `SRC-CSG-JD-001:186-217` — COP covers Rebilling, cost allocation, billing data, platform change/incident management, and data separation.
- `SRC-SA-JD-001:3-58`, `SRC-TS-JD-001:3-74`, `SRC-MSP-JD-001:3-84`, `SRC-AI-JD-001:3-68`, `SRC-COP-JD-001:3-66` — team-specific variants add competency and detailed responsibility but provide no explicit version precedence.

## Change history

- 2026-10-01 — Re-read the CSG aggregate source against the card (SHA-256 matches `sources.json`); the team-specific variants were not re-read. Applied two owner corrections the source predates: the COP team is now the FinOps team (written "옛 COP팀"), and the TS team no longer exists — its work routes to the MSP team as general tickets. `source_document` now names the single registered source `SRC-CSG-JD-001` because the validator needs one registered id. Precedence between the aggregate and team-specific JDs is still unresolved (Exceptions). Activated by 유지보수자.
