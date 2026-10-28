---
id: GUIDE-HEALTH-001
title: AWS Health events: SHD and PHD monitoring and customer notice
status: active
applies_to: [aws-health, shd, phd, service-event, customer-notice]
triggers: [aws-health, health-dashboard, shd, phd, outage, service-event, 장애, 공지, rss, region-issue, notice]
source_location: "SPT-009 (9.1 주요 절차, 9.2 SHD 프로세스) and SPT-002 2.2.4 (PHD 대응, AWS Health Status 전파)"
applicability: "[team: MSP] Applies when a ticket asks whether AWS is having an issue, or follows an AWS Health event"
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

# AWS Health events: SHD and PHD monitoring and customer notice

## Control statement

The COC watches AWS service health continuously and account-level health notices daily. A regional event is shared inside the company; a notice to all customers goes out only after the CSG group head approves it, and the CSM sends it. When a ticket asks about an AWS-side issue, check the public Health Dashboard and what has already been announced before answering.

## Scope

- Applies when: a customer asks whether an AWS service or region is having trouble, or a ticket was created from a PHD notice.
- Does not cover: incident handling for the customer's own workload (`POLICY-COC-001`, `POLICY-ESC-001`).

## Required behavior

1. For a service-status question, read the AWS Health Dashboard (`https://health.aws.amazon.com/health/status`) at the time of the ticket and cite what it shows with the time read. Recalled status is not evidence.
2. Check whether the COC has already shared the event internally, and whether a customer notice has gone out, before drafting. If you cannot tell, ask the engineer.
3. Service-wide events (SHD): the COC monitors the AWS status RSS feed in Slack and the Health Dashboard. For an issue in us-east-1, ap-northeast-1, ap-northeast-2, or ap-southeast-1, the COC summarizes it in the general Slack channel.
4. Notice to all customers: only when the issue is severe or long enough to affect customers, after the CSG group head approves; the CSM in charge writes it up and mails all customers.
5. Account-level notices (PHD): the COC checks them every morning at 09:00, informs each affected customer individually, and passes major ones on by mail and phone. When a service disruption is expected, it is shared in the general Slack channel.
6. If a ticket shows other customers may be affected, raise it as `POLICY-ESC-001` step 11 says.

## Prohibited behavior

- Do not tell a customer that AWS has, or does not have, an issue from memory.
- Do not send or draft-as-sent a notice to all customers; it needs the CSG group head's approval and is sent by the CSM.
- Do not post to Slack or mail customers from an agent session.
- Do not tell the customer whether other customers are affected, and do not say you are checking other customers or will report back on them. What the customer can be pointed to is the public Health Dashboard and their own account's Health notices.
- Do not promise a notice, or that one will follow "as soon as it is confirmed". Whether a notice goes out is not the agent's or the engineer's decision.
- Do not describe the internal chain to the customer — the COC, the CSM, the approval step. Those are for the engineer's section of the record.
- Do not write in the reply that a check or a request has been made ("확인을 요청해 두었습니다") when the record only asks the engineer to make it.

## Exceptions and escalation

- The region list differs inside the source: the COC duties name Seoul, Tokyo, Singapore, and Virginia; the FTR deck names global services plus Seoul, Japan, and the United States. Treat the four regions above as the minimum and ask a human for anything else.
- The source describes PHD notices arriving as tickets through an automated daily job. How to recognize such a ticket is not recorded.
- Phone notice depends on the customer's contract (`POLICY-SUPPORT-001`).

## Evidence

- Source document: `SRC-FTR-SPT-001` (excerpt in `policy/excerpts/`)
- Page/section: SPT-009 — 주요 절차, SHD 확인 방식, SHD 공지(내부 공지, 고객 공지); SPT-002 — PHD 대응, AWS Health Status 전파
- Verbatim source excerpt:

> RSS feed ( COC ) ->  해당 고객 email 전파 ( COC ) -> 공동 이벤트의 경우 Slack 전파 -> 내부 리뷰 -> 고객 전체 공지
> AWS Service상 문제가 심각하거나 오랜 시간 지속되어 고객에 지장이 있을 여지가 있는 경우 CSG 그룹장 승인 이후 아래에 절차에 따라 CSM에서 전체 고객 대상으로 내용을 공지합니다.
> COC는 매일 아침 9시에 PHD 알림을 확인하고, 주요 이슈는 고객에게 이메일과 전화로 전파합니다.

## Change history

- 2026-10-08 — Created and activated from the FTR-PLS 2.0 Support Operations document. The repository owner (final approver for these cards) stated the document is the one defined between the MSP and AWS and is in force.
