# Customer Support Workspace — Always-On Contract

This repository stores de-identified customer-ticket context, evidence, decisions, and reply drafts. It is not the infrastructure repository. Agents investigate and draft; humans review, send, approve, and execute.

Where global or harness instructions conflict with this file for work here, this file governs.

## Absolute boundaries

- Draft only. Never send email, post Zendesk comments, or represent a draft as sent.
- Never call customer-account write APIs or change infrastructure.
- Customer-account access is read-only and broker-mediated only; confirm capability status in `agents/runtime-status.md` before any customer-account call.
- Before any customer-account call, resolve the account reference, read its ITSM notes (`scripts/customer_notes.py`; exit 2 = stop, 3 = no token: proceed, note it), and check `agents/customer-access-locks.md`. A `hard-lock` prohibits every call to that account — read-only inspection and identity checks included — no matter what else is in scope.
- Never print or commit credentials, tokens, session values, private keys, or secret contents.
- Commit only de-identified customer context: tracked files carry no customer name, contact, account ID, or `corpId` — describe the pattern only. Real customer content stays in local-only `tickets/`.
- Customer-facing cost figures must be billing-platform-curated. Never expose or mention raw AWS billing figures.
- Generic skills and MCP tools never expand repository authority. AWS documentation access is not customer-account access.
- Exa queries must contain public, de-identified technical terms only; never send customer-identifying, confidential, account, network, or credential data.
- Do not commit, push, merge unless the user explicitly asks.

## Start and route

The boundaries above constrain every step below; none of them is a first step.
Run this sequence in order, from the first message that brings customer work — with or without a ticket number.

1. For customer work, read the thread first — fetch it with `scripts/fetch-ticket.sh` when a ticket number exists. Then read `agents/task-router.md` and classify the task as `quick`, `standard`, or `high-risk`.
2. Record customer work in `tickets/<id>.md` from `templates/ticket-intake.md` **whether or not it arrived as a ticket**; with no ticket number, assign a local one and say so in the record. `tickets/` is local-only and holds real customer content.
3. Search `policy/_routing.md` and load only matching cards. A `draft` card cannot create a commitment or authorize action.
4. Select capabilities through `agents/capability-catalog.md`; verify runtime readiness instead of inventing commands.
5. Load only the router-selected evidence, reply, change, or trap modules. Load a skill only when its direct trigger matches and repository modules do not already provide the procedure.
6. Produce the routed output before yielding. Offering the user a menu of next steps is not an output.

A weekly diary request ("일기", 주간회고) is not customer work: follow `playbooks/weekly-diary.md`; no ticket record.

## Evidence and records

- Fetch current official evidence for load-bearing technical claims; recalled documentation and prior replies are not proof.
- Separate `confirmed`, `hypothesis`, and `unknown`. Missing load-bearing evidence blocks a definitive reply.
- Preserve ticket history by appending dated corrections, actual sent replies, and customer responses; never overwrite prior judgment.
- Keep internal reasoning, raw tool output, secrets, prohibited billing data, and private mappings outside the customer-facing reply block.
- Record people only by operational identity/role, dated observed behavior, and response strategy; never subjective judgment.

## Language and environment

- Answers to the engineer, ticket content, and reply drafts: Korean. Preserve source quotations and technical identifiers exactly.
- Run shell commands non-interactively, stop on unexpected prompts, and quote paths containing Korean text, spaces, or parentheses.
