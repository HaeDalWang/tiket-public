---
id: GUIDE-IAM-001
title: IAM standards the MSP recommends to customers
status: active
applies_to: [iam, access-key, mfa, password-policy, least-privilege]
triggers: [iam, access-key, 액세스키, 키-유출, mfa, password-policy, 비밀번호-정책, 공용-계정, least-privilege, administratoraccess, 권한-검토, scp]
source_location: "IAM document — 자격 증명 관리 방안, IAM 사용자 관리, IAM 관리 표준, MFA 강제화 정책, 최소 권한 표준화; ARC-003 Accesskey 관리 표준"
applicability: "[team: MSP] Applies when a ticket touches how a customer sets up or uses IAM users, access keys, passwords, MFA, or permissions"
source_document: SRC-FTR-STD-001
source_owner: "The MSP — documents submitted to AWS for the Partner-Led Support FTR"
source_version: "[MSP 회사] IAM Best Practices(IAM).docx and AWS Root User Management(ARC).docx, FTR-PLS 2.0 (deck NEW_PLS_FTR_MSP_202411, 2024-11)"
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

# IAM standards the MSP recommends to customers

## Control statement

These are the standards the MSP holds itself to and recommends to customers. They are recommendations: the customer decides, and nothing here is applied from an agent session. Use them so that the advice in a reply is the same advice every time.

## Scope

- Applies when: a ticket asks how to create or share a user, issue or rotate an access key, set a password policy, enforce MFA, or grant permissions; or follows a leaked key.
- Does not cover: the root user (`POLICY-ROOT-001`), what the MSP's own role can do (`POLICY-ACCESS-002`), handling a customer's security information (`POLICY-SEC-001`).

## Required behavior

1. Recommend, in this order of weight:
   - MFA for every person — root and IAM users.
   - One credential per person. No shared IAM users, no shared access keys.
   - Permissions through groups, not attached to users one by one.
   - Least privilege, reviewed every quarter (90 days). `AdministratorAccess` is not attached to a group; wildcards are avoided.
   - Temporary credentials (IAM roles) instead of long-lived ones.
   - Passwords of at least eight characters with three kinds of character, expiring at 90 days; access keys rotated at 90 days; unused credentials found and removed.
2. Long-lived access keys are not issued by default. They can be, after the engineer's judgment and agreement with the customer, in these cases: a key whose only use is to assume a role; a key protected with Secrets Manager or the like; a system (not a person) doing read-only work that touches no personal or credit information; a third-party tool that needs one; a local development environment.
3. A long-lived key that is issued carries conditions: allowed source IPs only; least privilege and never administrator; MFA when a person uses it; and, when the key matters, an alarm on its use through CloudTrail and CloudWatch Logs. Keys are never written into code.
4. An MFA-only SCP (calls fail unless MFA is present, AWS's own actions excepted) is an extra to recommend where the customer's environment suits it.
5. When quoting any of this as what AWS recommends, check the current AWS documentation first. This card is the MSP's standard from 2024-11, not AWS's text.

## Prohibited behavior

- Do not create, change, or delete an IAM user, key, policy, or SCP from an agent session.
- Do not recommend a shared account or a shared key as a convenience, or `AdministratorAccess` as a quick fix.
- Do not ask a customer to send an access key or password, and do not write one into a record.
- Do not present these as requirements a customer must meet; a contract or the customer's own policy can differ.

## Exceptions and escalation

- A leaked or suspected-leaked key is an incident first (`POLICY-SEC-001`, `POLICY-RISK-001` draft); this card supplies the advice that follows it.
- The 90-day password expiry and the eight-character minimum are the source's figures. If current AWS guidance differs, say which is the MSP's standard and which is AWS's.
- Hardware MFA devices for the MSP's own accounts are kept locked away and used after approval through the CSG security officer and the CSG leader. Internal; not advice for customers.

## Evidence

- Source document: `SRC-FTR-STD-001` (excerpt in `policy/excerpts/`)
- Page/section: IAM — 자격 증명 관리 방안, IAM 관리 표준, 최소 권한 표준화; ARC-003 — Accesskey 관리 표준
- Verbatim source excerpt:

> 침해 발생 시 피해가 크게 발생할 수 있으나 관리가 미비한 고객이 다수 있기에 아래 몇 가지 원칙을 항상 기본적으로 강조하여 이행해야 합니다. ROOT 및 IAM 사용자는 다단계 인증(MFA) 적용 / IAM 사용자는 개인 전용 자격 증명 활용(공용 자격 증명 금지 원칙) / IAM사용자는 그룹화해서 관리 / 최소 권한 적용 및 분기 단위를 표준으로 하는 주기적인 권한 관리 / 임시 자격 증명(IAM 역할)을 사용

> 기본적으로 장기 액세스키를 사용해서는 안되며 아래의 경우에 담당자 판단과 고객협의를 거쳐 진행할 수 있습니다.

## Change history

- 2026-10-08 — Created and activated from FTR-PLS 2.0. The repository owner (final approver for these cards) stated the documents are the ones defined between the MSP and AWS and in force.
