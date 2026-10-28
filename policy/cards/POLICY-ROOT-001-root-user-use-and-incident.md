---
id: POLICY-ROOT-001
title: Root user: when it may be used, and what happens when it is compromised or locked out
status: active
applies_to: [root-user, root-incident, root-recovery, mfa-loss]
triggers: [root, 루트, root-login, root-mfa, mfa-분실, root-email, 비밀번호-재설정, guardduty-root, root-access-key, 계정-복구]
source_location: "ARC-001 (ROOT 계정 운영 표준, ROOT 사용 상황, ROOT 계정 사고 대응), ARC-003 (Accesskey 관리 표준), ARC-004"
applicability: "[team: MSP] Applies when a ticket involves the root user of a customer account: a request to use it, a sign-in alert, a lost password, mail, or MFA device"
source_document: SRC-FTR-STD-001
source_owner: "The MSP — documents submitted to AWS for the Partner-Led Support FTR"
source_version: "[MSP 회사] AWS Root User Management(ARC).docx, FTR-PLS 2.0 (deck NEW_PLS_FTR_MSP_202411, 2024-11)"
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

# Root user: when it may be used, and what happens when it is compromised or locked out

## Control statement

The root user cannot be limited and cannot be replaced, so it is used only for the few tasks that need it and is protected so that a breach does little. An unauthorized root sign-in attempt is treated as leaked credentials, at once. In a customer's account the customer acts; the MSP guides and says so.

## Scope

- Applies when: a customer asks about or wants to use the root user, reports a root sign-in they did not make, or has lost the root password, the root mail address, or the root MFA device.
- Does not cover: IAM users and access keys in general (`GUIDE-IAM-001`), the handling of customer security information (`POLICY-SEC-001`), the internal incident workflow (`POLICY-RISK-001`, draft).

## Required behavior

1. Root is for these tasks only: changing account settings that need it (account name, mail address, root password, root access keys); restoring IAM permissions an administrator removed by mistake; closing the account; configuring MFA delete on an S3 bucket; editing or deleting an S3 bucket policy or SQS policy that denies every principal; asking AWS Support to recover a KMS key that can no longer be managed; registering as a seller in the Reserved Instance Marketplace. For anything else, point to an IAM role or user.
2. Billing and root: at onboarding the customer turns on IAM access to billing information in their own account, once — it needs root, so only the customer can (`GUIDE-ONBOARD-001` step 11). After that the customer sees billing in the billing platform, and only the MSP looks at the console side (`POLICY-BILL-001`).
3. The baseline to recommend: no root access keys (delete, never create); MFA on root; a password of at least eight characters that is not the account name or mail address; account contact details on a shared group mailbox and phone number, not one person's.
4. **A root sign-in attempt nobody authorized means the credentials are taken as leaked.** At once: delete root access keys, change the root password, replace the MFA device, and report — to the CSG group leader for an MSP account, to the customer's contact for a customer account. In a customer account these are the customer's actions: give them as steps, and tell the customer that the MSP supports them through it.
5. Lost access has three cases — the root mail address cannot be reached, the password must be reset, the MFA device is lost. Each has a recovery path that depends on still reaching the account's mail and phone; when a path fails, the customer asks AWS account support. **Fetch the current AWS page for the steps before writing them**; do not reproduce them from this card or from memory.
6. Classify a root sign-in alert as `high-risk` (`agents/task-router.md`). If workload impact or an AWS-side cause is possible, the severe-issue route in `POLICY-ESC-001` applies as well.

## Prohibited behavior

- Do not accept, ask for, or write down a root password, a root MFA code, or root access keys — not in a ticket, a record, or a draft. If a customer offers them, decline in the reply.
- Do not sign in as root to a customer account, or say that the MSP will.
- Do not tell a customer to create a root access key, for any purpose.
- Do not tell a customer that an unexplained root sign-in is probably harmless.
- Do not carry out or claim to have carried out any of step 4 from an agent session.

## Exceptions and escalation

- The eight-character minimum is the 2024-11 document's figure. Current AWS or KISA guidance may ask for more; recommend it as a minimum and check before quoting it as a standard.
- Monitoring of root use (GuardDuty finding, CloudWatch Logs metric, EventBridge to SNS) is described for the MSP's own accounts. Whether a customer has it is read from that account.

## Evidence

- Source document: `SRC-FTR-STD-001` (excerpt in `policy/excerpts/`)
- Page/section: ARC-001 — ROOT계정에 대한 기본적인 권장 설정, ROOT 사용 상황, ROOT 계정 사고 대응
- Verbatim source excerpt:

> 미허가 로그인 시도 발생 시 자격증명이 유출된 것으로 판단합니다. 사용중인 자격증명은 변경절차를 수행합니다. 인지 즉시 아래 항목들을 수행합니다. ROOT 액세스키 삭제 / ROOT IAM 비밀번호 변경 / MFA 교체 / CSG그룹 리더(고객 환경인 경우 고객 담당자)에게 보고

> 고객 가이드 진행 시 진행 과정에서 파트너사 MSP 회사의 지원을 받을 수 있음을 가이드합니다.

## Change history

- 2026-10-08 — Created and activated from FTR-PLS 2.0. The repository owner (final approver for these cards) stated the documents are the ones defined between the MSP and AWS and in force.
