---
id: POLICY-COC-001
title: COC intake, ticket assignment, and night incident response
status: active
applies_to: [coc, ticket-assignment, after-hours, night-response, incident-communication]
triggers: [coc, cloud-operation-center, night, after-hours, 야간, 긴급, assignment, 배정, call, incident, slack-notice, csr]
source_location: "SPT-002 (2.2 COC 정의·근무체계·주요 업무, 2.3 야간 대응 프로세스 메뉴얼)"
applicability: "[team: MSP] Applies when a ticket or incident arrives through the COC, during or outside normal operating hours"
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

# COC intake, ticket assignment, and night incident response

## Control statement

The Cloud Operation Center (COC) runs 24x7: it takes calls and alarms, assigns tickets, and passes incidents to the people responsible. At night the COC collects what the customer reported, hands it to the responsible SA and MSP engineer, and announces it in Slack; the engineer diagnoses and keeps the customer updated, and the sales team leads customer communication. An out-of-hours request that the customer calls urgent is treated as urgent first; the COC and the sales owner (the CSR) decide the response. Agents draft; humans call, post, and reply.

## Scope

- Applies when: a ticket was assigned by the COC, or an incident is being handled outside normal operating hours.
- Does not cover: how a night or holiday response is recorded on the ticket (`POLICY-OT-001`), response-time targets and whether 24x7 support is contracted (`POLICY-SUPPORT-001`), or alarm thresholds (`GUIDE-MONITOR-001`).

## Required behavior

Assignment:

1. A ticket from an MSP customer goes to that customer's assigned engineer. A ticket from a general customer is assigned by ticket count.
2. Outside business hours, a request is urgent when the customer says it is — treat it as urgent first rather than judging the claim. The COC and the CSR owner, who is the sales side, decide the response. Once they decide to respond, the request goes to the general-ticket owners in turn.

Night incident response:

3. The COC learns of the incident from the customer's report or from alarm monitoring, and collects the customer's description quickly and accurately.
4. The COC passes it at once to the responsible SA and MSP engineer. Owners are fixed per MSP customer; an owner who cannot resolve it hands it up to the next owner.
5. The COC announces the incident and its details in Slack so everyone involved sees the symptom and the progress.
6. Communication runs in real time over Slack or phone; the AWS contact is brought in when needed.
7. Roles: the MSP engineer diagnoses the cause and, when needed, has an AWS case opened (`POLICY-ESC-001`); the SA reviews the infrastructure and talks with the customer when needed; the sales team leads customer communication and connects the AWS contact when needed.
8. The MSP engineer keeps monitoring until a technical resolution exists and updates the customer on progress.
9. Record the response on the ticket as `POLICY-OT-001` requires.

Other COC duties an engineer will meet on a ticket: non-AWS inquiries are redirected and noted for the CSR; alarms are graded L1, L2, L3 and passed on as agreed with the customer; a high-severity GuardDuty alarm agreed in advance is passed on like an L3 incident; PHD notices are checked every morning at 09:00 (`GUIDE-HEALTH-001`).

## Prohibited behavior

- Do not promise a customer an out-of-hours response. The decision belongs to the COC and the sales owner, and 24x7 support exists only where contracted (`POLICY-SUPPORT-001`).
- Do not downgrade a request the customer has called urgent.
- Do not reassign a ticket, post to Slack, or phone anyone from an agent session.
- Do not close a night response without the record `POLICY-OT-001` requires.

## Exceptions and escalation

- The source is dated 2024-11 and says "TS team" and "TS 담당자". The TS team has since been dissolved into the MSP team (`GUIDE-ROLE-001`); read TS as the assigned MSP engineer.
- The source gives the COC's head count and shift pattern as of 2024-11. They are not copied here; staffing changes, and no ticket decision depends on the number.
- The CSR owner is the sales side, and the COC runs 24 hours a day, 365 days a year. The order in which general-ticket owners are asked is not recorded.
- "Urgent" has no firm definition yet. The working rule is the customer's own word: if the customer says urgent, it is handled as urgent first.

## Evidence

- Source document: `SRC-FTR-SPT-001` (excerpt in `policy/excerpts/`)
- Page/section: SPT-002 — COC 주요 업무(티켓 배정), 야간 대응 프로세스 개요, 문의 접수 시 행동 강령
- Verbatim source excerpt:

> MSP 고객의 경우 담당 TS 인원에게 티켓을 배정하고, 일반 고객의 경우 티켓 수를 고려하여 임의로 배정합니다. 업무시간 외 긴급 지원 요청이 있을 경우 CSR 담당자와 협의하여 긴급 대응 여부를 결정합니다. 긴급 대응이 결정되면, General 티켓 담당자에게 순차적으로 대응 요청을 합니다.
> TS 팀은 문제의 원인을 진단하고, 필요한 경우 AWS Case를 열어 공식 지원을 요청합니다.
> 영업 팀은 고객과의 주된소통을 담당하며, 필요시 AWS 담당자와의 연결점을 잡습니다.

## Change history

- 2026-10-08 — Created and activated from the FTR-PLS 2.0 Support Operations document. The repository owner (final approver for these cards) stated the document is the one defined between the MSP and AWS and is in force.
