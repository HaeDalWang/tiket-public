---
id: POLICY-BILL-001
title: Rebilling: how the customer's bill is recalculated and what is never shown
status: active
applies_to: [rebilling, invoice, ri-sp-sharing, credit-sharing, program-discount, cost-figures]
triggers: [billing, invoice, 청구서, rebilling, 재계산, ri, savings-plan, credit, 크레딧, marketplace, discount, 할인, edp, cur, cost-detail, console-mismatch, 금액-차이, cost-explorer]
source_location: "ACM-009 (청구비용 재계산), ACM-010, RBL-001 (요금 청구서), RBL-002 (RI/SP·크레딧 공유), BIL-002 (Cost Detail)"
applicability: "[team: MSP] Applies when a ticket asks why a billed amount is what it is, why two numbers differ, or how RI, Savings Plans, or credit were applied"
source_document: SRC-FTR-BILL-001
source_owner: "The MSP — documents submitted to AWS for the Partner-Led Support FTR"
source_version: "BIL, RBL, ACM, SPP documents of FTR-PLS 2.0 (deck NEW_PLS_FTR_MSP_202411, 2024-11)"
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

# Rebilling: how the customer's bill is recalculated and what is never shown

## Control statement

The MSP does not pass AWS's bill through. It recalculates each customer's bill from usage and list price, then applies that customer's own tiering, RI, Savings Plans, and credit. Benefits that belong to the MSP's programs with AWS are removed before the customer sees anything, and the customer sees the result only in the billing platform. This is why an AWS-side figure is never a customer figure.

## Scope

- Applies when: a customer asks how an amount was calculated, why the billing platform differs from another number, whether RI, Savings Plans, or credit reached a charge, or where the invoice is.
- Does not cover: the hand-off of a cost inquiry (`POLICY-COST-ESC-001` — still required), data timing in the billing platform (`GUIDE-BILLING-001`), the Payer model (`POLICY-PAYER-001`).

## Required behavior

1. Quote only billing-platform-curated figures to a customer (`CLAUDE.md`). The reason, when one is needed internally: AWS-side data carries program discounts that are not the customer's.
2. Know what the recalculation does, so a difference can be explained without a number:

   | Item | How the customer's amount is made |
   |---|---|
   | Usage | usage amount × AWS list price, with tiering where it applies; the unblended cost is used only where the price list has no entry |
   | RI fee, upfront and recurring fees, refund, tax, credit, Marketplace | taken as they are |
   | RI and Savings Plans | recomputed per customer and account from what that customer bought |
   | Contract discounts (PPA, CFRC and the like) | the unit price agreed with that customer, kept in the MSP's own table |
   | AWS Support fee | computed per customer from the AWS Support price table over that customer's usage and fees; Marketplace, EKS Anywhere, and VMware Cloud on AWS are not counted |
   | Credit | collected per account, then applied by the customer's credit-sharing option (step 4) |

3. RI and Savings Plans are shared across the accounts of one customer, always. The billing platform has no switch to turn that off. They are not shared with other customers, whatever the AWS organization setting shows.
4. Credit sharing is an option per customer:
   - **On** — credit held by any of the customer's accounts applies across all of that customer's accounts, to on-demand charges, RI/SP-discounted charges, private-price charges, and the AWS Support fee.
   - **Off** — credit applies only in the account that holds it, and not to upfront fees, to Marketplace charges, or to Enterprise-or-higher Support or PLBS fees. With Activate credit, the Marketplace products that Activate credit covers are the exception.
   Which option a customer has is not assumed. Ask the sales manager first, then the FinOps team (옛 COP팀).
