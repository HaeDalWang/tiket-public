---
id: POLICY-PAYER-001
title: Standalone Payer scope and escalation
status: active
applies_to: [standalone-payer, partner-link, billing-visibility, support-scope, payer-transition, organizations-all-features, control-tower, identity-center]
triggers: [standalone-payer, separate-payer, independent-payer, payer, partner-link, billing-platform, cur, rebilling, cost-visibility, integrated-payer, technical-support, organizations, all-features, control-tower, identity-center, sso]
source_document: SRC-STANDALONE-PAYER-001
source_location: "lines 3-147, 149-200, 430-620, 715-764"
source_owner: "CSG Team (source footer); reviewed by the CSG group leader"
source_version: "last updated 2026-02-20"
effective_from: 2026-10-01
applicability: "[company] Read when a conversation involves a standalone (separate) Payer, or mentions AWS Organizations all features, AWS Control Tower, or IAM Identity Center (SSO), which call for a separate Payer. Not needed when the customer already runs a separate Payer with all features enabled"
reviewed_at: 2026-10-01
reviewed_by: Claude Code
review_by: 2026-12-30
authority_verified_at: "2026-10-01 KST"
approved_by: maintainer
approved_at: "2026-10-01 KST"
activation_blocker: ""
retired_at: ""
retirement_reason: ""
replacement: ""
supersedes: ""
---

# Standalone Payer scope and escalation

## Control statement

Use this guide only for standalone-Payer concepts, role boundaries, and general constraints. Before answering a billing, account-management, support, 빌링 플랫폼, or CUR question, identify the Payer model and verify fees/thresholds/support with CSR, current product behavior with the FinOps team (옛 COP팀), and customer-visible results in 빌링 플랫폼. Do not promise integrated-Payer capabilities to a standalone-Payer customer.

## Scope

- Applies to standalone Payer onboarding, partner link, support scope, billing visibility, CUR, the billing platform, and transition discussions.
- Applies when AWS Organizations all features, AWS Control Tower, or AWS IAM Identity Center (SSO) comes up: these call for a separate Payer, so read this card to check the Payer model first.
- Does not need to be read when the customer already runs a separate Payer with all features enabled.
- Does not authorize partner-link, account-transfer, permission, or billing-system changes.

## Required behavior

1. Confirm the customer's Payer model and applicable contract before investigating capability or cost.
2. Record whether account management remains the customer's responsibility.
3. Verify whether technical support, CUR data, the billing platform, and cost visibility are included or separately contracted.
4. Route general/contract questions to CSR, technical/system questions to the FinOps team (옛 COP팀) or SA, and exceptions/disputes to CSG leadership.
5. Treat a transition to integrated Payer as a separate approved project with backup, IAM, tagging, recovery, network, contract, and billing considerations.
6. Use only approved billing-platform-curated figures in a customer-facing cost response. Do not copy internal figures or AWS-origin values from this guide.
7. Record the Payer model, verification date, CSR contract reference, FinOps feature verification, and the billing platform observation in the ticket.
8. Background for any Payer question (FTR SPP-001): The MSP resells under the End Customer Account Model — the customer owns the AWS account and uses every service directly, and the MSP runs the management account of the consolidated-billing organization. Under the Partner-Led Support model the customer does not go to AWS for support; technical and non-technical requests (payment, account management) both come through the MSP.
9. Per-Payer facts — support level, PLBS, whether credit is shared — are kept centrally in a Payer-management document on SharePoint (FTR SPP-002). That document, not memory or this card, is where a person confirms them. The list of Payers is deliberately not in this repository.

## Prohibited behavior

- Assuming the billing platform or Rebilling is available to a standalone-Payer customer
- Quoting the guide's fees, thresholds, targets, or discount claims without current contract/billing platform verification
- Executing partner invitation, account transfer, IAM, resource migration, or billing configuration
- Using AWS Cost Explorer output in a customer reply
- Treating roadmap items as delivered capabilities
- Treating internal fees, volume thresholds, discount claims, conversion targets, or feature statements as current without CSR/FinOps/billing platform verification

## Exceptions and escalation

- The guide contains roadmap and target figures rather than only current controls; these are not customer commitments.
- The source states the billing platform is not provided for the standalone model, while other company systems may expose administrative billing data. Verify the active product and contract rather than resolving this from the guide alone.

## Evidence

- `SRC-STANDALONE-PAYER-001:4-15` — standalone Payer is defined as customer-owned account management with direct AWS payment and a partner link.
- `SRC-STANDALONE-PAYER-001:65-120` — pre-review, leadership approval, limited support, separate technical-support contract, Rebilling/billing platform constraints, and internal fee statements.
- `SRC-STANDALONE-PAYER-001:149-199` — customer account/security/cost responsibility is separated from the MSP partner-link and optional support.
- `SRC-STANDALONE-PAYER-001:463-551` — transition criteria and process include customer approval, account migration, permission, billing, backup, network, contract, and support changes.
- `SRC-STANDALONE-PAYER-001:553-620` — role and escalation mapping assigns CSR, SA, COP, MSP, and CSG leadership responsibilities.
- `SRC-STANDALONE-PAYER-001:715-764` — roadmap items are separate from current process; source updated 2026-02-20 and reviewed by CSG leadership.

## Change history

- 2026-10-01 — Re-read every cited range against the source (SHA-256 matches `sources.json`); added when this card must be read: a mention of AWS Organizations all features, Control Tower, or IAM Identity Center (SSO), and the case where it can be skipped (the customer already has a separate Payer with all features enabled). These are owner instructions, not statements in the source, and were not checked against AWS documentation. Activated by the maintainer.
