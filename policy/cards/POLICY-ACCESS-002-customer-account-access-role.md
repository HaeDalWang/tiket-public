---
id: POLICY-ACCESS-002
title: Customer-account access role: what MspCrossAccount can and cannot read
status: active
applies_to: [customer-account-access, cross-account-role, billing-switch-role, mfa, data-access]
triggers: [crossaccount, cross-account, switch-role, mspcrossaccount, access-denied, s3-object, dynamodb-item, readonly, mfa, 권한, 접근, 데이터-조회, 관리-대상, managed-account]
source_location: "ACM-006 (빌링 플랫폼 MFA), ACM-007 (CrossAccount Role 설정), ACM-003 (MspCrossAccount 설정) and the Diagnosis/Trouble shooting policy section"
applicability: "[team: MSP] Applies whenever a ticket depends on what the MSP can see or do inside a customer account"
source_document: SRC-FTR-ACM-001
source_owner: "The MSP — document submitted to AWS for the Partner-Led Support FTR"
source_version: "[MSP 회사] AWS Account Management(ACM).docx, FTR-PLS 2.0 (deck NEW_PLS_FTR_MSP_202411, 2024-11)"
effective_from: 2026-10-08
reviewed_at: 2026-10-22
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

# Customer-account access role: what MspCrossAccount can and cannot read

## Control statement

MSP staff reach a customer account through the billing platform, with MFA, by switching into the customer's `MspCrossAccount` role. That role reads configuration, opens support cases, and reads Savings Plans; it changes nothing, and it is explicitly denied the contents of the customer's data stores. What the role cannot read is out of reach by design, not a fault.

## Scope

- Applies when: a ticket needs something looked up in a customer account, a customer asks the MSP to look at or change something, or an access error appears on the MSP side, or a ticket turns on whether an account is the MSP's to manage.
- Does not cover: how this workspace is allowed to call a customer account — `CLAUDE.md` is narrower (read-only, broker-mediated, access locks) and governs. Employee departure is `POLICY-ACCESS-001`. Setting the role up for a new customer is `GUIDE-ONBOARD-001`.

## Required behavior

1. Treat the role as the ceiling of what the MSP can see. It carries four policies:

   | Policy | What it gives |
   |---|---|
   | `ReadOnlyAccess` | Read AWS resources. No create, change, or delete |
   | `AWSSupportAccess` | Open and follow AWS Support cases |
   | `AWSSavingsPlansReadOnlyAccess` | Read Savings Plans |
   | `msp_custom_deny` | Denies reading the contents of the customer's data stores (list below) |

2. These actions are denied on every resource: `dynamodb:GetItem`, `dynamodb:BatchGetItem`, `dynamodb:Query`, `dynamodb:Scan`, `ecr:BatchGetImage`, `ecr:GetAuthorizationToken`, `ecr:GetDownloadUrlForLayer`, `kinesis:Get*`, `s3:GetObject`, `glacier:Get*`, `sdb:Select*`, `sqs:ReceiveMessage`. Configuration is still readable — a bucket's policy, a table's settings, a queue's attributes — the contents are not.
3. When a ticket needs the contents of an object, an item, an image, a stream record, or a message, say that the MSP cannot read it and ask the customer to check it or send the relevant part. An access-denied error on one of the actions above is the deny policy working; do not investigate it as a fault.
4. When a customer asks the MSP to change something in the account, this role cannot do it. Any wider permission is the customer's to grant; the source says the role "cannot take administrator rights without the customer's permission".
5. Extra permission is taken for the length of a piece of work and handed back when it ends — that is the working practice. When a customer offers more permission, or the work cannot be done without it, the engineer decides whether to take it. The draft then asks for the least that the work needs, says what it is for and that it is returned when the work is done, and the record carries when it was granted and when it was returned.
6. An extra allow does not lift the deny list: an explicit deny overrides an allow (`https://docs.aws.amazon.com/IAM/latest/UserGuide/reference_policies_evaluation-logic.html`, read 2026-10-08). For the denied data actions, adding a permission to `MspCrossAccount` changes nothing. In practice the customer creates a separate IAM user or role for the work and removes it afterwards. Say that rather than naming a permission that will not work.
7. The billing platform sign-in requires ID, password, and MFA for every employee who uses the portal or reaches a customer account. Without MFA the portal is closed to them.
8. If the role is missing or cannot be assumed for a customer, that is an onboarding item (`GUIDE-ONBOARD-001`): the setup guide is sent to the customer at onboarding. State it as the blocker and leave it to the engineer.
9. On PLS accounts the role additionally carries `msp_ts_policy` and trusts `ts.amazonaws.com`, so that the diagnosis and troubleshooting service can run. Record it when relevant; do not start an execution from an agent session.
10. Do not decide whether the MSP "manages" an account from billing or access alone. Three things are separate: (a) billing — the account sits under an MSP Payer and is registered in the billing platform; (b) access — `MspCrossAccount` can be assumed; (c) operations — an MSP contract covers the account (scope: `POLICY-SUPPORT-001`). (a) and (b) can hold without (c), and the reverse. Before writing "managed by the MSP" or "not managed by the MSP", name which of the three was checked and how; an unchecked one is `unknown`.

