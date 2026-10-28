---
id: POLICY-OT-001
title: Night and holiday emergency response ticket recording
status: active
applies_to: [after-hours, holiday, emergency-response, ticket-recording, ot-tag]
triggers: [ot, ot-tag, overtime, night, holiday, after-hours, emergency-response, internal-ticket]
source_document: SRC-OT-001
source_location: "MSP 팀 내부 사항, '야간 및 공휴일 긴급 대응시 티켓 관리 (2025.4.10)' (repository owner 가 2026-10-01 에 붙여넣음)"
source_owner: MSP team lead
source_version: "dated 2025-04-10 in the source heading; current as of 2026-09-27 per the repository owner"
effective_from: 2025-04-10
applicability: "[team: MSP] Applies to night and holiday emergency response handled on a ticket"
reviewed_at: 2026-10-06
reviewed_by: Claude Code
review_by: 2027-01-04
authority_verified_at: "2026-10-06"
approved_by: repository owner
approved_at: "2026-10-06"
activation_blocker: ""
retired_at: ""
retirement_reason: ""
replacement: ""
supersedes: ""
---

# Night and holiday emergency response ticket recording

## Control statement

Every night or holiday emergency response must be recorded on the ticket with the response time and an `OT` tag. When a member handles another member's ticket, a separate internal ticket carries the `OT` tag, response time, a short description, and a reference to the related ticket.

## Scope

- Applies when: a night or holiday emergency response is performed on a ticket.
- Does not define what counts as an emergency. How an out-of-hours request is accepted and passed on is in `POLICY-COC-001`.

## Required behavior

1. Add the response time to the ticket content.
2. Add the `OT` tag.
3. If handling another member's ticket, create a separate internal ticket with the `OT` tag, the response time, a short description, and the related ticket reference.
4. Agents draft the entries; humans add them to Zendesk.

## Prohibited behavior

- Do not close an emergency response without the response time and `OT` tag.
- Do not write to Zendesk from an agent session.

## Exceptions and escalation

- The source states that OT tickets get a separate review and that extra credit in performance evaluation is "planned" (가점예정). This is stated intent, not a confirmed rule; do not cite it to a person as an entitlement.
- The source does not define the response-time format or the emergency threshold. Ask a human.

## Evidence

- Source document: `SRC-OT-001` (Slack is the original; excerpt in `policy/excerpts/`)
- Page/section: MSP 팀 내부 사항, 야간 및 공휴일 긴급 대응시 티켓 관리
- Verbatim source excerpt:

> 야간 및 공휴일 긴급 대응시 티켓 관리 ( 2025.4.10 )
> 1. 티켓에 대응 시간을 내용에 추가
> 2. OT 태그를 추가
> 3. 만일 다른 멤버의 티켓을 대신 처리하는 경우에는 별도로 내부 티켓을 생성 및 OT 태그와 대응시간, 간략한 내용 또는 연관 티켓에 대한 정보기록
> 4. OT 티켓은 별도 리뷰 하고, 업무 평가시 가점예정

## Change history

- 2026-10-06 — Activated. The repository owner (final approver for these cards) approved it, named the MSP team lead as source owner, and fixed the source date as 2026-09-27.
