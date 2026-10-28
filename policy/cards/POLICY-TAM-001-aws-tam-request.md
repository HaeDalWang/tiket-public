---
id: POLICY-TAM-001
title: AWS TAM request conditions and channel
status: active
applies_to: [aws-tam, aws-case, pls-account, escalation]
triggers: [tam, aws-tam, technical-account-manager, pls, aws-case, case-escalation, aws-tam-technical-support]
source_document: SRC-TAM-001
source_location: "MSP 팀 내부 사항, 항목 2 (repository owner 가 2026-10-01 에 붙여넣음); 원문 일자·버전 없음"
source_owner: MSP team lead
source_version: "Slack MSP 팀 내부 사항; no version in the text — date fixed as 2026-09-27 by the repository owner"
effective_from: 2026-09-27
applicability: "[team: MSP] Applies only to accounts under a PLS Payer whose Support Level is PLS (Business/Enterprise); independent of the MSP support grade"
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

# AWS TAM request conditions and channel

## Control statement

An AWS TAM request is allowed only for an account under a PLS Payer whose individual Support Level is PLS (Business or Enterprise), and only after an AWS Case is already open. When a case needs faster handling or is stalled, the part lead decides first; only then is the request sent with the case number.

## Scope

- Applies when: a customer AWS Case needs TAM acceleration or is not progressing.
- Does not apply when: the account is not PLS-eligible, or no AWS Case is open. The MSP support grade is irrelevant to eligibility.
- Does not cover COC security requests from the TAM; no card covers COC routing.

## Required behavior

1. Confirm the account is in a PLS Payer and its Support Level is PLS (Business/Enterprise). If this cannot be confirmed, state it as unknown and ask a human.
2. Confirm an AWS Case is open and record its case number.
3. Obtain the part lead's decision before requesting.
4. A human sends the request with the case number through one of two channels: the Slack AWS TAM channel (technical questions: `#aws-tam-technical-support`) or the AWS MSP 회사 team shared mailbox (address in the live MSP 주요 사항 entry).
5. Record the decision and send time in the ticket history using role references.

## Prohibited behavior

- Do not request a TAM for a non-PLS account or without an open AWS Case.
- Do not gate or grant the request by the MSP support grade.
- Do not send mail, post to Slack, or open an AWS Case from an agent session.

## Exceptions and escalation

- The source does not define who the "part lead" is for each part or how PLS status is verified. Ask a human; do not infer.
- The mailbox address is deliberately not copied here; take it from the live entry.
- What counts as a severe issue worth a TAM request is listed in `POLICY-ESC-001` (four criteria). They came from a document that named the AWS AM; the TAM replaced that contact.

## Evidence

- Source document: `SRC-TAM-001` (Slack is the original; excerpt in `policy/excerpts/`)
- Page/section: MSP 팀 내부 사항, 항목 2
- Verbatim source excerpt (공용 메일 주소만 생략, 나머지는 원문 그대로):

> TAM: 태크니컬 어이스턴트 매니저 - AWS 소속 MSP 회사전담 기술 매니저님
>
> AWS TAM 요청 시에는
> 1. PLS 대상 Account 를 전제로 함 ( PLS Payer 안의 개별 Account 의 Support Level 이 PLS ( Business/Enterprise ) 인 경우 )
> 2. AWS Case Open 이 되어 있어야 함
> 3. 빠른 Case 진행이 필요하거나, 진행이 잘 안되는 경우 각 파트리더가 결정 한 후에 (1) Slack AWS TAM 채널 ( 기술 문의의 경우 : (#aws-tam-technical-support) 또는 (2) [AWS MSP 회사 팀 공용 메일 주소 — 원문에서 생략] 메일 주소로 케이스 번호와 함께 관련 사항 요청
> 4. MSP 기술 지원 등급과 상관 없음

## Change history

- 2026-10-06 — Activated. The repository owner (final approver for these cards) approved it, named the MSP team lead as source owner, and fixed the source date as 2026-09-27.