## Prohibited behavior

- Do not ask for more than the work needs, for longer than the work lasts, or for standing administrator rights. Do not ask a customer to remove the deny policy for good.
- Do not ask for extra permission when the customer checking it themselves, or sending the relevant part, settles the ticket just as well.
- Do not propose a way around the deny list on your own (copying objects elsewhere, a public or pre-signed link, exporting a table). How the customer shares their data is the customer's choice.
- Do not tell a customer that the MSP can change resources through this role, or that the MSP has seen the contents of their data.
- Do not write any billing-platform credential into a tracked file or a reply draft. The MSP's own account IDs (internal account, main Payer account, billing-platform account) and the trust principal may be written in tracked files — everyone who uses this repository must know which account is which, and an account ID alone grants nothing. In a reply draft, write them only when the customer needs them (for example, setting up the role's trust).
- Do not create or edit the role, its policies, or its trust relationship from an agent session.

## Exceptions and escalation

- `AWSSupportAccess` makes it possible to open a case from the customer account, but which account a case is opened in is decided by `POLICY-CASE-001`. That card wins.
- The source is from 2024-11; the repository owner confirmed on 2026-10-08 that the four policies are unchanged. A single customer can still have granted more, or less. When the answer depends on it, read the role in that account rather than this card.
- Customers that receive the MC service can have other arrangements (the source mentions an SNS subscription set up in such accounts). Those are customer-specific.
- The source's onboarding text sets an initial billing-platform password by a fixed rule. It is deliberately not carried into this repository; whether it is still issued that way is unknown (a question for the development team).

## Evidence

- Source document: `SRC-FTR-ACM-001` (excerpt in `policy/excerpts/`)
- Page/section: ACM-006 — MFA을 통한 고객 및 파트너 계정의 보안 강화 및 권한 관리; ACM-007 — CrossAccount Role 설정; ACM-003 — MspCrossAccount 설정, Diagnosis 및 Trouble shooting을 위한 정책 설정
- Verbatim source excerpt:

> MSP 회사는 빌링 플랫폼이라는 자체 웹을 통해 고객 계정에 접근하며, 빌링 플랫폼 로그인시 아이디, 패스워드, MFA가 필수로 적용 되어 있습니다.

> 고객계정에 접근하는 Role(MspCrossAccount)은 ReadOnlyAccess, AWSSupportAccess, AWSSavingsPlansReadOnlyAccess 및 msp_custom_deny 가 연결 됩니다. Msp_custom_deny 정책은 S3, ECR, DynamoDB 등 리소스 정보 접근 권한을 막는 정책입니다.

> 해당 역할은 고객의 허가없이 관리자 권한을 취할수 없으며, 최소 권한의 원칙을 따라 필요 권한만을 가짐을 원칙으로 합니다.

> ※ MSP 회사에서는 고객사의 인프라를 수정하지 않으며, 설정된 정보만을 수집합니다.

## Change history

- 2026-10-08 — Created and activated from the FTR-PLS 2.0 AWS Account Management document. The repository owner (final approver for these cards) stated the document is the one defined between the MSP and AWS and in force.
