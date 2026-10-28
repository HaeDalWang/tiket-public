---
id: POLICY-ESC-001
title: Ticket review, escalation ladder, and AWS case record
status: active
applies_to: [ticket-review, internal-escalation, aws-support-escalation, am-escalation, case-record]
triggers: [escalation, aws-support, aws-case, tam, severe-issue, service-quota, case-tag, internal-memo, reference]
source_location: "SPT-005 (5.1, 5.2.1-5.2.7, 5.3) and SPT-006"
applicability: "[team: MSP] Applies to every customer ticket from review to close, and to any ticket for which an AWS Support Case is opened"
source_document: SRC-FTR-SPT-001
source_owner: "The MSP — document submitted to AWS for the Partner-Led Support FTR"
source_version: "[MSP 회사] Support Operations(SPT).docx, FTR-PLS 2.0 (deck NEW_PLS_FTR_MSP_202411, 2024-11)"
effective_from: 2026-10-08
reviewed_at: 2026-10-08
reviewed_by: Claude Code
review_by: 2027-04-08
authority_verified_at: "2026-10-08"
approved_by: repository owner
approved_at: "2026-10-08"
activation_blocker: ""
retired_at: ""
retirement_reason: ""
replacement: ""
supersedes: ""
---

# Ticket review, escalation ladder, and AWS case record

## Control statement

Answer a ticket from official AWS sources and team references first. Escalate inside CSG when those do not settle it, to AWS Support when CSG cannot confirm it or an official answer is needed, and to the AWS TAM only for a severe issue. A ticket with an AWS case carries the case in an internal memo and in tags, so the next engineer can find it. Agents prepare the text; humans escalate, open cases, tag, and reply.

## Scope

- Applies when: a customer ticket is being reviewed, escalated, answered, or closed.
- Does not cover: which account opens the case (`POLICY-CASE-001`), a Basic Support account (`POLICY-CASE-002`), TAM requests (`POLICY-TAM-001`), Kubernetes questions (`POLICY-K8S-001`), or cost inquiries (`POLICY-COST-ESC-001`).

## Required behavior

Review, in this order:

1. Make the question precise. Confirm account, region, and resource; if something needed is missing, ask the customer for it.
2. Check the official AWS pages (FAQ, Documentation, re:Post) and earlier case history.
3. Check team references.

Escalate one step at a time, and only when the step before did not settle it:

| Step | When | To whom |
|---|---|---|
| Internal | No official statement and no team reference — mostly general technical and incident questions | The CSG team that owns the workload (table below), with the question and what has been confirmed so far written out clearly |
| AWS Support | CSG cannot confirm it either, or an official answer is needed | An AWS Support Case — after the checks below |
| AWS TAM | A severe issue, in addition to the case | A TAM request under `POLICY-TAM-001` — the source says AM; the AM contact is gone and the TAM route replaced it |

Who to ask inside CSG. The source's team list (SA, DevOps, ProServ, CMP) is from before a reorganization; DevOps, ProServ, and CMP no longer exist. Use today's owners:

| Workload | Ask |
|---|---|
| References across workloads in general, architecture | SA (`GUIDE-ROLE-001`) |
| Container (ECS, EKS) | The container part (타이거 파트) — and for Kubernetes, `POLICY-K8S-001` applies first |
| AI | The AI team (`GUIDE-ROLE-001`) |
| Billing | The FinOps team (옛 COP팀) — see Exceptions; cost inquiries follow `POLICY-COST-ESC-001` |
| CI/CD, DB, Data Science, Network, Media, CDN | No team to escalate to — the assigned MSP engineer handles these. When the engineer cannot settle it, the next step is AWS Support |

Before an AWS Support Case:

4. Check the account's AWS Support Plan. If it is Basic, a technical inquiry is not possible — follow `POLICY-CASE-002`.
5. Tell the sales manager — always; every customer has one. Tell the SA with a short Slack message; some customers have no clear SA, and then this part is skipped.
6. Write the case so AWS can act on it: Account ID, Region, Resource, and Timeline with time zone (start to end) for a technical or incident inquiry; Account ID and issue details for an account or cost inquiry (plus Region and resource ID for an RI or SP change). Choose chat when fast support is needed, and copy the group mailbox.

A severe issue, for a TAM request, is one of:

