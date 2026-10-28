---
id: POLICY-SEC-001
title: Customer security information handling and sharing
status: active
applies_to: [customer-data, credentials, account-access, file-sharing, external-sharing, security-incident]
triggers: [account-id, payer-id, ip, cidr, access-key, password, token, certificate, private-key, database-access, customer-file, external-share, security-incident]
source_document: SRC-CUSTOMER-SECURITY-001
source_location: "lines 3-284; repository conflict cross-reference SRC-CUSTOMER-OFFBOARD-001 lines 374-384"
source_owner: "Security team / team leads (source contact line)"
source_version: "고객 보안 정보 보관 및 공유 관련 주의사항; 최종 업데이트 2026-02-10"
effective_from: 2026-09-30
applicability: "All MSP ticket work that stores, shares, requests, or disposes of customer security information"
reviewed_at: 2026-09-30
reviewed_by: Claude Code
review_by: 2026-12-30
authority_verified_at: "2026-09-30 KST"
approved_by: maintainer
approved_at: "2026-09-30 KST"
activation_blocker: ""
retired_at: ""
retirement_reason: ""
replacement: ""
supersedes: ""
---

# Customer security information handling and sharing

## Control statement

Treat customer account identifiers, network information, credentials, certificates, private keys, and database access details as customer security information. Do not commit or distribute such information through an unapproved platform. Use the approved cross-account access path whenever available, minimize and time-bound any exceptional credential, and remove it immediately after the work.

The source lists Teams and company OneDrive as approved sharing platforms and prohibits public Git repositories, but does not address a private GitHub repository. A separate Offboarding source lists `Git` as a storage location for technical information. Until the security team or team lead approves a broader scope, this repository applies the stricter rule selected on 2026-08-24: commit only de-identified technical context — tracked files carry no customer name, contact, account ID, or `corpId`; describe the pattern only, and keep real customer content in the local-only `tickets/`. The unresolved private-Git scope is an escalation item, not an activation blocker.

## Scope

- Applies when a ticket, profile, attachment, script, PoC handoff, or reply contains customer security information.
- Applies before sharing customer security information internally or externally.
- Applies when requesting or disposing of temporary customer credentials.
- Does not approve this private GitHub repository as storage for customer security information; only de-identified technical context may be committed.

## Required behavior

1. Classify the information before storing or sharing it.
2. Prefer the billing platform Cross Account for customer resource access.
3. If an exceptional temporary key is required, request least privilege and an explicit validity period.
4. Delete temporary credentials immediately after work and notify the customer when applicable.
5. For internal sharing, use Microsoft Teams Files or company OneDrive, restrict access to the organization and named recipients, and never create an external sharing link.
6. When sharing encrypted files internally, send the organization-only link by email and the password separately by Slack DM or SMS.
7. For external sharing, obtain prior team-lead approval (reason, recipient, scope, period), encrypt the file, separate file and password channels, and retain a sharing record. After sharing ends, ask the recipient to delete the file and dispose of internal copies.
8. After the task or project ends, remove local and shared copies, empty the trash, and notify the customer when applicable.
9. On a suspected security incident, immediately report to the team lead and security team, request revocation of affected keys or information, and assess the impact scope.

## Prohibited behavior

- Personal blog, personal-account Notion, personal cloud storage, personal note application, public Git repository, or messenger storage (KakaoTalk, personal Slack)
- Posting security information in a messenger group channel
- Long-term retention of temporary credentials
- Hardcoding Access Keys in code
- External sharing without prior approval
- Sending an encrypted file and its password through the same email channel
- Copying personal contact details from operational source documents into a policy card unless operationally necessary and approved

## Exceptions and escalation

- Exceptional retention is limited to an agreed project or configuration-support period, or until an incident is resolved. The file must be encrypted (Excel password or password-protected ZIP, strong password of 12+ mixed characters) and disposed of immediately when the period ends.
- Private GitHub storage approval is unresolved. Escalate to the security team or team lead before committing customer security information.
- If the customer does not revoke an obsolete key, request again and report to the team lead.

## Evidence

- `SRC-CUSTOMER-SECURITY-001:24-35` — “회사 및 고객사에 대한 보안 정보는 개인이 보관하지 않습니다.” The scope includes Account ID, Payer ID, IP/CIDR, credentials, tokens, certificates, private keys, and database access information.
- `SRC-CUSTOMER-SECURITY-001:41-55` — “다음 플랫폼에 고객 보안 정보 보관을 절대 금지합니다.”
- `SRC-CUSTOMER-SECURITY-001:60-74` — approved team sharing is Microsoft Teams Files or company OneDrive, restricted to internal or named users; external links are prohibited.
- `SRC-CUSTOMER-SECURITY-001:78-96` — “원칙: 빌링 플랫폼 Cross Account 사용”; an exception uses a least-privilege temporary key with a stated duration and immediate disposal.
- `SRC-CUSTOMER-SECURITY-001:101-142` — exceptional retention reasons, encryption method, retention period, and disposal steps.
- `SRC-CUSTOMER-SECURITY-001:147-161` — “2채널 분리 원칙” and “절대 이메일에 암호 포함 금지”.
- `SRC-CUSTOMER-SECURITY-001:204-227, 263-265` — checklist and FAQ prohibiting messenger group-channel sharing.
- `SRC-CUSTOMER-SECURITY-001:283-284` — source version `최종 업데이트: 2026-02-10`; contact `보안팀 또는 각 팀 팀장`.
- `SRC-CUSTOMER-SECURITY-001:181-200` — “원칙: 팀장 사전 승인 필수” for external sharing.
- `SRC-CUSTOMER-SECURITY-001:232-248` — immediate reporting and revocation actions for a security incident.
- `SRC-CUSTOMER-OFFBOARD-001:374-384` — the separate Offboarding guide lists technical information storage as “Outline, Git”, creating an unresolved scope conflict with the approved-platform list above.

## Change history

- 2026-09-30 — Re-read every cited range against the source (SHA-256 matches `sources.json`); added internal two-channel sharing, messenger group-channel ban, retention encryption detail, and incident impact assessment. Activated by the maintainer with the de-identified-only Git boundary kept; private-Git scope remains an escalation item.
