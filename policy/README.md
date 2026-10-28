# Company Policy Knowledge Base

This directory stores routing metadata and normalized policy cards. It must not inject every company document into the model context.

## Retrieval flow

1. Classify the current ticket by customer, service, action, data type, and risk.
2. Search `_routing.md` for matching triggers.
3. Read only the matching cards in `cards/`.
4. Open the relevant extracted section or original page only when the card is insufficient.
5. Record applied policy IDs, source pages, and effective dates in the ticket.
6. If two active policies conflict, stop and escalate to a human.

## Language contract

- Routing metadata, agent instructions, and normalized control statements: English where practical.
- Original company documents: preserve their source language without rewriting.
- Human-facing ticket notes and customer replies: Korean.
- Technical identifiers and quotations: preserve exactly.

## Storage layers

- `_routing.md`: compact policy index loaded for routing.
- `cards/`: short, reviewed policy cards with scope and source pointers.
- `sources.json`: machine-readable Source ID, normalized filename, line count, and SHA-256 manifest.
- `excerpts/`: searchable OCR/text derivatives when approved for this repository.
- `source-inventory.md`: source inventory and storage pointer.
- `pending-review.md`: human decisions required before draft cards can become active.
- `raw/`: local source documents; gitignored by default. Use an approved document system or Git LFS only after an explicit decision.

## Ingestion rules

- Never treat OCR output as authoritative without checking the source page for a load-bearing clause.
- Every card must identify source document, page/section, effective date, status, and review date.
- A superseded policy remains in history but must be marked `superseded` and linked to its replacement.
- `review_by` follows the source's volatility — a Slack announcement warrants about three months, a formal
  document up to one year — and may not exceed `reviewed_at` + 365 days. It re-checks that the cited source
  version is still current, not that the rule is still wise. A rule meant to hold indefinitely belongs in
  `CLAUDE.md` Absolute boundaries, not in a card (`development/decisions/0028-*`).
- The routing row's effective and review dates must equal the card's; `validate_workspace.py` compares them.
- Never store credentials or unrestricted raw operational logs with policy sources.
- Do not copy personal rosters, phone numbers, customer account examples, or operational access hints from Raw notes into tracked cards.

## Draft activation

1. Resolve the relevant item in `pending-review.md`.
2. Confirm the source owner, current version, and applicability.
3. Re-read every cited source range.
4. Record `source_owner`, `source_version`, `effective_from`/`applicability`, `authority_verified_at`, `approved_by`, and `approved_at`.
5. Change the card from `draft` to `active` only after those fields are verified.
6. Re-run `python3 scripts/validate_workspace.py`.
