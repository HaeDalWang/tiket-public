---
id: GUIDE-BILLING-001
title: The billing platform cost-data freshness limitations
status: active
applies_to: [billing-platform, billing-data, data-freshness, delayed-update, month-end]
triggers: [billing-delay, cur-update, billing-period, data-time, stale-cost, month-end, queue]
source_document: SRC-COP-QA-001
source_location: "lines 4-16"
source_owner: "Not recorded; undated Q&A answered by the COP team"
source_version: "undated Q&A, no version"
effective_from: 2026-10-01
applicability: "[company] Explaining why the billing platform cost data lags; live billing-platform behavior and current platform-team confirmation outrank it"
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

# The billing platform cost-data freshness limitations

## Control statement

Do not interpret the time shown in the billing platform as proof that all source billing data through that time has been processed. When investigating apparent delay, distinguish AWS source-data delivery, the source data's own coverage time, and the billing platform processing/queue time. Re-verify current platform behavior before using this draft guidance.

## Scope

- Applies to questions about delayed billing-platform cost reflection, CUR update time, processing time, and increasing month-end latency.
- Does not authorize use or disclosure of raw AWS billing values in a customer reply.

## Required behavior

1. Record the requested billing period and the exact billing-platform observation time.
2. Confirm the latest available billing-platform-curated data before quoting customer figures.
3. Distinguish source delivery, data coverage, queue wait, and processing completion.
4. If current behavior is needed, route a platform verification question to the FinOps team (옛 COP팀) and record the live result.
5. Explain uncertainty without promising a fixed refresh interval that has not been verified.

The billing platform budget alerts and cost allocation tags (FTR BIL-001, BIL-002). The intervals below are what the 2024-11 document states; give them as documented, not as measured today.

6. A billing platform budget is the MSP's own feature, not AWS Budgets. It is not real-time: it works on cost data aggregated at least once every 24 hours, and the budget information usually updates 8 to 12 hours after the previous update. So "the alert came late" or "the cost passed the threshold hours before the mail" is expected behavior.
7. A budget is set per AWS account that is linked to the billing platform (period by month, threshold, alert rate from 10% to 100%, recipients). Once an alert has gone out for a month, it is not mailed again for that month. It counts on-demand, RI/SP, and contract-discounted (CFRC, PPA) cost.
8. Cost allocation tags need the cross-account role in the account that owns the resources (`POLICY-ACCESS-002`); without it the billing platform cannot read the tags. A tag newly put on a resource shows in Available Tags up to 8 hours later. A tag with no cost yet sits in Unavailable Tags until cost occurs. At most five tags can be selected.
9. Turning cost allocation tags on for the first time can take 24 hours or more, counted in business days, and **cost is tracked only from the moment of activation** — usage before that does not appear under the tag.

## Prohibited behavior

- Treating a displayed timestamp as complete source coverage
- Quoting raw AWS/CUR figures to a customer
- Claiming a fixed daily delivery count or queue architecture as current without live verification
- Copying customer names, account IDs, or support-plan examples from the Raw Q&A

## Exceptions and escalation

- Platform implementation may have changed since this undated Q&A. Live 빌링 플랫폼 behavior and current FinOps team (옛 COP팀) confirmation outrank this card.

## Evidence

- `SRC-COP-QA-001:4-16` — the source says CUR delivery is periodic, delivered data may lag its delivery time, Payer jobs may queue sequentially, and month-end volume can increase delay.

## Change history

- 2026-10-01 — Re-read every cited range against the source (SHA-256 matches `sources.json`); activated by the maintainer. The source is an undated Q&A about platform internals that may have changed, so the review date is three months out.