- part or all of a customer workload is down and fast support is needed;
- an AWS-side issue is affecting a customer workload;
- it is unclear whether the cause is on the customer side (application and so on) or the AWS side;
- a Service Quota must be changed urgently.

After a case is opened, the ticket must carry:

7. An internal memo with `Account`, `Case ID`, and `Case` (a short summary of what was opened).
8. Tags: `aws_support_tech_case` and the AWS service name for a technical case; `aws_support_billing_case` for a billing case.
9. Each case update as a further internal memo, and a final summary memo.

When the ticket record sends a matter to an AWS case, the record's hand-off to the engineer lists these as the engineer's own to-do items, each one written out: tell the sales manager and the SA (step 5), the case text fields (step 6), and the memo and tags to leave once the case is open (steps 7–9). Citing this card is not enough; the engineer reads the record, not the card.

When answering and closing:

10. Confirm with the sales manager, and the SA where there is one, before the answer goes out when needed; anything about cost is confirmed with the sales manager first.
11. If other customers may be affected around the same time, share it inside the organization. If most customers may be affected, report to the team lead and the CSG group head so a notice to all customers can be considered (`GUIDE-HEALTH-001`).

## Prohibited behavior

- Do not jump to an AWS case before the official sources and CSG references have been checked.
- Do not open a case, tag a ticket, write a Zendesk memo, or contact the AM from an agent session.
- Do not write the account ID of the internal memo into a tracked file; it belongs in the ticket system.
- Do not send a cost-related answer that the sales manager has not confirmed.
- Do not treat the TAM route as a substitute for an open case; it comes alongside the case, and `POLICY-TAM-001` requires the case to be open first.

## Exceptions and escalation

- The source lists DevOps (Container, CI/CD, AI), ProServ (DB, Data Science, Network, Media, CDN), and CMP (Billing). The repository owner confirmed on 2026-10-08 that all three were removed in a reorganization. The DevOps team was dissolved; its container work remains in the container part (타이거 파트), held by one engineer. CMP was the development organization and is probably today's FinOps team — the owner's reading, not a recorded fact. The workloads ProServ and DevOps used to take (CI/CD, DB, Data Science, Network, Media, CDN) now stay with the assigned MSP engineer.
- The source routes Container (EKS) questions to the DevOps team as ordinary internal escalation. `POLICY-K8S-001` is narrower and newer: Kubernetes support is not ordinary ticket support. Follow `POLICY-K8S-001`.
- The source escalates a severe issue to the AWS AM (account manager); the AM contact no longer exists and the TAM took its place. The four criteria above are the source's; the conditions and channel for the request are `POLICY-TAM-001`'s (PLS account, an open case, the part lead's decision). A severe issue on an account that does not meet those conditions is reported to the team lead and the CSG leader, who choose the route; the agent says to report it and does not pick a route.
- Searching earlier cases by tag is done in Zendesk (`tags: aws_support_tech_case`, plus the service). An agent session cannot search Zendesk by tag; ask the engineer.

## Evidence

- Source document: `SRC-FTR-SPT-001` (excerpt in `policy/excerpts/`)
- Page/section: SPT-005 — 시스템 흐름도, 내부 프로세스(티켓 검토, 내부 에스컬레이션, AWS Support 에스컬레이션, AM 에스컬레이션, 티켓 처리, 티켓 종료), AWS support case 내용 공유; SPT-006
- Verbatim source excerpt:

> CSG 조직 내에서도 문의 및 요청 사항에 대한 내용을 확인할 수 없거나 공식 답변이 필요할 때 AWS Support로 에스컬레이션 합니다.
> AWS Support Plan이 Basic인 경우 기술 문의는 불가하기 때문에, 고객에게 Support Plan 업그레이드를 권장할지 영업 담당자와 확인해야 합니다.
> AWS Support Plan을 확인한 이후 AWS Support로 에스컬레이션 하기 전 영업 담당자와 SA 담당자에게 해당 내용을 공유하고, AWS Support에서 케이스 오픈을 진행합니다.
> 필요한 경우 담당 영업 및 SA와 확인 하에 고객에게 답변을 전달해야 하며, 특히 비용과 관련된 부분은 영업 담당자와 확인 후 답변해야 합니다.

## Change history

- 2026-10-08 — Created and activated from the FTR-PLS 2.0 Support Operations document. The repository owner (final approver for these cards) stated the document is the one defined between the MSP and AWS and is in force.
