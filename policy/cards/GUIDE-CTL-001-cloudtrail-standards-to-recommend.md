---
id: GUIDE-CTL-001
title: CloudTrail standards the MSP recommends to customers
status: active
applies_to: [cloudtrail, audit-log, log-retention, log-integrity]
triggers: [cloudtrail, trail, 추적, 감사-로그, 누가-삭제, 누가-변경, 90일, event-history, log-archive, mfa-delete, 로그-보관, 무결성]
source_location: "CTL-001 (Cloudtrail 설정 표준), CTL-002·003 (중앙 집중화 로깅, 암호화, 최소 권한, MFA 삭제, 수명 주기), CTL-004 (무결성, 모니터링)"
applicability: "[team: MSP] Applies when a ticket asks who did something in an account, or how CloudTrail should be set up or kept"
source_document: SRC-FTR-STD-001
source_owner: "The MSP — documents submitted to AWS for the Partner-Led Support FTR"
source_version: "[MSP 회사] CloudTrail Best Practices(CTL).docx, FTR-PLS 2.0 (deck NEW_PLS_FTR_MSP_202411, 2024-11)"
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

# CloudTrail standards the MSP recommends to customers

## Control statement

CloudTrail's event history keeps 90 days of management events and no more. Anything older exists only if a trail was writing to S3 at the time. These are the settings the MSP recommends so that the record exists, cannot be altered, and is watched. They are recommendations; nothing here is applied from an agent session.

## Scope

- Applies when: a customer asks who created, changed, or deleted something; asks how long activity is kept; or asks how to set up or protect a trail.
- Does not cover: reading a specific customer's events (`CLAUDE.md` access rules, `POLICY-ACCESS-002`), security incidents as such (`POLICY-SEC-001`).

## Required behavior

1. Before saying an event can be looked up, check how old it is and whether a trail exists. Within 90 days the event history has management events. Beyond 90 days it depends on a trail; if none was writing then, say the record does not exist rather than promising a search.
2. Recommend:
   - A trail in every region. The console creates a multi-region trail by default; with the CLI take care not to create a single-region one.
   - Central logging: a separate log-archive account, an organization trail in AWS Organizations, access to that account for trusted administrators only.
   - Encryption of stored logs with a customer-managed KMS key (SSE-KMS) rather than the default SSE-S3.
   - A bucket policy on the log bucket that names who may read it.
   - MFA delete on the log bucket.
   - Log file validation turned on when the trail is created; S3 Object Lock (WORM) on the log bucket as well.
   - Events sent to CloudWatch Logs with metric filters and alarms, so a breach is noticed.
   - A lifecycle rule for retention and archiving — see step 3.
3. The source warns that a bucket with MFA delete cannot have a lifecycle rule, so lifecycle is for ordinary API-activity logs and MFA delete for the audit logs that matter most. Confirm this against the current S3 documentation before telling a customer.
4. When quoting any of this as what AWS recommends, check the current AWS documentation first. This card is the MSP's standard from 2024-11.

## Prohibited behavior

- Do not create, change, or stop a trail, or touch a log bucket, from an agent session.
- Do not promise that an event older than 90 days can be found before a trail is confirmed.
- Do not recommend shortening retention or turning off validation to save cost without saying what is lost.

## Exceptions and escalation

- A customer under regulation or with its own audit policy follows that; these are the defaults when nothing else is set.
- Data events (S3 object-level, Lambda invocations) are not in the event history and are logged only if the trail was set to record them. The source does not go into them.

## Evidence

- Source document: `SRC-FTR-STD-001` (excerpt in `policy/excerpts/`)
- Page/section: CTL-001 — CloudTrail 보안 모범 사례, CloudTrail 추적; CTL-002 — 중앙 집중화 로깅 ~ 객체 수명 주기 관리; CTL-004 — CloudTrail 로그 파일 무결성, CloudTrail모니터링
- Verbatim source excerpt:

> CloudTrail은 기본적으로 90일간의 이벤트 기록 정보만 제공하므로 90일 이후 이벤트에 대해서 별도의 로깅 구성을 해야 합니다.

> MFA 삭제 활성화 버킷에 대해서는 객체 수명 주기 적용이 불가능합니다. 따라서 계정 감사 등과 같은 중요 로그 외 일반적인 AWS API 활동에 한해 객체 수명 주기 적용을 해야 합니다.

## Change history

- 2026-10-08 — Created and activated from FTR-PLS 2.0. The repository owner (final approver for these cards) stated the documents are the ones defined between the MSP and AWS and in force.