5. The Cost Detail page shows usage charges only. It leaves out the AWS Support fee, credit, and the MSP fee, so its total is not the invoice total — by design.
6. Invoices are in the billing platform by billing month (supply amount, VAT, total, issue date, PDF). A month that was billed by hand is not shown there; the customer asks their sales manager for it.
7. When a customer asks what MSP 회사 gets from AWS — a discount, a rate, EDP, partner pricing — the answer is one sentence and no more: the customer's bill is calculated from the customer's own usage and the terms of the customer's contract ("고객님 청구는 고객님의 사용량과 계약 조건으로 계산됩니다"). Neither confirm nor deny that such a discount exists, even when the customer writes that they know it does.
8. A cost question is still handed to sales (CSR) as `POLICY-COST-ESC-001` says. This card explains the mechanism; it does not settle an amount.
9. A member account in the MSP's consolidated-billing organization cannot use AWS Cost Explorer. This is a rule between AWS and the MSP as the partner, not a setting to look into or fix. When a customer asks, answer at once: Cost Explorer is not available, and costs and usage are in the billing platform. A standalone-Payer customer runs its own Payer and is outside this rule (`POLICY-PAYER-001`).

## Prohibited behavior

- Do not tell a customer what the MSP receives from AWS: SPP, EDP, or private-pricing discounts, their rates, or whether they exist at all. Do not write that such benefits are "separated", "removed", or "not reflected" in the customer's bill — that sentence confirms they exist.
- Do not quote or reconcile against AWS-side figures (CUR, the Payer's bill, Cost Explorer of the Payer).
- Do not tell a customer that a credit did or did not apply to a specific charge from this card alone; it depends on the credit's kind and the customer's option, and both have to be confirmed (step 4).
- Do not state or estimate an amount, a discount, or a Support fee.
- Do not change a credit-sharing option, a discount, or an extra charge in the billing platform from an agent session.

## Exceptions and escalation

- The source is from 2024-11 and 빌링 플랫폼 changes. If what 빌링 플랫폼 shows differs from this card, 빌링 플랫폼 and the FinOps team (옛 COP팀) win; record the difference.
- "PLBS" in the source is a name that is no longer used; read it as PLS. Plan codes are in `GUIDE-SUPPORT-PLAN-001`.
- A customer with a contract that fixes price or credit treatment follows the contract.
- Disputes about an amount go to sales, then CSG leadership (`POLICY-PAYER-001`).

## Evidence

- Source document: `SRC-FTR-BILL-001` (excerpt in `policy/excerpts/`)
- Page/section: ACM-009 청구비용 재계산; ACM-010; RBL-001 요금 청구서; RBL-002 빌링 플랫폼 RI/SP, 크레딧 적용 방식; BIL-002 Cost Detail
- Verbatim source excerpt:

> MSP 회사어서는 자체 리빌링을 통해 SPP  계약상의 할인, EDP 계약상의 할인, AWS 와의 Private Pricing 을 통한 할인, SP/SR/Credit Sharing 등의 할인 내역을 제외하고, 실제 Usage * List Price 만을 재 계산한 후에, 개별 고객사 Tiering / SP / RI / Credit  적용등을 추가하여 합니다. 고객사는 Program related benefits 이 모두 가려진 빌링 데이터를  빌링 플랫폼 웹사이트를 통해 확인 할 수 있습니다.

> 빌링 플랫폼에서는 고객사(계정 그룹) 단위에서 RI/SP의 공유 옵션이 제공되며 기본 상태는 활성화이며 비활성화는 지원하지 않습니다.

> A. AWS 서비스 Usage 관련 청구(또는 할인) 금액이며 AWS support요금, Credit할인, MSP요금 등 부가적인 청구(또는 할인) 금액은 포함하지 않습니다.

> 수기 청구된 월의 요금 청구서는 표시되지 않습니다. 해당 내역이 필요하신 경우 담당 영업에게 문의주시기 바랍니다.

## Change history

- 2026-10-08 — Created and activated from the FTR-PLS 2.0 billing documents. The repository owner (final approver for these cards) stated the documents are the ones defined between the MSP and AWS and in force.
- 2026-10-27 — Added step 9 (Cost Explorer is not available to member accounts). Source: the repository owner, stating it as the standing AWS–the MSP partner rule, after a 2026-10-26 field lesson where an agent deliberated over it.
